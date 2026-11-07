import SwiftUI
import YuyueCore

#if os(macOS)

/// 设置 (⌘,): the pages down a sidebar on the left, the page in the middle, and on the right what
/// was last changed, each change undoable, with a sample of the page where there's something to
/// see. Changes take at once; there is no 应用 button.
struct MacSettings: View {
    let library: Library
    @AppStorage("settings.page") private var page = SettingsPage.general

    @AppStorage("appearance.tint") private var tintID = YYTint.pine.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .pine }

    /// One height for every page, so switching pages doesn't move the window; less on a small screen.
    private var height: CGFloat {
        min(640, (NSScreen.main?.visibleFrame.height ?? 800) - 140)
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(page: $page, tint: tint)
                .ignoresSafeArea(.container, edges: .top)
            VStack(spacing: 0) {
                if page == .listening, ListeningFocus.shared.source != nil {
                    // One source's voices: no page title, and it scrolls only its own list.
                    ListeningPage()
                        .padding(.leading, 24)
                        .padding(.trailing, 18)
                        .padding(.top, 24)
                        .padding(.bottom, 12)
                        .ignoresSafeArea(.container, edges: .top)
                } else {
                    SettingsPageHeader(page: page)
                    ScrollView {
                        content(page)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // The scroller keeps clear of the line by the right column.
                    .padding(.trailing, 6)
                    // Rows slide under the header softly instead of being cut at its edge.
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                            Rectangle()
                        }
                    }
                    // A new page starts at its top.
                    .id(page)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(YYColor.bg.ignoresSafeArea())
            SettingsInspector(page: page, library: library)
                .ignoresSafeArea(.container, edges: .top)
        }
        // The title bar is see-through over the three columns; no toolbar, no title in it.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar(removing: .title)
        .frame(width: 980, height: height)
        .tint(tint.accent)
        .navigationTitle(page.title)
        .background(SettingsTitlebar())
        // At the top of the sidebar, as in the shelf window.
        .trafficLights(CGPoint(x: 22, y: 20))
        .onAppear { SettingsLog.shared.library = library }
        .background(SettingsUndoKey())
    }

    @ViewBuilder private func content(_ p: SettingsPage) -> some View {
        Group {
            switch p {
            case .general: GeneralSettings()
            case .appearance: AppearanceSettings()
            case .reading: ReadingSettings(library: library)
            case .listening: ListeningPage()
            case .foreign: ForeignSettings(library: library)
            case .companion: CompanionSettings(library: library)
            case .notes: NoteExportSettings()
            case .sync: SyncSettings(library: library)
            case .storage: StorageSettings(library: library)
            case .data: DataSettings(library: library)
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 18)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .top)
        // Two kinds of button in 设置: the one solid main action a page may have sets its own
        // style; every other action is words, no fill, no border.
        .buttonStyle(SettingsActionStyle())
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, reading, foreign, listening, companion, sync, notes, storage, data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "通用")
        case .appearance: String(localized: "外观")
        case .reading: String(localized: "阅读")
        case .foreign: String(localized: "外文")
        case .listening: String(localized: "朗读")
        case .companion: String(localized: "书伴")
        case .sync: String(localized: "同步")
        case .notes: String(localized: "笔记导出")
        case .storage: String(localized: "存储")
        case .data: String(localized: "数据")
        }
    }

    /// Under the page's name in its header: what the page is for, in a line.
    var summary: String {
        switch self {
        case .general: String(localized: "打开、睡眠和导入")
        case .appearance: String(localized: "书架、设置这些窗口；书页的纸在“阅读”里")
        case .reading: String(localized: "新打开的书用这些；单本书在 Aa 里另调")
        case .foreign: String(localized: "点词、难词注释、生词和翻译")
        case .listening: String(localized: "听书、点词和播客主持人的声音")
        case .companion: String(localized: "书伴和写播客稿用的模型")
        case .sync: String(localized: "进度、笔记和设置在你的设备之间同步")
        case .notes: String(localized: "笔记 › 导出 › 发到 的去处")
        case .storage: String(localized: "语阅在这台 Mac 上占的地方")
        case .data: String(localized: "快照和阅读记录，换设备时带走")
        }
    }

    /// The small grey line over a group of pages in the sidebar; 通用 and 外观 stand alone at the top.
    var group: String? {
        switch self {
        case .general, .appearance: nil
        case .reading, .foreign, .listening: String(localized: "读和听")
        case .companion, .sync, .notes: String(localized: "连接")
        case .storage, .data: String(localized: "这台 Mac")
        }
    }

    /// One set: SF Symbols, all line drawings of one weight.
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .appearance: "sun.max"
        case .reading: "book"
        case .foreign: "character.book.closed"
        case .listening: "headphones"
        case .companion: "text.bubble"
        case .sync: "arrow.triangle.2.circlepath"
        case .notes: "square.and.arrow.up"
        case .storage: "internaldrive"
        case .data: "shippingbox"
        }
    }
}

