package app.yuyue.library

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.NetworkCapabilities
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.yuyue.L10n
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.File
import java.io.OutputStream
import java.io.RandomAccessFile
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder

/**
 * Wi‑Fi 传书, as on iPhone: a small web server on this phone. A computer on the same Wi‑Fi opens
 * the address and drops books on the page (shared/wifi-page.html, the same page as Apple's);
 * each file comes over in pieces, so one that breaks off goes on from where it stopped, and goes
 * into the library the moment it's whole.
 */
class WifiTransfer(private val context: Context, private val library: Library) {
    data class Item(val id: String, val name: String, val size: Long, val received: Long, val state: State, val since: Pair<Long, Long>? = null) {
        sealed interface State {
            data object Queued : State
            data object Receiving : State
            data object Importing : State
            data object Done : State
            data class Failed(val message: String) : State
        }
    }

    var address by mutableStateOf<String?>(null)
        private set
    val items = mutableStateListOf<Item>()
    /** `Mac 上的 Chrome` once a browser has come. */
    var client by mutableStateOf<String?>(null)
        private set
    var problem by mutableStateOf<String?>(null)
        private set
    private var server: ServerSocket? = null
    private val folder = File(context.cacheDir, "wifi")

    fun start() {
        if (server != null) return
        problem = null
        val ip = wifiAddress() ?: run { problem = t("这台设备没有连上 Wi‑Fi"); return }
        val s = runCatching { ServerSocket().apply { reuseAddress = true; bind(InetSocketAddress(8080)) } }.getOrNull()
            // 8080 taken by something else: any free one will do.
            ?: runCatching { ServerSocket(0) }.getOrNull()
            ?: run { problem = t("没法开始传书，过一会儿再试"); return }
        server = s
        address = if (s.localPort == 80) ip else "$ip:${s.localPort}"
        Thread {
            while (!s.isClosed) {
                val socket = runCatching { s.accept() }.getOrNull() ?: break
                Thread { serve(socket) }.apply { isDaemon = true }.start()
            }
        }.apply { isDaemon = true }.start()
    }

    fun stop() {
        runCatching { server?.close() }
        server = null
    }

    // MARK: HTTP, just enough

    private class Request(val method: String, val path: String, val query: Map<String, String>, val headers: Map<String, String>, val body: ByteArray)

    private fun serve(socket: Socket) = socket.use {
        val input = BufferedInputStream(socket.getInputStream())
        val out = socket.getOutputStream()
        val head = StringBuilder()
        while (!head.endsWith("\r\n\r\n")) {
            val c = input.read()
            if (c < 0 || head.length > 64 * 1024) return
            head.append(c.toChar())
        }
        val lines = String(head.toString().toByteArray(Charsets.ISO_8859_1), Charsets.UTF_8).split("\r\n")
        val parts = lines.first().split(" ")
        if (parts.size < 2) return send(out, 400, "text/plain", ByteArray(0))
        val headers = lines.drop(1).mapNotNull { l -> l.indexOf(':').takeIf { it > 0 }?.let { l.substring(0, it).lowercase() to l.substring(it + 1).trim() } }.toMap()
        val length = headers["content-length"]?.toIntOrNull() ?: 0
        // The page sends pieces of 4 MB; anything far bigger is not from it.
        if (length > 16 shl 20) return send(out, 413, "text/plain", ByteArray(0))
        val body = ByteArray(length)
        var read = 0
        while (read < length) {
            val n = input.read(body, read, length - read)
            if (n < 0) return
            read += n
        }
        val target = parts[1]
        val path = target.substringBefore('?')
        val query = target.substringAfter('?', "").split('&').filter { '=' in it }.associate { p -> p.substringBefore('=') to URLDecoder.decode(p.substringAfter('='), "UTF-8") }
        val (status, type, data) = runBlocking { respond(Request(parts[0], path, query, headers, body)) }
        send(out, status, type, data)
    }

