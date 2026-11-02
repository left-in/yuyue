package app.yuyue.notes

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.ui.graphics.Color
import app.yuyue.design.ButtonKind
import app.yuyue.design.YYButton
import app.yuyue.library.percent
import uniffi.yuyue_core.MarkStyle
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
import androidx.compose.material3.DropdownMenuItem
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

    fun quote(m: Mark) = QuoteShare(m.text, m.note, book.title, book.author, chapter(m), book.coverPath)

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


private fun dayName(d: LocalDate): String = when (d) {
    LocalDate.now() -> t("今天")
    LocalDate.now().minusDays(1) -> t("昨天")
    else -> d.dayOfWeek.getDisplayName(TextStyle.FULL, Locale.getDefault())
}

internal fun dayNameOf(d: LocalDate) = dayName(d)

private fun time(ms: Long): String = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()).let { "%d:%02d".format(it.hour, it.minute) }

/** Which highlights show in a book's notes: all, or one style. */
private typealias Only = MarkStyle?

/**
 * 笔记 on the phone, as on iPhone (prototype 笔记 · 按时间 / 按书 / 一本书的笔记 / 多选): every
 * book's highlights and thoughts by day, with 今天回顾 on top, or book by book; and the 生词本.
 * A tap goes back to the page; a long press offers the rest; 选择 takes several at once.
 */
@Composable
fun NotesScreen(library: Library) {
    var kind by rememberPref("phone.notes.kind", "all")
    var byBook by rememberPref("notes.byBook", false)
    var opened by remember { mutableStateOf<String?>(null) }
    val notes = remember(library.books, library.notesVersion) { NotedBook.load(library) }
    val deck = remember(library.books, library.notesVersion) { Review(library.core) }
    val shown = notes.mapNotNull { n ->
        val marks = if (kind == "thoughts") n.marks.filter { it.note != null } else n.marks
        if (marks.isEmpty()) null else n.copy(marks = marks)
    }
    var writing by remember { mutableStateOf<Pair<NotedBook, Mark>?>(null) }
    var sharing by remember { mutableStateOf<QuoteShare?>(null) }
    var reviewing by remember { mutableStateOf<Review?>(null) }
    var selecting by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf(setOf<String>()) }
    var exporting by remember { mutableStateOf(false) }
    val context = LocalContext.current

    fun stopSelecting() { selecting = false; selected = emptySet() }

    fun act(action: String, n: NotedBook, m: Mark) {
        when (action) {
            "open" -> library.open(n.id, Position(m.section, m.start.sentence))
            "write" -> writing = n to m
            "copy" -> (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("", m.text + (m.note?.let { "\n\n$it" } ?: "")))
            "share" -> sharing = n.quote(m)
            "delete" -> library.deleteMarks(listOf(n.id to m))
        }
    }

    fun review(r: Review) { reviewing = r }

    Box(Modifier.fillMaxSize().background(YY.c.bg)) {
        val open = opened?.let { id -> notes.firstOrNull { it.id == id } }
        if (open != null) {
            androidx.activity.compose.BackHandler { opened = null }
            BookNotes(library, open, kind == "thoughts", back = { opened = null }, review = { review(Review(library.core, open.book)) }) { a, m -> act(a, open, m) }
        } else Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.statusBars)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                Text(t("笔记"), fontSize = 32.sp, fontWeight = FontWeight.Bold, color = YY.c.t1, modifier = Modifier.weight(1f))
                when {
                    selecting -> Action(t("完成"), bold = true) { stopSelecting() }
                    kind == "words" -> Action(t("导出")) { exporting = true }
                    shown.isNotEmpty() -> {
                        if (!byBook) Action(t("选择")) { selecting = true }
                        Box {
                            var menu by remember { mutableStateOf(false) }
                            Action(t("导出")) { menu = true }
                            NoteExportMenu(
                                library, menu, { menu = false },
                                { NotedBook.markdown(shown, if (kind == "thoughts") t("语阅 · 想法") else t("语阅笔记")) }, t("语阅笔记.md"), { shown },
                            )
                        }
                    }
                }
            }
            if (!selecting) Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                YYSegments(listOf("all" to t("全部"), "thoughts" to t("想法"), "words" to t("生词")), kind, { kind = it; stopSelecting() }, modifier = Modifier.weight(1f))
                // How they're ordered is a quieter choice than what's shown: the shelf's 最近读过 ⇅ menu.
                if (kind != "words") Box {
                    var sorting by remember { mutableStateOf(false) }
                    Row(Modifier.clickable { sorting = true }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(if (byBook) t("按书") else t("按时间"), fontSize = 13.sp, color = YY.c.t2)
                        Icon(Icons.sort, null, tint = YY.c.t2, modifier = Modifier.size(14.dp))
                    }
                    DropdownMenu(sorting, { sorting = false }, containerColor = YY.c.card) {
                        for ((value, title) in listOf(false to t("按时间"), true to t("按书"))) {
                            DropdownMenuItem(
                                text = { Text(title, color = YY.c.t1) },
                                trailingIcon = { if (value == byBook) Icon(Icons.check, null, tint = YY.tint.accent) },
                                onClick = { byBook = value; stopSelecting(); sorting = false },
                            )
                        }
                    }
                }
            }
            Box(Modifier.weight(1f)) {
                when {
                    kind == "words" -> WordsList(library, exporting) { exporting = false }
                    shown.isEmpty() -> if (kind == "thoughts") EmptyNotes(Icons.edit, t("还没有想法"), t("划线后点“写想法”，想到的就记在这里"))
                    else EmptyNotes(Icons.highlighter, t("还没有笔记"), t("读书时选中文字点“划线”；所有书的划线和想法都会在这里"))
                    byBook -> BookList(shown) { opened = it }
                    else -> Timeline(
                        shown, deck.takeIf { kind == "all" && !selecting && (deck.items.isNotEmpty() || deck.doneToday > 0) }, library, { review(deck) },
                        if (selecting) selected else null, { id -> selected = if (id in selected) selected - id else selected + id }, ::act,
                    )
                }
            }
            if (selecting) SelectionBar(shown, selected, library) { stopSelecting() }
        }
    }
    writing?.let { (n, m) -> ThoughtDialog(m.note ?: "") { text -> if (text != null) library.setNote(text.trim().ifEmpty { null }, n.id, m); writing = null } }
    sharing?.let { QuoteShareSheet(it) { sharing = null } }
    reviewing?.let { r ->
        ReviewSheet(r, library, open = { item -> reviewing = null; library.open(item.book, Position(item.mark.section, item.mark.start.sentence)) }, only = { b -> reviewing = Review(library.core, b) }) {
            reviewing = null
            library.notesChanged()
        }
    }
}

