package app.yuyue.me

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.BuildConfig
import app.yuyue.design.Appearance
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYGroup
import app.yuyue.design.YYLabel
import app.yuyue.design.YYNote
import app.yuyue.design.YYPage
import app.yuyue.design.YYRow
import app.yuyue.design.YYTints
import app.yuyue.design.rememberPref
import app.yuyue.library.Library
import app.yuyue.t
import uniffi.yuyue_core.ReadingStatus
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters

/** A page under 我的. */
enum class MePage { Stats, Appearance, About, Privacy, Licences }

/** 我的 (prototype 我的), as on iPhone: this week's reading and listening on top, the year's
 *  totals under it, then every setting in groups. */
@Composable
fun MeScreen(library: Library) {
    val stack = remember { mutableStateListOf<MePage>() }
    BackHandler(enabled = stack.isNotEmpty()) { stack.removeAt(stack.lastIndex) }
    when (val page = stack.lastOrNull()) {
        null -> Main(library) { stack += it }
        else -> Sub(page, back = { stack.removeAt(stack.lastIndex) }) {
            when (page) {
                MePage.Stats -> Stats(library)
                MePage.Appearance -> AppearancePage()
                MePage.About -> About { stack += it }
                MePage.Privacy -> TextPage(PRIVACY)
                MePage.Licences -> TextPage(LICENCES)
            }
        }
    }
}

private val MePage.title: String
    get() = when (this) {
        MePage.Stats -> t("阅读统计")
        MePage.Appearance -> t("外观")
        MePage.About -> t("关于")
        MePage.Privacy -> t("隐私说明")
        MePage.Licences -> t("开源许可")
    }

/** A page pushed over 我的: its name in the middle, ‹ on the left. */
@Composable
fun Sub(page: MePage, back: () -> Unit, content: @Composable () -> Unit) {
    SubPage(page.title, back, content)
}

@Composable
fun SubPage(title: String, back: () -> Unit, content: @Composable () -> Unit) {
    Column(Modifier.fillMaxSize().background(YY.c.bg).windowInsetsPadding(WindowInsets.statusBars)) {
        Box(Modifier.fillMaxWidth().height(52.dp)) {
            Icon(Icons.back, t("返回"), tint = YY.c.t1, modifier = Modifier.align(Alignment.CenterStart).padding(start = 12.dp).size(24.dp).clickable(onClick = back))
            Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1, modifier = Modifier.align(Alignment.Center))
        }
        Box(Modifier.weight(1f)) { content() }
    }
}

@Composable
private fun Main(library: Library, push: (MePage) -> Unit) {
    val mode by rememberPref(Appearance.KEY, Appearance.SYSTEM)
    val tintID by rememberPref("appearance.tint", YYTints.Default.id)
    Column(Modifier.fillMaxSize().background(YY.c.bg).windowInsetsPadding(WindowInsets.statusBars)) {
        Text(t("我的"), fontSize = 32.sp, fontWeight = FontWeight.Bold, color = YY.c.t1, modifier = Modifier.padding(start = 20.dp, top = 12.dp))
        YYPage {
            Box(Modifier.padding(top = YY.s(14), bottom = YY.s(12)).clickable { push(MePage.Stats) }) { WeekCard(library) }
            Group {
                row { YYRow(t("外观"), Icons.settings, "${modeTitle(mode)} · ${YYTints.All.firstOrNull { it.id == tintID }?.name?.let { t(it) } ?: ""}", chevron = true) { push(MePage.Appearance) } }
            }
            Group {
                row { YYRow(t("关于"), Icons.info, BuildConfig.VERSION_NAME, chevron = true) { push(MePage.About) } }
            }
        }
    }
}

@Composable
private fun Group(build: app.yuyue.design.GroupScope.() -> Unit) {
    YYGroup(Modifier.padding(bottom = YY.s(10)), build = build)
}

private fun modeTitle(mode: String) = when (mode) {
    Appearance.LIGHT -> t("浅色")
    Appearance.DARK -> t("深色")
    else -> t("跟随系统")
}

// MARK: 这周

private data class DaySums(val day: LocalDate, val read: Int, val listen: Int)

private fun weekDays(of: LocalDate = LocalDate.now()): List<LocalDate> {
    val monday = of.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
    return (0 until 7).map { monday.plusDays(it.toLong()) }
}

