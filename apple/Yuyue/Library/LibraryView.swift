import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import YuyueCore

struct LibraryView: View {
    @Bindable var library: Library
    @State private var importerShown = false
    #if os(iOS)
    @State private var reading: BookSummary?
    @Namespace private var covers
    #else
    @Environment(\.openWindow) private var openWindow
    #endif

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 20, alignment: .top)]

    var body: some View {
        NavigationStack {
            Group {
                if library.books.isEmpty {
                    ContentUnavailableView {
                        Label("书架是空的", systemImage: "books.vertical")
                    } description: {
                        Text("导入 EPUB、PDF、MOBI、TXT 或漫画就能开始读")
                    } actions: {
                        Button("导入书") { importerShown = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 28) {
                            ForEach(library.books) { book in
                                cell(book)
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("书架")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if library.importing > 0 {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("导入", systemImage: "plus") { importerShown = true }
                    }
                }
            }
        }
        .fileImporter(isPresented: $importerShown, allowedContentTypes: Library.importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await library.importFiles(urls) }
            }
        }
        .onOpenURL { url in
            Task { await library.importFiles([url]) }
        }
        #if os(macOS)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await library.importFiles(urls) }
            return true
        }
        #else
        .fullScreenCover(item: $reading) { book in
            ReaderScreen(library: library, bookID: book.id)
                .navigationTransition(.zoom(sourceID: book.id, in: covers))
        }
        #endif
        .alert("没能导入", isPresented: Binding(get: { library.alert != nil }, set: { if !$0 { library.alert = nil } })) {
            Button("好") {}
        } message: {
            Text(library.alert ?? "")
        }
    }

    private func cell(_ book: BookSummary) -> some View {
        Button {
            #if os(iOS)
            reading = book
            #else
            openWindow(id: "reader", value: book.id)
            #endif
        } label: {
            BookCell(book: book)
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .matchedTransitionSource(id: book.id, in: covers)
        #endif
        .contextMenu {
            Button("删除", systemImage: "trash", role: .destructive) { library.delete(book) }
        }
    }
}

struct BookCell: View {
    let book: BookSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BookCover(book: book)
            Text(book.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(YYColor.t1)
                .lineLimit(2)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(YYColor.t2)
                .lineLimit(1)
        }
        .contentShape(.rect)
    }

    private var subtitle: String {
        if book.progress > 0 {
            // Just started still reads as started.
            return String(localized: "读到 \(max(1, Int((book.progress * 100).rounded())))%")
        }
        return book.authors.first ?? String(localized: "读 \(book.readMinutes) 分钟 · 听 \(book.listenMinutes) 分钟")
    }
}

/// The cover, or a plain paper with the title when the book has none.
struct BookCover: View {
    let book: BookSummary
    @State private var image: CGImage?
    /// 墨水屏模式: covers in grey.
    @AppStorage(EInk.key) private var eink = false

    var body: some View {
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

extension View {
    /// A comic of many 话 sits as a little stack: two page edges behind the cover, and how many
    /// 话 in the corner.
    func comicStack(_ book: BookSummary) -> some View {
        modifier(ComicStack(episodes: book.isComic ? Int(book.episodes) : 0))
    }
}

private struct ComicStack: ViewModifier {
    let episodes: Int

    func body(content: Content) -> some View {
        if episodes > 1 {
            content
                .background(alignment: .top) {
                    GeometryReader { g in
                        let w = g.size.width
                        ZStack(alignment: .top) {
                            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                                .fill(YYColor.t3.opacity(0.35))
                                .frame(width: w * 0.72, height: 6)
                                .offset(y: -7)
                            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                                .fill(YYColor.t3.opacity(0.6))
                                .frame(width: w * 0.86, height: 6)
                                .offset(y: -4)
                        }
                        .frame(width: w)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    Text("\(episodes) 话")
                        .font(.yy(size: 10)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(.black.opacity(0.58), in: .rect(cornerRadius: 4))
                        .padding(5)
                        .accessibilityHidden(true)
                }
        } else {
            content
        }
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
