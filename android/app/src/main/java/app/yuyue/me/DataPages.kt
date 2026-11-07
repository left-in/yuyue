package app.yuyue.me

import android.content.Intent
import android.net.Uri
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import app.yuyue.YuyueApp
import app.yuyue.design.ButtonKind
import app.yuyue.design.ButtonSize
import app.yuyue.design.Icons
import app.yuyue.design.YY
import app.yuyue.design.YYButton
import app.yuyue.design.YYField
import app.yuyue.design.YYGroup
import app.yuyue.design.YYLabel
import app.yuyue.design.YYNote
import app.yuyue.design.YYPage
import app.yuyue.design.YYRow
import app.yuyue.library.Library
import app.yuyue.reader.SwitchRow
import app.yuyue.shelf.Field
import app.yuyue.sync.Sync
import app.yuyue.sync.DriveAuth
import androidx.activity.result.IntentSenderRequest
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.yuyue_core.SnapshotAbout
import uniffi.yuyue_core.SnapshotCounts
import uniffi.yuyue_core.SnapshotInfo
import uniffi.yuyue_core.SnapshotParts
import uniffi.yuyue_core.SyncPart
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

// MARK: 同步

/** 同步, as on iPhone: how it went, every device, where to meet (a WebDAV share
 *  on Android; iCloud is Apple's), and what goes. */
@Composable
fun SyncPage(sync: Sync) {
    var editing by remember { mutableStateOf(false) }
    var driving by remember { mutableStateOf(false) }
    var driveProblem by remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    fun connect() {
        scope.launch {
            try {
                withContext(Dispatchers.IO) { sync.connectDrive() }
            } catch (e: Exception) {
                driveProblem = Sync.message(e)
            }
            driving = false
        }
    }
    val allow = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        if (runCatching { DriveAuth.token(context, result.data) }.isSuccess) connect() else driving = false
    }
    LaunchedEffect(Unit) { sync.loadDevices() }
    YYPage {
        StatusCard(sync)
        YYLabel(t("同步方式"))
        YYGroup {
            row {
                YYRow("Google Drive", Icons.cloudDownload, if (sync.method == "drive") sync.driveEmail ?: t("已连接") else t("用这台手机上的 Google 账号"), onClick = {
                    if (sync.method == "drive") return@YYRow
                    driving = true
                    driveProblem = null
                    DriveAuth.authorize(context) { r ->
                        r.onSuccess { e ->
                            when (e) {
                                is DriveAuth.Either.Ask -> allow.launch(IntentSenderRequest.Builder(e.sender).build())
                                is DriveAuth.Either.Token -> connect()
                            }
                        }.onFailure { driving = false; driveProblem = t("Google 账号没连上（%@）", it.message ?: "") }
                    }
                }, trailing = {
                    if (driving) CircularProgressIndicator(Modifier.size(YY.s(14)), strokeWidth = 2.dp, color = YY.tint.accent)
                    else if (sync.method == "drive") Icon(Icons.check, null, tint = YY.tint.accent, modifier = Modifier.size(YY.s(13)))
                })
            }
            row {
                YYRow("WebDAV", Icons.server, if (sync.method == "webdav") sync.webdav?.url?.let { Uri.parse(it).host } else t("坚果云、群晖、Nextcloud…"), chevron = sync.method != "webdav", onClick = { editing = true }, trailing = {
                    if (sync.method == "webdav") Icon(Icons.check, null, tint = YY.tint.accent, modifier = Modifier.size(YY.s(13)))
                })
            }
        }
        YYNote(driveProblem ?: t("和 iPhone、Mac 选同一种方式，进度和笔记就在这些设备之间来回。Google Drive 存在只有语阅看得到的隐藏文件夹里。"), if (driveProblem != null) YY.c.danger else YY.c.t3)
        YYLabel(t("同步这些"))
        YYGroup {
            row { SwitchRow(t("进度和书签"), sync.includes(SyncPart.READING)) { sync.include(SyncPart.READING, it) } }
            row { SwitchRow(t("笔记和生词"), sync.includes(SyncPart.NOTES)) { sync.include(SyncPart.NOTES, it) } }
            row { SwitchRow(t("设置和替换规则"), sync.includes(SyncPart.SETTINGS)) { sync.include(SyncPart.SETTINGS, it) } }
            row { SwitchRow(t("书文件") + " · " + t("只在 Wi-Fi 下"), sync.syncsFiles) { sync.syncFiles(it) } }
        }
        if (sync.on) {
            Spacer(Modifier.height(14.dp))
            YYGroup { row { YYRow(t("停止同步"), titleColor = YY.c.danger, onClick = { sync.stop() }) } }
        }
        YYNote(t("不用注册账号，数据只在你的设备和你自己的网盘之间走。"))
    }
    if (editing) WebDAVSheet(sync) { editing = false }
}

