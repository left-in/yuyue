package app.yuyue.speech

import android.content.Context
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import java.util.UUID

/** One rendered sentence: 16-bit mono samples at `rate`. Every voice renders to this, so they
 *  all play through the same `Player` (TECH.md: 统一播放器). */
class Speech(val samples: ShortArray, val rate: Int) {
    val seconds: Double get() = samples.size.toDouble() / rate
}

/** Something that reads a sentence aloud: the system's voices now, the cloud ones too. */
interface BookVoice {
    val id: String
    val name: String
    /** "高级", or the cloud it comes from: said after the name. */
    val qualityName: String?
    val isOffline: Boolean
    fun speaks(tag: String): Boolean
    /** The sentence as audio; null when there is nothing to say. */
    suspend fun render(text: String, language: String): Speech?
}

/** Book languages are BCP 47 tags (zh-Hans, en, …); voices use locales (zh-CN, en-US). */
object SpokenLanguage {
    fun voiceLanguages(tag: String): List<String> {
        val t = tag.replace('_', '-').lowercase()
        return when {
            t == "yue" || t.startsWith("zh-hk") || t.startsWith("zh-mo") -> listOf("zh-HK", "zh-TW", "zh-CN")
            t.startsWith("zh-hant") || t.startsWith("zh-tw") -> listOf("zh-TW", "zh-HK", "zh-CN")
            t == "zh" || t.startsWith("zh-") || t == "cmn" -> listOf("zh-CN", "zh-TW")
            t == "en" || t.startsWith("en-") -> listOf("en-US", "en-GB", "en")
            else -> listOf(t.substringBefore('-'))
        }
    }

    fun matches(voiceLanguage: String, tag: String): Boolean =
        voiceLanguages(tag).any { voiceLanguage.lowercase().startsWith(it.lowercase()) }
}

/**
 * A voice of the phone's own TextToSpeech engine. The engine writes each sentence to a file
 * rather than speaking it, so its length is known before it plays and the ink line keeps pace;
 * the samples are collected as they arrive.
 */
class SystemVoice(private val voice: Voice, number: Int = 0) : BookVoice {
    override val id: String = "system.${voice.name}"
    // The engine's own names (`en-us-x-iol-local`) say nothing to a person, so a language's voices
    // are lettered in the order they're listed: 声音 A, 声音 B…
    override val name: String = voice.locale.getDisplayName(Locale.getDefault()) + " · " +
        app.yuyue.t("声音 %@", if (number < 26) ('A' + number).toString() else "${number + 1}")
    override val qualityName: String? = if (voice.quality >= Voice.QUALITY_HIGH) app.yuyue.t("高级") else null
    override val isOffline: Boolean = !voice.isNetworkConnectionRequired

    override fun speaks(tag: String) = SpokenLanguage.matches(voice.locale.toLanguageTag(), tag)

    override suspend fun render(text: String, language: String): Speech? {
        if (text.none { it.isLetterOrDigit() }) return null
        return Engine.render(text, voice)
    }

    /** The one TextToSpeech the app keeps, and its voices. */
    object Engine {
        private var tts: TextToSpeech? = null
        private val ready = CompletableDeferred<Boolean>()
        private val lock = Mutex()
        private lateinit var cache: File

        fun init(context: Context) {
            if (tts != null) return
            cache = File(context.cacheDir, "tts").apply { mkdirs() }
            tts = TextToSpeech(context.applicationContext) { status -> ready.complete(status == TextToSpeech.SUCCESS) }
        }

        suspend fun voices(): List<SystemVoice> {
            if (!ready.await()) return emptyList()
            val engine = tts ?: return emptyList()
            return (engine.voices ?: emptySet())
                .filter { !it.features.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED) }
                .sortedWith(compareBy({ it.locale.toLanguageTag() }, { it.isNetworkConnectionRequired }, { -it.quality }))
                .let { all -> all.mapIndexed { i, v -> SystemVoice(v, all.take(i).count { it.locale == v.locale }) } }
        }

