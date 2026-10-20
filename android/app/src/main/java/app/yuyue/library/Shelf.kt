package app.yuyue.library

import app.yuyue.design.Prefs
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

val BookSummary.isComic: Boolean get() = format == BookFormat.COMIC

/** A comic has nothing to listen to; a PDF is read from the words on its pages. */
val BookSummary.canListen: Boolean get() = format != BookFormat.COMIC

/** 第 15 话 · 第 6 页: where a comic is up to. */
val BookSummary.comicPlace: String
    get() {
        if (episode == 0u) return t("还没看")
        return if (episodes > 1u) t("第 %u 话 · 第 %u 页", episode.toInt(), page.toInt()) else t("第 %u 页", page.toInt())
    }

/** The line under a cover: how far, or where it stands. */
val BookSummary.shelfNote: String
    get() {
        if (!available) return t("在别的设备上")
        if (isComic) {
            if (status == ReadingStatus.FINISHED) return t("看完")
            if (episode == 0u) return t("漫画 · 没看过")
            val strip = Prefs.string("comic.layout.$id") == "strip"
            if (episodes <= 1u) return if (strip) t("条漫 · %@", percent) else percent
            return if (strip) t("条漫 · 第 %u 话", episode.toInt()) else t("读到第 %u 话", episode.toInt())
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
        if (isComic) {
            if (status == ReadingStatus.FINISHED) return t("看完了")
            if (episode == 0u) return t("还没看")
            if (episodes > 1u) return if (episode >= episodes) t("最后一话") else t("还剩 %u 话", (episodes - episode).toInt())
        }
        return when {
            status == ReadingStatus.FINISHED -> t("读完了")
            status == ReadingStatus.WANT && progress == 0.0 -> t("还没读")
            else -> {
                val minutes = maxOf(1, (readMinutes.toDouble() * (1 - progress)).roundToInt())
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
}
