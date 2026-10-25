#if os(iOS)
import SwiftUI
import YuyueCore

/// 漫画 on the phone (prototype C2 单页 · C3 条漫 · C4 阅读设置): only the pictures, on black.
/// A tap in the middle brings the bars — the title and page on top; the page slider, which
/// runs right to left when the comic does, and 目录 / 单页 / 裁白边 / 设置 below — and they go
/// again after a few seconds. The sides turn the page, as 点哪里翻页 says; so does a swipe.
struct PhoneComicView: View {
    @Bindable var model: ComicModel
    @Environment(\.dismiss) private var dismiss
    @State private var chrome = true
    @State private var hiding: Task<Void, Never>?
    @State private var tocShown = false
    @State private var settingsShown = false
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panned: CGSize = .zero
    @State private var sliding: Double?
    @AppStorage("comic.crop") private var crop = true
    @AppStorage("comic.splitSpreads") private var splitSpreads = true
    @AppStorage("comic.tapZones") private var zones = TapZones.sides.rawValue
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if model.layout == .strip {
                    PhoneComicStrip(model: model, tint: tint) { toggleChrome() } contents: { tocShown = true }
                } else {
                    pages(in: geo.size)
                }
            }
            .onAppear { model.splitWide = splitSpreads && geo.size.height > geo.size.width }
            .onChange(of: geo.size) { model.splitWide = splitSpreads && geo.size.height > geo.size.width }
            .onChange(of: splitSpreads) { model.splitWide = splitSpreads && geo.size.height > geo.size.width }
        }
        .ignoresSafeArea()
        .overlay {
            if chrome { bars.transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.2), value: chrome)
        .statusBarHidden(!chrome)
        .persistentSystemOverlays(chrome ? .automatic : .hidden)
        // 漫画一律深底.
        .preferredColorScheme(.dark)
        .onChange(of: model.page) { resetZoom() }
        .onChange(of: model.episode) { resetZoom() }
        .onAppear { hideSoon() }
        .sheet(isPresented: $tocShown) {
            PhoneComicContents(model: model, tint: tint)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $settingsShown) {
            PhoneComicSettings(model: model)
                .presentationDetents([.fraction(0.74), .large])
        }
        .task(id: "\(model.episode)-\(model.page)-\(crop)") {
            // 预加载: the next pages decoded before they are turned to.
            let side = Int(UIScreen.main.bounds.height * UIScreen.main.scale)
            for url in model.upcoming { _ = await ComicImages.shared.image(url, pixels: side, crop: crop) }
        }
        .bookFailure($model.failure, opened: model.current != nil)
    }

    // MARK: The page

    @ViewBuilder private func pages(in size: CGSize) -> some View {
        if let e = model.current {
            let shown = model.shown.filter { e.pages.indices.contains($0) }
            let urls = model.rightToLeft ? shown.reversed().map { e.pages[$0] } : shown.map { e.pages[$0] }
            let split = model.splitting
            let ratios = urls.map { model.aspect($0) / (split ? 2 : 1) }
            let h = min(size.height, size.width / max(0.1, ratios.reduce(0, +)))
            HStack(spacing: 0) {
                ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
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
            .scaleEffect(zoom * pinch)
            .offset(x: panned.width + pan.width, y: panned.height + pan.height)
            .frame(width: size.width, height: size.height)
            .contentShape(.rect)
            .onTapGesture(count: 2) { location in
                withAnimation(.snappy) {
                    if zoom > 1 { resetZoom() } else {
                        zoom = 2
                        panned = CGSize(width: size.width / 2 - location.x, height: size.height / 2 - location.y)
                    }
                }
            }
            .onTapGesture { location in tapped(at: location, in: size) }
            // VoiceOver: where it is, and the taps as actions.
            .accessibilityElement()
            .accessibilityLabel(Text("第 \(model.page + 1) 页"))
            .accessibilityAction(named: Text("下一页")) { model.next() }
            .accessibilityAction(named: Text("上一页")) { model.previous() }
            .gesture(MagnifyGesture()
                .onChanged { pinch = $0.magnification }
                .onEnded { _ in
                    zoom = min(4, max(1, zoom * pinch))
                    pinch = 1
                    if zoom == 1 { withAnimation(.snappy) { panned = .zero } }
                })
            .simultaneousGesture(DragGesture(minimumDistance: 12)
                .onChanged { v in if zoom > 1 { pan = v.translation } }
                .onEnded { v in
                    if zoom > 1 {
                        panned.width += pan.width
                        panned.height += pan.height
                        pan = .zero
                    } else if abs(v.translation.width) > 50, abs(v.translation.width) > abs(v.translation.height) {
                        // A swipe pulls the next page in from the side reading goes towards.
                        turn(left: v.translation.width > 0)
                    }
                })
        }
    }

    private func resetZoom() {
        zoom = 1
        pinch = 1
        pan = .zero
        panned = .zero
    }

    /// A tap on the left or the right side: towards the left is on, in a comic read right to left.
    private func turn(left: Bool) {
        if left == model.rightToLeft { model.next() } else { model.previous() }
    }

    private func tapped(at p: CGPoint, in size: CGSize) {
        if zoom > 1 { toggleChrome(); return }
        let x = p.x / size.width, y = p.y / size.height
        let middle = (1.0 / 3 ... 2.0 / 3).contains(x) && (1.0 / 3 ... 2.0 / 3).contains(y)
        switch TapZones(rawValue: zones) ?? .sides {
        case .sides:
            if x < 1.0 / 3 { turn(left: true) } else if x > 2.0 / 3 { turn(left: false) } else { toggleChrome() }
        case .ell:
            // The left column and the top band go back; the rest goes on (mirrored right to left).
            if middle { toggleChrome(); return }
            let back = model.rightToLeft ? (x > 2.0 / 3 || y < 1.0 / 3) : (x < 1.0 / 3 || y < 1.0 / 3)
            if back { model.previous() } else { model.next() }
        case .topBottom:
            if y < 1.0 / 3 { model.previous() } else if y > 2.0 / 3 { model.next() } else { toggleChrome() }
        case .swipe:
            toggleChrome()
        }
    }

    private func toggleChrome() {
        chrome.toggle()
        if chrome { hideSoon() }
    }

    private func hideSoon() {
        hiding?.cancel()
        hiding = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !tocShown, !settingsShown, sliding == nil else { return }
            chrome = false
        }
    }

    // MARK: The bars

    private var bars: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.yy(size: 15, weight: .semibold)).frame(width: 40, height: 40)
                }
                .accessibilityLabel("关闭")
                Text(model.episodes.count > 1 ? "\(model.title) · \(model.current.map(model.name) ?? "")" : model.title)
                    .font(.yy(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                Text(model.current.map { "\(model.page + 1) / \($0.pages.count)" } ?? "")
                    .font(.yy(size: 12.5)).foregroundStyle(.secondary).monospacedDigit()
                    .frame(minWidth: 40, alignment: .trailing)
                    .padding(.trailing, 8)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .background(.ultraThinMaterial)

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                if model.layout != .strip { slider }
                HStack {
                    tool(String(localized: "目录"), "list.bullet") { tocShown = true }
                    tool(model.layout.name, layoutSymbol) {
                        let all = ComicModel.Layout.allCases
                        model.layout = all[(all.firstIndex(of: model.layout)! + 1) % all.count]
                    }
                    tool(String(localized: "裁白边"), "crop", on: crop) { crop.toggle() }
                    tool(String(localized: "设置"), "slider.horizontal.3") { settingsShown = true }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .background(.ultraThinMaterial)
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { hideSoon() })
    }

    private var layoutSymbol: String {
        switch model.layout {
        case .single: "rectangle.portrait"
        case .double: "book"
        case .strip: "rectangle.split.1x2"
        }
    }

    private func tool(_ title: String, _ symbol: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.yy(size: 17))
                Text(title).font(.yy(size: 10.5))
            }
            .foregroundStyle(on ? tint.accent : .white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.rect)
        }
    }

    /// The page slider: filled from the side reading starts on; the far end goes on to the next
    /// episode, the near end back to the one before.
    private var slider: some View {
        let count = max(1, model.current?.pages.count ?? 1)
        return HStack(spacing: 10) {
            endButton(next: false)
            Slider(value: Binding(get: { sliding ?? Double(model.page) }, set: { sliding = $0 }),
                   in: 0...Double(max(1, count - 1)), step: 1) { editing in
                if !editing, let s = sliding {
                    model.go(episode: model.episode, page: Int(s))
                    sliding = nil
                    hideSoon()
                }
            }
            .tint(tint.accent)
            .accessibilityLabel(Text("翻页"))
            .accessibilityValue(Text("第 \(model.page + 1) 页"))
            .overlay(alignment: .top) {
                if let s = sliding {
                    Text("第 \(Int(s) + 1) 页").font(.yy(size: 12, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: .capsule)
                        .offset(y: -34)
                }
            }
            endButton(next: true)
        }
        .environment(\.layoutDirection, model.rightToLeft ? .rightToLeft : .leftToRight)
    }

    private func endButton(next: Bool) -> some View {
        let can = next ? model.episode + 1 < model.episodes.count : model.episode > 0
        return Button(next ? String(localized: "下一话") : String(localized: "上一话")) {
            model.go(episode: model.episode + (next ? 1 : -1), page: 0)
        }
        .font(.yy(size: 12))
        .foregroundStyle(can ? .white : .white.opacity(0.3))
        .disabled(!can)
    }
}

