package app.yuyue.companion

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.ClickableText
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.ButtonKind
import app.yuyue.design.ButtonSize
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYButton
import app.yuyue.design.YYSegments
import app.yuyue.reader.ReaderModel
import app.yuyue.t

/** 书伴 on the phone, as on iPhone: the talk in a sheet over the page; a 出处
 *  tag turns the page underneath. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CompanionSheet(model: ReaderModel, settings: () -> Unit, dismiss: () -> Unit) {
    val companion = model.companion
    var draft by remember { mutableStateOf("") }
    val readUpTo = model.bookPage?.let { t("你读到第 %lld 页", it) } ?: t("你读到这里")
    fun send(text: String) {
        val q = text.trim()
        if (q.isEmpty() || companion.busy) return
        companion.ask(q, model.companionQuote)
        draft = ""
        model.companionQuote = null
    }
    ModalBottomSheet({ model.pager.setSource(null); dismiss() }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(0.92f).imePadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(t("书伴"), fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1, modifier = Modifier.weight(1f))
                if (companion.turns.isNotEmpty()) Text(t("清空这次的对话"), fontSize = 13.sp, color = YY.c.t2, modifier = Modifier.clickable { companion.clear() }.padding(8.dp))
                Icon(Icons.settings, t("书伴设置"), tint = YY.c.t2, modifier = Modifier.size(36.dp).clickable(onClick = settings).padding(8.dp))
            }
            Column(Modifier.padding(horizontal = 16.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                YYSegments(listOf(BookCompanion.Scope.Read to t("只用读过的部分"), BookCompanion.Scope.Whole to t("问全书")), companion.scope, { companion.scope = it }, modifier = Modifier.fillMaxWidth())
                Text(if (companion.scope == BookCompanion.Scope.Read) readUpTo + t("，后面的事它不会说") else t("会用到整本书，可能提前知道结尾"), fontSize = 12.sp, color = YY.c.t3)
            }
            val list = rememberLazyListState()
            LaunchedEffect(companion.turns.size, companion.busy) { if (companion.turns.isNotEmpty()) list.animateScrollToItem(companion.turns.size) }
            LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = list, contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                item { if (companion.turns.isEmpty()) Welcome(settings) }
                items(companion.turns, key = { it.id }) { turn ->
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Row { Spacer(Modifier.weight(1f).width(48.dp)); Bubble(turn.question) }
                        Reply(model, turn, readUpTo)
                    }
                }
            }
            Column(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                model.companionQuote?.let { q ->
                    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Box(Modifier.width(1.5.dp).height(36.dp).background(YY.tint.accent))
                        Text(q, fontFamily = YY.serif, fontSize = 13.sp, color = YY.c.t2, maxLines = 2, modifier = Modifier.weight(1f))
                        Icon(Icons.close, t("不带这句"), tint = YY.c.t3, modifier = Modifier.size(20.dp).clickable { model.companionQuote = null })
                    }
                }
                val suggestions = if (model.companionQuote != null) listOf(t("这句是什么意思？"), t("为什么这么写？"))
                else companion.turns.lastOrNull()?.answer?.next ?: listOf(t("前面发生了什么？"), t("这一章讲了什么？"))
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (s in suggestions) {
                        Text(s, fontSize = 13.sp, color = YY.c.t2, modifier = Modifier.height(32.dp).background(YY.c.card, CircleShape).border(0.5.dp, YY.c.line, CircleShape)
                            .clickable(enabled = !companion.busy) { send(s) }.padding(horizontal = 13.dp, vertical = 7.dp))
                    }
                }
                Row(
                    Modifier.fillMaxWidth().background(YY.c.card, RoundedCornerShape(22.dp)).border(0.5.dp, YY.c.line, RoundedCornerShape(22.dp)).padding(start = 16.dp, end = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    BasicTextField(
                        draft, { draft = it }, maxLines = 4, textStyle = TextStyle(fontSize = 16.sp, color = YY.c.t1), cursorBrush = SolidColor(YY.tint.accent),
                        modifier = Modifier.weight(1f).heightIn(min = 44.dp).padding(vertical = 11.dp),
                        decorationBox = { inner -> if (draft.isEmpty()) Text(if (companion.turns.isEmpty()) t("问这本书…") else t("继续问…"), fontSize = 16.sp, color = YY.c.t3); inner() },
                    )
                    val can = draft.isNotBlank() && !companion.busy
                    Box(Modifier.size(34.dp).background(if (can) YY.tint.black else YY.c.inset, CircleShape).clickable(enabled = can) { send(draft) }, contentAlignment = Alignment.Center) {
                        Icon(Icons.forward, t("发送"), tint = if (can) YY.tint.onBlack else YY.c.t3, modifier = Modifier.size(16.dp))
                    }
                }
            }
        }
    }
}

@Composable
private fun Welcome(settings: () -> Unit) {
    val config = CompanionConfig.current
    Column(Modifier.fillMaxWidth().background(YY.c.inset, RoundedCornerShape(16.dp)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(t("读到哪儿问到哪儿"), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
        Text(t("可以问人物关系、这句是什么意思、前面发生了什么。回答标着出处，点一下就翻到那句。"), fontSize = 14.sp, lineHeight = 21.sp, color = YY.c.t2)
        if (config?.isReady != true) {
            Text(if (config == null) t("还没添加服务商") else t("还没填好 %@ 的 Key", config.provider.title), fontSize = 13.sp, color = YY.c.t3)
            YYButton(t("去设置 · 书伴"), ButtonKind.Raised, ButtonSize.Small, onClick = settings)
        }
    }
}

@Composable
private fun Bubble(text: String) {
    Text(
        text, fontSize = 15.sp, lineHeight = 21.sp, color = YY.tint.onBlack,
        modifier = Modifier.background(YY.tint.black, RoundedCornerShape(topStart = 16.dp, bottomStart = 16.dp, bottomEnd = 4.dp, topEnd = 16.dp)).padding(horizontal = 14.dp, vertical = 9.dp),
    )
}

@Composable
private fun Reply(model: ReaderModel, turn: BookCompanion.Turn, readUpTo: String) {
    val companion = model.companion
    val answer = turn.answer
    when {
        answer != null && answer.notYet -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(t("%@，这件事可能要到后面才写。切到“问全书”就能回答，不过会提前知道后面的事。", readUpTo), fontSize = 15.sp, lineHeight = 23.sp, color = YY.c.t1)
            Row(
                Modifier.height(34.dp).background(YY.c.card, CircleShape).border(0.5.dp, YY.c.line, CircleShape).clickable(enabled = !companion.busy) { companion.ask(turn.question, turn.quote, BookCompanion.Scope.Whole) }.padding(horizontal = 14.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(t("用全书回答"), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = YY.c.t1)
                Text(t("可能剧透"), fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = YY.c.warn)
            }
        }
        answer != null -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            val text = cited(answer, companion.shown)
            @Suppress("DEPRECATION")
            ClickableText(text, style = TextStyle(fontSize = 15.sp, lineHeight = 23.sp, color = YY.c.t1)) { offset ->
                text.getStringAnnotations("cite", offset, offset).firstOrNull()?.item?.toIntOrNull()?.let { n -> answer.sources[n]?.let(companion::show) }
            }
            Text(if (turn.scope == BookCompanion.Scope.Whole) answer.label + t(" · 用了全书") else answer.label, fontSize = 11.sp, color = YY.c.t3)
        }
        turn.failed != null -> Text(turn.failed, fontSize = 13.sp, color = YY.c.danger)
        else -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = YY.c.t3)
            Text(t("正在翻书…"), fontSize = 13.sp, color = YY.c.t3)
        }
    }
}

/** The answer with each [n] turned into a little 第 N 页 tag that goes there. */
@Composable
private fun cited(answer: BookCompanion.Answer, shown: BookCompanion.Source?): AnnotatedString {
    val accent = YY.tint.accent
    val soft = YY.tint.accentSoft
    val card = YY.c.card
    return buildAnnotatedString {
        var rest = answer.text
        val re = Regex("""\s?\[(\d+)]""")
        while (true) {
            val m = re.find(rest) ?: break
            append(rest.substring(0, m.range.first))
            val n = m.groupValues[1].toIntOrNull()
            val source = n?.let { answer.sources[it] }
            if (source != null) {
                val place = source.page?.let { t("第 %lld 页", it) } ?: t("出处")
                val label = " " + place + (if (source.later) t(" · 没读到") else "") + " "
                val on = shown == source
                append(" ")
                pushStringAnnotation("cite", "$n")
                withStyle(SpanStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = if (on) card else accent, background = if (on) accent else soft)) { append(label) }
                pop()
            }
            rest = rest.substring(m.range.last + 1)
        }
        append(rest)
    }
}
