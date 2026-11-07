#if os(macOS)
import SwiftUI
import AVFoundation

/// 设置 · 朗读 (prototypes/drafts/设置-换声音-置顶.html): first where the voices come from, a row
/// for this Mac and each cloud; one opened, its voices as voice messages that each say the line
/// you sent. Clicking only plays; 选择 (on hover, or in the right column) makes it read that kind
/// of book. The one reading is pinned at the top.
struct ListeningPage: View {
    @AppStorage("player.rate") private var rate = 1.0
    private var focus: ListeningFocus { .shared }

    var body: some View {
        let _ = focus.tick
        Group {
            if let source = focus.source {
                VoiceSourcePage(source: source)
            } else {
                sources
            }
        }
        .onAppear {
            SystemVoice.watch()
            focus.reload()
            #if DEBUG
            // `-debugCloudVoice openai|azure|elevenlabs` opens that one in the right column;
            // `-debugVoiceSource mac|openai|…` opens its voices; `-debugVoiceMacPanel 1` this Mac's
            // panel. Once, or ‹ could never leave.
            if !focus.debugApplied {
                focus.debugApplied = true
                if let d = UserDefaults.standard.string(forKey: "debugCloudVoice") { focus.page = CloudVoice.Provider(rawValue: d) }
                if let d = UserDefaults.standard.string(forKey: "debugVoiceSource") { focus.source = VoiceSource(rawValue: d) }
                if UserDefaults.standard.bool(forKey: "debugVoiceMacPanel") { focus.macPanel = true }
            }
            #endif
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline) {
                SettingsHeading(String(localized: "声音来源"))
                Spacer(minLength: 8)
                Text("点一个，进去听它的声音").font(.yy(size: 11)).foregroundStyle(YYColor.t3)
            }
            .padding(.bottom, -2)
            FlatCard {
                ForEach(Array(VoiceSource.all.enumerated()), id: \.element) { i, s in
                    if i > 0 { Rectangle().fill(YYColor.line).frame(height: 0.5).padding(.leading, 53).padding(.trailing, 9) }
                    SourceRow(source: s)
                }
            }
            SettingsNote(String(localized: "云端的填你自己的 Key，费用走你的账号，语阅不经手。念过的句子存在这台 Mac 上，再听不花钱。"))
            SettingsHeading(String(localized: "语速"))
            FlatCard {
                HStack(spacing: 8) {
                    Text("慢").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
                    Slider(value: Binding(get: { rate == 0 ? 1 : rate }, set: { rate = ($0 * 10).rounded() / 10 }), in: 0.8 ... 2.0)
                        .frame(width: 150)
                        .tint(YYColor.t1)
                    Text("快").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
                    rateMenu
                    Spacer(minLength: 8)
                    Text("读书窗口里调的也是这一个").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3).lineLimit(1)
                }
                .padding(.horizontal, 9)
                .frame(height: 40)
            }
            Spacer(minLength: 0)
        }
    }

    /// The value doubles as a menu of the reading window's marks, plus wherever the slider left it.
    private var rateMenu: some View {
        let current = rate == 0 ? 1 : rate
        let marks = [0.8, 1.0, 1.2, 1.5, 2.0]
        let choices = marks.contains { abs($0 - current) < 0.05 } ? marks : (marks + [current]).sorted()
        return Menu {
            ForEach(choices, id: \.self) { r in
                Toggle(String(format: "%.1f×", r), isOn: Binding(get: { abs(r - current) < 0.05 }, set: { _ in rate = r }))
            }
        } label: {
            HStack(spacing: 4) {
                Text(String(format: "%.1f×", current)).monospacedDigit()
                    .font(.yy(size: 12, weight: .semibold)).foregroundStyle(YYColor.t1)
                Image(systemName: "chevron.up.chevron.down").font(.yy(size: 8.5, weight: .semibold)).foregroundStyle(YYColor.t3)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.leading, 6)
    }
}

/// A path in an SVG's own numbers, scaled to the frame's width: the marks drawn for this page.
nonisolated struct SVGShape: Shape {
    let d: String
    var box: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let k = rect.width / box
        return Self.parse(d).applying(CGAffineTransform(scaleX: k, y: k).translatedBy(x: rect.minX / k, y: rect.minY / k))
    }

    /// M L H V C Z, either case, numbers run together as SVGs write them.
    private static func parse(_ d: String) -> Path {
        var path = Path()
        var at = CGPoint.zero, start = CGPoint.zero
        let chars = Array(d)
        var i = 0
        var cmd: Character = "M"
        func number() -> CGFloat {
            while i < chars.count, chars[i] == " " || chars[i] == "," { i += 1 }
            let from = i
            if i < chars.count, chars[i] == "-" { i += 1 }
            var dot = false
            while i < chars.count, chars[i].isNumber || (chars[i] == "." && !dot) {
                if chars[i] == "." { dot = true }
                i += 1
            }
            return CGFloat(Double(String(chars[from ..< i])) ?? 0)
        }
        while true {
            while i < chars.count, chars[i] == " " || chars[i] == "," { i += 1 }
            guard i < chars.count else { break }
            if chars[i].isLetter { cmd = chars[i]; i += 1 }
            let rel = cmd.isLowercase
            let base = rel ? at : .zero
            switch cmd.uppercased() {
            case "M":
                let x = number(), y = number()
                at = CGPoint(x: base.x + x, y: base.y + y)
                start = at
                path.move(to: at)
                cmd = rel ? "l" : "L"
            case "L":
                let x = number(), y = number()
                at = CGPoint(x: base.x + x, y: base.y + y)
                path.addLine(to: at)
            case "H":
                at.x = base.x + number()
                path.addLine(to: at)
            case "V":
                at.y = base.y + number()
                path.addLine(to: at)
            case "C":
                let x1 = number(), y1 = number(), x2 = number(), y2 = number(), x = number(), y = number()
                let end = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: end, control1: CGPoint(x: base.x + x1, y: base.y + y1), control2: CGPoint(x: base.x + x2, y: base.y + y2))
                at = end
            default:
                path.closeSubpath()
                at = start
            }
        }
        return path
    }
}

