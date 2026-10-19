// Draws the app icon from 关于's logo (`.v-me-logo`, PhoneAbout): a bold Songti 阅 on paper with
// the 墨蓝 rule under it. Everything is in the logo's own 64-unit box, scaled up.
//
//   swift scripts/make_app_icon.swift
//
// Writes the asset catalog PNGs (macOS 15 and iOS 18 to 25) and the Icon Composer layers in
// apple/Yuyue/AppIcon.icon (macOS and iOS 26 and later). See docs/dev/app-icon.md.

import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = root.appendingPathComponent("apple/Yuyue/Assets.xcassets/AppIcon.appiconset")
let composer = root.appendingPathComponent("apple/Yuyue/AppIcon.icon/Assets")

let paper = NSColor(srgbRed: 251 / 255, green: 250 / 255, blue: 247 / 255, alpha: 1)
let ink = NSColor(srgbRed: 28 / 255, green: 29 / 255, blue: 32 / 255, alpha: 1)
let rule = NSColor(srgbRed: 43 / 255, green: 76 / 255, blue: 126 / 255, alpha: 1)

/// Draws into a `px` square sRGB bitmap; the closure gets a flipped context (y down, like CSS).
func bitmap(_ px: Int, opaque: Bool = false, _ draw: (CGContext) -> Void) -> CGImage {
    let info = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
    let cg = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue)!
    cg.translateBy(x: 0, y: CGFloat(px))
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    draw(cg)
    return cg.makeImage()!
}

func save(_ image: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

/// 阅, 30 units, bold Songti, centred in the box and 3 units high (`margin-top:-6px`).
func drawGlyph(_ cg: CGContext, origin: CGPoint, unit u: CGFloat) {
    let font = NSFontManager.shared.font(withFamily: "Songti SC", traits: .boldFontMask, weight: 9, size: 30 * u)
        ?? NSFont.systemFont(ofSize: 30 * u, weight: .bold)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "阅", attributes: [.font: font, .foregroundColor: ink]))
    var ascent: CGFloat = 0, descent: CGFloat = 0
    let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
    let top = origin.y + (64 * u - (ascent + descent)) / 2 - 3 * u
    cg.saveGState()
    cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    cg.textPosition = CGPoint(x: origin.x + (64 * u - width) / 2, y: top + ascent)
    CTLineDraw(line, cg)
    cg.restoreGState()
}

/// The rule: 20 in from each side, 13 up from the bottom, 2.5 high.
func drawRule(_ cg: CGContext, origin: CGPoint, unit u: CGFloat) {
    let r = CGRect(x: origin.x + 20 * u, y: origin.y + (64 - 13 - 2.5) * u, width: 24 * u, height: 2.5 * u)
    cg.setFillColor(rule.cgColor)
    cg.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
    cg.fillPath()
}

/// The macOS 15 icon: the logo's card on Apple's grid (824 of 1024, 100 in), with its shadow.
func macIcon(_ px: Int) -> CGImage {
    bitmap(px) { cg in
        let k = CGFloat(px) / 1024
        let u = 824 * k / 64
        let o = CGPoint(x: 100 * k, y: 100 * k)
        let card = CGPath(roundedRect: CGRect(origin: o, size: CGSize(width: 64 * u, height: 64 * u)),
                          cornerWidth: 15 * u, cornerHeight: 15 * u, transform: nil)
        cg.saveGState()
        // `0 8px 20px rgba(30,28,24,.14)`, kept inside the 100px margin.
        cg.setShadow(offset: CGSize(width: 0, height: 12 * k), blur: 28 * k,
                     color: NSColor(srgbRed: 30 / 255, green: 28 / 255, blue: 24 / 255, alpha: 0.22).cgColor)
        cg.addPath(card)
        cg.setFillColor(paper.cgColor)
        cg.fillPath()
        cg.restoreGState()
        // `inset 0 0 0 .5px rgba(0,0,0,.1)`
        cg.addPath(card)
        cg.setStrokeColor(NSColor.black.withAlphaComponent(0.1).cgColor)
        cg.setLineWidth(max(1, 0.5 * u / 4))
        cg.strokePath()
        drawGlyph(cg, origin: o, unit: u)
        drawRule(cg, origin: o, unit: u)
    }
}

/// iOS 18 to 25: full bleed, no alpha; the system rounds the corners.
func phoneIcon() -> CGImage {
    bitmap(1024, opaque: true) { cg in
        cg.setFillColor(paper.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        drawGlyph(cg, origin: .zero, unit: 16)
        drawRule(cg, origin: .zero, unit: 16)
    }
}

for px in [16, 32, 64, 128, 256, 512, 1024] {
    save(macIcon(px), catalog.appendingPathComponent("icon_\(px).png"))
}
save(phoneIcon(), catalog.appendingPathComponent("icon_ios.png"))

// Icon Composer layers: the paper is the icon's fill, 阅 and the rule sit on it.
try? FileManager.default.createDirectory(at: composer, withIntermediateDirectories: true)
save(bitmap(1024) { drawGlyph($0, origin: .zero, unit: 16) }, composer.appendingPathComponent("glyph.png"))
save(bitmap(1024) { drawRule($0, origin: .zero, unit: 16) }, composer.appendingPathComponent("rule.png"))
print("done")
