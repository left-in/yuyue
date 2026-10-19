import SwiftUI
import YuyueCore

/// Puts a card centred over `rect`, above it when there is room and below otherwise.
struct Above: ViewModifier {
    let rect: CGRect
    let size: CGSize
    @State private var card = CGSize(width: 320, height: 120)

    init(rect: CGRect, in size: CGSize) {
        self.rect = rect
        self.size = size
    }

    func body(content: Content) -> some View {
        let gap: CGFloat = 14
        let above = rect.minY - card.height - gap > 8
        let x = min(max(rect.midX - card.width / 2, 12), max(12, size.width - card.width - 12))
        let y = above ? rect.minY - card.height - gap : rect.maxY + gap
        // The little point at the words, kept off the rounded corners.
        let tip = min(max(rect.midX - x, 22), max(22, card.width - 22))
        content
            .background(alignment: above ? .bottomLeading : .topLeading) {
                RoundedRectangle(cornerRadius: 2).fill(YYColor.card)
                    .frame(width: 11, height: 11)
                    .rotationEffect(.degrees(45))
                    // Behind the card, so only the part sticking out shows its edge on white paper.
                    .shadow(color: .black.opacity(0.12), radius: 2, y: above ? 1.5 : -1.5)
                    .offset(x: tip - 5.5, y: above ? 5 : -5)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { card = $0 }
            .offset(x: x, y: y)
    }
}

// MARK: - The card over selected text

/// 选中文字: the four highlight colours (1–4) with the last one used ringed, the two lines, then
/// 想法 · 从这读 · 问 · 翻译 · 复制. Over a highlight already made, it changes its colour or
/// takes it off.
struct SelectionCard: View {
    let model: ReaderModel
    /// The highlight clicked, or nil for a fresh selection.
    let current: Mark?
    let thought: () -> Void
    let translate: () -> Void
    /// 问 and 分享, where the device has them.
    var ask: (() -> Void)?
    var share: (() -> Void)?
    @Environment(\.colorScheme) private var scheme
    private let tint = YYTint.standard
    #if os(iOS)
    private static let touch = true
    #else
    private static let touch = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Self.touch ? 10 : 14) {
                ForEach(Array(MarkStyle.colours.enumerated()), id: \.offset) { i, style in
                    Button { pick(style) } label: {
                        VStack(spacing: Self.touch ? 5 : 4) {
                            swatch(style)
                            #if os(macOS)
                            // The key that makes it, with the text still selected.
                            Text("\(i + 1)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(ringed(style) ? YYColor.t1 : YYColor.t2)
                                .frame(width: 16, height: 15)
                                .background(YYColor.inset, in: .rect(cornerRadius: 4))
                            #endif
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("\(style.name) · 按 \(i + 1)")
                }
                Spacer(minLength: 16)
                ForEach(MarkStyle.lines, id: \.self) { style in
                    Button { pick(style) } label: {
                        Text("A")
                            .font(YYUI.serif(14.5))
                            .underline(pattern: style == .dotted ? .dot : .solid)
                            .foregroundStyle(ringed(style) ? tint.accent : YYColor.t2)
                            .frame(width: Self.touch ? 32 : 22, height: Self.touch ? 36 : 26)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(style.name)
                }
                if let current {
                    Button { model.deleteMark(current) } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12.5))
                            .foregroundStyle(YYColor.danger)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("删除划线")
                }
            }
            .padding(.horizontal, Self.touch ? 12 : 16)
            .padding(.top, Self.touch ? 10 : 9)
            .padding(.bottom, Self.touch ? 8 : 6)
            Rectangle().fill(YYColor.line).frame(height: 0.5)
            HStack(spacing: 0) {
                action(String(localized: "想法"), "pencil", thought)
                action(String(localized: "从这读"), "headphones") {
                    if let current {
                        model.selection = TextSelection(section: current.section, start: .init(s: Int(current.start.sentence), o: 0), end: .init(s: Int(current.end.sentence), o: 0), text: current.text, rect: .zero)
                    }
                    model.readFromSelection()
                }
                if let ask { action(String(localized: "问"), "sparkle", ask, accent: true) }
                action(String(localized: "翻译"), "translate", translate)
                action(String(localized: "复制"), "doc.on.doc") { model.copySelection() }
                if let share { action(String(localized: "分享"), "square.and.arrow.up", share) }
            }
            .padding(.horizontal, Self.touch ? 4 : 6)
            .padding(.vertical, Self.touch ? 6 : 9)
        }
        // `.v-mr-sc`
        .frame(width: Self.touch ? 340 : 332)
        .background(YYColor.card, in: .rect(cornerRadius: YYRadius.block))
        .yyShadow(scheme == .dark ? YYShadow.floatDark : YYShadow.floatLight)
    }

