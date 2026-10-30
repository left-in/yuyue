package app.yuyue.library

import android.content.Context
import android.util.Xml
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.yuyue.design.Prefs
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Authenticator
import okhttp3.Credentials
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.Route
import org.json.JSONArray
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser
import java.io.File
import java.io.IOException
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.TimeUnit

/** 远程书库, as on Apple: a Calibre, Kavita or Komga over OPDS, or a share (坚果云, a NAS) over
 *  WebDAV. Filled in once under 书库来源, then turned through like a catalogue and downloaded from. */
data class RemoteSource(val id: String = UUID.randomUUID().toString(), val name: String, val kind: Kind, val url: String, val user: String = "") {
    enum class Kind { OPDS, WEBDAV }

    val password: String get() = Keys.read(passwordKey(id)) ?: ""
    val host: String get() = runCatching { URI(url).host }.getOrNull() ?: url
    /** `OPDS · 192.168.1.8`. */
    val line: String get() = "${if (kind == Kind.OPDS) "OPDS" else "WebDAV"} · $host"

    fun json() = JSONObject().put("id", id).put("name", name).put("kind", kind.name).put("url", url).put("user", user)

    companion object {
        fun passwordKey(id: String) = "source.$id.password"
        fun of(j: JSONObject) = RemoteSource(j.getString("id"), j.getString("name"), Kind.valueOf(j.getString("kind")), j.getString("url"), j.optString("user"))
    }
}

/** One line in a catalogue: a way further in, or a book to take. */
data class RemoteEntry(val id: String, val title: String, val author: String? = null, val folder: String? = null, val book: String? = null, val type: String? = null, val size: Long? = null, val cover: String? = null, val format: String? = null) {
    val isBook: Boolean get() = book != null
}

data class RemoteFeed(val title: String = "", val entries: List<RemoteEntry> = emptyList(), val next: String? = null, val search: String? = null)

class RemoteError(message: String) : IOException(message)

/** The libraries filled in, and what is downloading from them. */
class RemoteSources {
    val all = mutableStateListOf<RemoteSource>()
    /** How far each download is, by `source/entry`. */
    val downloading = mutableStateMapOf<String, Float>()
    /** Taken from a library before, so it says 在书架. */
    var got by mutableStateOf(Prefs.string(GOT).split('\n').filter { it.isNotEmpty() }.toSet())
        private set

    init {
        runCatching { JSONArray(Prefs.string(KEY, "[]")) }.getOrNull()?.let { a -> for (i in 0 until a.length()) all += RemoteSource.of(a.getJSONObject(i)) }
    }

    fun save(source: RemoteSource, password: String) {
        if (password.isEmpty()) Keys.delete(RemoteSource.passwordKey(source.id)) else Keys.write(RemoteSource.passwordKey(source.id), password)
        val i = all.indexOfFirst { it.id == source.id }
        if (i >= 0) all[i] = source else all += source
        store()
    }

    fun remove(source: RemoteSource) {
        Keys.delete(RemoteSource.passwordKey(source.id))
        all.removeAll { it.id == source.id }
        store()
    }

    private fun store() = Prefs.set(KEY, JSONArray(all.map { it.json() }).toString())

    fun key(s: RemoteSource, e: RemoteEntry) = "${s.id}/${e.id}"

    /** Already on the shelf: taken from here before, or a book there by the same name. */
    fun has(e: RemoteEntry, s: RemoteSource, library: Library): Boolean {
        if (key(s, e) in got) return true
        val title = plain(e.title)
        return library.books.any { plain(it.title) == title }
    }

    private fun plain(s: String) = s.lowercase().filter { !it.isWhitespace() && it.isLetterOrDigit() }

    /** Downloads a book and puts it on the shelf. */
    suspend fun take(e: RemoteEntry, s: RemoteSource, library: Library, context: Context) {
        val k = key(s, e)
        if (k in downloading) return
        downloading[k] = 0f
        try {
            val file = RemoteClient(s).download(e, File(context.cacheDir, "remote-${UUID.randomUUID()}")) { f -> downloading[k] = f }
            try {
                withContext(Dispatchers.IO) { library.importPath(file.path) }
                library.reload()
            } finally {
                file.parentFile?.deleteRecursively()
            }
            got = got + k
            Prefs.set(GOT, got.joinToString("\n"))
        } finally {
            downloading.remove(k)
        }
    }

    companion object {
        private const val KEY = "remote.sources"
        private const val GOT = "remote.got"
    }
}

/** The kinds of file the shelf takes, and what servers call them. */
object RemoteFormats {
    val extensions = WatchedFolder.EXTENSIONS
    /** Best first, when a book comes in more than one. */
    private val types = listOf(
        "application/epub+zip" to "epub", "application/x-mobi8-ebook" to "azw3", "application/vnd.amazon.mobi8-ebook" to "azw3",
        "application/x-mobipocket-ebook" to "mobi", "application/pdf" to "pdf",
        "text/plain" to "txt",
    )

