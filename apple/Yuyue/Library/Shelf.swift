import Foundation
import SwiftUI
import YuyueCore

/// What the shelf shows: everything, one kind, one reading status or one collection.
enum ShelfFilter: Hashable {
    case all
    case books
    case comics
    /// 有声: books with a narrator's recording laid against them.
    case audio
    case status(ReadingStatus)
    case collection(String)
    /// 全部合集 (the 合集墙, on the Mac).
    case collections
    /// 笔记 and 生词本.
    case notes
    case words
}

extension ReadingStatus {
    var name: String {
        switch self {
        case .reading: String(localized: "在读")
        case .want: String(localized: "想读")
        case .finished: String(localized: "读完")
        }
    }

    var symbol: String {
        switch self {
        case .reading: "book"
        case .want: "bookmark"
        case .finished: "checkmark.circle"
        }
    }
}

extension BookSummary {
    var author: String? { authors.first }

    /// "42%", just started still reads as started.
    var percent: String { "\(max(1, Int((progress * 100).rounded())))%" }

    var isComic: Bool { format == .comic }

    /// A comic has nothing to listen to; a PDF is read from the words on its pages.
    var canListen: Bool { format != .comic }

    /// 第 15 话 · 第 6 页: where a comic is up to.
    var comicPlace: String {
        guard episode > 0 else { return String(localized: "还没看") }
        return episodes > 1 ? String(localized: "第 \(episode) 话 · 第 \(page) 页") : String(localized: "第 \(page) 页")
    }

    /// The line under a cover: how far, or where it stands.
    var shelfNote: String {
        // Synced from another device without its file.
        if !available { return String(localized: "在别的设备上") }
        if isComic {
            if status == .finished { return String(localized: "看完") }
            guard episode > 0 else { return String(localized: "漫画 · 没看过") }
            let strip = UserDefaults.standard.string(forKey: "comic.layout.\(id)") == "strip"
            if episodes <= 1 { return strip ? String(localized: "条漫 · \(percent)") : percent }
            return strip ? String(localized: "条漫 · 第 \(episode) 话") : String(localized: "读到第 \(episode) 话")
        }
        return switch status {
        case .finished: String(localized: "读完")
        case .want: String(localized: "想读")
        case .reading: progress > 0 ? percent : String(localized: "刚开始")
        }
    }

    /// 还剩 4 小时 20 分 · 还没读 · 读完了
    var remaining: String {
        if isComic {
            if status == .finished { return String(localized: "看完了") }
            guard episode > 0 else { return String(localized: "还没看") }
            if episodes > 1 { return episode >= episodes ? String(localized: "最后一话") : String(localized: "还剩 \(episodes - episode) 话") }
        }
        switch status {
        case .finished: return String(localized: "读完了")
        case .want where progress == 0: return String(localized: "还没读")
        default:
            let minutes = max(1, Int((Double(readMinutes) * (1 - progress)).rounded()))
            let h = minutes / 60, m = minutes % 60
            if h == 0 { return String(localized: "还剩 \(m) 分") }
            return m == 0 ? String(localized: "还剩 \(h) 小时") : String(localized: "还剩 \(h) 小时 \(m) 分")
        }
    }
}

/// The icon in front of a collection: the one the user picked, or one guessed from the name.
enum CollectionIcon {
    static let fallback = "books.vertical"

    static func symbol(for collection: BookCollection) -> String {
        collection.icon ?? guess(for: collection.name) ?? fallback
    }

    private static let guesses: [([String], String)] = [
        (["睡", "夜", "晚", "sleep", "night", "bed"], "moon"),
        (["科幻", "宇宙", "星", "sci-fi", "space", "star"], "sparkle"),
        (["听", "通勤", "路上", "listen", "commute", "audio"], "headphones"),
        (["英文", "原著", "外文", "日文", "english"], "globe"),
        (["周末", "咖啡", "闲", "weekend", "coffee"], "cup.and.saucer"),
        (["推理", "悬疑", "侦探", "mystery", "detective", "crime"], "key"),
        (["诗", "词", "poem", "poetry"], "quote.opening"),
        (["孩子", "儿童", "童", "kid", "child"], "sun.max"),
        (["重读", "再读", "reread"], "arrow.trianglehead.2.clockwise"),
        (["top", "榜", "最爱", "喜欢", "favorite", "love"], "heart"),
        (["历史", "史", "history"], "clock"),
        (["科普", "科学", "science"], "eye"),
        (["写", "作家", "鲁迅", "writer", "writing"], "pencil"),
    ]

