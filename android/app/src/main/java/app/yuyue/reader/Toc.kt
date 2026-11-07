package app.yuyue.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.yuyue.design.Icons
import app.yuyue.design.ProgressLine
import app.yuyue.design.YY
import app.yuyue.design.YYSegments
import app.yuyue.shelf.BookCover
import app.yuyue.t
import uniffi.yuyue_core.SectionKind
import uniffi.yuyue_core.TocItem
import kotlin.math.roundToInt

/** "第五回 游幻境指迷十二钗": the number and the name, when the title has both. */
class ChapterTitle(title: String) {
    val number: String?
    val name: String

    init {
        val t = title.trim()
        val m = Regex("""^(第[〇零一二三四五六七八九十百千两\d]+[回章节卷部篇集])[\s　:：、.]*(.*)$""").find(t)
        if (m != null && m.groupValues[2].isNotEmpty()) {
            number = m.groupValues[1]
            name = m.groupValues[2]
        } else {
            number = null
            name = t
        }
    }
}

/** One line of 目录: an entry and the sections it covers, up to the next entry's. */
data class TocChapter(val id: Int, val title: String, val depth: Int, val item: TocItem, val sections: IntRange)

/** The book's own table of contents; with none, the sections that have something to read. */
val ReaderModel.tocChapters: List<TocChapter>
    get() {
        val d = detail ?: return emptyList()
        var items = d.toc
        if (items.isEmpty()) {
            items = d.sections.mapIndexedNotNull { i, s ->
                if (!s.linear || s.kind != SectionKind.TEXT || s.continued) null
                else TocItem(s.title ?: t("第 %lld 节", i + 1), 0u, i.toUInt(), null)
            }
        }
        return items.mapIndexed { i, item ->
            val start = item.section.toInt()
            val end = items.drop(i + 1).firstOrNull { it.section.toInt() > start }?.section?.toInt() ?: d.sections.size
            TocChapter(i, item.title, item.depth.toInt(), item, start until maxOf(start + 1, end))
        }
    }

fun ReaderModel.currentChapter(chapters: List<TocChapter>): Int? = chapters.lastOrNull { it.sections.first <= section }?.id

/** About how long the chapter takes to read. */
fun ReaderModel.minutes(c: TocChapter): Int = c.sections.sumOf { minutes(it) }

/** How far into the chapter, by its sections' length. */
fun ReaderModel.within(c: TocChapter): Double {
    val d = detail ?: return 0.0
    val units = c.sections.map { (d.sections.getOrNull(it)?.units ?: 0u).toDouble() }
    val total = units.sum()
    if (total <= 0) return 0.0
    var done = 0.0
    c.sections.forEachIndexed { k, i ->
        if (i < section) done += units[k]
        if (i == section) done += units[k] * sentence / maxOf(1, sentenceCount)
    }
    return minOf(1.0, done / total)
}

/** 目录: the book on top, then 目录 · 书签 · 笔记. The chapter being read sits in
 *  the middle in the accent, with a line for how far into it; the ones read are faded. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TocSheet(model: ReaderModel, dismiss: () -> Unit) {
    var tab by remember { mutableStateOf(0) }
    val chapters = remember(model.section) { model.tocChapters }
    val current = model.currentChapter(chapters)
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.fillMaxSize().padding(top = YY.s(4)), verticalArrangement = Arrangement.spacedBy(YY.s(12))) {
            Header(model, chapters, current, dismiss)
            YYSegments(
                listOf(0 to t("目录"), 1 to (if (model.bookmarks.isEmpty()) t("书签") else t("书签 %lld", model.bookmarks.size)), 2 to (if (model.marks.isEmpty()) t("笔记") else t("笔记 %lld", model.marks.size))),
                tab, { tab = it }, modifier = Modifier.padding(horizontal = YY.s(14)).fillMaxWidth(),
            )
            when (tab) {
                0 -> Chapters(model, chapters, current, dismiss)
                1 -> Bookmarks(model, dismiss)
                else -> Marks(model, dismiss)
            }
        }
    }
}

@Composable
private fun Header(model: ReaderModel, chapters: List<TocChapter>, current: Int?, dismiss: () -> Unit) {
    val book = model.detail?.summary
    val at = current?.let { chapters.getOrNull(it) }?.let { ChapterTitle(it.title).number ?: it.title }
    Row(Modifier.padding(horizontal = YY.s(16)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(11))) {
        if (book != null) BookCover(book, Modifier.width(YY.s(30)))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(YY.s(3))) {
            Text(book?.title ?: t("目录"), style = YY.font(14f, FontWeight.Bold), color = YY.c.t1, maxLines = 1)
            Text(
                listOfNotNull(book?.authors?.firstOrNull(), at?.let { t("读到%@", it) }, t("全书 %lld%%", (model.bookFraction * 100).roundToInt())).joinToString(" · "),
                style = YY.font(10f), color = YY.c.t3, maxLines = 1,
            )
        }
        Box(Modifier.size(YY.s(26)).background(YY.c.inset, RoundedCornerShape(50)).clickable(onClick = dismiss), contentAlignment = Alignment.Center) {
            Icon(Icons.close, t("关闭"), tint = YY.c.t1, modifier = Modifier.size(YY.s(11)))
        }
    }
}

@Composable
private fun Chapters(model: ReaderModel, chapters: List<TocChapter>, current: Int?, dismiss: () -> Unit) {
    if (chapters.isEmpty()) return Empty(t("这本书没有目录"), t("书里没写章节，往后翻就行"))
    val state = rememberLazyListState()
    LaunchedEffect(current) { current?.let { state.scrollToItem(maxOf(0, it - 3)) } }
    LazyColumn(
        state = state,
        modifier = Modifier.padding(horizontal = YY.s(14)).padding(bottom = YY.s(20)).fillMaxWidth()
            .background(YY.c.card, RoundedCornerShape(YY.s(14))).border(0.5.dp, YY.c.line, RoundedCornerShape(YY.s(14))),
    ) {
        itemsIndexed(chapters, key = { _, c -> c.id }) { i, c ->
            if (i > 0) Box(Modifier.padding(horizontal = YY.s(12)).fillMaxWidth().height(0.5.dp).background(YY.c.line))
            ChapterRow(model, c, current) { model.go(c.item); dismiss() }
        }
    }
}

/** 第几回, the name, the minutes; this one in the accent, its name whole, a line under. */
@Composable
private fun ChapterRow(model: ReaderModel, c: TocChapter, current: Int?, go: () -> Unit) {
    val now = c.id == current
    val done = (current ?: -1) > c.id
    val title = ChapterTitle(c.title)
    val accent = YY.tint.accent
    val minutes = model.minutes(c)
    val note = if (now) t("还剩 %lld 分钟", maxOf(1, (minutes * (1 - model.within(c))).roundToInt())) else t("%lld 分钟", minutes)
    Row(Modifier.fillMaxWidth().clickable(onClick = go).padding(horizontal = YY.s(12), vertical = YY.s(11)), horizontalArrangement = Arrangement.spacedBy(YY.s(6))) {
        if (title.number != null) {
            Text(title.number, style = YY.font(10.5f, if (now) FontWeight.SemiBold else FontWeight.Normal), color = if (now) accent else YY.c.t3, maxLines = 1, modifier = Modifier.width(YY.s(46)))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(YY.s(8))) {
            Row(horizontalArrangement = Arrangement.spacedBy(YY.s(6))) {
                Text(
                    title.name, style = YY.font(11.5f, if (now) FontWeight.SemiBold else FontWeight.Normal),
                    color = if (done) YY.c.t3 else if (now) accent else YY.c.t1,
                    maxLines = if (now) 3 else 1,
                    modifier = Modifier.weight(1f).padding(start = YY.s(12) * c.depth),
                )
                Text(note, style = YY.font(10f, if (now) FontWeight.SemiBold else FontWeight.Normal), color = if (now) accent else YY.c.t3, maxLines = 1)
            }
            if (now) ProgressLine(model.within(c), YY.s(3))
        }
    }
}

