import AuthenticationServices
import Foundation
import Network
import Security
import YuyueCore

/// 同步, with no server of ours: every device keeps one file in a folder the user owns (a WebDAV
/// share, a folder in iCloud Drive, or 语阅's hidden folder on their Google Drive) holding every change it knows of, and reads the others'.
/// The operation log merges in any order (store.rs), so nothing here has to be careful about who
/// writes first.
@Observable
final class Sync {
    enum Method: String, CaseIterable {
        case none, icloud, webdav, googleDrive
    }

    enum State: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    private(set) var state = State.idle
    private(set) var lastSynced: Date?
    private(set) var devices: [DeviceInfo] = []
    var method: Method {
        didSet { UserDefaults.standard.set(method.rawValue, forKey: Keys.method) }
    }

    @ObservationIgnored private let core: YuyueCore
    /// Changes from other devices arrived.
    @ObservationIgnored var changed: (() -> Void)?
    @ObservationIgnored private var running: Task<Void, Never>?
    #if os(iOS)
    /// 书文件 only go over Wi-Fi on the phone.
    @ObservationIgnored private let network = NWPathMonitor()
    #endif

    init(core: YuyueCore) {
        self.core = core
        method = UserDefaults.standard.string(forKey: Keys.method).flatMap(Method.init) ?? .none
        lastSynced = UserDefaults.standard.object(forKey: Keys.last) as? Date
        loadDevices()
        #if os(iOS)
        network.start(queue: .global(qos: .utility))
        #endif
    }

    var isOn: Bool { folder != nil }

    /// 同步这些: what this device neither sends nor takes. Books, collections and the device
    /// list always go.
    private(set) var leftOut: Set<String> = Set(UserDefaults.standard.stringArray(forKey: Keys.leftOut) ?? [])

    func includes(_ part: SyncPart) -> Bool { !leftOut.contains(Self.name(part)) }

    /// Turning a part back on reads every device's file again from the start (`exchange`).
    func include(_ part: SyncPart, _ on: Bool) {
        if on { leftOut.remove(Self.name(part)) } else { leftOut.insert(Self.name(part)) }
        UserDefaults.standard.set(leftOut.sorted(), forKey: Keys.leftOut)
        now()
    }

    /// 书文件: each book's own file goes into the folder too, so a device that has only heard of a
    /// book gets it. On by default.
    private(set) var syncsFiles = UserDefaults.standard.object(forKey: Keys.files) as? Bool ?? true

    func syncFiles(_ on: Bool) {
        syncsFiles = on
        UserDefaults.standard.set(on, forKey: Keys.files)
        now()
    }

    /// 有声书录音: the recordings made into 听读书 here, whole (hundreds of MB each). Off by
    /// default: where each sentence is goes with 进度和书签 anyway, so a device that brings in
    /// its own copy of the recording listens straight away.
    private(set) var syncsRecordings = UserDefaults.standard.bool(forKey: Keys.recordings)

    func syncRecordings(_ on: Bool) {
        syncsRecordings = on
        UserDefaults.standard.set(on, forKey: Keys.recordings)
        now()
    }

    /// Big files go on the phone only over Wi-Fi.
    private var bigFilesNow: Bool {
        #if os(iOS)
        let path = network.currentPath
        return path.status == .satisfied && !path.isExpensive && !path.usesInterfaceType(.cellular)
        #else
        return true
        #endif
    }

    /// What the book files would take in the folder.
    func filesSize() -> Int64 {
        let books = ((try? core.books()) ?? []).filter(\.available).compactMap { try? core.originalFile(bookId: $0.id) }
        let fm = FileManager.default
        return books.reduce(0) { $0 + ((try? fm.attributesOfItem(atPath: $1)[.size] as? Int64) ?? 0) }
    }

    /// What the 听读书 made here would take in the folder.
    func recordingsSize() -> Int64 {
        let audio = Audiobooks.shared.map { a in a.all.filter { $0.book != nil && $0.made != nil }.map { a.folder($0.id) } } ?? []
        let fm = FileManager.default
        var total: Int64 = 0
        for dir in audio {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? [] where !name.hasPrefix("emissions-") {
                total += (try? fm.attributesOfItem(atPath: dir.appending(path: name).path(percentEncoded: false))[.size] as? Int64) ?? 0
            }
        }
        return total
    }

