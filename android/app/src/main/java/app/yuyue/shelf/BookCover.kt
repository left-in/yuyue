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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYPapers
import app.yuyue.design.rememberPref
import app.yuyue.library.isComic
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import uniffi.yuyue_core.BookSummary

/** The cover, or a plain paper with the title when the book has none. */
@Composable
fun BookCover(book: BookSummary, modifier: Modifier = Modifier) {
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
    }
}

/** A comic of many 话 sits as a little stack: two page edges behind the cover, and how many 话 in the corner. */
@Composable
fun ComicStack(book: BookSummary, content: @Composable () -> Unit) {
    val episodes = if (book.isComic) book.episodes.toInt() else 0
    if (episodes <= 1) return content()
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        Box(Modifier.align(Alignment.TopCenter).offset(y = (-7).dp).fillMaxWidth(0.72f).height(6.dp).clip(RoundedCornerShape(topStart = 3.dp, topEnd = 3.dp)).background(YY.c.t3.copy(alpha = 0.35f)))
        Box(Modifier.align(Alignment.TopCenter).offset(y = (-4).dp).fillMaxWidth(0.86f).height(6.dp).clip(RoundedCornerShape(topStart = 3.dp, topEnd = 3.dp)).background(YY.c.t3.copy(alpha = 0.6f)))
        content()
        Text(
            t("%lld 话", episodes), fontSize = 10.sp, color = Color.White,
            modifier = Modifier.align(Alignment.BottomStart).padding(5.dp).clip(RoundedCornerShape(4.dp)).background(Color.Black.copy(alpha = 0.58f)).padding(horizontal = 5.dp, vertical = 3.dp),
        )
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