@Composable
private fun StatusCard(sync: Sync) {
    val failed = sync.state is Sync.State.Failed
    Column(
        Modifier.padding(top = YY.s(10)).fillMaxWidth().background(YY.c.card, RoundedCornerShape(YY.s(16))).border(0.5.dp, YY.c.line, RoundedCornerShape(YY.s(16)))
            .padding(horizontal = YY.s(14), vertical = YY.s(14)),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(10))) {
            Box(Modifier.size(YY.s(34)).background(if (failed) YY.c.danger.copy(alpha = 0.12f) else YY.tint.accentSoft, RoundedCornerShape(YY.s(10))), contentAlignment = Alignment.Center) {
                if (sync.state == Sync.State.Syncing) CircularProgressIndicator(Modifier.size(YY.s(16)), strokeWidth = 2.dp, color = YY.tint.accent)
                else Icon(if (failed) Icons.error else Icons.sync, null, tint = if (failed) YY.c.danger else YY.tint.accent, modifier = Modifier.size(YY.s(17)))
            }
            Column(Modifier.weight(1f)) {
                Text(
                    when {
                        !sync.on -> t("没开同步")
                        failed -> t("没同步上")
                        sync.state == Sync.State.Syncing -> t("正在同步…")
                        else -> t("已同步")
                    },
                    style = YY.font(14f, FontWeight.Bold), color = if (failed) YY.c.danger else YY.c.t1,
                )
                Text(
                    (sync.state as? Sync.State.Failed)?.message ?: sync.lastSynced?.let { ago(it) } ?: t("选一个同步方式就开始"),
                    style = YY.font(10f), color = YY.c.t3, maxLines = 2,
                )
            }
            if (sync.on) YYButton(t("立即同步"), ButtonKind.Plain, ButtonSize.Small, enabled = sync.state != Sync.State.Syncing) { sync.now() }
        }
        for (d in sync.devices) {
            Box(Modifier.padding(top = YY.s(10)).fillMaxWidth().height(0.5.dp).background(YY.c.line))
            Row(Modifier.fillMaxWidth().heightIn(min = YY.s(34)), verticalAlignment = Alignment.CenterVertically) {
                Text(if (d.thisDevice) t("这台 %@", d.name.ifEmpty { t("设备") }) else d.name.ifEmpty { t("设备") }, style = YY.font(11f), color = YY.c.t1, maxLines = 1, modifier = Modifier.weight(1f))
                Text(d.lastAt?.let { ago(it) } ?: "", style = YY.font(10f), color = YY.c.t3)
            }
        }
    }
}

/** "刚刚" · "5 分钟前" · "3 小时前" · "10 月 2 日". */
fun ago(ms: Long): String {
    val s = (System.currentTimeMillis() - ms) / 1000
    return when {
        s < 60 -> t("刚刚")
        s < 3600 -> t("%lld 分钟前", s / 60)
        s < 86400 -> t("%lld 小时前", s / 3600)
        else -> day(ms)
    }
}

fun day(ms: Long): String {
    val c = Calendar.getInstance().apply { timeInMillis = ms }
    return t("%lld 月 %lld 日", c.get(Calendar.MONTH) + 1, c.get(Calendar.DAY_OF_MONTH))
}

