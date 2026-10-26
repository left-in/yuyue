import SwiftUI
import YuyueCore

#if os(macOS)

/// 设置 (⌘,): pages with icons along the top, each a grouped form. Changes take at once; there is
/// no 应用 button (prototype 设置 · 外观).
struct MacSettings: View {
    let library: Library
    @AppStorage("settings.page") private var page = SettingsPage.general
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id

    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }
    @State private var pageHeight: CGFloat = 300

    /// Below the tabs: at most 560, less on a small screen.
    private var maxPageHeight: CGFloat {
        min(560, (NSScreen.main?.visibleFrame.height ?? 800) - 200)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabs(page: $page, tint: tint)
            // The window fits a short page whole; a long one stops at a height that fits the
            // screen and scrolls, as 系统设置 does.
            ScrollView {
                content(page)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { pageHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(pageHeight, maxPageHeight))
            .background(YYColor.bg)
        }
        // `.v-ms-stb`: the title bar and the tabs are one header, one colour, no line between.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // The page's name sits in the middle (`SettingsTitlebar`), not on the left.
        .toolbar(removing: .title)
        .frame(width: 780)
        .tint(tint.accent)
        .navigationTitle(page.title)
        .background(SettingsTitlebar(title: page.title))
        // `.v-ms-stb .v-lights`: 16 in, 14 down.
        .trafficLights(CGPoint(x: 22, y: 20))
    }

    @ViewBuilder private func content(_ p: SettingsPage) -> some View {
        Group {
            switch p {
            case .general: GeneralSettings()
            case .appearance: AppearanceSettings()
            case .reading: ReadingSettings(library: library)
            case .comics: ComicSettings()
            case .listening: ListeningSettings()
            case .foreign: ForeignSettings(library: library)
            case .companion: CompanionSettings(library: library)
            case .sync: SyncSettings(library: library)
            case .storage: StorageSettings(library: library)
            case .data: DataSettings(library: library)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(YYColor.bg)
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, reading, comics, listening, foreign, companion, sync, storage, data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "通用")
        case .appearance: String(localized: "外观")
        case .reading: String(localized: "阅读")
        case .comics: String(localized: "漫画")
        case .listening: String(localized: "朗读")
        case .foreign: String(localized: "外文")
        case .companion: String(localized: "书伴")
        case .sync: String(localized: "同步")
        case .storage: String(localized: "存储")
        case .data: String(localized: "数据")
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .appearance: "sun.max"
        // 阅读 and 漫画 as in the shelf's sidebar.
        case .reading: ProtoIcon.book.rawValue
        case .comics: "asset." + PhoneTabIcon.comic
        case .listening: "headphones"
        case .foreign: "character.book.closed"
        case .companion: "sparkle"
        case .sync: "arrow.triangle.2.circlepath"
        case .storage: "cylinder.split.1x2"
        case .data: "shippingbox"
        }
    }
}

/// `.v-ms-tabs`: the pages along the top. The chosen one on a grey pad, its icon in the theme
/// colour, as the prototype draws it.
struct SettingsTabs: View {
    @Binding var page: SettingsPage
    let tint: YYTint
    /// The title bar's height (32 from macOS 26, 28 before): the tabs start 33 below the window's
    /// top edge. Read from the layout it went round and round, the tabs moving the bar.
    private var titlebar: CGFloat {
        if #available(macOS 26, *) { 32 } else { 28 }
    }

    /// `.v-ms-stb`: card 55% over the page, a little lighter than it; the title bar is this too.
    static let header = NSColor(name: nil) { look in
        look.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 22 / 255, green: 23 / 255, blue: 24.6 / 255, alpha: 1)
            : NSColor(srgbRed: 251 / 255, green: 250.5 / 255, blue: 249.6 / 255, alpha: 1)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsPage.allCases) { tab($0) }
        }
        // `.v-ms-tabs` start 33 down; the bar is 88 in all.
        .padding(.top, max(0, 33 - titlebar))
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: Self.header).ignoresSafeArea(.container, edges: .top))
        .overlay(alignment: .bottom) { Rectangle().fill(YYColor.line).frame(height: 0.5) }
    }

    private func tab(_ p: SettingsPage) -> some View {
        let on = page == p
        return Button {
            page = p
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let drawn = ProtoIcon(rawValue: p.symbol) {
                        // The sidebar's drawing, its line grown with it from 14 to 18.
                        drawn.shape
                            .stroke(style: StrokeStyle(lineWidth: drawn.line * 18 / 14, lineCap: .round, lineJoin: .round))
                            .frame(width: 18, height: 18)
                    } else if p.symbol.hasPrefix("asset.") {
                        Image(String(p.symbol.dropFirst(6))).resizable().renderingMode(.template).scaledToFit()
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: p.symbol).font(.yy(size: 16))
                    }
                }
                .frame(height: 19)
                .foregroundStyle(on ? tint.accent : YYColor.t2)
                Text(p.title)
                    .font(.yy(size: 11, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? YYColor.t1 : YYColor.t2)
            }
            .frame(width: 64, height: 48)
            .background { if on { RoundedRectangle(cornerRadius: 9).fill(YYColor.inset) } }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

}

/// `.v-ms-stb`: the title bar and the tabs are one header, no line between them, the page's name
/// in the middle of the title bar (`.v-ms-stt`; macOS 26 would put it on the left). SwiftUI puts
/// its own title and toolbar back whenever it likes, and a toolbar is taller than the title bar
/// and washes out the tabs under it, so every window update takes them off again.
private struct SettingsTitlebar: NSViewRepresentable {
    let title: String

