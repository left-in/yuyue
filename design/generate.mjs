#!/usr/bin/env node
// Generates platform token files from design/tokens.json. Plain Node, no dependencies.
//   node design/generate.mjs
// Writes:
//   reader/src/generated/tokens.css
//   apple/Yuyue/Design/Tokens.swift
//   android/app/src/main/java/app/yuyue/design/Tokens.kt
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const T = JSON.parse(readFileSync(join(ROOT, 'design/tokens.json'), 'utf8'));
const HEADER = 'generated from design/tokens.json — do not edit (run `node design/generate.mjs`)';

// ---------- helpers ----------
const keys = (o) => Object.keys(o).filter((k) => !k.startsWith('$'));
// camelCase -> kebab-case; digits stay attached (t1, fade0) except ink2 -> ink-2 as in the prototype.
const kebab = (s) => (s === 'ink2' ? 'ink-2' : s.replace(/([a-z0-9])([A-Z])/g, '$1-$2').toLowerCase());
const pascal = (s) => s.charAt(0).toUpperCase() + s.slice(1);
const num = (n) => {
  // Compact decimal for CSS/Swift/Kotlin: 0.5 -> .5 only in CSS (see cssNum).
  const r = Math.round(n * 10000) / 10000;
  return String(r);
};
const cssNum = (n) => num(n).replace(/^0\./, '.').replace(/^-0\./, '-.');
const ratio = (px) => cssNum(px / T.prototypeTextPx);

function parseColor(s) {
  let m = /^#([0-9a-f]{6})$/i.exec(s);
  if (m) {
    const v = parseInt(m[1], 16);
    return { r: (v >> 16) & 255, g: (v >> 8) & 255, b: v & 255, a: 1 };
  }
  m = /^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+)\s*)?\)$/i.exec(s);
  if (m) return { r: +m[1], g: +m[2], b: +m[3], a: m[4] === undefined ? 1 : parseFloat(m[4]) };
  throw new Error(`Unsupported colour: ${s}`);
}

function write(rel, text) {
  const p = join(ROOT, rel);
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, text);
  console.log('wrote', rel, `(${text.length} bytes)`);
}

const PAPERS = keys(T.paper);
const TINTS = keys(T.tint).filter((k) => k !== 'default');
const FONTS = keys(T.font);
const UI_KEYS = keys(T.color.light);
const TINT_KEYS = keys(T.tint[TINTS[0]].light);
const SHADOWS = keys(T.shadow.light);
const RADII = keys(T.radius);

// Fine-grain noise used by the e-ink paper (prototype .paper-eink background-image).
const NOISE =
  "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2' stitchTiles='stitch'/%3E%3CfeColorMatrix values='0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 .07 0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E\")";

// ---------- CSS ----------
function cssShadow(layers) {
  return layers.map(([x, y, b, s, c]) => [x, y, b, s].map((v) => (v ? `${cssNum(v)}px` : '0')).join(' ').replace(/ 0$/, '') + ' ' + c).join(',');
}

