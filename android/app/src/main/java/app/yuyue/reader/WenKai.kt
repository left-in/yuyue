package app.yuyue.reader

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.clickable
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.YuyueApp
import app.yuyue.design.YY
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * 霞鹜文楷 (排版 · 字体), as on Apple: too big to ship (two weights, about 28 MB), so it is
 * fetched from its own GitHub releases the first time it is chosen, into the core's fonts
 * folder, where the page loads it from (`/fonts/…`). Until it is here the page uses the serif.
 */
object WenKai {
    private val files = listOf("LXGWWenKaiLite-Regular.ttf", "LXGWWenKaiLite-Medium.ttf")
    private const val BASE = "https://github.com/lxgw/LxgwWenKai-Lite/releases/download/v1.530/"

    /** 0–1 while downloading. */
    var progress by mutableStateOf<Float?>(null)
        private set
    var failure by mutableStateOf<String?>(null)
        private set
    private var job: Job? = null
    /** Bumped when it arrives, for open pages to load again. */
    var version by mutableStateOf(0)
        private set

    private val dir: File get() = File(YuyueApp.instance.library.core.fontsDir())
    val installed: Boolean get() = files.all { File(dir, it).isFile }

    /** For showing the choice in its own face, once it is here. */
    val family: FontFamily? get() = if (installed) FontFamily(Font(File(dir, files[0]))) else null

    fun ensure() {
        if (installed || job != null) return
        failure = null
        progress = 0f
        val library = YuyueApp.instance.library
        job = library.scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    dir.mkdirs()
                    val http = OkHttpClient.Builder().readTimeout(60, TimeUnit.SECONDS).build()
                    files.forEachIndexed { i, name ->
                        val target = File(dir, name)
                        if (target.isFile) return@forEachIndexed
                        val temp = File(dir, "$name.part")
                        http.newCall(Request.Builder().url(BASE + name).build()).execute().use { r ->
                            if (!r.isSuccessful) throw java.io.IOException("HTTP ${r.code}")
                            val body = r.body!!
                            val total = body.contentLength().coerceAtLeast(1)
                            var done = 0L
                            temp.outputStream().use { out ->
                                body.byteStream().use { input ->
                                    val buffer = ByteArray(1 shl 16)
                                    while (true) {
                                        val n = input.read(buffer)
                                        if (n < 0) break
                                        out.write(buffer, 0, n)
                                        done += n
                                        progress = (i + done.toFloat() / total) / files.size
                                    }
                                }
                            }
                        }
                        temp.renameTo(target)
                    }
                }
                version++
            } catch (e: Exception) {
                failure = if (e is java.net.UnknownHostException) t("没有联网") else t("没下载下来")
            }
            progress = null
            job = null
        }
    }
}

/** Under 排版's fonts while 霞鹜文楷 is on its way, or when it didn't come. */
@Composable
fun WenKaiStatus(chosen: Boolean) {
    if (!chosen) return
    val p = WenKai.progress
    val f = WenKai.failure
    if (p != null) {
        Row(Modifier.padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            LinearProgressIndicator(progress = { p }, color = YY.tint.fill, trackColor = YY.c.inset, modifier = Modifier.width(90.dp))
            Text(t("霞鹜文楷正在下载 %lld%%", (p * 100).toInt()), fontSize = 11.sp, color = YY.c.t2)
        }
    } else if (f != null) {
        Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(t("霞鹜文楷%@", f), fontSize = 11.sp, color = YY.c.danger)
            Text(t("再试一次"), fontSize = 11.sp, color = YY.tint.accent, modifier = Modifier.clickable { WenKai.ensure() })
        }
    }
}
