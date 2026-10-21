package app.yuyue.notes

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYSegments
import app.yuyue.design.rememberPref
import app.yuyue.library.Library
import app.yuyue.library.author
import app.yuyue.reader.ReaderModel
import app.yuyue.reader.ThoughtDialog
import app.yuyue.shelf.BookCover
import app.yuyue.shelf.Item
import app.yuyue.shelf.UndoToast
import app.yuyue.t
import uniffi.yuyue_core.BookDetail
import uniffi.yuyue_core.BookSummary
import uniffi.yuyue_core.Mark
import uniffi.yuyue_core.Position
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.TextStyle
import java.util.Locale

/** One book's highlights, as 笔记 lists them. */
data class NotedBook(val book: BookSummary, val detail: BookDetail?, val marks: List<Mark>) {
    val id: String get() = book.id
    val latest: Long get() = marks.maxOfOrNull { it.at } ?: 0

    fun chapter(m: Mark): String? = detail?.let { ReaderModel.chapterTitle(it, m.section.toInt()) }?.takeIf { it != book.title }

    /** The marks in reading order, under their chapters. */
    fun chapters(marks: List<Mark> = this.marks): List<Pair<String, List<Mark>>> {
        val out = mutableListOf<Pair<String, MutableList<Mark>>>()
        for (m in marks.sortedWith(compareBy({ it.section }, { it.start.sentence }, { it.start.offset }))) {
            val title = detail?.let { ReaderModel.chapterTitle(it, m.section.toInt()) } ?: book.title
            if (out.lastOrNull()?.first == title) out.last().second += m else out += title to mutableListOf(m)
        }
        return out
    }

    companion object {
        fun load(library: Library, only: Set<String>? = null): List<NotedBook> =
            library.books.filter { it.available && (only == null || it.id in only) }.mapNotNull { b ->
                val marks = runCatching { library.core.marks(b.id) }.getOrDefault(emptyList())
                if (marks.isEmpty()) null else NotedBook(b, runCatching { library.core.book(b.id) }.getOrNull(), marks)
            }.sortedByDescending { it.latest }

        /** Markdown of the books' notes, chapter by chapter. */
        fun markdown(books: List<NotedBook>, title: String): String = buildString {
            append("# $title\n")
            val one = books.size == 1
            for (n in books) {
                if (!one) append("\n## 《${n.book.title}》\n")
                for ((chapter, marks) in n.chapters()) {
                    append("\n${if (one) "##" else "###"} $chapter\n")
                    for (m in marks) {
                        append("\n> ${m.text}\n")
                        m.note?.let { append("\n$it\n") }
                    }
                }
            }
        }
    }
}

private fun day(ms: Long): LocalDate = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()).toLocalDate()

private fun dayName(d: LocalDate): String = when (d) {
    LocalDate.now() -> t("今天")
    LocalDate.now().minusDays(1) -> t("昨天")
    else -> d.dayOfWeek.getDisplayName(TextStyle.FULL, Locale.getDefault())
}

private fun monthDay(d: LocalDate) = t("%lld 月 %lld 日", d.monthValue, d.dayOfMonth)

private fun time(ms: Long): String = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()).let { "%d:%02d".format(it.hour, it.minute) }

