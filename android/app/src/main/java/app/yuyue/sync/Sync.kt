package app.yuyue.sync

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Xml
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.yuyue.design.Prefs
import app.yuyue.library.Keys
import app.yuyue.library.Library
import app.yuyue.t
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser
import uniffi.yuyue_core.DeviceInfo
import uniffi.yuyue_core.SyncPart
import uniffi.yuyue_core.YuyueCore
import java.io.File
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.URLDecoder
import java.net.URLEncoder
import java.net.UnknownHostException
import kotlin.coroutines.coroutineContext
import okhttp3.Credentials
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.util.concurrent.TimeUnit

/**
 * 同步, with no server of ours, as on Apple: every device keeps one file in a folder the user
 * owns (a WebDAV share) holding every change it knows of, and reads the others'. The operation
 * log merges in any order, so nothing here has to be careful about who writes first. The
 * folder's layout is the same as Apple's, so phones, Macs and iPhones meet in the same one.
 */
class Sync(private val context: Context, private val core: YuyueCore, private val library: Library) {
    sealed interface State {
        data object Idle : State
        data object Syncing : State
        data class Failed(val message: String) : State
    }

    data class WebDAVAccount(val url: String, val user: String, val password: String, val folder: String = t("语阅"))

    var state by mutableStateOf<State>(State.Idle)
        private set
    var lastSynced by mutableStateOf(Prefs.shared.getLong(LAST, 0L).takeIf { it > 0 })
        private set
    var devices by mutableStateOf<List<DeviceInfo>>(emptyList())
        private set
    var on by mutableStateOf(Prefs.string(METHOD) == "webdav")
        private set
    /** 书文件: each book's own file goes into the folder too. On the phone only over Wi‑Fi. */
    var syncsFiles by mutableStateOf(Prefs.bool(FILES, true))
        private set
    /** 同步这些: what this device neither sends nor takes. */
    var leftOut by mutableStateOf(Prefs.string(LEFT_OUT).split(',').filter { it.isNotEmpty() }.toSet())
        private set
    private var running: Job? = null

    init {
        loadDevices()
    }

    fun loadDevices() {
        devices = runCatching { core.devices() }.getOrDefault(emptyList())
    }

    val webdav: WebDAVAccount?
        get() {
            val url = Prefs.string(URL_KEY).takeIf { it.isNotEmpty() } ?: return null
            return WebDAVAccount(url, Prefs.string(USER), Keys.read(PASSWORD) ?: "", Prefs.string(FOLDER, t("语阅")))
        }

    fun includes(part: SyncPart) = part.name !in leftOut

    fun include(part: SyncPart, yes: Boolean) {
        leftOut = if (yes) leftOut - part.name else leftOut + part.name
        Prefs.set(LEFT_OUT, leftOut.sorted().joinToString(","))
        now()
    }

    fun syncFiles(yes: Boolean) {
        syncsFiles = yes
        Prefs.set(FILES, yes)
        now()
    }

    /** Checks the account can be reached and written, then keeps it and syncs. */
    suspend fun connect(account: WebDAVAccount) {
        WebDAVFolder(account).prepare()
        Prefs.set(URL_KEY, account.url)
        Prefs.set(USER, account.user)
        Prefs.set(FOLDER, account.folder)
        Keys.write(PASSWORD, account.password)
        Prefs.set(METHOD, "webdav")
        on = true
        now()
    }

    fun stop() {
        running?.cancel()
        running = null
        Prefs.set(METHOD, "none")
        on = false
        state = State.Idle
    }

    /** Exchanges changes now, unless an exchange is already under way. */
    fun now() {
        if (running != null) return
        val account = webdav?.takeIf { on } ?: return
        state = State.Syncing
        running = library.scope.launch {
            try {
                val folder = WebDAVFolder(account)
                var applied = withContext(Dispatchers.IO) { exchange(folder) }
                if (syncsFiles && onWifi()) applied += withContext(Dispatchers.IO) { exchangeFiles(folder) }
                lastSynced = System.currentTimeMillis()
                Prefs.set(LAST, lastSynced!!)
                state = State.Idle
                if (applied > 0) library.reload()
            } catch (e: CancellationException) {
                state = State.Idle
            } catch (e: Exception) {
                state = State.Failed(message(e))
            }
            loadDevices()
            running = null
        }
    }

