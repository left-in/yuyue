import SwiftUI
import Translation
import YuyueCore

/// A book open for reading: the pages, and the controls around them.
struct ReaderScreen: View {
    let library: Library
    let bookID: String
    @State private var model: ReaderModel?
    @State private var comic: ComicModel?
    @State private var pdf: PdfModel?

    var body: some View {
        Group {
            if let model {
                ReaderContent(model: model)
                    // A book built again comes with a new model; the pages go with it.
                    .id(ObjectIdentifier(model))
                    #if os(macOS)
                    .background(ReaderWindowShape(kind: .book))
                    #endif
            } else if let comic {
                #if os(macOS)
                MacComicView(model: comic)
                    .background(ReaderWindowShape(kind: .comic))
                #else
                PhoneComicView(model: comic)
                #endif
            } else if let pdf {
                #if os(macOS)
                MacPdfView(model: pdf)
                    .background(ReaderWindowShape(kind: .book))
                #else
                PhonePdfView(model: pdf)
                #endif
            } else {
                Color.clear
            }
        }
        #if os(macOS)
        .background(OneWindowPerBook(bookID: bookID))
        #endif
        .onAppear {
            guard model == nil, comic == nil, pdf == nil else { return }
            #if os(iOS)
            // Still being read aloud from the shelf: pick it up as it is.
            if let held = library.nowPlaying, held.bookID == bookID {
                if let held = held as? ReaderModel { model = held } else if let held = held as? PdfModel { pdf = held }
                library.nowPlaying = nil
                if model != nil || pdf != nil { return }
            } else if let held = library.nowPlaying {
                // Another book: one voice at a time.
                held.stopAndClose()
                library.nowPlaying = nil
            }
            #endif
            let format = library.books.first(where: { $0.id == bookID })?.format
            if format == .comic {
                #if os(macOS)
                comic = ComicModel(library: library, bookID: bookID, wide: true)
                #else
                // An iPad held sideways shows two pages; a phone one.
                let screen = UIScreen.main.bounds.size
                comic = ComicModel(library: library, bookID: bookID, wide: screen.width > screen.height)
                #endif
            } else if format == .pdf {
                pdf = PdfModel(library: library, bookID: bookID)
            } else {
                model = ReaderModel(library: library, bookID: bookID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookRebuilt)) { n in
            // Read another way (编码和目录): the chapters changed under the open pages.
            guard n.object as? String == bookID, model != nil else { return }
            model?.retire()
            model = ReaderModel(library: library, bookID: bookID)
        }
        .onDisappear {
            #if os(iOS)
            // Closing the pages doesn't stop the voice: the 播放条 over the tabs carries on with it.
            if let model, model.isPlaying {
                model.flush()
                library.nowPlaying = model
            } else if let pdf, pdf.isPlaying {
                library.nowPlaying = pdf
            } else {
                model?.close()
                pdf?.close()
            }
            comic?.close()
            #else
            model?.close()
            comic?.close()
            pdf?.close()
            #endif
            // The shelf shows how far each book has been read; this one has just moved on.
            library.reload()
        }
    }
}

#if os(macOS)
/// A book has one window. Opening it again comes to the window it has; but windows put back from
/// last time (and any opened while they were being put back) can bring a book twice, so a second
/// window for a book brings the first forward and closes itself.
private struct OneWindowPerBook: NSViewRepresentable {
    let bookID: String

