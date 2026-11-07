package app.yuyue.companion

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
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
import app.yuyue.design.YYSheetHeader
import app.yuyue.me.Secret
import app.yuyue.shelf.Field
import app.yuyue.t
import kotlinx.coroutines.launch

/** 书伴 settings, as on iPhone's 引擎 · 书伴: the service is a menu (those
 *  added, then 配置… and 添加服务商…), the model its own row with the ones the service lists, then
 *  测试一下; 管理服务商 lists what was added. */
@Composable
fun CompanionSettings() {
    // Bumped when something changes, to read it again.
    var version by remember { mutableIntStateOf(0) }
    var sheet by remember { mutableStateOf<SheetStart?>(null) }
    val added = remember(version) { CompanionProvider.added }
    val current = remember(version) { CompanionConfig.current }
    var model by remember(version) { mutableStateOf(current?.model ?: "") }
    var models by remember { mutableStateOf<List<String>>(emptyList()) }
    var listing by remember { mutableStateOf(false) }
    var testing by remember { mutableStateOf(false) }
    var outcome by remember(version) { mutableStateOf<Pair<Boolean, String>?>(null) }
    var picking by remember { mutableStateOf(false) }
    var choosingModel by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    fun setModel(m: String) {
        model = m.trim()
        current?.copy(model = model)?.save()
        outcome = null
    }
    LaunchedEffect(current?.provider?.id, version) {
        models = emptyList()
        val c = current ?: return@LaunchedEffect
        if (!c.isConnected) return@LaunchedEffect
        listing = true
        val found = runCatching { Companion.models(c) }.getOrDefault(emptyList()).sorted()
        listing = false
        models = found
        if (model.isEmpty() && found.isNotEmpty()) setModel(found.first())
    }

    Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 28.dp)) {
        YYLabel(t("书伴"))
        YYGroup {
            row {
                Row(Modifier.fillMaxWidth().padding(vertical = YY.s(6)), verticalAlignment = Alignment.CenterVertically) {
                    Text(t("服务商"), style = YY.font(11.5f), color = YY.c.t1, modifier = Modifier.weight(1f))
                    Box {
                        Row(Modifier.clickable { picking = true }.padding(vertical = YY.s(4)), verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(YY.s(6))) {
                            if (current == null) Text(t("添加服务商…"), style = YY.font(11.5f), color = YY.tint.accent)
                            else {
                                ProviderLogo(current.provider, 18.dp)
                                Text(current.provider.title, style = YY.font(11.5f), color = YY.c.t1)
                            }
                            Icon(Icons.chevronDown, null, tint = YY.c.t3, modifier = Modifier.size(YY.s(14)))
                        }
                        DropdownMenu(picking, { picking = false }, containerColor = YY.c.card) {
                            for (p in added) DropdownMenuItem(
                                text = { Text(p.title, style = YY.font(11.5f), color = YY.c.t1) },
                                leadingIcon = { ProviderLogo(p, 20.dp) },
                                trailingIcon = { if (current?.provider == p) Icon(Icons.check, null, tint = YY.tint.accent, modifier = Modifier.size(YY.s(13))) },
                                onClick = { picking = false; CompanionConfig.saved(p).choose(); version++ },
                            )
                            if (added.isNotEmpty()) HorizontalDivider(color = YY.c.line)
                            if (current != null) DropdownMenuItem(
                                text = { Text(t("配置 %@…", current.provider.title), style = YY.font(11.5f), color = YY.c.t2) },
                                leadingIcon = { Icon(Icons.edit, null, tint = YY.c.t3, modifier = Modifier.size(YY.s(15))) },
                                onClick = { picking = false; sheet = SheetStart.Edit(current.provider) },
                            )
                            DropdownMenuItem(
                                text = { Text(t("添加服务商…"), style = YY.font(11.5f), color = YY.c.t2) },
                                leadingIcon = { Icon(Icons.add, null, tint = YY.c.t3, modifier = Modifier.size(YY.s(15))) },
                                onClick = { picking = false; sheet = SheetStart.Add },
                            )
                        }
                    }
                }
            }
            if (current != null) row {
                YYField(t("模型"), 70f) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.weight(1f)) { Field(model, current.provider.modelHint) { setModel(it) } }
                        Box {
                            Text(if (listing) "…" else t("选"), style = YY.font(10.5f), color = if (models.isEmpty()) YY.c.t3 else YY.tint.accent,
                                modifier = Modifier.clickable(enabled = models.isNotEmpty()) { choosingModel = true }.padding(start = YY.s(10), top = YY.s(6), bottom = YY.s(6)))
                            DropdownMenu(choosingModel, { choosingModel = false }, containerColor = YY.c.card) {
                                for (m in models) DropdownMenuItem(text = { Text(m, style = YY.font(11f), color = YY.c.t1) }, onClick = { choosingModel = false; setModel(m) })
                            }
                        }
                    }
                }
            }
            row {
                YYRow(t("测试一下"), value = outcome?.second ?: if (current != null && model.isEmpty()) t("还没选好模型") else null, trailing = {
                    YYButton(if (testing) "…" else t("测试"), ButtonKind.Plain, ButtonSize.Small, enabled = !testing && current?.copy(model = model)?.isReady == true) {
                        val c = current?.copy(model = model) ?: return@YYButton
                        testing = true
                        outcome = null
                        val started = System.currentTimeMillis()
                        scope.launch {
                            outcome = try {
                                Companion.answer(c, "用一句话回答。", "你好")
                                true to t("能用 · %@ 秒回答", "%.1f".format((System.currentTimeMillis() - started) / 1000.0))
                            } catch (e: Exception) {
                                false to Companion.message(e)
                            }
                            testing = false
                        }
                    }
                })
            }
            row { YYRow(t("管理服务商"), chevron = true, onClick = { sheet = SheetStart.Manage }) }
        }
        YYNote(t("Key 只存在这台设备上，加密保存，不同步。提问和书里相关的几段原文直接发给你选的服务商，语阅不经手。"))
    }
    sheet?.let { start ->
        ProviderSheet(start) {
            sheet = null
            version++
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

private sealed interface SheetStart {
    data object Add : SheetStart
    data object Manage : SheetStart
    data class Edit(val provider: CompanionProvider) : SheetStart
}

/** A service's logo, bare; the reader's own get their first letter on a small grey disc. */
@Composable
fun ProviderLogo(p: CompanionProvider, size: Dp = 18.dp) {
    val logo = p.logo
    if (logo != null) Icon(painterResource(logo), null, tint = if (p.logoTinted) YY.c.t1 else Color.Unspecified, modifier = Modifier.size(size))
    else Box(Modifier.size(size).background(YY.c.inset, CircleShape), contentAlignment = Alignment.Center) {
        Text(p.title.take(1).uppercase(), style = YY.font(size.value * 0.55f, FontWeight.SemiBold), color = YY.c.t2)
    }
}

/** 添加服务商, 管理服务商 and one service's form, in one sheet. 添加 is a picker: what's on
 *  offer, searchable, grouped by how it's reached, with one of your own at the bottom. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ProviderSheet(start: SheetStart, close: () -> Unit) {
    var adding by remember { mutableStateOf(start == SheetStart.Add) }
    var picked by remember { mutableStateOf((start as? SheetStart.Edit)?.provider) }
    var version by remember { mutableIntStateOf(0) }
    // After 添加, 保存 or 移除: back to 管理服务商 when that's where it started.
    val done: () -> Unit = { if (start == SheetStart.Manage) { picked = null; adding = false; version++ } else close() }
    ModalBottomSheet(close, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 28.dp)) {
            val p = picked
            when {
                p != null -> ProviderForm(p, adding, back = if (start is SheetStart.Edit) null else ({ picked = null }), close = close, done = done)
                adding -> Picker(back = if (start == SheetStart.Manage) ({ adding = false }) else null, close = close) { picked = it }
                else -> Manage(version, close, add = { adding = true }) { picked = it }
            }
        }
    }
}

@Composable
private fun Title(title: String, back: (() -> Unit)?, close: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (back != null) Box(Modifier.size(YY.s(28)).clickable(onClick = back), contentAlignment = Alignment.Center) {
            Icon(Icons.chevronLeft, t("返回"), tint = YY.c.t2, modifier = Modifier.size(YY.s(18)))
        }
        Box(Modifier.weight(1f)) { YYSheetHeader(title, t("书伴"), close) }
    }
}

@Composable
private fun Picker(back: (() -> Unit)?, close: () -> Unit, pick: (CompanionProvider) -> Unit) {
    var query by remember { mutableStateOf("") }
    val matches = CompanionProvider.available(query)
    Title(t("添加服务商"), back, close)
    Spacer(Modifier.height(YY.s(12)))
    Row(Modifier.fillMaxWidth().height(YY.s(34)).background(YY.c.inset, RoundedCornerShape(YY.s(10))).padding(horizontal = YY.s(10)),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(6))) {
        Icon(Icons.search, null, tint = YY.c.t3, modifier = Modifier.size(YY.s(14)))
        Box(Modifier.weight(1f)) { Field(query, t("搜索服务商，比如 千问、Kimi、magpie")) { query = it } }
    }
    for (group in CompanionProvider.Group.entries) {
        val list = matches.filter { it.group == group }
        if (list.isEmpty()) continue
        Text(group.title, style = YY.font(10f, FontWeight.SemiBold), color = YY.c.t3, modifier = Modifier.padding(start = YY.s(8), top = YY.s(12), bottom = YY.s(2)))
        Column(verticalArrangement = Arrangement.spacedBy(YY.s(2))) {
            for (pair in list.chunked(2)) Row(horizontalArrangement = Arrangement.spacedBy(YY.s(2))) {
                for (p in pair) Tile(p, Modifier.weight(1f)) { pick(p) }
                if (pair.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
    if (matches.isEmpty()) Text(t("没找到。在下面自己添加，填上接口地址就行"), style = YY.font(11f), color = YY.c.t3,
        modifier = Modifier.fillMaxWidth().padding(vertical = YY.s(36)), textAlign = TextAlign.Center)
    Spacer(Modifier.height(YY.s(14)))
    YYGroup {
        row {
            Row(Modifier.fillMaxWidth().clickable { pick(CompanionProvider.custom("")) }.padding(vertical = YY.s(8)),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(10))) {
                Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) { Icon(Icons.add, null, tint = YY.c.t2, modifier = Modifier.size(YY.s(16))) }
                Column(Modifier.weight(1f)) {
                    Text(t("自己添加"), style = YY.font(11.5f), color = YY.c.t1)
                    Text(t("任何 OpenAI 兼容接口，比如公司里部署的模型"), style = YY.font(10f), color = YY.c.t3)
                }
                Icon(Icons.chevronRight, null, tint = YY.c.t3, modifier = Modifier.size(YY.s(11)))
            }
        }
    }
}

@Composable
private fun Tile(p: CompanionProvider, modifier: Modifier, onClick: () -> Unit) {
    Row(modifier.height(YY.s(36)).clip(RoundedCornerShape(YY.s(8))).clickable(onClick = onClick).padding(horizontal = YY.s(8)),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(8))) {
        ProviderLogo(p)
        Text(p.title, style = YY.font(11.5f), color = YY.c.t1, maxLines = 1)
    }
}

@Composable
private fun Wide(p: CompanionProvider, detail: String, trailing: String? = null, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = YY.s(8)),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(10))) {
        ProviderLogo(p)
        Column(Modifier.weight(1f)) {
            Text(p.title, style = YY.font(11.5f), color = YY.c.t1)
            Text(detail, style = YY.font(10f), color = YY.c.t3, maxLines = 1)
        }
        if (trailing != null) Text(trailing, style = YY.font(10.5f), color = YY.c.t2)
        else Icon(Icons.chevronRight, null, tint = YY.c.t3, modifier = Modifier.size(YY.s(11)))
    }
}

@Composable
private fun Manage(version: Int, close: () -> Unit, add: () -> Unit, open: (CompanionProvider) -> Unit) {
    val added = remember(version) { CompanionProvider.added }
    Title(t("管理服务商"), null, close)
    Spacer(Modifier.height(YY.s(12)))
    if (added.isEmpty()) Text(t("还没添加服务商"), style = YY.font(11f), color = YY.c.t3,
        modifier = Modifier.fillMaxWidth().padding(vertical = YY.s(30)), textAlign = TextAlign.Center)
    else YYGroup {
        for (p in added) row {
            val saved = CompanionConfig.saved(p)
            Wide(p, if (saved.key.isEmpty()) saved.url.ifEmpty { p.urlHint } else saved.maskedKey, trailing = t("配置")) { open(p) }
        }
    }
    Spacer(Modifier.height(YY.s(14)))
    YYButton(t("添加服务商"), ButtonKind.Raised, ButtonSize.Large, wide = true, icon = Icons.add, onClick = add)
}

/** One service's key and address (the model is chosen in 设置 · 书伴).
 *  A key saved before shows as "sk-…3f9a" with 更换, so opening the form never wipes it.
 *  OpenRouter signs in instead; a key can still be pasted. */
@Composable
private fun ProviderForm(provider: CompanionProvider, adding: Boolean, back: (() -> Unit)?, close: () -> Unit, done: () -> Unit) {
    var config by remember(provider.id) { mutableStateOf(CompanionConfig.saved(provider)) }
    var name by remember(provider.id) { mutableStateOf(provider.title) }
    var keyLocked by remember(provider.id) { mutableStateOf(config.key.isNotEmpty()) }
    var showKey by remember { mutableStateOf(false) }
    var signingIn by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf<String?>(null) }
    var removing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val draft = config.copy(provider = if (provider.isCustom) CompanionProvider.custom(name.trim(), provider.id) else provider)
    fun save(c: CompanionConfig = draft) {
        if (!c.isConnected) return
        // A service just added answers from now on; editing one leaves the choice alone.
        if (adding) c.choose() else c.save()
        done()
    }
    val note = when {
        provider.local -> t("本机或局域网里跑的，提问和书里相关的几段原文只发到这个地址。")
        provider.isCustom -> t("提问和书里相关的几段原文直接发到这个地址，语阅不经手。")
        else -> t("Key 只存在这台设备上，加密保存。费用走你自己的 %@ 账号，语阅不经手，也看不到。", provider.account)
    }

    Title(if (provider.isCustom && adding) t("自己添加") else provider.title, back, close)
    Spacer(Modifier.height(YY.s(12)))
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(10))) {
        ProviderLogo(draft.provider, 22.dp)
        Column(Modifier.weight(1f)) {
            Text(if (provider.isCustom) t("OpenAI 兼容接口") else provider.group.title, style = YY.font(10.5f, FontWeight.Medium), color = YY.c.t2)
            Text(provider.blurb ?: note, style = YY.font(10f), color = YY.c.t3)
        }
    }
    Spacer(Modifier.height(YY.s(12)))
    if (provider.group == CompanionProvider.Group.SignIn && !keyLocked) {
        YYButton(if (signingIn) "…" else t("用 %@ 登录", provider.title), ButtonKind.Main, ButtonSize.Large, wide = true, enabled = !signingIn) {
            signingIn = true
            failed = null
            scope.launch {
                try {
                    val key = OpenRouterSignIn.run(context)
                    config = config.copy(key = key)
                    keyLocked = true
                    save(draft.copy(key = key))
                } catch (e: Exception) {
                    failed = Companion.message(e)
                }
                signingIn = false
            }
        }
        Text(t("或者粘贴一个已有的 Key"), style = YY.font(10f), color = YY.c.t3, modifier = Modifier.padding(start = YY.s(4), top = YY.s(10), bottom = YY.s(6)))
    }
    YYGroup {
        if (provider.isCustom) row { YYField(t("名称"), 70f) { Field(name, t("比如 公司的模型")) { name = it } } }
        row {
            YYField("API Key", 70f) {
                if (keyLocked) Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(config.maskedKey, style = YY.font(11.5f), color = YY.c.t2, modifier = Modifier.weight(1f))
                    YYButton(t("更换"), ButtonKind.Plain, ButtonSize.Small) { config = config.copy(key = ""); keyLocked = false }
                } else Row(verticalAlignment = Alignment.CenterVertically) {
                    val hint = if (provider.needsKey || provider.keyHint != "sk-…") provider.keyHint else t("可不填")
                    Box(Modifier.weight(1f)) {
                        if (showKey) Field(config.key, hint) { config = config.copy(key = it.trim()) }
                        else Secret(config.key, hint) { config = config.copy(key = it.trim()) }
                    }
                    Text(if (showKey) t("藏起 Key") else t("显示 Key"), style = YY.font(10.5f), color = YY.c.t3,
                        modifier = Modifier.clickable { showKey = !showKey }.padding(start = YY.s(8)))
                }
            }
        }
        row { YYField(t("接口地址"), 70f) { Field(config.url, provider.urlHint) { config = config.copy(url = it.trim()) } } }
    }
    failed?.let { YYNote(it, YY.c.danger) }
    if (provider.blurb != null) YYNote(note)
    Spacer(Modifier.height(16.dp))
    YYButton(if (adding) t("添加") else t("保存"), ButtonKind.Main, ButtonSize.Large, wide = true, enabled = draft.isConnected) { save() }
    if (!adding) {
        Spacer(Modifier.height(10.dp))
        YYButton(t("移除"), ButtonKind.Danger, ButtonSize.Large, wide = true) { removing = true }
    }
    if (removing) AlertDialog(
        onDismissRequest = { removing = false },
        title = { Text(t("移除 %@？", provider.title)) },
        text = { Text(t("它的 Key 也会从这台设备上删掉。")) },
        confirmButton = { TextButton({ CompanionConfig.remove(provider); removing = false; done() }) { Text(t("移除"), color = YY.c.danger) } },
        dismissButton = { TextButton({ removing = false }) { Text(t("取消")) } },
    )
}
