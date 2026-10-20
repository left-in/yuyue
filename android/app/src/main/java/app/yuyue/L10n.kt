package app.yuyue

import android.content.Context
import android.os.LocaleList
import org.json.JSONObject

/**
 * The interface's words. Code says `t("已导入 %lld 本书", n)`: the Chinese is the key, exactly as
 * in the Apple app's catalog (apple/Yuyue/Localizable.xcstrings), Swift format specifiers and
 * all, so both apps say the same thing. A Chinese system shows the key; any other gets the
 * English from assets/l10n/en.json (made from that catalog by scripts/l10n-android.py).
 */
object L10n {
    private var english: Map<String, Any>? = null

    /** Whether the interface speaks Chinese, as the core is told too. */
    var chinese = true
        private set

    fun load(context: Context) {
        val language = LocaleList.getDefault()[0]?.language ?: "zh"
        chinese = language == "zh"
        if (chinese) return
        val text = context.assets.open("l10n/en.json").bufferedReader().use { it.readText() }
        val json = JSONObject(text)
        english = buildMap {
            for (key in json.keys()) {
                when (val v = json.get(key)) {
                    is JSONObject -> put(key, v.keys().asSequence().associateWith { v.getString(it) })
                    else -> put(key, v.toString())
                }
            }
        }
    }

    fun get(key: String, args: Array<out Any?>): String {
        val found = english?.get(key)
        val pattern = when (found) {
            is String -> found
            is Map<*, *> -> {
                val n = args.firstOrNull { it is Number } as Number?
                (found[if (n?.toLong() == 1L) "one" else "other"] ?: found["other"]) as String
            }
            else -> key
        }
        if (args.isEmpty()) return pattern.replace("%%", "%")
        return String.format(kotlin(pattern), *args)
    }

    private val swiftSpec = Regex("""%(\d+\$)?([-+ 0#]*\d*(?:\.\d+)?)(lld|ld|llu|lu|u|@)""")

    /** Swift's specifiers as Java's: %@ → %s, %lld → %d. */
    private fun kotlin(p: String): String = swiftSpec.replace(p) { m ->
        val (pos, flags, kind) = m.destructured
        "%$pos$flags" + if (kind == "@") "s" else "d"
    }
}

/** The interface's words for `key` (Chinese, as in the Apple catalog), formatted with `args`. */
fun t(key: String, vararg args: Any?): String = L10n.get(key, args)
