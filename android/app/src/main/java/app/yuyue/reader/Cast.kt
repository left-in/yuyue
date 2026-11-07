package app.yuyue.reader

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYGroup
import app.yuyue.design.YYLabel
import app.yuyue.design.YYNote
import app.yuyue.design.YYSegments
import app.yuyue.speech.BookVoice
import app.yuyue.speech.ClonedVoice
import app.yuyue.speech.ClonedVoices
import app.yuyue.speech.SampleCheck
import app.yuyue.speech.SystemVoice
import app.yuyue.speech.TunedVoice
import app.yuyue.speech.Voices
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.yuyue_core.CastMember
import uniffi.yuyue_core.Role
import uniffi.yuyue_core.RoleVoice
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * 人物声音: who has spoken so far and the
 * voice each reads with; a character's own page; choosing a voice; cloning one. Everyone reads
 * with the narrator's until given one. Only those up to this chapter: no spoilers.
 */
private sealed interface CastRoute {
    data object List : CastRoute
    data class Person(val name: String) : CastRoute
    /** Choosing for someone, or (null) the narrator. */
    data class Voice(val name: String?) : CastRoute
    data class Clone(val name: String?) : CastRoute
}

private fun color(hex: String): Color = runCatching { Color(android.graphics.Color.parseColor(hex)) }.getOrDefault(Color.Gray)

private val plain = RoleVoice(null, 1.0, 0.0, false)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CastSheet(model: ReaderModel, dismiss: () -> Unit) {
    val core = model.core
    val section = model.player?.spot?.section ?: model.section
    val language = model.player?.language ?: model.detail?.summary?.language ?: "zh"
    val stack = remember { mutableStateListOf<CastRoute>(CastRoute.List) }
    var cast by remember { mutableStateOf<List<CastMember>>(emptyList()) }
    var roles by remember { mutableStateOf<List<Role>>(emptyList()) }
    var version by remember { mutableIntStateOf(0) }
    LaunchedEffect(version) {
        val (c, r) = withContext(Dispatchers.IO) {
            runCatching { core.bookCast(model.bookID, section.toUInt()) }.getOrDefault(emptyList()) to runCatching { core.bookRoles(model.bookID) }.getOrDefault(emptyList())
        }
        cast = c
        roles = r
    }
    fun roleOf(name: String) = roles.firstOrNull { it.name == name }?.voice
    fun set(name: String, v: RoleVoice) {
        runCatching { core.setBookRole(model.bookID, name, v) }
        model.player?.rolesChanged()
        model.castChanged()
        version++
    }
    fun sample(name: String?): String {
        if (name == null) return if (language.startsWith("zh")) "你好，这是我的声音。" else "Hello, this is how I sound."
        val script = runCatching { core.sectionScript(model.bookID, section.toUInt()) }.getOrNull()
        val sentences = runCatching { core.sentences(model.bookID, section.toUInt()) }.getOrDefault(emptyList())
        val l = script?.lines?.firstOrNull { (it.who?.let { w -> w == name || w.endsWith(name) || name.endsWith(w) } ?: false) && it.first == it.last }
        if (l != null) {
            val cps = sentences.getOrNull(l.first.toInt())?.codePoints()?.toArray()
            if (cps != null) {
                val a = minOf(l.start.toInt(), cps.size)
                val b = minOf(maxOf(l.end.toInt(), a), cps.size)
                val q = String(cps, a, b - a).trim()
                if (q.length >= 2) return q
            }
        }
        return if (language.startsWith("zh")) "我是$name。" else "I am $name."
    }
    fun preview(v: BookVoice, text: String) {
        model.player?.pause()
        val base = (v as? TunedVoice)?.base ?: v
        if (base is SystemVoice) base.preview(text)
    }

    val route = stack.last()
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 24.dp).verticalScroll(rememberScrollState())) {
            Row(Modifier.fillMaxWidth().height(40.dp), verticalAlignment = Alignment.CenterVertically) {
                if (stack.size > 1) {
                    Icon(Icons.chevronLeft, t("返回"), tint = YY.c.t1, modifier = Modifier.size(28.dp).clip(CircleShape).clickable { stack.removeAt(stack.lastIndex) }.padding(4.dp))
                    Spacer(Modifier.width(6.dp))
                }
                Text(
                    when (route) {
                        CastRoute.List -> t("人物")
                        is CastRoute.Person -> route.name
                        is CastRoute.Voice -> route.name?.let { t("%@的声音", it) } ?: t("旁白的声音")
                        is CastRoute.Clone -> t("克隆一个声音")
                    },
                    fontSize = 15.sp, fontWeight = FontWeight.Bold, color = YY.c.t1, modifier = Modifier.weight(1f),
                )
            }
            when (route) {
                CastRoute.List -> CastList(cast, roles, model, language) { stack.add(it) }
                is CastRoute.Person -> PersonPage(route.name, cast.firstOrNull { it.name == route.name }, roleOf(route.name) ?: plain, sample(route.name),
                    voiceName = { id -> id?.let { i -> roleVoiceName(i) } }, open = { stack.add(it) }, set = { set(route.name, it) },
                    preview = { v ->
                        scopePreview(model, language, v, sample(route.name), ::preview)
                    })
                is CastRoute.Voice -> VoicePage(route.name, model, language, roles, if (route.name != null) roleOf(route.name)?.voice else null, sample(route.name),
                    preview = ::preview, open = { stack.add(it) }) { id, voice ->
                    if (route.name != null) set(route.name, (roleOf(route.name) ?: plain).copy(voice = id))
                    else if (voice != null) { model.player?.choose(voice, language); version++ }
                }
                is CastRoute.Clone -> ClonePage(model, route.name, done = { saved ->
                    if (saved != null && route.name != null) set(route.name, (roleOf(route.name) ?: plain).copy(voice = saved.id))
                    stack.removeAt(stack.lastIndex)
                })
            }
        }
    }
}

