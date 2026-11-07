import Foundation
import SwiftUI
import YuyueCore

/// What the shelf shows: everything, one kind, one reading status or one collection.
enum ShelfFilter: Hashable {
    case all
    case books
    /// 有声: books with a narrator's recording laid against them.
    case audio
    case status(ReadingStatus)
    case collection(String)
    /// 全部合集 (the 合集墙, on the Mac).
    case collections
    /// 笔记 and 生词本.
    case notes
    case words
    /// 播客: a place held for it; nothing behind it yet.
    case podcasts
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

    /// The line under a cover: how far, or where it stands.
    var shelfNote: String {
        // Synced from another device without its file.
        if !available { return String(localized: "在别的设备上") }
        return switch status {
        case .finished: String(localized: "读完")
        case .want: String(localized: "想读")
        case .reading: progress > 0 ? percent : String(localized: "刚开始")
        }
    }

    /// 还剩 4 小时 20 分 · 还没读 · 读完了
    var remaining: String {
        let audio = format == .audio
        switch status {
        case .finished: return audio ? String(localized: "听完了") : String(localized: "读完了")
        case .want where progress == 0: return audio ? String(localized: "还没听") : String(localized: "还没读")
        default:
            let minutes = max(1, Int((Double(audio ? listenMinutes : readMinutes) * (1 - progress)).rounded()))
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

    /// 换图标: the same icons a name can bring, each with what it's for.
    static let choices: [(symbol: String, name: String)] = [
        (fallback, String(localized: "书")),
        ("moon", String(localized: "睡前")),
        ("headphones", String(localized: "听")),
        ("sparkle", String(localized: "科幻")),
        ("globe", String(localized: "外文")),
        ("cup.and.saucer", String(localized: "闲读")),
        ("key", String(localized: "推理")),
        ("quote.opening", String(localized: "诗词")),
        ("sun.max", String(localized: "孩子")),
        ("arrow.trianglehead.2.clockwise", String(localized: "重读")),
        ("heart", String(localized: "最爱")),
        ("clock", String(localized: "历史")),
        ("eye", String(localized: "科普")),
        ("pencil", String(localized: "写作")),
    ]
}

/// 换图标 in a collection's menu: one of `CollectionIcon.choices`, or back to the one its name brings.
struct CollectionIconMenu: View {
    let collection: BookCollection
    let library: Library

    var body: some View {
        Menu {
            ForEach(CollectionIcon.choices, id: \.symbol) { c in
                Button { library.setCollectionIcon(collection.id, c.symbol) } label: {
                    Label(c.name, systemImage: c.symbol)
                }
            }
            Divider()
            Button("按名字自动选") { library.setCollectionIcon(collection.id, nil) }
        } label: {
            Label("换图标", systemImage: CollectionIcon.symbol(for: collection))
        }
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
    /// 有声: an 有声书 of its own, or a narrator's recording laid against this book.
    func hasAudio(_ book: BookSummary) -> Bool { book.format == .audio || audiobooks.audiobook(for: book.id) != nil }

    /// Under the cover: `有声 · 6 小时` until it's opened, then `有声 · 42%`.
    func shelfNote(_ book: BookSummary) -> String {
        if book.available, book.format == .audio {
            if book.status == .finished { return String(localized: "有声 · 听完") }
            return String(localized: "有声 · ") + (book.progress > 0 ? book.percent : Audiobook.length(Double(book.listenMinutes) * 60).replacingOccurrences(of: #" \d+ 分$"#, with: "", options: .regularExpression))
        }
        guard book.available, let a = audiobooks.audiobook(for: book.id) else { return book.shelfNote }
        if book.status == .finished { return String(localized: "有声 · 听完") }
        return String(localized: "有声 · ") + (book.progress > 0 ? book.percent : Audiobook.length(a.total).replacingOccurrences(of: #" \d+ 分$"#, with: "", options: .regularExpression))
    }
}

/// The headphones on a cover with a recording.
struct AudioBadge: View {
    var body: some View {
        Image(systemName: "headphones")
            .font(.yy(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Color(red: 16 / 255, green: 18 / 255, blue: 20 / 255).opacity(0.72), in: .circle)
            .padding(5)
            .accessibilityHidden(true)
    }
}
