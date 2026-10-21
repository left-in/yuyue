package app.yuyue.reader

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.yuyue.design.Prefs
import app.yuyue.library.Library
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import uniffi.yuyue_core.BookDetail
import uniffi.yuyue_core.Bookmark
import uniffi.yuyue_core.Font
import uniffi.yuyue_core.LayoutMode
import uniffi.yuyue_core.Mark
import uniffi.yuyue_core.MarkStyle
import uniffi.yuyue_core.Paper
import uniffi.yuyue_core.Position
import uniffi.yuyue_core.ReaderSettings
import uniffi.yuyue_core.SearchHit
import uniffi.yuyue_core.SectionKind
import uniffi.yuyue_core.TocItem
import java.time.LocalDate
import kotlin.math.roundToInt
import uniffi.yuyue_core.TextPoint as CoreTextPoint

/** Text selected on the page, for the card over it. */
data class TextSelection(val section: Int, val start: TextPoint, val end: TextPoint, val text: String, val rect: TextRect?)

/** A highlight tapped on the page, for the card over it. */
data class OpenMark(val mark: Mark, val x: Double, val y: Double)

/** One open book: where the reader is, how the pages look, the notes in it (as `ReaderModel` on iPhone). */
class ReaderModel(val library: Library, val bookID: String, val pager: ReaderPager, val context: Context) : ReaderPager.Listener {
    val core = library.core
    val detail: BookDetail? = runCatching { core.book(bookID) }.getOrNull()
    var failure by mutableStateOf<String?>(null)
    var settings by mutableStateOf(ReaderSettings(Paper.PLAIN, LayoutMode.PAGINATED, null, 18.0, null, null, null, null, true))
        private set
    /** Whether this book keeps settings of its own (只用于这本书). */
    var ownSettings by mutableStateOf(false)
        private set
    var chromeShown by mutableStateOf(false)
    var tocShown by mutableStateOf(false)
    var settingsShown by mutableStateOf(false)
    var section by mutableIntStateOf(0)
        private set
    var page by mutableIntStateOf(0)
        private set
    var pageCount by mutableIntStateOf(1)
        private set
    /** The sentence the reader is at: the one read aloud, or the first on the page. */
    var sentence by mutableIntStateOf(0)
    var marks by mutableStateOf<List<Mark>>(emptyList())
        private set
    var bookmarks by mutableStateOf<List<Bookmark>>(emptyList())
        private set
    var selection by mutableStateOf<TextSelection?>(null)
    var openMark by mutableStateOf<OpenMark?>(null)
    var lastStyle by mutableStateOf(MarkStyle.YELLOW)
    /** 书内搜索. */
    var searchShown by mutableStateOf(false)
    var query by mutableStateOf("")
    var hits by mutableStateOf<List<SearchHit>>(emptyList())
        private set
    var hitIndex by mutableStateOf<Int?>(null)
        private set
    /** The undo note at the bottom of the page. */
    var toast by mutableStateOf<Library.Toast?>(null)
        private set
    /** 回到原处: where the reader was before jumping off, kept until a few pages are read. */
    var returnTo by mutableStateOf<Pair<Position, Int?>?>(null)
        private set
    /** The pull-down of 下拉加书签, 0 when not pulled. */
    var pull by mutableStateOf(0f)
    /** Reads the book aloud; null for a book without words to read. */
    val player: app.yuyue.speech.Player? = detail?.takeIf { it.summary.format != uniffi.yuyue_core.BookFormat.COMIC }?.let { app.yuyue.speech.Player(context, core, it) }
    var listenShown by mutableStateOf(false)
    var immersiveShown by mutableStateOf(false)
    var infoShown by mutableStateOf(false)
    var rulesShown by mutableStateOf(false)
    var txtShown by mutableStateOf(false)
    /** 外文原著: the word tapped, and its card. */
    var lookup by mutableStateOf<WordLookup?>(null)
    private var immersiveState = mutableStateOf(false)
    /** 沉浸阅读: only the words on the page. */
    var immersive: Boolean
        get() = immersiveState.value
        set(v) { immersiveState.value = v; applyImmersive() }
    /** 与书对话. */
    val companion = app.yuyue.companion.BookCompanion(this)
    var companionShown by mutableStateOf(false)
    /** Words handed to the companion (问). */
    var companionQuote by mutableStateOf<String?>(null)
    /** After a page is turned by hand the pages stop following the voice for a while. */
    private var followFrom = 0L