    final class Host: NSView {
        let label = NSTextField(labelWithString: "")
        nonisolated(unsafe) private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            guard let window else { return }
            label.font = .systemFont(ofSize: 12.5, weight: .semibold)
            label.textColor = .labelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            tidy(window)
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.tidy(window) }
            }
        }

        deinit { observer.map(NotificationCenter.default.removeObserver) }

        func tidy(_ window: NSWindow) {
            if window.toolbar != nil { window.toolbar = nil }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            // The header is drawn under the title bar, so the two are one colour with no line.
            if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
            window.backgroundColor = SettingsTabs.header
            guard label.superview == nil, let close = window.standardWindowButton(.closeButton), let bar = close.superview else { return }
            bar.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            ])
        }
    }

    func makeNSView(context: Context) -> Host { Host() }

    func updateNSView(_ host: Host, context: Context) {
        host.label.stringValue = title
        host.window.map(host.tidy)
    }
}

// MARK: - Traffic lights

extension View {
    /// Puts the window's close, minimise and zoom buttons where the prototype draws them: the
    /// close button's middle `close` from the window's top-left corner, the others after it at the
    /// system's spacing (`.v-lights`). AppKit lays them out again whenever it likes, so they are
    /// put back on every window update.
    func trafficLights(_ close: CGPoint, hidden: Bool = false) -> some View {
        background(TrafficLights(close: close, hidden: hidden))
    }
}

private struct TrafficLights: NSViewRepresentable {
    let close: CGPoint
    /// Faded away, as the shelf's are while its sidebar is put away; they fade back with it.
    var hidden = false

    final class Host: NSView {
        var close = CGPoint.zero
        var lightsHidden = false
        private var shownHidden: Bool?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didUpdateNotification, NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    guard let window = note.object as? NSWindow else { return }
                    MainActor.assumeIsolated { self?.place(in: window) }
                })
            }
            place(in: window)
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        func place(in window: NSWindow) {
            guard !window.styleMask.contains(.fullScreen) else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            guard buttons.count == 3, let bar = buttons[0].superview else { return }
            // A button below the title bar shows but can't be clicked: such a window needs a
            // toolbar, which makes the bar 52 high (SwiftUI owns it, so it isn't added here).
            guard bar.frame.height >= close.y + buttons[0].frame.height / 2 else { return }
            let step = buttons[1].frame.minX - buttons[0].frame.minX
            // The middle of the close button, in the bar's own coordinates.
            let top = window.frame.height - close.y
            let middle = bar.convert(NSPoint(x: close.x, y: top), from: nil)
            for (i, b) in buttons.enumerated() {
                let origin = NSPoint(x: (middle.x + CGFloat(i) * step - b.frame.width / 2).rounded(),
                                     y: (middle.y - b.frame.height / 2).rounded())
                if b.frame.origin != origin { b.setFrameOrigin(origin) }
            }
            fade(buttons)
        }

        /// The first time they just are as they should; after that they fade with the sidebar.
        private func fade(_ buttons: [NSButton]) {
            guard lightsHidden != shownHidden else { return }
            let first = shownHidden == nil
            shownHidden = lightsHidden
            let hide = lightsHidden
            if !hide { buttons.forEach { $0.isHidden = false } }
            if first {
                buttons.forEach { $0.alphaValue = hide ? 0 : 1; $0.isHidden = hide }
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                buttons.forEach { $0.animator().alphaValue = hide ? 0 : 1 }
            } completionHandler: {
                MainActor.assumeIsolated {
                    if self.shownHidden == true { buttons.forEach { $0.isHidden = true } }
                }
            }
        }
    }

    func makeNSView(context: Context) -> Host {
        let host = Host()
        host.close = close
        host.lightsHidden = hidden
        return host
    }

    func updateNSView(_ host: Host, context: Context) {
        host.close = close
        host.lightsHidden = hidden
        host.window.map(host.place)
    }
}

// MARK: - Pieces

/// A white card of rows, lines only between them.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Rectangle().fill(YYColor.line).frame(height: 0.5).padding(.horizontal, 16) }
                    row
                }
            }
        }
        // `.v-ms-box`
        .background(YYColor.card, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(scheme == .dark ? Color(yy: YYRGBA(255, 255, 255, 0.06)) : YYColor.line, lineWidth: 0.5))
        .shadow(color: scheme == .dark ? .clear : Color(yy: YYRGBA(51, 46, 41, 0.04)), radius: 1, y: 1)
    }
}

/// A row: what it is and a line under it on the left, the control on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String?
    /// `.v-ms-rs`: a list of switches, 38 high.
    var compact = false
    @ViewBuilder let trailing: Trailing

    init(_ title: String, detail: String? = nil, compact: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.compact = compact
        self.trailing = trailing()
    }

    var body: some View {
        // `.v-ms-row`: 12.5 over 10.5, at least 46 high.
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.yy(size: 12.5, weight: .medium)).foregroundStyle(YYColor.t1)
                if let detail {
                    Text(detail).font(.yy(size: 10.5)).lineSpacing(2).foregroundStyle(YYColor.t3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, compact ? 8 : 10)
        .frame(minHeight: compact ? 38 : 46)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(_ title: String, detail: String? = nil) {
        self.init(title, detail: detail) { EmptyView() }
    }
}

/// A switch in the theme colour.
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            // `.sw2` is 30 × 18: the small switch.
            .controlSize(.small)
            .tint(YYTint.standard.fill)
    }
}

