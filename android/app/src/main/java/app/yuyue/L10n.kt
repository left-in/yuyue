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
                    is JSONObject if v.has("subs") -> put(key, Counted(v.getString("text"), v.getJSONObject("subs").let { subs ->
                        subs.keys().asSequence().associateWith { name ->
                            subs.getJSONArray(name).let { Counted.Sub(it.getInt(0), it.getString(1), it.getString(2), it.getString(3)) }
                        }
                    }))
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
            is Counted -> found.pattern(args)
            is Map<*, *> -> {
                val n = args.firstOrNull { it is Number } as Number?
                (found[if (n?.toLong() == 1L) "one" else "other"] ?: found["other"]) as String
            }
            else -> key
        }
        if (args.isEmpty()) return pattern.replace("%%", "%")
        return String.format(kotlin(pattern), *args)
    }

    /** A key with several counts, each worded on its own: `%#@n@` in `text` becomes `n`'s one or
     *  other, with `%arg` as its argument. */
    private class Counted(val text: String, val subs: Map<String, Sub>) {
        class Sub(val arg: Int, val spec: String, val one: String, val other: String)

        fun pattern(args: Array<out Any?>): String = Regex("""%#@(\w+)@""").replace(text) { m ->
            val sub = subs[m.groupValues[1]] ?: return@replace m.value
            val n = (args.getOrNull(sub.arg - 1) as? Number)?.toLong()
            (if (n == 1L) sub.one else sub.other).replace("%arg", "%${sub.arg}\$${sub.spec}")
        }
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