    /** Opening a book only shows where it was; the position is written once the reader moves. */
    private var opened = false
    private var saving: Job? = null
    private var saved: Position? = null
    private var searching: Job? = null
    private var toastJob: Job? = null
    private var turnsSinceJump = 0
    /** 计时: when time was last added, and when a page was last turned. */
    private var since = System.currentTimeMillis()
    private var lastTurn = System.currentTimeMillis()

    init {
        val own = runCatching { core.bookReaderSettings(bookID) }.getOrNull()
        var s = own ?: runCatching { core.readerSettings() }.getOrNull() ?: settings
        // 我的 › 墨水屏: a book with its own paper reads on e-ink too.
        if (Prefs.bool("eink.on", false)) s = s.copy(paper = Paper.EINK)
        settings = s
        ownSettings = own != null
        pager.listener = this
        pager.fontSize = s.fontSize
        pager.mode = s.mode
        pager.calm = s.paper == Paper.EINK
        Prefs.string(STYLE_KEY).let { saved -> MarkStyle.entries.firstOrNull { it.name == saved }?.let { lastStyle = it } }
        reloadNotes()
        // 我的 › 沉浸阅读 on: every book opens with only its words.
        immersive = ImmersivePrefs.always
        setUpForeign()
        player?.let { p ->
            p.onSentence = { spot, duration, elapsed, playing -> reading(spot, duration, elapsed, playing); setListening(playing) }
            p.onStop = { pager.clearInk(); setListening(false) }
            p.onSleep = { spot ->
                run { core.addBookmark(bookID, spot.section.toUInt(), spot.sentence.toUInt()) }
                show(Library.Toast(Library.Toast.Icon.Check, t("定时到了，停在这里"), t("加了一个书签")))
            }
        }
        val d = detail
        if (d == null) {
            failure = t("找不到这本书的文件")
        } else {
            val intent = library.takeIntent(bookID)
            val start = Position(d.start, 0u)
            val mine = runCatching { core.progress(bookID) }.getOrNull()
            val latest = runCatching { core.latestProgress(bookID) }.getOrNull()
            var position = if (intent == Library.OpenIntent.ListenFromStart) start else mine?.position ?: latest?.position ?: start
            if (intent is Library.OpenIntent.At) position = intent.position
            pager.open(position.section.toInt(), if (position.sentence == 0u) Target.Start else Target.Sentence(position.sentence.toInt()))
            if (intent == Library.OpenIntent.Listen || intent == Library.OpenIntent.ListenFromStart) player?.play(position)
            if (intent is Library.OpenIntent.Ask) ask(intent.question)
        }
    }

    /** What 沉浸阅读 changes on the page. 墨水屏 turns whole pages, never slides them. */
    fun applyImmersive() {
        pager.calm = (immersive && ImmersivePrefs.stillPages) || settings.paper == Paper.EINK
        pager.marksHidden = immersive && ImmersivePrefs.hidesMarks
    }

    /** Opens 书伴 with a question. */
    fun ask(question: String) {
        companionShown = true
        if (question.isNotBlank()) companion.ask(question, companionQuote)
    }

    // MARK: Reading aloud

    val isPlaying: Boolean get() = player?.state == app.yuyue.speech.Player.State.Playing || player?.state == app.yuyue.speech.Player.State.Loading

    private val following: Boolean get() = System.currentTimeMillis() >= followFrom

