package app.yuyue.library

import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.yuyue.t
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.yuyue_core.BookCollection
import uniffi.yuyue_core.BookFormat
import uniffi.yuyue_core.BookSummary
import uniffi.yuyue_core.CoreException
import uniffi.yuyue_core.Mark
import uniffi.yuyue_core.Position
import uniffi.yuyue_core.YuyueCore
import java.io.File
import java.util.UUID

/** The app's handle on the core (one per process) and the shelf it shows, as on iPhone. */
class Library(private val context: Context) {
    val dataDir: File = File(context.filesDir, "Yuyue").apply { mkdirs() }
    val core: YuyueCore = YuyueCore.open(dataDir.path, deviceName(context), "android")
    val scope: CoroutineScope = MainScope()
    /** 导出's sending, which outlives the menu that starts it. */
    val noteSender by lazy { app.yuyue.notes.NoteSender(context, this) }

    var books by mutableStateOf<List<BookSummary>>(emptyList())
        private set
    var collections by mutableStateOf<List<BookCollection>>(emptyList())
        private set
    var importing by mutableIntStateOf(0)
        private set
    /** 出了点问题: shown once, over every tab. */
    var alert by mutableStateOf<String?>(null)
    /** The note at the bottom after deleting or importing, with its undo. */
    var toast by mutableStateOf<Toast?>(null)
        private set
    /** The book open over the tabs; opening one puts it here. */
    var presented by mutableStateOf<String?>(null)
    /** The book being read aloud, in whichever screen. */
    var listening by mutableStateOf<String?>(null)
    /** A book still being read aloud after its pages were closed (a ReaderModel): the 播放条
     *  over the tabs plays and pauses it, and opening the book again picks it up as it is. */
    var nowPlaying by mutableStateOf<Any?>(null)
    private val intents = mutableMapOf<String, OpenIntent>()
    val sync = app.yuyue.sync.Sync(context, core, this)
    /** 远程书库 filled in under 书库来源. */
    val sources = RemoteSources()
    /** 听读书: 有声书 laid against their e-books. */
    val recordings by lazy { app.yuyue.speech.Recordings(context, this) }
    /** 监听一个文件夹. */
    val watched = WatchedFolder(context)
    /** A 数据快照 opened from another app, waiting to be looked at before it's brought back. */
    var openedSnapshot by mutableStateOf<Pair<File, uniffi.yuyue_core.SnapshotInfo>?>(null)

    init {
        // Deleted books can be put back for 30 days; after that their files go.
        runCatching { core.purgeDeleted(30L * 24 * 3600 * 1000) }
        reload()
    }

    fun reload() {
        try {
            books = core.books()
            collections = core.collections()
            app.yuyue.reader.Papers.load(core)
        } catch (e: Exception) {
            alert = message(e)
        }
    }

    // MARK: Opening

    sealed interface OpenIntent {
        data object Listen : OpenIntent
        data object ListenFromStart : OpenIntent
        /** From 笔记: open at this place. */
        data class At(val position: Position) : OpenIntent
        /** From 搜索 · 问: open with 书伴 and this question. */
        data class Ask(val question: String) : OpenIntent
    }

    fun open(book: BookSummary, intent: OpenIntent? = null) {
        if (!book.available) {
            note(Toast.Icon.Download, t("《%@》在别的设备上", book.title), t("把同一个文件导入这台手机，进度和笔记就接上了"))
            return
        }
        if (intent != null) intents[book.id] = intent else intents.remove(book.id)
        presented = book.id
    }

    fun open(bookID: String, at: Position) {
        intents[bookID] = OpenIntent.At(at)
        presented = bookID
    }

    fun ask(question: String, bookID: String) {
        intents[bookID] = OpenIntent.Ask(question)
        presented = bookID
    }

    fun takeIntent(bookID: String): OpenIntent? = intents.remove(bookID)

    // MARK: Organising

    fun setFinished(book: BookSummary, finished: Boolean) = run { core.setFinished(book.id, finished) }

    fun setBook(book: String, collection: String, inside: Boolean) = run { core.setInCollection(collection, book, inside) }

    fun createCollection(name: String, book: String? = null): String? {
        var id: String? = null
        run { id = core.createCollection(name, CollectionIcon.guess(name), book).id }
        return id
    }

