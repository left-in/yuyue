package app.yuyue.reader

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.animation.DecelerateInterpolator
import android.widget.FrameLayout
import app.yuyue.BuildConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import uniffi.yuyue_core.LayoutMode
import uniffi.yuyue_core.PageGeometry
import uniffi.yuyue_core.Paging
import uniffi.yuyue_core.Position
import uniffi.yuyue_core.YuyueCore
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.roundToInt

/**
 * Shows the book one section at a time and turns its pages (reader contract: native owns
 * everything that moves). The current section's neighbours are kept loaded on both sides, so
 * turning into the next chapter is as quick as turning a page — as on iPhone.
 *
 * Each section is a WebView laid out in pages side by side (`data-yy-paging="native"`). The
 * WebViews never scroll themselves: a drag moves one place along the whole strip of pages,
 * the current section's and its neighbours', and on letting go it settles on a page. Past a
 * section's last page the next section slides in under the same finger.
 */
@SuppressLint("ViewConstructor")
class ReaderPager(context: Context, private val core: YuyueCore, private val bookID: String) : FrameLayout(context) {
    interface Listener {
        /** The visible page changed, or the section was laid out again. */
        fun moved(pager: ReaderPager)
        /** The reader started turning pages themselves. */
        fun turnedByHand(pager: ReaderPager)
        fun tapped(m: ReaderMessage)
        fun inkReached(page: Int)
        fun selected(m: ReaderMessage)
        fun doubleTapped(m: ReaderMessage)
        /** 下拉加书签: how far the page is pulled down (px), and whether the finger let go. */
        fun pulled(distance: Float, released: Boolean)
        /** A section was laid out for the first time: what is drawn in it goes in now. */
        fun sectionReady(page: SectionPage)
    }

    var listener: Listener? = null
    var mode: LayoutMode = LayoutMode.PAGINATED
    /** Used for the line length, which decides the side margins. */
    var fontSize = 18.0
    /** Top and bottom space the page keeps clear of the system bars, in px. */
    var insetTop = 0
    var insetBottom = 0
    /** 墨水屏 and 沉浸 with still pages: pages switch at once, never slide. */
    var calm = false
    var background: Int = 0
        set(v) {
            field = v
            setBackgroundColor(v)
            (slots + spare).forEach { it.setBackground(v) }
        }

    private val scope: CoroutineScope = MainScope()
    private val slots = mutableListOf<SectionPage>()
    private val spare = mutableListOf<SectionPage>()
    var current: SectionPage? = null
        private set
    private var pendingOpen: Pair<Int, Target>? = null
    private var appliedGeometry: PageGeometry? = null

    /** The place along the strip, in pages of the current section: 0 is its first page,
     *  -1 the previous section's last, pageCount the next section's first. */
    private var position = 0f
    private var animator: ValueAnimator? = null

    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private val minFling = ViewConfiguration.get(context).scaledMinimumFlingVelocity
    private var downX = 0f
    private var downY = 0f
    private var startPosition = 0f
    private var dragging = false
    private var pulling = false
    private var velocity: VelocityTracker? = null

    // MARK: Geometry

    fun geometry(): PageGeometry {
        val density = resources.displayMetrics.density
        val width = width / density
        // About 34 characters to a line at most; wider pages get wider margins instead.
        val measure = fontSize * 34
        val margin = maxOf(if (width < 500) 24.0 else 40.0, (width - measure) / 2).roundToInt().toDouble()
        val top = (insetTop / density + 28).roundToInt().toDouble()
        val bottom = (insetBottom / density + 40).roundToInt().toDouble()
        return PageGeometry(Paging.NATIVE, margin, top, bottom, 1u, calm)
    }

    // MARK: Opening

    fun open(section: Int, target: Target) {
        if (width == 0) {
            pendingOpen = section to target
            return
        }
        pendingOpen = null
        val cur = current
        if (cur != null && cur.section == section && cur.isReady) {
            scope.launch {
                cur.go(target)
                position = cur.page.toFloat()
                render()
                listener?.moved(this@ReaderPager)
            }
            return
        }
        slots.toList().forEach(::recycle)
        val page = makePage()
        page.load(bookID, section, target)
        slots.clear()
        slots += page
        current = page
        position = 0f
        render()
        loadNeighbours()
    }