/// The small grey heading over a card.
struct SettingsHeading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        // `.v-ms-gl`
        Text(text)
            .font(.yy(size: 11.5, weight: .semibold))
            .foregroundStyle(YYColor.t2)
            .padding(.leading, 4)
            .padding(.top, 2)
            .padding(.bottom, -5)
    }
}

// MARK: - 通用

private struct GeneralSettings: View {
    @AppStorage("general.reopenLast") private var reopenLast = false
    @AppStorage("general.keepAwake") private var keepAwake = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                SettingsRow(String(localized: "打开语阅时接着读上次那本"), detail: String(localized: "关掉就只打开书架")) {
                    SettingsSwitch(isOn: $reopenLast)
                }
                SettingsRow(String(localized: "听书时 Mac 不睡着"), detail: String(localized: "合上盖子照样会停")) {
                    SettingsSwitch(isOn: $keepAwake)
                }
            }
            SettingsHeading(String(localized: "导入"))
            SettingsCard {
                SettingsRow(String(localized: "把书拖进书架窗口就导入"), detail: String(localized: "EPUB、PDF、MOBI、AZW3、TXT，漫画的 CBZ、CBR、ZIP 或一文件夹图片；会拷一份进语阅，原文件挪走、删掉都不影响"))
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 外观

private struct AppearanceSettings: View {
    @AppStorage(AppAppearance.key) private var mode = AppAppearance.system
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    @AppStorage("shelf.coverSize") private var coverSize = 100.0
    @AppStorage("shelf.showProgress") private var showProgress = true
    @AppStorage(LiquidGlass.key) private var liquid = true
    @State private var sample = true

    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("界面").font(.yy(size: 13, weight: .medium)).foregroundStyle(YYColor.t1)
                        Text("书架、设置这些窗口；书页的纸色在读书窗口的 Aa 里另外选")
                            .font(.yy(size: 11.5)).foregroundStyle(YYColor.t2)
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        ForEach(AppAppearance.allCases) { m in modeChoice(m) }
                    }
                }
                .padding(16)
            }
            SettingsCard {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("主题色").font(.yy(size: 13, weight: .medium)).foregroundStyle(YYColor.t1)
                            Text("墨蓝是默认；墨黑是你确认过的原样").font(.yy(size: 11.5)).foregroundStyle(YYColor.t2)
                        }
                        Spacer()
                        HStack(spacing: 14) {
                            ForEach(YYTint.all) { t in tintChoice(t) }
                        }
                    }
                    Text("按钮、开关、进度和选中都用这个颜色")
                        .font(.yy(size: 11)).foregroundStyle(YYColor.t3)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(16)
                SettingsRow(String(localized: "看看效果")) {
                    HStack(spacing: 14) {
                        Text("接着读")
                            .font(.yy(size: 12, weight: .semibold))
                            .foregroundStyle(tint.onBlack)
                            .padding(.horizontal, 13).frame(height: 26)
                            .background(tint.black, in: .capsule)
                        HStack(spacing: 8) {
                            ZStack(alignment: .leading) {
                                Capsule().fill(YYColor.inset)
                                Capsule().fill(tint.fill).frame(width: 44)
                            }
                            .frame(width: 72, height: 3)
                            Text("62%").font(.yy(size: 11)).monospacedDigit().foregroundStyle(YYColor.t3)
                        }
                        Toggle("", isOn: $sample).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(tint.fill)
                        Text("全部")
                            .font(.yy(size: 12, weight: .semibold))
                            .foregroundStyle(tint.onBlack)
                            .padding(.horizontal, 11).frame(height: 26)
                            .background(tint.black, in: .capsule)
                    }
                }
            }
            SettingsCard {
                SettingsRow(String(localized: "书架封面大小"), detail: String(localized: "窗口越宽，一排放得越多")) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5).fill(YYColor.tint).frame(width: 8, height: 11)
                        Slider(value: $coverSize, in: 80 ... 130, step: 10)
                            .tint(tint.fill)
                            .frame(width: 180)
                        RoundedRectangle(cornerRadius: 2).fill(YYColor.tint).frame(width: 11, height: 16)
                    }
                }
                SettingsRow(String(localized: "封面下面写进度"), detail: String(localized: "关掉只留书名")) {
                    SettingsSwitch(isOn: $showProgress)
                }
            }
            if LiquidGlass.supported {
                SettingsCard {
                    SettingsRow(String(localized: "液态玻璃效果"), detail: String(localized: "读书窗口的工具胶囊和阅读胶囊、提示条这些浮着的东西用系统的液态玻璃；关掉照原型画：毛玻璃，选中的垫一层浅色")) {
                        SettingsSwitch(isOn: $liquid)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .onChange(of: mode) { AppAppearance.apply() }
    }

    private func modeChoice(_ m: AppAppearance) -> some View {
        let on = mode == m
        return Button { mode = m } label: {
            VStack(spacing: 7) {
                ModeThumbnail(mode: m)
                    .frame(width: 76, height: 50)
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? tint.accent : .clear, lineWidth: 2))
                Text(m.title)
                    .font(.yy(size: 11.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? YYColor.t1 : YYColor.t2)
            }
        }
        .buttonStyle(.plain)
    }

    private func tintChoice(_ t: YYTint) -> some View {
        let on = tintID == t.id
        return Button { tintID = t.id } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(Color(t.black.resolve(in: EnvironmentValues().with(\.colorScheme, .light))))
                    .frame(width: 26, height: 26)
                    .padding(3)
                    .overlay(Circle().strokeBorder(on ? t.black : .clear, lineWidth: 2))
                Text(t.name)
                    .font(.yy(size: 11.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? YYColor.t1 : YYColor.t2)
            }
        }
        .buttonStyle(.plain)
    }
}

