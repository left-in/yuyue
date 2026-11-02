package app.yuyue.speech

import android.app.PendingIntent
import android.content.Intent
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaLibraryService.LibraryParams
import androidx.media3.session.MediaLibraryService.MediaLibrarySession
import androidx.media3.session.SessionError
import com.google.common.collect.ImmutableList
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
    /** The player the notification and the car control now. */
    var current: Player? = null
        private set
    val player: SessionPlayer by lazy { SessionPlayer() }

    /** This player is the one the notification controls now. */
    fun claim(p: Player) {
        if (current !== p) current?.stop()
        audio?.pause()
        current = p
        if (audio != null) {
            audio = null
            onPlayerChanged?.invoke()
        }
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

    /** 有声书: its own ExoPlayer goes to the notification instead of the sentence player. */
    var audio: AudiobookPlayer? = null
        private set
    /** Set while the service runs, to hand the session the player that's playing. */
    internal var onPlayerChanged: (() -> Unit)? = null

    fun claimAudio(p: AudiobookPlayer) {
        current?.stop()
        if (audio !== p) audio?.pause()
        audio = p
        onPlayerChanged?.invoke()
        p.startService()
    }

    fun releaseAudio(p: AudiobookPlayer) {
        if (audio !== p) return
        audio = null
        onPlayerChanged?.invoke()
    }

    /** What the session should hold now. */
    val sessionPlayer: Media3Player get() = audio?.sessionPlayer ?: player

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
                // Android Auto picks a book to hear.
                COMMAND_SET_MEDIA_ITEM, COMMAND_CHANGE_MEDIA_ITEMS, COMMAND_PREPARE,
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
            val chapter = p.sectionTitle
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

        override fun handleSetMediaItems(mediaItems: MutableList<MediaItem>, startIndex: Int, startPositionMs: Long): ListenableFuture<*> {
            mediaItems.getOrNull(maxOf(0, startIndex))?.mediaId?.takeIf { it != CarListening.ROOT }?.let(CarListening::play)
            return Futures.immediateVoidFuture()
        }

        override fun handlePrepare(): ListenableFuture<*> = Futures.immediateVoidFuture()

        override fun handleStop(): ListenableFuture<*> {
            current?.stop()
            return Futures.immediateVoidFuture()
        }
    }
}

/** Keeps the voice going with the screen off and puts it in the notification; in a car, lists
 *  the books being read (Android Auto). */
@UnstableApi
class PlaybackService : MediaLibraryService() {
    private var session: MediaLibrarySession? = null

    override fun onCreate() {
        super.onCreate()
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        session = MediaLibrarySession.Builder(this, Session.sessionPlayer, Library()).setSessionActivity(open).build().also {
            // Started by the player, not by a controller: the notification needs the session added.
            addSession(it)
        }
        Session.onPlayerChanged = { session?.let { if (it.player !== Session.sessionPlayer) it.player = Session.sessionPlayer } }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? = session

    /** The car's list: one folder of books. */
    private class Library : MediaLibrarySession.Callback {
        override fun onGetLibraryRoot(session: MediaLibrarySession, browser: MediaSession.ControllerInfo, params: LibraryParams?): ListenableFuture<LibraryResult<MediaItem>> =
            Futures.immediateFuture(LibraryResult.ofItem(CarListening.root(), params))

        override fun onGetChildren(
            session: MediaLibrarySession, browser: MediaSession.ControllerInfo, parentId: String, page: Int, pageSize: Int, params: LibraryParams?,
        ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> {
            val items = if (parentId == CarListening.ROOT) CarListening.books().map(CarListening::item) else emptyList()
            return Futures.immediateFuture(LibraryResult.ofItemList(ImmutableList.copyOf(items), params))
        }

        override fun onGetItem(session: MediaLibrarySession, browser: MediaSession.ControllerInfo, mediaId: String): ListenableFuture<LibraryResult<MediaItem>> {
            val book = CarListening.books().firstOrNull { it.id == mediaId } ?: return Futures.immediateFuture(LibraryResult.ofError(SessionError.ERROR_BAD_VALUE))
            return Futures.immediateFuture(LibraryResult.ofItem(CarListening.item(book), null))
        }

        // The ids a car sends back are ours; the session player takes them as they are.
        override fun onAddMediaItems(session: MediaSession, controller: MediaSession.ControllerInfo, mediaItems: MutableList<MediaItem>): ListenableFuture<MutableList<MediaItem>> =
            Futures.immediateFuture(mediaItems)
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiped away while paused: nothing left to keep going.
        if (!Session.sessionPlayer.playWhenReady) stopSelf()
    }

    override fun onDestroy() {
        Session.onPlayerChanged = null
        session?.release()
        session = null
        super.onDestroy()
    }
}
