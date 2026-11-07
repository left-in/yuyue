import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// 分享书摘: one highlighted sentence on a card, with a little cover and
/// where it comes from, a small 语阅 in the corner, and the thought if wanted. Four looks — the
/// cover's own colour, 纸本, 素白, 暗黑 — and three shapes. The last look and shape are kept.
struct QuoteShare: Identifiable {
    let id = UUID()
    let text: String
    let note: String?
    let title: String
    let author: String?
    let chapter: String?
    let coverPath: String?

    /// 纯文字: the sentence and where it comes from.
    var plain: String {
        let from = ["《\(title)》", author, chapter].compactMap { $0 }.joined(separator: " ")
        return "「\(text)」\n—— \(from)"
    }
}

enum QuoteLook: String, CaseIterable, Identifiable {
    case cover, paper, white, dark
    var id: String { rawValue }

    var name: String {
        switch self {
        case .cover: String(localized: "封面色")
        case .paper: String(localized: "纸本")
        case .white: String(localized: "素白")
        case .dark: String(localized: "暗黑")
        }
    }
}

enum QuoteShape: String, CaseIterable, Identifiable {
    case portrait, square, landscape
    var id: String { rawValue }

    var name: String {
        switch self {
        case .portrait: String(localized: "竖图")
        case .square: String(localized: "方图")
        case .landscape: String(localized: "横图")
        }
    }

    var size: CGSize {
        switch self {
        case .portrait: CGSize(width: 270, height: 360)
        case .square: CGSize(width: 320, height: 320)
        case .landscape: CGSize(width: 400, height: 250)
        }
    }

}

/// The colours of one card.
struct QuoteColors {
    let bg: Color, ink: Color, ink2: Color, accent: Color
    let framed: Bool

    static func of(_ look: QuoteLook, cover: Color?) -> QuoteColors {
        switch look {
        case .cover:
            QuoteColors(bg: cover ?? Color(red: 47 / 255, green: 58 / 255, blue: 51 / 255),
                        ink: Color(red: 241 / 255, green: 234 / 255, blue: 218 / 255),
                        ink2: Color(red: 200 / 255, green: 191 / 255, blue: 166 / 255),
                        accent: Color(red: 200 / 255, green: 191 / 255, blue: 166 / 255), framed: true)
        case .paper:
            QuoteColors(bg: YYPaper.kami.bg, ink: YYPaper.kami.ink, ink2: YYPaper.kami.ink2, accent: YYPaper.kami.accent, framed: false)
        case .white:
            QuoteColors(bg: .white, ink: YYPaper.plain.ink, ink2: YYPaper.plain.ink2, accent: YYPaper.plain.paperAccent, framed: false)
        case .dark:
            QuoteColors(bg: YYPaper.dark.bg, ink: YYPaper.dark.ink, ink2: YYPaper.dark.ink2, accent: YYPaper.dark.paperAccent, framed: false)
        }
    }
}

/// The card itself, the same on screen and in the picture.
struct QuoteCard: View {
    let quote: QuoteShare
    let look: QuoteLook
    let shape: QuoteShape
    let withNote: Bool
    let cover: CGImage?
    let coverColor: Color?