    nonisolated private static func name(_ part: SyncPart) -> String {
        switch part {
        case .reading: "reading"
        case .notes: "notes"
        case .settings: "settings"
        }
    }

    func loadDevices() {
        devices = (try? core.devices()) ?? []
    }

    /// Exchanges changes now, unless an exchange is already under way.
    func now() {
        guard running == nil, let folder else { return }
        state = .syncing
        let core = core
        let audio = syncsRecordings && bigFilesNow ? Audiobooks.shared?.dir : nil
        let books = syncsFiles && bigFilesNow
        running = Task {
            do {
                var applied = try await Self.exchange(core: core, folder: folder)
                // Book files when they're on, and 播客's episodes always.
                let (gotBooks, notGot, gotAudio) = await Self.exchangeFiles(core: core, folder: folder, books: books, audiobooks: audio)
                applied += gotBooks
                let missed = notGot
                if gotAudio { Audiobooks.shared?.reload() }
                lastSynced = Date()
                UserDefaults.standard.set(lastSynced, forKey: Keys.last)
                // Notes and progress went across; a book file that didn't come down isn't 已同步.
                state = missed > 0 ? .failed(String(localized: "有 \(missed) 本书的文件没下载下来，下次同步再试")) : .idle
                if applied > 0 { changed?() }
            } catch {
                state = .failed(Self.message(for: error))
            }
            loadDevices()
            running = nil
        }
    }

    /// Syncs every few minutes while the app is open.
    func keepUp() async {
        while !Task.isCancelled {
            now()
            try? await Task.sleep(for: .seconds(5 * 60))
        }
    }

    // MARK: Where

    private var folder: (any SyncFolder)? {
        switch method {
        case .webdav: webdav.map(WebDAVFolder.init)
        case .icloud: Self.chosenFolder.map(LocalFolder.init)
        case .googleDrive: Keychain.read(Self.googleRefreshKey) != nil && GoogleAuth.clientID != nil ? GoogleDriveFolder() : nil
        case .none: nil
        }
    }

    /// The Google account signed in for 同步, to show.
    var googleEmail: String? { UserDefaults.standard.string(forKey: Keys.googleEmail) }

    /// Signs in to Google in the system's sheet, checks the hidden folder can be reached, then
    /// syncs with it.
    func connectGoogle(authenticate: (URL, String) async throws -> URL) async throws {
        let refresh = try await GoogleAuth.signIn(authenticate: authenticate)
        Keychain.write(Self.googleRefreshKey, refresh)
        let folder = GoogleDriveFolder()
        do {
            _ = try await folder.list()
        } catch {
            Keychain.delete(Self.googleRefreshKey)
            DriveSession.shared.forget()
            throw error
        }
        UserDefaults.standard.set(await folder.email(), forKey: Keys.googleEmail)
        method = .googleDrive
        now()
    }

    nonisolated static let googleRefreshKey = "sync.google.refresh"

    struct WebDAVAccount: Equatable, Sendable {
        var url: URL
        var user: String
        var password: String
        /// The folder on the share the devices meet in.
        var folder = String(localized: "语阅")
    }

    var webdav: WebDAVAccount? {
        let d = UserDefaults.standard
        guard let s = d.string(forKey: Keys.webdavURL), let url = URL(string: s) else { return nil }
        return WebDAVAccount(url: url, user: d.string(forKey: Keys.webdavUser) ?? "", password: Keychain.read(Keys.webdavPassword) ?? "",
                             folder: d.string(forKey: Keys.webdavFolder) ?? String(localized: "语阅"))
    }

    /// Checks the account can be reached and written, then keeps it.
    func connect(_ account: WebDAVAccount) async throws {
        try await WebDAVFolder(account).prepare()
        keep(account)
    }

    /// Keeps an account 连接检查 has passed, and syncs with it.
    func keep(_ account: WebDAVAccount) {
        UserDefaults.standard.set(account.url.absoluteString, forKey: Keys.webdavURL)
        UserDefaults.standard.set(account.user, forKey: Keys.webdavUser)
        UserDefaults.standard.set(account.folder, forKey: Keys.webdavFolder)
        Keychain.write(Keys.webdavPassword, account.password)
        method = .webdav
        now()
    }

