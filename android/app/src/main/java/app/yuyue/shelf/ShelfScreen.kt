package app.yuyue.shelf

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.ButtonKind
import app.yuyue.design.Icons
import app.yuyue.design.ProgressLine
import app.yuyue.design.YY
import app.yuyue.design.YYButton
import app.yuyue.design.rememberPref
import app.yuyue.library.Library
import app.yuyue.library.ShelfFilter
import app.yuyue.library.ShelfSort
import app.yuyue.library.author
import app.yuyue.library.percent
import app.yuyue.library.remaining
import app.yuyue.library.shelfNote
import app.yuyue.library.title
import app.yuyue.t
import uniffi.yuyue_core.BookFormat
import uniffi.yuyue_core.BookSummary
import uniffi.yuyue_core.ReadingStatus

/** What 导入 can pick: anything; the core says what it can't read. */
val importTypes = arrayOf("*/*")

private enum class Kind { All, Books, Audio;
    val title: String get() = when (this) { All -> t("全部"); Books -> t("书"); Audio -> t("有声") }
}

/** 书架 on the phone, as on iPhone: the books being read across the top, to read or listen on
 *  at a tap; all the books below, by kind and in an order. Tapping the title picks what the
 *  shelf shows: all, a reading status or one of your 合集. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShelfScreen(library: Library, openWifi: () -> Unit, openRemote: () -> Unit, openWatched: () -> Unit) {
    var filter by remember { mutableStateOf<ShelfFilter>(ShelfFilter.All) }
    var kind by rememberSaveable { mutableStateOf(Kind.All) }
    var sortKey by rememberPref("shelf.sort", "recent")
    val showProgress by rememberPref("shelf.showProgress", true)
    var importShown by remember { mutableStateOf(false) }
    var choosing by remember { mutableStateOf(false) }
    var selecting by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf(setOf<String>()) }
    var editing by remember { mutableStateOf<BookSummary?>(null) }
    var picking by remember { mutableStateOf<BookSummary?>(null) }
    val sort = ShelfSort.of(sortKey)
    val collection = (filter as? ShelfFilter.Collection)?.id

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris: List<Uri> ->
        library.importUris(uris, collection)
    }

    val title = when (val f = filter) {
        is ShelfFilter.Status -> f.status.title
        is ShelfFilter.Collection -> library.collections.firstOrNull { it.id == f.id }?.name ?: t("合集")
        else -> t("书架")
    }
    val all = library.books
    fun ofKind(b: BookSummary) = when (kind) {
        Kind.All -> true
        Kind.Books -> b.format != uniffi.yuyue_core.BookFormat.AUDIO
        Kind.Audio -> b.format == uniffi.yuyue_core.BookFormat.AUDIO
    }
    val shown = sort.sorted(all.filter { b ->
        when (val f = filter) {
            is ShelfFilter.Status -> b.status == f.status
            is ShelfFilter.Collection -> f.id in b.collections
            else -> true
        } && ofKind(b)
    })
    val reading = if (filter == ShelfFilter.All && !selecting) all.filter { it.status == ReadingStatus.READING && ofKind(it) } else emptyList()

    Box(Modifier.fillMaxSize().background(YY.c.bg)) {
        LazyVerticalGrid(
            columns = GridCells.Adaptive(96.dp),
            modifier = Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.statusBars),
            contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = app.yuyue.LocalTabBarHeight.current + 16.dp),
            horizontalArrangement = Arrangement.spacedBy(18.dp),
            verticalArrangement = Arrangement.spacedBy(22.dp),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                TopBar(
                    selecting = selecting, selectedCount = selected.size, allCount = shown.size,
                    importing = library.importing > 0,
                    onImport = { importShown = true },
                    onSelect = { selecting = true },
                    onDone = { selecting = false; selected = emptySet() },
                    onToggleAll = { selected = if (selected.size == shown.size) emptySet() else shown.map { it.id }.toSet() },
                )
            }
            item(span = { GridItemSpan(maxLineSpan) }) {
                Row(
                    Modifier.clickable { choosing = true }.padding(top = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(title, fontSize = 32.sp, fontWeight = FontWeight.Bold, color = YY.c.t1, maxLines = 1)
                    Icon(Icons.chevronDown, t("%@，换一个看", title), tint = YY.c.t3, modifier = Modifier.size(22.dp))
                }
            }
            if (reading.isNotEmpty()) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    ReadingRow(library, reading) { book, intent -> library.open(book, intent) }
                }
            }
            if (all.isEmpty() && filter == ShelfFilter.All) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Welcome(onFiles = { picker.launch(importTypes) }, onWifi = openWifi, onRemote = openRemote)
                }
            } else {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Kinds(kind, { kind = it }, sort) { sortKey = it.key }
                }
                if (shown.isEmpty()) {
                    item(span = { GridItemSpan(maxLineSpan) }) { Empty(library, collection != null) { picker.launch(importTypes) } }
                } else {
                    items(shown, key = { it.id }) { book ->
                        Cell(
                            library, book, showProgress, selecting, book.id in selected,
                            onTap = {
                                if (selecting) selected = if (book.id in selected) selected - book.id else selected + book.id
                                else library.open(book)
                            },
                            onEdit = { editing = book },
                            onPick = { picking = book },
                        )
                    }
                }
            }
        }

        Column(Modifier.align(Alignment.BottomCenter).padding(bottom = app.yuyue.LocalTabBarHeight.current).padding(horizontal = 8.dp, vertical = 8.dp)) {
            if (selecting) {
                SelectionBar(
                    enabled = selected.isNotEmpty(),
                    finish = {
                        library.books.filter { it.id in selected }.forEach { library.setFinished(it, true) }
                        selecting = false; selected = emptySet()
                    },
                    delete = {
                        library.books.filter { it.id in selected }.forEach { library.delete(it) }
                        selecting = false; selected = emptySet()
                    },
                )
            }
        }
    }

    if (importShown) {
        ImportSheet(
            watching = library.watched.name,
            dismiss = { importShown = false },
            files = { importShown = false; picker.launch(importTypes) },
            wifi = { importShown = false; openWifi() },
            remote = { importShown = false; openRemote() },
            watch = { importShown = false; openWatched() },
        )
    }
    if (choosing) {
        ShelfChooser(library, filter, { filter = it }) { choosing = false }
    }
    editing?.let { BookInfoSheet(library, it) { editing = null } }
    picking?.let { CollectionPickerSheet(library, it.id) { picking = null } }
}

@Composable
private fun TopBar(
    selecting: Boolean, selectedCount: Int, allCount: Int, importing: Boolean,
    onImport: () -> Unit, onSelect: () -> Unit, onDone: () -> Unit, onToggleAll: () -> Unit,
) {
    Row(Modifier.fillMaxWidth().height(48.dp), verticalAlignment = Alignment.CenterVertically) {
        if (selecting) {
            Text(if (selectedCount == allCount) t("全不选") else t("全选"), fontSize = 15.sp, color = YY.tint.accent, modifier = Modifier.clickable(onClick = onToggleAll))
            Spacer(Modifier.weight(1f))
            Text(if (selectedCount == 0) t("选择书") else t("已选 %lld 本", selectedCount), fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
            Spacer(Modifier.weight(1f))
            Text(t("完成"), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = YY.tint.accent, modifier = Modifier.clickable(onClick = onDone))
        } else {
            Spacer(Modifier.weight(1f))
            if (importing) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = YY.c.t2)
            } else {
                ToolButton(Icons.add, t("导入"), onImport)
            }
            Spacer(Modifier.width(8.dp))
            ToolButton(Icons.checkCircle, t("选择"), onSelect, enabled = allCount > 0)
        }
    }
}

@Composable
fun ToolButton(icon: ImageVector, label: String, onClick: () -> Unit, enabled: Boolean = true) {
    Box(
        Modifier.size(40.dp).clip(CircleShape).background(YY.c.card).border(0.5.dp, YY.c.line, CircleShape)
            .clickable(enabled = enabled, onClickLabel = label, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, label, tint = if (enabled) YY.c.t1 else YY.c.t3, modifier = Modifier.size(20.dp)) }
}

@Composable
private fun ReadingRow(library: Library, reading: List<BookSummary>, open: (BookSummary, Library.OpenIntent?) -> Unit) {
    Column(Modifier.padding(top = 18.dp)) {
        Row(Modifier.fillMaxWidth()) {
            Text(t("在读"), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
            Spacer(Modifier.weight(1f))
            Text(t("%lld 本", reading.size), fontSize = 13.sp, color = YY.c.t3)
        }
        LazyRow(
            Modifier.padding(top = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            contentPadding = PaddingValues(vertical = 4.dp),
        ) {
            items(reading, key = { it.id }) { book ->
                ReadingCard(book, listening = library.listening == book.id, modifier = Modifier.width(268.dp)) { open(book, it) }
            }
        }
    }
}

/** A book being read: cover, how far, and buttons to read or listen on. */
@Composable
fun ReadingCard(book: BookSummary, listening: Boolean, modifier: Modifier = Modifier, open: (Library.OpenIntent?) -> Unit) {
    val tint = YY.tint
    Row(
        modifier
            .clip(RoundedCornerShape(14.dp))
            .background(YY.c.card)
            .border(0.5.dp, if (YY.dark) Color.White.copy(alpha = 0.06f) else YY.c.line, RoundedCornerShape(14.dp))
            .padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        BookCover(book, Modifier.width(44.dp).clickable { open(null) })
        Column(Modifier.weight(1f)) {
            Text(book.title, fontSize = 12.5.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val meta = when {
                book.format == BookFormat.PDF && book.page > 0u -> listOfNotNull(book.author, t("第 %lld 页", book.page.toInt()), book.percent).joinToString(" · ")
                book.format == BookFormat.AUDIO -> listOfNotNull(book.author, book.remaining).joinToString(" · ")
                else -> listOfNotNull(book.author, book.percent, if (listening) t("听中") else null).joinToString(" · ")
            }
            Text(meta, fontSize = 10.5.sp, color = YY.c.t3, maxLines = 1, modifier = Modifier.padding(top = 3.dp, bottom = 8.dp))
            ProgressLine(book.progress, modifier = Modifier.padding(bottom = 10.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                when {
                    // 有声书 has only 接着听, moving while it plays.
                    book.format == BookFormat.AUDIO && listening -> Pill(t("正在听"), tint.accentSoft, tint.accent, Icons.waveform) { open(null) }
                    book.format == BookFormat.AUDIO -> Pill(t("接着听"), tint.black, tint.onBlack) { open(Library.OpenIntent.Listen) }
                    else -> {
                        Pill(t("接着读"), tint.black, tint.onBlack) { open(null) }
                        if (listening) Pill(t("听中"), tint.accentSoft, tint.accent, Icons.waveform) { open(null) }
                        else Pill(t("听"), YY.c.inset, YY.c.t1) { open(Library.OpenIntent.Listen) }
                    }
                }
            }
        }
    }
}

@Composable
private fun Pill(title: String, fill: Color, text: Color, icon: ImageVector? = null, action: () -> Unit) {
    Row(
        Modifier.height(26.dp).clip(CircleShape).background(fill).clickable(onClick = action).padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        if (icon != null) Icon(icon, null, tint = text, modifier = Modifier.size(13.dp))
        Text(title, fontSize = 11.5.sp, fontWeight = FontWeight.Medium, color = text, maxLines = 1)
    }
}

@Composable
private fun Kinds(kind: Kind, onKind: (Kind) -> Unit, sort: ShelfSort, onSort: (ShelfSort) -> Unit) {
    val tint = YY.tint
    var sorting by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(top = 22.dp, bottom = 0.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for (k in Kind.entries) {
            val on = k == kind
            Box(
                Modifier.height(30.dp).clip(CircleShape).background(if (on) tint.black else YY.c.inset).clickable { onKind(k) }.padding(horizontal = 14.dp),
                contentAlignment = Alignment.Center,
            ) { Text(k.title, fontSize = 13.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal, color = if (on) tint.onBlack else YY.c.t1) }
        }
        Spacer(Modifier.weight(1f))
        Box {
            Row(Modifier.clickable { sorting = true }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(sort.title, fontSize = 13.sp, color = YY.c.t2)
                Icon(Icons.sort, null, tint = YY.c.t2, modifier = Modifier.size(14.dp))
            }
            DropdownMenu(sorting, { sorting = false }, containerColor = YY.c.card) {
                for (s in ShelfSort.entries) {
                    DropdownMenuItem(
                        text = { Text(s.title, color = YY.c.t1) },
                        trailingIcon = { if (s == sort) Icon(Icons.check, null, tint = tint.accent) },
                        onClick = { onSort(s); sorting = false },
                    )
                }
            }
        }
    }
}

/** `.v-lib-wel` (prototype 第一次打开): what this is, then the three ways to put books in. */
@Composable
private fun Welcome(onFiles: () -> Unit, onWifi: () -> Unit, onRemote: () -> Unit) {
    Column(Modifier.padding(top = YY.s(14))) {
        Text(t("把书放进来，\n读或者听都行。"), fontFamily = YY.serif, fontWeight = FontWeight.Bold, fontSize = YY.sp(21f), lineHeight = YY.sp(31f), color = YY.c.t1)
        Text(t("不用注册。书、进度和笔记都存在你自己的设备里。"), style = YY.font(11f), color = YY.c.t2, modifier = Modifier.padding(top = YY.s(6)))
        Row(Modifier.padding(top = YY.s(16)), horizontalArrangement = Arrangement.spacedBy(YY.s(8))) {
            Way(Icons.folder, t("从文件导入"), t("本机或云盘里的"), Modifier.weight(1f), onFiles)
            Way(Icons.wifi, t("Wi‑Fi 传书"), t("用电脑浏览器传"), Modifier.weight(1f), onWifi)
            Way(Icons.server, t("远程书库"), "Calibre、NAS", Modifier.weight(1f), onRemote)
        }
    }
}

@Composable
private fun Way(icon: ImageVector, title: String, detail: String, modifier: Modifier, action: () -> Unit) {
    Column(
        modifier
            .clip(RoundedCornerShape(YY.s(16)))
            .background(YY.c.card)
            .border(0.5.dp, YY.c.line, RoundedCornerShape(YY.s(16)))
            .clickable(onClick = action)
            .padding(start = YY.s(10), end = YY.s(10), top = YY.s(12), bottom = YY.s(11)),
        verticalArrangement = Arrangement.spacedBy(YY.s(10)),
    ) {
        Box(Modifier.size(YY.s(28)).clip(RoundedCornerShape(YY.s(8))).background(YY.c.inset), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = YY.c.t1, modifier = Modifier.size(YY.s(14)))
        }
        Column {
            Text(title, style = YY.font(11.5f, FontWeight.SemiBold), color = YY.c.t1, maxLines = 1)
            Text(detail, style = YY.font(10f), color = YY.c.t3, maxLines = 2)
        }
    }
}

@Composable
private fun Empty(library: Library, inCollection: Boolean, import: () -> Unit) {
    val (icon, text) = when {
        library.books.isEmpty() -> Icons.books to t("书架是空的。点右上角的加号，导入 EPUB、PDF、MOBI 或 TXT")
        inCollection -> Icons.inbox to t("这个合集里还没有书。长按一本书，点「加入合集」")
        else -> Icons.book to t("这里还没有书")
    }
    Column(Modifier.fillMaxWidth().heightIn(min = 300.dp).padding(horizontal = 40.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically)) {
        Icon(icon, null, tint = YY.c.t3, modifier = Modifier.size(40.dp))
        Text(text, fontSize = 15.sp, color = YY.c.t2, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        if (library.books.isEmpty()) YYButton(t("导入书"), ButtonKind.Main, onClick = import)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Cell(
    library: Library, book: BookSummary, showProgress: Boolean, selecting: Boolean, chosen: Boolean,
    onTap: () -> Unit, onEdit: () -> Unit, onPick: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    val haptics = LocalHapticFeedback.current
    val tint = YY.tint
    Box {
        Column(
            Modifier.combinedClickable(
                onClick = onTap,
                onLongClick = if (selecting) null else ({ haptics.performHapticFeedback(HapticFeedbackType.LongPress); menu = true }),
            ),
        ) {
            Box(Modifier.padding(bottom = 8.dp)) {
                BookCover(book, Modifier.fillMaxWidth().then(if (book.available) Modifier else Modifier.background(Color.Transparent)))
                when {
                    selecting -> Box(Modifier.align(Alignment.BottomEnd).padding(6.dp)) {
                        Icon(
                            if (chosen) Icons.checkCircle else Icons.circle, if (chosen) t("已选") else t("未选"),
                            tint = if (chosen) tint.accent else Color.White,
                            modifier = Modifier.size(24.dp).clip(CircleShape).background(if (chosen) Color.White else Color.Black.copy(alpha = 0.25f)),
                        )
                    }
                    !book.available -> Box(Modifier.align(Alignment.BottomEnd).padding(6.dp).size(24.dp).clip(CircleShape).background(YY.c.card), contentAlignment = Alignment.Center) {
                        Icon(Icons.cloudDownload, null, tint = YY.c.t2, modifier = Modifier.size(13.dp))
                    }
                    book.format == BookFormat.AUDIO -> AudioBadge(Modifier.align(Alignment.BottomEnd))
                }
            }
            Text(book.title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(bottom = 2.dp))
            if (showProgress) {
                if (library.listening == book.id) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                        Icon(Icons.headphones, null, tint = tint.accent, modifier = Modifier.size(11.dp))
                        Text(t("听中 · %@", book.percent), fontSize = 11.sp, color = tint.accent)
                    }
                } else {
                    Text(book.shelfNote, fontSize = 11.sp, color = YY.c.t3, maxLines = 1)
                }
            }
        }
        BookMenu(library, book, menu, { menu = false }, onEdit, onPick)
    }
}

/** 长按: the book a size smaller with how far it is, then 接着读 · 从头听 · 标为读完, and
 *  编辑信息 · 加入合集 · 删除, as confirmed in the design. */
@Composable
private fun BookMenu(library: Library, book: BookSummary, shown: Boolean, dismiss: () -> Unit, onEdit: () -> Unit, onPick: () -> Unit) {
    DropdownMenu(shown, dismiss, containerColor = YY.c.card, shape = RoundedCornerShape(14.dp)) {
        BookPreview(book)
        HorizontalDivider(color = YY.c.line)
        val audio = book.format == BookFormat.AUDIO
        val resume = when {
            audio -> if (book.progress > 0) t("接着听") else t("开始听")
            book.status == ReadingStatus.FINISHED -> t("重读")
            else -> if (book.progress > 0) t("接着读") else t("开始读")
        }
        Item(resume, if (audio) Icons.headphones else Icons.book) { dismiss(); library.open(book, if (audio) Library.OpenIntent.Listen else null) }
        Item(t("从头听"), Icons.headphones) { dismiss(); library.open(book, Library.OpenIntent.ListenFromStart) }
        val finished = book.status == ReadingStatus.FINISHED
        Item(
            if (audio) (if (finished) t("标为没听完") else t("标为听完")) else if (finished) t("标为没读完") else t("标为读完"),
            if (finished) Icons.undo else Icons.check,
        ) { dismiss(); library.setFinished(book, !finished) }
        HorizontalDivider(color = YY.c.line)
        Item(t("编辑信息"), Icons.edit) { dismiss(); onEdit() }
        Item(t("加入合集"), Icons.collection) { dismiss(); onPick() }
        Item(t("删除"), Icons.delete, danger = true) { dismiss(); library.delete(book) }
    }
}

/** Menu rows as the Mac's white card: words on the left, the icon on the right. */
@Composable
fun Item(title: String, icon: ImageVector, danger: Boolean = false, onClick: () -> Unit) {
    val color = if (danger) YY.c.danger else YY.c.t1
    DropdownMenuItem(
        text = { Text(title, color = color, fontSize = 15.sp) },
        trailingIcon = { Icon(icon, null, tint = color, modifier = Modifier.size(20.dp)) },
        onClick = onClick,
    )
}

/** What floats up when a book is pressed: the cover a size smaller, the title, and how far —
 *  a thin line and how long is left, not a percentage. */
@Composable
fun BookPreview(book: BookSummary) {
    Row(Modifier.width(300.dp).padding(14.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        BookCover(book, Modifier.width(44.dp))
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.Bottom) {
                Text(book.title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                book.author?.let { Text(it, fontSize = 12.sp, color = YY.c.t3, maxLines = 1) }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                if (book.progress > 0 && book.status != ReadingStatus.FINISHED) {
                    ProgressLine(book.progress, 2.5.dp, Modifier.weight(1f))
                }
                Text(book.remaining, fontSize = 12.sp, color = YY.c.t2, maxLines = 1)
            }
        }
    }
}

@Composable
private fun SelectionBar(enabled: Boolean, finish: () -> Unit, delete: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 44.dp).padding(bottom = 8.dp)
            .clip(CircleShape).background(YY.c.card).border(0.5.dp, YY.c.line, CircleShape).padding(horizontal = 8.dp),
    ) {
        BarButton(t("标为读完"), Icons.check, enabled, Modifier.weight(1f), onClick = finish)
        BarButton(t("删除"), Icons.delete, enabled, Modifier.weight(1f), danger = true, onClick = delete)
    }
}

