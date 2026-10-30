#if os(iOS)
import PhotosUI
import SwiftUI
import YuyueCore

/// 书的信息 (prototype 书的信息), from 长按 · 编辑信息: the cover and 换封面, the name and author
/// the shelf shows, and what belongs to this book alone — its status, its 合集, its rules, the
/// space it takes.
struct PhoneBookInfo: View {
    let library: Library
    let book: BookSummary
    @State private var title: String
    @State private var author: String
    @State private var picking = false
    @State private var photo: PhotosPickerItem?
    @State private var fileSize: Int64?
    @State private var txtDoubt: String?
    @Environment(\.dismiss) private var dismiss

    init(library: Library, book: BookSummary) {
        self.library = library
        self.book = book
        _title = State(initialValue: book.title)
        _author = State(initialValue: book.authors.joined(separator: "、"))
    }

    private var current: BookSummary { library.books.first { $0.id == book.id } ?? book }

    var body: some View {
        NavigationStack {
            YYPage {
                coverPart
                YYGroup {
                    YYField(label: String(localized: "书名"), labelWidth: 44) {
                        TextField("", text: $title, prompt: Text("留空就用文件里的"))
                    }
                    YYField(label: String(localized: "作者"), labelWidth: 44) {
                        TextField("", text: $author, prompt: Text("几位作者用顿号隔开"))
                    }
                }
                .foregroundStyle(YYColor.t1)
                .padding(.bottom, YYUI.s(14))
                groupLabel(String(localized: "这本书"))
                YYGroup {
                    Menu {
                        Toggle("在读", isOn: Binding(get: { current.status == .reading }, set: { if $0 { library.setFinished(current, false) } }))
                        Toggle(String(localized: "读完了"), isOn: Binding(get: { current.status == .finished }, set: { if $0 { library.setFinished(current, true) } }))
                    } label: {
                        YYRow(String(localized: "状态"), value: current.status.name, chevron: true)
                    }
                    .buttonStyle(.plain)
                    Button { picking = true } label: {
                        YYRow(String(localized: "合集"), value: collections.isEmpty ? String(localized: "没有") : collections, chevron: true)
                    }
                    .buttonStyle(.plain)
                    if current.format != .pdf {
                        NavigationLink {
                            ReplaceRulesView(core: library.core, bookID: book.id, bookTitle: current.title)
                        } label: {
                            YYRow(String(localized: "替换规则"), value: ruleCount == 0 ? String(localized: "没有") : String(localized: "\(ruleCount) 条"), chevron: true)
                        }
                        .buttonStyle(.plain)
                    }
                    if current.format == .txt {
                        NavigationLink {
                            TxtLayoutView(library: library, bookID: book.id, bookTitle: current.title) { dismiss() }
                        } label: {
                            YYRow(title: String(localized: "编码和目录"), chevron: true) {
                                if let txtDoubt {
                                    Label(txtDoubt, systemImage: "exclamationmark.triangle.fill")
                                        .font(YYUI.font(10.5)).foregroundStyle(YYColor.warn).lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if current.readMinutes > 0 {
                        YYRow(String(localized: "读了"), value: durationText(seconds: Int(current.readMinutes) * 60))
                    }
                    if current.listenMinutes > 0 {
                        YYRow(String(localized: "听了"), value: durationText(seconds: Int(current.listenMinutes) * 60))
                    }
                }
                .padding(.bottom, YYUI.s(14))
                groupLabel(String(localized: "占用空间"))
                YYGroup {
                    YYRow(String(localized: "书文件"), value: "\(formatName) · \(fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")")
                }
                YYNote(String(localized: "书名和作者只改书架上显示的，书的文件不动。"))
            }
            .navigationTitle("书的信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("取消")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        let authors = author.split(whereSeparator: { "、,，;；/".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
                        if title != book.title || authors != book.authors {
                            library.editInfo(book, title: title, authors: authors)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $picking) {
                CollectionPicker(library: library, bookID: book.id) { picking = false }
                    .frame(maxWidth: .infinity)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(YYColor.bg)
            }
            .onChange(of: photo) {
                guard let photo else { return }
                Task {
                    if let data = try? await photo.loadTransferable(type: Data.self) {
                        library.setCover(current, image: data)
                    }
                    self.photo = nil
                }
            }
            .task {
                if book.format == .txt { txtDoubt = (try? library.core.txtDoubt(bookId: book.id)) ?? nil }
                if let url = library.originalFile(of: book) {
                    fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                } else {
                    fileSize = 0
                }
            }
        }
    }

    /// `.v-lib-cvw`: the cover a size smaller, 换封面 under it.
    private var coverPart: some View {
        VStack(spacing: YYUI.s(8)) {
            BookCover(book: current)
                .frame(width: YYUI.s(58))
                .shadow(color: Color(yy: YYRGBA(30, 30, 30, 0.16)), radius: YYUI.s(6), y: YYUI.s(4))
            PhotosPicker(selection: $photo, matching: .images) {
                Text("换封面").font(YYUI.font(11, .semibold)).foregroundStyle(YYTint.standard.accent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, YYUI.s(10))
        .padding(.bottom, YYUI.s(14))
    }

    /// `.gl`: the small grey name over a group.
    private func groupLabel(_ text: String) -> some View {
        Text(text).font(YYUI.font(10)).foregroundStyle(YYColor.t3)
            .padding(.horizontal, YYUI.s(4)).padding(.bottom, YYUI.s(6))
    }

    private var ruleCount: Int {
        (try? library.core.replaceRules(book: book.id).count) ?? 0
    }

    private var collections: String {
        library.collections.filter { current.collections.contains($0.id) }.map(\.name).joined(separator: "、")
    }

    private var formatName: String {
        switch book.format {
        case .epub: "EPUB"
        case .txt: "TXT"
        case .pdf: "PDF"
        case .mobi: "MOBI"
        }
    }
}
#endif
