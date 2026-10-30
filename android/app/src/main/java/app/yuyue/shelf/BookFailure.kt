package app.yuyue.shelf

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.t

/** 这本书打不开: in place of a book or PDF that could not be opened at all — why, in a
 *  sentence, and the way back to the shelf (as `BookFailureView` on iPhone). */
@Composable
fun BookFailure(reason: String?, close: () -> Unit) {
    Box(Modifier.fillMaxSize().background(YY.c.bg).clickable(enabled = false) {}, contentAlignment = Alignment.Center) {
        Column(
            Modifier.padding(32.dp).widthIn(max = 320.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Icon(Icons.book, null, tint = YY.c.t3, modifier = Modifier.size(40.dp))
            Text(t("这本书打不开"), fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
            Text(reason ?: t("这本书读不出来，文件可能坏了，或者不是它看起来的格式"), fontSize = 13.sp, lineHeight = 20.sp, color = YY.c.t2, textAlign = TextAlign.Center)
            Box(
                Modifier.padding(top = 6.dp).height(40.dp).clip(CircleShape).background(YY.tint.black)
                    .clickable(role = Role.Button, onClick = close).padding(horizontal = 22.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(t("回到书架"), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = YY.tint.onBlack)
            }
        }
    }
}

/** A failure after the book is open (a mark not saved…): the passing 出错了 dialog, gone on 好. */
@Composable
fun FailureDialog(message: String, dismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = dismiss, containerColor = YY.c.card,
        title = { Text(t("出错了"), color = YY.c.t1) }, text = { Text(message, color = YY.c.t2) },
        confirmButton = { TextButton(dismiss) { Text(t("好"), color = YY.tint.accent) } },
    )
}
