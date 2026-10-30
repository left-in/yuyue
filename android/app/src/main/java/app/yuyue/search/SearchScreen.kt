package app.yuyue.search

import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYGroup
import app.yuyue.design.YYLabel
import app.yuyue.library.Library
import app.yuyue.reader.ReaderModel
import app.yuyue.shelf.BookCover
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import uniffi.yuyue_core.BookFormat
import uniffi.yuyue_core.BookSummary
import uniffi.yuyue_core.Mark
import uniffi.yuyue_core.Position
import uniffi.yuyue_core.SearchHit
import uniffi.yuyue_core.TocItem
import uniffi.yuyue_core.VocabWord

private class TitleHit(val book: BookSummary, val chapter: TocItem?)
private class LineHit(val book: BookSummary, val hit: SearchHit, val chapter: String?)
private class NoteHit(val book: BookSummary, val mark: Mark, val chapter: String?)

private enum class Scope { All, Books, Lines, Notes, Words }

/** 搜索 · 问 on the phone (prototype 搜索结果), as on iPhone: book names, every book's own
 *  sentences, highlights and thoughts, and 生词, looked for at once; chips keep one kind. The
 *  first row always hands the words to 书伴. A tap goes to the page. */
@Composable
fun SearchScreen(library: Library) {
    var query by rememberSaveable { mutableStateOf("") }
    var scope by remember { mutableStateOf(Scope.All) }
    val q = query.trim()
    val books = remember(library.books) { library.books.filter { it.available } }
    val details = remember(books) { books.associate { it.id to runCatching { library.core.book(it.id) }.getOrNull() } }
    val marks = remember(books, library.notesVersion) { books.associate { it.id to runCatching { library.core.marks(it.id) }.getOrDefault(emptyList()) } }
    val vocab = remember(library.notesVersion) { runCatching { library.core.words() }.getOrDefault(emptyList()) }
    fun chapter(id: String, section: UInt) = details[id]?.let { ReaderModel.chapterTitle(it, section.toInt()) }

    val titles = if (q.isEmpty()) {
        books.filter { it.openedAt != null }.sortedByDescending { it.openedAt }.take(5).map { TitleHit(it, null) }
    } else {
        val lower = q.lowercase()
        books.filter { b -> b.title.lowercase().contains(lower) || b.authors.any { it.lowercase().contains(lower) } }.map { TitleHit(it, null) } +
            books.flatMap { b -> (details[b.id]?.toc ?: emptyList()).filter { it.title.contains(q, true) && it.title != b.title }.map { TitleHit(b, it) } }
    }.take(40)
    val notes = if (q.isEmpty()) emptyList() else books.flatMap { b ->
        (marks[b.id] ?: emptyList()).filter { it.text.contains(q, true) || it.note?.contains(q, true) == true }.map { NoteHit(b, it, chapter(b.id, it.section)) }
    }.sortedByDescending { it.mark.at }
    val words = if (q.isEmpty()) emptyList() else vocab.filter { it.word.contains(q, true) || it.meaning?.contains(q, true) == true }

    // 全文 can take a moment over a big library: wait for the typing to stop.
    var lines by remember { mutableStateOf<List<LineHit>>(emptyList()) }
    var lineCount by remember { mutableIntStateOf(0) }
    var lineBooks by remember { mutableIntStateOf(0) }
    LaunchedEffect(q) {
        if (q.isEmpty()) { lines = emptyList(); lineCount = 0; lineBooks = 0; scope = Scope.All; return@LaunchedEffect }
        delay(140)
        val found = withContext(Dispatchers.IO) { books.map { it to runCatching { library.core.searchBook(it.id, q) }.getOrDefault(emptyList()) } }
        lineCount = found.sumOf { it.second.size }
        lineBooks = found.count { it.second.isNotEmpty() }
        // The first sentence from each book, then the second…
        val picked = mutableListOf<LineHit>()
        var round = 0
        while (picked.size < 60 && found.any { it.second.size > round }) {
            for ((b, hits) in found) if (hits.size > round && picked.size < 60) picked += LineHit(b, hits[round], chapter(b.id, hits[round].section))
            round++
        }
        lines = picked
    }

    Column(Modifier.fillMaxSize().background(YY.c.bg).windowInsetsPadding(WindowInsets.statusBars)) {
        Text(t("搜索"), fontSize = 32.sp, fontWeight = FontWeight.Bold, color = YY.c.t1, modifier = Modifier.padding(start = 20.dp, top = 12.dp))
        Row(
            Modifier.padding(horizontal = 16.dp, vertical = 8.dp).fillMaxWidth().height(40.dp).background(YY.c.inset, RoundedCornerShape(12.dp)).padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(Icons.search, null, tint = YY.c.t3, modifier = Modifier.size(18.dp))
            BasicTextField(
                query, { query = it }, singleLine = true, modifier = Modifier.weight(1f).semantics { contentDescription = t("搜索") },
                textStyle = androidx.compose.ui.text.TextStyle(fontSize = 16.sp, color = YY.c.t1), cursorBrush = SolidColor(YY.tint.accent),
                decorationBox = { inner -> if (query.isEmpty()) Text(t("书名、原文、笔记、生词"), fontSize = 16.sp, color = YY.c.t3); inner() },
            )
            if (query.isNotEmpty()) Icon(Icons.close, t("清空"), tint = YY.c.t3, modifier = Modifier.size(18.dp).clickable { query = "" })
        }
        if (q.isNotEmpty()) {
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Chip(t("全部"), null, scope == Scope.All) { scope = Scope.All }
                Chip(t("书"), titles.size, scope == Scope.Books) { scope = Scope.Books }
                Chip(t("全文"), lineCount, scope == Scope.Lines) { scope = Scope.Lines }
                Chip(t("笔记"), notes.size, scope == Scope.Notes) { scope = Scope.Notes }
                Chip(t("生词"), words.size, scope == Scope.Words) { scope = Scope.Words }
            }
        }
        LazyColumn(Modifier.weight(1f).padding(horizontal = 16.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = app.yuyue.LocalTabBarHeight.current + 16.dp)) {
            if (q.isEmpty()) {
                if (titles.isNotEmpty()) {
                    item { YYLabel(t("最近读过")) }
                    item { YYGroup { for (h in titles) row { TitleRow(h) { open(library, h) } } } }
                }
            } else {
                val ask = if (scope == Scope.All) askBook(library, titles) else null
                if (ask != null) item { AskCard(q, ask) { library.ask(q, ask.id) } }
                if ((scope == Scope.All || scope == Scope.Books) && titles.isNotEmpty()) {
                    item { YYLabel(t("书"), "${titles.size}") }
                    item { YYGroup { for (h in titles) row { TitleRow(h) { open(library, h) } } } }
                }
                if ((scope == Scope.All || scope == Scope.Lines) && lines.isNotEmpty()) {
                    item { YYLabel(t("全文"), t("%lld 处 · %lld 本书", lineCount, lineBooks)) }
                    item {
                        YYGroup {
                            for (l in if (scope == Scope.All) lines.take(4) else lines) row {
                                HitRow(l.hit.before, l.hit.matched, l.hit.after, listOfNotNull(l.book.title, l.chapter).joinToString(" · ")) {
                                    library.open(l.book.id, Position(l.hit.section, l.hit.sentence))
                                }
                            }
                        }
                    }
                }
                if ((scope == Scope.All || scope == Scope.Notes) && notes.isNotEmpty()) {
                    item { YYLabel(t("笔记"), t("%lld 条", notes.size)) }
                    item {
                        YYGroup {
                            for (n in if (scope == Scope.All) notes.take(3) else notes) row {
                                HitRow("", n.mark.text, n.mark.note?.let { "\n$it" } ?: "", listOfNotNull(n.book.title, n.chapter).joinToString(" · ")) {
                                    library.open(n.book.id, Position(n.mark.section, n.mark.start.sentence))
                                }
                            }
                        }
                    }
                }
                if ((scope == Scope.All || scope == Scope.Words) && words.isNotEmpty()) {
                    item { YYLabel(t("生词"), t("%lld 个", words.size)) }
                    item { YYGroup { for (w in if (scope == Scope.All) words.take(3) else words) row { WordRow(w) } } }
                }
                val nothing = when (scope) {
                    Scope.All -> if (titles.isEmpty() && lines.isEmpty() && notes.isEmpty() && words.isEmpty()) t("书名、原文、笔记里都没有“%@”。可以问问书伴", q) else null
                    Scope.Books -> if (titles.isEmpty()) t("没有书名里带“%@”的书", q) else null
                    Scope.Lines -> if (lines.isEmpty()) t("书里的原文没有“%@”", q) else null
                    Scope.Notes -> if (notes.isEmpty()) t("划线和想法里没有“%@”", q) else null
                    Scope.Words -> if (words.isEmpty()) t("生词本里没有“%@”", q) else null
                }
                if (nothing != null) {
                    item { Text(nothing, style = YY.font(10.5f), color = YY.c.t3, modifier = Modifier.fillMaxWidth().padding(top = 24.dp)) }
                }
            }
            item { Box(Modifier.height(80.dp)) }
        }
    }
}