    /** Pauses; or reads on from what's on screen. Paused on a sentence still on the page, it carries on from there. */
    fun togglePlay() {
        val p = player ?: return
        when (p.state) {
            app.yuyue.speech.Player.State.Playing, app.yuyue.speech.Player.State.Loading -> p.pause()
            app.yuyue.speech.Player.State.Paused -> {
                followFrom = 0
                if (p.spot?.let(::isOnScreen) == true) p.resume() else pager.here()?.let { p.play(it) }
            }
            app.yuyue.speech.Player.State.Stopped -> {
                followFrom = 0
                pager.here()?.let { p.play(it) }
            }
        }
    }

    /** ‹ › in the capsule: a sentence while reading aloud, a page otherwise. */
    fun step(forward: Boolean) {
        val p = player
        if (p != null && p.spot != null) p.skip(forward) else turn(forward)
    }

    private fun isOnScreen(spot: app.yuyue.speech.Player.Spot): Boolean {
        val cur = pager.current ?: return false
        if (cur.section != spot.section) return false
        val layout = cur.layout ?: return false
        return settings.mode == LayoutMode.SCROLLED || layout.pageOf(spot.sentence) == cur.page
    }

    private fun setListening(playing: Boolean) {
        if (playing) { if (library.listening != bookID) library.listening = bookID }
        else if (library.listening == bookID) library.listening = null
    }

    private fun reading(spot: app.yuyue.speech.Player.Spot, durationMs: Double, elapsedMs: Double, playing: Boolean) {
        if (spot.section == section && sentence != spot.sentence) sentence = spot.sentence
        pager.setInk(spot.section, spot.sentence, durationMs, elapsedMs, playing)
        // Into the next chapter with the voice; within a section the reader says when the ink reaches another page.
        if (following && spot.section != pager.current?.section) pager.show(spot.section, Target.Sentence(spot.sentence, "third"))
    }

    val paper: Paper get() = settings.paper

    // MARK: Moving around

    fun turn(forward: Boolean) {
        turnedByHand(pager)
        pager.turn(forward)
    }

    fun go(item: TocItem) {
        leaving()
        turnedByHand(pager)
        pager.show(item.section.toInt(), item.anchor?.let { Target.Anchor(it) } ?: Target.Start)
    }

    fun jump(section: Int, sentence: Int) {
        leaving()
        lastTurn = System.currentTimeMillis()
        opened = true
        pager.show(section, Target.Sentence(sentence, "third"))
    }

    /** About to jump: the place to come back to, unless one is kept already. */
    fun leaving() {
        turnsSinceJump = 0
        if (returnTo != null || !opened) return
        val here = pager.here() ?: return
        returnTo = here to bookPage
    }

    /** 回到第 N 页. */
    fun goBack() {
        val back = returnTo?.first ?: return
        returnTo = null
        pager.show(back.section.toInt(), Target.Sentence(back.sentence.toInt(), "third"))
    }

    val chapterTitle: String? get() = detail?.let { chapterTitle(it, section) }

    // MARK: Notes

    fun reloadNotes() {
        marks = runCatching { core.marks(bookID) }.getOrDefault(emptyList())
        bookmarks = runCatching { core.bookmarks(bookID) }.getOrDefault(emptyList())
        pager.setMarks(marks)
        library.notesChanged()
    }

    /** Highlights the selection in `style` (the last one used when null). */
    fun mark(style: MarkStyle? = null, note: String? = null): Mark? {
        val sel = selection ?: return null
        val st = style ?: lastStyle
        remember(st)
        return try {
            val m = core.addMark(bookID, sel.section.toUInt(), CoreTextPoint(sel.start.s.toUInt(), sel.start.o.toUInt()), CoreTextPoint(sel.end.s.toUInt(), sel.end.o.toUInt()), sel.text.trim(), st, note)
            selection = null
            pager.call("yy.clearSelection()")
            reloadNotes()
            m
        } catch (e: Exception) {
            failure = Library.message(e)
            null
        }
    }

