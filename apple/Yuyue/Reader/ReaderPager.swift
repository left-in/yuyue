import WebKit
import YuyueCore
#if os(iOS)
import UIKit
typealias PlatformView = UIView
#else
import AppKit
typealias PlatformView = NSView
#endif

protocol ReaderPagerDelegate: AnyObject {
    /// The visible page changed, or the section was laid out again.
    func pagerMoved(_ pager: ReaderPager)
    /// The reader started turning pages themselves (a swipe, a key).
    func pagerTurnedByHand(_ pager: ReaderPager)
    func pager(_ pager: ReaderPager, tapped message: ReaderMessage)
    /// The ink line started on, or moved on to, `page` of the current section.
    func pager(_ pager: ReaderPager, inkReachedPage page: Int)
    /// Text was selected on the page, or the selection went away (`text` nil).
    func pager(_ pager: ReaderPager, selected message: ReaderMessage)
    /// A double click on `sentence`.
    func pager(_ pager: ReaderPager, doubleTapped message: ReaderMessage)
}

/// Shows the book one section at a time and turns its pages (reader contract: native owns
/// everything that moves). The current section's neighbours are kept loaded on both sides, so
/// turning into the next chapter is as quick as turning a page.
///
/// iPhone and iPad: each section is a WebView whose own scroll view pages through it; those
/// sit side by side in a paging scroll view. A swipe past a section's last page is handed to
/// the outer scroll view without lifting the finger, so chapters join like pages.
/// Mac: CSS scroll snapping inside the WebView; keys, clicks and the toolbar turn pages.
final class ReaderPager: PlatformView {
    weak var delegate: ReaderPagerDelegate?
    let core: YuyueCore
    let bookID: String
    /// Used for the line length, which decides the side margins.
    var fontSize: Double = 18
    var mode: LayoutMode {
        didSet { if mode != oldValue { modeChanged() } }
    }
    var background: PlatformColor {
        didSet { slots.forEach { $0.setBackground(background) } }
    }

    private let messages = MessageProxy()
    private var schemeHandler: SchemeHandler!
    private var configuration: WKWebViewConfiguration!
    /// Loaded sections in reading order: the current one and its neighbours.
    private var slots: [SectionPage] = []
    private(set) var current: SectionPage?
    private var spare: [SectionPage] = []
    private var pendingOpen: (section: UInt32, target: SectionPage.Target)?
    private var appliedGeometry: PageGeometry?

    #if os(iOS)
    private let outer = SectionScrollView()
    /// Directions the outer scroll view may move during the current drag.
    private var outerMayMove: (forward: Bool, backward: Bool) = (false, false)
    private var arranging = false
    /// 下拉加书签: how far the page is pulled down, and whether the finger let go.
    var onPull: ((CGFloat, Bool) -> Void)?
    private let pull = UIPanGestureRecognizer()
    /// How far to pull before letting go adds the bookmark.
    static let pullMark: CGFloat = 64
    #endif

