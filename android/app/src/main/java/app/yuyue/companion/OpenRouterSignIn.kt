package app.yuyue.companion

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Base64
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.net.ServerSocket
import java.net.URLDecoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID

/** 用 OpenRouter 登录, as on Apple: OpenRouter's sign-in for apps (PKCE,
 *  openrouter.ai/docs/guides/overview/auth/oauth). Its page opens in the browser and sends it back
 *  to `http://localhost:<port>/callback?code=…`, which a socket here answers; the code, with the
 *  verifier only this run knows, is traded for a key of the reader's own. OpenRouter documents
 *  localhost callbacks on any port, not custom schemes, hence the socket. */
object OpenRouterSignIn {
    /** Signs in and returns the new key. Waits up to ten minutes, as long as OpenRouter's code lives. */
    suspend fun run(context: Context): String = withContext(Dispatchers.IO) {
        val verifier = base64(ByteArray(32).also { SecureRandom().nextBytes(it) })
        val challenge = base64(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))
        val state = UUID.randomUUID().toString()
        val code = ServerSocket(0).use { server ->
            server.soTimeout = 10 * 60 * 1000
            val auth = Uri.parse("https://openrouter.ai/auth").buildUpon()
                .appendQueryParameter("callback_url", "http://localhost:${server.localPort}/callback")
                .appendQueryParameter("code_challenge", challenge)
                .appendQueryParameter("code_challenge_method", "S256")
                .appendQueryParameter("state", state)
                .appendQueryParameter("key_label", t("语阅 · 书伴"))
                .build()
            withContext(Dispatchers.Main) {
                context.startActivity(Intent(Intent.ACTION_VIEW, auth).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            var found: String? = null
            while (found == null) {
                server.accept().use { socket ->
                    val line = socket.getInputStream().bufferedReader().readLine() ?: ""
                    val target = line.split(' ').getOrNull(1) ?: ""
                    val query = target.substringAfter('?', "").split('&').associate {
                        URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('=', ""), "UTF-8")
                    }
                    val ok = target.startsWith("/callback") && query["state"] == state && !query["code"].isNullOrEmpty()
                    // A button back: Chrome opens an intent: link on a tap.
                    val back = "intent:#Intent;action=android.intent.action.MAIN;category=android.intent.category.LAUNCHER;package=${context.packageName};end"
                    val page = (if (ok) t("已经登录 OpenRouter，可以回到语阅了。") else t("没有登录成功，回到语阅再试一次。")) +
                        "<p><a href=\"$back\" style=\"display:inline-block;margin-top:20px;padding:12px 22px;border-radius:999px;background:#2B4C7E;color:#fff;text-decoration:none\">${t("回到语阅")}</a>"
                    val body = "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><body style='font:16px sans-serif;padding:48px 24px;text-align:center'>$page"
                        .toByteArray()
                    socket.getOutputStream().apply {
                        write("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
                        write(body)
                        flush()
                    }
                    if (target.startsWith("/callback")) found = if (ok) query["code"] else throw CompanionError(t("OpenRouter 没给 Key，再登录一次"))
                }
            }
            found!!
        }
        val body = JSONObject().put("code", code).put("code_verifier", verifier).put("code_challenge_method", "S256")
        val request = Request.Builder().url("https://openrouter.ai/api/v1/auth/keys")
            .post(body.toString().toRequestBody("application/json".toMediaType())).build()
        OkHttpClient().newCall(request).execute().use { response ->
            val key = runCatching { JSONObject(response.body?.string() ?: "").optString("key") }.getOrDefault("")
            if (!response.isSuccessful || key.isEmpty()) throw CompanionError(t("OpenRouter 没给 Key，再登录一次"))
            key
        }
    }

    private fun base64(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
}
