package app.yuyue.design

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** The palette for the appearance in effect: 浅色, 深色 or 跟随系统 (设置 · 外观). */
val LocalPalette = staticCompositionLocalOf { YYColors.Light }
val LocalDark = staticCompositionLocalOf { false }
val LocalTint = staticCompositionLocalOf { YYTints.Default }

/** The UI colours and the 主题色, as the iPhone's `YYColor` and `YYTint.standard`. */
object YY {
    val c: YYPalette
        @Composable @ReadOnlyComposable get() = LocalPalette.current

    val tint: YYTintColors
        @Composable @ReadOnlyComposable get() = if (LocalDark.current) LocalTint.current.dark else LocalTint.current.light

    val dark: Boolean
        @Composable @ReadOnlyComposable get() = LocalDark.current

    /** Sizes are design pixels; points are those times 1.2 (as on iPhone). */
    const val K = 1.2f

    fun s(px: Float): Dp = (px * K).dp
    fun s(px: Int): Dp = (px * K).dp
    fun sp(px: Float): TextUnit = (px * K).sp

    /** Type: `YYUI.font(px, weight)`. */
    fun font(px: Float, weight: FontWeight = FontWeight.Normal, family: FontFamily = FontFamily.Default): TextStyle =
        TextStyle(fontSize = sp(px), fontWeight = weight, fontFamily = family)

    /** `--serif`: Songti on Apple; Noto Serif CJK where the phone has it. */
    val serif: FontFamily = FontFamily.Serif
}

object Appearance {
    const val KEY = "appearance.mode"
    const val SYSTEM = "system"
    const val LIGHT = "light"
    const val DARK = "dark"
}

@Composable
fun YuyueTheme(content: @Composable () -> Unit) {
    val mode = rememberPref(Appearance.KEY, Appearance.SYSTEM)
    val tintID = rememberPref("appearance.tint", YYTints.Default.id)
    val dark = when (mode.value) {
        Appearance.LIGHT -> false
        Appearance.DARK -> true
        else -> isSystemInDarkTheme()
    }
    CompositionLocalProvider(
        LocalPalette provides if (dark) YYColors.Dark else YYColors.Light,
        LocalDark provides dark,
        LocalTint provides (YYTints.All.firstOrNull { it.id == tintID.value } ?: YYTints.Default),
        content = content,
    )
}

/** The app's settings, like the iPhone's UserDefaults. */
object Prefs {
    private lateinit var prefs: SharedPreferences

    fun init(context: Context) {
        prefs = context.getSharedPreferences("yuyue", Context.MODE_PRIVATE)
    }

    val shared: SharedPreferences get() = prefs

    fun string(key: String, default: String = ""): String = prefs.getString(key, default) ?: default
    fun bool(key: String, default: Boolean): Boolean = prefs.getBoolean(key, default)
    fun float(key: String, default: Float): Float = prefs.getFloat(key, default)
    fun int(key: String, default: Int): Int = prefs.getInt(key, default)
    fun set(key: String, value: Any?) {
        prefs.edit().apply {
            when (value) {
                null -> remove(key)
                is String -> putString(key, value)
                is Boolean -> putBoolean(key, value)
                is Float -> putFloat(key, value)
                is Double -> putFloat(key, value.toFloat())
                is Int -> putInt(key, value)
                is Long -> putLong(key, value)
            }
        }.apply()
    }
}

/** A setting as Compose state that writes through, like `@AppStorage`. */
@Composable
fun <T> rememberPref(key: String, default: T): MutableState<T> {
    @Suppress("UNCHECKED_CAST")
    fun read(): T = when (default) {
        is String -> Prefs.string(key, default)
        is Boolean -> Prefs.bool(key, default)
        is Float -> Prefs.float(key, default)
        is Int -> Prefs.int(key, default)
        else -> default
    } as T

    val state = remember(key) {
        object : MutableState<T> {
            val inner = mutableStateOf(read())
            override var value: T
                get() = inner.value
                set(v) {
                    inner.value = v
                    Prefs.set(key, v)
                }
            override fun component1() = value
            override fun component2(): (T) -> Unit = { value = it }
        }
    }
    DisposableEffect(key) {
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, k -> if (k == key) state.inner.value = read() }
        Prefs.shared.registerOnSharedPreferenceChangeListener(listener)
        onDispose { Prefs.shared.unregisterOnSharedPreferenceChangeListener(listener) }
    }
    return state
}

fun Color.alpha(a: Float) = copy(alpha = a)