private fun sums(library: Library, days: List<LocalDate>): List<DaySums> {
    val times = runCatching { library.core.dayTimes(days.first().toString(), days.last().toString()) }.getOrDefault(emptyList())
    return days.map { d ->
        val k = d.toString()
        val ts = times.filter { it.day == k }
        DaySums(d, ts.sumOf { it.readSeconds.toInt() }, ts.sumOf { it.listenSeconds.toInt() })
    }
}

/** `.v-me-wk`: this week's reading and listening, a column a day stacked, and under them the
 *  books finished this year, the lines marked and the words kept. */
@Composable
private fun WeekCard(library: Library) {
    val days = remember(library.notesVersion) { sums(library, weekDays()) }
    val marks = remember(library.notesVersion, library.books) { library.books.filter { it.available }.sumOf { runCatching { library.core.marks(it.id).size }.getOrDefault(0) } }
    val words = remember(library.notesVersion) { runCatching { library.core.words().count { !it.known } }.getOrDefault(0) }
    val year = LocalDate.now().year
    val finished = library.books.count { b ->
        b.status == ReadingStatus.FINISHED && Instant.ofEpochMilli(b.finishedAt ?: b.openedAt ?: b.addedAt).atZone(ZoneId.systemDefault()).year == year
    }
    Column(
        Modifier.fillMaxWidth().shadow(2.dp, RoundedCornerShape(YY.s(16))).background(YY.c.card, RoundedCornerShape(YY.s(16)))
            .border(0.5.dp, YY.c.line, RoundedCornerShape(YY.s(16))).padding(horizontal = YY.s(14), vertical = YY.s(12)),
    ) {
        Row {
            Text(t("这周"), style = YY.font(10.5f), color = YY.c.t3, modifier = Modifier.weight(1f))
            Text(t("阅读统计"), style = YY.font(10.5f), color = YY.c.t2)
            Icon(Icons.chevronRight, null, tint = YY.c.t2, modifier = Modifier.size(YY.s(12)))
        }
        Row(Modifier.padding(top = YY.s(6)), horizontalArrangement = Arrangement.spacedBy(YY.s(20))) {
            PeriodTotal(t("读"), days.sumOf { it.read }, YY.tint.fill)
            PeriodTotal(t("听"), days.sumOf { it.listen }, YY.c.tint)
        }
        Bars(days, Modifier.padding(top = YY.s(10)).height(YY.s(70)))
        Box(Modifier.padding(top = YY.s(12)).fillMaxWidth().height(0.5.dp).background(YY.c.line))
        Row(Modifier.padding(top = YY.s(11)).fillMaxWidth()) {
            Tile("$finished", t("本"), t("今年读完"), Modifier.weight(1f))
            Box(Modifier.width(0.5.dp).height(YY.s(30)).background(YY.c.line))
            Tile("$marks", t("句"), t("划线"), Modifier.weight(1f))
            Box(Modifier.width(0.5.dp).height(YY.s(30)).background(YY.c.line))
            Tile("$words", t("个"), t("生词"), Modifier.weight(1f))
        }
    }
}

@Composable
private fun Tile(number: String, unit: String, label: String, modifier: Modifier) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(YY.s(2))) {
            Text(number, style = YY.font(15f, FontWeight.Bold), color = YY.c.t1)
            Text(unit, style = YY.font(10f, FontWeight.Medium), color = YY.c.t2, modifier = Modifier.padding(bottom = 2.dp))
        }
        Text(label, style = YY.font(10f), color = YY.c.t3)
    }
}

/** `.v-me-tt`: "■ 读 5 小时 12 分", the numbers big. */
@Composable
private fun PeriodTotal(label: String, seconds: Int, color: Color) {
    val m = seconds / 60
    val parts = when {
        m < 60 -> listOf(m to t("分"))
        m % 60 == 0 -> listOf(m / 60 to t("小时"))
        else -> listOf(m / 60 to t("小时"), m % 60 to t("分"))
    }
    Row(verticalAlignment = Alignment.Bottom) {
        Box(Modifier.padding(bottom = 5.dp, end = YY.s(3)).size(YY.s(7)).background(color, RoundedCornerShape(2.dp)))
        Text(label, style = YY.font(10.5f), color = YY.c.t2, modifier = Modifier.padding(bottom = 2.dp))
        for ((n, unit) in parts) {
            Text("$n", style = YY.font(19f, FontWeight.Bold), color = YY.c.t1, modifier = Modifier.padding(start = YY.s(4), end = YY.s(1)))
            Text(unit, style = YY.font(10.5f), color = YY.c.t2, modifier = Modifier.padding(bottom = 2.dp))
        }
    }
}

