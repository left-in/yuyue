import Foundation
import YuyueCore

/// 笔记导出 beyond Markdown: an Obsidian vault (one note per book), Notion (one page per book
/// under a page the reader picks), flomo (one memo per highlight), and the book itself as an
/// EPUB with its highlights drawn in. Nothing goes through a server of ours: Notion and flomo
/// get the reader's own token, kept in the keychain.
///
/// Notion and flomo only get what they haven't had yet, so sending again after reading on just
/// adds the new highlights. Obsidian notes are written whole each time; they are 语阅's copy.
enum NoteExport {
    /// One book's highlights, chapter by chapter in reading order.
    struct Book: Sendable {
        let id: String
        let title: String
        let author: String?
        let chapters: [(String, [Mark])]

        var marks: [Mark] { chapters.flatMap(\.1) }
    }

    nonisolated enum Target: String, CaseIterable, Identifiable, Sendable {
        case obsidian, notion, flomo
        var id: String { rawValue }

        var title: String {
            switch self {
            case .obsidian: "Obsidian"
            case .notion: "Notion"
            case .flomo: "flomo"
            }
        }

        var symbol: String {
            switch self {
            case .obsidian: "folder"
            case .notion: "doc.text"
            case .flomo: "note.text"
            }
        }
    }

    nonisolated enum Failure: LocalizedError {
        case notSetUp(Target)
        case badToken(Target)
        case notShared
        case limited(Target)
        case server(Target, Int, String?)

        var errorDescription: String? {
            switch self {
            case .notSetUp(let t): String(localized: "还没设置 \(t.title)：在设置 · 数据 · 笔记导出里填好")
            case .badToken(let t): String(localized: "\(t.title) 的令牌不对，去设置 · 数据 · 笔记导出里重新填")
            case .notShared: String(localized: "Notion 页面还没共享给语阅：在那个页面右上角 ⋯ › 连接，选你建的集成")
            case .limited(let t): String(localized: "\(t.title) 说今天发得太多了，明天再发剩下的")
            case .server(let t, let code, let message): message.map { String(localized: "\(t.title) 回了 \(code)：\($0)") } ?? String(localized: "\(t.title) 回了 \(code)")
            }
        }
    }

    // MARK: Settings

    nonisolated static let flomoKey = "export.flomo.url"
    nonisolated static let notionKey = "export.notion.token"
    static let notionPageKey = "export.notion.page"
    static let obsidianKey = "export.obsidian.folder"

    static func isSetUp(_ t: Target) -> Bool {
        switch t {
        case .obsidian: UserDefaults.standard.data(forKey: obsidianKey) != nil
        case .notion: Keychain.read(notionKey)?.isEmpty == false && notionPage != nil
        case .flomo: Keychain.read(flomoKey)?.isEmpty == false
        }
    }

    /// The Notion page id from what the reader pasted: a link or the id itself.
    static func pageID(from text: String) -> String? {
        let hex = text.lowercased().split(separator: "?").first.map(String.init) ?? ""
        let m = hex.matches(of: /[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}|[0-9a-f]{32}/).last
        return m.map { String(hex[$0.range]).replacingOccurrences(of: "-", with: "") }
    }

    static var notionPage: String? {
        UserDefaults.standard.string(forKey: notionPageKey).flatMap(pageID)
    }

    /// The Obsidian folder the reader picked (a security-scoped bookmark: the app is sandboxed).
    static var obsidianFolder: URL? {
        guard let data = UserDefaults.standard.data(forKey: obsidianKey) else { return nil }
        var stale = false
        #if os(macOS)
        let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        #else
        let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
        #endif
        return url
    }

