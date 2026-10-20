package app.yuyue.shelf

import android.graphics.BitmapFactory
import android.text.format.Formatter
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import app.yuyue.design.ButtonKind
import app.yuyue.design.ButtonSize
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYButton
import app.yuyue.design.YYField
import app.yuyue.design.YYGroup
import app.yuyue.design.YYNote
import app.yuyue.design.YYPage
import app.yuyue.design.YYRow
import app.yuyue.design.YYSegments
import app.yuyue.design.yyCard
import app.yuyue.library.Library
import app.yuyue.library.RemoteClient
import app.yuyue.library.RemoteEntry
import app.yuyue.library.RemoteFeed
import app.yuyue.library.RemoteSource
import app.yuyue.me.Secret
import app.yuyue.me.SubPage
import app.yuyue.t
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** 远程书库 from 导入: straight into the one library when there is only one, else the list. */
@Composable
fun RemotePage(library: Library, back: () -> Unit) {
    var open by remember { mutableStateOf<RemoteSource?>(null) }
    val only = library.sources.all.singleOrNull()
    val source = open ?: only
    if (source != null) {
        RemoteBrowser(library, source) { if (open != null && only == null) open = null else back() }
    } else {
        SubPage(t("书库来源"), back) { SourcesList(library) { open = it } }
    }
}

/** 我的 › 书库来源: the list, and a library opened from it. */
@Composable
fun SourcesHome(library: Library, back: () -> Unit) {
    var open by remember { mutableStateOf<RemoteSource?>(null) }
    val o = open
    if (o != null) RemoteBrowser(library, o) { open = null } else SubPage(t("书库来源"), back) { SourcesList(library) { open = it } }
}