private extension EnvironmentValues {
    func with<V>(_ path: WritableKeyPath<EnvironmentValues, V>, _ value: V) -> EnvironmentValues {
        var copy = self
        copy[keyPath: path] = value
        return copy
    }
}

/// A tiny window: a sidebar and three covers, light, dark, or half and half.
private struct ModeThumbnail: View {
    let mode: AppAppearance

    var body: some View {
        ZStack {
            window(dark: mode == .dark)
            if mode == .system {
                window(dark: true)
                    .mask(GeometryReader { g in
                        Path { p in
                            p.move(to: CGPoint(x: g.size.width * 0.62, y: 0))
                            p.addLine(to: CGPoint(x: g.size.width, y: 0))
                            p.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                            p.addLine(to: CGPoint(x: g.size.width * 0.38, y: g.size.height))
                        }
                    })
            }
        }
        .clipShape(.rect(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.black.opacity(0.08)))
    }

    private func window(dark: Bool) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(dark ? Color(white: 0.2) : .white)
                .frame(width: 18)
                .padding(4)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(dark ? Color(white: 0.85) : Color(white: 0.2)).frame(width: 22, height: 3)
                HStack(spacing: 3) {
                    Rectangle().fill(Color(red: 0.2, green: 0.25, blue: 0.21)).frame(width: 9, height: 14)
                    Rectangle().fill(Color(red: 0.55, green: 0.17, blue: 0.14)).frame(width: 9, height: 14)
                    Rectangle().fill(Color(red: 0.84, green: 0.64, blue: 0.33)).frame(width: 9, height: 14)
                }
            }
            .padding(.leading, 6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dark ? Color(white: 0.1) : Color(white: 0.96))
    }
}

// MARK: - 阅读