/** `.v-me-ch`: seven columns, listening stacked on reading; today's column wider and its label dark. */
@Composable
private fun Bars(days: List<DaySums>, modifier: Modifier) {
    val most = maxOf(1, days.maxOf { it.read + it.listen })
    val today = LocalDate.now()
    val names = listOf(t("一"), t("二"), t("三"), t("四"), t("五"), t("六"), t("日"))
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
        days.forEachIndexed { i, d ->
            val on = d.day == today
            Column(Modifier.weight(1f).fillMaxHeight(), horizontalAlignment = Alignment.CenterHorizontally) {
                Column(Modifier.weight(1f).width(YY.s(if (on) 12 else 8)), verticalArrangement = Arrangement.Bottom) {
                    if (d.listen > 0) Box(Modifier.fillMaxWidth().fillMaxHeight(d.listen.toFloat() / most).background(YY.c.tint, RoundedCornerShape(topStart = 2.5.dp, topEnd = 2.5.dp)))
                    if (d.read > 0) Box(Modifier.fillMaxWidth().fillMaxHeight(d.read.toFloat() / (most - d.listen).coerceAtLeast(1)).background(YY.tint.fill, RoundedCornerShape(if (d.listen > 0) 0.dp else 2.5.dp)))
                }
                Text(if (on) t("今天") else names[i], style = YY.font(10f, if (on) FontWeight.SemiBold else FontWeight.Normal), color = if (on) YY.c.t1 else YY.c.t3, modifier = Modifier.padding(top = YY.s(5)))
            }
        }
    }
}

// MARK: 阅读统计

@Composable
private fun Stats(library: Library) {
    var week by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(LocalDate.now()) }
    val days = remember(week) { sums(library, weekDays(week)) }
    YYPage {
        Column(
            Modifier.padding(top = YY.s(12)).fillMaxWidth().background(YY.c.card, RoundedCornerShape(YY.s(16))).padding(YY.s(14)),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(t("%@ – %@", days.first().day.toString(), days.last().day.toString()), style = YY.font(12f, FontWeight.Bold), color = YY.c.t1, modifier = Modifier.weight(1f))
                Icon(Icons.chevronLeft, t("往前"), tint = YY.c.t1, modifier = Modifier.size(28.dp).clickable { week = week.minusWeeks(1) })
                Icon(Icons.chevronRight, t("往后"), tint = if (week >= LocalDate.now()) YY.c.t3 else YY.c.t1, modifier = Modifier.size(28.dp).clickable(enabled = week < LocalDate.now()) { week = week.plusWeeks(1) })
            }
            Row(Modifier.padding(top = YY.s(6)), horizontalArrangement = Arrangement.spacedBy(YY.s(20))) {
                PeriodTotal(t("读"), days.sumOf { it.read }, YY.tint.fill)
                PeriodTotal(t("听"), days.sumOf { it.listen }, YY.c.tint)
            }
            Bars(days, Modifier.padding(top = YY.s(10)).height(YY.s(90)))
        }
        YYLabel(t("怎么算的"))
        YYNote(t("只在翻页、滚动或朗读的时候计时。") + t("一页停了 5 分钟没翻，或者锁屏又没在听，就停表。") + t("倍速按实际时间算：1.5× 听 1 小时，记 1 小时。"))
    }
}

// MARK: 外观

@Composable
private fun AppearancePage() {
    var mode by rememberPref(Appearance.KEY, Appearance.SYSTEM)
    var tintID by rememberPref("appearance.tint", YYTints.Default.id)
    YYPage {
        YYLabel(t("界面"))
        Row(horizontalArrangement = Arrangement.spacedBy(YY.s(10))) {
            for (m in listOf(Appearance.LIGHT, Appearance.DARK, Appearance.SYSTEM)) {
                val on = m == mode
                Column(Modifier.weight(1f).clickable { mode = m }, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(YY.s(7))) {
                    val bg = when (m) { Appearance.LIGHT -> Color(0xFFF6F5F3); Appearance.DARK -> Color(0xFF101112); else -> Color(0xFF85827F) }
                    Box(Modifier.fillMaxWidth().height(YY.s(72)).background(bg, RoundedCornerShape(YY.s(12))).border(if (on) 2.dp else 0.5.dp, if (on) YY.tint.accent else YY.c.line, RoundedCornerShape(YY.s(12))))
                    Text(modeTitle(m), style = YY.font(11f, if (on) FontWeight.SemiBold else FontWeight.Normal), color = if (on) YY.c.t1 else YY.c.t2)
                }
            }
        }
        YYLabel(t("主题色"))
        YYGroup {
            for (tint in YYTints.All) {
                row {
                    YYRow(t(tint.name), value = if (tint.id == YYTints.Default.id) t("默认") else t("你确认过的原样"), onClick = { tintID = tint.id }) {
                        Box(Modifier.size(YY.s(18)).background(tint.light.black, CircleShape))
                        Icon(Icons.check, null, tint = if (tint.id == tintID) YY.tint.accent else Color.Transparent, modifier = Modifier.size(YY.s(13)))
                    }
                }
            }
        }
        YYNote(t("书页的颜色在阅读页的 Aa 里换。书页上只有播放键跟着主题色，字、划线和纸色都不动。"))
    }
}