@Composable
private fun BarButton(title: String, icon: ImageVector, enabled: Boolean, modifier: Modifier, danger: Boolean = false, onClick: () -> Unit) {
    val color = (if (danger) YY.c.danger else YY.c.t1).copy(alpha = if (enabled) 1f else 0.4f)
    Column(modifier.height(54.dp).clickable(enabled = enabled, onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Icon(icon, null, tint = color, modifier = Modifier.size(20.dp))
        Text(title, fontSize = 11.sp, color = color)
    }
}

/** 导入: from 文件, over Wi‑Fi, a 远程书库, or a folder to keep watching. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ImportSheet(watching: String?, dismiss: () -> Unit, files: () -> Unit, wifi: () -> Unit, remote: () -> Unit, watch: () -> Unit) {
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 24.dp)) {
            Text(t("导入"), style = YY.font(14f, FontWeight.Bold), color = YY.c.t1, modifier = Modifier.padding(start = 4.dp, bottom = 12.dp))
            app.yuyue.design.YYGroup {
                row { app.yuyue.design.YYRow(t("从文件导入"), Icons.folder, t("本机或云盘里的"), chevron = true, onClick = files) }
                row { app.yuyue.design.YYRow(t("Wi‑Fi 传书"), Icons.wifi, t("用电脑浏览器传"), chevron = true, onClick = wifi) }
                row { app.yuyue.design.YYRow(t("远程书库"), Icons.server, "OPDS · WebDAV", chevron = true, onClick = remote) }
                row { app.yuyue.design.YYRow(t("监听一个文件夹"), Icons.folder, watching ?: t("还没选"), chevron = true, onClick = watch) }
            }
            app.yuyue.design.YYNote(t("同一个文件只导入一次：按内容认，改过名字也认得出来"))
        }
    }
}
