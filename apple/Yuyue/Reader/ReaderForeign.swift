import AVFoundation
import Foundation
import Translation
import YuyueCore
#if os(macOS)
import CoreServices
#endif

/// 外文原著 (FEATURES §3.5, prototype 外文原著): click a word and it is said aloud and looked up
/// in the system dictionary; keep it in the 生词本 and it is dotted in every book; 译 puts a
/// translation under each paragraph, and a double click translates one sentence.

/// 设置 · 外文.
enum ForeignPrefs {
    static let speakKey = "foreign.speak"
    static let accentKey = "foreign.accent"
    static let markKey = "foreign.mark"
    static let glossKey = "foreign.gloss"
    static let levelKey = "foreign.glossLevel"
    static let glossVocabKey = "foreign.glossVocab"

    /// 难词注释's levels: the easiest exam that lists a word, 四级 marking the most.
    static let levels: [(name: String, level: UInt8)] = [(String(localized: "四级"), 2), (String(localized: "六级"), 3), (String(localized: "考研"), 4), (String(localized: "雅思"), 5), ("GRE", 6)]

    enum Accent: String {
        case british = "en-GB", american = "en-US"
    }

    /// 点词时读出来.
    static var speaks: Bool { UserDefaults.standard.object(forKey: speakKey) as? Bool ?? true }
    /// 生词在所有书里标出来.
    static var marks: Bool { UserDefaults.standard.object(forKey: markKey) as? Bool ?? true }
    /// 在难词上方写释义.
    static var glosses: Bool { UserDefaults.standard.object(forKey: glossKey) as? Bool ?? true }
    static var level: UInt8 { UserDefaults.standard.object(forKey: levelKey) == nil ? 3 : UInt8(clamping: UserDefaults.standard.integer(forKey: levelKey)) }
    /// 只标生词本里的词.
    static var glossVocabOnly: Bool { UserDefaults.standard.bool(forKey: glossVocabKey) }

    /// The voice for a book in `language`: English in the accent chosen.
    static func voice(for language: String?) -> AVSpeechSynthesisVoice? {
        let language = language ?? "en"
        if language.lowercased().hasPrefix("en") {
            let accent = UserDefaults.standard.string(forKey: accentKey).flatMap(Accent.init) ?? .british
            return AVSpeechSynthesisVoice(language: accent.rawValue)
        }
        return AVSpeechSynthesisVoice(language: language)
    }
}

/// The word clicked, and what its card shows.
struct WordLookup: Equatable {
    let word: String
    let section: UInt32
    let start: ReaderMessage.Point
    let end: ReaderMessage.Point
    /// The sentence it was met in.
    let context: String
    /// Where it is on the page.
    let rect: CGRect
    var definition: WordDefinition?
    /// From the translator, when the dictionary has nothing.
    var gloss: String?
    /// 本书出现 12 次.
    var count: Int?
    /// In the 生词本 already.
    var kept = false
    /// The imported MDict dictionary it came from, and its whole entry (完整释义).
    var dictionary: String?
    var html: String?

    /// What goes into the 生词本: the dictionary's headword, or the word as clicked, lower-cased
    /// unless it looks like a name.
    var headword: String {
        if let h = definition?.headword, !h.isEmpty { return h }
        let rest = word.dropFirst()
        return rest == rest.lowercased() ? word.lowercased() : word
    }
}

/// The short meaning, as the card shows it: "fortune /ˈfɔːtʃuːn/ n. 财富，大笔的钱；运气".
struct WordDefinition: Equatable {
    var headword: String
    var phonetic: String?
    /// "n.", "v.", "adj.".
    var partOfSpeech: String?
    var meaning: String

    /// "n. 财富，大笔的钱" for the 生词本.
    var line: String { [partOfSpeech, meaning].compactMap { $0 }.joined(separator: " ") }
}

/// 双击一句只翻这一句.
struct SentenceTranslation: Equatable {
    let section: UInt32
    let sentence: Int
    let text: String
    let at: CGPoint
    var translated: String?
    var failed: String?
}

