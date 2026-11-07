package app.yuyue.shelf

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.yuyue.design.ButtonKind
import app.yuyue.design.ButtonSize
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYButton
import app.yuyue.design.YYField
import app.yuyue.design.YYGroup
import app.yuyue.design.YYLabel
import app.yuyue.design.YYNote
import app.yuyue.design.YYRow
import app.yuyue.library.Library
import app.yuyue.library.ShelfFilter
import app.yuyue.library.title
import app.yuyue.t
import uniffi.yuyue_core.ReadingStatus
import java.io.ByteArrayOutputStream

/** 看哪些书: all, a status the app keeps, or one of your 合集 — which can be made, renamed and deleted here. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShelfChooser(library: Library, filter: ShelfFilter, choose: (ShelfFilter) -> Unit, dismiss: () -> Unit) {
    var naming by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf<uniffi.yuyue_core.BookCollection?>(null) }
    var menuFor by remember { mutableStateOf<String?>(null) }
    /** The collection whose icon is being picked. */
    var iconFor by remember { mutableStateOf<uniffi.yuyue_core.BookCollection?>(null) }
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(), containerColor = YY.c.bg) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 28.dp)) {
            Text(t("看哪些书"), style = YY.font(14f, FontWeight.Bold), color = YY.c.t1, modifier = Modifier.padding(start = 4.dp, bottom = 8.dp))
            fun pick(f: ShelfFilter) { choose(f); dismiss() }
            YYGroup {
                row { ChoiceRow(t("全部"), Icons.books, library.books.size, filter == ShelfFilter.All) { pick(ShelfFilter.All) } }
            }
            YYLabel(t("按状态"))
            YYGroup {
                for (s in listOf(ReadingStatus.READING, ReadingStatus.WANT, ReadingStatus.FINISHED)) {
                    row {
                        val icon = when (s) { ReadingStatus.READING -> Icons.book; ReadingStatus.WANT -> Icons.bookmarkOutline; ReadingStatus.FINISHED -> Icons.checkCircle }
                        ChoiceRow(s.title, icon, library.books.count { it.status == s }, filter == ShelfFilter.Status(s)) { pick(ShelfFilter.Status(s)) }
                    }
                }
            }
            YYLabel(t("合集"))
            YYGroup {
                for (c in library.collections) {
                    row {
                        ChoiceRow(c.name, app.yuyue.library.CollectionIcon.of(c), c.count.toInt(), filter == ShelfFilter.Collection(c.id), onLong = { menuFor = c.id }) { pick(ShelfFilter.Collection(c.id)) }
                        androidx.compose.material3.DropdownMenu(menuFor == c.id, { menuFor = null }, containerColor = YY.c.card) {
                            Item(t("重命名"), Icons.edit) { menuFor = null; renaming = c }
                            Item(t("换图标"), app.yuyue.library.CollectionIcon.of(c)) { menuFor = null; iconFor = c }
                            Item(t("删除"), Icons.delete, danger = true) {
                                menuFor = null
                                if (filter == ShelfFilter.Collection(c.id)) choose(ShelfFilter.All)
                                library.deleteCollection(c)
                            }
                        }
                    }
                }
                row {
                    Row(Modifier.fillMaxWidth().clickable { naming = true }.padding(vertical = YY.s(10)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(10))) {
                        Icon(Icons.add, null, tint = YY.tint.accent, modifier = Modifier.size(YY.s(16)))
                        Text(t("新建合集"), style = YY.font(11.5f, FontWeight.SemiBold), color = YY.tint.accent)
                    }
                }
            }
            YYNote(t("一本书可以同时放进几个合集。长按合集可以重命名或删除。"))
        }
    }
    if (naming) {
        NameDialog(t("新建合集"), "") { name ->
            naming = false
            if (name != null) library.createCollection(name)?.let { choose(ShelfFilter.Collection(it)); dismiss() }
        }
    }
    renaming?.let { c ->
        NameDialog(t("重命名合集"), c.name) { name ->
            renaming = null
            if (name != null && name != c.name) library.renameCollection(c.id, name)
        }
    }
    iconFor?.let { c -> IconPicker(c, { iconFor = null }) { symbol -> iconFor = null; library.setCollectionIcon(c.id, symbol) } }
}