/** 笔记 on the phone, as on iPhone: every book's highlights and thoughts by day, or book by book. */
@Composable
fun NotesScreen(library: Library) {
    var kind by rememberPref("phone.notes.kind", "all")
    var byBook by rememberPref("notes.byBook", false)
    var opened by remember { mutableStateOf<String?>(null) }
    val notes = remember(library.books, library.notesVersion) { NotedBook.load(library) }
    val shown = notes.mapNotNull { n ->
        val marks = if (kind == "thoughts") n.marks.filter { it.note != null } else n.marks
        if (marks.isEmpty()) null else n.copy(marks = marks)
    }
    var writing by remember { mutableStateOf<Pair<NotedBook, Mark>?>(null) }
    val context = LocalContext.current

    fun act(action: String, n: NotedBook, m: Mark) {
        when (action) {
            "open" -> library.open(n.id, Position(m.section, m.start.sentence))
            "write" -> writing = n to m
            "copy" -> (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("", m.text + (m.note?.let { "\n\n$it" } ?: "")))
            "share" -> context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "“${m.text}”" + (m.note?.let { "\n$it" } ?: "") + "\n——《${n.book.title}》"), null))
            "delete" -> library.deleteMarks(listOf(n.id to m))
        }
    }

    opened?.let { id ->
        notes.firstOrNull { it.id == id }?.let { n ->
            androidx.activity.compose.BackHandler { opened = null }
            Box(Modifier.fillMaxSize()) {
                BookNotes(library, n, kind == "thoughts", back = { opened = null }) { a, m -> act(a, n, m) }
                library.toast?.let { UndoToast(it, undo = { library.undo() }, modifier = Modifier.align(Alignment.BottomCenter).padding(16.dp)) }
            }
            writing?.let { (wn, m) -> ThoughtDialog(m.note ?: "") { text -> if (text != null) library.setNote(text.trim().ifEmpty { null }, wn.id, m); writing = null } }
            return
        }
    }

    Box(Modifier.fillMaxSize().background(YY.c.bg)) {
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.statusBars)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(t("笔记"), fontSize = 32.sp, fontWeight = FontWeight.Bold, color = YY.c.t1, modifier = Modifier.weight(1f))
                if (kind != "words" && shown.isNotEmpty()) Box {
                    var exporting by remember { mutableStateOf(false) }
                    Text(t("导出"), fontSize = 15.sp, color = YY.tint.accent, modifier = Modifier.clickable { exporting = true })
                    NoteExportMenu(
                        library, exporting, { exporting = false },
                        { NotedBook.markdown(shown, if (kind == "thoughts") t("语阅 · 想法") else t("语阅笔记")) }, t("语阅笔记.md"), { shown },
                    )
                }
            }
            Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                YYSegments(listOf("all" to t("全部"), "thoughts" to t("想法"), "words" to t("生词")), kind, { kind = it }, modifier = Modifier.weight(1f))
                if (kind != "words") YYSegments(listOf(false to t("按时间"), true to t("按书")), byBook, { byBook = it }, modifier = Modifier.width(140.dp))
            }
            when {
                kind == "words" -> WordsList(library)
                shown.isEmpty() -> Empty(kind == "thoughts")
                byBook -> BookList(shown) { opened = it }
                else -> Timeline(shown, ::act)
            }
        }
        library.toast?.let { UndoToast(it, undo = { library.undo() }, modifier = Modifier.align(Alignment.BottomCenter).padding(16.dp)) }
    }
    writing?.let { (n, m) -> ThoughtDialog(m.note ?: "") { text -> if (text != null) library.setNote(text.trim().ifEmpty { null }, n.id, m); writing = null } }
}

