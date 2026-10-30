package app.yuyue.me

import android.os.StatFs
import android.text.format.Formatter
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import app.yuyue.companion.CompanionConfig
import app.yuyue.companion.CompanionProvider
import app.yuyue.design.ButtonKind
import app.yuyue.design.ButtonSize
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYButton
import app.yuyue.design.YYGroup
import app.yuyue.design.YYLabel
import app.yuyue.design.YYNote
import app.yuyue.design.YYPage
import app.yuyue.design.YYRow
import app.yuyue.design.YYSegments
import app.yuyue.design.rememberPref
import app.yuyue.library.Library
import app.yuyue.reader.ForeignPrefs
import app.yuyue.shelf.BookCover
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import uniffi.yuyue_core.BookFormat
import java.io.File
import kotlinx.coroutines.launch
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.clickable
import androidx.compose.foundation.ExperimentalFoundationApi

@Composable
private fun Toggle(on: Boolean, change: (Boolean) -> Unit, enabled: Boolean = true) {
    Switch(on, change, enabled = enabled, colors = SwitchDefaults.colors(checkedTrackColor = YY.tint.fill, checkedThumbColor = YY.c.card, uncheckedTrackColor = YY.c.inset, uncheckedBorderColor = YY.c.line))
}

@Composable
private fun TwoLines(title: String, detail: String?, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(YY.s(1))) {
        Text(title, style = YY.font(11.5f), color = YY.c.t1)
        detail?.let { Text(it, style = YY.font(10f), color = YY.c.t3, maxLines = 1) }
    }
}

// MARK: 外文阅读

/** 外文阅读 (prototype 外文阅读设置), as on iPhone: saying a word aloud, 难词注释, the 生词 marks,
 *  and translation. */
@Composable
fun ForeignPage(core: uniffi.yuyue_core.YuyueCore) {
    var speak by rememberPref(ForeignPrefs.SPEAK, true)
    var accent by rememberPref(ForeignPrefs.ACCENT, "en-GB")
    var mark by rememberPref(ForeignPrefs.MARK, true)
    var gloss by rememberPref(ForeignPrefs.GLOSS, true)
    var level by rememberPref(ForeignPrefs.LEVEL, 3)
    var glossVocab by rememberPref(ForeignPrefs.GLOSS_VOCAB, false)
    YYPage {
        YYLabel(t("点词"))
        YYGroup {
            row { YYRow(t("点词时读出来"), trailing = { Toggle(speak, { speak = it }) }) }
            row {
                YYRow(t("发音"), trailing = {
                    YYSegments(listOf("en-GB" to t("英音"), "en-US" to t("美音")), accent, { accent = it }, small = true, modifier = Modifier.width(YY.s(110)))
                })
            }
        }
        YYLabel(t("MDict 词典"))
        MDictList(core)
        YYNote(t("点词先查这里导入的词典，查不到再用语阅自带的英汉词典（不联网，变形词能找回原词）。长按一本可以移除。"))
        YYLabel(t("难词注释"))
        YYGroup {
            row { YYRow(t("在难词上方写释义"), trailing = { Toggle(gloss, { gloss = it }) }) }
            row {
                // The five levels get the row's whole width: their English names are long.
                Column(Modifier.fillMaxWidth().padding(vertical = YY.s(8)), verticalArrangement = Arrangement.spacedBy(YY.s(6))) {
                    Text(t("级别"), style = YY.font(11.5f), color = YY.c.t1)
                    YYSegments(GLOSS_LEVELS.map { it.first to t(it.second) }, level, { if (gloss && !glossVocab) level = it }, small = true,
                        modifier = Modifier.fillMaxWidth().alpha(if (gloss && !glossVocab) 1f else 0.5f))
                }
            }
            row { YYRow(t("只标生词本里的词"), trailing = { Toggle(glossVocab, { glossVocab = it }, enabled = gloss) }) }
            row {
                Column(Modifier.padding(vertical = YY.s(6))) {
                    Text(t("预览"), style = YY.font(10f), color = YY.c.t3)
                    Row(verticalAlignment = Alignment.Bottom, modifier = Modifier.padding(top = YY.s(4))) {
                        val serif = FontFamily.Serif
                        Text("It is a truth universally ", style = YY.font(12f, family = serif), color = YY.c.t1)
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("公认", style = YY.font(9.5f), color = if (gloss && !glossVocab && level <= 4) YY.tint.accent else YY.c.card.copy(alpha = 0f))
                            Text("acknowledged", style = YY.font(12f, family = serif), color = YY.c.t1)
                        }
                        Text(", that a…", style = YY.font(12f, family = serif), color = YY.c.t1, maxLines = 1)
                    }
                }
            }
        }
        YYLabel(t("生词"))
        YYGroup {
            row {
                Row(Modifier.fillMaxWidth().padding(vertical = YY.s(8)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(10))) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(YY.s(3))) {
                        Text(t("在所有书里标出来"), style = YY.font(11.5f, FontWeight.SemiBold), color = YY.c.t1)
                        Text(buildAnnotatedString {
                            append("…this truth is so well ")
                            withStyle(SpanStyle(color = YY.c.t1, textDecoration = if (mark) TextDecoration.Underline else null)) { append("fixed") }
                            append(" in the minds…")
                        }, style = YY.font(11f, family = FontFamily.Serif), color = YY.c.t2)
                    }
                    Toggle(mark, { mark = it })
                }
            }
        }
        YYNote(t("生词本里在学的词，在任何一本书里再遇到，都用虚线标出来；掌握了就不再标。"))
        YYLabel(t("翻译"))
        YYGroup {
            row { YYRow(t("翻译"), value = t("交给手机上的翻译 App")) }
        }
        YYNote(t("选中一句点“翻译”，交给 Google 翻译这类装在手机上的翻译 App。"))
    }
}

