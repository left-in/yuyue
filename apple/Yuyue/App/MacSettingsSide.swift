import SwiftUI
import YuyueCore

#if os(macOS)

// 设置的侧栏和右栏 (docs/design/设置-三栏前后对比.html)：左边一列页，右边“已存在这台 Mac”、
// 能看的页放一张样张，下面是按天分组、能撤销的“最近改过”。

// MARK: - 侧栏

/// The pages down the left, drawn as the shelf's sidebar is: a faint wash under the one shown.
struct SettingsSidebar: View {
    @Binding var page: SettingsPage
    let tint: YYTint
    @Namespace private var selection

    /// The sidebar, the right column and the title bar over them are one colour, a little lighter
    /// than the page in the middle.
    static let header = NSColor(name: nil) { look in
        look.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 22 / 255, green: 23 / 255, blue: 24.6 / 255, alpha: 1)
            : NSColor(srgbRed: 251 / 255, green: 250.5 / 255, blue: 249.6 / 255, alpha: 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(SettingsPage.allCases.enumerated()), id: \.element) { i, p in
                if let group = p.group, i == 0 || SettingsPage.allCases[i - 1].group != group {
                    Text(group)
                        .font(.yy(size: 10.5, weight: .medium))
                        .foregroundStyle(YYColor.t3)
                        .padding(.leading, 8)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                }
                row(p)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        // Clear of the window's buttons, which sit in this column's top-left corner.
        .padding(.top, 46)
        .padding(.bottom, 10)
        .frame(width: 184)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: Self.header))
        .overlay(alignment: .trailing) { Rectangle().fill(YYColor.line).frame(width: 0.5) }
    }

    private func row(_ p: SettingsPage) -> some View {
        let on = page == p
        return Button {
            withAnimation(YYMotion.reduce ? nil : .snappy(duration: 0.22)) { page = p }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: p.symbol)
                    .font(.yy(size: 13))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(on ? tint.accent : YYColor.t2)
                Text(p.title)
                    .font(.yy(size: 12.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(YYColor.t1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 8).fill(ShelfDesk.on)
                        .matchedGeometryEffect(id: "on", in: selection)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - 右栏

struct SettingsInspector: View {
    let page: SettingsPage
    let library: Library
    @State private var reader = ReaderSettings.standard
    private var log: SettingsLog { SettingsLog.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    saved
                    Spacer(minLength: 4)
                    SettingsHistoryButton()
                }
                    .padding(.leading, 16)
                    .padding(.trailing, 10)
                    // Level with the window's buttons.
                    .padding(.top, 13)
                    .padding(.bottom, 10)
                if page == .reading {
                    section(String(localized: "样张"), trailing: ReadingSample.summary(reader)) {
                        ReadingSample(settings: reader)
                        caption(String(localized: "用《故乡》开头排的；单本书在 Aa 里另调"))
                    }
                    divider
                } else if page == .foreign {
                    section(String(localized: "样张"), trailing: ForeignSample.summary) {
                        ForeignSample(paper: ReadingSample.paper(reader))
                    }
                    divider
                } else if page == .listening {
                    if ListeningFocus.shared.macPanel {
                        MacVoicePanel()
                    } else if ListeningFocus.shared.page != nil {
                        ListeningInspector()
                            .animation(.easeOut(duration: 0.18), value: ListeningFocus.shared.page)
                    } else {
                        ListeningVoiceCard()
                    }
                } else if page == .companion {
                    CompanionInspector()
                        .animation(.easeOut(duration: 0.18), value: CompanionFocus.shared.page)
                    divider
                } else if page == .notes {
                    NotesInspector()
                    divider
                } else if page == .data {
                    section(String(localized: "上次快照"), trailing: "") { SnapshotCard(library: library) }
                    divider
                } else if page == .storage {
                    section(String(localized: "书库"), trailing: "") { LibraryCard(library: library) }
                    divider
                }
            }
        }
        .scrollIndicators(.never)
        .frame(width: 252)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: SettingsSidebar.header))
        .overlay(alignment: .leading) { Rectangle().fill(YYColor.line).frame(width: 0.5) }
        .onAppear { load() }
        .onReceive(NotificationCenter.default.publisher(for: .readerSettingsChanged)) { _ in load() }
        .task(id: log.flash?.id) {
            guard log.flash != nil else { return }
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.easeOut(duration: 0.3)) { log.flash = nil }
        }
    }

    private func load() { reader = (try? library.core.readerSettings()) ?? .standard }

    /// 已存在这台 Mac: there is no 应用 button; for a moment after a change it says what was kept.
    private var saved: some View {
        let note = log.flash
        return HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.yy(size: 10, weight: .semibold))
                .foregroundStyle(note == nil ? YYColor.t3 : YYColor.ok)
            Text(note.map { String(localized: "已存 · \($0.title) \($0.to)") } ?? String(localized: "已存在这台 Mac"))
                .font(.yy(size: 11.5))
                .foregroundStyle(note == nil ? YYColor.t3 : YYColor.t1)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .animation(.easeOut(duration: 0.2), value: note?.id)
        .accessibilityElement(children: .combine)
    }

    private var divider: some View { Rectangle().fill(YYColor.line).frame(height: 0.5) }

    private func section<Content: View>(_ title: String, trailing: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.yy(size: 12.5, weight: .semibold)).foregroundStyle(YYColor.t1)
                Spacer(minLength: 8)
                Text(trailing).font(.yy(size: 11)).foregroundStyle(YYColor.t3).lineLimit(1)
            }
            content()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.yy(size: 11)).foregroundStyle(YYColor.t3).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 右栏的状态