/** 书库来源: the libraries filled in, 添加书库, and a long press to change or remove one. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun SourcesList(library: Library, open: (RemoteSource) -> Unit) {
    var editing by remember { mutableStateOf<RemoteSource?>(null) }
    var adding by remember { mutableStateOf(false) }
    var menuFor by remember { mutableStateOf<String?>(null) }
    YYPage {
        Spacer(Modifier.height(YY.s(10)))
        if (library.sources.all.isNotEmpty()) {
            YYGroup {
                for (s in library.sources.all) row {
                    Box {
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = YY.s(44)).combinedClickable(onClick = { open(s) }, onLongClick = { menuFor = s.id }),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(10)),
                        ) {
                            Icon(Icons.server, null, tint = YY.c.t2, modifier = Modifier.size(YY.s(15)))
                            Column(Modifier.weight(1f)) {
                                Text(s.name, style = YY.font(11.5f, FontWeight.SemiBold), color = YY.c.t1, maxLines = 1)
                                Text(s.line, style = YY.font(10f), color = YY.c.t3, maxLines = 1)
                            }
                            Icon(Icons.chevronRight, null, tint = YY.c.t3, modifier = Modifier.size(YY.s(11)))
                        }
                        DropdownMenu(menuFor == s.id, { menuFor = null }, containerColor = YY.c.card) {
                            Item(t("修改"), Icons.edit) { menuFor = null; editing = s }
                            Item(t("删除"), Icons.delete, danger = true) { menuFor = null; library.sources.remove(s) }
                        }
                    }
                }
            }
            Spacer(Modifier.height(YY.s(10)))
        }
        YYGroup { row { YYRow(t("添加书库"), Icons.add, chevron = true) { adding = true } } }
        YYNote(t("Calibre、Kavita、Komga 用 OPDS；坚果云、群晖、NAS 用 WebDAV。一次填好，以后在导入里直接翻。"))
    }
    if (adding || editing != null) SourceForm(library, editing) { adding = false; editing = null }
}

/** 添加书库: the kind, a name, the address and a login; 连接并保存 checks it first. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SourceForm(library: Library, source: RemoteSource?, dismiss: () -> Unit) {
    var kind by remember { mutableStateOf(source?.kind ?: RemoteSource.Kind.OPDS) }
    var name by remember { mutableStateOf(source?.name ?: "") }
    var address by remember { mutableStateOf(source?.url ?: "") }
    var user by remember { mutableStateOf(source?.user ?: "") }
    var password by remember { mutableStateOf(source?.password ?: "") }
    var checking by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 28.dp)) {
            Text(if (source == null) t("添加书库") else t("修改书库"), style = YY.font(14f, FontWeight.Bold), color = YY.c.t1, modifier = Modifier.padding(start = 4.dp, bottom = 10.dp))
            YYSegments(listOf(RemoteSource.Kind.OPDS to "OPDS", RemoteSource.Kind.WEBDAV to "WebDAV"), kind, { kind = it }, modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(12.dp))
            YYGroup {
                row { YYField(t("名称"), 50f) { Field(name, if (kind == RemoteSource.Kind.OPDS) t("家里的 Calibre") else t("坚果云")) { name = it } } }
                row { YYField(t("地址"), 50f) { Field(address, if (kind == RemoteSource.Kind.OPDS) "http://192.168.1.8:8080/opds" else "https://dav.jianguoyun.com/dav/") { address = it } } }
                row { YYField(t("用户名"), 50f) { Field(user, t("没有就空着")) { user = it } } }
                row { YYField(t("密码"), 50f) { Secret(password, if (kind == RemoteSource.Kind.WEBDAV) t("坚果云填应用密码") else t("没有就空着")) { password = it } } }
            }
            YYNote(
                problem ?: if (kind == RemoteSource.Kind.OPDS) t("Calibre：http://电脑地址:8080/opds\nKavita：设置里的 OPDS 地址，带着 API 密钥\nKomga：http://地址:25600/opds/v1.2/catalog")
                else t("填到放书的那个文件夹。坚果云的密码要在网页版“安全选项”里生成应用密码。"),
                if (problem != null) YY.c.danger else YY.c.t3,
            )
            Spacer(Modifier.height(18.dp))
            YYButton(if (checking) "…" else t("连接并保存"), ButtonKind.Main, ButtonSize.Large, wide = true, enabled = !checking && address.isNotBlank()) {
                var text = address.trim()
                if ("://" !in text) text = "http://$text"
                if (kind == RemoteSource.Kind.WEBDAV && !text.endsWith("/")) text += "/"
                val host = runCatching { java.net.URI(text).host }.getOrNull()
                if (host == null) { problem = t("地址不对，像这样：http://192.168.1.8:8080/opds"); return@YYButton }
                val made = (source ?: RemoteSource(name = "", kind = kind, url = text)).copy(kind = kind, url = text, user = user.trim(), name = name.trim().ifEmpty { host })
                checking = true
                problem = null
                scope.launch {
                    try {
                        RemoteClient(made, password).feed()
                        library.sources.save(made, password)
                        dismiss()
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        problem = e.message
                    }
                    checking = false
                }
            }
        }
    }
}

/** 远程书库 (prototype): the catalogue's ways in as chips at the top, then its books — each with a
 *  download button, a ring while it comes, or 在书架. Folders open further in; 返回 comes back out. */
