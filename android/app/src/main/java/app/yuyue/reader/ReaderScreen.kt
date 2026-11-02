package app.yuyue.reader

import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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
import androidx.compose.ui.graphics.Brush
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
import app.yuyue.design.Prefs
import app.yuyue.design.YY
import app.yuyue.design.YYPaper
import app.yuyue.design.YYPapers
import app.yuyue.library.Library
import app.yuyue.shelf.UndoToast
import app.yuyue.t
import kotlinx.coroutines.launch
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
        // Still being read aloud with its pages closed: picked up as it is.
        (library.nowPlaying as? ReaderModel)?.takeIf { it.bookID == bookID }?.also { library.nowPlaying = null } ?: run {
            library.nowPlaying?.let { (it as? ReaderModel)?.close(); (it as? app.yuyue.speech.AudiobookPlayer)?.close() }
            library.nowPlaying = null
            val pager = ReaderPager(context, library.core, bookID)
            pager.insetTop = top
            pager.insetBottom = bottom
            ReaderModel.PULL_MARK = with(density) { 64.dp.toPx() }
            ReaderModel(library, bookID, pager, context)
        }
    }
    val paper = model.paperTokens
    model.pager.background = paper.bg.toArgb()
    LaunchedEffect(model, Papers.version) { model.papersChanged() }
    DisposableEffect(model) {
        // 音量键翻页: on unless reading aloud, when the keys are for the volume.
        VolumeKeys.handler = { forward ->
            if (Prefs.bool("reader.volumeKeys", true) && !model.isPlaying && model.settings.mode == uniffi.yuyue_core.LayoutMode.PAGINATED) {
                model.turn(forward); true
            } else false
        }
        onDispose {
            VolumeKeys.handler = null
            // Pages closed while the voice reads on: it goes on, with the 播放条 over the tabs.
            if (model.isPlaying) library.nowPlaying = model else model.close()
        }
    }
    // 霞鹜文楷 arrived: the open sections load again, now with its @font-face.
    val fonts = WenKai.version
    LaunchedEffect(fonts) { if (fonts > 0) model.pager.reload() }
    BackHandler {
        when {
            model.selection != null || model.openMark != null -> model.dismissCards()
            model.searchShown -> model.endSearch()
            else -> close()
        }
    }

    // The status bar only with the controls, as on iPhone; its icons follow the paper.
    val activity = context as? android.app.Activity
    LaunchedEffect(model.chromeShown, model.searchShown, model.immersive, paper) {
        val window = activity?.window ?: return@LaunchedEffect
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        controller.isAppearanceLightStatusBars = !paper.isDark
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        val show = model.chromeShown || model.searchShown || (model.immersive && !ImmersivePrefs.hidesStatusBar)
        if (show) controller.show(WindowInsetsCompat.Type.statusBars()) else controller.hide(WindowInsetsCompat.Type.statusBars())
        // 沉浸: the navigation bar goes too, until a swipe from the edge.
        if (model.immersive && !model.chromeShown) controller.hide(WindowInsetsCompat.Type.navigationBars()) else controller.show(WindowInsetsCompat.Type.navigationBars())
    }
    // 读书时通知不打扰, while 沉浸阅读 is on.
    LaunchedEffect(model.immersive) { if (ImmersivePrefs.quiet) DoNotDisturb.set(context, model.immersive) }
    // 沉浸: called up by a tap, gone again by itself.
    LaunchedEffect(model.immersive, model.chromeShown) {
        if (model.immersive && model.chromeShown) { kotlinx.coroutines.delay(4000); if (!model.listenShown && !model.settingsShown) model.chromeShown = false }
    }
    DisposableEffect(Unit) {
        onDispose {
            val window = activity?.window ?: return@onDispose
            WindowCompat.getInsetsController(window, window.decorView).show(WindowInsetsCompat.Type.systemBars())
        }
    }

    var thought by remember { mutableStateOf<Mark?>(null) }

    Box(Modifier.fillMaxSize().background(paper.bg)) {
        AndroidView({ model.pager.also { (it.parent as? android.view.ViewGroup)?.removeView(it) } }, Modifier.fillMaxSize())
        PullMark(model, paper)
        PageTapHint(model, paper)
        model.bookmarkHere?.takeIf { model.pull == 0f && !model.chromeShown && !model.searchShown }?.let {
            Icon(Icons.bookmark, null, tint = YY.tint.accent, modifier = Modifier.align(Alignment.TopEnd).padding(end = 22.dp).size(22.dp).offset(y = (-3).dp))
        }
        Chrome(model, paper, close)
        Cards(model, paper) { thought = it }
        model.lookup?.let { WordCard(model, it) }
        model.toast?.let {
            UndoToast(it, undo = { model.undoToast() }, modifier = Modifier.align(Alignment.TopCenter).windowInsetsPadding(WindowInsets.statusBars).padding(horizontal = 16.dp, vertical = 6.dp))
        }
        if (model.detail == null) app.yuyue.shelf.BookFailure(model.failure, close)
        else model.failure?.let { app.yuyue.shelf.FailureDialog(it) { model.failure = null } }
    }

    if (model.tocShown) TocSheet(model) { model.tocShown = false }
    if (model.settingsShown) TypesetSheet(model) { model.settingsShown = false }
    if (model.listenShown) ListenSheet(model) { model.listenShown = false }
    if (model.immersiveShown) ImmersiveSheet(model) { model.immersiveShown = false }
    if (model.rulesShown) ReplaceRulesSheet(library.core, bookID, changed = { model.player?.textsChanged(); model.pager.reload() }) { model.rulesShown = false }
    if (model.txtShown) TxtLayoutSheet(library, bookID, model.detail?.summary?.title ?: "", rebuilt = {
        // The book was built again: closed and opened afresh, at the place the core carried over.
        model.txtShown = false
        close()
        library.scope.launch { kotlinx.coroutines.delay(150); library.presented = bookID }
    }) { model.txtShown = false }
    if (model.infoShown) library.books.firstOrNull { it.id == bookID }?.let { app.yuyue.shelf.BookInfoSheet(library, it) { model.infoShown = false } }
    var companionSettings by remember { mutableStateOf(false) }
    if (model.companionShown) app.yuyue.companion.CompanionSheet(model, settings = { companionSettings = true }) { model.companionShown = false }
    if (companionSettings) app.yuyue.companion.CompanionSettingsSheet { companionSettings = false }
    model.player?.let { PlayerFailure(it) }
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
        .background(paper.glass.copy(alpha = maxOf(paper.glass.alpha, 0.97f)))
        .border(0.5.dp, paper.line, shape)

