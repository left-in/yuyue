package app.yuyue.design

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.yuyue.t

/** A page of these pieces on its grey ground. */
@Composable
fun YYPage(modifier: Modifier = Modifier, contentPadding: PaddingValues = PaddingValues(0.dp), content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier
            .fillMaxSize()
            .background(YY.c.bg)
            .verticalScroll(rememberScrollState())
            .padding(contentPadding)
            .padding(horizontal = YY.s(16))
            .padding(bottom = YY.s(20) + app.yuyue.LocalTabBarHeight.current),
        content = content,
    )
}

/** A heading over a card, a grey note on its right. */
@Composable
fun YYLabel(title: String, trailing: String? = null) {
    Row(
        Modifier.fillMaxWidth().padding(top = YY.s(18), bottom = YY.s(8), start = YY.s(2), end = YY.s(2)),
        verticalAlignment = Alignment.Bottom,
    ) {
        Text(title, style = YY.font(12.5f, FontWeight.SemiBold), color = YY.c.t1)
        Spacer(Modifier.weight(1f))
        if (trailing != null) Text(trailing, style = YY.font(10.5f), color = YY.c.t3)
    }
}

/** A grey line under a card. */
@Composable
fun YYNote(text: String, color: Color = YY.c.t3) {
    Text(
        text,
        style = YY.font(10f).copy(lineHeight = YY.sp(16f)),
        color = color,
        modifier = Modifier.padding(top = YY.s(6), start = YY.s(4), end = YY.s(4)),
    )
}

/** `.grp`: a white card of rows, a hairline between them. Pass rows as separate children. */
@Composable
fun YYGroup(modifier: Modifier = Modifier, rows: List<@Composable () -> Unit>) {
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(YY.s(14)))
            .background(YY.c.card)
            .border(0.5.dp, if (YY.dark) Color.White.copy(alpha = 0.06f) else YY.c.line, RoundedCornerShape(YY.s(14)))
            .padding(horizontal = YY.s(12)),
    ) {
        rows.forEachIndexed { i, row ->
            if (i > 0) Box(Modifier.fillMaxWidth().height(0.5.dp).background(YY.c.line))
            row()
        }
    }
}

/** A group from a builder: `YYGroup { row { … }; row { … } }`. */
@Composable
fun YYGroup(modifier: Modifier = Modifier, build: GroupScope.() -> Unit) {
    val scope = GroupScope().apply(build)
    YYGroup(modifier, scope.rows)
}

class GroupScope {
    val rows = mutableListOf<@Composable () -> Unit>()
    fun row(content: @Composable () -> Unit) {
        rows += content
    }
}

/** A white card on its own. */
fun Modifier.yyCard(dark: Boolean, card: Color, line: Color, radius: Dp = YY.s(16)): Modifier =
    this
        .shadow(if (dark) 0.dp else 2.dp, RoundedCornerShape(radius), ambientColor = Color(0x14332E29), spotColor = Color(0x14332E29))
        .clip(RoundedCornerShape(radius))
        .background(card)
        .border(0.5.dp, if (dark) Color.White.copy(alpha = 0.06f) else line, RoundedCornerShape(radius))

@Composable
fun Modifier.yyCard(radius: Dp = YY.s(16)): Modifier = yyCard(YY.dark, YY.c.card, YY.c.line, radius)

/** `.grp .row`: an icon, what it is, and a grey value with a chevron. */
@Composable
fun YYRow(
    title: String,
    icon: ImageVector? = null,
    value: String? = null,
    chevron: Boolean = false,
    titleColor: Color = YY.c.t1,
    trailing: @Composable RowScope.() -> Unit = {},
    onClick: (() -> Unit)? = null,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = YY.s(38))
            .then(if (onClick != null) Modifier.clickable(role = androidx.compose.ui.semantics.Role.Button, onClick = onClick) else Modifier),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(YY.s(10)),
    ) {
        if (icon != null) Icon(icon, null, tint = YY.c.t2, modifier = Modifier.size(YY.s(15)))
        // The name stays whole; the grey value gives way.
        Text(title, style = YY.font(11.5f), color = titleColor, maxLines = 1)
        Text(
            value ?: "", style = YY.font(10.5f), color = YY.c.t3, maxLines = 1, overflow = TextOverflow.Ellipsis,
            textAlign = androidx.compose.ui.text.style.TextAlign.End, modifier = Modifier.weight(1f).padding(start = YY.s(8)),
        )
        trailing()
        if (chevron) Icon(Icons.chevronRight, null, tint = YY.c.t3, modifier = Modifier.size(YY.s(11)))
    }
}

/** A field with its name in a fixed column on the left. */
@Composable
fun YYField(label: String, labelWidth: Float = 58f, field: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = YY.s(38)), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = YY.font(11f), color = YY.c.t2, modifier = Modifier.width(YY.s(labelWidth)))
        Spacer(Modifier.width(YY.s(8)))
        Box(Modifier.weight(1f)) { field() }
    }
}