@Composable
private fun Action(title: String, bold: Boolean = false, onClick: () -> Unit) {
    Text(title, fontSize = 15.sp, fontWeight = if (bold) FontWeight.SemiBold else FontWeight.Normal, color = YY.tint.accent, modifier = Modifier.clickable(onClick = onClick))
}

private fun key(n: NotedBook, m: Mark) = n.id + "/" + m.id

@Composable
private fun Timeline(
    shown: List<NotedBook>, deck: Review?, library: Library, startReview: () -> Unit,
    selected: Set<String>?, toggle: (String) -> Unit, act: (String, NotedBook, Mark) -> Unit,
) {
    val items = shown.flatMap { n -> n.marks.map { n to it } }.sortedByDescending { it.second.at }
    val days = items.groupBy { Notes.date(it.second.at) }.toList()
    LazyColumn(contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = app.yuyue.LocalTabBarHeight.current + 16.dp)) {
        if (deck != null) item(key = "deck") { Box(Modifier.padding(top = 8.dp)) { DeckCard(deck, library, startReview) } }
        for ((d, list) in days) {
            item(key = "h$d") {
                Row(Modifier.fillMaxWidth().padding(top = 18.dp, bottom = 8.dp, start = 4.dp, end = 4.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(dayName(d), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
                    Text(Notes.monthDay(d), fontSize = 12.sp, color = YY.c.t3)
                    Spacer(Modifier.weight(1f))
                    Text(t("%lld 条", list.size), fontSize = 12.sp, color = YY.c.t3)
                }
            }
            item(key = "c$d") {
                Column(Modifier.fillMaxWidth().background(YY.c.card, RoundedCornerShape(14.dp)).border(0.5.dp, YY.c.line, RoundedCornerShape(14.dp))) {
                    list.forEachIndexed { i, (n, m) ->
                        if (i > 0) Box(Modifier.padding(horizontal = 16.dp).fillMaxWidth().height(0.5.dp).background(YY.c.line))
                        NoteRow(m, selected?.contains(key(n, m)), { if (selected != null) toggle(key(n, m)) else act(it, n, m) }) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                                BookCover(n.book, Modifier.width(13.dp))
                                Text(n.book.title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t2, maxLines = 1)
                                n.chapter(m)?.let { Text("· $it", fontSize = 12.sp, color = YY.c.t3, maxLines = 1, modifier = Modifier.weight(1f, fill = false)) }
                                Spacer(Modifier.weight(1f))
                                NoteStamp(m, time(m.at))
                            }
                        }
                    }
                }
            }
        }
    }
}