    fun renameCollection(id: String, name: String) = run { core.renameCollection(id, name) }
    /** 换图标: null goes back to the icon its name brings. */
    fun setCollectionIcon(id: String, icon: String?) = run { core.setCollectionIcon(id, icon) }

    fun deleteCollection(c: BookCollection) {
        run { core.deleteCollection(c.id) }
        show(Toast(Toast.Icon.Delete, t("已删除合集「%@」", c.name), t("里面的书都还在"), danger = true) { run { core.restoreCollection(c.id) } })
    }

    fun reorderCollections(ids: List<String>) = run { core.reorderCollections(ids) }

    fun editInfo(book: BookSummary, title: String, authors: List<String>) = run { core.editBookInfo(book.id, title, authors) }

    fun setCover(book: BookSummary, jpeg: ByteArray) = run { core.setCover(book.id, jpeg) }

    /** Deletes straight away; the note at the bottom can put it back. */
    fun delete(book: BookSummary) {
        run { core.deleteBook(book.id) }
        show(Toast(Toast.Icon.Delete, t("已删除《%@》", book.title), t("笔记和进度都留着"), danger = true) { run { core.restoreBook(book.id) } })
    }

    /** Deletes highlights outside the book (笔记), with 撤销. Each is (book, mark). */
    fun deleteMarks(marks: List<Pair<String, Mark>>) {
        if (marks.isEmpty()) return
        try {
            for ((book, mark) in marks) core.deleteMark(book, mark.id)
        } catch (e: Exception) {
            alert = message(e)
        }
        notesChanged()
        val one = marks.singleOrNull()?.second
        val detail = one?.let { if (it.note == null) "“${it.text.take(16)}”" else t("想法也一起删了") } ?: t("%lld 条划线和它们的想法", marks.size)
        show(Toast(Toast.Icon.Highlight, if (one == null) t("已删除 %lld 条", marks.size) else t("已删除划线"), detail, danger = true) {
            for ((book, mark) in marks) runCatching { core.restoreMark(book, mark.id) }
            notesChanged()
        })
    }

    fun setNote(note: String?, book: String, mark: Mark) {
        try {
            core.setMarkNote(book, mark.id, note)
        } catch (e: Exception) {
            alert = message(e)
        }
        notesChanged()
    }

    /** Bumped when highlights change outside the book, so 笔记 loads again. */
    var notesVersion by mutableIntStateOf(0)
        private set

    fun notesChanged() {
        notesVersion++
    }

    /** Takes a word out of the 生词本, with 撤销. */
    fun deleteWord(word: String) {
        try {
            core.deleteWord(word)
        } catch (e: Exception) {
            alert = message(e)
            return
        }
        notesChanged()
        show(Toast(Toast.Icon.Delete, t("已删除“%@”", word), t("从生词本里拿掉了"), danger = true) {
            runCatching { core.restoreWord(word) }
            notesChanged()
        })
    }

    private inline fun run(change: () -> Unit) {
        try {
            change()
        } catch (e: Exception) {
            alert = message(e)
        }
        reload()
    }

    // MARK: The note at the bottom

    data class Toast(
        val icon: Icon,
        val title: String,
        val detail: String,
        val danger: Boolean = false,
        val id: String = UUID.randomUUID().toString(),
        val undo: (() -> Unit)? = null,
    ) {
        enum class Icon { Delete, Highlight, Add, Folder, Download, Check, Share, Error }

        /** Until it goes: a banner counts its seconds, shows the tick, then rises away. */
        val lifetime: Long get() = if (undo != null) UNDO_MS + UNDO_SETTLE_MS + 400 else TOAST_MS
    }

    fun note(icon: Toast.Icon, title: String, detail: String) = show(Toast(icon, title, detail))

    private var toastJob: Job? = null

    fun show(t: Toast) {
        toast = t
        toastJob?.cancel()
        toastJob = scope.launch {
            delay(t.lifetime)
            if (toast?.id == t.id) toast = null
        }
    }

    fun dismissToast() {
        toast = null
    }

    fun undo() {
        val t = toast ?: return
        toast = null
        t.undo?.invoke()
    }

    // MARK: Importing

