import Foundation
import SwiftUI
import YuyueCore

/// 生词本 helpers shared by the shelf's page and the reader's panel: picking the word out of
/// the sentence it was met in, and 导出 Anki · CSV.
enum Vocab {
    /// A word and its usual English inflections, as the core counts them (`words::forms`).
    static func forms(_ word: String) -> Set<String> {
        let w = word.trimmingCharacters(in: .whitespaces).lowercased()
        var out: Set<String> = [w]
        guard w.count >= 3, w.allSatisfy({ $0.isASCII && $0.isLetter }) else { return out }
        out.formUnion([w + "s", w + "es", w + "ed", w + "ing", w + "'s"])
        if w.hasSuffix("e") { out.formUnion([w + "d", String(w.dropLast()) + "ing"]) }
        if w.hasSuffix("y") { out.formUnion([String(w.dropLast()) + "ies", String(w.dropLast()) + "ied"]) }
        return out
    }

    /// Where `word` (or one of its forms) is in `context`.
    static func ranges(of word: String, in context: String) -> [Range<String.Index>] {
        let forms = forms(word)
        return context.matches(of: /\p{L}(?:\p{L}|['’\-](?=\p{L}))*/).map(\.range).filter {
            forms.contains(context[$0].lowercased().replacingOccurrences(of: "’", with: "'"))
        }
    }

    /// The sentence, shortened around the word when it is long: "…a single man in possession of
    /// a good fortune, must be in want of a wife."
    static func excerpt(_ context: String, word: String, limit: Int = 160) -> String {
        let text = context.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard text.count > limit, let r = ranges(of: word, in: text).first else { return text }
        let before = text.distance(from: text.startIndex, to: r.lowerBound)
        let from = max(0, before - limit / 3)
        var start = text.index(text.startIndex, offsetBy: from)
        if from > 0, let space = text[start...].firstIndex(of: " ") { start = text.index(after: space) }
        var end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        if end < text.endIndex, let space = text[..<end].lastIndex(of: " ") { end = space }
        return (from > 0 ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }

    /// The sentence with the word picked out (darker, underlined in the accent), for a card.
    static func attributed(_ context: String, word: String, accent: Color, limit: Int = 160) -> AttributedString {
        let text = excerpt(context, word: word, limit: limit)
        var out = AttributedString(text)
        for r in ranges(of: word, in: text) {
            guard let a = AttributedString.Index(r.lowerBound, within: out), let b = AttributedString.Index(r.upperBound, within: out)
            else { continue }
            out[a..<b].foregroundColor = YYColor.t1
            out[a..<b].underlineStyle = Text.LineStyle(pattern: .solid, color: accent)
        }
        return out
    }

    /// "n. 运气；命运" → ("n.", "运气；命运").
    static func split(meaning: String?) -> (pos: String?, text: String)? {
        guard let m = meaning?.trimmingCharacters(in: .whitespaces), !m.isEmpty else { return nil }
        if let space = m.firstIndex(of: " "), m[..<space].hasSuffix("."), m[..<space].allSatisfy({ $0.isASCII }) {
            return (String(m[..<space]), String(m[m.index(after: space)...]).trimmingCharacters(in: .whitespaces))
        }
        return (nil, m)
    }

    /// 在 3 本书里出现 41 次.
    static func spread(_ c: WordCount?) -> String? {
        guard let c, c.times > 0 else { return nil }
        if c.books > 1 { return String(localized: "在 \(c.books) 本书里出现 \(c.times) 次") }
        return c.times == 1 ? String(localized: "只出现过这一次") : String(localized: "在这本书里出现 \(c.times) 次")
    }

    /// Anki's plain-text import: one note a line, front and back split by a tab, HTML allowed.
    static func anki(_ words: [VocabWord], title: (VocabWord) -> String) -> String {
        func html(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }
        var out = "#separator:tab\n#html:true\n#tags column:3\n"
        for w in words {
            var front = "<b>\(html(w.word))</b>"
            if let p = w.phonetic { front += " <span style=\"color:#888\">\(html(p))</span>" }
            var context = html(excerpt(w.context, word: w.word, limit: 240))
            for r in ranges(of: w.word, in: context).reversed() { context.replaceSubrange(r, with: "<u>\(context[r])</u>") }
            var back = html(w.meaning ?? "")
            if !context.isEmpty { back += "<br><br><i>\(context)</i>" }
            back += "<br><small>\(html(title(w)))</small>"
            out += String(localized: "\(front)\t\(back)\t语阅\n")
        }
        return out
    }

    /// A table for Numbers or Excel; the BOM tells Excel it is UTF-8.
    static func csv(_ words: [VocabWord], title: (VocabWord) -> String) -> String {
        func cell(_ s: String) -> String {
            s.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var out = String(localized: "\u{FEFF}单词,音标,释义,原句,出处,加入时间,掌握了\r\n")
        let day = Date.FormatStyle.dateTime.year().month(.twoDigits).day(.twoDigits)
        for w in words {
            let at = Date(timeIntervalSince1970: Double(w.at) / 1000).formatted(day)
            out += [w.word, w.phonetic ?? "", w.meaning ?? "", w.context, title(w), at, w.known ? String(localized: "是") : ""]
                .map(cell).joined(separator: ",") + "\r\n"
        }
        return out
    }
}
