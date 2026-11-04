package app.yuyue.reader

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYPaper
import app.yuyue.design.YYSegments
import app.yuyue.library.Library
import app.yuyue.t
import uniffi.yuyue_core.CustomPaper
import uniffi.yuyue_core.Paper
import uniffi.yuyue_core.PaperHsl
import uniffi.yuyue_core.PaperTexture
import uniffi.yuyue_core.ReaderSettings
import uniffi.yuyue_core.YuyueCore
import uniffi.yuyue_core.paperColor
import uniffi.yuyue_core.paperColors
import uniffi.yuyue_core.paperHsl
import uniffi.yuyue_core.paperPalette
import uniffi.yuyue_core.paperStyle
import kotlin.random.Random

/** 我的纸, as on Apple: the papers the reader made, after the six presets. Their colours come
 *  from the core, so every device draws the same page. */
object Papers {
    var list by mutableStateOf<List<CustomPaper>>(emptyList())
        private set
    /** Goes up whenever a paper is made, changed or removed: open pages take it again. */
    var version by mutableIntStateOf(0)
        private set
    private var tokens = mapOf<String, YYPaper>()
    private var core: YuyueCore? = null

    fun load(core: YuyueCore) {
        this.core = core
        val fresh = runCatching { core.customPapers() }.getOrNull() ?: emptyList()
        if (fresh == list) return
        list = fresh
        tokens = emptyMap()
        version++
    }

    fun tokens(id: String): YYPaper? = tokens[id] ?: list.firstOrNull { it.id == id }?.let { customTokens(it) }?.also { tokens = tokens + (id to it) }

    fun paper(id: String?): CustomPaper? = id?.let { i -> list.firstOrNull { it.id == i } }

    fun save(paper: CustomPaper): CustomPaper? {
        val core = core ?: return null
        val saved = core.saveCustomPaper(paper)
        load(core)
        return saved
    }

    fun delete(id: String) {
        val core = core ?: return
        runCatching { core.deleteCustomPaper(id) }
        load(core)
    }

    /** 撤销 after 删除. */
    fun restore(id: String) {
        val core = core ?: return
        runCatching { core.restoreCustomPaper(id) }
        load(core)
    }

    fun rename(paper: CustomPaper, name: String) {
        val clean = name.trim().take(20)
        if (clean.isEmpty() || clean == paper.name) return
        runCatching { save(paper.copy(name = clean)) }
    }
}

/** 我的纸: its colours over the typography of the preset it reads like. */
fun customTokens(p: CustomPaper): YYPaper {
    val c = paperColors(p)
    val preset = c.preset.tokens
    return YYPaper(
        id = p.id, name = p.name, isDark = c.dark, hasNoiseTexture = p.texture != PaperTexture.NONE,
        bg = hexColor(c.bg), ink = hexColor(c.ink), ink2 = hexColor(c.ink2), line = hexColor(c.line), accent = hexColor(c.accent),
        hl = hexColor(c.hl), wave = hexColor(c.wave), glass = hexColor(c.glass), main = hexColor(c.main), onMain = hexColor(c.onMain),
        paperAccent = hexColor(c.paperAccent), text = preset.text, title = preset.title, meta = preset.meta,
    )
}

/** The paper the page is on: 我的纸 when it is one (and still there), else the preset. */
val ReaderSettings.paperTokens: YYPaper get() = customPaper?.let { Papers.tokens(it) } ?: paper.tokens

/** The paper as the swatches know it: a 我的纸 id, or a preset's. */
val ReaderSettings.paperChoice: String get() = customPaper?.takeIf { Papers.paper(it) != null } ?: paper.tokens.id

/** `data-yy-texture` (reader contract §2). */
val PaperTexture.css: String?
    get() = when (this) {
        PaperTexture.NONE -> null
        PaperTexture.GRAIN -> "grain"
        PaperTexture.XUAN -> "xuan"
        PaperTexture.LINEN -> "linen"
    }

private val PaperTexture.title: String
    get() = when (this) {
        PaperTexture.NONE -> t("无纹理")
        PaperTexture.GRAIN -> t("细颗粒")
        PaperTexture.XUAN -> t("宣纸")
        PaperTexture.LINEN -> t("亚麻")
    }

