import Foundation
import NaturalLanguage
import Observation
import PDFKit
import YuyueCore

/// A PDF open for reading (FEATURES §3.5): shown as it is printed, by the system's own viewer.
/// Where the reader is, is a page; each PDF keeps its own way of showing pages.
///
/// Its text is the page's own, as the system's PDF reads it; the core cuts it into sentences
/// (TECH §九), so it can be marked up and read aloud a sentence at a time. A highlight's ends,
/// and a place to read from, are a page and a character offset into that page's text — the
/// page standing where a book has its sentence, in section 0, just like the reading position.
@Observable
final class PdfModel {
    enum Layout: String, CaseIterable {
        /// 连续滚动, one page under another; 单页 and 双页 turn like a book.
        case scroll, single, double

        var name: String {
            switch self {
            case .scroll: String(localized: "连续滚动")
            case .single: String(localized: "单页")
            case .double: String(localized: "双页")
            }
        }

        var symbol: String {
            switch self {
            case .scroll: "rectangle.split.1x2"
            case .single: "rectangle.portrait"
            case .double: "rectangle.split.2x1"
            }
        }
    }

    struct Chapter: Identifiable {
        let id: Int
        let title: String
        let depth: Int
        let page: Int
    }

    struct Hit: Identifiable {
        let id: Int
        let page: Int
        let range: NSRange
        let before: String, match: String, after: String
    }

