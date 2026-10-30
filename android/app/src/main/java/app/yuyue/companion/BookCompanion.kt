package app.yuyue.companion

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.yuyue.reader.ReaderModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import uniffi.yuyue_core.Position
import uniffi.yuyue_core.YuyueCore
import java.io.File
import java.text.BreakIterator
import java.util.Locale
import java.util.UUID
import kotlin.math.abs
import kotlin.math.roundToInt

/** 与书对话 (prototype f94), as on Apple: by default only the part already read is handed to the
 *  model, so it can't give away what comes later; 问全书 lifts that. The sentences it gets are
 *  numbered, and the answer points back at them: 出处. */
class BookCompanion(private val model: ReaderModel) {
    enum class Scope { Read, Whole }

    data class Source(val section: Int, val sentence: Int, val page: Int?, val later: Boolean = false)

    data class Answer(val text: String, val sources: Map<Int, Source>, val label: String, val notYet: Boolean, val next: List<String>?)

    data class Turn(val question: String, val quote: String?, val scope: Scope, val answer: Answer? = null, val failed: String? = null, val id: String = UUID.randomUUID().toString())

    var scope by mutableStateOf(Scope.Read)
    val turns = mutableStateListOf<Turn>()
    /** The source being shown on the page. */
    var shown by mutableStateOf<Source?>(null)
        private set
    private var asking: Job? = null

    val busy: Boolean get() = turns.lastOrNull()?.let { it.answer == null && it.failed == null } ?: false

    fun clear() {
        asking?.cancel()
        turns.clear()
        shown = null
        model.pager.setSource(null)
    }

    /** Asks, in `scope` (the current one when null). Words chosen on the page go along as `quote`. */
    fun ask(question: String, quote: String? = null, scope: Scope? = null) {
        val q = question.trim()
        if (q.isEmpty() || busy) return
        val scope = scope ?: this.scope
        val config = CompanionConfig.current
        turns += Turn(q, quote, scope)
        val index = turns.lastIndex
        if (config == null || !config.isReady) {
            turns[index] = turns[index].copy(failed = app.yuyue.t("书伴还没接上：在设置 · 书伴里添加一个服务商"))
            return
        }
        val core = model.core
        val book = model.bookID
        val detail = model.detail
        val here = model.pager.here() ?: Position((detail?.start ?: 0u), 0u)
        val earlier = turns.take(index).takeLast(2).mapNotNull { t -> t.answer?.let { t.question to it.text } }
        val cacheKey = listOf(scope.name.lowercase(), if (scope == Scope.Read) "${here.section}" else "", quote ?: "", q).joinToString("|")
        cache()[cacheKey]?.let { turns[index] = turns[index].copy(answer = it); return }
        asking = model.library.scope.launch {
            val excerpts = withContext(Dispatchers.IO) { excerpts(core, book, q + " " + (quote ?: ""), if (scope == Scope.Read) here else null) }
            val title = detail?.summary?.title ?: ""
            val percent = (model.fraction(here.section.toInt(), here.sentence.toInt()) * 100).roundToInt()
            var system = "你是「语阅」里的书伴，陪读者读《$title》${detail?.summary?.authors?.firstOrNull()?.let { "（$it）" } ?: ""}。\n"
            system += when (scope) {
                Scope.Read -> """
                    读者现在读到全书的 $percent%。
                    规则：
                    1. 只根据下面给出的原文片段回答。不要用你知道的、这本书后面的情节，不要剧透。
                    2. 用${app.yuyue.companion.Companion.replyLanguage}，口语，简短，一般三到五句话。
                    3. 说到原文里的内容时，在那句话后面写上片段编号，比如 [2]。只用给出的编号。
                    4. 如果这些片段不够回答，或者答案在读者还没读到的地方，只回答三个字：没读到
                    5. 能回答的话，最后另起一行，写"接着问："，后面是读者可能想接着问的两个短问题，用"｜"隔开。
                    """.trimIndent()
                Scope.Whole -> """
                    读者想用整本书来回答，不介意提前知道后面的情节。
                    规则：
                    1. 可以用整本书的内容，也可以结合你对这本书的了解。
                    2. 用${app.yuyue.companion.Companion.replyLanguage}，口语，简短，一般三到五句话。
                    3. 说到下面原文片段里的内容时，在那句话后面写上片段编号，比如 [2]。只用给出的编号。
                    4. 最后另起一行，写"接着问："，后面是读者可能想接着问的两个短问题，用"｜"隔开。
                    """.trimIndent()
            }
            val prompt = buildString {
                if (earlier.isNotEmpty()) append("之前的对话：\n" + earlier.joinToString("\n") { "读者：${it.first}\n书伴：${it.second}" } + "\n\n")
                append("原文片段：\n")
                excerpts.forEachIndexed { n, e ->
                    val chapter = detail?.let { ReaderModel.chapterTitle(it, e.section) }?.let { "（$it）" } ?: ""
                    append("[${n + 1}]$chapter${e.text}\n")
                }
                quote?.let { append("\n读者选中的句子：「$it」\n") }
                append("\n读者问：$q")
            }
            try {
                val (text, next) = split(app.yuyue.companion.Companion.answer(config, system, prompt))
                val notYet = scope == Scope.Read && text.startsWith("没读到")
                val used = citations(text).toSet()
                val sources = excerpts.withIndex().filter { (it.index + 1) in used }.associate { (n, e) ->
                    val later = scope == Scope.Whole && (e.section > here.section.toInt() || (e.section == here.section.toInt() && e.sentence > here.sentence.toInt() + 8))
                    (n + 1) to Source(e.section, e.sentence, model.estimatedPage(e.section, e.sentence), later)
                }
                val answer = Answer(text, sources, config.label, notYet, if (notYet || next.isEmpty()) null else next)
                if (index in turns.indices) turns[index] = turns[index].copy(answer = answer)
                store(cacheKey, answer)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                if (index in turns.indices) turns[index] = turns[index].copy(failed = app.yuyue.companion.Companion.message(e))
            }
        }
    }

