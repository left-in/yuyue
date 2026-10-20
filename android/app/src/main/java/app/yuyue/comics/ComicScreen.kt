package app.yuyue.comics

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYSegments
import app.yuyue.design.rememberPref
import app.yuyue.library.Library
import app.yuyue.reader.SwitchRow
import app.yuyue.reader.VolumeKeys
import app.yuyue.t
import kotlinx.coroutines.delay
import kotlin.math.abs
import kotlin.math.roundToInt

/** 点哪里翻页: four ways; left and right swap round with the reading direction. */
enum class TapZones(val key: String) {
    Sides("sides"), Ell("ell"), TopBottom("topBottom"), Swipe("swipe");
    val title: String get() = when (this) { Sides -> t("左右"); Ell -> t("L 形"); TopBottom -> t("上下"); Swipe -> t("只滑动") }
}

/** 漫画 on the phone (prototype C2 单页 · C3 条漫 · C4 阅读设置), as on iPhone: only the pictures,
 *  on black. A tap in the middle brings the bars; the sides turn the page, and so does a swipe. */
@Composable
fun ComicScreen(library: Library, bookID: String, close: () -> Unit) {
    val config = LocalConfiguration.current
    val model = remember(bookID) { ComicModel(library, bookID, config.screenWidthDp > config.screenHeightDp) }
    var chrome by remember { mutableStateOf(true) }
    var touched by remember { mutableStateOf(0) }
    var tocShown by remember { mutableStateOf(false) }
    var settingsShown by remember { mutableStateOf(false) }
    val crop by rememberPref("comic.crop", true)
    val split by rememberPref("comic.splitSpreads", true)
    model.splitWide = split && config.screenHeightDp > config.screenWidthDp
    DisposableEffect(model) {
        VolumeKeys.handler = { forward -> if (model.layout != ComicModel.Layout.Strip) { if (forward) model.next() else model.previous(); true } else false }
        onDispose { VolumeKeys.handler = null; model.close() }
    }
    BackHandler { close() }
    // The bars go again after a few seconds.
    LaunchedEffect(chrome, touched, tocShown, settingsShown) {
        if (chrome && !tocShown && !settingsShown) { delay(4000); chrome = false }
    }
    // 预加载: the next pages decoded before they are turned to.
    val side = with(LocalDensity.current) { config.screenHeightDp.dp.roundToPx() }
    LaunchedEffect(model.episode, model.page, crop) { for (p in model.upcoming) ComicImages.image(p, side, crop) }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        if (model.layout == ComicModel.Layout.Strip) Strip(model, onTap = { chrome = !chrome }, contents = { tocShown = true })
        else Pages(model, crop, side, toggle = { chrome = !chrome })
        AnimatedVisibility(chrome, enter = fadeIn(), exit = fadeOut()) {
            Bars(model, crop, close, onTouch = { touched++ }, toc = { tocShown = true }, settings = { settingsShown = true })
        }
    }
    if (tocShown) Contents(model) { tocShown = false }
    if (settingsShown) Settings(model) { settingsShown = false }
    model.failure?.let { message ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { model.failure = null }, containerColor = YY.c.card,
            title = { Text(t("出错了"), color = YY.c.t1) }, text = { Text(message, color = YY.c.t2) },
            confirmButton = { androidx.compose.material3.TextButton({ model.failure = null }) { Text(t("好"), color = YY.tint.accent) } },
        )
    }
}

@Composable
private fun Picture(path: String, side: Int, crop: Boolean, modifier: Modifier, alignment: Alignment = Alignment.Center, scale: ContentScale = ContentScale.Fit) {
    var bitmap by remember(path, crop) { mutableStateOf(ComicImages.cached(path, side, crop)) }
    LaunchedEffect(path, crop) { if (bitmap == null) bitmap = ComicImages.image(path, side, crop) }
    val b = bitmap
    if (b != null) Image(b.asImageBitmap(), null, modifier, contentScale = scale, alignment = alignment)
    else Box(modifier)
}