/// 数据: when the last snapshot was made, what's in it, and the folder they're kept in.
private struct SnapshotCard: View {
    @State private var snapshots: Snapshots

    init(library: Library) { _snapshots = State(initialValue: Snapshots(library: library)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let last = snapshots.saved.first {
                Text(Snapshots.when(last.about.madeAt)).font(.yy(size: 17, weight: .semibold)).foregroundStyle(YYColor.t1)
                Text(([Snapshots.from(last.about)] + (last.about.parts.files ? [String(localized: "含书文件")] : []) + [Snapshots.size(last.about.bytes)]).joined(separator: " · "))
                    .font(.yy(size: 11)).foregroundStyle(YYColor.t3)
            } else {
                Text("还没生成过").font(.yy(size: 13, weight: .medium)).foregroundStyle(YYColor.t2)
                Text("在左边选好放什么，点“生成快照”").font(.yy(size: 11)).foregroundStyle(YYColor.t3)
            }
            Button {
                try? FileManager.default.createDirectory(at: snapshots.folder, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([snapshots.folder])
            } label: {
                RevealInFinderLabel()
            }
            .buttonStyle(SettingsActionStyle())
            .padding(.top, 5)
        }
        .statusCard()
        .task { await snapshots.load() }
    }
}

/// 存储: where the library is on this Mac.
private struct LibraryCard: View {
    let library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(library.dataDir.lastPathComponent).font(.yy(size: 13, weight: .medium)).foregroundStyle(YYColor.t1)
            Text(library.dataDir.deletingLastPathComponent().path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.yy(size: 10.5, design: .monospaced)).foregroundStyle(YYColor.t3)
                .lineLimit(3).truncationMode(.middle)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([library.dataDir])
            } label: {
                RevealInFinderLabel()
            }
            .buttonStyle(SettingsActionStyle())
            .padding(.top, 5)
        }
        .statusCard()
    }
}

private struct RevealInFinderLabel: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder").font(.yy(size: 11.5, weight: .medium))
            Text("在访达中显示")
        }
    }
}

private extension View {
    func statusCard() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(YYColor.card, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(YYColor.line, lineWidth: 0.5))
    }
}

// MARK: - 阅读的样张

/// The opening of 《故乡》 on the paper, in the font, size and spacing chosen.
struct ReadingSample: View {
    let settings: ReaderSettings

    private static let text = ["我冒了严寒，回到相隔二千余里，别了二十余年的故乡去。",
                               "时候既然是深冬；渐近故乡时，天气又阴晦了，冷风吹进船舱中，呜呜的响，从篷隙向外一望，苍黄的天底下，远近横着几个萧索的荒村，没有一些活气。"]

    static func paper(_ s: ReaderSettings) -> YYPaper {
        if let mine = Papers.shared.paper(s.customPaper) { return YYPaper(custom: mine) }
        return YYPaper.all.first { $0.id == s.paperChoice } ?? .plain
    }