/** 难词注释's levels, as on Apple (`ForeignPrefs.levels`). */
private val GLOSS_LEVELS = listOf(2 to "四级", 3 to "六级", 4 to "考研", 5 to "雅思", 6 to "GRE")

// MARK: 引擎

/** 引擎 (prototype 引擎), as on iPhone: who answers as 书伴, which voice reads, what translates.
 *  All free, no membership; the phone's own, or the reader's own key. */
@Composable
fun EnginesPage(open: (MePage) -> Unit) {
    val current = CompanionConfig.current
    YYPage {
        Text(
            t("书伴、朗读、翻译用的引擎都在这里。全部免费，没有会员；用设备自带的，或者填你自己的 Key。"),
            style = YY.font(11f).copy(lineHeight = YY.sp(18.7f)), color = YY.c.t2, modifier = Modifier.padding(start = YY.s(4), end = YY.s(4), top = YY.s(12), bottom = YY.s(4)),
        )
        YYLabel(t("书伴"))
        YYGroup {
            for (p in CompanionProvider.added) row {
                val saved = CompanionConfig.saved(p)
                val on = current?.provider == p && current.isReady
                YYRow(p.title, value = if (saved.isReady) saved.model else t("还没填好"), chevron = !on, onClick = { open(MePage.Companion) }, trailing = {
                    if (on) Icon(Icons.check, null, tint = YY.tint.accent, modifier = Modifier.size(YY.s(13)))
                })
            }
            row { YYRow(t("添加服务商"), icon = Icons.add, titleColor = YY.tint.accent, chevron = true, onClick = { open(MePage.Companion) }) }
        }
        YYLabel(t("朗读"))
        YYGroup {
            row {
                Row(Modifier.fillMaxWidth().padding(vertical = YY.s(8)), verticalAlignment = Alignment.CenterVertically) {
                    TwoLines(t("系统语音"), t("在这台设备上，不联网"), Modifier.weight(1f))
                    YYButton(t("设置"), ButtonKind.Plain, ButtonSize.Small) { open(MePage.Listening) }
                }
            }
        }
        YYLabel(t("翻译"))
        YYGroup {
            row {
                Row(Modifier.fillMaxWidth().padding(vertical = YY.s(8)), verticalAlignment = Alignment.CenterVertically) {
                    TwoLines(t("手机上的翻译 App"), t("比如 Google 翻译"), Modifier.weight(1f))
                    YYButton(t("设置"), ButtonKind.Plain, ButtonSize.Small) { open(MePage.Foreign) }
                }
            }
        }
        YYNote(t("Key 只存在这台设备上，加密保存，不同步、不上传。"))
    }
}