@Composable
private fun Timeline(shown: List<NotedBook>, act: (String, NotedBook, Mark) -> Unit) {
    val items = shown.flatMap { n -> n.marks.map { n to it } }.sortedByDescending { it.second.at }
    val days = items.groupBy { day(it.second.at) }.toList()
    LazyColumn(contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 96.dp)) {
        for ((d, list) in days) {
            item(key = "h$d") {
                Row(Modifier.fillMaxWidth().padding(top = 18.dp, bottom = 8.dp, start = 4.dp, end = 4.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(dayName(d), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
                    Text(monthDay(d), fontSize = 12.sp, color = YY.c.t3)
                    Spacer(Modifier.weight(1f))
                    Text(t("%lld 条", list.size), fontSize = 12.sp, color = YY.c.t3)
                }
            }
            item(key = "c$d") {
                Column(Modifier.fillMaxWidth().background(YY.c.card, RoundedCornerShape(14.dp)).border(0.5.dp, YY.c.line, RoundedCornerShape(14.dp))) {
                    list.forEachIndexed { i, (n, m) ->
                        if (i > 0) Box(Modifier.padding(horizontal = 16.dp).fillMaxWidth().height(0.5.dp).background(YY.c.line))
                        NoteRow(m, { act(it, n, m) }) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                                BookCover(n.book, Modifier.width(13.dp))
                                Text(n.book.title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t2, maxLines = 1)
                                n.chapter(m)?.let { Text("· $it", fontSize = 12.sp, color = YY.c.t3, maxLines = 1, modifier = Modifier.weight(1f, fill = false)) }
                                Spacer(Modifier.weight(1f))
                                if (m.heard) Icon(Icons.headphones, t("听书时划的"), tint = YY.c.t3, modifier = Modifier.size(11.dp))
                                Text(time(m.at), fontSize = 11.5.sp, color = YY.c.t3)
                            }
                        }
                    }
                }
            }
        }
    }
}

/** A highlight in the book's serif, its thought under it in the accent, and where it is from.
 *  A tap goes back to the page; a long press offers the rest. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun NoteRow(mark: Mark, act: (String) -> Unit, footer: @Composable () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Column(
            Modifier.fillMaxWidth().combinedClickable(onClick = { act("open") }, onLongClick = { menu = true }).padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(mark.text, fontFamily = YY.serif, fontSize = 16.sp, lineHeight = 26.sp, color = YY.c.t1)
            mark.note?.let {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Box(Modifier.width(1.5.dp).height(20.dp).background(YY.tint.accent))
                    Text(it, fontSize = 15.sp, color = YY.tint.accent)
                }
            }
            footer()
        }
        DropdownMenu(menu, { menu = false }, containerColor = YY.c.card) {
            Item(t("回到书里这一页"), Icons.book) { menu = false; act("open") }
            Item(if (mark.note == null) t("写想法") else t("改想法"), Icons.edit) { menu = false; act("write") }
            Item(t("复制"), Icons.upload) { menu = false; act("copy") }
            Item(t("分享书摘…"), Icons.share) { menu = false; act("share") }
            Item(t("删除划线"), Icons.delete, danger = true) { menu = false; act("delete") }
        }
    }
}

@Composable
private fun BookList(shown: List<NotedBook>, open: (String) -> Unit) {
    LazyColumn(contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 96.dp)) {
        item {
            Row(Modifier.padding(start = 4.dp, end = 4.dp, top = 12.dp, bottom = 8.dp)) {
                Text(t("%lld 本书 · %lld 条", shown.size, shown.sumOf { it.marks.size }), fontSize = 12.sp, color = YY.c.t3, modifier = Modifier.weight(1f))
                Text(t("最近记的在上面"), fontSize = 12.sp, color = YY.c.t3)
            }
        }
        items(shown, key = { it.id }) { n ->
            Row(
                Modifier.fillMaxWidth().padding(bottom = 8.dp).background(YY.c.card, RoundedCornerShape(14.dp)).clickable { open(n.id) }.padding(12.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                BookCover(n.book, Modifier.width(38.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(n.book.title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1, maxLines = 1)
                    val thoughts = n.marks.count { it.note != null }
                    Text(t("划线 %lld", n.marks.size) + if (thoughts > 0) t(" · 想法 %lld", thoughts) else "", fontSize = 12.sp, color = YY.c.t3)
                }
                Icon(Icons.chevronRight, null, tint = YY.c.t3, modifier = Modifier.size(16.dp))
            }
        }
    }
}

/** One book's notes in book order, under their chapters (prototype 一本书的笔记). */
@Composable
private fun BookNotes(library: Library, n: NotedBook, thoughtsOnly: Boolean, back: () -> Unit, act: (String, Mark) -> Unit) {
    val marks = if (thoughtsOnly) n.marks.filter { it.note != null } else n.marks
    Column(Modifier.fillMaxSize().background(YY.c.bg).windowInsetsPadding(WindowInsets.statusBars)) {
        Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.back, t("返回"), tint = YY.c.t1, modifier = Modifier.size(24.dp).clickable(onClick = back))
            Text(n.book.title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1, maxLines = 1, modifier = Modifier.weight(1f))
            Box {
                var exporting by remember { mutableStateOf(false) }
                Text(t("导出"), fontSize = 15.sp, color = YY.tint.accent, modifier = Modifier.clickable { exporting = true })
                NoteExportMenu(
                    library, exporting, { exporting = false },
                    { NotedBook.markdown(listOf(n), t("《%@》的笔记", n.book.title)) }, t("%@ 笔记.md", n.book.title), { listOf(n) }, n.book,
                )
            }
        }
        LazyColumn(contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 96.dp)) {
            item {
                Row(Modifier.padding(4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    BookCover(n.book, Modifier.width(44.dp))
                    Column {
                        Text(n.book.title, fontSize = 16.sp, fontWeight = FontWeight.Bold, color = YY.c.t1)
                        n.book.author?.let { Text(it, fontSize = 13.sp, color = YY.c.t3) }
                    }
                }
            }
            for ((chapter, list) in n.chapters(marks)) {
                item(key = "h$chapter") { Text(chapter, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t2, modifier = Modifier.padding(top = 16.dp, bottom = 6.dp, start = 4.dp)) }
                item(key = "c$chapter") {
                    Column(Modifier.fillMaxWidth().background(YY.c.card, RoundedCornerShape(14.dp))) {
                        list.forEachIndexed { i, m ->
                            if (i > 0) Box(Modifier.padding(horizontal = 16.dp).fillMaxWidth().height(0.5.dp).background(YY.c.line))
                            NoteRow(m, { act(it, m) }) { Text(time(m.at), fontSize = 11.5.sp, color = YY.c.t3) }
                        }
                    }
                }
            }
        }
    }
}

