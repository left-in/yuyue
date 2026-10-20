package app.yuyue.reader

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import uniffi.yuyue_core.PageGeometry
import uniffi.yuyue_core.Served
import uniffi.yuyue_core.YuyueCore
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileInputStream
import kotlin.coroutines.resume

/** A place in the text: sentence and UTF-16 offset (reader contract §8). */
data class TextPoint(val s: Int, val o: Int) {
    fun json() = JSONObject().put("s", s).put("o", o)
}

data class TextRect(val x: Double, val y: Double, val width: Double, val height: Double)

/** A message from the reader script (docs/dev/reader-contract.md §5). */
class ReaderMessage(val json: JSONObject) {
    val type: String = json.optString("type")
    val section: Int? = json.optIntOrNull("section")
    val pageCount: Int? = json.optIntOrNull("pageCount")
    val pageWidth: Double? = json.optDoubleOrNull("pageWidth")
    val sentence: Int? = json.optIntOrNull("sentence")
    val page: Int? = json.optIntOrNull("page")
    val progress: Double? = json.optDoubleOrNull("progress")
    val x: Double? = json.optDoubleOrNull("x")
    val y: Double? = json.optDoubleOrNull("y")
    val width: Double? = json.optDoubleOrNull("width")
    val height: Double? = json.optDoubleOrNull("height")
    val mark: String? = json.optStringOrNull("mark")
    val text: String? = json.optStringOrNull("text")
    val start: TextPoint? = json.optJSONObject("start")?.let { TextPoint(it.optInt("s"), it.optInt("o")) }
    val end: TextPoint? = json.optJSONObject("end")?.let { TextPoint(it.optInt("s"), it.optInt("o")) }
    val rect: TextRect? = json.optJSONObject("rect")?.rect()
    val link: JSONObject? = json.optJSONObject("link")
    val word: JSONObject? = json.optJSONObject("word")
    val sentencePages: List<Int> = json.optJSONArray("sentencePages").ints()
    val pageFirstSentence: List<Int> = json.optJSONArray("pageFirstSentence").ints()

    companion object {
        fun JSONObject.optIntOrNull(k: String): Int? = if (has(k) && !isNull(k)) optInt(k) else null
        fun JSONObject.optDoubleOrNull(k: String): Double? = if (has(k) && !isNull(k)) optDouble(k) else null
        fun JSONObject.optStringOrNull(k: String): String? = if (has(k) && !isNull(k)) optString(k) else null
        fun JSONObject.rect() = TextRect(optDouble("x"), optDouble("y"), optDouble("width"), optDouble("height"))
        fun JSONArray?.ints(): List<Int> = this?.let { a -> List(a.length()) { a.optInt(it) } } ?: emptyList()
    }
}

/** Where the pages of a laid-out section fall (from `ready` / `layout`). */
data class SectionLayout(val pageCount: Int, val pageWidth: Double, val sentencePages: List<Int>, val pageFirstSentence: List<Int>) {
    fun pageOf(sentence: Int): Int = sentencePages.getOrElse(sentence) { 0 }

    /** The sentence that stands for a page: the first one that starts on it (as on Apple). */
    fun firstSentence(page: Int): Int {
        var p = minOf(page, pageFirstSentence.size - 1)
        while (p >= 0 && pageFirstSentence[p] < 0) p--
        if (p < 0) return 0
        val first = pageFirstSentence[p]
        var s = first
        while (s in sentencePages.indices && sentencePages[s] <= p) {
            if (sentencePages[s] == p) return s
            s++
        }
        return first
    }

    companion object {
        fun of(m: ReaderMessage): SectionLayout? {
            val count = m.pageCount ?: return null
            return SectionLayout(maxOf(1, count), m.pageWidth ?: 0.0, m.sentencePages, m.pageFirstSentence)
        }
    }
}

/** Where a newly loaded section should open. */
sealed interface Target {
    data object Start : Target
    data object End : Target
    data class Page(val page: Int) : Target
    data class Sentence(val sentence: Int, val align: String = "top") : Target
    data class Anchor(val id: String, val align: String = "top") : Target
}