/// The marks of this page, as the prototype draws them.
enum VoiceGlyph {
    static let pin = "M9.6 1.9l4.5 4.5-1.2.5-2.7 2.7.4 3.1-1.1 1.1-2.9-2.9-3.7 3.7-.7-.7 3.7-3.7L3 7.3l1.1-1.1 3.1.4 2.7-2.7z"
    static let pinHead = "M9.6 1.9l4.5 4.5-1.2.5-2.7 2.7.4 3.1-1.1 1.1-6.8-6.8L4.8 6l3.1.4 2.7-2.7z"
    static let pinStem = "M5.6 10.4l-3.3 3.3"
    static let quote = "M3.2 9.6c0-2.6 1.4-4.5 3.6-5.4l.5 1c-1.2.6-1.9 1.5-2 2.7h1.9v3.6H3.2zm5.6 0c0-2.6 1.4-4.5 3.6-5.4l.5 1c-1.2.6-1.9 1.5-2 2.7h1.9v3.6H8.8z"
    static let play = "M2.8 1.4v7.2l6-3.6z"
    static let playLarge = "M2.5 1.2v7.6l6.3-3.8z"
    static let pause = "M2 1.5h2.2v7H2zM5.8 1.5H8v7H5.8z"
    static let tick = "M2 6.5l2.6 2.5L10 3.2"
    static let send = "M6 10V2M2.5 5.5L6 2l3.5 3.5"
    static let rays = "M8 1.8v1.6M8 12.6v1.6M1.8 8h1.6M12.6 8h1.6M3.6 3.6l1.1 1.1M11.3 11.3l1.1 1.1M3.6 12.4l1.1-1.1M11.3 4.7l1.1-1.1"
    static let back = "M6 2L2 6l4 4"
    static let chevron = "M2 2l4 4-4 4"
}

/// The little pin; `head`: the badge's, with its stem drawn apart.
private struct PinGlyph: View {
    let size: CGFloat
    var badge = false

    var body: some View {
        ZStack {
            if badge {
                SVGShape(d: VoiceGlyph.pinHead).fill()
                SVGShape(d: VoiceGlyph.pinStem).stroke(style: StrokeStyle(lineWidth: 1.3 * size / 16, lineCap: .round))
            } else {
                SVGShape(d: VoiceGlyph.pin).fill()
            }
        }
        .frame(width: size, height: size)
    }
}

/// ▶ / ❚❚ in a box of ten.
private struct PlayGlyph: View {
    let playing: Bool
    let size: CGFloat
    var large = false

    var body: some View {
        SVGShape(d: playing ? VoiceGlyph.pause : large ? VoiceGlyph.playLarge : VoiceGlyph.play, box: 10)
            .fill()
            .frame(width: size, height: size)
    }
}

/// A CSS shadow with a negative spread: narrower than what casts it, so it shows only below.
/// `.shadow` can't do that; it glows on every side.
private extension View {
    /// A hairline outside the edge, as `box-shadow: 0 0 0 .5px` draws it: strokeBorder would take
    /// half a point off everything it goes round.
    func ring(_ color: Color, radius: CGFloat) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius).inset(by: -0.25).stroke(color, lineWidth: 0.5).allowsHitTesting(false))
    }

    func spreadShadow(_ color: Color, y: CGFloat, blur: CGFloat, spread: CGFloat, radius: CGFloat) -> some View {
        background {
            RoundedRectangle(cornerRadius: max(0, radius - spread)).fill(color)
                .padding(spread).offset(y: y).blur(radius: blur / 2)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Where voices come from

/// This Mac, or one of the clouds.
enum VoiceSource: Hashable {
    case mac
    case cloud(CloudVoice.Provider)

    static var all: [VoiceSource] { [.mac] + CloudVoice.Provider.allCases.map { .cloud($0) } }

    init?(rawValue: String) {
        if rawValue == "mac" { self = .mac } else if let p = CloudVoice.Provider(rawValue: rawValue) { self = .cloud(p) } else { return nil }
    }

    var title: String {
        switch self {
        case .mac: String(localized: "这台 Mac")
        case .cloud(let p): p.title
        }
    }

    var isSetUp: Bool {
        switch self {
        case .mac: true
        case .cloud(let p): p.isSetUp
        }
    }

    var mark: ServiceTile.Mark {
        switch self {
        case .mac: .laptop
        case .cloud(let p): .cloud(p)
        }
    }

    /// Its voices that read `tag`.
    func voices(for tag: String) -> [any Voice] {
        switch self {
        case .mac: SystemVoice.all(for: tag)
        case .cloud(let p): CloudVoice.all().filter { $0.provider == p && $0.speaks(tag) }
        }
    }

    var voiceCount: Int {
        switch self {
        case .mac: Set(SystemVoice.all(for: "zh").map(\.id) + SystemVoice.all(for: "en").map(\.id)).count
        case .cloud(let p): p.voiceCount
        }
    }

    static func of(_ voice: any Voice) -> VoiceSource {
        if let c = voice as? CloudVoice { return .cloud(c.provider) }
        return .mac
    }
}

/// The two kinds of book a voice is chosen for.
enum VoiceBook: String, CaseIterable, Identifiable {
    case zh, en
    var id: String { rawValue }
    var key: String { "player.voice." + rawValue }
    var title: String { self == .zh ? String(localized: "中文书") : String(localized: "英文书") }
    var line: String {
        self == .zh ? "我冒了严寒，回到相隔二千余里，别了二十余年的故乡去。" : "It was the best of times, it was the worst of times."
    }

    /// The voice reading it: the one chosen, or the best this Mac has.
    var current: (any Voice)? {
        let id = UserDefaults.standard.string(forKey: key) ?? ""
        if !id.isEmpty, let v = Voices.find(id), v.speaks(rawValue) { return v }
        return SystemVoice.best(for: rawValue)
    }

    func choose(_ voice: any Voice) {
        UserDefaults.standard.set(voice.id, forKey: key)
    }

    /// Lines to try a voice on, for the “ at the start of the box.
    var quickLines: [(name: String, line: String)] {
        self == .zh
            ? [(String(localized: "叙述"), line), (String(localized: "对话"), "“这是谁？”我问。“这是闰土呀，你忘了么？”"),
               (String(localized: "数字"), "第 12 章，1986 年 3 月 4 日，下午 3:40。"), (String(localized: "中英夹杂"), "Hello，今天读到 Chapter 3 了。")]
            : [("Narration", line), ("Dialogue", "\"Is it you?\" she asked. \"Of course it is,\" he said."), ("Numbers", "Chapter 12, page 304: the year was 1859.")]
    }

    /// Put in the box for you to change, not sent.
    var bookLine: (hint: String, line: String) {
        self == .zh ? ("从《故乡》里随手取一句", "时候既然是深冬；渐近故乡时，天气又阴晦了。")
            : ("A line from Pride and Prejudice", "It is a truth universally acknowledged.")
    }
}

/// White, a hairline, no shadow.
private struct FlatCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(3)
            .background(YYColor.card, in: .rect(cornerRadius: 12))
            .ring(YYColor.line, radius: 12)
    }
}

