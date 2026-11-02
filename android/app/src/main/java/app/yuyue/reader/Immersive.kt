package app.yuyue.reader

import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import android.app.AutomaticZenRule
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.service.notification.Condition
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.yuyue.MainActivity
import app.yuyue.design.ButtonKind
import app.yuyue.design.ButtonSize
import app.yuyue.design.Icons
import app.yuyue.design.Prefs
import app.yuyue.design.YY
import app.yuyue.design.YYButton
import app.yuyue.design.YYGroup
import app.yuyue.design.YYNote
import app.yuyue.design.YYPage
import app.yuyue.design.YYPapers
import app.yuyue.design.YYRow
import app.yuyue.design.rememberPref
import app.yuyue.t
import uniffi.yuyue_core.Paper
import uniffi.yuyue_core.YuyueCore

/** 沉浸阅读's settings, as on Apple. */
object ImmersivePrefs {
    const val LINE = "immersive.line"
    const val MARKS = "immersive.hideMarks"
    const val STILL = "immersive.stillPages"
    const val STATUS = "immersive.hideStatus"
    const val PROGRESS = "immersive.hideProgress"
    const val QUIET = "immersive.quiet"
    const val HINTS = "immersive.hideHints"
    const val ALWAYS = "immersive.always"

    val keepsLine get() = Prefs.bool(LINE, true)
    /** Off at first (prototype 沉浸设置): a highlight is the reader's own and stays unless asked. */
    val hidesMarks get() = Prefs.bool(MARKS, false)
    val stillPages get() = Prefs.bool(STILL, true)
    val hidesStatusBar get() = Prefs.bool(STATUS, true)
    val hidesProgress get() = Prefs.bool(PROGRESS, true)
    val quiet get() = Prefs.bool(QUIET, true)
    /** 关掉书伴提示和难词注释, on at first as on Apple. */
    val hidesHints get() = Prefs.bool(HINTS, true)
    val always get() = Prefs.bool(ALWAYS, false)
}

/**
 * 读书时通知不打扰 (prototype: 打开沉浸阅读时，语阅顺手打开勿扰，快捷开关上写着"由语阅打开"；离开书页
 * 就关掉，你自己开的勿扰不会被动). An automatic rule of the app's own, so the system shows it as
 * turned on by 语阅, and turning it off never ends a Do Not Disturb the reader turned on.
 */
object DoNotDisturb {
    private val condition = Uri.parse("condition://app.yuyue/reading")
    private const val RULE = "dnd.rule"

    fun allowed(context: Context): Boolean = Build.VERSION.SDK_INT >= 29 && manager(context).isNotificationPolicyAccessGranted

