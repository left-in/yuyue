package app.yuyue.speech

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.PlaybackParams
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.yuyue.design.Prefs
import app.yuyue.t
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import uniffi.yuyue_core.BookDetail
import uniffi.yuyue_core.Position
import uniffi.yuyue_core.YuyueCore

/**
 * Reads a book aloud one sentence at a time, for every voice alike (TECH.md: 统一播放器), as on
 * Apple. A sentence is rendered to audio before it plays, so its length is known exactly and the
 * ink line keeps pace with the voice. Two sentences are kept rendered ahead, so sentences and
 * chapters follow one another without a gap. Speed is applied while playing (pitch kept). The
 * notification and lock screen show the book and take play, pause, next and previous sentence.
 */
class Player(private val context: Context, private val core: YuyueCore, val detail: BookDetail, script: Script? = null) {
    /** What is read, one section after another: a book's chapters from the core, or a PDF's
     *  pages, each a section of its own. */
    class Script(
        val sentences: (Int) -> List<String>,
        /** The next section with something to read, and the one before. */
        val next: (Int) -> Int?,
        val previous: (Int) -> Int?,
        val language: (Int) -> String,
        /** What the notification calls the section. */
        val title: (Int) -> String?,
    ) {
        companion object {
            fun book(core: YuyueCore, d: BookDetail): Script {
                val id = d.summary.id
                return Script(
                    sentences = { runCatching { core.spokenSentences(id, it.toUInt()) }.getOrDefault(emptyList()) },
                    next = { runCatching { core.nextSection(id, it.toUInt(), true) }.getOrNull()?.toInt() },
                    previous = { runCatching { core.previousSection(id, it.toUInt(), true) }.getOrNull()?.toInt() },
                    language = { d.sections.getOrNull(it)?.lang ?: d.summary.language },
                    title = { s -> d.toc.lastOrNull { it.section.toInt() <= s }?.title ?: d.sections.getOrNull(s)?.title },
                )
            }
        }
    }

    private val script: Script = script ?: Script.book(core, detail)

    enum class State { Stopped, Loading, Playing, Paused }

    /** A sentence of the book. */
    data class Spot(val section: Int, val sentence: Int) {
        val position: Position get() = Position(section.toUInt(), maxOf(0, sentence).toUInt())
    }

    sealed interface Sleep {
        data object Off : Sleep
        /** 本句读完 */
        data object Sentence : Sleep
        /** 本章结束 */
        data object Chapter : Sleep
        /** After some minutes: the moment to stop. */
        data class Until(val at: Long, val minutes: Int) : Sleep
    }

    var state by mutableStateOf(State.Stopped)
        private set
    /** The sentence being read or paused on. */
    var spot by mutableStateOf<Spot?>(null)
        private set
    var failure by mutableStateOf<String?>(null)
    /** The failure is that no voice reads this language, named as people say it (中文): the
     *  system's voice data can be downloaded. */
    var missingVoice by mutableStateOf<String?>(null)
    var sleep by mutableStateOf<Sleep>(Sleep.Off)
    /** 单句循环 */
    var loop by mutableStateOf(false)
    /** Speed, 0.5–3. */
    var rate by mutableStateOf(Prefs.float(RATE_KEY, 1f).takeIf { it > 0 } ?: 1f)
        private set

    /** The ink line: the sentence, its length and how much has been read (ms at the current speed), and whether it moves. */
    var onSentence: ((Spot, Double, Double, Boolean) -> Unit)? = null
    /** 听读书: the narrator's recording of the book, read instead of a voice where it has the
     *  sentence; the voice reads the rest. */
    var narrator: NarratorVoice? = null
    var onStop: (() -> Unit)? = null
    var onSleep: ((Spot) -> Unit)? = null

    private val scope: CoroutineScope = MainScope()
    private val main = Handler(Looper.getMainLooper())
    private var generation = 0
    private class Line(val spot: Spot, val speech: Speech, var startFrame: Long = 0, var endFrame: Long = 0)
    /** Sentences handed to the track, in order; the first is the one playing. */
    private val queued = ArrayDeque<Line>()
    private var nextToRender: Spot? = null
    private var rendering: Job? = null
    private var writer: Thread? = null
    private var track: AudioTrack? = null
    private var trackRate = 0
    /** Frames handed to the track so far (in its own rate). */
    private var scheduled = 0L
    private val pending = java.util.concurrent.LinkedBlockingQueue<Pair<Int, Speech>>()
    private var texts = mutableMapOf<Int, List<String>>()
    private val voices = mutableMapOf<String, BookVoice?>()
    private var fetching: Pair<Int, Job>? = null
    private var focus: AudioFocusRequest? = null
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    // MARK: Controls

