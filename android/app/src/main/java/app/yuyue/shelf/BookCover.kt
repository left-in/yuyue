package app.yuyue.shelf

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYPapers
import app.yuyue.design.rememberPref
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import uniffi.yuyue_core.BookSummary

/** The cover, or a plain paper with the title when the book has none. */
@Composable
fun BookCover(book: BookSummary, modifier: Modifier = Modifier) {
    if (book.format == uniffi.yuyue_core.BookFormat.AUDIO) {
        // A recording's cover is square, at the bottom of the book's place.
        Box(modifier.aspectRatio(2f / 3f), contentAlignment = Alignment.BottomCenter) { SquareCover(book, Modifier.fillMaxWidth(), radius = 4.dp, shadow = 3.dp) }
        return
    }
    var bitmap by remember(book.coverPath) { mutableStateOf(book.coverPath?.let(Thumbnails::cached)) }
    LaunchedEffect(book.coverPath) {
        if (bitmap == null) bitmap = book.coverPath?.let { Thumbnails.load(it, 600) }
    }
    // 墨水屏模式: covers in grey.
    val eink by rememberPref("eink.on", false)
    val shape = RoundedCornerShape(4.dp)
    Box(
        modifier
            .aspectRatio(2f / 3f)
            .shadow(if (eink) 0.dp else 3.dp, shape, ambientColor = Color.Black.copy(alpha = 0.08f), spotColor = Color.Black.copy(alpha = 0.12f))
            .clip(shape)
            .border(0.5.dp, YY.c.line, shape),
    ) {
        val b = bitmap
        if (b != null) {
            Image(
                b.asImageBitmap(), null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
                colorFilter = if (eink) ColorFilter.colorMatrix(ColorMatrix().apply { setToSaturation(0f) }) else null,
            )
        } else {
            Placeholder(book)
        }
    }
}

@Composable
private fun Placeholder(book: BookSummary) {
    // Sized to the cover, so it reads the same on a small card and in the grid.
    BoxWithConstraints(Modifier.fillMaxSize().background(YYPapers.Kami.bg)) {
        val unit = maxWidth.value / 100
        Column(Modifier.padding((11 * unit).dp)) {
            Text(
                book.title, maxLines = 4, overflow = TextOverflow.Ellipsis,
                fontFamily = YY.serif, fontWeight = FontWeight.SemiBold, fontSize = (14 * unit).sp, lineHeight = (18 * unit).sp,
                color = YYPapers.Kami.ink,
            )
            book.authors.firstOrNull()?.let {
                Text(it, maxLines = 1, fontFamily = YY.serif, fontSize = (9.5 * unit).sp, color = YYPapers.Kami.ink2, modifier = Modifier.padding(top = (5 * unit).dp))
            }
        }
        // I2: a PDF with no cover of its own says what it is, small, at the bottom.
        if (book.format == uniffi.yuyue_core.BookFormat.PDF) {
            Text(
                "PDF", fontSize = (8.5 * unit).sp, fontWeight = FontWeight.Medium, letterSpacing = (0.6 * unit).sp, color = YYPapers.Kami.ink2,
                modifier = Modifier.align(Alignment.BottomStart).padding((11 * unit).dp),
            )
        }
    }
}

/** A recording's cover, square; the headphones on grey when it has none. */
@Composable
fun SquareCover(book: BookSummary, modifier: Modifier = Modifier, radius: Dp = 10.dp, shadow: Dp = 14.dp) {
    var bitmap by remember(book.coverPath) { mutableStateOf(book.coverPath?.let(Thumbnails::cached)) }
    LaunchedEffect(book.coverPath) {
        if (bitmap == null) bitmap = book.coverPath?.let { Thumbnails.load(it, 600) }
    }
    val eink by rememberPref("eink.on", false)
    val shape = RoundedCornerShape(radius)
    Box(
        modifier
            .aspectRatio(1f)
            .shadow(if (eink) 0.dp else shadow, shape, ambientColor = Color.Black.copy(alpha = 0.12f), spotColor = Color.Black.copy(alpha = 0.18f))
            .clip(shape)
            .background(YY.c.inset)
            .border(0.5.dp, Color.Black.copy(alpha = 0.12f), shape),
        contentAlignment = Alignment.Center,
    ) {
        val b = bitmap
        if (b != null) {
            Image(
                b.asImageBitmap(), null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
                colorFilter = if (eink) ColorFilter.colorMatrix(ColorMatrix().apply { setToSaturation(0f) }) else null,
            )
        } else {
            Icon(Icons.headphones, null, tint = YY.c.t3, modifier = Modifier.fillMaxSize(0.25f))
        }
    }
}

/** `.v-aud`: the headphones on a cover with a recording. */
@Composable
fun AudioBadge(modifier: Modifier = Modifier) {
    Box(modifier.padding(5.dp).size(18.dp).clip(CircleShape).background(Color(0xB8101214)), contentAlignment = Alignment.Center) {
        Icon(Icons.headphones, null, tint = Color.White, modifier = Modifier.size(10.dp))
    }
}

object Thumbnails {
    private val cache = object : LruCache<String, Bitmap>(48 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }

    fun cached(path: String): Bitmap? = cache.get(path)

    /** Decodes a small version of an image file off the main thread. */
    suspend fun load(path: String, maxPixels: Int): Bitmap? = withContext(Dispatchers.IO) {
        cache.get(path)?.let { return@withContext it }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0) return@withContext null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxPixels) sample *= 2
        val bitmap = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return@withContext null
        cache.put(path, bitmap)
        bitmap
    }
}