    /** Moves to a section and place, e.g. from 目录 or a link. */
    fun show(section: Int, target: Target) = open(section, target)

    /** The words changed underneath (替换规则): loads the sections again, at the same place. */
    fun reload() {
        val here = here() ?: return
        current = null
        open(here.section.toInt(), Target.Sentence(here.sentence.toInt()))
    }

    private fun previous(of: Int): Int? = runCatching { core.previousSection(bookID, of.toUInt(), false) }.getOrNull()?.toInt()
    private fun next(of: Int): Int? = runCatching { core.nextSection(bookID, of.toUInt(), false) }.getOrNull()?.toInt()

    /** Keeps the sections on either side of the current one loaded, and lets the others go. */
    private fun loadNeighbours() {
        val cur = current ?: return
        val section = cur.section ?: return
        val wanted = mutableListOf<SectionPage>()
        previous(section)?.let { wanted += pageFor(it, Target.End) }
        wanted += cur
        next(section)?.let { wanted += pageFor(it, Target.Start) }
        slots.filter { it !in wanted }.forEach(::recycle)
        slots.clear()
        slots += wanted
        render()
    }

    private fun pageFor(section: Int, target: Target): SectionPage {
        slots.firstOrNull { it.section == section }?.let { return it }
        val p = makePage()
        p.load(bookID, section, target)
        return p
    }

