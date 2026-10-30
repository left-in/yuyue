package app.yuyue.companion

import app.yuyue.L10n
import app.yuyue.R
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
 *  a service the reader added with their own key, or a model of their own (Ollama). No service
 *  of ours sits in between; keys stay on this device, encrypted, and are not synced.
 *  添加服务商 picks from [catalog], grouped by how it's reached as nanobot's webui groups them
 *  ([Group]), or adds one of the reader's own (any OpenAI-shaped address). The logos are LobeHub
 *  Icons, from shared/provider-icons (scripts/provider-icons.py). */
data class CompanionProvider(
    val id: String,
    val title: String,
    val anthropic: Boolean = false,
    val group: Group = Group.Key,
    /** Who the bill goes to, for the key form. */
    val account: String = "",
    val defaultModel: String = "",
    val defaultURL: String? = null,
    val keyHint: String = "sk-…",
    /** What else it's searched by: its company, its Chinese name. */
    val aliases: String = "",
    /** A line under its name in 添加服务商. */
    val blurb: String? = null,
    /** Sent when no key is filled in: magpie's gateway takes any. */
    val defaultKey: String = "",
) {
    /** Its group in 添加服务商: how it's reached. */
    enum class Group {
        /** Signed in to on its own page (OpenRouter's sign-in for apps); a key can still be pasted. */
        SignIn,
        Key,
        /** A model or gateway on a computer on the network: Ollama, LM Studio, magpie. */
        Local;

        val title: String get() = when (this) { SignIn -> t("登录账号"); Key -> "API Key"; Local -> t("本机和局域网") }
    }

    val local: Boolean get() = group == Group.Local
    val isCustom: Boolean get() = id.startsWith("custom.")

    /** Local models and the reader's own addresses may go without. */
    val needsKey: Boolean get() = !local && !isCustom
    val modelHint: String get() = defaultModel.ifEmpty { t("比如 qwen3:8b") }
    val urlHint: String get() = defaultURL ?: when {
        id == "magpie" -> t("比如 http://192.168.1.5:3425/v1")
        local -> t("比如 http://192.168.1.5:11434/v1")
        else -> "https://…/v1"
    }

    /** Its logo (res/drawable/provider_<id>.xml), and whether it takes the text colour. */
    val logo: Int? get() = LOGOS[id]
    val logoTinted: Boolean get() = id in TINTED

    /** The first letter, on its little square. */
    val mark: String get() = title.take(1).uppercase()

    companion object {
        /** What 添加服务商 offers, in its order. The OpenAI-shaped ones differ only in address. On a
         *  phone "localhost" is the phone, so Ollama's address is left to fill. */
        val catalog: List<CompanionProvider> get() = listOf(
            CompanionProvider("openrouter", "OpenRouter", group = Group.SignIn, account = "OpenRouter", defaultModel = "openrouter/auto",
                defaultURL = "https://openrouter.ai/api/v1/", keyHint = "sk-or-…", blurb = t("登录就能用，几百个模型一个账号")),
            CompanionProvider("claude", "Claude", anthropic = true, account = "Anthropic", defaultModel = "claude-opus-5-5",
                defaultURL = "https://api.anthropic.com/v1/", keyHint = "sk-ant-…", aliases = "anthropic 克劳德"),
            CompanionProvider("openai", "OpenAI", account = "OpenAI", defaultModel = "gpt-5-mini",
                defaultURL = "https://api.openai.com/v1/", aliases = "chatgpt gpt"),
            CompanionProvider("gemini", "Gemini", account = "Google", defaultModel = "gemini-2.5-flash",
                defaultURL = "https://generativelanguage.googleapis.com/v1beta/openai/", keyHint = "AIza…", aliases = "google 谷歌"),
            CompanionProvider("deepseek", "DeepSeek", account = "DeepSeek", defaultModel = "deepseek-chat",
                defaultURL = "https://api.deepseek.com/v1/", aliases = "深度求索"),
            CompanionProvider("dashscope", t("通义千问"), account = t("阿里云百炼"), defaultModel = "qwen-plus",
                defaultURL = "https://dashscope.aliyuncs.com/compatible-mode/v1/", aliases = "qwen 阿里 百炼 dashscope"),
            CompanionProvider("moonshot", "Kimi", account = t("月之暗面"), defaultModel = "kimi-k2-turbo-preview",
                defaultURL = "https://api.moonshot.cn/v1/", aliases = "moonshot 月之暗面"),
            CompanionProvider("zhipu", t("智谱 GLM"), account = t("智谱"), defaultModel = "glm-4.6",
                defaultURL = "https://open.bigmodel.cn/api/paas/v4/", aliases = "zhipu glm z.ai 清言"),
            CompanionProvider("volcengine", t("豆包"), account = t("火山引擎"), defaultModel = "doubao-seed-1-6-250615",
                defaultURL = "https://ark.cn-beijing.volces.com/api/v3/", aliases = "doubao 火山引擎 volcengine 字节"),
            CompanionProvider("siliconflow", t("硅基流动"), account = t("硅基流动"), defaultModel = "deepseek-ai/DeepSeek-V3",
                defaultURL = "https://api.siliconflow.cn/v1/", aliases = "siliconflow"),
            CompanionProvider("minimax", "MiniMax", account = "MiniMax", defaultModel = "MiniMax-M2",
                defaultURL = "https://api.minimaxi.com/v1/", aliases = "海螺 稀宇"),
            CompanionProvider("xai", "Grok", account = "xAI", defaultModel = "grok-4", defaultURL = "https://api.x.ai/v1/", keyHint = "xai-…", aliases = "xai"),
            CompanionProvider("mistral", "Mistral", account = "Mistral", defaultModel = "mistral-small-latest", defaultURL = "https://api.mistral.ai/v1/", keyHint = ""),
            CompanionProvider("groq", "Groq", account = "Groq", defaultModel = "llama-3.3-70b-versatile",
                defaultURL = "https://api.groq.com/openai/v1/", keyHint = "gsk_…"),
            CompanionProvider("magpie", "magpie", group = Group.Local, keyHint = t("局域网里用才要填网关 Key"), aliases = "喜鹊 网关 gateway",
                blurb = t("转接你在 magpie 里登录的 Claude、ChatGPT 账号"), defaultKey = "magpie"),
            CompanionProvider("ollama", "Ollama", group = Group.Local, keyHint = t("不用填")),
            CompanionProvider("lmstudio", "LM Studio", group = Group.Local, keyHint = t("不用填")),
        )

        private val LOGOS = mapOf(
            "claude" to R.drawable.provider_claude, "openai" to R.drawable.provider_openai, "gemini" to R.drawable.provider_gemini,
            "deepseek" to R.drawable.provider_deepseek, "dashscope" to R.drawable.provider_dashscope, "moonshot" to R.drawable.provider_moonshot,
            "zhipu" to R.drawable.provider_zhipu, "volcengine" to R.drawable.provider_volcengine, "siliconflow" to R.drawable.provider_siliconflow,
            "minimax" to R.drawable.provider_minimax, "openrouter" to R.drawable.provider_openrouter, "xai" to R.drawable.provider_xai,
            "mistral" to R.drawable.provider_mistral, "groq" to R.drawable.provider_groq, "ollama" to R.drawable.provider_ollama,
            "lmstudio" to R.drawable.provider_lmstudio, "magpie" to R.drawable.provider_magpie,
        )
        private val TINTED = setOf("openai", "moonshot", "openrouter", "xai", "groq", "ollama", "lmstudio", "magpie")

        /** One of the reader's own: any OpenAI-shaped address, under a name they give it. */
        fun custom(title: String, id: String = "custom." + java.util.UUID.randomUUID().toString().take(8)) =
            CompanionProvider(id, title, keyHint = t("可不填"))

        /** A catalog entry or one of the reader's own, by its id. */
        fun find(id: String): CompanionProvider? =
            catalog.firstOrNull { it.id == id }
                ?: Prefs.string("companion.name.$id").takeIf { id.startsWith("custom.") && it.isNotEmpty() }?.let { custom(it, id) }

        private val addedIds: List<String> get() { migrate(); return Prefs.string("companion.added").split(',').filter { it.isNotEmpty() } }

        /** The services the reader added, in the order they were added. */
        val added: List<CompanionProvider> get() = addedIds.mapNotNull(::find)

        internal fun setAdded(ids: List<String>) = Prefs.set("companion.added", ids.joinToString(","))

        /** [catalog] less what's already added, matching what's typed in its name, id or aliases. */
        fun available(query: String): List<CompanionProvider> {
            val taken = addedIds.toSet()
            val q = query.lowercase().filterNot { it in " -_." }
            return catalog.filter { p -> p.id !in taken && (q.isEmpty() || "${p.id}${p.title}${p.aliases}".lowercase().filterNot { it == ' ' }.contains(q)) }
        }

        /** Before 添加服务商 every service had its row and a key was simply filled in. Those with
         *  a key are now added; what was 「OpenAI 兼容接口」 becomes one of the reader's own. */
        private fun migrate() {
            if (Prefs.shared.contains("companion.added")) return
            val ids = listOf("claude", "deepseek", "gemini").filter { !Keys.read("companion.key.$it").isNullOrEmpty() }.toMutableList()
            val url = Prefs.string("companion.url.openai")
            if (url.isNotEmpty()) {
                val id = "custom.openai"
                Prefs.set("companion.name.$id", t("OpenAI 兼容接口"))
                Prefs.set("companion.url.$id", url)
                Prefs.set("companion.model.$id", Prefs.string("companion.model.openai"))
                Keys.read("companion.key.openai")?.let { Keys.write("companion.key.$id", it) }
                if (Prefs.string("companion.provider") == "openai") Prefs.set("companion.provider", id)
                ids += id
            }
            Prefs.set("companion.url.openai", null)
            Prefs.set("companion.model.openai", null)
            Keys.delete("companion.key.openai")
            setAdded(ids)
        }
    }
}

