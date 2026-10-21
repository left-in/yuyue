package app.yuyue.notes

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYSegments
import app.yuyue.library.Library
import app.yuyue.reader.ReaderModel
import app.yuyue.reader.WordVoice
import app.yuyue.shelf.Item
import app.yuyue.t
import uniffi.yuyue_core.BookDetail
import uniffi.yuyue_core.Position
import uniffi.yuyue_core.VocabWord
import java.io.File
import java.time.format.DateTimeFormatter

/** 生词本 helpers, as on Apple (`Vocab`): picking the word out of its sentence, and 导出 Anki · CSV. */
object Vocab {
    /** A word and its usual English inflections, as the core counts them. */
    fun forms(word: String): Set<String> {
        val w = word.trim().lowercase()
        val out = mutableSetOf(w)
        if (w.length < 3 || !w.all { it in 'a'..'z' }) return out
        out += listOf(w + "s", w + "es", w + "ed", w + "ing", "$w's")
        if (w.endsWith("e")) out += listOf(w + "d", w.dropLast(1) + "ing")
        if (w.endsWith("y")) out += listOf(w.dropLast(1) + "ies", w.dropLast(1) + "ied")
        return out
    }

    private val wordPattern = Regex("""\p{L}(?:\p{L}|['’\-](?=\p{L}))*""")

    fun ranges(word: String, context: String): List<IntRange> {
        val forms = forms(word)
        return wordPattern.findAll(context).filter { it.value.lowercase().replace('’', '\'') in forms }.map { it.range }.toList()
    }

    /** The sentence, shortened around the word when it is long. */
    fun excerpt(context: String, word: String, limit: Int = 160): String {
        val text = context.replace('\n', ' ').trim()
        val r = ranges(word, text).firstOrNull()
        if (text.length <= limit || r == null) return text
        var start = maxOf(0, r.first - limit / 3)
        if (start > 0) text.indexOf(' ', start).takeIf { it >= 0 && it < r.first }?.let { start = it + 1 }
        var end = minOf(text.length, start + limit)
        if (end < text.length) text.lastIndexOf(' ', end).takeIf { it > r.last }?.let { end = it }
        return (if (start > 0) "…" else "") + text.substring(start, end) + (if (end < text.length) "…" else "")
    }

    /** "n. 运气；命运" → ("n.", "运气；命运"). */
    fun split(meaning: String?): Pair<String?, String>? {
        val m = meaning?.trim()?.ifEmpty { null } ?: return null
        val space = m.indexOf(' ')
        if (space > 0 && m.substring(0, space).endsWith(".") && m.substring(0, space).all { it.code < 128 }) return m.substring(0, space) to m.substring(space + 1).trim()
        return null to m
    }