    var body: some View {
        let c = QuoteColors.of(look, cover: coverColor)
        let wide = shape == .landscape
        VStack(alignment: .leading, spacing: 0) {
            if wide {
                Rectangle().fill(c.accent).frame(width: 28, height: 1).padding(.bottom, 14)
            } else {
                Text("“").font(.custom("Georgia", size: 34)).foregroundStyle(c.ink2.opacity(0.75))
                    .frame(height: 18, alignment: .top)
                    .padding(.bottom, 12)
            }
            Text(quote.text)
                .font(YYFontFamily.serif.font(size: wide ? 14.5 : 16, weight: wide ? .medium : .semibold))
                .tracking(0.5)
                .lineSpacing(wide ? 8 : 10)
                .foregroundStyle(c.ink)
                .minimumScaleFactor(0.55)
                .fixedSize(horizontal: false, vertical: false)
            if withNote, let note = quote.note {
                Text(note)
                    .font(YYFontFamily.kai.font(size: 12))
                    .lineSpacing(5)
                    .foregroundStyle(c.ink2)
                    .lineLimit(3)
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) { Rectangle().fill(c.accent).frame(width: 1.5) }
                    .padding(.top, 14)
            }
            Spacer(minLength: 12)
            HStack(alignment: .center, spacing: 8) {
                Group {
                    if let cover {
                        Image(decorative: cover, scale: 1).resizable().scaledToFill()
                    } else {
                        c.ink2.opacity(0.3)
                    }
                }
                .frame(width: 20, height: 30)
                .clipped()
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(quote.title).font(.yy(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(c.ink)
                    let sub = [quote.author, quote.chapter].compactMap { $0 }.joined(separator: " · ")
                    if !sub.isEmpty {
                        Text(sub).font(.yy(size: 9.5)).foregroundStyle(c.ink2)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Text("语阅").font(.yy(size: 9.5)).tracking(1.2).foregroundStyle(c.ink2.opacity(0.8))
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, wide ? 26 : 28)
        .padding(.top, wide ? 26 : 32)
        .padding(.bottom, 22)
        .frame(width: shape.size.width, height: shape.size.height, alignment: .topLeading)
        .background(c.bg)
        .overlay {
            if c.framed {
                Rectangle().strokeBorder(c.ink2.opacity(0.5), lineWidth: 0.6).padding(9)
            }
        }
        .environment(\.colorScheme, look == .dark ? .dark : .light)
    }
}

extension QuoteColors {
    /// The cover's average colour, deepened so light words read on it.
    static func deep(_ image: CGImage) -> Color? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let average = PlatformColor(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        average.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(max(s, 0.12), 0.38), brightness: min(b, 0.27))
    }
}

#if os(macOS)
/// 分享书摘: the card, the looks and shapes under it, and what to do with it.
struct QuoteShareSheet: View {
    let quote: QuoteShare
    let done: () -> Void
    @AppStorage("share.look") private var look = QuoteLook.cover
    @AppStorage("share.shape") private var shape = QuoteShape.portrait
    @AppStorage("share.note") private var withNote = true
    @State private var cover: CGImage?
    @State private var coverColor: Color?
    @State private var saving: PNGFile?
    @State private var copied = false

    private var card: QuoteCard {
        QuoteCard(quote: quote, look: look, shape: shape, withNote: withNote, cover: cover, coverColor: coverColor)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("分享书摘").font(.yy(size: 14, weight: .bold)).foregroundStyle(YYColor.t1)
                Spacer()
                Button(action: done) {
                    Image(systemName: "xmark").font(.yy(size: 10, weight: .bold)).foregroundStyle(YYColor.t2)
                        .accessibilityLabel(Text("关闭"))
                        .frame(width: 24, height: 24).background(YYColor.inset, in: .circle)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).padding(.top, 16)

            card
                .clipShape(.rect(cornerRadius: 6))
                .shadow(color: Color(red: 30 / 255, green: 28 / 255, blue: 24 / 255).opacity(0.22), radius: 20, y: 18)
                .frame(height: 380)
                .animation(.snappy(duration: 0.25), value: shape)

            HStack(spacing: 12) {
                ForEach(QuoteLook.allCases) { l in
                    Button { look = l } label: {
                        Circle().fill(QuoteColors.of(l, cover: coverColor).bg)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(YYColor.line, lineWidth: 0.75))
                            .padding(3)
                            .overlay(Circle().strokeBorder(look == l ? YYColor.t1 : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .help(l.name)
                }
                Text(look.name).font(.yy(size: 11)).foregroundStyle(YYColor.t2).frame(width: 44, alignment: .leading)
            }
            .padding(.bottom, 14)

            VStack(spacing: 10) {
                YYSegments(items: QuoteShape.allCases.map { ($0, $0.name) }, selection: $shape)
                SettingsCard {
                    SettingsRow(String(localized: "带上想法")) { SettingsSwitch(isOn: $withNote) }
                }
                .disabled(quote.note == nil)
                .opacity(quote.note == nil ? 0.5 : 1)
            }
            .padding(.horizontal, 18)

            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(quote.plain, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? String(localized: "拷好了") : String(localized: "纯文字"), systemImage: copied ? "checkmark" : "text.quote").frame(maxWidth: .infinity)
                }
                .help("只拷这句话和出处")
                .buttonStyle(YYButtonStyle(kind: .raised, size: .large, wide: true))
                Button { saving = render().map(PNGFile.init) } label: {
                    Label("存图", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(YYButtonStyle(kind: .raised, size: .large, wide: true))
                if let image = render() {
                    ShareLink(item: Image(nsImage: image), preview: SharePreview(String(localized: "《\(quote.title)》书摘"), image: Image(nsImage: image))) {
                        Label("分享", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(YYButtonStyle(kind: .main, size: .large, wide: true))
                }
            }
            .padding(18)
        }
        .frame(width: 440)
        .background(YYColor.bg)
        .task(id: quote.coverPath) {
            cover = await Thumbnail.load(quote.coverPath, maxPixels: 240)
            coverColor = cover.flatMap(Self.deepColor)
        }
        .fileExporter(isPresented: Binding { saving != nil } set: { if !$0 { saving = nil } },
                      document: saving, contentType: .png, defaultFilename: String(localized: "\(quote.title) 书摘")) { _ in saving = nil }
        .onChange(of: withNote) { copied = false }
    }

    /// The picture: three times the card, so it stays sharp on a phone.
    private func render() -> NSImage? {
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        return renderer.nsImage
    }

    static func deepColor(_ image: CGImage) -> Color? { QuoteColors.deep(image) }
}

private struct PNGFile: FileDocument {
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [.png] }
    let data: Data

    init(_ image: NSImage) {
        let rep = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        data = rep?.representation(using: .png, properties: [:]) ?? Data()
    }

    init(configuration: ReadConfiguration) throws { throw CocoaError(.fileReadUnsupportedScheme) }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif
