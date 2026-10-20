#if os(macOS)
import SwiftUI
import YuyueCore

/// 漫画窗口 (prototype 漫画窗口 · 双页 / 条漫): always dark, whatever the rest of the app. Only
/// the pictures until the mouse moves; then dark glass along the top (书架, 目录, 单页 / 双页 /
/// 条漫, 从右往左) and a page slider along the bottom, which runs right to left too when the
/// comic does, 下一话 at its far end.
struct MacComicView: View {
    @Bindable var model: ComicModel
    @Environment(\.openWindow) private var openWindow
    @State private var chrome = true
    @State private var hiding: Task<Void, Never>?
    @State private var tocShown = false
    /// 自动裁白边, for every comic; the strip keeps its pictures whole so they join up.
    @AppStorage("comic.crop") private var crop = true
    @State private var settingsShown = false
    @AppStorage("comic.splitSpreads") private var splitSpreads = true
    /// A narrow window: the tools show only their icons, so the title fits between.
    @State private var narrow = false
    @FocusState private var focused: Bool

    static let ink = Color(red: 11 / 255, green: 11 / 255, blue: 12 / 255)

    var body: some View {
        ZStack {
            Self.ink.ignoresSafeArea()
            Group {
                if model.layout == .strip {
                    ComicStrip(model: model, toc: { tocShown = true })
                } else {
                    paged
                }
            }
            .ignoresSafeArea()
            if chrome || tocShown {
                controls.transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: chrome)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle(model.title)
        .onContinuousHover { phase in
            if case .active = phase { wake() }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            wake()
            #if DEBUG
            // `-debugComicLayout strip` · `-debugComicPage 0-3` (episode-page) · `-debugChrome 1` · `-debugComicSettings 1`.
            let d = UserDefaults.standard
            if let l = d.string(forKey: "debugComicLayout").flatMap(ComicModel.Layout.init) { model.layout = l }
            if let p = d.string(forKey: "debugComicPage")?.split(separator: "-").compactMap({ Int($0) }), p.count == 2 {
                model.go(episode: p[0], page: p[1])
            }
            if d.bool(forKey: "debugComicToc") { tocShown = true }
            if d.bool(forKey: "debugComicSettings") { settingsShown = true }
            #endif
        }
        .onKeyPress(.leftArrow) { turn(left: true) }
        .onKeyPress(.rightArrow) { turn(left: false) }
        .onKeyPress(.space) {
            guard model.layout != .strip else { return .ignored }
            model.next()
            return .handled
        }
        .alert("出错了", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("好") {}
        } message: {
            Text(model.failure ?? "")
        }
    }

    /// ← is the next page when the comic reads right to left.
    private func turn(left: Bool) -> KeyPress.Result {
        guard model.layout != .strip else { return .ignored }
        if left == model.rightToLeft { model.next() } else { model.previous() }
        return .handled
    }

    /// Shows the controls for a while.
    private func wake() {
        chrome = true
        hiding?.cancel()
        hiding = Task {
            try? await Task.sleep(for: .seconds(2.5))
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "debugChrome") { return }
            #endif
            if !Task.isCancelled { chrome = false }
        }
    }

    // MARK: 单页 · 双页