    fun setStyle(style: MarkStyle, mark: Mark) {
        remember(style)
        run { core.setMarkStyle(bookID, mark.id, style) }
        if (openMark?.mark?.id == mark.id) marks.firstOrNull { it.id == mark.id }?.let { openMark = openMark?.copy(mark = it) }
    }

    fun setNote(note: String?, mark: Mark) = run { core.setMarkNote(bookID, mark.id, note?.trim()?.ifEmpty { null }) }

    fun deleteMark(mark: Mark) {
        openMark = null
        run { core.deleteMark(bookID, mark.id) }
        show(Library.Toast(Library.Toast.Icon.Highlight, t("已删除划线"), if (mark.note == null) "“${mark.text.take(16)}”" else t("想法也一起删了"), danger = true) {
            run { core.restoreMark(bookID, mark.id) }
        })
    }

    private fun remember(style: MarkStyle) {
        lastStyle = style
        Prefs.set(STYLE_KEY, style.name)
    }

    fun copySelection() {
        val text = selection?.text ?: openMark?.mark?.text ?: return
        (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("", text))
        dismissCards()
        show(Library.Toast(Library.Toast.Icon.Check, t("已复制"), "“${text.take(16)}”"))
    }

    /** 从这读: reads aloud from the first selected sentence, or the highlight's. */
    fun readFrom(mark: Mark?) {
        val p = player ?: return
        val start = mark?.let { Position(it.section, it.start.sentence) } ?: selection?.let { Position(it.section.toUInt(), it.start.s.toUInt()) } ?: return
        dismissCards()
        followFrom = 0
        p.play(start)
    }

    fun dismissCards() {
        if (selection != null) pager.call("yy.clearSelection()")
        selection = null
        openMark = null
    }

    // MARK: Bookmarks

    /** The bookmark on the page showing, if any. */
    val bookmarkHere: Bookmark?
        get() {
            val layout = pager.current?.layout ?: return null
            return bookmarks.firstOrNull { it.section.toInt() == section && layout.pageOf(it.sentence.toInt()) == page }
        }

    fun toggleBookmark() {
        val here = bookmarkHere
        if (here != null) {
            run { core.deleteBookmark(bookID, here.id) }
            show(Library.Toast(Library.Toast.Icon.Delete, t("书签拿掉了"), if (here.text.isEmpty()) t("这一页") else "“${here.text.take(16)}”") {
                run { core.restoreBookmark(bookID, here.id) }
            })
        } else {
            val p = pager.here() ?: return
            run { core.addBookmark(bookID, p.section, p.sentence) }
            show(Library.Toast(Library.Toast.Icon.Check, t("加了书签"), estimatedPage(p.section.toInt(), p.sentence.toInt())?.let { t("第 %lld 页", it) } ?: ""))
        }
    }

    fun deleteBookmark(b: Bookmark) = run { core.deleteBookmark(bookID, b.id) }

    // MARK: Search

    /** Searches the book for `query`, a moment after the typing stops. */
    fun search() {
        searching?.cancel()
        val q = query.trim()
        if (q.isEmpty()) {
            hits = emptyList()
            hitIndex = null
            pager.setHits(null, null)
            return
        }
        searching = library.scope.launch {
            delay(180)
            val found = withContext(Dispatchers.IO) { runCatching { core.searchBook(bookID, q) }.getOrDefault(emptyList()) }
            hits = found
            val first = found.indexOfFirst { it.section.toInt() > section || (it.section.toInt() == section && it.sentence.toInt() >= sentence) }
            showHit(if (first >= 0) first else if (found.isEmpty()) null else 0)
        }
    }

    fun showHit(index: Int?) {
        hitIndex = index
        val hit = index?.let { hits.getOrNull(it) }
        pager.setHits(query.trim(), hit)
        if (hit != null) jump(hit.section.toInt(), hit.sentence.toInt())
    }