@Composable
private fun Pages(model: ComicModel, crop: Boolean, side: Int, toggle: () -> Unit) {
    val e = model.current ?: return
    val zonesKey by rememberPref("comic.tapZones", TapZones.Sides.key)
    val zones = TapZones.entries.firstOrNull { it.key == zonesKey } ?: TapZones.Sides
    var zoom by remember(model.episode, model.page) { mutableFloatStateOf(1f) }
    var pan by remember(model.episode, model.page) { mutableStateOf(Offset.Zero) }
    var drag by remember { mutableFloatStateOf(0f) }
    fun turn(left: Boolean) = if (left == model.rightToLeft) model.next() else model.previous()

    BoxWithConstraints(
        Modifier.fillMaxSize()
            .pointerInput(model.episode, model.page, zones) {
                detectTapGestures(
                    onDoubleTap = { p ->
                        if (zoom > 1f) { zoom = 1f; pan = Offset.Zero } else { zoom = 2f; pan = Offset(size.width / 2f - p.x, size.height / 2f - p.y) }
                    },
                    onTap = { p ->
                        if (zoom > 1f) return@detectTapGestures toggle()
                        val x = p.x / size.width
                        val y = p.y / size.height
                        val middle = x in 1f / 3..2f / 3 && y in 1f / 3..2f / 3
                        when (zones) {
                            TapZones.Sides -> if (x < 1f / 3) turn(true) else if (x > 2f / 3) turn(false) else toggle()
                            TapZones.Ell -> if (middle) toggle() else {
                                val back = if (model.rightToLeft) (x > 2f / 3 || y < 1f / 3) else (x < 1f / 3 || y < 1f / 3)
                                if (back) model.previous() else model.next()
                            }
                            TapZones.TopBottom -> if (y < 1f / 3) model.previous() else if (y > 2f / 3) model.next() else toggle()
                            TapZones.Swipe -> toggle()
                        }
                    },
                )
            }
            .pointerInput(model.episode, model.page) {
                detectTransformGestures { _, move, gesture, _ ->
                    if (gesture != 1f || zoom > 1f) {
                        zoom = (zoom * gesture).coerceIn(1f, 4f)
                        pan = if (zoom > 1f) pan + move else Offset.Zero
                    } else {
                        drag += move.x
                    }
                }
            }
            .pointerInput(model.episode, model.page) {
                // A swipe pulls the next page in from the side reading goes towards.
                awaitPointerEventScope {
                    while (true) {
                        val ev = awaitPointerEvent()
                        if (ev.changes.all { !it.pressed }) {
                            if (zoom <= 1f && abs(drag) > 50.dp.toPx()) turn(drag > 0)
                            drag = 0f
                        }
                    }
                }
            },
    ) {
        val shown = model.shown.filter { it in e.pages.indices }
        val paths = (if (model.rightToLeft) shown.reversed() else shown).map { e.pages[it] }
        val splitting = model.splitting
        val ratios = paths.map { model.aspect(it) / if (splitting) 2 else 1 }
        val total = ratios.sum().coerceAtLeast(0.1)
        val h = minOf(maxHeight.value, maxWidth.value / total.toFloat())
        Row(
            Modifier.align(Alignment.Center).graphicsLayer { scaleX = zoom; scaleY = zoom; translationX = pan.x; translationY = pan.y },
        ) {
            paths.forEachIndexed { i, path ->
                val w = (h * ratios[i]).toFloat().dp
                if (splitting) {
                    // Half of the spread: the right half first when read right to left.
                    val right = (model.half == 0) == model.rightToLeft
                    Box(Modifier.width(w).height(h.dp).clipToBounds()) {
                        Picture(path, side, crop, Modifier.width(w * 2).height(h.dp).align(if (right) Alignment.CenterEnd else Alignment.CenterStart), scale = ContentScale.FillBounds)
                    }
                } else {
                    Picture(path, side, crop, Modifier.width(w).height(h.dp), scale = ContentScale.FillBounds)
                }
            }
        }
    }
}

