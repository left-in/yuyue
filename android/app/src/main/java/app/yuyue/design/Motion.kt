package app.yuyue.design

import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.FastOutLinearInEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.IntOffset

/**
 * 动效, as on Apple: every animation picks one of these.
 * Short, eased out, no bounce. Compose already follows the system's 移除动画 / animator scale, so
 * nothing here checks it.
 */
object YYMotion {
    /** Hover, press, an icon changing, a tick. */
    fun <T> quick(): FiniteAnimationSpec<T> = tween(YYDuration.Quick, easing = FastOutSlowInEasing)

    /** A card or panel coming and going, a colour, a progress line, a number. */
    fun <T> standard(): FiniteAnimationSpec<T> = tween(YYDuration.Standard, easing = FastOutSlowInEasing)

    /** Things moving to a new place: re-sorting, a selection, opening and closing. No bounce. */
    fun <T> layout(): FiniteAnimationSpec<T> = spring(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = 400f)

    /** Going away, a little quicker than coming. */
    fun <T> exit(): FiniteAnimationSpec<T> = tween(YYDuration.Exit, easing = FastOutLinearInEasing)

    /** A layout spring for positions (LazyGrid / LazyColumn `animateItem`). */
    val place: FiniteAnimationSpec<IntOffset> = spring(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = 400f)

    /** A bar or panel showing: fades in and comes a little way from its edge. */
    fun barIn(fromTop: Boolean): EnterTransition =
        fadeIn(standard()) + slideInVertically(standard()) { if (fromTop) -it / 3 else it / 3 }

    fun barOut(toTop: Boolean): ExitTransition =
        fadeOut(exit()) + slideOutVertically(exit()) { if (toTop) -it / 3 else it / 3 }

}

/** Gives a little while pressed (0.98), back as it's let go. Pass the same interaction
 *  source as the clickable. */
@Composable
fun Modifier.pressScale(source: MutableInteractionSource, scale: Float = 0.98f): Modifier {
    val pressed by source.collectIsPressedAsState()
    val s by animateFloatAsState(if (pressed) scale else 1f, if (pressed) tween(80) else YYMotion.quick(), label = "press")
    return graphicsLayer { scaleX = s; scaleY = s }
}
