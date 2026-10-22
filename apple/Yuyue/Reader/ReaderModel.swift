import AVFoundation
import SwiftUI
import YuyueCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// One open book: where the reader is, how the pages look, and the voice reading it aloud.
@Observable
final class ReaderModel {
    let bookID: String
    let detail: BookDetail?
    private(set) var settings: ReaderSettings
    /// Whether this book keeps settings of its own (只用于这本书).
    private(set) var ownSettings = false
    /// The Mac window's panel on the right.
    var panel: ReaderPanel?
    /// Words handed to the companion (问).
    var companionQuote: String?
    /// 与书对话.
    let companion = BookCompanion()
    /// 搜索 · 问 ⌘K over this window.
    var quickSearchShown = false
    /// 外文原著: the word clicked, and its card.
    var lookup: WordLookup?
    /// This book's words in the 生词本, in reading order.
    var bookWords: [VocabWord] = []
    /// 双击一句只翻这一句.
    var sentenceTranslation: SentenceTranslation?
    /// 译: translations under every paragraph.
    var translateShown = false
    @ObservationIgnored let translator = Translator()
    @ObservationIgnored var speaker: AVSpeechSynthesizer?
    /// 只听: the text hidden while the voice reads.
    var listenOnly = false
    /// 沉浸阅读: only the words on the page.
    var immersive = false {
        didSet { applyImmersive() }
    }

    private func applyImmersive() {
        // 墨水屏 turns whole pages, never slides them.
        pager.calm = (immersive && ImmersivePrefs.stillPages) || settings.paper == .eink
        pager.marksHidden = immersive && ImmersivePrefs.hidesMarks
        pager.glossesHidden = immersive && ImmersivePrefs.hidesHints
        if immersive { panel = nil }
    }
    /// The section on screen, and its page.
    private(set) var section: UInt32?
    private(set) var page = 0
    private(set) var pageCount = 1
    var chromeShown = false
    var tocShown = false
    var settingsShown = false
    /// 替换规则, from 更多 or the menu bar.
    var rulesShown = false
    /// 编码和目录, for a TXT.
    var txtShown = false
    /// Why the TXT may have been read wrong, for the hint that leads to 编码和目录.
    var txtDoubt: String?
    var failure: String?
    let player: Player?

    /// The sentence the reader is at in the current section: the one being read aloud, or the
    /// first on the page.
    private(set) var sentence = 0
    var marks: [Mark] = []
    var bookmarks: [Bookmark] = []
    var times: [UInt32: SectionTime] = [:]
    /// Text selected on the page, for the card over it.
    var selection: TextSelection?
    /// A highlight clicked on the page, for the card over it.
    var openMark: OpenMark?
    /// 脚注: a note marker tapped, its note in a card over the page.
    var openNote: OpenNote?
    /// 书内搜索.
    var searchShown = false
    /// Bumped when the open search field should take the keyboard again.
    var searchFieldWanted = 0
    var query = ""
    var hits: [SearchHit] = []
    var hitIndex: Int?
    /// The colour a highlight gets when none is picked: the last one used.
    var lastStyle: MarkStyle = .yellow
    /// The undo note at the bottom of the page.
    var toast: Library.Toast?
    /// 进度冲突: where another device read to, offered when the book opens.
    var elsewhere: Elsewhere?
    /// 回到原处: where the reader was before jumping off (目录, 搜索, a link, 出处), kept until
    /// a few pages have been read in the new place.
    private(set) var returnTo: (position: Position, page: Int?)?
    /// 前情提要, over the page until 接着读 or a page is turned.
    var recap: Recap?
    /// 有声书: the stretch being read that the recording doesn't line up with (`ReaderFlag`).
    var narrationFlag: NarrationFlag?
    var adjustingFlag: NarrationFlag?
    @ObservationIgnored var flagTimings: Timings?
    @ObservationIgnored var flagIssues: [Issue] = []
    @ObservationIgnored var flagsLetBe: Set<String> = []
    @ObservationIgnored private var turnsSinceJump = 0

    struct Elsewhere {
        let progress: ReadingProgress
        /// How far this device is.
        let here: Double
        let text: String?
        let chapter: String?
    }