@Composable
private fun Bookmarks(model: ReaderModel, dismiss: () -> Unit) {
    if (model.bookmarks.isEmpty()) return Empty(t("还没有书签"), t("书页往下拉一下，就给这一页加上书签"))
    LazyColumn(Modifier.padding(horizontal = YY.s(14)).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(YY.s(8))) {
        itemsIndexed(model.bookmarks, key = { _, b -> b.id }) { _, b ->
            Column(
                Modifier.fillMaxWidth().background(YY.c.card, RoundedCornerShape(YY.s(12))).clickable { model.jump(b.section.toInt(), b.sentence.toInt()); dismiss() }
                    .padding(YY.s(12)),
                verticalArrangement = Arrangement.spacedBy(YY.s(4)),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(5))) {
                    Icon(Icons.bookmark, null, tint = YY.tint.accent, modifier = Modifier.size(YY.s(10)))
                    Text(model.place(b.section.toInt(), b.sentence.toInt()), style = YY.font(10f), color = YY.c.t3, maxLines = 1, modifier = Modifier.weight(1f))
                    Text(t("删除"), style = YY.font(10f), color = YY.c.danger, modifier = Modifier.clickable { model.deleteBookmark(b) })
                }
                Text(b.text, style = YY.font(11.5f), color = YY.c.t1, maxLines = 2)
            }
        }
    }
}

@Composable
private fun Marks(model: ReaderModel, dismiss: () -> Unit) {
    if (model.marks.isEmpty()) return Empty(t("还没有划线"), t("长按选中文字，点一个颜色就划上"))
    LazyColumn(Modifier.padding(horizontal = YY.s(14)).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(YY.s(8))) {
        itemsIndexed(model.marks, key = { _, m -> m.id }) { _, m ->
            Column(
                Modifier.fillMaxWidth().background(YY.c.card, RoundedCornerShape(YY.s(12))).clickable { model.jump(m.section.toInt(), m.start.sentence.toInt()); dismiss() }
                    .padding(YY.s(12)),
                verticalArrangement = Arrangement.spacedBy(YY.s(5)),
            ) {
                Text(m.text, style = YY.font(12.5f, family = YY.serif), color = YY.c.t1)
                m.note?.let { Text(it, style = YY.font(12f), color = YY.tint.accent, modifier = Modifier.padding(start = YY.s(9))) }
                Row {
                    Text(model.place(m.section.toInt(), m.start.sentence.toInt()), style = YY.font(10f), color = YY.c.t3, maxLines = 1, modifier = Modifier.weight(1f))
                    Text(t("删除"), style = YY.font(10f), color = YY.c.danger, modifier = Modifier.clickable { model.deleteMark(m) })
                }
            }
        }
    }
}

@Composable
private fun Empty(title: String, detail: String) {
    Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(YY.s(5), Alignment.CenterVertically)) {
        Text(title, style = YY.font(12.5f, FontWeight.SemiBold), color = YY.c.t2)
        Text(detail, style = YY.font(10.5f), color = YY.c.t3)
        Spacer(Modifier.height(80.dp))
    }
}