/** 选了 3 条 · 分享 · 导出 · 删除, where the tabs were. */
@Composable
private fun SelectionBar(shown: List<NotedBook>, selected: Set<String>, library: Library, done: () -> Unit) {
    val context = LocalContext.current
    val picked = shown.flatMap { n -> n.marks.filter { key(n, it) in selected }.map { n to it } }
    Column(Modifier.fillMaxWidth().background(YY.c.card).padding(bottom = 4.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.fillMaxWidth().height(0.5.dp).background(YY.c.line))
        Text(if (picked.isEmpty()) t("点笔记来选") else t("选了 %lld 条", picked.size), fontSize = 12.sp, color = YY.c.t2, modifier = Modifier.padding(top = 8.dp))
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
            BarButton(t("分享"), Icons.share, picked.isNotEmpty()) {
                val text = picked.joinToString("\n\n") { (n, m) -> Notes.plain(m, n.book.title) }
                context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), null))
            }
            BarButton(t("导出"), Icons.upload, picked.isNotEmpty()) {
                val books = picked.groupBy({ it.first.id }) { it.second }.map { (id, ms) -> shown.first { it.id == id }.copy(marks = ms) }
                NoteExport.shareMarkdown(context, NotedBook.markdown(books, t("语阅笔记")), t("语阅笔记.md"))
            }
            BarButton(t("删除"), Icons.delete, picked.isNotEmpty(), danger = true) {
                library.deleteMarks(picked.map { (n, m) -> n.id to m })
                done()
            }
        }
    }
}

@Composable
private fun RowScope.BarButton(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, enabled: Boolean, danger: Boolean = false, onClick: () -> Unit) {
    val color = when { !enabled -> YY.c.t3; danger -> YY.c.danger; else -> YY.c.t1 }
    Column(Modifier.weight(1f).height(54.dp).clickable(enabled = enabled, onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterVertically)) {
        Icon(icon, null, tint = color, modifier = Modifier.size(20.dp))
        Text(title, fontSize = 11.sp, color = color)
    }
}

/** A highlight as the book set it, its thought under it in the accent, and where it is from.
 *  A tap goes back to the page; a long press offers the rest. While choosing, a tap picks it. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun NoteRow(mark: Mark, selected: Boolean?, act: (String) -> Unit, footer: @Composable () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.fillMaxWidth().combinedClickable(onClick = { act("open") }, onLongClick = { if (selected == null) menu = true else act("open") }).padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (selected != null) {
                Icon(if (selected) Icons.checkCircle else Icons.circle, if (selected) t("已选") else t("未选"), tint = if (selected) YY.tint.accent else YY.c.t3, modifier = Modifier.padding(top = 3.dp).size(22.dp))
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                MarkText(mark, androidx.compose.ui.text.TextStyle(fontFamily = YY.serif, fontSize = 16.sp, lineHeight = 26.sp), YY.c.t1)
                mark.note?.let {
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.height(androidx.compose.foundation.layout.IntrinsicSize.Min)) {
                        Box(Modifier.width(1.5.dp).fillMaxHeight().background(YY.tint.accent))
                        Text(it, fontSize = 15.sp, color = YY.tint.accent)
                    }
                }
                footer()
            }
        }
        DropdownMenu(menu, { menu = false }, containerColor = YY.c.card) {
            Item(t("回到书里这一页"), Icons.book) { menu = false; act("open") }
            Item(if (mark.note == null) t("写想法") else t("改想法"), Icons.edit) { menu = false; act("write") }
            Item(t("复制"), Icons.upload) { menu = false; act("copy") }
            Item(t("分享书摘…"), Icons.share) { menu = false; act("share") }
            HorizontalDivider(color = YY.c.line)
            Item(t("删除划线"), Icons.delete, danger = true) { menu = false; act("delete") }
        }
    }
}

@Composable
private fun BookList(shown: List<NotedBook>, open: (String) -> Unit) {
    LazyColumn(contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = app.yuyue.LocalTabBarHeight.current + 16.dp)) {
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
                    Text(Notes.counts(n.marks), fontSize = 12.sp, color = YY.c.t3)
                }
                Text(Notes.shortDay(Notes.date(n.latest)), fontSize = 12.sp, color = YY.c.t3)
                Icon(Icons.chevronRight, null, tint = YY.c.t3, modifier = Modifier.size(14.dp))
            }
        }
    }
}

/** One book's notes in book order, under their chapters (prototype 一本书的笔记). The dots keep one
 *  style; 导出 takes this book; 回顾这本书 goes through its highlights. */