    @ObservationIgnored let pager: ReaderPager
    @ObservationIgnored let core: YuyueCore
    @ObservationIgnored private(set) weak var library: Library?
    @ObservationIgnored private var madeNoteSender: NoteSender?
    /// 导出笔记's sends, told on the page.
    var noteSender: NoteSender {
        if let s = madeNoteSender { return s }
        let s = NoteSender(core: core) { [weak self] in self?.show($0) }
        madeNoteSender = s
        return s
    }
    /// After a page is turned by hand the pages stop following the voice for a while, so the
    /// reader can look back without being pulled along.
    @ObservationIgnored private var followFrom = Date.distantPast
    @ObservationIgnored private var saved: Position?
    /// Opening a book only shows where it was; the position is written once the reader moves,
    /// so a glance on one device doesn't bury further reading on another.
    @ObservationIgnored private var opened = false
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored var clock = TimeClock()
    @ObservationIgnored var searching: Task<Void, Never>?
    @ObservationIgnored private var watching: [Task<Void, Never>] = []
    /// The book is being built again; this model is about to be replaced and writes nothing more.
    @ObservationIgnored private var retired = false
    /// Heard at once, not later on a task: the core builds the book right after it's posted.
    @ObservationIgnored private var rebuildObserver: NSObjectProtocol?