    private fun plain(t: String) = t.substringBefore(';').trim().lowercase()
    fun ext(type: String): String? = types.firstOrNull { it.first == plain(type) }?.second
    fun rank(type: String?): Int? = type?.let { t -> types.indexOfFirst { it.first == plain(t) }.takeIf { it >= 0 } }
}

/** Talking to one library. */
class RemoteClient(private val source: RemoteSource, password: String? = null) {
    private val pass = password ?: source.password
    private val http = base.newBuilder().authenticator(Login(source.user, pass)).build()

    /** A page of the catalogue: the start when no address is given. */
    suspend fun feed(url: String? = null): RemoteFeed = withContext(Dispatchers.IO) {
        val at = url ?: source.url
        when (source.kind) {
            RemoteSource.Kind.OPDS -> {
                val (feed, description) = OPDS.parse(fetch(request(at)), at)
                if (feed.search == null && description != null) feed.copy(search = runCatching { searchTemplate(description) }.getOrNull()) else feed
            }
            RemoteSource.Kind.WEBDAV -> {
                val body = """<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:displayname/></d:prop></d:propfind>"""
                val r = request(at).newBuilder().method("PROPFIND", body.toRequestBody("application/xml".toMediaType())).header("Depth", "1").build()
                DAV.parse(fetch(r), at)
            }
        }
    }

    /** The search a catalogue offers, its words put in. */
    fun search(template: String, words: String): String =
        resolve(source.url, template.replace("{searchTerms}", URLEncoder.encode(words, "UTF-8").replace("+", "%20"))) ?: template

    /** An OpenSearch description, for the address its Atom search goes to. */
    private fun searchTemplate(url: String): String? {
        val text = String(fetch(request(url)))
        for (m in Regex("""<Url\b[^>]*>""").findAll(text)) {
            val tag = m.value
            if ("atom" !in tag) continue
            Regex("""template="([^"]+)"""").find(tag)?.let { return it.groupValues[1].replace("&amp;", "&") }
        }
        return null
    }

    suspend fun data(url: String): ByteArray = withContext(Dispatchers.IO) { fetch(request(url)) }

    /** The file, under a name that says what it is, in a folder of its own. */
    suspend fun download(e: RemoteEntry, folder: File, progress: (Float) -> Unit): File = withContext(Dispatchers.IO) {
        val url = e.book ?: throw RemoteError(t("连上了，但这个地址不是 OPDS 书库"))
        val response = execute(request(url), slow)
        response.use { r ->
            val body = r.body ?: throw RemoteError(t("书库回了一个错误（%lld），过一会儿再试", r.code))
            folder.mkdirs()
            val file = File(folder, name(e, url, e.type ?: r.header("Content-Type"), r.header("Content-Disposition")))
            val total = body.contentLength()
            var done = 0L
            var last = 0L
            body.byteStream().use { input ->
                file.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        done += n
                        if (total > 0 && System.currentTimeMillis() - last > 250) {
                            last = System.currentTimeMillis()
                            val f = done.toFloat() / total
                            withContext(Dispatchers.Main) { progress(f) }
                        }
                    }
                }
            }
            file
        }
    }

    /** The book's own name with the ending its kind has. */
    private fun name(e: RemoteEntry, url: String, type: String?, disposition: String?): String {
        val suggested = disposition?.let { Regex("""filename\*?=(?:UTF-8'')?"?([^";]+)"?""").find(it)?.groupValues?.get(1) }?.let { URLDecoder.decode(it, "UTF-8") }
        for (c in listOfNotNull(suggested, URLDecoder.decode(url.substringBefore('?').substringAfterLast('/'), "UTF-8"))) {
            if (c.substringAfterLast('.', "").lowercase() in RemoteFormats.extensions) return c.replace('/', '-')
        }
        val ext = type?.let(RemoteFormats::ext) ?: "epub"
        return e.title.replace('/', '-').take(100) + "." + ext
    }

    private fun request(url: String): Request {
        var u = url
        // A library on https that links to its own pages over http (Gutenberg's search does).
        if (source.url.startsWith("https:") && u.startsWith("http:")) u = "https:" + u.removePrefix("http:")
        return Request.Builder().url(u).header("User-Agent", "Yuyue").header("Cache-Control", "no-cache").build()
    }

    private fun fetch(r: Request): ByteArray = execute(r, http).use { it.body?.bytes() ?: ByteArray(0) }

    private fun execute(r: Request, client: OkHttpClient): Response {
        val response = try {
            client.newCall(r).execute()
        } catch (e: IOException) {
            throw RemoteError(t("连不上 %@：看看地址对不对，手机和书库是不是在同一个网络", source.host))
        }
        if (response.isSuccessful) return response
        response.close()
        throw RemoteError(when (response.code) {
            401, 403 -> t("连上了，但用户名或密码不对")
            404 -> if (source.kind == RemoteSource.Kind.OPDS) t("连上了，但这个地址上没有书库。OPDS 地址一般以 /opds 结尾") else t("连上了，但没有这个文件夹")
            else -> t("书库回了一个错误（%lld），过一会儿再试", response.code)
        })
    }

    private val slow get() = http.newBuilder().readTimeout(10, TimeUnit.MINUTES).build()

    companion object {
        private val base = OkHttpClient.Builder().connectTimeout(20, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS).build()

        fun resolve(base: String, href: String?): String? {
            if (href.isNullOrEmpty()) return null
            return runCatching { base.toHttpUrlOrNull()?.resolve(href)?.toString() }.getOrNull() ?: href
        }
    }

    /** Answers the server's request for a login — Basic or Digest, Calibre uses the latter — once:
     *  a second ask means the password is wrong, and the 401 says so. */
    private class Login(private val user: String, private val password: String) : Authenticator {
        override fun authenticate(route: Route?, response: Response): Request? {
            if (user.isEmpty() || response.priorResponse != null) return null
            val challenge = response.headers("WWW-Authenticate").firstOrNull { it.startsWith("Digest", true) }
            if (challenge == null) return response.request.newBuilder().header("Authorization", Credentials.basic(user, password)).build()
            val p = Regex("""(\w+)="?([^",]*)"?""").findAll(challenge.substringAfter(' ')).associate { it.groupValues[1].lowercase() to it.groupValues[2] }
            val realm = p["realm"] ?: ""
            val nonce = p["nonce"] ?: return null
            val uri = response.request.url.encodedPath + (response.request.url.encodedQuery?.let { "?$it" } ?: "")
            fun md5(s: String) = MessageDigest.getInstance("MD5").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }
            val ha1 = md5("$user:$realm:$password")
            val ha2 = md5("${response.request.method}:$uri")
            val qop = p["qop"]?.split(',')?.map { it.trim() }?.firstOrNull { it == "auth" }
            val cnonce = UUID.randomUUID().toString().replace("-", "").take(16)
            val header = buildString {
                append("Digest username=\"$user\", realm=\"$realm\", nonce=\"$nonce\", uri=\"$uri\"")
                if (qop != null) append(", qop=auth, nc=00000001, cnonce=\"$cnonce\", response=\"${md5("$ha1:$nonce:00000001:$cnonce:auth:$ha2")}\"")
                else append(", response=\"${md5("$ha1:$nonce:$ha2")}\"")
                p["opaque"]?.let { append(", opaque=\"$it\"") }
                p["algorithm"]?.let { append(", algorithm=$it") }
            }
            return response.request.newBuilder().header("Authorization", header).build()
        }
    }
}

