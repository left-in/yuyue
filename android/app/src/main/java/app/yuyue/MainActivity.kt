package app.yuyue

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.IntentCompat
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YuyueTheme
import app.yuyue.design.Prefs
import app.yuyue.design.rememberPref
import app.yuyue.library.Library
import app.yuyue.reader.ReaderScreen
import app.yuyue.shelf.ShelfScreen
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val library: Library get() = (application as YuyueApp).library

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) handle(intent)
        setContent { YuyueTheme { Root(library) } }
    }

    /** 音量键翻页: volume down turns on, up turns back; held down, the pages keep turning. */
    override fun onKeyDown(keyCode: Int, event: android.view.KeyEvent): Boolean {
        val forward = when (keyCode) {
            android.view.KeyEvent.KEYCODE_VOLUME_DOWN -> true
            android.view.KeyEvent.KEYCODE_VOLUME_UP -> false
            else -> return super.onKeyDown(keyCode, event)
        }
        return app.yuyue.reader.VolumeKeys.handler?.invoke(forward) == true || super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: android.view.KeyEvent): Boolean {
        if ((keyCode == android.view.KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP) && app.yuyue.reader.VolumeKeys.handler != null &&
            Prefs.bool("reader.volumeKeys", true)) return true
        return super.onKeyUp(keyCode, event)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** 用语阅打开: books opened or shared from other apps go into the library. */
    private fun handle(intent: Intent?) {
        intent ?: return
        val uris = mutableListOf<Uri>()
        when (intent.action) {
            Intent.ACTION_VIEW -> intent.data?.let { uris += it }
            Intent.ACTION_SEND -> IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)?.let { uris += it }
            Intent.ACTION_SEND_MULTIPLE -> IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)?.let { uris += it }
        }
        if (uris.isNotEmpty()) library.importUris(uris)
    }
}

/** The tabs: 书架 · 笔记 · 我的, and 搜索. */
enum class Tab { Shelf, Notes, Me, Search }

/** A page pushed over a tab. */
sealed interface Page {
    data object Wifi : Page
    data object Remote : Page
    data object Watched : Page
}

/** The phone, as on iPhone: four tabs along the bottom (on Android flush with the bottom edge),
 *  and a book over all of them, full screen. */