    init(core: YuyueCore, bookID: String, mode: LayoutMode, background: PlatformColor) {
        self.core = core
        self.bookID = bookID
        self.mode = mode
        self.background = background
        super.init(frame: .zero)
        messages.receiver = self
        schemeHandler = SchemeHandler(core: core) { [weak self] in
            self?.geometry() ?? PageGeometry(paging: .snap, margin: 24, top: 56, bottom: 88, columns: 1, reducedMotion: false)
        }
        configuration = .reader(schemeHandler: schemeHandler, messages: messages)
        #if os(iOS)
        outer.isPagingEnabled = true
        outer.showsHorizontalScrollIndicator = false
        outer.showsVerticalScrollIndicator = false
        outer.contentInsetAdjustmentBehavior = .never
        outer.delaysContentTouches = false
        outer.alwaysBounceHorizontal = true
        outer.alwaysBounceVertical = false
        outer.scrollsToTop = false
        outer.decelerationRate = .fast
        outer.delegate = self
        addSubview(outer)
        pull.addTarget(self, action: #selector(pulled(_:)))
        pull.delegate = self
        addGestureRecognizer(pull)
        #else
        wantsLayer = true
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Opening

    func open(section: UInt32, target: SectionPage.Target) {
        guard bounds.width > 0 else {
            pendingOpen = (section, target)
            return
        }
        pendingOpen = nil
        pin(section: section, target: target)
        if let current, current.section == section, current.isReady {
            Task {
                await current.go(to: target, animated: false)
                moved()
            }
            return
        }
        for slot in slots { recycle(slot) }
        let page = makePage()
        page.load(bookID: bookID, section: section, target: target)
        slots = [page]
        current = page
        show(page)
        loadNeighbours()
    }

    /// The words changed underneath (替换规则): loads the sections again, at the same place.
    func reload() {
        guard let here = position ?? current?.section.map({ Position(section: $0, sentence: 0) }) else { return }
        current = nil
        open(section: here.section, target: .sentence(Int(here.sentence)))
    }

    /// Keeps the sections on either side of the current one loaded, and lets the others go.
    private func loadNeighbours() {
        guard let current, let section = current.section else { return }
        var wanted: [SectionPage] = []
        if let previous = try? core.previousSection(bookId: bookID, section: section, speech: false) {
            wanted.append(page(for: previous, target: .end))
        }
        wanted.append(current)
        if let next = try? core.nextSection(bookId: bookID, section: section, speech: false) {
            wanted.append(page(for: next, target: .start))
        }
        for slot in slots where !wanted.contains(where: { $0 === slot }) { recycle(slot) }
        slots = wanted
        arrange()
        // The section just left keeps the page it was on; turning back into it starts at its edge.
        for slot in slots { join(slot) }
    }

    /// Puts a neighbour on the page that joins the current section: its last page when it comes
    /// before, its first when it comes after. Turning or swiping into it then arrives there.
    private func join(_ page: SectionPage) {
        guard page !== current, page.isReady,
              let i = slots.firstIndex(where: { $0 === page }),
              let c = slots.firstIndex(where: { $0 === current })
        else { return }
        Task { await page.go(to: i < c ? .end : .start, animated: false) }
    }

    private func page(for section: UInt32, target: SectionPage.Target) -> SectionPage {
        if let loaded = slots.first(where: { $0.section == section }) { return loaded }
        let page = makePage()
        page.load(bookID: bookID, section: section, target: target)
        return page
    }

    private func makePage() -> SectionPage {
        if let page = spare.popLast() { return page }
        let page = SectionPage(configuration: configuration, background: background)
        #if os(iOS)
        page.webView.scrollView.delegate = self
        configure(page.webView.scrollView)
        outer.addSubview(page.webView)
        #else
        page.webView.onKey = { [weak self] event in self?.key(event) ?? false }
        page.webView.menuItems = { [weak self] in self?.menuItems?() ?? [] }
        page.webView.isHidden = true
        // Hidden neighbours are laid out at the pager's size too, so their pages are the real ones.
        page.webView.frame = bounds
        page.webView.autoresizingMask = [.width, .height]
        addSubview(page.webView)
        #endif
        return page
    }

    private func recycle(_ page: SectionPage) {
        page.clear()
        #if os(macOS)
        page.webView.isHidden = true
        #endif
        if !spare.contains(where: { $0 === page }) { spare.append(page) }
    }

    // MARK: The reader's messages

    func received(_ m: ReaderMessage, from webView: WKWebView, frame: WKFrameInfo) {
        guard let page = slots.first(where: { $0.webView === webView }), page.sentByCurrentDocument(frame) else { return }
        switch m.type {
        case .ready, .layout:
            if m.type == .ready {
                // First: it rebuilds the section's boxes, the rest are drawn on them.
                if bubbles { sendBubbles(to: page) }
                sendMarks(to: page)
                sendHits(to: page)
                sendSource(to: page)
                sendForeign(to: page)
            }
            page.take(m)
            Task {
                let arrived = await page.settle()
                if arrived {
                    sendInk(to: page)
                } else {
                    // Laid out again, a neighbour may have moved off its joining page.
                    join(page)
                }
                // Arriving at the target is not a move: a position the pager was opened at stays,
                // even if the page it lands on reads as an earlier one (a window still taking its
                // size); and only a turn writes over where the book was left.
                if page === current { moved(relaidOut: true) }
            }
        case .tap:
            if page === current { delegate?.pager(self, tapped: m) }
        case .doubleTap:
            if page === current { delegate?.pager(self, doubleTapped: m) }
        case .activePage:
            if page === current, let p = m.page { delegate?.pager(self, inkReachedPage: p) }
        case .page:
            // A swipe on the trackpad; or, while settling, the page a new layout ended on.
            if let p = m.page {
                page.page = p
                if page === current { moved(relaidOut: page.settling) }
            }
        case .scroll:
            // Kept for a neighbour too: it may have been scrolled to its target before it comes in.
            page.scrolledTo = m.sentence
            if page === current { moved() }
        case .selection:
            if page === current { delegate?.pager(self, selected: m) }
        case .log:
            break
        }
    }

    /// The reading position: where the reader last moved to. Only moves change it. A new layout
    /// (a resize, another type size) keeps the same text in view under new page breaks, and the
    /// page it ends on can start well before this sentence; taking that page's first sentence
    /// instead would move the position back a little with every layout, and a book reopened at
    /// another size a page or more before where it was left.
    private(set) var position: Position?

    private func moved(relaidOut: Bool = false) {
        if !relaidOut || position?.section != current?.section, let here = onScreen { position = here }
        delegate?.pagerMoved(self)
    }

    /// A jump to a sentence makes it the position as long as its page is on screen: it is where
    /// the reader left off, even when the page it lands on now starts earlier. Any other jump
    /// takes the position from where it lands.
    private func pin(section: UInt32, target: SectionPage.Target) {
        if case .sentence(let s, _) = target {
            position = Position(section: section, sentence: UInt32(max(0, s)))
        } else {
            position = nil
        }
    }

    /// The first sentence on the page, or the first in view; in pages, the position while its page is
    /// still the one on screen.
    private var onScreen: Position? {
        guard let current, let section = current.section, let layout = current.layout else { return nil }
        if mode == .scrolled {
            return Position(section: section, sentence: UInt32(max(0, current.scrolledTo ?? layout.firstSentence(on: current.page))))
        }
        if let position, position.section == section, layout.page(of: Int(position.sentence)) == current.page { return position }
        return Position(section: section, sentence: UInt32(max(0, layout.firstSentence(on: current.page))))
    }

    // MARK: Turning pages

    /// 沉浸阅读 can turn whole pages without sliding.
    var calm = false

    var reduceMotion: Bool {
        #if os(iOS)
        calm || UIAccessibility.isReduceMotionEnabled
        #else
        calm || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #endif
    }

    /// Shows `section` with `target` in view: a turn when it is a neighbour, a jump otherwise.
    func show(section: UInt32, target: SectionPage.Target, animated: Bool) {
        guard let current else { return open(section: section, target: target) }
        if current.section == section {
            // A page turn: the position becomes the page's, as after any other.
            if case .sentence(let s, _) = target, let layout = current.layout {
                turn(to: layout.page(of: s), animated: animated)
            } else {
                Task {
                    await current.go(to: target, animated: false)
                    moved()
                }
            }
            return
        }
        guard let i = slots.firstIndex(where: { $0 === current }),
              let j = slots.firstIndex(where: { $0.section == section }), abs(i - j) == 1, slots[j].isReady
        else { return open(section: section, target: target) }
        let neighbour = slots[j]
        Task {
            await neighbour.go(to: target, animated: false)
            // The slots can have changed meanwhile.
            guard neighbour.section == section, let j = slots.firstIndex(where: { $0 === neighbour }) else {
                return open(section: section, target: target)
            }
            pin(section: section, target: target)
            move(toSlot: j, animated: animated)
        }
    }

    /// Turns one page; at a section's first or last page, into the neighbouring section.
    func turn(forward: Bool) {
        guard let current, let layout = current.layout else { return }
        let animated = !reduceMotion
        #if os(iOS)
        if mode == .scrolled {
            let scroll = current.webView.scrollView
            let step = scroll.bounds.height * 0.85
            let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
            let y = scroll.contentOffset.y
            if (forward && y < maxY - 1) || (!forward && y > 1) {
                scroll.setContentOffset(CGPoint(x: 0, y: min(maxY, max(0, y + (forward ? step : -step)))), animated: animated)
                return
            }
        } else {
            let target = current.page + (forward ? 1 : -1)
            if target >= 0 && target < layout.pageCount {
                turn(to: target, animated: animated)
                return
            }
        }
        guard let i = slots.firstIndex(where: { $0 === current }) else { return }
        let j = forward ? i + 1 : i - 1
        guard slots.indices.contains(j), slots[j].isReady else { return }
        move(toSlot: j, animated: animated)
        #else
        let generation = current.generation
        Task {
            let call = forward ? "yy.nextPage(a)" : "yy.prevPage(a)"
            // The page it turned to, or -1 at the section's edge.
            guard let landed = await current.ask("\(call) ? yy.currentPage() : -1", ["a": animated]) as? Int,
                  current === self.current, current.generation == generation
            else { return }
            if landed >= 0 {
                current.page = min(landed, layout.pageCount - 1)
                moved()
                return
            }
            guard let i = slots.firstIndex(where: { $0 === current }) else { return }
            let j = forward ? i + 1 : i - 1
            guard slots.indices.contains(j), slots[j].isReady else { return }
            move(toSlot: j, animated: animated)
        }
        #endif
    }

    /// Turns to a page of the current section.
    func turn(to page: Int, animated: Bool) {
        guard let current, let layout = current.layout else { return }
        let page = min(max(page, 0), layout.pageCount - 1)
        guard page != current.page else { return }
        #if os(iOS)
        if mode == .paginated {
            current.page = page
            current.webView.scrollView.setContentOffset(CGPoint(x: CGFloat(page) * bounds.width, y: 0), animated: animated)
            if !animated { moved() }
            return
        }
        #endif
        Task {
            await current.go(to: .page(page), animated: animated)
            moved()
        }
    }

    private func move(toSlot j: Int, animated: Bool) {
        #if os(iOS)
        guard let i = slots.firstIndex(where: { $0 === current }) else { return }
        outerMayMove = (j > i, j < i)
        if animated {
            outer.setContentOffset(CGPoint(x: CGFloat(j) * bounds.width, y: 0), animated: true)
        } else {
            outer.contentOffset = CGPoint(x: CGFloat(j) * bounds.width, y: 0)
            settle()
        }
        #else
        let page = slots[j]
        current = page
        show(page)
        loadNeighbours()
        moved()
        #endif
    }

    // MARK: The ink line

    private struct Ink {
        var section: UInt32
        var sentence: Int
        var durationMs: Double
        var elapsedMs: Double
        var playing: Bool
        var at = Date()
    }

    private var ink: Ink?

    /// Draws the ink line under a sentence being read: `elapsedMs` of `durationMs` read so far.
    /// A section loaded later picks it up where it has got to.
    func setInk(section: UInt32, sentence: Int, durationMs: Double, elapsedMs: Double, playing: Bool) {
        ink = Ink(section: section, sentence: sentence, durationMs: durationMs, elapsedMs: elapsedMs, playing: playing)
        slots.forEach(sendInk)
    }

    func clearInk() {
        ink = nil
        slots.forEach(sendInk)
    }

    private func sendInk(to page: SectionPage) {
        guard let ink, page.section == ink.section else { return page.call("yy.setActive(null)") }
        let elapsed = ink.elapsedMs + (ink.playing ? Date().timeIntervalSince(ink.at) * 1000 : 0)
        let options: [String: Any] = ["durationMs": ink.durationMs, "elapsedMs": min(elapsed, ink.durationMs), "playing": ink.playing]
        page.call("yy.setActive(s, o)", ["s": ink.sentence, "o": options])
    }

    // MARK: 气泡模式

    /// The book's dialogue as bubbles (docs/design/听书-气泡与有声书.html).
    var bubbles = false {
        didSet { if bubbles != oldValue { slots.forEach(sendBubbles) } }
    }

    /// Someone's side or name changed: draw the bubbles again.
    func bubblesChanged() {
        if bubbles { slots.forEach(sendBubbles) }
    }

    private func sendBubbles(to page: SectionPage) {
        guard let section = page.section else { return }
        guard bubbles else { return page.call("yy.setBubbles(null)") }
        let lines = ((try? core.sectionBubbles(bookId: bookID, section: section)) ?? []).map { l -> [String: Any] in
            ["first": Int(l.first), "last": Int(l.last), "start": Int(l.start), "end": Int(l.end), "who": l.who ?? NSNull(),
             "avatar": l.avatar, "color": l.color, "right": l.right]
        }
        page.call("yy.setBubbles(l)", ["l": lines])
    }

    // MARK: Highlights, search hits, selection

    private var marks: [Mark] = []
    /// 沉浸阅读 can leave the page without highlights for a while; they are only hidden.
    var marksHidden = false {
        didSet { if marksHidden != oldValue { slots.forEach(sendMarks) } }
    }
    /// …and without 难词注释.
    var glossesHidden = false {
        didSet { if glossesHidden != oldValue { slots.forEach(sendGlosses) } }
    }
    private var hits: (query: String, current: SearchHit?)?

    /// The book's highlights; each section draws its own.
    func setMarks(_ marks: [Mark]) {
        self.marks = marks
        slots.forEach(sendMarks)
    }

    /// Marks where `query` turns up; `current` in the solid colour. nil clears.
    func setHits(query: String?, current: SearchHit?) {
        hits = query.map { ($0, current) }
        slots.forEach(sendHits)
    }

    /// 书伴's 出处: one sentence washed in the accent until something else is pointed at.
    private var source: Position?

    func setSource(_ position: Position?) {
        source = position
        slots.forEach(sendSource)
    }

    private func sendSource(to page: SectionPage) {
        guard let source, page.section == source.section else { return page.call("yy.setSource(null)") }
        page.call("yy.setSource(s)", ["s": Int(source.sentence)])
    }

    private func sendMarks(to page: SectionPage) {
        guard let section = page.section else { return }
        let list: [[String: Any]] = marksHidden ? [] : marks.filter { $0.section == section }.map { m in
            ["id": m.id,
             "start": ["s": Int(m.start.sentence), "o": Int(m.start.offset)],
             "end": ["s": Int(m.end.sentence), "o": Int(m.end.offset)],
             "style": m.style.css,
             "note": m.note != nil]
        }
        page.call("yy.setMarks(m)", ["m": list])
    }

    private func sendHits(to page: SectionPage) {
        guard let hits, page.section != nil else { return page.call("yy.setHits(null)") }
        var current: Any = NSNull()
        if let hit = hits.current, hit.section == page.section {
            current = ["s": Int(hit.sentence), "nth": Int(hit.nth)]
        }
        page.call("yy.setHits(q, c)", ["q": hits.query, "c": current])
    }

    func clearSelection() {
        current?.call("yy.clearSelection()")
    }

    // MARK: 外文原著

    /// Clicks on words look them up (点词).
    var lookup = false {
        didSet { if lookup != oldValue { slots.forEach(sendForeign) } }
    }
    /// 生词: dotted wherever they turn up.
    private var vocab: [String] = []
    /// The word being looked up.
    private var looking: (section: UInt32, start: ReaderMessage.Point, end: ReaderMessage.Point)?
    /// 译: translates whole paragraphs; the answers are kept per section.
    var translator: (([String]) async -> [String?])?
    private(set) var translating = false
    private var translated: [UInt32: [[String: Any]]] = [:]
    private var inFlight: Set<UInt32> = []

    /// 难词注释: the harder words of a section and their meanings, from the core.
    var glosser: ((UInt32) -> [[String: String]])?
    private var glossed: [UInt32: [[String: String]]] = [:]

    /// The level or the 生词本 changed: work the meanings out again.
    func refreshGlosses() {
        guard glosser != nil else { return }
        glossed = [:]
        slots.forEach(sendGlosses)
    }

    private func sendGlosses(to page: SectionPage) {
        guard let section = page.section, let glosser else { return }
        if glossesHidden { return page.call("yy.setGlosses(null)") }
        let list = glossed[section] ?? glosser(section)
        glossed[section] = list
        page.call("yy.setGlosses(g)", ["g": list])
    }

    func setVocab(_ words: [String]) {
        guard words != vocab else { return }
        vocab = words
        for page in slots where page.section != nil { page.call("yy.setVocab(w)", ["w": words]) }
    }

    func setLooking(section: UInt32, start: ReaderMessage.Point, end: ReaderMessage.Point) {
        looking = (section, start, end)
        slots.forEach(sendLooking)
    }

    func clearLooking() {
        guard looking != nil else { return }
        looking = nil
        slots.forEach(sendLooking)
    }

    /// 有声书: an amber line beside the paragraphs of sentences first…last, for a stretch the
    /// recording doesn't line up with.
    private var flag: (section: UInt32, first: Int, last: Int)?

    func setFlag(section: UInt32, first: Int, last: Int) {
        if let flag, flag == (section, first, last) { return }
        flag = (section, first, last)
        slots.forEach(sendFlag)
    }

    func clearFlag() {
        guard flag != nil else { return }
        flag = nil
        slots.forEach(sendFlag)
    }

    private func sendFlag(to page: SectionPage) {
        guard page.section != nil else { return }
        guard let flag, page.section == flag.section else { return page.call("yy.setFlag(null)") }
        page.call("yy.setFlag(a, b)", ["a": flag.first, "b": flag.last])
    }

    /// 译 on or off.
    func setTranslating(_ on: Bool) {
        guard on != translating else { return }
        translating = on
        for page in slots where page.section != nil {
            if on { translate(page) } else { page.call("yy.setTranslations(null)") }
        }
    }

    private func sendForeign(to page: SectionPage) {
        guard page.section != nil else { return }
        page.call("yy.setLookup(on)", ["on": lookup])
        if !vocab.isEmpty { page.call("yy.setVocab(w)", ["w": vocab]) }
        sendGlosses(to: page)
        sendLooking(to: page)
        sendFlag(to: page)
        if translating { translate(page) }
    }

    private func sendLooking(to page: SectionPage) {
        guard let looking, page.section == looking.section else { return page.call("yy.setLooking(null, null)") }
        page.call("yy.setLooking(a, b)", ["a": ["s": looking.start.s, "o": looking.start.o], "b": ["s": looking.end.s, "o": looking.end.o]])
    }

    private func translate(_ page: SectionPage) {
        guard let section = page.section else { return }
        if let done = translated[section] { return page.call("yy.setTranslations(t)", ["t": done]) }
        guard !inFlight.contains(section) else { return }
        inFlight.insert(section)
        Task {
            defer { inFlight.remove(section) }
            guard let translator, let list = await page.ask("yy.paragraphs()") as? [[String: Any]], !list.isEmpty else { return }
            let texts = list.map { $0["text"] as? String ?? "" }
            let out = await translator(texts)
            var items: [[String: Any]] = []
            for (p, t) in zip(list, out) {
                if let t, let last = p["last"] { items.append(["last": last, "text": t]) }
            }
            guard !items.isEmpty else { return }
            translated[section] = items
            if translating, page.section == section { page.call("yy.setTranslations(t)", ["t": items]) }
        }
    }

    /// Selects a highlight's text on the page, to show which one a card is about.
    func select(_ mark: Mark) {
        let start: [String: Any] = ["s": Int(mark.start.sentence), "o": Int(mark.start.offset)]
        let end: [String: Any] = ["s": Int(mark.end.sentence), "o": Int(mark.end.offset)]
        current?.call("yy.select(a, b)", ["a": start, "b": end])
    }

    /// Where a highlight is drawn on the current page, in the pager's coordinates.
    func rect(of mark: Mark) async -> CGRect? {
        guard let current, current.section == mark.section,
              let r = await current.ask("yy.markRect(id)", ["id": mark.id]) as? [String: Any],
              let x = (r["x"] as? NSNumber)?.doubleValue, let y = (r["y"] as? NSNumber)?.doubleValue,
              let w = (r["width"] as? NSNumber)?.doubleValue, let h = (r["height"] as? NSNumber)?.doubleValue
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Settings and geometry

    /// Sends reader settings (contract §4) to the loaded sections, together with the page
    /// geometry, which may depend on them. Sections loaded later get both from the core.
    func apply(settings: [String: Any]) {
        let g = geometry()
        appliedGeometry = g
        let all = settings.merging(Self.settings(for: g)) { $1 }
        for page in slots { page.call("yy.applySettings(s)", ["s": all]) }
    }

    private static func settings(for g: PageGeometry) -> [String: Any] {
        ["margin": g.margin, "top": g.top, "bottom": g.bottom, "cols": Int(g.columns),
         "paging": g.paging == .native ? "native" : "snap", "motion": g.reducedMotion ? "reduced" : "full"]
    }

    /// The page geometry each device decides for itself (`PageGeometry`).
    /// 单栏 / 双栏: two pages side by side when the window is wide enough for them.
    var prefersTwoColumns = true {
        didSet { if prefersTwoColumns != oldValue { geometryChanged() } }
    }
    /// 播客: an episode's script is a chat, one host on the left and one on the right; two
    /// pages side by side would halve each bubble's width and lose that. Always one column.
    var chat = false {
        didSet { if chat != oldValue { geometryChanged() } }
    }

    func geometry() -> PageGeometry {
        let width = Double(bounds.width)
        let columns: UInt8 = prefersTwoColumns && !chat && width >= 880 && mode == .paginated ? 2 : 1
        // About 30 characters to a line at most (`.v-mac-col`: 460 wide at 15); wider pages get
        // wider margins instead.
        let measure = fontSize * 31
        let margin = max(width < 500 ? 24 : 40, (width / Double(columns) - measure) / 2).rounded()
        #if os(iOS)
        let top = Double(safeAreaInsets.top) + 28
        let bottom = Double(safeAreaInsets.bottom) + 40
        let paging = Paging.native
        #else
        // The reading capsule floats over the bottom of the page.
        let top = 40.0
        let bottom = 96.0
        let paging = Paging.snap
        #endif
        return PageGeometry(paging: paging, margin: margin, top: top.rounded(), bottom: bottom.rounded(), columns: columns, reducedMotion: reduceMotion)
    }

    private func geometryChanged() {
        guard bounds.width > 0 else { return }
        let g = geometry()
        guard g != appliedGeometry else { return }
        let first = appliedGeometry == nil
        appliedGeometry = g
        if !first { apply(settings: [:]) }
    }

    /// The reader's `mode` itself arrives with the settings; this sets up the scrolling around it.
    private func modeChanged() {
        // The other mode shows the text from another start: the position is taken again from
        // what it shows, as the reader does.
        position = nil
        #if os(iOS)
        for page in slots + spare { configure(page.webView.scrollView) }
        outer.isScrollEnabled = mode == .paginated
        #endif
    }

    // MARK: Layout

    #if os(iOS)
    override func layoutSubviews() {
        super.layoutSubviews()
        if outer.frame != bounds {
            outer.frame = bounds
            arrange()
        }
        afterLayout()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        geometryChanged()
    }
    #else
    override func layout() {
        super.layout()
        afterLayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The page keys work as soon as the book opens, without clicking into the page first.
        if let current { window?.makeFirstResponder(current.webView) }
    }
    #endif

    private func afterLayout() {
        guard bounds.width > 0 else { return }
        geometryChanged()
        if let pendingOpen { open(section: pendingOpen.section, target: pendingOpen.target) }
    }

    private func arrange() {
        #if os(iOS)
        arranging = true
        defer { arranging = false }
        let w = bounds.width, h = bounds.height
        for (i, page) in slots.enumerated() {
            page.webView.frame = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: h)
            page.webView.isHidden = false
        }
        for page in spare { page.webView.isHidden = true }
        outer.contentSize = CGSize(width: CGFloat(slots.count) * w, height: h)
        if let current, let i = slots.firstIndex(where: { $0 === current }) {
            outer.contentOffset = CGPoint(x: CGFloat(i) * w, y: 0)
        }
        #endif
    }

    private func show(_ page: SectionPage) {
        #if os(macOS)
        for slot in slots + spare where slot !== page { slot.webView.isHidden = true }
        page.webView.frame = bounds
        page.webView.isHidden = false
        window?.makeFirstResponder(page.webView)
        #endif
    }

    #if os(macOS)
    /// Keys the window wants before the page turns, such as 1–4 for a highlight colour.
    var keyHandler: ((NSEvent) -> Bool)?
    /// What right-clicking the page offers.
    var menuItems: (() -> [NSMenuItem])?

    private func key(_ event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        let forward: Bool
        switch event.keyCode {
        case 123, 116: forward = false  // ← page up
        case 124, 121: forward = true  // → page down
        // Scrolling, ↑ and ↓ move by lines as anywhere else; the other keys move by a screen
        // and carry on into the next section at the end of this one.
        case 126 where mode == .paginated: forward = false  // ↑
        case 125 where mode == .paginated: forward = true  // ↓
        case 49: forward = !event.modifierFlags.contains(.shift)  // space
        default: return false
        }
        delegate?.pagerTurnedByHand(self)
        turn(forward: forward)
        return true
    }
    #endif
}

extension SectionPage {
    func setBackground(_ color: PlatformColor) {
        #if os(iOS)
        webView.backgroundColor = color
        webView.scrollView.backgroundColor = color
        #else
        webView.underPageBackgroundColor = color
        #endif
    }
}

#if os(iOS)
/// Lets the sections' own scroll views track the same touch, so one swipe can turn the last
/// page of a section and carry on into the next.
final class SectionScrollView: UIScrollView, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === panGestureRecognizer && other.view is UIScrollView && other.view !== self
    }
}