function genCss() {
  const L = [];
  L.push(`/* ${HEADER} */`);
  L.push('/* Everything is namespaced --yy-* so publisher CSS cannot collide with it. */');
  // Fonts, radii, light UI colours and the default tint.
  const root = [];
  for (const f of FONTS) root.push(`--yy-${kebab(f)}:${T.font[f].css}`);
  for (const k of UI_KEYS) root.push(`--yy-${kebab(k)}:${T.color.light[k]}`);
  const dt = T.tint.default;
  for (const k of TINT_KEYS) root.push(`--yy-${kebab(k)}:${T.tint[dt].light[k]}`);
  for (const s of SHADOWS) root.push(`--yy-shadow-${kebab(s)}:${cssShadow(T.shadow.light[s])}`);
  for (const r of RADII) root.push(`--yy-radius-${kebab(r)}:${T.radius[r]}px`);
  root.push(`--yy-ink-w:${cssNum(T.ink.widthPx)}px`);
  L.push(`:root{${root.join(';')}}`);
  const dark = [];
  for (const k of UI_KEYS) if (T.color.dark[k] !== T.color.light[k]) dark.push(`--yy-${kebab(k)}:${T.color.dark[k]}`);
  for (const k of TINT_KEYS) dark.push(`--yy-${kebab(k)}:${T.tint[dt].dark[k]}`);
  for (const s of SHADOWS) dark.push(`--yy-shadow-${kebab(s)}:${cssShadow(T.shadow.dark[s])}`);
  L.push(`@media (prefers-color-scheme:dark){:root{${dark.join(';')}}}`);
  for (const t of TINTS) {
    if (t === dt) continue;
    L.push(`:root[data-yy-tint="${t}"]{${TINT_KEYS.map((k) => `--yy-${kebab(k)}:${T.tint[t].light[k]}`).join(';')}}`);
    L.push(`@media (prefers-color-scheme:dark){:root[data-yy-tint="${t}"]{${TINT_KEYS.map((k) => `--yy-${kebab(k)}:${T.tint[t].dark[k]}`).join(';')}}}`);
  }
  // Papers. The first paper is also the default when data-yy-paper is missing.
  PAPERS.forEach((id, i) => {
    const p = T.paper[id];
    const v = [];
    for (const k of ['bg', 'ink', 'ink2', 'line', 'accent', 'hl', 'wave', 'glass', 'main', 'onMain']) v.push(`--yy-p-${kebab(k)}:${p[k]}`);
    v.push(`--yy-p-pa:${p.paperAccent}`);
    v.push(`--yy-p-texture:${p.texture === 'noise' ? NOISE : 'none'}`);
    const tx = p.text, ti = p.title, me = p.meta;
    v.push(`--yy-p-font:var(--yy-${kebab(tx.font)})`);
    v.push(`--yy-p-lh:${cssNum(tx.lineHeight)}`);
    v.push(`--yy-p-ps:${cssNum(tx.paragraphSpacingEm)}em`);
    v.push(`--yy-p-indent:${cssNum(tx.indentEm)}em`);
    v.push(`--yy-p-align:${tx.justify ? 'justify' : 'start'}`);
    v.push(`--yy-p-ls:${cssNum(tx.letterSpacingEm)}em`);
    v.push(`--yy-p-fscale:${ratio(tx.sizePx)}`);
    v.push(`--yy-p-title-font:var(--yy-${kebab(ti.font)})`);
    v.push(`--yy-p-title-size:${ratio(ti.sizePx)}`);
    v.push(`--yy-p-title-weight:${ti.weight}`);
    v.push(`--yy-p-title-lh:${cssNum(ti.lineHeight)}`);
    v.push(`--yy-p-title-ls:${cssNum(ti.letterSpacingEm)}em`);
    v.push(`--yy-p-title-rule:${ti.rule ? 'block' : 'none'}`);
    v.push(`--yy-p-meta-font:var(--yy-${kebab(me.font)})`);
    v.push(`--yy-p-meta-size:${ratio(me.sizePx)}`);
    v.push(`--yy-p-meta-ls:${cssNum(me.letterSpacingEm)}em`);
    v.push(`--yy-p-meta-border:${me.border ? '.5px' : '0'}`);
    v.push(`--yy-p-meta-mt:${ratio(me.marginTopPx)}`);
    v.push(`--yy-p-meta-pb:${ratio(me.paddingBottomPx)}`);
    v.push(`color-scheme:${p.dark ? 'dark' : 'light'}`);
    const sel = i === 0 ? `:root,html[data-yy-paper="${id}"]` : `html[data-yy-paper="${id}"]`;
    L.push(`${sel}{${v.join(';')}}`);
  });
  // Play button colour per tint (the e-ink paper never follows the tint).
  for (const t of TINTS) {
    if (t === dt) continue;
    for (const id of keys(T.tint[t].play)) {
      L.push(`html[data-yy-tint="${t}"][data-yy-paper="${id}"]{--yy-p-main:${T.tint[t].play[id]}}`);
    }
  }
  // English body text replaces the paper's text defaults.
  const lt = T.latinText;
  L.push(
    `:root{--yy-lt-font:var(--yy-${kebab(lt.font)});--yy-lt-lh:${cssNum(lt.lineHeight)};--yy-lt-ls:${cssNum(lt.letterSpacingEm)}em;` +
      `--yy-lt-align:${lt.justify ? 'justify' : 'start'};--yy-lt-fscale:${ratio(lt.sizePx)}}`
  );
  return L.join('\n') + '\n';
}