/** The chosen engine and how to reach it. */
data class CompanionConfig(val provider: CompanionProvider, val key: String, val model: String, val url: String) {
    /** Its key and address are in: enough to add it, and to list its models. */
    val isConnected: Boolean
        get() = (if (url.isEmpty()) provider.defaultURL != null else url.startsWith("http")) &&
            (!provider.needsKey || key.isNotEmpty()) && provider.title.isNotEmpty()

    /** Filled in enough to ask: connected, and a model chosen. */
    val isReady: Boolean get() = isConnected && model.isNotEmpty()

    /** What goes in the request: the key typed in, or the one the service takes without one. */
    val sentKey: String get() = key.ifEmpty { provider.defaultKey }

    /** "DeepSeek · deepseek-chat": under each answer. */
    val label: String get() = "${provider.title} · $model"

    /** "sk-ant-…3f9a": the saved key, shown without giving it away. */
    val maskedKey: String get() = if (key.length <= 8) "•".repeat(key.length) else (if (key.startsWith("sk-")) "sk-" else "") + "…" + key.takeLast(4)

    /** Adds the service, or keeps the changes to one added before. */
    fun save() {
        val id = provider.id
        if (provider.isCustom) Prefs.set("companion.name.$id", provider.title)
        Prefs.set("companion.model.$id", model)
        Prefs.set("companion.url.$id", url)
        if (key.isEmpty()) Keys.delete("companion.key.$id") else Keys.write("companion.key.$id", key)
        val ids = CompanionProvider.added.map { it.id }
        if (id !in ids) CompanionProvider.setAdded(ids + id)
    }