/// A row of 声音来源: its tile, name, how many voices; which books it reads at the end.
private struct SourceRow: View {
    let source: VoiceSource
    @State private var hovering = false
    private var focus: ListeningFocus { .shared }

    var body: some View {
        let _ = SettingsLog.shared.entries
        let on = source.isSetUp
        let reads = VoiceBook.allCases.compactMap { b in b.current.flatMap { VoiceSource.of($0) == source ? (b, $0) : nil } }
        let selected: Bool = { if case .cloud(let p) = source { focus.page == p } else { false } }()
        Button {
            if on {
                focus.page = nil
                focus.open(source)
            } else if case .cloud(let p) = source {
                focus.page = p
            }
        } label: {
            HStack(spacing: 12) {
                ServiceTile(mark: source.mark, size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(source.title).font(.yy(size: 13, weight: .medium)).foregroundStyle(YYColor.t1)
                    Group {
                        switch source {
                        case .mac: Text("\(source.voiceCount) 个声音 · 免费，不联网")
                        case .cloud(let p): Text(on ? String(localized: "\(source.voiceCount) 个声音 · 已连上") : p.blurb)
                        }
                    }
                    .font(.yy(size: 11)).foregroundStyle(YYColor.t3).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    ForEach(reads, id: \.0) { b, v in
                        Label("\(b.title) · \(v.name)", systemImage: "pin.fill")
                            .labelStyle(PinLabelStyle())
                            .font(.yy(size: 11)).foregroundStyle(YYColor.t2).lineLimit(1)
                    }
                }
                HStack(spacing: 8) {
                    if !on { Text("填 Key").font(.yy(size: 11.5)).foregroundStyle(YYColor.t3) }
                    SVGShape(d: VoiceGlyph.chevron, box: 8)
                        .stroke(YYColor.t3, style: StrokeStyle(lineWidth: 1.6 * 7 / 8, lineCap: .round, lineJoin: .round))
                        .frame(width: 7, height: 11)
                }
                .padding(.leading, 6)
            }
            .padding(.leading, 10).padding(.trailing, 12)
            .frame(height: 58)
            .background(selected ? YYColor.t1.opacity(0.055) : hovering ? YYColor.t1.opacity(0.035) : .clear, in: .rect(cornerRadius: 9))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A small pin before the words, tighter than a Label's own.
struct PinLabelStyle: LabelStyle {
    var size: CGFloat = 9

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            PinGlyph(size: size)
            configuration.title
        }
    }
}

// MARK: - One source's voices

/// ‹, the sources as tabs, ⚙ (its key in the right column); 中文书 / 英文书; the one reading, pinned;
/// then your line and every other voice as voice messages, which alone scroll; the box to send
/// them another line.
private struct VoiceSourcePage: View {
    let source: VoiceSource
    @State private var scrolled = false
    @State private var linesOpen = false
    @State private var draft = ""
    @FocusState private var typing: Bool
    private var focus: ListeningFocus { .shared }