// ---------- Swift ----------
const swNum = (n) => num(n);
function swRGBA(s) {
  const c = parseColor(s);
  return `YYRGBA(${c.r}, ${c.g}, ${c.b}${c.a === 1 ? '' : ', ' + swNum(c.a)})`;
}
const swStr = (s) => JSON.stringify(s); // JSON string escaping is valid Swift for our content
const swDyn = (l, d) => (l === d ? `Color(yy: ${swRGBA(l)})` : `Color.yyDynamic(light: ${swRGBA(l)}, dark: ${swRGBA(d)})`);
const swShadow = (layers) =>
  '[' + layers.map(([x, y, b, s, c]) => `YYShadowLayer(x: ${swNum(x)}, y: ${swNum(y)}, blur: ${swNum(b)}, spread: ${swNum(s)}, color: ${swRGBA(c)})`).join(', ') + ']';

function genSwift() {
  const L = [];
  L.push(`// ${HEADER}`);
  L.push('// Colours are sRGB. UI colours resolve light/dark through UIKit/AppKit dynamic providers.');
  L.push('import SwiftUI');
  L.push('#if canImport(UIKit)');
  L.push('import UIKit');
  L.push('#elseif canImport(AppKit)');
  L.push('import AppKit');
  L.push('#endif');
  L.push('');
  L.push(`/// An sRGB colour value from tokens.json (0-255 channels, alpha 0-1).
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
`);
  // UI colours
  L.push('/// UI colours (界面). Tint-dependent colours (black, accent, …) live on `YYTint`.');
  L.push('public enum YYColor {');
  for (const k of UI_KEYS) L.push(`    public static let ${k} = ${swDyn(T.color.light[k], T.color.dark[k])}`);
  L.push('}');
  L.push('');
  // Fonts
  L.push(`/// Font families. \`css\` is the reader's stack; \`appleNames\` are tried in order, then the system design.
public enum YYFontFamily: String, Sendable, CaseIterable {
${FONTS.map((f) => `    case ${f}`).join('\n')}

    public var css: String {
        switch self {
${FONTS.map((f) => `        case .${f}: return ${swStr(T.font[f].css)}`).join('\n')}
        }
    }

    public var appleNames: [String] {
        switch self {
${FONTS.map((f) => `        case .${f}: return [${T.font[f].apple.map(swStr).join(', ')}]`).join('\n')}
        }
    }

    public var systemDesign: Font.Design {
        switch self {
${FONTS.map((f) => `        case .${f}: return .${{ sans: 'default', serif: 'serif', mono: 'monospaced' }[T.font[f].system]}`).join('\n')}
        }
    }

    /// The first installed family from \`appleNames\`, or nil to use the system font.
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
`);
  // Tints
  L.push('/// 主题色. `black`/`onBlack`: main buttons; `fill`: switches and progress; `soft`/`onSoft`: soft chips.');
  L.push('public struct YYTint: Sendable, Hashable, Identifiable {');
  L.push('    public let id: String');
  L.push('    public let name: String');
  for (const k of TINT_KEYS) L.push(`    public let ${k}: Color`);
  L.push('    /// Accent drawn on light papers (素白、纸本) and on dark papers (暗黑、纸本 · 夜).');
  L.push('    public let paperAccentLight: Color');
  L.push('    public let paperAccentDark: Color');
  L.push('    public let playPlain: Color, playKami: Color, playDark: Color, playKaminight: Color');
  L.push('');
  L.push('    /// The play button colour on a paper. The e-ink paper keeps its own.');
  L.push('    public func play(on paper: YYPaper) -> Color {');
  L.push('        switch paper.id {');
  L.push('        case "plain": return playPlain');
  L.push('        case "kami": return playKami');
  L.push('        case "dark": return playDark');
  L.push('        case "kaminight": return playKaminight');
  L.push('        default: return paper.main');
  L.push('        }');
  L.push('    }');
  L.push('');
  for (const t of TINTS) {
    const x = T.tint[t];
    const args = [`id: ${swStr(t)}`, `name: ${swStr(x.name)}`];
    for (const k of TINT_KEYS) args.push(`${k}: ${swDyn(x.light[k], x.dark[k])}`);
    args.push(`paperAccentLight: Color(yy: ${swRGBA(x.paperAccent.lightPaper)})`);
    args.push(`paperAccentDark: Color(yy: ${swRGBA(x.paperAccent.darkPaper)})`);
    for (const p of ['plain', 'kami', 'dark', 'kaminight']) args.push(`play${pascal(p)}: Color(yy: ${swRGBA(x.play[p])})`);
    L.push(`    public static let ${t} = YYTint(\n        ${args.join(',\n        ')}\n    )`);
  }
  L.push(`    public static let all: [YYTint] = [${TINTS.map((t) => '.' + t).join(', ')}]`);
  L.push(`    /// The tint chosen in 设置 · 外观 (\`appearance.tint\`), or the default.`);
  L.push(`    public static var standard: YYTint {`);
  L.push(`        let chosen = UserDefaults.standard.string(forKey: "appearance.tint")`);
  L.push(`        return all.first { $0.id == chosen } ?? .${T.tint.default}`);
  L.push(`    }`);
  L.push('}');
  L.push('');
  // Papers
  L.push(`/// Body typography defaults of a paper. Sizes are prototype pixels at 14px text: scale by fontSize / 14.
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
`);
  for (const id of PAPERS) {
    const p = T.paper[id];
    const c = (k) => `Color(yy: ${swRGBA(p[k])})`;
    const tx = p.text, ti = p.title, me = p.meta;
    L.push(`    public static let ${id} = YYPaper(
        id: ${swStr(id)}, name: ${swStr(p.name)}, isDark: ${!!p.dark}, hasNoiseTexture: ${p.texture === 'noise'},
        bg: ${c('bg')}, ink: ${c('ink')}, ink2: ${c('ink2')}, line: ${c('line')}, accent: ${c('accent')},
        hl: ${c('hl')}, wave: ${c('wave')}, glass: ${c('glass')}, main: ${c('main')}, onMain: ${c('onMain')},
        paperAccent: ${c('paperAccent')},
        text: YYPaperText(font: .${tx.font}, lineHeight: ${swNum(tx.lineHeight)}, paragraphSpacingEm: ${swNum(tx.paragraphSpacingEm)}, indentEm: ${swNum(tx.indentEm)}, justify: ${tx.justify}, letterSpacingEm: ${swNum(tx.letterSpacingEm)}, sizePx: ${swNum(tx.sizePx)}),
        title: YYPaperTitle(font: .${ti.font}, sizePx: ${swNum(ti.sizePx)}, weight: ${ti.weight}, lineHeight: ${swNum(ti.lineHeight)}, letterSpacingEm: ${swNum(ti.letterSpacingEm)}, rule: ${ti.rule}),
        meta: YYPaperMeta(font: .${me.font}, sizePx: ${swNum(me.sizePx)}, border: ${me.border}, letterSpacingEm: ${swNum(me.letterSpacingEm)}, marginTopPx: ${swNum(me.marginTopPx)}, paddingBottomPx: ${swNum(me.paddingBottomPx)})
    )`);
  }
  L.push(`    public static let all: [YYPaper] = [${PAPERS.map((p) => '.' + p).join(', ')}]`);
  L.push('}');
  L.push('');
  const lt = T.latinText;
  L.push(`/// English body text replaces the paper's font, line height, letter spacing, alignment and size.
public enum YYLatinText {
    public static let font: YYFontFamily = .${lt.font}
    public static let lineHeight: Double = ${swNum(lt.lineHeight)}
    public static let letterSpacingEm: Double = ${swNum(lt.letterSpacingEm)}
    public static let justify = ${lt.justify}
    public static let sizePx: Double = ${swNum(lt.sizePx)}
}
`);
  // Shadows & radii
  L.push(`public struct YYShadowLayer: Sendable, Hashable {
    public let x: Double, y: Double, blur: Double, spread: Double
    public let color: YYRGBA
}

/// Shadow layers in CSS order. A layer with spread > 0 and blur 0 is a hairline ring (draw it as a stroke).
public enum YYShadow {`);
  for (const s of SHADOWS) {
    L.push(`    public static let ${s}Light: [YYShadowLayer] = ${swShadow(T.shadow.light[s])}`);
    L.push(`    public static let ${s}Dark: [YYShadowLayer] = ${swShadow(T.shadow.dark[s])}`);
  }
  L.push('}');
  L.push('');
  L.push('public enum YYRadius {');
  for (const r of RADII) L.push(`    public static let ${r}: CGFloat = ${T.radius[r]}`);
  L.push('}');
  L.push('');
  L.push(`/// The reading line (墨线) and reader defaults.
public enum YYReader {
    public static let prototypeTextPx: Double = ${swNum(T.prototypeTextPx)}
    public static let inkWidthPx: Double = ${swNum(T.ink.widthPx)}
    public static let inkGapPx: Double = ${swNum(T.ink.gapPx)}
    public static let fallbackSecondsPerChar: Double = ${swNum(T.ink.fallbackSecondsPerChar)}
    public static let fallbackMinSeconds: Double = ${swNum(T.ink.fallbackMinSeconds)}
    public static let defaultFontSize: Double = ${swNum(T.readerDefaults.fontSizePx)}
    public static let defaultMargin: Double = ${swNum(T.readerDefaults.marginPx)}
    public static let defaultTop: Double = ${swNum(T.readerDefaults.topPx)}
    public static let defaultBottom: Double = ${swNum(T.readerDefaults.bottomPx)}
    public static let defaultPaper: String = ${swStr(T.readerDefaults.paper)}
}`);
  return L.join('\n') + '\n';
}

