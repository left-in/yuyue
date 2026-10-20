package app.yuyue.reader

import android.content.Context
import android.speech.tts.TextToSpeech
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.yuyue.design.Icons
import app.yuyue.design.Prefs
import app.yuyue.design.YY
import app.yuyue.library.Library
import app.yuyue.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Locale

/** 设置 · 外文, as on Apple. */
object ForeignPrefs {
    const val SPEAK = "foreign.speak"
    const val ACCENT = "foreign.accent"
    const val MARK = "foreign.mark"
    const val GLOSS = "foreign.gloss"
    const val LEVEL = "foreign.glossLevel"
    const val GLOSS_VOCAB = "foreign.glossVocab"

    /** 点词时读出来. */
    val speaks get() = Prefs.bool(SPEAK, true)
    /** 生词在所有书里标出来. */
    val marks get() = Prefs.bool(MARK, true)
    /** 在难词上方写释义. */
    val glosses get() = Prefs.bool(GLOSS, true)
    val level: Int get() = Prefs.int(LEVEL, 3)
    val glossVocabOnly get() = Prefs.bool(GLOSS_VOCAB, false)
    /** en-GB or en-US. */
    val accent get() = Prefs.string(ACCENT, "en-GB")
}

/** The short meaning, as the card shows it: "fortune /ˈfɔːtʃuːn/ n. 财富，大笔的钱；运气". */
data class WordDefinition(val headword: String, val phonetic: String?, val lines: List<String>) {
    /** "n. 财富，大笔的钱" for the 生词本. */
    val line: String get() = lines.firstOrNull() ?: ""
}

/** 点词's dictionary on Android: ECDICT, trimmed by scripts/ecdict-android.py. Android has no system
 *  dictionary like Apple's; this one is English–Chinese, as the reader most often needs. */
object Dictionary {
    @Volatile private var lines: Array<String>? = null

    private fun load(context: Context): Array<String> = lines ?: synchronized(this) {
        lines ?: context.assets.open("ecdict.tsv").bufferedReader().useLines { s -> s.filter { !it.startsWith("#") }.toList().toTypedArray() }.also { lines = it }
    }

    private fun find(all: Array<String>, word: String): String? {
        var lo = 0
        var hi = all.size - 1
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            val key = all[mid].substringBefore('\t')
            val c = key.compareTo(word)
            when {
                c < 0 -> lo = mid + 1
                c > 0 -> hi = mid - 1
                else -> return all[mid]
            }
        }
        return null
    }

    /** The word, or the word it is a form of (went → go, happier → happy). */
    suspend fun define(context: Context, word: String): WordDefinition? = withContext(Dispatchers.IO) {
        val all = load(context)
        var w = word.lowercase().trim('\'', '’', '-', '.')
        var row = find(all, w)
        // A plural or a tense the dictionary has under its word.
        row?.split('\t')?.let { if (it.size == 2 && it[1].startsWith("=")) { w = it[1].drop(1); row = find(all, w) } }
        if (row == null && w.endsWith("'s")) { w = w.dropLast(2); row = find(all, w) }
        val parts = row?.split('\t') ?: return@withContext null
        if (parts.size < 3) return@withContext null
        WordDefinition(parts[0], parts[1].ifEmpty { null }?.let { "/$it/" }, parts[2].split("\\n"))
    }
}

/** The word tapped, and what its card shows. */
data class WordLookup(
    val word: String,
    val section: Int,
    val start: TextPoint,
    val end: TextPoint,
    /** The sentence it was met in. */
    val context: String,
    val rect: TextRect?,
    val definition: WordDefinition? = null,
    /** 本书出现 12 次. */
    val count: Int? = null,
    /** In the 生词本 already. */
    val kept: Boolean = false,
) {
    /** What goes into the 生词本: the dictionary's headword, or the word as tapped. */
    val headword: String
        get() = definition?.headword ?: if (word.drop(1) == word.drop(1).lowercase()) word.lowercase() else word
}

/** The book's words are read out in the book's language, English in the accent chosen. */
object WordVoice {
    private var tts: TextToSpeech? = null