enum SystemDictionary {
    /// The first entry the system dictionaries have for `word`, cut down to one line; nil when
    /// none has it (on a Mac, Dictionary › Settings decides which are on, and in what order).
    static func define(_ word: String) -> WordDefinition? {
        #if os(macOS)
        let ns = word as NSString
        guard let raw = DCSCopyTextDefinition(nil, word as CFString, CFRange(location: 0, length: ns.length))?.takeRetainedValue() as String?
        else { return nil }
        #if DEBUG
        try? raw.write(to: URL(filePath: NSTemporaryDirectory()).appending(path: "dict-raw.txt"), atomically: true, encoding: .utf8)
        #endif
        return parse(raw, word: word)
        #else
        return nil
        #endif
    }

    private static let partsOfSpeech: [(String, String)] = [
        ("noun", "n."), ("verb", "v."), ("adjective", "adj."), ("adverb", "adv."), ("preposition", "prep."),
        ("conjunction", "conj."), ("pronoun", "pron."), ("exclamation", "int."), ("determiner", "det."),
        ("n.", "n."), ("vt.", "vt."), ("vi.", "vi."), ("v.", "v."), ("adj.", "adj."), ("adv.", "adv."), ("prep.", "prep."),
    ]

    /// "for·tune | ˈfôrCHən | noun 1 chance or luck as …" or "fortune /ˈfɔːtʃuːn/ n. ① 运气 …".
    static func parse(_ raw: String, word: String) -> WordDefinition? {
        var text = raw.replacingOccurrences(of: "\n", with: " ")
        var phonetic: String?
        var head = word
        if let m = text.firstMatch(of: /^(.+?)\s*\|\s*(.+?)\s*\|/) {
            head = String(m.1)
            // "BrE ˈfɔːtʃuːn, ˈfɔːtʃ(ə)n, AmE ˈfɔrtʃən": the first one.
            let first = m.2.replacingOccurrences(of: #"^(BrE|AmE)\s+"#, with: "", options: .regularExpression)
                .split(separator: ",").first.map(String.init) ?? String(m.2)
            phonetic = "/\(first.trimmingCharacters(in: .whitespaces))/"
            text = String(text[m.range.upperBound...])
        } else if let m = text.firstMatch(of: /^(.+?)\s+(\/[^\/]{1,40}\/)/) {
            head = String(m.1)
            phonetic = String(m.2)
            text = String(text[m.range.upperBound...])
        } else if text.lowercased().hasPrefix(word.lowercased()) {
            text = String(text.dropFirst(word.count))
        }
        head = head.replacingOccurrences(of: "·", with: "").replacingOccurrences(of: "•", with: "").trimmingCharacters(in: .whitespaces)
        if head.contains(" ") || head.count > 40 { head = word }
        text = text.trimmingCharacters(in: .whitespaces)
        var pos: String?
        let lower = text.lowercased()
        if let (name, short) = partsOfSpeech.first(where: { lower.hasPrefix($0.0 + " ") || lower.hasPrefix("a. " + $0.0) }) {
            pos = short
            text = String(text[(lower.range(of: name)!.upperBound)...])
        }
        // Numbering and labels: "1", "①", "A.", "[mass noun]", "(informal)".
        text = text.replacingOccurrences(of: #"^\s*(?:[A-Z]\.|\d+|[①-⑳])\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^\s*(?:\[[^\]]*\]|\([^)]*\))\s*"#, with: "", options: .regularExpression)
        var meaning: String
        // An English–Chinese entry: the Chinese of the first few senses, examples (▸) left out.
        var hans: [String] = []
        for sense in text.split(whereSeparator: { "①②③④⑤⑥⑦⑧⑨⑩".contains($0) }).prefix(5) {
            let head = sense.split(separator: "▸").first.map(String.init) ?? ""
            if let m = head.firstMatch(of: /\p{Han}[\p{Han}，、…]*/) {
                let h = String(m.0).trimmingCharacters(in: CharacterSet(charactersIn: "，、"))
                if !hans.contains(h) { hans.append(h) }
            }
        }
        if !hans.isEmpty {
            meaning = hans.prefix(3).joined(separator: "；")
        } else {
            meaning = String(text.prefix { !":;".contains($0) })
        }
        meaning = meaning.trimmingCharacters(in: .whitespaces)
        if meaning.count > 48 { meaning = String(meaning.prefix(46)) + "…" }
        guard !meaning.isEmpty else { return nil }
        return WordDefinition(headword: head, phonetic: phonetic, partOfSpeech: pos, meaning: meaning)
    }
}

/// The system's translation (Translation framework): on the device, free, no limit. Requests
/// queue here; the reader window runs them through `.translationTask(configuration)`, which
/// is also where the system offers to download a language the first time.
@Observable
final class Translator {
    var configuration: TranslationSession.Configuration?
    /// Why the last request failed.
    private(set) var failure: String?
    @ObservationIgnored var source = Locale.Language(identifier: "en")
    @ObservationIgnored private var queue: [(texts: [String], done: CheckedContinuation<[String?], Never>)] = []

    static let target = Locale.Language(identifier: "zh-Hans")

    /// The language pair is downloaded, so a request won't ask for anything.
    func installed() async -> Bool {
        await LanguageAvailability().status(from: source, to: Self.target) == .installed
    }

    func translate(_ texts: [String]) async -> [String?] {
        guard !texts.isEmpty else { return [] }
        return await withCheckedContinuation { done in
            queue.append((texts, done))
            if configuration == nil {
                configuration = .init(source: source, target: Self.target)
            } else {
                configuration?.invalidate()
            }
        }
    }

    func run(_ session: TranslationSession) async {
        while !queue.isEmpty {
            let (texts, done) = queue.removeFirst()
            do {
                // The session is only ever used from here, one request at a time.
                nonisolated(unsafe) let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
                nonisolated(unsafe) let session = session
                var out = [String?](repeating: nil, count: texts.count)
                for r in try await session.translations(from: requests) {
                    if let i = r.clientIdentifier.flatMap(Int.init), out.indices.contains(i) { out[i] = r.targetText }
                }
                failure = nil
                done.resume(returning: out)
            } catch {
                failure = Self.message(for: error)
                done.resume(returning: [String?](repeating: nil, count: texts.count))
            }
        }
    }

    static func message(for error: Error) -> String {
        if let e = error as? TranslationError {
            switch e {
            case TranslationError.unsupportedLanguagePairing, TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedTargetLanguage:
                return String(localized: "系统翻译不支持这种语言")
            case TranslationError.unableToIdentifyLanguage:
                return String(localized: "认不出是什么语言")
            default:
                break
            }
        }
        return String(localized: "翻译没成功：要先在系统设置里下载这种语言")
    }
}

extension ReaderModel {
    /// Read in a language other than Chinese: words can be looked up and translated.
    var isForeign: Bool {
        guard let language = detail?.summary.language.lowercased(), !language.isEmpty else { return false }
        return !["zh", "ja", "ko", "und"].contains { language.hasPrefix($0) }
    }

    func setUpForeign() {
        guard isForeign else { return }
        pager.lookup = true
        if let language = detail?.summary.language { translator.source = Locale.Language(identifier: language) }
        pager.translator = { [weak self] texts in await self?.translator.translate(texts) ?? [] }
        let core = core, bookID = bookID
        // 难词注释 is only for English: the list is English–Chinese.
        if detail?.summary.language.lowercased().hasPrefix("en") == true {
            pager.glosser = { section in
                guard ForeignPrefs.glosses else { return [] }
                let list = (try? core.glosses(bookId: bookID, section: section, level: ForeignPrefs.level, vocabOnly: ForeignPrefs.glossVocabOnly)) ?? []
                return list.map { ["form": $0.form, "gloss": $0.gloss] }
            }
        }
        loadVocab()
        if UserDefaults.standard.bool(forKey: translateKey) { setTranslateShown(true) }
    }

    private var translateKey: String { "translate.\(bookID)" }

    /// 生词本 words still being learned, for the dotted line.
    func loadVocab() {
        guard isForeign else { return }
        let words = (try? core.words()) ?? []
        pager.setVocab(ForeignPrefs.marks ? words.filter { !$0.known }.map(\.word) : [])
        pager.refreshGlosses()
        let here = words.filter { $0.book == bookID }.sorted { ($0.section, $0.sentence) < ($1.section, $1.sentence) }
        if here != bookWords { bookWords = here }
    }

    /// 译 in the tools.
    func setTranslateShown(_ on: Bool) {
        translateShown = on
        UserDefaults.standard.set(on, forKey: translateKey)
        pager.setTranslating(on)
    }

    // MARK: 点词

    /// Says the word and opens its card.
    func look(up word: ReaderMessage.Word, quiet: Bool = false) {
        guard let section = pager.current?.section else { return }
        dismissCards()
        sentenceTranslation = nil
        // The dictionaries the reader imported first, then the system's.
        let entry = (try? core.lookUp(word: word.text)) ?? nil
        let definition = entry.map { WordDefinition(headword: $0.headword, phonetic: nil, partOfSpeech: nil, meaning: $0.summary) }
            ?? SystemDictionary.define(word.text)
        var l = WordLookup(word: word.text, section: section, start: word.start, end: word.end, context: word.sentence,
                           rect: CGRect(x: word.rect.x, y: word.rect.y, width: word.rect.width, height: word.rect.height),
                           definition: definition)
        l.dictionary = entry?.dictionary
        l.html = entry?.html
        let words = (try? core.words()) ?? []
        l.kept = words.contains { $0.word.lowercased() == l.headword.lowercased() && !$0.known }
        l.count = (try? core.bookWordCount(book: bookID, word: l.headword)).map(Int.init)
        lookup = l
        pager.setLooking(section: section, start: word.start, end: word.end)
        if !quiet, ForeignPrefs.speaks { say(word.text) }
        if definition == nil {
            Task {
                guard await translator.installed() else { return }
                let gloss = await translator.translate([word.text]).first ?? nil
                if lookup?.word == word.text, lookup?.section == section { lookup?.gloss = gloss }
            }
        }
    }

    func closeLookup() {
        guard lookup != nil else { return }
        lookup = nil
        pager.clearLooking()
    }

    /// The word, read in the book's language.
    func say(_ text: String) {
        let speaker = speaker ?? AVSpeechSynthesizer()
        self.speaker = speaker
        speaker.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = ForeignPrefs.voice(for: detail?.summary.language)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        speaker.speak(u)
    }

    /// 加入生词本, or out of it again.
    func keep(_ on: Bool) {
        guard var l = lookup else { return }
        do {
            if on {
                let meaning = l.definition?.line ?? l.gloss
                _ = try core.addWord(word: l.headword, phonetic: l.definition?.phonetic, meaning: meaning, book: bookID,
                                     section: l.section, sentence: UInt32(max(0, l.start.s)), context: l.context)
                show(Library.Toast(icon: "character.book.closed", title: String(localized: "加入了生词本"), detail: l.headword))
            } else {
                try core.deleteWord(word: l.headword)
            }
            l.kept = on
            lookup = l
            NotificationCenter.default.post(name: .vocabChanged, object: nil)
        } catch {
            failure = Library.message(for: error)
        }
    }

    // MARK: 双击一句

    func pager(_ pager: ReaderPager, doubleTapped m: ReaderMessage) {
        #if os(iOS)
        // 双击屏幕边缘进出沉浸: the outer eighth on either side, where no words are.
        if let x = m.x.map({ CGFloat($0) }), pager.bounds.width > 0, x < pager.bounds.width * 0.12 || x > pager.bounds.width * 0.88 {
            chromeShown = false
            immersive.toggle()
            return
        }
        #endif
        guard isForeign, let s = m.sentence, let section = pager.current?.section else { return }
        dismissCards()
        closeLookup()
        let sentences = (try? core.sentences(bookId: bookID, section: section)) ?? []
        guard sentences.indices.contains(s) else { return }
        let text = sentences[s].trimmingCharacters(in: .whitespacesAndNewlines)
        sentenceTranslation = SentenceTranslation(section: section, sentence: s, text: text, at: CGPoint(x: m.x ?? 0, y: m.y ?? 0))
        Task {
            let out = await translator.translate([text]).first ?? nil
            guard sentenceTranslation?.sentence == s, sentenceTranslation?.section == section else { return }
            if let out { sentenceTranslation?.translated = out } else { sentenceTranslation?.failed = translator.failure ?? String(localized: "翻译没成功") }
        }
    }
}

extension Notification.Name {
    /// A word was put in or taken out of the 生词本.
    static let vocabChanged = Notification.Name("yuyue.vocabChanged")
}