    /** Saves it and makes it the one that answers: a service just added answers from now on. */
    fun choose() {
        save()
        Prefs.set("companion.provider", provider.id)
    }

    companion object {
        /** The one answering: the chosen one, else the first added. Null before any is added. */
        val current: CompanionConfig?
            get() {
                val added = CompanionProvider.added
                return (added.firstOrNull { it.id == Prefs.string("companion.provider") } ?: added.firstOrNull())?.let(::saved)
            }

        /** What was filled in for a provider before, or its defaults. */
        fun saved(p: CompanionProvider) = CompanionConfig(
            p, Keys.read("companion.key.${p.id}") ?: "",
            Prefs.string("companion.model.${p.id}").ifEmpty { p.defaultModel },
            Prefs.string("companion.url.${p.id}"),
        )

        /** Forgets the service and its key. */
        fun remove(p: CompanionProvider) {
            CompanionProvider.setAdded(CompanionProvider.added.map { it.id }.filter { it != p.id })
            for (k in listOf("model", "url", "name")) Prefs.set("companion.$k.${p.id}", null)
            Keys.delete("companion.key.${p.id}")
            if (Prefs.string("companion.provider") == p.id) Prefs.set("companion.provider", null)
        }
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
        if (!config.isReady) throw CompanionError(t("书伴还没接上：在设置 · 书伴里添加一个服务商"))
        val base = base(config)
        val text = if (config.provider.anthropic) {
            val body = JSONObject().put("model", config.model).put("max_tokens", 1024).put("system", system)
                .put("messages", JSONArray().put(JSONObject().put("role", "user").put("content", prompt)))
            val r = Request.Builder().url(base + "messages").post(body.toString().toRequestBody(json))
                .header("x-api-key", config.sentKey).header("anthropic-version", "2023-06-01").build()
            val out = send(r)
            val blocks = out.optJSONArray("content") ?: JSONArray()
            (0 until blocks.length()).joinToString("") { blocks.getJSONObject(it).optString("text") }
        } else {
            // OpenAI, DeepSeek, Gemini (its OpenAI-shaped endpoint), Ollama and the rest.
            val body = JSONObject().put("model", config.model).put("temperature", 0.3)
                .put("messages", JSONArray().put(JSONObject().put("role", "system").put("content", system)).put(JSONObject().put("role", "user").put("content", prompt)))
            val b = Request.Builder().url(base + "chat/completions").post(body.toString().toRequestBody(json))
            if (config.sentKey.isNotEmpty()) b.header("Authorization", "Bearer ${config.sentKey}")
            val out = send(b.build())
            out.optJSONArray("choices")?.optJSONObject(0)?.optJSONObject("message")?.optString("content") ?: ""
        }
        text.trim().ifEmpty { throw CompanionError(t("没有回答，换个问法试试")) }
    }

    /** The models the service lists (`GET …/models`, the same shape from Anthropic, OpenAI and the
     *  rest), for the 模型 menu. Ollama, LM Studio and magpie list what's there to use. */
    suspend fun models(config: CompanionConfig): List<String> = withContext(Dispatchers.IO) {
        val b = Request.Builder().url(base(config) + "models")
        if (config.provider.anthropic) b.header("x-api-key", config.sentKey).header("anthropic-version", "2023-06-01")
        else if (config.sentKey.isNotEmpty()) b.header("Authorization", "Bearer ${config.sentKey}")
        val out = send(b.build())
        val list = out.optJSONArray("data") ?: out.optJSONArray("models") ?: JSONArray()
        (0 until list.length()).mapNotNull { i ->
            list.optJSONObject(i)?.let { it.optString("id").ifEmpty { it.optString("name") } }?.ifEmpty { null }?.removePrefix("models/")
        }
    }

    private fun base(config: CompanionConfig) = (config.url.trim().ifEmpty { config.provider.defaultURL ?: "" }).let { if (it.endsWith("/")) it else "$it/" }

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
