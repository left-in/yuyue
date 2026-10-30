package app.yuyue.notes

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.remember
import app.yuyue.design.YYField
import app.yuyue.design.YYGroup
import app.yuyue.design.YYLabel
import app.yuyue.design.YYNote
import app.yuyue.design.YYPage
import app.yuyue.design.YYRow
import app.yuyue.design.rememberPref
import app.yuyue.me.Secret
import app.yuyue.shelf.Field
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.HorizontalDivider
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.shelf.Item
import uniffi.yuyue_core.BookFormat
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.documentfile.provider.DocumentFile
import app.yuyue.design.Prefs
import app.yuyue.library.Keys
import app.yuyue.library.Library
import app.yuyue.library.author
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import uniffi.yuyue_core.BookSummary
import uniffi.yuyue_core.Mark
import java.io.File
import java.time.Instant
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * 笔记导出 beyond Markdown, as on Apple: an Obsidian vault (one note per book), Notion (one page
 * per book under a page the reader picks), flomo (one memo per highlight), and the book itself as
 * an EPUB with its highlights drawn in. Nothing goes through a server of ours: Notion and flomo
 * get the reader's own token, kept encrypted on this device.
 *
 * Notion and flomo only get what they haven't had yet, so sending again after reading on just
 * adds the new highlights. Obsidian notes are written whole each time.
 */
object NoteExport {
    enum class Target(val key: String, val title: String) { Obsidian("obsidian", "Obsidian"), Notion("notion", "Notion"), Flomo("flomo", "flomo") }

    class Failure(message: String) : Exception(message)

    const val FLOMO = "export.flomo.url"
    const val NOTION = "export.notion.token"
    const val NOTION_PAGE = "export.notion.page"
    const val OBSIDIAN = "export.obsidian.tree"

    fun isSetUp(t: Target): Boolean = when (t) {
        Target.Obsidian -> Prefs.string(OBSIDIAN).isNotEmpty()
        Target.Notion -> !Keys.read(NOTION).isNullOrEmpty() && notionPage != null
        Target.Flomo -> !Keys.read(FLOMO).isNullOrEmpty()
    }

    /** The Notion page id from what the reader pasted: a link or the id itself. */
    fun pageID(text: String): String? {
        val hex = text.lowercase().substringBefore('?')
        return Regex("""[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}|[0-9a-f]{32}""").findAll(hex).lastOrNull()?.value?.replace("-", "")
    }

    val notionPage: String? get() = pageID(Prefs.string(NOTION_PAGE))

    private val http = OkHttpClient.Builder().connectTimeout(20, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS).build()
    private val json = "application/json".toMediaType()

    /** Sends the books' highlights; the count that went this time. */
    suspend fun send(context: Context, books: List<NotedBook>, target: Target): Int = withContext(Dispatchers.IO) {
        when (target) {
            Target.Obsidian -> obsidian(context, books)
            Target.Notion -> notion(books)
            Target.Flomo -> flomo(books)
        }
    }

    // MARK: Obsidian

    /** One Markdown file per book, `<title>.md`, with properties Obsidian reads. */
    private fun obsidian(context: Context, books: List<NotedBook>): Int {
        val tree = Prefs.string(OBSIDIAN).ifEmpty { throw Failure(t("还没设置 %@：在设置 · 数据 · 笔记导出里填好", "Obsidian")) }
        val folder = DocumentFile.fromTreeUri(context, Uri.parse(tree)) ?: throw Failure(t("还没设置 %@：在设置 · 数据 · 笔记导出里填好", "Obsidian"))
        for (b in books) {
            val name = b.book.title.replace(Regex("""[/\\:*?"<>|#^\[\]]"""), "-") + ".md"
            val file = folder.findFile(name) ?: folder.createFile("text/markdown", name) ?: continue
            context.contentResolver.openOutputStream(file.uri, "wt")?.use { it.write(obsidianNote(b).toByteArray()) }
        }
        return books.sumOf { it.marks.size }
    }

    fun obsidianNote(b: NotedBook): String = buildString {
        fun yaml(s: String) = "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
        append("---\ntitle: ${yaml(b.book.title)}\n")
        b.book.author?.let { append("author: ${yaml(it)}\n") }
        append("source: 语阅\ntags:\n  - 语阅\nupdated: ${Instant.now()}\n---\n\n# ${b.book.title}\n")
        for ((chapter, marks) in b.chapters()) {
            append("\n## $chapter\n")
            for (m in marks) {
                // Each highlight keeps a block id, so links to it survive the next export.
                append("\n> " + m.text.replace("\n", "\n> ") + " ^yy-${m.id.take(8)}\n")
                m.note?.let { append("\n$it\n") }
            }
        }
    }