/** One section of the book in its own WebView, shown by the pager (as `SectionPage` on Apple).
 *  The document is served by the core at the reader contract's origin. */
@SuppressLint("SetJavaScriptEnabled", "ViewConstructor")
class SectionPage(context: Context, private val core: YuyueCore, private val geometry: () -> PageGeometry, private val received: (SectionPage, ReaderMessage) -> Unit) {
    val webView = ReaderWebView(context)
    var section: Int? = null
        private set
    var layout: SectionLayout? = null
        private set
    /** The page showing, as far as native knows. */
    var page = 0
    private var target: Target? = null
    var generation = 0
        private set
    /** Called when a newly loaded section has been laid out and positioned. */
    var onReady: ((SectionPage) -> Unit)? = null

    init {
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = false
            allowFileAccess = false
            allowContentAccess = false
            setSupportZoom(false)
            builtInZoomControls = false
            displayZoomControls = false
            mediaPlaybackRequiresUserGesture = false
            cacheMode = WebSettings.LOAD_NO_CACHE
            textZoom = 100
        }
        webView.isHorizontalScrollBarEnabled = false
        webView.isVerticalScrollBarEnabled = false
        webView.overScrollMode = WebView.OVER_SCROLL_NEVER
        webView.setBackgroundColor(Color.TRANSPARENT)
        webView.addJavascriptInterface(Bridge(), "yyNative")
        webView.webViewClient = Client()
        webView.webChromeClient = object : android.webkit.WebChromeClient() {
            override fun onConsoleMessage(m: android.webkit.ConsoleMessage): Boolean {
                android.util.Log.d("yuyue-reader", "${m.messageLevel()} ${m.sourceId()}:${m.lineNumber()} ${m.message()}")
                return true
            }
        }
    }

    fun setBackground(color: Int) = webView.setBackgroundColor(color)

    fun load(bookID: String, section: Int, target: Target) {
        generation++
        this.section = section
        this.target = target
        layout = null
        page = 0
        webView.alpha = 0f
        webView.loadUrl("$ORIGIN/book/$bookID/s/$section.html?g=$generation")
    }

    /** Forget the section, so the view can be reused. */
    fun clear() {
        generation++
        section = null
        layout = null
        target = null
        webView.stopLoading()
        webView.loadUrl("about:blank")
    }

    /** Takes the pages a `ready` or `layout` message describes, as it arrives. */
    fun take(m: ReaderMessage) {
        if (m.type != "ready" && m.type != "layout") return
        layout = SectionLayout.of(m) ?: return
    }

    val isReady: Boolean get() = layout != null && target == null

    /** After `take`: a newly loaded section goes to its target and shows itself (returns true);
     *  one laid out again learns which page the reader kept in view. */
    suspend fun settle(): Boolean {
        val layout = layout ?: return false
        val g = generation
        val t = target
        if (t != null) {
            target = null
            go(t)
            if (g != generation) return false
            webView.alpha = 1f
            onReady?.invoke(this)
            return true
        }
        (ask("yy.currentPage()") as? Number)?.toInt()?.let { if (g == generation) page = minOf(it, layout.pageCount - 1) }
        return false
    }

    /** Puts the page in view at once: the pager animates by moving the views, never the reader. */
    suspend fun go(t: Target) {
        val layout = layout ?: run { target = t; return }
        val g = generation
        val last = layout.pageCount - 1
        val landed = when (t) {
            Target.Start -> ask("(yy.scrollToPage(0, false), 0)")
            Target.End -> ask("(yy.scrollToPage($last, false), $last)")
            is Target.Page -> { val p = t.page.coerceIn(0, last); ask("(yy.scrollToPage($p, false), $p)") }
            is Target.Sentence -> ask("yy.scrollToSentence(${t.sentence}, false, {align: '${t.align}'})")
            is Target.Anchor -> ask("yy.scrollToAnchor(${JSONObject.quote(t.id)}, false, {align: '${t.align}'})")
        }
        val p = (landed as? Number)?.toInt() ?: return
        if (p >= 0 && g == generation) page = minOf(p, last)
    }

    /** Runs `expression` with `window.yy`. */
    fun call(expression: String) {
        webView.evaluateJavascript("if (window.yy) { $expression; }", null)
    }

    /** Like `call`, for calls whose answer matters: a number, string, boolean, or JSON. */
    suspend fun ask(expression: String): Any? = suspendCancellableCoroutine { cont ->
        webView.evaluateJavascript("(function(){ return window.yy ? ($expression) : null; })()") { raw ->
            val value = runCatching { JSONTokener(raw ?: "null").nextValue() }.getOrNull()
            cont.resume(if (value == JSONObject.NULL) null else value)
        }
    }

    private inner class Bridge {
        @JavascriptInterface
        fun postMessage(body: String) {
            val json = runCatching { JSONObject(body) }.getOrNull() ?: return
            webView.post { received(this@SectionPage, ReaderMessage(json)) }
        }
    }

    private inner class Client : WebViewClient() {
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            val url = request.url
            if (url.host != HOST) return blocked()
            val path = url.encodedPath ?: return notFound()
            if (path.startsWith("/app/")) {
                val name = path.removePrefix("/app/")
                if (name.contains("..")) return notFound()
                return runCatching {
                    WebResourceResponse(if (name.endsWith(".css")) "text/css" else "text/javascript", "utf-8", view.context.assets.open(name))
                }.getOrElse { notFound() }
            }
            return when (val served = runCatching { core.serve(path, geometry()) }.getOrElse { Served.NotFound }) {
                is Served.Html -> WebResourceResponse("text/html", "utf-8", ByteArrayInputStream(served.body.toByteArray())).noStore()
                is Served.File -> {
                    val f = File(served.path)
                    if (f.isFile) WebResourceResponse(served.mime.substringBefore(';'), null, FileInputStream(f)) else notFound()
                }
                Served.NotFound -> notFound()
            }
        }

        /** Links never navigate the page: the reader posts them as taps. */
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = request.url.host != HOST
    }

    companion object {
        const val HOST = "appassets.androidplatform.net"
        const val ORIGIN = "https://$HOST"

        private fun notFound() = WebResourceResponse("text/plain", "utf-8", 404, "Not Found", mapOf("Cache-Control" to "no-store"), ByteArrayInputStream(ByteArray(0)))

        /** Nothing in a book needs to reach the network. */
        private fun blocked() = WebResourceResponse("text/plain", "utf-8", 403, "Forbidden", emptyMap(), ByteArrayInputStream(ByteArray(0)))

        private fun WebResourceResponse.noStore() = apply { responseHeaders = mapOf("Cache-Control" to "no-store") }
    }
}

