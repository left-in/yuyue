package app.yuyue.notes

import android.content.Intent
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.library.Library
import app.yuyue.library.author
import app.yuyue.reader.ReaderModel
import app.yuyue.shelf.BookCover
import app.yuyue.shelf.Item
import app.yuyue.t
import uniffi.yuyue_core.BookSummary
import uniffi.yuyue_core.ReviewItem
import uniffi.yuyue_core.YuyueCore
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.roundToInt

/**
 * 今天回顾, as on Apple: five old highlights a day, one at a time,
 * each asking one thing: 留下, or 不要了. 留下 comes back in a while; 不要了 only stops it coming
 * back. When the five are done it says so and stops: no streaks, no "come back tomorrow".
 */
class Review(private val core: YuyueCore, val book: BookSummary? = null) {
    var items by mutableStateOf<List<ReviewItem>>(emptyList())
        private set
    var doneToday by mutableIntStateOf(0)
        private set
    /** What was chosen for each highlight, by mark id. */
    val kept = mutableStateMapOf<String, Boolean>()
    var index by mutableIntStateOf(0)
        private set

    init { reload() }

    fun reload() {
        // One book's review is not today's five: everything not seen lately is due.
        val start = if (book == null) LocalDate.now().atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli() else System.currentTimeMillis()
        val deck = runCatching { core.reviewToday(book?.id, start, PER_DAY) }.getOrNull()
        items = deck?.items ?: emptyList()
        doneToday = if (book == null) deck?.doneToday?.toInt() ?: 0 else 0
        kept.clear()
        index = 0
    }

    val current: ReviewItem? get() = items.getOrNull(index)

    /** 约 2 分钟: about 25 seconds each. */
    val minutes: Int get() = maxOf(1, (items.size * 25 / 60.0).roundToInt())

    fun choose(keep: Boolean) {
        val item = current ?: return
        set(item, keep)
        index++
    }

    /** Changing one's mind on the 看完了 page. */
    fun flip(item: ReviewItem) = set(item, !(kept[item.mark.id] ?: true))

    private fun set(item: ReviewItem, keep: Boolean) {
        runCatching { core.setMarkReview(item.book, item.mark.id, keep) }
        kept[item.mark.id] = keep
    }

    companion object {
        const val PER_DAY = 5u
    }
}

/** The cards underneath, two edges showing, and the card on top. */
@Composable
private fun Stack(modifier: Modifier = Modifier, under: Float = 12f, radius: Float = 16f, content: @Composable () -> Unit) {
    Box(modifier) {
        Box(Modifier.matchParentSize().padding(horizontal = (under * 2).dp).offset(y = (under + 1).dp).alpha(0.45f).background(YY.c.card, RoundedCornerShape(radius.dp)))
        Box(Modifier.matchParentSize().padding(horizontal = under.dp).offset(y = (under / 2).dp).shadow(2.dp, RoundedCornerShape(radius.dp)).alpha(0.75f).background(YY.c.card, RoundedCornerShape(radius.dp)))
        Box(Modifier.shadow(2.dp, RoundedCornerShape((radius + 2).dp)).background(YY.c.card, RoundedCornerShape((radius + 2).dp))) { content() }
    }
}

/** The stack of cards on top of 按时间, as on iPhone: how many and how long, the first sentence,
 *  the books they come from, 开始. */
@Composable
fun DeckCard(review: Review, library: Library, start: () -> Unit) {
    val covers = review.items.map { it.book }.distinct().mapNotNull { id -> library.books.firstOrNull { it.id == id } }.take(4)
    Stack(Modifier.fillMaxWidth().padding(bottom = 12.dp)) {
        Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(t("今天回顾"), fontSize = 15.sp, fontWeight = FontWeight.Bold, color = YY.c.t1)
                Text(if (review.items.isEmpty()) t("看完了") else t("%lld 条 · 约 %lld 分钟", review.items.size, review.minutes), fontSize = 12.sp, color = YY.c.t3)
            }
            val first = review.items.firstOrNull()
            if (first != null) {
                Text("“" + first.mark.text + "”", fontFamily = YY.serif, fontSize = 16.sp, lineHeight = 26.sp, color = YY.c.t1, maxLines = 3, overflow = TextOverflow.Ellipsis)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy((-6).dp)) { for (b in covers) BookCover(b, Modifier.width(18.dp)) }
                    Text(t("来自 %lld 本书", covers.size), fontSize = 12.sp, color = YY.c.t3, modifier = Modifier.weight(1f))
                    Box(Modifier.height(34.dp).background(YY.tint.black, CircleShape).clickable(onClick = start).padding(horizontal = 20.dp), contentAlignment = Alignment.Center) {
                        Text(t("开始"), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = YY.tint.onBlack)
                    }
                }
            } else {
                Text(t("今天的 %u 条看完了。留下的以后还会再出现。", review.doneToday), fontSize = 13.sp, color = YY.c.t2)
            }
        }
    }
}

