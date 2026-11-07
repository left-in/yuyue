package app.yuyue.me

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYGroup
import app.yuyue.design.YYLabel
import app.yuyue.design.YYPage
import app.yuyue.design.YYSegments
import app.yuyue.library.Library
import app.yuyue.library.percent
import app.yuyue.library.remaining
import app.yuyue.shelf.BookCover
import app.yuyue.t
import uniffi.yuyue_core.BookSummary
import uniffi.yuyue_core.DayTime
import uniffi.yuyue_core.ReadingStatus
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.TextStyle
import java.util.Locale
import java.time.temporal.TemporalAdjusters

/** 阅读统计, as on iPhone: by week, month or year, reading and listening
 *  apart; the books finished; each book's time; and, at the bottom, how the time is counted. */
@Composable
fun StatsPage(library: Library) {
    var period by remember { mutableStateOf(Period.Week) }
    var anchor by remember { mutableStateOf(LocalDate.now()) }
    val days = period.days(anchor)
    val today = LocalDate.now()
    val current = today in days
    val times = remember(period, anchor, library.notesVersion) {
        runCatching { library.core.dayTimes(days.first().toString(), days.last().toString()) }.getOrDefault(emptyList())
    }
    val word = period.word(current)
    val finished = library.books.filter { b ->
        b.status == ReadingStatus.FINISHED && b.finishedAt?.let { date(it) in days.first()..days.last() } == true
    }
    val perBook = times.groupBy { it.book }.mapNotNull { (id, ts) ->
        library.books.firstOrNull { it.id == id }?.let { Triple(it, ts.sumOf { t -> t.readSeconds.toInt() }, ts.sumOf { t -> t.listenSeconds.toInt() }) }
    }.filter { it.second + it.third >= 60 }.sortedByDescending { it.second + it.third }

    YYPage {
        YYSegments(Period.entries.map { it to it.title }, period, { period = it; anchor = LocalDate.now() }, modifier = Modifier.padding(top = YY.s(10)).fillMaxWidth())
        Column(Modifier.padding(top = YY.s(12)).fillMaxWidth().background(YY.c.card, RoundedCornerShape(YY.s(16))).padding(start = YY.s(14), end = YY.s(14), top = YY.s(12))) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(6))) {
                val (title, range) = heading(period, days, current, word)
                Text(title, style = YY.font(13f, FontWeight.Bold), color = YY.c.t1)
                Text(range, style = YY.font(10f), color = YY.c.t3, modifier = Modifier.weight(1f))
                Step(Icons.chevronLeft, t("往前"), true) { anchor = period.move(anchor, -1) }
                Step(Icons.chevronRight, t("往后"), !current) { anchor = period.move(anchor, 1) }
            }
            Row(Modifier.padding(top = YY.s(6)), horizontalArrangement = Arrangement.spacedBy(YY.s(20))) {
                PeriodTotal(t("读"), times.sumOf { it.readSeconds.toInt() }, YY.tint.fill)
                PeriodTotal(t("听"), times.sumOf { it.listenSeconds.toInt() }, YY.c.tint)
            }
            Columns(slots(period, days, times, today), if (period == Period.Week) 8f else 5f, Modifier.padding(top = YY.s(12)).height(YY.s(50)))
            Row(Modifier.padding(top = YY.s(5)).fillMaxWidth()) {
                val n = if (period == Period.Year) 12 else days.size
                for (i in 0 until n) Text(axis(period, days, i), style = YY.font(10f), color = YY.c.t3, maxLines = 1, softWrap = false, modifier = Modifier.weight(1f).wrapContentWidth(Alignment.CenterHorizontally, unbounded = true))
            }
            if (finished.isEmpty()) Spacer(Modifier.height(YY.s(12)))
            else {
                Box(Modifier.padding(top = YY.s(12)).fillMaxWidth().height(0.5.dp).background(YY.c.line))
                Row(Modifier.padding(top = YY.s(10), bottom = YY.s(11)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(10))) {
                    Row(horizontalArrangement = Arrangement.spacedBy((-6).dp)) {
                        for (b in finished.take(3)) BookCover(b, Modifier.width(YY.s(20)).border(1.5.dp, YY.c.card, RoundedCornerShape(3.dp)))
                    }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                        Text(t("%@读完 %lld 本", word, finished.size), style = YY.font(11.5f, FontWeight.SemiBold), color = YY.c.t1)
                        Text(finished.joinToString(" · ") { it.title }, style = YY.font(10f), color = YY.c.t3, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
        if (perBook.isNotEmpty()) {
            YYLabel(t("每本书"), t("%@ · 按时长", word))
            YYGroup {
                for ((b, read, listen) in perBook) row { BookTime(b, read, listen) }
            }
        }
        How(Modifier.padding(top = YY.s(12), bottom = YY.s(12)))
    }
}

enum class Period {
    Week, Month, Year;

    val title: String get() = when (this) { Week -> t("周"); Month -> t("月"); Year -> t("年") }

    /** Every day of the period `date` falls in; weeks start on Monday. */
    fun days(date: LocalDate): List<LocalDate> {
        val (first, last) = when (this) {
            Week -> date.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY)).let { it to it.plusDays(6) }
            Month -> date.withDayOfMonth(1).let { it to it.plusMonths(1).minusDays(1) }
            Year -> date.withDayOfYear(1).let { it to it.plusYears(1).minusDays(1) }
        }
        return generateSequence(first) { it.plusDays(1) }.takeWhile { it <= last }.toList()
    }

    fun move(date: LocalDate, by: Long): LocalDate = when (this) {
        Week -> date.plusWeeks(by)
        Month -> date.plusMonths(by)
        Year -> date.plusYears(by)
    }

    fun word(current: Boolean): String = when (this) {
        Week -> if (current) t("这周") else t("那一周")
        Month -> if (current) t("这个月") else t("那个月")
        Year -> if (current) t("今年") else t("那年")
    }
}

