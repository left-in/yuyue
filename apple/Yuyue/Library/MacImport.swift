import SwiftUI
import YuyueCore
#if os(macOS)
import UniformTypeIdentifiers

/// `.v-ms-imp` (prototype 38): at the top of the shelf while files come in — one row each, with
/// where it went, what's being read, or that it was already there and where to find it.
struct MacImportCard: View {
    let library: Library
    let tint: YYTint
    /// 在书架里显示.
    let reveal: (String) -> Void

    private var files: [ImportFile] { library.imports }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.to.line")
                    .font(.yy(size: 11, weight: .semibold))
                    .foregroundStyle(tint.accent)
                    .frame(width: 24, height: 24)
                    .background(tint.accentSoft, in: .rect(cornerRadius: 7))
                Text(title).font(.yy(size: 12.5, weight: .semibold)).foregroundStyle(YYColor.t1)
                Text(note).font(.yy(size: 11).monospacedDigit()).foregroundStyle(YYColor.t3)
                Spacer(minLength: 0)
                Button { withAnimation(.easeOut(duration: 0.2)) { library.closeImports() } } label: {
                    Image(systemName: "xmark")
                        .accessibilityLabel(Text("关闭"))
                        .font(.yy(size: 9, weight: .semibold))
                        .foregroundStyle(YYColor.t2)
                        .frame(width: 22, height: 22)
                        .background(YYColor.inset, in: .circle)
                }
                .buttonStyle(.plain)
                .help("收起")
            }
            bar(Double(files.count(where: \.settled)) / Double(max(files.count, 1)))
                .padding(.top, 10)
                .padding(.bottom, 2)
            ForEach(Array(files.enumerated()), id: \.element.id) { i, file in
                if i > 0 { Rectangle().fill(YYColor.line).frame(height: 0.5) }
                row(file)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .background(YYColor.card, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
    }

    private var title: String {
        files.allSatisfy(\.settled) ? String(localized: "导入了 \(files.count) 个文件") : String(localized: "正在导入 \(files.count) 个文件")
    }

    /// `第 2 / 3 个 · 还要几秒`, then how it went.
    private var note: String {
        let done = files.filter(\.settled)
        guard done.count < files.count else {
            let added = files.count(where: \.added)
            let failed = files.count { if case .failed = $0.state { true } else { false } }
            var parts = [String(localized: "\(added) 个进了书架")]
            if added < files.count - failed { parts.append(String(localized: "\(files.count - failed - added) 个已经有了")) }
            if failed > 0 { parts.append(String(localized: "\(failed) 个没导入")) }
            return parts.joined(separator: " · ")
        }
        var text = String(localized: "第 \(done.count + 1) / \(files.count) 个")
        if let took = done.compactMap(\.took).max(), took > 0 {
            let left = took / Double(done.count) * Double(files.count - done.count)
            text += left < 10 ? String(localized: " · 还要几秒") : left < 60 ? String(localized: " · 还要 \(Int(left)) 秒") : String(localized: " · 还要 \(Int(left / 60) + 1) 分钟")
        }
        return text
    }

    private func bar(_ fraction: Double) -> some View {
        Capsule().fill(YYColor.inset)
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(tint.accent).frame(width: g.size.width * fraction)
                }
            }
            .animation(.easeOut(duration: 0.25), value: fraction)
    }

    private func row(_ file: ImportFile) -> some View {
        HStack(spacing: 12) {
            cover(file)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.yy(size: 12, weight: .semibold)).foregroundStyle(YYColor.t1).lineLimit(1).truncationMode(.middle)
                Text(detail(file))
                    .font(.yy(size: 10.5).monospacedDigit())
                    .foregroundStyle(file.state == .waiting || file.added ? YYColor.t3 : YYColor.t2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing(file)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private func cover(_ file: ImportFile) -> some View {
        Group {
            if let id = bookID(file), let book = library.books.first(where: { $0.id == id }) {
                BookCover(book: book)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(YYColor.inset)
                    .overlay {
                        Text(file.name.split(separator: ".").last.map { $0.uppercased() } ?? "")
                            .font(.yy(size: 6, weight: .heavy))
                            .foregroundStyle(YYColor.t3)
                    }
                    .opacity(file.state == .waiting ? 0.4 : 1)
            }
        }
        .frame(width: 24, height: 36)
    }

    private func bookID(_ file: ImportFile) -> String? {
        switch file.state {
        case .added(let id, _), .already(let id): id
        default: nil
        }
    }

    private func detail(_ file: ImportFile) -> String {
        switch file.state {
        case .waiting: String(localized: "排队中")
        case .reading: String(localized: "正在读目录和封面")
        case .added(_, let line): line
        case .already: String(localized: "书架里已经有这本了，没有再导入一份")
        case .failed(let why): why
        }
    }

    @ViewBuilder private func trailing(_ file: ImportFile) -> some View {
        switch file.state {
        case .waiting:
            EmptyView()
        case .reading:
            ProgressView().progressViewStyle(.linear).controlSize(.small).tint(tint.accent).frame(width: 90)
        case .added:
            Label("已导入", systemImage: "checkmark")
                .labelStyle(TightLabel())
                .font(.yy(size: 11, weight: .semibold))
                .foregroundStyle(YYColor.ok)
        case .already(let id):
            Button { reveal(id) } label: {
                HStack(spacing: 2) {
                    Text("在书架里显示")
                    Image(systemName: "chevron.right").font(.yy(size: 9, weight: .semibold))
                }
                .font(.yy(size: 11, weight: .semibold))
                .foregroundStyle(tint.accent)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        case .failed:
            Text("没导入").font(.yy(size: 11, weight: .semibold)).foregroundStyle(YYColor.danger)
        }
    }

    private struct TightLabel: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) { configuration.icon; configuration.title }
        }
    }
}

