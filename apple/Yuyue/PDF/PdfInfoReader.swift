import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import YuyueCore

/// What the core can't read from a PDF itself: how many pages, the title and author the file
/// carries (when they are a person's, not a word processor's), how much text, and the first page
/// as a cover.
nonisolated enum PdfInfoReader {
    enum Failure: Error { case locked, unreadable }

    static func read(_ url: URL) throws(Failure) -> PdfInfo {
        guard let doc = PDFDocument(url: url) else { throw .unreadable }
        if doc.isLocked, !doc.unlock(withPassword: "") { throw .locked }
        guard doc.pageCount > 0 else { throw .unreadable }
        let attributes = doc.documentAttributes ?? [:]
        let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String).flatMap(sensible)
        let authors = (attributes[PDFDocumentAttribute.authorAttribute] as? String).flatMap(sensible)
            .map { $0.split(whereSeparator: { ",;，；、".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) } } ?? []
        // Counting a thousand pages takes a while; the first hundred tell enough.
        let sample = min(doc.pageCount, 100)
        var characters = 0
        for i in 0..<sample {
            characters += doc.page(at: i)?.string?.count(where: { !$0.isWhitespace }) ?? 0
        }
        let total = UInt64(Double(characters) * Double(doc.pageCount) / Double(sample))
        // A first page full of text (a paper, a report) shrunk down is a grey smudge; such a
        // PDF gets the paper cover with its title instead. A cover page, a scan, a picture stays.
        let first = doc.page(at: 0)
        let wordy = (first?.string?.count(where: { !$0.isWhitespace }) ?? 0) > textCoverLimit
        return PdfInfo(pages: UInt32(doc.pageCount), title: title, authors: authors.filter { !$0.isEmpty },
                       characters: total, cover: wordy ? nil : first.flatMap(cover))
    }

    /// More characters than a cover page has (a title, a name, a few lines): a page of text.
    static let textCoverLimit = 400

    /// "Microsoft Word - 报告.docx", "untitled", "1234.pdf": not titles.
    private static func sensible(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        let junk = ["microsoft", "untitled", String(localized: "无标题"), ".doc", ".pdf", ".tex", ".indd", ".qxd", "acrobat", "powerpoint", "adobe"]
        guard t.count >= 2, !junk.contains(where: lower.contains), t.contains(where: \.isLetter) else { return nil }
        return t
    }

    /// The first page, 600 pixels wide, on white.
    static func cover(_ page: PDFPage) -> Data? {
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = 600 / size.width
        let w = 600, h = Int((size.height * scale).rounded())
        guard h > 0, h < 4000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