    /// The iCloud Drive folder picked for 同步 (a security-scoped bookmark: the app is sandboxed).
    static var chosenFolder: URL? {
        #if DEBUG
        // `-debugSyncDir <dir>`: a folder in the app's own container, to try a round between two scratch libraries.
        if let dir = UserDefaults.standard.string(forKey: "debugSyncDir") { return URL(filePath: dir, directoryHint: .isDirectory) }
        #endif
        guard let data = UserDefaults.standard.data(forKey: Keys.folder) else { return nil }
        var stale = false
        #if os(macOS)
        let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        #else
        let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
        #endif
        return url
    }

    func choose(folder url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        let data = try url.bookmarkData(options: .withSecurityScope)
        #else
        let data = try url.bookmarkData()
        #endif
        UserDefaults.standard.set(data, forKey: Keys.folder)
        method = .icloud
        now()
    }

    func stop() {
        running?.cancel()
        running = nil
        if method == .googleDrive {
            // 停止同步 signs out too; the files stay in the Drive for the other devices.
            Keychain.delete(Self.googleRefreshKey)
            UserDefaults.standard.removeObject(forKey: Keys.googleEmail)
            DriveSession.shared.forget()
        }
        method = .none
        state = .idle
    }

    private enum Keys {
        static let method = "sync.method"
        static let last = "sync.last"
        static let webdavURL = "sync.webdav.url"
        static let webdavUser = "sync.webdav.user"
        static let webdavPassword = "sync.webdav.password"
        static let webdavFolder = "sync.webdav.folder"
        static let folder = "sync.folder"
        static let googleEmail = "sync.google.email"
        static let leftOut = "sync.leftOut"
        static let files = "sync.files"
        static let recordings = "sync.recordings"
    }

    // MARK: Exchanging

    nonisolated private static let suffix = ".yuyue-sync.json"

    /// Reads every other device's file that changed since last time, then writes this device's
    /// own when it knows something new. Returns how many values changed here.
    @concurrent private static func exchange(core: YuyueCore, folder: any SyncFolder) async throws -> UInt32 {
        try await folder.prepare()
        let mine = core.deviceId() + suffix
        let files = try await folder.list()
        // 同步这些 as it is now, and as it was the last time round.
        let names = Set(UserDefaults.standard.stringArray(forKey: "sync.leftOut") ?? [])
        let leftOut = [SyncPart.reading, .notes, .settings].filter { names.contains(name($0)) }
        let before = UserDefaults.standard.stringArray(forKey: "sync.leftOut.done").map(Set.init)
        // A part on again: what was passed over in files already read is only in them, so read them all.
        let reread = before.map { !$0.isSubset(of: names) } ?? false
        var seen = reread ? [:] : UserDefaults.standard.dictionary(forKey: "sync.seen") as? [String: String] ?? [:]
        var applied: UInt32 = 0
        for (name, tag) in files where name.hasSuffix(suffix) && name != mine && seen[name] != tag {
            try Task.checkCancellation()
            let data = try await folder.read(name)
            applied += try core.importChangesExcept(batch: String(decoding: data, as: UTF8.self), leftOut: leftOut)
            seen[name] = tag
        }
        UserDefaults.standard.set(seen, forKey: "sync.seen")
        let version = try core.syncVersion() + "|" + names.sorted().joined(separator: ",")
        if files[mine] == nil || UserDefaults.standard.string(forKey: "sync.written") != version {
            let everything = try core.exportChangesExcept(version: "{}", leftOut: leftOut)
            try await folder.write(mine, Data(everything.utf8))
            UserDefaults.standard.set(version, forKey: "sync.written")
        }
        UserDefaults.standard.set(names.sorted(), forKey: "sync.leftOut.done")
        return applied
    }

