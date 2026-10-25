import SwiftUI
import YuyueCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - 我的纸

/// The papers the reader made, after the five presets. The colours of each come from the core,
/// so every device draws the same page.
@MainActor @Observable
final class Papers {
    static let shared = Papers()
    /// A paper was made, changed or removed: open pages take it again.
    static let changed = Notification.Name("yuyue.papersChanged")

    private(set) var list: [CustomPaper] = []
    @ObservationIgnored private var tokens: [String: YYPaper] = [:]
    @ObservationIgnored private weak var core: YuyueCore?

    func load(_ core: YuyueCore) {
        self.core = core
        let fresh = (try? core.customPapers()) ?? []
        guard fresh != list else { return }
        list = fresh
        tokens = [:]
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func tokens(for id: String) -> YYPaper? {
        if let t = tokens[id] { return t }
        guard let paper = list.first(where: { $0.id == id }) else { return nil }
        let t = YYPaper(custom: paper)
        tokens[id] = t
        return t
    }

    func paper(_ id: String?) -> CustomPaper? { id.flatMap { id in list.first { $0.id == id } } }

    /// Saves it and returns it as stored.
    @discardableResult
    func save(_ paper: CustomPaper) throws -> CustomPaper? {
        guard let core else { return nil }
        let saved = try core.saveCustomPaper(paper: paper)
        load(core)
        return saved
    }

    func delete(_ id: String) {
        guard let core else { return }
        try? core.deleteCustomPaper(id: id)
        load(core)
        NotificationCenter.default.post(name: .readerSettingsChanged, object: nil)
    }

    /// 撤销 after 删除.
    func restore(_ id: String) {
        guard let core else { return }
        try? core.restoreCustomPaper(id: id)
        load(core)
    }

    func rename(_ paper: CustomPaper, to name: String) {
        var renamed = paper
        renamed.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !renamed.name.isEmpty, renamed.name != paper.name else { return }
        _ = try? save(renamed)
    }
}

extension YYPaper {
    /// 我的纸: its colours over the typography of the preset it reads like.
    init(custom: CustomPaper) {
        let c = paperColors(paper: custom)
        let preset = c.preset.tokens
        self.init(
            id: custom.id, name: custom.name, isDark: c.dark, hasNoiseTexture: custom.texture != .none,
            bg: Color(hex: c.bg), ink: Color(hex: c.ink), ink2: Color(hex: c.ink2), line: Color(hex: c.line), accent: Color(hex: c.accent),
            hl: Color(hex: c.hl), wave: Color(hex: c.wave), glass: Color(hex: c.glass), main: Color(hex: c.main), onMain: Color(hex: c.onMain),
            paperAccent: Color(hex: c.paperAccent),
            text: preset.text, title: preset.title, meta: preset.meta
        )
    }
}

extension ReaderSettings {
    /// The paper the page is on: 我的纸 when it is one (and still there), else the preset.
    var paperTokens: YYPaper {
        customPaper.flatMap { Papers.shared.tokens(for: $0) } ?? paper.tokens
    }

    /// The paper as the swatches know it: a 我的纸 id, or a preset's.
    var paperChoice: String {
        if let id = customPaper, Papers.shared.paper(id) != nil { return id }
        return paper.tokens.id
    }
}

extension Color {
    /// `#RRGGBB` or `#RRGGBBAA`.
    init(hex: String) {
        var v: UInt64 = 0
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        Scanner(string: h).scanHexInt64(&v)
        let alpha = h.count == 8
        if alpha { self.init(yy: YYRGBA(Double(v >> 24 & 255), Double(v >> 16 & 255), Double(v >> 8 & 255), Double(v & 255) / 255)) }
        else { self.init(yy: YYRGBA(Double(v >> 16 & 255), Double(v >> 8 & 255), Double(v & 255))) }
    }