/** Choices on an inset track, the chosen one lifted on a white chip. */
@Composable
fun <T> YYSegments(items: List<Pair<T, String>>, selection: T, onSelect: (T) -> Unit, small: Boolean = false, modifier: Modifier = Modifier) {
    Row(
        modifier
            .clip(RoundedCornerShape(YY.s(if (small) 10 else 12)))
            .background(YY.c.inset)
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        for ((value, title) in items) {
            val on = value == selection
            Box(
                Modifier
                    .weight(1f, fill = true)
                    .height(YY.s(if (small) 22 else 28))
                    .then(
                        if (on) Modifier.shadow(1.dp, RoundedCornerShape(YY.s(if (small) 7 else 9))).clip(RoundedCornerShape(YY.s(if (small) 7 else 9))).background(YY.c.card)
                        else Modifier.clip(RoundedCornerShape(YY.s(if (small) 7 else 9))),
                    )
                    .selectable(selected = on, role = androidx.compose.ui.semantics.Role.Tab) { onSelect(value) }
                    .padding(horizontal = if (small) YY.s(8) else 0.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    title,
                    style = YY.font(if (small) 10f else 11f, if (on) FontWeight.SemiBold else FontWeight.Normal),
                    color = if (on) YY.c.t1 else YY.c.t2,
                    maxLines = 1,
                    softWrap = false,
                )
            }
        }
    }
}

enum class ButtonKind { Main, Raised, Soft, Plain, Danger }
enum class ButtonSize { Small, Regular, Large }

/** The app's pill buttons: `Main`, the page's one action, is a faint wash of the theme colour with
 *  a hairline and words in the colour; `Raised` and `Plain` the warm white pill with a hairline.
 *  No shadows. */
@Composable
fun YYButton(
    title: String,
    kind: ButtonKind = ButtonKind.Plain,
    size: ButtonSize = ButtonSize.Regular,
    wide: Boolean = false,
    enabled: Boolean = true,
    icon: ImageVector? = null,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    // Low on purpose: a tall pill looks heavy next to the rows around it.
    val height = when (size) { ButtonSize.Small -> 26f; ButtonSize.Regular -> 30f; ButtonSize.Large -> 38f }
    val font = when (size) { ButtonSize.Small -> 11f; ButtonSize.Regular -> 12f; ButtonSize.Large -> 13.5f }
    val pad = when (size) { ButtonSize.Small -> 11f; ButtonSize.Regular -> 14f; ButtonSize.Large -> 20f }
    val tint = YY.tint
    val fg = when (kind) {
        ButtonKind.Main -> tint.onBlack
        ButtonKind.Soft -> tint.accent
        ButtonKind.Danger -> YY.c.danger
        else -> YY.c.t1
    }
    val bg = when (kind) {
        ButtonKind.Main -> tint.black
        ButtonKind.Raised, ButtonKind.Plain -> YY.c.pill
        ButtonKind.Soft -> tint.accentSoft
        ButtonKind.Danger -> YY.c.danger.copy(alpha = 0.11f)
    }
    val line = when (kind) {
        ButtonKind.Main -> tint.edge
        ButtonKind.Raised, ButtonKind.Plain -> YY.c.pillLine
        else -> Color.Transparent
    }
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    Row(
        modifier
            .then(if (wide) Modifier.fillMaxWidth() else Modifier)
            .height(YY.s(height))
            .alpha(if (!enabled) 0.4f else if (pressed) 0.75f else 1f)
            .clip(CircleShape)
            .background(bg)
            .border(0.5.dp, line, CircleShape)
            .clickable(interactionSource = source, indication = null, enabled = enabled, onClick = onClick)
            .padding(horizontal = YY.s(pad)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(YY.s(5), Alignment.CenterHorizontally),
    ) {
        if (icon != null) Icon(icon, null, tint = fg, modifier = Modifier.size(YY.s(font + 2)))
        val weight = if (kind == ButtonKind.Main || kind == ButtonKind.Danger) FontWeight.SemiBold else FontWeight.Normal
        Text(title, style = YY.font(font, weight), color = fg, maxLines = 1, softWrap = false)
    }
}

/** A small grey label. */
@Composable
fun YYTag(text: String, icon: ImageVector? = null) {
    Row(
        Modifier.clip(RoundedCornerShape(YY.s(5))).background(YY.c.inset).padding(horizontal = YY.s(5), vertical = YY.s(1.5f)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(YY.s(3)),
    ) {
        if (icon != null) Icon(icon, null, tint = YY.c.t2, modifier = Modifier.size(YY.s(10)))
        Text(text, style = YY.font(10f, FontWeight.Medium), color = YY.c.t2)
    }
}

/** A sheet's own title with × on the right. */
@Composable
fun YYSheetHeader(title: String, subtitle: String? = null, close: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = YY.s(16)).padding(top = YY.s(14), bottom = YY.s(10)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(YY.s(8)),
    ) {
        Text(title, style = YY.font(14f, FontWeight.SemiBold), color = YY.c.t1)
        if (subtitle != null) Text(subtitle, style = YY.font(10f), color = YY.c.t3, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
        Spacer(Modifier.weight(1f))
        Box(
            Modifier.size(YY.s(26)).clip(CircleShape).background(YY.c.inset).clickable(role = androidx.compose.ui.semantics.Role.Button, onClick = close),
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.close, t("关上"), tint = YY.c.t2, modifier = Modifier.size(YY.s(11))) }
    }
}

/** A thin progress bar in the tint. */
@Composable
fun ProgressLine(value: Double, height: Dp = 3.dp, modifier: Modifier = Modifier) {
    // A new value grows to its length instead of jumping there.
    val shown by androidx.compose.animation.core.animateFloatAsState(value.coerceIn(0.0, 1.0).toFloat(), YYMotion.standard(), label = "progress")
    BoxWithConstraints(modifier.fillMaxWidth().height(height).clip(CircleShape).background(YY.c.inset)) {
        Box(Modifier.width(maxWidth * shown).height(height).clip(CircleShape).background(YY.tint.fill))
    }
}