    fun nextHit(forward: Boolean) {
        if (hits.isEmpty()) return
        val i = hitIndex ?: if (forward) -1 else hits.size
        showHit((i + (if (forward) 1 else -1) + hits.size) % hits.size)
    }

    fun endSearch() {
        searching?.cancel()
        searchShown = false
        query = ""
        hits = emptyList()
        hitIndex = null
        pager.setHits(null, null)
    }

    // MARK: Settings

    fun update(change: (ReaderSettings) -> ReaderSettings) {
        val new = change(settings)
        if (new == settings) return
        settings = new
        try {
            if (ownSettings) core.setBookReaderSettings(bookID, new) else core.setReaderSettings(new)
        } catch (e: Exception) {
            failure = Library.message(e)
        }
        apply(new)
    }

    /** 只用于这本书: the book keeps its own settings from now on, or goes back to the shared ones. */
    fun setOwn(on: Boolean) {
        if (on == ownSettings) return
        ownSettings = on
        runCatching { core.setBookReaderSettings(bookID, if (on) settings else null) }
        if (!on) runCatching { core.readerSettings() }.getOrNull()?.takeIf { it != settings }?.let { settings = it; apply(it) }
    }

    private fun apply(s: ReaderSettings) {
        pager.fontSize = s.fontSize
        val modeChanged = pager.mode != s.mode
        pager.mode = s.mode
        applyImmersive()
        pager.apply(s.script(pager.geometry()))
        if (modeChanged) pager.reload()
    }

    // MARK: Where the reader is

    private val counted: List<Pair<Int, uniffi.yuyue_core.SectionSummary>>
        get() = detail?.sections?.withIndex()?.filter { it.value.linear && it.value.kind == SectionKind.TEXT }?.map { it.index to it.value } ?: emptyList()

    /** 0–1 through the main text at a sentence, as the core counts it. */
    fun fraction(section: Int, sentence: Int): Double {
        val all = counted
        val total = all.sumOf { it.second.units.toDouble() }
        if (total <= 0) return 0.0
        var before = 0.0
        for ((i, s) in all) {
            if (i < section) before += s.units.toDouble()
            else if (i == section) before += s.units.toDouble() * sentence / maxOf(1u, s.sentences).toDouble()
        }
        return minOf(1.0, before / total)
    }

    val bookFraction: Double get() = fraction(section, sentence)

    /** Sentences in the current section. */
    val sentenceCount: Int get() = detail?.sections?.getOrNull(section)?.sentences?.toInt() ?: 0

    /** Minutes to read a section at the core's pace (300 characters a minute). */
    fun minutes(section: Int): Int {
        val s = detail?.sections?.getOrNull(section) ?: return 0
        return maxOf(1, (s.units.toDouble() / 300).roundToInt())
    }

    val chapterMinutesLeft: Int
        get() {
            val n = maxOf(1, sentenceCount)
            return maxOf(1, (minutes(section).toDouble() * (n - sentence) / n).roundToInt())
        }

    /** The capsule's second line: `42% · 本章还剩 6 分钟`. */
    val capsuleNote: String get() = t("%lld%% · 本章还剩 %lld 分钟", (bookFraction * 100).roundToInt(), chapterMinutesLeft)

    /** The page in the whole book, guessed from how much text the current section puts on a page. */
    fun estimatedPage(section: Int, sentence: Int): Int? {
        val s = detail?.sections?.getOrNull(this.section) ?: return null
        if (s.units == 0u) return null
        val perPage = s.units.toDouble() / maxOf(1, pageCount)
        if (perPage <= 0) return null
        var before = counted.filter { it.first < section }.sumOf { it.second.units.toDouble() }
        detail.sections.getOrNull(section)?.let { before += it.units.toDouble() * sentence / maxOf(1u, it.sentences).toDouble() }
        return (before / perPage).toInt() + 1
    }

