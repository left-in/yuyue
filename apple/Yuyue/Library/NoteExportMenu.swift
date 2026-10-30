import SwiftUI
import YuyueCore

/// 导出's work outside the menu that starts it (a menu's items are gone once it closes): what
/// is being sent, and the EPUB waiting to be saved. The outcome shows as a note, like 导出好了.
@Observable
final class NoteSender {
    private(set) var sending: NoteExport.Target?
    private(set) var making = false
    var epub: URL?
    var moving = false
    @ObservationIgnored let core: YuyueCore
    /// Shows the outcome where the menu is: the library's notes or the reading window's.
    @ObservationIgnored let note: (Library.Toast) -> Void

    init(core: YuyueCore, note: @escaping (Library.Toast) -> Void) {
        self.core = core
        self.note = note
    }

    func send(_ books: [NoteExport.Book], to target: NoteExport.Target) {
        guard NoteExport.isSetUp(target) else {
            tell("exclamationmark.circle", String(localized: "还没设置 \(target.title)"), String(localized: "在设置 · 数据 · 笔记导出里填好"))
            return
        }
        sending = target
        Task {
            defer { sending = nil }
            do {
                let n = try await NoteExport.send(books, to: target)
                tell("checkmark.circle", String(localized: "发到了 \(target.title)"), n == 0 ? String(localized: "没有新的划线") : String(localized: "\(n) 条划线"))
            } catch {
                tell("exclamationmark.circle", String(localized: "没发出去"), Self.message(error))
            }
        }
    }

    func makeEpub(_ book: BookSummary) {
        making = true
        Task {
            defer { making = false }
            do {
                epub = try await NoteExport.epub(core: core, book: book)
                moving = true
            } catch {
                tell("exclamationmark.circle", String(localized: "没导出来"), Self.message(error))
            }
        }
    }

    func saved(_ result: Result<URL, Error>) {
        if case .success(let url) = result { tell("square.and.arrow.up", String(localized: "导出好了"), url.lastPathComponent) }
        epub = nil
    }

    private func tell(_ icon: String, _ title: String, _ detail: String) {
        note(Library.Toast(icon: icon, title: title, detail: detail))
    }

    static func message(_ error: Error) -> String {
        switch error {
        case let e as NoteExport.Failure: e.errorDescription ?? ""
        case let e as CoreError: Library.message(for: e)
        case let e as URLError where e.code == .notConnectedToInternet: String(localized: "没有联网")
        default: error.localizedDescription
        }
    }
}

/// 发到 Obsidian / Notion / flomo, and for one book EPUB（书和笔记一起）: items for a menu.
struct NoteSendItems: View {
    let sender: NoteSender
    /// What goes out; made only when one is picked.
    let books: () -> [NoteExport.Book]
    var book: BookSummary?

    var body: some View {
        ForEach(NoteExport.Target.allCases) { t in
            Button {
                sender.send(books(), to: t)
            } label: {
                Label(String(localized: "发到 \(t.title)") + (sender.sending == t ? " …" : ""), systemImage: t.symbol)
            }
            .disabled(sender.sending != nil)
        }
        if let book, book.format != .pdf {
            Divider()
            Button {
                sender.makeEpub(book)
            } label: {
                Label(String(localized: "EPUB（书和笔记一起）"), systemImage: "book.closed")
            }
            .disabled(sender.making)
        }
    }
}

extension View {
    /// Where the EPUB that `sender` made is saved.
    func noteSender(_ sender: NoteSender) -> some View {
        modifier(NoteSenderSaving(sender: sender))
    }
}

private struct NoteSenderSaving: ViewModifier {
    @Bindable var sender: NoteSender

    func body(content: Content) -> some View {
        content.fileMover(isPresented: $sender.moving, file: sender.epub) { sender.saved($0) }
    }
}

/// 导出 as a menu: Markdown to share, then the 发到 items.
struct NoteExportMenu<MenuLabel: View>: View {
    let sender: NoteSender
    /// The Markdown to share, and its file name.
    let markdown: String
    let name: String
    let books: () -> [NoteExport.Book]
    var book: BookSummary?
    @ViewBuilder let label: MenuLabel

    var body: some View {
        Menu {
            ShareLink(item: MarkdownFile(text: markdown, name: name), preview: SharePreview(name)) {
                Label("Markdown", systemImage: "doc.plaintext")
            }
            Divider()
            NoteSendItems(sender: sender, books: books, book: book)
        } label: {
            label
        }
        #if os(macOS)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        #endif
        .noteSender(sender)
    }
}

/// Markdown handed to the share sheet as a `.md` file.
nonisolated struct MarkdownFile: Transferable, Sendable {
    let text: String
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { file in
            let dir = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(path: file.name.replacingOccurrences(of: "/", with: "-"))
            try Data(file.text.utf8).write(to: url)
            return SentTransferredFile(url)
        }
    }
}
