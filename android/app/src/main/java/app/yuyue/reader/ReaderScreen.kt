package app.yuyue.reader

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYPaper
import app.yuyue.design.YYPapers
import app.yuyue.library.Library
import app.yuyue.shelf.UndoToast
import app.yuyue.t
import uniffi.yuyue_core.Mark
import uniffi.yuyue_core.MarkStyle
import uniffi.yuyue_core.Paper
import kotlin.math.roundToInt

val Paper.tokens: YYPaper
    get() = when (this) {
        Paper.PLAIN -> YYPapers.Plain
        Paper.DARK -> YYPapers.Dark
        Paper.KAMI -> YYPapers.Kami
        Paper.KAMI_NIGHT -> YYPapers.Kaminight
        Paper.EINK -> YYPapers.Eink
    }

/** A book over the tabs, full screen, as on iPhone: only the words and one capsule at the
 *  bottom (目录, where the reader is, ‹ 朗读 ›, Aa); a tap in the middle floats 返回, the
 *  book's name and page, 搜索, 书签 and 更多 along the top. */
@Composable
fun ReaderScreen(library: Library, bookID: String, close: () -> Unit) {
    val context = LocalContext.current
    val density = LocalDensity.current
    val top = WindowInsets.statusBars.getTop(density)
    val bottom = WindowInsets.navigationBars.getBottom(density)
    val model = remember(bookID) {
        val pager = ReaderPager(context, library.core, bookID)
        pager.insetTop = top
        pager.insetBottom = bottom
        ReaderModel.PULL_MARK = with(density) { 64.dp.toPx() }
        ReaderModel(library, bookID, pager, context)
    }
    val paper = model.paper.tokens
    model.pager.background = paper.bg.toArgb()
    DisposableEffect(model) { onDispose { model.close() } }
    BackHandler {
        when {
            model.selection != null || model.openMark != null -> model.dismissCards()
            model.searchShown -> model.endSearch()
            else -> close()
        }
    }

    // The status bar only with the controls, as on iPhone; its icons follow the paper.
    val activity = context as? android.app.Activity
    LaunchedEffect(model.chromeShown, paper) {
        val window = activity?.window ?: return@LaunchedEffect
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        controller.isAppearanceLightStatusBars = !paper.isDark
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (model.chromeShown || model.searchShown) controller.show(WindowInsetsCompat.Type.statusBars()) else controller.hide(WindowInsetsCompat.Type.statusBars())
    }
    DisposableEffect(Unit) {
        onDispose {
            val window = activity?.window ?: return@onDispose
            WindowCompat.getInsetsController(window, window.decorView).show(WindowInsetsCompat.Type.statusBars())
        }
    }

    var thought by remember { mutableStateOf<Mark?>(null) }

    Box(Modifier.fillMaxSize().background(paper.bg)) {
        AndroidView({ model.pager }, Modifier.fillMaxSize())
        PullMark(model, paper)
        model.bookmarkHere?.takeIf { model.pull == 0f && !model.chromeShown && !model.searchShown }?.let {
            Icon(Icons.bookmark, null, tint = YY.tint.accent, modifier = Modifier.align(Alignment.TopEnd).padding(end = 22.dp).size(22.dp).offset(y = (-3).dp))
        }
        Chrome(model, paper, close)
        Cards(model, paper) { thought = it }
        model.toast?.let {
            UndoToast(it, undo = { model.undoToast() }, modifier = Modifier.align(Alignment.BottomCenter).windowInsetsPadding(WindowInsets.navigationBars).padding(horizontal = 16.dp).padding(bottom = 72.dp))
        }
        model.failure?.let { Text(it, color = paper.ink2, modifier = Modifier.align(Alignment.Center).padding(32.dp)) }
    }

    if (model.tocShown) TocSheet(model) { model.tocShown = false }
    if (model.settingsShown) TypesetSheet(model) { model.settingsShown = false }
    thought?.let { mark ->
        ThoughtDialog(mark.note ?: "") { text ->
            if (text != null) model.setNote(text, mark)
            thought = null
        }
    }
}

