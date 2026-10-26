import SwiftUI
import YuyueCore

/// What the floating panel on the right of the Mac window shows.
enum ReaderPanel: String {
    case toc, notes, search, companion
}

/// Text selected on the page: where, and the lines it covers (in the pager's coordinates).
struct TextSelection: Equatable {
    var section: UInt32
    var start: ReaderMessage.Point
    var end: ReaderMessage.Point
    var text: String
    var rect: CGRect
}

/// A highlight clicked on the page, and where.
struct OpenMark: Equatable {
    var mark: Mark
    var at: CGPoint
}

/// Counts the time spent in a section: reading while pages are being turned, listening while
/// the voice reads.
struct TimeClock {
    var lastTurn = Date()
    var since = Date()
}

extension MarkStyle {
    /// As the reader names it (contract §8).
    var css: String {
        switch self {
        case .yellow: "yellow"
        case .blue: "blue"
        case .pink: "pink"
        case .wave: "wave"
        case .underline: "underline"
        case .dotted: "dotted"
        }
    }

    var name: String {
        switch self {
        case .yellow: String(localized: "黄色")
        case .blue: String(localized: "蓝色")
        case .pink: String(localized: "粉色")
        case .wave: String(localized: "波浪线")
        case .underline: String(localized: "下划线")
        case .dotted: String(localized: "点线")
        }
    }

    /// The four that 1–4 put down.
    static let colours: [MarkStyle] = [.yellow, .blue, .pink, .wave]
    static let lines: [MarkStyle] = [.underline, .dotted]

    /// Whether it colours behind the words (the others draw a line under them).
    var fills: Bool { [.yellow, .blue, .pink].contains(self) }

    var fill: Color {
        switch self {
        case .yellow: YYColor.mkY
        case .blue: YYColor.mkB
        case .pink: YYColor.mkP
        default: .clear
        }
    }

    init?(css: String) {
        guard let style = MarkStyle.colours.first(where: { $0.css == css }) ?? MarkStyle.lines.first(where: { $0.css == css }) else { return nil }
        self = style
    }
}

extension ReaderModel {
    private static let styleKey = "reader.markStyle"

    func loadNotes() {
        if let saved = UserDefaults.standard.string(forKey: Self.styleKey), let style = MarkStyle(css: saved) {
            lastStyle = style
        }
        reloadNotes()
        times = Dictionary(((try? core.sectionTimes(book: bookID)) ?? []).map { ($0.section, $0) }) { a, _ in a }
    }

    func reloadNotes() {
        marks = (try? core.marks(book: bookID)) ?? []
        bookmarks = (try? core.bookmarks(book: bookID)) ?? []
        pager.setMarks(marks)
        NotificationCenter.default.post(name: .notesChanged, object: bookID)
    }

    // MARK: Highlights

    /// Highlights the selection in `style` (the last one used when nil). Returns the new mark.
    @discardableResult
    func mark(_ style: MarkStyle? = nil, note: String? = nil) -> Mark? {
        guard let selection else { return nil }
        let style = style ?? lastStyle
        remember(style)
        do {
            let mark = try core.addMark(
                book: bookID, section: selection.section,
                start: TextPoint(sentence: UInt32(selection.start.s), offset: UInt32(selection.start.o)),
                end: TextPoint(sentence: UInt32(selection.end.s), offset: UInt32(selection.end.o)),
                text: selection.text.trimmingCharacters(in: .whitespacesAndNewlines), style: style, note: note)
            self.selection = nil
            pager.clearSelection()
            reloadNotes()
            return mark
        } catch {
            failure = Library.message(for: error)
            return nil
        }
    }

    func setStyle(_ style: MarkStyle, of mark: Mark) {
        remember(style)
        run { try $0.core.setMarkStyle(book: $0.bookID, id: mark.id, style: style) }
        if openMark?.mark.id == mark.id, let fresh = marks.first(where: { $0.id == mark.id }) { openMark?.mark = fresh }
    }