    /// 书文件和有声书. A book's file is `<id>.book.<ext>`: ids are the file's hash, so the same file
    /// imported anywhere is the same book. A 听读书 is `<id>.audio.<file>` for each of its files,
    /// with `info.json` written last, so a device takes it only once all of it is there. One file
    /// failing doesn't stop the rest; it's tried again next time. Returns the books taken, and
    /// whether any 听读书 came.
    @concurrent private static func exchangeFiles(core: YuyueCore, folder: any SyncFolder, books all: Bool, audiobooks: URL?) async -> (UInt32, Int, Bool) {
        guard let files = try? await folder.list() else { return (0, 0, false) }
        let fm = FileManager.default
        // 书文件 off (or the phone not on Wi-Fi): only 播客's episodes, a few KB each.
        let books = ((try? core.books()) ?? []).filter { all || $0.format == .podcast }
        var took: UInt32 = 0
        var missed = 0
        // Up: each book here the folder doesn't have yet.
        for book in books where book.available && !files.keys.contains(where: { $0.hasPrefix(book.id + ".book.") }) {
            guard !Task.isCancelled, let path = try? core.originalFile(bookId: book.id) else { continue }
            let url = URL(filePath: path)
            try? await folder.upload("\(book.id).book.\(url.pathExtension)", from: url)
        }
        // Down: each book known here only from another device.
        let temp = fm.temporaryDirectory.appending(path: "yuyue-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        for book in books where !book.available {
            guard !Task.isCancelled, let name = files.keys.first(where: { $0.hasPrefix(book.id + ".book.") }) else { continue }
            // Named as the book is, so a TXT's title (taken from its file name) comes out the same.
            let ext = (name as NSString).pathExtension
            let url = temp.appending(path: fileName(book.title) + "." + ext)
            do {
                try await folder.download(name, to: url)
                _ = try await Library.importBook(core, path: url.path(percentEncoded: false))
                took += 1
            } catch { missed += 1 }
            try? fm.removeItem(at: url)
        }
        guard let audiobooks else { return (took, missed, false) }
        return (took, missed, await exchangeAudiobooks(folder: folder, files: files, dir: audiobooks))
    }