    private var paged: some View {
        GeometryReader { geo in
            let pages = model.shown
            let urls = pages.compactMap { model.current?.pages[$0] }
            let shown = model.rightToLeft ? Array(urls.reversed()) : urls
            let split = model.splitting
            let ratios = shown.map { model.aspect($0) / (split ? 2 : 1) }
            let room = CGSize(width: geo.size.width - 48, height: geo.size.height - 116)
            let h = max(1, min(room.height, room.width / max(0.1, ratios.reduce(0, +))))
            ZStack {
                HStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element) { i, url in
                        if split {
                            // Half of the spread: the right half first when read right to left.
                            ComicPicture(url: url, size: CGSize(width: h * ratios[i] * 2, height: h), crop: crop)
                                .frame(width: h * ratios[i], alignment: (model.half == 0) == model.rightToLeft ? .trailing : .leading)
                                .clipped()
                        } else {
                            ComicPicture(url: url, size: CGSize(width: h * ratios[i], height: h), crop: crop)
                        }
                    }
                }
                .overlay {
                    // The fold between two pages.
                    if shown.count == 2 {
                        LinearGradient(colors: [.clear, .black.opacity(0.09), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 28)
                            .allowsHitTesting(false)
                    }
                }
                .shadow(color: .black.opacity(0.6), radius: 30, y: 24)
                .overlay(alignment: .bottom) {
                    HStack {
                        ForEach(Array(pageNumbers(pages).enumerated()), id: \.offset) { i, n in
                            if i > 0 { Spacer() }
                            Text("\(n)").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .padding(.horizontal, 6)
                    .offset(y: 22)
                }
            }
            .position(x: geo.size.width / 2, y: 48 + room.height / 2)
            .onChange(of: splitSpreads && geo.size.height > geo.size.width, initial: true) { model.splitWide = $1 }
            .contentShape(.rect)
            .gesture(SpatialTapGesture().onEnded { tap in click(at: tap.location.x, width: geo.size.width) })
            .task(id: model.shown) {
                for url in model.upcoming { _ = await ComicImages.shared.image(url, pixels: Int(h * 2 * max(1, model.aspect(url))), crop: crop) }
            }
        }
    }

    private func pageNumbers(_ pages: [Int]) -> [Int] {
        let n = pages.map { $0 + 1 }
        return model.rightToLeft ? n.reversed() : n
    }

    /// A click on the outer thirds turns; in the middle it shows or hides the controls.
    private func click(at x: Double, width: Double) {
        if x < width / 3 {
            if model.rightToLeft { model.next() } else { model.previous() }
        } else if x > width * 2 / 3 {
            if model.rightToLeft { model.previous() } else { model.next() }
        } else {
            if chrome { hiding?.cancel(); chrome = false } else { wake() }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { openWindow(id: "library") } label: {
                    Label("书架", systemImage: "chevron.left").labelStyle(.titleAndIcon)
                        .font(.system(size: 12))
                        .padding(.leading, 7).padding(.trailing, 12).frame(height: 30)
                        .comicGlass(in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.leading, 78)
                .help("回到书架")
                Spacer()
                tools
            }
            .padding(.trailing, 14)
            .frame(height: 44)
            .overlay {
                if model.layout != .strip { titleBlock }
            }
            Spacer()
            if model.layout != .strip, let e = model.current, !e.pages.isEmpty {
                ComicSlider(model: model)
                    .padding(.bottom, 16)
            }
        }
        .foregroundStyle(Color(white: 0.93))
        .ignoresSafeArea()
        .onGeometryChange(for: Bool.self) { $0.size.width < 900 } action: { narrow = $0 }
        .onHover { if $0 { hiding?.cancel(); chrome = true } }
    }

    private var titleBlock: some View {
        VStack(spacing: 1) {
            Text(model.current.map { "\(model.title) · \(model.name(of: $0))" } ?? model.title)
                .font(.system(size: 12.5, weight: .semibold))
            Text(model.pageLabel).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Color(white: 0.6))
        }
        .lineLimit(1)
        .frame(maxWidth: narrow ? 170 : 340)
        .allowsHitTesting(false)
    }

