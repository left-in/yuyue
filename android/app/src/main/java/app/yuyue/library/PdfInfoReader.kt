package app.yuyue.library

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.ParcelFileDescriptor
import uniffi.yuyue_core.PdfInfo
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * What the core can't read from a PDF itself, as on Apple: how many pages, how much text, and
 * the first page as a cover. The system renderer gives no title or author, so the file's name
 * stands in (the core's fallback).
 */
object PdfInfoReader {
    class Locked : Exception()
    class Unreadable : Exception()

    fun read(file: File): PdfInfo {
        val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        val renderer = try {
            PdfRenderer(fd)
        } catch (e: SecurityException) {
            fd.close()
            throw Locked()
        } catch (e: Exception) {
            fd.close()
            throw Unreadable()
        }
        renderer.use { r ->
            if (r.pageCount == 0) throw Unreadable()
            // Counting a thousand pages takes a while; the first hundred tell enough.
            val sample = minOf(r.pageCount, 100)
            var characters = 0L
            if (Build.VERSION.SDK_INT >= 35) {
                for (i in 0 until sample) r.openPage(i).use { p -> characters += p.textContents.sumOf { c -> c.text.count { !it.isWhitespace() } } }
                characters = characters * r.pageCount / sample
            } else {
                // Without the text, a page of a book is about six hundred characters.
                characters = r.pageCount * 600L
            }
            // I2: a first page full of text shrunk down is a grey smudge; such a PDF gets the
            // paper cover with its title. (Before Android 15 the text can't be read: the page it is.)
            val wordy = Build.VERSION.SDK_INT >= 35 && r.openPage(0).use { p -> p.textContents.sumOf { c -> c.text.count { !it.isWhitespace() } } } > 400
            return PdfInfo(r.pageCount.toUInt(), null, emptyList(), characters.toULong(), if (wordy) null else cover(r))
        }
    }

    /** The first page, 600 pixels wide, on white. */
    private fun cover(r: PdfRenderer): ByteArray? = r.openPage(0).use { page ->
        if (page.width <= 0 || page.height <= 0) return null
        val w = 600
        val h = (page.height * 600f / page.width).toInt()
        if (h <= 0 || h > 4000) return null
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.WHITE)
        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
        ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
            bitmap.recycle()
            out.toByteArray()
        }
    }
}
