package app.yuyue.notes

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.ButtonKind
import app.yuyue.design.ButtonSize
import app.yuyue.design.YY
import app.yuyue.design.YYButton
import app.yuyue.design.YYPapers
import app.yuyue.design.YYSegments
import app.yuyue.design.rememberPref
import app.yuyue.shelf.Thumbnails
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** 分享书摘, as on Apple: one highlighted sentence on a card, with a little
 *  cover and where it comes from, a small 语阅 in the corner, and the thought if wanted. */
class QuoteShare(val text: String, val note: String?, val title: String, val author: String?, val chapter: String?, val coverPath: String?)

enum class QuoteLook(val key: String) {
    Cover("cover"), Paper("paper"), White("white"), Dark("dark");

    val title: String get() = when (this) { Cover -> t("封面色"); Paper -> t("纸本"); White -> t("素白"); Dark -> t("暗黑") }
}

enum class QuoteShape(val key: String, val width: Dp, val height: Dp) {
    Portrait("portrait", 270.dp, 360.dp), Square("square", 320.dp, 320.dp), Landscape("landscape", 400.dp, 250.dp);

    val title: String get() = when (this) { Portrait -> t("竖图"); Square -> t("方图"); Landscape -> t("横图") }
}

private class QuoteColors(val bg: Color, val ink: Color, val ink2: Color, val accent: Color, val framed: Boolean)

private fun colors(look: QuoteLook, cover: Color?): QuoteColors = when (look) {
    QuoteLook.Cover -> QuoteColors(cover ?: Color(0xFF2F3A33), Color(0xFFF1EADA), Color(0xFFC8BFA6), Color(0xFFC8BFA6), true)
    QuoteLook.Paper -> YYPapers.Kami.let { QuoteColors(it.bg, it.ink, it.ink2, it.accent, false) }
    QuoteLook.White -> YYPapers.Plain.let { QuoteColors(Color.White, it.ink, it.ink2, it.paperAccent, false) }
    QuoteLook.Dark -> YYPapers.Dark.let { QuoteColors(it.bg, it.ink, it.ink2, it.paperAccent, false) }
}

/** The cover's average colour, deepened so light words read on it. */
private fun deep(b: Bitmap): Color {
    val one = Bitmap.createScaledBitmap(b, 1, 1, true).getPixel(0, 0)
    val hsv = FloatArray(3)
    android.graphics.Color.colorToHSV(one, hsv)
    hsv[1] = hsv[1].coerceIn(0.12f, 0.38f)
    hsv[2] = minOf(hsv[2], 0.27f)
    return Color(android.graphics.Color.HSVToColor(hsv))
}