    func setNote(_ note: String?, of mark: Mark) {
        run { try $0.core.setMarkNote(book: $0.bookID, id: mark.id, note: note) }
    }

    /// 双击耳机: the sentence just heard, highlighted in the last colour used.
    func markHeard(_ spot: Player.Spot) {
        guard let all = try? core.sentences(bookId: bookID, section: spot.section), all.indices.contains(spot.sentence) else { return }
        let raw = all[spot.sentence]
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let range = raw.range(of: text) else { return }
        let point = { TextPoint(sentence: UInt32(spot.sentence), offset: UInt32(raw.utf16.distance(from: raw.startIndex, to: $0))) }
        let known = Set(marks.map(\.id))
        var made: Mark?
        run { made = try $0.core.markHeard(book: $0.bookID, section: spot.section, start: point(range.lowerBound),
                                             end: point(range.upperBound), text: text, style: $0.lastStyle) }
        guard let made else { return }
        let new = !known.contains(made.id)
        show(Library.Toast(icon: "headphones", title: new ? String(localized: "划下了刚听到的这句") : String(localized: "这句已经划过了"), detail: "“\(text.prefix(16))”",
                           undo: new ? { [weak self] in self?.run { try $0.core.deleteMark(book: $0.bookID, id: made.id) } } : nil))
    }

    func deleteMark(_ mark: Mark) {
        openMark = nil
        run { try $0.core.deleteMark(book: $0.bookID, id: mark.id) }
        show(Library.Toast(icon: "highlighter", danger: true, title: String(localized: "已删除划线"),
                           detail: mark.note == nil ? "“\(mark.text.prefix(16))”" : String(localized: "想法也一起删了")) { [weak self] in
            self?.run { try $0.core.restoreMark(book: $0.bookID, id: mark.id) }
        })
    }

    private func remember(_ style: MarkStyle) {
        lastStyle = style
        UserDefaults.standard.set(style.css, forKey: Self.styleKey)
    }

    func copySelection() {
        guard let text = selection?.text ?? openMark?.mark.text else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        dismissCards()
        show(Library.Toast(icon: "doc.on.doc", title: String(localized: "已复制"), detail: "“\(text.prefix(16))”"))
    }

    /// 从这读: reads aloud from the first selected sentence.
    func readFromSelection() {
        guard let player, let selection else { return }
        let start = Position(section: selection.section, sentence: UInt32(selection.start.s))
        dismissCards()
        player.play(from: start)
    }

    func dismissCards() {
        if selection != nil { pager.clearSelection() }
        selection = nil
        openMark = nil
    }

    func go(to mark: Mark) {
        jump(section: mark.section, sentence: Int(mark.start.sentence))
    }

    func jump(section: UInt32, sentence: Int) {
        leaving()
        clock.lastTurn = Date()
        pager.show(section: section, target: .sentence(sentence, align: .third), animated: false)
    }

    // MARK: Bookmarks

    /// The bookmark on the page showing, if any.
    var bookmarkHere: Bookmark? {
        guard let section, let layout = pager.current?.layout else { return nil }
        return bookmarks.first { $0.section == section && layout.page(of: Int($0.sentence)) == page }
    }

    /// ⌘D: a bookmark on this page, or off it again.
    func toggleBookmark() {
        if let mark = bookmarkHere {
            run { try $0.core.deleteBookmark(book: $0.bookID, id: mark.id) }
            show(Library.Toast(icon: "bookmark.slash", title: String(localized: "书签拿掉了"), detail: mark.text.isEmpty ? String(localized: "这一页") : "“\(mark.text.prefix(16))”") { [weak self] in
                self?.run { try $0.core.restoreBookmark(book: $0.bookID, id: mark.id) }
            })
        } else if let position = pager.position {
            run { try $0.core.addBookmark(book: $0.bookID, section: position.section, sentence: position.sentence) }
            show(Library.Toast(icon: "bookmark.fill", title: String(localized: "加了书签"), detail: estimatedPage(section: position.section, sentence: Int(position.sentence)).map { String(localized: "第 \($0) 页") } ?? ""))
        }
    }

