package app.yuyue.reader

import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import app.yuyue.design.ButtonKind
import app.yuyue.design.ButtonSize
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYButton
import app.yuyue.design.YYField
import app.yuyue.design.YYGroup
import app.yuyue.design.YYNote
import app.yuyue.design.YYRow
import app.yuyue.design.YYSegments
import app.yuyue.design.YYTag
import app.yuyue.shelf.Field
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import uniffi.yuyue_core.ReplaceRule
import uniffi.yuyue_core.RulePreview
import uniffi.yuyue_core.YuyueCore

/** 替换规则 (prototype), as on Apple: what this book's words are changed into — on the page and
 *  in the voice, or only in the voice. Rules for this book, or for every book; each can be
 *  turned off, changed, or taken away; common ones can be picked from a list. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReplaceRulesSheet(core: YuyueCore, bookID: String, changed: () -> Unit, dismiss: () -> Unit) {
    var forBook by remember { mutableStateOf(true) }
    var version by remember { mutableIntStateOf(0) }
    var editing by remember { mutableStateOf<ReplaceRule?>(null) }
    var picking by remember { mutableStateOf(false) }
    val rules = remember(forBook, version) {
        runCatching { core.replaceRules(bookID) }.getOrDefault(emptyList()).filter { (it.book != null) == forBook }.sortedBy { it.order }
    }
    fun touched() { version++; changed() }
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 28.dp)) {
            Text(t("替换规则"), style = YY.font(14f, FontWeight.Bold), color = YY.c.t1, modifier = Modifier.padding(start = 4.dp, bottom = 10.dp))
            YYSegments(listOf(true to t("这本书"), false to t("全部书")), forBook, { forBook = it }, modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(12.dp))
            YYGroup {
                if (rules.isEmpty()) row { YYRow(if (forBook) t("这本书还没有自己的规则") else t("还没有用于全部书的规则"), titleColor = YY.c.t3) }
                for (r in rules) row {
                    Row(Modifier.fillMaxWidth().clickable { editing = r }.padding(vertical = YY.s(9)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(8))) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(
                                buildAnnotatedString {
                                    append(r.find)
                                    withStyle(SpanStyle(color = YY.c.t3)) { append("  →  ") }
                                    if (r.replace.isEmpty()) withStyle(SpanStyle(color = YY.c.t3, textDecoration = TextDecoration.None)) { append(t("删掉")) } else append(r.replace)
                                },
                                style = YY.font(11.5f), color = if (r.enabled) YY.c.t1 else YY.c.t3, maxLines = 2,
                            )
                            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                if (r.regex) YYTag(t("正则"))
                                if (r.speechOnly) YYTag(t("只改朗读"), Icons.headphones)
                            }
                        }
                        Switch(r.enabled, { on -> runCatching { core.setReplaceRuleEnabled(r.id, on) }; touched() }, modifier = Modifier.semantics { contentDescription = t("启用这条规则") },
                            colors = SwitchDefaults.colors(checkedTrackColor = YY.tint.fill, checkedThumbColor = YY.c.card, uncheckedTrackColor = YY.c.inset, uncheckedBorderColor = YY.c.line))
                    }
                }
                row { YYRow(t("添加一条规则"), Icons.add, chevron = true) { editing = ReplaceRule("", if (forBook) bookID else null, "", "", false, false, true, 0.0) } }
                row { YYRow(t("从常用规则里挑"), Icons.list, t("网址水印、多余空行…"), chevron = true) { picking = true } }
            }
            YYNote(t("规则从上往下依次执行。只改朗读的规则不动屏幕上的字，只改读出来的音。"))
        }
    }
    editing?.let { r -> RuleEditor(core, bookID, r, { editing = null; touched() }) { editing = null } }
    if (picking) CommonRules(core, if (forBook) bookID else null, { touched() }) { picking = false }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RuleEditor(core: YuyueCore, bookID: String, initial: ReplaceRule, saved: () -> Unit, dismiss: () -> Unit) {
    var rule by remember { mutableStateOf(initial) }
    var preview by remember { mutableStateOf<RulePreview?>(null) }
    val isNew = initial.id.isEmpty()
    LaunchedEffect(rule) {
        delay(200)
        preview = if (rule.find.isEmpty()) null else withContext(Dispatchers.IO) { runCatching { core.previewReplaceRule(bookID, rule) }.getOrNull() }
    }
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 28.dp)) {
            Text(if (isNew) t("添加规则") else t("编辑规则"), style = YY.font(14f, FontWeight.Bold), color = YY.c.t1, modifier = Modifier.padding(start = 4.dp, bottom = 10.dp))
            YYGroup {
                row { YYField(t("查找"), 50f) { Field(rule.find, t("要换掉的字")) { rule = rule.copy(find = it) } } }
                row { YYField(t("替换为"), 50f) { Field(rule.replace, t("留空就是删掉")) { rule = rule.copy(replace = it) } } }
            }
            Spacer(Modifier.height(10.dp))
            YYGroup {
                row { SwitchRow(t("正则表达式"), rule.regex) { rule = rule.copy(regex = it) } }
                row {
                    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(t("改哪里"), style = YY.font(11.5f), color = YY.c.t1, modifier = Modifier.weight(1f))
                        YYSegments(listOf(false to t("显示和朗读"), true to t("只改朗读")), rule.speechOnly, { rule = rule.copy(speechOnly = it) }, small = true)
                    }
                }
                row {
                    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(t("用于"), style = YY.font(11.5f), color = YY.c.t1, modifier = Modifier.weight(1f))
                        YYSegments(listOf(true to t("这本书"), false to t("全部书")), rule.book != null, { rule = rule.copy(book = if (it) bookID else null) }, small = true)
                    }
                }
            }
            val p = preview
            Column(Modifier.padding(top = 12.dp).fillMaxWidth().background(YY.c.card, RoundedCornerShape(14.dp)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                when {
                    p?.error != null -> Text(p.error!!, style = YY.font(11f), color = YY.c.danger)
                    p?.first != null -> {
                        val f = p.first!!
                        Text(if (p.count == 0u) t("这本书里没有找到") else t("这本书里有 %u%@ 处", p.count.toInt(), if (p.more) "+" else ""), style = YY.font(11.5f, FontWeight.SemiBold), color = YY.c.t1)
                        Text(t("改前") + "  " + f.lead + f.matched, style = YY.font(11f, family = YY.serif), color = YY.c.t2, maxLines = 2)
                        Text(t("改后") + "  " + f.lead + f.replaced, style = YY.font(11f, family = YY.serif), color = YY.c.t1, maxLines = 2)
                    }
                    else -> Text(if (rule.find.isEmpty()) t("写好要查找的字，这里马上显示改前改后") else t("这本书里没有找到"), style = YY.font(11f), color = YY.c.t3)
                }
            }
            Spacer(Modifier.height(16.dp))
            YYButton(t("保存"), ButtonKind.Main, ButtonSize.Large, wide = true, enabled = rule.find.isNotEmpty() && p?.error == null) {
                runCatching { core.saveReplaceRule(rule) }
                saved()
            }
            if (!isNew) {
                Spacer(Modifier.height(8.dp))
                YYButton(t("删除"), ButtonKind.Danger, ButtonSize.Large, wide = true) {
                    runCatching { core.deleteReplaceRule(rule.id) }
                    saved()
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CommonRules(core: YuyueCore, book: String?, added: () -> Unit, dismiss: () -> Unit) {
    val list = remember { runCatching { core.commonReplaceRules() }.getOrDefault(emptyList()) }
    var done by remember { mutableStateOf(setOf<String>()) }
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 28.dp)) {
            Text(if (book != null) t("加到这本书") else t("加到全部书"), style = YY.font(14f, FontWeight.Bold), color = YY.c.t1, modifier = Modifier.padding(start = 4.dp, bottom = 10.dp))
            YYGroup {
                for (c in list) row {
                    Row(Modifier.fillMaxWidth().padding(vertical = YY.s(9)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Column(Modifier.weight(1f)) {
                            Text(c.title, style = YY.font(11.5f, FontWeight.SemiBold), color = YY.c.t1)
                            Text(c.detail, style = YY.font(10f), color = YY.c.t3)
                        }
                        val on = c.title in done
                        YYButton(if (on) t("已添加") else t("添加"), if (on) ButtonKind.Plain else ButtonKind.Main, ButtonSize.Small, enabled = !on) {
                            runCatching { core.saveReplaceRule(c.rule.copy(book = book)) }
                            done = done + c.title
                            added()
                        }
                    }
                }
            }
            YYNote(t("挑中的规则会加到%@，加完还能改、能关。", if (book != null) t("这本书") else t("全部书")))
        }
    }
}