/// The page's name and what it's for, fixed over the page as it scrolls.
private struct SettingsPageHeader: View {
    let page: SettingsPage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(page.title).font(.yy(size: 16, weight: .semibold)).foregroundStyle(YYColor.t1)
            Text(page.summary).font(.yy(size: 11.5)).foregroundStyle(YYColor.t2).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Level with the first row of the sidebar, clear of the title bar.
        .padding(.leading, 24 + 16)
        .padding(.trailing, 24)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Every action but a page's main one: words in ink, red for one that throws something away,
/// faint while it can't be used.
struct SettingsActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration)
    }

    private struct Label: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.yy(size: 12.5, weight: .medium))
                .foregroundStyle(configuration.role == .destructive ? YYColor.danger : YYColor.t1)
                .opacity(!enabled ? 0.35 : configuration.isPressed ? 0.55 : 1)
                .contentShape(.rect)
        }
    }
}

/// ⌘Z in 设置 takes back the last change in 最近改过, unless a text field is being typed in, where
/// it undoes the typing as usual.
private struct SettingsUndoKey: NSViewRepresentable {
    final class Host: NSView {
        nonisolated(unsafe) private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            monitor.map(NSEvent.removeMonitor)
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "z" else { return event }
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let window = self?.window, event.window === window,
                          !(window.firstResponder is NSText),
                          let last = SettingsLog.shared.entries.first(where: { $0.undo != nil && $0.undone != true }) else { return false }
                    SettingsLog.shared.undo(last)
                    return true
                }
                return handled ? nil : event
            }
        }

        deinit { monitor.map(NSEvent.removeMonitor) }
    }

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ host: Host, context: Context) {}
}

/// The title bar is drawn over the three columns, see-through, with no line under it and no title
/// in it (the sidebar says which page this is). SwiftUI puts its own title and toolbar back
/// whenever it likes, and a toolbar is taller than the title bar, so every window update takes
/// them off again.
private struct SettingsTitlebar: NSViewRepresentable {
    final class Host: NSView {
        nonisolated(unsafe) private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            guard let window else { return }
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
            if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
            window.backgroundColor = SettingsSidebar.header
        }
    }

    func makeNSView(context: Context) -> Host { Host() }

    func updateNSView(_ host: Host, context: Context) {
        host.window.map(host.tidy)
    }
}

// MARK: - Traffic lights

extension View {
    /// Puts the window's close, minimise and zoom buttons where the design has them: the
    /// close button's middle `close` from the window's top-left corner, the others after it at the
    /// system's spacing. AppKit lays them out again whenever it likes, so they are
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
        .background(YYColor.card, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(scheme == .dark ? Color(yy: YYRGBA(255, 255, 255, 0.06)) : YYColor.line, lineWidth: 0.5))
        .shadow(color: scheme == .dark ? .clear : Color(yy: YYRGBA(51, 46, 41, 0.04)), radius: 1, y: 1)
    }
}

