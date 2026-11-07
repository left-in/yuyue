package app.yuyue.speech

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import app.yuyue.design.Prefs
import app.yuyue.library.Library
import app.yuyue.t
import uniffi.yuyue_core.AudioChapter
import uniffi.yuyue_core.AudioRecording
import uniffi.yuyue_core.BookSummary
import uniffi.yuyue_core.Bookmark
import uniffi.yuyue_core.Position
import java.io.File
import java.time.LocalDate
import kotlin.math.roundToLong

/**
 * 有声书 listened to on its own, as on Apple: the recording's files one
 * after another in ExoPlayer, by time. A position is a chapter and the milliseconds into it, saved
 * like any book's, so progress, 书签 and 听了多久 follow the book to other devices.
 *
 * Speed keeps the pitch; −15 s and +30 s; after a pause of a while it goes back a few seconds;
 * 定时 stops after some minutes or at the end of the chapter. The notification, lock screen,
 * headphones and car take the same controls: their 上一曲 / 下一曲 are −15 s and +30 s.
 */
@UnstableApi
class AudiobookPlayer(private val context: Context, private val library: Library, book: BookSummary) {
    val bookID = book.id
    var summary by mutableStateOf(book)
        private set
    var recording by mutableStateOf<AudioRecording?>(runCatching { library.core.audioRecording(book.id) }.getOrNull())
        private set
    var isPlaying by mutableStateOf(false)
        private set
    /** Seconds from the start of the whole recording. */
    var time by mutableDoubleStateOf(0.0)
        private set
    var rate by mutableStateOf(Prefs.float(RATE_KEY, 1f).takeIf { it > 0 } ?: 1f)
        private set
    var sleep by mutableStateOf<Player.Sleep>(Player.Sleep.Off)
        private set
    var bookmarks by mutableStateOf(runCatching { library.core.bookmarks(book.id) }.getOrDefault(emptyList()))
        private set
    var failure by mutableStateOf<String?>(if (recording == null) t("这本有声书的录音不在这台设备上") else null)
    /** A call (or the navigation's voice) has the sound for a moment: shown as paused, and it
     *  goes on by itself when they're done. */
    var waiting by mutableStateOf(false)
        private set

    private val core get() = library.core
    private val main = Handler(Looper.getMainLooper())
    /** Where each file starts in the whole recording. */
    private val starts: List<Double> = recording?.files?.runningFold(0.0) { at, f -> at + f.seconds }?.dropLast(1) ?: emptyList()
    private var pausedAt = 0L
    private var listenSince = 0L
    private var savedAt = 0L
    private var closed = false

