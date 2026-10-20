package app.yuyue.pdf

import android.content.Context
import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.LruCache
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.Icons
import app.yuyue.design.Prefs
import app.yuyue.design.YY
import app.yuyue.library.Library
import app.yuyue.reader.VolumeKeys
import app.yuyue.speech.Player
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import uniffi.yuyue_core.Position
import uniffi.yuyue_core.pageSentences
import java.io.File
import java.time.LocalDate
import kotlin.math.roundToInt

/** A PDF open for reading (FEATURES §3.5), as on Apple: shown as it is printed; where the reader
 *  is, is a page (section 0, the page standing where a book has its sentence). Its words, where
 *  the system can read them (Android 15 on), are cut into sentences by the core and read aloud
 *  page by page. */
class PdfModel(private val library: Library, val bookID: String, private val context: Context) {
    enum class Layout(val key: String) {
        Scroll("scroll"), Single("single");
        val title: String get() = when (this) { Scroll -> t("连续滚动"); Single -> t("单页") }
    }

    private val core = library.core
    val detail = runCatching { core.book(bookID) }.getOrNull()
    val title: String = detail?.summary?.title ?: ""
    private var fd: ParcelFileDescriptor? = null
    private var renderer: PdfRenderer? = null
    private val lock = Mutex()
    var pageCount = 0
        private set
    /** Each page's width over height. */
    private var aspects = DoubleArray(0)
    var page by mutableIntStateOf(0)
        private set
    var layout by mutableStateOf(Layout.entries.firstOrNull { it.key == Prefs.string("pdf.layout.$bookID") } ?: Layout.Scroll)
        private set
    var night by mutableStateOf(Prefs.bool("pdf.night.$bookID", false))
        private set
    var failure by mutableStateOf<String?>(null)
    /** Pages turned to in view by the voice or the slider; the view moves there. */
    var target by mutableStateOf<Int?>(null)
    private val sentenceCache = mutableMapOf<Int, List<String>>()
    private var saving: Job? = null
    private var since = System.currentTimeMillis()
    private var lastTurn = System.currentTimeMillis()

    /** The page text the system can give: from Android 15. */
    val canListen = Build.VERSION.SDK_INT >= 35
    val player: Player? = detail?.takeIf { canListen }?.let {
        Player(context, core, it, Player.Script(
            sentences = { p -> sentences(p) },
            next = { p -> if (p + 1 < pageCount) p + 1 else null },
            previous = { p -> if (p > 0) p - 1 else null },
            language = { p -> language(p) },
            title = { p -> t("第 %lld 页", p + 1) },
        ))
    }

    init {
        val file = runCatching { core.originalFile(bookID) }.getOrNull()?.let(::File)
        try {
            fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            renderer = PdfRenderer(fd!!).also { r ->
                pageCount = r.pageCount
                aspects = DoubleArray(r.pageCount) { i -> r.openPage(i).use { p -> p.width.toDouble() / maxOf(1, p.height) } }
            }
        } catch (e: Exception) {
            failure = t("这个 PDF 读不出来")
        }
        var position = runCatching { core.progress(bookID) }.getOrNull()?.position ?: runCatching { core.latestProgress(bookID) }.getOrNull()?.position
        (library.takeIntent(bookID) as? Library.OpenIntent.At)?.let { position = it.position }
        page = (position?.sentence?.toInt() ?: 0).coerceIn(0, maxOf(0, pageCount - 1))
        player?.onSentence = { spot, _, _, _ -> if (spot.section != page) { page = spot.section; target = spot.section } }
        player?.onStop = { if (library.listening == bookID) library.listening = null }
    }

    fun aspect(i: Int): Double = aspects.getOrElse(i) { 0.7 }

    fun changeLayout(l: Layout) { layout = l; Prefs.set("pdf.layout.$bookID", l.key) }
    fun changeNight(on: Boolean) { night = on; Prefs.set("pdf.night.$bookID", on) }

