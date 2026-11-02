import ImageIO
import SwiftUI
import YuyueCore

/// The cover, or a plain paper with the title when the book has none.
struct BookCover: View {
    let book: BookSummary
    @State private var image: CGImage?
    /// 墨水屏模式: covers in grey.
    @AppStorage(EInk.key) private var eink = false

    var body: some View {
        if book.format == .audio {
            // A recording's cover is square, at the bottom of the book's place.
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    SquareCover(book: book, shadow: false)
                }
        } else {
            page
        }
    }

    private var page: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipShape(.rect(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(YYColor.line, lineWidth: 0.5))
            .grayscale(eink ? 1 : 0)
            .shadow(color: .black.opacity(eink ? 0 : 0.08), radius: 6, y: 3)
            .task(id: book.coverPath) {
                image = await Thumbnail.load(book.coverPath, maxPixels: 600)
            }
    }

    private var placeholder: some View {
        // Sized to the cover, so it reads the same on a small card and in the grid.
        GeometryReader { g in
            let unit = g.size.width / 100
            ZStack(alignment: .topLeading) {
                YYPaper.kami.bg
                VStack(alignment: .leading, spacing: 5 * unit) {
                    Text(book.title)
                        .font(YYFontFamily.serif.font(size: 14 * unit, weight: .semibold))
                        .foregroundStyle(YYPaper.kami.ink)
                        .lineLimit(4)
                    if let author = book.authors.first {
                        Text(author)
                            .font(YYFontFamily.serif.font(size: 9.5 * unit))
                            .foregroundStyle(YYPaper.kami.ink2)
                            .lineLimit(1)
                    }
                }
                .padding(11 * unit)
            }
        }
        // The title and author are read out below the cover already.
        .accessibilityHidden(true)
    }
}

enum Thumbnail {
    /// Decodes a small version of an image file off the main thread.
    @concurrent nonisolated static func load(_ path: String?, maxPixels: Int) async -> CGImage? {
        guard let path, let source = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