/** `#RRGGBB` or `#RRGGBBAA`. */
fun hexColor(hex: String): Color {
    val h = hex.removePrefix("#")
    val v = h.toLongOrNull(16) ?: return Color.White
    return if (h.length == 8) Color(((v and 0xFF) shl 24) or (v shr 8)) else Color(0xFF000000 or v)
}

fun Color.hex(): String = String.format("#%06X", toArgb() and 0xFFFFFF)

private val presets = listOf(Paper.PLAIN, Paper.DARK, Paper.KAMI, Paper.KAMI_NIGHT, Paper.SAGE, Paper.EINK)

/** The presets, then 我的纸 (long-press: 调整颜色、重命名、复制一张、删除), scrolling when there are
 *  too many; ＋ stays pinned at the right so making one is always in sight. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PaperRow(model: ReaderModel, edit: (CustomPaper) -> Unit) {
    val choice = model.settings.paperChoice
    val scroll = rememberScrollState()
    var renaming by remember { mutableStateOf<CustomPaper?>(null) }
    // The paper the page is on stays in sight, a new one too.
    val at = presets.map { it.tokens.id }.plus(Papers.list.map { it.id }).indexOf(choice)
    val step = with(LocalDensity.current) { 58.dp.roundToPx() }
    LaunchedEffect(choice) { if (at > 3) scroll.animateScrollTo((at - 3) * step) }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
        Row(Modifier.weight(1f).horizontalScroll(scroll), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (p in presets) {
                PaperTile(p.tokens, if (p == Paper.EINK) PaperTexture.GRAIN else PaperTexture.NONE, t(p.tokens.name), choice == p.tokens.id,
                    Modifier.clickable { model.update { it.copy(paper = p, customPaper = null) } })
            }
            for (mine in Papers.list) {
                var menu by remember { mutableStateOf(false) }
                Box {
                    PaperTile(customTokens(mine), mine.texture, mine.name, choice == mine.id,
                        Modifier.combinedClickable(onLongClick = { menu = true }) { model.choose(mine) })
                    DropdownMenu(menu, { menu = false }, containerColor = YY.c.card) {
                        DropdownMenuItem({ Text(t("调整颜色")) }, { menu = false; edit(mine) })
                        DropdownMenuItem({ Text(t("重命名")) }, { menu = false; renaming = mine })
                        DropdownMenuItem({ Text(t("复制一张")) }, { menu = false; model.duplicatePaper(mine) })
                        DropdownMenuItem({ Text(t("删除"), color = YY.c.danger) }, { menu = false; model.deletePaper(mine) })
                    }
                }
            }
        }
        Box(Modifier.padding(start = 6.dp).width(0.5.dp).height(44.dp).background(YY.c.line))
        Column(
            Modifier.padding(start = 6.dp).width(52.dp).clickable { edit(model.newPaper()) }.semantics { contentDescription = t("自己调一张纸") },
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Box(Modifier.fillMaxWidth().height(44.dp).background(YY.c.inset, RoundedCornerShape(10.dp)), contentAlignment = Alignment.Center) {
                Text("＋", fontSize = 18.sp, color = YY.c.t2)
            }
            Text(t("新建"), fontSize = 10.sp, color = YY.c.t2, maxLines = 1)
        }
    }
    renaming?.let { paper ->
        var name by remember(paper) { mutableStateOf(paper.name) }
        AlertDialog(
            onDismissRequest = { renaming = null },
            containerColor = YY.c.card,
            title = { Text(t("重命名"), color = YY.c.t1) },
            text = { OutlinedTextField(name, { name = it.take(20) }, singleLine = true) },
            confirmButton = { TextButton({ Papers.rename(paper, name); renaming = null }) { Text(t("好"), color = YY.tint.accent) } },
            dismissButton = { TextButton({ renaming = null }) { Text(t("取消"), color = YY.c.t2) } },
        )
    }
}

/** A paper as a small tile with 文 in its ink (`.v-rd-paper i`), its texture on it. */
@Composable
private fun PaperTile(tokens: YYPaper, texture: PaperTexture, name: String, on: Boolean, modifier: Modifier, height: Int = 44) {
    Column(
        modifier.width(52.dp).semantics { selected = on },
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(
            Modifier.fillMaxWidth().height(height.dp)
                .border(if (on) 1.5.dp else 0.dp, if (on) YY.c.t1 else Color.Transparent, RoundedCornerShape(12.dp)).padding(if (on) 3.dp else 0.dp)
                .clip(RoundedCornerShape(10.dp)).background(tokens.bg)
                .border(0.5.dp, if (tokens.isDark) Color.Transparent else YY.c.line, RoundedCornerShape(10.dp)),
            contentAlignment = Alignment.Center,
        ) {
            TextureLayer(texture, tokens.isDark, Modifier.fillMaxSize())
            Text("文", fontFamily = FontFamily.Serif, fontSize = 16.sp, color = tokens.ink)
        }
        Text(name, fontSize = 10.sp, color = if (on) YY.c.t1 else YY.c.t2, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal, maxLines = 1)
    }
}

