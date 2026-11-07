// generated from design/tokens.json — do not edit (run `node design/generate.mjs`)
// Colours are sRGB. UI colours resolve light/dark through UIKit/AppKit dynamic providers.
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An sRGB colour value from tokens.json (0-255 channels, alpha 0-1).
public struct YYRGBA: Sendable, Hashable {
    public let r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r / 255; self.g = g / 255; self.b = b / 255; self.a = a
    }
}

public extension Color {
    init(yy c: YYRGBA) {
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    /// A colour that follows the system light/dark appearance on iOS and macOS.
    static func yyDynamic(light: YYRGBA, dark: YYRGBA) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
        })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        })
        #else
        return Color(yy: light)
        #endif
    }
}

/// UI colours (界面). Tint-dependent colours (black, accent, …) live on `YYTint`.
public enum YYColor {
    public static let bg = Color.yyDynamic(light: YYRGBA(246, 245, 243), dark: YYRGBA(16, 17, 18))
    public static let card = Color.yyDynamic(light: YYRGBA(255, 255, 255), dark: YYRGBA(27, 28, 30))
    public static let inset = Color.yyDynamic(light: YYRGBA(239, 238, 235), dark: YYRGBA(38, 39, 42))
    public static let line = Color.yyDynamic(light: YYRGBA(231, 229, 225), dark: YYRGBA(44, 45, 48))
    public static let t1 = Color.yyDynamic(light: YYRGBA(42, 43, 46), dark: YYRGBA(237, 237, 238))
    public static let t2 = Color.yyDynamic(light: YYRGBA(110, 107, 104), dark: YYRGBA(154, 152, 149))
    public static let t3 = Color.yyDynamic(light: YYRGBA(138, 134, 130), dark: YYRGBA(142, 140, 137))
    public static let tint = Color.yyDynamic(light: YYRGBA(201, 196, 189), dark: YYRGBA(78, 76, 73))
    public static let player = Color.yyDynamic(light: YYRGBA(236, 235, 232), dark: YYRGBA(24, 25, 27))
    public static let hlY = Color(yy: YYRGBA(251, 231, 160))
    public static let hlR = Color(yy: YYRGBA(239, 127, 113))
    public static let hlB = Color(yy: YYRGBA(196, 227, 244))
    public static let mkY = Color.yyDynamic(light: YYRGBA(251, 231, 160), dark: YYRGBA(251, 231, 160, 0.26))
    public static let mkB = Color.yyDynamic(light: YYRGBA(207, 230, 244), dark: YYRGBA(196, 227, 244, 0.22))
    public static let mkP = Color.yyDynamic(light: YYRGBA(246, 199, 192), dark: YYRGBA(246, 199, 192, 0.24))
    public static let ok = Color.yyDynamic(light: YYRGBA(62, 155, 106), dark: YYRGBA(93, 187, 136))
    public static let danger = Color.yyDynamic(light: YYRGBA(194, 71, 58), dark: YYRGBA(229, 128, 111))
    public static let warn = Color.yyDynamic(light: YYRGBA(183, 121, 31), dark: YYRGBA(217, 165, 74))
    public static let glass = Color.yyDynamic(light: YYRGBA(255, 255, 255, 0.86), dark: YYRGBA(30, 31, 34, 0.86))
    public static let fade0 = Color.yyDynamic(light: YYRGBA(246, 245, 243, 0), dark: YYRGBA(16, 17, 18, 0))
    public static let pill = Color.yyDynamic(light: YYRGBA(251, 250, 247), dark: YYRGBA(44, 45, 48))
    public static let pillLine = Color.yyDynamic(light: YYRGBA(80, 65, 45, 0.16), dark: YYRGBA(255, 255, 255, 0.1))
}

/// Font families. `css` is the reader's stack; `appleNames` are tried in order, then the system design.
public enum YYFontFamily: String, Sendable, CaseIterable {
    case sans
    case serif
    case kai
    case kaiti
    case wenkai
    case mono
    case latinSerif