/// 点哪里翻页: four ways; left and right swap round with the reading direction.
enum TapZones: String, CaseIterable {
    case sides, ell, topBottom, swipe

    var name: String {
        switch self {
        case .sides: String(localized: "左右")
        case .ell: String(localized: "L 形")
        case .topBottom: String(localized: "上下")
        case .swipe: String(localized: "只滑动")
        }
    }
}

// MARK: - 条漫

/// Scrolled down without end: each episode's pictures full width, joined; where one ends, a line
/// on black and 上一话 · 目录 · 下一话 under the thumb, then the next one begins.
private struct PhoneComicStrip: View {
    @Bindable var model: ComicModel
    let tint: YYTint
    let tapped: () -> Void
    let contents: () -> Void
    @State private var top: String?
    @State private var restored = false

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.episodes) { e in
                        if e.id > 0 { header(e) }
                        ForEach(Array(e.pages.enumerated()), id: \.offset) { p, url in
                            ComicPicture(url: url, size: CGSize(width: geo.size.width, height: geo.size.width / model.aspect(url)))
                                .id("\(e.id)-\(p)")
                        }
                        seam(e)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $top, anchor: .top)
            .onTapGesture { tapped() }
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
            .onChange(of: top) {
                guard restored, let top, let dash = top.firstIndex(of: "-"), let e = Int(top[..<dash]), let p = Int(top[top.index(after: dash)...]) else { return }
                model.scrolled(to: e, page: p)
            }
            .onChange(of: "\(model.episode)-\(model.page)") { _, now in
                // A jump from 目录 or the seam.
                if top != now { proxy.scrollTo(now, anchor: .top) }
            }
            .overlay(alignment: .trailing) { progress(height: geo.size.height) }
            }
        }
    }

    /// This episode's progress, a thin line down the right edge.
    private func progress(height: CGFloat) -> some View {
        let count = Double(max(1, model.current?.pages.count ?? 1))
        let f = Double(model.page + 1) / count
        return VStack(spacing: 0) {
            Capsule().fill(Color.white.opacity(0.55)).frame(width: 2.5, height: max(8, (height - 120) * f))
            Spacer(minLength: 0)
        }
        .frame(width: 2.5, height: height - 120)
        .background(Capsule().fill(Color.white.opacity(0.12)))
        .padding(.trailing, 3)
        .allowsHitTesting(false)
    }

    private func header(_ e: ComicModel.Episode) -> some View {
        Text(model.name(of: e))
            .font(.yy(size: 15, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }

    private func seam(_ e: ComicModel.Episode) -> some View {
        VStack(spacing: 18) {
            Text("\(model.name(of: e)) · 完").font(.yy(size: 13)).foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 10) {
                seamButton(String(localized: "上一话"), "chevron.left", enabled: e.id > 0) { model.go(episode: e.id - 1, page: 0) }
                seamButton(String(localized: "目录"), "list.bullet", enabled: true) { contents() }
                seamButton(String(localized: "下一话"), "chevron.right", enabled: e.id + 1 < model.episodes.count, strong: true) { model.go(episode: e.id + 1, page: 0) }
            }
        }
        .padding(.vertical, 44)
        .frame(maxWidth: .infinity)
    }

    private func seamButton(_ title: String, _ symbol: String, enabled: Bool, strong: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.yy(size: 13, weight: .semibold))
                .padding(.horizontal, 16).frame(height: 38)
                .foregroundStyle(strong ? .black : .white)
                .background(strong ? Color.white : Color.white.opacity(0.14), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

// MARK: - 目录

/// 目录 as the grid of episode numbers everyone knows: read ones faded, the one being read filled
/// in; a comic of one episode shows its pages instead.
private struct PhoneComicContents: View {
    @Bindable var model: ComicModel
    let tint: YYTint
    @Environment(\.dismiss) private var dismiss

    private var byPage: Bool { model.episodes.count <= 1 }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(byPage ? String(localized: "读到 \(model.pageLabel)") : String(localized: "读到\(model.current.map(model.name) ?? "") · \(model.pageLabel)"))
                            .font(.yy(size: 13)).foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                            if byPage, let e = model.current {
                                ForEach(e.pages.indices, id: \.self) { p in
                                    cell(p + 1, current: model.shown.contains(p), read: p < model.page) {
                                        model.go(episode: model.episode, page: p)
                                    }
                                    .id(p)
                                }
                            } else {
                                ForEach(model.episodes) { e in
                                    cell(e.id + 1, current: e.id == model.episode, read: e.id < model.episode) {
                                        model.go(episode: e.id, page: e.id == model.episode ? model.page : 0)
                                    }
                                    .id(e.id)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
                .onAppear { proxy.scrollTo(byPage ? model.page : model.episode, anchor: .center) }
            }
            .navigationTitle(byPage ? String(localized: "目录 · 共 \(model.current?.pages.count ?? 0) 页") : String(localized: "目录 · 共 \(model.episodes.count) 话"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private func cell(_ n: Int, current: Bool, read: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            Text("\(n)")
                .font(.yy(size: 15, weight: current ? .bold : .medium)).monospacedDigit()
                .foregroundStyle(current ? .white : (read ? .secondary : .primary))
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(current ? tint.accent : Color.primary.opacity(read ? 0.05 : 0.1), in: .rect(cornerRadius: 10))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 阅读设置

/// `.v-mg-dk`: a dark panel over the page. 阅读方式 and 方向 kept for this comic; 点哪里翻页
/// as four little pages; the rest for every comic.
private struct PhoneComicSettings: View {
    @Bindable var model: ComicModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("comic.crop") private var crop = true
    @AppStorage("comic.splitSpreads") private var splitSpreads = true
    @AppStorage("comic.preload") private var preload = 5
    @AppStorage("comic.tapZones") private var zones = TapZones.sides.rawValue

    /// The panel's own darks, a step lighter than the page behind it.
    static let bg = Color(yy: YYRGBA(26, 26, 29))
    static let card = Color(yy: YYRGBA(36, 36, 40))
    static let inset = Color(yy: YYRGBA(46, 46, 51))
    static let on = Color(yy: YYRGBA(70, 70, 76))

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YYUI.s(10)) {
                HStack {
                    Text("阅读设置").font(YYUI.font(14, .bold))
                    Spacer()
                    Button("完成") { dismiss() }
                        .buttonStyle(.plain)
                        .font(YYUI.font(12, .semibold))
                }
                .foregroundStyle(YYColor.t1)
                .padding(.bottom, YYUI.s(2))
                label(String(localized: "这部漫画 · \(model.title)"), String(localized: "每部漫画分别记住"))
                option(String(localized: "阅读方式")) {
                    segments(ComicModel.Layout.allCases.map { ($0, $0.name, Self.icon($0)) }, $model.layout)
                }
                option(String(localized: "方向")) {
                    segments([(true, String(localized: "从右往左"), nil), (false, String(localized: "从左往右"), nil)], $model.rightToLeft)
                }
                label(String(localized: "点哪里翻页"))
                HStack(alignment: .top, spacing: YYUI.s(8)) {
                    ForEach(TapZones.allCases, id: \.self) { z in zoneTile(z) }
                }
                HStack(spacing: YYUI.s(10)) {
                    key(String(localized: "下一页"), 0.82)
                    key(String(localized: "上一页"), 0.26)
                    Text("中间呼出菜单；左右跟着方向对调")
                }
                .font(YYUI.font(10))
                .foregroundStyle(YYColor.t3)
                .padding(.horizontal, YYUI.s(4))
                .padding(.top, -YYUI.s(2))
                label(String(localized: "所有漫画"))
                VStack(spacing: 0) {
                    row { Text("自动裁白边") } trailing: { YYSwitch(isOn: $crop, label: String(localized: "自动裁白边")) }
                    line
                    row { Text("预加载") } trailing: {
                        Menu {
                            Picker("预加载", selection: $preload) {
                                ForEach([2, 3, 5, 10, 20], id: \.self) { Text("后面 \($0) 页").tag($0) }
                            }
                        } label: {
                            HStack(spacing: YYUI.s(3)) {
                                Text("后面 \(preload) 页").monospacedDigit()
                                Image(systemName: "chevron.right").font(YYUI.font(9, .semibold))
                            }
                            .font(YYUI.font(10.5))
                            .foregroundStyle(YYColor.t3)
                        }
                    }
                    line
                    HStack(spacing: YYUI.s(10)) {
                        VStack(alignment: .leading, spacing: YYUI.s(1)) {
                            Text("竖屏时拆开跨页").font(YYUI.font(11.5))
                            Text("扫描版的双页图，竖着看时拆成两页").font(YYUI.font(10)).foregroundStyle(YYColor.t3)
                        }
                        Spacer(minLength: 0)
                        YYSwitch(isOn: $splitSpreads, label: String(localized: "竖屏时拆开跨页"))
                    }
                    .padding(.vertical, YYUI.s(8))
                }
                .padding(.horizontal, YYUI.s(12))
                .background(Self.card, in: .rect(cornerRadius: YYUI.s(14)))
                .overlay(RoundedRectangle(cornerRadius: YYUI.s(14)).strokeBorder(.white.opacity(0.07), lineWidth: 0.5))
            }
            .foregroundStyle(YYColor.t1)
            .padding(.top, YYUI.s(18))
            .padding(.horizontal, YYUI.s(14))
            .padding(.bottom, YYUI.s(22))
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Self.bg)
        .environment(\.colorScheme, .dark)
        .presentationBackground(Self.bg)
        .presentationDragIndicator(.visible)
    }

    static func icon(_ layout: ComicModel.Layout) -> String {
        switch layout {
        case .single: "rectangle.portrait"
        case .double: "rectangle.split.2x1"
        case .strip: "rectangle.split.1x2"
        }
    }

    /// `.v-mg-gl`: grey words over a part, maybe a note at the right.
    private func label(_ text: String, _ note: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
            Spacer()
            if let note { Text(note) }
        }
        .font(YYUI.font(10))
        .foregroundStyle(YYColor.t3)
        .padding(.horizontal, YYUI.s(4))
        .padding(.top, YYUI.s(4))
        .padding(.bottom, -YYUI.s(4))
    }

    private func option(_ title: String, @ViewBuilder _ control: () -> some View) -> some View {
        HStack(spacing: YYUI.s(10)) {
            Text(title).font(YYUI.font(11)).foregroundStyle(YYColor.t2).frame(width: YYUI.s(52), alignment: .leading)
            control()
        }
    }

    /// `.v-seg.sm` in the panel's darks.
    private func segments<T: Hashable>(_ items: [(T, String, String?)], _ selection: Binding<T>) -> some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { value, title, icon in
                let on = selection.wrappedValue == value
                Button { selection.wrappedValue = value } label: {
                    HStack(spacing: YYUI.s(4)) {
                        if let icon { Image(systemName: icon).font(YYUI.font(10)) }
                        Text(title)
                    }
                    .font(YYUI.font(10, on ? .semibold : .regular))
                    .foregroundStyle(on ? Color.white : YYColor.t2)
                    .frame(maxWidth: .infinity)
                    .frame(height: YYUI.s(22))
                    .background(on ? Self.on : .clear, in: .rect(cornerRadius: YYUI.s(7)))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(YYUI.s(3))
        .background(Self.inset, in: .rect(cornerRadius: YYUI.s(10)))
    }

    private func zoneTile(_ z: TapZones) -> some View {
        let on = zones == z.rawValue
        return Button { zones = z.rawValue } label: {
            VStack(spacing: YYUI.s(5)) {
                ZoneIcon(zones: z, rightToLeft: model.rightToLeft)
                    .frame(width: YYUI.s(28), height: YYUI.s(46))
                    .frame(maxWidth: .infinity)
                    .frame(height: YYUI.s(62))
                    .background(Self.card, in: .rect(cornerRadius: YYUI.s(12)))
                    .overlay(RoundedRectangle(cornerRadius: YYUI.s(12))
                        .strokeBorder(on ? YYColor.t1 : .white.opacity(0.07), lineWidth: on ? 1.5 : 0.5))
                Text(z.name)
                    .font(YYUI.font(10, on ? .semibold : .regular))
                    .foregroundStyle(on ? YYColor.t1 : YYColor.t2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func key(_ text: String, _ opacity: Double) -> some View {
        HStack(spacing: YYUI.s(4)) {
            RoundedRectangle(cornerRadius: 2).fill(YYColor.t1.opacity(opacity)).frame(width: YYUI.s(9), height: YYUI.s(9))
            Text(text)
        }
    }

    private func row(@ViewBuilder _ title: () -> some View, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: YYUI.s(10)) {
            title().font(YYUI.font(11.5))
            Spacer(minLength: 0)
            trailing()
        }
        .frame(height: YYUI.s(36))
    }

    private var line: some View { Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5) }
}

/// One of 点哪里翻页's little pages: 下一页 bright, 上一页 faint, a dot for the menu. Turned
/// round for comics read left to right.
private struct ZoneIcon: View {
    let zones: TapZones
    let rightToLeft: Bool

    var body: some View {
        Canvas { ctx, size in
            let k = size.width / 28
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: x * k, y: y * k, width: w * k, height: h * k), cornerRadius: 2.5 * k)
            }
            let ink = Color(yy: YYRGBA(237, 237, 238))
            ctx.stroke(Path(roundedRect: CGRect(x: 0.75 * k, y: 0.75 * k, width: 26.5 * k, height: 44.5 * k), cornerRadius: 4 * k),
                       with: .color(ink.opacity(0.35)), lineWidth: 1.5 * k)
            var next = Path(), prev = Path()
            var dot = CGPoint(x: 14, y: 23)
            switch zones {
            case .sides:
                next.addPath(r(2.5, 2.5, 7.5, 41))
                prev.addPath(r(18, 2.5, 7.5, 41))
            case .ell:
                next.addPath(r(2.5, 2.5, 7.5, 41)); next.addPath(r(2.5, 32, 23, 11.5))
                prev.addPath(r(12, 2.5, 13.5, 10)); prev.addPath(r(18, 2.5, 7.5, 27.5))
                dot.y = 21
            case .topBottom:
                prev.addPath(r(2.5, 2.5, 23, 13))
                next.addPath(r(2.5, 30.5, 23, 13))
            case .swipe:
                var arrow = Path()
                arrow.move(to: CGPoint(x: 8 * k, y: 23 * k)); arrow.addLine(to: CGPoint(x: 20 * k, y: 23 * k))
                arrow.move(to: CGPoint(x: 10.5 * k, y: 20.5 * k)); arrow.addLine(to: CGPoint(x: 8 * k, y: 23 * k)); arrow.addLine(to: CGPoint(x: 10.5 * k, y: 25.5 * k))
                arrow.move(to: CGPoint(x: 17.5 * k, y: 20.5 * k)); arrow.addLine(to: CGPoint(x: 20 * k, y: 23 * k)); arrow.addLine(to: CGPoint(x: 17.5 * k, y: 25.5 * k))
                ctx.stroke(arrow, with: .color(ink.opacity(0.7)), style: StrokeStyle(lineWidth: 1.2 * k, lineCap: .round, lineJoin: .round))
                return
            }
            ctx.fill(next, with: .color(ink.opacity(0.82)))
            ctx.fill(prev, with: .color(ink.opacity(0.26)))
            ctx.fill(Path(ellipseIn: CGRect(x: (dot.x - 1.6) * k, y: (dot.y - 1.6) * k, width: 3.2 * k, height: 3.2 * k)), with: .color(ink.opacity(0.6)))
        }
        .scaleEffect(x: rightToLeft || zones == .topBottom ? 1 : -1)
    }
}
#endif
