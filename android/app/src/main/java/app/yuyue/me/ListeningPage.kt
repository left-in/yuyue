package app.yuyue.me

import android.content.Intent
import android.speech.tts.TextToSpeech
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.yuyue.design.ButtonKind
import app.yuyue.design.ButtonSize
import app.yuyue.design.Icons
import app.yuyue.design.Prefs
import app.yuyue.design.YY
import app.yuyue.design.YYButton
import app.yuyue.design.YYField
import app.yuyue.design.YYGroup
import app.yuyue.design.YYLabel
import app.yuyue.design.YYNote
import app.yuyue.design.YYPage
import app.yuyue.design.YYRow
import app.yuyue.design.YYTag
import app.yuyue.design.rememberPref
import app.yuyue.library.Keys
import app.yuyue.shelf.Field
import app.yuyue.speech.BookVoice
import app.yuyue.speech.CloudVoice
import app.yuyue.speech.Player
import app.yuyue.speech.SystemVoice
import app.yuyue.speech.Voices
import app.yuyue.t
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

private val languages get() = listOf(
    Triple("zh", t("中文"), t("从前有一座山，山里有一座庙。")),
    Triple("en", t("英文"), "It was the best of times, it was the worst of times."),
)

/** 朗读, as on iPhone: speed, each language's voice with 试听, and the cloud voices with your own key. */
@Composable
fun ListeningPage() {
    val context = LocalContext.current
    var rate by rememberPref(Player.RATE_KEY, 1f)
    var cloud by remember { mutableStateOf<CloudVoice.Provider?>(null) }
    var version by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) { SystemVoice.Engine.init(context) }
    YYPage {
        Spacer(Modifier.height(YY.s(12)))
        YYGroup {
            row {
                Row(Modifier.heightIn(min = YY.s(38)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(10))) {
                    Text(t("语速"), style = YY.font(11.5f), color = YY.c.t1)
                    Slider(
                        if (rate == 0f) 1f else rate, { rate = (it * 10).roundToInt() / 10f }, valueRange = 0.8f..2f, modifier = Modifier.weight(1f),
                        colors = SliderDefaults.colors(thumbColor = YY.c.card, activeTrackColor = YY.tint.fill, inactiveTrackColor = YY.c.line),
                    )
                    Text("%.1f×".format(if (rate == 0f) 1f else rate), style = YY.font(10.5f, FontWeight.Medium), color = YY.c.t2)
                }
            }
        }
        YYNote(t("读书时在听书面板里调的也是这一个。"))
        for ((tag, name, sample) in languages) VoiceSection(tag, name, sample, version)
        YYNote(t("系统声音在这台设备上合成，不联网。想要更自然的声音：在系统的“文字转语音”里下载语音数据。"))
        Spacer(Modifier.height(8.dp))
        YYGroup {
            row {
                YYRow(t("下载声音"), Icons.cloudDownload, chevron = true) {
                    runCatching { context.startActivity(Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                }
            }
        }
        YYLabel(t("云端声音"))
        YYGroup {
            for (p in CloudVoice.Provider.entries) row {
                YYRow(p.title, Icons.waveform, if (p.isSetUp) t("已连上") else t("填 Key"), chevron = true) { cloud = p }
            }
        }
        YYNote(t("填你自己的 Key，费用直接走你的账号，语阅不经手。读过的句子存在这台设备上，再听不花钱，断网也能听；听书时会把这一章提前合成好。"))
    }
    cloud?.let { CloudKeySheet(it) { cloud = null; version++ } }
}

@Composable
private fun VoiceSection(tag: String, name: String, sample: String, version: Int) {
    var voices by remember { mutableStateOf<List<BookVoice>>(emptyList()) }
    var chosen by rememberPref("player.voice.$tag", "")
    var best by remember { mutableStateOf<BookVoice?>(null) }
    LaunchedEffect(version) {
        voices = Voices.all(tag)
        best = Voices.best(tag)
    }
    val current = voices.firstOrNull { it.id == chosen } ?: best
    val scope = rememberCoroutineScope()
    YYLabel(name, if (voices.isEmpty()) null else t("%lld 个声音", voices.size))
    YYGroup {
        if (voices.isEmpty()) row { YYRow(t("这台设备上没有这种语言的声音")) }
        for (v in voices.take(12)) row {
            Row(Modifier.fillMaxWidth().heightIn(min = YY.s(38)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(10))) {
                Row(Modifier.weight(1f).clickable { chosen = v.id }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(8))) {
                    Text(v.name, style = YY.font(11.5f), color = YY.c.t1, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                    v.qualityName?.let { YYTag(it) }
                    Spacer(Modifier.weight(1f))
                    if (v.id == current?.id) Icon(Icons.check, null, tint = YY.tint.accent, modifier = Modifier.size(YY.s(13)))
                }
                Icon(Icons.play, t("试听"), tint = YY.c.t1, modifier = Modifier.size(YY.s(24)).background(YY.c.inset, CircleShape).clickable {
                    scope.launch { if (v is SystemVoice) v.preview(sample) }
                }.padding(YY.s(5)))
            }
        }
    }
}

/** 云端声音: one provider's key (and Azure's region); 连接 checks it and fetches the voices. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CloudKeySheet(p: CloudVoice.Provider, dismiss: () -> Unit) {
    var key by remember { mutableStateOf(Keys.read(p.keyName) ?: "") }
    var region by remember { mutableStateOf(Prefs.string(CloudVoice.Provider.REGION)) }
    var checking by remember { mutableStateOf(false) }
    var outcome by remember { mutableStateOf<String?>(null) }
    var failed by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 28.dp)) {
            Text(p.title, style = YY.font(14f, FontWeight.Bold), color = YY.c.t1, modifier = Modifier.padding(start = 4.dp, bottom = 10.dp))
            YYGroup {
                row { YYField("Key", 44f) { Secret(key, p.keyHint) { key = it } } }
                if (p == CloudVoice.Provider.Azure) row { YYField(t("区域"), 44f) { Field(region, "eastasia") { region = it } } }
            }
            YYNote(outcome ?: p.help, if (failed) YY.c.danger else YY.c.t3)
            Spacer(Modifier.height(18.dp))
            YYButton(if (checking) "…" else if (key.isBlank()) t("清掉") else t("连接"), ButtonKind.Main, ButtonSize.Large, wide = true, enabled = !checking) {
                val k = key.trim()
                Prefs.set(CloudVoice.Provider.REGION, region.trim().lowercase())
                if (k.isEmpty()) {
                    Keys.delete(p.keyName)
                    dismiss()
                    return@YYButton
                }
                Keys.write(p.keyName, k)
                checking = true
                scope.launch {
                    try {
                        val n = CloudVoice.refresh(p)
                        failed = false
                        outcome = t("已连上 · %lld 个声音", n)
                    } catch (e: Exception) {
                        failed = true
                        outcome = e.message
                    }
                    checking = false
                }
            }
        }
    }
}