    private fun makePage(): SectionPage {
        val p = spare.removeLastOrNull() ?: SectionPage(context, core, ::geometry, ::received).also {
            it.setBackground(background)
            addView(it.webView, LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }
        p.webView.visibility = View.VISIBLE
        return p
    }

    private fun recycle(p: SectionPage) {
        if (p === current) current = null
        p.clear()
        p.webView.visibility = View.INVISIBLE
        spare += p
    }

    private val previousSlot: SectionPage? get() = current?.let { c -> slots.getOrNull(slots.indexOf(c) - 1) }
    private val nextSlot: SectionPage? get() = current?.let { c -> slots.getOrNull(slots.indexOf(c) + 1) }

    // MARK: Drawing the strip

    private fun pageWidthPx(p: SectionPage): Float {
        val css = p.layout?.pageWidth ?: 0.0
        return if (css > 0) (css * resources.displayMetrics.density).toFloat() else width.toFloat()
    }

    /** Puts every slot where `position` says. */
    private fun render() {
        val cur = current ?: return
        val w = width.toFloat()
        val n = (cur.layout?.pageCount ?: 1)
        val inside = position.coerceIn(0f, (n - 1).toFloat())
        cur.webView.scrollTo((inside * pageWidthPx(cur)).roundToInt(), 0)
        cur.webView.translationX = (inside - position) * w
        previousSlot?.let { prev ->
            val last = (prev.layout?.pageCount ?: 1) - 1
            prev.webView.scrollTo((last * pageWidthPx(prev)).roundToInt(), 0)
            prev.webView.translationX = (-1 - position) * w
        }
        nextSlot?.let { nx ->
            nx.webView.scrollTo(0, 0)
            nx.webView.translationX = (n - position) * w
        }
        for (s in slots) if (s !== cur && s !== previousSlot && s !== nextSlot) s.webView.translationX = 10f * w
    }

    // MARK: Turning

    /** One page on or back, as a tap on the side or a volume key does. */
    fun turn(forward: Boolean) {
        val cur = current ?: return
        val n = cur.layout?.pageCount ?: return
        val target = (cur.page + if (forward) 1 else -1)
        if (target >= n && nextSlot?.isReady != true) return
        if (target < 0 && previousSlot?.isReady != true) return
        listener?.turnedByHand(this)
        settle(target.toFloat(), animated = !calm)
    }

    /** Goes to a page of the current section, as the voice moves on. */
    fun showPage(page: Int, animated: Boolean) {
        val cur = current ?: return
        val n = cur.layout?.pageCount ?: return
        if (page !in 0 until n || page == cur.page) return
        settle(page.toFloat(), animated && !calm)
    }

    /** The ink line under `sentence` of `section` (contract §7); off when null. */
    fun setInk(section: Int, sentence: Int, durationMs: Double, elapsedMs: Double, playing: Boolean) {
        for (s in slots) {
            if (s.section == section) s.call("yy.setActive($sentence, {durationMs: $durationMs, elapsedMs: $elapsedMs, playing: $playing})")
            else s.call("yy.setActive(null)")
        }
    }

    fun clearInk() = callAll("yy.setActive(null)")

    /** Goes to page `p` of the current section (`-1` and `pageCount` cross into the neighbours). */
    private fun settle(to: Float, animated: Boolean) {
        animator?.cancel()
        if (!animated) {
            position = to
            landed()
            return
        }
        val from = position
        animator = ValueAnimator.ofFloat(from, to).apply {
            duration = (180 + 140 * minOf(1f, abs(to - from))).toLong()
            interpolator = DecelerateInterpolator(1.6f)
            addUpdateListener {
                position = it.animatedValue as Float
                render()
            }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: android.animation.Animator) {
                    if (animator === animation) landed()
                }
            })
            start()
        }
    }

    /** The strip has stopped on a page: cross into a neighbour when it went past an end. */
    private fun landed() {
        animator = null
        val cur = current ?: return
        val n = cur.layout?.pageCount ?: 1
        when {
            position >= n -> nextSlot?.let { nx ->
                current = nx
                nx.page = 0
                position = 0f
                loadNeighbours()
            }
            position < 0 -> previousSlot?.let { prev ->
                current = prev
                val last = (prev.layout?.pageCount ?: 1) - 1
                prev.page = last
                position = last.toFloat()
                loadNeighbours()
            }
            else -> {
                cur.page = position.roundToInt()
                position = cur.page.toFloat()
            }
        }
        render()
        listener?.moved(this)
    }

    // MARK: Touch

    override fun onInterceptTouchEvent(e: MotionEvent): Boolean {
        if (mode != LayoutMode.PAGINATED) return false
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = e.x
                downY = e.y
                dragging = false
                pulling = false
                velocity?.recycle()
                velocity = VelocityTracker.obtain().apply { addMovement(e) }
                // A page still settling is caught by the finger, as a scroll view would.
                if (animator != null) {
                    animator?.cancel()
                    animator = null
                    startDrag()
                    return true
                }
            }
            MotionEvent.ACTION_MOVE -> {
                velocity?.addMovement(e)
                val dx = e.x - downX
                val dy = e.y - downY
                if (current?.webView?.selecting == true) return false
                if (abs(dx) > touchSlop && abs(dx) > abs(dy) * 1.2f) {
                    startDrag()
                    downX = e.x
                    return true
                }
                if (dy > touchSlop * 2 && dy > abs(dx) * 2) {
                    pulling = true
                    return true
                }
            }
        }
        return false
    }

    private fun startDrag() {
        dragging = true
        startPosition = position
        parent?.requestDisallowInterceptTouchEvent(true)
        listener?.turnedByHand(this)
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        velocity?.addMovement(e)
        when (e.actionMasked) {
            MotionEvent.ACTION_MOVE -> {
                if (pulling) {
                    listener?.pulled(maxOf(0f, e.y - downY), false)
                } else if (dragging) {
                    val cur = current ?: return true
                    val n = cur.layout?.pageCount ?: 1
                    var p = startPosition - (e.x - downX) / width
                    // Past the book's first or last page the strip gives only a little.
                    val low = if (previousSlot?.isReady == true) -1f else 0f
                    val high = if (nextSlot?.isReady == true) n.toFloat() else (n - 1).toFloat()
                    if (p < low) p = low - (low - p) / 3
                    if (p > high) p = high + (p - high) / 3
                    position = p
                    render()
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (pulling) {
                    listener?.pulled(maxOf(0f, e.y - downY), true)
                    pulling = false
                } else if (dragging) {
                    dragging = false
                    velocity?.computeCurrentVelocity(1000)
                    val v = velocity?.xVelocity ?: 0f
                    val cur = current
                    val n = cur?.layout?.pageCount ?: 1
                    val base = floor(startPosition + 0.0001f)
                    var target = when {
                        v < -minFling * 4 -> floor(position) + 1
                        v > minFling * 4 -> floor(position + 0.9999f) - 1
                        else -> position.roundToInt().toFloat()
                    }
                    // One page per swipe, like a book.
                    target = target.coerceIn(base - 1, base + 1)
                    val low = if (previousSlot?.isReady == true) -1f else 0f
                    val high = if (nextSlot?.isReady == true) n.toFloat() else (n - 1).toFloat()
                    settle(target.coerceIn(low, high), animated = !calm)
                }
                velocity?.recycle()
                velocity = null
            }
        }
        return true
    }

    // MARK: Messages

    private fun received(page: SectionPage, m: ReaderMessage) {
        if (BuildConfig.DEBUG && m.type != "log") android.util.Log.d("yuyue-reader", "${m.type} section=${m.section} page.section=${page.section} pages=${m.pageCount}")
        if (m.section != null && m.section != page.section) return
        when (m.type) {
            "log" -> android.util.Log.d("yuyue-reader", m.json.optString("level") + " " + m.json.optString("message"))
            "ready", "layout" -> {
                if (m.type == "ready") {
                    // First: it rebuilds the section's boxes; the rest are drawn on them.
                    if (bubbles) sendBubbles(page)
                    sendMarks(page)
                    sendHits(page)
                    sendSource(page)
                    sendForeign(page)
                    listener?.sectionReady(page)
                }
                page.take(m)
                scope.launch {
                    val shown = page.settle()
                    if (page === current) {
                        position = page.page.toFloat()
                        if (shown || m.type == "layout") listener?.moved(this@ReaderPager)
                    }
                    render()
                }
            }
            "tap" -> if (page === current && !dragging) listener?.tapped(m)
            "doubleTap" -> if (page === current) listener?.doubleTapped(m)
            "selection" -> if (page === current) {
                page.webView.selecting = m.text != null
                listener?.selected(m)
            }
            "activePage" -> if (page === current) m.page?.let { listener?.inkReached(it) }
            "scroll" -> if (page === current) {
                scrolledTo = m.sentence
                listener?.moved(this)
            }
        }
    }

    /** In scrolled mode, the first sentence in view (from `scroll`). */
    private var scrolledTo: Int? = null

    // MARK: Where the reader is

    /** The section and sentence standing for what is on screen. */
    fun here(): Position? {
        val cur = current ?: return null
        val section = cur.section ?: return null
        val layout = cur.layout ?: return null
        val sentence = if (mode == LayoutMode.SCROLLED) scrolledTo ?: 0 else layout.firstSentence(cur.page)
        return Position(section.toUInt(), sentence.toUInt())
    }

    // MARK: 气泡模式

    /** The book's dialogue as bubbles. */
    var bubbles = false
        set(v) { if (v != field) { field = v; slots.forEach(::sendBubbles) } }

    fun bubblesChanged() {
        if (bubbles) slots.forEach(::sendBubbles)
    }

    private fun sendBubbles(page: SectionPage) {
        val section = page.section ?: return
        if (!bubbles) return page.call("yy.setBubbles(null)")
        val list = org.json.JSONArray()
        for (l in runCatching { core.sectionBubbles(bookID, section.toUInt()) }.getOrDefault(emptyList())) {
            list.put(org.json.JSONObject().put("first", l.first.toInt()).put("last", l.last.toInt()).put("start", l.start.toInt()).put("end", l.end.toInt())
                .put("who", l.who ?: org.json.JSONObject.NULL).put("avatar", l.avatar).put("color", l.color).put("right", l.right))
        }
        page.call("yy.setBubbles($list)")
    }

    // MARK: Drawn in the text

    private var marks: List<uniffi.yuyue_core.Mark> = emptyList()
    private var hits: Pair<String, uniffi.yuyue_core.SearchHit?>? = null
    /** 沉浸阅读 can hide the highlights. */
    var marksHidden = false
        set(v) { field = v; slots.forEach(::sendMarks) }

    fun setMarks(list: List<uniffi.yuyue_core.Mark>) {
        marks = list
        slots.forEach(::sendMarks)
    }

    /** Marks where `query` turns up; `current` in the solid colour. null clears. */
    fun setHits(query: String?, current: uniffi.yuyue_core.SearchHit?) {
        hits = query?.let { it to current }
        slots.forEach(::sendHits)
    }

    private fun sendMarks(page: SectionPage) {
        val section = page.section ?: return
        val list = org.json.JSONArray()
        if (!marksHidden) for (m in marks) if (m.section.toInt() == section) {
            list.put(org.json.JSONObject().put("id", m.id)
                .put("start", org.json.JSONObject().put("s", m.start.sentence.toInt()).put("o", m.start.offset.toInt()))
                .put("end", org.json.JSONObject().put("s", m.end.sentence.toInt()).put("o", m.end.offset.toInt()))
                .put("style", m.style.css).put("note", m.note != null))
        }
        page.call("yy.setMarks($list)")
    }

    /** 书伴's 出处: one sentence washed in the accent until something else is pointed at. */
    private var source: Position? = null

    fun setSource(p: Position?) {
        source = p
        slots.forEach(::sendSource)
    }

    private fun sendSource(page: SectionPage) {
        val s = source
        if (s == null || page.section != s.section.toInt()) return page.call("yy.setSource(null)")
        page.call("yy.setSource(${s.sentence})")
    }

    private fun sendHits(page: SectionPage) {
        val h = hits
        if (h == null || page.section == null) return page.call("yy.setHits(null, null)")
        val c = h.second?.takeIf { it.section.toInt() == page.section }?.let { "{s: ${it.sentence}, nth: ${it.nth}}" } ?: "null"
        page.call("yy.setHits(${org.json.JSONObject.quote(h.first)}, $c)")
    }

    // MARK: 外文原著

    /** Taps on words look them up (点词). */
    var lookup = false
        set(v) { if (v != field) { field = v; slots.forEach(::sendForeign) } }
    /** 生词: dotted wherever they turn up. */
    private var vocab: List<String> = emptyList()
    /** The word being looked up. */
    private var looking: Triple<Int, TextPoint, TextPoint>? = null
    /** 难词注释: the harder words of a section and their meanings, from the core. */
    var glosser: ((Int) -> List<Pair<String, String>>)? = null
    private val glossed = mutableMapOf<Int, List<Pair<String, String>>>()
    /** 沉浸阅读 can hide 难词注释 too. */
    var glossesHidden = false
        set(value) {
            if (field == value) return
            field = value
            slots.forEach(::sendGlosses)
        }

    fun refreshGlosses() {
        if (glosser == null) return
        glossed.clear()
        slots.forEach(::sendGlosses)
    }

    fun setVocab(words: List<String>) {
        if (words == vocab) return
        vocab = words
        for (p in slots) if (p.section != null) p.call("yy.setVocab(${org.json.JSONArray(words)})")
    }

    fun setLooking(section: Int?, start: TextPoint?, end: TextPoint?) {
        looking = if (section != null && start != null && end != null) Triple(section, start, end) else null
        slots.forEach(::sendLooking)
    }

    private fun sendForeign(page: SectionPage) {
        if (page.section == null) return
        page.call("yy.setLookup($lookup)")
        if (vocab.isNotEmpty()) page.call("yy.setVocab(${org.json.JSONArray(vocab)})")
        sendGlosses(page)
        sendLooking(page)
    }

    private fun sendGlosses(page: SectionPage) {
        val section = page.section ?: return
        val g = glosser ?: return
        if (glossesHidden) return page.call("yy.setGlosses(null)")
        val list = glossed.getOrPut(section) { g(section) }
        page.call("yy.setGlosses(${org.json.JSONArray(list.map { org.json.JSONObject().put("form", it.first).put("gloss", it.second) })})")
    }

    private fun sendLooking(page: SectionPage) {
        val l = looking
        if (l == null || page.section != l.first) return page.call("yy.setLooking(null, null)")
        page.call("yy.setLooking(${l.second.json()}, ${l.third.json()})")
    }

    /** Hands JavaScript to the current section's reader. */
    fun call(expression: String) = current?.call(expression)

    /** Hands JavaScript to every loaded section (settings, marks hidden). */
    fun callAll(expression: String) = slots.forEach { it.call(expression) }

    /** Reader settings changed: every loaded section lays out again. */
    fun apply(settings: org.json.JSONObject) = callAll("yy.applySettings(${settings})")

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        pendingOpen?.let { (s, t) -> post { open(s, t) } }
        val g = geometry()
        if (appliedGeometry != null && g != appliedGeometry) {
            apply(org.json.JSONObject().put("margin", g.margin).put("top", g.top).put("bottom", g.bottom))
        }
        appliedGeometry = g
        render()
    }

    fun close() {
        animator?.cancel()
        scope.cancel()
        (slots + spare).forEach { it.webView.destroy() }
        slots.clear()
        spare.clear()
    }
}
