package app.yuyue.speech

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.yuyue.library.Library
import app.yuyue.t
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import uniffi.yuyue_core.Alignment
import uniffi.yuyue_core.BookSummary
import uniffi.yuyue_core.Emissions
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * 听读书 on Android (听书开发方案 §4.3), as on Apple: an 有声书 on the shelf laid against its e-book
 * (强制对齐), so the e-book can be listened to in the narrator's voice with the ink line
 * following along. What's kept, in `audiobooks/<e-book>/`: which 有声书 it is, the model's output
 * for each of its files (so a stopped job picks up where it was), and `timings.json`, where each
 * sentence is in the recording.
 */
class Recordings(private val context: Context, private val library: Library) {
    private val dir = File(library.dataDir, "audiobooks").apply { mkdirs() }

    /** The one being made, while it is. */
    var making by mutableStateOf<Making?>(null)
        private set

    class Making(val ebook: String, val audio: String, val total: Double) {
        /** 0–1 while the model is fetched; then seconds of the recording run so far. */
        var downloaded by mutableStateOf<Double?>(null)
        var heard by mutableStateOf(0.0)
        var problem by mutableStateOf<String?>(null)
        var done by mutableStateOf(false)
        internal var job: Job? = null
        val fraction: Double get() = if (total > 0) minOf(1.0, heard / total) else 0.0
    }

    private fun folder(ebook: String) = File(dir, ebook)

    /** The 有声书 laid against `ebook`, when there is one. */
    fun audioFor(ebook: String): String? = File(folder(ebook), "audio").takeIf { it.isFile }?.readText()?.trim()

    /** The e-book on the shelf that is the same book as this 有声书, not yet laid against it. */
    fun ebookFor(audio: BookSummary): BookSummary? {
        if (audio.format != uniffi.yuyue_core.BookFormat.AUDIO) return null
        if (library.books.any { audioFor(it.id) == audio.id }) return null
        val want = plain(audio.title)
        if (want.length < 2) return null
        return library.books.filter { it.available && it.format != uniffi.yuyue_core.BookFormat.AUDIO && it.format != uniffi.yuyue_core.BookFormat.PDF }
            .firstOrNull { val p = plain(it.title); p == want || p.length >= 2 && (p.contains(want) || want.contains(p)) }
    }

    /** 合成: lays the 有声书 against the e-book on this device. */
    fun make(audio: BookSummary, ebook: BookSummary) {
        making?.job?.cancel()
        val recording = runCatching { library.core.audioRecording(audio.id) }.getOrElse { return }
        val m = Making(ebook.id, audio.id, recording.seconds)
        making = m
        val f = folder(ebook.id).apply { mkdirs() }
        File(f, "audio").writeText(audio.id)
        m.job = library.scope.launch {
            try {
                if (!Aligner.installed(library.dataDir)) {
                    m.downloaded = 0.0
                    Aligner.ensure(library.dataDir) { p -> library.scope.launch { m.downloaded = p } }
                    m.downloaded = null
                }
                val files = mutableListOf<Emissions>()
                var offset = 0.0
                for ((i, file) in recording.files.withIndex()) {
                    val cache = File(f, "emissions-$i.f32")
                    val em = if (cache.isFile && cache.length() > 0 && cache.length() % (4 * Aligner.LETTERS) == 0L) {
                        val b = ByteBuffer.wrap(cache.readBytes()).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
                        val values = FloatArray(b.remaining()).also { b.get(it) }
                        Emissions(values.toList(), (values.size / Aligner.LETTERS).toUInt(), file.seconds)
                    } else {
                        val base = offset
                        val (values, frames, seconds) = Aligner.emissions(library.dataDir, File(file.path)) { s -> library.scope.launch { m.heard = base + s } }
                        val bytes = ByteBuffer.allocate(values.size * 4).order(ByteOrder.LITTLE_ENDIAN)
                        bytes.asFloatBuffer().put(values)
                        cache.writeBytes(bytes.array())
                        Emissions(values.toList(), frames.toUInt(), seconds)
                    }
                    files += em
                    offset += file.seconds
                    m.heard = offset
                    save(ebook.id, library.core.alignRecordingFiles(ebook.id, files))
                }
                m.done = true
                making = null
                library.note(Library.Toast.Icon.Check, t("《%@》的有声书合成好了", ebook.title), t("打开书，点朗读就是主播的声音"))
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                m.problem = if (e.message == "ENOSPC") t("存储空间不够：对齐用的模型要约 800 MB 空间才装得下")
                    else if (e is java.io.IOException) t("对齐用的模型没下载下来，连上网再试一次")
                    else t("合成没做完（%@）", e.message ?: e.toString())
            }
        }
    }

    fun cancel() {
        making?.job?.cancel()
        making = null
    }

    // MARK: Where each sentence is

    class Timing(val section: Int, val sentence: Int, val start: Double, val end: Double)

