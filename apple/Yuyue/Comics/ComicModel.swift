import CoreGraphics
import Foundation
import ImageIO
import Observation
import YuyueCore

/// 漫画 (FEATURES §3.6): the pages of a comic, where the reader is, and how this comic is read:
/// one page, two side by side (a wide picture alone, as the spread it is), or a strip scrolled
/// down; right to left or left to right. Each comic keeps its own way of reading.
@Observable
final class ComicModel {
    enum Layout: String, CaseIterable {
        case single, double, strip

        var name: String {
            switch self {
            case .single: String(localized: "单页")
            case .double: String(localized: "双页")
            case .strip: String(localized: "条漫")
            }
        }
    }

    struct Episode: Identifiable {
        let id: Int
        let section: UInt32
        let title: String
        let pages: [URL]
    }

    let bookID: String
    let title: String
    let episodes: [Episode]
    /// Where the reader is: the episode and the first page shown.
    private(set) var episode = 0
    private(set) var page = 0
    var layout: Layout {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "comic.layout.\(bookID)") }
    }
    /// 从右往左, as Japanese comics are read.
    var rightToLeft: Bool {
        didSet { UserDefaults.standard.set(rightToLeft, forKey: "comic.rtl.\(bookID)") }
    }
    var failure: String?
    /// 竖屏时拆开跨页: in one page at a time and a window taller than wide, a wide scan is shown
    /// half by half, the half read first before the other.
    var splitWide = false {
        didSet { if splitWide != oldValue { half = 0 } }
    }
    private(set) var half = 0

    @ObservationIgnored private let core: YuyueCore
    @ObservationIgnored private var spreadCache: [Int: [[Int]]] = [:]
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var since = Date()
    @ObservationIgnored private var lastTurn = Date()

    init(library: Library, bookID: String, wide: Bool) {
        core = library.core
        self.bookID = bookID
        let detail = try? core.book(id: bookID)
        title = detail?.summary.title ?? ""
        var episodes: [Episode] = []
        for (i, s) in (detail?.sections ?? []).enumerated() where s.pages > 0 {
            let pages = ((try? core.comicPages(bookId: bookID, section: UInt32(i))) ?? []).map { URL(filePath: $0) }
            episodes.append(Episode(id: episodes.count, section: UInt32(i), title: s.title ?? "", pages: pages))
        }
        self.episodes = episodes
        let d = UserDefaults.standard
        // A window wider than tall shows two pages, unless this comic was read otherwise.
        layout = d.string(forKey: "comic.layout.\(bookID)").flatMap(Layout.init) ?? (wide ? .double : .single)
        rightToLeft = d.object(forKey: "comic.rtl.\(bookID)") as? Bool ?? true
        if detail == nil { failure = String(localized: "打不开这部漫画") }

        var position = (try? core.progress(bookId: bookID))?.position ?? (try? core.latestProgress(bookId: bookID))?.position
        if case .at(let there) = library.takeIntent(for: bookID) { position = there }
        if let position, let e = episodes.firstIndex(where: { $0.section == position.section }) {
            episode = e
            page = min(Int(position.sentence), max(0, episodes[e].pages.count - 1))
        }
    }

    var current: Episode? { episodes.indices.contains(episode) ? episodes[episode] : nil }

    /// 第 15 话, or the folder's own name when it says more.
    func name(of e: Episode) -> String {
        if !e.title.isEmpty { return e.title }
        return episodes.count > 1 ? String(localized: "第 \(e.id + 1) 话") : title
    }

    // MARK: Pages and spreads

    /// A picture's size in pixels, from its header.
    nonisolated static func size(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Double, let h = p[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0
        else { return nil }
        let turned = (p[kCGImagePropertyOrientation] as? Int).map { (5...8).contains($0) } ?? false
        return turned ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    @ObservationIgnored private var sizes: [URL: CGSize] = [:]

    func aspect(_ url: URL) -> Double {
        if let s = sizes[url] { return s.width / s.height }
        let s = Self.size(of: url) ?? CGSize(width: 2, height: 3)
        sizes[url] = s
        return s.width / s.height
    }

    func isWide(_ url: URL) -> Bool { aspect(url) > 1.05 }

    /// The episode's pages two by two: the first alone (it is the cover, or the title page), a
    /// wide picture alone, the rest in pairs.
    func spreads(of e: Int) -> [[Int]] {
        if let s = spreadCache[e] { return s }
        let pages = episodes[e].pages
        var out: [[Int]] = []
        var i = 0
        while i < pages.count {
            if i == 0 || isWide(pages[i]) || i + 1 >= pages.count || isWide(pages[i + 1]) {
                out.append([i])
                i += 1
            } else {
                out.append([i, i + 1])
                i += 2
            }
        }
        spreadCache[e] = out
        return out
    }

    /// The pages on screen now.
    var shown: [Int] {
        guard current != nil else { return [] }
        switch layout {
        case .double: return spreads(of: episode).first { $0.contains(page) } ?? [page]
        default: return [page]
        }
    }

    /// 第 6–7 / 32 页.
    var pageLabel: String {
        guard let e = current else { return "" }
        let s = shown.map { $0 + 1 }
        let here = s.count > 1 ? "\(s[0])–\(s[1])" : "\(s.first ?? 1)"
        return String(localized: "第 \(here) / \(e.pages.count) 页")
    }

    /// The page on screen is a spread being shown half by half.
    var splitting: Bool {
        guard layout == .single, splitWide, let e = current, e.pages.indices.contains(page) else { return false }
        return isWide(e.pages[page])
    }

    var atEnd: Bool {
        guard let e = current else { return true }
        return episode == episodes.count - 1 && (shown.last ?? 0) >= e.pages.count - 1 && (!splitting || half == 1)
    }

    // MARK: Moving

    /// The next page or spread; past the last, the next episode's first.
    func next() {
        guard let e = current else { return }
        if splitting, half == 0 { half = 1; return }
        let last = shown.last ?? page
        if last + 1 < e.pages.count {
            go(episode: episode, page: last + 1)
        } else if episode + 1 < episodes.count {
            go(episode: episode + 1, page: 0)
        }
    }

    /// The page or spread before; before the first, the previous episode's last.
    func previous() {
        if splitting, half == 1 { half = 0; return }
        let first = shown.first ?? page
        if first > 0 {
            let target = layout == .double ? (spreads(of: episode).last { ($0.first ?? 0) < first }?.first ?? 0) : first - 1
            go(episode: episode, page: target)
        } else if episode > 0 {
            let e = episode - 1
            let target = layout == .double ? (spreads(of: e).last?.first ?? 0) : episodes[e].pages.count - 1
            go(episode: e, page: max(0, target))
        } else {
            return
        }
        // Coming back onto a spread, the half read last.
        if splitting { half = 1 }
    }

    func go(episode e: Int, page p: Int) {
        guard episodes.indices.contains(e) else { return }
        tick()
        lastTurn = Date()
        half = 0
        episode = e
        page = min(max(0, p), max(0, episodes[e].pages.count - 1))
        if layout == .double, let first = spreads(of: e).first(where: { $0.contains(page) })?.first { page = first }
        save()
    }

    /// From the strip: the page at the top of the window, as the reader scrolls.
    func scrolled(to e: Int, page p: Int) {
        guard e != episode || p != page, episodes.indices.contains(e) else { return }
        if e != episode { tick() }
        lastTurn = Date()
        episode = e
        page = p
        save()
    }

    /// Pictures worth decoding before they are needed: 预加载, the next few, and the one before.
    var upcoming: [URL] {
        guard let e = current else { return [] }
        let ahead = UserDefaults.standard.object(forKey: "comic.preload") as? Int ?? 5
        let from = (shown.last ?? page) + 1
        var out = Array(e.pages.dropFirst(from).prefix(ahead))
        if out.count < ahead, episodes.indices.contains(episode + 1) { out += episodes[episode + 1].pages.prefix(ahead - out.count) }
        if let before = shown.first, before > 0 { out.append(e.pages[before - 1]) }
        return out
    }

    // MARK: Progress

    private func save() {
        saving?.cancel()
        let position = Position(section: current?.section ?? 0, sentence: UInt32(page))
        saving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.write(position)
        }
    }

    private func write(_ position: Position) {
        saving = nil
        do {
            try core.saveProgress(bookId: bookID, position: position)
        } catch {
            failure = Library.message(for: error)
        }
    }

    /// Time spent looking at pages, for 读了多久.
    private func tick() {
        let now = Date()
        let seconds = now.timeIntervalSince(since)
        since = now
        guard let section = current?.section, seconds > 0, seconds < 3600, now.timeIntervalSince(lastTurn) < 180 else { return }
        try? core.addTime(book: bookID, section: section, readSeconds: UInt32(seconds.rounded()), listenSeconds: 0, day: Notes.today)
    }

    func close() {
        tick()
        if saving != nil {
            saving?.cancel()
            write(Position(section: current?.section ?? 0, sentence: UInt32(page)))
        }
    }
}