@Composable
private fun BookNotes(library: Library, n: NotedBook, thoughtsOnly: Boolean, back: () -> Unit, review: () -> Unit, act: (String, Mark) -> Unit) {
    val all = if (thoughtsOnly) n.marks.filter { it.note != null } else n.marks
    var only by remember { mutableStateOf<Only>(null) }
    val marks = all.filter { only == null || it.style == only }
    var more by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().background(YY.c.bg).windowInsetsPadding(WindowInsets.statusBars)) {
        Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.back, t("返回"), tint = YY.c.t1, modifier = Modifier.size(24.dp).clickable(onClick = back))
            Text(n.book.title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1, maxLines = 1, textAlign = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.weight(1f))
            Box {
                Icon(Icons.more, t("更多"), tint = YY.c.t1, modifier = Modifier.size(24.dp).clickable { more = true })
                DropdownMenu(more, { more = false }, containerColor = YY.c.card) {
                    Item(t("打开书"), Icons.book) { more = false; library.open(n.book) }
                    Item(t("回顾这本书"), Icons.sync) { more = false; review() }
                }
            }
        }
        LazyColumn(contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = app.yuyue.LocalTabBarHeight.current + 16.dp)) {
            item {
                Row(Modifier.padding(4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    BookCover(n.book, Modifier.width(52.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(n.book.title, fontSize = 19.sp, fontWeight = FontWeight.Bold, color = YY.c.t1, maxLines = 2)
                        Text(listOfNotNull(n.book.author, t("读到 %@", n.book.percent)).joinToString(" · "), fontSize = 12.sp, color = YY.c.t2)
                        Text(Notes.counts(n.marks) + t(" · 按书里的顺序"), fontSize = 12.sp, color = YY.c.t2)
                    }
                }
            }
            item {
                Row(Modifier.padding(vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(YY.s(8))) {
                    YYButton(t("回顾这本书"), ButtonKind.Raised, icon = Icons.sync, modifier = Modifier.weight(1f), onClick = review)
                    Box(Modifier.weight(1f)) {
                        var exporting by remember { mutableStateOf(false) }
                        YYButton(t("导出"), ButtonKind.Raised, icon = Icons.upload, wide = true) { exporting = true }
                        NoteExportMenu(
                            library, exporting, { exporting = false },
                            { NotedBook.markdown(listOf(n), t("《%@》的笔记", n.book.title)) }, t("%@ 笔记.md", n.book.title), { listOf(n) }, n.book,
                        )
                    }
                }
            }
            item {
                Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 4.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Chip(t("全部 %lld", all.size), only == null, null) { only = null }
                    for (style in markStyles) {
                        val count = all.count { it.style == style }
                        if (count > 0) Chip("$count", only == style, style) { only = if (only == style) null else style }
                    }
                }
            }
            for ((chapter, list) in n.chapters(marks)) {
                item(key = "h$chapter") {
                    Row(Modifier.padding(top = 16.dp, bottom = 6.dp, start = 4.dp, end = 4.dp)) {
                        Text(chapter, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1, maxLines = 1, modifier = Modifier.weight(1f))
                        Text(t("%lld 条", list.size), fontSize = 12.sp, color = YY.c.t3)
                    }
                }
                item(key = "c$chapter") {
                    Column(Modifier.fillMaxWidth().background(YY.c.card, RoundedCornerShape(14.dp))) {
                        list.forEachIndexed { i, m ->
                            if (i > 0) Box(Modifier.padding(horizontal = 16.dp).fillMaxWidth().height(0.5.dp).background(YY.c.line))
                            NoteRow(m, null, { act(it, m) }) {
                                Row { Spacer(Modifier.weight(1f)); NoteStamp(m, Notes.monthDay(Notes.date(m.at))) }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Chip(text: String, on: Boolean, style: MarkStyle?, onClick: () -> Unit) {
    Row(
        Modifier.height(30.dp).background(if (on) YY.tint.black else YY.c.card, CircleShape).border(if (on) 0.dp else 0.5.dp, if (on) Color.Transparent else YY.c.line, CircleShape)
            .clickable(onClick = onClick).padding(horizontal = 13.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        when {
            style == null -> {}
            style.fills -> Box(Modifier.size(9.dp).background(style.dot, CircleShape))
            else -> Text(if (style == MarkStyle.WAVE) "~" else "_", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = style.dot)
        }
        Text(text, fontSize = 13.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal, color = if (on) YY.tint.onBlack else YY.c.t2)
    }
}

/** Nothing to list yet: what goes here and how it gets here. */
@Composable
internal fun EmptyNotes(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, detail: String) {
    Column(Modifier.fillMaxSize().padding(40.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically)) {
        Icon(icon, null, tint = YY.c.t3, modifier = Modifier.size(36.dp))
        Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
        Text(detail, fontSize = 14.sp, color = YY.c.t2, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}