    private val exo: ExoPlayer = ExoPlayer.Builder(context)
        .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_SPEECH).build(), true)
        .setHandleAudioBecomingNoisy(true)
        .setSeekBackIncrementMs((BACK * 1000).toLong())
        .setSeekForwardIncrementMs((AHEAD * 1000).toLong())
        .build()

    /** What the session hands the notification: 上一曲 / 下一曲 move by seconds, not files. */
    val sessionPlayer: androidx.media3.common.Player = object : ForwardingPlayer(exo) {
        override fun getAvailableCommands() = super.getAvailableCommands().buildUpon()
            .add(COMMAND_SEEK_TO_NEXT).add(COMMAND_SEEK_TO_PREVIOUS).add(COMMAND_SEEK_BACK).add(COMMAND_SEEK_FORWARD).build()
        override fun isCommandAvailable(command: Int) = command in listOf(COMMAND_SEEK_TO_NEXT, COMMAND_SEEK_TO_PREVIOUS, COMMAND_SEEK_BACK, COMMAND_SEEK_FORWARD) || super.isCommandAvailable(command)
        override fun seekToNext() = skip(AHEAD)
        override fun seekToNextMediaItem() = skip(AHEAD)
        override fun seekToPrevious() = skip(-BACK)
        override fun seekToPreviousMediaItem() = skip(-BACK)
        override fun seekBack() = skip(-BACK)
        override fun seekForward() = skip(AHEAD)
        override fun play() = this@AudiobookPlayer.play()
        override fun pause() = this@AudiobookPlayer.pause()
        override fun setPlayWhenReady(playWhenReady: Boolean) = if (playWhenReady) this@AudiobookPlayer.play() else this@AudiobookPlayer.pause()
    }

    private val listener = object : androidx.media3.common.Player.Listener {
        override fun onIsPlayingChanged(playing: Boolean) {
            if (closed) return
            readTime()
            if (playing != isPlaying && !exo.playWhenReady) {
                // Paused from outside (headphones out, a call): as if 暂停 were pressed.
                stopped()
            }
        }

        override fun onPlaybackStateChanged(state: Int) {
            if (state == androidx.media3.common.Player.STATE_ENDED) finished()
        }

        override fun onPlaybackSuppressionReasonChanged(reason: Int) {
            if (closed) return
            val held = reason == androidx.media3.common.Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS
            if (held && isPlaying) {
                // The player still means to play; to the reader it's paused until the call ends.
                readTime()
                isPlaying = false
                waiting = true
                listened()
                save(now = true)
                main.removeCallbacks(tick)
            } else if (!held && waiting) {
                waiting = false
                if (exo.playWhenReady) {
                    isPlaying = true
                    listened()
                    main.removeCallbacks(tick)
                    main.post(tick)
                }
            }
        }
    }

    private val tick = object : Runnable {
        override fun run() {
            if (closed) return
            onTick()
            main.postDelayed(this, 500)
        }
    }

    init {
        recording?.let { r ->
            val p = runCatching { core.progress(bookID) ?: core.latestProgress(bookID) }.getOrNull()
            if (p != null) time = seconds(p.position)
            exo.setMediaItems(r.files.mapIndexed { i, f ->
                MediaItem.Builder().setUri(android.net.Uri.fromFile(File(f.path))).setMediaId("$bookID/$i").setMediaMetadata(meta(i)).build()
            })
            exo.playbackParameters = PlaybackParameters(rate, 1f)
            exo.addListener(listener)
            seekExo(time)
            exo.prepare()
        }
    }

    // MARK: Where it is

    val total: Double get() = recording?.seconds ?: 0.0
    val chapters: List<AudioChapter> get() = recording?.chapters ?: emptyList()
    val chapter: Int get() = chapter(time)

    fun chapter(at: Double): Int = maxOf(0, chapters.indexOfLast { it.start <= at + 0.05 })

    /** `第 3 集`, or the recording's own name for it. */
    fun title(i: Int): String = chapters.getOrNull(i)?.let { it.title ?: t("第 %lld 集", i + 1) } ?: summary.title

    /** Seconds into the chapter being heard, and how long it is. */
    val inChapter: Pair<Double, Double>
        get() = chapters.getOrNull(chapter)?.let { (time - it.start) to it.seconds } ?: (0.0 to 0.0)

    private fun seconds(p: Position): Double {
        val c = chapters.getOrNull(p.section.toInt()) ?: return 0.0
        return minOf(total, c.start + p.sentence.toDouble() / 1000)
    }

    private fun position(at: Double): Position {
        val i = chapter(at)
        val into = chapters.getOrNull(i)?.let { at - it.start } ?: 0.0
        return Position(i.toUInt(), (maxOf(0.0, into) * 1000).roundToLong().toUInt())
    }

    fun seconds(b: Bookmark) = seconds(Position(b.section, b.sentence))

    // MARK: Controls

    fun toggle() = if (isPlaying) pause() else play()

    fun play() {
        if (recording == null || isPlaying || closed) return
        waiting = false
        // Picked up after a while: a few seconds back, to hear where it was.
        if (pausedAt > 0) {
            val gap = (System.currentTimeMillis() - pausedAt) / 1000.0
            val back = when { gap > 3600 -> 10.0; gap > 300 -> 5.0; gap > 30 -> 2.0; else -> 0.0 }
            if (back > 0) seekTo(maxOf(chapters.getOrNull(chapter)?.start ?: 0.0, time - back))
        }
        if (time >= total - 0.5) seekTo(0.0)
        pausedAt = 0
        Session.claimAudio(this)
        exo.play()
        isPlaying = true
        library.listening = bookID
        listened()
        main.removeCallbacks(tick)
        main.post(tick)
        armSleep()
    }

    fun pause() {
        if (waiting) {
            // Paused during a call: it stays paused after it.
            waiting = false
            exo.pause()
            pausedAt = System.currentTimeMillis()
            return
        }
        if (!isPlaying) return
        exo.pause()
        stopped()
    }

    private fun stopped() {
        readTime()
        isPlaying = false
        pausedAt = System.currentTimeMillis()
        listened()
        save(now = true)
        if (library.listening == bookID) library.listening = null
        main.removeCallbacks(tick)
        main.removeCallbacks(sleepAt)
    }

    fun skip(by: Double) = seekTo(time + by)

    fun seekTo(t: Double) {
        time = t.coerceIn(0.0, maxOf(0.0, total - 0.1))
        pausedAt = 0
        seekExo(time)
        save(now = !isPlaying)
    }

    fun goToChapter(i: Int) {
        val c = chapters.getOrNull(i) ?: return
        seekTo(c.start)
        if (!isPlaying) play()
    }

    fun changeRate(r: Float) {
        rate = r
        Prefs.set(RATE_KEY, r)
        exo.playbackParameters = PlaybackParameters(r, 1f)
    }

    fun changeSleep(s: Player.Sleep) {
        sleep = s
        armSleep()
    }

    fun close() {
        if (closed) return
        if (isPlaying) {
            exo.pause()
            stopped()
        } else {
            save(now = true)
        }
        closed = true
        main.removeCallbacksAndMessages(null)
        Session.releaseAudio(this)
        exo.removeListener(listener)
        exo.release()
    }

    /** 长按改名: a chapter's own name, or empty to have it called 第 n 集. */
    fun renameChapter(i: Int, name: String) {
        runCatching {
            summary = core.renameAudioChapter(bookID, i.toUInt(), name)
            recording = core.audioRecording(bookID)
        }.onFailure { failure = Library.message(it) }
    }

    // MARK: 书签

    fun addBookmark() {
        val p = position(time)
        runCatching { core.addBookmark(bookID, p.section, p.sentence) }
            .onFailure { failure = Library.message(it) }
        bookmarks = runCatching { core.bookmarks(bookID) }.getOrDefault(bookmarks)
    }

    fun deleteBookmark(b: Bookmark) {
        runCatching { core.deleteBookmark(bookID, b.id) }
        bookmarks = bookmarks.filter { it.id != b.id }
    }

    // MARK: The files

    private fun seekExo(t: Double) {
        if (starts.isEmpty()) return
        val i = maxOf(0, starts.indexOfLast { it <= t })
        exo.seekTo(i, ((t - starts[i]) * 1000).roundToLong())
    }

    private fun readTime() {
        val i = exo.currentMediaItemIndex
        if (i !in starts.indices) return
        time = minOf(total, starts[i] + exo.currentPosition / 1000.0)
    }

    private fun onTick() {
        if (!isPlaying) return
        val before = chapter
        readTime()
        if (sleep == Player.Sleep.Chapter && chapter != before) {
            // 本集完: stop at the start of the next one.
            sleep = Player.Sleep.Off
            pause()
            seekTo(chapters[chapter].start)
            return
        }
        val now = System.currentTimeMillis()
        if (now - savedAt > 10_000) save()
        if (listenSince > 0 && now - listenSince > 60_000) listened()
    }

    private fun finished() {
        if (!isPlaying) return
        time = total
        isPlaying = false
        pausedAt = 0
        listened()
        save(now = true)
        if (library.listening == bookID) library.listening = null
        sleep = Player.Sleep.Off
        main.removeCallbacks(tick)
    }

    // MARK: Progress and time listened

    private fun save(now: Boolean = false) {
        if (recording == null) return
        savedAt = System.currentTimeMillis()
        runCatching { core.saveProgress(bookID, position(time)) }.onFailure { failure = Library.message(it) }
        if (now) library.reload()
    }

    private fun listened() {
        val now = System.currentTimeMillis()
        if (listenSince > 0) {
            val seconds = (now - listenSince) / 1000
            if (seconds in 1..599) runCatching { core.addTime(bookID, chapter.toUInt(), 0u, seconds.toUInt(), LocalDate.now().toString()) }
        }
        listenSince = if (isPlaying) now else 0
    }

    // MARK: 定时

    private val sleepAt = Runnable {
        pause()
        sleep = Player.Sleep.Off
    }

    private fun armSleep() {
        main.removeCallbacks(sleepAt)
        val s = sleep as? Player.Sleep.Until ?: return
        if (isPlaying) main.postDelayed(sleepAt, maxOf(0, s.at - System.currentTimeMillis()))
    }

    // MARK: The notification

    /** Each file as the notification shows it: the book, the chapter it starts, the cover. */
    private fun meta(file: Int): MediaMetadata {
        val start = starts.getOrNull(file) ?: 0.0
        return MediaMetadata.Builder()
            .setTitle(t("%@ · %@", summary.title, title(chapter(start))))
            .setArtist(summary.authors.firstOrNull())
            .setAlbumTitle(summary.title)
            .setMediaType(MediaMetadata.MEDIA_TYPE_AUDIO_BOOK_CHAPTER)
            .apply { summary.coverPath?.let { runCatching { File(it).readBytes() }.getOrNull() }?.let { setArtworkData(it, MediaMetadata.PICTURE_TYPE_FRONT_COVER) } }
            .build()
    }

    fun startService() {
        context.startService(Intent(context, PlaybackService::class.java))
    }

    companion object {
        const val BACK = 15.0
        const val AHEAD = 30.0
        private const val RATE_KEY = "audiobook.rate"

        /** `14:22`, `1:02:05`. */
        fun clock(seconds: Double): String {
            val s = maxOf(0.0, seconds).toLong()
            return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
        }
    }
}
