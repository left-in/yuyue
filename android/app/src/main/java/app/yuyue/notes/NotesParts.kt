package app.yuyue.notes

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.t
import uniffi.yuyue_core.Mark
import uniffi.yuyue_core.MarkStyle
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit

/** The styles 笔记 filters by: the colours first, then the lines. */
val markStyles = listOf(MarkStyle.YELLOW, MarkStyle.BLUE, MarkStyle.PINK, MarkStyle.WAVE, MarkStyle.UNDERLINE, MarkStyle.DOTTED)

/** Whether it colours behind the words (the others draw a line under them). */
val MarkStyle.fills get() = this == MarkStyle.YELLOW || this == MarkStyle.BLUE || this == MarkStyle.PINK

/** The colour behind the words. */
val MarkStyle.fill: Color
    @Composable get() = when (this) {
        MarkStyle.YELLOW -> YY.c.mkY
        MarkStyle.BLUE -> YY.c.mkB
        MarkStyle.PINK -> YY.c.mkP
        else -> Color.Transparent
    }

/** The solid dot standing for the colour in 笔记's filters. */
val MarkStyle.dot: Color
    @Composable get() = when (this) {
        MarkStyle.YELLOW -> YY.c.hlY
        MarkStyle.BLUE -> YY.c.hlB
        MarkStyle.PINK -> Color(0xFFF09E94)
        else -> YY.c.hlR
    }

/** The words of a highlight drawn as in the book: a colour behind, or a line under (the red one
 *  wavy, the dotted one dotted). */
@Composable
fun MarkText(mark: Mark, style: TextStyle, color: Color, modifier: Modifier = Modifier, maxLines: Int = Int.MAX_VALUE) {
    val text = buildAnnotatedString {
        when {
            mark.style.fills -> withStyle(SpanStyle(background = mark.style.fill)) { append(mark.text) }
            mark.style == MarkStyle.UNDERLINE -> withStyle(SpanStyle(textDecoration = TextDecoration.Underline)) { append(mark.text) }
            else -> append(mark.text)
        }
    }
    var layout by remember { mutableStateOf<TextLayoutResult?>(null) }
    val line = if (mark.style == MarkStyle.WAVE) YY.c.hlR else color
    val drawn = if (mark.style == MarkStyle.WAVE || mark.style == MarkStyle.DOTTED) Modifier.drawBehind {
        val l = layout ?: return@drawBehind
        for (i in 0 until l.lineCount) {
            val left = l.getLineLeft(i)
            val right = l.getLineRight(i)
            val y = l.getLineBottom(i) - 2.dp.toPx()
            if (mark.style == MarkStyle.WAVE) {
                val path = Path()
                val step = 3.dp.toPx()
                path.moveTo(left, y)
                var x = left
                var up = true
                while (x < right) {
                    val next = minOf(x + step, right)
                    path.quadraticTo((x + next) / 2, y + (if (up) -2.2f else 2.2f).dp.toPx(), next, y)
                    x = next
                    up = !up
                }
                drawPath(path, line, style = Stroke(1.dp.toPx()))
            } else {
                drawLine(line.copy(alpha = 0.6f), androidx.compose.ui.geometry.Offset(left, y), androidx.compose.ui.geometry.Offset(right, y), 1.2.dp.toPx(),
                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(1.5.dp.toPx(), 2.5.dp.toPx())))
            }
        }
    } else Modifier
    Text(text, style = style, color = color, maxLines = maxLines, onTextLayout = { layout = it }, modifier = modifier.then(drawn))
}

/** When a note was made, a small headphone before it when it was marked by 双击耳机. */
@Composable
fun NoteStamp(mark: Mark, text: String, size: Float = 11.5f) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        if (mark.heard) Icon(Icons.headphones, t("听书时划的"), tint = YY.c.t3, modifier = Modifier.size((size - 1.5f).dp))
        Text(text, fontSize = size.sp, color = YY.c.t3)
    }
}

object Notes {
    fun date(ms: Long): LocalDate = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()).toLocalDate()

    fun monthDay(d: LocalDate) = t("%lld 月 %lld 日", d.monthValue, d.dayOfMonth)

    fun shortDay(d: LocalDate): String = when (d) {
        LocalDate.now() -> t("今天")
        LocalDate.now().minusDays(1) -> t("昨天")
        else -> monthDay(d)
    }

    /** 划线 12 · 想法 3. */
    fun counts(marks: List<Mark>): String {
        val thoughts = marks.count { it.note != null }
        return t("划线 %lld", marks.size) + if (thoughts > 0) t(" · 想法 %lld", thoughts) else ""
    }

    /** 90 天前划的. */
    fun whenMarked(ms: Long): String {
        val days = ChronoUnit.DAYS.between(date(ms), LocalDate.now())
        return when {
            days < 1 -> t("今天划的")
            days == 1L -> t("昨天划的")
            days < 365 -> t("%lld 天前划的", days)
            else -> t("%lld 年前划的", days / 365)
        }
    }

    /** “…”\n——《书名》, for sharing as text. */
    fun plain(mark: Mark, title: String?) = "“${mark.text}”" + (mark.note?.let { "\n$it" } ?: "") + (title?.let { "\n——《$it》" } ?: "")
}
