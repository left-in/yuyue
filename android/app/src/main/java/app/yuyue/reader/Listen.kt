package app.yuyue.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.speech.BookVoice
import app.yuyue.speech.Player
import app.yuyue.speech.SystemVoice
import app.yuyue.speech.Voices
import app.yuyue.t
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.roundToInt

/** 听书, over the capsule (as on iPhone): the voice and 试听, speed (the pitch stays), the sleep
 *  timer, and 单句循环. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ListenSheet(model: ReaderModel, dismiss: () -> Unit) {
    val player = model.player ?: return dismiss()
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.card) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            VoiceRow(model, player)
            Speed(model, player)
            Sleep(model, player)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Tile(t("单句循环"), if (player.loop) t("开") else t("关"), player.loop, Modifier.weight(1f)) { player.loop = !player.loop }
                Spacer(Modifier.weight(2f))
            }
        }
    }
}

@Composable
private fun VoiceRow(model: ReaderModel, player: Player) {
    val language = player.language
    var current by remember { mutableStateOf<BookVoice?>(null) }
    var all by remember { mutableStateOf<List<BookVoice>>(emptyList()) }
    var menu by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(language) {
        current = player.currentVoice(language)
        all = Voices.all(language)
    }
    Row(
        Modifier.fillMaxWidth().background(YY.c.inset, RoundedCornerShape(14.dp)).padding(start = 9.dp, end = 8.dp, top = 9.dp, bottom = 9.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(Modifier.size(32.dp).background(YY.c.card, RoundedCornerShape(9.dp)), contentAlignment = Alignment.Center) {
            Icon(Icons.waveform, null, tint = YY.c.t1, modifier = Modifier.size(17.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(current?.let(Voices::title) ?: t("没有能读的声音"), fontSize = 12.5.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1, maxLines = 1)
            Text(
                listOf(language, if (current?.isOffline == false) t("云端 · 读过的存在本机") else t("离线"), t("在这台设备上合成")).joinToString(" · "),
                fontSize = 10.5.sp, color = YY.c.t2, maxLines = 1,
            )
        }
        current?.let { v ->
            Text(t("试听"), fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1, modifier = Modifier.background(YY.c.card, RoundedCornerShape(50)).clickable {
                if (model.isPlaying) player.pause()
                if (v is SystemVoice) v.preview(sample(language))
            }.padding(horizontal = 10.dp, vertical = 5.dp))
        }
        Box {
            Row(Modifier.clickable { menu = true }, verticalAlignment = Alignment.CenterVertically) {
                Text(t("换声音"), fontSize = 11.sp, color = YY.c.t2)
                Icon(Icons.chevronRight, null, tint = YY.c.t2, modifier = Modifier.size(14.dp))
            }
            DropdownMenu(menu, { menu = false }, containerColor = YY.c.card) {
                for (v in all) {
                    DropdownMenuItem(
                        text = { Text(Voices.title(v), color = YY.c.t1) },
                        trailingIcon = { if (v.id == current?.id) Icon(Icons.check, null, tint = YY.tint.accent) },
                        onClick = {
                            menu = false
                            scope.launch { player.choose(v, language); current = v }
                        },
                    )
                }
            }
        }
    }
}

private fun sample(language: String) = if (language.lowercase().startsWith("zh")) "你好，我来给你读这本书。" else "Hello, I'll read this book to you."

private val rates = listOf(0.8f, 1.0f, 1.2f, 1.5f, 2.0f)

private fun rateText(r: Float) = if (r == r.roundToInt().toFloat()) "${r.roundToInt()}" else "%.1f".format(r)

@Composable
private fun Speed(model: ReaderModel, player: Player) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(t("速度"), fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
            Text(rateText(player.rate) + "×", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = YY.c.t1)
            Text(t("不变调"), fontSize = 10.sp, fontWeight = FontWeight.Medium, color = YY.c.t2, modifier = Modifier.background(YY.c.inset, RoundedCornerShape(5.dp)).padding(horizontal = 6.dp, vertical = 3.dp))
            Spacer(Modifier.weight(1f))
            Text(t("这一%@按这个速度还要 %lld 分钟", t("章"), minutesLeft(model, player)), fontSize = 10.5.sp, color = YY.c.t3)
        }
        Slider(
            player.rate, { player.changeRate((it * 10).roundToInt() / 10f) }, valueRange = 0.8f..2.0f,
            colors = SliderDefaults.colors(thumbColor = YY.c.card, activeTrackColor = YY.tint.fill, inactiveTrackColor = YY.c.line),
        )
        Row(Modifier.fillMaxWidth().padding(horizontal = 6.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            for (r in rates) {
                val on = abs(player.rate - r) < 0.05f
                Text(rateText(r), fontSize = 10.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal, color = if (on) YY.c.t1 else YY.c.t3, modifier = Modifier.clickable { player.changeRate(r) })
            }
        }
    }
}

/** Minutes of listening left in the chapter at this speed (about 220 characters a minute at 1×). */
private fun minutesLeft(model: ReaderModel, player: Player): Int {
    val s = model.detail?.sections?.getOrNull(model.section) ?: return 0
    val n = maxOf(1, s.sentences.toInt())
    val left = s.units.toDouble() * (n - model.sentence) / n
    return maxOf(1, (left / 220 / maxOf(0.5f, player.rate)).roundToInt())
}