@Composable
fun Root(library: Library) {
    var tab by rememberSaveable { mutableStateOf(Tab.Shelf) }
    val pages = remember { mutableStateListOf<Page>() }
    var lastBook by rememberPref("phone.lastBook", "")
    var reopened by rememberSaveable { mutableStateOf(false) }

    // 上次停在书页上，打开 App 就直接回到那一页.
    LaunchedEffect(Unit) {
        if (!reopened) {
            reopened = true
            if (lastBook.isNotEmpty() && library.books.any { it.id == lastBook && it.available }) library.presented = lastBook
        }
    }

    Box(Modifier.fillMaxSize().background(YY.c.bg)) {
        Column(Modifier.fillMaxSize()) {
            Box(Modifier.weight(1f)) {
                when (val page = pages.lastOrNull()) {
                    null -> when (tab) {
                        Tab.Shelf -> ShelfScreen(library, openWifi = { pages += Page.Wifi }, openRemote = { pages += Page.Remote }, openWatched = { pages += Page.Watched })
                        Tab.Notes -> app.yuyue.notes.NotesScreen(library)
                        Tab.Me -> app.yuyue.me.MeScreen(library)
                        Tab.Search -> app.yuyue.search.SearchScreen(library)
                    }
                    Page.Wifi -> app.yuyue.me.SubPage(t("Wi‑Fi 传书"), { pages.removeAt(pages.lastIndex) }) { app.yuyue.shelf.WifiPage(library) }
                    Page.Remote -> Placeholder(t("远程书库"))
                    Page.Watched -> app.yuyue.me.SubPage(t("监听一个文件夹"), { pages.removeAt(pages.lastIndex) }) { app.yuyue.shelf.WatchedPage(library) }
                }
            }
            NowPlayingBar(library)
            TabBar(tab) { tab = it; pages.clear() }
        }
        BackHandler(enabled = pages.isNotEmpty()) { pages.removeAt(pages.lastIndex) }

        library.presented?.let { id ->
            LaunchedEffect(id) { lastBook = id }
            val closeBook = {
                library.presented = null
                lastBook = ""
            }
            when (library.books.firstOrNull { it.id == id }?.format) {
                uniffi.yuyue_core.BookFormat.COMIC -> app.yuyue.comics.ComicScreen(library, id, closeBook)
                uniffi.yuyue_core.BookFormat.PDF -> app.yuyue.pdf.PdfScreen(library, id, closeBook)
                else -> ReaderScreen(library, id, closeBook)
            }
        }
    }

    LaunchedEffect(Unit) { library.sync.keepUp() }
    // Books put in the watched folder come in whenever 语阅 comes to the front.
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    androidx.compose.runtime.DisposableEffect(lifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, e ->
            if (e == androidx.lifecycle.Lifecycle.Event.ON_START) library.scope.launch { library.watched.scan(library) }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    library.openedSnapshot?.let { (file, info) -> app.yuyue.me.SnapshotImportSheet(library, file, info) { library.openedSnapshot = null } }

    library.alert?.let { message ->
        AlertDialog(
            onDismissRequest = { library.alert = null },
            containerColor = YY.c.card,
            title = { Text(t("出了点问题"), color = YY.c.t1) },
            text = { Text(message, color = YY.c.t2) },
            confirmButton = { TextButton({ library.alert = null }) { Text(t("好"), color = YY.tint.accent) } },
        )
    }
}

/** The tab bar flush with the bottom edge: the prototype's Android 底栏. */
@Composable
private fun TabBar(tab: Tab, select: (Tab) -> Unit) {
    Column(Modifier.fillMaxWidth().background(YY.c.card)) {
        Box(Modifier.fillMaxWidth().height(0.5.dp).background(YY.c.line))
        Row(
            Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.navigationBars).height(56.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TabItem(Icons.books, t("书架"), tab == Tab.Shelf) { select(Tab.Shelf) }
            TabItem(Icons.highlighter, t("笔记"), tab == Tab.Notes) { select(Tab.Notes) }
            TabItem(Icons.person, t("我的"), tab == Tab.Me) { select(Tab.Me) }
            TabItem(Icons.search, t("搜索"), tab == Tab.Search) { select(Tab.Search) }
        }
    }
}

@Composable
private fun TabItem(icon: ImageVector, title: String, on: Boolean, onClick: () -> Unit) {
    val color = if (on) YY.tint.accent else YY.c.t2
    Column(
        Modifier.clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onClick).padding(horizontal = 18.dp, vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(icon, title, tint = color, modifier = Modifier.size(24.dp))
        Text(title, fontSize = 10.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Medium, color = color)
    }
}

@Composable
fun Placeholder(title: String) {
    Box(Modifier.fillMaxSize().background(YY.c.bg), contentAlignment = Alignment.Center) {
        Text(title, color = YY.c.t3)
    }
}

/** Cover, the sentence being read, ‹ ▶ ›, and a thin line for the chapter underneath, while a
 *  book is read aloud with its pages closed. A tap anywhere else goes back to the page. */
@Composable
private fun NowPlayingBar(library: Library) {
    val model = library.nowPlaying as? app.yuyue.reader.ReaderModel ?: return
    val player = model.player ?: return
    val book = library.books.firstOrNull { it.id == model.bookID } ?: return
    if (player.state == app.yuyue.speech.Player.State.Stopped) {
        LaunchedEffect(Unit) { model.close(); library.nowPlaying = null }
        return
    }
    val tint = YY.tint
    Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Row(
            Modifier.fillMaxWidth().background(YY.c.card, androidx.compose.foundation.shape.CircleShape)
                .clickable { library.presented = book.id }.padding(start = 10.dp, end = 8.dp, top = 7.dp, bottom = 7.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            app.yuyue.shelf.BookCover(book, Modifier.size(width = 30.dp, height = 45.dp))
            Column(Modifier.weight(1f)) {
                Text(player.line ?: book.title, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = YY.c.t1, maxLines = 1)
                Text(book.title, fontSize = 11.sp, color = YY.c.t3, maxLines = 1)
            }
            Icon(Icons.previous, t("上一句"), tint = YY.c.t1, modifier = Modifier.size(34.dp).clickable { player.skip(false) }.padding(6.dp))
            val playing = player.state == app.yuyue.speech.Player.State.Playing || player.state == app.yuyue.speech.Player.State.Loading
            Icon(if (playing) Icons.pause else Icons.play, if (playing) t("暂停") else t("接着听"), tint = YY.c.t1, modifier = Modifier.size(38.dp).clickable { player.toggle() }.padding(5.dp))
            Icon(Icons.next, t("下一句"), tint = YY.c.t1, modifier = Modifier.size(34.dp).clickable { player.skip(true) }.padding(6.dp))
        }
        androidx.compose.foundation.layout.BoxWithConstraints(Modifier.align(Alignment.BottomStart).padding(horizontal = 22.dp).fillMaxWidth().height(2.dp)) {
            Box(Modifier.width(maxWidth * player.sectionProgress.toFloat()).height(2.dp).background(tint.accent, androidx.compose.foundation.shape.CircleShape))
        }
    }
}
