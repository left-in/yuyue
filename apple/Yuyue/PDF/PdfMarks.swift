import PDFKit
import SwiftUI
import YuyueCore
import os

/// A PDF page as 语阅 draws it: the colours of highlights laid under the ink, as a marker on
/// paper would be, and on the phone 夜间 (views there take no filters). Nothing is written
/// into the file.
nonisolated final class MarkedPage: PDFPage {
    /// 夜间: the colours laid on lighter, and on the phone the page turned round here.
    nonisolated(unsafe) static var night = false
    /// The colour behind each marked line, in page space, by page. Kept outside the page: the
    /// document makes its pages without running their Swift initialisers, and draws them on
    /// threads of its own.
    private static let allFills = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: [(CGRect, CGColor)]]())

    var fills: [(CGRect, CGColor)] {
        get {
            let key = ObjectIdentifier(self)
            return Self.allFills.withLock { $0[key] ?? [] }
        }
        set {
            let key = ObjectIdentifier(self)
            Self.allFills.withLock { $0[key] = newValue.isEmpty ? nil : newValue }
        }
    }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
        // Pages run edge to edge on white: a hairline at the foot of each is where one ends.
        if !Self.night, let doc = document, doc.index(for: self) < doc.pageCount - 1 {
            let r = bounds(for: box)
            context.saveGState()
            context.setFillColor(CGColor(gray: 0, alpha: 0.08))
            context.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: max(0.5, r.height * 0.0008)))
            context.restoreGState()
        }
        let fills = self.fills
        if !fills.isEmpty {
            context.saveGState()
            // Multiplied, so the ink stays as dark as it was; at night half as strong, as the
            // page turned round makes a pale colour deep.
            context.setBlendMode(.multiply)
            context.setAlpha(Self.night ? 0.5 : 1)
            for (rect, colour) in fills {
                context.setFillColor(colour)
                context.fill(rect)
            }
            context.restoreGState()
        }
        #if os(iOS)
        guard Self.night else { return }
        // Turned round, then softened: the paper a deep grey, the ink a warm light grey.
        let rect = bounds(for: box)
        context.saveGState()
        context.setBlendMode(.difference)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.setBlendMode(.multiply)
        context.setFillColor(CGColor(srgbRed: 0.86, green: 0.84, blue: 0.8, alpha: 1))
        context.fill(rect)
        context.setBlendMode(.lighten)
        context.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1))
        context.fill(rect)
        context.restoreGState()
        #endif
    }
}

/// Behind the pages: the paper's own white, so a page filling the window has no edge to show.
enum PdfDesk {
    static let color = Color.white
}

nonisolated final class MarkedPages: NSObject, PDFDocumentDelegate, Sendable {
    static let shared = MarkedPages()
    func classForPage() -> AnyClass { MarkedPage.self }
}

/// The line under a highlight that is a line: 波浪线, 下划线, 点线.
nonisolated final class MarkAnnotation: PDFAnnotation {
    var markID = ""
    var style = MarkStyle.yellow

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let r = bounds
        context.saveGState()
        defer { context.restoreGState() }
        switch style {
        case .yellow, .blue, .pink:
            break
        case .underline:
            context.setStrokeColor(Self.ink)
            context.setLineWidth(max(0.8, r.height * 0.06))
            context.move(to: CGPoint(x: r.minX, y: r.minY + 0.5))
            context.addLine(to: CGPoint(x: r.maxX, y: r.minY + 0.5))
            context.strokePath()
        case .dotted:
            let w = max(1.1, r.height * 0.08)
            context.setStrokeColor(Self.ink)
            context.setLineWidth(w)
            context.setLineCap(.round)
            context.setLineDash(phase: 0, lengths: [0.01, w * 2.4])
            context.move(to: CGPoint(x: r.minX + w, y: r.minY + 0.5))
            context.addLine(to: CGPoint(x: r.maxX, y: r.minY + 0.5))
            context.strokePath()
        case .wave:
            // A red wavy line, as on the page of a book.
            let a = max(0.9, r.height * 0.07), step = a * 2.2
            context.setStrokeColor(Self.wave)
            context.setLineWidth(max(0.7, r.height * 0.05))
            var x = r.minX
            let y = r.minY + a
            context.move(to: CGPoint(x: x, y: y))
            var up = true
            while x < r.maxX {
                let next = min(r.maxX, x + step)
                context.addQuadCurve(to: CGPoint(x: next, y: y), control: CGPoint(x: (x + next) / 2, y: y + (up ? a : -a)))
                x = next
                up.toggle()
            }
            context.strokePath()
        }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
        CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    static func fill(_ style: MarkStyle) -> CGColor {
        switch style {
        case .blue: rgb(207, 230, 244)
        case .pink: rgb(246, 199, 192)
        default: rgb(251, 231, 160)
        }
    }

    private static let ink = rgb(60, 60, 64)
    private static let wave = rgb(239, 127, 113)
}

/// Keeps the highlights on the pages in step with the book's marks.
final class MarkPainter {
    private var drawn: [MarkAnnotation] = []
    /// Where each mark lies, line by line, to find the one under the pointer.
    private var lines: [(page: PDFPage, rect: CGRect, id: String)] = []
    private var filled: Set<PDFPage> = []
    private var shown: [Mark]?

    func paint(_ marks: [Mark], in model: PdfModel, view: PDFView) {
        guard marks != shown else { return }
        shown = marks
        var touched = filled
        for a in drawn {
            if let page = a.page { touched.insert(page) }
            a.page?.removeAnnotation(a)
        }
        for page in filled { (page as? MarkedPage)?.fills = [] }
        drawn = []
        lines = []
        filled = []
        for mark in marks {
            for piece in model.selections(of: mark) {
                for line in piece.selectionsByLine() {
                    guard let page = line.pages.first else { continue }
                    let r = line.bounds(for: page)
                    guard r.width > 0.5, r.height > 0.5 else { continue }
                    lines.append((page, r, mark.id))
                    touched.insert(page)
                    if mark.style.fills {
                        (page as? MarkedPage)?.fills.append((r, MarkAnnotation.fill(mark.style)))
                        filled.insert(page)
                    } else {
                        let a = MarkAnnotation(bounds: r, forType: .stamp, withProperties: nil)
                        a.markID = mark.id
                        a.style = mark.style
                        page.addAnnotation(a)
                        drawn.append(a)
                    }
                }
            }
        }
        for page in touched { view.annotationsChanged(on: page) }
    }

    /// Draws the coloured pages again, after 夜间 changed.
    func refresh(_ view: PDFView) {
        for page in filled { view.annotationsChanged(on: page) }
    }

    /// The highlight under a point on a page, if any.
    func mark(at point: CGPoint, on page: PDFPage) -> String? {
        lines.last { $0.page == page && $0.rect.insetBy(dx: -1, dy: -2).contains(point) }?.id
    }
}