private val names = HashMap<String, String>()
private fun roleVoiceName(id: String): String? = names[id]

private fun scopePreview(model: ReaderModel, language: String, v: RoleVoice, text: String, play: (BookVoice, String) -> Unit) {
    kotlinx.coroutines.MainScope().launch {
        val base = v.voice?.let { Voices.find(it) } ?: model.player?.currentVoice(language) ?: return@launch
        play(if (v.rate == 1.0 && v.pitch == 0.0) base else TunedVoice(base, v.rate.toFloat(), v.pitch.toFloat()), text)
    }
}

@Composable
private fun Avatar(text: String?, c: Color) {
    Box(Modifier.size(26.dp).background(if (text == null) YY.c.inset else c.copy(alpha = 0.18f), CircleShape), contentAlignment = Alignment.Center) {
        if (text == null) Icon(Icons.book, null, tint = YY.c.t3, modifier = Modifier.size(13.dp))
        else Text(text, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = c)
    }
}

@Composable
private fun PersonRow(avatar: String?, c: Color, name: String, detail: String, voice: String, own: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 9.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Avatar(avatar, c)
        Column(Modifier.weight(1f)) {
            Text(name, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
            Text(detail, fontSize = 10.sp, color = YY.c.t3, maxLines = 1)
        }
        Text(voice, fontSize = 10.sp, fontWeight = if (own) FontWeight.SemiBold else FontWeight.Normal, color = if (own) YY.c.t1 else YY.c.t3, maxLines = 1)
        Icon(Icons.chevronRight, null, tint = YY.c.t3, modifier = Modifier.size(11.dp))
    }
}

