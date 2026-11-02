package app.yuyue.shelf

import android.graphics.BitmapFactory
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.media3.common.util.UnstableApi
import app.yuyue.design.ButtonKind
import app.yuyue.design.ButtonSize
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYButton
import app.yuyue.design.YYField
import app.yuyue.design.YYGroup
import app.yuyue.design.YYLabel
import app.yuyue.design.YYNote
import app.yuyue.design.yyCard
import app.yuyue.library.Library
import app.yuyue.speech.AudiobookPlayer
import app.yuyue.t

/** 导入有声书 (prototype v0.30 C1): the cover, name and author read from the files, to change;
 *  the files in the order they'll play, by the numbers in their names, moved up or down with
 *  the arrows when that's wrong. An M4B's own chapters are shown as they are. */
@OptIn(ExperimentalMaterial3Api::class)
@UnstableApi
@Composable
fun AudiobookImportSheet(library: Library, pending: Library.PendingRecording) {
    val context = LocalContext.current
    var audio by remember(pending) { mutableStateOf(pending.audio) }
    var names by remember(pending) { mutableStateOf(pending.names) }
    var title by remember(pending) { mutableStateOf(pending.audio.title) }
    var author by remember(pending) { mutableStateOf(pending.audio.authors.joinToString("、")) }
    val photo = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return@rememberLauncherForActivityResult
        coverJpeg(bytes)?.let { audio = audio.copy(cover = it) }
    }
    fun finish() {
        val authors = author.split('、', ',', '，', ';', '；', '/').map { it.trim() }.filter { it.isNotEmpty() }
        library.finishRecording(pending.copy(audio = audio.copy(title = title.trim().ifEmpty { audio.title }, authors = authors), names = names))
    }
    fun move(i: Int, by: Int) {
        val j = i + by
        if (j !in names.indices) return
        names = names.toMutableList().also { it.add(j, it.removeAt(i)) }
        audio = audio.copy(files = audio.files.toMutableList().also { it.add(j, it.removeAt(i)) })
    }
    val total = audio.files.sumOf { it.seconds }
    ModalBottomSheet({ library.cancelRecording() }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 28.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(t("导入有声书"), style = YY.font(14f, FontWeight.SemiBold), color = YY.c.t1, modifier = Modifier.weight(1f))
                YYButton(t("完成"), ButtonKind.Main, ButtonSize.Small) { finish() }
            }
            Spacer(Modifier.height(14.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                val bitmap = remember(audio.cover) { audio.cover?.let { BitmapFactory.decodeByteArray(it, 0, it.size) } }
                Box(Modifier.size(YY.s(64)).clip(RoundedCornerShape(8.dp)).background(YY.c.inset), contentAlignment = Alignment.Center) {
                    if (bitmap != null) Image(bitmap.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                    else Icon(Icons.headphones, null, tint = YY.c.t3, modifier = Modifier.size(22.dp))
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(t("%lld 个文件 · %@", audio.files.size, length(total)), style = YY.font(10.5f), color = YY.c.t3)
                    YYButton(t("换封面"), ButtonKind.Raised, ButtonSize.Small) { photo.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
                }
            }
            Spacer(Modifier.height(12.dp))
            YYGroup {
                row { YYField(t("书名"), 44f) { Field(title, t("留空就用文件里的")) { title = it } } }
                row { YYField(t("作者"), 44f) { Field(author, t("几位作者用顿号隔开")) { author = it } } }
            }
            if (audio.marks.isNotEmpty()) {
                YYLabel(t("章节 · 文件里自带的"))
                Column(Modifier.fillMaxWidth().yyCard()) {
                    audio.marks.forEachIndexed { i, m -> FileLine(i, m.title ?: t("第 %lld 集", i + 1), null, null) }
                }
            } else {
                YYLabel(t("章节顺序 · 按文件名里的数字排"))
                Column(Modifier.fillMaxWidth().yyCard()) {
                    names.forEachIndexed { i, n ->
                        FileLine(i, n, AudiobookPlayer.clock(audio.files[i].seconds), if (names.size > 1) ({ by: Int -> move(i, by) }) else null)
                    }
                }
                if (names.size > 1) YYNote(t("“第 2 集”排在“第 10 集”前面。顺序不对，点箭头挪一挪。"))
            }
        }
    }
}

@Composable
private fun FileLine(i: Int, name: String, length: String?, move: ((Int) -> Unit)?) {
    Row(Modifier.fillMaxWidth().height(YY.s(40)).padding(horizontal = YY.s(12)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("${i + 1}", style = YY.font(10f).copy(fontFeatureSettings = "tnum"), color = YY.c.t3, modifier = Modifier.width(YY.s(18)))
        Text(name, style = YY.font(10.5f).copy(fontFamily = FontFamily.Monospace), color = YY.c.t2, maxLines = 1, overflow = TextOverflow.MiddleEllipsis, modifier = Modifier.weight(1f))
        length?.let { Text(it, style = YY.font(10.5f).copy(fontFeatureSettings = "tnum"), color = YY.c.t3) }
        if (move != null) {
            Arrow(Icons.chevronUp, t("上移")) { move(-1) }
            Arrow(Icons.chevronDown, t("下移")) { move(1) }
        }
    }
}

@Composable
private fun Arrow(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Box(Modifier.size(28.dp).clip(CircleShape).clickable(onClickLabel = label, onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, label, tint = YY.c.t2, modifier = Modifier.size(16.dp))
    }
}