/// A row: what it is and a line under it on the left, the control on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String?
    /// A list of switches, 38 high.
    var compact = false
    @ViewBuilder let trailing: Trailing

    init(_ title: String, detail: String? = nil, compact: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.compact = compact
        self.trailing = trailing()
    }

    var body: some View {
        // 12.5 over 10.5, at least 46 high.
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
                // A switch on the right says what it switches to VoiceOver: the row's title.
                .environment(\.settingsRowTitle, title)
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
extension EnvironmentValues {
    /// The title of the settings row a control sits in.
    @Entry var settingsRowTitle = ""
}

struct SettingsSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.settingsRowTitle) private var title

    var body: some View {
        Toggle(title, isOn: $isOn)
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
        Text(text)
            .font(.yy(size: 11.5, weight: .semibold))
            .foregroundStyle(YYColor.t2)
            .padding(.leading, 16)
            .padding(.top, 6)
            .padding(.bottom, -6)
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
                LoginItemRow()
                SettingsRow(String(localized: "听书时 Mac 不睡着"), detail: String(localized: "合上盖子照样会停")) {
                    SettingsSwitch(isOn: $keepAwake)
                }
            }
            SettingsHeading(String(localized: "导入"))
            SettingsCard {
                SettingsRow(String(localized: "把书拖进书架窗口就导入"), detail: String(localized: "拷一份进语阅，原文件挪走、删掉都不影响")) {
                    Text(verbatim: "EPUB PDF MOBI AZW3 TXT").font(.yy(size: 11, design: .monospaced)).foregroundStyle(YYColor.t3)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 外观

private struct AppearanceSettings: View {
    @AppStorage(AppAppearance.key) private var mode = AppAppearance.system
    @AppStorage("shelf.coverSize") private var coverSize = 100.0
    @AppStorage("shelf.showProgress") private var showProgress = true
    @AppStorage(LiquidGlass.key) private var liquid = true

    @AppStorage("appearance.tint") private var tintID = YYTint.pine.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .pine }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                // What 界面 covers is the page header's line; the card only chooses.
                HStack(alignment: .top) {
                    Text("界面").font(.yy(size: 12.5, weight: .medium)).foregroundStyle(YYColor.t1)
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
                            Text("松绿是默认").font(.yy(size: 11.5)).foregroundStyle(YYColor.t2)
                        }
                        Spacer()
                        HStack(spacing: 14) { ForEach(YYTint.all) { t in tintChoice(t) } }
                    }
                    Text("按钮、开关、进度和选中都用这个颜色")
                        .font(.yy(size: 11)).foregroundStyle(YYColor.t3)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(16)
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
                    SettingsRow(String(localized: "液态玻璃效果"), detail: String(localized: "浮着的胶囊和提示条用系统的玻璃；关掉是毛玻璃")) {
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
                    // 跟随系统 on one line, not broken in two under its picture.
                    .fixedSize()
            }
        }
        .buttonStyle(.plain)
    }

    private func tintChoice(_ t: YYTint) -> some View {
        let on = tintID == t.id
        return Button { tintID = t.id } label: {
            VStack(spacing: 6) {
                Circle().fill(Color(t.accent.resolve(in: EnvironmentValues().with(\.colorScheme, .light))))
                    .frame(width: 26, height: 26).padding(3)
                    .overlay(Circle().strokeBorder(on ? t.accent : .clear, lineWidth: 2))
                Text(t.name).font(.yy(size: 11.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? YYColor.t1 : YYColor.t2)
            }
        }.buttonStyle(.plain)
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
                // The papers and fonts as tiles, so each is seen before it's chosen.
                tiles(String(localized: "纸色"), detail: String(localized: "新打开的书用这个；单本书在 Aa 里另选"), columns: YYPaper.all.count) {
                    ForEach(YYPaper.all) { paper in
                        SettingsPaperTile(paper: paper, texture: paper.hasNoiseTexture ? .grain : .none, name: paper.name, selected: settings.paperChoice == paper.id) {
                            change { $0.paper = Paper(id: paper.id) ?? .plain; $0.customPaper = nil }
                        }
                    }
                    // 我的纸 are made in the book's Aa.
                    ForEach(Papers.shared.list, id: \.id) { mine in
                        SettingsPaperTile(paper: YYPaper(custom: mine), texture: mine.texture, name: mine.name, selected: settings.paperChoice == mine.id) {
                            let preset = paperColors(paper: mine).preset
                            change { $0.customPaper = mine.id; $0.paper = preset }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    tiles(String(localized: "字体"), columns: 4) {
                        ForEach([ReaderFont?.none, .serif, .kai, .wenKai], id: \.self) { font in
                            SettingsFontTile(font: font, selected: settings.font == font) {
                                change { $0.font = font }
                                if font == .wenKai { WenKai.shared.ensure() }
                            }
                        }
                    }
                    WenKaiStatus(chosen: settings.font == .wenKai)
                        .padding(.horizontal, 16)
                        .padding(.top, -6)
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
        // 撤销 in 最近改过 writes the old value back.
        .onReceive(NotificationCenter.default.publisher(for: .readerSettingsChanged)) { _ in
            settings = (try? library.core.readerSettings()) ?? settings
        }
    }

    /// A titled row of tiles in the card: what it is on top, the choices filling the width.
    private func tiles<Content: View>(_ title: String, detail: String? = nil, columns: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.yy(size: 12.5, weight: .medium)).foregroundStyle(YYColor.t1)
                if let detail { Text(detail).font(.yy(size: 10.5)).foregroundStyle(YYColor.t3) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) { content() }
        }
        .padding(16)
    }

    private func change(_ edit: (inout ReaderSettings) -> Void) {
        var new = settings
        edit(&new)
        guard new != settings else { return }
        SettingsLog.shared.reader(from: settings, to: new)
        settings = new
        try? library.core.setReaderSettings(settings: new)
        NotificationCenter.default.post(name: .readerSettingsChanged, object: nil)
    }
}

// MARK: - 朗读: MacVoicePicker.swift

// MARK: - 书伴

// MARK: - 数据

/// A line under a card, on the cards' one left edge: what to know, never something to click.
struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.yy(size: 11)).lineSpacing(2).foregroundStyle(YYColor.t3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
    }
}