    /** The system page where 语阅 is let in. */
    fun ask(context: Context) {
        runCatching { context.startActivity(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
    }

    fun set(context: Context, on: Boolean) {
        if (Build.VERSION.SDK_INT < 29 || !allowed(context)) return
        val nm = manager(context)
        val id = Prefs.string(RULE).takeIf { it.isNotEmpty() && nm.getAutomaticZenRule(it) != null } ?: run {
            if (!on) return
            val rule = AutomaticZenRule(
                t("语阅 · 沉浸阅读"), null, ComponentName(context, MainActivity::class.java), condition, null,
                NotificationManager.INTERRUPTION_FILTER_PRIORITY, true,
            )
            nm.addAutomaticZenRule(rule).also { Prefs.set(RULE, it) }
        }
        runCatching { nm.setAutomaticZenRuleState(id, Condition(condition, t("读书时不打扰"), if (on) Condition.STATE_TRUE else Condition.STATE_FALSE)) }
    }

    private fun manager(context: Context) = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
}

/** 墨水屏模式, as on Apple: the e-ink paper and no motion. On a phone with an e-ink screen it is
 *  turned on by itself the first time 语阅 opens. */
object EInk {
    const val KEY = "eink.on"
    private const val PREVIOUS = "eink.previous"
    private const val PREVIOUS_CUSTOM = "eink.previousCustom"
    private const val CHECKED = "eink.checked"

    val on get() = Prefs.bool(KEY, false)

    fun set(on: Boolean, core: YuyueCore) {
        val shared = runCatching { core.readerSettings() }.getOrNull() ?: return
        val paper = if (on) {
            if (shared.paper != Paper.EINK) {
                Prefs.set(PREVIOUS, shared.paper.name)
                Prefs.set(PREVIOUS_CUSTOM, shared.customPaper ?: "")
            }
            Paper.EINK
        } else {
            Paper.entries.firstOrNull { it.name == Prefs.string(PREVIOUS) } ?: Paper.PLAIN
        }
        val custom = if (on) null else Prefs.string(PREVIOUS_CUSTOM)?.takeIf { it.isNotEmpty() }
        Prefs.set(KEY, on)
        runCatching { core.setReaderSettings(shared.copy(paper = paper, customPaper = custom)) }
    }

    /** The makers whose phones and readers have e-ink screens. */
    private val makers = listOf("onyx", "boox", "boyue", "likebook", "meebook", "bigme", "pocketbook", "ireader", "hisense a", "kobo", "dasung", "moaan", "mooink", "inkpalm")

    fun checkDevice(core: YuyueCore) {
        if (Prefs.bool(CHECKED, false)) return
        Prefs.set(CHECKED, true)
        val name = "${Build.MANUFACTURER} ${Build.BRAND} ${Build.MODEL}".lowercase()
        if (makers.any { it in name }) set(true, core)
    }
}

/** 沉浸阅读 (prototype 沉浸设置): one switch, and what goes with it, each to keep if wanted. From
 *  a book it turns it on there; from 我的 it is for every book. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ImmersiveSheet(model: ReaderModel?, dismiss: () -> Unit) {
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 24.dp)) { ImmersiveSettings(model) }
    }
}

@Composable
fun ImmersiveSettings(model: ReaderModel?) {
    val context = LocalContext.current
    var always by rememberPref(ImmersivePrefs.ALWAYS, false)
    var status by rememberPref(ImmersivePrefs.STATUS, true)
    var progress by rememberPref(ImmersivePrefs.PROGRESS, true)
    var quiet by rememberPref(ImmersivePrefs.QUIET, true)
    var still by rememberPref(ImmersivePrefs.STILL, true)
    var marks by rememberPref(ImmersivePrefs.MARKS, false)
    var hints by rememberPref(ImmersivePrefs.HINTS, true)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(t("沉浸阅读"), style = YY.font(13f, FontWeight.SemiBold), color = YY.c.t1, modifier = Modifier.weight(1f))
        Switch(
            model?.immersive ?: always,
            { on -> if (model != null) { model.chromeShown = false; model.immersive = on } else always = on },
            modifier = Modifier.semantics { contentDescription = t("沉浸阅读") },
            colors = SwitchDefaults.colors(checkedTrackColor = YY.tint.fill, checkedThumbColor = YY.c.card, uncheckedTrackColor = YY.c.inset, uncheckedBorderColor = YY.c.line),
        )
    }
    Text(
        if (model == null) t("打开后每本书一打开就只留下字。下面这些会一起关掉，也可以逐项留下。") else t("打开后读书时只留下字。下面这些会一起关掉，也可以逐项留下。"),
        style = YY.font(10f), color = YY.c.t3, modifier = Modifier.padding(top = 6.dp, bottom = 12.dp),
    )
    YYGroup {
        row { SwitchRow(t("隐藏状态栏、时间和电量"), status) { status = it } }
        row { SwitchRow(t("隐藏进度、页码和剩余时间"), progress) { progress = it } }
        row { SwitchRow(t("读书时通知不打扰"), quiet) { quiet = it } }
        row { SwitchRow(t("关掉翻页动画"), still) { still = it; model?.applyImmersive() } }
        row { SwitchRow(t("隐藏划线和想法"), marks) { marks = it; model?.applyImmersive() } }
        row { SwitchRow(t("关掉书伴提示和难词注释"), hints) { hints = it; model?.applyImmersive() } }
    }
    if (quiet && !DoNotDisturb.allowed(context)) {
        YYNote(t("要让语阅读书时打开勿扰，先在系统里允许它管理勿扰。"))
        Spacer(Modifier.height(8.dp))
        YYButton(t("去允许"), ButtonKind.Raised, ButtonSize.Small) { DoNotDisturb.ask(context) }
    } else if (quiet) {
        YYNote(t("读书时语阅打开勿扰，离开书页就关掉；你自己开的勿扰不会被动。"))
    }
}

/** 我的 › 墨水屏: one switch, a piece of the page as it will look, and what changes with it. */
@Composable
fun EInkPage(core: YuyueCore) {
    var on by rememberPref(EInk.KEY, false)
    val paper = YYPapers.Eink
    YYPage {
        Spacer(Modifier.height(YY.s(10)))
        YYGroup {
            row {
                YYRow(t("墨水屏模式"), Icons.book, trailing = {
                    Switch(on, { EInk.set(it, core); on = it }, modifier = Modifier.semantics { contentDescription = t("墨水屏模式") }, colors = SwitchDefaults.colors(checkedTrackColor = YY.tint.fill, checkedThumbColor = YY.c.card, uncheckedTrackColor = YY.c.inset, uncheckedBorderColor = YY.c.line))
                })
            }
        }
        Column(Modifier.padding(top = YY.s(14)).fillMaxWidth().background(paper.bg, RoundedCornerShape(YY.s(12))).padding(YY.s(18)), verticalArrangement = Arrangement.spacedBy(YY.s(8))) {
            Text(t("背影"), style = YY.font(18f, FontWeight.SemiBold, YY.serif), color = paper.ink)
            Text(
                t("父亲说：“事已如此，不必难过，") + t("好在天无绝人之路！") + "”" + t("回家变卖典质，父亲还了亏空；") + t("又借钱办了丧事。"),
                style = YY.font(13.5f, family = YY.serif).copy(lineHeight = YY.sp(28f)), color = paper.ink,
            )
        }
        YYNote(t("纸色换成墨水屏那种带颗粒的浅灰，字是纯黑；划线变成黑色的实线、波浪线；封面、插图转成灰度；没有任何动画，翻页是整页直接切换，界面也不再有阴影和毛玻璃。关掉后回到原来的纸色。"))
    }
}