/** 换图标: the icons a collection can have, four to a row, and 按名字自动选. */
@Composable
private fun IconPicker(c: uniffi.yuyue_core.BookCollection, dismiss: () -> Unit, pick: (String?) -> Unit) {
    val current = c.icon
    androidx.compose.material3.AlertDialog(
        onDismissRequest = dismiss,
        containerColor = YY.c.card,
        title = { Text(t("换图标"), color = YY.c.t1) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(YY.s(8))) {
                for (line in app.yuyue.library.CollectionIcon.choices.chunked(4)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(YY.s(8))) {
                        for ((symbol, name) in line) {
                            val on = symbol == current
                            Column(
                                Modifier.weight(1f).clip(RoundedCornerShape(YY.s(10)))
                                    .background(if (on) YY.tint.accentSoft else YY.c.inset).clickable { pick(symbol) }.padding(vertical = YY.s(8)),
                                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(YY.s(3)),
                            ) {
                                Icon(app.yuyue.library.CollectionIcon.vector(symbol), null, tint = if (on) YY.tint.accent else YY.c.t1, modifier = Modifier.size(YY.s(18)))
                                Text(t(name), style = YY.font(10f), color = YY.c.t2, maxLines = 1)
                            }
                        }
                        repeat(4 - line.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }
        },
        confirmButton = { androidx.compose.material3.TextButton({ pick(null) }) { Text(t("按名字自动选"), color = YY.tint.accent) } },
        dismissButton = { androidx.compose.material3.TextButton(dismiss) { Text(t("取消"), color = YY.c.t2) } },
    )
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun ChoiceRow(name: String, icon: androidx.compose.ui.graphics.vector.ImageVector, count: Int, on: Boolean, onLong: (() -> Unit)? = null, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().combinedClickable(onClick = onClick, onLongClick = onLong).padding(vertical = YY.s(10)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(YY.s(10)),
    ) {
        Icon(icon, null, tint = YY.c.t2, modifier = Modifier.size(YY.s(16)))
        Text(name, style = YY.font(11.5f, if (on) FontWeight.SemiBold else FontWeight.Normal), color = YY.c.t1, maxLines = 1, modifier = Modifier.weight(1f))
        Text("$count", style = YY.font(10.5f), color = YY.c.t3)
        if (on) Icon(Icons.check, null, tint = YY.tint.accent, modifier = Modifier.size(YY.s(13)))
    }
}

/** A name typed in: a new 合集, or a new name for one. Null when cancelled. */
@Composable
fun NameDialog(title: String, initial: String, done: (String?) -> Unit) {
    var name by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = { done(null) },
        containerColor = YY.c.card,
        title = { Text(title, color = YY.c.t1) },
        text = { OutlinedTextField(name, { name = it }, singleLine = true, placeholder = { Text(t("合集的名字")) }) },
        confirmButton = { TextButton({ done(name.trim().ifEmpty { null }) }) { Text(t("好"), color = YY.tint.accent) } },
        dismissButton = { TextButton({ done(null) }) { Text(t("取消"), color = YY.c.t2) } },
    )
}

/** 书的信息, from 长按 · 编辑信息: the cover and 换封面, the name and author the shelf shows,
 *  its status and 合集. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BookInfoSheet(library: Library, book: uniffi.yuyue_core.BookSummary, dismiss: () -> Unit) {
    var title by remember { mutableStateOf(book.title) }
    var author by remember { mutableStateOf(book.authors.joinToString("、")) }
    var picking by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val current = library.books.firstOrNull { it.id == book.id } ?: book
    val photo = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return@rememberLauncherForActivityResult
        coverJpeg(bytes)?.let { library.setCover(current, it) }
    }
    fun save() {
        val authors = author.split('、', ',', '，', ';', '；', '/').map { it.trim() }.filter { it.isNotEmpty() }
        if (title.trim() != current.title || authors != current.authors) library.editInfo(current, title.trim(), authors)
    }
    ModalBottomSheet({ save(); dismiss() }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 28.dp)) {
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                BookCover(current, Modifier.width(84.dp))
                YYButton(t("换封面"), ButtonKind.Raised, ButtonSize.Small) { photo.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
                Spacer(Modifier.weight(1f))
                YYButton(t("完成"), ButtonKind.Main, ButtonSize.Small) { save(); dismiss() }
            }
            Spacer(Modifier.size(14.dp))
            YYGroup {
                row { YYField(t("书名"), 44f) { Field(title, t("留空就用文件里的")) { title = it } } }
                row { YYField(t("作者"), 44f) { Field(author, t("几位作者用顿号隔开")) { author = it } } }
            }
            YYLabel(t("这本书"))
            YYGroup {
                row {
                    val finished = current.status == ReadingStatus.FINISHED
                    YYRow(t("状态"), value = current.status.title, chevron = false, onClick = { library.setFinished(current, !finished) })
                }
                row {
                    val names = library.collections.filter { it.id in current.collections }.joinToString("、") { it.name }
                    YYRow(t("合集"), value = names.ifEmpty { t("没有") }, chevron = true, onClick = { picking = true })
                }
                if (current.readMinutes > 0u) row { YYRow(t("读了"), value = t("%lld 分钟", current.readMinutes.toInt())) }
            }
            YYNote(t("书名和作者只改书架上显示的，书的文件不动。"))
        }
    }
    if (picking) CollectionPickerSheet(library, current.id) { picking = false }
}

@Composable
fun Field(value: String, placeholder: String, onChange: (String) -> Unit) {
    BasicTextField(
        value, onChange, singleLine = true,
        textStyle = YY.font(11.5f).copy(color = YY.c.t1),
        cursorBrush = SolidColor(YY.tint.accent),
        decorationBox = { inner ->
            if (value.isEmpty()) Text(placeholder, style = YY.font(11.5f), color = YY.c.t3)
            inner()
        },
        modifier = Modifier.fillMaxWidth(),
    )
}

/** 加入合集: the book's 合集 ticked; a tap puts it in or takes it out; a name makes a new one. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CollectionPickerSheet(library: Library, bookID: String, dismiss: () -> Unit) {
    var query by remember { mutableStateOf("") }
    val book = library.books.firstOrNull { it.id == bookID }
    val mine = book?.collections?.toSet() ?: emptySet()
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(), containerColor = YY.c.bg) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 28.dp)) {
            Text(t("加入合集"), style = YY.font(14f, FontWeight.Bold), color = YY.c.t1, modifier = Modifier.padding(start = 4.dp, bottom = 10.dp))
            YYGroup {
                row { YYField(t("找合集"), 44f) { Field(query, t("找合集，或打个新名字")) { query = it } } }
            }
            Spacer(Modifier.size(12.dp))
            val shown = library.collections.filter { query.isBlank() || it.name.contains(query.trim(), ignoreCase = true) }
            YYGroup {
                for (c in shown) {
                    row {
                        val inside = c.id in mine
                        ChoiceRow(c.name, Icons.collection, c.count.toInt(), inside) { library.setBook(bookID, c.id, !inside) }
                    }
                }
                if (query.isNotBlank() && library.collections.none { it.name == query.trim() }) {
                    row {
                        Row(Modifier.fillMaxWidth().clickable { library.createCollection(query.trim(), bookID); query = "" }.padding(vertical = YY.s(10)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(10))) {
                            Icon(Icons.add, null, tint = YY.tint.accent, modifier = Modifier.size(YY.s(16)))
                            Text(t("新建合集“%@”", query.trim()), style = YY.font(11.5f, FontWeight.SemiBold), color = YY.tint.accent)
                        }
                    }
                }
                if (shown.isEmpty() && query.isBlank()) row { YYRow(t("打个名字就能建一个合集")) }
            }
        }
    }
}

/** 换封面: the picked picture, as a JPEG no bigger than a cover needs. */
fun coverJpeg(bytes: ByteArray, longest: Int = 1200): ByteArray? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    if (bounds.outWidth <= 0) return null
    var sample = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= longest) sample *= 2
    val b = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
    val scale = minOf(1f, longest.toFloat() / maxOf(b.width, b.height))
    val out = if (scale < 1f) Bitmap.createScaledBitmap(b, (b.width * scale).toInt(), (b.height * scale).toInt(), true) else b
    return ByteArrayOutputStream().use { out.compress(Bitmap.CompressFormat.JPEG, 85, it); it.toByteArray() }
}