/** WebDAV: 地址, 账号, 密码, 文件夹; 连接 checks it can be reached and written. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WebDAVSheet(sync: Sync, dismiss: () -> Unit) {
    val a = sync.webdav
    var url by remember { mutableStateOf(a?.url ?: "") }
    var user by remember { mutableStateOf(a?.user ?: "") }
    var password by remember { mutableStateOf(a?.password ?: "") }
    var folder by remember { mutableStateOf(a?.folder ?: t("语阅")) }
    var checking by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 28.dp)) {
            Text("WebDAV", style = YY.font(14f, FontWeight.Bold), color = YY.c.t1, modifier = Modifier.padding(start = 4.dp, bottom = 10.dp))
            YYGroup {
                row { YYField(t("地址"), 64f) { Field(url, "https://dav.jianguoyun.com/dav/") { url = it } } }
                row { YYField(t("账号"), 64f) { Field(user, t("邮箱或用户名")) { user = it } } }
                row { YYField(t("密码"), 64f) { Secret(password, t("坚果云填应用密码")) { password = it } } }
                row { YYField(t("文件夹"), 64f) { Field(folder, t("语阅")) { folder = it } } }
            }
            YYNote(problem ?: t("密码存在这台设备上，加密保存。"), if (problem != null) YY.c.danger else YY.c.t3)
            Spacer(Modifier.height(18.dp))
            YYButton(if (checking) t("正在连接…") else t("连接"), ButtonKind.Main, ButtonSize.Large, wide = true, enabled = !checking && url.startsWith("http")) {
                checking = true
                problem = null
                scope.launch {
                    try {
                        withContext(Dispatchers.IO) { sync.connect(Sync.WebDAVAccount(url.trim(), user.trim(), password, folder.trim('/', ' '))) }
                        dismiss()
                    } catch (e: Exception) {
                        problem = Sync.message(e)
                    }
                    checking = false
                }
            }
        }
    }
}

@Composable
fun Secret(value: String, placeholder: String, onChange: (String) -> Unit) {
    androidx.compose.foundation.text.BasicTextField(
        value, onChange, singleLine = true,
        textStyle = YY.font(11.5f).copy(color = YY.c.t1),
        visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
        keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Password),
        cursorBrush = androidx.compose.ui.graphics.SolidColor(YY.tint.accent),
        decorationBox = { inner ->
            if (value.isEmpty()) Text(placeholder, style = YY.font(11.5f), color = YY.c.t3)
            inner()
        },
        modifier = Modifier.fillMaxWidth(),
    )
}

// MARK: 数据快照

private class Saved(val file: File, val about: SnapshotAbout)

private fun snapshotsDir() = File(YuyueApp.instance.filesDir, "snapshots").apply { mkdirs() }

private fun size(bytes: Long) = Formatter.formatShortFileSize(YuyueApp.instance, bytes)

private fun when_(ms: Long): String = SimpleDateFormat(if (L10nChinese()) "M 月 d 日 HH:mm" else "MMM d, HH:mm", Locale.getDefault()).format(Date(ms))

private fun L10nChinese() = app.yuyue.L10n.chinese

private fun snapshotName(note: String? = null) =
    t("语阅快照-%@%@.yuyue", note?.let { "$it-" } ?: "", SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date()))

/** 数据快照, as on iPhone: what goes in and how big, 生成快照, 导入快照, and the ones
 *  made before, to send on. The same .yuyue file moves between iPhone, Mac and Android. */