/// `.v-ms-drop`: over the shelf while files are dragged in from Finder — how many, where they'll
/// go, and what can be read.
struct MacDropHint: View {
    let count: Int
    let place: String
    let tint: YYTint

    var body: some View {
        ZStack {
            YYColor.bg.opacity(0.84)
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(tint.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                .background(tint.accent.opacity(0.03), in: .rect(cornerRadius: 18))
                .padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 12)
            VStack(spacing: 0) {
                Image(systemName: "arrow.down.to.line")
                    .font(.yy(size: 26, weight: .light))
                    .foregroundStyle(tint.accent)
                    .frame(width: 64, height: 64)
                    .background(tint.accentSoft, in: .circle)
                    .padding(.bottom, 16)
                Text(count > 1 ? String(localized: "松手就导入这 \(count) 个文件") : String(localized: "松手就导入"))
                    .font(.yy(size: 20, weight: .bold))
                    .foregroundStyle(YYColor.t1)
                Text("放进“\(place)”。书名、作者和封面从文件里读出来，之后都能改")
                    .font(.yy(size: 12.5))
                    .foregroundStyle(YYColor.t2)
                    .padding(.top, 6)
                    .padding(.bottom, 20)
                VStack(alignment: .leading, spacing: 9) {
                    formats(String(localized: "书"), ["EPUB", "TXT", "PDF", "MOBI", "AZW3"])
                    formats(String(localized: "有声书"), ["M4B", "MP3"])
                }
                .padding(.leading, 16).padding(.trailing, 20).padding(.vertical, 14)
                .background(YYColor.card, in: .rect(cornerRadius: 14))
                .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.yy(size: 13)).foregroundStyle(YYColor.ok)
                    Text("同一个文件只导入一次：按内容认，改过名字也认得出来")
                }
                .font(.yy(size: 11.5))
                .foregroundStyle(YYColor.t2)
                .padding(.top, 16)
            }
            .multilineTextAlignment(.center)
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .allowsHitTesting(false)
    }

    private func formats(_ kind: String, _ names: [String]) -> some View {
        HStack(spacing: 5) {
            Text(kind)
                .font(.yy(size: 11, weight: .semibold))
                .foregroundStyle(YYColor.t2)
                .frame(width: 46, alignment: .trailing)
                .padding(.trailing, 6)
            ForEach(names, id: \.self) { name in
                Text(name)
                    .font(.yy(size: 10.5, weight: .medium))
                    .foregroundStyle(YYColor.t2)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(YYColor.inset, in: .rect(cornerRadius: 5))
            }
        }
    }
}

/// Files from Finder, and on the sidebar's collections books from the shelf too: says how many
/// files hover, and hands over what was let go.
struct ShelfDrop: DropDelegate {
    /// How many files are over it, nil when none.
    @Binding var hovering: Int?
    var acceptsBooks = false
    let files: ([URL]) -> Void
    var books: ([String]) -> Void = { _ in }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL]) || (acceptsBooks && info.hasItemsConforming(to: [.utf8PlainText, .plainText]))
    }

    func dropEntered(info: DropInfo) {
        let files = info.itemProviders(for: [.fileURL]).count
        hovering = files > 0 ? files : acceptsBooks ? 0 : nil
    }

    func dropExited(info: DropInfo) { hovering = nil }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: info.hasItemsConforming(to: [.fileURL]) ? .copy : .move) }

    func performDrop(info: DropInfo) -> Bool {
        hovering = nil
        let urls = info.itemProviders(for: [.fileURL])
        let texts = urls.isEmpty && acceptsBooks ? info.itemProviders(for: [.utf8PlainText, .plainText]) : []
        let (files, books) = (files, books)
        Task {
            if !urls.isEmpty {
                var got: [URL] = []
                for p in urls { if let url = await Self.load(p, URL.self) { got.append(url) } }
                files(got)
            } else {
                var got: [String] = []
                for p in texts { if let s = await Self.load(p, String.self) { got.append(s) } }
                books(got)
            }
        }
        return !urls.isEmpty || !texts.isEmpty
    }

    private static func load<T: _ObjectiveCBridgeable & Sendable>(_ provider: NSItemProvider, _: T.Type) async -> T? where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: T.self) { value, _ in done.resume(returning: value) }
        }
    }
}
#endif