/** OPDS (Atom): the feed's entries, its next page and its search. */
private object OPDS {
    fun parse(data: ByteArray, base: String): Pair<RemoteFeed, String?> {
        val p = Xml.newPullParser()
        p.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true)
        p.setInput(data.inputStream(), null)
        var sawFeed = false
        var title = ""
        var next: String? = null
        var search: String? = null
        var description: String? = null
        val entries = mutableListOf<RemoteEntry>()
        var inEntry = false
        var inAuthor = false
        var id = ""
        var entryTitle = ""
        val authors = mutableListOf<String>()
        val links = mutableListOf<Map<String, String>>()
        var text = StringBuilder()
        fun resolve(h: String?) = RemoteClient.resolve(base, h)
        try {
            while (p.next() != XmlPullParser.END_DOCUMENT) {
                when (p.eventType) {
                    XmlPullParser.START_TAG -> {
                        text = StringBuilder()
                        when (p.name) {
                            "feed" -> sawFeed = true
                            "entry" -> { inEntry = true; id = ""; entryTitle = ""; authors.clear(); links.clear() }
                            "author" -> inAuthor = true
                            "link" -> {
                                val a = (0 until p.attributeCount).associate { p.getAttributeName(it) to p.getAttributeValue(it) }
                                if (inEntry) links += a else {
                                    val rel = a["rel"] ?: ""
                                    val type = a["type"] ?: ""
                                    if (rel == "next") next = resolve(a["href"])
                                    if (rel == "search") {
                                        val href = a["href"]
                                        if ("atom" in type && href != null && "{searchTerms}" in href) {
                                            search = resolve(href.replace("{searchTerms}", "SEARCHTERMS"))?.replace("SEARCHTERMS", "{searchTerms}")
                                        } else if ("opensearchdescription" in type) description = resolve(href)
                                    }
                                }
                            }
                        }
                    }
                    XmlPullParser.TEXT -> text.append(p.text)
                    XmlPullParser.END_TAG -> {
                        val v = text.toString().trim()
                        when (p.name) {
                            "title" -> if (inEntry) entryTitle = v else if (title.isEmpty()) title = v
                            "id" -> if (inEntry) id = v
                            "name" -> if (inAuthor && inEntry && v.isNotEmpty()) authors += v
                            "author" -> inAuthor = false
                            "entry" -> {
                                inEntry = false
                                make(id, entryTitle, authors, links, ::resolve)?.let { entries += it }
                            }
                        }
                        text = StringBuilder()
                    }
                }
            }
        } catch (e: Exception) {
            if (!sawFeed) throw RemoteError(t("连上了，但这个地址不是 OPDS 书库"))
        }
        if (!sawFeed) throw RemoteError(t("连上了，但这个地址不是 OPDS 书库"))
        return RemoteFeed(title, entries, next, search) to description
    }

    private fun make(id0: String, title: String, authors: List<String>, links: List<Map<String, String>>, resolve: (String?) -> String?): RemoteEntry? {
        val id = id0.ifEmpty { links.firstOrNull()?.get("href") ?: title }
        val author = authors.take(2).joinToString("、").ifEmpty { null }
        val cover = listOf("http://opds-spec.org/image/thumbnail", "http://opds-spec.org/thumbnail", "x-stanza-cover-image-thumbnail", "http://opds-spec.org/image", "http://opds-spec.org/cover")
            .firstNotNullOfOrNull { rel -> links.firstOrNull { it["rel"] == rel } }?.let { resolve(it["href"]) }
        val takes = links.filter { (it["rel"] ?: "").startsWith("http://opds-spec.org/acquisition") }
        if (takes.isNotEmpty()) {
            // The best kind the shelf can open; none of them, and it isn't shown.
            val best = takes.mapNotNull { l -> RemoteFormats.rank(l["type"])?.let { l to it } }.minByOrNull { it.second }?.first ?: return null
            val url = resolve(best["href"]) ?: return null
            val type = best["type"]
            return RemoteEntry(id, title, author, book = url, type = type, size = best["length"]?.toLongOrNull(), cover = cover, format = type?.let(RemoteFormats::ext)?.uppercase())
        }
        val nav = links.firstOrNull { (it["type"] ?: "").let { t -> "atom+xml" in t || "opds" in t } } ?: links.firstOrNull() ?: return null
        return RemoteEntry(id, title, folder = resolve(nav["href"]) ?: return null)
    }
}