    /** 出处: the page goes there and the sentence is washed in the accent. */
    fun show(s: Source) {
        shown = s
        model.jump(s.section, s.sentence)
        model.pager.setSource(Position(s.section.toUInt(), s.sentence.toUInt()))
    }

    // MARK: Finding the sentences

    class Excerpt(val section: Int, val sentence: Int, val text: String)

    /** Up to a dozen numbered sentences (with a little around each) to answer from: the ones
     *  sharing the most words with the question, then the last few read. With `upTo`, nothing after it. */
    private fun excerpts(core: YuyueCore, book: String, question: String, upTo: Position?): List<Excerpt> {
        val words = mutableSetOf<String>()
        val it = BreakIterator.getWordInstance(Locale.getDefault()).apply { setText(question) }
        var start = it.first()
        var end = it.next()
        while (end != BreakIterator.DONE) {
            val w = question.substring(start, end).lowercase()
            val latin = w.all { c -> c.code < 128 }
            if ((if (latin) w.length >= 3 else w.length >= 2) && w.any { c -> c.isLetterOrDigit() } && w !in stopWords) words += w
            start = end
            end = it.next()
        }
        val cache = mutableMapOf<Int, List<String>>()
        fun text(section: Int) = cache.getOrPut(section) { runCatching { core.sentences(book, section.toUInt()) }.getOrDefault(emptyList()) }
        fun allowed(section: Int, sentence: Int): Boolean {
            val u = upTo ?: return true
            return section < u.section.toInt() || (section == u.section.toInt() && sentence <= u.sentence.toInt() + 8)
        }
        val score = mutableMapOf<String, Triple<Int, Int, Int>>()
        for (w in words) {
            for (h in runCatching { core.searchBook(book, w) }.getOrDefault(emptyList())) {
                val s = h.section.toInt()
                val n = h.sentence.toInt()
                if (!allowed(s, n)) continue
                val key = "$s/$n"
                score[key] = Triple((score[key]?.first ?: 0) + 1, s, n)
            }
        }
        val picked = mutableListOf<Pair<Int, Int>>()
        for ((_, s, n) in score.values.sortedWith(compareByDescending<Triple<Int, Int, Int>> { it.first }.thenByDescending { it.second }.thenByDescending { it.third })) {
            if (picked.size >= 8) break
            if (picked.any { it.first == s && abs(it.second - n) <= 2 }) continue
            picked += s to n
        }
        // The page being read: what "这句" and "刚才" are about.
        upTo?.let { u ->
            val section = u.section.toInt()
            val last = u.sentence.toInt() + 3
            var s = last
            while (s >= maxOf(0, last - 12)) {
                if (s < text(section).size && picked.none { it.first == section && abs(it.second - s) <= 2 }) picked += section to s
                s -= 4
            }
        }
        return picked.sortedWith(compareBy({ it.first }, { it.second })).mapNotNull { (section, sentence) ->
            val all = text(section)
            if (sentence !in all.indices) return@mapNotNull null
            // A space between sentences: English ones would run together otherwise.
            val joined = all.subList(maxOf(0, sentence - 1), minOf(all.size, sentence + 2)).joinToString(" ") { it.trim() }.replace("\n", " ")
            Excerpt(section, sentence, joined.take(240))
        }
    }