    private func ringed(_ style: MarkStyle) -> Bool {
        (current?.style ?? model.lastStyle) == style
    }

    private func swatch(_ style: MarkStyle) -> some View {
        ZStack {
            if style == .wave {
                Circle().fill(Self.touch ? YYColor.hlR.opacity(0.14) : YYColor.inset)
                Text("~")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(YYColor.hlR)
                    .offset(y: -1.5)
            } else {
                Circle().fill(style.fill)
            }
        }
        .frame(width: Self.touch ? 22 : 20, height: Self.touch ? 22 : 20)
        .padding(Self.touch ? 3 : 2.5)
        .overlay(Circle().strokeBorder(ringed(style) ? tint.accent : .clear, lineWidth: 1.5))
    }

    private func pick(_ style: MarkStyle) {
        if let current {
            model.setStyle(style, of: current)
            model.dismissCards()
        } else {
            model.mark(style)
        }
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void, accent: Bool = false) -> some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: Self.touch ? 13.5 : 14.5)).frame(height: 16)
                Text(title).font(.system(size: Self.touch ? 10.5 : 11, weight: accent ? .semibold : .regular))
            }
            .foregroundStyle(accent ? tint.accent : YYColor.t1)
            .frame(maxWidth: .infinity)
            .frame(height: Self.touch ? 44 : 41)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The words of a highlight drawn as in the book: a colour behind, or a line under (the red
/// one wavy, as on the page).
struct MarkText: View {
    let mark: Mark

    var body: some View {
        if mark.style == .wave {
            Text(mark.text).customAttribute(WavyLine()).textRenderer(WavyLineRenderer())
        } else {
            Text(attributed)
        }
    }

    private var attributed: AttributedString {
        var text = AttributedString(mark.text)
        switch mark.style {
        case .yellow, .blue, .pink: text.backgroundColor = mark.style.fill
        case .underline: text.underlineStyle = .single
        default: text.underlineStyle = Text.LineStyle(pattern: .dot)
        }
        return text
    }
}

struct WavyLine: TextAttribute {}

/// Draws a red wave under every line of text marked `WavyLine`.
struct WavyLineRenderer: TextRenderer {
    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        for line in layout {
            ctx.draw(line)
            for run in line where run[WavyLine.self] != nil {
                let r = run.typographicBounds.rect
                var path = Path()
                let y = r.maxY + 1.5, step = 3.0
                path.move(to: CGPoint(x: r.minX, y: y))
                var x = r.minX, up = true
                while x < r.maxX {
                    let next = min(x + step, r.maxX)
                    path.addQuadCurve(to: CGPoint(x: next, y: y), control: CGPoint(x: (x + next) / 2, y: y + (up ? -2.2 : 2.2)))
                    x = next
                    up.toggle()
                }
                ctx.stroke(path, with: .color(YYColor.hlR), lineWidth: 1)
            }
        }
    }
}

extension Int64 {
    /// "今天" · "10月3日"
    var dayText: String {
        let date = Date(timeIntervalSince1970: Double(self) / 1000)
        if Calendar.current.isDateInToday(date) { return String(localized: "今天") }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "昨天") }
        return date.formatted(.dateTime.month(.defaultDigits).day())
    }
}

#if os(iOS)
/// Liquid Glass when it's on (液态玻璃效果), frosted otherwise.
struct CapsuleGlass: ViewModifier {
    func body(content: Content) -> some View {
        content.yyGlass(Capsule(), fill: .clear, shadow: 0)
    }
}

/// 想法 on the phone.
struct PhoneThoughtSheet: View {
    let mark: Mark
    let save: (String?) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(mark.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(mark.style.fills ? mark.style.fill : YYColor.hlR).frame(width: 3) }
                TextEditor(text: $text)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(YYColor.inset, in: .rect(cornerRadius: 12))
                if mark.note != nil {
                    Button("删掉想法", role: .destructive) { save(nil) }
                }
            }
            .padding(16)
            .navigationTitle("想法")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: cancel) }
                ToolbarItem(placement: .confirmationAction) { Button("好") { save(text) } }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            text = mark.note ?? ""
            focused = true
        }
    }
}
#endif