    private fun save(ebook: String, a: Alignment) {
        val arr = JSONArray()
        for (s in a.sentences) {
            if (s.start < 0) continue
            arr.put(JSONArray().put(s.section.toInt()).put(s.sentence.toInt()).put(s.start).put(s.end))
        }
        val tmp = File(folder(ebook), "timings.json.part")
        tmp.writeText(JSONObject().put("sentences", arr).toString())
        tmp.renameTo(File(folder(ebook), "timings.json"))
        cache.remove(ebook)
    }

    private val cache = mutableMapOf<String, Map<Pair<Int, Int>, Timing>>()

    /** Where each sentence of `ebook` is in its recording, when it's been laid out. */
    fun timings(ebook: String): Map<Pair<Int, Int>, Timing>? = cache[ebook] ?: run {
        val f = File(folder(ebook), "timings.json").takeIf { it.isFile } ?: return null
        val arr = runCatching { JSONObject(f.readText()).getJSONArray("sentences") }.getOrNull() ?: return null
        val map = HashMap<Pair<Int, Int>, Timing>(arr.length())
        for (i in 0 until arr.length()) {
            val r = arr.getJSONArray(i)
            map[r.getInt(0) to r.getInt(1)] = Timing(r.getInt(0), r.getInt(1), r.getDouble(2), r.getDouble(3))
        }
        cache[ebook] = map
        map
    }

    /** The narrator's voice for `ebook`, when it has a recording laid against it. */
    fun voice(ebook: String): NarratorVoice? {
        val audio = audioFor(ebook) ?: return null
        val times = timings(ebook) ?: return null
        val rec = runCatching { library.core.audioRecording(audio) }.getOrNull() ?: return null
        return NarratorVoice(rec.files.map { File(it.path) to it.seconds }, times)
    }

    companion object {
        fun plain(s: String): String {
            var t = s.lowercase()
            for (p in listOf(Regex("[（(【\\[《].*?[)）】\\]》]"), Regex("有声(书|小说|版)?"), Regex("(全集|完整版|精品|播讲|朗读|演播)"), Regex("^\\d+[\\s._-]*"))) t = t.replace(p, "")
            return t.filter { it.isLetterOrDigit() }
        }
    }
}

/** A sentence in the narrator's voice: its stretch of the recording, decoded to 16-bit mono. */
class NarratorVoice(private val files: List<Pair<File, Double>>, private val times: Map<Pair<Int, Int>, Recordings.Timing>) {
    private val starts = files.runningFold(0.0) { at, f -> at + f.second }.dropLast(1)

    fun has(section: Int, sentence: Int) = times.containsKey(section to sentence)

    /** The sentence's stretch, or null when the recording doesn't have it. */
    fun speech(section: Int, sentence: Int): Speech? {
        val t = times[section to sentence] ?: return null
        if (t.end <= t.start) return null
        val i = starts.indexOfLast { it <= t.start }.coerceAtLeast(0)
        return clip(files[i].first, t.start - starts[i], t.end - starts[i])
    }

    private fun clip(file: File, from: Double, to: Double): Speech? {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(file.path)
            val track = (0 until ex.trackCount).firstOrNull { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true } ?: return null
            ex.selectTrack(track)
            val format = ex.getTrackFormat(track)
            ex.seekTo((from * 1_000_000).toLong(), MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(format, null, null, 0)
            codec.start()
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            val out = java.io.ByteArrayOutputStream()
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var done = false
            try {
                while (!done) {
                    if (!inputDone) {
                        val i = codec.dequeueInputBuffer(10_000)
                        if (i >= 0) {
                            val n = ex.readSampleData(codec.getInputBuffer(i)!!, 0)
                            if (n < 0 || ex.sampleTime / 1e6 > to + 0.5) {
                                codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                codec.queueInputBuffer(i, 0, n, ex.sampleTime, 0)
                                ex.advance()
                            }
                        }
                    }
                    val o = codec.dequeueOutputBuffer(info, 10_000)
                    if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        rate = codec.outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = codec.outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    } else if (o >= 0) {
                        val at = info.presentationTimeUs / 1e6
                        val buf = codec.getOutputBuffer(o)!!.order(ByteOrder.nativeOrder()).asShortBuffer()
                        val frames = buf.remaining() / channels
                        for (k in 0 until frames) {
                            val time = at + k.toDouble() / rate
                            if (time < from) continue
                            if (time >= to) { done = true; break }
                            var sum = 0
                            for (c in 0 until channels) sum += buf.get(k * channels + c)
                            val v = (sum / channels).toShort()
                            out.write(v.toInt() and 0xff)
                            out.write(v.toInt() shr 8 and 0xff)
                        }
                        codec.releaseOutputBuffer(o, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) done = true
                    }
                }
            } finally {
                codec.stop()
                codec.release()
            }
            val bytes = out.toByteArray()
            if (bytes.isEmpty()) return null
            val samples = ShortArray(bytes.size / 2)
            ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(samples)
            return Speech(samples, rate)
        } catch (_: Exception) {
            return null
        } finally {
            ex.release()
        }
    }
}