    val bookPage: Int?
        get() {
            val layout = pager.current?.layout
            if (layout != null && pager.current?.section == section) {
                val first = estimatedPage(section, 0) ?: 1
                return first + minOf(page, layout.pageCount - 1)
            }
            return estimatedPage(section, sentence)
        }

    /** "第三回 · 第 3 页". */
    fun place(section: Int, sentence: Int): String =
        listOfNotNull(detail?.let { chapterTitle(it, section) }, estimatedPage(section, sentence)?.let { t("第 %lld 页", it) }).joinToString(" · ")

    // MARK: Time

    /** Adds the time since the last tick to the section showing: reading while pages have been
     *  turned in the last five minutes. */
    fun tick() {
        val now = System.currentTimeMillis()
        val seconds = (now - since) / 1000
        since = now
        if (seconds <= 0 || seconds >= 3600) return
        if (now - lastTurn >= 300_000) return
        runCatching { core.addTime(bookID, section.toUInt(), seconds.toUInt(), 0u, LocalDate.now().toString()) }
    }

    // MARK: Progress

    private fun save(p: Position) {
        if (p == saved) return
        saved = p
        saving?.cancel()
        saving = library.scope.launch {
            delay(1000)
            saving = null
            write(p)
        }
    }

    fun flush() {
        val job = saving ?: return
        job.cancel()
        saving = null
        saved?.let(::write)
    }

    private fun write(p: Position) {
        try {
            core.saveProgress(bookID, p)
        } catch (e: Exception) {
            failure = Library.message(e)
        }
        library.reload()
    }

    fun close() {
        if (ImmersivePrefs.quiet) DoNotDisturb.set(context, false)
        tick()
        flush()
        player?.close()
        setListening(false)
        pager.close()
    }

    // MARK: Helpers

    fun show(t: Library.Toast) {
        toast = t
        toastJob?.cancel()
        toastJob = library.scope.launch {
            delay(Library.TOAST_MS)
            if (toast?.id == t.id) toast = null
        }
    }

    fun undoToast() {
        val t = toast ?: return
        toast = null
        t.undo?.invoke()
    }

    private inline fun run(work: () -> Unit) {
        try {
            work()
        } catch (e: Exception) {
            failure = Library.message(e)
        }
        reloadNotes()
    }

    // MARK: ReaderPager.Listener

    override fun moved(pager: ReaderPager) {
        val cur = pager.current ?: return
        val layout = cur.layout ?: return
        if (section != cur.section) tick()
        section = cur.section ?: 0
        page = cur.page
        pageCount = layout.pageCount
        val p = pager.here() ?: return
        if (opened) save(p) else { opened = true; saved = p }
        sentence = p.sentence.toInt()
    }

    override fun turnedByHand(pager: ReaderPager) {
        lastTurn = System.currentTimeMillis()
        followFrom = System.currentTimeMillis() + 8000
        chromeShown = false
        dismissCards()
        if (returnTo != null && ++turnsSinceJump >= 3) returnTo = null
    }

