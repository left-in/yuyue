package app.yuyue.library

import androidx.compose.material.icons.Icons.Rounded
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.FormatQuote
import androidx.compose.material.icons.rounded.Headphones
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.LightMode
import androidx.compose.material.icons.rounded.LocalCafe
import androidx.compose.material.icons.rounded.Replay
import androidx.compose.material.icons.rounded.Schedule
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.ui.graphics.vector.ImageVector
import app.yuyue.t
import uniffi.yuyue_core.BookFormat
import uniffi.yuyue_core.BookSummary
import uniffi.yuyue_core.ReadingStatus
import kotlin.math.roundToInt

/** What the shelf shows: everything, one reading status or one collection. */
sealed interface ShelfFilter {
    data object All : ShelfFilter
    data class Status(val status: ReadingStatus) : ShelfFilter
    data class Collection(val id: String) : ShelfFilter
}

val ReadingStatus.title: String
    get() = when (this) {
        ReadingStatus.READING -> t("在读")
        ReadingStatus.WANT -> t("想读")
        ReadingStatus.FINISHED -> t("读完")
    }

val BookSummary.author: String? get() = authors.firstOrNull()

/** "42%", just started still reads as started. */
val BookSummary.percent: String get() = "${maxOf(1, (progress * 100).roundToInt())}%"

/** The line under a cover: how far, or where it stands. */
val BookSummary.shelfNote: String
    get() {
        if (!available) return t("在别的设备上")
        if (format == uniffi.yuyue_core.BookFormat.AUDIO) return when {
            status == ReadingStatus.FINISHED -> t("有声 · 听完")
            progress > 0 -> t("有声 · %@", percent)
            else -> t("有声 · %@", app.yuyue.shelf.length(listenMinutes.toDouble() * 60).replace(Regex(" \\d+ 分$"), ""))
        }
        return when (status) {
            ReadingStatus.FINISHED -> t("读完")
            ReadingStatus.WANT -> t("想读")
            ReadingStatus.READING -> if (progress > 0) percent else t("刚开始")
        }
    }

/** 还剩 4 小时 20 分 · 还没读 · 读完了 */
val BookSummary.remaining: String
    get() {
        val audio = format == uniffi.yuyue_core.BookFormat.AUDIO
        return when {
            status == ReadingStatus.FINISHED -> if (audio) t("听完了") else t("读完了")
            status == ReadingStatus.WANT && progress == 0.0 -> if (audio) t("还没听") else t("还没读")
            else -> {
                val minutes = maxOf(1, ((if (audio) listenMinutes else readMinutes).toDouble() * (1 - progress)).roundToInt())
                val h = minutes / 60
                val m = minutes % 60
                when {
                    h == 0 -> t("还剩 %lld 分", m)
                    m == 0 -> t("还剩 %lld 小时", h)
                    else -> t("还剩 %lld 小时 %lld 分", h, m)
                }
            }
        }
    }

enum class ShelfSort(val key: String) {
    Recent("recent"), Added("added"), Title("title"), Author("author");

    val title: String
        get() = when (this) {
            Recent -> t("最近读过")
            Added -> t("加入时间")
            Title -> t("书名")
            Author -> t("作者")
        }

    fun sorted(books: List<BookSummary>): List<BookSummary> {
        val collator = java.text.Collator.getInstance()
        return when (this) {
            Recent -> books
            Added -> books.sortedByDescending { it.addedAt }
            Title -> books.sortedWith { a, b -> collator.compare(a.title, b.title) }
            Author -> books.sortedWith { a, b -> collator.compare(a.author ?: "", b.author ?: "") }
        }
    }

    companion object {
        fun of(key: String) = entries.firstOrNull { it.key == key } ?: Recent
    }
}

/** The icon in front of a collection: guessed from its name, the same words as on Apple. */
object CollectionIcon {
    private val guesses: List<Pair<List<String>, String>> = listOf(
        listOf("睡", "夜", "晚", "sleep", "night", "bed") to "moon",
        listOf("科幻", "宇宙", "星", "sci-fi", "space", "star") to "sparkle",
        listOf("听", "通勤", "路上", "listen", "commute", "audio") to "headphones",
        listOf("英文", "原著", "外文", "日文", "english") to "globe",
        listOf("周末", "咖啡", "闲", "weekend", "coffee") to "cup.and.saucer",
        listOf("推理", "悬疑", "侦探", "mystery", "detective", "crime") to "key",
        listOf("诗", "词", "poem", "poetry") to "quote.opening",
        listOf("孩子", "儿童", "童", "kid", "child") to "sun.max",
        listOf("重读", "再读", "reread") to "arrow.trianglehead.2.clockwise",
        listOf("top", "榜", "最爱", "喜欢", "favorite", "love") to "heart",
        listOf("历史", "史", "history") to "clock",
        listOf("科普", "科学", "science") to "eye",
        listOf("写", "作家", "鲁迅", "writer", "writing") to "pencil",
    )

    fun guess(name: String): String? {
        val lower = name.lowercase()
        return guesses.firstOrNull { (keys, _) -> keys.any { lower.contains(it) } }?.second
    }

    /** The icon a collection shows: the one picked, or the one its name brings. The names are
     *  Apple's symbol names, kept the same so a pick follows the collection to every device. */
    fun of(c: uniffi.yuyue_core.BookCollection): ImageVector =
        vector(c.icon ?: guess(c.name))

    /** 换图标: the same icons a name can bring, each with what it's for. */
    val choices: List<Pair<String, String>> = listOf(
        "books.vertical" to "书", "moon" to "睡前", "headphones" to "听", "sparkle" to "科幻", "globe" to "外文",
        "cup.and.saucer" to "闲读", "key" to "推理", "quote.opening" to "诗词", "sun.max" to "孩子",
        "arrow.trianglehead.2.clockwise" to "重读", "heart" to "最爱", "clock" to "历史", "eye" to "科普", "pencil" to "写作",
    )

    fun vector(symbol: String?): ImageVector = when (symbol) {
        "moon" -> Rounded.Bedtime
        "headphones" -> Rounded.Headphones
        "sparkle" -> Rounded.AutoAwesome
        "globe" -> Rounded.Language
        "cup.and.saucer" -> Rounded.LocalCafe
        "key" -> Rounded.Key
        "quote.opening" -> Rounded.FormatQuote
        "sun.max" -> Rounded.LightMode
        "arrow.trianglehead.2.clockwise" -> Rounded.Replay
        "heart" -> Rounded.FavoriteBorder
        "clock" -> Rounded.Schedule
        "eye" -> Rounded.Visibility
        "pencil" -> Rounded.Edit
        else -> app.yuyue.design.Icons.collection
    }
}