    /// `#RRGGBB` in sRGB.
    var hex: String {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
        #endif
        let byte = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

// MARK: - 调纸

/// 调纸, as docs/design/自己调纸页.html: 白天 or 夜里, six made colours for it, 微调 within bounds
/// that stay restful (色调、浓淡、深浅), a texture, and the text: picked for the colour or one of
/// four inks. Everything it can reach reads well, so there is nothing to warn about. No name to
/// type: the core names a new paper after the colour it is closest to. The page behind changes as
/// it is set; 取消 (or closing the card) puts it back.
struct PaperEditor: View {
    let model: ReaderModel
    @State var draft: CustomPaper
    /// Done (saved, the page on it) or cancelled (nil).
    let finish: (CustomPaper?) -> Void
    @State private var night: Bool
    @State private var hsl: PaperHsl
    @State private var tuning = false
    @State private var failure: String?
    private let tint = YYTint.standard

    init(model: ReaderModel, draft: CustomPaper, finish: @escaping (CustomPaper?) -> Void) {
        self.model = model
        self.finish = finish
        _draft = State(initialValue: draft)
        _night = State(initialValue: paperColors(paper: draft).dark)
        _hsl = State(initialValue: paperHsl(color: draft.bg))
    }

    private var palette: PaperPalette { paperPalette(night: night) }
    private var colors: PaperColors { paperColors(paper: draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // `.ed-top`
            HStack {
                Button { model.previewPaper(nil); finish(nil) } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.yy(size: 11, weight: .semibold))
                        Text("排版")
                    }
                    .foregroundStyle(YYColor.t2)
                    .contentShape(.rect)
                }
                .help(Text("取消"))
                Spacer()
                Text(draft.id.isEmpty ? String(localized: "调纸") : String(localized: "调整“\(draft.name)”"))
                    .font(.yy(size: 13, weight: .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                Spacer()
                Button { done() } label: {
                    Text("完成")
                        .font(.yy(size: 11.5, weight: .semibold))
                        .foregroundStyle(tint.onBlack)
                        .padding(.horizontal, 13).frame(height: 26)
                        .background(tint.black, in: .capsule)
                }
                .keyboardShortcut(.defaultAction)
            }
            .font(.yy(size: 12))
            .buttonStyle(.plain)

            Segments(items: [(false, String(localized: "白天")), (true, String(localized: "夜里"))],
                     selection: Binding(get: { night }, set: { switchSide($0) }), small: true) { _, t in Text(t) }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 6) {
                ForEach(palette.swatches, id: \.color) { swatch in
                    let made = CustomPaper(id: "", name: swatch.name, bg: swatch.color, ink: draft.ink, layout: draft.layout, texture: draft.texture)
                    PaperTile(paper: YYPaper(custom: made), texture: draft.texture, name: swatch.name, selected: draft.bg == swatch.color, small: true) {
                        hsl = paperHsl(color: swatch.color)
                        set { $0.bg = swatch.color }
                    }
                }
            }

            // `.grp`
            VStack(spacing: 0) {
                Button { withAnimation(.snappy(duration: 0.2)) { tuning.toggle() } } label: {
                    HStack {
                        Text("微调颜色").foregroundStyle(YYColor.t1)
                        Spacer()
                        Text("色调、浓淡、深浅").foregroundStyle(YYColor.t3).font(.yy(size: 10.5))
                        Image(systemName: "chevron.right")
                            .font(.yy(size: 9, weight: .semibold)).foregroundStyle(YYColor.t3)
                            .rotationEffect(.degrees(tuning ? 90 : 0))
                    }
                    .font(.yy(size: 12))
                    .frame(height: 38)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if tuning {
                    VStack(spacing: 2) {
                        tune(String(localized: "色调"), \.h, 0 ... 359, track: stride(from: 0.0, through: 360, by: 60).map { swatchColor(h: $0, s: max(hsl.s, 30)) })
                        tune(String(localized: "浓淡"), \.s, 0 ... palette.saturationMax, track: [swatchColor(s: 0), swatchColor(s: palette.saturationMax)])
                        // 深浅: light on the left on both sides, dark on the right.
                        tune(String(localized: "深浅"), \.l, palette.lightnessMin ... palette.lightnessMax,
                             track: [swatchColor(l: palette.lightnessMax), swatchColor(l: palette.lightnessMin)], reversed: true)
                    }
                    .padding(.bottom, 8)
                }
                row(String(localized: "纹理")) {
                    HStack(spacing: 6) {
                        ForEach([PaperTexture.none, .grain, .xuan, .linen], id: \.self) { t in
                            let on = draft.texture == t
                            Button { set { $0.texture = t } } label: {
                                Color(hex: colors.bg)
                                    .overlay { PaperTextureView(texture: t, dark: colors.dark) }
                                    .frame(width: 34, height: 26)
                                    .clipShape(.rect(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.black.opacity(0.14), lineWidth: 0.5))
                                    .padding(2)
                                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(on ? YYColor.t1 : .clear, lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                            .help(Text(t.title))
                            .accessibilityLabel(Text(t.title))
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
                row(String(localized: "字色")) {
                    HStack(spacing: 8) {
                        Button { set { $0.ink = nil } } label: {
                            Text("自动")
                                .font(.yy(size: 9.5, weight: .semibold))
                                .foregroundStyle(draft.ink == nil ? YYColor.t1 : YYColor.t2)
                                .padding(.horizontal, 8).frame(height: 22)
                                .background(YYColor.inset, in: .capsule)
                                .padding(1.5)
                                .overlay(Capsule().strokeBorder(draft.ink == nil ? YYColor.t1 : .clear, lineWidth: 1.5))
                        }
                        ForEach(palette.inks, id: \.color) { ink in
                            let on = draft.ink == ink.color
                            Button { set { $0.ink = ink.color } } label: {
                                Text(ink.name)
                                    .font(.yy(size: 9.5, weight: .semibold))
                                    .foregroundStyle(Color(hex: ink.color))
                                    .frame(width: 22, height: 22)
                                    .background(Color(hex: colors.bg), in: .circle)
                                    .overlay(Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                                    .padding(1.5)
                                    .overlay(Circle().strokeBorder(on ? YYColor.t1 : .clear, lineWidth: 1.5))
                            }
                            .help(Text(ink.name))
                            .accessibilityLabel(Text(ink.name))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .background(YYColor.card, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(YYColor.line, lineWidth: 0.5))

            if let failure {
                Text(failure).font(.yy(size: 11)).foregroundStyle(YYColor.danger)
            }
        }
        .onAppear { preview() }
        // Closed without 完成 (a click outside the card, the sheet pulled down): as 取消.
        .onDisappear { model.previewPaper(nil) }
    }

    private func row(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            Text(title).font(.yy(size: 12)).foregroundStyle(YYColor.t1)
            Spacer()
            content()
        }
        .frame(minHeight: 40)
        .overlay(alignment: .top) { Rectangle().fill(YYColor.line).frame(height: 0.5) }
    }

    private func tune(_ title: String, _ key: WritableKeyPath<PaperHsl, Double>, _ range: ClosedRange<Double>, track: [Color], reversed: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.yy(size: 11)).foregroundStyle(YYColor.t2).frame(width: 30, alignment: .leading)
            TrackSlider(value: Binding(get: { hsl[keyPath: key] }, set: { v in
                hsl[keyPath: key] = v
                let bg = paperColor(hsl: hsl, night: night)
                set { $0.bg = bg }
            }), range: range, track: track, thumb: Color(hex: colors.bg), reversed: reversed, label: title)
        }
        .frame(height: 30)
    }

    /// The colour 微调 would land on with one part changed: for the slider tracks.
    private func swatchColor(h: Double? = nil, s: Double? = nil, l: Double? = nil) -> Color {
        Color(hex: paperColor(hsl: PaperHsl(h: h ?? hsl.h, s: s ?? hsl.s, l: l ?? hsl.l), night: night))
    }

    /// 白天 ↔ 夜里: the first made colour of that side, its text picked for it.
    private func switchSide(_ toNight: Bool) {
        guard toNight != night, let first = paperPalette(night: toNight).swatches.first else { return }
        night = toNight
        hsl = paperHsl(color: first.color)
        set { $0.bg = first.color; $0.ink = nil }
    }

    private func set(_ change: (inout CustomPaper) -> Void) {
        change(&draft)
        preview()
    }

    private func preview() { model.previewPaper(draft) }

    private func done() {
        do {
            let saved = try Papers.shared.save(draft)
            model.previewPaper(nil)
            finish(saved)
        } catch {
            failure = Library.message(for: error)
        }
    }
}

extension PaperTexture {
    /// `data-yy-texture` (reader contract §2).
    var css: String? {
        switch self {
        case .none: nil
        case .grain: "grain"
        case .xuan: "xuan"
        case .linen: "linen"
        }
    }

    var title: String {
        switch self {
        case .none: String(localized: "无纹理")
        case .grain: String(localized: "细颗粒")
        case .xuan: String(localized: "宣纸")
        case .linen: String(localized: "亚麻")
        }
    }
}

/// A paper as a small tile with 文 in its ink (`.v-rd-paper i`), its texture on it.
struct PaperTile: View {
    let paper: YYPaper
    var texture: PaperTexture = .none
    let name: String
    let selected: Bool
    var small = false
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 6) {
                Text("文")
                    .font(YYUI.serif(15))
                    .foregroundStyle(paper.ink)
                    .frame(width: small ? 44 : 46, height: 38)
                    .background { paper.bg.overlay { PaperTextureView(texture: texture, dark: paper.isDark) } }
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(YYColor.line, lineWidth: paper.isDark ? 0 : 0.5))
                    .padding(2)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? YYColor.t1 : .clear, lineWidth: 1.5))
                Text(name)
                    .font(.yy(size: 10.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? YYColor.t1 : YYColor.t2)
                    .lineLimit(1)
                    .frame(maxWidth: 50)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 纹理 drawn natively, to look like the page's (reader.css `data-yy-texture`).
struct PaperTextureView: View {
    let texture: PaperTexture
    let dark: Bool

    var body: some View {
        Canvas { ctx, size in
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func next() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 33) / Double(1 << 31)
            }
            switch texture {
            case .none:
                break
            case .grain:
                let dot = dark ? Color.white.opacity(0.07) : Color.black.opacity(0.09)
                for _ in 0 ..< Int(size.width * size.height / 7) {
                    ctx.fill(Path(CGRect(x: next() * size.width, y: next() * size.height, width: 0.8, height: 0.8)), with: .color(dot))
                }
            case .xuan:
                let fibre = Color(red: 0.5, green: 0.44, blue: 0.32).opacity(dark ? 0.16 : 0.11)
                for _ in 0 ..< Int(size.width * size.height / 90) {
                    let x = next() * size.width, y = next() * size.height, len = 6 + next() * 22
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: y))
                    p.addLine(to: CGPoint(x: x + len, y: y + (next() - 0.5) * 2))
                    ctx.stroke(p, with: .color(fibre), lineWidth: 0.6)
                }
            case .linen:
                let thread = Color.gray.opacity(0.09)
                for x in stride(from: 0.0, to: size.width, by: 3) { ctx.fill(Path(CGRect(x: x, y: 0, width: 0.6, height: size.height)), with: .color(thread)) }
                for y in stride(from: 0.0, to: size.height, by: 3) { ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.6)), with: .color(thread)) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A slider on a coloured track (`.sl input`): the track shows where it goes, the knob is the colour.
struct TrackSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let track: [Color]
    let thumb: Color
    var reversed = false
    let label: String

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width - 20, 1)
            let t = (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 1e-9)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 6)
                    .padding(.horizontal, 10)
                Circle()
                    .fill(thumb)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: 20, height: 20)
                    .offset(x: (reversed ? 1 - t : t) * w)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let p = min(max((drag.location.x - 10) / w, 0), 1)
                value = range.lowerBound + (reversed ? 1 - p : p) * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: 26)
        .accessibilityElement()
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text("\(Int(((value - range.lowerBound) / max(range.upperBound - range.lowerBound, 1e-9) * 100).rounded()))%"))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            value = min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound)
        }
    }
}