@Composable
fun SnapshotPage(library: Library) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var counts by remember { mutableStateOf<SnapshotCounts?>(null) }
    var saved by remember { mutableStateOf<List<Saved>>(emptyList()) }
    var parts by remember { mutableStateOf(SnapshotParts(true, true, true, true, false)) }
    var making by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    var importing by remember { mutableStateOf<Pair<File, SnapshotInfo>?>(null) }
    var version by remember { mutableIntStateOf(0) }
    var saving by remember { mutableStateOf<File?>(null) }

    LaunchedEffect(version) {
        withContext(Dispatchers.IO) {
            counts = runCatching { library.core.snapshotCounts() }.getOrNull()
            saved = (snapshotsDir().listFiles() ?: emptyArray()).filter { it.extension == "yuyue" }
                .mapNotNull { f -> runCatching { Saved(f, library.core.peekSnapshot(f.path)) }.getOrNull() }
                .sortedByDescending { it.about.madeAt }
        }
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch {
            try {
                importing = withContext(Dispatchers.IO) { copyIn(uri)?.let { f -> f to library.core.readSnapshot(f.path) } }
            } catch (e: Exception) {
                library.alert = Library.message(e)
            }
        }
    }
    val saver = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val f = saving
        saving = null
        if (uri == null || f == null) return@rememberLauncherForActivityResult
        scope.launch(Dispatchers.IO) {
            context.contentResolver.openOutputStream(uri)?.use { out -> f.inputStream().use { it.copyTo(out) } }
        }
    }

    YYPage {
        Text(t("把进度、笔记、生词和设置打包成一个文件。换手机、换到 Android，都用它搬家。"), style = YY.font(10.5f), color = YY.c.t2, modifier = Modifier.padding(start = 4.dp, end = 4.dp, top = YY.s(10), bottom = YY.s(8)))
        YYLabel(t("生成快照"))
        val c = counts
        YYGroup {
            row { SwitchRow(t("进度和书签") + (c?.let { " · " + t("%lld 本", it.read.toInt()) } ?: ""), parts.progress) { parts = parts.copy(progress = it) } }
            row { SwitchRow(t("笔记") + (c?.let { " · " + t("%lld 条", it.notes.toInt()) } ?: ""), parts.notes) { parts = parts.copy(notes = it) } }
            row { SwitchRow(t("生词") + (c?.let { " · " + t("%lld 个", it.words.toInt()) } ?: ""), parts.words) { parts = parts.copy(words = it) } }
            row { SwitchRow(t("设置和替换规则"), parts.settings) { parts = parts.copy(settings = it) } }
            row { SwitchRow(t("书文件") + (c?.let { " · " + size(it.fileBytes.toLong()) } ?: ""), parts.files) { parts = parts.copy(files = it) } }
            row {
                Row(Modifier.fillMaxWidth().padding(vertical = YY.s(9)), verticalAlignment = Alignment.CenterVertically) {
                    val estimate = c?.let { (it.dataBytes.toDouble() * 0.15).toLong() + if (parts.files) it.fileBytes.toLong() else 0 }
                    Text((if (parts.files) t("含书文件 · 约 ") else t("不含书文件 · 约 ")) + (estimate?.let(::size) ?: "…"), style = YY.font(10.5f), color = YY.c.t3, modifier = Modifier.weight(1f))
                    YYButton(if (making) "…" else t("生成快照"), ButtonKind.Main, enabled = !making && (parts.progress || parts.notes || parts.words || parts.settings || parts.files)) {
                        making = true
                        problem = null
                        scope.launch {
                            try {
                                withContext(Dispatchers.IO) { library.core.makeSnapshot(File(snapshotsDir(), snapshotName()).path, parts) }
                                version++
                            } catch (e: Exception) {
                                problem = Library.message(e)
                            }
                            making = false
                        }
                    }
                }
            }
            problem?.let { p -> row { YYRow(p, Icons.error, titleColor = YY.c.danger) } }
        }
        Spacer(Modifier.height(10.dp))
        YYGroup { row { YYRow(t("导入快照"), Icons.inbox, chevron = true) { picker.launch(arrayOf("*/*")) } } }
        if (saved.isNotEmpty()) {
            YYLabel(t("以前的快照"))
            YYGroup {
                for (s in saved) row {
                    Row(Modifier.fillMaxWidth().padding(vertical = YY.s(9)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(YY.s(8))) {
                        Column(Modifier.weight(1f).clickable { scope.launch { runCatching { importing = s.file to withContext(Dispatchers.IO) { library.core.readSnapshot(s.file.path) } } } }) {
                            Text(when_(s.about.madeAt), style = YY.font(11.5f, FontWeight.Medium), color = YY.c.t1)
                            Text(listOfNotNull(from(s.about.deviceName), if (s.about.parts.files) t("含书文件") else null, size(s.about.bytes.toLong())).joinToString(" · "), style = YY.font(10f), color = YY.c.t3, maxLines = 1)
                        }
                        Icon(Icons.share, t("分享"), tint = YY.c.t1, modifier = Modifier.size(YY.s(28)).background(YY.c.inset, RoundedCornerShape(50)).clickable { share(s.file) }.padding(YY.s(6)))
                        Icon(Icons.upload, t("存到…"), tint = YY.c.t1, modifier = Modifier.size(YY.s(28)).background(YY.c.inset, RoundedCornerShape(50)).clickable { saving = s.file; saver.launch(s.file.name) }.padding(YY.s(6)))
                        Icon(Icons.delete, t("删除"), tint = YY.c.danger, modifier = Modifier.size(YY.s(28)).clickable { s.file.delete(); version++ }.padding(YY.s(6)))
                    }
                }
            }
            YYNote(t("快照是一个 .yuyue 文件，拷到别的设备上打开就能导入，iPhone、Android 和 Mac 之间都通用。"))
        }
    }
    importing?.let { (file, info) -> SnapshotImportSheet(library, file, info, { importing = null; version++ }) }
}

private fun from(device: String) = if (device == Library.deviceName(YuyueApp.instance)) t("这台 %@", t("手机")) else device