/** The card itself, the same on screen and in the picture. */
@Composable
private fun QuoteCard(quote: QuoteShare, look: QuoteLook, shape: QuoteShape, withNote: Boolean, cover: Bitmap?, modifier: Modifier = Modifier) {
    val c = colors(look, cover?.let(::deep))
    val wide = shape == QuoteShape.Landscape
    Box(modifier.requiredSize(shape.width, shape.height).background(c.bg)) {
        if (c.framed) Box(Modifier.fillMaxSize().padding(9.dp).border(0.6.dp, c.ink2.copy(alpha = 0.5f)))
        Column(Modifier.fillMaxSize().padding(start = if (wide) 26.dp else 28.dp, end = if (wide) 26.dp else 28.dp, top = if (wide) 26.dp else 32.dp, bottom = 22.dp)) {
            if (wide) Box(Modifier.padding(bottom = 14.dp).width(28.dp).height(1.dp).background(c.accent))
            else Text("“", fontFamily = YY.serif, fontSize = 34.sp, lineHeight = 34.sp, color = c.ink2.copy(alpha = 0.75f), modifier = Modifier.height(18.dp).padding(bottom = 0.dp))
            if (!wide) Spacer(Modifier.height(12.dp))
            Text(
                quote.text, fontFamily = YY.serif, fontWeight = if (wide) FontWeight.Medium else FontWeight.SemiBold,
                fontSize = if (wide) 14.5.sp else 16.sp, lineHeight = if (wide) 25.sp else 28.sp, letterSpacing = 0.5.sp, color = c.ink,
                maxLines = when (shape) { QuoteShape.Portrait -> 9; QuoteShape.Square -> 8; QuoteShape.Landscape -> 5 }, overflow = TextOverflow.Ellipsis,
            )
            val note = quote.note
            if (withNote && note != null) Row(Modifier.padding(top = 14.dp), horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                Box(Modifier.width(1.5.dp).height(16.dp).background(c.accent))
                Text(note, fontSize = 12.sp, lineHeight = 18.sp, color = c.ink2, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
            Spacer(Modifier.weight(1f).height(12.dp))
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(Modifier.size(20.dp, 30.dp).shadow(3.dp).background(c.ink2.copy(alpha = 0.3f))) {
                    cover?.let { Image(it.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Text(quote.title, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.4.sp, color = c.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    val sub = listOfNotNull(quote.author, quote.chapter).joinToString(" · ")
                    if (sub.isNotEmpty()) Text(sub, fontSize = 9.5.sp, color = c.ink2, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Text(t("语阅"), fontSize = 9.5.sp, letterSpacing = 1.2.sp, color = c.ink2.copy(alpha = 0.8f))
            }
        }
    }
}

/** 书摘分享 on the phone: the card as it will look, its colours and shape, and the system's share
 *  sheet for the picture. The last look and shape are kept. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QuoteShareSheet(quote: QuoteShare, dismiss: () -> Unit) {
    val context = LocalContext.current
    var lookKey by rememberPref("share.look", QuoteLook.Cover.key)
    var shapeKey by rememberPref("share.shape", QuoteShape.Portrait.key)
    val look = QuoteLook.entries.firstOrNull { it.key == lookKey } ?: QuoteLook.Cover
    val shape = QuoteShape.entries.firstOrNull { it.key == shapeKey } ?: QuoteShape.Portrait
    var withNote by remember { mutableStateOf(true) }
    var cover by remember { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(quote.coverPath) { cover = quote.coverPath?.let { Thumbnails.load(it, 360) } }
    val layer = rememberGraphicsLayer()
    val scope = rememberCoroutineScope()
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 28.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(t("书摘分享"), style = YY.font(14f, FontWeight.Bold), color = YY.c.t1)
            val scale = minOf(1f, 330f / shape.width.value)
            Box(Modifier.padding(top = 16.dp).size(shape.width * scale, shape.height * scale).shadow(10.dp), contentAlignment = Alignment.Center) {
                QuoteCard(
                    quote, look, shape, withNote && quote.note != null, cover,
                    Modifier.scale(scale).drawWithContent {
                        layer.record { this@drawWithContent.drawContent() }
                        drawLayer(layer)
                    },
                )
            }
            Column(Modifier.padding(top = 22.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                YYSegments(QuoteLook.entries.map { it.key to it.title }, look.key, { lookKey = it }, modifier = Modifier.fillMaxWidth())
                YYSegments(QuoteShape.entries.map { it.key to it.title }, shape.key, { shapeKey = it }, modifier = Modifier.fillMaxWidth())
                if (quote.note != null) Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(t("带上想法"), style = YY.font(12f), color = YY.c.t1, modifier = Modifier.weight(1f))
                    Switch(withNote, { withNote = it }, colors = SwitchDefaults.colors(checkedTrackColor = YY.tint.fill, checkedThumbColor = YY.c.card, uncheckedTrackColor = YY.c.inset, uncheckedBorderColor = YY.c.line))
                }
                YYButton(t("分享"), ButtonKind.Main, ButtonSize.Large, wide = true) {
                    scope.launch {
                        val bitmap = layer.toImageBitmap().asAndroidBitmap()
                        val file = withContext(Dispatchers.IO) { save(context, bitmap, quote.title) }
                        NoteExport.share(context, file, "image/png")
                    }
                }
            }
        }
    }
}

private fun save(context: Context, bitmap: Bitmap, title: String): File {
    val dir = File(context.cacheDir, "export").apply { mkdirs() }
    val file = File(dir, t("%@ 书摘", title).replace(Regex("""[/\\:]"""), "-") + ".png")
    file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    return file
}