    init(library: Library, bookID: String) {
        let core = library.core
        self.core = core
        self.library = library
        self.bookID = bookID
        var detail: BookDetail?
        var failure: String?
        do {
            detail = try core.book(id: bookID)
        } catch {
            failure = Library.message(for: error)
        }
        self.detail = detail
        let own = (try? core.bookReaderSettings(bookId: bookID)) ?? nil
        var settings = own ?? (try? core.readerSettings()) ?? .standard
        // 我的 › 墨水屏: a book with its own paper reads on e-ink too.
        if EInk.on { settings.paper = .eink }
        self.settings = settings
        self.ownSettings = own != nil
        pager = ReaderPager(core: core, bookID: bookID, mode: settings.mode, background: settings.paper.tokens.platformBackground)
        player = detail.map { Player(core: core, detail: $0) }
        self.failure = failure
        companion.model = self
        pager.fontSize = settings.fontSize
        pager.delegate = self
        if let player {
            player.recording = Audiobooks.shared?.recording(for: bookID)
            loadFlags()
            let rate = UserDefaults.standard.float(forKey: Self.rateKey)
            if rate > 0 { player.rate = rate }
            player.onSentence = { [weak self] spot, duration, elapsed, playing in
                self?.reading(spot, durationMs: duration, elapsedMs: elapsed, playing: playing)
                self?.setListening(playing)
            }
            player.onStop = { [weak self] in
                self?.pager.clearInk()
                self?.showFlag(nil)
                self?.setListening(false)
            }
            player.onSleep = { [weak self] spot in self?.fellAsleep(at: spot) }
            player.onMarkHeard = { [weak self] spot in self?.markHeard(spot) }
        }
        // 我的 › 沉浸阅读 on: every book opens with only its words.
        immersive = ImmersivePrefs.always
        applyImmersive()
        loadNotes()
        setUpForeign()
        if detail?.summary.format == .txt, let doubt = (try? core.txtDoubt(bookId: bookID)) ?? nil,
           UserDefaults.standard.string(forKey: Self.doubtKey(bookID)) != doubt {
            txtDoubt = doubt
        }
        rebuildObserver = NotificationCenter.default.addObserver(forName: .bookWillRebuild, object: nil, queue: nil) { [weak self] n in
            let id = n.object as? String
            MainActor.assumeIsolated {
                guard let self, id == self.bookID else { return }
                self.retire()
            }
        }
        watching = [
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: .readerSettingsChanged) {
                    self?.sharedSettingsChanged()
                }
            },
            Task { [weak self] in
                for await n in NotificationCenter.default.notifications(named: .replaceRulesChanged) {
                    guard let self, n.object == nil || n.object as? String == self.bookID else { continue }
                    self.player?.textsChanged()
                    self.pager.reload()
                    if !self.query.isEmpty { self.search() }
                }
            },
            Task { [weak self] in
                // 霞鹜文楷 arrived: the open sections load again, now with its @font-face.
                for await _ in NotificationCenter.default.notifications(named: .fontsChanged) {
                    self?.pager.reload()
                }
            },
            Task { [weak self] in
                for await n in NotificationCenter.default.notifications(named: .readerJump) {
                    guard let self, n.object as? String == self.bookID else { continue }
                    switch self.library?.takeIntent(for: self.bookID) {
                    case .at(let p): self.jump(section: p.section, sentence: Int(p.sentence))
                    case .ask(let q): self.ask(q)
                    default: break
                    }
                }
            },
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: .vocabChanged) { self?.loadVocab() }
            },
        ]
        if let detail {
            // Pick up where this book was left, on whichever device that was; or from the
            // top when the shelf said 从头听.
            let intent = library.takeIntent(for: bookID)
            let start = Position(section: detail.start, sentence: 0)
            let mine = try? core.progress(bookId: bookID)
            let latest = try? core.latestProgress(bookId: bookID)
            var position = intent == .listenFromStart ? start : mine?.position ?? latest?.position ?? start
            if case .at(let there) = intent { position = there }
            if case .ask(let q) = intent { ask(q) }
            // 进度冲突: this device has its own place, but another read on later, elsewhere.
            if intent == nil, let mine, let latest, !latest.thisDevice, latest.at > mine.at, latest.position != mine.position {
                let sentences = (try? core.sentences(bookId: bookID, section: latest.position.section)) ?? []
                let i = Int(latest.position.sentence)
                elsewhere = Elsewhere(progress: latest, here: mine.fraction,
                                      text: sentences.indices.contains(i) ? sentences[i] : nil,
                                      chapter: detail.chapterTitle(for: latest.position.section))
            }
            if intent == nil, elsewhere == nil, let last = latest ?? mine {
                startRecap(lastRead: last.at, here: position)
            }
            pager.open(section: position.section, target: position.sentence == 0 ? .start : .sentence(Int(position.sentence)))
            if intent == .listen || intent == .listenFromStart, let player {
                player.play(from: position)
            }
        }
    }

    /// Opens 书伴 with a question.
    func ask(_ question: String) {
        panel = .companion
        if !question.isEmpty { companion.ask(question, quote: companionQuote) }
    }

    /// Writes the position, stops reading aloud. The window is going away.
    func close() {
        tick(closing: true)
        flush()
        player?.close()
        setListening(false)
        watching.forEach { $0.cancel() }
        rebuildObserver.map(NotificationCenter.default.removeObserver)
        rebuildObserver = nil
    }

    private static func doubtKey(_ bookID: String) -> String { "txtDoubtDismissed.\(bookID)" }

    /// 不用了 on the hint: it doesn't come back for the same doubt.
    func dismissDoubt() {
        if let txtDoubt { UserDefaults.standard.set(txtDoubt, forKey: Self.doubtKey(bookID)) }
        txtDoubt = nil
    }

    /// Before the book is built again (编码和目录): where the reader is gets written in the old
    /// chapters, so the core can carry it over, and nothing is written after that.
    func retire() {
        guard !retired else { return }
        close()
        retired = true
    }

    // MARK: Moving around

    func turn(forward: Bool) {
        turnedByHand()
        pager.turn(forward: forward)
    }

    func go(to item: TocItem) {
        leaving()
        turnedByHand()
        pager.show(section: item.section, target: item.anchor.map { .anchor($0) } ?? .start, animated: false)
    }

    func goToChapter(forward: Bool) {
        guard let section else { return }
        let next: UInt32?
        if forward {
            next = try? core.nextSection(bookId: bookID, section: section, speech: false)
        } else {
            next = try? core.previousSection(bookId: bookID, section: section, speech: false)
        }
        guard let next else { return }
        turnedByHand()
        pager.show(section: next, target: .start, animated: false)
    }

    /// 跳过去: to where the other device stopped; the voice goes along.
    func jumpElsewhere() {
        guard let e = elsewhere else { return }
        elsewhere = nil
        turnedByHand()
        opened = true
        let p = e.progress.position
        pager.show(section: p.section, target: .sentence(Int(p.sentence), align: .third), animated: false)
        if isPlaying { player?.play(from: p) }
    }

    /// About to jump: the place to come back to, unless one is kept already.
    func leaving() {
        turnsSinceJump = 0
        guard returnTo == nil, opened, let here = pager.position else { return }
        returnTo = (here, bookPage)
    }

    /// 回到第 N 页.
    func goBack() {
        guard let back = returnTo?.position else { return }
        returnTo = nil
        turnedByHand()
        pager.show(section: back.section, target: .sentence(Int(back.sentence), align: .third), animated: false)
    }

    var chapterTitle: String? {
        section.flatMap { detail?.chapterTitle(for: $0) }
    }

    /// "3 / 12" in paginated mode.
    var pageLabel: String? {
        settings.mode == .paginated && section != nil ? "\(page + 1) / \(pageCount)" : nil
    }

    /// The table of contents entry the reader is in.
    var tocIndex: Int? {
        guard let section, let toc = detail?.toc else { return nil }
        return toc.lastIndex { $0.section <= section }
    }

    private func turnedByHand() {
        followFrom = Date().addingTimeInterval(8)
        clock.lastTurn = Date()
    }

    private var following: Bool { Date() >= followFrom }

    /// Opens a note in place; false when there's nothing there to show, and the link is followed.
    private func showNote(target: String, marker: ReaderMessage.Note) -> Bool {
        guard let section = pager.current?.section,
              let note = (try? core.footnote(bookId: bookID, fromSection: section, target: target)) ?? nil
        else { return false }
        selection = nil
        openNote = OpenNote(note: note, label: marker.label, before: marker.before, target: target)
        return true
    }

    /// 到注释页, with 回到原处 left behind.
    func goToNotes() {
        guard let open = openNote else { return }
        openNote = nil
        follow(link: open.target)
    }

    private func follow(link target: String) {
        let parts = target.split(separator: "#", maxSplits: 1)
        guard let first = parts.first, let section = UInt32(first) else { return }
        leaving()
        turnedByHand()
        pager.show(section: section, target: parts.count > 1 ? .anchor(String(parts[1]), align: .third) : .start, animated: false)
    }

    private func openExternal(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    // MARK: Reading aloud

    var isPlaying: Bool {
        player?.state == .playing || player?.state == .loading
    }

    /// Pauses; or reads on from what's on screen. Paused on a sentence that is still on the
    /// page, it carries on from there.
    func togglePlay() {
        guard let player else { return }
        switch player.state {
        case .playing, .loading:
            player.pause()
        case .paused where player.spot.map(isOnScreen) == true:
            followFrom = .distantPast
            player.resume()
        case .paused, .stopped:
            guard let position = pager.position else { return }
            followFrom = .distantPast
            player.play(from: position)
        }
    }

    var rate: Float {
        get { player?.rate ?? 1 }
        set {
            player?.rate = newValue
            UserDefaults.standard.set(newValue, forKey: Self.rateKey)
        }
    }

    private static let rateKey = "player.rate"

    private func isOnScreen(_ spot: Player.Spot) -> Bool {
        guard let current = pager.current, current.section == spot.section, let layout = current.layout else { return false }
        return settings.mode == .scrolled || layout.page(of: spot.sentence) == current.page
    }

    /// Lets the shelf show 听中 on this book.
    private func setListening(_ playing: Bool) {
        guard let library else { return }
        if playing {
            if library.listening != bookID { library.listening = bookID }
        } else if library.listening == bookID {
            library.listening = nil
        }
    }

    private func reading(_ spot: Player.Spot, durationMs: Double, elapsedMs: Double, playing: Bool) {
        checkFlag(spot)
        if spot.section == section, sentence != spot.sentence { sentence = spot.sentence }
        pager.setInk(section: spot.section, sentence: spot.sentence, durationMs: durationMs, elapsedMs: elapsedMs, playing: playing)
        // Into the next chapter with the voice. Within a section the reader says when the ink
        // reaches another page (`inkReachedPage`).
        if following, spot.section != pager.current?.section {
            pager.show(section: spot.section, target: .sentence(spot.sentence, align: .third), animated: !pager.reduceMotion)
        }
    }

    // MARK: Settings

    func update(_ change: (inout ReaderSettings) -> Void) {
        var new = settings
        change(&new)
        guard new != settings else { return }
        settings = new
        do {
            if ownSettings {
                try core.setBookReaderSettings(bookId: bookID, settings: new)
            } else {
                try core.setReaderSettings(settings: new)
            }
        } catch {
            failure = Library.message(for: error)
        }
        applyToPager(new)
    }

    /// 只用于这本书: the book keeps its own settings from now on, or goes back to the shared ones.
    func setOwnSettings(_ on: Bool) {
        guard on != ownSettings else { return }
        ownSettings = on
        do {
            try core.setBookReaderSettings(bookId: bookID, settings: on ? settings : nil)
        } catch {
            failure = Library.message(for: error)
        }
        if !on, let shared = try? core.readerSettings(), shared != settings {
            settings = shared
            applyToPager(shared)
        }
    }

    /// 设置 · 阅读 changed the shared settings: books without their own follow.
    private func sharedSettingsChanged() {
        guard !ownSettings, let shared = try? core.readerSettings(), shared != settings else { return }
        settings = shared
        applyToPager(shared)
    }

    private func applyToPager(_ new: ReaderSettings) {
        pager.fontSize = new.fontSize
        pager.mode = new.mode
        pager.background = new.paper.tokens.platformBackground
        pager.apply(settings: new.script)
        applyImmersive()
    }

    // MARK: Progress

    private func save(_ position: Position) {
        guard position != saved, !retired else { return }
        saved = position
        saving?.cancel()
        saving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.saving = nil
            self.write(position)
        }
    }

    /// Writes a position still waiting to be written.
    func flush() {
        guard let saving else { return }
        saving.cancel()
        self.saving = nil
        if let saved { write(saved) }
    }

    private func write(_ position: Position) {
        do {
            try core.saveProgress(bookId: bookID, position: position)
        } catch {
            failure = Library.message(for: error)
        }
    }
}