    let bookID: String
    let title: String
    let author: String?
    let document: PDFDocument?
    /// Its pages can be shown: there, readable, not locked.
    var opened: Bool { document.map { !$0.isLocked } ?? false }
    let chapters: [Chapter]
    /// The page in view, from 0.
    private(set) var page = 0
    var layout: Layout {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "pdf.layout.\(bookID)") }
    }
    /// 夜间: the pages' colours turned round, so white paper reads dark.
    var night: Bool {
        didSet { UserDefaults.standard.set(night, forKey: "pdf.night.\(bookID)") }
    }
    var failure: String?
    var query = ""
    private(set) var hits: [Hit] = []
    private(set) var searching = false
    /// Asked of the view: the page to show, and what to light up there.
    var target: (page: Int, range: NSRange?)?

    /// 划线 and 想法, in reading order.
    private(set) var marks: [Mark] = []
    /// The note at the bottom, with 撤销.
    var toast: Library.Toast?
    /// 写想法: the highlight whose thought is being written.
    var writing: Mark?
    /// The sentence the voice is on: its page, and where it is in the page's text.
    private(set) var reading: Reading?
    struct Reading: Equatable {
        let page: Int
        let sentence: Int
        let count: Int
        let range: NSRange
    }
    /// Reads the pages aloud; nil when the book can't be found.
    @ObservationIgnored private(set) var player: Player?
    @ObservationIgnored var lastStyle: MarkStyle

    @ObservationIgnored let core: YuyueCore
    @ObservationIgnored private weak var library: Library?
    @ObservationIgnored private var language: String
    @ObservationIgnored private var sentenceCache: [Int: [PageSentence]] = [:]
    @ObservationIgnored private var listenSince: Date?
    @ObservationIgnored private var jumps: Task<Void, Never>?
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var finding: Task<Void, Never>?
    @ObservationIgnored private var since = Date()
    @ObservationIgnored private var lastTurn = Date()

    init(library: Library, bookID: String) {
        core = library.core
        self.library = library
        self.bookID = bookID
        let summary = library.books.first { $0.id == bookID }
        title = summary?.title ?? ""
        author = summary?.author
        url = summary.flatMap(library.originalFile)
        let document = url.flatMap(PDFDocument.init(url:))
        // Before any page is made: the pages draw highlights, and 夜间 on the phone, themselves.
        document?.delegate = MarkedPages.shared
        if let document, document.isLocked { document.unlock(withPassword: "") }
        self.document = document
        chapters = document?.outlineRoot.map { Self.flatten($0, in: document!) } ?? []
        let d = UserDefaults.standard
        layout = d.string(forKey: "pdf.layout.\(bookID)").flatMap(Layout.init) ?? .scroll
        night = d.bool(forKey: "pdf.night.\(bookID)")
        lastStyle = d.string(forKey: "reader.markStyle").flatMap(MarkStyle.init(css:)) ?? .yellow
        language = summary?.language ?? ""
        if url == nil {
            failure = String(localized: "找不到这本书的文件，可能被移走或删掉了。从书架上删掉，再导入一次就好")
        } else if document == nil {
            failure = String(localized: "这个 PDF 读不出来，文件可能坏了")
        } else if document?.isLocked == true {
            failure = String(localized: "这个 PDF 设了密码，打不开")
        }

        let intent = library.takeIntent(for: bookID)
        var position = (try? core.progress(bookId: bookID))?.position ?? (try? core.latestProgress(bookId: bookID))?.position
        if intent == .listenFromStart { position = nil }
        if case .at(let there) = intent { position = there }
        if let position { page = min(Int(position.sentence), max(0, pageCount - 1)) }
        marks = (try? core.marks(book: bookID)) ?? []
        if document != nil, let detail = try? core.book(id: bookID) {
            player = Player(core: core, detail: detail, script: script)
            setUpPlayer()
        }
        if intent == .listen || intent == .listenFromStart { togglePlay() }
        // From 笔记 or 搜索, with the window already open.
        jumps = Task { [weak self] in
            for await n in NotificationCenter.default.notifications(named: .readerJump) {
                guard let self, n.object as? String == self.bookID else { continue }
                if case .at(let p) = self.library?.takeIntent(for: self.bookID) { self.go(to: Int(p.sentence)) }
            }
        }
    }

    var pageCount: Int { document?.pageCount ?? 0 }

    /// The page as the PDF numbers it (xii, 23), when that differs from its place.
    func label(of page: Int) -> String {
        let n = "\(page + 1)"
        guard let printed = document?.page(at: page)?.label, !printed.isEmpty, printed != n else { return n }
        return printed
    }

    /// The chapter the page is in.
    var chapter: Chapter? { chapters.last { $0.page <= page } }

    private static func flatten(_ node: PDFOutline, in doc: PDFDocument, depth: Int = 0) -> [Chapter] {
        var out: [Chapter] = []
        func walk(_ node: PDFOutline, _ depth: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                if let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
                   let page = child.destination?.page.map(doc.index(for:)) {
                    out.append(Chapter(id: out.count, title: label, depth: depth, page: page))
                }
                if depth < 2 { walk(child, depth + 1) }
            }
        }
        walk(node, depth)
        return out
    }

    // MARK: Moving

    func go(to p: Int, range: NSRange? = nil) {
        guard pageCount > 0 else { return }
        target = (min(max(0, p), pageCount - 1), range)
    }

    /// From the view, as the reader scrolls or turns.
    func shown(_ p: Int) {
        guard p != page else { return }
        lastTurn = Date()
        page = p
        save()
    }

    // MARK: 书内搜索

    func search() {
        finding?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 1, let url else { hits = []; searching = false; return }
        searching = true
        finding = Task { [weak self] in
            let found = await Self.find(q, in: url)
            guard !Task.isCancelled else { return }
            self?.hits = found
            self?.searching = false
        }
    }

    /// On a copy of the document, so a long search doesn't hold up the pages.
    @concurrent nonisolated private static func find(_ query: String, in url: URL) async -> [Hit] {
        guard let doc = PDFDocument(url: url) else { return [] }
        if doc.isLocked { doc.unlock(withPassword: "") }
        var hits: [Hit] = []
        for i in 0..<doc.pageCount {
            if Task.isCancelled || hits.count >= 300 { break }
            guard let page = doc.page(at: i), let text = page.string as NSString? else { continue }
            var from = 0
            while from < text.length, hits.count < 300 {
                let r = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: text.length - from))
                guard r.location != NSNotFound else { break }
                let start = max(0, r.location - 18), end = min(text.length, r.location + r.length + 40)
                let clean = { (s: String) in Self.joinLines(s) }
                hits.append(Hit(id: hits.count, page: i, range: r,
                                before: clean(text.substring(with: NSRange(location: start, length: r.location - start))),
                                match: text.substring(with: r),
                                after: clean(text.substring(with: NSRange(location: r.location + r.length, length: end - r.location - r.length)))))
                from = r.location + max(1, r.length)
            }
        }
        return hits
    }

    /// Lines of a page run together: nothing between Chinese, a space between words.
    nonisolated static func joinLines(_ s: String) -> String {
        let lines = s.split(whereSeparator: \.isNewline)
        var out = ""
        for line in lines {
            if let a = out.last, let b = line.first, a.isASCII, b.isASCII, !a.isWhitespace { out.append(" ") }
            out += line
        }
        return out
    }

    // MARK: Progress

    private func save() {
        saving?.cancel()
        let position = Position(section: 0, sentence: UInt32(page))
        saving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.write(position)
        }
        tick()
    }

    private func write(_ position: Position) {
        saving = nil
        do {
            try core.saveProgress(bookId: bookID, position: position)
        } catch {
            failure = Library.message(for: error)
        }
    }

    /// Time spent on the pages, for 读了多久: a page left open for long doesn't count.
    private func tick() {
        let now = Date()
        let seconds = now.timeIntervalSince(since)
        since = now
        guard seconds > 0, seconds < 600 else { return }
        try? core.addTime(book: bookID, section: 0, readSeconds: UInt32(seconds.rounded()), listenSeconds: 0, day: Notes.today)
    }

    func close() {
        jumps?.cancel()
        player?.close()
        listened(playing: false)
        finding?.cancel()
        if Date().timeIntervalSince(lastTurn) < 180 { tick() }
        if saving != nil {
            saving?.cancel()
            write(Position(section: 0, sentence: UInt32(page)))
        }
    }

    // MARK: The page's sentences

    /// The sentences on a page, cut by the core from the page's text.
    func sentences(on page: Int) -> [PageSentence] {
        if let known = sentenceCache[page] { return known }
        let text = document?.page(at: page)?.string ?? ""
        let found = text.isEmpty ? [] : pageSentences(text: text)
        sentenceCache[page] = found
        return found
    }

    /// The language to read in: the book's, or else the one its words are in.
    private func language(near page: Int) -> String {
        if !language.isEmpty, language != "und" { return language }
        let sample = (page..<min(pageCount, page + 3)).flatMap { sentences(on: $0).map(\.text) }.joined(separator: " ")
        guard let found = NLLanguageRecognizer.dominantLanguage(for: sample) else { return "zh-Hans" }
        language = found == .simplifiedChinese || found == .traditionalChinese ? found.rawValue : String(found.rawValue.prefix(2))
        return language
    }

    /// What the voice reads: each page a section.
    private var script: Player.Script {
        Player.Script(
            sentences: { [weak self] p in self?.sentences(on: Int(p)).map(\.text) ?? [] },
            next: { [weak self] p in
                guard let self, Int(p) + 1 < self.pageCount else { return nil }
                return p + 1
            },
            previous: { p in p > 0 ? p - 1 : nil },
            language: { [weak self] p in self?.language(near: Int(p)) ?? "zh-Hans" },
            title: { [weak self] p in
                guard let self else { return nil }
                return self.chapters.last { $0.page <= Int(p) }?.title ?? String(localized: "第 \(self.label(of: Int(p))) 页")
            })
    }

    // MARK: 听

    var isPlaying: Bool { player?.state == .playing || player?.state == .loading }

    private func setUpPlayer() {
        guard let player else { return }
        let rate = UserDefaults.standard.float(forKey: "player.rate")
        if rate > 0 { player.rate = rate }
        player.onSentence = { [weak self] spot, _, _, playing in
            self?.heard(spot, playing: playing)
        }
        player.onStop = { [weak self] in
            self?.reading = nil
            self?.listened(playing: false)
        }
        player.onSleep = { [weak self] spot in
            guard let self else { return }
            self.listened(playing: false)
            try? self.core.addBookmark(book: self.bookID, section: 0, sentence: UInt32(spot.section))
            self.show(Library.Toast(icon: "moon.zzz", title: String(localized: "睡眠定时停了"), detail: String(localized: "在第 \(self.label(of: Int(spot.section))) 页加了书签")))
        }
        player.onMarkHeard = { [weak self] spot in self?.markHeard(spot) }
    }

    var rate: Float {
        get { player?.rate ?? 1 }
        set {
            player?.rate = newValue
            UserDefaults.standard.set(newValue, forKey: "player.rate")
        }
    }

    /// Pauses; or reads on — where it paused if that page is still in view, else from the top
    /// of the page in view.
    func togglePlay() {
        guard let player else { return }
        switch player.state {
        case .playing, .loading:
            player.pause()
        case .paused where player.spot.map { Int($0.section) == page } == true:
            player.resume()
        case .paused, .stopped:
            read(from: page, sentence: 0)
        }
    }

    /// 从这读.
    func read(from page: Int, sentence: Int) {
        guard let player else { return }
        player.play(from: Position(section: UInt32(page), sentence: UInt32(sentence)))
        if player.state == .stopped {
            failure = String(localized: "从这里往后没有能读的字。扫描成图片的 PDF 读不出来。")
        }
    }

    /// The voice moved on: light up the sentence, and turn the page with it.
    private func heard(_ spot: Player.Spot, playing: Bool) {
        let p = Int(spot.section)
        let all = sentences(on: p)
        guard all.indices.contains(spot.sentence) else { return }
        let s = all[spot.sentence]
        let now = Reading(page: p, sentence: spot.sentence, count: all.count,
                          range: NSRange(location: Int(s.start), length: Int(s.end - s.start)))
        if reading?.page != p, p != page { go(to: p) }
        if reading != now { reading = now }
        listened(playing: playing)
    }

    /// Time spent listening, for 听了多久; and 听中 on the shelf.
    private func listened(playing: Bool) {
        let now = Date()
        if let since = listenSince {
            let seconds = now.timeIntervalSince(since)
            if seconds > 0, seconds < 120 {
                try? core.addTime(book: bookID, section: 0, readSeconds: 0, listenSeconds: UInt32(seconds.rounded()), day: Notes.today)
            }
        }
        listenSince = playing ? now : nil
        guard let library else { return }
        if playing {
            if library.listening != bookID { library.listening = bookID }
        } else if library.listening == bookID {
            library.listening = nil
        }
    }

    /// Minutes of listening left on the page in view at this speed.
    var minutesLeftOnPage: Int {
        let all = sentences(on: reading?.page ?? page)
        let from = reading?.page == page ? reading?.sentence ?? 0 : 0
        let chars = all.dropFirst(from).reduce(0) { $0 + $1.text.count }
        return max(1, Int((Double(chars) / 220 / Double(max(0.5, rate))).rounded()))
    }

    // MARK: 划线 and 想法

    /// A selection on the pages as the core keeps it: page and offset at each end.
    struct Span {
        let start: TextPoint
        let end: TextPoint
        let text: String
    }

    func span(of selection: PDFSelection) -> Span? {
        guard let document else { return nil }
        let pages = selection.pages
        guard let first = pages.first, let last = pages.last else { return nil }
        let a = selection.range(at: 0, on: first)
        let lastCount = selection.numberOfTextRanges(on: last)
        guard a.location != NSNotFound, lastCount > 0 else { return nil }
        let b = selection.range(at: lastCount - 1, on: last)
        let text = Self.joinLines(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, b.location != NSNotFound else { return nil }
        return Span(start: TextPoint(sentence: UInt32(document.index(for: first)), offset: UInt32(a.location)),
                    end: TextPoint(sentence: UInt32(document.index(for: last)), offset: UInt32(b.location + b.length)),
                    text: text)
    }

    /// The pieces of a highlight, a page at a time.
    func selections(of mark: Mark) -> [PDFSelection] {
        guard let document else { return [] }
        var out: [PDFSelection] = []
        for p in Int(mark.start.sentence)...max(Int(mark.start.sentence), Int(mark.end.sentence)) {
            guard let page = document.page(at: p) else { continue }
            let length = (page.string as NSString?)?.length ?? 0
            let from = p == Int(mark.start.sentence) ? Int(mark.start.offset) : 0
            let to = p == Int(mark.end.sentence) ? Int(mark.end.offset) : length
            guard to > from, to <= length, let piece = page.selection(for: NSRange(location: from, length: to - from)) else { continue }
            out.append(piece)
        }
        return out
    }

    @discardableResult
    func mark(_ selection: PDFSelection, style: MarkStyle? = nil) -> Mark? {
        guard let span = span(of: selection) else { return nil }
        let style = style ?? lastStyle
        remember(style)
        do {
            let mark = try core.addMark(book: bookID, section: 0, start: span.start, end: span.end, text: span.text, style: style, note: nil)
            reloadMarks()
            return mark
        } catch {
            failure = Library.message(for: error)
            return nil
        }
    }

    /// 写想法 on the selection: highlighted first, then the thought.
    func writeNote(on selection: PDFSelection) {
        if let mark = mark(selection) { writing = mark }
    }

    func setStyle(_ style: MarkStyle, of mark: Mark) {
        remember(style)
        run { try $0.core.setMarkStyle(book: $0.bookID, id: mark.id, style: style) }
    }

    func setNote(_ note: String?, of mark: Mark) {
        run { try $0.core.setMarkNote(book: $0.bookID, id: mark.id, note: note) }
    }

    /// 双击耳机: the sentence just heard, highlighted in the last colour used.
    func markHeard(_ spot: Player.Spot) {
        let page = Int(spot.section)
        let all = sentences(on: page)
        guard all.indices.contains(spot.sentence) else { return }
        let s = all[spot.sentence]
        let known = Set(marks.map(\.id))
        var made: Mark?
        run { made = try $0.core.markHeard(book: $0.bookID, section: 0, start: TextPoint(sentence: UInt32(page), offset: s.start),
                                             end: TextPoint(sentence: UInt32(page), offset: s.end), text: s.text, style: $0.lastStyle) }
        guard let made else { return }
        let new = !known.contains(made.id)
        show(Library.Toast(icon: "headphones", title: new ? String(localized: "划下了刚听到的这句") : String(localized: "这句已经划过了"), detail: "“\(s.text.prefix(16))”",
                           undo: new ? { [weak self] in self?.run { try $0.core.deleteMark(book: $0.bookID, id: made.id) } } : nil))
    }

    func deleteMark(_ mark: Mark) {
        run { try $0.core.deleteMark(book: $0.bookID, id: mark.id) }
        show(Library.Toast(icon: "highlighter", danger: true, title: String(localized: "已删除划线"),
                           detail: mark.note == nil ? "“\(mark.text.prefix(16))”" : String(localized: "想法也一起删了")) { [weak self] in
            self?.run { try $0.core.restoreMark(book: $0.bookID, id: mark.id) }
        })
    }

    func go(to mark: Mark) {
        go(to: Int(mark.start.sentence), range: selections(of: mark).isEmpty ? nil
            : NSRange(location: Int(mark.start.offset), length: mark.start.sentence == mark.end.sentence ? Int(mark.end.offset - mark.start.offset) : 0))
    }

    /// The page and sentence where a selection starts, to read from.
    func sentence(at selection: PDFSelection) -> (page: Int, sentence: Int)? {
        guard let span = span(of: selection) else { return nil }
        let p = Int(span.start.sentence)
        let offset = span.start.offset
        let i = sentences(on: p).lastIndex { $0.start <= offset } ?? 0
        return (p, i)
    }

    func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        show(Library.Toast(icon: "doc.on.doc", title: String(localized: "已复制"), detail: "“\(text.prefix(16))”"))
    }

    func reloadMarks() {
        marks = (try? core.marks(book: bookID)) ?? []
        NotificationCenter.default.post(name: .notesChanged, object: bookID)
    }

    private func remember(_ style: MarkStyle) {
        lastStyle = style
        UserDefaults.standard.set(style.css, forKey: "reader.markStyle")
    }

    private func run(_ work: (PdfModel) throws -> Void) {
        do {
            try work(self)
        } catch {
            failure = Library.message(for: error)
        }
        reloadMarks()
    }

    func show(_ toast: Library.Toast) {
        self.toast = toast
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Library.toastSeconds))
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
    }

    func undoToast() {
        guard let toast else { return }
        self.toast = nil
        toast.undo?()
    }

    #if DEBUG
    /// `-debugPdfMarks 1`: a few highlights on the page in view, and its fourth sentence lit as
    /// if being read, to look at without sound.
    func debugMarks() {
        let all = sentences(on: page)
        let styles: [MarkStyle] = [.yellow, .wave, .underline, .blue, .dotted]
        if marks.isEmpty {
            for (i, style) in styles.enumerated() where all.indices.contains(i * 2) {
                let s = all[i * 2]
                _ = try? core.addMark(book: bookID, section: 0, start: TextPoint(sentence: UInt32(page), offset: s.start),
                                      end: TextPoint(sentence: UInt32(page), offset: s.end), text: s.text, style: style,
                                      note: style == .wave ? String(localized: "这一句写得真好。") : nil)
            }
            reloadMarks()
        }
        if all.indices.contains(3) {
            let s = all[3]
            reading = Reading(page: page, sentence: 3, count: all.count, range: NSRange(location: Int(s.start), length: Int(s.end - s.start)))
        }
    }

    /// `-debugPdfVoice 1`: what the voice would read, written to the log, and the voice moved
    /// on to the next page's third sentence — without a sound.
    func debugVoice() {
        let script = script
        let p = UInt32(page)
        NSLog("debugPdfVoice language=%@ title=%@ next=%@ previous=%@", script.language(p), script.title(p) ?? "-",
              script.next(p).map(String.init) ?? "-", script.previous(p).map(String.init) ?? "-")
        for (i, s) in script.sentences(p + 1).prefix(4).enumerated() { NSLog("debugPdfVoice %d: %@", i, s) }
        heard(Player.Spot(section: p + 1, sentence: 2), playing: false)
    }
    #endif
}