    var body: some View {
        let _ = focus.tick
        // ⌘Z or 最近改过 can change who's reading from outside this page.
        let _ = SettingsLog.shared.entries
        let book = focus.book
        let current = book.current
        let voices = source.voices(for: book.rawValue).filter { $0.id != current?.id }
        let groups = VoiceGroup.groups(voices)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SquareBackButton(help: String(localized: "回到声音来源")) { focus.close() }
                SourceTabs(selection: source)
                Spacer(minLength: 8)
                gear
            }
            HStack {
                BookSegments(selection: book) { focus.book = $0; focus.listening = nil; Voices.stopPreview() }
                Spacer(minLength: 8)
                Text("点语音听，指着点“选择”").font(.yy(size: 11)).foregroundStyle(YYColor.t3)
            }
            .padding(.top, 12).padding(.bottom, 8)
            if let current { PinnedVoice(voice: current, book: book, elsewhere: VoiceSource.of(current) != source).padding(.bottom, 6) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        YourLine(text: focus.line(book)).padding(.top, 4).padding(.bottom, 6)
                        if voices.isEmpty {
                            Text("\(source.title) 没有别的\(book.title)声音了")
                                .font(.yy(size: 11)).foregroundStyle(YYColor.t3).frame(maxWidth: .infinity).padding(.top, 8)
                        } else {
                            ForEach(groups, id: \.title) { g in
                                DayLine(title: g.title)
                                ForEach(g.voices, id: \.id) { v in VoiceMessage(voice: v, book: book).id(v.id) }
                            }
                        }
                    }
                    .padding(.top, 6).padding(.bottom, 6)
                }
                .scrollIndicators(.never)
                .id(source)
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 2 } action: { _, now in scrolled = now }
                .mask {
                    // Only once scrolled, so your line isn't faded where it rests.
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(scrolled ? 0 : 1), .black], startPoint: .top, endPoint: .bottom).frame(height: 26)
                        Rectangle()
                    }
                }
                .onChange(of: focus.listening) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }
            VoiceComposer(book: book, draft: $draft, linesOpen: $linesOpen, typing: $typing).padding(.top, 8)
        }
        .overlay {
            if linesOpen {
                Color.clear.contentShape(.rect).onTapGesture { linesOpen = false }
                QuickLines(book: book, send: { linesOpen = false; send($0) }, fill: {
                    linesOpen = false
                    draft = $0
                    typing = true
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.bottom, 48)
            }
        }
        .background(VoiceKeys { key($0, book: book, order: (current.map { [$0] } ?? []) + groups.flatMap(\.voices)) })
        .onAppear {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "debugVoiceLines") { linesOpen = true }
            // A moment later: the page lays itself out again as it opens, which stops what's playing.
            if UserDefaults.standard.bool(forKey: "debugVoiceListening"), let v = groups.first?.voices.first { focus.listening = v.id }
            // `-debugVoicePick 1`: chooses the next voice, and takes that back 4s later.
            if UserDefaults.standard.bool(forKey: "debugVoicePick"), let v = voices.first {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { focus.pick(v, book: book) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if let last = SettingsLog.shared.entries.first { SettingsLog.shared.undo(last) }
                    focus.listening = nil
                }
            }
            if let d = UserDefaults.standard.string(forKey: "debugVoiceSend") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { send(d) }
            }
            #endif
        }
        .onDisappear { Voices.stopPreview() }
    }

    @ViewBuilder private var gear: some View {
        let on: Bool = { if case .cloud(let p) = source { focus.page == p } else { focus.macPanel } }()
        Button {
            if case .cloud(let p) = source { focus.page = on ? nil : p } else { focus.macPanel.toggle() }
        } label: {
            ZStack {
                let k: CGFloat = 15 / 16
                SVGShape(d: VoiceGlyph.rays).stroke(style: StrokeStyle(lineWidth: 1.4 * k, lineCap: .round))
                Circle().stroke(lineWidth: 1.4 * k).frame(width: 4.4 * k, height: 4.4 * k)
            }
            .foregroundStyle(on ? YYColor.t1 : YYColor.t2)
            .frame(width: 15, height: 15)
            .frame(width: 28, height: 28).contentShape(.rect)
        }
        .buttonStyle(HoverSquareStyle(on: on))
        .help(Text("\(source.title) 的 Key 和连接"))
    }

    private func send(_ text: String) {
        focus.send(text, book: focus.book)
        draft = ""
        typing = false
    }

    /// ↑↓ the next voice and hear it, space to stop or play, return to choose it, esc to leave it.
    private func key(_ code: UInt16, book: VoiceBook, order: [any Voice]) -> Bool {
        let currentID = book.current?.id
        let at = focus.listening ?? currentID
        switch code {
        case 125, 126:
            guard let i = order.firstIndex(where: { $0.id == at }) else { return false }
            let next = order[max(0, min(order.count - 1, i + (code == 125 ? 1 : -1)))]
            if next.id != at || PreviewState.shared.voiceID != next.id {
                Voices.stopPreview()
                focus.listen(next, text: focus.line(book))
            }
            return true
        case 49:
            guard let v = order.first(where: { $0.id == at }) else { return false }
            focus.listen(v, text: focus.line(book))
            return true
        case 36:
            guard let id = focus.listening, id != currentID, let v = order.first(where: { $0.id == id }) else { return false }
            focus.pick(v, book: book)
            return true
        case 53:
            guard let id = focus.listening, id != currentID else { return false }
            Voices.stopPreview()
            focus.listening = nil
            return true
        default:
            return false
        }
    }
}

/// 中文书 / 英文书.
private struct BookSegments: View {
    let selection: VoiceBook
    let choose: (VoiceBook) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(VoiceBook.allCases) { b in
                let on = b == selection
                Button { choose(b) } label: {
                    Text(b.title).font(.yy(size: 11.5, weight: on ? .medium : .regular)).foregroundStyle(on ? YYColor.t1 : YYColor.t2)
                        .padding(.horizontal, 10).frame(height: 22.7)
                        .background {
                            if on { RoundedRectangle(cornerRadius: 6).fill(YYColor.card).shadow(color: .black.opacity(0.08), radius: 1, y: 1) }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(YYColor.inset, in: .rect(cornerRadius: 8))
        .fixedSize()
    }
}

/// The box under the voices: “ for a ready line, what you type, how much of it, ↑ to send.
private struct VoiceComposer: View {
    let book: VoiceBook
    @Binding var draft: String
    @Binding var linesOpen: Bool
    var typing: FocusState<Bool>.Binding
    private static let limit = 120
    private var focus: ListeningFocus { .shared }

    var body: some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 8) {
            Button { linesOpen.toggle() } label: {
                SVGShape(d: VoiceGlyph.quote).fill(linesOpen ? YYColor.t1 : YYColor.t2)
                    .frame(width: 14, height: 14)
                    .frame(width: 28, height: 28)
                    .background(linesOpen ? YYColor.inset : .clear, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help(Text("换一句现成的"))
            TextField("", text: $draft, prompt: Text(book == .zh ? "想听他们念什么，写一句，或粘贴书里的一段" : "Type a line for them to read")
                .font(.yy(size: 12)).foregroundStyle(YYColor.t3))
                .textFieldStyle(.plain)
                .font(.custom("Songti SC", size: 13))
                .foregroundStyle(YYColor.t1)
                .focused(typing)
                .onSubmit(send)
                .onChange(of: draft) { _, new in if new.count > Self.limit { draft = String(new.prefix(Self.limit)) } }
                .padding(.leading, 2)
                .offset(y: 2)
            Text(draft.isEmpty ? String(localized: "回车发") : "\(draft.count) / \(Self.limit)")
                .font(.yy(size: 10.5).monospacedDigit()).foregroundStyle(YYColor.t3).fixedSize()
            Button(action: send) {
                SVGShape(d: VoiceGlyph.send, box: 12).stroke(YYColor.card, lineWidth: 2)
                    .frame(width: 12, height: 12)
                    .frame(width: 28, height: 28).background(YYColor.t1, in: .circle).contentShape(.circle)
            }
            .buttonStyle(.plain)
            // Not .disabled: that dims it again on top of this. send() does nothing while empty.
            // As one: faded apart, the circle shows through the arrow.
            .compositingGroup()
            .opacity(empty ? 0.25 : 1)
            .help(Text("发给大家"))
        }
        .padding(.leading, 6).padding(.trailing, 6)
        .frame(height: 40)
        .background(YYColor.card, in: .capsule)
        .ring(YYColor.line, radius: 20)
        .shadow(color: Color(yy: YYRGBA(51, 46, 41, 0.04)), radius: 1, y: 1)
    }

    private func send() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        focus.send(draft, book: book)
        draft = ""
        typing.wrappedValue = false
    }
}

/// The ready lines, over the box.
private struct QuickLines: View {
    let book: VoiceBook
    let send: (String) -> Void
    let fill: (String) -> Void
    private var focus: ListeningFocus { .shared }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(book.quickLines, id: \.name) { q in
                let using = focus.line(book) == q.line
                QuickLine(name: using ? String(localized: "\(q.name) · 正在用") : q.name, line: q.line) { send(q.line) }
            }
            QuickLine(name: book == .zh ? String(localized: "书里的一句") : "From a book", line: book.bookLine.hint) { fill(book.bookLine.line) }
        }
        .padding(5)
        .frame(width: 330)
        .background(YYColor.card, in: .rect(cornerRadius: 12))
        .ring(YYColor.line, radius: 12)
        .shadow(color: Color(yy: YYRGBA(40, 36, 32, 0.16)), radius: 16, y: 12)
    }
}