/** 条漫: scrolled down without end, each episode's pictures full width; where one ends, 上一话 · 目录 · 下一话. */
@Composable
private fun Strip(model: ComicModel, onTap: () -> Unit, contents: () -> Unit) {
    val rows = remember(model.episodes) { model.episodes.flatMap { e -> e.pages.indices.map { e.id to it } } }
    val start = rows.indexOfFirst { it.first == model.episode && it.second == model.page }.coerceAtLeast(0)
    val state = rememberLazyListState(initialFirstVisibleItemIndex = start)
    val side = with(LocalDensity.current) { LocalConfiguration.current.screenWidthDp.dp.roundToPx() }
    LaunchedEffect(state) {
        snapshotFlow { state.firstVisibleItemIndex }.collect { i -> rows.getOrNull(i)?.let { (e, p) -> model.scrolled(e, p) } }
    }
    LaunchedEffect(model.episode, model.page) {
        val i = rows.indexOfFirst { it.first == model.episode && it.second == model.page }
        if (i >= 0 && i != state.firstVisibleItemIndex) state.scrollToItem(i)
    }
    LazyColumn(state = state, modifier = Modifier.fillMaxSize().pointerInput(Unit) { detectTapGestures(onTap = { onTap() }) }) {
        itemsIndexed(rows, key = { _, r -> "${r.first}-${r.second}" }) { _, (e, p) ->
            val ep = model.episodes[e]
            val path = ep.pages[p]
            Column {
                if (p == 0 && e > 0) Text(model.name(ep), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.85f), modifier = Modifier.fillMaxWidth().padding(vertical = 28.dp), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                Picture(path, side, false, Modifier.fillMaxWidth().aspectRatio(model.aspect(path).toFloat()), scale = ContentScale.FillWidth)
                if (p == ep.pages.size - 1) Seam(model, ep, contents)
            }
        }
    }
}

@Composable
private fun Seam(model: ComicModel, e: ComicModel.Episode, contents: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(vertical = 44.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Text(t("%@ · 完", model.name(e)), fontSize = 13.sp, color = Color.White.copy(alpha = 0.6f))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            SeamButton(t("上一话"), e.id > 0) { model.go(e.id - 1, 0) }
            SeamButton(t("目录"), true) { contents() }
            SeamButton(t("下一话"), e.id + 1 < model.episodes.size, strong = true) { model.go(e.id + 1, 0) }
        }
    }
}

@Composable
private fun SeamButton(title: String, enabled: Boolean, strong: Boolean = false, onClick: () -> Unit) {
    Box(
        Modifier.height(38.dp).background(if (strong) Color.White else Color.White.copy(alpha = 0.14f), CircleShape)
            .clickable(enabled = enabled, onClick = onClick).padding(horizontal = 16.dp).graphicsLayer { alpha = if (enabled) 1f else 0.35f },
        contentAlignment = Alignment.Center,
    ) { Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = if (strong) Color.Black else Color.White) }
}

@Composable
private fun Bars(model: ComicModel, crop: Boolean, close: () -> Unit, onTouch: () -> Unit, toc: () -> Unit, settings: () -> Unit) {
    var cropOn by rememberPref("comic.crop", true)
    Box(Modifier.fillMaxSize()) {
        Row(
            Modifier.align(Alignment.TopCenter).fillMaxWidth().background(Color.Black.copy(alpha = 0.72f)).windowInsetsPadding(WindowInsets.statusBars).padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(Icons.close, t("关闭"), tint = Color.White, modifier = Modifier.size(40.dp).clickable(onClick = close).padding(10.dp))
            Text(if (model.episodes.size > 1) "${model.title} · ${model.current?.let(model::name) ?: ""}" else model.title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White, maxLines = 1, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            Text(model.current?.let { "${model.page + 1} / ${it.pages.size}" } ?: "", fontSize = 12.5.sp, color = Color.White.copy(alpha = 0.6f), modifier = Modifier.padding(end = 8.dp))
        }
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(Color.Black.copy(alpha = 0.72f)).windowInsetsPadding(WindowInsets.navigationBars).padding(horizontal = 16.dp).padding(top = 12.dp, bottom = 4.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (model.layout != ComicModel.Layout.Strip) PageSlider(model, onTouch)
            Row {
                Tool(t("目录"), Icons.list, Modifier.weight(1f), onClick = toc)
                Tool(model.layout.title, Icons.grid, Modifier.weight(1f)) {
                    val all = ComicModel.Layout.entries
                    model.changeLayout(all[(all.indexOf(model.layout) + 1) % all.size]); onTouch()
                }
                Tool(t("裁白边"), Icons.textSize, Modifier.weight(1f), on = crop) { cropOn = !cropOn; onTouch() }
                Tool(t("设置"), Icons.settings, Modifier.weight(1f), onClick = settings)
            }
        }
    }
}

@Composable
private fun Tool(title: String, icon: ImageVector, modifier: Modifier, on: Boolean = false, onClick: () -> Unit) {
    val color = if (on) YY.tint.accent else Color.White
    Column(modifier.height(48.dp).clickable(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Icon(icon, null, tint = color, modifier = Modifier.size(20.dp))
        Text(title, fontSize = 10.5.sp, color = color)
    }
}

/** The page slider, running right to left when the comic does; the ends go to the next or previous episode. */
@Composable
private fun PageSlider(model: ComicModel, onTouch: () -> Unit) {
    val count = maxOf(1, model.current?.pages?.size ?: 1)
    var sliding by remember { mutableStateOf<Float?>(null) }
    androidx.compose.runtime.CompositionLocalProvider(androidx.compose.ui.platform.LocalLayoutDirection provides if (model.rightToLeft) LayoutDirection.Rtl else LayoutDirection.Ltr) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            val canBack = model.episode > 0
            val canOn = model.episode + 1 < model.episodes.size
            Text(t("上一话"), fontSize = 12.sp, color = Color.White.copy(alpha = if (canBack) 1f else 0.3f), modifier = Modifier.clickable(enabled = canBack) { model.go(model.episode - 1, 0) })
            Slider(
                sliding ?: model.page.toFloat(), { sliding = it; onTouch() }, valueRange = 0f..maxOf(1, count - 1).toFloat(), modifier = Modifier.weight(1f),
                onValueChangeFinished = { sliding?.let { model.go(model.episode, it.roundToInt()) }; sliding = null },
                colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = YY.tint.accent, inactiveTrackColor = Color.White.copy(alpha = 0.25f)),
            )
            Text(t("下一话"), fontSize = 12.sp, color = Color.White.copy(alpha = if (canOn) 1f else 0.3f), modifier = Modifier.clickable(enabled = canOn) { model.go(model.episode + 1, 0) })
        }
    }
}