    fun say(context: Context, text: String, language: String) {
        val engine = tts ?: TextToSpeech(context.applicationContext) { status ->
            if (status == TextToSpeech.SUCCESS) speak(text, language)
        }.also { tts = it; return }
        engine.stop()
        speak(text, language)
    }

    private fun speak(text: String, language: String) {
        val engine = tts ?: return
        val tag = if (language.lowercase().startsWith("en")) ForeignPrefs.accent else language
        engine.language = Locale.forLanguageTag(tag)
        engine.setSpeechRate(0.9f)
        engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, "word")
    }
}

/** 点词 (prototype 外文原著): over or under the word, its headword and sound, the short meaning,
 *  the phrase it was met in, then where it is from · 本书出现 N 次, and 加入生词本. */
@Composable
fun WordCard(model: ReaderModel, lookup: WordLookup) {
    val tint = YY.tint
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val top = (lookup.rect?.y ?: 200.0).toFloat()
        val bottom = (lookup.rect?.let { it.y + it.height } ?: 220.0).toFloat()
        // Under the word when there is room, over it otherwise.
        val y = if (bottom + 230 < maxHeight.value) (bottom + 10).dp else maxOf(56f, top - 230).dp
        Column(
            Modifier.align(Alignment.TopCenter).offset(y = y).width(340.dp)
                .shadow(16.dp, RoundedCornerShape(14.dp)).clip(RoundedCornerShape(14.dp)).background(YY.c.card)
                .padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(lookup.definition?.headword ?: lookup.word, fontFamily = FontFamily.Serif, fontWeight = FontWeight.Bold, fontSize = 21.sp, color = YY.c.t1)
                lookup.definition?.phonetic?.let { Text(it, fontSize = 11.5.sp, color = YY.c.t2) }
                Spacer(Modifier.weight(1f))
                Box(Modifier.size(28.dp).background(YY.c.inset, CircleShape).clickable { model.say(lookup.word) }, contentAlignment = Alignment.Center) {
                    Icon(Icons.headphones, t("再读一遍"), tint = YY.c.t1, modifier = Modifier.size(14.dp))
                }
            }
            val d = lookup.definition
            if (d != null) {
                Column(Modifier.padding(top = 6.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    for (line in d.lines) {
                        val pos = Regex("""^([a-z]+\.)\s*""").find(line)
                        Text(
                            buildAnnotatedString {
                                if (pos != null) withStyle(SpanStyle(fontFamily = FontFamily.Serif, fontStyle = FontStyle.Italic, color = YY.c.t3)) { append(pos.groupValues[1] + " ") }
                                append(if (pos != null) line.substring(pos.range.last + 1) else line)
                            },
                            fontSize = 13.sp, color = YY.c.t1,
                        )
                    }
                }
            } else {
                Text(t("词典里没有这个词。"), fontSize = 12.sp, color = YY.c.t2, modifier = Modifier.padding(top = 6.dp))
            }
            phrase(lookup)?.let { Text(it, fontFamily = FontFamily.Serif, fontStyle = FontStyle.Italic, fontSize = 11.5.sp, color = YY.c.t1, maxLines = 2, modifier = Modifier.padding(top = 4.dp)) }
            Box(Modifier.padding(top = 12.dp).fillMaxWidth().height(0.5.dp).background(YY.c.line))
            Row(Modifier.padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                val from = t("词典")
                val n = lookup.count ?: 0
                Text(if (n == 1) t("%@ · 本书只出现这一次", from) else if (n > 1) t("%@ · 本书出现 %lld 次", from, n) else from, fontSize = 10.5.sp, color = YY.c.t3, modifier = Modifier.weight(1f))
                Row(
                    Modifier.height(28.dp).background(if (lookup.kept) YY.c.inset else tint.black, CircleShape).clickable { model.keep(!lookup.kept) }.padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Icon(if (lookup.kept) Icons.check else Icons.add, null, tint = if (lookup.kept) YY.c.t1 else tint.onBlack, modifier = Modifier.size(13.dp))
                    Text(if (lookup.kept) t("在生词本里") else t("加入生词本"), fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, color = if (lookup.kept) YY.c.t1 else tint.onBlack)
                }
            }
        }
    }
}