/** 纹理 drawn natively, to look like the page's (reader.css `data-yy-texture`). */
@Composable
private fun TextureLayer(texture: PaperTexture, dark: Boolean, modifier: Modifier) {
    if (texture == PaperTexture.NONE) return
    Canvas(modifier) {
        val r = Random(7)
        when (texture) {
            PaperTexture.GRAIN -> {
                val dot = if (dark) Color.White.copy(alpha = 0.07f) else Color.Black.copy(alpha = 0.09f)
                repeat((size.width * size.height / 7f).toInt()) { drawRect(dot, Offset(r.nextFloat() * size.width, r.nextFloat() * size.height), Size(1.2f, 1.2f)) }
            }
            PaperTexture.XUAN -> {
                val fibre = Color(0.5f, 0.44f, 0.32f, if (dark) 0.16f else 0.11f)
                repeat((size.width * size.height / 90f).toInt()) {
                    val x = r.nextFloat() * size.width
                    val y = r.nextFloat() * size.height
                    drawLine(fibre, Offset(x, y), Offset(x + 8f + r.nextFloat() * 30f, y + (r.nextFloat() - 0.5f) * 3f), 0.9f)
                }
            }
            PaperTexture.LINEN -> {
                val thread = Color.Gray.copy(alpha = 0.09f)
                var x = 0f
                while (x < size.width) { drawRect(thread, Offset(x, 0f), Size(0.9f, size.height)); x += 4.5f }
                var y = 0f
                while (y < size.height) { drawRect(thread, Offset(0f, y), Size(size.width, 0.9f)); y += 4.5f }
            }
            PaperTexture.NONE -> Unit
        }
    }
}

/** 调纸, as docs/design/自己调纸页.html: 白天 or 夜里, six made colours for it, 微调 within bounds
 *  that stay restful (色调、浓淡、深浅), a texture, and the text: picked for the colour or one of
 *  four inks. Everything it can reach reads well, so there is nothing to warn about. No name to
 *  type: the core names a new paper after the colour it is closest to. The page behind changes as
 *  it is set; 取消 (or closing the sheet) puts it back. */