private struct QuickLine: View {
    let name: String
    let line: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.yy(size: 11, weight: .medium)).foregroundStyle(YYColor.t3)
                Text(line).font(.custom("Songti SC", size: 12.5)).foregroundStyle(YYColor.t1).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(hovering ? YYColor.t1.opacity(0.04) : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Keys pressed in this window while nothing is being typed.
private struct VoiceKeys: NSViewRepresentable {
    let handle: (UInt16) -> Bool

    final class Host: NSView {
        var handle: ((UInt16) -> Bool)?
        nonisolated(unsafe) private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            monitor.map(NSEvent.removeMonitor)
            monitor = nil
            guard let window else { return }
            // Otherwise the box takes the keyboard as the page opens.
            DispatchQueue.main.async { [weak window] in window?.makeFirstResponder(nil) }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window, event.window === window,
                          !(window.firstResponder is NSText) else { return false }
                    return self.handle?(event.keyCode) ?? false
                }
                return handled ? nil : event
            }
        }

        deinit { monitor.map(NSEvent.removeMonitor) }
    }

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ host: Host, context: Context) { host.handle = handle }
}

/// The connected sources side by side, the one open lifted.
private struct SourceTabs: View {
    let selection: VoiceSource
    private var focus: ListeningFocus { .shared }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(VoiceSource.all.filter(\.isSetUp), id: \.self) { s in
                let on = s == selection
                Button { focus.open(s) } label: {
                    HStack(spacing: 6) {
                        ServiceTile(mark: s.mark, size: 20)
                        Text(s.title).font(.yy(size: 12, weight: on ? .semibold : .regular)).foregroundStyle(on ? YYColor.t1 : YYColor.t2)
                            .lineLimit(1).fixedSize()
                    }
                    .padding(.leading, 4).padding(.trailing, 10)
                    .frame(height: 28)
                    .background {
                        if on { RoundedRectangle(cornerRadius: 8).fill(YYColor.card).shadow(color: .black.opacity(0.08), radius: 1, y: 1) }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(YYColor.inset, in: .rect(cornerRadius: 10))
    }
}

/// Voices as the ear hears them: 女声, 男声, then the rest. The system's say which they are; the
/// clouds' don't, so theirs are one group.
private struct VoiceGroup {
    let title: String
    let voices: [any Voice]

    static func groups(_ voices: [any Voice]) -> [VoiceGroup] {
        let sys = voices.compactMap { $0 as? SystemVoice }
        guard sys.count == voices.count else { return [VoiceGroup(title: String(localized: "\(voices.count) 位"), voices: voices)] }
        return [(AVSpeechSynthesisVoiceGender.female, String(localized: "女声")),
                (.male, String(localized: "男声")),
                (.unspecified, String(localized: "其他"))].compactMap { g, t in
            let vs = sys.filter { $0.gender == g }
            return vs.isEmpty ? nil : VoiceGroup(title: t, voices: vs)
        }
    }
}

/// A line across, words in the middle: as a chat's date.
private struct DayLine: View {
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(YYColor.line).frame(height: 0.5)
            Text(title).font(.yy(size: 10.5)).foregroundStyle(YYColor.t3).fixedSize().frame(height: 15.2)
            Rectangle().fill(YYColor.line).frame(height: 0.5)
        }
        .padding(.horizontal, 10)
        .padding(.top, 13).padding(.bottom, 4)
    }
}

/// What every voice says back: your line, as your own dark bubble on the right.
private struct YourLine: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Spacer(minLength: 60)
            ViewThatFits(in: .horizontal) {
                Text(text).fixedSize()
                Text(text).fixedSize(horizontal: false, vertical: true).frame(width: 272, alignment: .leading)
            }
            .frame(maxWidth: 272, alignment: .trailing)
            .font(.custom("Songti SC", size: 13)).lineSpacing(3.7)
            .foregroundStyle(YYColor.card)
            .padding(.horizontal, 14).padding(.vertical, 9.85)
            .background(YYColor.t1, in: .rect(cornerRadius: 14))
            Text("我").font(.yy(size: 11, weight: .semibold)).foregroundStyle(YYColor.t2)
                .frame(width: 28, height: 28).background(YYColor.inset, in: .circle)
        }
        .padding(.horizontal, 10)
    }
}