/** A few words either side of it in the sentence: "in possession of a good fortune". */
private fun phrase(l: WordLookup): String? {
    val words = l.context.split(' ').filter { it.isNotEmpty() }
    val i = words.indexOfFirst { it.lowercase().contains(l.word.lowercase()) }
    if (i < 0) return null
    val from = maxOf(0, i - 4)
    val to = minOf(words.size - 1, i + 1)
    val core = words.subList(from, to + 1).joinToString(" ").trim(',', ';', ':', '“', '”', '"', '\'', '‘', '’')
    return (if (from > 0) "…" else "") + core + (if (to < words.size - 1) "…" else "")
}

// MARK: The model's side

/** Read in a language other than Chinese, Japanese or Korean: words can be looked up. */
val ReaderModel.isForeign: Boolean
    get() {
        val language = detail?.summary?.language?.lowercase() ?: return false
        return language.isNotEmpty() && listOf("zh", "ja", "ko", "und").none { language.startsWith(it) }
    }

/** Shows the word's card and says it. */
suspend fun ReaderModel.look(word: org.json.JSONObject) {
    val start = word.optJSONObject("start")?.let { TextPoint(it.optInt("s"), it.optInt("o")) } ?: return
    val end = word.optJSONObject("end")?.let { TextPoint(it.optInt("s"), it.optInt("o")) } ?: return
    val text = word.optString("text").ifEmpty { return }
    val rect = word.optJSONObject("rect")?.let { TextRect(it.optDouble("x"), it.optDouble("y"), it.optDouble("width"), it.optDouble("height")) }
    dismissCards()
    val definition = Dictionary.define(context, text)
    var l = WordLookup(text, section, start, end, word.optString("sentence"), rect, definition)
    val words = runCatching { core.words() }.getOrDefault(emptyList())
    l = l.copy(
        kept = words.any { it.word.equals(l.headword, true) && !it.known },
        count = runCatching { core.bookWordCount(bookID, l.headword).toInt() }.getOrNull(),
    )
    lookup = l
    pager.setLooking(section, start, end)
    if (ForeignPrefs.speaks) say(text)
}

fun ReaderModel.closeLookup() {
    if (lookup == null) return
    lookup = null
    pager.setLooking(null, null, null)
}

fun ReaderModel.say(text: String) = WordVoice.say(context, text, detail?.summary?.language ?: "en")

/** 加入生词本, or out of it again. */
fun ReaderModel.keep(on: Boolean) {
    val l = lookup ?: return
    try {
        if (on) {
            core.addWord(l.headword, l.definition?.phonetic, l.definition?.line, bookID, l.section.toUInt(), maxOf(0, l.start.s).toUInt(), l.context)
            show(Library.Toast(Library.Toast.Icon.Check, t("加入了生词本"), l.headword))
        } else {
            core.deleteWord(l.headword)
        }
        lookup = l.copy(kept = on)
        loadVocab()
        library.notesChanged()
    } catch (e: Exception) {
        failure = Library.message(e)
    }
}

/** 生词本 words still being learned, for the dotted line; and 难词注释 again. */
fun ReaderModel.loadVocab() {
    if (!isForeign) return
    val words = runCatching { core.words() }.getOrDefault(emptyList())
    pager.setVocab(if (ForeignPrefs.marks) words.filter { !it.known }.map { it.word } else emptyList())
    pager.refreshGlosses()
}

/** Turns on what a foreign book has: 点词, the dotted 生词, and (for English) 难词注释. */
fun ReaderModel.setUpForeign() {
    if (!isForeign) return
    pager.lookup = true
    if (detail?.summary?.language?.lowercase()?.startsWith("en") == true) {
        pager.glosser = { section ->
            if (!ForeignPrefs.glosses) emptyList()
            else runCatching { core.glosses(bookID, section.toUInt(), ForeignPrefs.level.toUByte(), ForeignPrefs.glossVocabOnly) }.getOrDefault(emptyList()).map { it.form to it.gloss }
        }
    }
    loadVocab()
}