    // MARK: flomo

    /** One memo per highlight, tagged #语阅 and the book. */
    private fun flomo(books: List<NotedBook>): Int {
        val url = Keys.read(FLOMO)?.trim()?.takeIf { it.startsWith("https://") } ?: throw Failure(t("还没设置 %@：在设置 · 数据 · 笔记导出里填好", "flomo"))
        val sent = Sent(Target.Flomo)
        var n = 0
        try {
            for (b in books) {
                val tag = "#语阅/" + b.book.title.replace(Regex("""[\s#/]+"""), "_")
                for (m in b.marks) {
                    if (sent.has(m)) continue
                    var content = m.text
                    m.note?.let { content += "\n\n$it" }
                    content += "\n\n——《${b.book.title}》${b.book.author?.let { " $it" } ?: ""}\n$tag"
                    http.newCall(Request.Builder().url(url).post(JSONObject().put("content", content).toString().toRequestBody(json)).build()).execute().use { r ->
                        val body = runCatching { JSONObject(r.body?.string() ?: "") }.getOrNull()
                        // flomo answers 200 with {"code": 0} when it took the memo.
                        if (body?.optInt("code", -1) != 0) {
                            val message = body?.optString("message")?.ifEmpty { null }
                            throw Failure(when {
                                r.code == 401 || r.code == 403 || message?.contains("token") == true -> t("%@ 的令牌不对，去设置 · 数据 · 笔记导出里重新填", "flomo")
                                r.code == 429 || message?.contains("次") == true -> t("%@ 说今天发得太多了，明天再发剩下的", "flomo")
                                message != null -> t("%@ 回了 %lld：%@", "flomo", r.code, message)
                                else -> t("%@ 回了 %lld", "flomo", r.code)
                            })
                        }
                    }
                    sent.add(m)
                    n++
                }
            }
        } finally {
            sent.save()
        }
        return n
    }

    // MARK: Notion

    /** A page per book under the page the reader chose; later sends append the new highlights. */
    private fun notion(books: List<NotedBook>): Int {
        val token = Keys.read(NOTION)?.ifEmpty { null }
        val parent = notionPage
        if (token == null || parent == null) throw Failure(t("还没设置 %@：在设置 · 数据 · 笔记导出里填好", "Notion"))
        val sent = Sent(Target.Notion)
        val pages = JSONObject(Prefs.string("export.notion.pages", "{}"))
        var n = 0
        try {
            for (b in books) {
                val fresh = b.chapters().map { (c, ms) -> c to ms.filter { !sent.has(it) } }.filter { it.second.isNotEmpty() }
                if (fresh.isEmpty()) continue
                val blocks = mutableListOf<JSONObject>()
                for ((chapter, marks) in fresh) {
                    blocks += block("heading_2", chapter)
                    for (m in marks) {
                        blocks += block("quote", m.text)
                        m.note?.let { blocks += block("paragraph", it) }
                    }
                }
                var page = pages.optString(b.id).ifEmpty { null }
                if (page == null) {
                    val props = JSONObject().put("title", JSONObject().put("title", JSONArray().put(JSONObject().put("text", JSONObject().put("content", b.book.title.take(2000))))))
                    val made = call("pages", "POST", token, JSONObject().put("parent", JSONObject().put("page_id", parent)).put("properties", props).put("children", JSONArray(blocks.take(100))), first = true)
                    page = made.optString("id")
                    pages.put(b.id, page)
                    repeat(minOf(100, blocks.size)) { blocks.removeAt(0) }
                }
                // Notion takes at most 100 blocks a call.
                while (blocks.isNotEmpty()) {
                    val chunk = blocks.take(100)
                    try {
                        call("blocks/$page/children", "PATCH", token, JSONObject().put("children", JSONArray(chunk)))
                    } catch (e: Failure) {
                        if (e.message?.contains("404") == true) {
                            // The page was deleted in Notion: start a new one next time.
                            pages.remove(b.id)
                            throw Failure(t("《%@》的页面在 Notion 里删掉了，再发一次会新建", b.book.title))
                        }
                        throw e
                    }
                    repeat(chunk.size) { blocks.removeAt(0) }
                }
                for ((_, ms) in fresh) { ms.forEach(sent::add); n += ms.size }
            }
        } finally {
            sent.save()
            Prefs.set("export.notion.pages", pages.toString())
        }
        return n
    }