// MARK: - A voice

/// A voice's own colours: a pale ground and a dark letter, picked from its id so it keeps them.
enum VoiceColors {
    private static let pairs: [(YYRGBA, YYRGBA)] = [
        (YYRGBA(235, 221, 200), YYRGBA(107, 78, 51)), (YYRGBA(220, 229, 219), YYRGBA(52, 80, 63)),
        (YYRGBA(242, 230, 191), YYRGBA(110, 90, 30)), (YYRGBA(222, 218, 234), YYRGBA(62, 58, 90)),
        (YYRGBA(237, 210, 195), YYRGBA(122, 58, 36)), (YYRGBA(214, 220, 228), YYRGBA(47, 58, 74)),
        (YYRGBA(221, 217, 210), YYRGBA(60, 58, 54)), (YYRGBA(246, 221, 211), YYRGBA(139, 59, 42)),
    ]

    static func of(_ id: String) -> (ground: Color, ink: Color) {
        let n = id.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        let p = pairs[Int(n % UInt32(pairs.count))]
        return (Color(yy: p.0), Color(yy: p.1))
    }
}

/// Its first letter on its own colour.
struct VoiceAvatar: View {
    let voice: any Voice
    var size: CGFloat = 34
    var pinned = false

    var body: some View {
        let c = VoiceColors.of(voice.id)
        let first = String(voice.name.prefix(1))
        let latin = first.unicodeScalars.first.map { $0.isASCII } ?? false
        Text(first)
            .font(latin ? .custom("Iowan Old Style", size: size * 0.42).weight(.semibold) : .custom("Songti SC", size: size * 0.42).weight(.semibold))
            .foregroundStyle(c.ink)
            .frame(width: size, height: size)
            .background(c.ground, in: .circle)
            .overlay(Circle().strokeBorder(.black.opacity(0.06), lineWidth: 0.5))
            .background { if pinned { Circle().fill(YYColor.card).padding(-2) } }
            .overlay(alignment: .bottomTrailing) {
                if pinned {
                    PinGlyph(size: 8, badge: true).foregroundStyle(YYColor.t1)
                        .frame(width: 15, height: 15)
                        .background(YYColor.card, in: .circle)
                        .overlay(Circle().strokeBorder(YYColor.line, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                        .offset(x: 4, y: 4)
                }
            }
    }
}

/// A voice message: ▶, a little wave, the seconds; lit from the left while it plays. Dark for the
/// one reading, as your own bubble is.
struct VoiceBubble: View {
    let voice: any Voice
    let text: String
    var dark = false
    var height: CGFloat = 36
    /// The one being listened to in the list: raised a little.
    var lifted = false
    @AppStorage("player.rate") private var rate = 1.0
    private var state: PreviewState { .shared }

    var body: some View {
        let playing = state.voiceID == voice.id
        let secs = Self.seconds(text, rate: rate)
        let bars = min(24, 8 + secs * 2)
        Button {
            ListeningFocus.shared.listen(voice, text: text)
        } label: {
            TimelineView(.animation(paused: !playing)) { t in
                let p = playing ? state.progress(at: t.date) : nil
                HStack(spacing: 8) {
                    PlayGlyph(playing: playing, size: 8)
                        .foregroundStyle(dark ? YYColor.card : YYColor.t1)
                        .frame(width: 22, height: 22)
                        .background(dark ? Color.white.opacity(0.16) : YYColor.inset, in: .circle)
                    Wave(seed: voice.id, bars: bars, ink: dark ? YYColor.card.opacity(0.5) : YYColor.t3.opacity(0.6))
                    Spacer(minLength: 0)
                    Text("\(secs)″").font(.yy(size: 11).monospacedDigit()).foregroundStyle(dark ? YYColor.card.opacity(0.6) : YYColor.t3)
                }
                .padding(.leading, 5).padding(.trailing, 12)
                .frame(width: CGFloat(min(240, 66 + bars * 4 + 28)), height: height)
                .background(alignment: .leading) {
                    GeometryReader { g in
                        Rectangle()
                            .fill(dark ? Color.white.opacity(0.14) : YYColor.danger.opacity(0.09))
                            .frame(width: g.size.width * (p ?? 0))
                    }
                }
                .background(dark ? YYColor.t1 : YYColor.card)
                .clipShape(.rect(cornerRadius: 14))
                .ring(dark ? .clear : YYColor.line, radius: 14)
                .shadow(color: dark || lifted ? .clear : Color(yy: YYRGBA(51, 46, 41, 0.05)), radius: 1, y: 1)
                .spreadShadow(lifted ? Color(yy: YYRGBA(51, 46, 41, 0.24)) : .clear, y: 6, blur: 16, spread: 6, radius: 14)
                .offset(y: lifted ? -1 : 0)
                .animation(.easeOut(duration: 0.15), value: lifted)
                .overlay {
                    if playing && p == nil { Shimmer().clipShape(.rect(cornerRadius: 14)) }
                }
            }
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .help(Text(playing ? "停下" : "听\(voice.name)念"))
        .accessibilityLabel(Text("\(voice.name)，\(secs) 秒"))
    }

    /// About how long the line takes at this speed.
    static func seconds(_ text: String, rate: Double) -> Int {
        let latin = text.unicodeScalars.filter(\.isASCII).count > text.count / 2
        let r = rate == 0 ? 1 : rate
        return max(2, Int((Double(text.count) * (latin ? 0.07 : 0.2) / r).rounded()))
    }
}

/// Bar heights for a voice, the same every time.
private func waveHeights(seed: String, bars: Int, tallest: Double, taper: Double) -> [CGFloat] {
    var x = seed.unicodeScalars.reduce(UInt32(17)) { ($0 &* 31) &+ $1.value } % 233_280
    return (0 ..< bars).map { i in
        x = (x &* 9301 &+ 49297) % 233_280
        let k = pow(sin(Double.pi * (Double(i) + 0.5) / Double(bars)), taper) * (0.3 + 0.7 * Double(x) / 233_280)
        return max(3, tallest * k)
    }
}

/// Little bars.
private struct Wave: View {
    let seed: String
    let bars: Int
    let ink: Color

    var body: some View {
        let heights = waveHeights(seed: seed, bars: bars, tallest: 14, taper: 0.5)
        return HStack(spacing: 2) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                RoundedRectangle(cornerRadius: 1).fill(ink).frame(width: 2, height: h)
            }
        }
        .frame(height: 14)
    }
}

/// While a cloud voice is being fetched: a light passing over the bubble.
private struct Shimmer: View {
    var body: some View {
        TimelineView(.animation) { t in
            let phase = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            GeometryReader { g in
                LinearGradient(colors: [.clear, .white.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: g.size.width)
                    .offset(x: (phase * 2 - 1) * g.size.width)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 选择: white, a hairline, a pin; once chosen, green ✓ 已选择.
struct ChooseButton: View {
    let chosen: Bool
    var small = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if chosen {
                    SVGShape(d: VoiceGlyph.tick, box: 12).stroke(lineWidth: 2.6).frame(width: 10, height: 10)
                } else {
                    PinGlyph(size: 11)
                }
                Text(chosen ? "已选择" : "选择")
            }
            .font(.yy(size: small ? 11.5 : 12, weight: chosen ? .semibold : .medium))
            .foregroundStyle(chosen ? YYColor.ok : YYColor.t1)
            .padding(.leading, small ? 9 : 10).padding(.trailing, small ? 11 : 13)
            .frame(height: small ? 26 : 28)
            .background(chosen ? YYColor.ok.opacity(0.11) : YYColor.card, in: .capsule)
            .ring(chosen ? .clear : (hovering ? YYColor.t3 : YYColor.line), radius: small ? 13 : 14)
            .spreadShadow(chosen ? .clear : Color(yy: YYRGBA(51, 46, 41, hovering ? 0.26 : 0.2)), y: hovering ? 3 : 2, blur: hovering ? 10 : 8, spread: 3, radius: 14)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // Not .disabled: that would pale the green it's meant to show.
        .allowsHitTesting(!chosen)
        .onHover { hovering = $0 }
    }
}

/// One voice in the list: avatar and bubble on one line, its name and a line above; 选择 beside
/// the bubble on hover.
private struct VoiceMessage: View {
    let voice: any Voice
    let book: VoiceBook
    @State private var hovering = false
    private var focus: ListeningFocus { .shared }

    var body: some View {
        let open = hovering || focus.listening == voice.id
        HStack(alignment: .bottom, spacing: 10) {
            VoiceAvatar(voice: voice).padding(.bottom, 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(voice.name).font(.yy(size: 12.5, weight: .medium)).foregroundStyle(YYColor.t1)
                    if let q = voice.qualityName, !(voice is CloudVoice) {
                        Text(q).font(.yy(size: 11)).foregroundStyle(YYColor.t3)
                    }
                }
                .lineLimit(1)
                .frame(height: 18)
                .padding(.leading, 2)
                HStack(spacing: 8) {
                    VoiceBubble(voice: voice, text: focus.line(book), lifted: focus.listening == voice.id)
                    if !focus.heard.contains(voice.id) {
                        Circle().fill(Color(yy: YYRGBA(229, 72, 59))).frame(width: 6, height: 6)
                    }
                    ChooseButton(chosen: false, small: true) { focus.pick(voice, book: book) }
                        .padding(.leading, 4)
                        .opacity(open ? 1 : 0)
                        .offset(x: open ? 0 : -4)
                        .allowsHitTesting(open)
                        .animation(.easeOut(duration: 0.12), value: open)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { focus.listen(voice, text: focus.line(book)) }
    }
}

/// The one reading this kind of book, pinned at the top: one line in a card of its own colour.
private struct PinnedVoice: View {
    let voice: any Voice
    let book: VoiceBook
    /// It comes from another source than the one open.
    let elsewhere: Bool
    @Environment(\.colorScheme) private var scheme
    private var focus: ListeningFocus { .shared }

    var body: some View {
        let c = VoiceColors.of(voice.id)
        HStack(spacing: 8) {
            VoiceAvatar(voice: voice, size: 28, pinned: true)
            Text(voice.name).font(.yy(size: 12.5, weight: .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                .padding(.trailing, 2)
            VoiceBubble(voice: voice, text: focus.line(book), dark: true, height: 30)
            Spacer(minLength: 8)
            Label(elsewhere ? "念你的\(book.title) · \(VoiceSource.of(voice).title)" : "念你的\(book.title)", systemImage: "pin.fill")
                .labelStyle(PinLabelStyle(size: 10))
                .font(.yy(size: 11, weight: .medium))
                .foregroundStyle(scheme == .dark ? YYColor.t2 : c.ink.mix(with: YYColor.t2, by: 0.2))
                .lineLimit(1)
        }
        .padding(.leading, 8).padding(.trailing, 10)
        .frame(height: 44)
        .background(scheme == .dark ? c.ground.opacity(0.12) : c.ground.opacity(0.34), in: .rect(cornerRadius: 14))
        .background(YYColor.card, in: .rect(cornerRadius: 14))
        .ring(scheme == .dark ? YYColor.line : c.ink.opacity(0.16), radius: 14)
        .spreadShadow(scheme == .dark ? .clear : Color(yy: YYRGBA(51, 46, 41, 0.3)), y: 6, blur: 18, spread: 10, radius: 14)
        .id(voice.id)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// A square that lights on hover: ‹ and ⚙.
/// Back one page: the arrow alone, its square only under the pointer. 朗读's, and 播客's pages'.
struct SquareBackButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SVGShape(d: VoiceGlyph.back, box: 8)
                .stroke(YYColor.t2, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: 8, height: 12)
                .frame(width: 28, height: 28).contentShape(.rect)
        }
        .buttonStyle(HoverSquareStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

struct HoverSquareStyle: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View { Square(configuration: configuration, on: on) }

    private struct Square: View {
        let configuration: Configuration
        let on: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(YYColor.inset.opacity(on || hovering ? 1 : 0), in: .rect(cornerRadius: 8))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - The right column

/// 朗读's right column when no service is open: what was just changed (换回), then the voice last
/// listened to, or the one reading, as a card: its voice, its line, where it's from, 选择.
struct ListeningVoiceCard: View {
    private var focus: ListeningFocus { .shared }
    private var log: SettingsLog { .shared }

    var body: some View {
        let _ = focus.tick
        let book = focus.book
        let current = book.current
        let voice = focus.listening.flatMap(Voices.find).flatMap { $0.speaks(book.rawValue) ? $0 : nil } ?? current
        VStack(alignment: .leading, spacing: 10) {
            if let last = log.entries.first, last.undone != true, case .defaults(let key, _)? = last.undo, key == book.key,
               Date.now.timeIntervalSince(last.date) < 600 {
                HStack(spacing: 8) {
                    Text("\(last.to) 换下了 \(last.from)").font(.yy(size: 11)).foregroundStyle(YYColor.t3).lineLimit(1)
                    Spacer(minLength: 4)
                    UndoButton { log.undo(last); focus.tick &+= 1 }
                }
            }
            if let voice {
                let chosen = voice.id == current?.id
                Text(chosen ? "在念你的\(book.title)" : "正在听")
                    .font(.yy(size: 11.5, weight: .semibold)).foregroundStyle(YYColor.t2)
                    .frame(height: 16.7).padding(.top, 4).padding(.bottom, -4).padding(.leading, 4)
                HStack(spacing: 10) {
                    VoiceAvatar(voice: voice)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(voice.name).font(.yy(size: 14, weight: .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                        Text(VoiceSource.of(voice).title).font(.yy(size: 11)).foregroundStyle(YYColor.t3).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    ChooseButton(chosen: chosen) { focus.pick(voice, book: book) }
                    .fixedSize()
                }
                .frame(minHeight: 38.2)
                PanelCard { VoicePlayer(voice: voice, text: focus.line(book), whole: chosen || focus.heard.contains(voice.id)) }
                PanelCard {
                    PanelRow { Text("来自") } trailing: {
                        Text([VoiceSource.of(voice).title, voice is CloudVoice ? nil : voice.qualityName].compactMap { $0 }.joined(separator: " · "))
                            .font(.yy(size: 12)).foregroundStyle(YYColor.t2)
                    }
                    PanelRow { Text("费用") } trailing: {
                        Text(Self.cost(voice)).font(.yy(size: 12)).foregroundStyle(YYColor.t2)
                    }
                }
            } else {
                PanelHint(String(localized: "这台 Mac 上没有这种语言的声音"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private static func cost(_ v: any Voice) -> String {
        guard let c = v as? CloudVoice else { return String(localized: "免费 · 不联网") }
        switch c.provider {
        case .openai: return String(localized: "按字数 · 走你的 OpenAI")
        case .azure: return String(localized: "每月 50 万字免费")
        case .elevenlabs: return String(localized: "按字数 · 走你的账号")
        }
    }
}

/// The right column's player: ▶, a long wave lit red as it goes, and the line, each word darkening
/// as it's said. `whole`: already heard, so the line rests dark.
private struct VoicePlayer: View {
    let voice: any Voice
    let text: String
    let whole: Bool
    @AppStorage("player.rate") private var rate = 1.0
    private var state: PreviewState { .shared }
    private static let bars = 30

    var body: some View {
        let playing = state.voiceID == voice.id
        TimelineView(.animation(paused: !playing)) { t in
            let p = playing ? state.progress(at: t.date) ?? 0 : 0
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button { ListeningFocus.shared.listen(voice, text: text) } label: {
                        PlayGlyph(playing: playing, size: 10, large: true)
                            .foregroundStyle(YYColor.card)
                            .frame(width: 30, height: 30).background(YYColor.t1, in: .circle).contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .help(Text(playing ? "停下" : "听\(voice.name)念"))
                    HStack(spacing: 2) {
                        ForEach(Array(waveHeights(seed: voice.id, bars: Self.bars, tallest: 24, taper: 0.6).enumerated()), id: \.offset) { i, h in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(playing && Double(i) / Double(Self.bars) < p ? YYColor.danger : YYColor.line)
                                .frame(maxWidth: .infinity).frame(height: h)
                        }
                    }
                    .frame(height: 26)
                    Text("\(VoiceBubble.seconds(text, rate: rate))″").font(.yy(size: 11).monospacedDigit()).foregroundStyle(YYColor.t3)
                        .frame(width: 24, alignment: .trailing)
                }
                Text(said(playing ? Int((p * Double(text.count)).rounded(.up)) : whole ? text.count : 0))
                    .font(.custom("Songti SC", size: 13)).lineSpacing(6.3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2).padding(.vertical, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9).padding(.top, 9).padding(.bottom, 7)
        }
    }

    private func said(_ lit: Int) -> AttributedString {
        var a = AttributedString(text)
        a.foregroundColor = YYColor.t3
        let end = a.characters.index(a.startIndex, offsetBy: min(lit, a.characters.count))
        a[a.startIndex ..< end].foregroundColor = YYColor.t1
        return a
    }
}

/// ↶ 换回 ⌘Z, the same white capsule as 选择.
private struct UndoButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold))
                Text("换回").font(.yy(size: 11.5, weight: .medium))
                Text("⌘Z").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
            }
            .foregroundStyle(YYColor.t1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(YYColor.card, in: .capsule)
            .ring(hovering ? YYColor.t3 : YYColor.line, radius: 13)
            .spreadShadow(Color(yy: YYRGBA(51, 46, 41, hovering ? 0.26 : 0.2)), y: hovering ? 3 : 2, blur: hovering ? 10 : 8, spread: 3, radius: 13)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
#endif