@Composable
private fun CastList(cast: List<CastMember>, roles: List<Role>, model: ReaderModel, language: String, open: (CastRoute) -> Unit) {
    var narrator by remember { mutableStateOf("") }
    var all by remember { mutableStateOf<List<BookVoice>>(emptyList()) }
    LaunchedEffect(Unit) {
        narrator = model.player?.currentVoice(language)?.name ?: ""
        all = Voices.all(language) + ClonedVoices.all()
        for (v in all) names[v.id] = v.name
    }
    YYGroup(Modifier.padding(top = 8.dp)) {
        row { PersonRow(null, YY.c.t3, t("旁白"), t("没单独设声音的人物也用这个"), narrator, true) { open(CastRoute.Voice(null)) } }
    }
    val here = cast.filter { it.linesHere > 0u }
    val before = cast.filter { it.linesHere == 0u }
    for ((title, list) in listOf(t("这一章") to here, t("前面出场过") to before)) {
        if (list.isEmpty()) continue
        YYLabel(title, if (list === here) t("%@ 人", list.size.toString()) else t("读到这里共 %@ 人", cast.size.toString()))
        YYGroup {
            for (m in list) row {
                val role = roles.firstOrNull { it.name == m.name }?.voice
                val v = role?.voice?.let { all.firstOrNull { a -> a.id == it }?.name }
                val detail = (listOfNotNull(m.aliases.take(2).joinToString("、").ifEmpty { null }, t("%@ 句", m.linesSoFar.toString())) +
                    listOfNotNull(if (role?.right == true) t("右边") else null)).joinToString(" · ")
                PersonRow(m.avatar, color(m.color), m.name, detail, v ?: t("跟旁白"), v != null) { open(CastRoute.Person(m.name)) }
            }
        }
    }
    YYNote(if (cast.isEmpty()) t("读到这里还没认出谁在说话。对话多的书读几章后，这里会列出说过话的人。") else t("点一个人：声音、快慢高低、气泡放左边还是右边。改了从下一段起生效，跟着同步到你的其他设备。"))
}

@Composable
private fun PersonPage(
    name: String, member: CastMember?, role: RoleVoice, sample: String, voiceName: (String?) -> String?,
    open: (CastRoute) -> Unit, set: (RoleVoice) -> Unit, preview: (RoleVoice) -> Unit,
) {
    var v by remember(role) { mutableStateOf(role) }
    Row(Modifier.padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.size(34.dp).background(color(member?.color ?: "#888888").copy(alpha = 0.18f), CircleShape), contentAlignment = Alignment.Center) {
            Text(member?.avatar ?: name.takeLast(1), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = color(member?.color ?: "#888888"))
        }
        Text(listOfNotNull(member?.aliases?.joinToString("、")?.ifEmpty { null }, member?.let { t("%@ 句", it.linesSoFar.toString()) }).joinToString(" · "), fontSize = 10.sp, color = YY.c.t3)
    }
    YYGroup {
        row {
            Row(Modifier.fillMaxWidth().heightIn(min = 40.dp).clickable { open(CastRoute.Voice(name)) }, verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.waveform, null, tint = YY.c.t2, modifier = Modifier.size(15.dp))
                Spacer(Modifier.width(10.dp))
                Text(t("声音"), fontSize = 11.5.sp, color = YY.c.t1, modifier = Modifier.weight(1f))
                Text(voiceName(v.voice) ?: t("跟旁白"), fontSize = 10.5.sp, color = YY.c.t3)
                Icon(Icons.chevronRight, null, tint = YY.c.t3, modifier = Modifier.size(11.dp))
            }
        }
        row {
            Row(Modifier.fillMaxWidth().heightIn(min = 40.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(t("气泡放在"), fontSize = 11.5.sp, color = YY.c.t1, modifier = Modifier.weight(1f))
                YYSegments(listOf(false to t("左边"), true to t("右边")), v.right, { v = v.copy(right = it); set(v) }, small = true, modifier = Modifier.width(130.dp))
            }
        }
    }
    Column(Modifier.padding(top = 12.dp).fillMaxWidth().background(YY.c.card, RoundedCornerShape(16.dp)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Tune(t("快慢 %@×", "%.1f".format(v.rate)), t("在全书速度上再快或慢一点"), v.rate.toFloat(), 0.7f..1.4f) { v = v.copy(rate = it.toDouble()) ; set(v) }
        Tune(t("高低 %@", if (v.pitch == 0.0) "0" else "%+.0f".format(v.pitch)), t("声音高一点或低一点"), v.pitch.toFloat(), -6f..6f, steps = 11) { v = v.copy(pitch = it.toDouble()); set(v) }
    }
    Row(
        Modifier.padding(top = 12.dp).fillMaxWidth().background(YY.c.card, RoundedCornerShape(16.dp)).clickable { preview(v) }.padding(12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(Modifier.size(28.dp).background(YY.c.inset, CircleShape), contentAlignment = Alignment.Center) { Icon(Icons.play, null, tint = YY.c.t1, modifier = Modifier.size(12.dp)) }
        Column(Modifier.weight(1f)) {
            Text("“$sample”", fontSize = 11.5.sp, color = YY.c.t1, maxLines = 2)
            Text(t("%@的一句 · 点一下试听", name), fontSize = 10.sp, color = YY.c.t3)
        }
    }
    if (v != plain) {
        Text(t("改回跟旁白"), fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1,
            modifier = Modifier.padding(top = 12.dp).background(YY.c.inset, CircleShape).clickable { v = plain; set(plain) }.padding(horizontal = 14.dp, vertical = 8.dp))
    }
}

@Composable
private fun Tune(title: String, note: String, value: Float, range: ClosedFloatingPointRange<Float>, steps: Int = 0, change: (Float) -> Unit) {
    var local by remember(value) { mutableStateOf(value) }
    Column {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = YY.c.t1, modifier = Modifier.weight(1f))
            Text(note, fontSize = 10.sp, color = YY.c.t3)
        }
        Slider(local, { local = it }, valueRange = range, steps = steps, onValueChangeFinished = { change(local) },
            colors = SliderDefaults.colors(thumbColor = YY.tint.fill, activeTrackColor = YY.tint.fill))
    }
}