// MARK: 存储空间

private class Usage(val total: Long, val free: Long, val books: List<Pair<String, Long>>, val deleted: Int, val deletedBytes: Long)

private fun bytes(f: File): Long = if (f.isFile) f.length() else f.listFiles()?.sumOf(::bytes) ?: 0

private fun measure(library: Library): Usage {
    val active = library.books.map { it.id }.toSet()
    val dirs = File(library.dataDir, "books").listFiles()?.filter { !it.name.startsWith(".") } ?: emptyList()
    val sizes = dirs.map { it.name to bytes(it) }
    val (kept, gone) = sizes.partition { it.first in active }
    return Usage(bytes(library.dataDir), StatFs(library.dataDir.path).availableBytes, kept.sortedByDescending { it.second }, gone.size, gone.sumOf { it.second })
}

/** 存储空间, as on iPhone: what 语阅 takes, the books deleted (kept 30 days), and each book from
 *  the largest. */
@Composable
fun StoragePage(library: Library) {
    val context = LocalContext.current
    var version by remember { mutableIntStateOf(0) }
    var usage by remember { mutableStateOf<Usage?>(null) }
    LaunchedEffect(version, library.books) { usage = withContext(Dispatchers.IO) { measure(library) } }
    fun size(b: Long) = Formatter.formatShortFileSize(context, b)
    val u = usage
    val bookBytes = u?.books?.sumOf { it.second } ?: 0
    val parts = listOf(t("书文件") to bookBytes, t("已删除") to (u?.deletedBytes ?: 0),
        t("其他") to maxOf(0, (u?.total ?: 0) - bookBytes - (u?.deletedBytes ?: 0)))
    val shades = listOf(1f, 0.5f, 0.25f)
    YYPage {
        // `.v-sy-use`
        Column(Modifier.padding(top = YY.s(10), bottom = YY.s(14)).fillMaxWidth().background(YY.c.card, RoundedCornerShape(YY.s(16))).padding(horizontal = YY.s(14), vertical = YY.s(13))) {
            Text(t("语阅一共用了"), style = YY.font(10.5f), color = YY.c.t3)
            Row(verticalAlignment = Alignment.Bottom) {
                val (number, unit) = (u?.let { size(it.total) } ?: "…").let { s -> s.substringBeforeLast(' ', s) to s.substringAfterLast(' ', "") }
                Text(number, style = YY.font(26f, FontWeight.Bold), color = YY.c.t1)
                Text(unit, style = YY.font(12f, FontWeight.SemiBold), color = YY.c.t1, modifier = Modifier.padding(start = YY.s(3), bottom = YY.s(5)))
                Spacer(Modifier.weight(1f))
                u?.let { Text(t("这台 %@ 还剩 %@", t("手机"), size(it.free)), style = YY.font(10f), color = YY.c.t3, modifier = Modifier.padding(bottom = YY.s(5))) }
            }
            val total = maxOf(1L, parts.sumOf { it.second })
            Row(Modifier.padding(top = YY.s(10)).fillMaxWidth().height(YY.s(10)).background(YY.c.inset, RoundedCornerShape(YY.s(5))), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                parts.forEachIndexed { i, (_, b) ->
                    if (b > 0) Box(Modifier.weight(maxOf(0.01f, b.toFloat() / total)).height(YY.s(10)).background(YY.c.t1.copy(alpha = shades[i])))
                }
            }
            Column(Modifier.padding(top = YY.s(12)), verticalArrangement = Arrangement.spacedBy(YY.s(7))) {
                for (pair in parts.chunked(2)) Row(horizontalArrangement = Arrangement.spacedBy(YY.s(16))) {
                    for ((label, b) in pair) Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(6))) {
                        Box(Modifier.size(YY.s(8)).background(YY.c.t1.copy(alpha = shades[parts.indexOfFirst { it.first == label }]), RoundedCornerShape(2.dp)))
                        Text(label, style = YY.font(10.5f), color = YY.c.t2, modifier = Modifier.weight(1f))
                        Text(size(b), style = YY.font(10.5f, FontWeight.Medium), color = YY.c.t1)
                    }
                }
            }
        }
        YYGroup {
            row {
                Row(Modifier.fillMaxWidth().padding(vertical = YY.s(9)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(10))) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(YY.s(1))) {
                        Text(t("已删除的书 · %lld 本 · %@", u?.deleted ?: 0, size(u?.deletedBytes ?: 0)), style = YY.font(11.5f, FontWeight.Medium), color = YY.c.t1)
                        Text(t("留 30 天可以撤销，过了自动清掉"), style = YY.font(10f), color = YY.c.t3)
                    }
                    YYButton(t("现在清掉"), ButtonKind.Danger, ButtonSize.Small, enabled = (u?.deleted ?: 0) > 0) {
                        runCatching { library.core.purgeDeleted(0) }
                        version++
                    }
                }
            }
        }
        if (u != null && u.books.isNotEmpty()) {
            YYLabel(t("每本书"), t("从大到小"))
            YYGroup {
                for ((id, b) in u.books.take(30)) {
                    val book = library.books.firstOrNull { it.id == id } ?: continue
                    row {
                        Row(Modifier.fillMaxWidth().padding(vertical = YY.s(7)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(10))) {
                            BookCover(book, Modifier.width(YY.s(24)))
                            TwoLines(book.title, when (book.format) { BookFormat.PDF -> "PDF"; BookFormat.TXT -> "TXT"; BookFormat.MOBI -> "MOBI"; BookFormat.EPUB -> "EPUB" }, Modifier.weight(1f))
                            Text(size(b), style = YY.font(11f, FontWeight.SemiBold), color = YY.c.t1)
                        }
                    }
                }
            }
        }
    }
}

