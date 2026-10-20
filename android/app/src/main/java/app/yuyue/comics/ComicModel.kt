package app.yuyue.comics

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.util.LruCache
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.exifinterface.media.ExifInterface
import app.yuyue.design.Prefs
import app.yuyue.library.Library
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.yuyue_core.Position
import java.time.LocalDate

/** 漫画 (FEATURES §3.6), as on Apple: the pages of a comic, where the reader is, and how this
 *  comic is read — one page, two side by side, or a strip scrolled down; right to left or left
 *  to right. Each comic keeps its own way of reading. */
class ComicModel(private val library: Library, val bookID: String, wide: Boolean) {
    enum class Layout(val key: String) {
        Single("single"), Double("double"), Strip("strip");
        val title: String get() = when (this) { Single -> t("单页"); Double -> t("双页"); Strip -> t("条漫") }
    }

    class Episode(val id: Int, val section: Int, val title: String, val pages: List<String>)

    private val core = library.core
    val title: String
    val episodes: List<Episode>
    var episode by mutableIntStateOf(0)
        private set
    var page by mutableIntStateOf(0)
        private set
    var layout by mutableStateOf(Layout.Single)
        private set
    var rightToLeft by mutableStateOf(true)
        private set
    var failure by mutableStateOf<String?>(null)
    /** 竖屏时拆开跨页: one page at a time, taller than wide, a wide scan shown half by half. */
    var splitWide = false
        set(v) { if (v != field) { field = v; half = 0 } }
    var half by mutableIntStateOf(0)
        private set

    private val spreadCache = mutableMapOf<Int, List<List<Int>>>()
    private val aspects = mutableMapOf<String, Double>()
    private var saving: Job? = null
    private var since = System.currentTimeMillis()
    private var lastTurn = System.currentTimeMillis()

    init {
        val detail = runCatching { core.book(bookID) }.getOrNull()
        title = detail?.summary?.title ?: ""
        episodes = (detail?.sections ?: emptyList()).withIndex().filter { it.value.pages > 0u }.mapIndexed { n, (i, s) ->
            Episode(n, i, s.title ?: "", runCatching { core.comicPages(bookID, i.toUInt()) }.getOrDefault(emptyList()))
        }
        layout = Layout.entries.firstOrNull { it.key == Prefs.string("comic.layout.$bookID") } ?: if (wide) Layout.Double else Layout.Single
        rightToLeft = Prefs.bool("comic.rtl.$bookID", true)
        if (detail == null) failure = t("打不开这部漫画")
        var position = runCatching { core.progress(bookID) }.getOrNull()?.position ?: runCatching { core.latestProgress(bookID) }.getOrNull()?.position
        (library.takeIntent(bookID) as? Library.OpenIntent.At)?.let { position = it.position }
        position?.let { p ->
            val e = episodes.indexOfFirst { it.section == p.section.toInt() }
            if (e >= 0) {
                episode = e
                page = minOf(p.sentence.toInt(), maxOf(0, episodes[e].pages.size - 1))
            }
        }
    }

    fun changeLayout(l: Layout) {
        layout = l
        Prefs.set("comic.layout.$bookID", l.key)
        if (l == Layout.Double) spreads(episode).firstOrNull { page in it }?.first()?.let { page = it }
    }

    fun changeDirection(rtl: Boolean) {
        rightToLeft = rtl
        Prefs.set("comic.rtl.$bookID", rtl)
    }

    val current: Episode? get() = episodes.getOrNull(episode)

    /** 第 15 话, or the folder's own name when it says more. */
    fun name(e: Episode): String = e.title.ifEmpty { if (episodes.size > 1) t("第 %lld 话", e.id + 1) else title }

    // MARK: Pages and spreads