@Composable
private fun VoicePage(
    name: String?, model: ReaderModel, language: String, roles: List<Role>, chosenID: String?, sample: String,
    preview: (BookVoice, String) -> Unit, open: (CastRoute) -> Unit, pick: (String?, BookVoice?) -> Unit,
) {
    var all by remember { mutableStateOf<List<BookVoice>>(emptyList()) }
    var cloned by remember { mutableStateOf<List<ClonedVoice>>(emptyList()) }
    var narrator by remember { mutableStateOf<BookVoice?>(null) }
    var chosen by remember(chosenID) { mutableStateOf(chosenID) }
    LaunchedEffect(Unit) {
        all = Voices.all(language)
        cloned = ClonedVoices.all()
        narrator = model.player?.currentVoice(language)
        if (name == null) chosen = narrator?.id
        for (v in all + cloned) names[v.id] = v.name
    }
    @Composable
    fun Choice(id: String?, title: String, detail: String, voice: BookVoice?) {
        Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.size(28.dp).background(YY.c.inset, CircleShape).clickable { voice?.let { preview(it, sample) } }, contentAlignment = Alignment.Center) {
                Icon(Icons.play, t("试听"), tint = YY.c.t1, modifier = Modifier.size(11.dp))
            }
            Row(Modifier.weight(1f).clickable { chosen = id; pick(id, voice) }, verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(title, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
                    Text(detail, fontSize = 10.sp, color = YY.c.t3, maxLines = 1)
                }
                if (chosen == id) Icon(Icons.check, null, tint = YY.tint.accent, modifier = Modifier.size(14.dp))
            }
        }
    }
    if (name != null) {
        YYGroup(Modifier.padding(top = 8.dp)) { row { Choice(null, t("跟旁白"), t("现在旁白是%@，旁白换了%@也跟着换", narrator?.name ?: "", name), narrator) } }
    }
    YYLabel(t("我的声音"))
    YYGroup {
        for (c in cloned) row { Choice(c.id, c.name, if (c.isReady) t("克隆") else t("克隆 · 还不能念，先用旁白的"), c) }
        row {
            Row(Modifier.fillMaxWidth().clickable { open(CastRoute.Clone(name)) }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.size(28.dp).background(YY.c.inset, CircleShape), contentAlignment = Alignment.Center) { Text("🎙", fontSize = 12.sp) }
                Column(Modifier.weight(1f)) {
                    Text(t("克隆一个声音"), fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
                    Text(t("照着念一小段，或者导入一段录音"), fontSize = 10.sp, color = YY.c.t3)
                }
                Icon(Icons.chevronRight, null, tint = YY.c.t3, modifier = Modifier.size(11.dp))
            }
        }
    }
    YYLabel(t("声音"))
    YYGroup {
        for (v in all) row {
            val used = roles.filter { it.voice.voice == v.id && it.name != name }.map { it.name }
            Choice(v.id, Voices.title(v), if (used.isNotEmpty()) t("%@在用", used.joinToString("、")) else if (v.isOffline) t("离线") else t("云端"), v)
        }
    }
}

