package app.yuyue.reader

import android.text.format.Formatter
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.yuyue.design.ButtonKind
import app.yuyue.design.ButtonSize
import app.yuyue.design.YY
import app.yuyue.design.YYButton
import app.yuyue.design.YYField
import app.yuyue.design.YYGroup
import app.yuyue.design.YYLabel
import app.yuyue.design.YYNote
import app.yuyue.design.YYRow
import app.yuyue.design.YYSegments
import app.yuyue.library.Library
import app.yuyue.shelf.Field
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.yuyue_core.TxtChoice
import uniffi.yuyue_core.TxtLayout

/** 编码和目录, as on Apple, for a TXT: which encoding it is read in, with the first
 *  lines to see whether they read, and the rule that finds its chapters, with what it found. A
 *  chapter far longer than the others is pointed out. 完成 builds the book again the chosen way. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TxtLayoutSheet(library: Library, bookID: String, title: String, rebuilt: () -> Unit, dismiss: () -> Unit) {
    val core = library.core
    val applied = remember { runCatching { core.txtChoice(bookID) }.getOrDefault(TxtChoice(null, null)) }
    var encoding by remember { mutableStateOf(applied.encoding) }
    var rule by remember { mutableStateOf(applied.rule ?: "") }
    var layout by remember { mutableStateOf<TxtLayout?>(null) }
    var working by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    var allChapters by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val choice = TxtChoice(encoding, rule.trim().ifEmpty { null })
    LaunchedEffect(choice) {
        // A rule being typed is tried once the typing pauses; a tapped encoding at once.
        if (layout != null) delay(250)
        layout = withContext(Dispatchers.IO) { runCatching { core.txtLayout(bookID, choice) }.getOrNull() }
    }
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 28.dp)) {
            Text(t("编码和目录"), style = YY.font(14f, FontWeight.Bold), color = YY.c.t1, modifier = Modifier.padding(start = 4.dp))
            Text(listOfNotNull("$title.txt", layout?.let { Formatter.formatShortFileSize(context, it.size.toLong()) }).joinToString(" · "), style = YY.font(10f), color = YY.c.t3, modifier = Modifier.padding(start = 4.dp))
            val l = layout
            YYLabel(t("编码"), l?.let { t("自动识别为 %@", it.detected) })
            YYSegments(listOf<Pair<String?, String>>(null to t("自动"), "UTF-8" to "UTF-8", "GB18030" to "GB18030", "Big5" to "Big5"), encoding, { encoding = it }, modifier = Modifier.fillMaxWidth())
            Column(Modifier.padding(top = 10.dp).fillMaxWidth().background(YY.c.card, RoundedCornerShape(14.dp)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                if (l == null || l.preview.isEmpty()) Text(if (l?.error == null) t("正在读…") else t("这种编码读不出字"), style = YY.font(11.5f), color = YY.c.t3)
                l?.previewTitle?.let { Text(it, style = YY.font(12.5f, FontWeight.SemiBold, YY.serif), color = YY.c.t1) }
                l?.preview?.take(3)?.forEach { Text("　　" + it, style = YY.font(11.5f, family = YY.serif), color = YY.c.t1, maxLines = 3) }
            }
            YYLabel(t("目录"), l?.takeIf { it.error == null }?.let { t("识别出 %lld 章", it.chapters.size) })
            YYGroup {
                row { YYField(t("目录规则"), 52f) { Field(rule, l?.defaultRule ?: t("自动")) { rule = it } } }
                val chapters = l?.chapters ?: emptyList()
                for (c in if (allChapters) chapters else chapters.take(3)) row { YYRow(c.title, value = t("%@ 字", "%,d".format(c.chars.toInt()))) }
                if (!allChapters && chapters.size > 3) row { YYRow(t("全部 %lld 章", chapters.size), chevron = true) { allChapters = true } }
            }
            YYNote(t("每一行从头比对规则，对上的就是一章的标题。自动识别还认得序章、楔子、Chapter 1 这些。"))
            l?.long?.toInt()?.takeIf { it in l.chapters.indices }?.let { i ->
                YYNote(t("第 %lld 章之后有 %@字，可能漏了几章", i + 1, "%,d ".format(l.chapters[i].chars.toInt())), YY.c.warn)
            }
            l?.doubt?.takeIf { l.unreadable == 0u }?.let { YYNote(it, YY.c.warn) }
            failure?.let { YYNote(it, YY.c.danger) }
            Spacer(Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                YYButton(t("取消"), ButtonKind.Plain, ButtonSize.Large, enabled = !working, modifier = Modifier.weight(1f)) { dismiss() }
                YYButton(if (working) t("正在按新的方式整理这本书…") else t("完成"), ButtonKind.Main, ButtonSize.Large, enabled = !working && l?.error == null, modifier = Modifier.weight(1f)) {
                    if (choice == applied) return@YYButton dismiss()
                    working = true
                    scope.launch {
                        try {
                            withContext(Dispatchers.IO) { core.setTxtChoice(bookID, choice) }
                            library.reload()
                            rebuilt()
                        } catch (e: Exception) {
                            failure = Library.message(e)
                        }
                        working = false
                    }
                }
            }
        }
    }
}