    /** Syncs every few minutes while the app is open. */
    suspend fun keepUp() {
        while (true) {
            now()
            delay(5 * 60 * 1000L)
        }
    }

    private fun onWifi(): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }

    /** Reads every other device's file that changed since last time, then writes this device's
     *  own when it knows something new. Returns how many values changed here. */
    private suspend fun exchange(folder: WebDAVFolder): Int {
        folder.prepare()
        val mine = core.deviceId() + SUFFIX
        val files = folder.list()
        val parts = SyncPart.entries.filter { it.name in leftOut }
        val before = Prefs.string(LEFT_OUT_DONE, "\u0000").takeIf { it != "\u0000" }?.split(',')?.filter { it.isNotEmpty() }?.toSet()
        // A part on again: what was passed over in files already read is only in them, so read them all.
        val reread = before != null && !leftOut.containsAll(before)
        val seen = if (reread) mutableMapOf() else JSONObject(Prefs.string(SEEN, "{}")).let { j -> j.keys().asSequence().associateWith { j.getString(it) }.toMutableMap() }
        var applied = 0
        for ((name, tag) in files) {
            if (!name.endsWith(SUFFIX) || name == mine || seen[name] == tag) continue
            coroutineContext.ensureActive()
            applied += core.importChangesExcept(String(folder.read(name)), parts).toInt()
            seen[name] = tag
        }
        Prefs.set(SEEN, JSONObject(seen as Map<*, *>).toString())
        val version = core.syncVersion() + "|" + leftOut.sorted().joinToString(",")
        if (files[mine] == null || Prefs.string(WRITTEN) != version) {
            folder.write(mine, core.exportChangesExcept("{}", parts).toByteArray())
            Prefs.set(WRITTEN, version)
        }
        Prefs.set(LEFT_OUT_DONE, leftOut.sorted().joinToString(","))
        return applied
    }

    /** 书文件: a book's file is `<id>.book.<ext>`; ids are the file's hash, so the same file
     *  imported anywhere is the same book. One failing doesn't stop the rest. */
    private suspend fun exchangeFiles(folder: WebDAVFolder): Int {
        val files = runCatching { folder.list() }.getOrNull() ?: return 0
        val books = runCatching { core.books() }.getOrDefault(emptyList())
        var took = 0
        for (b in books.filter { it.available }) {
            if (files.keys.any { it.startsWith(b.id + ".book.") }) continue
            coroutineContext.ensureActive()
            val path = runCatching { core.originalFile(b.id) }.getOrNull() ?: continue
            runCatching { folder.upload("${b.id}.book.${File(path).extension}", File(path)) }
        }
        val temp = File(context.cacheDir, "sync-${System.nanoTime()}").apply { mkdirs() }
        try {
            for (b in books.filter { !it.available }) {
                val name = files.keys.firstOrNull { it.startsWith(b.id + ".book.") } ?: continue
                coroutineContext.ensureActive()
                // Named as the book is, so a TXT's title (taken from its file name) comes out the same.
                val file = File(temp, b.title.replace(Regex("""[/\\:?*"<>|]"""), "-") + "." + name.substringAfterLast('.'))
                runCatching {
                    folder.download(name, file)
                    library.importPath(file.path)
                    took++
                }
                file.delete()
            }
        } finally {
            temp.deleteRecursively()
        }
        return took
    }

    class Status(val code: Int) : IOException("HTTP $code")

    companion object {
        private const val SUFFIX = ".yuyue-sync.json"
        private const val METHOD = "sync.method"
        private const val LAST = "sync.last.ms"
        private const val URL_KEY = "sync.webdav.url"
        private const val USER = "sync.webdav.user"
        private const val PASSWORD = "sync.webdav.password"
        private const val FOLDER = "sync.webdav.folder"
        private const val FILES = "sync.files"
        private const val LEFT_OUT = "sync.leftOut"
        private const val LEFT_OUT_DONE = "sync.leftOut.done"
        private const val SEEN = "sync.seen"
        private const val WRITTEN = "sync.written"

        fun message(e: Throwable): String = when {
            e is Status && (e.code == 401 || e.code == 403) -> t("账号或密码不对")
            e is Status && e.code == 404 -> t("服务器上没有这个地址")
            e is Status -> t("服务器回了 %lld", e.code)
            e is UnknownHostException || e is ConnectException -> t("连不上服务器")
            e is SocketTimeoutException -> t("连接超时")
            else -> Library.message(e)
        }
    }
}

