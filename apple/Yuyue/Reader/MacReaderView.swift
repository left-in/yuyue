#if os(macOS)
import SwiftUI
import Translation
import YuyueCore

/// The book's own window (FEATURES §5): the paper fills it, the tools sit in the toolbar, the
/// reading capsule floats at the bottom and a panel on the right holds the contents, notes or
/// search results. Closing the panel puts the text back in the middle.
struct MacReaderView: View {
    @Bindable var model: ReaderModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("reader.panel") private var savedPanel = ""
    private var panel: ReaderPanel? {
        get { model.panel }
        nonmutating set { model.panel = newValue }
    }
    @State private var typesetShown = false
    @State private var listenShown = false
    @State private var thought: Mark?
    @State private var translating: String?
    @State private var sharing: QuoteShare?
    /// 沉浸阅读: the capsule comes back while the pointer is at the bottom edge.
    @State private var peek = false
    /// The player bar is for listening (待定方案 9 · A): it rises when reading aloud starts and
    /// settles away a few seconds after it stops. Reading, the page has nothing on it.
    @State private var listening = false
    @State private var settle: Task<Void, Never>?
    private var barAway: Bool { !(listening || listenShown) || (model.immersive && !peek && !listenShown) }
    @State private var unpeek: Task<Void, Never>?
    @State private var pageHeight = 0.0
    /// The window 沉浸阅读 put into full screen, to take it out again.
    @State private var fullScreened: NSWindow?
    @FocusState private var searchFocused: Bool
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }
    @AppStorage(LiquidGlass.key) private var liquidChosen = true
    /// 墨水屏 has no glass.
    private var liquid: Bool { liquidChosen && LiquidGlass.supported && !paper.isEink }

    private var paper: YYPaper { model.paperTokens }

    var body: some View {
        HStack(spacing: 0) {
            page
            if let panel {
                side(panel)
                    .frame(width: 288)
                    .padding(.trailing, 14)
                    .padding(.bottom, 14)
                    .padding(.top, 6)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: panel)
        .overlay {
            if model.quickSearchShown, let library = model.library {
                QuickSearchPanel(library: library) { model.quickSearchShown = false } ask: { model.ask($0) }
                    .preferredColorScheme(nil)
            }
        }
        .background(paper.bg.ignoresSafeArea())
        .preferredColorScheme(paper.isDark ? .dark : .light)
        .tint(tint.accent)
        .toolbar { toolbar }
        .toolbar(model.immersive ? .hidden : .visible, for: .windowToolbar)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // `.v-mac-tb`: 18 in, in the middle of the 58-high bar.
        .trafficLights(CGPoint(x: 24, y: 29))
        .navigationTitle(model.detail?.summary.title ?? String(localized: "读书"))
        .focusedSceneValue(\.reader, model)
        .onChange(of: model.searchFieldWanted) { focusSearch() }
        .onChange(of: model.searchShown) { _, shown in
            if shown {
                if panel != .search { panel = .search }
                focusSearch()
            } else if panel == .search {
                panel = ReaderPanel(rawValue: savedPanel)
            }
        }
        .sheet(isPresented: $model.rulesShown) {
            NavigationStack {
                ReplaceRulesView(core: model.core, bookID: model.bookID, bookTitle: model.detail?.summary.title ?? "") {
                    model.rulesShown = false
                }
            }
            .frame(width: 480, height: 600)
        }
        .sheet(isPresented: $model.txtShown) {
            if let library = model.library {
                NavigationStack {
                    TxtLayoutView(library: library, bookID: model.bookID, bookTitle: model.detail?.summary.title ?? "",
                                  go: { section in
                                      model.txtShown = false
                                      model.jump(section: section, sentence: 0)
                                  }) {
                        model.txtShown = false
                    }
                }
                .frame(width: 480, height: 640)
            }
        }
        .sheet(item: $sharing) { quote in
            QuoteShareSheet(quote: quote) { sharing = nil }
                .preferredColorScheme(nil)
        }
        .sheet(item: $thought) { mark in
            ThoughtSheet(mark: mark) { text in
                model.setNote(text, of: mark)
                thought = nil
            } cancel: {
                thought = nil
            }
        }
        .translationPresentation(isPresented: Binding(get: { translating != nil }, set: { if !$0 { translating = nil } }), text: translating ?? "")
        .translationTask(model.translator.configuration) { session in await model.translator.run(session) }
        .onAppear {
            // A question from 搜索 · 问 opened this window on 书伴.
            if model.companion.turns.isEmpty {
                panel = ReaderPanel(rawValue: savedPanel).flatMap { $0 == .search ? nil : $0 }
            }
            model.pager.prefersTwoColumns = UserDefaults.standard.object(forKey: "reader.twoColumns") as? Bool ?? true
            #if DEBUG
            // `-debugPanel toc|notes|companion` · `-debugQuery 宝玉` · `-debugListen 1` · `-debugTypeset 1`
            let d = UserDefaults.standard
            if let p = d.string(forKey: "debugPanel") { panel = ReaderPanel(rawValue: p) }
            if let q = d.string(forKey: "debugQuery") {
                model.searchShown = true
                panel = .search
                model.query = q
                model.search()
            }
            // `-debugFlag 1`: the card for the book's first stretch that doesn't line up, without playing.
            if d.bool(forKey: "debugFlag"), let i = model.flagIssues.first {
                Task { try? await Task.sleep(for: .seconds(1.5)); model.showFlag(NarrationFlag(issue: i, number: 1, total: model.flagIssues.count)) }
            }
            if d.bool(forKey: "debugListen") { Task { try? await Task.sleep(for: .seconds(1.5)); listenShown = true } }
            // `-debugSeed 1`: a few highlights to look at (use with -debugLibrary).
            if d.bool(forKey: "debugSeed"), model.marks.isEmpty, let section = model.section ?? model.detail?.start {
                let p = { (s: UInt32, o: UInt32) in TextPoint(sentence: s, offset: o) }
                _ = try? model.core.addMark(book: model.bookID, section: section, start: p(1, 0), end: p(1, 12), text: String(localized: "那年冬天，祖母死了，父亲的差使"), style: .yellow, note: nil)
                _ = try? model.core.addMark(book: model.bookID, section: section, start: p(4, 0), end: p(4, 10), text: String(localized: "父亲说，“事已如此，不必难过"), style: .wave, note: String(localized: "父亲的话，是安慰我，也是安慰他自己。"))
                _ = try? model.core.addMark(book: model.bookID, section: section, start: p(6, 2), end: p(6, 12), text: String(localized: "家中光景很是惨淡"), style: .pink, note: nil)
                model.reloadNotes()
            }
            // `-debugWord fortune`: clicks the word where it first shows on the page (quietly);
            // `-debugDouble 3`: double-clicks sentence 3; `-debugTranslate 1`: turns 译 on.
            if d.bool(forKey: "debugTranslate") { model.setTranslateShown(true) }
            if let w = d.string(forKey: "debugWord") {
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    if let r = await model.pager.current?.ask("yy.wordAt(w)", ["w": w]),
                       let data = try? JSONSerialization.data(withJSONObject: r),
                       let word = try? JSONDecoder().decode(ReaderMessage.Word.self, from: data) {
                        model.look(up: word, quiet: true)
                    }
                }
            }
            if d.object(forKey: "debugDouble") != nil {
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    if let m = ReaderMessage(body: ["type": "doubleTap", "sentence": d.integer(forKey: "debugDouble"), "x": 120, "y": 300]) {
                        model.pager(model.pager, doubleTapped: m)
                    }
                }
            }
            // `-debugSelect "2,0,2,9"`: selects that much of the page, as a drag would.
            if let spec = d.string(forKey: "debugSelect") {
                let n = spec.split(separator: ",").compactMap { Int($0) }
                if n.count == 4 {
                    Task {
                        try? await Task.sleep(for: .seconds(2.5))
                        model.pager.current?.call("yy.select(a, b)", ["a": ["s": n[0], "o": n[1]], "b": ["s": n[2], "o": n[3]]])
                    }
                }
            }
            // `-debugAsk 问题`: asks 书伴 once the page is up.
            // `-debugScope whole` asks the whole book; `-debugCite n` then taps the answer's [n].
            if let q = d.string(forKey: "debugAsk") {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if d.string(forKey: "debugScope") == "whole" { model.companion.scope = .whole }
                    model.ask(q)
                    let n = d.integer(forKey: "debugCite")
                    guard n > 0 else { return }
                    for _ in 0 ..< 40 where model.companion.busy { try? await Task.sleep(for: .milliseconds(250)) }
                    if let source = model.companion.turns.last?.answer?.sources[n] { model.companion.show(source) }
                }
            }
            if d.bool(forKey: "debugImmersive") { Task { try? await Task.sleep(for: .seconds(1)); model.immersive = true } }
            if d.bool(forKey: "debugTypeset") { Task { try? await Task.sleep(for: .seconds(1.5)); typesetShown = true } }
            if d.bool(forKey: "debugRules") { Task { try? await Task.sleep(for: .seconds(1.5)); model.rulesShown = true } }
            if d.bool(forKey: "debugTxt") { Task { try? await Task.sleep(for: .seconds(1.5)); model.txtShown = true } }
            if d.object(forKey: "debugSection") != nil { Task { try? await Task.sleep(for: .seconds(1)); model.jump(section: UInt32(d.integer(forKey: "debugSection")), sentence: 0) } }
            #endif
            model.pager.menuItems = { menuItems() }
            model.pager.keyHandler = { [weak model] event in model.map { Self.key(event, model: $0) } ?? false }
        }
        .onChange(of: model.immersive) { _, on in immerse(on) }
        .onChange(of: model.isPlaying, initial: true) { _, playing in
            settle?.cancel()
            if playing {
                listening = true
            } else if listening {
                settle = Task {
                    try? await Task.sleep(for: .seconds(5))
                    if !Task.isCancelled, !model.isPlaying { listening = false }
                }
            }
        }
        .onChange(of: model.rulesShown) { _, shown in if shown { typesetShown = false } }
        .onChange(of: model.txtShown) { _, shown in if shown { typesetShown = false } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            // Leaving full screen by the green button or the menu leaves 沉浸 too.
            guard model.immersive, let window = note.object as? NSWindow, window === fullScreened else { return }
            fullScreened = nil
            model.immersive = false
        }
        .onDisappear { unpeek?.cancel() }
        .onChange(of: panel) { _, new in
            if new != .search { savedPanel = new?.rawValue ?? "" }
            if new != .search, model.searchShown { model.endSearch() }
        }
        .task {
            // Time spent in each chapter, written every half minute.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                model.tick()
            }
        }
    }

    // MARK: The page

    private var page: some View {
        ZStack {
            PagerView(pager: model.pager)
            if model.listenOnly { ListenOnlyCover(model: model).transition(.opacity) }
            cards
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                UndoToast(toast: toast) { model.undoToast() }
                    .padding(.top, 10)
                    .transition(UndoToast.transition)
                    .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.3), value: model.toast?.id)
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if let e = model.elsewhere {
                    ElsewhereCard(elsewhere: e, tint: tint, stay: { model.elsewhere = nil }, jump: { model.jumpElsewhere() })
                        .frame(width: 396)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let open = model.openNote {
                    FootnoteCard(open: open, bookTitle: model.detail?.summary.title ?? "", tint: tint,
                                 toNotes: { model.goToNotes() }, done: { model.openNote = nil })
                        .frame(width: 396)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let recap = model.recap {
                    RecapCard(recap: recap, tint: tint) { model.recap = nil }
                        .frame(width: 396)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let flag = model.narrationFlag {
                    NarrationFlagCard(flag: flag, letBe: { model.letFlagBe() }, adjust: {
                        model.player?.pause()
                        if let target = model.flagTarget { openWindow(id: "align", value: target) }
                    })
                        .frame(width: 340)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let back = model.returnTo, !model.immersive || peek {
                    ReturnPill(page: back.page, paper: paper) { model.goBack() }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let doubt = model.txtDoubt, !model.immersive || peek {
                    DoubtPill(doubt: doubt, paper: paper, open: { model.txtShown = true }, dismiss: { model.dismissDoubt() })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if !barAway {
                    capsule.transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 18)
            .animation(.spring(duration: 0.35, bounce: 0.1), value: barAway)
            .animation(.snappy(duration: 0.25), value: model.toast?.id)
            .animation(.snappy(duration: 0.25), value: model.elsewhere == nil)
            .animation(.snappy(duration: 0.25), value: model.returnTo == nil)
            .animation(.snappy(duration: 0.25), value: model.recap)
            .animation(.snappy(duration: 0.25), value: model.openNote)
            .animation(.snappy(duration: 0.25), value: model.narrationFlag)
        }
        .onReceive(NotificationCenter.default.publisher(for: Audiobooks.timingsChanged)) { _ in model.timingsChanged() }
        .overlay(alignment: .bottomLeading) {
            // All that is left of the progress while the capsule is away: a hairline along the
            // bottom (the book's in 沉浸阅读, the chapter's while reading in the window).
            if model.immersive, !peek, ImmersivePrefs.keepsLine {
                GeometryReader { g in
                    Rectangle().fill(paper.ink.opacity(0.22))
                        .frame(width: g.size.width * model.bookFraction, height: 1.5)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .onGeometryChange(for: Double.self) { $0.size.height } action: { pageHeight = $0 }
        .onContinuousHover { phase in
            guard model.immersive else { return }
            if case .active(let at) = phase, at.y > pageHeight - 84 {
                unpeek?.cancel()
                peek = true
            } else if peek, unpeek == nil || unpeek?.isCancelled == true {
                unpeek = Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    if !Task.isCancelled { peek = false }
                    unpeek = nil
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 分享书摘 for a highlight or what is selected.
    private func share(_ text: String, note: String?, section: UInt32) {
        let summary = model.detail?.summary
        let chapter = model.detail?.chapterTitle(for: section)
        sharing = QuoteShare(text: text, note: note, title: summary?.title ?? "", author: summary?.authors.first,
                             chapter: chapter == summary?.title ? nil : chapter, coverPath: summary?.coverPath)
        model.dismissCards()
    }

    /// 沉浸阅读 fills the screen; leaving it gives the window back as it was.
    private func immerse(_ on: Bool) {
        peek = false
        if on {
            #if DEBUG
            // `-debugImmersive 1` looks at it without taking over the screen.
            if UserDefaults.standard.bool(forKey: "debugImmersive") { return }
            #endif
            guard let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) else { return }
            fullScreened = window
            window.toggleFullScreen(nil)
        } else if let window = fullScreened {
            fullScreened = nil
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ShelfButtonToolbar(liquid: liquid, ink: paper.ink, glass: paper.glass, line: paper.line) {
            openWindow(id: "library")
        }
        if model.searchShown {
            if liquid {
                ToolbarItem(placement: .principal) { searchField }
            } else {
                ToolbarItem(placement: .principal) { searchField.yyGlass(Capsule(), fill: paper.glass, line: paper.line, shadow: paper.isDark ? 0.3 : 0.06, radius: 7, liquid: false) }
                    .withoutGlass()
            }
        } else {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(model.detail?.summary.title ?? "")
                        .font(.yy(size: 13, weight: .semibold))
                        .foregroundStyle(paper.ink)
                    Text(subtitle)
                        .font(.yy(size: 10.5))
                        .foregroundStyle(paper.ink2)
                        .monospacedDigit()
                }
                .lineLimit(1)
                .frame(minWidth: 200)
            }
            .withoutGlass()
        }
        ToolbarItem(placement: .primaryAction) { tools }
            .withoutGlass()
    }

    // MARK: The tool capsule

    /// `.v-mac-tools`: what's open is in the paper's theme colour on a soft pad; the capsule is
    /// Liquid Glass or, as the prototype draws it, frosted.
    private var tools: some View {
        HStack(spacing: 2) {
            tool(model.isPlaying ? String(localized: "暂停") : String(localized: "朗读"), model.isPlaying ? "pause.fill" : "play.fill",
                 help: model.isPlaying ? String(localized: "暂停 空格") : String(localized: "朗读 空格"), on: model.isPlaying) { model.togglePlay() }
            tool(String(localized: "目录"), "list.bullet", help: String(localized: "目录、书签 ⌘⌥T"), on: panel == .toc) { panel = panel == .toc ? nil : .toc }
            tool(String(localized: "书内搜索"), "magnifyingglass", help: String(localized: "书内搜索 ⌘F"), on: model.searchShown) {
                model.searchShown ? closeSearch() : startSearch()
            }
            tool(String(localized: "排版"), nil, help: String(localized: "排版"), on: typesetShown) { typesetShown.toggle() }
                .popover(isPresented: $typesetShown, arrowEdge: .bottom) {
                    TypesetCard(model: model)
                        .presentationBackground(YYColor.card)
                }
            if model.isForeign {
                tool(String(localized: "译"), "translate", help: String(localized: "每段下面跟着译文；关掉只剩原文，双击一句只翻这一句"), on: model.translateShown) {
                    model.setTranslateShown(!model.translateShown)
                }
            }
            tool(String(localized: "书伴"), "sparkle", help: String(localized: "书伴"), on: panel == .companion) { panel = panel == .companion ? nil : .companion }
            tool(String(localized: "笔记"), "sidebar.right", help: String(localized: "笔记栏 ⌘⌥N"), on: panel == .notes) { panel = panel == .notes ? nil : .notes }
        }
        .padding(.horizontal, 3)
        .frame(height: 32)
        .yyGlass(Capsule(), fill: paper.glass, line: paper.line, shadow: paper.isDark ? 0.3 : 0.06, radius: 7,
                 interactive: true, liquid: !paper.isEink)
    }

    private func tool(_ title: String, _ symbol: String?, help: String, on: Bool, action: @escaping () -> Void) -> some View {
        let accent = paper.isDark ? tint.paperAccentDark : tint.paperAccentLight
        return GlassTool(title: title, symbol: symbol, help: help, on: on, accent: accent,
                         soft: accent.opacity(paper.isDark ? 0.18 : 0.12), ink: paper.ink, action: action)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let author = model.detail?.summary.authors.first { parts.append(author) }
        if let chapter = model.chapterTitle, model.detail?.toc.count ?? 0 > 1 {
            parts.append(ChapterTitle(chapter).number ?? chapter)
        }
        if let page = model.bookPage { parts.append(String(localized: "第 \(page) 页")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.yy(size: 12, weight: .medium))
                .foregroundStyle(paper.ink2)
            TextField("书内搜索", text: $model.query)
                .textFieldStyle(.plain)
                .font(.yy(size: 13, weight: .semibold))
                .focused($searchFocused)
                .frame(width: 130)
                .onSubmit { model.nextHit(forward: true) }
                .onChange(of: model.query) { model.search() }
                .onKeyPress(.escape) {
                    closeSearch()
                    return .handled
                }
            if !model.query.isEmpty {
                Text(model.hits.isEmpty ? String(localized: "没找到") : String(localized: "第 \((model.hitIndex ?? 0) + 1) / \(model.hits.count) 处"))
                    .font(.yy(size: 11.5, weight: .semibold))
                    .foregroundStyle(model.hits.isEmpty ? paper.ink2 : paper.ink)
                    .monospacedDigit()
                    .fixedSize()
            }
            Divider().frame(height: 14)
            Button { model.nextHit(forward: false) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel(Text("上一处"))
                .buttonStyle(.borderless)
                .disabled(model.hits.isEmpty)
            Button { model.nextHit(forward: true) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel(Text("下一处"))
                .buttonStyle(.borderless)
                .disabled(model.hits.isEmpty)
            Button { closeSearch() } label: {
                Image(systemName: "xmark")
                    .accessibilityLabel(Text("结束搜索"))
                    .font(.yy(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(paper.line, in: .circle)
            }
            .buttonStyle(.plain)
            .help("收起 Esc")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private func startSearch() {
        model.startSearch()
    }

    /// The field is new in the toolbar and the page (a web view) holds the keyboard: ask for it
    /// once the toolbar has it, and again when that has settled, or typing goes to the page.
    private func focusSearch() {
        Task {
            searchFocused = true
            // A field in the toolbar doesn't answer to focus state here; hand it the keyboard
            // directly once the toolbar has it.
            try? await Task.sleep(for: .milliseconds(80))
            guard let window = NSApp.keyWindow, let field = Self.field(in: window.contentView?.superview, placeholder: String(localized: "书内搜索")) else { return }
            if window.firstResponder !== field.currentEditor() { window.makeFirstResponder(field) }
        }
    }

    private static func field(in view: NSView?, placeholder: String) -> NSTextField? {
        guard let view else { return nil }
        if let f = view as? NSTextField, f.isEditable, f.placeholderString == placeholder { return f }
        for sub in view.subviews { if let f = field(in: sub, placeholder: placeholder) { return f } }
        return nil
    }

    private func closeSearch() {
        model.endSearch()
    }

    // MARK: The reading capsule

    private var capsule: some View {
        HStack(spacing: 4) {
            Button { panel = panel == .toc ? nil : .toc } label: {
                Image(systemName: "list.bullet")
                    .font(.yy(size: 13, weight: .medium))
                    .frame(width: 32, height: 36)
            }
            .help("目录")
            .accessibilityLabel(Text("目录"))
            Button { listenShown.toggle() } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.sentenceCount > 0 ? String(localized: "第 \(min(model.sentence + 1, model.sentenceCount)) / \(model.sentenceCount) 句") : (model.chapterTitle ?? ""))
                        .font(.yy(size: 12, weight: .semibold))
                        .foregroundStyle(paper.ink)
                    Text(model.capsuleNote)
                        .font(.yy(size: 10))
                        .foregroundStyle(paper.ink2)
                }
                .monospacedDigit()
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 36)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(listenShown ? paper.line.opacity(0.8) : .clear, in: .rect(cornerRadius: 12))
                .contentShape(.rect)
            }
            .help("听书：声音、速度、睡眠定时")
            .popover(isPresented: $listenShown, arrowEdge: .top) {
                ListenCard(model: model)
                    .presentationBackground(YYColor.card)
            }
            Button { step(forward: false) } label: {
                Image(systemName: "chevron.left").font(.yy(size: 13, weight: .semibold)).frame(width: 30, height: 36)
            }
            .help(model.player?.spot != nil ? String(localized: "上一句 ⌘[") : String(localized: "上一页 ←"))
            .accessibilityLabel(model.player?.spot != nil ? Text("上一句") : Text("上一页"))
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.yy(size: 14, weight: .semibold))
                    .foregroundStyle(paper.onMain)
                    .frame(width: 36, height: 36)
                    .background(paper.main, in: .circle)
            }
            .help(model.isPlaying ? String(localized: "暂停 空格") : String(localized: "朗读 空格"))
            .accessibilityLabel(model.isPlaying ? Text("暂停") : Text("朗读"))
            Button { step(forward: true) } label: {
                Image(systemName: "chevron.right").font(.yy(size: 13, weight: .semibold)).frame(width: 30, height: 36)
            }
            .help(model.player?.spot != nil ? String(localized: "下一句 ⌘]") : String(localized: "下一页 →"))
            .accessibilityLabel(model.player?.spot != nil ? Text("下一句") : Text("下一页"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(paper.ink)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(width: 360)
        .yyGlass(Capsule(), fill: paper.glass, shadow: paper.isDark ? 0.4 : 0.08, liquid: !paper.isEink)
        .overlay(alignment: .bottom) {
            // How far into this chapter.
            GeometryReader { g in
                Capsule().fill(paper.line)
                Capsule().fill(paper.ink).frame(width: g.size.width * chapterProgress)
            }
            .frame(height: 2)
            .padding(.horizontal, 22)
            .padding(.bottom, 1)
        }
        .overlay(Capsule().strokeBorder(paper.line, lineWidth: 0.5))
    }

    private var chapterProgress: Double {
        let n = model.sentenceCount
        return n > 0 ? min(1, Double(model.sentence + 1) / Double(n)) : 0
    }

    private func step(forward: Bool) {
        if let player = model.player, player.spot != nil {
            player.skip(forward: forward)
        } else {
            model.turn(forward: forward)
        }
    }

    // MARK: Cards over the text

    @ViewBuilder private var cards: some View {
        if let selection = model.selection {
            GeometryReader { g in
                SelectionCard(model: model, current: nil, thought: { startThought() }, translate: { translate(selection.text) }, ask: { ask(selection.text) })
                    .fixedSize()
                    .modifier(Above(rect: selection.rect, in: g.size))
            }
            .transition(.opacity)
        } else if let open = model.openMark {
            GeometryReader { g in
                SelectionCard(model: model, current: open.mark, thought: { thought = open.mark; model.dismissCards() }, translate: { translate(open.mark.text) }, ask: { ask(open.mark.text) })
                    .fixedSize()
                    .modifier(Above(rect: CGRect(x: open.at.x - 1, y: open.at.y - 12, width: 2, height: 24), in: g.size))
            }
            .transition(.opacity)
        } else if let lookup = model.lookup {
            GeometryReader { g in
                WordCard(model: model, lookup: lookup)
                    .fixedSize()
                    .modifier(Beneath(rect: lookup.rect, in: g.size))
            }
            .transition(.opacity)
        } else if let item = model.sentenceTranslation {
            GeometryReader { g in
                SentenceCard(model: model, item: item)
                    .fixedSize()
                    .modifier(Beneath(rect: CGRect(x: item.at.x, y: item.at.y - 12, width: 2, height: 24), in: g.size))
            }
            .transition(.opacity)
        }
    }

    private func startThought() {
        guard let mark = model.mark() else { return }
        thought = mark
    }

    private func translate(_ text: String) {
        model.dismissCards()
        translating = text
    }

    private func ask(_ text: String) {
        model.dismissCards()
        model.companionQuote = text
        panel = .companion
    }

    /// Right-clicking the page: the selection card's choices in the same order, or what can
    /// be done with the page.
    private func menuItems() -> [NSMenuItem] {
        if let selection = model.selection {
            var items: [NSMenuItem] = MarkStyle.colours.enumerated().map { i, style in
                ActionMenuItem(String(localized: "划\(style.name)"), symbol: style == .wave ? "scribble" : "highlighter", key: "\(i + 1)") { model.mark(style) }
            }
            items.append(ActionMenuItem(String(localized: "划下划线"), symbol: "underline") { model.mark(.underline) })
            items.append(.separator())
            items.append(ActionMenuItem(String(localized: "想法…"), symbol: "pencil") { startThought() })
            items.append(ActionMenuItem(String(localized: "从这读"), symbol: "headphones") { model.readFromSelection() })
            items.append(ActionMenuItem(String(localized: "问书伴"), symbol: "sparkle") { ask(selection.text) })
            items.append(ActionMenuItem(String(localized: "翻译"), symbol: "translate") { translate(selection.text) })
            items.append(ActionMenuItem(String(localized: "复制"), symbol: "doc.on.doc", key: "c", modifiers: .command) { model.copySelection() })
            // Not on the card (`.v-mr-act` has five); here instead.
            items.append(ActionMenuItem(String(localized: "分享…"), symbol: "square.and.arrow.up") { share(selection.text, note: nil, section: selection.section) })
            return items
        }
        if let open = model.openMark {
            return [
                ActionMenuItem(open.mark.note == nil ? String(localized: "写想法…") : String(localized: "改想法…"), symbol: "pencil") { thought = open.mark; model.dismissCards() },
                ActionMenuItem(String(localized: "复制"), symbol: "doc.on.doc") { model.copySelection() },
                ActionMenuItem(String(localized: "分享…"), symbol: "square.and.arrow.up") { share(open.mark.text, note: open.mark.note, section: open.mark.section) },
                .separator(),
                ActionMenuItem(String(localized: "删除划线"), symbol: "trash") { model.deleteMark(open.mark) },
            ]
        }
        let marked = model.bookmarkHere != nil
        return [
            ActionMenuItem(model.isPlaying ? String(localized: "暂停朗读") : String(localized: "从这页读"), symbol: model.isPlaying ? "pause" : "headphones") { model.togglePlay() },
            ActionMenuItem(marked ? String(localized: "拿掉书签") : String(localized: "加书签"), symbol: marked ? "bookmark.slash" : "bookmark", key: "d", modifiers: .command) { model.toggleBookmark() },
            .separator(),
            ActionMenuItem(String(localized: "书内搜索"), symbol: "magnifyingglass", key: "f", modifiers: .command) { startSearch() },
            ActionMenuItem(String(localized: "目录"), symbol: "list.bullet") { panel = .toc },
            ActionMenuItem(String(localized: "笔记"), symbol: "sidebar.right") { panel = .notes },
        ]
    }

    // MARK: Side panel

    @ViewBuilder private func side(_ which: ReaderPanel) -> some View {
        Group {
            switch which {
            case .toc: TocPanel(model: model)
            case .notes: NotesPanel(model: model) { thought = $0 }
            case .search: SearchPanel(model: model)
            case .companion: CompanionPanel(model: model)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(YYColor.card, in: .rect(cornerRadius: YYRadius.card))
        // One shadow for the card, not one under every line of text.
        .compositingGroup()
        .yyShadow(paper.isDark ? YYShadow.floatDark : YYShadow.floatLight)
    }

    // MARK: Keys

    /// Keys the page hands over before turning pages.
    private static func key(_ event: NSEvent, model: ReaderModel) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        if event.keyCode == 53, model.selection != nil || model.openMark != nil {  // esc
            model.dismissCards()
            return true
        }
        if event.keyCode == 53, model.lookup != nil || model.sentenceTranslation != nil {
            model.closeLookup()
            model.sentenceTranslation = nil
            return true
        }
        if event.keyCode == 53, model.immersive {
            model.immersive = false
            return true
        }
        if let c = event.charactersIgnoringModifiers, let n = Int(c), (1 ... 4).contains(n) {
            let style = MarkStyle.colours[n - 1]
            if model.selection != nil {
                model.mark(style)
                return true
            }
            if let open = model.openMark {
                model.setStyle(style, of: open.mark)
                return true
            }
        }
        if event.keyCode == 49, model.selection == nil {  // space reads aloud
            model.togglePlay()
            return true
        }
        return false
    }

}

/// 想法: a few lines about a highlight.
struct ThoughtSheet: View {
    let mark: Mark
    let save: (String?) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    private let tint = YYTint.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("想法")
                .font(.yy(size: 15, weight: .bold))
            Text(mark.text)
                .font(.yy(size: 12.5))
                .foregroundStyle(YYColor.t2)
                .lineLimit(3)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(mark.style.fills ? mark.style.fill : YYColor.hlR).frame(width: 3) }
            TextEditor(text: $text)
                .font(.yy(size: 13.5))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 110)
                .background(YYColor.inset, in: .rect(cornerRadius: YYRadius.control))
                .focused($focused)
            HStack {
                if mark.note != nil {
                    Button("删掉想法", role: .destructive) { save(nil) }
                        .foregroundStyle(YYColor.danger)
                }
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                    .buttonStyle(YYButtonStyle(kind: .plain))
                Button("好") { save(text) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(YYButtonStyle(kind: .main))
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear {
            text = mark.note ?? ""
            focused = true
        }
    }
}

// MARK: - Panels

private struct PanelTabs<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title)
                        .font(.yy(size: 11.5, weight: selection == value ? .semibold : .regular))
                        .foregroundStyle(selection == value ? YYColor.t1 : YYColor.t2)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(selection == value ? YYColor.card : .clear, in: .rect(cornerRadius: 8))
                        .shadow(color: .black.opacity(selection == value ? 0.06 : 0), radius: 1.5, y: 0.5)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(YYColor.inset, in: .rect(cornerRadius: 10))
    }
}

/// 目录: the book on top, then the chapters (read ones faded with the time spent, this one in
/// the accent with how far, the rest with how long), bookmarks and notes beside.
private struct TocPanel: View {
    let model: ReaderModel
    @State private var tab = Tab.toc
    private let tint = YYTint.standard

    enum Tab { case toc, bookmarks, notes }

    private typealias Chapter = TocChapter

    private var chapters: [Chapter] { model.tocChapters }

    private var currentID: Int? { model.currentChapter(in: chapters) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            PanelTabs(items: [(Tab.toc, String(localized: "目录")), (.bookmarks, String(localized: "书签 \(model.bookmarks.count)")), (.notes, String(localized: "笔记 \(model.marks.count)"))], selection: $tab)
            switch tab {
            case .toc: list
            case .bookmarks: BookmarkList(model: model)
            case .notes: NoteList(model: model, marks: model.marks, edit: { _ in })
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    private var header: some View {
        let book = model.detail?.summary
        let read = model.times.values.reduce(0) { $0 + Int($1.readSeconds) }
        let listen = model.times.values.reduce(0) { $0 + Int($1.listenSeconds) }
        let chapterCount = chapters.count
        let unit = chapters.compactMap { ChapterTitle($0.title).number?.last }.first.map(String.init) ?? String(localized: "章")
        // `.v-mr-bk` / `.v-mr-bp`
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                if let book {
                    BookCover(book: book).frame(width: 30)
                        .clipShape(.rect(cornerRadius: 3))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(book?.title ?? "")
                        .font(.yy(size: 14, weight: .bold))
                        .foregroundStyle(YYColor.t1)
                    Text([book?.authors.first, chapterCount > 1 ? String(localized: "共 \(chapterCount) \(unit)") : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.yy(size: 10.5))
                        .foregroundStyle(YYColor.t3)
                }
                .lineLimit(1)
            }
            .padding(.horizontal, 2)
            ProgressLine(value: model.bookFraction, height: 2.5)
                .padding(.horizontal, 2).padding(.top, 12)
            HStack(alignment: .firstTextBaseline) {
                Text("读到\(model.chapterTitle.map { ChapterTitle($0).number ?? String(localized: "这里") } ?? String(localized: "这里")) · \(Int((model.bookFraction * 100).rounded()))%")
                    .font(.yy(size: 11, weight: .semibold))
                    .foregroundStyle(YYColor.t1)
                Spacer()
                if read + listen > 0 {
                    Text([read > 0 ? String(localized: "读 \(durationText(seconds: read))") : nil, listen > 0 ? String(localized: "听 \(durationText(seconds: listen))") : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.yy(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(YYColor.t3)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 2).padding(.top, 7)
        }
    }

    @ViewBuilder private var list: some View {
        if chapters.isEmpty {
            empty(String(localized: "这本书没有目录"), String(localized: "书里没写章节，往后翻就行"))
        } else {
            chapterList
        }
    }

    private var chapterList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(chapters) { c in
                        row(c)
                            .id(c.id)
                        if c.id != currentID, c.id + 1 != currentID, c.id != chapters.count - 1 {
                            Rectangle().fill(YYColor.line).frame(height: 0.5)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            // `.v-mr-chs` reaches 6 past the panel's padding (on the scroll view, which clips).
            .padding(.horizontal, -6)
            .onAppear {
                if let currentID { proxy.scrollTo(currentID, anchor: .center) }
            }
        }
    }

    private func row(_ c: Chapter) -> some View {
        let current = c.id == currentID
        let past = (currentID ?? -1) > c.id
        let t = ChapterTitle(c.title)
        return Button { model.go(to: c.item) } label: {
            // `.v-mr-ch`: only the chapter being read wraps; the rest stay one line.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let number = t.number {
                    Text(number)
                        .font(.yy(size: 11, weight: current ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(current ? tint.accent : past ? YYColor.t3 : YYColor.t2)
                        .frame(width: 44, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.name)
                        .font(.yy(size: current ? 12.5 : 12, weight: current ? .semibold : .regular))
                        .lineSpacing(current ? 4 : 0)
                        .lineLimit(current ? nil : 1)
                        .foregroundStyle(current ? tint.accent : past ? YYColor.t3 : YYColor.t1)
                        .multilineTextAlignment(.leading)
                        .padding(.leading, CGFloat(c.depth) * 12)
                    Text(note(c, current: current, past: past))
                        .font(.yy(size: 10.5, weight: current ? .medium : .regular))
                        .foregroundStyle(current ? tint.accent : YYColor.t3)
                        .monospacedDigit()
                        .lineLimit(1)
                    if current {
                        ProgressLine(value: within(c), height: 2.5)
                            .padding(.top, 5)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, current ? 11 : 9)
            .padding(.bottom, current ? 12 : 9)
            .opacity(past ? 0.85 : 1)
            .background(current ? tint.accentSoft : .clear, in: .rect(cornerRadius: 11))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func minutes(_ c: Chapter) -> Int { model.minutes(of: c) }

    private func within(_ c: Chapter) -> Double { model.within(c) }

    private func note(_ c: Chapter, current: Bool, past: Bool) -> String {
        let minutes = minutes(c)
        if current {
            let left = max(1, Int((Double(minutes) * (1 - within(c))).rounded()))
            return String(localized: "读到 \(Int((within(c) * 100).rounded()))% · 还剩 \(left) 分钟")
        }
        let spent = c.sections.compactMap { model.times[UInt32($0)] }
        let read = spent.reduce(0) { $0 + Int($1.readSeconds) }
        let listen = spent.reduce(0) { $0 + Int($1.listenSeconds) }
        if read + listen >= 30 {
            return [read >= 30 ? String(localized: "读 \(durationText(seconds: read))") : nil, listen >= 30 ? String(localized: "听 \(durationText(seconds: listen))") : nil].compactMap { $0 }.joined(separator: " · ")
        }
        return past ? String(localized: "翻过") : String(localized: "约 \(minutes) 分钟")
    }
}

private struct BookmarkList: View {
    let model: ReaderModel
    private let tint = YYTint.standard

    var body: some View {
        if model.bookmarks.isEmpty {
            empty(String(localized: "还没有书签"), String(localized: "按 ⌘D 给这一页加一个"))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.bookmarks, id: \.id) { mark in
                        Button { model.jump(section: mark.section, sentence: Int(mark.sentence)) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 5) {
                                    Image(systemName: "bookmark.fill").font(.yy(size: 9)).foregroundStyle(tint.accent)
                                    Text(pageLabel(model, section: mark.section, sentence: Int(mark.sentence)))
                                        .font(.yy(size: 10.5, weight: .medium))
                                        .foregroundStyle(YYColor.t3)
                                    Spacer()
                                    Text(mark.at.dayText).font(.yy(size: 10)).foregroundStyle(YYColor.t3)
                                }
                                Text(mark.text)
                                    .font(.yy(size: 12.5))
                                    .foregroundStyle(YYColor.t1)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(.vertical, 11)
                            .padding(.horizontal, 4)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("删除书签", role: .destructive) { model.deleteBookmark(mark) }
                        }
                        Rectangle().fill(YYColor.line).frame(height: 0.5)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

/// The page a place is on, and whether it is this one.
private func pageLabel(_ model: ReaderModel, section: UInt32, sentence: Int) -> String {
    let page = model.estimatedPage(section: section, sentence: sentence).map { String(localized: "第 \($0) 页") } ?? String(localized: "这里")
    if section == model.section, let layout = model.pager.current?.layout, layout.page(of: sentence) == model.page {
        return String(localized: "\(page) · 这一页")
    }
    return page
}

private func empty(_ title: String, _ detail: String) -> some View {
    VStack(spacing: 6) {
        Text(title).font(.yy(size: 13, weight: .semibold)).foregroundStyle(YYColor.t2)
        Text(detail).font(.yy(size: 11.5)).foregroundStyle(YYColor.t3)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 60)
}

/// 笔记: highlights and thoughts in the book's order; this page's in the accent.
private struct NotesPanel: View {
    let model: ReaderModel
    let edit: (Mark) -> Void
    @State private var tab = Tab.marks

    enum Tab: String { case marks, thoughts, words }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("笔记").font(.yy(size: 15, weight: .bold)).foregroundStyle(YYColor.t1)
                Text("按书里的顺序").font(.yy(size: 11)).foregroundStyle(YYColor.t3)
                Spacer()
                NoteExportMenu(sender: model.noteSender, markdown: markdown,
                               name: String(localized: "\(model.detail?.summary.title ?? "") 笔记.md"),
                               books: { exportBook.map { [$0] } ?? [] }, book: model.detail?.summary) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.yy(size: 12, weight: .medium))
                        .foregroundStyle(YYColor.t1)
                        .frame(width: 28, height: 28)
                        .background(YYColor.inset, in: .circle)
                }
                .disabled(model.marks.isEmpty)
                .help("导出笔记")
            }
            PanelTabs(items: [(Tab.marks, String(localized: "划线 \(model.marks.count)")), (.thoughts, String(localized: "想法 \(model.marks.filter { $0.note != nil }.count)")), (.words, model.bookWords.isEmpty ? String(localized: "生词") : String(localized: "生词 \(model.bookWords.count)"))], selection: $tab)
            switch tab {
            case .marks: NoteList(model: model, marks: model.marks, edit: edit)
            case .thoughts: NoteList(model: model, marks: model.marks.filter { $0.note != nil }, edit: edit)
            case .words: WordList(model: model)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        #if DEBUG
        // `-debugNotesTab words`.
        .onAppear { if let t = UserDefaults.standard.string(forKey: "debugNotesTab").flatMap(Tab.init) { tab = t } }
        #endif
    }

    /// The book's notes under their chapters, for 发到 Obsidian, Notion, flomo.
    private var exportBook: NoteExport.Book? {
        guard let book = model.detail?.summary else { return nil }
        var chapters: [(String, [Mark])] = []
        for m in model.marks {
            let title = model.detail?.chapterTitle(for: m.section) ?? book.title
            if chapters.last?.0 == title { chapters[chapters.count - 1].1.append(m) } else { chapters.append((title, [m])) }
        }
        return NoteExport.Book(id: book.id, title: book.title, author: book.author, chapters: chapters)
    }

    /// The notes as Markdown, for 导出.
    private var markdown: String {
        var out = String(localized: "# 《\(model.detail?.summary.title ?? "")》笔记\n")
        var chapter: String?
        for mark in model.marks {
            let title = model.detail?.chapterTitle(for: mark.section)
            if title != chapter, let title {
                out += "\n## \(title)\n"
                chapter = title
            }
            out += "\n> \(mark.text)\n"
            if let note = mark.note { out += "\n\(note)\n" }
        }
        return out
    }
}

/// 生词: this book's words in the 生词本, in reading order; a click goes to the sentence.
private struct WordList: View {
    let model: ReaderModel
    private let tint = YYTint.standard

    var body: some View {
        if model.bookWords.isEmpty {
            if model.isForeign {
                empty(String(localized: "还没有生词"), String(localized: "点一个词，在卡片里点“加入生词本”"))
            } else {
                empty(String(localized: "没有生词"), String(localized: "读外文书时查过的词会记在这里"))
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.bookWords.enumerated()), id: \.element.word) { i, w in
                        if i > 0 { Rectangle().fill(YYColor.line).frame(height: 0.5) }
                        item(w)
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
    }

    private func item(_ w: VocabWord) -> some View {
        let label = pageLabel(model, section: w.section, sentence: Int(w.sentence))
        let here = label.hasSuffix(String(localized: "这一页"))
        let meaning = Vocab.split(meaning: w.meaning)
        return Button { model.jump(section: w.section, sentence: Int(w.sentence)) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(label)
                        .font(.yy(size: 10.5, weight: here ? .semibold : .regular))
                        .foregroundStyle(here ? tint.accent : YYColor.t3)
                    Spacer()
                    if w.known {
                        Text("掌握了").font(.yy(size: 10)).foregroundStyle(YYColor.t3)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(w.word).font(.custom("Georgia", size: 15).weight(.bold))
                        .foregroundStyle(w.known ? YYColor.t2 : YYColor.t1)
                    if let p = w.phonetic {
                        Text(p).font(.yy(size: 10.5)).foregroundStyle(YYColor.t3).lineLimit(1)
                    }
                }
                if let meaning {
                    (Text(meaning.pos.map { $0 + " " } ?? "").font(.custom("Georgia", size: 12)).italic().foregroundStyle(YYColor.t3)
                        + Text(meaning.text).font(.yy(size: 12)).foregroundStyle(YYColor.t1))
                        .lineLimit(2)
                }
                if !w.context.isEmpty {
                    Text(Vocab.attributed(w.context, word: w.word, accent: tint.accent, limit: 110))
                        .font(.custom("Georgia", size: 12)).foregroundStyle(YYColor.t2)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .padding(.top, 1)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct NoteList: View {
    let model: ReaderModel
    let marks: [Mark]
    let edit: (Mark) -> Void
    private let tint = YYTint.standard

    var body: some View {
        if marks.isEmpty {
            empty(String(localized: "还没有划线"), String(localized: "选中文字，按 1–4 就划上"))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(marks.enumerated()), id: \.element.id) { i, mark in
                            if i > 0 { Rectangle().fill(YYColor.line).frame(height: 0.5) }
                            item(mark).id(mark.id)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
                .onAppear {
                    if let here = marks.first(where: { $0.section == model.section && Int($0.start.sentence) >= model.sentence }) {
                        proxy.scrollTo(here.id, anchor: .center)
                    }
                }
            }
        }
    }

    private func item(_ mark: Mark) -> some View {
        let label = pageLabel(model, section: mark.section, sentence: Int(mark.start.sentence))
        let here = label.hasSuffix(String(localized: "这一页"))
        return Button { model.go(to: mark) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                    .font(.yy(size: 10.5, weight: here ? .semibold : .regular))
                    .foregroundStyle(here ? tint.accent : YYColor.t3)
                MarkText(mark: mark)
                    .font(YYUI.serif(13))
                    .foregroundStyle(YYColor.t1)
                    .lineSpacing(5)
                    .multilineTextAlignment(.leading)
                if let note = mark.note {
                    Text(note)
                        .font(.custom("Kaiti SC", size: 12.5).italic())
                        .foregroundStyle(tint.accent)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(tint.accent).frame(width: 1.5) }
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(mark.note == nil ? String(localized: "写想法…") : String(localized: "改想法…")) { edit(mark) }
            Menu("换个样子") {
                ForEach(MarkStyle.colours + MarkStyle.lines, id: \.self) { style in
                    Button(style.name) { model.setStyle(style, of: mark) }
                }
            }
            Divider()
            Button("删除划线", role: .destructive) { model.deleteMark(mark) }
        }
    }

    private func styled(_ mark: Mark) -> Text {
        var text = AttributedString(mark.text)
        switch mark.style {
        case .yellow, .blue, .pink: text.backgroundColor = mark.style.fill
        case .wave:
            text.underlineStyle = Text.LineStyle(pattern: .dot, color: YYColor.hlR)
        case .underline: text.underlineStyle = .single
        case .dotted: text.underlineStyle = Text.LineStyle(pattern: .dot)
        }
        return Text(text)
    }
}

/// 搜索结果: every hit with its context, by page; the current one filled.
private struct SearchPanel: View {
    let model: ReaderModel
    private let tint = YYTint.standard

    private static func rowID(_ i: Int) -> String { "hit-\(i)" }

    private struct Group: Identifiable {
        let page: Int
        var id: String { "page-\(page)" }
        let label: String
        var hits: [(Int, SearchHit)]
    }

    private var groups: [Group] {
        var out: [Group] = []
        for (i, hit) in model.hits.enumerated() {
            let page = model.estimatedPage(section: hit.section, sentence: Int(hit.sentence)) ?? 0
            if out.last?.page == page {
                out[out.count - 1].hits.append((i, hit))
            } else {
                out.append(Group(page: page, label: pageLabel(model, section: hit.section, sentence: Int(hit.sentence)), hits: [(i, hit)]))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("搜索结果").font(.yy(size: 14, weight: .bold)).foregroundStyle(YYColor.t1)
                if !model.query.isEmpty {
                    Text("“\(model.query)” · \(model.hits.count) 处").font(.yy(size: 10.5)).monospacedDigit().foregroundStyle(YYColor.t3)
                }
            }
            .padding(.horizontal, 2)
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                empty(String(localized: "搜这本书"), String(localized: "在上面打字，回车或 ⌘G 下一处"))
            } else if model.hits.isEmpty {
                empty(String(localized: "没找到"), String(localized: "换个说法试试"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // `.v-mr-rg` / `.v-mr-r`
                            // Pages and hits are both numbers: their ids are kept apart, or a page
                            // and the hit with the same number land in each other's place.
                            ForEach(Array(groups.enumerated()), id: \.element.id) { g, group in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(group.label.replacingOccurrences(of: String(localized: " · 这一页"), with: ""))
                                        .font(.yy(size: 11, weight: .semibold))
                                        .foregroundStyle(YYColor.t1)
                                    Spacer()
                                    Text("\(group.hits.count) 处\(group.label.hasSuffix(String(localized: "这一页")) ? String(localized: " · 这一页") : "")")
                                        .font(.yy(size: 10))
                                        .foregroundStyle(YYColor.t3)
                                }
                                .monospacedDigit()
                                .padding(.horizontal, 8)
                                .padding(.top, g == 0 ? 0 : 12)
                                .padding(.bottom, 5)
                                ForEach(Array(group.hits.enumerated()), id: \.element.0) { k, pair in
                                    // No line next to the one showing.
                                    let quiet = k == 0 || model.hitIndex == pair.0 || model.hitIndex == group.hits[k - 1].0
                                    Rectangle().fill(quiet ? .clear : YYColor.line).frame(height: 0.5)
                                    row(pair.0, pair.1, first: k == 0).id(Self.rowID(pair.0))
                                }
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .scrollIndicators(.never)
                    .padding(.horizontal, -6)
                    .onChange(of: model.hitIndex) { _, i in
                        if let i { withAnimation { proxy.scrollTo(Self.rowID(i), anchor: .center) } }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    private func row(_ i: Int, _ hit: SearchHit, first: Bool) -> some View {
        let now = model.hitIndex == i
        var text = AttributedString(hit.before)
        var match = AttributedString(hit.matched)
        match.foregroundColor = tint.accent
        match.font = YYUI.serif(12.5, .bold)
        var after = AttributedString(hit.after)
        if now { text.foregroundColor = tint.accent; after.foregroundColor = tint.accent }
        text.append(match)
        text.append(after)
        return Button { model.show(hit: i) } label: {
            Text(text)
                .font(YYUI.serif(12.5))
                .foregroundStyle(YYColor.t1)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.top, first && !now ? 2 : 8)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(now ? tint.accentSoft : .clear, in: .rect(cornerRadius: 10))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

#endif

#if os(macOS)
extension ToolbarContent {
    /// Text that sits on the toolbar itself, not in a glass capsule (macOS 26 and later).
    @ToolbarContentBuilder func withoutGlass() -> some ToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
#endif