    /** Starts reading at `position`, or at the first sentence after it with something to read. */
    fun play(from: Position) {
        failure = null
        missingVoice = null
        reset()
        val start = first(Spot(from.section.toInt(), from.sentence.toInt())) ?: return stop()
        spot = start
        nextToRender = start
        state = State.Loading
        Session.claim(this)
        render()
    }

    fun pause() {
        if (state != State.Playing && state != State.Loading) return
        track?.pause()
        state = State.Paused
        report()
        Session.update()
    }

    fun resume() {
        if (state != State.Paused) return
        if (queued.isEmpty()) {
            state = State.Loading
            return render()
        }
        if (!takeFocus()) return
        track?.play()
        state = State.Playing
        report()
        Session.update()
    }

    fun toggle() = if (state == State.Playing || state == State.Loading) pause() else resume()

    fun stop() {
        val was = state
        fetching?.second?.cancel()
        fetching = null
        reset()
        state = State.Stopped
        spot = null
        releaseFocus()
        Session.update()
        if (was != State.Stopped) onStop?.invoke()
    }

    /** Moves on, or back, by one sentence. */
    fun skip(forward: Boolean) {
        val s = spot ?: return
        val target = (if (forward) after(s) else before(s)) ?: return
        val paused = state == State.Paused
        play(target.position)
        if (paused) pause()
    }

    fun changeRate(r: Float) {
        rate = r
        Prefs.set(RATE_KEY, r)
        track?.let { runCatching { it.playbackParams = PlaybackParams().setSpeed(r).setPitch(1f) } }
        report()
    }

    /** Reads `language` with another voice from now on, starting the sentence again in it. */
    fun choose(voice: BookVoice, language: String) {
        Prefs.set("player.voice.$language", voice.id)
        voices[language] = voice
        restartHere()
    }

    suspend fun currentVoice(language: String): BookVoice? = voice(language)

    /** The sentence being read or paused on, for the 播放条 and the notification. */
    val line: String? get() = spot?.let { sentences(it.section).getOrNull(it.sentence) }

    /** Sentences in the section being read, for the 播放条's `第 4 / 24 句`. */
    val sentenceCount: Int get() = spot?.let { sentences(it.section).size } ?: 0

    val sectionProgress: Double get() = spot?.let { s -> sentences(s.section).size.takeIf { it > 0 }?.let { (s.sentence + 1.0) / it } } ?: 0.0

    val language: String get() = spot?.let { lang(it.section) } ?: detail.summary.language

    fun textsChanged() = texts.clear()

    /** Stops reading and lets go of the notification. The player can't be used afterwards. */
    fun close() {
        stop()
        Session.release(this)
        scope.cancel()
        track?.release()
        track = null
    }

    // MARK: The queue

    private fun reset() {
        generation++
        rendering?.cancel()
        rendering = null
        writer?.interrupt()
        writer = null
        pending.clear()
        queued.clear()
        nextToRender = null
        track?.let {
            runCatching { it.pause(); it.flush() }
            it.release()
        }
        track = null
        scheduled = 0
        main.removeCallbacks(watch)
    }