    private fun block(type: String, text: String): JSONObject {
        // A rich text piece holds at most 2,000 characters.
        val pieces = JSONArray()
        text.chunked(2000).forEach { pieces.put(JSONObject().put("type", "text").put("text", JSONObject().put("content", it))) }
        return JSONObject().put("object", "block").put("type", type).put(type, JSONObject().put("rich_text", pieces))
    }

    private fun call(path: String, method: String, token: String, body: JSONObject, first: Boolean = false): JSONObject {
        val r = Request.Builder().url("https://api.notion.com/v1/$path").method(method, body.toString().toRequestBody(json))
            .header("Authorization", "Bearer $token").header("Notion-Version", "2022-06-28").build()
        http.newCall(r).execute().use { response ->
            val out = runCatching { JSONObject(response.body?.string() ?: "") }.getOrDefault(JSONObject())
            return when (response.code) {
                in 200..299 -> out
                401 -> throw Failure(t("%@ 的令牌不对，去设置 · 数据 · 笔记导出里重新填", "Notion"))
                404 -> if (first) throw Failure(t("Notion 页面还没共享给语阅：在那个页面右上角 ⋯ › 连接，选你建的集成")) else throw Failure(t("%@ 回了 %lld", "Notion", 404))
                429 -> throw Failure(t("%@ 说今天发得太多了，明天再发剩下的", "Notion"))
                else -> throw Failure(out.optString("message").ifEmpty { null }?.let { t("%@ 回了 %lld：%@", "Notion", response.code, it) } ?: t("%@ 回了 %lld", "Notion", response.code))
            }
        }
    }

    /** Which highlights a target already has, by id; one whose thought changed counts as new. */
    private class Sent(private val target: Target) {
        private val ids = JSONObject(Prefs.string("export.${target.key}.sent", "{}"))
        /** FNV-1a of the words and the thought, the same as Apple's. */
        private fun stamp(m: Mark): Int {
            var h = 2166136261L.toInt()
            for (b in (m.text + "\u0001" + (m.note ?: "")).toByteArray()) h = (h xor (b.toInt() and 0xff)) * 16777619
            return h and 0x7fffffff
        }
        fun has(m: Mark) = ids.optInt(m.id, -1) == stamp(m)
        fun add(m: Mark) { ids.put(m.id, stamp(m)) }
        fun save() = Prefs.set("export.${target.key}.sent", ids.toString())
    }

    // MARK: Sharing

    /** Markdown, handed to the share sheet as a file. */
    fun shareMarkdown(context: Context, markdown: String, name: String) {
        val dir = File(context.cacheDir, "export").apply { mkdirs() }
        val file = File(dir, name.replace('/', '-'))
        file.writeText(markdown)
        share(context, file, "text/markdown")
    }

    /** The book as an EPUB with its highlights and thoughts, to share. */
    suspend fun epub(context: Context, library: Library, book: BookSummary): File = withContext(Dispatchers.IO) {
        val dir = File(context.cacheDir, "export/${UUID.randomUUID()}").apply { mkdirs() }
        val file = File(dir, t("%@（带笔记）.epub", book.title.replace(Regex("""[/\\:]"""), "-")))
        library.core.exportEpub(book.id, true, file.path)
        file
    }

    fun share(context: Context, file: File, type: String) {
        val uri = androidx.core.content.FileProvider.getUriForFile(context, context.packageName + ".files", file)
        context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType(type).putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}

/** 导出's work: what is being sent, told in the library's notes at the bottom. */
class NoteSender(private val context: Context, private val library: Library) {
    var sending by mutableStateOf<NoteExport.Target?>(null)
        private set
    var making by mutableStateOf(false)
        private set

    fun send(books: List<NotedBook>, target: NoteExport.Target) {
        if (!NoteExport.isSetUp(target)) {
            library.note(Library.Toast.Icon.Error, t("还没设置 %@", target.title), t("在设置 · 数据 · 笔记导出里填好"))
            return
        }
        sending = target
        library.scope.launch {
            try {
                val n = NoteExport.send(context, books, target)
                library.note(Library.Toast.Icon.Check, t("发到了 %@", target.title), if (n == 0) t("没有新的划线") else t("%lld 条划线", n))
            } catch (e: Exception) {
                library.note(Library.Toast.Icon.Error, t("没发出去"), e.message ?: "")
            }
            sending = null
        }
    }