private fun open(library: Library, h: TitleHit) {
    val c = h.chapter
    if (c != null) library.open(h.book.id, Position(c.section, 0u)) else library.open(h.book)
}

/** The book 书伴 answers from: one whose name was typed, else the one read last. */
private fun askBook(library: Library, titles: List<TitleHit>): BookSummary? {
    fun can(b: BookSummary) = b.format != BookFormat.PDF
    titles.firstOrNull { it.chapter == null && can(it.book) }?.let { return it.book }
    return library.books.filter { it.available && can(it) && it.openedAt != null }.maxByOrNull { it.openedAt ?: 0 }
}

@Composable
private fun Chip(title: String, count: Int?, on: Boolean, onClick: () -> Unit) {
    val tint = YY.tint
    val enabled = count == null || count > 0
    Row(
        Modifier.height(30.dp).background(if (on) tint.black else YY.c.card, CircleShape).border(0.5.dp, if (on) tint.black else YY.c.line, CircleShape)
            .clickable(enabled = enabled, onClick = onClick).padding(horizontal = 13.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(title, fontSize = 13.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal, color = if (on) tint.onBlack else if (enabled) YY.c.t2 else YY.c.t3)
        if (count != null && count > 0) Text("$count", fontSize = 13.sp, color = if (on) tint.onBlack.copy(alpha = 0.55f) else YY.c.t3)
    }
}

/** `.v-fx-ask`: the row that's always first, handing the words to 书伴. */
@Composable
private fun AskCard(q: String, book: BookSummary, onClick: () -> Unit) {
    val tint = YY.tint
    Row(
        Modifier.padding(top = 6.dp).fillMaxWidth().background(YY.c.card, RoundedCornerShape(16.dp)).border(0.5.dp, YY.c.line, RoundedCornerShape(16.dp))
            .clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(Modifier.size(38.dp).background(tint.accentSoft, RoundedCornerShape(12.dp)), contentAlignment = Alignment.Center) {
            Icon(Icons.companion, null, tint = tint.accent, modifier = Modifier.size(18.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(t("问书伴“%@”", q), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = tint.accent, maxLines = 1)
            Text(t("只用《%@》里你读过的部分回答，带出处", book.title), fontSize = 12.sp, color = YY.c.t3, maxLines = 1)
        }
        Icon(Icons.chevronRight, null, tint = YY.c.t3, modifier = Modifier.size(16.dp))
    }
}

@Composable
private fun TitleRow(h: TitleHit, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        BookCover(h.book, Modifier.width(30.dp))
        Column(Modifier.weight(1f)) {
            Text(h.chapter?.let { "${h.book.title} · ${it.title}" } ?: h.book.title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1, maxLines = 1)
            Text(h.book.authors.firstOrNull() ?: "", fontSize = 12.sp, color = YY.c.t3, maxLines = 1)
        }
    }
}

@Composable
private fun HitRow(before: String, matched: String, after: String, place: String, onClick: () -> Unit) {
    val accent = YY.tint.accent
    Column(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            buildAnnotatedString {
                append(before)
                withStyle(SpanStyle(color = accent, fontWeight = FontWeight.SemiBold)) { append(matched) }
                append(after)
            },
            fontFamily = YY.serif, fontSize = 15.sp, lineHeight = 24.sp, color = YY.c.t1, maxLines = 3,
        )
        Text(place, fontSize = 12.sp, color = YY.c.t3, maxLines = 1)
    }
}

@Composable
private fun WordRow(w: VocabWord) {
    Column(Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(w.word, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
            w.phonetic?.let { Text(it, fontSize = 12.sp, color = YY.c.t3) }
        }
        w.meaning?.let { Text(it, fontSize = 13.sp, color = YY.c.t2, maxLines = 2) }
    }
}