/// The settings every book uses unless it keeps its own (只用于这本书 under Aa).
private struct ReadingSettings: View {
    let library: Library
    @State private var settings = ReaderSettings.standard
    @AppStorage("reader.twoColumns") private var twoColumns = true
    @AppStorage(ImmersivePrefs.lineKey) private var immersiveLine = true
    @AppStorage(ImmersivePrefs.marksKey) private var immersiveMarks = false
    @AppStorage(ImmersivePrefs.hintsKey) private var immersiveHints = true
    @AppStorage(ImmersivePrefs.alwaysKey) private var immersiveAlways = false
    @AppStorage(ImmersivePrefs.stillKey) private var immersiveStill = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                SettingsRow(String(localized: "纸色"), detail: String(localized: "新打开的书用这个；单本书在 Aa 里另选")) {
                    HStack(spacing: 8) {
                        ForEach(YYPaper.all) { paper in
                            dot(paper, selected: settings.paperChoice == paper.id) { change { $0.paper = Paper(id: paper.id) ?? .plain; $0.customPaper = nil } }
                        }
                        // 我的纸 are made in the book's Aa.
                        ForEach(Papers.shared.list, id: \.id) { mine in
                            dot(YYPaper(custom: mine), selected: settings.paperChoice == mine.id) {
                                let preset = paperColors(paper: mine).preset
                                change { $0.customPaper = mine.id; $0.paper = preset }
                            }
                        }
                    }
                }
                SettingsRow(String(localized: "字体")) {
                    VStack(alignment: .trailing, spacing: 6) {
                        YYSegments(items: [(ReaderFont?.none, String(localized: "系统")), (.some(.serif), String(localized: "宋体")), (.some(.kai), String(localized: "楷体")), (.some(.wenKai), String(localized: "霞鹜文楷"))],
                                   selection: Binding(get: { settings.font }, set: { v in change { $0.font = v }; if v == .wenKai { WenKai.shared.ensure() } }), small: true)
                            .frame(minWidth: 260).fixedSize()
                        WenKaiStatus(chosen: settings.font == .wenKai)
                    }
                }
                SettingsRow(String(localized: "字号")) {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { settings.fontSize }, set: { v in change { $0.fontSize = v.rounded() } }),
                               in: TypesetCard.sizes)
                            .frame(width: 180)
                        Text("\(Int(settings.fontSize))").monospacedDigit().foregroundStyle(YYColor.t2).frame(width: 22)
                    }
                }
                SettingsRow(String(localized: "行距")) {
                    YYSegments(items: [(Double?.some(1.6), String(localized: "紧")), (nil, String(localized: "适中")), (.some(2.2), String(localized: "松"))],
                               selection: Binding(get: { settings.lineHeight }, set: { v in change { $0.lineHeight = v } }), small: true)
                        .frame(minWidth: 160).fixedSize()
                }
            }
            SettingsCard {
                SettingsRow(String(localized: "翻页方式")) {
                    YYSegments(items: [(LayoutMode.paginated, String(localized: "左右翻页")), (.scrolled, String(localized: "上下滚动"))],
                               selection: Binding(get: { settings.mode }, set: { v in change { $0.mode = v } }), small: true)
                        .frame(minWidth: 160).fixedSize()
                }
                SettingsRow(String(localized: "窗口够宽时分两栏"), detail: String(localized: "像翻开一本书，左右两页")) {
                    SettingsSwitch(isOn: $twoColumns)
                }
                SettingsRow(String(localized: "两端对齐")) {
                    SettingsSwitch(isOn: Binding(get: { settings.justify ?? true }, set: { v in change { $0.justify = v } }))
                }
                SettingsRow(String(localized: "首行缩进两字")) {
                    SettingsSwitch(isOn: Binding(get: { settings.indent ?? true }, set: { v in change { $0.indent = v } }))
                }
                SettingsRow(String(localized: "中文标点挤压"), detail: String(localized: "连在一起的标点只占一个字宽")) {
                    SettingsSwitch(isOn: Binding(get: { settings.compress }, set: { v in change { $0.compress = v } }))
                }
            }
            SettingsHeading(String(localized: "沉浸阅读"))
            SettingsCard {
                SettingsRow(String(localized: "进出沉浸"), detail: String(localized: "全屏只留下字；指针移到最底下，胶囊就出来")) {
                    Text("⌃⌘F 或 Esc").font(.yy(size: 12)).foregroundStyle(YYColor.t2)
                }
                SettingsRow(String(localized: "打开书就进沉浸"), detail: String(localized: "每本书一打开就只留下字")) { SettingsSwitch(isOn: $immersiveAlways) }
                SettingsRow(String(localized: "留一条进度细线"), detail: String(localized: "屏幕最底下一条几乎看不见的线")) { SettingsSwitch(isOn: $immersiveLine) }
                SettingsRow(String(localized: "隐藏划线和想法"), detail: String(localized: "只是不显示，退出沉浸就回来")) { SettingsSwitch(isOn: $immersiveMarks) }
                SettingsRow(String(localized: "关掉书伴提示和难词注释"), detail: String(localized: "页面上只剩书里的字")) { SettingsSwitch(isOn: $immersiveHints) }
                SettingsRow(String(localized: "关掉翻页动画"), detail: String(localized: "整页直接换，不滑动")) { SettingsSwitch(isOn: $immersiveStill) }
                SettingsRow(String(localized: "通知不打扰"), detail: String(localized: "给“阅读”专注模式加上语阅")) {
                    Button("打开专注模式设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear { settings = (try? library.core.readerSettings()) ?? .standard }
    }

    private func change(_ edit: (inout ReaderSettings) -> Void) {
        var new = settings
        edit(&new)
        guard new != settings else { return }
        settings = new
        try? library.core.setReaderSettings(settings: new)
        NotificationCenter.default.post(name: .readerSettingsChanged, object: nil)
    }

    private func dot(_ paper: YYPaper, selected: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            Circle().fill(paper.bg)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(YYColor.line))
                .padding(2.5)
                .overlay(Circle().strokeBorder(selected ? YYTint.standard.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(paper.name)
    }
}

// MARK: - 漫画

/// 漫画 (prototype C4): what holds for every comic. 单页、双页还是条漫，从右往左还是从左往右，
/// each comic keeps for itself, chosen in its own window.
private struct ComicSettings: View {
    @AppStorage("comic.crop") private var crop = true
    @AppStorage("comic.preload") private var preload = 5
    @AppStorage("comic.splitSpreads") private var split = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                SettingsRow(String(localized: "阅读方式和方向"), detail: String(localized: "每部漫画分别记住，在漫画窗口右上角换")) {
                    Text("单页 · 双页 · 条漫").font(.yy(size: 12)).foregroundStyle(YYColor.t2)
                }
                SettingsRow(String(localized: "翻页"), detail: String(localized: "点窗口左右两边，或按 ← →、空格；点中间呼出菜单")) {
                    Text("左右跟着方向对调").font(.yy(size: 12)).foregroundStyle(YYColor.t2)
                }
            }
            SettingsHeading(String(localized: "所有漫画"))
            SettingsCard {
                SettingsRow(String(localized: "自动裁白边"), detail: String(localized: "扫描版四周的白边裁掉，画大一些")) { SettingsSwitch(isOn: $crop) }
                SettingsRow(String(localized: "预加载"), detail: String(localized: "翻到之前先备好，翻页不等")) {
                    Picker("", selection: $preload) {
                        ForEach([3, 5, 8], id: \.self) { Text("后面 \($0) 页").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(String(localized: "窗口竖着时拆开跨页"), detail: String(localized: "扫描版的双页图，单页看时拆成两半")) { SettingsSwitch(isOn: $split) }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 朗读

private struct ListeningSettings: View {
    @AppStorage("player.rate") private var rate = 1.0

    private static let languages = [("zh", String(localized: "中文"), String(localized: "从前有一座山，山里有一座庙。")),
                                    ("en", String(localized: "英文"), "It was the best of times, it was the worst of times.")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                SettingsRow(String(localized: "语速"), detail: String(localized: "读书窗口里调的也是这一个")) {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { rate == 0 ? 1 : rate }, set: { rate = ($0 * 10).rounded() / 10 }),
                               in: 0.8 ... 2.0)
                            .frame(width: 180)
                        Text(String(format: "%.1f×", rate == 0 ? 1 : rate)).monospacedDigit()
                            .foregroundStyle(YYColor.t2).frame(width: 36, alignment: .trailing)
                    }
                }
            }
            SettingsHeading(String(localized: "声音"))
            SettingsCard {
                ForEach(Self.languages, id: \.0) { tag, name, sample in
                    VoiceRow(tag: tag, name: name, sample: sample)
                }
            }
            Text("系统声音在这台 Mac 上合成，不联网。想要更自然的声音：系统设置 › 辅助功能 › 朗读内容 › 系统声音 › 管理声音，下载“高级”的那几个")
                .font(.yy(size: 11)).foregroundStyle(YYColor.t3)
                .padding(.horizontal, 8)
            SettingsHeading(String(localized: "云端声音"))
            SettingsCard {
                ForEach(CloudVoice.Provider.allCases) { CloudVoiceRow(provider: $0) }
            }
            Text("填你自己的 Key，费用直接走你的账号，语阅不经手。读过的句子存在这台 Mac 上，再听不花钱，断网也能听；听书时会把这一章提前合成好。")
                .font(.yy(size: 11)).foregroundStyle(YYColor.t3)
                .padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
    }
}

/// 云端声音: one provider's key (and Azure's region); 连接 checks it and fetches the voices.
private struct CloudVoiceRow: View {
    let provider: CloudVoice.Provider
    @State private var key = ""
    @AppStorage(CloudVoice.Provider.regionName) private var region = ""
    @State private var checking = false
    @State private var outcome: String?
    @State private var failed = false
    /// A key is kept: an empty field then offers to take it away.
    @State private var saved = false

    var body: some View {
        SettingsRow(provider.title, detail: outcome ?? provider.help) {
            HStack(spacing: 8) {
                if provider == .azure {
                    TextField("", text: $region, prompt: Text(verbatim: "eastasia"))
                        .textFieldStyle(.roundedBorder).font(.yy(size: 12, design: .monospaced))
                        .frame(width: 90)
                }
                SecureField("", text: $key, prompt: Text(provider.keyHint))
                    .textFieldStyle(.roundedBorder).font(.yy(size: 12, design: .monospaced))
                    .frame(width: provider == .azure ? 130 : 200)
                Button {
                    connect()
                } label: {
                    if checking { ProgressView().controlSize(.small) } else { Text(key.isEmpty && saved ? String(localized: "清掉") : String(localized: "连接")) }
                }
                .disabled(checking || (key.isEmpty && !saved))
                // Squeezed by a long detail on the left, it was cut to a sliver.
                .fixedSize()
            }
            .fixedSize()
        }
        .foregroundStyle(failed ? YYColor.danger : YYColor.t1)
        .onAppear {
            key = Keychain.read(provider.keyName) ?? ""
            saved = !key.isEmpty
        }
    }

    private func connect() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        region = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else {
            Keychain.delete(provider.keyName)
            saved = false
            outcome = nil
            return
        }
        Keychain.write(provider.keyName, k)
        saved = true
        checking = true
        Task {
            defer { checking = false }
            do {
                let n = try await CloudVoice.refresh(provider)
                failed = false
                outcome = String(localized: "已连上 · \(n) 个声音")
            } catch {
                failed = true
                outcome = error.localizedDescription
            }
        }
    }
}

private struct VoiceRow: View {
    let tag: String
    let name: String
    let sample: String
    @State private var chosen: String?

    private var key: String { "player.voice." + tag }

    var body: some View {
        let voices = Voices.all(for: tag)
        let current = voices.first { $0.id == chosen } ?? SystemVoice.best(for: tag) ?? voices.first
        SettingsRow(name, detail: current.map(Voices.title) ?? String(localized: "这台 Mac 上没有这种语言的声音")) {
            HStack(spacing: 8) {
                if let current {
                    Button("试听") { Voices.preview(current, text: sample) }
                }
                Menu("换声音") {
                    ForEach(voices, id: \.id) { v in
                        Button {
                            chosen = v.id
                            UserDefaults.standard.set(v.id, forKey: key)
                        } label: {
                            if v.id == current?.id {
                                Label(Voices.title(v), systemImage: "checkmark")
                            } else {
                                Text(Voices.title(v))
                            }
                        }
                    }
                }
                .fixedSize()
                .disabled(voices.isEmpty)
            }
        }
        .onAppear { chosen = UserDefaults.standard.string(forKey: key) }
    }
}

// MARK: - 书伴

// MARK: - 数据

/// 笔记导出: where 笔记 › 导出 › 发到 sends. Obsidian is a folder (the vault, or one in it);
/// Notion an integration's token and the page the books go under; flomo its API link.
private struct NoteExportSettings: View {
    @State private var folder = NoteExport.obsidianFolder
    @State private var notionToken = Keychain.read(NoteExport.notionKey) ?? ""
    @AppStorage(NoteExport.notionPageKey) private var notionPage = ""
    @State private var flomo = Keychain.read(NoteExport.flomoKey) ?? ""

    var body: some View {
        SettingsHeading(String(localized: "笔记导出"))
        SettingsCard {
            SettingsRow("Obsidian", detail: String(localized: "每本书一篇笔记，写进你选的文件夹；再发一次就更新那一篇")) {
                HStack(spacing: 8) {
                    if let folder {
                        Text(folder.lastPathComponent).font(.yy(size: 12)).foregroundStyle(YYColor.t2).lineLimit(1)
                    }
                    Button(folder == nil ? String(localized: "选文件夹…") : String(localized: "换一个…")) { pick() }
                }
            }
            SettingsRow("Notion", detail: String(localized: "在 notion.so/my-integrations 建一个集成，把令牌填在这里；再把要放书的页面共享给它，页面链接填在下面")) {
                SecureField("", text: $notionToken, prompt: Text(verbatim: "ntn_…"))
                    .textFieldStyle(.roundedBorder).font(.yy(size: 12, design: .monospaced))
                    .frame(width: 240)
                    .onChange(of: notionToken) { save(NoteExport.notionKey, notionToken) }
            }
            SettingsRow(String(localized: "Notion 页面"), detail: notionPage.isEmpty || NoteExport.pageID(from: notionPage) != nil ? nil : String(localized: "这不像一个 Notion 页面链接")) {
                TextField("", text: $notionPage, prompt: Text(verbatim: "https://www.notion.so/…"))
                    .textFieldStyle(.roundedBorder).font(.yy(size: 12, design: .monospaced))
                    .frame(width: 240)
            }
            SettingsRow("flomo", detail: String(localized: "flomo 网页版 › 设置 › API，拷那条以 https://flomoapp.com/iwh/ 开头的链接；每条划线成一条笔记")) {
                SecureField("", text: $flomo, prompt: Text(verbatim: "https://flomoapp.com/iwh/…"))
                    .textFieldStyle(.roundedBorder).font(.yy(size: 12, design: .monospaced))
                    .frame(width: 240)
                    .onChange(of: flomo) { save(NoteExport.flomoKey, flomo) }
            }
        }
    }

    private func save(_ key: String, _ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { Keychain.delete(key) } else { Keychain.write(key, v) }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "用这个文件夹")
        panel.message = String(localized: "选 Obsidian 库，或库里的一个文件夹")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        NoteExport.setObsidianFolder(url)
        folder = NoteExport.obsidianFolder
    }
}

