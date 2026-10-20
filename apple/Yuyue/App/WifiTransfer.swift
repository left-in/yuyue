import Foundation
import Network

/// Wi‑Fi 传书: a small web server on this device. A computer on the same Wi‑Fi opens the address
/// and drops books on the page; each file comes over in pieces, so one that breaks off goes on
/// from where it stopped, and goes into the library the moment it's whole.
@Observable
final class WifiTransfer {
    struct Item: Identifiable {
        enum State: Equatable { case queued, receiving, importing, done, failed(String) }
        let id: String
        let name: String
        let size: Int64
        var received: Int64
        var state: State
        /// Where this stretch began, to say how long is left.
        var since: (Date, Int64)?
    }

    let library: Library
    private(set) var address: String?
    private(set) var items: [Item] = []
    /// `Mac 上的 Safari` once a browser has come; empty when it doesn't say what it is.
    private(set) var client: String?
    private(set) var problem: String?
    private var listener: NWListener?
    private let folder = FileManager.default.temporaryDirectory.appending(path: "wifi", directoryHint: .isDirectory)

    init(library: Library) {
        self.library = library
    }

    func start() {
        guard listener == nil else { return }
        problem = nil
        address = Self.wifiAddress()
        guard address != nil else {
            problem = String(localized: "这台设备没有连上 Wi‑Fi")
            return
        }
        listen(on: 8080)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func listen(on port: UInt16?) {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        let made: NWListener
        do {
            made = try port.map { try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: $0)!) } ?? NWListener(using: parameters)
        } catch {
            if port != nil { listen(on: nil) } else { problem = String(localized: "没法开始传书：\(error.localizedDescription)") }
            return
        }
        made.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.listener === made else { return }
                switch state {
                case .ready:
                    if let p = made.port?.rawValue, let ip = Self.wifiAddress() { self.address = p == 80 ? ip : "\(ip):\(p)" }
                case .failed:
                    made.cancel()
                    self.listener = nil
                    // 8080 taken by something else: any free one will do.
                    if port != nil { self.listen(on: nil) } else { self.problem = String(localized: "没法开始传书，过一会儿再试") }
                default: break
                }
            }
        }
        made.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                HTTPExchange(connection: connection, server: self).start()
            }
        }
        listener = made
        made.start(queue: .main)
    }

    // MARK: What the page asks

    fileprivate func respond(to request: HTTPRequest) async -> HTTPResponse {
        if let agent = request.headers["user-agent"] { client = Self.describe(agent) }
        switch (request.method, request.path) {
        case ("GET", "/"):
            return HTTPResponse(type: "text/html; charset=utf-8", body: Data(Self.page(device: Library.deviceName).utf8))
        case ("POST", "/queue"):
            return queue(request.body)
        case ("PUT", "/chunk"):
            return await chunk(request)
        default:
            return HTTPResponse(status: 404, body: Data())
        }
    }

    private struct Wanted: Decodable { let id: String; let name: String; let size: Int64 }

    /// The files the page is about to send: each gets a row, and the page learns how much of
    /// each is already here.
    private func queue(_ body: Data) -> HTTPResponse {
        guard let wanted = try? JSONDecoder().decode([Wanted].self, from: body) else { return HTTPResponse(status: 400, body: Data()) }
        var have: [String: Int64] = [:]
        for w in wanted where Self.validID(w.id) {
            if let i = items.firstIndex(where: { $0.id == w.id }) {
                have[w.id] = items[i].state == .done ? w.size : items[i].received
                continue
            }
            let received = (try? FileManager.default.attributesOfItem(atPath: file(w.id, w.name).path(percentEncoded: false))[.size] as? Int64) ?? 0
            items.append(Item(id: w.id, name: Self.clean(w.name), size: w.size, received: min(received, w.size), state: .queued))
            have[w.id] = min(received, w.size)
        }
        return .json(have)
    }

    /// One piece of a file, put after what is already here. Once the file is whole it goes into
    /// the library, and the answer says how that went.
    private func chunk(_ request: HTTPRequest) async -> HTTPResponse {
        guard let id = request.query["id"], let offset = request.query["offset"].flatMap(Int64.init),
              let i = items.firstIndex(where: { $0.id == id }) else { return HTTPResponse(status: 404, body: Data()) }
        var item = items[i]
        if item.state == .done { return .json(["received": item.size, "done": true] as [String: Any]) }
        guard offset == item.received else { return .json(["received": item.received] as [String: Any]) }
        let url = file(item.id, item.name)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(offset))
            try handle.seekToEnd()
            try handle.write(contentsOf: request.body)
            try handle.close()
        } catch {
            update(id) { $0.state = .failed(String(localized: "手机存不下了")) }
            return .json(["received": item.received, "error": String(localized: "手机存不下了")] as [String: Any])
        }
        item.received = offset + Int64(request.body.count)
        if item.since == nil || item.state != .receiving { item.since = (Date(), offset) }
        item.state = item.received >= item.size ? .importing : .receiving
        update(id) { $0 = item }
        guard item.state == .importing else { return .json(["received": item.received] as [String: Any]) }

        do {
            _ = try await library.importReceived(url)
            update(id) { $0.state = .done }
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            return .json(["received": item.size, "done": true] as [String: Any])
        } catch {
            let message = Library.message(for: error)
            update(id) { $0.state = .failed(message) }
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            return .json(["received": item.size, "error": message] as [String: Any])
        }
    }

    private func update(_ id: String, _ change: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    private func file(_ id: String, _ name: String) -> URL {
        folder.appending(path: id, directoryHint: .isDirectory).appending(path: Self.clean(name))
    }

    // MARK: Words

    /// `46% · 还要 20 秒`, from how fast this stretch has gone.
    static func progress(_ item: Item) -> String {
        let percent = Int(Double(item.received) / Double(max(item.size, 1)) * 100)
        guard let (start, from) = item.since else { return "\(percent)%" }
        let seconds = Date().timeIntervalSince(start)
        let speed = Double(item.received - from) / max(seconds, 0.001)
        guard seconds > 1, speed > 0 else { return "\(percent)%" }
        let left = Double(item.size - item.received) / speed
        let words = left < 60 ? String(localized: "\(max(1, Int(left))) 秒") : left < 3600 ? String(localized: "\(Int(left / 60)) 分钟") : String(localized: "\(Int(left / 3600)) 小时")
        return String(localized: "\(percent)% · 还要 \(words)")
    }

    /// `Mac 上的 Chrome`, `Windows 电脑`, or nothing.
    static func describe(_ agent: String) -> String {
        let system: String? = if agent.contains("Macintosh") { "Mac" } else if agent.contains("Windows") { String(localized: "Windows 电脑") } else if agent.contains("iPad") { "iPad" } else if agent.contains("Android") { "Android" } else if agent.contains("Linux") { String(localized: "Linux 电脑") } else { nil }
        let browser = agent.contains("Edg/") ? "Edge" : agent.contains("Firefox/") ? "Firefox" : agent.contains("Chrome/") ? "Chrome" : agent.contains("Safari/") ? "Safari" : nil
        switch (system, browser) {
        case let (s?, b?): return String(localized: "\(s) 上的 \(b)")
        case let (s?, nil): return s
        default: return ""
        }
    }

    private static func validID(_ id: String) -> Bool {
        (1...40).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// A name to keep: no folders in it, not too long.
    private static func clean(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == ":" }).last.map(String.init) ?? ""
        let trimmed = last.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? String(localized: "书") : String(trimmed.suffix(120))
    }

    /// The Wi‑Fi address the computer can reach this device at.
    static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  a.ifa_flags & UInt32(IFF_UP) != 0, a.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: a.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // en0 is Wi‑Fi on iPhone; the others only if there is nothing better.
            if name == "en0" { return ip }
            found = found ?? ip
        }
        return found
    }
}