/// Decoded pages, made no bigger than they are shown, kept while memory allows.
nonisolated final class ComicImages: @unchecked Sendable {
    static let shared = ComicImages()
    private let cache = NSCache<NSString, CGImage>()

    init() {
        cache.countLimit = 40
    }

    func cached(_ url: URL, _ pixels: Int, crop: Bool = false) -> CGImage? {
        cache.object(forKey: "\(url.path)#\(pixels)\(crop ? "c" : "")" as NSString)
    }

    /// `crop` trims the white margin of a scanned page, the same share from every side, so the
    /// page keeps its shape and only the drawing grows.
    func image(_ url: URL, pixels: Int, crop: Bool = false) async -> CGImage? {
        let key = "\(url.path)#\(pixels)\(crop ? "c" : "")" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let made = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
            return crop ? Self.trimmed(image) : image
        }.value
        if let made { cache.setObject(made, forKey: key) }
        return made
    }

    /// The page without its white border: how far in the paper stays blank from each edge, on a
    /// small grey copy, and the least of the four taken off all round. Never more than a fifth.
    nonisolated static func trimmed(_ image: CGImage) -> CGImage {
        let w = 160, h = max(1, Int(Double(image.height) / Double(image.width) * 160))
        var grey = [UInt8](repeating: 255, count: w * h)
        guard let ctx = CGContext(data: &grey, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // A line is blank when almost all of it is near white (a speck of dust doesn't count).
        func blank(_ count: Int, _ at: (Int) -> UInt8) -> Bool {
            var ink = 0
            for i in 0..<count where at(i) < 225 { ink += 1 }
            return Double(ink) / Double(count) < 0.01
        }
        func run(_ n: Int, _ isBlank: (Int) -> Bool) -> Int {
            var k = 0
            while k < n / 5, isBlank(k) { k += 1 }
            return k
        }
        let top = run(h) { y in blank(w) { grey[y * w + $0] } }
        let bottom = run(h) { y in blank(w) { grey[(h - 1 - y) * w + $0] } }
        let left = run(w) { x in blank(h) { grey[$0 * w + x] } }
        let right = run(w) { x in blank(h) { grey[$0 * w + w - 1 - x] } }
        let share = min(Double(min(top, bottom)) / Double(h), Double(min(left, right)) / Double(w))
        // Keep a hair of paper round the drawing.
        let cut = max(0, share - 0.006)
        guard cut > 0.01 else { return image }
        let dx = Double(image.width) * cut, dy = Double(image.height) * cut
        return image.cropping(to: CGRect(x: dx, y: dy, width: Double(image.width) - 2 * dx, height: Double(image.height) - 2 * dy).integral) ?? image
    }
}