    /** A picture's width over height, from its header (turned by its EXIF orientation). */
    fun aspect(path: String): Double = aspects.getOrPut(path) {
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, o)
        if (o.outWidth <= 0 || o.outHeight <= 0) return@getOrPut 2.0 / 3
        val turned = runCatching { ExifInterface(path).rotationDegrees % 180 != 0 }.getOrDefault(false)
        if (turned) o.outHeight.toDouble() / o.outWidth else o.outWidth.toDouble() / o.outHeight
    }

    fun isWide(path: String) = aspect(path) > 1.05

    /** The episode's pages two by two: the first alone (the cover), a wide picture alone, the rest in pairs. */
    fun spreads(e: Int): List<List<Int>> = spreadCache.getOrPut(e) {
        val pages = episodes[e].pages
        val out = mutableListOf<List<Int>>()
        var i = 0
        while (i < pages.size) {
            if (i == 0 || isWide(pages[i]) || i + 1 >= pages.size || isWide(pages[i + 1])) {
                out += listOf(i); i += 1
            } else {
                out += listOf(i, i + 1); i += 2
            }
        }
        out
    }

    /** The pages on screen now. */
    val shown: List<Int>
        get() {
            if (current == null) return emptyList()
            return if (layout == Layout.Double) spreads(episode).firstOrNull { page in it } ?: listOf(page) else listOf(page)
        }

    /** 第 6–7 / 32 页. */
    val pageLabel: String
        get() {
            val e = current ?: return ""
            val s = shown.map { it + 1 }
            return t("第 %@ / %lld 页", if (s.size > 1) "${s[0]}–${s[1]}" else "${s.firstOrNull() ?: 1}", e.pages.size)
        }

    /** The page on screen is a spread being shown half by half. */
    val splitting: Boolean
        get() {
            val e = current ?: return false
            return layout == Layout.Single && splitWide && page in e.pages.indices && isWide(e.pages[page])
        }

    // MARK: Moving

    fun next() {
        val e = current ?: return
        if (splitting && half == 0) { half = 1; return }
        val last = shown.lastOrNull() ?: page
        when {
            last + 1 < e.pages.size -> go(episode, last + 1)
            episode + 1 < episodes.size -> go(episode + 1, 0)
        }
    }

    fun previous() {
        if (splitting && half == 1) { half = 0; return }
        val first = shown.firstOrNull() ?: page
        when {
            first > 0 -> go(episode, if (layout == Layout.Double) spreads(episode).lastOrNull { it.first() < first }?.first() ?: 0 else first - 1)
            episode > 0 -> {
                val e = episode - 1
                go(e, if (layout == Layout.Double) spreads(e).lastOrNull()?.first() ?: 0 else episodes[e].pages.size - 1)
            }
            else -> return
        }
        // Coming back onto a spread, the half read last.
        if (splitting) half = 1
    }

    fun go(e: Int, p: Int) {
        if (e !in episodes.indices) return
        tick()
        lastTurn = System.currentTimeMillis()
        half = 0
        episode = e
        page = p.coerceIn(0, maxOf(0, episodes[e].pages.size - 1))
        if (layout == Layout.Double) spreads(e).firstOrNull { page in it }?.first()?.let { page = it }
        save()
    }

    /** From the strip: the page at the top of the screen, as the reader scrolls. */
    fun scrolled(e: Int, p: Int) {
        if ((e == episode && p == page) || e !in episodes.indices) return
        if (e != episode) tick()
        lastTurn = System.currentTimeMillis()
        episode = e
        page = p
        save()
    }

    /** Pictures worth decoding before they are needed: the next few, and the one before. */
    val upcoming: List<String>
        get() {
            val e = current ?: return emptyList()
            val ahead = Prefs.int("comic.preload", 5)
            val from = (shown.lastOrNull() ?: page) + 1
            val out = e.pages.drop(from).take(ahead).toMutableList()
            if (out.size < ahead) episodes.getOrNull(episode + 1)?.let { out += it.pages.take(ahead - out.size) }
            shown.firstOrNull()?.takeIf { it > 0 }?.let { out += e.pages[it - 1] }
            return out
        }

    // MARK: Progress

    private fun save() {
        saving?.cancel()
        val p = Position((current?.section ?: 0).toUInt(), page.toUInt())
        saving = library.scope.launch {
            delay(1000)
            write(p)
        }
    }

    private fun write(p: Position) {
        saving = null
        try {
            core.saveProgress(bookID, p)
        } catch (e: Exception) {
            failure = Library.message(e)
        }
        library.reload()
    }

    /** Time spent looking at pages, for 读了多久. */
    private fun tick() {
        val now = System.currentTimeMillis()
        val seconds = (now - since) / 1000
        since = now
        val section = current?.section ?: return
        if (seconds <= 0 || seconds >= 3600 || now - lastTurn >= 180_000) return
        runCatching { core.addTime(bookID, section.toUInt(), seconds.toUInt(), 0u, LocalDate.now().toString()) }
    }

    fun close() {
        tick()
        if (saving != null) {
            saving?.cancel()
            write(Position((current?.section ?: 0).toUInt(), page.toUInt()))
        }
    }
}