private fun date(ms: Long): LocalDate = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()).toLocalDate()

private fun monthDay(d: LocalDate) = t("%lld 月 %lld 日", d.monthValue, d.dayOfMonth)

/** "10 月" and "1 日 – 11 日"; "这周" and the days; "2026 年" and the months so far. In other
 *  languages the months go by their names: "October", "Oct 1 – 21". */
private fun heading(period: Period, days: List<LocalDate>, current: Boolean, word: String): Pair<String, String> {
    val first = days.first()
    val last = days.last()
    val end = if (current) minOf(LocalDate.now(), last) else last
    if (!app.yuyue.L10n.chinese) return when (period) {
        Period.Week -> word to "${short(first)} ${first.dayOfMonth} – ${if (first.monthValue == last.monthValue) "" else short(last) + " "}${last.dayOfMonth}"
        Period.Month -> first.month.getDisplayName(TextStyle.FULL, Locale.getDefault()) to "${short(first)} 1 – ${end.dayOfMonth}"
        Period.Year -> "${first.year}" to "${short(first)} – ${short(end)}"
    }
    return when (period) {
        Period.Week -> word to t("%@ – %@", monthDay(first), if (first.monthValue == last.monthValue) t("%lld 日", last.dayOfMonth) else monthDay(last))
        Period.Month -> t("%lld 月", first.monthValue) to t("1 日 – %lld 日", end.dayOfMonth)
        Period.Year -> t("%lld 年", first.year) to t("1 – %lld 月", end.monthValue)
    }
}

private fun short(d: LocalDate) = d.month.getDisplayName(TextStyle.SHORT, Locale.getDefault())

private class Slot(val read: Int, val listen: Int, val today: Boolean, val future: Boolean)

/** One slot per day (per month over a year). */
private fun slots(period: Period, days: List<LocalDate>, times: List<DayTime>, today: LocalDate): List<Slot> {
    if (period == Period.Year) return (0 until 12).map { m ->
        val start = days.first().plusMonths(m.toLong())
        val prefix = start.toString().take(7)
        val ts = times.filter { it.day.startsWith(prefix) }
        Slot(ts.sumOf { it.readSeconds.toInt() }, ts.sumOf { it.listenSeconds.toInt() }, start.year == today.year && start.monthValue == today.monthValue, start > today)
    }
    return days.map { d ->
        val ts = times.filter { it.day == d.toString() }
        Slot(ts.sumOf { it.readSeconds.toInt() }, ts.sumOf { it.listenSeconds.toInt() }, d == today, d > today)
    }
}

