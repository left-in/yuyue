package app.yuyue.shelf

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.media3.common.util.UnstableApi
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYSegments
import app.yuyue.design.yyCard
import app.yuyue.library.Library
import app.yuyue.speech.AudiobookPlayer
import app.yuyue.speech.Player
import app.yuyue.t

/** 有声书 open: the cover, the chapter, the scrubber with the 书签 on
 *  it, and the controls; 章节 and 书签 come up from the bottom. */
@UnstableApi
@Composable
fun AudiobookScreen(library: Library, bookID: String, close: () -> Unit) {
    val context = LocalContext.current
    val player = remember(bookID) {
        // Still playing with the page closed: picked up as it is.
        (library.nowPlaying as? AudiobookPlayer)?.takeIf { it.bookID == bookID }?.also { library.nowPlaying = null } ?: run {
            (library.nowPlaying as? AudiobookPlayer)?.close()
            (library.nowPlaying as? app.yuyue.reader.ReaderModel)?.close()
            library.nowPlaying = null
            val book = library.books.first { it.id == bookID }
            AudiobookPlayer(context, library, book).also { p ->
                when (library.takeIntent(bookID)) {
                    Library.OpenIntent.Listen -> p.play()
                    Library.OpenIntent.ListenFromStart -> { p.seekTo(0.0); p.play() }
                    else -> {}
                }
            }
        }
    }
    DisposableEffect(player) {
        onDispose {
            // Closed while it plays: it goes on, with the 播放条 over the tabs.
            if (player.isPlaying || player.waiting) library.nowPlaying = player else player.close()
        }
    }
    BackHandler(onBack = close)
    var list by remember { mutableStateOf<Int?>(null) }

    Column(
        Modifier.fillMaxSize().background(YY.c.bg).windowInsetsPadding(WindowInsets.safeDrawing).padding(horizontal = YY.s(22)),
    ) {
        Row(Modifier.fillMaxWidth().padding(top = YY.s(4))) {
            Box(Modifier.size(YY.s(36)).clip(CircleShape).clickable(onClickLabel = t("收起"), onClick = close), contentAlignment = Alignment.Center) {
                Icon(Icons.chevronDown, t("收起"), tint = YY.c.t1, modifier = Modifier.size(YY.s(22)))
            }
        }
        SquareCover(player.summary, Modifier.align(Alignment.CenterHorizontally).padding(top = YY.s(14), bottom = YY.s(18)).width(YY.s(188)))
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(YY.s(8))) {
            Column(Modifier.weight(1f)) {
                Text(player.title(player.chapter), style = YY.font(17f, FontWeight.Bold), color = YY.c.t1, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(listOfNotNull(player.summary.title, player.summary.authors.firstOrNull()).joinToString(" · "), style = YY.font(11f), color = YY.c.t2, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Box(Modifier.size(YY.s(30)).clip(CircleShape).clickable(onClickLabel = t("加书签")) { player.addBookmark() }, contentAlignment = Alignment.Center) {
                Icon(Icons.bookmarkOutline, t("加书签"), tint = YY.c.t1, modifier = Modifier.size(YY.s(18)))
            }
        }
        Scrubber(player, Modifier.padding(top = YY.s(18), bottom = YY.s(6)))
        Times(player)
        Controls(player, Modifier.padding(vertical = YY.s(14)))
        Tiles(player) { list = it }
        PairCard(library, player.summary)
        if (player.waiting) Text(t("已暂停 · 通话结束后继续"), style = YY.font(11f), color = YY.c.t2, modifier = Modifier.padding(top = YY.s(10)))
        player.failure?.let { Text(it, style = YY.font(11f), color = YY.c.danger, modifier = Modifier.padding(top = YY.s(10))) }
    }
    list?.let { ChapterSheet(player, it, { list = it }) { list = null } }
}

/** 书架上有同一本电子书: 合成 lays the recording against it; while it runs, how far. */
@UnstableApi
@Composable
private fun PairCard(library: Library, audio: uniffi.yuyue_core.BookSummary) {
    val r = library.recordings
    val making = r.making?.takeIf { it.audio == audio.id }
    val ebook = making?.let { m -> library.books.firstOrNull { it.id == m.ebook } } ?: r.ebookFor(audio) ?: return
    Row(
        Modifier.padding(top = YY.s(14)).fillMaxWidth().yyCard(YY.s(14)).padding(horizontal = YY.s(12), vertical = YY.s(10)),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(10)),
    ) {
        BookCover(ebook, Modifier.width(YY.s(24)))
        Column(Modifier.weight(1f)) {
            Text(t("书架上有《%@》电子书", ebook.title), style = YY.font(11f, FontWeight.SemiBold), color = YY.c.t1, maxLines = 1, overflow = TextOverflow.Ellipsis)
            val line = when {
                making == null -> t("合成以后听到哪句，书页就走到哪句")
                making.problem != null -> making.problem!!
                making.downloaded != null -> t("下载对齐模型 %lld%%", ((making.downloaded ?: 0.0) * 100).toInt())
                else -> t("合成中 %lld%%", (making.fraction * 100).toInt())
            }
            Text(line, style = YY.font(10f), color = if (making?.problem != null) YY.c.danger else YY.c.t3, maxLines = 2)
        }
        if (making == null || making.problem != null) {
            Box(Modifier.height(YY.s(26)).clip(CircleShape).background(YY.c.t1).clickable { r.make(audio, ebook) }.padding(horizontal = YY.s(12)), contentAlignment = Alignment.Center) {
                Text(if (making?.problem != null) t("再试一次") else t("合成"), style = YY.font(11f, FontWeight.SemiBold), color = YY.c.bg)
            }
        }
    }
}

/** The chapter: what's been heard, the 书签 in it as small marks, and a knob to drag. */
@UnstableApi
@Composable
private fun Scrubber(player: AudiobookPlayer, modifier: Modifier) {
    var dragging by remember { mutableStateOf<Double?>(null) }
    val (at, of) = player.inChapter
    val start = player.chapters.getOrNull(player.chapter)?.start ?: 0.0
    val shown = dragging ?: at
    BoxWithConstraints(modifier.fillMaxWidth().height(YY.s(16))) {
        val w = constraints.maxWidth.toFloat()
        val full = maxWidth
        fun frac(t: Double) = if (of > 0) (t / of).coerceIn(0.0, 1.0).toFloat() else 0f
        Box(
            Modifier.fillMaxSize()
                .pointerInput(of, start) {
                    detectTapGestures { o -> player.seekTo(start + of * (o.x / w).coerceIn(0f, 1f)) }
                }
                .pointerInput(of, start) {
                    detectHorizontalDragGestures(
                        onDragStart = { o -> dragging = of * (o.x / w).coerceIn(0f, 1f) },
                        onDragEnd = { dragging?.let { player.seekTo(start + it) }; dragging = null },
                        onDragCancel = { dragging = null },
                    ) { change, _ -> dragging = of * (change.position.x / w).coerceIn(0f, 1f) }
                },
            contentAlignment = Alignment.CenterStart,
        ) {
            Box(Modifier.fillMaxWidth().height(4.dp).clip(CircleShape).background(YY.c.inset))
            Box(Modifier.width(full * frac(shown)).height(4.dp).clip(CircleShape).background(YY.c.t1))
            for (b in player.bookmarks) {
                val m = player.seconds(b) - start
                if (m in 0.0..of) Box(Modifier.offset(x = full * frac(m) - 1.dp).size(2.dp, 6.dp).background(YY.c.card))
            }
            Box(Modifier.offset(x = full * frac(shown) - 6.dp).size(12.dp).clip(CircleShape).background(YY.c.t1))
        }
    }
}

@UnstableApi
@Composable
private fun Times(player: AudiobookPlayer) {
    val (at, of) = player.inChapter
    val left = player.total - player.time
    val tnum = YY.font(10f).copy(fontFeatureSettings = "tnum")
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(AudiobookPlayer.clock(at), style = tnum.copy(fontWeight = FontWeight.Medium), color = YY.c.t2)
        Text(
            t("本集还剩 %@ · 全书还剩 %@", AudiobookPlayer.clock(of - at), length(left)),
            style = tnum, color = YY.c.t3, maxLines = 1, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
        Text(AudiobookPlayer.clock(of), style = tnum.copy(fontWeight = FontWeight.Medium), color = YY.c.t2)
    }
}

/** `6 小时 12 分`, `38 分钟`. */
fun length(seconds: Double): String {
    val m = (seconds / 60).toInt()
    return if (m >= 60) (if (m % 60 > 0) t("%lld 小时 %lld 分", m / 60, m % 60) else t("%lld 小时", m / 60)) else t("%lld 分钟", maxOf(1, m))
}

private val rates = listOf(0.75f, 1f, 1.1f, 1.2f, 1.25f, 1.5f, 1.75f, 2f, 2.5f, 3f)

private fun rateName(r: Float) = (if (r == r.toInt().toFloat()) r.toInt().toString() else r.toString().trimEnd('0')) + "×"

@UnstableApi
@Composable
private fun Controls(player: AudiobookPlayer, modifier: Modifier) {
    var rateOpen by remember { mutableStateOf(false) }
    Row(modifier.fillMaxWidth().padding(horizontal = YY.s(4)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
        Box {
            Box(Modifier.size(YY.s(40)).clip(CircleShape).clickable(onClickLabel = t("倍速")) { rateOpen = true }, contentAlignment = Alignment.Center) {
                Text(rateName(player.rate), style = YY.font(12.5f, FontWeight.SemiBold).copy(fontFeatureSettings = "tnum"), color = YY.c.t1)
            }
            DropdownMenu(rateOpen, { rateOpen = false }) {
                for (r in rates) DropdownMenuItem({ Text(rateName(r)) }, { player.changeRate(r); rateOpen = false })
            }
        }
        RoundIcon(Icons.back15, t("后退 15 秒")) { player.skip(-AudiobookPlayer.BACK) }
        val label = if (player.isPlaying) t("暂停") else t("播放")
        Box(Modifier.size(YY.s(60)).clip(CircleShape).background(YY.tint.black).clickable(onClickLabel = label) { player.toggle() }, contentAlignment = Alignment.Center) {
            Icon(if (player.isPlaying) Icons.pause else Icons.play, label, tint = YY.tint.onBlack, modifier = Modifier.size(YY.s(24)))
        }
        RoundIcon(Icons.ahead30, t("前进 30 秒")) { player.skip(AudiobookPlayer.AHEAD) }
        SleepButton(player)
    }
}

@Composable
private fun RoundIcon(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Box(Modifier.size(YY.s(40)).clip(CircleShape).clickable(onClickLabel = label, onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, label, tint = YY.c.t1, modifier = Modifier.size(YY.s(24)))
    }
}

@UnstableApi
@Composable
private fun SleepButton(player: AudiobookPlayer, tile: Boolean = false) {
    var open by remember { mutableStateOf(false) }
    Box {
        if (tile) {
            TileFace(Icons.sleep, t("定时"), sleepName(player.sleep)) { open = true }
        } else {
            Box(Modifier.size(YY.s(40)).clip(CircleShape).clickable(onClickLabel = t("定时")) { open = true }, contentAlignment = Alignment.Center) {
                Icon(Icons.sleep, t("定时"), tint = if (player.sleep == Player.Sleep.Off) YY.c.t1 else YY.tint.accent, modifier = Modifier.size(YY.s(22)))
            }
        }
        DropdownMenu(open, { open = false }) {
            DropdownMenuItem({ Text(t("本集完")) }, { player.changeSleep(Player.Sleep.Chapter); open = false })
            for (m in listOf(15, 30, 45, 60, 90)) {
                DropdownMenuItem({ Text(t("%lld 分钟", m)) }, { player.changeSleep(Player.Sleep.Until(System.currentTimeMillis() + m * 60_000L, m)); open = false })
            }
            if (player.sleep != Player.Sleep.Off) DropdownMenuItem({ Text(t("关闭定时"), color = YY.c.danger) }, { player.changeSleep(Player.Sleep.Off); open = false })
        }
    }
}

private fun sleepName(s: Player.Sleep) = when (s) {
    Player.Sleep.Off -> t("关")
    Player.Sleep.Chapter, Player.Sleep.Sentence -> t("本集完")
    is Player.Sleep.Until -> t("%lld 分钟", s.minutes)
}

@UnstableApi
@Composable
private fun Tiles(player: AudiobookPlayer, open: (Int) -> Unit) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(YY.s(6))) {
        Box(Modifier.weight(1f)) { TileFace(Icons.list, t("章节"), t("%lld 集", player.chapters.size)) { open(0) } }
        Box(Modifier.weight(1f)) { TileFace(Icons.bookmarkOutline, t("书签"), t("%lld 个", player.bookmarks.size)) { open(1) } }
        Box(Modifier.weight(1f)) { SleepButton(player, tile = true) }
    }
}