/** The WebView of one section. Its own scrolling is off: the pager moves it. */
class ReaderWebView(context: Context) : WebView(context) {
    /** Text is selected on the page, so drags extend the selection instead of turning it. */
    var selecting = false

    /** Selected words get 语阅's own card (划线 · 想法 · 复制 …), not the system's toolbar over it;
     *  the selection and its handles stay. */
    override fun startActionMode(callback: android.view.ActionMode.Callback?, type: Int): android.view.ActionMode = NoToolbar(this)

    override fun startActionMode(callback: android.view.ActionMode.Callback?): android.view.ActionMode = NoToolbar(this)

    private class NoToolbar(private val view: android.view.View) : android.view.ActionMode() {
        override fun setTitle(title: CharSequence?) {}
        override fun setTitle(resId: Int) {}
        override fun setSubtitle(subtitle: CharSequence?) {}
        override fun setSubtitle(resId: Int) {}
        override fun setCustomView(view: android.view.View?) {}
        override fun invalidate() {}
        override fun finish() {}
        override fun getMenu(): android.view.Menu = android.widget.PopupMenu(view.context, view).menu
        override fun getTitle(): CharSequence? = null
        override fun getSubtitle(): CharSequence? = null
        override fun getCustomView(): android.view.View? = null
        override fun getMenuInflater(): android.view.MenuInflater = android.view.MenuInflater(view.context)
    }
}