    private static func texture(_ s: ReaderSettings) -> PaperTexture {
        if let mine = Papers.shared.paper(s.customPaper) { return mine.texture }
        return paper(s).hasNoiseTexture ? .grain : .none
    }

    static func fontName(_ f: ReaderFont?) -> String {
        switch f {
        case .serif?: String(localized: "宋体")
        case .kai?: String(localized: "楷体")
        case .wenKai?: String(localized: "霞鹜文楷")
        case .sans?: String(localized: "黑体")
        case nil: String(localized: "系统")
        }
    }

    static func summary(_ s: ReaderSettings) -> String {
        "\(paper(s).name) · \(fontName(s.font)) · \(Int(s.fontSize.rounded()))"
    }

    private var font: NSFont {
        // Two thirds of the page's size: the column is a third as wide as a book's.
        let size = (settings.fontSize * 0.68).rounded()
        let name: String? = switch settings.font {
        case .serif?: "Songti SC"
        case .kai?: "Kaiti SC"
        case .wenKai?: WenKai.shared.installed ? "LXGW WenKai Lite" : "Kaiti SC"
        default: nil
        }
        return name.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
    }

    private var page: NSAttributedString {
        let paper = Self.paper(settings)
        let font = font
        let style = NSMutableParagraphStyle()
        let lineHeight = settings.lineHeight ?? paper.text.lineHeight
        style.lineSpacing = font.pointSize * max(0, lineHeight - 1.25)
        style.paragraphSpacing = font.pointSize * 0.5
        style.alignment = settings.justify ?? true ? .justified : .natural
        style.firstLineHeadIndent = settings.indent ?? true ? font.pointSize * 2 : 0
        return NSAttributedString(string: Self.text.joined(separator: "\n"),
                                  attributes: [.font: font, .foregroundColor: NSColor(paper.ink), .paragraphStyle: style])
    }

    var body: some View {
        let paper = Self.paper(settings)
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("故乡")
                Spacer()
                Text("12 / 31").monospacedDigit()
            }
            .font(.yy(size: 9))
            .foregroundStyle(paper.ink.opacity(0.45))
            PageText(string: page)
        }
        .padding(.horizontal, 14).padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 236, alignment: .top)
        .background { paper.bg.overlay { PaperTextureView(texture: Self.texture(settings), dark: paper.isDark) } }
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(YYColor.line, lineWidth: paper.isDark ? 0 : 0.5))
        .animation(.easeOut(duration: 0.2), value: settings)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("样张：\(Self.summary(settings))"))
    }
}

/// Text laid out by AppKit, which justifies and indents as SwiftUI's `Text` can't.
private struct PageText: NSViewRepresentable {
    let string: NSAttributedString

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: string)
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) { field.attributedStringValue = string }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        field.preferredMaxLayoutWidth = width
        let box = string.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: width, height: ceil(box.height))
    }
}

// MARK: - 外文的样张

/// A line of English with the meanings written over the hard words, as the page does.
struct ForeignSample: View {
    let paper: YYPaper
    @AppStorage(ForeignPrefs.glossKey) private var gloss = true
    @AppStorage(ForeignPrefs.levelKey) private var level = 3
    @AppStorage(ForeignPrefs.glossVocabKey) private var vocabOnly = false
    @AppStorage(ForeignPrefs.markKey) private var mark = true

    /// Word, meaning, the easiest list that has it, and whether it's in the 生词本.
    private static let words: [(String, String?, Int, Bool)] = {
        let line = "It was the best of times, it was the worst of times, it was the age of wisdom, it was the age of foolishness, it was the epoch of belief, it was the epoch of incredulity…"
        let meanings: [String: (String, Int, Bool)] = ["wisdom": (String(localized: "智慧"), 2, false), "foolishness": (String(localized: "愚蠢"), 4, false),
                                                       "epoch": (String(localized: "时代"), 5, false), "belief": (String(localized: "信仰"), 3, false),
                                                       "incredulity": (String(localized: "怀疑"), 6, true)]
        return line.split(separator: " ").map { piece in
            let bare = piece.trimmingCharacters(in: .punctuationCharacters)
            let m = meanings[bare]
            return (piece + " ", m?.0, m?.1 ?? 0, m?.2 ?? false)
        }
    }()

