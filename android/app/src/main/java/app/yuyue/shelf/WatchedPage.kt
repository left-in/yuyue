package app.yuyue.shelf

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.yuyue.design.ButtonKind
import app.yuyue.design.ButtonSize
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYButton
import app.yuyue.design.YYGroup
import app.yuyue.design.YYNote
import app.yuyue.design.YYPage
import app.yuyue.design.YYRow
import app.yuyue.library.Library
import app.yuyue.t
import kotlinx.coroutines.launch

/** 监听一个文件夹, as on iPhone: the folder, 选一个 / 换一个, 停止监听. */
@Composable
fun WatchedPage(library: Library) {
    val watched = library.watched
    var working by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        working = true
        scope.launch {
            try {
                watched.choose(uri, library)
            } catch (e: Exception) {
                library.alert = Library.message(e)
            }
            working = false
        }
    }
    YYPage {
        Text(
            t("放进这个文件夹的书，下次打开语阅时自动导入。可以是手机里的任何文件夹，比如“下载”或者网盘 App 同步下来的文件夹。"),
            style = YY.font(10.5f), color = YY.c.t2, modifier = Modifier.padding(start = 4.dp, end = 4.dp, top = YY.s(10), bottom = YY.s(14)),
        )
        YYGroup { row { YYRow(t("文件夹"), Icons.folder, watched.name ?: t("还没选")) } }
        Spacer(Modifier.height(YY.s(14)))
        YYButton(if (working) "…" else if (watched.name == null) t("选一个文件夹") else t("换一个文件夹"), ButtonKind.Main, ButtonSize.Large, wide = true, enabled = !working) { picker.launch(null) }
        if (watched.name != null) {
            Spacer(Modifier.height(YY.s(6)))
            YYButton(t("停止监听"), ButtonKind.Plain, ButtonSize.Large, wide = true) { watched.stop() }
        }
        YYNote(t("从书架删掉的书不会再导入；文件改过以后会当成新的一本。"))
    }
}