    @concurrent private static func exchangeAudiobooks(folder: any SyncFolder, files: [String: String], dir: URL) async -> Bool {
        let fm = FileManager.default
        func info(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
        func parts(_ info: [String: Any]) -> [String] { (info["files"] as? [String] ?? []) + ["cover.jpg", "timings.json"] }
        func stamp(_ url: URL) -> String? {
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            return "\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(v.fileSize ?? 0)"
        }
        // What was last put up from here, by file, so 微调 goes up again.
        var sent = UserDefaults.standard.dictionary(forKey: "sync.audio.sent") as? [String: String] ?? [:]
        var seen = UserDefaults.standard.dictionary(forKey: "sync.audio.seen") as? [String: String] ?? [:]
        defer {
            UserDefaults.standard.set(sent, forKey: "sync.audio.sent")
            UserDefaults.standard.set(seen, forKey: "sync.audio.seen")
        }
        let ids = (try? fm.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
        // Up: the 听读书 made here, laid against a book.
        for id in ids {
            let here = dir.appending(path: id, directoryHint: .isDirectory)
            guard let data = try? Data(contentsOf: here.appending(path: "info.json")), let i = info(data),
                  i["book"] is String, i["made"] != nil else { continue }
            var whole = true
            for part in parts(i) + ["info.json"] {
                let url = here.appending(path: part)
                guard !Task.isCancelled, let now = stamp(url) else { continue }
                let name = "\(id).audio.\(part)"
                // info.json last, and only once the rest is up.
                if part == "info.json", !whole { break }
                // New to the folder, or changed since it went up (微调). What came from another
                // device was marked sent when it came.
                guard files[name] == nil || sent[name].map({ $0 != now }) == true else { continue }
                do {
                    try await folder.upload(name, from: url)
                    sent[name] = now
                } catch { whole = false }
            }
        }
        // Down: one from another device, once its info.json is there.
        var got = false
        for (name, tag) in files where name.hasSuffix(".audio.info.json") && seen[name] != tag {
            guard !Task.isCancelled, let data = try? await folder.read(name), let i = info(data) else { continue }
            let id = String(name.dropLast(".audio.info.json".count))
            guard !id.isEmpty, !id.contains("/") else { continue }
            let here = dir.appending(path: id, directoryHint: .isDirectory)
            try? fm.createDirectory(at: here, withIntermediateDirectories: true)
            var whole = true
            for part in parts(i) {
                let remote = "\(id).audio.\(part)"
                let url = here.appending(path: part)
                guard let remoteTag = files[remote] else { continue }
                let present = fm.fileExists(atPath: url.path(percentEncoded: false))
                // The recording doesn't change; the timings do (微调).
                if present, part != "timings.json" || seen[remote] == remoteTag {
                    if sent[remote] == nil { sent[remote] = stamp(url) }
                    continue
                }
                do {
                    let partial = here.appending(path: part + ".download")
                    try await folder.download(remote, to: partial)
                    if present, (try? Data(contentsOf: partial)) == (try? Data(contentsOf: url)) {
                        try? fm.removeItem(at: partial)
                    } else {
                        _ = try fm.replaceItemAt(url, withItemAt: partial)
                        got = true
                    }
                    sent[remote] = stamp(url)
                    seen[remote] = remoteTag
                } catch { whole = false }
            }
            guard whole else { continue }
            let url = here.appending(path: "info.json")
            if (try? Data(contentsOf: url)) != data {
                try? data.write(to: url, options: .atomic)
                got = true
            }
            sent[name] = stamp(url)
            seen[name] = tag
        }
        return got
    }

    /// A book's title as a file name.
    nonisolated private static func fileName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        let clean = title.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let cut = String(clean.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cut.isEmpty ? "book" : cut
    }

    static func message(for error: Error) -> String {
        switch error {
        case SyncError.status(401), SyncError.status(403): String(localized: "账号或密码不对")
        case SyncError.status(404): String(localized: "服务器上没有这个地址")
        case SyncError.status(let code): String(localized: "服务器回了 \(code)")
        case SyncError.noFolder: String(localized: "找不到同步用的文件夹，重新选一下")
        case SyncError.signedOut: String(localized: "Google 账号要重新登录一下")
        case SyncError.signInFailed: String(localized: "Google 没让登录，再试一次")
        case SyncError.notRegistered: String(localized: "这个版本还没开通 Google Drive")
        case let e as ASWebAuthenticationSessionError where e.code == .canceledLogin: String(localized: "没有登录")
        case is CancellationError: String(localized: "没有登录")
        case let e as URLError where e.code == .notConnectedToInternet: String(localized: "没有联网")
        case let e as URLError where e.code == .timedOut: String(localized: "连接超时")
        case let e as URLError where e.code == .cannotFindHost || e.code == .cannotConnectToHost: String(localized: "连不上服务器")
        default: Library.message(for: error)
        }
    }
}

enum SyncError: Error {
    case status(Int)
    case noFolder
    /// Google took the sign-in back, or it ran out.
    case signedOut
    case signInFailed
    /// No Google client id in this build.
    case notRegistered
}

/// A folder the devices meet in: file name → a tag that changes when the file does.
protocol SyncFolder: Sendable {
    func prepare() async throws
    func list() async throws -> [String: String]
    func read(_ name: String) async throws -> Data
    func write(_ name: String, _ data: Data) async throws
    /// 书文件 and recordings, without holding them in memory.
    func upload(_ name: String, from file: URL) async throws
    func download(_ name: String, to file: URL) async throws
}

extension SyncFolder {
    /// The sync files are JSON; everything else goes as it is.
    nonisolated static func type(of name: String) -> String {
        name.hasSuffix(".json") ? "application/json" : "application/octet-stream"
    }

    /// Puts a file downloaded to `temp` at `file`.
    nonisolated static func place(_ temp: URL, at file: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path(percentEncoded: false)) { try fm.removeItem(at: file) }
        try fm.moveItem(at: temp, to: file)
    }
}

// MARK: - WebDAV

/// 坚果云、群晖、Nextcloud…: files under `<base>/语阅/`.
struct WebDAVFolder: SyncFolder {
    let base: URL
    let user: String
    let password: String
    var folder = String(localized: "语阅")

    init(_ account: Sync.WebDAVAccount) {
        base = account.url
        user = account.user
        password = account.password
        folder = account.folder
    }

    var dir: URL {
        let path = folder.split(separator: "/").joined(separator: "/")
        return path.isEmpty ? base : base.appending(path: path, directoryHint: .isDirectory)
    }

    func prepare() async throws {
        var r = request(dir, "MKCOL")
        r.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 405: there already.
        guard (200 ..< 300).contains(code) || code == 405 else { throw SyncError.status(code) }
    }