    // MARK: Kept answers

    /** 按"书 + 章节"缓存: the same question at the same place costs nothing the second time. */
    private val file: File get() = File(model.library.dataDir, "companion/${model.bookID}.json")

    private fun cache(): Map<String, Answer> = runCatching {
        val j = JSONObject(file.readText())
        j.keys().asSequence().associateWith { k ->
            val a = j.getJSONObject(k)
            val src = a.optJSONObject("sources") ?: JSONObject()
            Answer(
                a.getString("text"),
                src.keys().asSequence().associate { n ->
                    val s = src.getJSONObject(n)
                    n.toInt() to Source(s.getInt("section"), s.getInt("sentence"), if (s.has("page")) s.getInt("page") else null, s.optBoolean("later"))
                },
                a.optString("label"), a.optBoolean("notYet"),
                a.optJSONArray("next")?.let { arr -> (0 until arr.length()).map { arr.getString(it) } },
            )
        }
    }.getOrDefault(emptyMap())

    private fun store(key: String, a: Answer) {
        val all = runCatching { JSONObject(file.readText()) }.getOrDefault(JSONObject())
        val src = JSONObject()
        for ((n, s) in a.sources) src.put("$n", JSONObject().put("section", s.section).put("sentence", s.sentence).put("later", s.later).apply { s.page?.let { put("page", it) } })
        all.put(key, JSONObject().put("text", a.text).put("sources", src).put("label", a.label).put("notYet", a.notYet).apply { a.next?.let { put("next", org.json.JSONArray(it)) } })
        file.parentFile?.mkdirs()
        file.writeText(all.toString())
    }

    companion object {
        /** The answer, and the 接着问 line taken off its end. */
        fun split(reply: String): Pair<String, List<String>> {
            val lines = reply.split("\n").toMutableList()
            val i = lines.indexOfLast { "接着问" in it }
            if (i < 0) return reply to emptyList()
            val line = lines.removeAt(i)
            val asks = line.substringAfterLast("接着问").trim('：', ':', ' ', '*').split('｜', '|').map { it.trim() }.filter { it.isNotEmpty() }
            return lines.joinToString("\n").trim() to asks.take(2)
        }

        fun citations(text: String): List<Int> = Regex("""\[(\d+)]""").findAll(text).mapNotNull { it.groupValues[1].toIntOrNull() }.toList()

        private val stopWords = setOf(
            "什么", "为什么", "怎么", "怎么样", "怎样", "如何", "哪里", "哪儿", "哪个", "谁", "是不是", "有没有",
            "这个", "那个", "这些", "那些", "这里", "那里", "这本书", "本书", "这本", "这章", "这一章", "一章",
            "意思", "后来", "之后", "以后", "现在", "时候", "为何", "是否", "可以", "能不能", "一个", "一下",
            "他们", "她们", "我们", "你们", "自己", "就是", "还是", "但是", "因为", "所以", "然后", "发生",
            "the", "and", "what", "why", "how", "who", "does", "did", "this", "that", "with", "about",
        )
    }
}
