package app.yuyue.speech

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.coroutines.coroutineContext
import kotlin.math.sqrt

/**
 * 强制对齐 (听书开发方案 §4.2), as on Apple: Meta's MMS alignment model, 8-bit, as ONNX. It turns a
 * recording into how likely each letter is every 20 ms; the core lays the book's words along that.
 *
 * The model (about 300 MB) isn't in the app: it's fetched from 语阅's own GitHub release the first
 * time an audiobook is made, checked against its BLAKE3, and kept beside the library. Its licence
 * is CC-BY-NC 4.0 — 语阅 is free and takes no money, and 开源许可 names it.
 */
object Aligner {
    const val FILE = "mms_fa.int8.onnx"
    private const val URL = "https://github.com/left-in/yuyue/releases/download/models-1/mms_fa.int8.onnx"
    /** BLAKE3 of the file (`yuyue digest`). */
    private const val DIGEST = "fad66a4545c60898c382c001aefd26dafb550e3baf58b915480b70dd89d48861"
    private const val BYTES = 317_327_887L
    /** The model's letters a frame (`forced::LETTERS`). */
    const val LETTERS = 28
    private const val RATE = 16_000
    /** 30 s a window, with 2 s either side. */
    private const val HOP = 30 * RATE
    private const val CONTEXT = 2 * RATE

    fun file(dataDir: File) = File(dataDir, "models/$FILE")
    fun installed(dataDir: File) = file(dataDir).isFile

    /** Fetched and checked unless it's here. `progress` hears 0–1. */
    suspend fun ensure(dataDir: File, progress: (Double) -> Unit) = withContext(Dispatchers.IO) {
        if (installed(dataDir)) return@withContext
        val dir = File(dataDir, "models").apply { mkdirs() }
        if (dir.usableSpace < BYTES * 2) throw java.io.IOException("ENOSPC")
        val temp = File(dir, "$FILE.part")
        try {
            OkHttpClient().newCall(Request.Builder().url(URL).build()).execute().use { r ->
                if (!r.isSuccessful) throw java.io.IOException("HTTP ${r.code}")
                val body = r.body ?: throw java.io.IOException("empty")
                val total = body.contentLength().takeIf { it > 0 } ?: BYTES
                body.byteStream().use { input ->
                    temp.outputStream().use { out ->
                        val buf = ByteArray(1 shl 16)
                        var done = 0L
                        var last = 0L
                        while (true) {
                            coroutineContext.ensureActive()
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            done += n
                            if (done - last > (1 shl 20)) {
                                last = done
                                progress(done.toDouble() / total)
                            }
                        }
                    }
                }
            }
            if (uniffi.yuyue_core.fileDigest(temp.path) != DIGEST) throw java.io.IOException("digest")
            if (!temp.renameTo(file(dataDir))) throw java.io.IOException("rename")
        } finally {
            temp.delete()
        }
    }

    /** The model's output for one file: frames × `LETTERS` log probabilities, row by row, and
     *  how long the file is. `progress` hears seconds done. */
    suspend fun emissions(dataDir: File, audio: File, progress: (Double) -> Unit): Triple<FloatArray, Int, Double> = withContext(Dispatchers.Default) {
        val env = OrtEnvironment.getEnvironment()
        val options = OrtSession.SessionOptions().apply {
            setIntraOpNumThreads(maxOf(1, Runtime.getRuntime().availableProcessors() - 1))
        }
        env.createSession(file(dataDir).path, options).use { session ->
            val wave = samples(audio)
            val out = ArrayList<FloatArray>()
            var start = 0
            while (start < wave.size) {
                coroutineContext.ensureActive()
                val a = maxOf(0, start - CONTEXT)
                val b = minOf(wave.size, start + HOP + CONTEXT)
                val x = wave.copyOfRange(a, b)
                // The layer norm the model was trained with, over the window.
                var mean = 0.0
                for (v in x) mean += v
                mean /= x.size
                var variance = 0.0
                for (v in x) variance += (v - mean) * (v - mean)
                variance /= x.size
                val scale = (1 / sqrt(variance + 1e-5)).toFloat()
                for (i in x.indices) x[i] = ((x[i] - mean) * scale).toFloat()
                OnnxTensor.createTensor(env, FloatBuffer.wrap(x), longArrayOf(1, x.size.toLong())).use { input ->
                    session.run(mapOf("wav" to input)).use { result ->
                        val t = result[0] as OnnxTensor
                        val shape = t.info.shape
                        val frames = shape[1].toInt()
                        val values = t.floatBuffer
                        val fps = frames / ((b - a).toDouble() / RATE)
                        val lo = Math.round((start - a).toDouble() / RATE * fps).toInt()
                        val hi = minOf(frames, lo + Math.round(minOf(HOP, wave.size - start).toDouble() / RATE * fps).toInt())
                        val chunk = FloatArray((hi - lo) * LETTERS)
                        values.position(lo * LETTERS)
                        values.get(chunk)
                        out += chunk
                    }
                }
                start += HOP
                progress(minOf(start, wave.size).toDouble() / RATE)
            }
            val all = FloatArray(out.sumOf { it.size })
            var at = 0
            for (c in out) {
                c.copyInto(all, at)
                at += c.size
            }
            Triple(all, all.size / LETTERS, wave.size.toDouble() / RATE)
        }
    }

