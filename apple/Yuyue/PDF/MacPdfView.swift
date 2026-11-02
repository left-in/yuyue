#if os(macOS)
import PDFKit
import SwiftUI
import YuyueCore

/// The PDF's window: the pages as printed on a quiet grey, the tools in the toolbar as in a
/// book's window — 目录, 笔记 and 书内搜索 open at the side, 显示 picks 连续滚动 / 单页 / 双页 and
/// 夜间. Selected text is marked up from the right-click menu, or with 1–4 as in a book; the
/// capsule at the bottom reads the pages aloud, the sentence being read lit up.
struct MacPdfView: View {
    @Bindable var model: PdfModel
    @Environment(\.openWindow) private var openWindow
    @State private var panel: Panel?
    @State private var showShown = false
    @State private var listenShown = false
    @FocusState private var searchFocused: Bool
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }
    @AppStorage(LiquidGlass.key) private var liquidChosen = true
    private var liquid: Bool { liquidChosen && LiquidGlass.supported }

    enum Panel { case toc, notes, search }

    var body: some View {
        HStack(spacing: 0) {
            PdfPages(model: model, accent: tint.accent)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    if let toast = model.toast {
                        UndoToast(toast: toast) { model.undoToast() }
                            .padding(.top, 10)
                            .transition(UndoToast.transition)
                            .id(toast.id)
                    }
                }
                .yyToastMotion(value: model.toast?.id)
                .overlay(alignment: .bottom) {
                    capsule.padding(.bottom, 18)
                }
            if let panel {
                side(panel)
                    .frame(width: 300)
                    .padding(.trailing, 14)
                    .padding(.bottom, 14)
                    .padding(.top, 6)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: panel)
        .background((model.night ? Color(white: 0.13) : PdfDesk.color).ignoresSafeArea())
        .preferredColorScheme(model.night ? .dark : nil)
        .tint(tint.accent)
        .toolbar { toolbar }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // `.v-mac-tb`, as in the reading window.
        .trafficLights(CGPoint(x: 24, y: 29))
        .navigationTitle(model.title)
        .onAppear {
            #if DEBUG
            // `-debugPdfPage 3` · `-debugPdfPanel toc|search` · `-debugPdfQuery 词`.
            let d = UserDefaults.standard
            if d.object(forKey: "debugPdfPage") != nil { model.go(to: d.integer(forKey: "debugPdfPage")) }
            if d.string(forKey: "debugPdfPanel") == "toc" { panel = .toc }
            if let q = d.string(forKey: "debugPdfQuery") { panel = .search; model.query = q; model.search() }
            // `-debugPdfLayout double` · `-debugPdfNight 1` · `-debugPdfShow 1` opens 显示.
            if let l = d.string(forKey: "debugPdfLayout").flatMap(PdfModel.Layout.init) { model.layout = l }
            if d.object(forKey: "debugPdfNight") != nil { model.night = d.bool(forKey: "debugPdfNight") }
            if d.bool(forKey: "debugPdfShow") { showShown = true }
            // `-debugPdfMarks 1` · `-debugPdfNotes 1` opens 笔记.
            if d.bool(forKey: "debugPdfMarks") { model.debugMarks() }
            if d.bool(forKey: "debugPdfNotes") { panel = .notes }
            if d.bool(forKey: "debugPdfVoice") {
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    model.debugVoice()
                }
            }
            if d.bool(forKey: "debugPdfMenu") {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    NotificationCenter.default.post(name: .init("debugPdfMenu"), object: nil)
                }
            }
            #endif
        }
        .sheet(item: $model.writing) { mark in
            ThoughtSheet(mark: mark) { text in
                model.setNote(text, of: mark)
                model.writing = nil
            } cancel: {
                model.writing = nil
            }
        }
        .bookFailure($model.failure, opened: model.opened)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ShelfButtonToolbar(liquid: liquid, ink: YYColor.t1, glass: YYColor.glass, line: YYColor.line) {
            openWindow(id: "library")
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(model.title)
                    .font(.yy(size: 13, weight: .semibold))
                    .foregroundStyle(YYColor.t1)
                Text(subtitle)
                    .font(.yy(size: 10.5))
                    .foregroundStyle(YYColor.t2)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .frame(minWidth: 200, maxWidth: 360)
        }
        .withoutGlass()
        ToolbarItem(placement: .primaryAction) { tools }
            .withoutGlass()
    }

    /// The tool capsule, as in a book's window.
    private var tools: some View {
        HStack(spacing: 2) {
            tool(String(localized: "目录"), "list.bullet", help: String(localized: "目录"), on: panel == .toc) { panel = panel == .toc ? nil : .toc }
            tool(String(localized: "笔记"), "highlighter", help: String(localized: "划线和想法"), on: panel == .notes) { panel = panel == .notes ? nil : .notes }
            tool(String(localized: "书内搜索"), "magnifyingglass", help: String(localized: "书内搜索 ⌘F"), on: panel == .search) {
                if panel == .search {
                    panel = nil
                } else {
                    panel = .search
                    Task { searchFocused = true }
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            tool(String(localized: "显示"), "doc.text.magnifyingglass", help: String(localized: "显示方式"), on: showShown) { showShown.toggle() }
                .popover(isPresented: $showShown, arrowEdge: .bottom) {
                    ShowCard(model: model)
                        .presentationBackground(YYColor.card)
                }
        }
        .padding(.horizontal, 3)
        .frame(height: 32)
        .yyGlass(Capsule(), fill: YYColor.glass, line: YYColor.line, shadow: 0.06, radius: 7, interactive: true)
    }

    private func tool(_ title: String, _ symbol: String, help: String, on: Bool, action: @escaping () -> Void) -> some View {
        GlassTool(title: title, symbol: symbol, help: help, on: on, accent: tint.accent, soft: tint.accentSoft,
                  ink: YYColor.t1, action: action)
    }

    // MARK: The reading capsule

    private var capsule: some View {
        let player = model.player
        let speaking = player?.spot != nil
        return HStack(spacing: 4) {
            Button { listenShown.toggle() } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(capsuleTitle)
                        .font(.yy(size: 12, weight: .semibold))
                        .foregroundStyle(YYColor.t1)
                    Text(speaking ? String(localized: "这一页还剩 \(model.minutesLeftOnPage) 分钟 · \(rateText)×") : String(localized: "点播放从这一页读起"))
                        .font(.yy(size: 10))
                        .foregroundStyle(YYColor.t2)
                }
                .monospacedDigit()
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(listenShown ? YYColor.line.opacity(0.8) : .clear, in: .rect(cornerRadius: 12))
                .contentShape(.rect)
            }
            .help("听：声音、速度、睡眠定时")
            .popover(isPresented: $listenShown, arrowEdge: .top) {
                ListenCard(player: player, rate: $model.rate, minutesLeft: model.minutesLeftOnPage, unit: String(localized: "页"))
                    .presentationBackground(YYColor.card)
            }
            Button { step(forward: false) } label: {
                Image(systemName: "chevron.left").font(.yy(size: 13, weight: .semibold)).frame(width: 30, height: 36)
            }
            .help(speaking ? String(localized: "上一句 ⌘[") : String(localized: "上一页"))
            .accessibilityLabel(speaking ? Text("上一句") : Text("上一页"))
            .keyboardShortcut("[", modifiers: .command)
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.yy(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(tint.accent, in: .circle)
            }
            .help(model.isPlaying ? String(localized: "暂停") : String(localized: "朗读这一页"))
            .accessibilityLabel(model.isPlaying ? Text("暂停") : Text("朗读这一页"))
            .disabled(player == nil)
            Button { step(forward: true) } label: {
                Image(systemName: "chevron.right").font(.yy(size: 13, weight: .semibold)).frame(width: 30, height: 36)
            }
            .help(speaking ? String(localized: "下一句 ⌘]") : String(localized: "下一页"))
            .accessibilityLabel(speaking ? Text("下一句") : Text("下一页"))
            .keyboardShortcut("]", modifiers: .command)
        }
        .buttonStyle(.plain)
        .foregroundStyle(YYColor.t1)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(width: 300)
        .yyGlass(Capsule(), fill: .clear, line: YYColor.line, shadow: model.night ? 0.4 : 0.1)
        .colorScheme(model.night ? .dark : .light)
    }

    private var capsuleTitle: String {
        if let r = model.reading { return String(localized: "第 \(model.label(of: r.page)) 页 · 第 \(r.sentence + 1) / \(r.count) 句") }
        return String(localized: "第 \(model.label(of: model.page)) / \(model.pageCount) 页")
    }

    private var rateText: String {
        model.rate.formatted(.number.precision(.fractionLength(1)))
    }

    private func step(forward: Bool) {
        if let player = model.player, player.spot != nil {
            player.skip(forward: forward)
        } else {
            model.go(to: model.page + (forward ? 1 : -1))
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let author = model.author { parts.append(author) }
        if let chapter = model.chapter, model.chapters.count > 1 { parts.append(chapter.title) }
        if model.pageCount > 0 { parts.append(String(localized: "第 \(model.label(of: model.page)) / \(model.pageCount) 页")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func side(_ which: Panel) -> some View {
        Group {
            switch which {
            case .toc: PdfToc(model: model)
            case .notes: PdfNotes(model: model)
            case .search: PdfSearch(model: model, focused: $searchFocused) { panel = nil }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .yyFloatCard(.rect(cornerRadius: YYRadius.card), shadow: model.night ? YYShadow.floatDark : YYShadow.floatLight)
    }
}

/// 显示: how the pages lie, and 夜间.
private struct ShowCard: View {
    @Bindable var model: PdfModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("显示").font(.yy(size: 13, weight: .bold)).foregroundStyle(YYColor.t1)
            HStack(spacing: 8) {
                ForEach(PdfModel.Layout.allCases, id: \.self) { l in
                    Button { model.layout = l } label: {
                        VStack(spacing: 6) {
                            Image(systemName: l.symbol).font(.yy(size: 17))
                            Text(l.name).font(.yy(size: 11))
                        }
                        .foregroundStyle(model.layout == l ? YYColor.t1 : YYColor.t2)
                        .frame(width: 76, height: 58)
                        .background(model.layout == l ? YYColor.inset : .clear, in: .rect(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(model.layout == l ? YYColor.t1.opacity(0.6) : YYColor.line, lineWidth: model.layout == l ? 1.2 : 0.75))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            SettingsCard {
                SettingsRow(String(localized: "夜间"), detail: String(localized: "白纸变黑，字变浅")) { SettingsSwitch(isOn: $model.night) }
            }
        }
        .padding(16)
        .frame(width: 276)
    }
}

/// 目录: the PDF's own bookmarks; without them, nothing to pretend.
private struct PdfToc: View {
    let model: PdfModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("目录").font(.yy(size: 14, weight: .bold)).foregroundStyle(YYColor.t1)
                Spacer()
                Text("\(model.pageCount) 页").font(.yy(size: 11)).foregroundStyle(YYColor.t3).monospacedDigit()
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            if model.chapters.isEmpty {
                VStack(spacing: 6) {
                    Text("这个 PDF 没有目录").font(.yy(size: 13, weight: .semibold)).foregroundStyle(YYColor.t2)
                    Text("可以用书内搜索找内容").font(.yy(size: 11.5)).foregroundStyle(YYColor.t3)
                }
                .frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.chapters) { c in
                                row(c, current: c.id == model.chapter?.id)
                            }
                        }
                        .padding(.horizontal, 8).padding(.bottom, 10)
                    }
                    .onAppear { if let id = model.chapter?.id { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    private func row(_ c: PdfModel.Chapter, current: Bool) -> some View {
        Button { model.go(to: c.page) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(c.title)
                    .font(.yy(size: c.depth == 0 ? 13 : 12.5, weight: current ? .semibold : (c.depth == 0 ? .medium : .regular)))
                    .foregroundStyle(current ? YYColor.t1 : (c.depth == 0 ? YYColor.t1 : YYColor.t2))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Text(model.label(of: c.page)).font(.yy(size: 11)).foregroundStyle(YYColor.t3).monospacedDigit()
            }
            .padding(.leading, 10 + CGFloat(c.depth) * 14).padding(.trailing, 10).padding(.vertical, 7)
            .background(current ? YYColor.inset : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .id(c.id)
    }
}

/// 笔记: the PDF's highlights and thoughts, page by page.
private struct PdfNotes: View {
    let model: PdfModel
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("笔记").font(.yy(size: 14, weight: .bold)).foregroundStyle(YYColor.t1)
                Spacer()
                if !model.marks.isEmpty {
                    Text("\(model.marks.count) 条划线").font(.yy(size: 11)).foregroundStyle(YYColor.t3).monospacedDigit()
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
            if model.marks.isEmpty {
                VStack(spacing: 6) {
                    Text("还没有划线").font(.yy(size: 13, weight: .semibold)).foregroundStyle(YYColor.t2)
                    Text("选中文字，按 1–4 就划上，右键还能写想法").font(.yy(size: 11.5)).foregroundStyle(YYColor.t3)
                }
                .frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(model.marks.enumerated()), id: \.element.id) { i, mark in
                                if i > 0 { Rectangle().fill(YYColor.line).frame(height: 0.5) }
                                item(mark).id(mark.id)
                            }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 12)
                    }
                    .scrollIndicators(.never)
                    .onAppear {
                        if let here = model.marks.first(where: { Int($0.start.sentence) >= model.page }) { proxy.scrollTo(here.id, anchor: .center) }
                    }
                }
            }
        }
    }

    private func item(_ mark: Mark) -> some View {
        let here = Int(mark.start.sentence) == model.page
        return Button { model.go(to: mark) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(here ? String(localized: "第 \(model.label(of: Int(mark.start.sentence))) 页 · 这一页") : String(localized: "第 \(model.label(of: Int(mark.start.sentence))) 页"))
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
            Button(mark.note == nil ? String(localized: "写想法…") : String(localized: "改想法…")) { model.writing = mark }
            Menu("换个样子") {
                ForEach(MarkStyle.colours + MarkStyle.lines, id: \.self) { style in
                    Button(style.name) { model.setStyle(style, of: mark) }
                }
            }
            Button("从这读") { readFrom(mark) }
            Divider()
            Button("删除划线", role: .destructive) { model.deleteMark(mark) }
        }
    }

    private func readFrom(_ mark: Mark) {
        let p = Int(mark.start.sentence)
        let i = model.sentences(on: p).lastIndex { $0.start <= mark.start.offset } ?? 0
        model.read(from: p, sentence: i)
    }
}

/// 书内搜索: every place the words appear, with a little of what is around them.
private struct PdfSearch: View {
    @Bindable var model: PdfModel
    var focused: FocusState<Bool>.Binding
    let close: () -> Void
    @State private var picked: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.yy(size: 12)).foregroundStyle(YYColor.t3)
                TextField("在这个 PDF 里找", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.yy(size: 13))
                    .focused(focused)
                    .onSubmit { model.search() }
                    .onKeyPress(.escape) { close(); return .handled }
                if !model.query.isEmpty {
                    Button { model.query = ""; model.search() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(YYColor.t3)
                    }
                    .accessibilityLabel(Text("清空"))
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(YYColor.inset, in: .rect(cornerRadius: 9))
            .padding(12)
            .onChange(of: model.query) {
                Task {
                    let q = model.query
                    try? await Task.sleep(for: .milliseconds(300))
                    if q == model.query { model.search() }
                }
            }

            if model.searching {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 30)
            } else if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(model.hits.isEmpty ? String(localized: "没找到") : model.hits.count >= 300 ? String(localized: "300 多处") : String(localized: "\(model.hits.count) 处"))
                    .font(.yy(size: 11)).foregroundStyle(YYColor.t3)
                    .padding(.horizontal, 16).padding(.bottom, 6)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.hits) { hit in
                            Button {
                                picked = hit.id
                                model.go(to: hit.page, range: hit.range)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("第 \(model.label(of: hit.page)) 页").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
                                    (Text(hit.before) + Text(hit.match).foregroundStyle(YYColor.t1).bold() + Text(hit.after))
                                        .font(.yy(size: 12.5)).foregroundStyle(YYColor.t2).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(picked == hit.id ? YYColor.inset : .clear, in: .rect(cornerRadius: 8))
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 10)
                }
            }
        }
    }
}