    private var tools: some View {
        HStack(spacing: 2) {
            Button { tocShown.toggle() } label: {
                Image(systemName: "list.bullet").font(.system(size: 13, weight: .medium))
                    .frame(width: 34, height: 28).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("目录")
            .popover(isPresented: $tocShown, arrowEdge: .bottom) {
                ComicContents(model: model) { tocShown = false }
                    .environment(\.colorScheme, .dark)
                    .presentationBackground(Color(white: 0.12))
            }
            HStack(spacing: 2) {
                ForEach(ComicModel.Layout.allCases, id: \.self) { l in
                    let on = model.layout == l
                    Button { model.layout = l } label: {
                        tag(l.name, l.symbol)
                            .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? .white : Color(white: 0.66))
                            .padding(.leading, 7).padding(.trailing, narrow ? 7 : 9).frame(height: 24)
                            .background(on ? Color.white.opacity(0.2) : .clear, in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .help(l.name)
                }
            }
            .padding(2)
            .background(Color.white.opacity(0.07), in: .capsule)
            .padding(.horizontal, 4)
            if model.layout != .strip {
                Button { model.rightToLeft.toggle() } label: {
                    tag(String(localized: "从右往左"), "arrow.left")
                        .font(.system(size: 11.5, weight: model.rightToLeft ? .semibold : .regular))
                        .foregroundStyle(model.rightToLeft ? .white : Color(white: 0.85))
                        .padding(.leading, 8).padding(.trailing, narrow ? 8 : 10).frame(height: 28)
                        .background(model.rightToLeft ? Color.white.opacity(0.16) : .clear, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help(model.rightToLeft ? String(localized: "现在从右往左翻，点一下改成从左往右") : String(localized: "现在从左往右翻，点一下改成从右往左"))
            }
            // `i-sliders`: what holds for every comic, the same switches as 设置 · 漫画.
            Button { settingsShown.toggle() } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(settingsShown ? .white : Color(white: 0.85))
                    .frame(width: 32, height: 28)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help("漫画阅读设置")
            .popover(isPresented: $settingsShown, arrowEdge: .bottom) {
                ComicQuickSettings()
                    .environment(\.colorScheme, .dark)
                    .presentationBackground(Color(white: 0.12))
            }
        }
        .padding(.horizontal, 3)
        .frame(height: 34)
        .comicGlass(in: Capsule())
    }

    @ViewBuilder private func tag(_ title: String, _ symbol: String) -> some View {
        if narrow {
            Image(systemName: symbol)
        } else {
            Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
        }
    }
}

extension ComicModel.Layout {
    var symbol: String {
        switch self {
        case .single: "rectangle.portrait"
        case .double: "book.pages"
        case .strip: "arrow.down.to.line.compact"
        }
    }
}

extension View {
    /// The comic window's dark glass.
    func comicGlass(in shape: some Shape) -> some View {
        let dark = Color(red: 40 / 255, green: 40 / 255, blue: 44 / 255)
        return yyGlass(shape, fill: dark.opacity(0.78), line: .white.opacity(0.12), material: .ultraThinMaterial,
                       shadow: 0.4, radius: 11, y: 8, tint: dark.opacity(0.6))
    }
}

/// The page slider: filled from the side reading starts on; the far end goes on to the next
/// episode.
private struct ComicSlider: View {
    @Bindable var model: ComicModel
    @State private var dragging: Double?

    var body: some View {
        let e = model.current!
        let count = max(1, e.pages.count)
        let fraction = Double((model.shown.last ?? 0) + 1) / Double(count)
        HStack(spacing: 16) {
            end(first: true)
            GeometryReader { geo in
                let shown = dragging ?? fraction
                let x = model.rightToLeft ? geo.size.width * (1 - shown) : geo.size.width * shown
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2)).frame(height: 4)
                    Capsule().fill(Color(white: 0.93))
                        .frame(width: geo.size.width * shown, height: 4)
                        .frame(maxWidth: .infinity, alignment: model.rightToLeft ? .trailing : .leading)
                    Circle().fill(.white).frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                        .position(x: x, y: geo.size.height / 2)
                    Text(label(for: shown, count: count))
                        .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Color(white: 0.07))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.white, in: .rect(cornerRadius: 7))
                        .fixedSize()
                        .position(x: x, y: geo.size.height / 2 - 20)
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let f = min(max(v.location.x / max(1, geo.size.width), 0), 1)
                        dragging = model.rightToLeft ? 1 - f : f
                    }
                    .onEnded { _ in
                        if let d = dragging { model.go(episode: model.episode, page: max(0, Int((d * Double(count)).rounded(.up)) - 1)) }
                        dragging = nil
                    })
            }
            end(first: false)
        }
        .padding(.horizontal, 18)
        .frame(width: 540, height: 42)
        .comicGlass(in: Capsule())
    }

    private func label(for f: Double, count: Int) -> String {
        guard dragging != nil else { return model.shown.map { "\($0 + 1)" }.joined(separator: "–") }
        return "\(max(1, Int((f * Double(count)).rounded(.up))))"
    }

    /// The left end is 下一话 when reading right to left.
    @ViewBuilder private func end(first: Bool) -> some View {
        let forward = first == model.rightToLeft
        let target = model.episode + (forward ? 1 : -1)
        Button { model.go(episode: target, page: 0) } label: {
            HStack(spacing: 2) {
                if first { Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold)) }
                Text(forward ? String(localized: "下一话") : String(localized: "上一话"))
                if !first { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Color(white: 0.79))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!model.episodes.indices.contains(target))
        .opacity(model.episodes.indices.contains(target) ? 1 : 0.35)
    }
}

/// 目录: the episodes, 读到这里 on the one being read.
private struct ComicContents: View {
    let model: ComicModel
    let done: () -> Void
    /// 格子 by default, like other comic apps: one 话号 a cell, easy to find among many. The list
    /// has the titles and page counts.
    @AppStorage("comic.tocList") private var list = false
    @State private var newestFirst = false
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var accent: Color { (YYTint.all.first { $0.id == tintID } ?? .blue).accent }