    private fun send(out: OutputStream, status: Int, type: String, body: ByteArray) {
        val reason = mapOf(200 to "OK", 400 to "Bad Request", 404 to "Not Found", 413 to "Payload Too Large")[status] ?: "OK"
        out.write("HTTP/1.1 $status $reason\r\nContent-Type: $type\r\nContent-Length: ${body.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".toByteArray())
        out.write(body)
        out.flush()
    }

    private fun json(o: Any) = Triple(200, "application/json", o.toString().toByteArray())

    // MARK: What the page asks

    private suspend fun respond(r: Request): Triple<Int, String, ByteArray> {
        r.headers["user-agent"]?.let { a -> withContext(Dispatchers.Main) { client = describe(a) } }
        return when (r.method to r.path) {
            "GET" to "/" -> Triple(200, "text/html; charset=utf-8", page().toByteArray())
            "POST" to "/queue" -> withContext(Dispatchers.Main) { queue(r.body) }
            "PUT" to "/chunk" -> chunk(r)
            else -> Triple(404, "text/plain", ByteArray(0))
        }
    }

    /** The files the page is about to send: each gets a row, and the page learns how much of each is here. */
    private fun queue(body: ByteArray): Triple<Int, String, ByteArray> {
        val wanted = runCatching { JSONArray(String(body)) }.getOrNull() ?: return Triple(400, "text/plain", ByteArray(0))
        val have = JSONObject()
        for (i in 0 until wanted.length()) {
            val w = wanted.getJSONObject(i)
            val id = w.optString("id")
            if (!validID(id)) continue
            val size = w.optLong("size")
            val known = items.indexOfFirst { it.id == id }
            if (known >= 0) {
                have.put(id, if (items[known].state == Item.State.Done) size else items[known].received)
                continue
            }
            val name = clean(w.optString("name"))
            val got = minOf(file(id, name).length(), size)
            items += Item(id, name, size, got, Item.State.Queued)
            have.put(id, got)
        }
        return json(have)
    }

    /** One piece of a file, put after what is already here; once whole, into the library. */
    private suspend fun chunk(r: Request): Triple<Int, String, ByteArray> {
        val id = r.query["id"] ?: return Triple(404, "text/plain", ByteArray(0))
        val offset = r.query["offset"]?.toLongOrNull() ?: return Triple(404, "text/plain", ByteArray(0))
        val item = withContext(Dispatchers.Main) { items.firstOrNull { it.id == id } } ?: return Triple(404, "text/plain", ByteArray(0))
        if (item.state == Item.State.Done) return json(JSONObject().put("received", item.size).put("done", true))
        if (offset != item.received) return json(JSONObject().put("received", item.received))
        val f = file(id, item.name)
        try {
            f.parentFile?.mkdirs()
            RandomAccessFile(f, "rw").use { raf ->
                raf.setLength(offset)
                raf.seek(offset)
                raf.write(r.body)
            }
        } catch (e: Exception) {
            update(id) { it.copy(state = Item.State.Failed(t("手机存不下了"))) }
            return json(JSONObject().put("received", item.received).put("error", t("手机存不下了")))
        }
        val received = offset + r.body.size
        val importing = received >= item.size
        update(id) {
            it.copy(
                received = received,
                state = if (importing) Item.State.Importing else Item.State.Receiving,
                since = if (it.since == null || it.state != Item.State.Receiving) System.currentTimeMillis() to offset else it.since,
            )
        }
        if (!importing) return json(JSONObject().put("received", received))
        return try {
            withContext(Dispatchers.IO) { library.importPath(f.path) }
            withContext(Dispatchers.Main) { library.reload() }
            update(id) { it.copy(state = Item.State.Done) }
            json(JSONObject().put("received", item.size).put("done", true))
        } catch (e: Exception) {
            val message = Library.message(e)
            update(id) { it.copy(state = Item.State.Failed(message)) }
            json(JSONObject().put("received", item.size).put("error", message))
        } finally {
            f.parentFile?.deleteRecursively()
        }
    }