/// The pages themselves.
private struct PdfPages: NSViewRepresentable {
    let model: PdfModel
    let accent: Color

    final class Coordinator: NSObject {
        let model: PdfModel
        let painter = MarkPainter()
        var placed = false
        var layout: PdfModel.Layout?
        var night: Bool?
        var reading: PdfModel.Reading?
        nonisolated(unsafe) var observer: NSObjectProtocol?

        init(model: PdfModel) { self.model = model }
        deinit { observer.map(NotificationCenter.default.removeObserver) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    private static var nightFilters: [CIFilter] {
        let soften = CIFilter(name: "CIColorMatrix", parameters: [
            // In linear light: paper about #1f1f21, ink about #dcd6cc.
            "inputRVector": CIVector(x: 0.70, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.66, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.58, w: 0),
            "inputBiasVector": CIVector(x: 0.013, y: 0.013, z: 0.015, w: 0),
        ])
        return [CIFilter(name: "CIColorInvert"), CIFilter(name: "CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi]), soften].compactMap { $0 }
    }

    func makeNSView(context: Context) -> MarkingPDFView {
        let view = MarkingPDFView()
        view.model = model
        view.painter = context.coordinator.painter
        view.document = model.document
        view.displayDirection = .vertical
        // The pages draw their own rounded edge; a square shadow behind would show at the corners.
        view.pageShadowsEnabled = false
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        #if DEBUG
        NotificationCenter.default.addObserver(forName: .init("debugPdfMenu"), object: nil, queue: .main) { [weak view] _ in
            MainActor.assumeIsolated { view?.debugMenus() }
        }
        #endif
        let model = model
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { note in
            guard let view = note.object as? PDFView, let page = view.currentPage, let doc = view.document else { return }
            let index = doc.index(for: page)
            MainActor.assumeIsolated { model.shown(index) }
        }
        return view
    }

    func updateNSView(_ view: MarkingPDFView, context: Context) {
        let c = context.coordinator
        c.painter.paint(model.marks, in: model, view: view)
        if c.layout != model.layout {
            c.layout = model.layout
            switch model.layout {
            case .scroll: view.displayMode = .singlePageContinuous
            case .single: view.displayMode = .singlePage
            case .double:
                view.displayMode = .twoUp
                view.displaysAsBook = true
            }
            view.fitted = true
        }
        if c.night != model.night {
            c.night = model.night
            MarkedPage.night = model.night
            c.painter.refresh(view)
            // Turned round, the hues put back so a red stays red, then softened: the paper a deep
            // grey rather than black, the ink a warm light grey rather than white.
            // The filters take in the grey round the pages too: light here comes out dark.
            view.backgroundColor = model.night ? NSColor(white: 0.989, alpha: 1) : NSColor(PdfDesk.color)
            view.contentFilters = model.night ? Self.nightFilters : []
        }
        if !c.placed, let page = model.document?.page(at: model.page) {
            c.placed = true
            DispatchQueue.main.async {
                // The first page from the very top, its margin above it showing, not tucked under the bar.
                // (Only plain NSView calls here: the scroller inside PDFView is its own class.)
                if model.page == 0, let doc = view.documentView {
                    doc.scrollToVisible(NSRect(x: doc.bounds.midX, y: doc.isFlipped ? doc.bounds.minY : doc.bounds.maxY - 1, width: 1, height: 1))
                } else {
                    view.go(to: page)
                }
            }
        }
        if c.reading != model.reading {
            c.reading = model.reading
            // The sentence being read, lit up softly in the accent.
            if let r = model.reading, let page = model.document?.page(at: r.page), let line = page.selection(for: r.range) {
                line.color = NSColor(accent).withAlphaComponent(0.22)
                view.highlightedSelections = [line]
            } else {
                view.highlightedSelections = nil
            }
        }
        if let target = model.target, let page = model.document?.page(at: target.page) {
            let range = target.range
            DispatchQueue.main.async {
                model.target = nil
                if let range, range.length > 0, let selection = page.selection(for: range) {
                    selection.color = .findHighlightColor
                    view.highlightedSelections = [selection]
                    view.go(to: selection)
                } else {
                    if model.reading == nil { view.highlightedSelections = nil }
                    view.go(to: page)
                }
            }
        }
    }
}

/// The pages, with 1–4 to highlight the selection and a right-click menu for marking up.
final class MarkingPDFView: PDFView {
    var model: PdfModel?
    var painter: MarkPainter?

    /// Sized by the window rather than by hand: the pages fill its width; on their own (单页, 双页)
    /// the whole of them shows.
    var fitted = true { didSet { if fitted { fit() } } }

    override func layout() {
        super.layout()
        if fitted { fit() }
    }

    private func fit() {
        guard let page = currentPage ?? document?.page(at: 0) else { return }
        let size = page.bounds(for: displayBox).size
        let turned = page.rotation % 180 != 0
        let w = turned ? size.height : size.width, h = turned ? size.width : size.height
        guard w > 0, h > 0, bounds.width > 0 else { return }
        let m = pageBreakMargins
        let across: CGFloat = displayMode == .twoUp || displayMode == .twoUpContinuous ? 2 : 1
        let room = bounds.width - (m.left + m.right) * across
        var scale = room / (w * across)
        if displayMode == .singlePage || displayMode == .twoUp {
            scale = min(scale, (bounds.height - m.top - m.bottom) / h)
        }
        scale = max(scale, 0.1)
        if autoScales { autoScales = false }
        guard abs(scaleFactor - scale) > 0.001 else { return }
        // Where the reader is stays where it is through the change of size.
        let place = currentDestination
        scaleFactor = scale
        if let place { go(to: place) }
    }

    // Zoomed by hand: the size is the reader's until the layout changes.
    override func magnify(with event: NSEvent) {
        fitted = false
        super.magnify(with: event)
    }

    override func zoomIn(_ sender: Any?) {
        fitted = false
        super.zoomIn(sender)
    }

    override func zoomOut(_ sender: Any?) {
        fitted = false
        super.zoomOut(sender)
    }

    override func keyDown(with event: NSEvent) {
        let keys = event.charactersIgnoringModifiers ?? ""
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           let n = Int(keys), (1...4).contains(n), let selection = chosen, let model {
            model.mark(selection, style: MarkStyle.colours[n - 1])
            clearSelection()
            return
        }
        super.keyDown(with: event)
    }

    /// The selection, when there are words in it.
    private var chosen: PDFSelection? {
        guard let s = currentSelection, let text = s.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let standard = super.menu(for: event)
        guard let model else { return standard }
        let point = convert(event.locationInWindow, from: nil)
        var items: [NSMenuItem] = []
        if let page = page(for: point, nearest: false),
           let id = painter?.mark(at: convert(point, to: page), on: page),
           let mark = model.marks.first(where: { $0.id == id }) {
            items = markItems(mark, model)
        } else if let selection = chosen {
            items = selectionItems(selection, model)
        }
        guard !items.isEmpty else { return standard }
        let menu = NSMenu()
        items.forEach(menu.addItem)
        let rest = standard?.items ?? []
        if !rest.isEmpty {
            menu.addItem(.separator())
            for item in rest {
                standard?.removeItem(item)
                menu.addItem(item)
            }
        }
        return menu
    }

    #if DEBUG
    /// `-debugPdfMenu 1`: the menus a right-click on the first highlight, and on a selection,
    /// would open, written to the log.
    func debugMenus() {
        guard let model, let mark = model.marks.first, let piece = model.selections(of: mark).first?.selectionsByLine().first,
              let page = piece.pages.first, let window else { return }
        let r = piece.bounds(for: page)
        let inView = convert(CGPoint(x: r.midX, y: r.midY), from: page)
        let at = convert(inView, to: nil)
        func dump(_ title: String) {
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: at, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let items = menu(for: event)?.items.map { $0.isSeparatorItem ? "—" : $0.title + ($0.submenu.map { " ▸ " + $0.items.map(\.title).joined(separator: "/") } ?? "") } ?? []
            NSLog("debugPdfMenu %@: %@", title, items.joined(separator: " | "))
        }
        dump("mark")
        if let words = page.selection(for: NSRange(location: 0, length: 4)) { currentSelection = words }
        let saved = painter
        painter = nil
        dump("selection")
        painter = saved
        clearSelection()
    }
    #endif

    private func selectionItems(_ selection: PDFSelection, _ model: PdfModel) -> [NSMenuItem] {
        [
            MenuAction(String(localized: "划线"), symbol: "highlighter") { [weak self] in
                model.mark(selection)
                self?.clearSelection()
            },
            styles(current: nil) { [weak self] style in
                model.mark(selection, style: style)
                self?.clearSelection()
            },
            MenuAction(String(localized: "写想法…"), symbol: "pencil") { [weak self] in
                model.writeNote(on: selection)
                self?.clearSelection()
            },
            MenuAction(String(localized: "从这读"), symbol: "play") { [weak self] in
                if let at = model.sentence(at: selection) { model.read(from: at.page, sentence: at.sentence) }
                self?.clearSelection()
            },
        ]
    }

    private func markItems(_ mark: Mark, _ model: PdfModel) -> [NSMenuItem] {
        let delete = MenuAction(String(localized: "删除划线"), symbol: "trash") { model.deleteMark(mark) }
        delete.attributedTitle = NSAttributedString(string: String(localized: "删除划线"), attributes: [.foregroundColor: NSColor.systemRed])
        return [
            MenuAction(mark.note == nil ? String(localized: "写想法…") : String(localized: "改想法…"), symbol: "pencil") { model.writing = mark },
            styles(current: mark.style) { model.setStyle($0, of: mark) },
            MenuAction(String(localized: "复制"), symbol: "doc.on.doc") { model.copy(mark.text) },
            MenuAction(String(localized: "从这读"), symbol: "play") {
                let p = Int(mark.start.sentence)
                let i = model.sentences(on: p).lastIndex { $0.start <= mark.start.offset } ?? 0
                model.read(from: p, sentence: i)
            },
            .separator(),
            delete,
        ]
    }

    private func styles(current: MarkStyle?, pick: @escaping (MarkStyle) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: current == nil ? String(localized: "划线样式") : String(localized: "换个样子"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        let menu = NSMenu()
        for (i, style) in (MarkStyle.colours + MarkStyle.lines).enumerated() {
            let choice = MenuAction(style.name, symbol: nil) { pick(style) }
            if i < 4, current == nil { choice.keyEquivalent = "\(i + 1)"; choice.keyEquivalentModifierMask = [] }
            choice.state = style == (current ?? model?.lastStyle) ? .on : .off
            menu.addItem(choice)
        }
        item.submenu = menu
        return item
    }
}

/// A menu item that runs a closure.
private func MenuAction(_ title: String, symbol: String?, _ work: @escaping () -> Void) -> NSMenuItem {
    let runner = MenuRunner(work)
    let item = NSMenuItem(title: title, action: #selector(MenuRunner.run), keyEquivalent: "")
    item.target = runner
    // The item keeps its runner alive; a menu's target is held weakly.
    item.representedObject = runner
    if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    return item
}

private final class MenuRunner: NSObject {
    private let work: () -> Void
    init(_ work: @escaping () -> Void) { self.work = work }
    @objc func run() { work() }
}
#endif