/** 下拉加书签 (prototype): in the space the page leaves, a bookmark and what letting go does. */
@Composable
private fun PullMark(model: ReaderModel, paper: YYPaper) {
    if (model.pull <= 0f) return
    val density = LocalDensity.current
    val reached = model.pull >= ReaderModel.PULL_MARK
    val adding = model.bookmarkHere == null
    val haptics = LocalHapticFeedback.current
    LaunchedEffect(reached) { if (reached) haptics.performHapticFeedback(HapticFeedbackType.LongPress) }
    Column(
        Modifier.fillMaxWidth().height(with(density) { model.pull.toDp() }).windowInsetsPadding(WindowInsets.statusBars),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Bottom,
    ) {
        Icon(if (adding) Icons.bookmark else Icons.bookmarkOutline, null, tint = if (reached) YY.tint.accent else paper.ink2, modifier = Modifier.size(if (reached) 24.dp else 20.dp))
        Text(
            if (reached) (if (adding) t("松手加书签") else t("松手删掉书签")) else (if (adding) t("下拉加书签") else t("下拉删掉书签")),
            fontSize = 12.sp, fontWeight = FontWeight.Medium, color = paper.ink2, modifier = Modifier.padding(top = 6.dp, bottom = 8.dp),
        )
    }
}

/** A paper-tinted glass shape: the page shows through a little. */
private fun Modifier.glass(paper: YYPaper, shape: androidx.compose.ui.graphics.Shape = CircleShape): Modifier =
    this.shadow(10.dp, shape, ambientColor = Color.Black.copy(alpha = 0.08f), spotColor = Color.Black.copy(alpha = 0.14f))
        .clip(shape)
        .background(paper.glass.copy(alpha = maxOf(paper.glass.alpha, 0.92f)))
        .border(0.5.dp, paper.line, shape)

