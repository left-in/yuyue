package app.yuyue.reader

import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYSegments
import app.yuyue.t
import uniffi.yuyue_core.Font
import uniffi.yuyue_core.LayoutMode
import uniffi.yuyue_core.Paper
import kotlin.math.roundToInt

/** The card under Aa, as on iPhone: paper, typeface, size, line spacing, whether this book keeps
 *  its own, and the rest under 更多. The page changes as it is set. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TypesetSheet(model: ReaderModel, dismiss: () -> Unit) {
    var more by remember { mutableStateOf(false) }
    /** 调纸 open on this paper (a new one has no id yet). */
    var editing by remember { mutableStateOf<uniffi.yuyue_core.CustomPaper?>(null) }
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(), containerColor = YY.c.card, scrimColor = androidx.compose.ui.graphics.Color.Transparent) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            val open = editing
            when {
                open != null -> PaperEditor(model, open) { saved -> editing = null; saved?.let { model.choose(it) } }
                more -> More(model) { more = false }
                else -> Main(model, { more = true }) { editing = it }
            }
        }
    }
}

/** 紧 · 适中 · 松; null is the paper's own. */
private val spacings = listOf(1.6, null, 2.2)

@Composable
private fun Main(model: ReaderModel, openMore: () -> Unit, edit: (uniffi.yuyue_core.CustomPaper) -> Unit) {
    val s = model.settings
    PaperRow(model, edit)
    // Android phones have no 楷体 of their own, so 楷体 is 霞鹜文楷 here, downloaded when chosen.
    YYSegments(
        listOf<Pair<Font?, String>>(null to t("系统"), Font.SERIF to t("宋体"), Font.WEN_KAI to t("霞鹜文楷")),
        s.font, { f -> model.update { it.copy(font = f) }; if (f == Font.WEN_KAI) WenKai.ensure() }, modifier = Modifier.fillMaxWidth(),
    )
    WenKaiStatus(s.font == Font.WEN_KAI)
    Row(
        Modifier.fillMaxWidth().height(40.dp).background(YY.c.inset, RoundedCornerShape(12.dp)).padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text("A", fontFamily = FontFamily.Serif, fontSize = 13.sp, color = YY.c.t1)
        Slider(
            s.fontSize.toFloat(), { v -> model.update { it.copy(fontSize = v.roundToInt().toDouble()) } }, valueRange = 12f..34f, steps = 21,
            modifier = Modifier.weight(1f).semantics { contentDescription = t("字号"); stateDescription = "${s.fontSize.roundToInt()}" },
            colors = SliderDefaults.colors(thumbColor = YY.c.card, activeTrackColor = YY.tint.fill, inactiveTrackColor = YY.c.line, activeTickColor = androidx.compose.ui.graphics.Color.Transparent, inactiveTickColor = androidx.compose.ui.graphics.Color.Transparent),
        )
        Text("A", fontFamily = FontFamily.Serif, fontSize = 19.sp, color = YY.c.t1)
        Text("${s.fontSize.roundToInt()}", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = YY.c.t1, modifier = Modifier.width(26.dp))
    }
    YYSegments(
        spacings.mapIndexed { i, _ -> i to listOf(t("行距紧"), t("行距适中"), t("行距松"))[i] },
        spacings.indexOf(s.lineHeight).takeIf { it >= 0 } ?: 1, { i -> model.update { it.copy(lineHeight = spacings[i]) } },
        small = true, modifier = Modifier.fillMaxWidth(),
    )
    Column {
        SwitchRow(t("只用于这本书"), model.ownSettings) { model.setOwn(it) }
        Row(Modifier.fillMaxWidth().height(44.dp).clickable(onClick = openMore), verticalAlignment = Alignment.CenterVertically) {
            Text(t("更多"), fontSize = 13.sp, color = YY.c.t1, modifier = Modifier.weight(1f))
            Text(t("段距、页边、翻页方式"), fontSize = 12.sp, color = YY.c.t3)
            Icon(Icons.chevronRight, null, tint = YY.c.t3, modifier = Modifier.size(16.dp))
        }
    }
}

@Composable
private fun More(model: ReaderModel, back: () -> Unit) {
    val s = model.settings
    Row(Modifier.clickable(onClick = back), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.chevronLeft, null, tint = YY.tint.accent, modifier = Modifier.size(18.dp))
        Text(t("排版"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = YY.tint.accent)
    }
    Row2(t("翻页方式")) {
        YYSegments(listOf(LayoutMode.PAGINATED to t("左右翻页"), LayoutMode.SCROLLED to t("上下滚动")), s.mode, { m -> model.update { it.copy(mode = m) } }, modifier = Modifier.width(190.dp))
    }
    Row2(t("段距")) {
        YYSegments(listOf<Pair<Double?, String>>(0.0 to t("无"), null to t("适中"), 1.0 to t("宽")), s.paragraphSpacing, { v -> model.update { it.copy(paragraphSpacing = v) } }, modifier = Modifier.width(190.dp))
    }
    Row2(t("首行缩进")) {
        YYSegments(listOf<Pair<Boolean?, String>>(null to t("跟书"), true to t("缩进"), false to t("不缩")), s.indent, { v -> model.update { it.copy(indent = v) } }, modifier = Modifier.width(190.dp))
    }
    Row2(t("两端对齐")) {
        YYSegments(listOf<Pair<Boolean?, String>>(null to t("跟书"), true to t("对齐"), false to t("靠左")), s.justify, { v -> model.update { it.copy(justify = v) } }, modifier = Modifier.width(190.dp))
    }
    SwitchRow(t("中文标点挤压"), s.compress) { v -> model.update { it.copy(compress = v) } }
    if (model.isChinese) {
        Row2(t("简繁")) {
            YYSegments(listOf<Pair<uniffi.yuyue_core.Script?, String>>(null to t("原样"), uniffi.yuyue_core.Script.SIMPLIFIED to t("简体"), uniffi.yuyue_core.Script.TRADITIONAL to t("繁體")),
                model.script, { model.changeScript(it) }, modifier = Modifier.width(190.dp))
        }
    }
}

@Composable
private fun Row2(title: String, content: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(title, fontSize = 13.sp, color = YY.c.t1, modifier = Modifier.weight(1f))
        content()
    }
}

@Composable
fun SwitchRow(title: String, on: Boolean, set: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().height(44.dp).toggleable(on, role = androidx.compose.ui.semantics.Role.Switch, onValueChange = set), verticalAlignment = Alignment.CenterVertically) {
        Text(title, fontSize = 13.sp, color = YY.c.t1, modifier = Modifier.weight(1f))
        Switch(on, null, colors = SwitchDefaults.colors(checkedTrackColor = YY.tint.fill, checkedThumbColor = YY.c.card, uncheckedTrackColor = YY.c.inset, uncheckedBorderColor = YY.c.line))
    }
}