    @MainActor private static var open: [String: WeakWindow] = [:]
    private struct WeakWindow { weak var window: NSWindow? }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let bookID = bookID
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if let other = Self.open[bookID]?.window, other !== window, other.isVisible || other.isMiniaturized {
                other.makeKeyAndOrderFront(nil)
                window.close()
                return
            }
            Self.open[bookID] = WeakWindow(window: window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// Books and comics keep their own window size: a book opens as the shelf does (`.v-mac`, with
/// room for the notes beside the column), a comic wider for two pages side by side and dark
/// behind the glass. Each remembers how it was last sized, so
/// reading a comic doesn't leave the next book in a wide window.
private struct ReaderWindowShape: NSViewRepresentable {
    enum Kind: String {
        case book, comic

        var standard: CGSize { self == .book ? CGSize(width: 1040, height: 720) : CGSize(width: 1180, height: 820) }
    }

    let kind: Kind

    final class Coordinator {
        nonisolated(unsafe) var observer: NSObjectProtocol?
        deinit { observer.map(NotificationCenter.default.removeObserver) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let key = "window.size.\(kind.rawValue)", kind = kind
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if kind == .comic {
                window.backgroundColor = .black
                window.titlebarAppearsTransparent = true
            }
            let saved = UserDefaults.standard.string(forKey: key).map(NSSizeFromString) ?? kind.standard
            let frame = window.frame
            if !window.styleMask.contains(.fullScreen), let screen = window.screen?.visibleFrame,
               abs(frame.width - saved.width) > 1 || abs(frame.height - saved.height) > 1 {
                let width = min(saved.width, screen.width - 40), height = min(saved.height, screen.height - 40)
                window.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
                    .intersection(screen), display: true)
            }
            context.coordinator.observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
            ) { note in
                guard let window = note.object as? NSWindow, !window.styleMask.contains(.fullScreen) else { return }
                UserDefaults.standard.set(NSStringFromSize(window.frame.size), forKey: key)
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
#endif

private struct ReaderContent: View {
    @AppStorage(ImmersivePrefs.statusKey) private var hidesStatusBar = true
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var thought: Mark?
    @State private var translating: String?
    #if os(iOS)
    @State private var sharing: QuoteShare?
    /// 下拉加书签: how far the page is pulled down.
    @State private var pull: CGFloat = 0
    /// 第一次进阅读器: where to tap, drawn once.
    @AppStorage("reader.tapHintShown") private var tapHintShown = false
    @State private var tapHint = false
    #endif

    private var paper: YYPaper { model.settings.paper.tokens }

    var body: some View {
        pages
            .preferredColorScheme(paper.isDark ? .dark : .light)
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { model.flush() }
            }
            .alert("出错了", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
                Button("好") {}
            } message: {
                Text(model.failure ?? "")
            }
            .alert("朗读出错了", isPresented: Binding(get: { model.player?.failure != nil }, set: { if !$0 { model.player?.failure = nil } })) {
                Button("好") {}
            } message: {
                Text(model.player?.failure ?? "")
            }
    }

    #if os(iOS)
    private var pages: some View {
        PagerView(pager: model.pager)
            .ignoresSafeArea()
            .background(paper.bg.ignoresSafeArea())
            .overlay(alignment: .top) { pullMark }
            .overlay(alignment: .topTrailing) {
                if pull == 0, model.bookmarkHere != nil, !model.chromeShown, !model.searchShown {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(YYTint.standard.accent)
                        .padding(.trailing, 22)
                        .offset(y: -3)
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay {
                if tapHint { PageTapHint(paper: paper).transition(.opacity) }
            }
            .overlay {
                if model.listenOnly { ListenOnlyCover(model: model) }
            }
            .overlay { PhoneReaderChrome(model: model, close: { dismiss() }) }
            .overlay { cards.ignoresSafeArea() }
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    UndoToast(toast: toast) { model.undoToast() }
                        .padding(.horizontal, 16)
                        .padding(.bottom, model.immersive && !model.chromeShown ? 24 : 72)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: model.toast?.id)
            .animation(.easeOut(duration: 0.15), value: model.selection)
            .animation(.easeOut(duration: 0.15), value: model.openMark)
            .sheet(item: $thought) { mark in
                PhoneThoughtSheet(mark: mark) { text in
                    model.setNote(text, of: mark)
                    thought = nil
                } cancel: {
                    thought = nil
                }
            }
            .translationPresentation(isPresented: Binding(get: { translating != nil }, set: { if !$0 { translating = nil } }), text: translating ?? "")
            .animation(.easeOut(duration: 0.2), value: model.chromeShown)
            .statusBarHidden(model.immersive ? hidesStatusBar : !model.chromeShown)
            .persistentSystemOverlays(model.immersive && !model.chromeShown ? .hidden : .automatic)
            .sheet(isPresented: $model.tocShown) {
                TocList(model: model)
                    .presentationDetents([.large])
            }
            .onChange(of: model.chromeShown) { _, shown in
                if shown { model.dismissCards() }
            }
            .sheet(isPresented: Binding(get: { model.panel == .companion }, set: { if !$0 { model.panel = nil } })) {
                PhoneCompanion(model: model)
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
            .sheet(item: $sharing) { PhoneQuoteShare(quote: $0) }
            .sensoryFeedback(.impact(weight: .light), trigger: pull >= ReaderPager.pullMark)
            .animation(.easeOut(duration: 0.2), value: model.bookmarkHere?.id)
            .onAppear {
                model.pager.onPull = { distance, ended in
                    if ended {
                        if distance >= ReaderPager.pullMark { model.toggleBookmark() }
                        pull = 0
                    } else {
                        pull = distance
                    }
                }
                guard !tapHintShown, model.settings.mode == .paginated else { return }
                tapHintShown = true
                withAnimation(.easeOut(duration: 0.3)) { tapHint = true }
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation(.easeOut(duration: 0.6)) { tapHint = false }
                }
            }
    }

    /// 下拉加书签 (prototype): in the space the page leaves, a bookmark and what letting go does.
    @ViewBuilder private var pullMark: some View {
        if pull > 0 {
            let reached = pull >= ReaderPager.pullMark
            let adding = model.bookmarkHere == nil
            VStack(spacing: 6) {
                Image(systemName: adding ? "bookmark.fill" : "bookmark.slash")
                    .font(.system(size: 20))
                    .foregroundStyle(reached ? YYTint.standard.accent : paper.ink2)
                    .scaleEffect(reached ? 1.1 : 0.9)
                Text(reached ? (adding ? String(localized: "松手加书签") : String(localized: "松手删掉书签")) : (adding ? String(localized: "下拉加书签") : String(localized: "下拉删掉书签")))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(paper.ink2)
            }
            .frame(height: pull, alignment: .bottom)
            .padding(.bottom, 0)
            .clipped()
            .animation(.snappy(duration: 0.15), value: reached)
            .allowsHitTesting(false)
        }
    }

    /// 选中文字, or a highlight tapped: the same card as on the Mac, over the words.
    @ViewBuilder private var cards: some View {
        if let selection = model.selection {
            GeometryReader { g in
                SelectionCard(model: model, current: nil, thought: {
                    if let mark = model.mark() { thought = mark }
                }, translate: { translate(selection.text) }, ask: { askCompanion(selection.text) },
                share: { share(selection.text, note: nil, section: selection.section) })
                .fixedSize()
                .modifier(Above(rect: selection.rect, in: g.size))
            }
            .transition(.opacity)
        } else if let open = model.openMark {
            GeometryReader { g in
                SelectionCard(model: model, current: open.mark, thought: {
                    thought = open.mark
                    model.dismissCards()
                }, translate: { translate(open.mark.text) }, ask: { askCompanion(open.mark.text) },
                share: { share(open.mark.text, note: open.mark.note, section: open.mark.section) })
                .fixedSize()
                .modifier(Above(rect: CGRect(x: open.at.x - 1, y: open.at.y - 12, width: 2, height: 24), in: g.size))
            }
            .transition(.opacity)
        }
    }

    private func translate(_ text: String) {
        model.dismissCards()
        translating = text
    }

    /// 问: the words chosen go along to 书伴.
    private func askCompanion(_ quote: String?) {
        model.dismissCards()
        if let quote { model.companionQuote = quote }
        model.chromeShown = false
        model.panel = .companion
    }

    private func share(_ text: String, note: String?, section: UInt32) {
        let summary = model.detail?.summary
        let chapter = model.detail?.chapterTitle(for: section)
        sharing = QuoteShare(text: text, note: note, title: summary?.title ?? "", author: summary?.authors.first,
                             chapter: chapter == summary?.title ? nil : chapter, coverPath: summary?.coverPath)
        model.dismissCards()
    }

    #else
    private var pages: some View {
        MacReaderView(model: model)
    }
    #endif
}

#if os(iOS)
struct PagerView: UIViewRepresentable {
    let pager: ReaderPager
    func makeUIView(context: Context) -> ReaderPager { pager }
    func updateUIView(_ view: ReaderPager, context: Context) {}
}
#else
struct PagerView: NSViewRepresentable {
    let pager: ReaderPager
    func makeNSView(context: Context) -> ReaderPager { pager }
    func updateNSView(_ view: ReaderPager, context: Context) {}
}
#endif

/// 目录 (prototype R4): the book on top, then 目录 · 书签 · 笔记. The chapter being read sits in
/// the middle in the accent, with a line for how far into it; the ones read are faded; each says
/// about how long it takes.
private struct TocList: View {
    let model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.toc
    @State private var thought: Mark?
    private let tint = YYTint.standard

    private enum Tab { case toc, bookmarks, notes }

    var body: some View {
        let chapters = model.tocChapters
        let current = model.currentChapter(in: chapters)
        VStack(alignment: .leading, spacing: YYUI.s(12)) {
            header(chapters, current)
                .padding(.horizontal, YYUI.s(16))
            YYSegments(items: [(Tab.toc, String(localized: "目录")), (.bookmarks, String(localized: "书签")), (.notes, String(localized: "笔记"))], selection: $tab,
                       counts: [.bookmarks: model.bookmarks.count, .notes: model.marks.count].filter { $0.value > 0 })
                .padding(.horizontal, YYUI.s(14))
            switch tab {
            case .toc: toc(chapters, current)
            case .bookmarks: bookmarks
            case .notes: notes
            }
        }
        .padding(.top, YYUI.s(20))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(YYColor.bg)
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #endif
        .sheet(item: $thought) { mark in
            #if os(iOS)
            PhoneThoughtSheet(mark: mark) { text in
                model.setNote(text, of: mark)
                thought = nil
            } cancel: {
                thought = nil
            }
            #endif
        }
    }

    /// `.v-rd-bkh`: the cover, the book, where the reader is in it.
    private func header(_ chapters: [TocChapter], _ current: Int?) -> some View {
        let book = model.detail?.summary
        let at = current.flatMap { chapters[safe: $0] }.map { c in ChapterTitle(c.title).number ?? c.title }
        return HStack(spacing: YYUI.s(11)) {
            if let book { BookCover(book: book).frame(width: YYUI.s(30)) }
            VStack(alignment: .leading, spacing: YYUI.s(3)) {
                Text(book?.title ?? String(localized: "目录")).font(YYUI.font(14, .bold)).foregroundStyle(YYColor.t1)
                Text([book?.authors.first, at.map { String(localized: "读到\($0)") }, String(localized: "全书 \(Int((model.bookFraction * 100).rounded()))%")].compactMap { $0 }.joined(separator: " · "))
                    .font(YYUI.font(10)).monospacedDigit().foregroundStyle(YYColor.t3)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(YYUI.font(10, .semibold)).foregroundStyle(YYColor.t1)
                    .frame(width: YYUI.s(26), height: YYUI.s(26))
                    .background(YYColor.inset, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
    }

    // MARK: 目录

    private func toc(_ chapters: [TocChapter], _ current: Int?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(chapters) { c in
                        if c.id > 0 { Rectangle().fill(YYColor.line).frame(height: 0.5) }
                        chapterRow(c, current: current)
                            .id(c.id)
                    }
                }
                .padding(.horizontal, YYUI.s(12))
                .background(YYColor.card, in: .rect(cornerRadius: YYUI.s(14)))
                .overlay(RoundedRectangle(cornerRadius: YYUI.s(14)).strokeBorder(YYColor.line, lineWidth: 0.5))
                .padding(.horizontal, YYUI.s(14))
                .padding(.bottom, YYUI.s(20))
            }
            .scrollIndicators(.never)
            .onAppear {
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
        }
    }

    /// `.v-rd-ch`: 第几回, the name, the minutes; this one in the accent, its name whole, a line under.
    private func chapterRow(_ c: TocChapter, current: Int?) -> some View {
        let now = c.id == current
        let done = (current ?? -1) > c.id
        let t = ChapterTitle(c.title)
        let color = now ? tint.accent : YYColor.t1
        let minutes = model.minutes(of: c)
        let note = now ? String(localized: "还剩 \(max(1, Int((Double(minutes) * (1 - model.within(c))).rounded()))) 分钟") : String(localized: "\(minutes) 分钟")
        return Button {
            model.go(to: c.item)
            dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: YYUI.s(6)) {
                if let number = t.number {
                    Text(number)
                        .font(YYUI.font(10.5, now ? .semibold : .regular))
                        .foregroundStyle(now ? tint.accent : YYColor.t3)
                        .lineLimit(1)
                        .frame(width: YYUI.s(46), alignment: .leading)
                }
                VStack(alignment: .leading, spacing: YYUI.s(8)) {
                    HStack(alignment: .firstTextBaseline, spacing: YYUI.s(6)) {
                        Text(t.name)
                            .font(YYUI.font(11.5, now ? .semibold : .regular))
                            .foregroundStyle(done ? YYColor.t3 : color)
                            .lineLimit(now ? nil : 1)
                            .lineSpacing(now ? YYUI.s(11.5) * 0.6 : 0)
                            .multilineTextAlignment(.leading)
                            .padding(.leading, CGFloat(c.depth) * YYUI.s(12))
                        Spacer(minLength: 0)
                        Text(note)
                            .font(YYUI.font(10, now ? .semibold : .regular)).monospacedDigit()
                            .foregroundStyle(now ? tint.accent : YYColor.t3)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if now { ProgressLine(value: model.within(c), height: YYUI.s(3)) }
                }
            }
            .padding(.vertical, YYUI.s(11))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: 书签 · 笔记

    /// The same white cards, kept as a list so a row can be swiped away.
    private func cards(@ViewBuilder _ rows: () -> some View) -> some View {
        List { Section { rows() } }
            #if os(iOS)
            .listStyle(.insetGrouped)
            .listSectionSpacing(0)
            .contentMargins(.top, 0, for: .scrollContent)
            #endif
            .scrollContentBackground(.hidden)
    }

    @ViewBuilder private var bookmarks: some View {
        if model.bookmarks.isEmpty {
            empty(String(localized: "还没有书签"), String(localized: "书页往下拉一下，就给这一页加上书签"))
        } else {
            cards {
                ForEach(model.bookmarks, id: \.id) { mark in
                    Button {
                        model.jump(section: mark.section, sentence: Int(mark.sentence))
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: YYUI.s(4)) {
                            HStack(spacing: YYUI.s(5)) {
                                Image(systemName: "bookmark.fill").font(YYUI.font(9)).foregroundStyle(tint.accent)
                                Text(place(section: mark.section, sentence: Int(mark.sentence))).lineLimit(1)
                                Spacer()
                                Text(mark.at.dayText)
                            }
                            .font(YYUI.font(10)).monospacedDigit()
                            .foregroundStyle(YYColor.t3)
                            Text(mark.text)
                                .font(YYUI.font(11.5))
                                .foregroundStyle(YYColor.t1)
                                .lineLimit(2)
                        }
                        .padding(.vertical, YYUI.s(3))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("删除", role: .destructive) { model.deleteBookmark(mark) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var notes: some View {
        if model.marks.isEmpty {
            empty(String(localized: "还没有划线"), String(localized: "长按选中文字，点一个颜色就划上"))
        } else {
            cards {
                ForEach(model.marks, id: \.id) { mark in
                    Button {
                        model.go(to: mark)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: YYUI.s(5)) {
                            MarkText(mark: mark)
                                .font(YYUI.font(12.5, design: .serif))
                                .lineSpacing(YYUI.s(12.5) * 0.7)
                                .foregroundStyle(YYColor.t1)
                            if let note = mark.note {
                                Text(note)
                                    .font(.custom("Kaiti SC", size: YYUI.s(12)))
                                    .foregroundStyle(tint.accent)
                                    .padding(.leading, YYUI.s(9))
                                    .overlay(alignment: .leading) { Rectangle().fill(tint.accent).frame(width: 1.5) }
                            }
                            Text(place(section: mark.section, sentence: Int(mark.start.sentence)))
                                .font(YYUI.font(10)).monospacedDigit()
                                .foregroundStyle(YYColor.t3)
                                .lineLimit(1)
                        }
                        .padding(.vertical, YYUI.s(4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(mark.note == nil ? String(localized: "写想法") : String(localized: "改想法"), systemImage: "pencil") { thought = mark }
                        Menu("换个样子", systemImage: "paintpalette") {
                            ForEach(MarkStyle.colours + MarkStyle.lines, id: \.self) { style in
                                Button(style.name) { model.setStyle(style, of: mark) }
                            }
                        }
                        Button("删除划线", systemImage: "trash", role: .destructive) { model.deleteMark(mark) }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { model.deleteMark(mark) }
                    }
                }
            }
        }
    }

    /// "第三回 · 第 3 页", or the chapter when the pages are not counted yet.
    private func place(section: UInt32, sentence: Int) -> String {
        let chapter = model.detail?.chapterTitle(for: section)
        let page = model.estimatedPage(section: section, sentence: sentence).map { String(localized: "第 \($0) 页") }
        return [chapter, page].compactMap { $0 }.joined(separator: " · ")
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: YYUI.s(5)) {
            Text(title).font(YYUI.font(12.5, .semibold)).foregroundStyle(YYColor.t2)
            Text(detail).font(YYUI.font(10.5)).foregroundStyle(YYColor.t3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(iOS)
/// 第一次进阅读器 (prototype): three faint zones — 上一页, 菜单, 下一页 — gone after a few seconds.
private struct PageTapHint: View {
    let paper: YYPaper

    var body: some View {
        HStack(spacing: 0) {
            zone(String(localized: "上一页"), "chevron.left", 0.3)
            zone(String(localized: "菜单"), "hand.tap", 0.4)
            zone(String(localized: "下一页"), "chevron.right", 0.3)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func zone(_ title: String, _ symbol: String, _ share: CGFloat) -> some View {
        GeometryReader { g in
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium))
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(paper.ink.opacity(0.7))
            .frame(width: g.size.width, height: g.size.height)
            .background(paper.ink.opacity(title == String(localized: "菜单") ? 0.07 : 0.035))
            .overlay(alignment: .trailing) {
                if title != String(localized: "下一页") {
                    Rectangle().fill(paper.ink.opacity(0.12)).frame(width: 0.5)
                }
            }
        }
        .containerRelativeFrame(.horizontal) { w, _ in w * share }
    }
}
#endif