    static func guess(for name: String) -> String? {
        let name = name.lowercased()
        return guesses.first { keys, _ in keys.contains { name.contains($0) } }?.1
    }
}

/// Finds names by what was typed: the characters themselves, their pinyin, or the first
/// letters of it ("kh" finds 科幻, "kehuan" and "keh" too).
struct NameMatcher {
    let query: String

    init(_ query: String) {
        self.query = query.lowercased().filter { !$0.isWhitespace }
    }

    var isEmpty: Bool { query.isEmpty }

    /// The matched characters of `name`, or nil when it doesn't match.
    func match(_ name: String) -> Range<Int>? {
        let chars = Array(name.lowercased())
        if let r = chars.firstRange(of: Array(query)) { return r }
        let syllables = chars.map(Self.pinyin)
        for start in syllables.indices {
            if let end = consume(Substring(query), syllables, from: start) {
                return start..<end
            }
        }
        return nil
    }

    /// The name with the matched characters in `color`.
    func highlighted(_ name: String, color: Color) -> AttributedString {
        var text = AttributedString(name)
        guard let r = match(name) else { return text }
        let chars = text.characters
        let lower = chars.index(chars.startIndex, offsetBy: r.lowerBound)
        let upper = chars.index(chars.startIndex, offsetBy: r.upperBound)
        text[lower..<upper].foregroundColor = color
        return text
    }

    /// Eats the query syllable by syllable: each one wholly or by its first letters.
    /// Returns where the match ends.
    private func consume(_ q: Substring, _ syllables: [String], from i: Int) -> Int? {
        if q.isEmpty { return i }
        guard i < syllables.count else { return nil }
        let s = syllables[i]
        guard let first = s.first, q.first == first else { return nil }
        var k = min(s.count, q.count)
        while k > 0 {
            if q.hasPrefix(s.prefix(k)), let end = consume(q.dropFirst(k), syllables, from: i + 1) {
                return end
            }
            k -= 1
        }
        return nil
    }

    private static var cache: [Character: String] = [:]

    private static func pinyin(_ c: Character) -> String {
        if let hit = cache[c] { return hit }
        let latin = String(c).applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?
            .lowercased()
            .filter(\.isLetter) ?? ""
        let out = latin.isEmpty ? String(c) : latin
        cache[c] = out
        return out
    }
}

/// A thin progress bar in the tint.
struct ProgressLine: View {
    let value: Double
    var height: CGFloat = 3

    var body: some View {
        Capsule()
            .fill(YYColor.inset)
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(YYTint.standard.fill).frame(width: g.size.width * min(1, max(0, value)))
                }
            }
            .accessibilityHidden(true)
    }
}

extension View {
    /// Layers of a shadow from the tokens.
    func yyShadow(_ layers: [YYShadowLayer]) -> some View {
        layers.reduce(AnyView(self)) { view, layer in
            if layer.blur == 0 && layer.spread > 0 {
                // A hairline ring.
                return AnyView(view.overlay(RoundedRectangle(cornerRadius: YYRadius.block).strokeBorder(Color(yy: layer.color), lineWidth: layer.spread)))
            }
            return AnyView(view.shadow(color: Color(yy: layer.color), radius: layer.blur / 2, x: layer.x, y: layer.y))
        }
    }
}

/// An icon and text a little closer than the system's label.
struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

extension Library {
    /// 有声: whether a narrator's recording is laid against this book.
    func hasAudio(_ book: BookSummary) -> Bool { audiobooks.audiobook(for: book.id) != nil }

    /// Under the cover: `有声 · 6 小时` until it's opened, then `有声 · 42%`.
    func shelfNote(_ book: BookSummary) -> String {
        guard book.available, let a = audiobooks.audiobook(for: book.id) else { return book.shelfNote }
        if book.status == .finished { return String(localized: "有声 · 听完") }
        return String(localized: "有声 · ") + (book.progress > 0 ? book.percent : Audiobook.length(a.total).replacingOccurrences(of: #" \d+ 分$"#, with: "", options: .regularExpression))
    }
}

/// `.v-aud`: the headphones on a cover with a recording.
struct AudioBadge: View {
    var body: some View {
        Image(systemName: "headphones")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Color(red: 16 / 255, green: 18 / 255, blue: 20 / 255).opacity(0.72), in: .circle)
            .padding(5)
            .accessibilityHidden(true)
    }
}
