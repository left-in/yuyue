package app.yuyue.shelf

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.text.format.Formatter
import android.view.WindowManager
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import app.yuyue.design.ButtonKind
import app.yuyue.design.ButtonSize
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYButton
import app.yuyue.design.YYGroup
import app.yuyue.design.YYNote
import app.yuyue.design.YYPage
import app.yuyue.design.yyCard
import app.yuyue.library.Library
import app.yuyue.library.WifiTransfer
import app.yuyue.t

/** Wi‑Fi 传书 (prototype 导入), as on iPhone: the address in big type, whether a computer has come,
 *  and a row for each file coming over — how far, how long still, and when it's on the shelf. */
@Composable
fun WifiPage(library: Library) {
    val context = LocalContext.current
    val transfer = remember { WifiTransfer(context, library) }
    var copied by remember { mutableStateOf(false) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        transfer.start()
        // The screen stays on while the page is open: a sleeping phone drops the connection.
        (context as? Activity)?.window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val observer = LifecycleEventObserver { _, e ->
            if (e == Lifecycle.Event.ON_START) transfer.start() else if (e == Lifecycle.Event.ON_STOP) transfer.stop()
        }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            transfer.stop()
            (context as? Activity)?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }
    YYPage {
        Column(Modifier.padding(top = YY.s(8)).fillMaxWidth().yyCard().padding(horizontal = YY.s(16)).padding(top = YY.s(16), bottom = YY.s(14))) {
            Text(t("在电脑浏览器里打开"), style = YY.font(10.5f), color = YY.c.t3)
            Row(Modifier.padding(top = YY.s(6)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(8))) {
                val address = transfer.address
                if (address != null && transfer.problem == null) {
                    Text(address, style = YY.font(19f, FontWeight.Bold, FontFamily.Monospace), color = YY.c.t1, modifier = Modifier.weight(1f))
                    YYButton(if (copied) t("已复制") else t("复制"), ButtonKind.Raised, ButtonSize.Small, icon = if (copied) Icons.check else null) {
                        (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("", "http://$address"))
                        copied = true
                    }
                } else {
                    Text(transfer.problem ?: t("正在准备…"), style = YY.font(14f, FontWeight.SemiBold), color = if (transfer.problem == null) YY.c.t2 else YY.c.danger)
                }
            }
            Box(Modifier.padding(top = YY.s(12)).fillMaxWidth().height(0.5.dp).background(YY.c.line))
            Row(Modifier.padding(top = YY.s(11)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(6))) {
                Box(Modifier.size(YY.s(6)).background(if (transfer.client == null) YY.c.t3 else YY.c.ok, CircleShape))
                Text(
                    transfer.client?.let { if (it.isEmpty()) t("已连上一台电脑") else t("已连上一台电脑 · %@", it) } ?: t("电脑和这台手机连同一个 Wi‑Fi"),
                    style = YY.font(10.5f), color = YY.c.t2,
                )
            }
        }
        if (transfer.items.isNotEmpty()) {
            Row(Modifier.padding(top = YY.s(18), bottom = YY.s(8), start = 2.dp, end = 2.dp)) {
                Text(t("正在接收"), style = YY.font(12.5f, FontWeight.SemiBold), color = YY.c.t1, modifier = Modifier.weight(1f))
                Text(t("%lld 个文件", transfer.items.size), style = YY.font(10.5f), color = YY.c.t3)
            }
            YYGroup { for (item in transfer.items) row { Item(item) } }
        }
        YYNote(t("传的时候让这一页亮着；锁屏会断开，回来后从断的地方接着传。"))
    }
}

@Composable
private fun Item(item: WifiTransfer.Item) {
    val failed = item.state is WifiTransfer.Item.State.Failed
    Row(Modifier.padding(vertical = YY.s(9)), horizontalArrangement = Arrangement.spacedBy(YY.s(10))) {
        Box(Modifier.size(YY.s(28)).background(YY.c.inset, RoundedCornerShape(YY.s(8))), contentAlignment = Alignment.Center) {
            val icon = when {
                item.state == WifiTransfer.Item.State.Done -> Icons.check
                failed -> Icons.error
                item.name.substringAfterLast('.').lowercase() in setOf("cbz", "cbr", "zip", "rar") -> Icons.grid
                else -> Icons.book
            }
            Icon(icon, null, tint = YY.c.t1, modifier = Modifier.size(YY.s(14)))
        }
        Column(Modifier.weight(1f)) {
            Text(item.name, style = YY.font(11f, FontWeight.SemiBold), color = YY.c.t1, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
            val detail = when (val s = item.state) {
                WifiTransfer.Item.State.Queued -> if (item.received > 0) t("停在 %lld%%，等电脑接着传", (item.received * 100 / maxOf(item.size, 1)).toInt()) else t("排队中")
                WifiTransfer.Item.State.Receiving -> WifiTransfer.progress(item)
                WifiTransfer.Item.State.Importing -> t("正在放进书架…")
                WifiTransfer.Item.State.Done -> t("已经放进书架")
                is WifiTransfer.Item.State.Failed -> s.message
            }
            Text(Formatter.formatShortFileSize(LocalContext.current, item.size) + " · " + detail, style = YY.font(10f), color = if (failed) YY.c.danger else YY.c.t3, maxLines = 2)
            if (item.state == WifiTransfer.Item.State.Receiving) {
                BoxWithConstraints(Modifier.padding(top = YY.s(4)).fillMaxWidth().height(3.dp).background(YY.c.inset, CircleShape)) {
                    Box(Modifier.width(maxWidth * (item.received.toFloat() / maxOf(item.size, 1))).height(3.dp).background(YY.tint.accent, CircleShape))
                }
            }
        }
    }
}