    /** A page drawn `width` pixels wide, on white. */
    suspend fun render(i: Int, width: Int): Bitmap? = withContext(Dispatchers.IO) {
        val key = "$bookID#$i#$width"
        cache.get(key)?.let { return@withContext it }
        lock.withLock {
            val r = renderer ?: return@withContext null
            r.openPage(i).use { p ->
                val h = (width / aspect(i)).roundToInt().coerceIn(1, 8000)
                val b = Bitmap.createBitmap(width, h, Bitmap.Config.ARGB_8888)
                b.eraseColor(android.graphics.Color.WHITE)
                p.render(b, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                cache.put(key, b)
                b
            }
        }
    }

    private fun sentences(p: Int): List<String> = sentenceCache.getOrPut(p) {
        if (Build.VERSION.SDK_INT < 35) return@getOrPut emptyList()
        val text = kotlinx.coroutines.runBlocking {
            lock.withLock { renderer?.openPage(p)?.use { page -> page.textContents.joinToString("\n") { it.text } } ?: "" }
        }
        val out = if (text.isBlank()) emptyList() else runCatching { pageSentences(text).map { it.text } }.getOrDefault(emptyList())
        if (app.yuyue.BuildConfig.DEBUG) android.util.Log.d("yuyue-pdf", "page $p: ${text.length} chars, ${out.size} sentences")
        out
    }

    private var guessed: String? = null

    /** The book's language, or else the one its words are in: Chinese when they are mostly Han characters. */
    private fun language(p: Int): String {
        detail?.summary?.language?.takeIf { it.isNotEmpty() && it != "und" }?.let { return it }
        guessed?.let { return it }
        val sample = (p until minOf(pageCount, p + 3)).flatMap { sentences(it) }.joinToString(" ")
        val han = sample.count { Character.UnicodeScript.of(it.code) == Character.UnicodeScript.HAN }
        val letters = sample.count { it.isLetter() }
        return (if (letters > 0 && han * 3 >= letters) "zh-Hans" else "en").also { guessed = it }
    }

    fun seen(p: Int) {
        if (p == page) return
        tick()
        lastTurn = System.currentTimeMillis()
        page = p
        save()
    }

    fun go(p: Int) {
        val q = p.coerceIn(0, maxOf(0, pageCount - 1))
        seen(q)
        target = q
    }

    val isPlaying: Boolean get() = player?.state == Player.State.Playing || player?.state == Player.State.Loading

    fun togglePlay() {
        val p = player ?: return
        when (p.state) {
            Player.State.Playing, Player.State.Loading -> p.pause()
            Player.State.Paused -> if (p.spot?.section == page) p.resume() else p.play(Position(page.toUInt(), 0u))
            Player.State.Stopped -> { library.listening = bookID; p.play(Position(page.toUInt(), 0u)) }
        }
        if (isPlaying) library.listening = bookID
    }

    private fun save() {
        saving?.cancel()
        val pos = Position(0u, page.toUInt())
        saving = library.scope.launch {
            delay(1000)
            saving = null
            runCatching { core.saveProgress(bookID, pos) }
            library.reload()
        }
    }

    private fun tick() {
        val now = System.currentTimeMillis()
        val seconds = (now - since) / 1000
        since = now
        if (seconds <= 0 || seconds >= 3600) return
        val listening = isPlaying
        if (!listening && now - lastTurn >= 300_000) return
        runCatching { core.addTime(bookID, 0u, if (listening) 0u else seconds.toUInt(), if (listening) seconds.toUInt() else 0u, LocalDate.now().toString()) }
    }

    fun close() {
        tick()
        saving?.cancel()
        runCatching { core.saveProgress(bookID, Position(0u, page.toUInt())) }
        player?.close()
        if (library.listening == bookID) library.listening = null
        runCatching { renderer?.close(); fd?.close() }
        library.reload()
    }

    companion object {
        private val cache = object : LruCache<String, Bitmap>((Runtime.getRuntime().maxMemory() / 6).toInt()) {
            override fun sizeOf(key: String, value: Bitmap) = value.byteCount
        }
    }
}

/** A PDF on the phone, as on iPhone: the pages edge to edge, scrolled down or turned one at a
 *  time; a tap brings the bars — 关闭, the title, the page and its slider, 朗读, 显示. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PdfScreen(library: Library, bookID: String, close: () -> Unit) {
    val context = LocalContext.current
    val model = remember(bookID) { PdfModel(library, bookID, context) }
    var chrome by remember { mutableStateOf(true) }
    DisposableEffect(model) {
        VolumeKeys.handler = { forward -> if (!model.isPlaying) { model.go(model.page + if (forward) 1 else -1); true } else false }
        onDispose { VolumeKeys.handler = null; model.close() }
    }
    BackHandler { close() }
    val width = context.resources.displayMetrics.widthPixels
    val bg = if (model.night) Color(0xFF1F1F1F) else Color(0xFFEBEBEB)

    Box(Modifier.fillMaxSize().background(bg).pointerInput(Unit) { detectTapGestures(onTap = { chrome = !chrome }) }) {
        when (model.layout) {
            PdfModel.Layout.Scroll -> {
                val state = rememberLazyListState(initialFirstVisibleItemIndex = model.page)
                LaunchedEffect(state) { snapshotFlow { state.firstVisibleItemIndex }.collect { model.seen(it) } }
                LaunchedEffect(model.target) { model.target?.let { state.animateScrollToItem(it); model.target = null } }
                LazyColumn(state = state, modifier = Modifier.fillMaxSize(), contentPadding = PaddingValues(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(model.pageCount) { i -> Page(model, i, width) }
                }
            }
            PdfModel.Layout.Single -> {
                val state = rememberPagerState(initialPage = model.page) { model.pageCount }
                LaunchedEffect(state) { snapshotFlow { state.currentPage }.collect { model.seen(it) } }
                LaunchedEffect(model.target) { model.target?.let { state.animateScrollToPage(it); model.target = null } }
                HorizontalPager(state, Modifier.fillMaxSize()) { i ->
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Page(model, i, width) }
                }
            }
        }
        AnimatedVisibility(chrome, enter = fadeIn(), exit = fadeOut()) { Bars(model, close) }
    }
    model.player?.failure?.let { message ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { model.player.failure = null }, containerColor = YY.c.card,
            title = { Text(t("朗读出错了"), color = YY.c.t1) }, text = { Text(message, color = YY.c.t2) },
            confirmButton = { androidx.compose.material3.TextButton({ model.player.failure = null }) { Text(t("好"), color = YY.tint.accent) } },
        )
    }
    model.failure?.let { message ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { model.failure = null; close() }, containerColor = YY.c.card,
            title = { Text(t("出错了"), color = YY.c.t1) }, text = { Text(message, color = YY.c.t2) },
            confirmButton = { androidx.compose.material3.TextButton({ model.failure = null; close() }) { Text(t("好"), color = YY.tint.accent) } },
        )
    }
}

/** 夜间: the page's colours turned round, so white paper reads dark. */
private val invert = ColorMatrix(floatArrayOf(-1f, 0f, 0f, 0f, 255f, 0f, -1f, 0f, 0f, 255f, 0f, 0f, -1f, 0f, 255f, 0f, 0f, 0f, 1f, 0f))

@Composable
private fun Page(model: PdfModel, i: Int, width: Int) {
    var bitmap by remember(i, width) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(i, width) { bitmap = model.render(i, width) }
    val b = bitmap
    val m = Modifier.fillMaxWidth().aspectRatio(model.aspect(i).toFloat())
    if (b != null) Image(b.asImageBitmap(), t("第 %lld 页", i + 1), m.background(Color.White), contentScale = ContentScale.FillWidth, colorFilter = if (model.night) ColorFilter.colorMatrix(invert) else null)
    else Box(m.background(if (model.night) Color(0xFF2A2A2A) else Color.White))
}

@Composable
private fun Bars(model: PdfModel, close: () -> Unit) {
    var showMenu by remember { mutableStateOf(false) }
    var sliding by remember { mutableStateOf<Float?>(null) }
    Box(Modifier.fillMaxSize()) {
        Row(
            Modifier.align(Alignment.TopCenter).fillMaxWidth().background(YY.c.card.copy(alpha = 0.96f)).windowInsetsPadding(WindowInsets.statusBars).padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.close, t("关闭"), tint = YY.c.t1, modifier = Modifier.size(44.dp).clickable(onClick = close).padding(12.dp))
            Text(model.title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1, maxLines = 1, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            Box {
                Icon(Icons.textSize, t("显示"), tint = YY.c.t1, modifier = Modifier.size(44.dp).clickable { showMenu = true }.padding(12.dp))
                DropdownMenu(showMenu, { showMenu = false }, containerColor = YY.c.card) {
                    for (l in PdfModel.Layout.entries) DropdownMenuItem(
                        text = { Text(l.title, color = YY.c.t1) },
                        trailingIcon = { if (l == model.layout) Icon(Icons.check, null, tint = YY.tint.accent) },
                        onClick = { model.changeLayout(l); showMenu = false },
                    )
                    DropdownMenuItem(
                        text = { Text(t("夜间"), color = YY.c.t1) },
                        trailingIcon = { if (model.night) Icon(Icons.check, null, tint = YY.tint.accent) },
                        onClick = { model.changeNight(!model.night); showMenu = false },
                    )
                }
            }
        }
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(YY.c.card.copy(alpha = 0.96f)).windowInsetsPadding(WindowInsets.navigationBars).padding(horizontal = 16.dp, vertical = 6.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(t("第 %lld / %lld 页", ((sliding?.roundToInt() ?: model.page) + 1), model.pageCount), fontSize = 13.sp, color = YY.c.t1, modifier = Modifier.weight(1f))
                if (model.player != null) {
                    Tool(if (model.isPlaying) Icons.pause else Icons.play, if (model.isPlaying) t("暂停") else t("朗读")) { model.togglePlay() }
                    if (model.player.spot != null) {
                        Tool(Icons.previous, t("上一句")) { model.player.skip(false) }
                        Tool(Icons.next, t("下一句")) { model.player.skip(true) }
                    }
                }
            }
            if (model.pageCount > 1) Slider(
                sliding ?: model.page.toFloat(), { sliding = it }, valueRange = 0f..(model.pageCount - 1).toFloat(),
                onValueChangeFinished = { sliding?.let { model.go(it.roundToInt()) }; sliding = null },
                colors = SliderDefaults.colors(thumbColor = YY.c.card, activeTrackColor = YY.tint.fill, inactiveTrackColor = YY.c.line),
            )
            if (!model.canListen) Text(t("这台手机的系统读不出 PDF 里的字，Android 15 起才能朗读 PDF"), fontSize = 11.sp, color = YY.c.t3, modifier = Modifier.padding(bottom = 4.dp))
        }
    }
}

@Composable
private fun Tool(icon: ImageVector, label: String, onClick: () -> Unit) {
    Icon(icon, label, tint = YY.c.t1, modifier = Modifier.size(44.dp).clickable(onClick = onClick).padding(11.dp))
}