/** WebDAV: a folder's folders, then the books in it. */
private object DAV {
    fun parse(data: ByteArray, base: String): RemoteFeed {
        val p = Xml.newPullParser()
        p.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true)
        p.setInput(data.inputStream(), null)
        val out = mutableListOf<RemoteEntry>()
        var href = ""
        var name = ""
        var size: Long? = null
        var folder = false
        var text = StringBuilder()
        val basePath = runCatching { URI(base).path.trim('/') }.getOrDefault("")
        while (p.next() != XmlPullParser.END_DOCUMENT) {
            when (p.eventType) {
                XmlPullParser.START_TAG -> {
                    text = StringBuilder()
                    when (p.name) {
                        "response" -> { href = ""; name = ""; size = null; folder = false }
                        "collection" -> folder = true
                    }
                }
                XmlPullParser.TEXT -> text.append(p.text)
                XmlPullParser.END_TAG -> {
                    val v = text.toString().trim()
                    when (p.name) {
                        "href" -> href = v
                        "displayname" -> name = v
                        "getcontentlength" -> size = v.toLongOrNull()
                        "response" -> {
                            val url = RemoteClient.resolve(base, href) ?: continue
                            // The folder itself comes first in the answer.
                            if (runCatching { URI(url).path.trim('/') }.getOrDefault("") == basePath) continue
                            val file = URLDecoder.decode(url.trimEnd('/').substringAfterLast('/').replace("+", "%2B"), "UTF-8")
                            if (file.startsWith(".")) continue
                            if (folder) out += RemoteEntry(url, name.ifEmpty { file }, folder = url)
                            else {
                                val ext = file.substringAfterLast('.', "").lowercase()
                                if (ext in RemoteFormats.extensions) out += RemoteEntry(url, file.substringBeforeLast('.'), book = url, size = size, format = ext.uppercase())
                            }
                        }
                    }
                    text = StringBuilder()
                }
            }
        }
        val collator = java.text.Collator.getInstance()
        val folders = out.filter { !it.isBook }.sortedWith { a, b -> collator.compare(a.title, b.title) }
        val books = out.filter { it.isBook }.sortedWith { a, b -> collator.compare(a.title, b.title) }
        return RemoteFeed(URLDecoder.decode(base.trimEnd('/').substringAfterLast('/'), "UTF-8"), folders + books)
    }
}
