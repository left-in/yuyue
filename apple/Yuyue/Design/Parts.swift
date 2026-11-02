import SwiftUI

/// The prototype's own pieces (`.grp`, `.v-lb`, `.v-seg`, `.v-btn`…), for the screens it draws
/// with them instead of a system form. Sizes are the prototype's pixels, scaled up from its
/// phone mock to points.
enum YYUI {
    #if os(macOS)
    static let k: CGFloat = 1.13
    #else
    static let k: CGFloat = 1.2
    #endif

    /// A prototype size in points.
    static func s(_ px: CGFloat) -> CGFloat { px * k }

    static func font(_ px: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        design == .serif ? serif(s(px), weight) : .yy(size: s(px), weight: weight, design: design)
    }

    /// `--serif`: Songti, as the prototype sets it. The system serif (New York) borrows its Chinese
    /// from a fallback that sets every ，and 。 nearly two characters wide.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let size = size * TextScale.shared.factor
        return hasSongti ? .custom("Songti SC", fixedSize: size).weight(weight) : .system(size: size, weight: weight, design: .serif)
    }

    #if os(macOS)
    private static let hasSongti = NSFont(name: "Songti SC", size: 12) != nil
    #else
    private static let hasSongti = UIFont(name: "Songti SC", size: 12) != nil
    #endif
}

/// 大字体: the system text size as a factor on the prototype's fixed sizes, on iPhone and iPad (the
/// Mac has no such setting). Between 0.85 and 1.5, so the drawn layouts still hold. Views read it
/// through `Font.yy`, so they draw again when the setting changes.
@Observable final class TextScale {
    static let shared = TextScale()
    private(set) var factor: CGFloat = 1

    private init() {
        #if os(iOS)
        update()
        NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TextScale.shared.update() }
        }
        #endif
    }

    #if os(iOS)
    private func update() {
        factor = min(1.5, max(0.85, UIFontMetrics(forTextStyle: .body).scaledValue(for: 17) / 17))
    }
    #endif
}

extension Font {
    /// `.system(size:)` that follows 大字体.
    static func yy(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * TextScale.shared.factor, weight: weight, design: design)
    }
}

/// A page of the prototype's pieces on its grey ground.
struct YYPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, YYUI.s(16))
                .padding(.bottom, YYUI.s(20))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(YYColor.bg)
    }
}

/// `.v-lb`: a heading over a card, a grey note on its right.
struct YYLabel: View {
    let title: String
    var trailing: String?

    init(_ title: String, _ trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(YYUI.font(12.5, .semibold)).foregroundStyle(YYColor.t1)
            Spacer()
            if let trailing { Text(trailing).font(YYUI.font(10.5)).foregroundStyle(YYColor.t3) }
        }
        .padding(.top, YYUI.s(18))
        .padding(.bottom, YYUI.s(8))
        .padding(.horizontal, YYUI.s(2))
    }
}

/// `.v-note`: a grey line under a card.
struct YYNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(YYUI.font(10))
            .lineSpacing(YYUI.s(10) * 0.6)
            .foregroundStyle(YYColor.t3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, YYUI.s(6))
            .padding(.horizontal, YYUI.s(4))
    }
}

/// `.grp`: a white card of rows, a hairline between them.
struct YYGroup<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Rectangle().fill(YYColor.line).frame(height: 0.5) }
                    row
                }
            }
        }
        .padding(.horizontal, YYUI.s(12))
        .background(YYColor.card, in: .rect(cornerRadius: YYUI.s(14)))
        .overlay(RoundedRectangle(cornerRadius: YYUI.s(14)).strokeBorder(scheme == .dark ? Color.white.opacity(0.06) : YYColor.line, lineWidth: 0.5))
    }
}

/// `.v-card`: a white card on its own.
struct YYCardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(YYColor.card, in: .rect(cornerRadius: YYUI.s(16)))
            .overlay(RoundedRectangle(cornerRadius: YYUI.s(16)).strokeBorder(scheme == .dark ? Color.white.opacity(0.06) : YYColor.line, lineWidth: 0.5))
            .shadow(color: Color(yy: YYRGBA(51, 46, 41, scheme == .dark ? 0 : 0.04)), radius: 1, y: 1)
    }
}

extension View {
    func yyCard() -> some View { modifier(YYCardBackground()) }
}

/// How a note (删除 · 撤销 and the rest) comes and goes: a spring that settles without overshoot,
/// or with 减弱动态效果 on, a short fade.
struct YYToastMotion<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0), value: value)
    }
}

extension View {
    func yyToastMotion<Value: Equatable>(value: Value) -> some View { modifier(YYToastMotion(value: value)) }
}

/// `.grp .row`: an icon, what it is, and a grey value with a chevron.
struct YYRow<Trailing: View>: View {
    let title: String
    var icon: String?
    var value: String?
    var chevron = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: YYUI.s(10)) {
            if let icon {
                Image(systemName: icon).font(YYUI.font(13)).foregroundStyle(YYColor.t2).frame(width: YYUI.s(15))
            }
            Text(title).font(YYUI.font(11.5)).foregroundStyle(YYColor.t1).lineLimit(1)
            Spacer(minLength: YYUI.s(8))
            if let value {
                Text(value).font(YYUI.font(10.5)).foregroundStyle(YYColor.t3).lineLimit(1)
            }
            trailing
            if chevron {
                Image(systemName: "chevron.right").font(YYUI.font(9, .semibold)).foregroundStyle(YYColor.t3)
            }
        }
        .frame(minHeight: YYUI.s(38))
        .contentShape(.rect)
    }
}