// MARK: HTTP, just enough

fileprivate struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    var body = Data()
}

fileprivate struct HTTPResponse {
    var status = 200
    var type = "application/json"
    var body: Data

    static func json(_ object: Any) -> HTTPResponse {
        HTTPResponse(body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    var data: Data {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 413: "Payload Too Large"][status] ?? "OK"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// One request and its answer on one connection.
private final class HTTPExchange {
    let connection: NWConnection
    weak var server: WifiTransfer?
    private var buffer = Data()
    private var request: HTTPRequest?
    private var length = 0
    /// The page sends pieces of 4 MB; anything far bigger is not from it.
    private static let largest = 16 << 20

    init(connection: NWConnection, server: WifiTransfer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        connection.start(queue: .main)
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
            MainActor.assumeIsolated {
                if let data { self.buffer.append(data) }
                if error != nil { return self.connection.cancel() }
                if self.request == nil, !self.parseHead() {
                    return complete ? self.connection.cancel() : self.read()
                }
                if self.buffer.count >= self.length {
                    self.request?.body = self.buffer.prefix(self.length)
                    self.answer()
                } else if complete {
                    self.connection.cancel()
                } else {
                    self.read()
                }
            }
        }
    }

    /// The request line and headers, once they've all come.
    private func parseHead() -> Bool {
        guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 64 << 10 { send(HTTPResponse(status: 400, body: Data())) }
            return false
        }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        buffer = Data(buffer[end.upperBound...])
        let parts = head.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { send(HTTPResponse(status: 400, body: Data())); return false }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = URLComponents(string: String(parts[1]))
        var query: [String: String] = [:]
        for item in target?.queryItems ?? [] { query[item.name] = item.value }
        length = Int(headers["content-length"] ?? "") ?? 0
        guard length <= Self.largest else { send(HTTPResponse(status: 413, body: Data())); return false }
        request = HTTPRequest(method: String(parts[0]), path: target?.path ?? "/", query: query, headers: headers)
        return true
    }

    private func answer() {
        guard let request, let server else { return connection.cancel() }
        Task {
            send(await server.respond(to: request))
        }
    }

    private func send(_ response: HTTPResponse) {
        connection.send(content: response.data, completion: .contentProcessed { _ in
            MainActor.assumeIsolated { self.connection.cancel() }
        })
    }
}

// MARK: The page on the computer

extension WifiTransfer {
    /// `shared/wifi-page.html` (the same page as Android's) in the interface's language.
    static func page(device: String) -> String {
        guard let url = Bundle.main.url(forResource: "wifi-page", withExtension: "html"),
              var page = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        func html(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        func js(_ s: String) -> String {
            (try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        }
        let words: [String: String] = [
            "lang": Bundle.main.preferredLocalizations.first ?? "zh-Hans",
            "title": String(localized: "语阅 · Wi‑Fi 传书"),
            "heading": html(String(localized: "传书到「\(device)」")),
            "formats": String(localized: "EPUB、PDF、TXT、MOBI、AZW3，漫画 CBZ、CBR、ZIP。传完直接放进书架。"),
            "drop": String(localized: "把书拖到这里，或者点这里选文件"),
            "many": String(localized: "一次可以放很多本"),
            "sending": String(localized: "正在传"),
            "gone": String(localized: "连不上手机了。回到语阅的“Wi‑Fi 传书”页面，这里会从断的地方接着传。"),
            "awake": String(localized: "传的时候让手机上的那一页亮着。"),
            "files": js(String(localized: "%d 个文件")),
            "done": js(String(localized: "已经放进书架")),
            "queued": js(String(localized: "排队中")),
            "importing": js(String(localized: "正在放进书架…")),
        ]
        for (key, value) in words { page = page.replacingOccurrences(of: "{{\(key)}}", with: value) }
        return page
    }
}