    private var episodes: [ComicModel.Episode] { newestFirst ? model.episodes.reversed() : model.episodes }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    (Text("目录").font(.system(size: 13, weight: .bold))
                        + Text(" · 共 \(model.episodes.count) 话").font(.system(size: 10.5)).foregroundStyle(.secondary))
                    if let e = model.current {
                        Text("读到\(model.name(of: e)) · \(model.pageLabel)")
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(accent)
                    }
                }
                Spacer()
                Button { newestFirst.toggle() } label: {
                    Label(newestFirst ? String(localized: "倒序") : String(localized: "正序"), systemImage: "arrow.up.arrow.down").labelStyle(.titleAndIcon)
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Picker("", selection: $list) {
                    Image(systemName: "square.grid.3x3").tag(false).help("格子")
                    Image(systemName: "list.bullet").tag(true).help("列表")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 70)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    if list { rows } else { grid }
                }
                .scrollIndicators(.never)
                .onAppear { proxy.scrollTo(model.episode, anchor: .center) }
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300)
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
            ForEach(episodes) { e in
                let here = e.id == model.episode, read = e.id < model.episode
                Button { go(e) } label: {
                    Text("\(e.id + 1)")
                        .font(.system(size: 12, weight: read ? .medium : .semibold)).monospacedDigit()
                        .foregroundStyle(here ? .white : read ? Color(white: 0.45) : Color(white: 0.92))
                        .frame(maxWidth: .infinity).frame(height: 38)
                        .background(here ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(read ? 0.035 : 0.09)),
                                    in: .rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(read ? 0.08 : 0)))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(model.name(of: e))
                .id(e.id)
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(episodes) { e in
                let here = e.id == model.episode
                Button { go(e) } label: {
                    HStack {
                        Text(model.name(of: e)).font(.system(size: 13, weight: here ? .semibold : .regular))
                            .foregroundStyle(e.id < model.episode ? .secondary : .primary)
                        Spacer()
                        Text(here ? String(localized: "读到这里") : String(localized: "\(e.pages.count) 页"))
                            .font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(here ? accent : .secondary)
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(here ? Color.white.opacity(0.08) : .clear, in: .rect(cornerRadius: 7))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .id(e.id)
            }
        }
    }

    private func go(_ e: ComicModel.Episode) {
        // The one being read opens where it was left.
        if e.id != model.episode { model.go(episode: e.id, page: 0) }
        done()
    }
}

/// 条漫: the pictures one under another in a column down the middle, the next episode straight
/// after this one's 完, and a thin line on the right for how far through this episode.
private struct ComicStrip: View {
    @Bindable var model: ComicModel
    let toc: () -> Void
    @State private var top: String?
    @State private var restored = false