    static var summary: String {
        guard ForeignPrefs.glosses else { return String(localized: "不写释义") }
        if ForeignPrefs.glossVocabOnly { return String(localized: "只写生词本里的") }
        let name = ForeignPrefs.levels.first { $0.level == ForeignPrefs.level }?.name ?? ""
        return String(localized: "\(name)及以上")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WordFlow(lineSpacing: 5) {
                ForEach(Array(Self.words.enumerated()), id: \.offset) { _, w in
                    let shown = gloss && w.1 != nil && (vocabOnly ? w.3 : w.2 >= level)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(shown ? w.1! : " ")
                            .font(.yy(size: 8.5))
                            .foregroundStyle(paper.paperAccent)
                        Text(w.0)
                            .font(.custom("Georgia", size: 13))
                            .foregroundStyle(paper.ink)
                            .overlay(alignment: .bottomLeading) {
                                if mark && w.3 {
                                    // The 生词's dashed line, under the word and not the space after it.
                                    Text(w.0.trimmingCharacters(in: .whitespaces)).font(.custom("Georgia", size: 13)).hidden()
                                        .overlay(alignment: .bottom) {
                                            Line().stroke(paper.ink.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(height: 1)
                                        }
                                }
                            }
                    }
                    .fixedSize()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(paper.bg, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(YYColor.line, lineWidth: paper.isDark ? 0 : 0.5))
            .animation(.snappy(duration: 0.2), value: "\(gloss)\(level)\(vocabOnly)\(mark)")
            Text(caption).font(.yy(size: 11)).foregroundStyle(YYColor.t3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var caption: String {
        var parts: [String] = []
        if !gloss { parts.append(String(localized: "难词上方不写释义")) }
        if mark { parts.append(String(localized: "虚线是生词本里的词")) }
        return parts.isEmpty ? String(localized: "生词不标") : parts.joined(separator: "；")
    }

    private nonisolated struct Line: Shape {
        func path(in rect: CGRect) -> Path { Path { $0.move(to: CGPoint(x: 0, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) } }
    }
}

/// Words left to right, onto the next line when one doesn't fit.
private struct WordFlow: Layout {
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 220
        return CGSize(width: width, height: place(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, at) in zip(subviews, place(subviews, width: bounds.width).points) {
            view.place(at: CGPoint(x: bounds.minX + at.x, y: bounds.minY + at.y), proposal: .unspecified)
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += line + lineSpacing
                line = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width
            line = max(line, size.height)
        }
        return (points, y + line)
    }
}

// MARK: - 最近改过

/// Every change made in 设置, kept across launches (the last 40), each one undoable: a
/// preference in UserDefaults goes back to what it was; a reading setting is written back to the
/// core. Changes are noticed rather than reported, so a page needs no code of its own.
@MainActor @Observable
final class SettingsLog {
    static let shared = SettingsLog()

    enum Value: Codable, Equatable {
        case bool(Bool), double(Double), int(Int), string(String), none
    }

    enum Undo: Codable, Equatable {
        case defaults(key: String, old: Value)
        case reader(field: String, old: String)
    }

    /// How 最近改过 draws a value: a dot of the colour, the font's own letters, a little switch,
    /// a voice that can be heard; plain words otherwise.
    enum Look: String, Codable {
        case tint, paper, font, toggle, voice
    }

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var date: Date
        let title: String
        var to: String
        let from: String
        var undo: Undo?
        /// Taken back: kept, faded, with 再改过来.
        var undone: Bool?
        /// The 设置 page it was changed on (SettingsPage's raw value); older entries have none.
        var page: String?
        var look: Look?
        /// The values themselves (an id, "1"/"0"), for drawing them.
        var fromRaw: String?
        var toRaw: String?
        /// What 再改过来 writes back, once it has been taken back.
        var redo: Undo?
    }

    private(set) var entries: [Entry] = []
    /// The change just made, for 已存 to say for a moment.
    var flash: Entry?
    /// For writing a reading setting back.
    @ObservationIgnored var library: Library?
    @ObservationIgnored private var snapshot: [String: Value] = [:]
    /// A value is being put back, not changed.
    @ObservationIgnored private var restoring = false

    private static let storeKey = "settings.log"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
        snapshot = Self.read()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SettingsLog.shared.defaultsChanged() }
        }
    }

    // MARK: Preferences

    private struct Watched {
        enum Kind { case bool, double, int, string }
        let title: String
        let kind: Kind
        /// What @AppStorage shows while the key was never written.
        let standard: Value
        var format: ((Value) -> String)?

        func text(_ value: Value) -> String {
            let v = value == .none ? standard : value
            if let format { return format(v) }
            switch v {
            case .bool(let b): return b ? String(localized: "开") : String(localized: "关")
            case .double(let d): return d.formatted()
            case .int(let i): return "\(i)"
            case .string(let s): return s
            case .none: return ""
            }
        }
    }

    private static let watched: [String: Watched] = [
        "general.reopenLast": Watched(title: String(localized: "接着读上次那本"), kind: .bool, standard: .bool(false)),
        "general.keepAwake": Watched(title: String(localized: "听书时不睡着"), kind: .bool, standard: .bool(true)),
        AppAppearance.key: Watched(title: String(localized: "界面"), kind: .string, standard: .string(AppAppearance.system.rawValue)) {
            if case .string(let s) = $0 { AppAppearance(rawValue: s)?.title ?? s } else { "" }
        },
        "shelf.coverSize": Watched(title: String(localized: "封面大小"), kind: .double, standard: .double(100)) {
            if case .double(let d) = $0 { "\(Int(d))" } else { "" }
        },
        "shelf.showProgress": Watched(title: String(localized: "封面下写进度"), kind: .bool, standard: .bool(true)),
        LiquidGlass.key: Watched(title: String(localized: "液态玻璃"), kind: .bool, standard: .bool(true)),
        "reader.twoColumns": Watched(title: String(localized: "分两栏"), kind: .bool, standard: .bool(true)),
        ImmersivePrefs.alwaysKey: Watched(title: String(localized: "打开书就进沉浸"), kind: .bool, standard: .bool(false)),
        ImmersivePrefs.lineKey: Watched(title: String(localized: "进度细线"), kind: .bool, standard: .bool(true)),
        ImmersivePrefs.marksKey: Watched(title: String(localized: "沉浸时隐藏划线"), kind: .bool, standard: .bool(false)),
        ImmersivePrefs.hintsKey: Watched(title: String(localized: "沉浸时关掉提示"), kind: .bool, standard: .bool(true)),
        ImmersivePrefs.stillKey: Watched(title: String(localized: "关掉翻页动画"), kind: .bool, standard: .bool(true)),
        "companion.provider": Watched(title: String(localized: "书伴用"), kind: .string, standard: .string(CompanionProvider.apple.id)) {
            if case .string(let s) = $0 { s == CompanionProvider.apple.id ? String(localized: "这台 Mac") : CompanionProvider.find(s)?.title ?? s } else { "" }
        },
        "player.voice.zh": Watched(title: String(localized: "中文声音"), kind: .string, standard: .string("")) {
            if case .string(let s) = $0, !s.isEmpty { Voices.find(s)?.name ?? s } else { String(localized: "自动") }
        },
        "player.voice.en": Watched(title: String(localized: "英文声音"), kind: .string, standard: .string("")) {
            if case .string(let s) = $0, !s.isEmpty { Voices.find(s)?.name ?? s } else { String(localized: "自动") }
        },
        "player.rate": Watched(title: String(localized: "语速"), kind: .double, standard: .double(1)) {
            if case .double(let d) = $0 { String(format: "%.1f×", d == 0 ? 1 : d) } else { "" }
        },
        ForeignPrefs.speakKey: Watched(title: String(localized: "点词时读出来"), kind: .bool, standard: .bool(true)),
        ForeignPrefs.accentKey: Watched(title: String(localized: "英文发音"), kind: .string, standard: .string(ForeignPrefs.Accent.british.rawValue)) {
            if case .string(let s) = $0 { s == ForeignPrefs.Accent.american.rawValue ? String(localized: "美音") : String(localized: "英音") } else { "" }
        },
        ForeignPrefs.markKey: Watched(title: String(localized: "标出生词"), kind: .bool, standard: .bool(true)),
        ForeignPrefs.glossKey: Watched(title: String(localized: "难词释义"), kind: .bool, standard: .bool(true)),
        ForeignPrefs.levelKey: Watched(title: String(localized: "难词级别"), kind: .int, standard: .int(3)) {
            if case .int(let i) = $0 { ForeignPrefs.levels.first { Int($0.level) == i }?.name ?? "\(i)" } else { "" }
        },
        ForeignPrefs.glossVocabKey: Watched(title: String(localized: "只标生词本里的"), kind: .bool, standard: .bool(false)),
        Podcasts.keepHeardKey: Watched(title: String(localized: "听过的节目一直保留"), kind: .bool, standard: .bool(false)),
    ]

    /// The page each preference is on, and how its value is drawn.
    private static let places: [String: (SettingsPage, Look?)] = [
        "general.reopenLast": (.general, .toggle), "general.keepAwake": (.general, .toggle),
        AppAppearance.key: (.appearance, nil),
        "shelf.coverSize": (.appearance, nil), "shelf.showProgress": (.appearance, .toggle), LiquidGlass.key: (.appearance, .toggle),
        "reader.twoColumns": (.reading, .toggle), ImmersivePrefs.alwaysKey: (.reading, .toggle), ImmersivePrefs.lineKey: (.reading, .toggle),
        ImmersivePrefs.marksKey: (.reading, .toggle), ImmersivePrefs.hintsKey: (.reading, .toggle), ImmersivePrefs.stillKey: (.reading, .toggle),
        "companion.provider": (.companion, nil),
        "player.rate": (.listening, nil), "player.voice.zh": (.listening, .voice), "player.voice.en": (.listening, .voice),
        Podcasts.keepHeardKey: (.listening, .toggle),
        ForeignPrefs.speakKey: (.foreign, .toggle), ForeignPrefs.accentKey: (.foreign, nil), ForeignPrefs.markKey: (.foreign, .toggle),
        ForeignPrefs.glossKey: (.foreign, .toggle), ForeignPrefs.levelKey: (.foreign, nil), ForeignPrefs.glossVocabKey: (.foreign, .toggle),
    ]

    private static func raw(_ v: Value, _ w: Watched) -> String {
        switch v == .none ? w.standard : v {
        case .bool(let b): b ? "1" : "0"
        case .double(let d): "\(d)"
        case .int(let i): "\(i)"
        case .string(let s): s
        case .none: ""
        }
    }

    private static func read() -> [String: Value] {
        let d = UserDefaults.standard
        var now: [String: Value] = [:]
        for (key, w) in watched {
            guard let object = d.object(forKey: key) else { now[key] = Value.none; continue }
            switch w.kind {
            case .bool: now[key] = (object as? Bool).map(Value.bool) ?? .none
            case .double: now[key] = (object as? NSNumber).map { .double($0.doubleValue) } ?? .none
            case .int: now[key] = (object as? NSNumber).map { .int($0.intValue) } ?? .none
            case .string: now[key] = (object as? String).map(Value.string) ?? .none
            }
        }
        return now
    }

    private func defaultsChanged() {
        guard !restoring else { return }
        let now = Self.read()
        guard now != snapshot else { return }
        // Before recording: saving the log is itself a change of defaults, which comes straight
        // back here, and would record this again, without end, if the snapshot were still old.
        let before = snapshot
        snapshot = now
        for (key, w) in Self.watched {
            guard let new = now[key], let old = before[key], new != old else { continue }
            // Written but no different, as when a key is first stored with its default.
            guard w.text(new) != w.text(old) else { continue }
            let place = Self.places[key]
            record(title: w.title, to: w.text(new), from: w.text(old), undo: .defaults(key: key, old: old),
                   page: place?.0, look: place?.1, fromRaw: Self.raw(old, w), toRaw: Self.raw(new, w))
        }
    }

    // MARK: Reading settings

    private enum ReaderField: String, CaseIterable {
        case paper, font, size, lineHeight, mode, justify, indent, compress

        var title: String {
            switch self {
            case .paper: String(localized: "纸色")
            case .font: String(localized: "字体")
            case .size: String(localized: "字号")
            case .lineHeight: String(localized: "行距")
            case .mode: String(localized: "翻页方式")
            case .justify: String(localized: "两端对齐")
            case .indent: String(localized: "首行缩进")
            case .compress: String(localized: "标点挤压")
            }
        }

        private static let fonts: [ReaderFont] = [.sans, .serif, .kai, .wenKai]

        func value(_ s: ReaderSettings) -> String {
            switch self {
            case .paper: s.paperChoice
            case .font: s.font.map { "\($0)" } ?? ""
            case .size: "\(Int(s.fontSize.rounded()))"
            case .lineHeight: s.lineHeight.map { "\($0)" } ?? ""
            case .mode: s.mode == .scrolled ? "scrolled" : "paginated"
            case .justify: s.justify ?? true ? "1" : "0"
            case .indent: s.indent ?? true ? "1" : "0"
            case .compress: s.compress ? "1" : "0"
            }
        }

        func show(_ v: String) -> String {
            switch self {
            case .paper: YYPaper.all.first { $0.id == v }?.name ?? Papers.shared.paper(v)?.name ?? v
            case .font: ReadingSample.fontName(Self.fonts.first { "\($0)" == v })
            case .size: v
            case .lineHeight: ["1.6": String(localized: "紧"), "": String(localized: "适中"), "2.2": String(localized: "松")][v] ?? v
            case .mode: v == "scrolled" ? String(localized: "上下滚动") : String(localized: "左右翻页")
            case .justify, .indent, .compress: v == "1" ? String(localized: "开") : String(localized: "关")
            }
        }

        func apply(_ v: String, to s: inout ReaderSettings) {
            switch self {
            case .paper:
                if let preset = Paper(id: v) {
                    s.paper = preset
                    s.customPaper = nil
                } else if let mine = Papers.shared.paper(v) {
                    s.customPaper = v
                    s.paper = paperColors(paper: mine).preset
                }
            case .font: s.font = Self.fonts.first { "\($0)" == v }
            case .size: if let d = Double(v) { s.fontSize = d }
            case .lineHeight: s.lineHeight = Double(v)
            case .mode: s.mode = v == "scrolled" ? .scrolled : .paginated
            case .justify: s.justify = v == "1"
            case .indent: s.indent = v == "1"
            case .compress: s.compress = v == "1"
            }
        }
    }

    /// 设置 · 阅读 changed the reading settings from `old` to `new`.
    func reader(from old: ReaderSettings, to new: ReaderSettings) {
        for f in ReaderField.allCases {
            let a = f.value(old), b = f.value(new)
            guard a != b else { continue }
            let look: Look? = switch f {
            case .paper: .paper
            case .font: .font
            case .justify, .indent, .compress: .toggle
            default: nil
            }
            record(title: f.title, to: f.show(b), from: f.show(a), undo: .reader(field: f.rawValue, old: a),
                   page: .reading, look: look, fromRaw: a, toRaw: b)
        }
    }

    // MARK: Keeping and undoing

    func record(title: String, to: String, from: String, undo: Undo,
                page: SettingsPage? = nil, look: Look? = nil, fromRaw: String? = nil, toRaw: String? = nil) {
        // Dragging a slider is one change, not one per step; dragged back, it's none.
        if let first = entries.first, first.title == title, first.undone != true, Date.now.timeIntervalSince(first.date) < 90 {
            if first.from == to {
                entries.removeFirst()
            } else {
                entries[0].to = to
                entries[0].toRaw = toRaw
                entries[0].date = .now
            }
        } else {
            entries.insert(Entry(date: .now, title: title, to: to, from: from, undo: undo,
                                 page: (page ?? currentPage)?.rawValue, look: look, fromRaw: fromRaw, toRaw: toRaw), at: 0)
        }
        entries = Array(entries.prefix(40))
        flash = Entry(date: .now, title: title, to: to, from: from)
        save()
    }

    /// The page 设置 shows, for a change that doesn't say where it was made.
    private var currentPage: SettingsPage? {
        UserDefaults.standard.string(forKey: "settings.page").flatMap(SettingsPage.init(rawValue:))
    }

    /// 改回: writes the old value back; the entry stays, faded, so it can be made again.
    func undo(_ entry: Entry) {
        guard let undo = entry.undo, entry.undone != true, let at = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[at].redo = current(for: undo)
        entries[at].undone = true
        write(undo)
        flash = Entry(date: .now, title: entry.title, to: entry.from, from: entry.to)
        save()
    }

    /// 再改过来: what was taken back, back again.
    func redo(_ entry: Entry) {
        guard let redo = entry.redo, entry.undone == true, let at = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[at].undone = false
        entries[at].redo = nil
        write(redo)
        flash = Entry(date: .now, title: entry.title, to: entry.to, from: entry.from)
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    /// What `undo` would overwrite, to put back with 再改过来.
    private func current(for undo: Undo) -> Undo? {
        switch undo {
        case .defaults(let key, _):
            return .defaults(key: key, old: Self.read()[key] ?? Self.value(of: key))
        case .reader(let field, _):
            guard let s = try? library?.core.readerSettings(), let f = ReaderField(rawValue: field) else { return nil }
            return .reader(field: field, old: f.value(s))
        }
    }

    /// A key's value though it isn't watched (书伴's models).
    private static func value(of key: String) -> Value {
        switch UserDefaults.standard.object(forKey: key) {
        case let b as Bool: .bool(b)
        case let s as String: .string(s)
        case let n as NSNumber: .double(n.doubleValue)
        default: .none
        }
    }

    private func write(_ undo: Undo) {
        switch undo {
        case .defaults(let key, let old):
            let d = UserDefaults.standard
            // Each write below reports straight back to defaultsChanged, before the snapshot
            // can be brought up to date.
            restoring = true
            defer { restoring = false }
            switch old {
            case .bool(let b): d.set(b, forKey: key)
            case .double(let v): d.set(v, forKey: key)
            case .int(let i): d.set(i, forKey: key)
            case .string(let s): d.set(s, forKey: key)
            case .none: d.removeObject(forKey: key)
            }
            // Put back, not changed: no new entry for it.
            snapshot = Self.read()
            if key == AppAppearance.key { AppAppearance.apply() }
        case .reader(let field, let old):
            guard let core = library?.core, var s = try? core.readerSettings(), let f = ReaderField(rawValue: field) else { break }
            f.apply(old, to: &s)
            try? core.setReaderSettings(settings: s)
            NotificationCenter.default.post(name: .readerSettingsChanged, object: nil)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
    }
}

// MARK: - 纸和字的方块

/// A paper to choose: a strip of it with two lines of its ink, its name under it.
struct SettingsPaperTile: View {
    let paper: YYPaper
    var texture: PaperTexture = .none
    let name: String
    let selected: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(paper.ink.opacity(0.5)).frame(width: 28, height: 2)
                    Capsule().fill(paper.ink.opacity(0.5)).frame(width: 20, height: 2)
                }
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background { paper.bg.overlay { PaperTextureView(texture: texture, dark: paper.isDark) } }
                .clipShape(.rect(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(paper.isDark ? 0 : 0.12), lineWidth: 0.5))
                Text(name)
                    .font(.yy(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? YYColor.t1 : YYColor.t2)
                    .lineLimit(1)
            }
            .settingsTile(selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A font to choose: 永 in it, its name under it.
struct SettingsFontTile: View {
    let font: ReaderFont?
    let selected: Bool
    let pick: () -> Void

    private var face: SwiftUI.Font {
        switch font {
        case .serif?: .custom("Songti SC", size: 22)
        case .kai?: .custom("Kaiti SC", size: 22)
        case .wenKai?: WenKai.shared.installed ? .custom("LXGW WenKai Lite", size: 22) : .custom("Kaiti SC", size: 22)
        default: .system(size: 21)
        }
    }

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 3) {
                Text("永").font(face).foregroundStyle(YYColor.t1).frame(height: 30)
                Text(ReadingSample.fontName(font))
                    .font(.yy(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? YYColor.t1 : YYColor.t2)
                    .lineLimit(1)
            }
            .settingsTile(selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(ReadingSample.fontName(font)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension View {
    /// `.tile`: a hairline box, the chosen one ringed in the theme colour.
    func settingsTile(selected: Bool) -> some View {
        padding(.horizontal, 6).padding(.top, 9).padding(.bottom, 7)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? YYTint.standard.accent : YYColor.line, lineWidth: selected ? 1.5 : 0.5))
            .contentShape(.rect(cornerRadius: 9))
            .animation(.easeOut(duration: 0.15), value: selected)
    }
}

#endif