extension ReaderModel: ReaderPagerDelegate {
    func pagerMoved(_ pager: ReaderPager) {
        guard let current = pager.current, let layout = current.layout else { return }
        if section != current.section { tick() }
        section = current.section
        page = current.page
        pageCount = layout.pageCount
        if let position = pager.position {
            if opened { save(position) } else { opened = true; saved = position }
            if player?.spot?.section != current.section || !isPlaying { sentence = Int(position.sentence) }
        }
    }

    func pagerTurnedByHand(_ pager: ReaderPager) {
        turnedByHand()
        if openNote != nil { openNote = nil }
        if recap != nil { recap = nil }
        // Read on a few pages where the jump landed: no going back any more.
        if returnTo != nil {
            turnsSinceJump += 1
            if turnsSinceJump >= 3 { returnTo = nil }
        }
    }

    func pager(_ pager: ReaderPager, tapped m: ReaderMessage) {
        if let word = m.word, isForeign, m.link == nil {
            return look(up: word)
        }
        if lookup != nil || sentenceTranslation != nil {
            closeLookup()
            sentenceTranslation = nil
            return
        }
        if let id = m.mark, let mark = marks.first(where: { $0.id == id }) {
            selection = nil
            openMark = OpenMark(mark: mark, at: CGPoint(x: m.x ?? 0, y: m.y ?? 0))
            return
        }
        if openMark != nil {
            openMark = nil
            return
        }
        if openNote != nil, m.link == nil {
            openNote = nil
            return
        }
        if let link = m.link {
            if let target = link.target, let marker = link.note, showNote(target: target, marker: marker) {
                return
            } else if let target = link.target {
                follow(link: target)
            } else if let external = link.external, let url = URL(string: external) {
                openExternal(url)
            }
            return
        }
        #if os(iOS)
        if chromeShown {
            chromeShown = false
            return
        }
        #endif
        // The outer thirds turn pages, the middle brings up the controls.
        let x = m.x ?? 0, width = m.width ?? 0
        if settings.mode == .paginated, width > 0, x < width * 0.3 || x > width * 0.7 {
            return turn(forward: x > width * 0.7)
        }
        #if os(iOS)
        chromeShown = true
        #endif
    }