@Composable
fun RemoteBrowser(library: Library, source: RemoteSource, back: () -> Unit) {
    class Level(val url: String?, val title: String)
    val stack = remember(source.id) { mutableStateListOf(Level(null, source.name)) }
    val here = stack.last()
    var feed by remember(source.id, here) { mutableStateOf<RemoteFeed?>(null) }
    var chips by remember(source.id) { mutableStateOf<List<RemoteEntry>>(emptyList()) }
    var chip by remember(source.id) { mutableStateOf<RemoteEntry?>(null) }
    var problem by remember(here) { mutableStateOf<String?>(null) }
    var query by remember { mutableStateOf("") }
    var searching by remember { mutableStateOf(false) }
    var loadingMore by remember { mutableStateOf(false) }
    var reload by remember { mutableStateOf(0) }
    val scope = rememberCoroutineScope()
    val client = remember(source) { RemoteClient(source) }
    fun goBack() = if (stack.size > 1) { stack.removeAt(stack.lastIndex); Unit } else back()
    BackHandler { goBack() }

    LaunchedEffect(here, reload) {
        problem = null
        try {
            val page = client.feed(here.url)
            // At the start, a catalogue of only ways in shows them as chips, the first one open.
            if (here.url == null && page.entries.isNotEmpty() && page.entries.none { it.isBook } && source.kind == RemoteSource.Kind.OPDS) {
                chips = page.entries
                val first = chip?.let { c -> chips.firstOrNull { it.id == c.id } } ?: chips[0]
                chip = first
                val opened = client.feed(first.folder)
                feed = opened.copy(search = opened.search ?: page.search)
            } else {
                feed = page
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            problem = e.message
        }
    }

    SubPage(here.title, { goBack() }) {
        Column(Modifier.fillMaxSize()) {
            if (feed?.search != null || searching) {
                Row(
                    Modifier.padding(horizontal = 16.dp, vertical = 6.dp).fillMaxWidth().height(40.dp).background(YY.c.inset, RoundedCornerShape(12.dp)).padding(horizontal = 10.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Icon(Icons.search, null, tint = YY.c.t3, modifier = Modifier.size(18.dp))
                    BasicTextField(
                        query, { query = it }, singleLine = true, modifier = Modifier.weight(1f),
                        textStyle = YY.font(11.5f).copy(color = YY.c.t1), cursorBrush = SolidColor(YY.tint.accent),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                        keyboardActions = KeyboardActions(onSearch = {
                            val template = feed?.search ?: return@KeyboardActions
                            val words = query.trim().ifEmpty { return@KeyboardActions }
                            searching = true
                            feed = null
                            scope.launch {
                                try {
                                    val found = client.feed(client.search(template, words))
                                    feed = found.copy(search = found.search ?: template)
                                } catch (e: Exception) { problem = e.message }
                            }
                        }),
                        decorationBox = { inner -> if (query.isEmpty()) Text(t("搜书名、作者"), style = YY.font(11.5f), color = YY.c.t3); inner() },
                    )
                    if (searching) Icon(Icons.close, t("清空"), tint = YY.c.t3, modifier = Modifier.size(18.dp).clickable { query = ""; searching = false; reload++ })
                }
            }
            if (chips.size > 1 && stack.size == 1) {
                Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    for (c in chips) {
                        val on = chip?.id == c.id
                        Text(
                            c.title, style = YY.font(10.5f, if (on) FontWeight.SemiBold else FontWeight.Normal), color = if (on) YY.tint.onBlack else YY.c.t2,
                            modifier = Modifier.height(YY.s(28)).background(if (on) YY.tint.black else YY.c.card, CircleShape).border(0.5.dp, if (on) YY.tint.black else YY.c.line, CircleShape)
                                .clickable {
                                    chip = c
                                    feed = null
                                    scope.launch {
                                        try { val o = client.feed(c.folder); if (chip?.id == c.id) feed = o.copy(search = o.search ?: feed?.search) } catch (e: Exception) { problem = e.message }
                                    }
                                }.padding(horizontal = YY.s(11), vertical = YY.s(6)),
                        )
                    }
                }
            }
            val f = feed
            when {
                problem != null -> Column(Modifier.fillMaxWidth().padding(30.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Icon(Icons.error, null, tint = YY.c.t3, modifier = Modifier.size(30.dp))
                    Text(problem ?: "", style = YY.font(11.5f), color = YY.c.t2, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    YYButton(t("再试一次"), ButtonKind.Raised) { reload++ }
                }
                f == null -> Box(Modifier.fillMaxWidth().height(300.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = YY.c.t3) }
                f.entries.isEmpty() -> Text(if (searching) t("没有找到") else t("这里没有书"), style = YY.font(11.5f), color = YY.c.t3, modifier = Modifier.fillMaxWidth().padding(top = 80.dp), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                else -> LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp)) {
                    itemsIndexed(f.entries, key = { _, e -> e.id }) { i, e ->
                        Column(Modifier.fillMaxWidth().background(YY.c.card).padding(horizontal = YY.s(14))) {
                            if (i > 0) Box(Modifier.fillMaxWidth().height(0.5.dp).background(YY.c.line))
                            if (e.isBook) BookRow(library, source, client, e) else FolderRow(e) { stack += Level(e.folder, e.title) }
                        }
                        if (i == f.entries.lastIndex && f.next != null && !loadingMore) LaunchedEffect(f.next) {
                            loadingMore = true
                            runCatching { client.feed(f.next) }.getOrNull()?.let { page ->
                                val known = f.entries.map { it.id }.toSet()
                                feed = f.copy(entries = f.entries + page.entries.filter { it.id !in known }, next = page.next)
                            }
                            loadingMore = false
                        }
                    }
                    if (loadingMore) item { Box(Modifier.fillMaxWidth().padding(10.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = YY.c.t3) } }
                }
            }
        }
    }
}

@Composable
private fun FolderRow(e: RemoteEntry, open: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = open).padding(vertical = YY.s(10)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(10))) {
        Box(Modifier.size(YY.s(28)).background(YY.c.inset, RoundedCornerShape(YY.s(8))), contentAlignment = Alignment.Center) {
            Icon(Icons.folder, null, tint = YY.c.t1, modifier = Modifier.size(YY.s(14)))
        }
        Text(e.title, style = YY.font(11.5f, FontWeight.SemiBold), color = YY.c.t1, maxLines = 1, modifier = Modifier.weight(1f))
        Icon(Icons.chevronRight, null, tint = YY.c.t3, modifier = Modifier.size(YY.s(11)))
    }
}

