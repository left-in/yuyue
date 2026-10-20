package app.yuyue.companion

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.yuyue.design.ButtonKind
import app.yuyue.design.ButtonSize
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYButton
import app.yuyue.design.YYField
import app.yuyue.design.YYGroup
import app.yuyue.design.YYLabel
import app.yuyue.design.YYNote
import app.yuyue.design.YYRow
import app.yuyue.me.Secret
import app.yuyue.shelf.Field
import app.yuyue.t
import kotlinx.coroutines.launch

/** 书伴 settings, as on iPhone's 引擎 · 书伴: which service answers, its key, model and address,
 *  and 测试一下 — a short question that says whether it works and how long it took. */
@Composable
fun CompanionSettings() {
    var provider by remember { mutableStateOf(CompanionConfig.current.provider) }
    var config by remember(provider) { mutableStateOf(CompanionConfig.saved(provider)) }
    var testing by remember { mutableStateOf(false) }
    var outcome by remember { mutableStateOf<Pair<Boolean, String>?>(null) }
    val scope = rememberCoroutineScope()
    Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 28.dp)) {
        YYLabel(t("用哪个"))
        YYGroup {
            for (p in CompanionProvider.entries) row {
                YYRow(p.title, value = p.detail, onClick = { provider = p; outcome = null }, trailing = {
                    if (p == provider) Icon(Icons.check, null, tint = YY.tint.accent, modifier = Modifier.size(YY.s(13)))
                })
            }
        }
        YYLabel(provider.title)
        YYGroup {
            row { YYField(if (provider.needsKey) "API Key" else t("API Key（可不填）"), 70f) { Secret(config.key, provider.keyHint) { config = config.copy(key = it.trim()) } } }
            row { YYField(t("模型"), 70f) { Field(config.model, if (provider == CompanionProvider.OpenAI) t("比如 qwen3:8b") else provider.defaultModel) { config = config.copy(model = it.trim()) } } }
            row { YYField(t("接口地址"), 70f) { Field(config.url, if (provider == CompanionProvider.OpenAI) t("比如 http://192.168.1.5:11434/v1") else t("空着就用官方的")) { config = config.copy(url = it.trim()) } } }
        }
        YYNote(
            outcome?.second ?: t("Key 只存在这台设备上，加密保存，不同步。提问和书里相关的几段原文直接发给你选的服务商，语阅不经手。"),
            if (outcome?.first == false) YY.c.danger else YY.c.t3,
        )
        Spacer(Modifier.height(16.dp))
        YYButton(if (testing) "…" else t("测试一下"), ButtonKind.Plain, ButtonSize.Large, wide = true, enabled = !testing && config.isReady) {
            testing = true
            outcome = null
            val started = System.currentTimeMillis()
            scope.launch {
                outcome = try {
                    Companion.answer(config, "用一句话回答。", "你好")
                    true to t("能用 · %@ 秒回答", "%.1f".format((System.currentTimeMillis() - started) / 1000.0))
                } catch (e: Exception) {
                    false to Companion.message(e)
                }
                testing = false
            }
        }
        Spacer(Modifier.height(10.dp))
        YYButton(t("保存"), ButtonKind.Main, ButtonSize.Large, wide = true, enabled = config.isReady) {
            config.save()
            outcome = true to t("已保存，书伴用 %@", config.label)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CompanionSettingsSheet(dismiss: () -> Unit) {
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.fillMaxWidth()) { CompanionSettings() }
    }
}
