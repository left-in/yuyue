package app.yuyue.library

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.documentfile.provider.DocumentFile
import app.yuyue.design.Prefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** 监听一个文件夹, as on iPhone (and the prototype's Android page): books put in it are taken in
 *  the next time 语阅 comes to the front. Each file is taken once — by name, size and date — so
 *  one deleted from the shelf stays deleted. */
class WatchedFolder(private val context: Context) {
    /** The folder's name, while there is one. */
    var name by mutableStateOf(Prefs.string(NAME).ifEmpty { null })
        private set
    private var scanning = false

    /** Starts watching the folder the system's picker gave, and takes in what is there already. */
    suspend fun choose(uri: Uri, library: Library) {
        context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        Prefs.shared.getString(TREE, null)?.let { old ->
            if (old != uri.toString()) runCatching { context.contentResolver.releasePersistableUriPermission(Uri.parse(old), Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        }
        Prefs.set(TREE, uri.toString())
        val n = DocumentFile.fromTreeUri(context, uri)?.name ?: uri.lastPathSegment?.substringAfterLast(':') ?: "?"
        Prefs.set(NAME, n)
        Prefs.set(SEEN, null)
        name = n
        scan(library)
    }

    fun stop() {
        Prefs.shared.getString(TREE, null)?.let { runCatching { context.contentResolver.releasePersistableUriPermission(Uri.parse(it), Intent.FLAG_GRANT_READ_URI_PERMISSION) } }
        for (k in listOf(TREE, NAME, SEEN)) Prefs.set(k, null)
        name = null
    }

    /** Takes in the books put in the folder since last time. */
    suspend fun scan(library: Library) {
        if (scanning) return
        val tree = Prefs.shared.getString(TREE, null)?.let(Uri::parse) ?: return
        scanning = true
        try {
            val seen = Prefs.string(SEEN).split('\n').filter { it.isNotEmpty() }.toMutableSet()
            val fresh = withContext(Dispatchers.IO) {
                val root = DocumentFile.fromTreeUri(context, tree) ?: return@withContext emptyList()
                val out = mutableListOf<Uri>()
                fun walk(dir: DocumentFile, depth: Int) {
                    for (f in dir.listFiles()) {
                        val n = f.name ?: continue
                        if (n.startsWith(".")) continue
                        if (f.isDirectory) { if (depth < 4) walk(f, depth + 1); continue }
                        if (n.substringAfterLast('.', "").lowercase() !in EXTENSIONS) continue
                        if (seen.add("$n|${f.length()}|${f.lastModified() / 1000}")) out += f.uri
                    }
                }
                walk(root, 0)
                out
            }
            Prefs.set(SEEN, seen.joinToString("\n"))
            if (fresh.isNotEmpty()) library.importUris(fresh, folder = name)
        } finally {
            scanning = false
        }
    }

    companion object {
        val EXTENSIONS = setOf("epub", "azw3", "mobi", "azw", "pdf", "txt")
        private const val TREE = "watch.tree"
        private const val NAME = "watch.name"
        private const val SEEN = "watch.seen"
    }
}