    override fun tapped(m: ReaderMessage) {
        if (selection != null || openMark != null) return dismissCards()
        if (lookup != null) return closeLookup()
        m.word?.takeIf { isForeign && m.link == null }?.let { w -> library.scope.launch { look(w) }; return }
        m.mark?.let { id -> marks.firstOrNull { it.id == id }?.let { openMark = OpenMark(it, m.x ?: 0.0, m.y ?: 0.0); return } }
        m.link?.let { link ->
            link.optString("target").takeIf { it.isNotEmpty() }?.let { return follow(it) }
            link.optString("external").takeIf { it.isNotEmpty() }?.let { url ->
                if (url.startsWith("http") || url.startsWith("mailto")) {
                    runCatching { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url)).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)) }
                }
                return
            }
        }
        val w = m.width ?: return
        val x = m.x ?: return
        // 点哪里翻页: the outer thirds turn, the middle shows the controls.
        when {
            settings.mode == LayoutMode.SCROLLED -> chromeShown = !chromeShown
            x < w * 0.3 -> turn(false)
            x > w * 0.7 -> turn(true)
            else -> chromeShown = !chromeShown
        }
    }

    private fun follow(target: String) {
        val parts = target.split('#', limit = 2)
        val s = parts[0].toIntOrNull() ?: return
        leaving()
        turnedByHand(pager)
        pager.show(s, if (parts.size > 1) Target.Anchor(parts[1], "third") else Target.Start)
    }

    override fun inkReached(page: Int) {
        if (following && isPlaying) pager.showPage(page, animated = true)
    }

    override fun selected(m: ReaderMessage) {
        val start = m.start
        val end = m.end
        val text = m.text
        selection = if (start != null && end != null && !text.isNullOrBlank()) TextSelection(section, start, end, text, m.rect) else null
        if (selection != null) openMark = null
    }

    override fun doubleTapped(m: ReaderMessage) {
        // 双击屏幕边缘进出沉浸, as on iPhone: the outer eighth on either side, where no words are.
        val view = pager.current?.webView ?: return
        val width = view.width / view.resources.displayMetrics.density
        val x = m.x ?: return
        if (width > 0 && (x < width * 0.12 || x > width * 0.88)) {
            chromeShown = false
            immersive = !immersive
        }
    }

    override fun sectionReady(page: SectionPage) {
        player?.spot?.takeIf { it.section == page.section && player.state != app.yuyue.speech.Player.State.Stopped }?.let {
            page.call("yy.setActive(${it.sentence}, {durationMs: 0, elapsedMs: 0, playing: false})")
        }
    }

    override fun pulled(distance: Float, released: Boolean) {
        if (released) {
            if (distance >= PULL_MARK) toggleBookmark()
            pull = 0f
        } else {
            pull = distance
        }
    }

    companion object {
        private const val STYLE_KEY = "reader.markStyle"
        /** How far to pull before letting go adds the bookmark, in px. */
        var PULL_MARK = 180f

        fun chapterTitle(d: BookDetail, section: Int): String? =
            d.toc.lastOrNull { it.section.toInt() <= section }?.title ?: d.sections.getOrNull(section)?.title
    }
}

/** The CSS name a style has in the reader (`::highlight(yy-yellow)`). */
val MarkStyle.css: String
    get() = when (this) {
        MarkStyle.YELLOW -> "yellow"
        MarkStyle.BLUE -> "blue"
        MarkStyle.PINK -> "pink"
        MarkStyle.WAVE -> "wave"
        MarkStyle.UNDERLINE -> "underline"
        MarkStyle.DOTTED -> "dotted"
    }

/** The reader's `applySettings` for these settings (contract §4). */
fun ReaderSettings.script(g: uniffi.yuyue_core.PageGeometry): JSONObject = JSONObject().apply {
    put("paper", when (paper) { Paper.PLAIN -> "plain"; Paper.DARK -> "dark"; Paper.KAMI -> "kami"; Paper.KAMI_NIGHT -> "kaminight"; Paper.EINK -> "eink" })
    put("mode", if (mode == LayoutMode.SCROLLED) "scrolled" else "paginated")
    put("fontSize", fontSize)
    put("lineHeight", lineHeight ?: JSONObject.NULL)
    put("paragraphSpacing", paragraphSpacing ?: JSONObject.NULL)
    put("justify", justify ?: JSONObject.NULL)
    put("indent", indent ?: JSONObject.NULL)
    put("compress", compress)
    put("font", when (font) { Font.SANS -> "sans"; Font.SERIF -> "serif"; Font.KAI -> "kai"; null -> JSONObject.NULL })
    put("margin", g.margin)
    put("top", g.top)
    put("bottom", g.bottom)
    put("motion", if (g.reducedMotion) "reduced" else "full")
}
