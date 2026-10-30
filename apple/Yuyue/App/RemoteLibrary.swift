import Foundation

/// 远程书库: a Calibre, Kavita or Komga over OPDS, or a share (坚果云, a NAS) over WebDAV. Filled
/// in once under 书库来源, then turned through like a catalogue and downloaded from.
nonisolated struct RemoteSource: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case opds, webdav }
    var id = UUID().uuidString
    var name: String
    var kind: Kind
    var url: URL
    var user = ""

    var password: String { Keychain.read(Self.passwordKey(id)) ?? "" }
    var host: String { url.host() ?? url.absoluteString }
    /// `OPDS · 192.168.1.8`.
    var line: String { "\(kind == .opds ? "OPDS" : "WebDAV") · \(host)" }

    static func passwordKey(_ id: String) -> String { "source.\(id).password" }
}

/// One line in a catalogue: a way further in, or a book to take.
nonisolated struct RemoteEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case folder(URL)
        case book(URL, type: String?)
    }
    let id: String
    let title: String
    var author: String?
    let kind: Kind
    var size: Int64?
    var cover: URL?
    var format: String?

    var isBook: Bool { if case .book = kind { true } else { false } }
}

nonisolated struct RemoteFeed: Sendable {
    var title = ""
    var entries: [RemoteEntry] = []
    var next: URL?
    /// With `{searchTerms}` where the words go.
    var search: String?
}

/// What went wrong, and at which step.
nonisolated enum RemoteError: LocalizedError {
    case unreachable(String)
    case login
    case notFound(RemoteSource.Kind)
    case notCatalogue
    case insecure
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .unreachable(let host): String(localized: "连不上 \(host)：看看地址对不对，手机和书库是不是在同一个网络")
        case .login: String(localized: "连上了，但用户名或密码不对")
        case .notFound(.opds): String(localized: "连上了，但这个地址上没有书库。OPDS 地址一般以 /opds 结尾")
        case .notFound(.webdav): String(localized: "连上了，但没有这个文件夹")
        case .notCatalogue: String(localized: "连上了，但这个地址不是 OPDS 书库")
        case .insecure: String(localized: "这个地址要用 https 开头")
        case .status(let code): String(localized: "书库回了一个错误（\(code)），过一会儿再试")
        }
    }
}

/// The libraries filled in, and what is downloading from them.
@Observable
final class RemoteSources {
    private(set) var all: [RemoteSource] = []
    /// How far each download is, by `source/entry`.
    private(set) var downloading: [String: Double] = [:]
    /// Taken from a library before, by `source/entry`, so it says 在书架.
    private(set) var got: Set<String> = []
    private static let key = "remote.sources"
    private static let gotKey = "remote.got"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            all = (try? JSONDecoder().decode([RemoteSource].self, from: data)) ?? []
        }
        got = Set(UserDefaults.standard.stringArray(forKey: Self.gotKey) ?? [])
    }

    func save(_ source: RemoteSource, password: String) {
        Keychain.write(RemoteSource.passwordKey(source.id), password)
        if let i = all.firstIndex(where: { $0.id == source.id }) { all[i] = source } else { all.append(source) }
        store()
    }

    func remove(_ source: RemoteSource) {
        Keychain.delete(RemoteSource.passwordKey(source.id))
        all.removeAll { $0.id == source.id }
        store()
    }

    private func store() {
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: Self.key)
    }

    static func key(_ source: RemoteSource, _ entry: RemoteEntry) -> String { "\(source.id)/\(entry.id)" }

    /// Already on the shelf: taken from here before, or a book there by the same name.
    func has(_ entry: RemoteEntry, from source: RemoteSource, in library: Library) -> Bool {
        if got.contains(Self.key(source, entry)) { return true }
        let title = Self.plain(entry.title)
        return library.books.contains { Self.plain($0.title) == title }
    }

    private static func plain(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    /// Downloads a book and puts it on the shelf.
    func take(_ entry: RemoteEntry, from source: RemoteSource, into library: Library) async throws {
        let key = Self.key(source, entry)
        guard downloading[key] == nil else { return }
        downloading[key] = 0
        defer { downloading[key] = nil }
        let file = try await RemoteClient(source).download(entry) { fraction in
            Task { @MainActor in if self.downloading[key] != nil { self.downloading[key] = fraction } }
        }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        _ = try await library.importReceived(file)
        got.insert(key)
        UserDefaults.standard.set(Array(got), forKey: Self.gotKey)
    }
}