// MARK: 关于

@Composable
private fun About(push: (MePage) -> Unit) {
    val context = LocalContext.current
    YYPage {
        Column(Modifier.fillMaxWidth().padding(top = YY.s(24)), horizontalAlignment = Alignment.CenterHorizontally) {
            // `.v-me-logo`: 阅 on paper, the blue rule under it.
            Box(
                Modifier.size(YY.s(64)).shadow(8.dp, RoundedCornerShape(YY.s(15))).background(Color(0xFFFBFAF7), RoundedCornerShape(YY.s(15))),
                contentAlignment = Alignment.Center,
            ) {
                Text("阅", fontFamily = YY.serif, fontWeight = FontWeight.Bold, fontSize = YY.sp(30f), color = Color(0xFF1C1D20), modifier = Modifier.padding(bottom = YY.s(6)))
                Box(Modifier.align(Alignment.BottomCenter).padding(bottom = YY.s(13)).width(YY.s(24)).height(YY.s(2.5f)).background(Color(0xFF2B4C7E), CircleShape))
            }
            Text(t("语阅"), style = YY.font(17f, FontWeight.Bold), color = YY.c.t1, modifier = Modifier.padding(top = YY.s(10)))
            Text(t("版本 %@", "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})"), style = YY.font(10f), color = YY.c.t3)
            Text(t("免费，没有服务器，不收集任何数据。"), style = YY.font(12.5f, FontWeight.SemiBold), color = YY.c.t1, modifier = Modifier.padding(top = YY.s(22), bottom = YY.s(26)))
        }
        YYGroup {
            row { YYRow(t("开源许可"), Icons.list, chevron = true) { push(MePage.Licences) } }
            row { YYRow(t("隐私说明"), Icons.info, chevron = true) { push(MePage.Privacy) } }
            row {
                YYRow(t("反馈"), Icons.share, t("发邮件给开发者"), chevron = true) {
                    runCatching { context.startActivity(Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:yuyue.app@icloud.com"))) }
                }
            }
        }
    }
}

@Composable
private fun TextPage(text: String) {
    YYPage {
        Text(
            text, style = YY.font(11.5f).copy(lineHeight = YY.sp(19.5f)), color = YY.c.t1,
            modifier = Modifier.padding(top = YY.s(10)).fillMaxWidth().background(YY.c.card, RoundedCornerShape(YY.s(16))).padding(YY.s(14)),
        )
        Spacer(Modifier.height(20.dp))
    }
}

private val PRIVACY: String
    get() = t("语阅没有服务器，也不收集任何数据：没有账号、没有统计、没有广告。") + "\n\n" +
        t("书、进度、笔记和生词都存在这台设备上。打开同步时，它们只在你的设备和你自己选的网盘（WebDAV 或 Google Drive）之间传，语阅看不到。") + "\n\n" +
        t("书伴、云端声音和笔记导出只在你填了自己的 Key 时联网，提问、要读的句子或笔记直接发给你选的服务商；Key 只存在这台设备上，加密保存。")

private val LICENCES: String
    get() = t("语阅用到了这些开源项目，感谢它们的作者：") + "\n\n" +
        "UniFFI (MPL-2.0) · rusqlite / SQLite (MIT / Public Domain) · serde, serde_json, regex, encoding_rs, chardetng, zip, html5ever, roxmltree, ICU4X, blake3, percent-encoding, thiserror (MIT / Apache-2.0) · rars (MIT) · JNA (Apache-2.0) · AndroidX, Jetpack Compose, Media3 (Apache-2.0)" + "\n\n" +
        t("完整的许可文本随源代码一起发布。")