// ---------- Kotlin ----------
const ktNum = (n) => {
  const s = num(n);
  return (s.includes('.') ? s : s + '.0') + 'f';
};
function ktColor(s) {
  const c = parseColor(s);
  const a = Math.round(c.a * 255);
  const hex = [a, c.r, c.g, c.b].map((v) => v.toString(16).toUpperCase().padStart(2, '0')).join('');
  return `Color(0x${hex}L)`;
}
const ktStr = (s) => JSON.stringify(s).replace(/\$/g, '\\$');
const ktShadow = (layers) =>
  'listOf(' + layers.map(([x, y, b, s, c]) => `YYShadowLayer(${ktNum(x)}, ${ktNum(y)}, ${ktNum(b)}, ${ktNum(s)}, ${ktColor(c)})`).join(', ') + ')';
const KT_SYSTEM = { sans: 'FontFamily.SansSerif', serif: 'FontFamily.Serif', mono: 'FontFamily.Monospace' };

function genKotlin() {
  const L = [];
  L.push(`// ${HEADER}`);
  L.push('package app.yuyue.design');
  L.push('');
  L.push('import androidx.compose.ui.graphics.Color');
  L.push('import androidx.compose.ui.text.font.FontFamily');
  L.push('import androidx.compose.ui.unit.Dp');
  L.push('import androidx.compose.ui.unit.dp');
  L.push('');
  L.push('/** UI colours (界面) for one appearance. Tint-dependent colours live on [YYTintColors]. */');
  L.push('data class YYPalette(');
  L.push(UI_KEYS.map((k) => `    val ${k}: Color`).join(',\n'));
  L.push(')');
  L.push('');
  L.push('object YYColors {');
  for (const mode of ['light', 'dark']) {
    L.push(`    val ${pascal(mode)} = YYPalette(`);
    L.push(UI_KEYS.map((k) => `        ${k} = ${ktColor(T.color[mode][k])}`).join(',\n'));
    L.push('    )');
  }
  L.push('}');
  L.push('');
  L.push('/** Font families: `css` is the reader stack, `androidNames` are tried first, then [system]. */');
  L.push('enum class YYFont(val css: String, val androidNames: List<String>, val system: FontFamily) {');
  L.push(
    FONTS.map((f) => `    ${pascal(f)}(${ktStr(T.font[f].css)}, listOf(${T.font[f].android.map(ktStr).join(', ')}), ${KT_SYSTEM[T.font[f].system]})`).join(',\n') + ';'
  );
  L.push('}');
  L.push('');
  L.push('/** 主题色 for one appearance. */');
  L.push('data class YYTintColors(');
  L.push(TINT_KEYS.map((k) => `    val ${k}: Color`).join(',\n'));
  L.push(')');
  L.push('');
  L.push(`data class YYTint(
    val id: String,
    val name: String,
    val light: YYTintColors,
    val dark: YYTintColors,
    /** Accent drawn on light papers (素白、纸本) and dark papers (暗黑、纸本 · 夜). */
    val paperAccentLight: Color,
    val paperAccentDark: Color,
    val playPlain: Color,
    val playKami: Color,
    val playDark: Color,
    val playKaminight: Color,
) {
    /** The play button colour on a paper. The e-ink paper keeps its own. */
    fun play(paper: YYPaper): Color = when (paper.id) {
        "plain" -> playPlain
        "kami" -> playKami
        "dark" -> playDark
        "kaminight" -> playKaminight
        else -> paper.main
    }
}
`);
  L.push('object YYTints {');
  for (const t of TINTS) {
    const x = T.tint[t];
    const tc = (mode) => `YYTintColors(${TINT_KEYS.map((k) => `${k} = ${ktColor(x[mode][k])}`).join(', ')})`;
    L.push(`    val ${pascal(t)} = YYTint(`);
    L.push(`        id = ${ktStr(t)},`);
    L.push(`        name = ${ktStr(x.name)},`);
    L.push(`        light = ${tc('light')},`);
    L.push(`        dark = ${tc('dark')},`);
    L.push(`        paperAccentLight = ${ktColor(x.paperAccent.lightPaper)},`);
    L.push(`        paperAccentDark = ${ktColor(x.paperAccent.darkPaper)},`);
    for (const p of ['plain', 'kami', 'dark', 'kaminight']) L.push(`        play${pascal(p)} = ${ktColor(x.play[p])},`);
    L.push('    )');
  }
  L.push(`    val Default = ${pascal(T.tint.default)}`);
  L.push(`    val All = listOf(${TINTS.map(pascal).join(', ')})`);
  L.push('}');
  L.push('');
  L.push(`/** Body typography defaults of a paper. Sizes are prototype pixels at 14px text: scale by fontSize / 14. */
data class YYPaperText(
    val font: YYFont,
    val lineHeight: Float,
    val paragraphSpacingEm: Float,
    val indentEm: Float,
    val justify: Boolean,
    val letterSpacingEm: Float,
    val sizePx: Float,
)

data class YYPaperTitle(
    val font: YYFont,
    val sizePx: Float,
    val weight: Int,
    val lineHeight: Float,
    val letterSpacingEm: Float,
    /** A short accent rule under the title (纸本 papers). */
    val rule: Boolean,
)

data class YYPaperMeta(
    val font: YYFont,
    val sizePx: Float,
    val border: Boolean,
    val letterSpacingEm: Float,
    val marginTopPx: Float,
    val paddingBottomPx: Float,
)

/** 纸页. Paper colours do not follow the system appearance. */
data class YYPaper(
    val id: String,
    val name: String,
    val isDark: Boolean,
    val hasNoiseTexture: Boolean,
    val bg: Color,
    val ink: Color,
    val ink2: Color,
    val line: Color,
    val accent: Color,
    val hl: Color,
    val wave: Color,
    val glass: Color,
    val main: Color,
    val onMain: Color,
    /** Accent for marks on the paper (search hits, footnote references, bookmarks). */
    val paperAccent: Color,
    val text: YYPaperText,
    val title: YYPaperTitle,
    val meta: YYPaperMeta,
)
`);
  L.push('object YYPapers {');
  for (const id of PAPERS) {
    const p = T.paper[id];
    const tx = p.text, ti = p.title, me = p.meta;
    L.push(`    val ${pascal(id)} = YYPaper(`);
    L.push(`        id = ${ktStr(id)},`);
    L.push(`        name = ${ktStr(p.name)},`);
    L.push(`        isDark = ${!!p.dark},`);
    L.push(`        hasNoiseTexture = ${p.texture === 'noise'},`);
    for (const k of ['bg', 'ink', 'ink2', 'line', 'accent', 'hl', 'wave', 'glass', 'main', 'onMain', 'paperAccent']) L.push(`        ${k} = ${ktColor(p[k])},`);
    L.push(
      `        text = YYPaperText(YYFont.${pascal(tx.font)}, ${ktNum(tx.lineHeight)}, ${ktNum(tx.paragraphSpacingEm)}, ${ktNum(tx.indentEm)}, ${tx.justify}, ${ktNum(tx.letterSpacingEm)}, ${ktNum(tx.sizePx)}),`
    );
    L.push(
      `        title = YYPaperTitle(YYFont.${pascal(ti.font)}, ${ktNum(ti.sizePx)}, ${ti.weight}, ${ktNum(ti.lineHeight)}, ${ktNum(ti.letterSpacingEm)}, ${ti.rule}),`
    );
    L.push(
      `        meta = YYPaperMeta(YYFont.${pascal(me.font)}, ${ktNum(me.sizePx)}, ${me.border}, ${ktNum(me.letterSpacingEm)}, ${ktNum(me.marginTopPx)}, ${ktNum(me.paddingBottomPx)}),`
    );
    L.push('    )');
  }
  L.push(`    val All = listOf(${PAPERS.map(pascal).join(', ')})`);
  L.push('}');
  L.push('');
  const lt = T.latinText;
  L.push(`/** English body text replaces the paper's font, line height, letter spacing, alignment and size. */
object YYLatinText {
    val font = YYFont.${pascal(lt.font)}
    const val LINE_HEIGHT = ${ktNum(lt.lineHeight)}
    const val LETTER_SPACING_EM = ${ktNum(lt.letterSpacingEm)}
    const val JUSTIFY = ${lt.justify}
    const val SIZE_PX = ${ktNum(lt.sizePx)}
}

/** One shadow layer in CSS order. spread > 0 with blur 0 is a hairline ring (draw it as a border). */
data class YYShadowLayer(val x: Float, val y: Float, val blur: Float, val spread: Float, val color: Color)
`);
  L.push('object YYShadows {');
  for (const s of SHADOWS) {
    L.push(`    val ${pascal(s)}Light = ${ktShadow(T.shadow.light[s])}`);
    L.push(`    val ${pascal(s)}Dark = ${ktShadow(T.shadow.dark[s])}`);
  }
  L.push('}');
  L.push('');
  L.push('object YYRadius {');
  for (const r of RADII) L.push(`    val ${pascal(r)}: Dp = ${T.radius[r]}.dp`);
  L.push('}');
  L.push('');
  L.push(`/** The reading line (墨线) and reader defaults. */
object YYReader {
    const val PROTOTYPE_TEXT_PX = ${ktNum(T.prototypeTextPx)}
    const val INK_WIDTH_PX = ${ktNum(T.ink.widthPx)}
    const val INK_GAP_PX = ${ktNum(T.ink.gapPx)}
    const val FALLBACK_SECONDS_PER_CHAR = ${ktNum(T.ink.fallbackSecondsPerChar)}
    const val FALLBACK_MIN_SECONDS = ${ktNum(T.ink.fallbackMinSeconds)}
    const val DEFAULT_FONT_SIZE = ${ktNum(T.readerDefaults.fontSizePx)}
    const val DEFAULT_MARGIN = ${ktNum(T.readerDefaults.marginPx)}
    const val DEFAULT_TOP = ${ktNum(T.readerDefaults.topPx)}
    const val DEFAULT_BOTTOM = ${ktNum(T.readerDefaults.bottomPx)}
    const val DEFAULT_PAPER = ${ktStr(T.readerDefaults.paper)}
}`);
  return L.join('\n') + '\n';
}

write('reader/src/generated/tokens.css', genCss());
write('apple/Yuyue/Design/Tokens.swift', genSwift());
write('android/app/src/main/java/app/yuyue/design/Tokens.kt', genKotlin());