    func list() async throws -> [String: String] {
        var r = request(dir, "PROPFIND")
        r.setValue("1", forHTTPHeaderField: "Depth")
        r.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:getlastmodified/><d:getcontentlength/></d:prop></d:propfind>
        """.utf8)
        let data = try await send(r)
        return PropfindParser.parse(data)
    }

    func read(_ name: String) async throws -> Data {
        try await send(request(dir.appending(path: name), "GET"))
    }

    func write(_ name: String, _ data: Data) async throws {
        var r = request(dir.appending(path: name), "PUT")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = data
        _ = try await send(r)
    }

    func upload(_ name: String, from file: URL) async throws {
        var r = request(dir.appending(path: name), "PUT")
        r.setValue(Self.type(of: name), forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 600
        let (_, response) = try await URLSession.shared.upload(for: r, fromFile: file)
        try Self.check(response)
    }

    func download(_ name: String, to file: URL) async throws {
        var r = request(dir.appending(path: name), "GET")
        r.timeoutInterval = 600
        let (temp, response) = try await URLSession.shared.download(for: r)
        try Self.check(response)
        try Self.place(temp, at: file)
    }

    private static func check(_ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else { throw SyncError.status(code) }
    }

    func request(_ url: URL, _ method: String) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        r.httpMethod = method
        if !user.isEmpty {
            let token = Data("\(user):\(password)".utf8).base64EncodedString()
            r.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    private func send(_ r: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else { throw SyncError.status(code) }
        return data
    }
}

/// The file names and tags in a PROPFIND answer.
private final class PropfindParser: NSObject, XMLParserDelegate {
    private var out: [String: String] = [:]
    private var href = ""
    private var tag = ""
    private var modified = ""
    private var text = ""

    static func parse(_ data: Data) -> [String: String] {
        let p = PropfindParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = p
        parser.parse()
        return p.out
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "response" { href = ""; tag = ""; modified = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href": href = value
        case "getetag": tag = value
        case "getlastmodified": modified = value
        case "response":
            let file = (href.removingPercentEncoding ?? href).split(separator: "/").last.map(String.init) ?? ""
            if !file.isEmpty, !href.hasSuffix("/") { out[file] = tag.isEmpty ? modified : tag }
        default: break
        }
    }
}

// MARK: - A folder on disk (iCloud Drive)

struct LocalFolder: SyncFolder {
    let url: URL

    func prepare() async throws {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { throw SyncError.noFolder }
    }

    func list() async throws -> [String: String] {
        try scoped {
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))
            var out: [String: String] = [:]
            for name in names {
                // iCloud keeps files not yet downloaded as ".name.icloud".
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url.appending(path: name))
                    continue
                }
                let v = try? url.appending(path: name).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                out[name] = "\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(v?.fileSize ?? 0)"
            }
            return out
        }
    }

    func read(_ name: String) async throws -> Data {
        try scoped { try Data(contentsOf: url.appending(path: name)) }
    }

    func write(_ name: String, _ data: Data) async throws {
        try scoped { try data.write(to: url.appending(path: name), options: .atomic) }
    }

    func upload(_ name: String, from file: URL) async throws {
        try await Self.copy(file, to: url.appending(path: name), scope: url)
    }

    func download(_ name: String, to file: URL) async throws {
        try await Self.copy(url.appending(path: name), to: file, scope: url)
    }

    /// Off the main thread: a book can be big.
    @concurrent nonisolated private static func copy(_ from: URL, to: URL, scope: URL) async throws {
        let on = scope.startAccessingSecurityScopedResource()
        defer { if on { scope.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let temp = to.deletingLastPathComponent().appending(path: ".\(to.lastPathComponent).\(UUID().uuidString)")
        try fm.copyItem(at: from, to: temp)
        try place(temp, at: to)
    }

    private func scoped<T>(_ body: () throws -> T) throws -> T {
        let on = url.startAccessingSecurityScopedResource()
        defer { if on { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}

// MARK: - Keychain

nonisolated enum Keychain {
    private static let service = "app.yuyue.Yuyue"

    /// `-debugNoKeychain 1`: a scratch run never touches the keychain, so a fresh ad-hoc build
    /// doesn't put 钥匙串 的密码框 in front of whatever the user is doing.
    private static var off: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "debugNoKeychain")
        #else
        false
        #endif
    }

    static func read(_ key: String) -> String? {
        if off { return nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ key: String, _ value: String) {
        if off { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        if off { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}