    /** Renders sentences until enough are queued. */
    private fun render() {
        if (rendering != null) return
        val g = generation
        rendering = scope.launch {
            while (generation == g && queued.size <= AHEAD) {
                val s = nextToRender ?: break
                // 听读书: the narrator's own voice where the recording has the sentence.
                narrator?.takeIf { it.has(s.section, s.sentence) }?.let { n ->
                    val speech = kotlinx.coroutines.withContext(Dispatchers.IO) { n.speech(s.section, s.sentence) }
                    if (generation != g) return@launch
                    if (speech != null) {
                        nextToRender = after(s)
                        schedule(Line(s, speech))
                        continue
                    }
                }
                val language = lang(s.section)
                val voice = voice(language)
                if (voice == null) {
                    val name = java.util.Locale.forLanguageTag(language).getDisplayLanguage(java.util.Locale.getDefault()).ifEmpty { language }
                    failed(t("下载一个%@声音就能朗读这本书，系统会带你去它的下载页。", name))
                    missingVoice = name
                    return@launch
                }
                if (voice is CloudVoice) fetchAhead(voice, s, language)
                val speech = try {
                    voice.render(text(s), language)
                } catch (e: Exception) {
                    failed(t("朗读出错了（%@）", e.message ?: e.toString()))
                    return@launch
                }
                if (generation != g) return@launch
                nextToRender = after(s)
                // A sentence with nothing to say (a lone dash, say) is skipped.
                if (speech != null) schedule(Line(s, speech))
            }
            if (generation != g) return@launch
            rendering = null
            // The book is over once the last sentence has played.
            if (queued.isEmpty() && nextToRender == null && state == State.Loading) stop()
        }
    }

    /** 整章缓存: a cloud voice fetches the rest of the chapter in the background. */
    private fun fetchAhead(voice: CloudVoice, from: Spot, language: String) {
        if (fetching?.first == from.section) return
        fetching?.second?.cancel()
        val rest = sentences(from.section).drop(from.sentence + 1)
        fetching = from.section to scope.launch(Dispatchers.IO) { voice.prefetch(rest, language) }
    }

    private fun schedule(l: Line) {
        val t = ensureTrack(l.speech.rate) ?: return
        l.startFrame = scheduled
        l.endFrame = scheduled + l.speech.samples.size
        scheduled = l.endFrame
        queued.addLast(l)
        pending.put(generation to l.speech)
        if (writer == null) startWriter(t)
        if (queued.size == 1 && (state == State.Loading || state == State.Playing)) {
            if (!takeFocus()) return
            t.play()
            began()
        }
    }

    /** The sentences go to the track from a thread of their own: writing blocks while it plays. */
    private fun startWriter(t: AudioTrack) {
        val g = generation
        writer = Thread {
            try {
                while (!Thread.currentThread().isInterrupted) {
                    val (gen, speech) = pending.take()
                    if (gen != g) continue
                    var off = 0
                    while (off < speech.samples.size && !Thread.currentThread().isInterrupted) {
                        val n = t.write(speech.samples, off, speech.samples.size - off)
                        if (n < 0) return@Thread
                        off += n
                    }
                }
            } catch (_: InterruptedException) {
            } catch (_: IllegalStateException) {
            }
        }.apply { isDaemon = true; start() }
    }