/** A folder on a WebDAV share: file name → a tag that changes when the file does. */
class WebDAVFolder(private val account: Sync.WebDAVAccount) {
    private val dir: String
        get() {
            val base = account.url.trimEnd('/')
            val path = account.folder.split('/').filter { it.isNotEmpty() }.joinToString("/") { enc(it) }
            return if (path.isEmpty()) "$base/" else "$base/$path/"
        }

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8").replace("+", "%20")

    private fun request(url: String, method: String, body: RequestBody? = null): Request {
        val b = Request.Builder().url(url).method(method, body).header("Cache-Control", "no-cache")
        if (account.user.isNotEmpty()) b.header("Authorization", Credentials.basic(account.user, account.password))
        return b.build()
    }

    private fun send(r: Request, client: OkHttpClient = http, ok: (Int) -> Boolean = { it in 200..299 }): Response {
        val response = client.newCall(r).execute()
        if (!ok(response.code)) {
            response.close()
            throw Sync.Status(response.code)
        }
        return response
    }

    fun prepare() {
        // 405: there already.
        send(request(dir, "MKCOL")) { it in 200..299 || it == 405 }.close()
    }

    fun list(): Map<String, String> {
        val body = """<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:getlastmodified/><d:getcontentlength/></d:prop></d:propfind>"""
            .toRequestBody("application/xml".toMediaType())
        val r = request(dir, "PROPFIND", body).newBuilder().header("Depth", "1").build()
        return send(r).use { parse(it.body!!.byteStream()) }
    }

    fun read(name: String): ByteArray = send(request(dir + enc(name), "GET")).use { it.body!!.bytes() }

    fun write(name: String, data: ByteArray) {
        send(request(dir + enc(name), "PUT", data.toRequestBody("application/json".toMediaType()))).close()
    }

    fun upload(name: String, file: File) {
        send(request(dir + enc(name), "PUT", file.asRequestBody("application/octet-stream".toMediaType())), slow).close()
    }

    fun download(name: String, to: File) {
        val part = File(to.path + ".download")
        send(request(dir + enc(name), "GET"), slow).use { r -> r.body!!.byteStream().use { input -> part.outputStream().use { input.copyTo(it) } } }
        if (!part.renameTo(to)) throw IOException("rename")
    }

    /** The file names and tags in a PROPFIND answer. */
    private fun parse(input: java.io.InputStream): Map<String, String> {
        val out = mutableMapOf<String, String>()
        val p = Xml.newPullParser()
        p.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true)
        p.setInput(input, null)
        var href = ""
        var tag = ""
        var modified = ""
        var text = StringBuilder()
        while (p.next() != XmlPullParser.END_DOCUMENT) {
            when (p.eventType) {
                XmlPullParser.START_TAG -> {
                    text = StringBuilder()
                    if (p.name == "response") { href = ""; tag = ""; modified = "" }
                }
                XmlPullParser.TEXT -> text.append(p.text)
                XmlPullParser.END_TAG -> {
                    val v = text.toString().trim()
                    when (p.name) {
                        "href" -> href = v
                        "getetag" -> tag = v
                        "getlastmodified" -> modified = v
                        "response" -> {
                            val file = runCatching { URLDecoder.decode(href.replace("+", "%2B"), "UTF-8") }.getOrDefault(href).split('/').lastOrNull() ?: ""
                            if (file.isNotEmpty() && !href.endsWith("/")) out[file] = tag.ifEmpty { modified }
                        }
                    }
                }
            }
        }
        return out
    }

    companion object {
        private val http = OkHttpClient.Builder().connectTimeout(20, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS).build()
        /** 书文件 take a while. */
        private val slow = http.newBuilder().readTimeout(10, TimeUnit.MINUTES).writeTimeout(10, TimeUnit.MINUTES).build()
    }
}