/** The review itself, one card at a time, then 看完了. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReviewSheet(review: Review, library: Library, open: (ReviewItem) -> Unit, only: (BookSummary) -> Unit, dismiss: () -> Unit) {
    val context = LocalContext.current
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(0.92f).padding(horizontal = 24.dp).padding(bottom = 24.dp)) {
            // 关闭 · 今天回顾 · 1 / 5 · 分享
            Row(verticalAlignment = Alignment.CenterVertically) {
                Round(Icons.close, t("关闭"), dismiss)
                val name = review.book?.let { t("回顾《%@》", it.title) } ?: t("今天回顾")
                Text("$name · ${minOf(review.index + 1, review.items.size)} / ${review.items.size}", fontSize = 13.sp, fontWeight = FontWeight.Bold, color = YY.c.t1,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.weight(1f))
                val item = review.current
                if (item != null) Round(Icons.share, t("分享")) {
                    val title = library.books.firstOrNull { it.id == item.book }?.title
                    context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, Notes.plain(item.mark.copy(note = null), title)), null))
                } else Spacer(Modifier.size(30.dp))
            }
            Row(Modifier.padding(top = 14.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                for (i in review.items.indices) Box(Modifier.weight(1f).height(3.dp).background(if (i < review.index) YY.c.t1 else YY.c.line, CircleShape))
            }
            AnimatedContent(review.current, transitionSpec = { (slideInHorizontally { it / 3 } + fadeIn()) togetherWith fadeOut() }, label = "card", modifier = Modifier.weight(1f).padding(top = 22.dp)) { item ->
                Stack(Modifier.fillMaxSize(), under = 12f) {
                    if (item != null) Card(item, library, open) else Summary(review, library, only)
                }
            }
            Spacer(Modifier.height(28.dp))
            if (review.current != null) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Pill(t("不要了"), Icons.close, false, Modifier.weight(1f)) { review.choose(false) }
                    Pill(t("留下"), Icons.check, true, Modifier.weight(1f)) { review.choose(true) }
                }
            } else {
                Pill(t("完成"), null, true, Modifier.fillMaxWidth(), dismiss)
            }
        }
    }
}

@Composable
private fun Round(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Box(Modifier.size(30.dp).background(YY.c.card, CircleShape).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, label, tint = YY.c.t2, modifier = Modifier.size(14.dp))
    }
}

@Composable
private fun Pill(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector?, main: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Row(
        modifier.height(38.dp)
            .background(if (main) YY.tint.black else YY.c.pill, CircleShape)
            .border(0.5.dp, if (main) YY.tint.edge else YY.c.pillLine, CircleShape)
            .clickable(onClick = onClick),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
    ) {
        val color = if (main) YY.tint.onBlack else YY.c.t1
        if (icon != null) Icon(icon, null, tint = color, modifier = Modifier.size(15.dp))
        Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = color)
    }
}

@Composable
private fun Card(item: ReviewItem, library: Library, open: (ReviewItem) -> Unit) {
    val book = library.books.firstOrNull { it.id == item.book }
    Column(Modifier.fillMaxSize().padding(start = 22.dp, end = 22.dp, top = 24.dp, bottom = 18.dp)) {
        Text("“", fontFamily = YY.serif, fontSize = 40.sp, lineHeight = 40.sp, color = YY.tint.accent, modifier = Modifier.height(22.dp))
        Column(Modifier.weight(1f).padding(top = 10.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(item.mark.text, fontFamily = YY.serif, fontWeight = FontWeight.SemiBold, fontSize = 19.sp, lineHeight = 34.sp, letterSpacing = 0.4.sp, color = YY.c.t1)
            item.mark.note?.let {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Box(Modifier.width(1.5.dp).height(20.dp).background(YY.tint.accent))
                    Text(it, fontSize = 13.sp, lineHeight = 20.sp, color = YY.tint.accent)
                }
            }
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(YY.c.line))
        Row(Modifier.padding(top = 14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (book != null) BookCover(book, Modifier.width(26.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(book?.title ?: "", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1, maxLines = 1, overflow = TextOverflow.Ellipsis)
                val chapter = book?.let { b -> runCatching { library.core.book(b.id) }.getOrNull()?.let { ReaderModel.chapterTitle(it, item.mark.section.toInt()) }?.takeIf { it != b.title } }
                Text(listOfNotNull(book?.author, chapter, Notes.whenMarked(item.mark.at)).joinToString(" · "), fontSize = 10.5.sp, color = YY.c.t3, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Row(Modifier.clickable { open(item) }, verticalAlignment = Alignment.CenterVertically) {
                Text(t("回原文"), fontSize = 11.sp, color = YY.c.t2)
                Icon(Icons.chevronRight, null, tint = YY.c.t2, modifier = Modifier.size(12.dp))
            }
        }
    }
}

/** 看完了: what was kept and dropped, each to change, and 只回顾某一本书. */
@Composable
private fun Summary(review: Review, library: Library, only: (BookSummary) -> Unit) {
    val kept = review.items.count { review.kept[it.mark.id] ?: true }
    val dropped = review.items.size - kept
    var picking by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().padding(start = 22.dp, end = 22.dp, top = 24.dp, bottom = 18.dp)) {
        Text(if (review.book == null) t("今天的 %lld 条看完了", review.items.size) else t("这本书的 %lld 条看完了", review.items.size),
            fontFamily = YY.serif, fontWeight = FontWeight.SemiBold, fontSize = 19.sp, letterSpacing = 0.4.sp, color = YY.c.t1)
        Text(t("留下 %lld 条", kept) + if (dropped > 0) t(" · 不要了 %lld 条", dropped) else "", fontSize = 11.5.sp, color = YY.c.t2, modifier = Modifier.padding(top = 6.dp))
        Column(Modifier.padding(top = 18.dp)) {
            review.items.forEachIndexed { i, item ->
                if (i > 0) Box(Modifier.fillMaxWidth().height(1.dp).background(YY.c.line))
                val keep = review.kept[item.mark.id] ?: true
                val book = library.books.firstOrNull { it.id == item.book }
                Row(Modifier.fillMaxWidth().height(40.dp).clickable { review.flip(item) }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                    if (book != null) BookCover(book, Modifier.width(14.dp).alpha(if (keep) 1f else 0.45f))
                    Text(item.mark.text, fontFamily = YY.serif, fontSize = 12.5.sp, color = if (keep) YY.c.t1 else YY.c.t3, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    if (keep) Icon(Icons.check, null, tint = YY.c.t2, modifier = Modifier.size(13.dp))
                    else Text(t("不要了"), fontSize = 10.5.sp, color = YY.c.t3)
                }
            }
        }
        Text(t("留下的以后还会再出现。不要了的只是不再回顾，笔记还在；点一条可以改主意。"), fontSize = 11.sp, lineHeight = 17.sp, color = YY.c.t3, modifier = Modifier.padding(top = 14.dp))
        Spacer(Modifier.weight(1f).height(12.dp))
        Box(Modifier.fillMaxWidth().height(1.dp).background(YY.c.line))
        Box {
            Row(Modifier.fillMaxWidth().padding(top = 13.dp).clickable { picking = true }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.book, null, tint = YY.c.t2, modifier = Modifier.size(15.dp))
                Text(t("只回顾某一本书"), fontSize = 12.5.sp, fontWeight = FontWeight.Medium, color = YY.c.t1, modifier = Modifier.weight(1f))
                Icon(Icons.chevronRight, null, tint = YY.c.t3, modifier = Modifier.size(12.dp))
            }
            DropdownMenu(picking, { picking = false }, containerColor = YY.c.card) {
                val books = remember { library.books.filter { b -> b.available && runCatching { library.core.marks(b.id) }.getOrDefault(emptyList()).isNotEmpty() } }
                for (b in books) Item(b.title, Icons.book) { picking = false; only(b) }
            }
        }
    }
}

