package app.yuyue.speech

import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.util.UnstableApi
import app.yuyue.YuyueApp
import app.yuyue.library.author
import app.yuyue.t
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import uniffi.yuyue_core.BookFormat
import uniffi.yuyue_core.BookSummary
import uniffi.yuyue_core.Position
import uniffi.yuyue_core.ReadingStatus
import java.io.File

/**
 * Android Auto: the books being read, to pick one and hear it from where it was left, with no
 * page open. The player is the same one the reader uses, without the page to follow; the place
 * reached is saved as it goes, so the book opens there afterwards.
 */
@UnstableApi
object CarListening {
    const val ROOT = "root"
    private var player: Player? = null
    private var saving: Job? = null

    /** 在读 first, then the rest opened lately: books with words to read, not PDFs. */
    fun books(): List<BookSummary> = YuyueApp.instance.library.books
        .filter { it.available && it.format != BookFormat.PDF && it.status != ReadingStatus.FINISHED }
        .sortedWith(compareBy<BookSummary> { it.status != ReadingStatus.READING }.thenByDescending { it.openedAt ?: it.addedAt })
        .take(20)

    fun item(b: BookSummary): MediaItem = MediaItem.Builder().setMediaId(b.id).setMediaMetadata(
        MediaMetadata.Builder()
            .setTitle(b.title)
            .setArtist(b.author)
            .setSubtitle(b.author)
            .setIsPlayable(true)
            .setIsBrowsable(false)
            .setMediaType(MediaMetadata.MEDIA_TYPE_AUDIO_BOOK)
            .apply { cover(b)?.let { setArtworkData(it, MediaMetadata.PICTURE_TYPE_FRONT_COVER) } }
            .build(),
    ).build()

    fun root(): MediaItem = MediaItem.Builder().setMediaId(ROOT).setMediaMetadata(
        MediaMetadata.Builder().setTitle(t("语阅")).setIsBrowsable(true).setIsPlayable(false).setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_AUDIO_BOOKS).build(),
    ).build()

    /** A small cover: cars show them tiny and the bytes go over the link. */
    private fun cover(b: BookSummary): ByteArray? = b.coverPath?.let { path ->
        runCatching {
            val bitmap = app.yuyue.shelf.Thumbnails.cached(path) ?: android.graphics.BitmapFactory.decodeFile(path, android.graphics.BitmapFactory.Options().apply { inSampleSize = 4 })
            java.io.ByteArrayOutputStream().also { bitmap?.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, it) }.toByteArray().takeIf { it.isNotEmpty() }
        }.getOrNull() ?: runCatching { File(path).readBytes() }.getOrNull()
    }

    /** Reads `bookID` aloud from where it was left; the book already being heard just goes on. */
    fun play(bookID: String) {
        val app = YuyueApp.instance
        val library = app.library
        val core = library.core
        val heard = Session.current
        if (heard != null && heard.detail.summary.id == bookID) return heard.resume()
        player?.stop()
        val detail = runCatching { core.book(bookID) }.getOrNull() ?: return
        val start = runCatching { core.progress(bookID)?.position }.getOrNull() ?: Position(detail.start, 0u)
        val p = Player(app, core, detail)
        p.onSentence = { spot, _, _, _ ->
            saving?.cancel()
            saving = library.scope.launch {
                delay(1000)
                runCatching { core.saveProgress(bookID, spot.position) }
                library.reload()
            }
        }
        player = p
        p.play(start)
    }
}