@Composable
private fun TileFace(icon: androidx.compose.ui.graphics.vector.ImageVector, name: String, detail: String, onClick: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().yyCard(YY.s(14)).clickable(onClick = onClick).padding(vertical = YY.s(9)),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(YY.s(3)),
    ) {
        Icon(icon, null, tint = YY.c.t1, modifier = Modifier.size(YY.s(16)))
        Text(name, style = YY.font(10f, FontWeight.SemiBold), color = YY.c.t1)
        Text(detail, style = YY.font(10f), color = YY.c.t3, maxLines = 1)
    }
}

/** 章节 and 书签: the one being heard has the moving bars, the ones heard are grey. */
@OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.ExperimentalFoundationApi::class)
@UnstableApi
@Composable
private fun ChapterSheet(player: AudiobookPlayer, page: Int, select: (Int) -> Unit, dismiss: () -> Unit) {
    // 长按改名: the chapter being named, and the name typed.
    var renaming by remember { mutableStateOf<Int?>(null) }
    var newName by remember { mutableStateOf("") }
    renaming?.let { i ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { renaming = null },
            containerColor = YY.c.card,
            title = { Text(t("给这一集起个名字"), color = YY.c.t1) },
            text = {
                Column {
                    androidx.compose.material3.OutlinedTextField(newName, { newName = it }, singleLine = true, placeholder = { Text(t("第 %lld 集", i + 1)) })
                    Text(t("留空就叫“第几集”"), style = YY.font(10f), color = YY.c.t3, modifier = Modifier.padding(top = 6.dp))
                }
            },
            confirmButton = { androidx.compose.material3.TextButton({ player.renameChapter(i, newName); renaming = null }) { Text(t("好"), color = YY.tint.accent) } },
            dismissButton = { androidx.compose.material3.TextButton({ renaming = null }) { Text(t("取消"), color = YY.c.t2) } },
        )
    }
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(), containerColor = YY.c.bg) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 24.dp)) {
            YYSegments(listOf(0 to t("章节 %lld", player.chapters.size), 1 to t("书签 %lld", player.bookmarks.size)), page, select)
            Spacer(Modifier.height(10.dp))
            val now = player.chapter
            LazyColumn(Modifier.fillMaxWidth().yyCard()) {
                if (page == 0) {
                    itemsIndexed(player.chapters) { i, c ->
                        Row(
                            Modifier.fillMaxWidth()
                                .combinedClickable(onLongClickLabel = t("改名"), onLongClick = { renaming = i; newName = c.title ?: "" }) { player.goToChapter(i); dismiss() }
                                .padding(horizontal = YY.s(14)).height(YY.s(40)),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            if (i == now) {
                                Icon(Icons.waveform, null, tint = YY.c.t1, modifier = Modifier.width(YY.s(20)).size(YY.s(13)))
                            } else {
                                Text("${i + 1}", style = YY.font(10f).copy(fontFeatureSettings = "tnum"), color = YY.c.t3, modifier = Modifier.width(YY.s(20)))
                            }
                            Text(
                                player.title(i), style = YY.font(13f, if (i == now) FontWeight.SemiBold else FontWeight.Normal),
                                color = if (i < now) YY.c.t3 else YY.c.t1, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
                            )
                            Text(
                                if (i == now) t("还剩 %@", AudiobookPlayer.clock(player.inChapter.second - player.inChapter.first)) else AudiobookPlayer.clock(c.seconds),
                                style = YY.font(11f).copy(fontFeatureSettings = "tnum"), color = YY.c.t3,
                            )
                        }
                    }
                } else {
                    if (player.bookmarks.isEmpty()) item {
                        Text(t("听到想记住的地方，点书签按钮记一下。"), style = YY.font(11f), color = YY.c.t3, modifier = Modifier.padding(YY.s(14)))
                    }
                    items(player.bookmarks, key = { it.id }) { b ->
                        Row(
                            Modifier.fillMaxWidth().clickable { player.seekTo(player.seconds(b)); dismiss() }.padding(horizontal = YY.s(14)).height(YY.s(40)),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(player.title(b.section.toInt()), style = YY.font(13f), color = YY.c.t1, maxLines = 1, modifier = Modifier.weight(1f))
                            Text(AudiobookPlayer.clock(b.sentence.toDouble() / 1000), style = YY.font(11f).copy(fontFeatureSettings = "tnum"), color = YY.c.t3)
                            Box(Modifier.padding(start = YY.s(8)).size(YY.s(28)).clip(CircleShape).clickable(onClickLabel = t("删除")) { player.deleteBookmark(b) }, contentAlignment = Alignment.Center) {
                                Icon(Icons.close, t("删除"), tint = YY.c.t3, modifier = Modifier.size(YY.s(12)))
                            }
                        }
                    }
                }
            }
        }
    }
}