@Composable
private fun BookRow(library: Library, source: RemoteSource, client: RemoteClient, e: RemoteEntry) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val key = library.sources.key(source, e)
    val fraction = library.sources.downloading[key]
    Row(Modifier.fillMaxWidth().padding(vertical = YY.s(10)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(10))) {
        RemoteCover(client, e, Modifier.width(YY.s(34)).height(YY.s(51)))
        Column(Modifier.weight(1f)) {
            Text(e.title, style = YY.font(11.5f, FontWeight.SemiBold), color = YY.c.t1, maxLines = 2)
            val parts = listOfNotNull(e.author, e.format) + when {
                fraction != null -> listOf(t("正在下载 %lld%%", (fraction * 100).toInt()))
                (e.size ?: 0) > 0 -> listOf(Formatter.formatShortFileSize(context, e.size!!))
                else -> emptyList()
            }
            Text(parts.joinToString(" · "), style = YY.font(10f), color = YY.c.t3, maxLines = 1)
        }
        when {
            fraction != null -> CircularProgressIndicator({ maxOf(0.03f, fraction) }, Modifier.size(YY.s(26)), color = YY.tint.accent, trackColor = YY.c.inset, strokeWidth = YY.s(3))
            library.sources.has(e, source, library) -> Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.check, null, tint = YY.c.t3, modifier = Modifier.size(YY.s(11)))
                Text(t("在书架"), style = YY.font(10f), color = YY.c.t3)
            }
            else -> Box(Modifier.size(YY.s(30)).background(YY.c.inset, CircleShape).clickable(onClickLabel = t("下载《%@》", e.title)) {
                scope.launch {
                    try {
                        library.sources.take(e, source, library, context)
                    } catch (x: CancellationException) {
                        throw x
                    } catch (x: Exception) {
                        library.alert = t("《%@》没有下载下来：%@", e.title, x.message ?: "")
                    }
                }
            }, contentAlignment = Alignment.Center) { Icon(Icons.cloudDownload, null, tint = YY.c.t1, modifier = Modifier.size(YY.s(14))) }
        }
    }
}

/** The library's own picture of the book, or a plain paper with its name. */
@Composable
private fun RemoteCover(client: RemoteClient, e: RemoteEntry, modifier: Modifier) {
    var bitmap by remember(e.cover) { mutableStateOf<android.graphics.Bitmap?>(null) }
    LaunchedEffect(e.cover) {
        val url = e.cover ?: return@LaunchedEffect
        bitmap = runCatching { client.data(url) }.getOrNull()?.let { withContext(Dispatchers.Default) { BitmapFactory.decodeByteArray(it, 0, it.size) } }
    }
    val b = bitmap
    Box(modifier.yyCard(radius = 3.dp)) {
        if (b != null) Image(b.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        else Box(Modifier.fillMaxSize().background(app.yuyue.design.YYPapers.Kami.bg).padding(3.dp)) {
            Text(e.title, style = YY.font(6.5f, family = YY.serif), color = app.yuyue.design.YYPapers.Kami.ink, maxLines = 4)
        }
    }
}