/** Decoded pages, made no bigger than they are shown, kept while memory allows. */
object ComicImages {
    private val cache = object : LruCache<String, Bitmap>((Runtime.getRuntime().maxMemory() / 6).toInt()) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }

    fun cached(path: String, pixels: Int, crop: Boolean): Bitmap? = cache.get("$path#$pixels${if (crop) "c" else ""}")

    /** `crop` trims the white margin of a scanned page, the same share from every side, so the
     *  page keeps its shape and only the drawing grows. */
    suspend fun image(path: String, pixels: Int, crop: Boolean): Bitmap? = withContext(Dispatchers.IO) {
        val key = "$path#$pixels${if (crop) "c" else ""}"
        cache.get(key)?.let { return@withContext it }
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, o)
        if (o.outWidth <= 0) return@withContext null
        var sample = 1
        while (maxOf(o.outWidth, o.outHeight) / (sample * 2) >= pixels) sample *= 2
        var b = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return@withContext null
        val degrees = runCatching { ExifInterface(path).rotationDegrees }.getOrDefault(0)
        if (degrees != 0) b = Bitmap.createBitmap(b, 0, 0, b.width, b.height, android.graphics.Matrix().apply { postRotate(degrees.toFloat()) }, true)
        if (crop) b = trimmed(b)
        cache.put(key, b)
        b
    }

    /** The page without its white border: the least blank run of the four sides, taken off all round. Never more than a fifth. */
    private fun trimmed(image: Bitmap): Bitmap {
        val w = 160
        val h = maxOf(1, (image.height.toDouble() / image.width * 160).toInt())
        val small = Bitmap.createScaledBitmap(image, w, h, true)
        val px = IntArray(w * h)
        small.getPixels(px, 0, w, 0, 0, w, h)
        fun grey(i: Int): Int { val c = px[i]; return (Color.red(c) * 30 + Color.green(c) * 59 + Color.blue(c) * 11) / 100 }
        fun blank(count: Int, at: (Int) -> Int): Boolean = (0 until count).count { at(it) < 225 }.toDouble() / count < 0.01
        fun run(n: Int, isBlank: (Int) -> Boolean): Int { var k = 0; while (k < n / 5 && isBlank(k)) k++; return k }
        val top = run(h) { y -> blank(w) { grey(y * w + it) } }
        val bottom = run(h) { y -> blank(w) { grey((h - 1 - y) * w + it) } }
        val left = run(w) { x -> blank(h) { grey(it * w + x) } }
        val right = run(w) { x -> blank(h) { grey(it * w + w - 1 - x) } }
        val share = minOf(minOf(top, bottom).toDouble() / h, minOf(left, right).toDouble() / w)
        val cut = maxOf(0.0, share - 0.006)
        if (cut <= 0.01) return image
        val dx = (image.width * cut).toInt()
        val dy = (image.height * cut).toInt()
        return Bitmap.createBitmap(image, dx, dy, image.width - 2 * dx, image.height - 2 * dy)
    }
}