    private fun ensureTrack(rate: Int): AudioTrack? {
        track?.let { if (trackRate == rate) return it }
        // Another voice at another sample rate: a track of its own.
        track?.release()
        val min = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val t = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(AudioFormat.Builder().setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setBufferSizeInBytes(maxOf(min, rate)) // half a second
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        runCatching { t.playbackParams = PlaybackParams().setSpeed(this.rate).setPitch(1f) }
        track = t
        trackRate = rate
        scheduled = 0
        return t
    }

    private fun began() {
        val l = queued.firstOrNull() ?: return
        val newSection = spot?.section != l.spot.section
        spot = l.spot
        state = State.Playing
        report()
        if (newSection) Session.update() else Session.updateLine()
        main.removeCallbacks(watch)
        main.postDelayed(watch, 40)
    }

    /** Watches the track's head: when it passes a sentence's end, the next one has begun. */
    private val watch: Runnable = object : Runnable {
        override fun run() {
            val t = track ?: return
            val head = runCatching { t.playbackHeadPosition.toLong() and 0xffffffffL }.getOrDefault(0)
            val first = queued.firstOrNull()
            if (first != null && head >= first.endFrame) {
                played()
                return
            }
            if (state == State.Playing || state == State.Loading) main.postDelayed(this, 40)
        }
    }

    private fun played() {
        val done = queued.firstOrNull()?.spot ?: return
        if (loop) return play(done.position)
        val next = queued.getOrNull(1)?.spot ?: nextToRender
        if (shouldSleep(done, next)) return fallAsleep(next ?: done)
        queued.removeFirst()
        when {
            queued.isNotEmpty() -> began()
            nextToRender == null && rendering == null -> stop()
            else -> {
                // Rendering fell behind; the next sentence starts as soon as it's ready.
                state = State.Loading
                main.postDelayed(watch, 40)
            }
        }
        render()
    }

    private fun shouldSleep(done: Spot, next: Spot?): Boolean = when (val s = sleep) {
        Sleep.Off -> false
        Sleep.Sentence -> true
        Sleep.Chapter -> next == null || next.section != done.section
        is Sleep.Until -> System.currentTimeMillis() >= s.at
    }

    /** Stops between sentences for the sleep timer, paused where it would have gone on. */
    private fun fallAsleep(at: Spot) {
        reset()
        sleep = Sleep.Off
        spot = at
        nextToRender = at
        state = State.Paused
        Session.update()
        onSleep?.invoke(at)
    }

    private fun failed(message: String) {
        stop()
        failure = message
    }

    private fun report() {
        val l = queued.firstOrNull() ?: return
        val t = track ?: return
        val head = runCatching { t.playbackHeadPosition.toLong() and 0xffffffffL }.getOrDefault(0)
        val heard = ((head - l.startFrame).coerceIn(0, l.speech.samples.size.toLong())).toDouble() / l.speech.rate
        onSentence?.invoke(l.spot, l.speech.seconds / rate * 1000, heard / rate * 1000, state == State.Playing)
    }

    private fun restartHere() {
        val s = spot ?: return
        if (state == State.Stopped) return
        val paused = state == State.Paused
        play(s.position)
        if (paused) pause()
    }

    // MARK: Audio focus

    private val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()

    private val focusChange = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> pause()
            AudioManager.AUDIOFOCUS_GAIN -> if (state == State.Paused && pausedForFocus) resume()
        }
        pausedForFocus = change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT
    }
    private var pausedForFocus = false

    private fun takeFocus(): Boolean {
        val req = focus ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN).setAudioAttributes(attributes).setOnAudioFocusChangeListener(focusChange).build().also { focus = it }
        return audio.requestAudioFocus(req) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun releaseFocus() {
        focus?.let { audio.abandonAudioFocusRequest(it) }
    }

    // MARK: The book's sentences

    private fun sentences(section: Int): List<String> = texts.getOrPut(section) { script.sentences(section) }

    private fun text(s: Spot) = sentences(s.section).getOrElse(s.sentence) { "" }

    private fun lang(section: Int): String = script.language(section)

    private fun next(section: Int) = script.next(section)
    private fun previous(section: Int) = script.previous(section)

    /** What the notification calls the section being read. */
    val sectionTitle: String? get() = spot?.let { script.title(it.section) }

    /** `s` itself when it can be read, or the first sentence after it that can. */
    private fun first(s: Spot): Spot? {
        if (sentences(s.section).isNotEmpty() && s.sentence < sentences(s.section).size) return s
        var n = next(s.section)
        while (n != null) {
            if (sentences(n).isNotEmpty()) return Spot(n, 0)
            n = next(n)
        }
        return null
    }

    private fun after(s: Spot): Spot? {
        if (s.sentence + 1 < sentences(s.section).size) return s.copy(sentence = s.sentence + 1)
        var n = next(s.section)
        while (n != null) {
            if (sentences(n).isNotEmpty()) return Spot(n, 0)
            n = next(n)
        }
        return null
    }

    private fun before(s: Spot): Spot? {
        if (s.sentence > 0) return s.copy(sentence = s.sentence - 1)
        var p = previous(s.section)
        while (p != null) {
            val n = sentences(p).size
            if (n > 0) return Spot(p, n - 1)
            p = previous(p)
        }
        return null
    }

    private suspend fun voice(language: String): BookVoice? {
        if (voices.containsKey(language)) return voices[language]
        val chosen = Prefs.string("player.voice.$language").takeIf { it.isNotEmpty() }?.let { Voices.find(it) }
        val v = chosen ?: Voices.best(language)
        voices[language] = v
        return v
    }

    companion object {
        const val RATE_KEY = "player.rate"
        private const val AHEAD = 2
    }

    init {
        SystemVoice.Engine.init(context)
    }

    fun startService() {
        context.startService(Intent(context, PlaybackService::class.java))
    }
}