@Composable
private fun Chrome(model: ReaderModel, paper: YYPaper, close: () -> Unit) {
    Box(Modifier.fillMaxSize()) {
        AnimatedVisibility(model.chromeShown || model.searchShown, enter = fadeIn() + slideInVertically { -it }, exit = fadeOut() + slideOutVertically { -it }, modifier = Modifier.align(Alignment.TopCenter)) {
            // The page fades out under the bar, so a chapter title never shows through the title pill.
            val edge = Brush.verticalGradient(0f to paper.bg, 0.72f to paper.bg, 1f to paper.bg.copy(alpha = 0f))
            Box(Modifier.fillMaxWidth().background(edge).padding(bottom = 20.dp), contentAlignment = Alignment.TopCenter) {
                Box(Modifier.windowInsetsPadding(WindowInsets.statusBars).padding(horizontal = 12.dp).padding(top = 4.dp).widthIn(max = 560.dp)) {
                    if (model.searchShown) SearchField(model, paper) else TopBar(model, paper, close)
                }
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
            // 沉浸阅读 hides the capsule until the middle is tapped.
            val capsule = !model.immersive || model.chromeShown || model.searchShown
            AnimatedVisibility(capsule, enter = fadeIn() + slideInVertically { it }, exit = fadeOut() + slideOutVertically { it }) {
                if (model.searchShown) SearchCapsule(model, paper) else Capsule(model, paper)
            }
            if (!capsule) {
                if (!ImmersivePrefs.hidesProgress) {
                    Text(model.capsuleNote, fontSize = 12.sp, color = paper.ink2, modifier = Modifier.padding(bottom = 2.dp))
                } else if (ImmersivePrefs.keepsLine) {
                    BoxWithConstraints(Modifier.fillMaxWidth().height(1.dp)) {
                        Box(Modifier.width(maxWidth * model.bookFraction.toFloat()).fillMaxHeight().background(paper.ink.copy(alpha = 0.25f)))
                    }
                }
            }
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
                    app.yuyue.shelf.Item(t("沉浸阅读"), Icons.read) { more = false; model.immersiveShown = true }
                    app.yuyue.shelf.Item(t("书伴"), Icons.companion) { more = false; model.chromeShown = false; model.companionShown = true }
                    app.yuyue.shelf.Item(t("书的信息"), Icons.info) { more = false; model.infoShown = true }
                    if (model.detail?.summary?.format != uniffi.yuyue_core.BookFormat.PDF) app.yuyue.shelf.Item(t("替换规则"), Icons.sort) { more = false; model.rulesShown = true }
                    if (model.detail?.summary?.format == uniffi.yuyue_core.BookFormat.TXT) app.yuyue.shelf.Item(t("编码和目录"), Icons.textSize) { more = false; model.txtShown = true }
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
            Column(Modifier.weight(1f).padding(start = 2.dp).clickable(enabled = model.player != null) { model.listenShown = true }) {
                val n = model.sentenceCount
                Text(
                    if (n > 0) t("第 %lld / %lld 句", minOf(model.sentence + 1, n), n) else model.chapterTitle ?: "",
                    fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = paper.ink, maxLines = 1,
                )
                Text(model.capsuleNote, fontSize = 12.sp, color = paper.ink2, maxLines = 1)
            }
            val reading = model.player?.spot != null
            Glyph(Icons.chevronLeft, if (reading) t("上一句") else t("上一页"), paper.ink) { model.step(false) }
            val playing = model.isPlaying
            Box(Modifier.size(40.dp).clip(CircleShape).background(paper.main).clickable(enabled = model.player != null, onClickLabel = if (playing) t("暂停") else t("朗读")) { model.togglePlay() }, contentAlignment = Alignment.Center) {
                Icon(if (playing) Icons.pause else Icons.play, if (playing) t("暂停") else t("朗读"), tint = paper.onMain, modifier = Modifier.size(20.dp))
            }
            Glyph(Icons.chevronRight, if (reading) t("下一句") else t("下一页"), paper.ink) { model.step(true) }
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
                modifier = Modifier.weight(1f).focusRequester(focus).semantics { contentDescription = t("搜这本书") },
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

/** 选中文字, or a highlight tapped: the same card as on iPhone, over the words — three colours
 *  and the wave, the two underlines (and 删除 for a highlight), then 想法 · 从这读 · 翻译 · 复制 · 分享. */
@Composable
private fun Cards(model: ReaderModel, paper: YYPaper, thought: (Mark) -> Unit) {
    val density = LocalDensity.current
    val context = LocalContext.current
    val sel = model.selection
    val open = model.openMark
    if (sel == null && open == null) return
    val current = open?.mark
    val text = current?.text ?: sel?.text ?: return
    val top = (sel?.rect?.y ?: open?.y ?: 200.0).toFloat()
    val bottom = (sel?.rect?.let { it.y + it.height } ?: ((open?.y ?: 200.0) + 24)).toFloat()
    val tint = YY.tint
    fun ringed(style: MarkStyle) = (current?.style ?: model.lastStyle) == style
    fun pick(style: MarkStyle) {
        if (current != null) { model.setStyle(style, current); model.dismissCards() } else model.mark(style)
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val cardHeight = 116.dp
        // Above the words when there is room, under them otherwise.
        val y = with(density) {
            val above = (top.dp - cardHeight - 12.dp)
            if (above > 56.dp) above else (bottom.dp + 12.dp)
        }
        Column(
            Modifier.align(Alignment.TopCenter).offset(y = y).width(340.dp)
                .shadow(16.dp, RoundedCornerShape(14.dp), ambientColor = Color.Black.copy(alpha = 0.14f), spotColor = Color.Black.copy(alpha = 0.2f))
                .clip(RoundedCornerShape(14.dp)).background(YY.c.card),
        ) {
            Row(Modifier.padding(start = 12.dp, end = 12.dp, top = 10.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                for (style in listOf(MarkStyle.YELLOW, MarkStyle.BLUE, MarkStyle.PINK, MarkStyle.WAVE)) {
                    Box(
                        Modifier.size(28.dp).border(1.5.dp, if (ringed(style)) tint.accent else Color.Transparent, CircleShape).padding(3.dp)
                            .clip(CircleShape).background(if (style == MarkStyle.WAVE) YY.c.hlR.copy(alpha = 0.14f) else style.swatch(paper)).clickable { pick(style) },
                        contentAlignment = Alignment.Center,
                    ) { if (style == MarkStyle.WAVE) Text("~", fontSize = 17.sp, fontWeight = FontWeight.Medium, color = YY.c.hlR, modifier = Modifier.offset(y = (-2).dp)) }
                }
                Box(Modifier.weight(1f))
                for (style in listOf(MarkStyle.UNDERLINE, MarkStyle.DOTTED)) {
                    Text(
                        "A", fontFamily = YY.serif, fontSize = 17.sp, color = if (ringed(style)) tint.accent else YY.c.t2,
                        textDecoration = androidx.compose.ui.text.style.TextDecoration.Underline,
                        modifier = Modifier.width(32.dp).clickable { pick(style) }.padding(vertical = 6.dp),
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    )
                }
                if (current != null) {
                    Icon(Icons.delete, t("删除划线"), tint = YY.c.danger, modifier = Modifier.size(26.dp).clickable { model.deleteMark(current) }.padding(4.dp))
                }
            }
            Box(Modifier.fillMaxWidth().height(0.5.dp).background(YY.c.line))
            Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 6.dp)) {
                CardAction(Icons.edit, t("想法"), Modifier.weight(1f)) {
                    val m = current ?: model.mark()
                    model.dismissCards()
                    if (m != null) thought(m)
                }
                if (model.player != null) CardAction(Icons.headphones, t("从这读"), Modifier.weight(1f)) { model.readFrom(current) }
                CardAction(Icons.companion, t("问"), Modifier.weight(1f), color = YY.tint.accent) {
                    model.companionQuote = text
                    model.dismissCards()
                    model.chromeShown = false
                    model.companionShown = true
                }
                CardAction(Icons.translate, t("翻译"), Modifier.weight(1f)) {
                    model.dismissCards()
                    runCatching {
                        context.startActivity(android.content.Intent(android.content.Intent.ACTION_PROCESS_TEXT).setType("text/plain").putExtra(android.content.Intent.EXTRA_PROCESS_TEXT, text).putExtra(android.content.Intent.EXTRA_PROCESS_TEXT_READONLY, true))
                    }.onFailure { model.show(app.yuyue.library.Library.Toast(app.yuyue.library.Library.Toast.Icon.Error, t("翻译没成功"), "")) }
                }
                CardAction(Icons.upload, t("复制"), Modifier.weight(1f)) { model.copySelection() }
                CardAction(Icons.share, t("分享"), Modifier.weight(1f)) {
                    model.dismissCards()
                    val book = model.detail?.summary
                    val quote = "“$text”" + (current?.note?.let { "\n$it" } ?: "") + (book?.let { "\n——《${it.title}》" } ?: "")
                    context.startActivity(android.content.Intent.createChooser(android.content.Intent(android.content.Intent.ACTION_SEND).setType("text/plain").putExtra(android.content.Intent.EXTRA_TEXT, quote), null))
                }
            }
        }
    }
}

@Composable
private fun CardAction(icon: ImageVector, title: String, modifier: Modifier, color: Color = YY.c.t1, onClick: () -> Unit) {
    Column(modifier.clip(RoundedCornerShape(8.dp)).clickable(onClick = onClick).padding(vertical = 4.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Icon(icon, title, tint = color, modifier = Modifier.size(19.dp))
        Text(title, fontSize = 11.sp, color = color, maxLines = 1)
    }
}

/** The colours 笔记 and the card show for a highlight, as on Apple (`YYColor.mkY` …). */
@Composable
private fun MarkStyle.swatch(paper: YYPaper): Color = when (this) {
    MarkStyle.YELLOW -> YY.c.mkY
    MarkStyle.BLUE -> YY.c.mkB
    MarkStyle.PINK -> YY.c.mkP
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

/** The volume keys while a book is open: the reader takes them to turn pages, or lets them be. */
object VolumeKeys {
    var handler: ((forward: Boolean) -> Boolean)? = null
}

/** 第一次进阅读器 (prototype): three faint zones — 上一页, 菜单, 下一页 — over the page the first time
 *  a book is opened, gone after three seconds and never shown again. */
@Composable
private fun PageTapHint(model: ReaderModel, paper: YYPaper) {
    var shown by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        if (Prefs.bool("reader.tapHintShown", false) || model.settings.mode != uniffi.yuyue_core.LayoutMode.PAGINATED) return@LaunchedEffect
        Prefs.set("reader.tapHintShown", true)
        shown = true
        kotlinx.coroutines.delay(3000)
        shown = false
    }
    androidx.compose.animation.AnimatedVisibility(
        shown,
        enter = androidx.compose.animation.fadeIn(androidx.compose.animation.core.tween(300)),
        exit = androidx.compose.animation.fadeOut(androidx.compose.animation.core.tween(600)),
    ) {
        Row(Modifier.fillMaxSize()) {
            listOf(Triple(t("上一页"), Icons.chevronLeft, 0.3f), Triple(t("菜单"), Icons.more, 0.4f), Triple(t("下一页"), Icons.chevronRight, 0.3f))
                .forEachIndexed { i, (title, icon, share) ->
                    Column(
                        Modifier.weight(share).fillMaxHeight().background(paper.ink.copy(alpha = if (i == 1) 0.07f else 0.035f)),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
                    ) {
                        Icon(icon, null, tint = paper.ink.copy(alpha = 0.7f), modifier = Modifier.size(24.dp))
                        Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = paper.ink.copy(alpha = 0.7f))
                    }
                    if (i < 2) Box(Modifier.width(0.5.dp).fillMaxHeight().background(paper.ink.copy(alpha = 0.12f)))
                }
        }
    }
}

/** Why reading aloud stopped. With no voice for the language, the way to get one comes first. */
@Composable
internal fun PlayerFailure(player: app.yuyue.speech.Player) {
    val message = player.failure ?: return
    val context = LocalContext.current
    val missing = player.missingVoice
    AlertDialog(
        onDismissRequest = { player.failure = null },
        containerColor = YY.c.card,
        title = { Text(if (missing != null) t("这台手机还没有%@声音", missing) else t("朗读出错了"), color = YY.c.t1) },
        text = { Text(message, color = YY.c.t2) },
        confirmButton = if (missing != null) {
            {
                TextButton({
                    player.failure = null
                    // The engine's own page for voice data: Chinese, English and the rest.
                    runCatching { context.startActivity(android.content.Intent(android.speech.tts.TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)) }
                }) { Text(t("下载%@声音", missing), color = YY.tint.accent) }
            }
        } else {
            { TextButton({ player.failure = null }) { Text(t("好"), color = YY.tint.accent) } }
        },
        dismissButton = if (missing != null) {
            { TextButton({ player.failure = null }) { Text(t("先不听"), color = YY.c.t2) } }
        } else null,
    )
}