extension YYRow where Trailing == EmptyView {
    init(_ title: String, icon: String? = nil, value: String? = nil, chevron: Bool = false) {
        self.init(title: title, icon: icon, value: value, chevron: chevron) { EmptyView() }
    }
}

/// `.v-in`: a field with its name in a fixed column on the left.
struct YYField<Field: View>: View {
    let label: String
    var labelWidth: CGFloat = 58
    @ViewBuilder let field: Field

    var body: some View {
        HStack(spacing: YYUI.s(8)) {
            Text(label).font(YYUI.font(11)).foregroundStyle(YYColor.t2).frame(width: YYUI.s(labelWidth), alignment: .leading)
            field.font(YYUI.font(11.5)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: YYUI.s(38))
    }
}

/// `.v-seg`: choices on an inset track, the chosen one lifted on a white chip; `small` is
/// `.v-seg.sm`, the one at the end of a row.
struct YYSegments<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    var counts: [T: Int] = [:]
    var small = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { value, title in
                let on = selection == value
                Button { selection = value } label: {
                    HStack(spacing: YYUI.s(4)) {
                        // Never cut a choice short; a longer (English) label widens its own chip.
                        Text(title).fixedSize()
                        if let n = counts[value] {
                            Text("\(n)").font(YYUI.font(10).monospacedDigit()).foregroundStyle(YYColor.t3)
                        }
                    }
                    .font(YYUI.font(small ? 10 : 11, on ? .semibold : .regular))
                    .foregroundStyle(on ? YYColor.t1 : YYColor.t2)
                    .lineLimit(1)
                    .padding(.horizontal, small ? YYUI.s(8) : 0)
                    .frame(maxWidth: .infinity)
                    .frame(height: YYUI.s(small ? 22 : 28))
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: YYUI.s(small ? 7 : 9)).fill(YYColor.card)
                                .shadow(color: .black.opacity(0.07), radius: 1.5, y: 1)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(small ? 10 : 12)))
    }
}

/// `.v-tag`: a small grey label.
struct YYTag: View {
    let text: String
    var icon: String?

    var body: some View {
        HStack(spacing: YYUI.s(3)) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(YYUI.font(10, .medium))
        .foregroundStyle(YYColor.t2)
        .padding(.horizontal, YYUI.s(6))
        .padding(.vertical, YYUI.s(3))
        .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(5)))
    }
}

/// `.sw2`: a switch in the theme colour.
struct YYSwitch: View {
    @Binding var isOn: Bool
    var label = ""

    var body: some View {
        Toggle(label, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            #if os(macOS)
            .controlSize(.small)
            #endif
            .tint(YYTint.standard.fill)
    }
}

/// `.v-btn`: a capsule button. `main` is the theme's dark one (`.k`), `raised` the white one
/// (`.o`), `soft` the tinted one (`.a`), `plain` the grey one.
struct YYButtonStyle: ButtonStyle {
    enum Kind { case main, raised, soft, plain, danger }
    enum Size { case small, regular, large }
    var kind = Kind.plain
    var size = Size.regular
    var wide = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let height: CGFloat = switch size { case .small: 26; case .regular: 32; case .large: 46 }
        let font: CGFloat = switch size { case .small: 10.5; case .regular: 11.5; case .large: 13 }
        let pad: CGFloat = switch size { case .small: 10; case .regular: 14; case .large: 20 }
        let tint = YYTint.standard
        return configuration.label
            .font(YYUI.font(font, .semibold))
            .lineLimit(1)
            .foregroundStyle(foreground(tint))
            .padding(.horizontal, YYUI.s(pad))
            .frame(maxWidth: wide ? .infinity : nil)
            .frame(height: YYUI.s(height))
            .background(background(tint), in: .capsule)
            .shadow(color: kind == .raised ? Color(yy: YYRGBA(51, 46, 41, 0.08)) : .clear, radius: 1.5, y: 1)
            .overlay(kind == .raised ? Capsule().strokeBorder(YYColor.line, lineWidth: 0.5) : nil)
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(.capsule)
    }

    private func foreground(_ tint: YYTint) -> Color {
        switch kind {
        case .main: tint.onBlack
        case .soft: tint.accent
        case .danger: YYColor.danger
        case .raised, .plain: YYColor.t1
        }
    }

    private func background(_ tint: YYTint) -> Color {
        switch kind {
        case .main: tint.black
        case .raised: YYColor.card
        case .soft: tint.accentSoft
        case .danger: YYColor.danger.opacity(0.11)
        case .plain: YYColor.inset
        }
    }
}

/// `.v-sh`: a sheet's own title with × on the right.
struct YYSheetHeader: View {
    let title: String
    var subtitle: String?
    let close: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: YYUI.s(8)) {
            Text(title).font(YYUI.font(14, .semibold)).foregroundStyle(YYColor.t1)
            if let subtitle { Text(subtitle).font(YYUI.font(10)).foregroundStyle(YYColor.t3).lineLimit(1) }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(YYUI.font(10, .bold)).foregroundStyle(YYColor.t2)
                    .frame(width: YYUI.s(26), height: YYUI.s(26))
                    .background(YYColor.inset, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("关上")
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + YYUI.s(5) }
        }
    }
}

/// The tab bar's own icons (the prototype's `#tab-shelf-f`, as Android draws it), for the places
/// that stand for the same thing: the Mac sidebar's 全部 is the 书架 tab.
enum PhoneTabIcon {
    /// An asset in the catalogue, drawn as a template.
    static let shelf = "tab-shelf"
}
