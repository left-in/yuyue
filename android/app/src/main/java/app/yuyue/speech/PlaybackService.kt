package app.yuyue.speech

import android.app.PendingIntent
import android.content.Intent
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import app.yuyue.MainActivity
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import java.io.File
import androidx.media3.common.Player as Media3Player

/**
 * 通知栏、锁屏、耳机: the book being read aloud as one media item whose title is the book and
 * whose line is the sentence being read. Play and pause go to the player; next and previous
 * move by one sentence, as on iPhone's lock screen and headphones.
 */
@UnstableApi
object Session {
    private var current: Player? = null
    val player: SessionPlayer by lazy { SessionPlayer() }

    /** This player is the one the notification controls now. */
    fun claim(p: Player) {
        if (current !== p) current?.stop()
        current = p
        player.refresh()
        p.startService()
    }

    fun release(p: Player) {
        if (current === p) {
            current = null
            player.refresh()
        }
    }

    fun update() = player.refresh()
    fun updateLine() = player.refresh()

    class SessionPlayer : SimpleBasePlayer(Looper.getMainLooper()) {
        private var artBook: String? = null
        private var art: ByteArray? = null

        fun refresh() = invalidateState()

        override fun getState(): State {
            val p = current
            val commands = Media3Player.Commands.Builder().addAll(
                COMMAND_PLAY_PAUSE, COMMAND_STOP, COMMAND_SEEK_TO_NEXT, COMMAND_SEEK_TO_PREVIOUS,
                COMMAND_SEEK_TO_NEXT_MEDIA_ITEM, COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
                COMMAND_GET_CURRENT_MEDIA_ITEM, COMMAND_GET_METADATA, COMMAND_GET_TIMELINE,
            ).build()
            val builder = State.Builder().setAvailableCommands(commands)
            if (p == null || p.state == Player.State.Stopped) {
                return builder.setPlaybackState(STATE_IDLE).setPlayWhenReady(false, PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST).build()
            }
            val book = p.detail.summary
            if (artBook != book.id) {
                artBook = book.id
                art = book.coverPath?.let { runCatching { File(it).readBytes() }.getOrNull() }
            }
            val chapter = p.spot?.let { s -> p.detail.toc.lastOrNull { it.section.toInt() <= s.section }?.title }
            val meta = MediaMetadata.Builder()
                .setTitle(p.line ?: book.title)
                .setArtist(listOfNotNull(book.title, chapter).joinToString(" · "))
                .setAlbumTitle(book.title)
                .apply { art?.let { setArtworkData(it, MediaMetadata.PICTURE_TYPE_FRONT_COVER) } }
                .build()
            val item = MediaItemData.Builder(book.id).setMediaItem(MediaItem.Builder().setMediaId(book.id).build()).setMediaMetadata(meta).build()
            return builder
                .setPlaylist(listOf(item))
                .setCurrentMediaItemIndex(0)
                .setPlaybackState(if (p.state == Player.State.Loading) STATE_BUFFERING else STATE_READY)
                .setPlayWhenReady(p.state == Player.State.Playing || p.state == Player.State.Loading, PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
                .build()
        }

        override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
            current?.let { if (playWhenReady) it.resume() else it.pause() }
            return Futures.immediateVoidFuture()
        }

        override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
            when (seekCommand) {
                COMMAND_SEEK_TO_NEXT, COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> current?.skip(true)
                COMMAND_SEEK_TO_PREVIOUS, COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> current?.skip(false)
            }
            return Futures.immediateVoidFuture()
        }

        override fun handleStop(): ListenableFuture<*> {
            current?.stop()
            return Futures.immediateVoidFuture()
        }
    }
}

/** Keeps the voice going with the screen off and puts it in the notification. */
@UnstableApi
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        session = MediaSession.Builder(this, Session.player).setSessionActivity(open).build().also {
            // Started by the player, not by a controller: the notification needs the session added.
            addSession(it)
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiped away while paused: nothing left to keep going.
        if (!Session.player.playWhenReady) stopSelf()
    }

    override fun onDestroy() {
        session?.release()
        session = null
        super.onDestroy()
    }
}