extension ReaderPager: UIGestureRecognizerDelegate {
    /// Only a pull straight down on a page that turns sideways.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === pull else { return super.gestureRecognizerShouldBegin(g) }
        let v = pull.velocity(in: self)
        return mode == .paginated && onPull != nil && v.y > 0 && v.y > abs(v.x) * 2
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === pull
    }

    @objc fileprivate func pulled(_ g: UIPanGestureRecognizer) {
        // The paper comes down at half the finger's pace, and no further than a little past the mark.
        let shown = min(Self.pullMark * 1.6, max(0, g.translation(in: self).y) * 0.5)
        switch g.state {
        case .began, .changed:
            outer.transform = CGAffineTransform(translationX: 0, y: shown)
            onPull?(shown, false)
        default:
            onPull?(g.state == .ended ? shown : 0, true)
            UIView.animate(withDuration: reduceMotion ? 0 : 0.25, delay: 0, options: .curveEaseOut) {
                self.outer.transform = .identity
            }
        }
    }
}

extension ReaderPager: UIScrollViewDelegate {
    private func configure(_ scroll: UIScrollView) {
        let paged = mode == .paginated
        scroll.isPagingEnabled = paged
        // At a section's edge the outer scroll view takes over, so the inner one must not bounce.
        scroll.bounces = !paged
        scroll.alwaysBounceHorizontal = false
        scroll.alwaysBounceVertical = !paged
    }