    public var css: String {
        switch self {
        case .sans: return "-apple-system,BlinkMacSystemFont,\"PingFang SC\",\"Hiragino Sans GB\",\"Microsoft YaHei\",sans-serif"
        case .serif: return "\"Noto Serif SC\",\"Source Han Serif SC\",\"Songti SC\",\"STSong\",serif"
        case .kai: return "\"LXGW WenKai\",\"Kaiti SC\",\"STKaiti\",\"KaiTi\",serif"
        case .kaiti: return "\"Kaiti SC\",\"STKaiti\",\"KaiTi\",serif"
        case .wenkai: return "\"LXGW WenKai\",\"Kaiti SC\",\"STKaiti\",serif"
        case .mono: return "ui-monospace,\"SF Mono\",Menlo,Consolas,monospace"
        case .latinSerif: return "Georgia,\"Times New Roman\",serif"
        }
    }

    public var appleNames: [String] {
        switch self {
        case .sans: return []
        case .serif: return ["Noto Serif SC", "Source Han Serif SC", "Songti SC"]
        case .kai: return ["LXGW WenKai", "Kaiti SC", "STKaiti"]
        case .kaiti: return ["Kaiti SC", "STKaiti"]
        case .wenkai: return ["LXGW WenKai Lite", "LXGW WenKai", "Kaiti SC"]
        case .mono: return []
        case .latinSerif: return ["Georgia"]
        }
    }

    public var systemDesign: Font.Design {
        switch self {
        case .sans: return .default
        case .serif: return .serif
        case .kai: return .serif
        case .kaiti: return .serif
        case .wenkai: return .serif
        case .mono: return .monospaced
        case .latinSerif: return .serif
        }
    }

    /// The first installed family from `appleNames`, or nil to use the system font.
    public var installedName: String? {
        #if canImport(UIKit)
        let families = Set(UIFont.familyNames)
        #elseif canImport(AppKit)
        let families = Set(NSFontManager.shared.availableFontFamilies)
        #else
        let families = Set<String>()
        #endif
        return appleNames.first { families.contains($0) }
    }

    public func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let name = installedName {
            return Font.custom(name, fixedSize: size).weight(weight)
        }
        return Font.system(size: size, weight: weight, design: systemDesign)
    }
}