    func pager(_ pager: ReaderPager, selected m: ReaderMessage) {
        guard let section = pager.current?.section, let start = m.start, let end = m.end,
              let text = m.text, let r = m.rect
        else {
            selection = nil
            return
        }
        openMark = nil
        selection = TextSelection(section: section, start: start, end: end, text: text,
                                  rect: CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
    }

    func pager(_ pager: ReaderPager, inkReachedPage page: Int) {
        guard following, settings.mode == .paginated, page != pager.current?.page else { return }
        pager.turn(to: page, animated: !pager.reduceMotion)
    }
}

extension Notification.Name {
    /// The shared reader settings changed in 设置 · 阅读.
    static let readerSettingsChanged = Notification.Name("yuyue.readerSettingsChanged")
    /// `Library.open(_:at:)`: the book's id.
    static let readerJump = Notification.Name("yuyue.readerJump")
    /// A highlight or thought was added, changed or removed in a book window: the book's id.
    static let notesChanged = Notification.Name("yuyue.notesChanged")
    /// 替换规则 changed: the book's id, or nil for the rules for every book.
    static let replaceRulesChanged = Notification.Name("yuyue.replaceRulesChanged")
    /// A TXT is about to be read another way (编码和目录): open readers write where they are and stop.
    static let bookWillRebuild = Notification.Name("yuyue.bookWillRebuild")
    /// …and has been: its book id. Readers open it again.
    static let bookRebuilt = Notification.Name("yuyue.bookRebuilt")
}

extension BookDetail {
    /// The chapter a section belongs to, as the table of contents names it.
    func chapterTitle(for section: UInt32) -> String? {
        if let item = toc.first(where: { $0.section == section }) ?? toc.last(where: { $0.section < section }) {
            return item.title
        }
        let i = Int(section)
        return sections.indices.contains(i) ? sections[i].title : nil
    }
}

extension ReaderSettings {
    static let standard = ReaderSettings(
        paper: .plain, mode: .paginated, font: nil, fontSize: YYReader.defaultFontSize,
        lineHeight: nil, paragraphSpacing: nil, justify: nil, indent: nil, compress: true
    )