/** 目录 as the grid of episode numbers: read ones faded, the one being read filled in; a comic of
 *  one episode shows its pages instead. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Contents(model: ComicModel, dismiss: () -> Unit) {
    val byPage = model.episodes.size <= 1
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(), containerColor = YY.c.card) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(if (byPage) t("目录 · 共 %lld 页", model.current?.pages?.size ?: 0) else t("目录 · 共 %lld 话", model.episodes.size), fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
            Text(if (byPage) t("读到 %@", model.pageLabel) else t("读到%@ · %@", model.current?.let(model::name) ?: "", model.pageLabel), fontSize = 13.sp, color = YY.c.t2)
            val cells = if (byPage) (model.current?.pages?.indices?.toList() ?: emptyList()) else model.episodes.map { it.id }
            LazyVerticalGrid(GridCells.Fixed(5), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                items(cells) { n ->
                    val current = if (byPage) n in model.shown else n == model.episode
                    val read = if (byPage) n < model.page else n < model.episode
                    Box(
                        Modifier.height(44.dp).background(if (current) YY.tint.accent else YY.c.inset, RoundedCornerShape(10.dp)).clickable {
                            if (byPage) model.go(model.episode, n) else model.go(n, if (n == model.episode) model.page else 0)
                            dismiss()
                        },
                        contentAlignment = Alignment.Center,
                    ) { Text("${n + 1}", fontSize = 15.sp, fontWeight = if (current) FontWeight.Bold else FontWeight.Medium, color = if (current) Color.White else if (read) YY.c.t3 else YY.c.t1) }
                }
            }
        }
    }
}

/** 阅读设置: how this comic is read, and the taps. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Settings(model: ComicModel, dismiss: () -> Unit) {
    var zones by rememberPref("comic.tapZones", TapZones.Sides.key)
    var split by rememberPref("comic.splitSpreads", true)
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(), containerColor = YY.c.card) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(t("阅读设置"), fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
            Label(t("看法"))
            YYSegments(ComicModel.Layout.entries.map { it to it.title }, model.layout, { model.changeLayout(it) }, modifier = Modifier.fillMaxWidth())
            Label(t("方向"))
            YYSegments(listOf(true to t("从右往左"), false to t("从左往右")), model.rightToLeft, { model.changeDirection(it) }, modifier = Modifier.fillMaxWidth())
            Label(t("点哪里翻页"))
            YYSegments(TapZones.entries.map { it.key to it.title }, zones, { zones = it }, modifier = Modifier.fillMaxWidth())
            SwitchRow(t("竖屏时拆开跨页"), split) { split = it }
        }
    }
}

@Composable
private fun Label(text: String) = Text(text, fontSize = 12.sp, color = YY.c.t3)
