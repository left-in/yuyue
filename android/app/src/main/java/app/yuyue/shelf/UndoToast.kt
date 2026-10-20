package app.yuyue.shelf

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.updateTransition
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.library.Library
import app.yuyue.t

/** The glass note at the bottom after deleting or importing, with 撤销 and a line running out
 *  over the seconds it stays. A delete shows red. */
@Composable
fun UndoToast(toast: Library.Toast, undo: () -> Unit, modifier: Modifier = Modifier) {
    val tint = YY.tint
    var started by remember(toast.id) { mutableStateOf(false) }
    LaunchedEffect(toast.id) { started = true }
    val left by updateTransition(started, label = "left").animateFloat({ tween(Library.TOAST_MS.toInt(), easing = LinearEasing) }, label = "left") { if (it) 0f else 1f }
    val accent = if (toast.danger) YY.c.danger else tint.accent
    Box(
        modifier
            .fillMaxWidth()
            .shadow(15.dp, CircleShape, ambientColor = Color.Black.copy(alpha = 0.12f), spotColor = Color.Black.copy(alpha = 0.18f))
            .clip(CircleShape)
            .background(YY.c.card.copy(alpha = 0.96f))
            .border(0.5.dp, YY.c.line.copy(alpha = 0.6f), CircleShape),
    ) {
        Row(
            Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            Box(Modifier.size(36.dp).clip(CircleShape).background(if (toast.danger) YY.c.danger.copy(alpha = 0.14f) else tint.accentSoft), contentAlignment = Alignment.Center) {
                Icon(toast.icon.vector, null, tint = accent, modifier = Modifier.size(17.dp))
            }
            Column(Modifier.weight(1f)) {
                Text(toast.title, fontSize = 12.5.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1, maxLines = 1)
                if (toast.detail.isNotEmpty()) Text(toast.detail, fontSize = 10.5.sp, color = YY.c.t2, maxLines = 1)
            }
            if (toast.undo != null) {
                Row(
                    Modifier.height(36.dp).clip(CircleShape).background(tint.black).clickable(onClick = undo).padding(horizontal = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    Icon(Icons.undo, null, tint = tint.onBlack, modifier = Modifier.size(15.dp))
                    Text(t("撤销"), fontSize = 12.5.sp, fontWeight = FontWeight.SemiBold, color = tint.onBlack)
                }
            }
        }
        BoxWithConstraints(Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(horizontal = 24.dp)) {
            Box(Modifier.width(maxWidth * left).height(2.dp).clip(CircleShape).background(tint.accent.copy(alpha = 0.55f)))
        }
    }
}

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