/** 导入 MDict 词典: the ones imported, on or off, 导入 from the files on the phone. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MDictList(core: uniffi.yuyue_core.YuyueCore) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var list by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(runCatching { core.dictionaries() }.getOrDefault(emptyList())) }
    var importing by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<String?>(null) }
    var failed by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<String?>(null) }
    fun reload() { list = runCatching { core.dictionaries() }.getOrDefault(emptyList()) }
    val picker = androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        scope.launch {
            failed = null
            for (uri in uris) {
                val name = uri.lastPathSegment?.substringAfterLast('/')?.substringBeforeLast('.') ?: "MDict"
                importing = name
                val result = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    runCatching {
                        // A copy the core can read by path; gone once it has been read in.
                        val file = java.io.File(context.cacheDir, "import-$name.mdx")
                        context.contentResolver.openInputStream(uri)?.use { input -> file.outputStream().use { input.copyTo(it) } }
                        try { core.importDictionary(file.path) } finally { file.delete() }
                    }
                }
                result.exceptionOrNull()?.let { failed = it.message }
                reload()
            }
            importing = null
        }
    }
    YYGroup {
        for (d in list) {
            row {
                Box(Modifier.combinedClickable(onClick = {}, onLongClick = { runCatching { core.removeDictionary(d.id) }; reload() })) {
                    YYRow(d.title, value = t("%lld 个词条", d.entries.toLong()), trailing = {
                        Toggle(d.enabled, { on -> runCatching { core.setDictionary(d.id, on) }; reload() })
                    })
                }
            }
        }
        row {
            Row(Modifier.fillMaxWidth().clickable(enabled = importing == null) { picker.launch(arrayOf("*/*")) }.padding(vertical = YY.s(10)),
                verticalAlignment = Alignment.CenterVertically) {
                Text(importing?.let { t("正在导入 %@…", it) } ?: t("导入 MDict 词典（.mdx）"), style = YY.font(11.5f), color = YY.tint.accent)
            }
        }
        failed?.let { f -> row { Text(f, style = YY.font(10.5f), color = YY.c.danger, modifier = Modifier.padding(vertical = YY.s(6))) } }
    }
}