@Composable
fun PaperEditor(model: ReaderModel, start: CustomPaper, finish: (CustomPaper?) -> Unit) {
    var draft by remember(start) { mutableStateOf(start) }
    var night by remember(start) { mutableStateOf(paperColors(start).dark) }
    var hsl by remember(start) { mutableStateOf(paperHsl(start.bg)) }
    var tuning by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    val palette = paperPalette(night)
    val colors = paperColors(draft)
    fun set(p: CustomPaper) { draft = p; model.previewPaper(p) }
    fun swatch(h: Double = hsl.h, s: Double = hsl.s, l: Double = hsl.l) = hexColor(paperColor(PaperHsl(h, s, l), night))
    LaunchedEffect(start) { model.previewPaper(start) }
    // Closed without 完成 (the sheet pulled down): as 取消.
    DisposableEffect(Unit) { onDispose { model.previewPaper(null) } }

    // `.ed-top`
    Row(Modifier.fillMaxWidth().height(32.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.clickable { model.previewPaper(null); finish(null) }.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.chevronLeft, t("取消"), tint = YY.c.t2, modifier = Modifier.size(16.dp))
                Text(t("排版"), fontSize = 13.sp, color = YY.c.t2)
            }
        }
        Text(if (draft.id.isEmpty()) t("调纸") else t("调整“%@”", draft.name), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1, maxLines = 1)
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.End) {
            Text(t("完成"), fontSize = 12.5.sp, fontWeight = FontWeight.SemiBold, color = YY.tint.onBlack,
                modifier = Modifier.clip(CircleShape).background(YY.tint.black).clickable {
                    try {
                        val saved = Papers.save(draft)
                        model.previewPaper(null)
                        finish(saved)
                    } catch (e: Exception) {
                        failure = Library.message(e)
                    }
                }.padding(horizontal = 14.dp, vertical = 6.dp))
        }
    }
    YYSegments(listOf(false to t("白天"), true to t("夜里")), night, { toNight ->
        if (toNight != night) {
            val first = paperPalette(toNight).swatches.first()
            night = toNight
            hsl = paperHsl(first.color)
            set(draft.copy(bg = first.color, ink = null))
        }
    }, small = true, modifier = Modifier.fillMaxWidth())
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        for (sw in palette.swatches) {
            val made = draft.copy(bg = sw.color, name = sw.name)
            PaperTile(customTokens(made), draft.texture, sw.name, draft.bg == sw.color,
                Modifier.clickable { hsl = paperHsl(sw.color); set(draft.copy(bg = sw.color)) }, height = 40)
        }
    }
    // `.grp`
    Column(Modifier.fillMaxWidth().background(YY.c.card, RoundedCornerShape(14.dp)).border(0.5.dp, YY.c.line, RoundedCornerShape(14.dp)).padding(horizontal = 12.dp)) {
        Row(Modifier.fillMaxWidth().height(42.dp).clickable { tuning = !tuning }, verticalAlignment = Alignment.CenterVertically) {
            Text(t("微调颜色"), fontSize = 13.sp, color = YY.c.t1, modifier = Modifier.weight(1f))
            Text(t("色调、浓淡、深浅"), fontSize = 11.sp, color = YY.c.t3)
            Icon(Icons.chevronRight, null, tint = YY.c.t3, modifier = Modifier.size(14.dp).rotate(if (tuning) 90f else 0f))
        }
        if (tuning) {
            fun move(h: Double = hsl.h, s: Double = hsl.s, l: Double = hsl.l) {
                hsl = PaperHsl(h, s, l)
                set(draft.copy(bg = paperColor(hsl, night)))
            }
            val thumb = hexColor(colors.bg)
            Tune(t("色调"), hsl.h, 0.0, 359.0, (0..6).map { swatch(h = it * 60.0, s = maxOf(hsl.s, 30.0)) }, thumb) { move(h = it) }
            Tune(t("浓淡"), hsl.s, 0.0, palette.saturationMax, listOf(swatch(s = 0.0), swatch(s = palette.saturationMax)), thumb) { move(s = it) }
            // 深浅: light on the left on both sides, dark on the right.
            Tune(t("深浅"), hsl.l, palette.lightnessMin, palette.lightnessMax, listOf(swatch(l = palette.lightnessMax), swatch(l = palette.lightnessMin)), thumb, reversed = true) { move(l = it) }
            Box(Modifier.height(6.dp))
        }
        Line()
        Row(Modifier.fillMaxWidth().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(t("纹理"), fontSize = 13.sp, color = YY.c.t1, modifier = Modifier.weight(1f))
            for (tx in listOf(PaperTexture.NONE, PaperTexture.GRAIN, PaperTexture.XUAN, PaperTexture.LINEN)) {
                val on = draft.texture == tx
                Box(
                    Modifier.padding(start = 6.dp).size(40.dp, 30.dp)
                        .border(if (on) 1.5.dp else 0.dp, if (on) YY.c.t1 else Color.Transparent, RoundedCornerShape(9.dp)).padding(if (on) 2.5.dp else 0.dp)
                        .clip(RoundedCornerShape(7.dp)).background(hexColor(colors.bg)).border(0.5.dp, Color.Black.copy(alpha = 0.14f), RoundedCornerShape(7.dp))
                        .clickable { set(draft.copy(texture = tx)) }
                        .semantics { contentDescription = tx.title; selected = on },
                ) { TextureLayer(tx, colors.dark, Modifier.fillMaxSize()) }
            }
        }
        Line()
        Row(Modifier.fillMaxWidth().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(t("字色"), fontSize = 13.sp, color = YY.c.t1, modifier = Modifier.weight(1f))
            val auto = draft.ink == null
            Text(t("自动"), fontSize = 10.5.sp, fontWeight = FontWeight.SemiBold, color = if (auto) YY.c.t1 else YY.c.t2,
                modifier = Modifier.border(if (auto) 1.5.dp else 0.dp, if (auto) YY.c.t1 else Color.Transparent, CircleShape).padding(2.dp)
                    .clip(CircleShape).background(YY.c.inset).clickable { set(draft.copy(ink = null)) }.padding(horizontal = 9.dp, vertical = 4.dp))
            for (ink in palette.inks) {
                val on = draft.ink == ink.color
                Box(
                    Modifier.padding(start = 6.dp).size(30.dp)
                        .border(if (on) 1.5.dp else 0.dp, if (on) YY.c.t1 else Color.Transparent, CircleShape).padding(2.5.dp)
                        .clip(CircleShape).background(hexColor(colors.bg)).border(0.5.dp, Color.Black.copy(alpha = 0.18f), CircleShape)
                        .clickable { set(draft.copy(ink = ink.color)) }
                        .semantics { contentDescription = ink.name; selected = on },
                    contentAlignment = Alignment.Center,
                ) { Text(ink.name, fontSize = 10.5.sp, fontWeight = FontWeight.SemiBold, color = hexColor(ink.color), textAlign = TextAlign.Center) }
            }
        }
    }
    failure?.let { Text(it, fontSize = 11.sp, color = YY.c.danger) }
}