/// 主题色 (松绿, 茶色, 苔绿, 黛紫). `black`/`onBlack`: main buttons, a faint wash of the colour with the
/// colour as text; `edge`: their hairline; `fill`: switches and progress; `soft`/`onSoft`: soft chips.
public struct YYTint: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let black: Color
    public let onBlack: Color
    public let accent: Color
    public let accentSoft: Color
    public let edge: Color
    public let fill: Color
    public let soft: Color
    public let onSoft: Color
    /// Accent drawn on light papers (素白、纸本) and on dark papers (暗黑、纸本 · 夜).
    public let paperAccentLight: Color
    public let paperAccentDark: Color
    public let playPlain: Color, playKami: Color, playDark: Color, playKaminight: Color, playSage: Color

    /// The play button colour on a paper. The e-ink paper keeps its own.
    public func play(on paper: YYPaper) -> Color {
        switch paper.id {
        case "plain": return playPlain
        case "kami": return playKami
        case "dark": return playDark
        case "kaminight": return playKaminight
        case "sage": return playSage
        default: return paper.main
        }
    }

    public static let pine = YYTint(
        id: "pine",
        name: String(localized: "松绿"),
        black: Color.yyDynamic(light: YYRGBA(234, 244, 240), dark: YYRGBA(120, 190, 170, 0.16)),
        onBlack: Color.yyDynamic(light: YYRGBA(36, 104, 88), dark: YYRGBA(120, 190, 170)),
        accent: Color.yyDynamic(light: YYRGBA(36, 104, 88), dark: YYRGBA(120, 190, 170)),
        accentSoft: Color.yyDynamic(light: YYRGBA(36, 104, 88, 0.1), dark: YYRGBA(120, 190, 170, 0.16)),
        edge: Color.yyDynamic(light: YYRGBA(36, 104, 88, 0.32), dark: YYRGBA(120, 190, 170, 0.35)),
        fill: Color.yyDynamic(light: YYRGBA(64, 146, 122), dark: YYRGBA(74, 150, 128)),
        soft: Color.yyDynamic(light: YYRGBA(36, 104, 88, 0.1), dark: YYRGBA(120, 190, 170, 0.16)),
        onSoft: Color.yyDynamic(light: YYRGBA(36, 104, 88), dark: YYRGBA(120, 190, 170)),
        paperAccentLight: Color(yy: YYRGBA(36, 104, 88)),
        paperAccentDark: Color(yy: YYRGBA(120, 190, 170)),
        playPlain: Color(yy: YYRGBA(36, 104, 88)),
        playKami: Color(yy: YYRGBA(36, 104, 88)),
        playDark: Color(yy: YYRGBA(120, 190, 170)),
        playKaminight: Color(yy: YYRGBA(120, 190, 170)),
        playSage: Color(yy: YYRGBA(36, 104, 88))
    )
    public static let tea = YYTint(
        id: "tea",
        name: String(localized: "茶色"),
        black: Color.yyDynamic(light: YYRGBA(248, 239, 230), dark: YYRGBA(214, 164, 124, 0.16)),
        onBlack: Color.yyDynamic(light: YYRGBA(140, 88, 50), dark: YYRGBA(214, 164, 124)),
        accent: Color.yyDynamic(light: YYRGBA(140, 88, 50), dark: YYRGBA(214, 164, 124)),
        accentSoft: Color.yyDynamic(light: YYRGBA(140, 88, 50, 0.1), dark: YYRGBA(214, 164, 124, 0.16)),
        edge: Color.yyDynamic(light: YYRGBA(140, 88, 50, 0.32), dark: YYRGBA(214, 164, 124, 0.35)),
        fill: Color.yyDynamic(light: YYRGBA(170, 116, 76), dark: YYRGBA(176, 120, 80)),
        soft: Color.yyDynamic(light: YYRGBA(140, 88, 50, 0.1), dark: YYRGBA(214, 164, 124, 0.16)),
        onSoft: Color.yyDynamic(light: YYRGBA(140, 88, 50), dark: YYRGBA(214, 164, 124)),
        paperAccentLight: Color(yy: YYRGBA(140, 88, 50)),
        paperAccentDark: Color(yy: YYRGBA(214, 164, 124)),
        playPlain: Color(yy: YYRGBA(140, 88, 50)),
        playKami: Color(yy: YYRGBA(140, 88, 50)),
        playDark: Color(yy: YYRGBA(214, 164, 124)),
        playKaminight: Color(yy: YYRGBA(214, 164, 124)),
        playSage: Color(yy: YYRGBA(140, 88, 50))
    )
    public static let moss = YYTint(
        id: "moss",
        name: String(localized: "苔绿"),
        black: Color.yyDynamic(light: YYRGBA(240, 243, 229), dark: YYRGBA(178, 194, 120, 0.16)),
        onBlack: Color.yyDynamic(light: YYRGBA(88, 104, 44), dark: YYRGBA(178, 194, 120)),
        accent: Color.yyDynamic(light: YYRGBA(88, 104, 44), dark: YYRGBA(178, 194, 120)),
        accentSoft: Color.yyDynamic(light: YYRGBA(88, 104, 44, 0.1), dark: YYRGBA(178, 194, 120, 0.16)),
        edge: Color.yyDynamic(light: YYRGBA(88, 104, 44, 0.32), dark: YYRGBA(178, 194, 120, 0.35)),
        fill: Color.yyDynamic(light: YYRGBA(116, 136, 64), dark: YYRGBA(128, 146, 70)),
        soft: Color.yyDynamic(light: YYRGBA(88, 104, 44, 0.1), dark: YYRGBA(178, 194, 120, 0.16)),
        onSoft: Color.yyDynamic(light: YYRGBA(88, 104, 44), dark: YYRGBA(178, 194, 120)),
        paperAccentLight: Color(yy: YYRGBA(88, 104, 44)),
        paperAccentDark: Color(yy: YYRGBA(178, 194, 120)),
        playPlain: Color(yy: YYRGBA(88, 104, 44)),
        playKami: Color(yy: YYRGBA(88, 104, 44)),
        playDark: Color(yy: YYRGBA(178, 194, 120)),
        playKaminight: Color(yy: YYRGBA(178, 194, 120)),
        playSage: Color(yy: YYRGBA(88, 104, 44))
    )
    public static let dai = YYTint(
        id: "dai",
        name: String(localized: "黛紫"),
        black: Color.yyDynamic(light: YYRGBA(240, 237, 248), dark: YYRGBA(176, 164, 226, 0.16)),
        onBlack: Color.yyDynamic(light: YYRGBA(94, 78, 146), dark: YYRGBA(176, 164, 226)),
        accent: Color.yyDynamic(light: YYRGBA(94, 78, 146), dark: YYRGBA(176, 164, 226)),
        accentSoft: Color.yyDynamic(light: YYRGBA(94, 78, 146, 0.1), dark: YYRGBA(176, 164, 226, 0.16)),
        edge: Color.yyDynamic(light: YYRGBA(94, 78, 146, 0.32), dark: YYRGBA(176, 164, 226, 0.35)),
        fill: Color.yyDynamic(light: YYRGBA(124, 108, 180), dark: YYRGBA(124, 108, 190)),
        soft: Color.yyDynamic(light: YYRGBA(94, 78, 146, 0.1), dark: YYRGBA(176, 164, 226, 0.16)),
        onSoft: Color.yyDynamic(light: YYRGBA(94, 78, 146), dark: YYRGBA(176, 164, 226)),
        paperAccentLight: Color(yy: YYRGBA(94, 78, 146)),
        paperAccentDark: Color(yy: YYRGBA(176, 164, 226)),
        playPlain: Color(yy: YYRGBA(94, 78, 146)),
        playKami: Color(yy: YYRGBA(94, 78, 146)),
        playDark: Color(yy: YYRGBA(176, 164, 226)),
        playKaminight: Color(yy: YYRGBA(176, 164, 226)),
        playSage: Color(yy: YYRGBA(94, 78, 146))
    )
    public static let all: [YYTint] = [.pine, .tea, .moss, .dai]
    /// The tint chosen in 设置 · 外观 (`appearance.tint`), or the default.
    public static var standard: YYTint {
        let chosen = UserDefaults.standard.string(forKey: "appearance.tint")
        return all.first { $0.id == chosen } ?? .pine
    }
}