    /** Anki's plain-text import: one note a line, front and back split by a tab, HTML allowed. */
    fun anki(words: List<VocabWord>, title: (VocabWord) -> String): String {
        fun html(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\t", " ").replace("\n", " ")
        val out = StringBuilder("#separator:tab\n#html:true\n#tags column:3\n")
        for (w in words) {
            var front = "<b>${html(w.word)}</b>"
            w.phonetic?.let { front += " <span style=\"color:#888\">${html(it)}</span>" }
            var context = html(excerpt(w.context, w.word, 240))
            for (r in ranges(w.word, context).reversed()) context = context.replaceRange(r, "<u>${context.substring(r)}</u>")
            var back = html(w.meaning ?: "")
            if (context.isNotEmpty()) back += "<br><br><i>$context</i>"
            back += "<br><small>${html(title(w))}</small>"
            out.append("$front\t$back\t").append(t("语阅")).append("\n")
        }
        return out.toString()
    }

    /** A table for a spreadsheet; the BOM tells Excel it is UTF-8. */
    fun csv(words: List<VocabWord>, title: (VocabWord) -> String): String {
        fun cell(s: String) = if (s.any { it in ",\"\n\r" }) "\"" + s.replace("\"", "\"\"") + "\"" else s
        val out = StringBuilder(t("﻿单词,音标,释义,原句,出处,加入时间,掌握了\r\n"))
        val day = DateTimeFormatter.ofPattern("yyyy-MM-dd")
        for (w in words) {
            out.append(listOf(w.word, w.phonetic ?: "", w.meaning ?: "", w.context, title(w), Notes.date(w.at).format(day), if (w.known) t("是") else "")
                .joinToString(",", transform = ::cell)).append("\r\n")
        }
        return out.toString()
    }

    fun share(context: Context, text: String, name: String) {
        val dir = File(context.cacheDir, "export").apply { mkdirs() }
        val file = File(dir, name)
        file.writeText(text)
        NoteExport.share(context, file, if (name.endsWith(".csv")) "text/csv" else "text/plain")
    }
}

/** The 生词本, as on iPhone: the words kept while reading in another language, by the day they
 *  were kept, with the sound, the meaning and the sentence they came from. 在学 / 掌握了 apart;
 *  a tap goes back to the sentence; a long press offers the rest. */
@Composable
fun WordsList(library: Library, exporting: Boolean, doneExporting: () -> Unit) {
    val context = LocalContext.current
    val words = remember(library.notesVersion) { runCatching { library.core.words() }.getOrDefault(emptyList()) }
    val details = remember(words) {
        words.map { it.book }.distinct().associateWith { runCatching { library.core.book(it) }.getOrNull() }
    }
    var showKnown by remember { mutableStateOf(false) }
    val learning = words.filter { !it.known }
    val known = words.filter { it.known }
    val shown = if (showKnown) known else learning

    fun title(book: String) = library.books.firstOrNull { it.id == book }?.title ?: details[book]?.summary?.title ?: t("已删除的书")
    fun source(w: VocabWord): String {
        val title = title(w.book)
        val chapter = details[w.book]?.let { ReaderModel.chapterTitle(it, w.section.toInt()) }
        return if (chapter == null || chapter == title) title else "$title · $chapter"
    }

    Box {
        DropdownMenu(exporting, doneExporting, containerColor = YY.c.card) {
            Item(t("Anki 卡片"), Icons.books) { doneExporting(); Vocab.share(context, Vocab.anki(shown, ::source), t("语阅生词 Anki.txt")) }
            Item(t("CSV 表格"), Icons.grid) { doneExporting(); Vocab.share(context, Vocab.csv(shown, ::source), t("语阅生词.csv")) }
        }
    }
    if (words.isEmpty()) return EmptyNotes(Icons.translate, t("还没有生词"), t("读外文书时点一个词，在释义卡片里点“加入生词本”，就记在这里，带着原句"))
    val days = shown.sortedByDescending { it.at }.groupBy { Notes.date(it.at) }.toList()
    LazyColumn(contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 96.dp)) {
        item {
            YYSegments(listOf(false to t("在学 %lld", learning.size), true to t("掌握了 %lld", known.size)), showKnown, { showKnown = it }, modifier = Modifier.fillMaxWidth().padding(top = 4.dp))
        }
        if (shown.isEmpty()) item {
            Text(
                if (showKnown) t("还没有掌握的词。在学的词右滑“掌握了”，就挪到这里") else t("都掌握了。新查的词加进生词本，会出现在这里"),
                fontSize = 13.sp, color = YY.c.t3, textAlign = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(top = 24.dp),
            )
        }
        for ((day, list) in days) {
            item(key = "h$day") {
                Row(Modifier.fillMaxWidth().padding(top = 18.dp, bottom = 8.dp, start = 4.dp, end = 4.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(dayNameOf(day), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
                    Text(Notes.monthDay(day), fontSize = 12.sp, color = YY.c.t3)
                    Spacer(Modifier.weight(1f))
                    Text(t("%lld 个", list.size), fontSize = 12.sp, color = YY.c.t3)
                }
            }
            item(key = "c$day") {
                Column(Modifier.fillMaxWidth().background(YY.c.card, RoundedCornerShape(14.dp))) {
                    list.forEachIndexed { i, w ->
                        if (i > 0) Box(Modifier.padding(horizontal = 16.dp).fillMaxWidth().height(0.5.dp).background(YY.c.line))
                        WordRow(w, source(w), details[w.book], library)
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WordRow(w: VocabWord, source: String, detail: BookDetail?, library: Library) {
    val context = LocalContext.current
    var menu by remember { mutableStateOf(false) }
    val available = library.books.any { it.id == w.book && it.available }
    fun open() { if (available) library.open(w.book, Position(w.section, w.sentence)) }
    fun say() = WordVoice.say(context, w.word, detail?.summary?.language ?: "en")
    fun setKnown(on: Boolean) { runCatching { library.core.setWordKnown(w.word, on) }; library.notesChanged() }
    val serif = FontFamily.Serif
    // Right for 掌握了 (or 再学一遍), left to delete; the row springs back either way.
    val swipe = rememberSwipeToDismissBoxState(confirmValueChange = { v ->
        when (v) {
            SwipeToDismissBoxValue.StartToEnd -> setKnown(!w.known)
            SwipeToDismissBoxValue.EndToStart -> library.deleteWord(w.word)
            else -> {}
        }
        false
    })
    SwipeToDismissBox(swipe, backgroundContent = {
        val right = swipe.dismissDirection == SwipeToDismissBoxValue.StartToEnd
        Row(
            Modifier.fillMaxSize().background(if (right) (if (w.known) YY.c.warn else YY.c.ok) else YY.c.danger).padding(horizontal = 20.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = if (right) Arrangement.Start else Arrangement.End,
        ) {
            Text(if (!right) t("删除") else if (w.known) t("再学一遍") else t("掌握了"), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = androidx.compose.ui.graphics.Color.White)
        }
    }) { Box(Modifier.background(YY.c.card)) {
        Column(Modifier.fillMaxWidth().combinedClickable(onClick = ::open, onLongClick = { menu = true }).padding(horizontal = 16.dp, vertical = 14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                Text(w.word, fontFamily = serif, fontWeight = FontWeight.Bold, fontSize = 20.sp, color = YY.c.t1)
                w.phonetic?.let { Text(it, fontSize = 13.sp, color = YY.c.t2) }
                Spacer(Modifier.weight(1f))
                Box(Modifier.size(32.dp).background(YY.c.inset, CircleShape).clickable(onClick = ::say), contentAlignment = Alignment.Center) {
                    Icon(Icons.waveform, t("读一遍"), tint = YY.c.t1, modifier = Modifier.size(15.dp))
                }
            }
            Vocab.split(w.meaning)?.let { (pos, text) ->
                Text(buildAnnotatedString {
                    pos?.let { withStyle(SpanStyle(fontFamily = serif, fontStyle = FontStyle.Italic, color = YY.c.t3)) { append("$it ") } }
                    append(text)
                }, fontSize = 14.sp, color = YY.c.t1, modifier = Modifier.padding(top = 4.dp))
            }
            if (w.context.isNotEmpty()) {
                val text = Vocab.excerpt(w.context, w.word, 200)
                Text(buildAnnotatedString {
                    append(text)
                    for (r in Vocab.ranges(w.word, text)) addStyle(SpanStyle(color = YY.c.t1, textDecoration = TextDecoration.Underline), r.first, r.last + 1)
                }, fontFamily = serif, fontSize = 14.5.sp, lineHeight = 22.sp, color = YY.c.t2, modifier = Modifier.padding(top = 9.dp))
            }
            Text(source, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t3, maxLines = 1, modifier = Modifier.padding(top = 10.dp))
        }
        DropdownMenu(menu, { menu = false }, containerColor = YY.c.card) {
            if (available) Item(t("回到书里这一句"), Icons.book) { menu = false; open() }
            Item(t("读一遍"), Icons.waveform) { menu = false; say() }
            Item(if (w.known) t("再学一遍") else t("掌握了"), if (w.known) Icons.undo else Icons.check) { menu = false; setKnown(!w.known) }
            Item(t("复制"), Icons.upload) {
                menu = false
                (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("", listOfNotNull(w.word, w.phonetic, w.meaning).joinToString(" ")))
            }
            HorizontalDivider(color = YY.c.line)
            Item(t("删除"), Icons.delete, danger = true) { menu = false; library.deleteWord(w.word) }
        }
    } }
}