// MARK: - Talking to it

nonisolated struct RemoteClient: Sendable {
    let source: RemoteSource
    let password: String

    init(_ source: RemoteSource, password: String? = nil) {
        self.source = source
        self.password = password ?? source.password
    }

    /// A page of the catalogue: the start when no address is given.
    func feed(_ url: URL? = nil) async throws -> RemoteFeed {
        let url = url ?? source.url
        switch source.kind {
        case .opds:
            let data = try await fetch(request(url))
            var (feed, description) = try OPDSParser.parse(data, base: url)
            if feed.search == nil, let description {
                feed.search = try? await searchTemplate(description)
            }
            return feed
        case .webdav:
            var r = request(url, "PROPFIND")
            r.setValue("1", forHTTPHeaderField: "Depth")
            r.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:displayname/></d:prop></d:propfind>
            """.utf8)
            return DAVListing.parse(try await fetch(r), base: url)
        }
    }

    /// The search a catalogue offers, its words put in.
    func search(_ template: String, _ words: String) -> URL? {
        let q = words.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? words
        return URL(string: template.replacingOccurrences(of: "{searchTerms}", with: q), relativeTo: source.url)?.absoluteURL
    }

    /// An OpenSearch description, for the address its Atom search goes to.
    private func searchTemplate(_ url: URL) async throws -> String? {
        let data = try await fetch(request(url))
        let text = String(decoding: data, as: UTF8.self)
        // `<Url type="application/atom+xml" template="…{searchTerms}…"/>`, attributes in any order.
        for match in text.matches(of: /<Url\b[^>]*>/) {
            let tag = String(match.output)
            guard tag.contains("atom"), let t = tag.firstMatch(of: /template="([^"]+)"/)?.output.1 else { continue }
            return String(t).replacingOccurrences(of: "&amp;", with: "&")
        }
        return nil
    }

    func data(_ url: URL) async throws -> Data {
        try await fetch(request(url))
    }

    /// The file, under a name that says what it is, in a folder of its own.
    func download(_ entry: RemoteEntry, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard case .book(let url, let type) = entry.kind else { throw RemoteError.notCatalogue }
        let delegate = RemoteDelegate(user: source.user, password: password)
        let watch = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if let task = delegate.task, task.countOfBytesExpectedToReceive > 0 {
                    progress(Double(task.countOfBytesReceived) / Double(task.countOfBytesExpectedToReceive))
                }
            }
        }
        defer { watch.cancel() }
        let (temp, response): (URL, URLResponse)
        do {
            (temp, response) = try await URLSession.shared.download(for: request(url), delegate: delegate)
        } catch {
            throw Self.explain(error, source)
        }
        try Self.check(response, source)
        let folder = FileManager.default.temporaryDirectory.appending(path: "remote-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: Self.name(entry, url: url, type: type ?? response.mimeType, suggested: response.suggestedFilename))
        try FileManager.default.moveItem(at: temp, to: file)
        return file
    }

    /// The book's own name with the ending its kind has.
    private static func name(_ entry: RemoteEntry, url: URL, type: String?, suggested: String?) -> String {
        let known = Set(RemoteFormats.extensions)
        for candidate in [suggested, url.lastPathComponent].compactMap({ $0 }) where known.contains((candidate as NSString).pathExtension.lowercased()) {
            return candidate.replacingOccurrences(of: "/", with: "-")
        }
        let ext = type.flatMap(RemoteFormats.ext(forType:)) ?? "epub"
        let base = entry.title.replacingOccurrences(of: "/", with: "-").prefix(100)
        return "\(base).\(ext)"
    }

    func request(_ url: URL, _ method: String = "GET") -> URLRequest {
        var url = url
        // A library on https that links to its own pages over http (Gutenberg's search does).
        if source.url.scheme == "https", url.scheme == "http", var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.scheme = "https"
            url = parts.url ?? url
        }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        r.httpMethod = method
        r.setValue(String(localized: "语阅"), forHTTPHeaderField: "User-Agent")
        return r
    }

    private func fetch(_ r: URLRequest) async throws -> Data {
        let delegate = RemoteDelegate(user: source.user, password: password)
        do {
            let (data, response) = try await URLSession.shared.data(for: r, delegate: delegate)
            try Self.check(response, source)
            return data
        } catch let error as RemoteError {
            throw error
        } catch {
            throw Self.explain(error, source)
        }
    }

    private static func check(_ response: URLResponse, _ source: RemoteSource) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 200
        switch code {
        case 200 ..< 300: return
        case 401, 403: throw RemoteError.login
        case 404: throw RemoteError.notFound(source.kind)
        default: throw RemoteError.status(code)
        }
    }

    private static func explain(_ error: Error, _ source: RemoteSource) -> Error {
        guard let e = error as? URLError else { return error }
        switch e.code {
        case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed: return RemoteError.insecure
        case .userAuthenticationRequired, .userCancelledAuthentication: return RemoteError.login
        case .cancelled: return CancellationError()
        default: return RemoteError.unreachable(source.host)
        }
    }
}

/// Answers the server's request for a login — Basic or Digest, Calibre uses the latter — and
/// keeps hold of the task so a download can say how far it is.
nonisolated private final class RemoteDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let user: String
    let password: String
    private let lock = NSLock()
    private var made: URLSessionTask?
    var task: URLSessionTask? { lock.withLock { made } }

    init(user: String, password: String) {
        self.user = user
        self.password = password
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { made = task }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault].contains(method) else {
            return (.performDefaultHandling, nil)
        }
        // Once only: a second ask means the password is wrong, and the 401 says so.
        guard challenge.previousFailureCount == 0, !user.isEmpty else { return (.rejectProtectionSpace, nil) }
        // Not kept: a changed password, or another library on the same server, must not reuse it.
        return (.useCredential, URLCredential(user: user, password: password, persistence: .none))
    }
}

/// The kinds of file the shelf takes, and what servers call them.
nonisolated enum RemoteFormats {
    static let extensions = ["epub", "azw3", "mobi", "azw", "pdf", "txt"]
    /// Best first, when a book comes in more than one.
    private static let types: [(String, String)] = [
        ("application/epub+zip", "epub"),
        ("application/x-mobi8-ebook", "azw3"),
        ("application/vnd.amazon.mobi8-ebook", "azw3"),
        ("application/x-mobipocket-ebook", "mobi"),
        ("application/pdf", "pdf"),
        ("text/plain", "txt"),
    ]

    static func ext(forType type: String) -> String? {
        let t = type.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return types.first { $0.0 == t }?.1
    }

    static func rank(_ type: String?) -> Int? {
        guard let type else { return nil }
        let t = type.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return types.firstIndex { $0.0 == t }
    }
}

// MARK: - OPDS (Atom)

nonisolated private final class OPDSParser: NSObject, XMLParserDelegate {
    private let base: URL
    private var feed = RemoteFeed()
    private var sawFeed = false
    private var inEntry = false
    private var inAuthor = false
    private var text = ""
    private var entry: (id: String, title: String, authors: [String], links: [[String: String]]) = ("", "", [], [])
    /// An OpenSearch description, to look the search up in.
    private var searchDescription: URL?

    init(base: URL) {
        self.base = base
    }

    static func parse(_ data: Data, base: URL) throws -> (RemoteFeed, URL?) {
        let p = OPDSParser(base: base)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = p
        parser.parse()
        guard p.sawFeed else { throw RemoteError.notCatalogue }
        return (p.feed, p.searchDescription)
    }

    private func resolve(_ href: String?) -> URL? {
        guard let href, !href.isEmpty else { return nil }
        return URL(string: href, relativeTo: base)?.absoluteURL
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "feed": sawFeed = true
        case "entry":
            inEntry = true
            entry = ("", "", [], [])
        case "author": inAuthor = true
        case "link":
            if inEntry {
                entry.links.append(attributes)
            } else {
                let rel = attributes["rel"] ?? ""
                let type = attributes["type"] ?? ""
                if rel == "next" { feed.next = resolve(attributes["href"]) }
                if rel == "search" {
                    if type.contains("atom"), let href = attributes["href"], href.contains("{searchTerms}") {
                        feed.search = resolve(href.replacingOccurrences(of: "{searchTerms}", with: "SEARCHTERMS"))?
                            .absoluteString.replacingOccurrences(of: "SEARCHTERMS", with: "{searchTerms}")
                    } else if type.contains("opensearchdescription") {
                        searchDescription = resolve(attributes["href"])
                    }
                }
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title":
            if inEntry { entry.title = value } else if feed.title.isEmpty { feed.title = value }
        case "id": if inEntry { entry.id = value }
        case "name": if inAuthor, inEntry, !value.isEmpty { entry.authors.append(value) }
        case "author": inAuthor = false
        case "entry":
            inEntry = false
            if let made = make() { feed.entries.append(made) }
        default: break
        }
        text = ""
    }

    private func make() -> RemoteEntry? {
        let links = entry.links
        let id = entry.id.isEmpty ? (links.first?["href"] ?? entry.title) : entry.id
        let author = entry.authors.isEmpty ? nil : entry.authors.prefix(2).joined(separator: "、")
        let cover = ["http://opds-spec.org/image/thumbnail", "http://opds-spec.org/thumbnail", "x-stanza-cover-image-thumbnail", "http://opds-spec.org/image", "http://opds-spec.org/cover"]
            .lazy.compactMap { rel in links.first { $0["rel"] == rel } }.first.flatMap { resolve($0["href"]) }
        let takes = links.filter { ($0["rel"] ?? "").hasPrefix("http://opds-spec.org/acquisition") }
        if !takes.isEmpty {
            // The best kind the shelf can open; none of them, and it isn't shown.
            guard let best = takes.compactMap({ link in RemoteFormats.rank(link["type"]).map { (link, $0) } }).min(by: { $0.1 < $1.1 })?.0,
                  let url = resolve(best["href"]) else { return nil }
            let type = best["type"]
            return RemoteEntry(id: id, title: entry.title, author: author, kind: .book(url, type: type),
                               size: best["length"].flatMap(Int64.init), cover: cover,
                               format: type.flatMap(RemoteFormats.ext(forType:))?.uppercased())
        }
        if let nav = links.first(where: { ($0["type"] ?? "").contains("atom+xml") || ($0["type"] ?? "").contains("opds") }) ?? links.first,
           let url = resolve(nav["href"]) {
            return RemoteEntry(id: id, title: entry.title, author: nil, kind: .folder(url))
        }
        return nil
    }
}

// MARK: - WebDAV

nonisolated private final class DAVListing: NSObject, XMLParserDelegate {
    private let base: URL
    private var out: [RemoteEntry] = []
    private var href = ""
    private var name = ""
    private var size: Int64?
    private var folder = false
    private var text = ""

    init(base: URL) {
        self.base = base
    }

    static func parse(_ data: Data, base: URL) -> RemoteFeed {
        let p = DAVListing(base: base)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = p
        parser.parse()
        let folders = p.out.filter { !$0.isBook }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let books = p.out.filter(\.isBook).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return RemoteFeed(title: base.lastPathComponent.removingPercentEncoding ?? "", entries: folders + books)
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch element {
        case "response": href = ""; name = ""; size = nil; folder = false
        case "collection": folder = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "href": href = value
        case "displayname": name = value
        case "getcontentlength": size = Int64(value)
        case "response": add()
        default: break
        }
        text = ""
    }

    private func add() {
        guard let url = URL(string: href, relativeTo: base)?.absoluteURL else { return }
        // The folder itself comes first in the answer.
        guard url.standardized.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                != base.standardized.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { return }
        let file = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        guard !file.hasPrefix(".") else { return }
        if folder {
            out.append(RemoteEntry(id: url.absoluteString, title: name.isEmpty ? file : name, kind: .folder(url)))
            return
        }
        let ext = (file as NSString).pathExtension.lowercased()
        guard RemoteFormats.extensions.contains(ext) else { return }
        out.append(RemoteEntry(id: url.absoluteString, title: (file as NSString).deletingPathExtension, kind: .book(url, type: nil),
                               size: size, format: ext.uppercased()))
    }
}