    /** The file's sound, one channel at 16 kHz, decoded by the system's codecs. */
    private fun samples(audio: File): FloatArray {
        val ex = MediaExtractor()
        ex.setDataSource(audio.path)
        val track = (0 until ex.trackCount).firstOrNull { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
            ?: throw java.io.IOException("no audio")
        ex.selectTrack(track)
        val format = ex.getTrackFormat(track)
        val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(format, null, null, 0)
        codec.start()
        var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val mono = FloatArrayBuilder()
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false
        try {
            while (!outputDone) {
                if (!inputDone) {
                    val i = codec.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        val buf = codec.getInputBuffer(i)!!
                        val n = ex.readSampleData(buf, 0)
                        if (n < 0) {
                            codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(i, 0, n, ex.sampleTime, 0)
                            ex.advance()
                        }
                    }
                }
                val o = codec.dequeueOutputBuffer(info, 10_000)
                when {
                    o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = codec.outputFormat
                        rate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    }
                    o >= 0 -> {
                        val buf = codec.getOutputBuffer(o)!!.order(ByteOrder.nativeOrder())
                        val shorts = buf.asShortBuffer()
                        val frames = shorts.remaining() / channels
                        for (k in 0 until frames) {
                            var sum = 0f
                            for (c in 0 until channels) sum += shorts.get(k * channels + c)
                            mono.add(sum / channels / 32768f)
                        }
                        codec.releaseOutputBuffer(o, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                    }
                }
            }
        } finally {
            codec.stop()
            codec.release()
            ex.release()
        }
        return resample(mono.toArray(), rate, RATE)
    }

    /** Linear resampling to the model's rate: plenty for finding where words are. */
    private fun resample(x: FloatArray, from: Int, to: Int): FloatArray {
        if (from == to) return x
        val n = (x.size.toLong() * to / from).toInt()
        val out = FloatArray(n)
        val step = from.toDouble() / to
        // A light low-pass first when going down a lot (44.1 kHz → 16 kHz), so it doesn't alias.
        val src = if (from > to * 2) smooth(x, (from / to)) else x
        for (i in 0 until n) {
            val p = i * step
            val k = p.toInt()
            val f = (p - k).toFloat()
            val a = src[minOf(k, src.size - 1)]
            val b = src[minOf(k + 1, src.size - 1)]
            out[i] = a + (b - a) * f
        }
        return out
    }

    private fun smooth(x: FloatArray, width: Int): FloatArray {
        val out = FloatArray(x.size)
        var sum = 0f
        for (i in x.indices) {
            sum += x[i]
            if (i >= width) sum -= x[i - width]
            out[i] = sum / minOf(i + 1, width)
        }
        return out
    }

    private class FloatArrayBuilder {
        private var data = FloatArray(1 shl 20)
        private var n = 0
        fun add(v: Float) {
            if (n == data.size) data = data.copyOf(data.size * 2)
            data[n++] = v
        }
        fun toArray() = data.copyOf(n)
    }
}