    var body: some View {
        GeometryReader { geo in
            let width = min(720, max(320, geo.size.width - 200))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.episodes) { e in
                            if e.id > 0 { header(e) }
                            ForEach(Array(e.pages.enumerated()), id: \.offset) { i, url in
                                ComicPicture(url: url, size: CGSize(width: width, height: width / model.aspect(url)))
                                    .id("\(e.id)-\(i)")
                            }
                            seam(e)
                        }
                    }
                    .frame(width: width)
                    .background(Color(red: 20 / 255, green: 20 / 255, blue: 22 / 255))
                    .frame(maxWidth: .infinity)
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $top, anchor: .top)
                .scrollIndicators(.never)
                .task {
                    // The pictures above aren't measured yet, so the first jump lands by guess;
                    // once they are laid out, again.
                    let here = "\(model.episode)-\(model.page)"
                    for _ in 0..<3 {
                        proxy.scrollTo(here, anchor: .top)
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                    restored = true
                }
                .onChange(of: "\(model.episode)-\(model.page)") { _, here in
                    // 目录 or the buttons at an episode's end; scrolling itself already put it there.
                    if top != here { proxy.scrollTo(here, anchor: .top) }
                }
            }
            .onChange(of: top) {
                guard restored, let top else { return }
                let parts = top.split(separator: "-").compactMap { Int($0) }
                if parts.count == 2 { model.scrolled(to: parts[0], page: parts[1]) }
            }
            .overlay(alignment: .topLeading) {
                // How far through this episode.
                let count = max(1, model.current?.pages.count ?? 1)
                Capsule().fill(Color.white.opacity(0.12)).frame(width: 3)
                    .overlay(alignment: .top) {
                        GeometryReader { bar in
                            Capsule().fill(Color.white.opacity(0.6))
                                .frame(height: bar.size.height * Double(model.page + 1) / Double(count))
                        }
                    }
                    .padding(.vertical, 76)
                    .offset(x: geo.size.width / 2 + width / 2 + 22)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                VStack(spacing: 1) {
                    Text(model.current.map { "\(model.title) · \(model.name(of: $0))" } ?? model.title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("条漫 · " + (model.page + 1 >= (model.current?.pages.count ?? 0) ? String(localized: "这一话看完了") : String(localized: "第 \(model.page + 1) / \(model.current?.pages.count ?? 0) 张")))
                        .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Color(white: 0.6))
                }
                .lineLimit(1)
                .padding(.horizontal, 18).frame(height: 36)
                .comicGlass(in: Capsule())
                .padding(.top, 11)
                .allowsHitTesting(false)
            }
        }
    }

    /// 第 12 话 · 完, then 上一话 · 目录 · 下一话.
    private func seam(_ e: ComicModel.Episode) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Rectangle().fill(Color.white.opacity(0.22)).frame(width: 40, height: 0.5)
                Text(e.id == model.episodes.count - 1 ? String(localized: "\(model.name(of: e)) · 完 · 已经是最后一话") : String(localized: "\(model.name(of: e)) · 完"))
                    .font(.system(size: 11)).tracking(0.9).foregroundStyle(.white.opacity(0.5))
                Rectangle().fill(Color.white.opacity(0.22)).frame(width: 40, height: 0.5)
            }
            HStack(spacing: 6) {
                if e.id > 0 {
                    seamButton(String(localized: "上一话"), icon: "chevron.left", leading: true) { model.go(episode: e.id - 1, page: 0) }
                }
                seamButton(String(localized: "目录"), icon: "list.bullet", leading: true) { toc() }
                if e.id + 1 < model.episodes.count {
                    seamButton(String(localized: "下一话 · \(model.name(of: model.episodes[e.id + 1]))"), icon: "chevron.right", leading: false, strong: true) {
                        model.go(episode: e.id + 1, page: 0)
                    }
                }
            }
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .background(MacComicView.ink)
    }

    private func header(_ e: ComicModel.Episode) -> some View {
        VStack(spacing: 3) {
            Text("第 \(e.id + 1) 话").font(.system(size: 10)).tracking(1.4).foregroundStyle(.white.opacity(0.5))
            if !e.title.isEmpty, e.title != String(localized: "第\(e.id + 1)话") {
                Text(e.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.88))
            }
        }
        .padding(.top, 8).padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(MacComicView.ink)
    }

    private func seamButton(_ title: String, icon: String, leading: Bool, strong: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if leading { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
                Text(title)
                if !leading { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
            }
            .font(.system(size: 11.5, weight: strong ? .semibold : .regular))
            .foregroundStyle(.white.opacity(strong ? 1 : 0.88))
            .padding(.horizontal, 13).frame(height: 32)
            .comicGlass(in: Capsule())
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

/// The comic window's 阅读设置 (prototype C4, `.v-mg-dk`): what holds for every comic. 单页、
/// 双页、条漫 and the direction each comic keeps for itself, in the toolbar beside it.
private struct ComicQuickSettings: View {
    @AppStorage("comic.crop") private var crop = true
    @AppStorage("comic.preload") private var preload = 5
    @AppStorage("comic.splitSpreads") private var split = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("所有漫画")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(white: 0.6))
                .padding(.bottom, 8)
            row(String(localized: "自动裁白边"), String(localized: "扫描版四周的白边裁掉，画大一些")) {
                Toggle("", isOn: $crop).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(YYTint.standard.fill)
            }
            Divider().overlay(Color.white.opacity(0.08))
            row(String(localized: "预加载"), nil) {
                Picker("", selection: $preload) {
                    ForEach([3, 5, 8], id: \.self) { Text("后面 \($0) 页").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Divider().overlay(Color.white.opacity(0.08))
            row(String(localized: "窗口竖着时拆开跨页"), String(localized: "扫描版的双页图，单页看时拆成两半")) {
                Toggle("", isOn: $split).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(YYTint.standard.fill)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func row(_ title: String, _ detail: String?, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5)).foregroundStyle(Color(white: 0.93))
                if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(Color(white: 0.55)) }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 9)
    }
}
#endif