@Composable
private fun Chrome(model: ReaderModel, paper: YYPaper, close: () -> Unit) {
    Box(Modifier.fillMaxSize()) {
        AnimatedVisibility(model.chromeShown || model.searchShown, enter = fadeIn() + slideInVertically { -it }, exit = fadeOut() + slideOutVertically { -it }, modifier = Modifier.align(Alignment.TopCenter)) {
            Box(Modifier.windowInsetsPadding(WindowInsets.statusBars).padding(horizontal = 12.dp).padding(top = 4.dp).widthIn(max = 560.dp)) {
                if (model.searchShown) SearchField(model, paper) else TopBar(model, paper, close)
            }
        }
        Column(
            Modifier.align(Alignment.BottomCenter).windowInsetsPadding(WindowInsets.navigationBars).padding(horizontal = 12.dp).padding(bottom = 4.dp).widthIn(max = 560.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            model.returnTo?.let { (_, page) ->
                Row(
                    Modifier.padding(bottom = 8.dp).glass(paper).clickable { model.goBack() }.padding(horizontal = 14.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Icon(Icons.undo, null, tint = paper.ink, modifier = Modifier.size(15.dp))
                    Text(page?.let { t("回到第 %lld 页", it) } ?: t("回到原处"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = paper.ink)
                }
            }
            if (model.searchShown) SearchCapsule(model, paper) else Capsule(model, paper)
        }
    }
}

@Composable
private fun TopBar(model: ReaderModel, paper: YYPaper, close: () -> Unit) {
    var more by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.size(40.dp).glass(paper).clickable(onClickLabel = t("返回书架"), onClick = close), contentAlignment = Alignment.Center) {
            Icon(Icons.back, t("返回书架"), tint = paper.ink, modifier = Modifier.size(20.dp))
        }
        Column(Modifier.weight(1f).height(40.dp).glass(paper).padding(horizontal = 12.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Text(model.detail?.summary?.title ?: "", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = paper.ink, maxLines = 1)
            val line = listOfNotNull(model.chapterTitle?.takeIf { it != model.detail?.summary?.title }, model.bookPage?.let { t("第 %lld 页", it) }).joinToString(" · ")
            if (line.isNotEmpty()) Text(line, fontSize = 11.sp, color = paper.ink2, maxLines = 1)
        }
        Row(Modifier.height(40.dp).glass(paper).padding(horizontal = 3.dp), verticalAlignment = Alignment.CenterVertically) {
            Glyph(Icons.search, t("搜索这本书"), paper.ink) { model.chromeShown = false; model.searchShown = true }
            val here = model.bookmarkHere
            Glyph(if (here == null) Icons.bookmarkOutline else Icons.bookmark, if (here == null) t("加书签") else t("拿掉书签"), if (here == null) paper.ink else YY.tint.accent) { model.toggleBookmark() }
            Box {
                Glyph(Icons.more, t("更多"), paper.ink) { more = true }
                DropdownMenu(more, { more = false }, containerColor = YY.c.card) {
                    app.yuyue.shelf.Item(t("书的信息"), Icons.info) { more = false }
                }
            }
        }
    }
}

@Composable
private fun Glyph(icon: ImageVector, label: String, tint: Color, onClick: () -> Unit) {
    Box(Modifier.size(34.dp).clip(CircleShape).clickable(onClickLabel = label, onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, label, tint = tint, modifier = Modifier.size(19.dp))
    }
}

/** 平时只有一条胶囊: 目录, where the reader is, ‹ 朗读 ›, Aa, and how far into the chapter. */
@Composable
private fun Capsule(model: ReaderModel, paper: YYPaper) {
    Box(Modifier.fillMaxWidth().height(50.dp).glass(paper)) {
        Row(Modifier.fillMaxSize().padding(horizontal = 5.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            Glyph(Icons.list, t("目录、书签和笔记"), paper.ink) { model.tocShown = true }
            Column(Modifier.weight(1f).padding(start = 2.dp)) {
                val n = model.sentenceCount
                Text(
                    if (n > 0) t("第 %lld / %lld 句", minOf(model.sentence + 1, n), n) else model.chapterTitle ?: "",
                    fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = paper.ink, maxLines = 1,
                )
                Text(model.capsuleNote, fontSize = 10.5.sp, color = paper.ink2, maxLines = 1)
            }
            Glyph(Icons.chevronLeft, t("上一页"), paper.ink) { model.turn(false) }
            Box(Modifier.size(40.dp).clip(CircleShape).background(paper.main).clickable(onClickLabel = t("朗读")) {}, contentAlignment = Alignment.Center) {
                Icon(Icons.play, t("朗读"), tint = paper.onMain, modifier = Modifier.size(20.dp))
            }
            Glyph(Icons.chevronRight, t("下一页"), paper.ink) { model.turn(true) }
            Box(Modifier.size(36.dp).clip(CircleShape).clickable(onClickLabel = t("排版")) { model.settingsShown = true }, contentAlignment = Alignment.Center) {
                Text("Aa", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = paper.ink)
            }
        }
        // How far into this chapter.
        BoxWithConstraints(Modifier.align(Alignment.BottomCenter).padding(horizontal = 24.dp).fillMaxWidth().height(2.dp)) {
            val n = model.sentenceCount
            val share = if (n > 0) minOf(1f, (model.sentence + 1f) / n) else 0f
            Box(Modifier.fillMaxSize().clip(CircleShape).background(paper.line))
            Box(Modifier.width(maxWidth * share).fillMaxHeight().clip(CircleShape).background(YY.tint.accent))
        }
    }
}

@Composable
private fun SearchField(model: ReaderModel, paper: YYPaper) {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.weight(1f).height(40.dp).glass(paper).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(Icons.search, null, tint = paper.ink2, modifier = Modifier.size(17.dp))
            BasicTextField(
                model.query, { model.query = it; model.search() }, singleLine = true,
                textStyle = androidx.compose.ui.text.TextStyle(fontSize = 15.sp, color = paper.ink),
                cursorBrush = SolidColor(YY.tint.accent),
                modifier = Modifier.weight(1f).focusRequester(focus),
                decorationBox = { inner ->
                    if (model.query.isEmpty()) Text(t("搜这本书"), fontSize = 15.sp, color = paper.ink2)
                    inner()
                },
            )
        }
        Box(Modifier.size(40.dp).glass(paper).clickable(onClickLabel = t("结束搜索")) { model.endSearch() }, contentAlignment = Alignment.Center) {
            Icon(Icons.close, t("结束搜索"), tint = paper.ink, modifier = Modifier.size(18.dp))
        }
    }
}

@Composable
private fun SearchCapsule(model: ReaderModel, paper: YYPaper) {
    val q = model.query.trim()
    Row(Modifier.fillMaxWidth().height(50.dp).glass(paper).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(
                when {
                    q.isEmpty() -> t("输入要找的字")
                    model.hits.isEmpty() -> t("没找到“%@”", q)
                    else -> t("第 %lld / %lld 处", (model.hitIndex ?: 0) + 1, model.hits.size)
                },
                fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = paper.ink, maxLines = 1,
            )
            val hit = model.hitIndex?.let { model.hits.getOrNull(it) }
            Text(hit?.let { model.place(it.section.toInt(), it.sentence.toInt()) } ?: if (q.isEmpty()) t("输完直接跳到第一处") else "", fontSize = 10.5.sp, color = paper.ink2, maxLines = 1)
        }
        Glyph(Icons.chevronLeft, t("上一处"), paper.ink.copy(alpha = if (model.hits.isEmpty()) 0.3f else 1f)) { model.nextHit(false) }
        Glyph(Icons.chevronRight, t("下一处"), paper.ink.copy(alpha = if (model.hits.isEmpty()) 0.3f else 1f)) { model.nextHit(true) }
    }
}