    private func x(of page: SectionPage) -> CGFloat {
        CGFloat(slots.firstIndex(where: { $0 === page }) ?? 0) * bounds.width
    }

    private func atStart(_ s: UIScrollView) -> Bool { s.contentOffset.x <= 1 }
    private func atEnd(_ s: UIScrollView) -> Bool { s.contentOffset.x >= s.contentSize.width - s.bounds.width - 1 }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        delegate?.pagerTurnedByHand(self)
        guard scrollView === outer, let current else { return }
        let inner = current.webView.scrollView
        outerMayMove = (atEnd(inner), atStart(inner))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !arranging, mode == .paginated, let current, bounds.width > 0 else { return }
        let inner = current.webView.scrollView
        let base = x(of: current)
        let d = outer.contentOffset.x - base
        if scrollView === outer {
            // Within a section the section's own pages turn; the outer view only moves at its edges.
            if (d > 0 && !outerMayMove.forward) || (d < 0 && !outerMayMove.backward) {
                outer.contentOffset.x = base
            }
        } else if scrollView === inner {
            if d > 0.5 {
                inner.contentOffset.x = max(0, inner.contentSize.width - inner.bounds.width)
            } else if d < -0.5 {
                inner.contentOffset.x = 0
            }
        } else if scrollView.isDragging || scrollView.isDecelerating,
                  let i = slots.firstIndex(where: { $0.webView.scrollView === scrollView }),
                  let c = slots.firstIndex(where: { $0 === current }) {
            // A neighbour seen during a turn keeps showing the page that joins this section.
            scrollView.contentOffset.x = i < c ? max(0, scrollView.contentSize.width - scrollView.bounds.width) : 0
        }
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard scrollView === outer, let current else { return }
        let base = x(of: current)
        let target = targetContentOffset.pointee.x
        if (target > base && !outerMayMove.forward) || (target < base && !outerMayMove.backward) {
            targetContentOffset.pointee.x = base
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { ended(scrollView) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        ended(scrollView)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        ended(scrollView)
    }

    private func ended(_ scrollView: UIScrollView) {
        if scrollView === outer {
            settle()
        } else if let current, scrollView === current.webView.scrollView, mode == .paginated, bounds.width > 0 {
            let page = Int((scrollView.contentOffset.x / bounds.width).rounded())
            current.page = page
            moved()
        }
    }

    /// After the outer view comes to rest: if it rests on a neighbour, that section is current now.
    private func settle() {
        outerMayMove = (false, false)
        guard bounds.width > 0 else { return }
        let i = Int((outer.contentOffset.x / bounds.width).rounded())
        guard slots.indices.contains(i) else { return }
        if slots[i] !== current {
            current = slots[i]
            loadNeighbours()
        }
        moved()
    }
}
#endif