    /** Imports the files the system picker or another app handed over, into the collection when given. */
    fun importUris(uris: List<Uri>, collection: String? = null, folder: String? = null) {
        if (uris.isEmpty()) return
        scope.launch {
            importing++
            val failures = mutableListOf<String>()
            val imported = mutableListOf<BookSummary>()
            // Sound files picked together are one 有声书; an M4B is one on its own.
            val named = uris.map { it to displayName(it) }
            val (sounds, files) = named.partition { AudioImporter.isAudio(it.second) }
            val (m4b, loose) = sounds.partition { it.second.endsWith(".m4b", ignoreCase = true) }
            for ((uri, name) in files) {
                if (name.endsWith(".yuyue", ignoreCase = true)) {
                    try {
                        openedSnapshot = withContext(Dispatchers.IO) { app.yuyue.me.copyIn(uri)?.let { it to core.readSnapshot(it.path) } }
                    } catch (e: Exception) {
                        failures += "$name：${message(e)}"
                    }
                    continue
                }
                val had = books.map { it.id }.toSet()
                try {
                    val book = withContext(Dispatchers.IO) { importOne(uri, name) }
                    if (book.id !in had) {
                        imported += book
                        if (collection != null) runCatching { core.setInCollection(collection, book.id, true) }
                    }
                } catch (e: Exception) {
                    failures += "$name：${message(e)}"
                }
                reload()
            }
            importing--
            when {
                failures.isNotEmpty() -> alert = failures.joinToString("\n")
                imported.isNotEmpty() -> {
                    val first = imported[0]
                    val title = when {
                        folder != null -> t("导入了 %lld 本", imported.size)
                        imported.size == 1 -> t("已导入《%@》", first.title)
                        else -> t("已导入 %lld 本书", imported.size)
                    }
                    show(Toast(if (folder != null) Toast.Icon.Folder else Toast.Icon.Add, title, folder?.let { t("来自“%@”文件夹", it) } ?: t("在书架最前面")) {
                        for (b in imported) runCatching { core.deleteBook(b.id) }
                        reload()
                    })
                }
                openedSnapshot != null && uris.size == 1 -> {}
                // Recordings wait on 导入有声书; the note comes when they go in.
                files.isEmpty() -> {}
                else -> note(Toast.Icon.Check, t("书架里已经有这本了，没有再导入一份"), "")
            }
            // Recordings after the books: their sheet waits on the reader, and the books
            // shouldn't wait on it.
            val recordingFailures = mutableListOf<String>()
            for (recording in m4b.map { listOf(it) } + listOfNotNull(loose.takeIf { it.isNotEmpty() })) {
                importing++
                val pending = try {
                    withContext(Dispatchers.IO) { readRecording(recording) }
                } catch (e: Exception) {
                    recordingFailures += "${recording.first().second}：${message(e)}"
                    null
                } finally {
                    importing--
                }
                if (pending != null) {
                    // Several brought in at once: one sheet after another.
                    while (pendingRecording != null) delay(200)
                    pendingRecording = pending
                }
            }
            if (recordingFailures.isNotEmpty()) alert = (listOfNotNull(alert) + recordingFailures).joinToString("\n")
        }
    }

    /** A recording read and waiting on 导入有声书 (prototype v0.30 C1): its name, author, cover
     *  and the order of its files can be changed before it goes onto the shelf. Its files sit in
     *  `scratch` till then. */
    data class PendingRecording(val audio: uniffi.yuyue_core.AudioImport, val scratch: File, val names: List<String>)

    var pendingRecording by mutableStateOf<PendingRecording?>(null)