/** 克隆一个声音: read a little of this book (or bring a recording), hear what's off, name it,
 *  keep it with the white block top right. */
@Composable
private fun ClonePage(model: ReaderModel, forName: String?, done: (ClonedVoice?) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val section = model.player?.spot?.section ?: model.section
    val script = remember {
        val all = runCatching { model.core.sentences(model.bookID, section.toUInt()) }.getOrDefault(emptyList())
        val b = StringBuilder()
        // Whole sentences, not the chapter's title (no punctuation in it).
        for (s in all) { if (s.isBlank() || s.none { it in "，。！？；,.!?;" }) continue; b.append(s); if (b.length > 90) break }
        b.toString().ifEmpty { "你好，这是我的声音。" }
    }
    var recording by remember { mutableStateOf(false) }
    var seconds by remember { mutableStateOf(0.0) }
    val levels = remember { mutableStateListOf<Float>() }
    var file by remember { mutableStateOf<File?>(null) }
    var imported by remember { mutableStateOf(false) }
    var check by remember { mutableStateOf<SampleCheck?>(null) }
    var name by remember { mutableStateOf("") }
    var consent by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    var recorder by remember { mutableStateOf<Recorder?>(null) }

    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (!ok) failure = t("语阅没有用麦克风的权限。在系统设置里给语阅打开麦克风。")
    }
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        val out = File(context.cacheDir, "clone-import-${System.currentTimeMillis()}.audio")
        runCatching { context.contentResolver.openInputStream(uri)?.use { i -> out.outputStream().use { i.copyTo(it) } } }
        imported = true
        file = out
        check = null
        name = t("导入的声音")
    }
    DisposableEffect(Unit) { onDispose { recorder?.stop() } }
    LaunchedEffect(recording) {
        while (recording && isActive) {
            delay(100)
            recorder?.let { r -> seconds = r.seconds; levels.add(r.level); if (levels.size > 40) levels.removeAt(0) }
        }
    }

    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        Step(1, t("录一段"), file == null)
        Step(2, t("试听、起名字"), file != null)
        Spacer(Modifier.weight(1f))
        if (file != null) {
            // 存下 · 右上角白底小块 (11-03 选的 B)
            val ok = !saving && name.isNotBlank() && (!imported || consent)
            Row(
                Modifier.background(YY.c.card, RoundedCornerShape(10.dp)).clickable(enabled = ok) {
                    saving = true
                    scope.launch {
                        try {
                            val v = ClonedVoices.save(file!!, name.trim(), if (imported) null else script, check?.seconds ?: 0.0)
                            done(v)
                        } catch (e: Exception) {
                            failure = e.message
                        }
                        saving = false
                    }
                }.padding(horizontal = 12.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("✓ ", color = YY.c.ok, fontWeight = FontWeight.Bold, fontSize = 12.sp)
                Text(if (saving) t("存下…") else t("存下"), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = if (ok) YY.c.t1 else YY.c.t3)
            }
        }
    }
    if (file == null) {
        Text(script, fontSize = 15.sp, lineHeight = 27.sp, color = YY.c.t1,
            modifier = Modifier.padding(top = 12.dp).fillMaxWidth().background(YY.c.card, RoundedCornerShape(16.dp)).padding(horizontal = 16.dp, vertical = 14.dp))
        YYNote(t("照平常读书的样子念，不用念完。"))
        // 录音 B · 整条就是录音 (11-03 选的)
        Row(
            Modifier.padding(top = 10.dp).fillMaxWidth().height(58.dp).background(YY.c.card, RoundedCornerShape(16.dp)).clickable {
                if (recording) {
                    val r = recorder
                    recording = false
                    recorder = null
                    val f = r?.stop()
                    if (f != null && seconds >= 1) { file = f; check = r.check(); name = t("我的声音") }
                } else if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                    permission.launch(Manifest.permission.RECORD_AUDIO)
                } else {
                    model.player?.pause()
                    levels.clear()
                    seconds = 0.0
                    recorder = Recorder(File(context.cacheDir, "clone-${System.currentTimeMillis()}.wav")).also { it.start() }
                    recording = true
                }
            }.padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(Modifier.size(10.dp).background(YY.c.danger, CircleShape))
            Text("%d:%02d".format(seconds.toInt() / 60, seconds.toInt() % 60), fontSize = 17.sp, fontWeight = FontWeight.Bold, color = YY.c.t1)
            Row(Modifier.weight(1f).height(24.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                for (l in levels.takeLast(28)) Box(Modifier.width(2.dp).height((l * 24).coerceAtLeast(3f).dp).background(YY.c.t2, RoundedCornerShape(1.dp)))
            }
            if (recording) Box(Modifier.size(10.dp).background(YY.c.danger, RoundedCornerShape(2.5.dp)))
            Text(if (recording) t("停下") else t("点一下开始录"), fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
        }
        if (seconds >= 8) Text(t("✓ 8 秒够用了；多录到 30 秒更像。"), fontSize = 10.sp, color = YY.c.ok, modifier = Modifier.padding(4.dp))
        else YYNote(t("8 秒就够，30 秒更像。"))
        Row(Modifier.padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            WhiteBlock(t("重来"), Modifier) { recorder?.stop(); recorder = null; recording = false; seconds = 0.0; levels.clear() }
            WhiteBlock(t("导入一段录音"), Modifier.weight(1f)) { importer.launch("audio/*") }
        }
    } else {
        check?.let { c ->
            YYGroup(Modifier.padding(top = 12.dp)) {
                for (item in c.items) row {
                    Row(Modifier.fillMaxWidth().padding(vertical = 9.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(if (item.ok) "✓" else "!", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = if (item.ok) YY.c.ok else YY.c.warn,
                            modifier = Modifier.background((if (item.ok) YY.c.ok else YY.c.warn).copy(alpha = 0.13f), RoundedCornerShape(5.dp)).padding(horizontal = 6.dp, vertical = 1.dp))
                        Column(Modifier.weight(1f)) {
                            Text(item.title, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
                            item.detail?.let { Text(it, fontSize = 10.sp, color = YY.c.t3) }
                        }
                        if (!item.ok) WhiteBlock(t("重录"), Modifier) { file = null; check = null; seconds = 0.0; levels.clear() }
                    }
                }
            }
        }
        if (!ClonedVoices.engineAvailable) YYNote(t("试听要等克隆好：现在克隆用你在设置里接的 ElevenLabs（录音会传到你自己的 ElevenLabs 账号）。没接也能先存下，接上后再用。"))
        YYGroup(Modifier.padding(top = 12.dp)) {
            row {
                Row(Modifier.fillMaxWidth().heightIn(min = 40.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(t("名字"), fontSize = 11.sp, color = YY.c.t2, modifier = Modifier.width(58.dp))
                    BasicTextField(name, { name = it }, singleLine = true, textStyle = TextStyle(fontSize = 12.sp, color = YY.c.t1), modifier = Modifier.weight(1f))
                }
            }
        }
        YYGroup(Modifier.padding(top = 12.dp)) {
            row {
                Row(Modifier.fillMaxWidth().clickable { consent = !consent }.padding(vertical = 9.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(if (consent) Icons.checkCircle else Icons.circle, null, tint = if (consent) YY.tint.fill else YY.c.t3, modifier = Modifier.size(18.dp))
                    Column(Modifier.weight(1f)) {
                        Text(t("这是我的声音，或者我得到了本人同意"), fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
                        Text(if (imported) t("导入别人的录音时一定要勾") else t("录的是别人时也要勾"), fontSize = 10.sp, color = YY.c.t3)
                    }
                }
            }
        }
        YYNote(if (ClonedVoices.engineAvailable) t("录音存在这台设备上，克隆时会传到你自己的 ElevenLabs 账号。") else t("录音只存在这台设备上。"))
    }
    failure?.let { Text(it, fontSize = 11.sp, color = YY.c.danger, modifier = Modifier.padding(top = 8.dp)) }
}

@Composable
private fun Step(n: Int, title: String, on: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.size(16.dp).background(if (on) YY.tint.black else YY.c.inset, CircleShape), contentAlignment = Alignment.Center) {
            Text("$n", fontSize = 9.5.sp, fontWeight = FontWeight.SemiBold, color = if (on) YY.tint.onBlack else YY.c.t3)
        }
        Text(title, fontSize = 10.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal, color = if (on) YY.c.t1 else YY.c.t3)
    }
}

@Composable
private fun WhiteBlock(title: String, modifier: Modifier, onClick: () -> Unit) {
    Box(modifier.height(34.dp).background(YY.c.card, RoundedCornerShape(10.dp)).clickable(onClick = onClick).padding(horizontal = 14.dp), contentAlignment = Alignment.Center) {
        Text(title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
    }
}

/** The microphone, for 录一段: 16-bit mono WAV, with a level as it goes. */
private class Recorder(private val file: File) {
    private val rate = 44_100
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    @Volatile var seconds = 0.0
    @Volatile var level = 0f
    private val samples = java.io.ByteArrayOutputStream()

    @android.annotation.SuppressLint("MissingPermission")
    fun start() {
        val size = maxOf(AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT), 4096)
        val r = AudioRecord(MediaRecorder.AudioSource.MIC, rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, size)
        record = r
        r.startRecording()
        thread = Thread {
            val buf = ShortArray(rate / 10)
            while (record != null) {
                val n = r.read(buf, 0, buf.size)
                if (n <= 0) continue
                var sum = 0.0
                val bytes = ByteArray(n * 2)
                for (i in 0 until n) {
                    sum += (buf[i] / 32768.0).let { it * it }
                    bytes[i * 2] = (buf[i].toInt() and 0xFF).toByte()
                    bytes[i * 2 + 1] = (buf[i].toInt() shr 8 and 0xFF).toByte()
                }
                synchronized(samples) { samples.write(bytes) }
                val db = 20 * log10(sqrt(sum / n).coerceAtLeast(1e-5))
                level = ((db + 50) / 50).toFloat().coerceIn(0.08f, 1f)
                seconds = samples.size() / 2.0 / rate
                if (seconds >= 60) break
            }
        }.also { it.start() }
    }

    fun stop(): File? {
        val r = record ?: return file.takeIf { it.exists() }
        record = null
        thread?.join(500)
        runCatching { r.stop() }
        r.release()
        val pcm = synchronized(samples) { samples.toByteArray() }
        RandomAccessFile(file, "rw").use { f ->
            fun int(v: Int) = f.write(byteArrayOf(v.toByte(), (v shr 8).toByte(), (v shr 16).toByte(), (v shr 24).toByte()))
            fun short(v: Int) = f.write(byteArrayOf(v.toByte(), (v shr 8).toByte()))
            f.setLength(0)
            f.write("RIFF".toByteArray()); int(36 + pcm.size); f.write("WAVEfmt ".toByteArray())
            int(16); short(1); short(1); int(rate); int(rate * 2); short(2); short(16)
            f.write("data".toByteArray()); int(pcm.size); f.write(pcm)
        }
        return file
    }

    fun check(): SampleCheck {
        val pcm = synchronized(samples) { samples.toByteArray() }
        val s = ShortArray(pcm.size / 2) { i -> ((pcm[i * 2 + 1].toInt() shl 8) or (pcm[i * 2].toInt() and 0xFF)).toShort() }
        return SampleCheck.of(s, rate)
    }
}