/** 生词本: the words looked up while reading, each with its sentence. */
@Composable
private fun WordsList(library: Library) {
    val words = remember(library.notesVersion) { runCatching { library.core.words() }.getOrDefault(emptyList()) }
    if (words.isEmpty()) return Empty(false, t("还没有生词"), t("读外文书时点一个词，在释义卡片里点“加入生词本”，就记在这里，带着原句"))
    LazyColumn(contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 96.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        items(words, key = { it.word }) { w ->
            Column(Modifier.fillMaxWidth().background(YY.c.card, RoundedCornerShape(12.dp)).padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(w.word, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
                    w.phonetic?.let { Text(it, fontSize = 12.sp, color = YY.c.t3) }
                    Spacer(Modifier.weight(1f))
                    Text(t("删除"), fontSize = 12.sp, color = YY.c.danger, modifier = Modifier.clickable { library.deleteWord(w.word) })
                }
                w.meaning?.let { Text(it, fontSize = 13.sp, color = YY.c.t2) }
                Text(w.context, fontFamily = YY.serif, fontSize = 13.sp, color = YY.c.t3, maxLines = 2)
            }
        }
    }
}

@Composable
private fun Empty(thoughts: Boolean, title: String? = null, detail: String? = null) {
    Column(Modifier.fillMaxSize().padding(40.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically)) {
        Icon(if (thoughts) Icons.edit else Icons.highlighter, null, tint = YY.c.t3, modifier = Modifier.size(36.dp))
        Text(title ?: if (thoughts) t("还没有想法") else t("还没有笔记"), fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
        Text(detail ?: if (thoughts) t("划线后点“写想法”，想到的就记在这里") else t("读书时选中文字点“划线”；所有书的划线和想法都会在这里"), fontSize = 14.sp, color = YY.c.t2, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}
