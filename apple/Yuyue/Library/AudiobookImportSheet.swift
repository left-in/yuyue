import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import YuyueCore

extension View {
    /// 导入有声书, over the shelf while a recording waits to be looked over.
    func recordingImportSheet(_ library: Library) -> some View {
        sheet(item: Binding(get: { library.pendingRecording }, set: { if $0 == nil { library.cancelRecording() } })) { pending in
            AudiobookImportSheet(library: library, pending: pending)
        }
    }
}

/// 导入有声书 (prototype v0.30 C1): the cover, name and author read from the files, to change;
/// the files in the order they'll play, by the numbers in their names, to drag into another;
/// and, when the e-book is on the shelf, 合成听读书 after.
struct AudiobookImportSheet: View {
    let library: Library
    @State private var pending: Library.PendingRecording
    @State private var title: String
    @State private var author: String
    @State private var pair = true
    @State private var photo: PhotosPickerItem?
    @State private var coverImage: CGImage?
    @Environment(\.dismiss) private var dismiss

    init(library: Library, pending: Library.PendingRecording) {
        self.library = library
        _pending = State(initialValue: pending)
        _title = State(initialValue: pending.audio.title)
        _author = State(initialValue: pending.audio.authors.joined(separator: "、"))
    }

    private var total: Double { pending.audio.files.reduce(0) { $0 + $1.seconds } }
    /// An M4B's own chapters: the order is in the file, nothing to sort.
    private var marked: Bool { !pending.audio.marks.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: YYUI.s(12)) {
            HStack {
                Text("导入有声书").font(YYUI.font(14, .semibold)).foregroundStyle(YYColor.t1)
                Spacer()
                Button("取消") { library.cancelRecording() }
                    .buttonStyle(.plain)
                    .font(YYUI.font(12))
                    .foregroundStyle(YYColor.t2)
                    .keyboardShortcut(.cancelAction)
                Button("完成", action: finish)
                    .buttonStyle(.plain)
                    .font(YYUI.font(12, .semibold))
                    .foregroundStyle(YYTint.standard.accent)
                    .keyboardShortcut(.defaultAction)
                    .padding(.leading, YYUI.s(10))
            }
            head
            if marked {
                YYLabel(String(localized: "章节 · 文件里自带的"))
                list(rows: pending.audio.marks.enumerated().map { i, m in (String(i + 1), m.title ?? String(localized: "第 \(i + 1) 集"), "") }, movable: false)
            } else {
                YYLabel(String(localized: "章节顺序 · 按文件名里的数字排"))
                list(rows: pending.names.enumerated().map { i, n in (String(i + 1), n, AudiobookPlayer.clock(pending.audio.files[i].seconds)) }, movable: pending.names.count > 1)
                if pending.names.count > 1 {
                    YYNote(String(localized: "“第 2 集”排在“第 10 集”前面。顺序不对，按住一行拖。"))
                }
            }
            if let match = pending.match {
                Toggle(isOn: $pair) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("书架上有《\(match.title)》电子书").font(YYUI.font(12))
                        Text("导入后合成听读书：听到哪句，书页就走到哪句").font(YYUI.font(10)).foregroundStyle(YYColor.t3)
                    }
                }
                .toggleStyle(.switch)
                .tint(YYTint.standard.accent)
                .padding(YYUI.s(12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .yyCard()
            }
        }
        .padding(YYUI.s(16))
        #if os(macOS)
        .frame(width: 420)
        .frame(minHeight: 420)
        #endif
        .background(YYColor.bg)
        .task(id: pending.audio.cover) {
            coverImage = pending.audio.cover.flatMap { data in
                CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 300] as CFDictionary) }
            }
        }
        .onChange(of: photo) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self) { pending.audio.cover = data }
            }
        }
    }

    private var head: some View {
        HStack(spacing: YYUI.s(12)) {
            ZStack {
                YYColor.inset
                if let coverImage {
                    Image(decorative: coverImage, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: "headphones").font(.system(size: 20)).foregroundStyle(YYColor.t3)
                }
            }
            .frame(width: YYUI.s(64), height: YYUI.s(64))
            .clipShape(.rect(cornerRadius: YYUI.s(8)))
            VStack(alignment: .leading, spacing: YYUI.s(4)) {
                TextField("书名", text: $title)
                    .textFieldStyle(.plain)
                    .font(YYUI.font(13, .bold))
                TextField("作者", text: $author)
                    .textFieldStyle(.plain)
                    .font(YYUI.font(11))
                    .foregroundStyle(YYColor.t2)
                Text(String(localized: "\(pending.audio.files.count) 个文件 · \(Audiobook.length(total))"))
                    .font(YYUI.font(10.5))
                    .foregroundStyle(YYColor.t3)
                coverButton
            }
        }
    }

    @ViewBuilder private var coverButton: some View {
        #if os(macOS)
        Button("换封面") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.prompt = String(localized: "用作封面")
            if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) { pending.audio.cover = data }
        }
        .buttonStyle(.plain)
        .font(YYUI.font(10, .semibold))
        .foregroundStyle(YYTint.standard.accent)
        #else
        PhotosPicker(selection: $photo, matching: .images) {
            Text("换封面").font(YYUI.font(10, .semibold)).foregroundStyle(YYTint.standard.accent)
        }
        .buttonStyle(.plain)
        #endif
    }

    private func list(rows: [(String, String, String)], movable: Bool) -> some View {
        let items: [FileRow] = rows.enumerated().map { FileRow(id: $0.offset, number: $0.element.0, name: $0.element.1, length: $0.element.2) }
        let reorder: ((IndexSet, Int) -> Void)? = movable ? { move($0, $1) } : nil
        return List {
            ForEach(items) { row in row }
                .onMove(perform: reorder)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { RoundedRectangle(cornerRadius: YYUI.s(14)).fill(YYColor.card) }
        .frame(minHeight: YYUI.s(160), maxHeight: YYUI.s(320))
        #if os(iOS)
        .environment(\.editMode, Binding<EditMode>.constant(movable ? .active : .inactive))
        #endif
    }

    private func move(_ from: IndexSet, _ to: Int) {
        pending.audio.files.move(fromOffsets: from, toOffset: to)
        pending.names.move(fromOffsets: from, toOffset: to)
    }

    private func finish() {
        var p = pending
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { p.audio.title = t }
        p.audio.authors = author.split(whereSeparator: { "、,，/".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let match = p.match
        guard let book = library.finishRecording(p) else { return }
        // 导入后合成听读书: the recording goes to be laid against the e-book.
        if pair, let match { library.pair(book, with: match) }
    }
}

/// A file on 导入有声书: its place, its name as it was, how long it is.
private struct FileRow: View, Identifiable {
    let id: Int
    let number: String
    let name: String
    let length: String

    var body: some View {
        HStack(spacing: YYUI.s(10)) {
            Text(number).font(YYUI.font(10).monospacedDigit()).foregroundStyle(YYColor.t3).frame(width: YYUI.s(20), alignment: .leading)
            Text(name).font(.system(size: 11, design: .monospaced)).foregroundStyle(YYColor.t2).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(length).font(YYUI.font(10.5).monospacedDigit()).foregroundStyle(YYColor.t3)
        }
        .listRowBackground(YYColor.card)
    }
}