    /// The sleep timer stopped the voice: a bookmark where it stopped, to find the place again.
    func fellAsleep(at spot: Player.Spot) {
        run { try $0.core.addBookmark(book: $0.bookID, section: spot.section, sentence: UInt32(spot.sentence)) }
        show(Library.Toast(icon: "moon.zzz", title: String(localized: "定时到了，停在这里"), detail: String(localized: "加了一个书签")))
    }

    func deleteBookmark(_ mark: Bookmark) {
        run { try $0.core.deleteBookmark(book: $0.bookID, id: mark.id) }
    }

    // MARK: Search

    /// Searches the book for `query`, a moment after the typing stops.
    func search() {
        searching?.cancel()
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            hits = []
            hitIndex = nil
            pager.setHits(query: nil, current: nil)
            return
        }
        let core = core, book = bookID
        searching = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let found = await Task.detached { (try? core.searchBook(book: book, query: query)) ?? [] }.value
            guard !Task.isCancelled, let self else { return }
            self.hits = found
            // Start from the first one at or after where the reader is.
            let here = (self.section ?? 0, self.sentence)
            let first = found.firstIndex { ($0.section, Int($0.sentence)) >= here } ?? (found.isEmpty ? nil : 0)
            self.show(hit: first)
        }
    }

    func show(hit index: Int?) {
        hitIndex = index
        let hit = index.flatMap { hits.indices.contains($0) ? hits[$0] : nil }
        pager.setHits(query: query.trimmingCharacters(in: .whitespaces), current: hit)
        if let hit { jump(section: hit.section, sentence: Int(hit.sentence)) }
    }

    func nextHit(forward: Bool) {
        guard !hits.isEmpty else { return }
        let i = hitIndex ?? (forward ? -1 : hits.count)
        show(hit: (i + (forward ? 1 : -1) + hits.count) % hits.count)
    }

    func endSearch() {
        searching?.cancel()
        searchShown = false
        query = ""
        hits = []
        hitIndex = nil
        pager.setHits(query: nil, current: nil)
    }

    // MARK: Where the reader is

    private var counted: [(Int, SectionSummary)] {
        (detail?.sections ?? []).enumerated().filter { $1.linear && $1.kind == .text }
    }

    /// 0–1 through the main text at a sentence, as the core counts it.
    func fraction(section: UInt32, sentence: Int) -> Double {
        let all = counted
        let total = all.reduce(0) { $0 + Double($1.1.units) }
        guard total > 0 else { return 0 }
        var before = 0.0
        for (i, s) in all {
            if i < Int(section) {
                before += Double(s.units)
            } else if i == Int(section) {
                before += Double(s.units) * Double(sentence) / Double(max(1, s.sentences))
            }
        }
        return min(1, before / total)
    }

    /// 0–1 through the book where the reader is.
    var bookFraction: Double {
        guard let section else { return 0 }
        return fraction(section: section, sentence: sentence)
    }

    /// Sentences in the current section.
    var sentenceCount: Int {
        guard let section, let s = detail?.sections[safe: Int(section)] else { return 0 }
        return Int(s.sentences)
    }

    /// Minutes to read a section at the core's pace (300 characters a minute).
    func minutes(of section: Int) -> Int {
        guard let s = detail?.sections[safe: section] else { return 0 }
        return max(1, Int((Double(s.units) / 300).rounded()))
    }

    /// Minutes left in the current section.
    var chapterMinutesLeft: Int {
        guard let section else { return 0 }
        let n = max(1, sentenceCount)
        return max(1, Int((Double(minutes(of: Int(section))) * Double(n - sentence) / Double(n)).rounded()))
    }

    /// The capsule's second line: `42% · 本章还剩 6 分钟`, or `原声 · 本章还剩 38 分钟` in the
    /// narrator's voice, timed from the recording.
    var capsuleNote: String {
        if let player, player.narrated, let section,
           let left = player.recording?.secondsLeft(section: section, sentence: sentence) {
            return String(localized: "原声 · 本章还剩 \(max(1, Int((left / 60 / Double(rate)).rounded()))) 分钟")
        }
        return String(localized: "\(Int((bookFraction * 100).rounded()))% · 本章还剩 \(chapterMinutesLeft) 分钟")
    }

    /// The page in the whole book, guessed from how much text the current section puts on a page.
    func estimatedPage(section: UInt32, sentence: Int) -> Int? {
        guard let here = self.section, let s = detail?.sections[safe: Int(here)], s.units > 0 else { return nil }
        let perPage = Double(s.units) / Double(max(1, pageCount))
        guard perPage > 0 else { return nil }
        var before = 0.0
        for (i, x) in counted where i < Int(section) { before += Double(x.units) }
        if let t = detail?.sections[safe: Int(section)] {
            before += Double(t.units) * Double(sentence) / Double(max(1, t.sentences))
        }
        return Int(before / perPage) + 1
    }

    var bookPage: Int? {
        guard let section else { return nil }
        if let layout = pager.current?.layout, pager.current?.section == section {
            // The pages before this section, guessed; this section's own, as laid out.
            let first = estimatedPage(section: section, sentence: 0) ?? 1
            return first + min(page, layout.pageCount - 1)
        }
        return estimatedPage(section: section, sentence: sentence)
    }

    // MARK: Time

    /// Adds the time since the last tick to the section showing: listening while the voice
    /// reads, reading while pages have been turned in the last few minutes.
    func tick(closing: Bool = false) {
        let now = Date()
        let seconds = now.timeIntervalSince(clock.since)
        clock.since = now
        guard let section = player?.spot?.section ?? section, seconds > 0, seconds < 3600 else { return }
        var read = 0, listen = 0
        if isPlaying {
            listen = Int(seconds.rounded())
        } else if now.timeIntervalSince(clock.lastTurn) < 300 {
            read = Int(seconds.rounded())
        }
        guard read + listen > 0 else { return }
        try? core.addTime(book: bookID, section: section, readSeconds: UInt32(read), listenSeconds: UInt32(listen), day: Notes.today)
        if !closing {
            var t = times[section] ?? SectionTime(section: section, readSeconds: 0, listenSeconds: 0)
            t.readSeconds += UInt32(read)
            t.listenSeconds += UInt32(listen)
            times[section] = t
        }
    }

    // MARK: Menu commands

    func stepFont(_ d: Double) {
        update { $0.fontSize = min(max($0.fontSize + d, 12), 34) }
    }

    func togglePanel(_ which: ReaderPanel) {
        panel = panel == which ? nil : which
    }

    func startSearch() {
        // ⌘F again while it is open: back to the field.
        if searchShown { searchFieldWanted += 1 } else { searchShown = true }
    }

    // MARK: Helpers

    func show(_ toast: Library.Toast) {
        self.toast = toast
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Library.lifetime(of: toast)))
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
    }

    func undoToast() {
        guard let toast else { return }
        self.toast = nil
        toast.undo?()
    }

    private func run(_ work: (ReaderModel) throws -> Void) {
        do {
            try work(self)
        } catch {
            failure = Library.message(for: error)
        }
        reloadNotes()
    }
}

extension Array {
    subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}

/// "1 小时 52 分" · "38 分钟"
func durationText(seconds: Int) -> String {
    let minutes = max(1, (seconds + 30) / 60)
    let h = minutes / 60, m = minutes % 60
    if h == 0 { return String(localized: "\(m) 分钟") }
    return m == 0 ? String(localized: "\(h) 小时") : String(localized: "\(h) 小时 \(m) 分")
}

extension Mark: Identifiable {}