    /** A recording's files copied next to the library and read. */
    private fun readRecording(files: List<Pair<Uri, String>>): PendingRecording {
        val tmp = File(context.cacheDir, "import-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            val copied = files.map { (uri, name) ->
                File(tmp, name.replace('/', '-')).also { f ->
                    context.contentResolver.openInputStream(uri)?.use { input -> f.outputStream().use { input.copyTo(it) } } ?: throw CoreException.NotFound(name)
                }
            }
            val audio = AudioImporter.read(core, copied, null)
            return PendingRecording(audio, tmp, audio.files.map { File(it.path).name })
        } catch (e: Exception) {
            tmp.deleteRecursively()
            throw e
        }
    }

    /** 完成 on 导入有声书: onto the shelf as a book of its own. */
    fun finishRecording(p: PendingRecording) {
        pendingRecording = null
        scope.launch {
            val had = books.map { it.id }.toSet()
            try {
                val book = withContext(Dispatchers.IO) { core.importAudiobook(p.audio) }
                reload()
                if (book.id !in had) {
                    show(Toast(Toast.Icon.Add, t("已导入《%@》", book.title), t("在书架最前面")) {
                        runCatching { core.deleteBook(book.id) }
                        reload()
                    })
                }
            } catch (e: Exception) {
                alert = message(e)
            } finally {
                withContext(Dispatchers.IO) { p.scratch.deleteRecursively() }
            }
        }
    }

    fun cancelRecording() {
        pendingRecording?.scratch?.deleteRecursively()
        pendingRecording = null
    }

    /** Copies the picked file next to the library (the core reads paths) and imports it. */
    private fun importOne(uri: Uri, name: String): BookSummary {
        val tmp = File(context.cacheDir, "import-${UUID.randomUUID()}").apply { mkdirs() }
        val file = File(tmp, name.replace('/', '-'))
        try {
            context.contentResolver.openInputStream(uri)?.use { input -> file.outputStream().use { input.copyTo(it) } }
                ?: throw CoreException.NotFound(name)
            return importPath(file.path)
        } finally {
            tmp.deleteRecursively()
        }
    }

    /** A file already on disk (Wi‑Fi 传书, a watched folder): into the library, or why not. */
    fun importPath(path: String): BookSummary {
        val book = core.importBook(path)
        if (book.format != BookFormat.PDF || book.readMinutes != 0u) return book
        // The core keeps a PDF as it is; the system's renderer says what is in it.
        return try {
            core.setPdfInfo(book.id, PdfInfoReader.read(File(path)))
        } catch (e: Exception) {
            runCatching { core.deleteBook(book.id) }
            throw e
        }
    }

    private fun displayName(uri: Uri): String {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0)?.let { return it }
        }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "book"
    }

    fun originalFile(book: BookSummary): File? =
        File(dataDir, "books/${book.id}").listFiles()?.firstOrNull { it.name.startsWith("original.") }

    companion object {
        /** How long a note stays. */
        /** How long a plain note stays. */
        const val TOAST_MS = 3000L
        /** The seconds a deletion can be undone, counted down on its banner (Telegram's 5). */
        const val UNDO_MS = 5000L
        /** How long the red tick shows after the count before the banner rises away. */
        const val UNDO_SETTLE_MS = 900L

        fun message(e: Throwable): String = when (e) {
            is PdfInfoReader.Locked -> t("这个 PDF 设了密码，打不开")
            is PdfInfoReader.Unreadable -> t("这个 PDF 读不出来")
            is CoreException.Unsupported -> t("不支持这种文件，目前能打开 EPUB、PDF、MOBI、AZW3 和 TXT")
            is CoreException.Protected -> t("这本书有版权保护（DRM），打不开")
            is CoreException.BadBook -> when {
                e.detail.contains("password", ignoreCase = true) -> t("这个压缩包设了密码，打不开")
                e.detail.contains("too large") -> t("这本书太大了，读不进来")
                else -> t("这本书读不出来，文件可能坏了，或者不是它看起来的格式")
            }
            is CoreException.NotFound -> t("找不到这本书的文件，可能被移走或删掉了。从书架上删掉，再导入一次就好")
            is CoreException.Io -> when {
                e.detail.contains("os error 28)") -> t("磁盘满了，腾点地方再导入")
                else -> t("出错了（%@）", e.detail)
            }
            is CoreException.Db -> t("出错了（%@）", e.detail)
            is CoreException.Invalid -> t("出错了（%@）", e.detail)
            is java.net.UnknownHostException -> t("没有联网，连上网再试")
            is java.net.SocketTimeoutException, is java.net.SocketException -> t("网断了，下载停在半路。连好网再点一次，会重新下")
            is java.io.IOException -> when {
                outOfSpace(e) -> t("存储空间不够了，腾出一些地方再试")
                else -> t("读写文件时出了问题，再试一次")
            }
            else -> e.localizedMessage ?: e.toString()
        }

        /** The disk is full, whichever layer said so. */
        fun outOfSpace(e: Throwable): Boolean =
            generateSequence(e) { it.cause }.any { it.message?.contains("ENOSPC") == true || it.message?.contains("No space") == true }

        fun deviceName(context: Context): String =
            Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
                ?: "${Build.MANUFACTURER} ${Build.MODEL}".trim()
    }
}