    /// As `yy.applySettings` takes them (reader contract §4). nil means the paper's default.
    var script: [String: Any] {
        func js(_ value: Any?) -> Any { value ?? NSNull() }
        return [
            "paper": paper.tokens.id,
            "mode": mode == .paginated ? "paginated" : "scrolled",
            "font": js(font?.name),
            "fontSize": fontSize,
            "lineHeight": js(lineHeight),
            "paragraphSpacing": js(paragraphSpacing),
            "justify": js(justify),
            "indent": js(indent),
            "compress": compress,
        ]
    }
}

extension ReaderFont {
    var name: String {
        switch self {
        case .sans: "sans"
        case .serif: "serif"
        case .kai: "kai"
        case .wenKai: "wenkai"
        }
    }
}

extension Paper {
    var tokens: YYPaper {
        switch self {
        case .plain: .plain
        case .dark: .dark
        case .kami: .kami
        case .kamiNight: .kaminight
        case .eink: .eink
        }
    }

    init?(id: String) {
        switch id {
        case "plain": self = .plain
        case "dark": self = .dark
        case "kami": self = .kami
        case "kaminight": self = .kamiNight
        case "eink": self = .eink
        default: return nil
        }
    }
}

extension YYPaper {
    var platformBackground: PlatformColor { PlatformColor(bg) }
}

/// 沉浸阅读: what goes when only the words should stay. Each can be kept.
/// 墨水屏模式 (我的 › 墨水屏): every book on the e-ink paper — black on grain, marks as black lines,
/// pictures and covers in grey, no animation, no shadows or glass.
enum EInk {
    static let key = "eink.on"
    /// The paper before, to go back to.
    static let previousKey = "eink.previous"
    static var on: Bool { UserDefaults.standard.bool(forKey: key) }

    static func set(_ on: Bool, core: YuyueCore) {
        guard var shared = try? core.readerSettings() else { return }
        if on {
            if shared.paper != .eink { UserDefaults.standard.set(shared.paper.tokens.id, forKey: previousKey) }
            shared.paper = .eink
        } else {
            shared.paper = UserDefaults.standard.string(forKey: previousKey).flatMap(Paper.init(id:)) ?? .plain
        }
        UserDefaults.standard.set(on, forKey: key)
        try? core.setReaderSettings(settings: shared)
        NotificationCenter.default.post(name: .readerSettingsChanged, object: nil)
    }
}

enum ImmersivePrefs {
    static let lineKey = "immersive.line"
    static let marksKey = "immersive.hideMarks"
    static let stillKey = "immersive.stillPages"
    static let statusKey = "immersive.hideStatus"
    static let progressKey = "immersive.hideProgress"
    static let quietKey = "immersive.quiet"
    static let hintsKey = "immersive.hideHints"
    static let alwaysKey = "immersive.always"

    private static func flag(_ key: String, _ otherwise: Bool = true) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? otherwise }
    /// A hairline at the very bottom for how far through the book.
    static var keepsLine: Bool { flag(lineKey) }
    /// Off at first (prototype 沉浸设置): a highlight is the reader's own and stays unless asked.
    static var hidesMarks: Bool { flag(marksKey, false) }
    static var stillPages: Bool { flag(stillKey) }
    static var hidesStatusBar: Bool { flag(statusKey) }
    /// Off, a line of where you are and how long the chapter has left stays at the bottom.
    static var hidesProgress: Bool { flag(progressKey) }
    /// 难词注释 and such: nothing on the page but the book's own words.
    static var hidesHints: Bool { flag(hintsKey) }
    /// 读书时通知不打扰: iOS lets no app turn on 勿扰 itself, so this asks the system's 专注模式.
    static var quiet: Bool { flag(quietKey) }
    /// 我的 › 沉浸阅读: every book opens in it.
    static var always: Bool { flag(alwaysKey, false) }
}