private fun share(file: File) {
    val ctx = YuyueApp.instance
    val uri = FileProvider.getUriForFile(ctx, ctx.packageName + ".files", file)
    ctx.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("application/octet-stream").putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

/** A picked snapshot copied next to the app, to read. */
fun copyIn(uri: Uri): File? {
    val ctx = YuyueApp.instance
    val f = File(ctx.cacheDir, "picked.yuyue")
    ctx.contentResolver.openInputStream(uri)?.use { input -> f.outputStream().use { input.copyTo(it) } } ?: return null
    return f
}

/** 导入快照: where it's from and what it holds, 合并 or 覆盖, and what that does. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SnapshotImportSheet(library: Library, file: File, info: SnapshotInfo, dismiss: () -> Unit) {
    var replace by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = YY.c.bg) {
        Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 28.dp)) {
            Text(t("导入快照"), style = YY.font(14f, FontWeight.Bold), color = YY.c.t1, modifier = Modifier.padding(start = 4.dp, bottom = 12.dp))
            Column(Modifier.fillMaxWidth().background(YY.c.card, RoundedCornerShape(16.dp)).padding(12.dp)) {
                Text(t("来自 %@ · %@ · %@", from(info.deviceName), when_(info.madeAt), size(info.bytes.toLong())), style = YY.font(10.5f), color = YY.c.t2)
                val c = info.counts
                val tags = listOfNotNull(
                    if (info.parts.progress) t("进度") + " " + t("%lld 本", c.read.toInt()) else null,
                    if (info.parts.notes) t("笔记") + " " + t("%lld 条", c.notes.toInt()) else null,
                    if (info.parts.words) t("生词") + " " + t("%lld 个", c.words.toInt()) else null,
                    if (info.parts.settings) t("设置") else null,
                    if (info.parts.files) t("书文件") + " " + size(c.fileBytes.toLong()) else null,
                )
                Text(tags.joinToString(" · "), style = YY.font(11f, FontWeight.Medium), color = YY.c.t1, modifier = Modifier.padding(top = 8.dp))
            }
            Row(Modifier.padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Choice(t("合并"), t("这台设备上的都留着，加上快照里没有的；同一条取较新的。"), !replace, Modifier.weight(1f)) { replace = false }
                Choice(t("覆盖"), t("这台设备上的全部换成快照里的。换之前先自动备份一份。"), replace, Modifier.weight(1f)) { replace = true }
            }
            Text(problem ?: change(info, replace), style = YY.font(10.5f), color = if (problem == null) YY.c.t2 else YY.c.danger, modifier = Modifier.fillMaxWidth().padding(top = 12.dp))
            Spacer(Modifier.height(12.dp))
            YYButton(if (working) "…" else t("导入"), ButtonKind.Main, ButtonSize.Large, wide = true, enabled = !working) {
                working = true
                scope.launch {
                    try {
                        withContext(Dispatchers.IO) {
                            if (replace) library.core.makeSnapshot(File(snapshotsDir(), snapshotName(t("覆盖前"))).path, SnapshotParts(true, true, true, true, false))
                            library.core.restoreSnapshot(file.path, replace)
                        }
                        library.reload()
                        library.notesChanged()
                        library.note(Library.Toast.Icon.Check, t("快照导入好了"), "")
                        dismiss()
                    } catch (e: Exception) {
                        problem = Library.message(e)
                    }
                    working = false
                }
            }
        }
    }
}

@Composable
private fun Choice(title: String, detail: String, on: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Column(
        modifier.background(YY.c.card, RoundedCornerShape(14.dp)).border(if (on) 1.5.dp else 0.5.dp, if (on) YY.tint.accent else YY.c.line, RoundedCornerShape(14.dp))
            .clickable(onClick = onClick).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = YY.font(12f, FontWeight.SemiBold), color = YY.c.t1, modifier = Modifier.weight(1f))
            if (on) Icon(Icons.checkCircle, null, tint = YY.tint.accent, modifier = Modifier.size(16.dp))
        }
        Text(detail, style = YY.font(10f), color = YY.c.t2)
    }
}

/** What 合并 or 覆盖 would do to the counts that change, in a line (as on Apple). */
private fun change(info: SnapshotInfo, replace: Boolean): String {
    val after = if (replace) info.replaced else info.merged
    if (after == info.now && !replace) return t("这份快照里的，这台设备上都已经有了")
    val parts = mutableListOf<String>()
    if (info.parts.notes) parts += t("笔记 %@ → %@ 条", "${info.now.notes}", "${after.notes}")
    if (info.parts.words) parts += t("生词 %@ → %@ 个", "${info.now.words}", "${after.words}")
    if (parts.isEmpty() || after.books != info.now.books) parts.add(0, t("书 %@ → %@ 本", "${info.now.books}", "${after.books}"))
    return (if (replace) t("覆盖后：") else t("合并后：")) + parts.joinToString(t("，"))
}
