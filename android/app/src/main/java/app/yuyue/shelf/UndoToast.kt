package app.yuyue.shelf

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.library.Library
import app.yuyue.t
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.ceil

/** The note after something happened. A plain one is a small white capsule that flashes at the
 *  top; one that can be undone is the wide glass banner instead,
 *  so the two never look alike. */
@Composable
fun UndoToast(toast: Library.Toast, undo: () -> Unit, modifier: Modifier = Modifier) {
    if (toast.undo != null) UndoBanner(toast, undo, modifier) else NoteCapsule(toast, modifier)
}

/** White capsule, as wide as its one line: a round red or green dot with a tick, then the words. */
@Composable
private fun NoteCapsule(toast: Library.Toast, modifier: Modifier) {
    val shown = remember(toast.id) { Animatable(0f) }
    LaunchedEffect(toast.id) { shown.animateTo(1f, spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessMediumLow)) }
    val words = if (toast.detail.isEmpty()) toast.title else "${toast.title} · ${toast.detail}"
    Row(
        modifier
            .widthIn(max = 420.dp)
            .graphicsLayer {
                val v = shown.value
                alpha = v.coerceIn(0f, 1f)
                translationY = (1 - v) * -16.dp.toPx()
                scaleX = 0.94f + 0.06f * v
                scaleY = 0.94f + 0.06f * v
                transformOrigin = TransformOrigin(0.5f, 0f)
            }
            .shadow(12.dp, CircleShape, ambientColor = Color.Black.copy(alpha = 0.05f), spotColor = Color.Black.copy(alpha = if (YY.dark) 0.4f else 0.09f))
            .background(YY.c.card, CircleShape)
            .border(0.5.dp, YY.c.line, CircleShape)
            .height(YY.s(34))
            .padding(start = YY.s(11), end = YY.s(14))
            .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(YY.s(7)),
    ) {
        Box(Modifier.size(YY.s(15)).background(if (toast.danger) YY.c.danger else Done, CircleShape), contentAlignment = Alignment.Center) {
            Icon(Icons.check, null, tint = Color.White, modifier = Modifier.size(YY.s(11)))
        }
        Text(words, style = YY.font(11.5f), color = YY.c.t1, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
    }
}

/** The glass banner across the top: a red ring counting the seconds down, the two lines, and a
 *  round glass button with the undo arrow. At 0 the ring closes into a red tick, the button goes,
 *  and a moment later the banner rises away (Library takes the toast off just after). */
@Composable
private fun UndoBanner(toast: Library.Toast, undo: () -> Unit, modifier: Modifier) {
    val shown = remember(toast.id) { Animatable(0f) }
    val left = remember(toast.id) { Animatable(1f) }
    var done by remember(toast.id) { mutableStateOf(false) }
    val tick = remember(toast.id) { Animatable(0f) }
    LaunchedEffect(toast.id) {
        launch { shown.animateTo(1f, spring(dampingRatio = 0.75f, stiffness = Spring.StiffnessMediumLow)) }
        left.animateTo(0f, tween(Library.UNDO_MS.toInt(), easing = LinearEasing))
        done = true
        tick.animateTo(1f, spring(dampingRatio = 0.45f, stiffness = Spring.StiffnessMedium))
        delay(Library.UNDO_SETTLE_MS)
        shown.animateTo(0f, tween(300))
    }
    val shape = RoundedCornerShape(YY.s(20))
    Row(
        modifier
            .fillMaxWidth()
            .widthIn(max = 460.dp)
            .graphicsLayer {
                val v = shown.value
                alpha = v.coerceIn(0f, 1f)
                translationY = (1 - v) * -18.dp.toPx()
            }
            .shadow(14.dp, shape, ambientColor = Color.Black.copy(alpha = 0.06f), spotColor = Color.Black.copy(alpha = if (YY.dark) 0.5f else 0.18f))
            .background(YY.c.glass, shape)
            .border(0.5.dp, YY.c.line, shape)
            .padding(start = YY.s(13), end = YY.s(10), top = YY.s(11), bottom = YY.s(11))
            .semantics(mergeDescendants = true) {
                liveRegion = LiveRegionMode.Polite
                if (!done) customActions = listOf(CustomAccessibilityAction(t("撤销")) { undo(); true })
            },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(YY.s(12)),
    ) {
        CountdownRing(left.value, tick.value, done)
        Column(Modifier.weight(1f)) {
            Text(toast.title, style = YY.font(13f, FontWeight.SemiBold), color = YY.c.t1, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (toast.detail.isNotEmpty()) Text(toast.detail, style = YY.font(10.5f), color = YY.c.t2, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        // A round glass button with only the arrow; it fades as the tick comes.
        val gone = tick.value.coerceIn(0f, 1f)
        Box(
            Modifier.size(YY.s(36)).graphicsLayer { alpha = 1 - gone; scaleX = 1 - 0.1f * gone; scaleY = 1 - 0.1f * gone }
                .clip(CircleShape).background(YY.c.t1.copy(alpha = 0.06f)).border(0.5.dp, YY.c.line, CircleShape)
                .clickable(enabled = !done, onClickLabel = t("撤销"), onClick = undo),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.undo, t("撤销"), tint = YY.tint.accent, modifier = Modifier.size(YY.s(17)))
        }
    }
}

/** A thin red ring with the seconds left inside, draining as they go; then a red disc with a tick. */
@Composable
private fun CountdownRing(left: Float, tick: Float, done: Boolean) {
    val red = YY.c.danger
    val seconds = ceil(left * Library.UNDO_MS / 1000f).toInt().coerceAtLeast(1)
    Box(Modifier.size(YY.s(26)), contentAlignment = Alignment.Center) {
        if (!done) {
            Canvas(Modifier.fillMaxSize()) {
                val w = YY.K * 2.2f * density
                val inset = w / 2
                val arc = Size(size.width - w, size.height - w)
                drawArc(red.copy(alpha = 0.18f), 0f, 360f, false, Offset(inset, inset), arc, style = Stroke(w))
                // Drains anticlockwise from the top.
                drawArc(red, -90f, -360f * left, false, Offset(inset, inset), arc, style = Stroke(w, cap = StrokeCap.Round))
            }
            Text("$seconds", style = YY.font(11.5f, FontWeight.Bold).copy(fontFeatureSettings = "tnum"), color = red)
        } else {
            Box(
                Modifier.fillMaxSize().graphicsLayer { val s = 0.4f + 0.6f * tick; scaleX = s; scaleY = s; alpha = tick.coerceIn(0f, 1f) }
                    .background(red, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.check, null, tint = Color.White, modifier = Modifier.size(YY.s(15)))
            }
        }
    }
}

/** A green tick for a plain note; a deletion is red. */
private val Done = Color(0xFF2DBE60)

val Library.Toast.Icon.vector: ImageVector
    get() = when (this) {
        Library.Toast.Icon.Delete -> Icons.delete
        Library.Toast.Icon.Highlight -> Icons.highlighter
        Library.Toast.Icon.Add -> Icons.add
        Library.Toast.Icon.Folder -> Icons.folder
        Library.Toast.Icon.Download -> Icons.cloudDownload
        Library.Toast.Icon.Check -> Icons.checkCircle
        Library.Toast.Icon.Share -> Icons.upload
        Library.Toast.Icon.Error -> Icons.error
    }