        suspend fun render(text: String, voice: Voice): Speech? = lock.withLock {
            if (!ready.await()) return null
            val engine = tts ?: return null
            val id = UUID.randomUUID().toString()
            val done = CompletableDeferred<Speech?>()
            val out = ByteArrayOutputStream()
            val file = File(cache, "$id.wav")
            var rate = 0
            var format = 0
            engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {}
                override fun onBeginSynthesis(utteranceId: String?, sampleRateInHz: Int, audioFormat: Int, channelCount: Int) {
                    rate = sampleRateInHz
                    format = audioFormat
                }
                override fun onAudioAvailable(utteranceId: String?, audio: ByteArray) {
                    out.write(audio)
                }
                override fun onDone(utteranceId: String?) {
                    // Engines that don't hand the audio over as it's made still wrote the file.
                    done.complete(if (out.size() > 0) pcm(out.toByteArray(), rate, format) else wav(file))
                }
                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String?) {
                    done.complete(null)
                }
                override fun onError(utteranceId: String?, errorCode: Int) {
                    done.complete(null)
                }
            })
            engine.voice = voice
            engine.setSpeechRate(1f)
            engine.synthesizeToFile(text, Bundle(), file, id)
            // A sentence that never finishes must not stall the book.
            val speech = withTimeoutOrNull(20_000L + text.length * 300L) { done.await() }
            file.delete()
            speech
        }

        /** A 16-bit PCM WAV file's samples. */
        fun wav(file: File): Speech? {
            val b = runCatching { file.readBytes() }.getOrNull() ?: return null
            if (b.size < 44 || String(b, 0, 4) != "RIFF") return null
            val buf = ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN)
            var i = 12
            var rate = 0
            var bits = 16
            while (i + 8 <= b.size) {
                val tag = String(b, i, 4)
                val size = buf.getInt(i + 4)
                if (tag == "fmt ") {
                    rate = buf.getInt(i + 12)
                    bits = buf.getShort(i + 22).toInt()
                } else if (tag == "data" && bits == 16 && rate > 0) {
                    val n = minOf(size, b.size - i - 8) / 2
                    val s = ShortArray(n) { buf.getShort(i + 8 + it * 2) }
                    return if (n > 0) Speech(s, rate) else null
                }
                i += 8 + size + (size and 1)
            }
            return null
        }

        /** 16-bit samples; 8-bit and float are converted. */
        private fun pcm(bytes: ByteArray, rate: Int, format: Int): Speech? {
            if (rate <= 0 || bytes.isEmpty()) return null
            val samples = when (format) {
                android.media.AudioFormat.ENCODING_PCM_8BIT -> ShortArray(bytes.size) { ((bytes[it].toInt() and 0xff) - 128 shl 8).toShort() }
                android.media.AudioFormat.ENCODING_PCM_FLOAT -> {
                    val f = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
                    ShortArray(f.remaining()) { (f.get(it).coerceIn(-1f, 1f) * 32767).toInt().toShort() }
                }
                else -> {
                    val s = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                    ShortArray(s.remaining()).also { s.get(it) }
                }
            }
            return if (samples.isEmpty()) null else Speech(samples, rate)
        }

        /** Says a few words straight away, for 试听. */
        fun preview(voice: Voice, text: String) {
            val engine = tts ?: return
            engine.setOnUtteranceProgressListener(null)
            engine.voice = voice
            engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, "preview")
        }
    }

    fun preview(text: String) = Engine.preview(voice, text)
}

/** Every voice to choose from: the system's, then the cloud ones that have a key. */
object Voices {
    suspend fun all(tag: String): List<BookVoice> =
        SystemVoice.Engine.voices().filter { it.speaks(tag) }.sortedByDescending { it.isOffline } + CloudVoice.all().filter { it.speaks(tag) }

    suspend fun find(id: String): BookVoice? =
        if (id.startsWith("cloud.")) CloudVoice.all().firstOrNull { it.id == id } else SystemVoice.Engine.voices().firstOrNull { it.id == id }

    /** The best voice for text in `tag`: offline, high quality, the language's main region first. */
    suspend fun best(tag: String): BookVoice? {
        val voices = SystemVoice.Engine.voices()
        for (lang in SpokenLanguage.voiceLanguages(tag)) {
            voices.filter { it.speaks(lang) && it.isOffline }.firstOrNull()?.let { return it }
        }
        return voices.firstOrNull { it.speaks(tag) }
    }

    fun title(v: BookVoice) = listOfNotNull(v.name, v.qualityName).joinToString(" · ")
}
