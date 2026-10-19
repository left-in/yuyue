import SwiftUI

/// 液态玻璃效果, one switch for the whole app (设置 · 外观 on the Mac, 我的 · 外观 on the phone):
/// everything that floats — capsules, tool capsules, the tabs along the top of 设置 — in the
/// system's Liquid Glass, or as the prototype draws it: frosted, with a soft pad under what's
/// chosen. Systems before 26 have no Liquid Glass and always get the prototype.
enum LiquidGlass {
    static let key = "appearance.liquidGlass"

    static var supported: Bool {
        if #available(macOS 26, iOS 26, *) { true } else { false }
    }

    /// The switch, and the system can do it.
    static var on: Bool {
        supported && (UserDefaults.standard.object(forKey: key) as? Bool ?? true)
    }
}

extension YYPaper {
    /// 墨水屏: no glass, no shadow, no animation.
    var isEink: Bool { id == YYPaper.eink.id }
}

extension View {
    /// The glass under something that floats. Off, or before 26, the prototype's frost: `fill`
    /// over the material, a soft shadow, a hairline. `liquid: false` keeps the frost whatever the
    /// switch says (墨水屏 has no glass).
    func yyGlass(
        _ shape: some Shape,
        fill: Color,
        line: Color? = nil,
        material: Material = .regularMaterial,
        shadow: Double = 0.08, radius: CGFloat = 12, y: CGFloat = 4,
        tint: Color? = nil,
        interactive: Bool = false,
        liquid: Bool = true
    ) -> some View {
        modifier(YYGlass(shape: shape, fill: fill, line: line, material: material, shadow: shadow, radius: radius,
                         y: y, tint: tint, interactive: interactive, allowed: liquid))
    }
}

private struct YYGlass<S: Shape>: ViewModifier {
    let shape: S
    let fill: Color
    let line: Color?
    let material: Material
    let shadow: Double, radius: CGFloat, y: CGFloat
    let tint: Color?
    let interactive: Bool
    let allowed: Bool
    @AppStorage(LiquidGlass.key) private var chosen = true

    func body(content: Content) -> some View {
        if chosen && allowed, #available(macOS 26, iOS 26, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background {
                    shape.fill(fill)
                        .background(material, in: shape)
                        .shadow(color: .black.opacity(shadow), radius: radius, y: y)
                }
                .overlay {
                    if let line { shape.stroke(line, lineWidth: 0.5) }
                }
        }
    }

    @available(macOS 26, iOS 26, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        return interactive ? glass.interactive() : glass
    }
}

extension View {
    /// macOS 26 and iOS 26 fade whatever scrolls under a bar; the prototype doesn't.
    @ViewBuilder func noScrollEdgeFade() -> some View {
        if #available(macOS 26, iOS 26, *) {
            scrollEdgeEffectHidden(true, for: .vertical)
        } else {
            self
        }
    }
}

#if os(macOS)

/// A tool in a tool capsule (`.v-mac-tools i`), 34 × 26: what's open is in `accent` on a soft
/// pad of it. `symbol` nil is the prototype's Latin "Aa".
struct GlassTool: View {
    let title: String
    let symbol: String?
    let help: String
    let on: Bool
    let accent: Color
    let soft: Color
    let ink: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                } else {
                    Text("Aa").font(.system(size: 12.5, weight: .semibold))
                }
            }
            .foregroundStyle(on ? accent : ink)
            .frame(width: 34, height: 26)
            .background(on ? soft : .clear, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
        .help(help)
    }
}

/// `.v-mac-back`: 书架 at the top left, the system's own toolbar button in Liquid Glass, or the
/// prototype's frosted capsule.
struct ShelfButtonToolbar: ToolbarContent {
    let liquid: Bool
    let ink: Color
    let glass: Color
    let line: Color
    let open: () -> Void

    var body: some ToolbarContent {
        if liquid {
            ToolbarItem(placement: .navigation) {
                Button(action: open) {
                    Label("书架", systemImage: "chevron.left").labelStyle(.titleAndIcon)
                }
                .help("回到书架")
            }
        } else {
            ToolbarItem(placement: .navigation) {
                Button(action: open) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("书架").font(.system(size: 12))
                    }
                    .foregroundStyle(ink)
                    .padding(.leading, 7)
                    .padding(.trailing, 12)
                    .frame(height: 30)
                    .yyGlass(Capsule(), fill: glass, line: line, shadow: 0.06, radius: 7, liquid: false)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help("回到书架")
            }
            .withoutGlass()
        }
    }
}

#endif