/// 数据快照 and 导出阅读记录, as on iPhone: what goes in and how big, 生成快照,
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
                        .buttonStyle(YYButtonStyle(kind: .raised, size: .small))
                    Button {
                        Task { await snapshots.make() }
                    } label: {
                        if snapshots.making { ProgressView().controlSize(.small) } else { Text("生成快照") }
                    }
                    .buttonStyle(YYButtonStyle(kind: .card, size: .small))
                    .disabled(snapshots.making)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
            SettingsCard {
                SettingsRow(String(localized: "导出阅读记录"), detail: String(localized: "想读、在读、读完和读完的日期，给 Goodreads 或 StoryGraph 导入")) {
                    Button("导出…") { exporting = true }
                        .buttonStyle(YYButtonStyle(kind: .raised, size: .small))
                }
            }
            if !snapshots.saved.isEmpty {
                SettingsHeading(String(localized: "以前的快照"))
                SettingsCard {
                    ForEach(snapshots.saved) { s in
                        SettingsRow(Snapshots.when(s.about.madeAt),
                                    detail: ([Snapshots.from(s.about)] + (s.about.parts.files ? [String(localized: "含书文件")] : []) + [Snapshots.size(s.about.bytes)]).joined(separator: " · ")) {
                            HStack(spacing: 8) {
                                Button("导入…") { open(s.url) }
                                ShareLink(item: s.url) { Image(systemName: "square.and.arrow.up").font(.yy(size: 12)) }
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
            SettingsNote(String(localized: "快照是一个 .yuyue 文件，拷到别的设备上打开就能导入，iPhone、Android 和 Mac 之间都通用。"))
            Spacer(minLength: 0)
        }
        .task { await snapshots.load() }
        // The sheets keep their own buttons, not 设置's words.
        .sheet(isPresented: $exporting) { ReadingExportSheet(library: library).buttonStyle(.automatic) }
        .sheet(item: $importing) { SnapshotImportSheet(snapshots: snapshots, url: $0.url, info: $0.info).buttonStyle(.automatic) }
    }

    private func part(_ title: String, count: String?, _ key: WritableKeyPath<SnapshotParts, Bool>) -> some View {
        SettingsRow(title, detail: count) {
            SettingsSwitch(isOn: Binding { snapshots.parts[keyPath: key] } set: { snapshots.parts[keyPath: key] = $0 })
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
                    Button("现在清掉", role: .destructive) { purge() }
                        .disabled((usage?.deleted.isEmpty ?? true) || cleaning)
                }
                if modelBytes > 0 {
                    SettingsRow(String(localized: "有声书对齐模型"), detail: String(localized: "合成有声书时用；删掉后下次合成会再下载一次（约 270 MB）")) {
                        HStack(spacing: 10) {
                            Text(Self.size(modelBytes))
                                .font(.yy(size: 12)).monospacedDigit().foregroundStyle(YYColor.t2)
                            Button("删掉") {
                                try? FileManager.default.removeItem(at: Aligner.folder(library.dataDir))
                                Task { await measure() }
                            }
                            .disabled(library.audiobooks.job != nil)
                        }
                    }
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
                KeepHeardRow()
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
    /// The alignment model and the 有声书 recordings, told apart from 其他.
    @State private var modelBytes: Int64 = 0
    @State private var audioBytes: Int64 = 0

    /// Everything under `dir`, folders and all.
    nonisolated private static func tree(_ dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
    private var companionDir: URL { library.dataDir.appending(path: "companion", directoryHint: .isDirectory) }

    private static func bytes(in dir: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func bar(_ u: StorageUsage) -> some View {
        let parts: [(String, Int64, Color)] = [(String(localized: "书文件"), u.bookBytes, YYTint.standard.fill),
                                               (String(localized: "有声书录音"), audioBytes, YYTint.standard.fill.opacity(0.55)),
                                               (String(localized: "对齐模型"), modelBytes, YYColor.t3),
                                               (String(localized: "已删除"), u.deletedBytes, YYColor.danger.opacity(0.7)),
                                               (String(localized: "其他"), max(0, u.total - u.bookBytes - u.deletedBytes - audioBytes - modelBytes), YYColor.tint)]
            .filter { $0.1 > 0 || $0.0 == String(localized: "书文件") }
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
        let (model, audio) = await Task.detached {
            (Self.tree(Aligner.folder(dir)), Self.tree(dir.appending(path: "audiobooks", directoryHint: .isDirectory)))
        }.value
        modelBytes = model
        audioBytes = audio
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