/** Listening on top of reading, today wider, the days to come a nub. */
@Composable
private fun Columns(slots: List<Slot>, width: Float, modifier: Modifier) {
    val most = maxOf(1, slots.maxOf { it.read + it.listen })
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
        for (s in slots) {
            Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.BottomCenter) {
                Column(Modifier.width(YY.s(if (s.today) width + 2 else width)).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(1.dp, Alignment.Bottom)) {
                    if (s.future) Box(Modifier.fillMaxWidth().height(2.dp).background(YY.c.line, RoundedCornerShape(1.dp)))
                    else {
                        if (s.listen > 0) Box(Modifier.fillMaxWidth().fillMaxHeight(s.listen.toFloat() / most).background(YY.c.tint, RoundedCornerShape(topStart = 2.dp, topEnd = 2.dp)))
                        if (s.read > 0) Box(Modifier.fillMaxWidth().fillMaxHeight(s.read.toFloat() / (most - s.listen).coerceAtLeast(1)).background(YY.tint.fill, RoundedCornerShape(if (s.listen > 0) 0.dp else 2.dp)))
                    }
                }
            }
        }
    }
}

/** Under the columns: the weekdays; 1, 8, 15, 22, 29 of a month; every other month of a year. */
private fun axis(period: Period, days: List<LocalDate>, i: Int): String = when (period) {
    Period.Week -> if (app.yuyue.L10n.chinese) listOf("一", "二", "三", "四", "五", "六", "日")[i]
    else days[i].dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.getDefault())
    Period.Month -> if (i % 7 == 0) "${i + 1}" else ""
    Period.Year -> if (i % 2 != 0) "" else if (app.yuyue.L10n.chinese) t("%lld 月", i + 1) else short(days.first().plusMonths(i.toLong()))
}

@Composable
private fun Step(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(YY.s(24)).background(YY.c.inset, CircleShape).clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, label, tint = if (enabled) YY.c.t1 else YY.c.t3, modifier = Modifier.size(YY.s(13))) }
}

/** A book, how far and how long to go, and the time read and listened. */
@Composable
private fun BookTime(book: BookSummary, read: Int, listen: Int) {
    Row(Modifier.padding(vertical = YY.s(8)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(10))) {
        BookCover(book, Modifier.width(YY.s(24)))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(YY.s(2))) {
            Row(horizontalArrangement = Arrangement.spacedBy(YY.s(8))) {
                Text(book.title, style = YY.font(11.5f, FontWeight.SemiBold), color = YY.c.t1, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                Spacer(Modifier.weight(1f))
                val line = if (book.status == ReadingStatus.FINISHED) book.finishedAt?.let { monthDay(date(it)) + t("读完") } ?: t("读完了")
                else t("%@ · %@", book.percent, book.remaining.replace(t("还剩"), t("还要")))
                Text(line, style = YY.font(10.5f), color = YY.c.t2, maxLines = 1)
            }
            Text(listOfNotNull(if (read > 0) t("读 ") + duration(read) else null, if (listen > 0) t("听 ") + duration(listen) else null).joinToString(" · "), style = YY.font(10f), color = YY.c.t3, maxLines = 1)
        }
    }
}

/** 5 小时 12 分. */
private fun duration(seconds: Int): String {
    val m = seconds / 60
    return when {
        m < 60 -> t("%lld 分", m)
        m % 60 == 0 -> t("%lld 小时", m / 60)
        else -> t("%lld 小时 %lld 分", m / 60, m % 60)
    }
}

/** How the time is counted, on a grey card. */
@Composable
private fun How(modifier: Modifier) {
    Column(modifier.fillMaxWidth().background(YY.c.inset, RoundedCornerShape(YY.s(14))).padding(start = YY.s(13), end = YY.s(13), top = YY.s(11), bottom = YY.s(12))) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(6)), modifier = Modifier.padding(bottom = YY.s(3))) {
            Icon(Icons.info, null, tint = YY.c.t1, modifier = Modifier.size(YY.s(13)))
            Text(t("怎么算的"), style = YY.font(11.5f, FontWeight.SemiBold), color = YY.c.t1)
        }
        for (line in listOf(t("只在翻页、滚动或朗读的时候计时。"), t("一页停了 5 分钟没翻，或者锁屏又没在听，就停表。"), t("倍速按实际时间算：1.5× 听 1 小时，记 1 小时。"))) {
            Row(Modifier.padding(vertical = YY.s(2)), horizontalArrangement = Arrangement.spacedBy(YY.s(6))) {
                Box(Modifier.padding(top = YY.s(6)).size(3.dp).background(YY.c.t3, CircleShape))
                Text(line, style = YY.font(10.5f), color = YY.c.t2)
            }
        }
    }
}