@Composable
private fun Sleep(model: ReaderModel, player: Player) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row {
            Text(t("睡眠定时"), fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1, modifier = Modifier.weight(1f))
            Text(t("停的时候自动加一个书签"), fontSize = 10.5.sp, color = YY.c.t3)
        }
        Row(Modifier.fillMaxWidth().background(YY.c.inset, RoundedCornerShape(12.dp)).padding(3.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            val s = player.sleep
            Choice(t("关"), null, s == Player.Sleep.Off, Modifier.weight(1f)) { player.sleep = Player.Sleep.Off }
            Choice(t("本句读完"), null, s == Player.Sleep.Sentence, Modifier.weight(1f)) { player.sleep = if (s == Player.Sleep.Sentence) Player.Sleep.Off else Player.Sleep.Sentence }
            Choice(t("本章结束"), t("约 %lld 分钟", minutesLeft(model, player)), s == Player.Sleep.Chapter, Modifier.weight(1f)) { player.sleep = if (s == Player.Sleep.Chapter) Player.Sleep.Off else Player.Sleep.Chapter }
            for (m in listOf(15, 30, 60)) {
                val on = s is Player.Sleep.Until && s.minutes == m
                val left = (s as? Player.Sleep.Until)?.takeIf { it.minutes == m }?.let { maxOf(1, ((it.at - System.currentTimeMillis()) / 60000.0).toInt() + 1) }
                Choice(t("%lld 分钟", m), left?.let { t("还剩 %lld 分", it) }, on, Modifier.weight(1f)) {
                    player.sleep = if (on) Player.Sleep.Off else Player.Sleep.Until(System.currentTimeMillis() + m * 60_000L, m)
                }
            }
        }
    }
}

@Composable
private fun Choice(title: String, detail: String?, on: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Column(
        modifier.height(40.dp).background(if (on) YY.c.card else Color.Transparent, RoundedCornerShape(9.dp)).clickable(onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
    ) {
        Text(title, fontSize = 11.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal, color = YY.c.t1, maxLines = 1)
        if (on && detail != null) Text(detail, fontSize = 10.sp, color = YY.c.t2, maxLines = 1)
    }
}

@Composable
private fun Tile(title: String, detail: String, on: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Column(
        modifier.background(if (on) YY.tint.accentSoft else YY.c.inset, RoundedCornerShape(12.dp)).clickable(onClick = onClick).padding(10.dp),
    ) {
        Text(title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = if (on) YY.tint.accent else YY.c.t1)
        Text(detail, fontSize = 10.5.sp, color = YY.c.t2)
    }
}
