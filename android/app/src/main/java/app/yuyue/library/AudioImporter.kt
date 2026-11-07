package app.yuyue.library

import android.media.MediaMetadataRetriever
import uniffi.yuyue_core.AudioFile
import uniffi.yuyue_core.AudioImport
import uniffi.yuyue_core.AudioMark
import uniffi.yuyue_core.YuyueCore
import java.io.File

/**
 * 有声书 onto the shelf, as on Apple: reads what the system's player can
 * tell of the files (how long each is, title, author, cover) and hands it to the core, which
 * copies the files in and keeps the order. The system's reader doesn't give an M4B's chapter
 * marks; the core reads them from the file.
 */
object AudioImporter {
    val extensions = setOf("m4b", "m4a", "mp3", "aac", "wav", "flac", "ogg", "opus")

    fun isAudio(name: String) = name.substringAfterLast('.', "").lowercase() in extensions

    /** One recording, from files already on disk; `folderName` when they came as a folder. */
    fun read(core: YuyueCore, files: List<File>, folderName: String?): AudioImport {
        val ordered = core.sortAudioFiles(files.map { it.path }).map(::File)
        val first = ordered.firstOrNull() ?: throw IllegalArgumentException("no files")
        val out = mutableListOf<AudioFile>()
        val marks = mutableListOf<AudioMark>()
        var at = 0.0
        var title: String? = null
        var album: String? = null
        var author: String? = null
        var cover: ByteArray? = null
        for ((i, f) in ordered.withIndex()) {
            val r = MediaMetadataRetriever()
            try {
                r.setDataSource(f.path)
                val ms = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0
                if (ms <= 0) throw IllegalArgumentException(app.yuyue.t("“%@”读不出来", f.name))
                out += AudioFile(f.path, ms / 1000.0)
                marks += core.audioChapterMarks(f.path).map { AudioMark(it.title, at + it.start) }
                at += ms / 1000.0
                if (i == 0) {
                    title = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE)
                    album = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM)
                    author = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)
                        ?: r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_AUTHOR)
                        ?: r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUMARTIST)
                    cover = r.embeddedPicture
                }
            } finally {
                r.release()
            }
        }
        // A book in several files names each file a chapter; the album or folder is the book.
        val name = (if (ordered.size > 1) album else title ?: album)?.takeIf { it.isNotBlank() }
            ?: folderName ?: first.nameWithoutExtension
        return AudioImport(out, name, listOfNotNull(author?.takeIf { it.isNotBlank() }), if (marks.size < 2) emptyList() else marks, cover)
    }
}