    static func setObsidianFolder(_ url: URL) {
        let on = url.startAccessingSecurityScopedResource()
        defer { if on { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        let data = try? url.bookmarkData(options: .withSecurityScope)
        #else
        let data = try? url.bookmarkData()
        #endif
        UserDefaults.standard.set(data, forKey: obsidianKey)
    }

    // MARK: Sending

    /// Sends the books' highlights; the count of highlights that went this time.
    static func send(_ books: [Book], to target: Target) async throws -> Int {
        switch target {
        case .obsidian: try obsidian(books)
        case .notion: try await notion(books)
        case .flomo: try await flomo(books)
        }
    }

    // MARK: Obsidian

    /// One Markdown file per book, `<title>.md`, with properties Obsidian reads.
    private static func obsidian(_ books: [Book]) throws -> Int {
        guard let folder = obsidianFolder else { throw Failure.notSetUp(.obsidian) }
        let on = folder.startAccessingSecurityScopedResource()
        defer { if on { folder.stopAccessingSecurityScopedResource() } }
        for b in books {
            let name = b.title.replacingOccurrences(of: #"[/\\:*?"<>|#^\[\]]"#, with: "-", options: .regularExpression)
            try Data(obsidianNote(b).utf8).write(to: folder.appending(path: "\(name).md"), options: .atomic)
        }
        return books.reduce(0) { $0 + $1.marks.count }
    }

    static func obsidianNote(_ b: Book) -> String {
        func yaml(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var out = "---\ntitle: \(yaml(b.title))\n"
        if let a = b.author { out += "author: \(yaml(a))\n" }
        out += "source: 语阅\ntags:\n  - 语阅\nupdated: \(ISO8601DateFormatter().string(from: Date()))\n---\n\n# \(b.title)\n"
        for (chapter, marks) in b.chapters {
            out += "\n## \(chapter)\n"
            for m in marks {
                // Each highlight keeps a block id, so links to it survive the next export.
                out += "\n> " + m.text.replacingOccurrences(of: "\n", with: "\n> ") + " ^yy-\(m.id.prefix(8))\n"
                if let note = m.note { out += "\n\(note)\n" }
            }
        }
        return out
    }

    // MARK: flomo

    /// One memo per highlight, tagged #语阅 and the book.
    private static func flomo(_ books: [Book]) async throws -> Int {
        guard let link = Keychain.read(flomoKey), let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https" else { throw Failure.notSetUp(.flomo) }
        var sent = Sent(.flomo)
        var n = 0
        defer { sent.save() }
        for b in books {
            let tag = "#语阅/" + b.title.replacingOccurrences(of: #"[\s#/]+"#, with: "_", options: .regularExpression)
            for m in b.marks where !sent.has(m) {
                var content = m.text
                if let note = m.note { content += "\n\n" + note }
                content += "\n\n——《\(b.title)》\(b.author.map { " " + $0 } ?? "")\n\(tag)"
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["content": content])
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                // flomo answers 200 with {"code": 0} when it took the memo.
                let ok = (body?["code"] as? Int) == 0
                if !ok {
                    let message = body?["message"] as? String
                    if code == 401 || code == 403 || (message?.contains("token") ?? false) { throw Failure.badToken(.flomo) }
                    if code == 429 || (message?.contains("次") ?? false) { throw Failure.limited(.flomo) }
                    throw Failure.server(.flomo, code, message)
                }
                sent.add(m)
                n += 1
            }
        }
        return n
    }

    // MARK: Notion

    /// A page per book under the page the reader chose; later sends append the new highlights.
    private static func notion(_ books: [Book]) async throws -> Int {
        guard let token = Keychain.read(notionKey), !token.isEmpty, let parent = notionPage else { throw Failure.notSetUp(.notion) }
        var sent = Sent(.notion)
        var pages = UserDefaults.standard.dictionary(forKey: "export.notion.pages") as? [String: String] ?? [:]
        var n = 0
        defer {
            sent.save()
            UserDefaults.standard.set(pages, forKey: "export.notion.pages")
        }
        for b in books {
            let fresh = b.chapters.map { ($0.0, $0.1.filter { !sent.has($0) }) }.filter { !$0.1.isEmpty }
            guard !fresh.isEmpty else { continue }
            var blocks: [[String: Any]] = []
            for (chapter, marks) in fresh {
                blocks.append(block("heading_2", chapter))
                for m in marks {
                    blocks.append(block("quote", m.text))
                    if let note = m.note { blocks.append(block("paragraph", note)) }
                }
            }
            var page = pages[b.id]
            if page == nil {
                let props: [String: Any] = ["title": ["title": [["text": ["content": String(b.title.prefix(2000))]]]]]
                let made = try await notionCall("pages", method: "POST", token: token,
                                                body: ["parent": ["page_id": parent], "properties": props,
                                                       "children": Array(blocks.prefix(100))])
                page = made["id"] as? String
                pages[b.id] = page
                blocks.removeFirst(min(100, blocks.count))
            }
            guard let page else { continue }
            // Notion takes at most 100 blocks a call.
            while !blocks.isEmpty {
                let chunk = Array(blocks.prefix(100))
                do {
                    _ = try await notionCall("blocks/\(page)/children", method: "PATCH", token: token, body: ["children": chunk])
                } catch Failure.server(_, 404, _) {
                    // The page was deleted in Notion: start a new one next time.
                    pages[b.id] = nil
                    throw Failure.server(.notion, 404, String(localized: "《\(b.title)》的页面在 Notion 里删掉了，再发一次会新建"))
                }
                blocks.removeFirst(chunk.count)
            }
            for (_, marks) in fresh { marks.forEach { sent.add($0) }; n += marks.count }
        }
        return n
    }

    private static func block(_ type: String, _ text: String) -> [String: Any] {
        // A rich text piece holds at most 2,000 characters.
        var pieces: [[String: Any]] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            pieces.append(["type": "text", "text": ["content": String(rest.prefix(2000))]])
            rest = rest.dropFirst(2000)
        }
        return ["object": "block", "type": type, type: ["rich_text": pieces]]
    }

    private static func notionCall(_ path: String, method: String, token: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch code {
        case 200 ..< 300: return json
        case 401: throw Failure.badToken(.notion)
        case 404 where path == "pages": throw Failure.notShared
        case 429: throw Failure.limited(.notion)
        default: throw Failure.server(.notion, code, json["message"] as? String)
        }
    }

    /// Which highlights a target already has, by id; a highlight whose thought changed since
    /// counts as new.
    private struct Sent {
        let target: Target
        var ids: [String: Int]

        init(_ target: Target) {
            self.target = target
            ids = UserDefaults.standard.dictionary(forKey: "export.\(target.rawValue).sent") as? [String: Int] ?? [:]
        }

        /// FNV-1a of the words and the thought: the same on every launch, unlike `hashValue`.
        private static func stamp(_ m: Mark) -> Int {
            var h: UInt32 = 2_166_136_261
            for b in (m.text + "\u{1}" + (m.note ?? "")).utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
            return Int(h & 0x7fff_ffff)
        }

        func has(_ m: Mark) -> Bool { ids[m.id] == Self.stamp(m) }
        mutating func add(_ m: Mark) { ids[m.id] = Self.stamp(m) }
        func save() { UserDefaults.standard.set(ids, forKey: "export.\(target.rawValue).sent") }
    }

    // MARK: EPUB

    /// The book as an EPUB with its highlights and thoughts, in a temporary folder to share.
    static func epub(core: YuyueCore, book: BookSummary) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = book.title.replacingOccurrences(of: #"[/\\:]"#, with: "-", options: .regularExpression)
        let url = dir.appending(path: String(localized: "\(name)（带笔记）.epub"))
        let path = url.path(percentEncoded: false)
        try await Task.detached { try core.exportEpub(bookId: book.id, notes: true, path: path) }.value
        return url
    }
}