/// 数据快照 and 导出阅读记录, as on iPhone (prototype 29): what goes in and how big, 生成快照,
/// 导入快照…, and the ones made before.
private struct DataSettings: View {
    let library: Library
    @State private var snapshots: Snapshots
    @State private var exporting = false
    @State private var importing: Importing?

    struct Importing: Identifiable {
        let url: URL
        let info: SnapshotInfo
        var id: URL { url }
    }

    init(library: Library) {
        self.library = library
        _snapshots = State(initialValue: Snapshots(library: library))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsHeading(String(localized: "生成快照"))
            SettingsCard {
                part(String(localized: "进度和书签"), count: snapshots.counts.map { String(localized: "\(Snapshots.number($0.read)) 本") }, \.progress)
                part(String(localized: "笔记"), count: snapshots.counts.map { String(localized: "\(Snapshots.number($0.notes)) 条") }, \.notes)
                part(String(localized: "生词"), count: snapshots.counts.map { String(localized: "\(Snapshots.number($0.words)) 个") }, \.words)
                part(String(localized: "设置和替换规则"), count: nil, \.settings)
                part(String(localized: "书文件"), count: snapshots.counts.map { Snapshots.size($0.fileBytes) }, \.files)
                HStack(spacing: 12) {
                    (Text(snapshots.parts.files ? String(localized: "含书文件 · 约 ") : String(localized: "不含书文件 · 约 "))
                        + Text(snapshots.counts == nil ? "…" : StorageSettings.size(snapshots.estimate)).fontWeight(.semibold).foregroundStyle(YYColor.t1))
                        .font(.yy(size: 12).monospacedDigit()).foregroundStyle(YYColor.t3)
                    if let problem = snapshots.problem {
                        Text(problem).font(.yy(size: 11.5)).foregroundStyle(YYColor.danger).lineLimit(2)
                    }
                    Spacer()
                    Button("导入快照…") { pick() }
                    Button {
                        Task { await snapshots.make() }
                    } label: {
                        if snapshots.making { ProgressView().controlSize(.small) } else { Text("生成快照") }
                    }
                    .buttonStyle(YYButtonStyle(kind: .main, size: .small))
                    .disabled(snapshots.making)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
            SettingsCard {
                SettingsRow(String(localized: "导出阅读记录"), detail: String(localized: "想读、在读、读完和读完的日期，给 Goodreads 或 StoryGraph 导入")) {
                    Button("导出…") { exporting = true }
                }
            }
            NoteExportSettings()
            if !snapshots.saved.isEmpty {
                SettingsHeading(String(localized: "以前的快照"))
                SettingsCard {
                    ForEach(snapshots.saved) { s in
                        SettingsRow(Snapshots.when(s.about.madeAt),
                                    detail: ([Snapshots.from(s.about)] + (s.about.parts.files ? [String(localized: "含书文件")] : []) + [Snapshots.size(s.about.bytes)]).joined(separator: " · ")) {
                            HStack(spacing: 8) {
                                Button("导入…") { open(s.url) }
                                ShareLink(item: s.url) { Image(systemName: "square.and.arrow.up") }
                                    .help("分享")
                            }
                        }
                        .contextMenu {
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([s.url]) }
                            Divider()
                            Button("删除", role: .destructive) { snapshots.delete(s) }
                        }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "info.circle")
                Text("快照是一个 .yuyue 文件，拷到别的设备上打开就能导入，iPhone、Android 和 Mac 之间都通用。")
                Button("在访达中显示") {
                    try? FileManager.default.createDirectory(at: snapshots.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([snapshots.folder])
                }
                .buttonStyle(.link)
            }
            .font(.yy(size: 11)).foregroundStyle(YYColor.t3)
            .padding(.leading, 8)
            Spacer(minLength: 0)
        }
        .task { await snapshots.load() }
        .sheet(isPresented: $exporting) { ReadingExportSheet(library: library) }
        .sheet(item: $importing) { SnapshotImportSheet(snapshots: snapshots, url: $0.url, info: $0.info) }
    }

    private func part(_ title: String, count: String?, _ key: WritableKeyPath<SnapshotParts, Bool>) -> some View {
        SettingsRow(title) {
            HStack(spacing: 12) {
                if let count { Text(count).font(.yy(size: 12).monospacedDigit()).foregroundStyle(YYColor.t3) }
                SettingsSwitch(isOn: Binding { snapshots.parts[keyPath: key] } set: { snapshots.parts[keyPath: key] = $0 })
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yuyueSnapshot]
        panel.prompt = String(localized: "导入")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    private func open(_ url: URL) {
        do {
            let (local, info) = try snapshots.preview(url)
            importing = Importing(url: local, info: info)
        } catch {
            snapshots.problem = Library.message(for: error)
        }
    }
}

// MARK: - 存储

private struct StorageSettings: View {
    let library: Library
    @State private var usage: StorageUsage?
    @State private var cleaning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("语阅一共用了").font(.yy(size: 13)).foregroundStyle(YYColor.t2)
                        Text(usage.map { Self.size($0.total) } ?? "…")
                            .font(.yy(size: 22, weight: .bold)).foregroundStyle(YYColor.t1)
                        Spacer()
                        if let free = usage?.free {
                            Text("这台 Mac 还剩 \(Self.size(free))").font(.yy(size: 11.5)).foregroundStyle(YYColor.t3)
                        }
                    }
                    if let usage { bar(usage) }
                }
                .padding(16)
                SettingsRow(String(localized: "已删除的书 · \(usage?.deleted.count ?? 0) 本 · \(Self.size(usage?.deletedBytes ?? 0))"),
                            detail: String(localized: "删掉的书留 30 天，可以撤销；过了就自动清掉")) {
                    Button("现在清掉") { purge() }
                        .foregroundStyle(YYColor.danger)
                        .disabled((usage?.deleted.isEmpty ?? true) || cleaning)
                }
                SettingsRow(String(localized: "书伴存下的回答"), detail: String(localized: "同一本书、读到同一章问同样的问题，直接用存下的，不再花钱")) {
                    HStack(spacing: 10) {
                        Text(Self.size(companionBytes))
                            .font(.yy(size: 12)).monospacedDigit().foregroundStyle(YYColor.t2)
                        Button("清掉") {
                            try? FileManager.default.removeItem(at: companionDir)
                            companionBytes = Self.bytes(in: companionDir)
                        }
                        .disabled(companionBytes == 0)
                    }
                }
                SettingsRow(String(localized: "书库放在"), detail: library.dataDir.path(percentEncoded: false)) {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([library.dataDir]) }
                }
            }
            if let usage, !usage.books.isEmpty {
                SettingsHeading(String(localized: "每本书 · 从大到小"))
                SettingsCard {
                    ForEach(usage.books.prefix(12), id: \.id) { b in
                        SettingsRow(b.title) {
                            Text(Self.size(b.bytes)).monospacedDigit().foregroundStyle(YYColor.t2)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .task { await measure() }
        .onAppear { companionBytes = Self.bytes(in: companionDir) }
    }

    @State private var companionBytes: Int64 = 0
    private var companionDir: URL { library.dataDir.appending(path: "companion", directoryHint: .isDirectory) }

    private static func bytes(in dir: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func bar(_ u: StorageUsage) -> some View {
        let parts: [(String, Int64, Color)] = [(String(localized: "书文件"), u.bookBytes, YYTint.standard.fill),
                                               (String(localized: "已删除"), u.deletedBytes, YYColor.danger.opacity(0.7)),
                                               (String(localized: "其他"), max(0, u.total - u.bookBytes - u.deletedBytes), YYColor.tint)]
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(parts.filter { $0.1 > 0 }, id: \.0) { p in
                        Rectangle().fill(p.2)
                            .frame(width: max(3, g.size.width * Double(p.1) / Double(max(1, u.total))))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 8)
            .clipShape(.capsule)
            HStack(spacing: 16) {
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 5) {
                        Circle().fill(p.2).frame(width: 7, height: 7)
                        Text("\(p.0) \(Self.size(p.1))").font(.yy(size: 11)).foregroundStyle(YYColor.t2)
                    }
                }
            }
        }
    }

    private func measure() async {
        let dir = library.dataDir
        let active = Dictionary(library.books.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        usage = await StorageUsage.measure(dir: dir, active: active)
    }

    private func purge() {
        cleaning = true
        _ = try? library.core.purgeDeleted(olderThanMs: 0)
        Task {
            await measure()
            cleaning = false
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#endif

/// 界面 light · dark · following the system, kept in `appearance.mode`.
enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: String(localized: "浅色")
        case .dark: String(localized: "深色")
        case .system: String(localized: "跟随系统")
        }
    }

    static let key = "appearance.mode"

    static var current: AppAppearance {
        UserDefaults.standard.string(forKey: key).flatMap(AppAppearance.init) ?? .system
    }

    #if os(macOS)
    /// Puts every window in the chosen appearance.
    static func apply() {
        switch current {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
    }
    #endif

    #if os(iOS)
    var scheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }
    #endif
}


/// Where the library's space goes.
struct StorageUsage: Sendable {
    struct Book: Sendable {
        let id: String
        let title: String
        let bytes: Int64
    }

    var total: Int64 = 0
    var free: Int64?
    var books: [Book] = []
    var deleted: [String] = []
    var deletedBytes: Int64 = 0
    var bookBytes: Int64 { books.reduce(0) { $0 + $1.bytes } }

    @concurrent static func measure(dir: URL, active: [String: String]) async -> StorageUsage {
        var u = StorageUsage()
        u.total = bytes(in: dir)
        let booksDir = dir.appending(path: "books", directoryHint: .isDirectory)
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: booksDir.path(percentEncoded: false))) ?? []
        for id in ids where !id.hasPrefix(".") {
            let size = bytes(in: booksDir.appending(path: id, directoryHint: .isDirectory))
            if let title = active[id] {
                u.books.append(Book(id: id, title: title, bytes: size))
            } else {
                u.deleted.append(id)
                u.deletedBytes += size
            }
        }
        u.books.sort { $0.bytes > $1.bytes }
        u.free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        return u
    }

    nonisolated private static func bytes(in dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var sum: Int64 = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { sum += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return sum
    }
}