/** 选中文字, or a highlight tapped: the card over the words — four colours and two lines, then
 *  想法 · 复制 · 删除. */
@Composable
private fun Cards(model: ReaderModel, paper: YYPaper, thought: (Mark) -> Unit) {
    val density = LocalDensity.current
    val sel = model.selection
    val open = model.openMark
    if (sel == null && open == null) return
    val anchorY = with(density) { ((sel?.rect?.y ?: open?.y ?: 200.0).toFloat() * density.density).roundToInt() }
    val current = open?.mark
    Box(Modifier.fillMaxSize()) {
        Column(
            Modifier
                .align(Alignment.TopCenter)
                .offset { IntOffset(0, maxOf(with(density) { 60.dp.roundToPx() }, anchorY - with(density) { 120.dp.roundToPx() })) }
                .shadow(16.dp, RoundedCornerShape(14.dp))
                .clip(RoundedCornerShape(14.dp))
                .background(YY.c.card)
                .padding(10.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                for (style in listOf(MarkStyle.YELLOW, MarkStyle.BLUE, MarkStyle.PINK, MarkStyle.WAVE)) {
                    val on = current?.style == style
                    Box(
                        Modifier.size(28.dp).clip(CircleShape).background(style.swatch(paper)).border(if (on) 2.dp else 0.5.dp, if (on) YY.tint.accent else YY.c.line, CircleShape)
                            .clickable { if (current != null) model.setStyle(style, current) else model.mark(style) },
                    )
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                CardAction(Icons.edit, if (current?.note != null) t("改想法") else t("写想法")) {
                    val m = current ?: model.mark()
                    model.dismissCards()
                    if (m != null) thought(m)
                }
                CardAction(Icons.upload, t("复制")) { model.copySelection() }
                if (current != null) CardAction(Icons.delete, t("删除"), YY.c.danger) { model.deleteMark(current) }
            }
        }
    }
}

@Composable
private fun CardAction(icon: ImageVector, title: String, color: Color = YY.c.t1, onClick: () -> Unit) {
    Column(Modifier.clip(RoundedCornerShape(8.dp)).clickable(onClick = onClick).padding(horizontal = 6.dp, vertical = 4.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, title, tint = color, modifier = Modifier.size(18.dp))
        Text(title, fontSize = 11.sp, color = color)
    }
}

private fun MarkStyle.swatch(paper: YYPaper): Color = when (this) {
    MarkStyle.YELLOW -> Color(0xFFF2D27A)
    MarkStyle.BLUE -> Color(0xFF9DBDEB)
    MarkStyle.PINK -> Color(0xFFF0A094)
    else -> paper.wave
}

/** 写想法: a few lines about the highlight. Null when cancelled. */
@Composable
fun ThoughtDialog(initial: String, done: (String?) -> Unit) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = { done(null) },
        containerColor = YY.c.card,
        title = { Text(t("写想法"), color = YY.c.t1) },
        text = { OutlinedTextField(text, { text = it }, minLines = 3, placeholder = { Text(t("想法…")) }) },
        confirmButton = { TextButton({ done(text) }) { Text(t("完成"), color = YY.tint.accent) } },
        dismissButton = { TextButton({ done(null) }) { Text(t("取消"), color = YY.c.t2) } },
    )
}