    private suspend fun update(id: String, change: (Item) -> Item) = withContext(Dispatchers.Main) {
        val i = items.indexOfFirst { it.id == id }
        if (i >= 0) items[i] = change(items[i])
    }

    private fun file(id: String, name: String) = File(File(folder, id), clean(name))

    /** `shared/wifi-page.html` in the interface's language. */
    private fun page(): String {
        var page = context.assets.open("wifi-page.html").bufferedReader().use { it.readText() }
        fun html(s: String) = s.replace("&", "&amp;").replace("<", "&lt;")
        fun js(s: String) = JSONObject.quote(s)
        val words = mapOf(
            "lang" to if (L10n.chinese) "zh-Hans" else "en",
            "title" to t("语阅 · Wi‑Fi 传书"),
            "heading" to html(t("传书到「%@」", Library.deviceName(context))),
            "formats" to t("EPUB、PDF、TXT、MOBI、AZW3，漫画 CBZ、CBR、ZIP。传完直接放进书架。"),
            "drop" to t("把书拖到这里，或者点这里选文件"),
            "many" to t("一次可以放很多本"),
            "sending" to t("正在传"),
            "gone" to t("连不上手机了。回到语阅的“Wi‑Fi 传书”页面，这里会从断的地方接着传。"),
            "awake" to t("传的时候让手机上的那一页亮着。"),
            "files" to js(t("%d 个文件")),
            "done" to js(t("已经放进书架")),
            "queued" to js(t("排队中")),
            "importing" to js(t("正在放进书架…")),
        )
        for ((k, v) in words) page = page.replace("{{$k}}", v)
        return page
    }

    /** The Wi‑Fi address the computer can reach this phone at. */
    private fun wifiAddress(): String? {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.allNetworks.firstOrNull { cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true } ?: return null
        val props: LinkProperties = cm.getLinkProperties(network) ?: return null
        return props.linkAddresses.map { it.address }.firstOrNull { it is Inet4Address }?.hostAddress
    }

    companion object {
        /** `46% · 还要 20 秒`, from how fast this stretch has gone. */
        fun progress(item: Item): String {
            val percent = (item.received.toDouble() / maxOf(item.size, 1) * 100).toInt()
            val (start, from) = item.since ?: return "$percent%"
            val seconds = (System.currentTimeMillis() - start) / 1000.0
            val speed = (item.received - from) / maxOf(seconds, 0.001)
            if (seconds <= 1 || speed <= 0) return "$percent%"
            val left = (item.size - item.received) / speed
            val words = when {
                left < 60 -> t("%lld 秒", maxOf(1, left.toInt()))
                left < 3600 -> t("%lld 分钟", (left / 60).toInt())
                else -> t("%lld 小时", (left / 3600).toInt())
            }
            return t("%lld%% · 还要 %@", percent, words)
        }

        /** `Mac 上的 Chrome`, `Windows 电脑`, or nothing. */
        fun describe(agent: String): String {
            val system = when {
                "Macintosh" in agent -> "Mac"
                "Windows" in agent -> t("Windows 电脑")
                "iPad" in agent -> "iPad"
                "Android" in agent -> "Android"
                "Linux" in agent -> t("Linux 电脑")
                else -> null
            }
            val browser = when {
                "Edg/" in agent -> "Edge"
                "Firefox/" in agent -> "Firefox"
                "Chrome/" in agent -> "Chrome"
                "Safari/" in agent -> "Safari"
                else -> null
            }
            return when {
                system != null && browser != null -> t("%@ 上的 %@", system, browser)
                system != null -> system
                else -> ""
            }
        }

        private fun validID(id: String) = id.length in 1..40 && id.all { it.isLetterOrDigit() && it.code < 128 }

        /** A name to keep: no folders in it, not too long. */
        private fun clean(name: String): String {
            val last = name.split('/', '\\', ':').lastOrNull()?.trim()?.trim('.') ?: ""
            return if (last.isEmpty()) t("书") else last.takeLast(120)
        }
    }
}