/// Body typography defaults of a paper. Sizes are design pixels at 14px text: scale by fontSize / 14.
public struct YYPaperText: Sendable, Hashable {
    public let font: YYFontFamily
    public let lineHeight: Double
    public let paragraphSpacingEm: Double
    public let indentEm: Double
    public let justify: Bool
    public let letterSpacingEm: Double
    public let sizePx: Double
}

public struct YYPaperTitle: Sendable, Hashable {
    public let font: YYFontFamily
    public let sizePx: Double
    public let weight: Int
    public let lineHeight: Double
    public let letterSpacingEm: Double
    /// A short accent rule under the title (纸本 papers).
    public let rule: Bool
}

public struct YYPaperMeta: Sendable, Hashable {
    public let font: YYFontFamily
    public let sizePx: Double
    public let border: Bool
    public let letterSpacingEm: Double
    public let marginTopPx: Double
    public let paddingBottomPx: Double
}

/// 纸页. Paper colours do not follow the system appearance.
public struct YYPaper: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let isDark: Bool
    public let hasNoiseTexture: Bool
    public let bg: Color, ink: Color, ink2: Color, line: Color, accent: Color
    public let hl: Color, wave: Color, glass: Color, main: Color, onMain: Color
    /// Accent for marks on the paper (search hits, footnote references, bookmarks).
    public let paperAccent: Color
    public let text: YYPaperText
    public let title: YYPaperTitle
    public let meta: YYPaperMeta

    public static let plain = YYPaper(
        id: "plain", name: String(localized: "素白"), isDark: false, hasNoiseTexture: false,
        bg: Color(yy: YYRGBA(255, 255, 255)), ink: Color(yy: YYRGBA(42, 43, 46)), ink2: Color(yy: YYRGBA(119, 117, 113)), line: Color(yy: YYRGBA(239, 238, 235)), accent: Color(yy: YYRGBA(42, 43, 46)),
        hl: Color(yy: YYRGBA(251, 231, 160)), wave: Color(yy: YYRGBA(239, 127, 113)), glass: Color(yy: YYRGBA(255, 255, 255, 0.82)), main: Color(yy: YYRGBA(43, 76, 126)), onMain: Color(yy: YYRGBA(255, 255, 255)),
        paperAccent: Color(yy: YYRGBA(43, 76, 126)),
        text: YYPaperText(font: .sans, lineHeight: 2.15, paragraphSpacingEm: 1.1, indentEm: 0, justify: true, letterSpacingEm: 0.02, sizePx: 14),
        title: YYPaperTitle(font: .sans, sizePx: 22, weight: 700, lineHeight: 1.4, letterSpacingEm: 0, rule: false),
        meta: YYPaperMeta(font: .sans, sizePx: 10.5, border: true, letterSpacingEm: 0, marginTopPx: 10, paddingBottomPx: 14)
    )
    public static let dark = YYPaper(
        id: "dark", name: String(localized: "暗黑"), isDark: true, hasNoiseTexture: false,
        bg: Color(yy: YYRGBA(18, 19, 20)), ink: Color(yy: YYRGBA(214, 214, 216)), ink2: Color(yy: YYRGBA(126, 126, 131)), line: Color(yy: YYRGBA(38, 39, 42)), accent: Color(yy: YYRGBA(214, 214, 216)),
        hl: Color(yy: YYRGBA(81, 70, 31)), wave: Color(yy: YYRGBA(229, 122, 110)), glass: Color(yy: YYRGBA(34, 35, 38, 0.82)), main: Color(yy: YYRGBA(143, 168, 200)), onMain: Color(yy: YYRGBA(18, 19, 20)),
        paperAccent: Color(yy: YYRGBA(143, 168, 200)),
        text: YYPaperText(font: .sans, lineHeight: 2.15, paragraphSpacingEm: 1.1, indentEm: 0, justify: true, letterSpacingEm: 0.02, sizePx: 14),
        title: YYPaperTitle(font: .sans, sizePx: 22, weight: 700, lineHeight: 1.4, letterSpacingEm: 0, rule: false),
        meta: YYPaperMeta(font: .sans, sizePx: 10.5, border: true, letterSpacingEm: 0, marginTopPx: 10, paddingBottomPx: 14)
    )
    public static let kami = YYPaper(
        id: "kami", name: String(localized: "纸本"), isDark: false, hasNoiseTexture: false,
        bg: Color(yy: YYRGBA(245, 244, 237)), ink: Color(yy: YYRGBA(38, 37, 31)), ink2: Color(yy: YYRGBA(113, 110, 98)), line: Color(yy: YYRGBA(226, 223, 211)), accent: Color(yy: YYRGBA(27, 54, 93)),
        hl: Color(yy: YYRGBA(233, 224, 194)), wave: Color(yy: YYRGBA(27, 54, 93)), glass: Color(yy: YYRGBA(250, 249, 244, 0.84)), main: Color(yy: YYRGBA(27, 54, 93)), onMain: Color(yy: YYRGBA(245, 244, 237)),
        paperAccent: Color(yy: YYRGBA(43, 76, 126)),
        text: YYPaperText(font: .serif, lineHeight: 2.05, paragraphSpacingEm: 0.3, indentEm: 2, justify: true, letterSpacingEm: 0.01, sizePx: 14.5),
        title: YYPaperTitle(font: .serif, sizePx: 25, weight: 700, lineHeight: 1.4, letterSpacingEm: 0.05, rule: true),
        meta: YYPaperMeta(font: .serif, sizePx: 10.5, border: false, letterSpacingEm: 0.06, marginTopPx: 0, paddingBottomPx: 4)
    )
    public static let kaminight = YYPaper(
        id: "kaminight", name: String(localized: "纸本 · 夜"), isDark: true, hasNoiseTexture: false,
        bg: Color(yy: YYRGBA(27, 26, 23)), ink: Color(yy: YYRGBA(227, 222, 208)), ink2: Color(yy: YYRGBA(140, 135, 121)), line: Color(yy: YYRGBA(46, 44, 39)), accent: Color(yy: YYRGBA(143, 168, 200)),
        hl: Color(yy: YYRGBA(70, 63, 44)), wave: Color(yy: YYRGBA(143, 168, 200)), glass: Color(yy: YYRGBA(40, 38, 34, 0.84)), main: Color(yy: YYRGBA(143, 168, 200)), onMain: Color(yy: YYRGBA(27, 26, 23)),
        paperAccent: Color(yy: YYRGBA(143, 168, 200)),
        text: YYPaperText(font: .serif, lineHeight: 2.05, paragraphSpacingEm: 0.3, indentEm: 2, justify: true, letterSpacingEm: 0.01, sizePx: 14.5),
        title: YYPaperTitle(font: .serif, sizePx: 25, weight: 700, lineHeight: 1.4, letterSpacingEm: 0.05, rule: true),
        meta: YYPaperMeta(font: .serif, sizePx: 10.5, border: false, letterSpacingEm: 0.06, marginTopPx: 0, paddingBottomPx: 4)
    )
    public static let sage = YYPaper(
        id: "sage", name: String(localized: "鼠尾草"), isDark: false, hasNoiseTexture: false,
        bg: Color(yy: YYRGBA(230, 231, 220)), ink: Color(yy: YYRGBA(42, 44, 36)), ink2: Color(yy: YYRGBA(99, 102, 90)), line: Color(yy: YYRGBA(211, 213, 198)), accent: Color(yy: YYRGBA(42, 44, 36)),
        hl: Color(yy: YYRGBA(243, 227, 164)), wave: Color(yy: YYRGBA(201, 96, 79)), glass: Color(yy: YYRGBA(234, 235, 225, 0.84)), main: Color(yy: YYRGBA(43, 76, 126)), onMain: Color(yy: YYRGBA(255, 255, 255)),
        paperAccent: Color(yy: YYRGBA(43, 76, 126)),
        text: YYPaperText(font: .serif, lineHeight: 2.05, paragraphSpacingEm: 0.3, indentEm: 2, justify: true, letterSpacingEm: 0.01, sizePx: 14.5),
        title: YYPaperTitle(font: .serif, sizePx: 25, weight: 700, lineHeight: 1.4, letterSpacingEm: 0.05, rule: true),
        meta: YYPaperMeta(font: .serif, sizePx: 10.5, border: false, letterSpacingEm: 0.06, marginTopPx: 0, paddingBottomPx: 4)
    )
    public static let eink = YYPaper(
        id: "eink", name: String(localized: "铅印"), isDark: false, hasNoiseTexture: true,
        bg: Color(yy: YYRGBA(233, 232, 227)), ink: Color(yy: YYRGBA(20, 20, 20)), ink2: Color(yy: YYRGBA(85, 85, 85)), line: Color(yy: YYRGBA(201, 200, 194)), accent: Color(yy: YYRGBA(20, 20, 20)),
        hl: Color(yy: YYRGBA(0, 0, 0, 0)), wave: Color(yy: YYRGBA(20, 20, 20)), glass: Color(yy: YYRGBA(233, 232, 227)), main: Color(yy: YYRGBA(20, 20, 20)), onMain: Color(yy: YYRGBA(233, 232, 227)),
        paperAccent: Color(yy: YYRGBA(20, 20, 20)),
        text: YYPaperText(font: .serif, lineHeight: 2.05, paragraphSpacingEm: 0.3, indentEm: 2, justify: true, letterSpacingEm: 0.02, sizePx: 14),
        title: YYPaperTitle(font: .serif, sizePx: 24, weight: 700, lineHeight: 1.4, letterSpacingEm: 0.05, rule: false),
        meta: YYPaperMeta(font: .sans, sizePx: 10.5, border: true, letterSpacingEm: 0, marginTopPx: 10, paddingBottomPx: 14)
    )
    public static let all: [YYPaper] = [.plain, .dark, .kami, .kaminight, .sage, .eink]
}

