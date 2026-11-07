#if os(iOS)
import SwiftUI
import YuyueCore

/// The phone's page: only the words and one glass capsule at the
/// bottom — 目录, where the reader is, ‹ 朗读 ›, Aa. A tap in the middle floats 返回, the book's
/// name and page, 搜索, 书签 and 更多 along the top. 书内搜索 takes over both: the field on top,
/// 第 3 / 11 处 in the capsule. 沉浸阅读 leaves only a hairline.
struct PhoneReaderChrome: View {
    @Bindable var model: ReaderModel
    let close: () -> Void
    @State private var listenShown = false
    @State private var hitsShown = false
    @State private var infoShown = false
    @State private var immersiveShown = false
    @AppStorage(ImmersivePrefs.progressKey) private var hidesProgress = true
    @State private var exported: URL?
    @FocusState private var typing: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var paper: YYPaper { model.paperTokens }
    /// 沉浸阅读 hides the capsule until the middle is tapped.
    private var capsuleShown: Bool { !model.immersive || model.chromeShown || model.searchShown }

    var body: some View {
        layout
        .foregroundStyle(paper.ink)
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.22), value: model.chromeShown)
        .animation(.snappy(duration: 0.22), value: model.searchShown)
        .animation(.snappy(duration: 0.22), value: model.immersive)
        .animation(.snappy(duration: 0.22), value: model.returnTo == nil)
        .animation(.snappy(duration: 0.22), value: model.recap)
        .animation(.snappy(duration: 0.22), value: model.openNote)
        .animation(.snappy(duration: 0.22), value: model.elsewhere == nil)
        .animation(.snappy(duration: 0.22), value: model.narrationFlag)
        .task(id: model.immersive && model.chromeShown) {
            // 沉浸: called up by a tap, gone again by itself.
            guard model.immersive, model.chromeShown else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, !listenShown, !model.settingsShown { model.chromeShown = false }
        }
        .sheet(isPresented: $listenShown) {
            ScrollView { ListenCard(model: model) }
                .presentationDetents([.medium, .large])
                .presentationBackground(YYColor.card)
        }
        .sheet(isPresented: $model.settingsShown) {
            ScrollView { TypesetCard(model: model) }
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationBackground(YYColor.card)
        }
        .sheet(isPresented: $hitsShown) { hitList }
        .sheet(item: $model.adjustingFlag) { flag in NarrationAdjustSheet(model: model, flag: flag) }
        .onReceive(NotificationCenter.default.publisher(for: Audiobooks.timingsChanged)) { _ in model.timingsChanged() }
        .sheet(isPresented: $model.rulesShown) {
            NavigationStack {
                ReplaceRulesView(core: model.core, bookID: model.bookID, bookTitle: model.detail?.summary.title ?? "") {
                    model.rulesShown = false
                }
            }
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
            }
        }
        .sheet(isPresented: $immersiveShown) { PhoneImmersiveSheet(model: model) }
        .sheet(isPresented: $infoShown) {
            if let library = model.library, let book = library.books.first(where: { $0.id == model.bookID }) {
                PhoneBookInfo(library: library, book: book)
            }
        }
        .noteSender(model.noteSender)
        .sheet(item: Binding(get: { exported.map(Shared.init) }, set: { exported = $0?.url })) { item in
            ActivitySheet(items: [item.url]).ignoresSafeArea()
        }
    }

    // MARK: Layout

    /// On the phone: the top bar, and the capsule with the cards above it, in one column at the
    /// bottom. On iPhone Duo's inner display the bottom goes under the right page (§3 of the Duo
    /// spec), so it never sits on the fold.
    @ViewBuilder private var layout: some View {
        if InnerDisplay.isOn(sizeClass) {
            spreadLayout
        } else {
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottom
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) { immersiveNote }
        }
    }

    /// The inner display: the top bar as on the phone; the capsule and its cards on the right
    /// page, trailing, as wide as the page less 16 each side and 24 above the safe area. Half
    /// folded, they start clear of the fold. Measured over the whole screen, as the pages are.
    private var spreadLayout: some View {
        GeometryReader { g in
            let width = g.size.width
            let trailing = g.safeAreaInsets.trailing
            // The right page starts past the gutter; half folded, at least 16 past the fold.
            let pageStart = max(width / 2 + CGFloat(ReaderPager.spreadMargin), (InnerDisplay.fold(in: g)?.maxX ?? 0) + 16)
            let barWidth = max(0, width - trailing - 16 - (pageStart + 16))
            // The left page ends before the gutter; half folded, at least 16 before the fold.
            let leftPageEnd = min(width / 2 - CGFloat(ReaderPager.spreadMargin), (InnerDisplay.fold(in: g)?.minX ?? width) - 16)
            VStack(spacing: 0) {
                // On the left page, so half folded it never crosses the fold.
                topBar
                    .padding(.horizontal, 12)
                    .frame(width: max(0, leftPageEnd - g.safeAreaInsets.leading - 16))
                    .padding(.leading, g.safeAreaInsets.leading + 4)
                    .padding(.top, g.safeAreaInsets.top)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                bottom
                    .frame(width: barWidth)
                    .overlay(alignment: .bottom) { immersiveNote }
                    .padding(.trailing, trailing + 16)
                    .padding(.bottom, g.safeAreaInsets.bottom + 24)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The pages' rectangle; the keyboard still pushes the search capsule up.
        .ignoresSafeArea(.container)
        .overlay(alignment: .bottom) {
            if model.immersive, !capsuleShown, hidesProgress, ImmersivePrefs.keepsLine { hairline }
        }
    }

    @ViewBuilder private var topBar: some View {
        if model.searchShown {
            searchField.transition(.move(edge: .top).combined(with: .opacity))
        } else if model.chromeShown {
            top.transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// The capsule, and the cards and pills that come up above it.
    private var bottom: some View {
        VStack(spacing: 0) {
            if let e = model.elsewhere {
                ElsewhereCard(elsewhere: e, tint: .standard, stay: { model.elsewhere = nil }, jump: { model.jumpElsewhere() })
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let open = model.openNote {
                FootnoteCard(open: open, bookTitle: model.detail?.summary.title ?? "", tint: .standard,
                             toNotes: { model.goToNotes() }, done: { model.openNote = nil })
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let recap = model.recap, !model.searchShown {
                RecapCard(recap: recap, tint: .standard) { model.recap = nil }
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let flag = model.narrationFlag, !model.searchShown {
                NarrationFlagCard(flag: flag, letBe: { model.letFlagBe() }, adjust: { model.adjustFlag() })
                    .padding(.horizontal, 2)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let back = model.returnTo, capsuleShown, !model.searchShown {
                ReturnPill(page: back.page, paper: paper) { model.goBack() }
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let doubt = model.txtDoubt, capsuleShown, !model.searchShown {
                DoubtPill(doubt: doubt, paper: paper, open: { model.txtShown = true }, dismiss: { model.dismissDoubt() })
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if capsuleShown {
                Group {
                    if model.searchShown { searchCapsule } else { capsule }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// 沉浸, with the capsule away: the progress line, or the hairline.
    @ViewBuilder private var immersiveNote: some View {
        if model.immersive, !capsuleShown {
            if !hidesProgress {
                Text(model.capsuleNote)
                    .font(.yy(size: 10).monospacedDigit())
                    .foregroundStyle(paper.ink2)
                    .padding(.bottom, 2)
                    .allowsHitTesting(false)
            } else if ImmersivePrefs.keepsLine, !InnerDisplay.isOn(sizeClass) {
                hairline
            }
        }
    }

    // MARK: Top

    private var top: some View {
        HStack(spacing: 8) {
            Button(action: close) {
                Image(systemName: "chevron.left").font(.yy(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .glass(paper, in: Circle())
            }
            .accessibilityLabel("返回书架")
            VStack(spacing: 1) {
                Text(model.detail?.summary.title ?? "").font(.yy(size: 13, weight: .semibold)).lineLimit(1)
                Text(whereLine).font(.yy(size: 11)).foregroundStyle(paper.ink2).lineLimit(1).monospacedDigit()
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .glass(paper, in: Capsule())
            HStack(spacing: 0) {
                Button { startSearch() } label: { icon("magnifyingglass") }
                    .accessibilityLabel("搜索这本书")
                Button { model.toggleBookmark() } label: {
                    icon(model.bookmarkHere == nil ? "bookmark" : "bookmark.fill")
                        .foregroundStyle(model.bookmarkHere == nil ? paper.ink : YYTint.standard.accent)
                }
                .accessibilityLabel(model.bookmarkHere == nil ? String(localized: "加书签") : String(localized: "拿掉书签"))
                Menu {
                    Button("沉浸阅读", systemImage: "viewfinder") { immersiveShown = true }
                    Button("书的信息", systemImage: "info.circle") { infoShown = true }
                    if model.detail?.summary.format != .pdf {
                        Button("替换规则", systemImage: "arrow.left.arrow.right") { model.rulesShown = true }
                    }
                    if model.detail?.summary.format == .txt {
                        Button("编码和目录", systemImage: "doc.text.magnifyingglass") { model.txtShown = true }
                    }
                    Menu("导出笔记", systemImage: "square.and.arrow.up") {
                        Button("Markdown", systemImage: "doc.plaintext") { exportNotes() }
                        Divider()
                        NoteSendItems(sender: model.noteSender, books: {
                            guard let library = model.library else { return [] }
                            return NotedBook.load(library, only: [model.bookID]).map(\.export)
                        }, book: model.detail?.summary)
                    }
                } label: {
                    icon("ellipsis")
                        .background(paper.ink.opacity(0.09), in: .circle)
                }
                .accessibilityLabel("更多")
            }
            .padding(.horizontal, 3)
            .frame(height: 40)
            .glass(paper, in: Capsule())
        }
        .padding(.top, 4)
    }

    private var whereLine: String {
        // On a spread, the left page's number, as printed under it.
        let spread = InnerDisplay.isOn(sizeClass) && model.settings.mode == .paginated && !model.pager.chat
        return [model.chapterTitle == model.detail?.summary.title ? nil : model.chapterTitle,
                model.bookPage.map { String(localized: "第 \(spread ? $0 * 2 - 1 : $0) 页") }].compactMap { $0 }.joined(separator: " · ")
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.yy(size: 15, weight: .medium)).frame(width: 34, height: 34)
    }

    // MARK: The capsule

    private var capsule: some View {
        HStack(spacing: 2) {
            Button { model.tocShown = true } label: { capButton("list.bullet") }
                .accessibilityLabel("目录、书签和笔记")
            Button { listenShown = true } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.sentenceCount > 0 ? String(localized: "第 \(min(model.sentence + 1, model.sentenceCount)) / \(model.sentenceCount) 句") : (model.chapterTitle ?? ""))
                        .font(.yy(size: 12, weight: .semibold))
                    Text(model.capsuleNote)
                        .font(.yy(size: 10.5))
                        .foregroundStyle(paper.ink2)
                }
                .monospacedDigit()
                .lineLimit(1)
                .padding(.leading, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 40)
                .contentShape(.rect)
            }
            .accessibilityHint("听书：声音、速度、睡眠定时")
            Button { step(forward: false) } label: { capButton("chevron.left") }
                .accessibilityLabel(model.player?.spot != nil ? String(localized: "上一句") : String(localized: "上一页"))
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    // ▶ and ❚❚ turn into each other.
                    .contentTransition(.symbolEffect(.replace))
                    .animation(YYMotion.quick, value: model.isPlaying)
                    .font(.yy(size: 14, weight: .semibold))
                    .foregroundStyle(paper.onMain)
                    .frame(width: 40, height: 40)
                    .background(paper.main, in: .circle)
            }
            .accessibilityLabel(model.isPlaying ? String(localized: "暂停") : String(localized: "朗读"))
            .disabled(model.player == nil)
            Button { step(forward: true) } label: { capButton("chevron.right") }
                .accessibilityLabel(model.player?.spot != nil ? String(localized: "下一句") : String(localized: "下一页"))
            Button { model.settingsShown = true } label: {
                Text("Aa").font(.yy(size: 14, weight: .semibold)).frame(width: 36, height: 36).contentShape(.rect)
            }
            .accessibilityLabel("排版")
        }
        .padding(.horizontal, 5)
        .frame(height: 50)
        .glass(paper, in: Capsule())
        .overlay(alignment: .bottom) {
            // How far into this chapter.
            GeometryReader { g in
                Capsule().fill(paper.line)
                Capsule().fill(YYTint.standard.accent).frame(width: g.size.width * chapterProgress)
            }
            .frame(height: 2)
            .padding(.horizontal, 24)
        }
    }

    private func capButton(_ name: String) -> some View {
        Image(systemName: name).font(.yy(size: 14, weight: .semibold)).frame(width: 34, height: 40).contentShape(.rect)
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

    private var hairline: some View {
        GeometryReader { g in
            Rectangle().fill(paper.ink.opacity(0.25)).frame(width: g.size.width * model.bookFraction)
        }
        .frame(height: 1)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: 书内搜索

    private func startSearch() {
        model.chromeShown = false
        model.searchShown = true
        typing = true
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.yy(size: 14, weight: .medium)).foregroundStyle(paper.ink2)
                TextField("", text: $model.query, prompt: Text("搜这本书").foregroundStyle(paper.ink2))
                    .font(.yy(size: 15))
                    .focused($typing)
                    .submitLabel(.search)
                    .onChange(of: model.query) { model.search() }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(paper.ink2)
                    }
                    .accessibilityLabel("清空")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .glass(paper, in: Capsule())
            Button { model.endSearch() } label: {
                Image(systemName: "xmark").font(.yy(size: 14, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .glass(paper, in: Circle())
            }
            .accessibilityLabel("结束搜索")
        }
        .padding(.top, 4)
    }

    private var searchCapsule: some View {
        let q = model.query.trimmingCharacters(in: .whitespaces)
        return HStack(spacing: 2) {
            Button { typing = false; hitsShown = true } label: { capButton("list.bullet.rectangle") }
                .accessibilityLabel("全部结果")
                .disabled(model.hits.isEmpty && q.isEmpty)
            VStack(alignment: .leading, spacing: 1) {
                Group {
                    if q.isEmpty {
                        Text("输入要找的字")
                    } else if model.hits.isEmpty {
                        Text("没找到“\(q)”")
                    } else {
                        Text("第 \((model.hitIndex ?? 0) + 1) / \(model.hits.count) 处")
                    }
                }
                .font(.yy(size: 12, weight: .semibold))
                Text(hitChapter ?? (q.isEmpty ? String(localized: "输完直接跳到第一处") : String(localized: "可以问问书伴")))
                    .font(.yy(size: 10.5)).foregroundStyle(paper.ink2)
            }
            .monospacedDigit()
            .lineLimit(1)
            .padding(.leading, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.nextHit(forward: false) } label: { capButton("chevron.left") }
                .accessibilityLabel("上一处")
                .disabled(model.hits.isEmpty)
            Button { model.nextHit(forward: true) } label: { capButton("chevron.right") }
                .accessibilityLabel("下一处")
                .disabled(model.hits.isEmpty)
        }
        .padding(.horizontal, 5)
        .frame(height: 50)
        .glass(paper, in: Capsule())
    }

    private var hitChapter: String? {
        guard let i = model.hitIndex, model.hits.indices.contains(i) else { return nil }
        let hit = model.hits[i]
        return [model.detail?.chapterTitle(for: hit.section), model.estimatedPage(section: hit.section, sentence: Int(hit.sentence)).map { String(localized: "第 \($0) 页") }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// 全部结果: the same cards as 搜索结果 — 问书伴 first, then each place as the book's own
    /// sentence and where it is; the one showing is tinted.
    private var hitList: some View {
        let q = model.query.trimmingCharacters(in: .whitespaces)
        let tint = YYTint.standard
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    YYSheetHeader(title: model.hits.isEmpty ? String(localized: "没找到") : String(localized: "\(model.hits.count) 处"),
                                  subtitle: q.isEmpty ? nil : "“\(q)”") { hitsShown = false }
                    if !q.isEmpty, model.detail?.summary.format != .pdf {
                        Button {
                            hitsShown = false
                            model.endSearch()
                            model.ask(q)
                        } label: {
                            HStack(spacing: YYUI.s(10)) {
                                Image(systemName: "sparkle")
                                    .font(YYUI.font(14, .semibold))
                                    .foregroundStyle(tint.accent)
                                    .frame(width: YYUI.s(32), height: YYUI.s(32))
                                    .background(tint.accentSoft, in: .rect(cornerRadius: YYUI.s(10)))
                                VStack(alignment: .leading, spacing: YYUI.s(1)) {
                                    Text("问书伴“\(q)”").font(YYUI.font(12, .semibold)).foregroundStyle(tint.accent).lineLimit(1)
                                    Text("只用你读过的部分回答，带出处").font(YYUI.font(10)).foregroundStyle(YYColor.t3)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(YYUI.font(10, .semibold)).foregroundStyle(YYColor.t3)
                            }
                            .padding(.vertical, YYUI.s(10))
                            .padding(.horizontal, YYUI.s(12))
                            .yyCard()
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, YYUI.s(14))
                    }
                    if !model.hits.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(model.hits.enumerated()), id: \.offset) { i, hit in
                                if i > 0 { Rectangle().fill(YYColor.line).frame(height: 0.5).padding(.horizontal, YYUI.s(12)) }
                                Button {
                                    hitsShown = false
                                    model.show(hit: i)
                                } label: {
                                    VStack(alignment: .leading, spacing: YYUI.s(4)) {
                                        Text(highlighted(hit))
                                            .font(YYUI.font(12.5, design: .serif))
                                            .lineSpacing(YYUI.s(12.5) * 0.8)
                                            .foregroundStyle(YYColor.t1)
                                            .lineLimit(2)
                                        Text(place(hit))
                                            .font(YYUI.font(10)).monospacedDigit()
                                            .foregroundStyle(i == model.hitIndex ? tint.accent : YYColor.t3)
                                            .lineLimit(1)
                                    }
                                    .padding(.top, YYUI.s(10))
                                    .padding(.bottom, YYUI.s(9))
                                    .padding(.horizontal, YYUI.s(12))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(i == model.hitIndex ? tint.accentSoft : .clear)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .id(i)
                            }
                        }
                        .background(YYColor.card)
                        .clipShape(.rect(cornerRadius: YYUI.s(14)))
                        .overlay(RoundedRectangle(cornerRadius: YYUI.s(14)).strokeBorder(YYColor.line, lineWidth: 0.5))
                        .padding(.top, YYUI.s(14))
                    }
                }
                .padding(.horizontal, YYUI.s(14))
                .padding(.top, YYUI.s(18))
                .padding(.bottom, YYUI.s(20))
            }
            .scrollIndicators(.never)
            .background(YYColor.bg)
            .onAppear {
                if let i = model.hitIndex { proxy.scrollTo(i, anchor: .center) }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// "第一章 · 第 3 页".
    private func place(_ hit: SearchHit) -> String {
        [model.detail?.chapterTitle(for: hit.section), model.estimatedPage(section: hit.section, sentence: Int(hit.sentence)).map { String(localized: "第 \($0) 页") }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func highlighted(_ hit: SearchHit) -> AttributedString {
        var matched = AttributedString(hit.matched)
        matched.foregroundColor = YYTint.standard.accent
        matched.inlinePresentationIntent = .stronglyEmphasized
        matched.underlineStyle = .single
        return AttributedString(hit.before) + matched + AttributedString(hit.after)
    }

    // MARK: 导出笔记

    private struct Shared: Identifiable {
        let url: URL
        var id: URL { url }
    }

    private func exportNotes() {
        guard let library = model.library else { return }
        let noted = NotedBook.load(library, only: [model.bookID])
        guard !noted.isEmpty else {
            // Nothing to export isn't a failure: a passing note.
            model.show(Library.Toast(icon: "highlighter", title: String(localized: "这本书还没有划线和想法"), detail: String(localized: "选中文字点“划线”，就会出现在这里")))
            return
        }
        let title = model.detail?.summary.title ?? String(localized: "笔记")
        let dir = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)")
        let url = dir.appending(path: String(localized: "\(title.replacingOccurrences(of: "/", with: "-")) · 笔记.md"))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(NotedBook.markdown(noted, title: title).utf8).write(to: url)
            exported = url
        } catch {
            model.failure = String(localized: "没导出来，再试一次")
        }
    }
}

/// The system's share sheet, for a file made on the spot.
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private extension View {
    /// The page's frosted glass, as on the capsule. On e-ink, no glass and no shadow: the paper
    /// itself, a black line round it, the corners less round.
    @ViewBuilder func glass(_ paper: YYPaper, in shape: some Shape) -> some View {
        if paper.id == YYPaper.eink.id {
            let flat = shape is Circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 12))
            background(paper.bg, in: flat)
                .overlay(flat.stroke(paper.ink, lineWidth: 1))
        } else {
            yyGlass(shape, fill: paper.glass, line: paper.line, shadow: paper.isDark ? 0.4 : 0.1)
        }
    }
}
#endif