@Composable
private fun Line() = Box(Modifier.fillMaxWidth().height(0.5.dp).background(YY.c.line))

/** One 微调 slider on a coloured track (`.sl input`): the track shows where it goes, the knob is the colour. */
@Composable
private fun Tune(label: String, value: Double, lo: Double, hi: Double, track: List<Color>, thumb: Color, reversed: Boolean = false, change: (Double) -> Unit) {
    Row(Modifier.fillMaxWidth().height(34.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, fontSize = 12.sp, color = YY.c.t2, modifier = Modifier.width(36.dp))
        BoxWithConstraints(
            Modifier.weight(1f).height(30.dp)
                .semantics {
                    contentDescription = label
                    progressBarRangeInfo = ProgressBarRangeInfo(value.toFloat(), lo.toFloat()..hi.toFloat())
                    setProgress { change(it.toDouble().coerceIn(lo, hi)); true }
                }
                .pointerInput(lo, hi, reversed) {
                    fun at(x: Float) {
                        val p = ((x - 11.dp.toPx()) / (size.width - 22.dp.toPx())).coerceIn(0f, 1f)
                        change(lo + (if (reversed) 1 - p else p) * (hi - lo))
                    }
                    detectTapGestures { at(it.x) }
                }
                .pointerInput(lo, hi, reversed) {
                    detectDragGestures { pointer, _ ->
                        val p = ((pointer.position.x - 11.dp.toPx()) / (size.width - 22.dp.toPx())).coerceIn(0f, 1f)
                        change(lo + (if (reversed) 1 - p else p) * (hi - lo))
                    }
                },
            contentAlignment = Alignment.CenterStart,
        ) {
            val w = maxWidth - 22.dp
            val p = ((value - lo) / (hi - lo).coerceAtLeast(1e-9)).toFloat().coerceIn(0f, 1f)
            Box(Modifier.padding(horizontal = 11.dp).fillMaxWidth().height(6.dp).clip(CircleShape).background(Brush.horizontalGradient(track)))
            Box(
                Modifier.offset(x = w * (if (reversed) 1 - p else p)).size(22.dp).shadow(2.dp, CircleShape)
                    .clip(CircleShape).background(Color.White).padding(2.5.dp).clip(CircleShape).background(thumb)
            )
        }
    }
}