/// English body text replaces the paper's font, line height, letter spacing, alignment and size.
public enum YYLatinText {
    public static let font: YYFontFamily = .latinSerif
    public static let lineHeight: Double = 2.25
    public static let letterSpacingEm: Double = 0
    public static let justify = false
    public static let sizePx: Double = 13.5
}

public struct YYShadowLayer: Sendable, Hashable {
    public let x: Double, y: Double, blur: Double, spread: Double
    public let color: YYRGBA
}

/// Shadow layers in CSS order. A layer with spread > 0 and blur 0 is a hairline ring (draw it as a stroke).
public enum YYShadow {
    public static let cardLight: [YYShadowLayer] = [YYShadowLayer(x: 0, y: 1, blur: 2, spread: 0, color: YYRGBA(51, 46, 41, 0.04)), YYShadowLayer(x: 0, y: 8, blur: 24, spread: 0, color: YYRGBA(51, 46, 41, 0.05))]
    public static let cardDark: [YYShadowLayer] = [YYShadowLayer(x: 0, y: 0, blur: 0, spread: 0.5, color: YYRGBA(255, 255, 255, 0.05))]
    public static let floatLight: [YYShadowLayer] = [YYShadowLayer(x: 0, y: 10, blur: 30, spread: 0, color: YYRGBA(51, 46, 41, 0.14)), YYShadowLayer(x: 0, y: 1, blur: 3, spread: 0, color: YYRGBA(51, 46, 41, 0.08))]
    public static let floatDark: [YYShadowLayer] = [YYShadowLayer(x: 0, y: 10, blur: 30, spread: 0, color: YYRGBA(0, 0, 0, 0.5)), YYShadowLayer(x: 0, y: 0, blur: 0, spread: 0.5, color: YYRGBA(255, 255, 255, 0.07))]
    public static let ringLight: [YYShadowLayer] = [YYShadowLayer(x: 0, y: 0, blur: 0, spread: 0.5, color: YYRGBA(231, 229, 225)), YYShadowLayer(x: 0, y: 1, blur: 2, spread: 0, color: YYRGBA(51, 46, 41, 0.04))]
    public static let ringDark: [YYShadowLayer] = [YYShadowLayer(x: 0, y: 0, blur: 0, spread: 0.5, color: YYRGBA(255, 255, 255, 0.06))]
    public static let ringFloatLight: [YYShadowLayer] = [YYShadowLayer(x: 0, y: 0, blur: 0, spread: 0.5, color: YYRGBA(231, 229, 225)), YYShadowLayer(x: 0, y: 8, blur: 24, spread: 0, color: YYRGBA(51, 46, 41, 0.1))]
    public static let ringFloatDark: [YYShadowLayer] = [YYShadowLayer(x: 0, y: 0, blur: 0, spread: 0.5, color: YYRGBA(255, 255, 255, 0.08)), YYShadowLayer(x: 0, y: 16, blur: 40, spread: 0, color: YYRGBA(0, 0, 0, 0.5))]
}

public enum YYRadius {
    public static let card: CGFloat = 16
    public static let block: CGFloat = 14
    public static let sheet: CGFloat = 22
    public static let capsule: CGFloat = 24
    public static let control: CGFloat = 10
    public static let chip: CGFloat = 999
}

/// 动效 durations in seconds; the animations themselves are YYMotion (Parts.swift).
public enum YYDuration {
    public static let quick: Double = 0.14
    public static let standard: Double = 0.24
    public static let layout: Double = 0.35
    public static let exit: Double = 0.12
}

/// The reading line (墨线) and reader defaults.
public enum YYReader {
    public static let prototypeTextPx: Double = 14
    public static let inkWidthPx: Double = 1.5
    public static let inkGapPx: Double = 2
    public static let fallbackSecondsPerChar: Double = 0.12
    public static let fallbackMinSeconds: Double = 1.8
    public static let defaultFontSize: Double = 18
    public static let defaultMargin: Double = 24
    public static let defaultTop: Double = 56
    public static let defaultBottom: Double = 88
    public static let defaultPaper: String = "plain"
}
