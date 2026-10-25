package app.yuyue.shelf

import androidx.compose.animation.core.Animatable
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.layout.widthIn
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.library.Library
import app.yuyue.t

/** The note after deleting or importing, as 即刻's toast (its “已设置”, measured off a screenshot):
 *  a pale grey capsule at the top, as wide as its one line, the same room either side, a small
 *  filled round icon before the words. When the thing can be undone, 撤销 follows the words. */
@Composable
fun UndoToast(toast: Library.Toast, undo: () -> Unit, modifier: Modifier = Modifier) {
    val dark = YY.dark
    val shown = remember(toast.id) { Animatable(0f) }
    LaunchedEffect(toast.id) { shown.animateTo(1f, spring(dampingRatio = 0.7f, stiffness = Spring.StiffnessMediumLow)) }
    Row(
        modifier
            .widthIn(max = 420.dp)
            .graphicsLayer {
                val v = shown.value
                alpha = v.coerceIn(0f, 1f)
                translationY = (1 - v) * -24.dp.toPx()
                scaleX = 0.92f + 0.08f * v
                scaleY = 0.92f + 0.08f * v
                transformOrigin = TransformOrigin(0.5f, 0f)
            }
            .shadow(10.dp, CircleShape, ambientColor = Color.Black.copy(alpha = 0.06f), spotColor = Color.Black.copy(alpha = if (dark) 0.3f else 0.08f))
            .background(if (dark) Color(0xF5333333) else Color(0xF8E9E9E9), CircleShape)
            .height(45.dp)
            .padding(horizontal = 25.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        Box(Modifier.size(17.dp).background(if (toast.danger) YY.c.danger else Done, CircleShape), contentAlignment = Alignment.Center) {
            Icon(if (toast.danger) Icons.close else Icons.check, null, tint = Color.White, modifier = Modifier.size(11.dp))
        }
        Text(toast.title, fontSize = 15.sp, color = if (dark) Color(0xFFEBEBEB) else Color(0xFF333333), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
        if (toast.undo != null) {
            Box(Modifier.height(36.dp).clip(RoundedCornerShape(8.dp)).clickable(onClick = undo).padding(horizontal = 4.dp), contentAlignment = Alignment.Center) {
                Text(t("撤销"), fontSize = 15.sp, fontWeight = FontWeight.Medium, color = YY.tint.accent)
            }
        }
    }
}

/** 即刻's green tick; a deletion is red. */
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
