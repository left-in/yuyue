import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers
import YuyueCore
#if canImport(UIKit)
import UIKit
#endif

/// The app's handle on the core (one per process) and the shelf it shows.
@Observable
final class Library {
    let core: YuyueCore
    private(set) var books: [BookSummary] = []
    private(set) var collections: [BookCollection] = []
    private(set) var importing = 0
    /// 正在导入 (prototype 38): on the Mac, each file being brought in, one row each, until
    /// they've settled and the card folds away.
    private(set) var imports: [ImportFile] = []
    @ObservationIgnored private var importsStarted = Date()
    var alert: String?
    /// A 数据快照 opened from 文件 or dropped in, waiting to be looked at before it's brought back.
    var openedSnapshot: URL?
    /// The note at the bottom of the window after deleting or importing, with its undo.
    private(set) var toast: Toast?
    /// The book being read aloud, in whichever window.
    var listening: String? {
        didSet { keepAwake(listening != nil) }
    }
    @ObservationIgnored private var awake: NSObjectProtocol?

    @ObservationIgnored private let booksDir: URL
    /// Where the library lives: the database and the books' files.
    @ObservationIgnored let dataDir: URL
    let sync: Sync
    /// 远程书库 filled in under 书库来源.
    let sources = RemoteSources()
    /// 监听一个文件夹.
    let watched = WatchedFolder()
    /// 有声书.
    let audiobooks: Audiobooks
    @ObservationIgnored private var madeNoteSender: NoteSender?
    /// 笔记 › 导出's sends, told in the library's notes.
    var noteSender: NoteSender {
        if let s = madeNoteSender { return s }
        let s = NoteSender(core: core) { [weak self] t in self?.note(icon: t.icon, t.title, t.detail) }
        madeNoteSender = s
        return s
    }
    /// What to do when a book's window opens: from the shelf's 听 / 从头听.
    @ObservationIgnored private var intents: [String: OpenIntent] = [:]

