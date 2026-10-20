package app.yuyue.companion

import app.yuyue.L10n
import app.yuyue.design.Prefs
import app.yuyue.library.Keys
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit

/** Where 书伴's answers come from (FEATURES §3.8), as on Apple, less Apple's on-device model:
 *  the user's own key with one of a few services, or a model of their own (Ollama). No
 *  service of ours sits in between; keys stay on this device, encrypted, and are not synced. */
enum class CompanionProvider(val key: String) {
    Claude("claude"), DeepSeek("deepseek"), Gemini("gemini"), OpenAI("openai");

    val title: String get() = when (this) { Claude -> "Claude"; DeepSeek -> "DeepSeek"; Gemini -> "Gemini"; OpenAI -> t("OpenAI 兼容接口") }
    val detail: String? get() = if (this == OpenAI) t("可以接 Ollama 和自己部署的模型") else null
    val needsKey: Boolean get() = this != OpenAI
    val defaultModel: String get() = when (this) { Claude -> "claude-opus-5-5"; DeepSeek -> "deepseek-chat"; Gemini -> "gemini-2.5-flash"; OpenAI -> "" }
    val defaultURL: String? get() = when (this) {
        Claude -> "https://api.anthropic.com/v1/"
        DeepSeek -> "https://api.deepseek.com/v1/"
        Gemini -> "https://generativelanguage.googleapis.com/v1beta/openai/"
        OpenAI -> null
    }
    val keyHint: String get() = when (this) { Claude -> "sk-ant-…"; Gemini -> "AIza…"; OpenAI -> t("Ollama 不用填"); else -> "sk-…" }
}

/** The chosen engine and how to reach it. */
data class CompanionConfig(val provider: CompanionProvider, val key: String, val model: String, val url: String) {
    /** Filled in enough to ask. */
    val isReady: Boolean
        get() = when (provider) {
            CompanionProvider.OpenAI -> url.startsWith("http") && model.isNotEmpty()
            else -> key.isNotEmpty() && model.isNotEmpty()
        }

    /** "DeepSeek · deepseek-chat": under each answer. */
    val label: String get() = if (provider == CompanionProvider.OpenAI) model else "${provider.title} · $model"

    fun save() {
        Prefs.set("companion.provider", provider.key)
        Prefs.set("companion.model.${provider.key}", model)
        Prefs.set("companion.url.${provider.key}", url)
        if (key.isEmpty()) Keys.delete("companion.key.${provider.key}") else Keys.write("companion.key.${provider.key}", key)
    }

    companion object {
        /** Set up at all: a provider was chosen once. */
        val chosen: Boolean get() = Prefs.string("companion.provider").isNotEmpty()

        val current: CompanionConfig
            get() = saved(CompanionProvider.entries.firstOrNull { it.key == Prefs.string("companion.provider") } ?: CompanionProvider.Claude)

        /** What was filled in for a provider before, or its defaults. */
        fun saved(p: CompanionProvider) = CompanionConfig(
            p, Keys.read("companion.key.${p.key}") ?: "",
            Prefs.string("companion.model.${p.key}").ifEmpty { p.defaultModel },
            Prefs.string("companion.url.${p.key}"),
        )
    }
}

class CompanionError(message: String) : Exception(message)

object Companion {
    /** The language the companion answers in: the interface's. The prompts stay Chinese, and so
     *  do the markers in them (没读到, 接着问) that the replies are read back by. */
    val replyLanguage: String get() = if (L10n.chinese) "简体中文" else "英文（English）"

    private val http = OkHttpClient.Builder().connectTimeout(20, TimeUnit.SECONDS).readTimeout(120, TimeUnit.SECONDS).build()
    private val json = "application/json".toMediaType()

    /** One answer: `system` says how to behave, `prompt` carries the excerpts and the question. */
    suspend fun answer(config: CompanionConfig, system: String, prompt: String): String = withContext(Dispatchers.IO) {
        if (!config.isReady) throw CompanionError(t("书伴还没接上：在设置 · 书伴里选一个"))
        val base = (config.url.trim().ifEmpty { config.provider.defaultURL ?: "" }).let { if (it.endsWith("/")) it else "$it/" }
        val text = if (config.provider == CompanionProvider.Claude) {
            val body = JSONObject().put("model", config.model).put("max_tokens", 1024).put("system", system)
                .put("messages", JSONArray().put(JSONObject().put("role", "user").put("content", prompt)))
            val r = Request.Builder().url(base + "messages").post(body.toString().toRequestBody(json))
                .header("x-api-key", config.key).header("anthropic-version", "2023-06-01").build()
            val out = send(r)
            val blocks = out.optJSONArray("content") ?: JSONArray()
            (0 until blocks.length()).joinToString("") { blocks.getJSONObject(it).optString("text") }
        } else {
            // DeepSeek, Gemini (its OpenAI-shaped endpoint), Ollama and the rest.
            val body = JSONObject().put("model", config.model).put("temperature", 0.3)
                .put("messages", JSONArray().put(JSONObject().put("role", "system").put("content", system)).put(JSONObject().put("role", "user").put("content", prompt)))
            val b = Request.Builder().url(base + "chat/completions").post(body.toString().toRequestBody(json))
            if (config.key.isNotEmpty()) b.header("Authorization", "Bearer ${config.key}")
            val out = send(b.build())
            out.optJSONArray("choices")?.optJSONObject(0)?.optJSONObject("message")?.optString("content") ?: ""
        }
        text.trim().ifEmpty { throw CompanionError(t("没有回答，换个问法试试")) }
    }

    private fun send(r: Request): JSONObject {
        http.newCall(r).execute().use { response ->
            val raw = response.body?.string() ?: ""
            val out = runCatching { JSONObject(raw) }.getOrDefault(JSONObject())
            if (response.isSuccessful) return out
            val error = out.optJSONObject("error")
            val message = error?.optString("message")?.ifEmpty { null } ?: out.optString("message").ifEmpty { null }
            val kind = "${error?.optString("type")} ${error?.optString("code")} $message".lowercase()
            val code = response.code
            throw CompanionError(when {
                code == 401 || code == 403 -> t("Key 不对，去设置 · 书伴里重新填")
                code == 402 -> t("账号余额不够了")
                code == 429 && ("quota" in kind || "credit" in kind || "balance" in kind) -> t("账号余额不够了")
                code == 429 || code == 529 -> t("问得太快了，等一会儿再问")
                code == 400 && ("credit" in kind || "balance" in kind) -> t("账号余额不够了")
                message != null -> t("服务器回了 %lld：%@", code, message)
                else -> t("服务器回了 %lld", code)
            })
        }
    }

    fun message(e: Throwable): String = when (e) {
        is CompanionError -> e.message ?: t("出错了")
        is UnknownHostException, is ConnectException -> t("连不上服务器，看看接口地址")
        is SocketTimeoutException -> t("等太久没回答，再问一次")
        else -> e.localizedMessage ?: e.toString()
    }
}