    fun epub(book: BookSummary) {
        making = true
        library.scope.launch {
            try {
                NoteExport.share(context, NoteExport.epub(context, library, book), "application/epub+zip")
            } catch (e: Exception) {
                library.note(Library.Toast.Icon.Error, t("没导出来"), Library.message(e))
            }
            making = false
        }
    }
}

/** 导出 as a menu, as on iPhone: Markdown to share, then 发到 Obsidian / Notion / flomo, and for
 *  one book EPUB（书和笔记一起）. */
@Composable
fun NoteExportMenu(library: Library, open: Boolean, dismiss: () -> Unit, markdown: () -> String, name: String, books: () -> List<NotedBook>, book: BookSummary? = null) {
    val context = LocalContext.current
    val sender = library.noteSender
    DropdownMenu(open, dismiss, containerColor = YY.c.card) {
        Item("Markdown", Icons.share) { dismiss(); NoteExport.shareMarkdown(context, markdown(), name) }
        HorizontalDivider(color = YY.c.line)
        for (target in NoteExport.Target.entries) {
            Item(t("发到 %@", target.title) + if (sender.sending == target) " …" else "", Icons.upload) {
                dismiss()
                if (sender.sending == null) sender.send(books(), target)
            }
        }
        if (book != null && book.format != BookFormat.PDF) {
            HorizontalDivider(color = YY.c.line)
            Item(t("EPUB（书和笔记一起）") + if (sender.making) " …" else "", Icons.book) {
                dismiss()
                if (!sender.making) sender.epub(book)
            }
        }
    }
}

/** 我的 › 笔记导出, as on iPhone: where 发到 sends. Obsidian is a folder (the vault, or one in
 *  it); Notion an integration's token and the page the books go under; flomo its API link.
 *  Tokens are kept encrypted on this device. */
@Composable
fun NoteExportPage() {
    val context = LocalContext.current
    var folder by rememberPref(NoteExport.OBSIDIAN, "")
    var notionToken by remember { mutableStateOf(Keys.read(NoteExport.NOTION) ?: "") }
    var notionPage by rememberPref(NoteExport.NOTION_PAGE, "")
    var flomo by remember { mutableStateOf(Keys.read(NoteExport.FLOMO) ?: "") }
    fun save(key: String, value: String) = value.trim().let { if (it.isEmpty()) Keys.delete(key) else Keys.write(key, it) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        runCatching { context.contentResolver.takePersistableUriPermission(uri, flags) }
        folder = uri.toString()
    }
    YYPage {
        YYLabel("Obsidian")
        YYGroup {
            val name = folder.takeIf { it.isNotEmpty() }?.let { DocumentFile.fromTreeUri(context, Uri.parse(it))?.name }
            row { YYRow(t("文件夹"), Icons.folder, name ?: t("还没选"), chevron = true) { picker.launch(null) } }
        }
        YYNote(t("每本书一篇笔记，写进你选的文件夹；再发一次就更新那一篇。选 Obsidian 库，或库里的一个文件夹。"))
        YYLabel("Notion")
        YYGroup {
            row { YYField(t("令牌"), 44f) { Secret(notionToken, "ntn_…") { notionToken = it; save(NoteExport.NOTION, it) } } }
            row { YYField(t("页面"), 44f) { Field(notionPage, "https://www.notion.so/…") { notionPage = it } } }
        }
        YYNote(
            if (notionPage.isEmpty() || NoteExport.pageID(notionPage) != null) t("在 notion.so/my-integrations 建一个集成，令牌填在上面；再把要放书的页面共享给它，页面链接填在下面。每本书在它下面一页。")
            else t("这不像一个 Notion 页面链接"),
        )
        YYLabel("flomo")
        YYGroup {
            row { YYField(t("链接"), 44f) { Secret(flomo, "https://flomoapp.com/iwh/…") { flomo = it; save(NoteExport.FLOMO, it) } } }
        }
        YYNote(t("flomo 网页版 › 设置 › API，拷那条以 https://flomoapp.com/iwh/ 开头的链接；每条划线成一条笔记"))
    }
}