    init() throws {
        var dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Yuyue", directoryHint: .isDirectory)
        #if DEBUG
        // `-debugLibrary <dir>` opens a scratch library instead of the real one.
        if let other = UserDefaults.standard.string(forKey: "debugLibrary") { dir = URL(filePath: other, directoryHint: .isDirectory) }
        #endif
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The core's own words (errors, 常用规则, a chapter's 读/听 line) in the interface's language.
        setUiLanguage(language: Bundle.main.preferredLocalizations.first ?? "zh-Hans")
        core = try YuyueCore.open(dataDir: dir.path(percentEncoded: false), deviceName: Self.deviceName, platform: Self.platform)
        booksDir = dir.appending(path: "books", directoryHint: .isDirectory)
        dataDir = dir
        sync = Sync(core: core)
        audiobooks = Audiobooks(core: core, dataDir: dir)
        Audiobooks.shared = audiobooks
        // Deleted books can be put back for 30 days; after that their files go.
        _ = try? core.purgeDeleted(olderThanMs: 30 * 24 * 3600 * 1000)
        reload()
        sync.changed = { [weak self] in self?.reload() }
    }

    /// 听书时 Mac 不睡着 (设置 · 通用).
    private func keepAwake(_ on: Bool) {
        if on, awake == nil, UserDefaults.standard.object(forKey: "general.keepAwake") as? Bool ?? true {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: String(localized: "听书"))
        } else if !on, let awake {
            ProcessInfo.processInfo.endActivity(awake)
            self.awake = nil
        }
    }

    func reload() {
        do {
            books = try core.books()
            collections = try core.collections()
        } catch {
            alert = Self.message(for: error)
        }
    }

    // MARK: Opening

    enum OpenIntent: Equatable {
        case listen, listenFromStart
        /// From 笔记: open at this place.
        case at(Position)
        /// From 搜索 · 问: open with 书伴 and this question.
        case ask(String)
    }

    func open(_ book: BookSummary, _ intent: OpenIntent?) {
        intents[book.id] = intent
        #if os(iOS)
        presented = book.id
        #endif
    }

    /// Opens a book at a place: a window opening takes it as its intent, one already open
    /// hears it (`readerJump`).
    func open(_ bookID: String, at position: Position) {
        intents[bookID] = .at(position)
        NotificationCenter.default.post(name: .readerJump, object: bookID)
        #if os(iOS)
        presented = bookID
        #endif
    }

    /// Hands a question to the book's 书伴, in a window open already or one about to open.
    func ask(_ question: String, in bookID: String) {
        intents[bookID] = .ask(question)
        NotificationCenter.default.post(name: .readerJump, object: bookID)
        #if os(iOS)
        presented = bookID
        #endif
    }

    #if os(iOS)
    /// The book over the tabs on the phone; opening one puts it there.
    var presented: String?
    /// A book still being read aloud after its pages were closed: the 播放条 over the tabs
    /// plays and pauses it, and opening the book again picks it up as it is.
    var nowPlaying: (any NowPlaying)? {
        didSet { if let oldValue, nowPlaying != nil, oldValue !== nowPlaying { oldValue.stopAndClose() } }
    }
    #endif

    func takeIntent(for bookID: String) -> OpenIntent? {
        intents.removeValue(forKey: bookID)
    }

    /// The imported file, for 在访达中显示.
    func originalFile(of book: BookSummary) -> URL? {
        let dir = booksDir.appending(path: book.id, directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.lastPathComponent.hasPrefix("original.") }
    }

    // MARK: Organising

    func setFinished(_ book: BookSummary, _ finished: Bool) {
        run { try core.setFinished(book: book.id, finished: finished) }
    }

    func setBook(_ book: String, in collection: String, _ inside: Bool) {
        run { try core.setInCollection(collection: collection, book: book, inside: inside) }
    }

    /// Makes a collection, with the book in it when given. Returns its id.
    @discardableResult
    func createCollection(_ name: String, with book: String? = nil) -> String? {
        var id: String?
        run { id = try core.createCollection(name: name, icon: CollectionIcon.guess(for: name), book: book).id }
        return id
    }

    func renameCollection(_ id: String, to name: String) {
        run { try core.renameCollection(id: id, name: name) }
    }

    func deleteCollection(_ collection: BookCollection) {
        run { try core.deleteCollection(id: collection.id) }
        show(Toast(icon: "trash", danger: true, title: String(localized: "已删除合集「\(collection.name)」"), detail: String(localized: "里面的书都还在")) { [weak self] in
            self?.run { try self?.core.restoreCollection(id: collection.id) }
        })
    }

    /// 合集 dragged into a new order.
    func reorderCollections(_ ids: [String]) {
        run { try core.reorderCollections(ids: ids) }
    }

    func editInfo(_ book: BookSummary, title: String, authors: [String]) {
        run { _ = try core.editBookInfo(book: book.id, title: title, authors: authors) }
    }

    /// 换封面: the picked picture, as a JPEG no bigger than a cover needs.
    func setCover(_ book: BookSummary, image: Data) {
        run {
            guard let jpeg = Self.coverJPEG(image) else { throw CocoaError(.fileReadCorruptFile) }
            _ = try core.setCover(bookId: book.id, image: jpeg)
        }
    }

    nonisolated static func coverJPEG(_ data: Data, longest: Int = 1200) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: longest,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    private func run(_ change: () throws -> Void) {
        do {
            try change()
        } catch {
            alert = Self.message(for: error)
        }
        reload()
    }

    // MARK: The note at the bottom

    struct Toast: Identifiable {
        let id = UUID()
        var icon: String
        var danger = false
        var title: String
        var detail: String
        var undo: (() -> Void)?
    }

    /// How long a note stays.
    static let toastSeconds = 8.0

    /// A note without undo.
    func note(icon: String, _ title: String, _ detail: String) {
        show(Toast(icon: icon, title: title, detail: detail))
    }

    private func show(_ toast: Toast) {
        self.toast = toast
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.toastSeconds))
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
    }

    #if DEBUG
    /// A delete note that puts nothing back, to look at it.
    func debugToast() {
        show(Toast(icon: "trash", danger: true, title: String(localized: "已删除《三体》"), detail: String(localized: "笔记和进度都留着")) {})
    }
    #endif

    /// Takes a word out of the 生词本, with 撤销.
    func deleteWord(_ word: String) {
        do {
            try core.deleteWord(word: word)
        } catch {
            alert = Self.message(for: error)
            return
        }
        NotificationCenter.default.post(name: .vocabChanged, object: nil)
        show(Toast(icon: "trash", danger: true, title: String(localized: "已删除“\(word)”"), detail: String(localized: "从生词本里拿掉了")) { [weak self] in
            try? self?.core.restoreWord(word: word)
            NotificationCenter.default.post(name: .vocabChanged, object: nil)
        })
    }

    /// Deletes highlights outside the book (笔记), with 撤销. Each is (book, mark).
    func deleteMarks(_ marks: [(String, Mark)]) {
        guard !marks.isEmpty else { return }
        do {
            for (book, mark) in marks { try core.deleteMark(book: book, id: mark.id) }
        } catch {
            alert = Self.message(for: error)
        }
        NotificationCenter.default.post(name: .notesChanged, object: nil)
        let one = marks.count == 1 ? marks[0].1 : nil
        let detail = one.map { $0.note == nil ? "“\($0.text.prefix(16))”" : String(localized: "想法也一起删了") } ?? String(localized: "\(marks.count) 条划线和它们的想法")
        show(Toast(icon: "highlighter", danger: true, title: one == nil ? String(localized: "已删除 \(marks.count) 条") : String(localized: "已删除划线"), detail: detail) { [weak self] in
            for (book, mark) in marks { try? self?.core.restoreMark(book: book, id: mark.id) }
            NotificationCenter.default.post(name: .notesChanged, object: nil)
        })
    }

    /// Writes or clears a highlight's thought outside the book.
    func setNote(_ note: String?, book: String, mark: Mark) {
        do {
            try core.setMarkNote(book: book, id: mark.id, note: note)
        } catch {
            alert = Self.message(for: error)
        }
        NotificationCenter.default.post(name: .notesChanged, object: nil)
    }

    func dismissToast() {
        toast = nil
    }

    func undo() {
        guard let toast else { return }
        self.toast = nil
        toast.undo?()
    }

    /// What 导入 can pick: books, comics as an archive or a folder of pictures.
    static let importTypes: [UTType] = [.epub, .yuyueSnapshot, .pdf, .plainText, .zip, .folder, .audio] + ["cbz", "cbr", "rar", "mobi", "azw3", "azw", "prc"].compactMap { UTType(filenameExtension: $0) }

    /// Imports the files, into the collection when given; `folder` names the watched folder
    /// they came from.
    func importFiles(_ urls: [URL], into collection: String? = nil, from folder: String? = nil) async {
        importing += 1
        defer { importing -= 1 }
        // A folder of books brings in each of them; a folder of pictures is one comic.
        let folders = urls.filter { $0.hasDirectoryPath && $0.startAccessingSecurityScopedResource() }
        defer { folders.forEach { $0.stopAccessingSecurityScopedResource() } }
        // 有声书 go to be paired with their e-book instead.
        let (recordings, rest) = Self.recordings(in: urls)
        defer {
            // After the books, so an e-book brought in with its recording is there to pair with.
            if !recordings.isEmpty {
                Task { for files in recordings { await importRecording(files) } }
            }
        }
        let urls = rest.flatMap(Self.booksInside)
        var failures: [String] = []
        var imported: [BookSummary] = []
        #if os(macOS)
        let card = true
        #else
        let card = false
        #endif
        let place = collection.flatMap { id in collections.first { $0.id == id }?.name } ?? String(localized: "全部")
        var rows: [UUID: URL] = [:]
        if card {
            if imports.allSatisfy(\.settled) {
                imports = []
                importsStarted = .now
            }
            for url in urls where url.pathExtension.lowercased() != Snapshots.fileExtension {
                let file = ImportFile(name: url.lastPathComponent)
                rows[file.id] = url
                imports.append(file)
            }
        }
        for url in urls {
            if url.pathExtension.lowercased() == Snapshots.fileExtension {
                openedSnapshot = url
                continue
            }
            let row = rows.first { $0.value == url }?.key
            let had = Set(books.map(\.id))
            setImport(row, .reading)
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                let book = try await Self.importBook(core, path: url.path(percentEncoded: false))
                if had.contains(book.id) {
                    setImport(row, .already(book.id))
                } else {
                    imported.append(book)
                    if let collection { try? core.setInCollection(collection: collection, book: book.id, inside: true) }
                    setImport(row, .added(book.id, line: Self.importedLine(book, place: place)))
                }
            } catch {
                failures.append("\(url.lastPathComponent)：\(Self.message(for: error))")
                setImport(row, .failed(Self.message(for: error)))
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
            reload()
        }
        reload()
        if card {
            foldImports()
        } else if !failures.isEmpty {
            alert = failures.joined(separator: "\n")
        } else if !imported.isEmpty {
            let first = imported[0]
            let title = folder != nil ? String(localized: "导入了 \(imported.count) 本") : imported.count == 1 ? String(localized: "已导入《\(first.title)》") : String(localized: "已导入 \(imported.count) 本书")
            show(Toast(icon: folder != nil ? "folder" : "plus", title: title, detail: folder.map { String(localized: "来自“\($0)”文件夹") } ?? String(localized: "在书架最前面")) { [weak self] in
                for book in imported { try? self?.core.deleteBook(id: book.id) }
                self?.reload()
            })
        }
    }

    /// The recordings among what was brought in: each M4B on its own, the other sound files
    /// together as one book, and a folder of sound files as one book.
    nonisolated private static func recordings(in urls: [URL]) -> ([[URL]], [URL]) {
        let isAudio = { (u: URL) in Audiobooks.extensions.contains(u.pathExtension.lowercased()) }
        var books: [[URL]] = []
        var loose: [URL] = []
        var rest: [URL] = []
        for url in urls {
            if url.hasDirectoryPath {
                let all = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])?
                    .compactMap { $0 as? URL } ?? []
                let audio = all.filter(isAudio)
                if !audio.isEmpty, !all.contains(where: { ["epub", "azw3", "mobi", "pdf", "txt", "cbz", "zip"].contains($0.pathExtension.lowercased()) }) {
                    books.append(audio)
                } else {
                    rest.append(url)
                }
            } else if url.pathExtension.lowercased() == "m4b" {
                books.append([url])
            } else if isAudio(url) {
                loose.append(url)
            } else {
                rest.append(url)
            }
        }
        if !loose.isEmpty { books.append(loose) }
        return (books, rest)
    }

    /// A recording in, then the 配对 sheet — or straight to 合成 when 以后同名的书都这样配 is on
    /// and the e-book is clear.
    private func importRecording(_ files: [URL]) async {
        let scoped = files.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        do {
            let a = try await audiobooks.add(files)
            if Audiobooks.autoPair, let book = audiobooks.match(a, in: books) {
                audiobooks.make(a, with: book)
            } else {
                audiobooks.pairing = a
            }
        } catch {
            alert = "\(files.first?.lastPathComponent ?? "")：\((error as? AudiobookError)?.message ?? Self.message(for: error))"
        }
    }

    /// The books in a folder, all the way down, unless it's the pictures of a comic.
    nonisolated private static func booksInside(_ url: URL) -> [URL] {
        let fm = FileManager.default
        let pictures: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "avif", "heic"]
        let books: Set<String> = ["epub", "azw3", "mobi", "azw", "prc", "pdf", "txt", "cbz", "cbr", "rar", "zip"]
        guard url.hasDirectoryPath,
              let top = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles),
              !top.contains(where: { pictures.contains($0.pathExtension.lowercased()) }),
              let all = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [url] }
        let found = all.compactMap { $0 as? URL }.filter { books.contains($0.pathExtension.lowercased()) }
        return found.isEmpty ? [url] : found.sorted { $0.path < $1.path }
    }

    private func setImport(_ id: UUID?, _ state: ImportFile.State) {
        guard let id, let i = imports.firstIndex(where: { $0.id == id }) else { return }
        imports[i].state = state
        if state.settled { imports[i].took = Date.now.timeIntervalSince(importsStarted) }
    }

    /// `萧红 · 已放进“全部”`.
    private static func importedLine(_ book: BookSummary, place: String) -> String {
        var parts: [String] = []
        if !book.authors.isEmpty { parts.append(book.authors.joined(separator: "、")) }
        if book.isComic, book.episodes > 1 { parts.append(String(localized: "\(book.episodes) 话")) }
        parts.append(String(localized: "已放进“\(place)”"))
        return parts.joined(separator: " · ")
    }

    /// When every file went in, the card folds a few seconds later; anything that didn't stays
    /// until it's closed.
    private func foldImports() {
        guard imports.allSatisfy(\.settled), imports.allSatisfy(\.added) else { return }
        let shown = imports.map(\.id)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, imports.map(\.id) == shown else { return }
            imports = []
        }
    }

    func closeImports() {
        imports.removeAll(where: \.settled)
    }

    /// One file that came over Wi‑Fi 传书: into the library, or why not.
    func importReceived(_ url: URL) async throws -> BookSummary {
        importing += 1
        defer { importing -= 1 }
        let book = try await Self.importBook(core, path: url.path(percentEncoded: false))
        reload()
        return book
    }

    /// Deletes straight away; the note at the bottom can put it back.
    func delete(_ book: BookSummary) {
        run { try core.deleteBook(id: book.id) }
        show(Toast(icon: "trash", danger: true, title: String(localized: "已删除《\(book.title)》"), detail: String(localized: "笔记和进度都留着")) { [weak self] in
            self?.run { _ = try self?.core.restoreBook(id: book.id) }
        })
    }

    /// Big books take a moment to import; keep it off the main thread.
    @concurrent nonisolated static func importBook(_ core: YuyueCore, path: String) async throws -> BookSummary {
        let book = try core.importBook(path: path)
        guard book.format == .pdf, book.readMinutes == 0 else { return book }
        // The core keeps a PDF as it is; the system's viewer says what is in it.
        do {
            return try core.setPdfInfo(bookId: book.id, info: PdfInfoReader.read(URL(filePath: path)))
        } catch {
            try? core.deleteBook(id: book.id)
            throw error
        }
    }

    static func message(for error: Error) -> String {
        if let error = error as? PdfInfoReader.Failure {
            return error == .locked ? String(localized: "这个 PDF 设了密码，打不开") : String(localized: "这个 PDF 读不出来")
        }
        guard let error = error as? CoreError else { return error.localizedDescription }
        switch error {
        case .Unsupported: return String(localized: "不支持这种文件，目前能打开 EPUB、PDF、MOBI、AZW3、TXT 和漫画（CBZ、CBR、ZIP、RAR、一文件夹图片）")
        case .Protected: return String(localized: "这本书有版权保护（DRM），打不开")
        case .BadBook(let message) where message.contains("password"): return String(localized: "这个压缩包设了密码，打不开")
        case .BadBook(let message) where message.contains("no pictures"): return String(localized: "里面没有图片，不是漫画")
        case .BadBook(let message): return String(localized: "这本书读不出来（\(message)）")
        case .NotFound: return String(localized: "找不到这本书的文件")
        case .Io(let message) where message.contains("os error 1)") || message.contains("os error 13)"):
            return String(localized: "没有权限读这个文件，从访达拖进来或用“导入”选一次就行")
        case .Io(let message) where message.contains("os error 28)"): return String(localized: "磁盘满了，腾点地方再导入")
        case .Io(let message), .Db(let message), .Invalid(let message): return String(localized: "出错了（\(message)）")
        }
    }

    static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }

    private static var platform: String {
        #if os(macOS)
        "macos"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #endif
    }

    /// `iPhone`, `iPad`, `Mac`: for 这台 iPhone.
    static var platformWord: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.model
        #endif
    }
}

extension BookSummary: @retroactive Identifiable {}

/// One row of 正在导入.
struct ImportFile: Identifiable, Equatable {
    let id = UUID()
    let name: String
    var state = State.waiting
    /// Seconds from the start of the batch until it settled, for 还要几秒.
    var took: TimeInterval?

    enum State: Equatable {
        case waiting, reading
        case added(String, line: String)
        /// The same file, by its contents, was already on the shelf.
        case already(String)
        case failed(String)

        var settled: Bool { self != .waiting && self != .reading }
    }

    var settled: Bool { state.settled }
    var added: Bool { if case .added = state { true } else { false } }
}
