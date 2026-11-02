import Foundation
import Observation
import YuyueCore

/// 播客 (docs/播客开发方案.md §3.3): writes an episode on this device, step by step.
///
///   1 取新内容 → 2 取正文 → 3 挑选 → 4 逐篇摘要 → 5 写稿 → 6 存成一集
///
/// The core reads the feeds and pages, writes the prompts and checks the answers; this file only
/// downloads, asks the model chosen for 书伴, and keeps going. Each step's result is saved, so
/// an episode cut off (no network, the app quit) carries on where it stopped the next time.
@Observable
final class Podcasts {
    let core: YuyueCore
    private(set) var shows: [Show] = []
    private(set) var latest: [Episode] = []
    /// The episode being written for each show.
    private(set) var writing: [String: Progress] = [:]
    /// Why the last one failed, by show.
    var failure: [String: String] = [:]
    /// 编辑部: what the editor and the reader have said, by show, for the episode being written.
    private(set) var talk: [String: [Message]] = [:]

    @ObservationIgnored private let workDir: URL
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// Which run of a show is the current one, so a cancelled run finishing late doesn't clear
    /// the one started after it.
    @ObservationIgnored private var runs: [String: UUID] = [:]
    /// 编辑部 changed the pick while an episode was being written: the run takes it up at its
    /// next step (it holds its own copy of the work, and would write over a change on disk).
    @ObservationIgnored private var repick: [String: [Int]] = [:]

    struct Progress: Equatable {
        enum Step: Int, Comparable {
            case fetch = 1, read, pick, summarize, write, save
            static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
        }

        var step: Step
        /// "正在写第 4 / 7 条": how far into the step.
        var done = 0
        var total = 0
        /// 23 篇新的.
        var found = 0
        /// The picked titles, in order; the one being written is `done`.
        var picked: [String] = []
        var skipped = ""
    }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        var fromEditor: Bool
        var text: String
        /// The editor's list, under its first message.
        var list: [String] = []
    }

    init(core: YuyueCore, dataDir: URL) {
        self.core = core
        workDir = dataDir.appending(path: "podcast", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        shows = (try? core.shows()) ?? []
        latest = (try? core.latestEpisodes(limit: 60)) ?? []
    }

    func episodes(of show: String) -> [Episode] {
        latest.filter { $0.show == show }
    }

    // MARK: Shows

    @discardableResult
    func add(_ draft: ShowDraft) throws -> Show {
        let s = try core.addShow(draft: draft)
        reload()
        return s
    }

    func update(_ id: String, _ draft: ShowDraft) throws {
        _ = try core.updateShow(id: id, draft: draft)
        reload()
    }

    func remove(_ id: String) {
        try? core.removeShow(id: id)
        cancel(id)
        reload()
    }

    /// 配一档节目 starts from one of these.
    static func templates() -> [ShowDraft] {
        let hosts = [
            ShowHost(name: String(localized: "小林"), about: String(localized: "做产品的，好奇心重，爱打比方"), voice: nil),
            ShowHost(name: String(localized: "老周"), about: String(localized: "写了二十年代码，说话慢，讲清楚来龙去脉"), voice: nil),
        ]
        let weekdays = ShowSchedule(days: [1, 2, 3, 4, 5], minute: 7 * 60)
        let language = (Bundle.main.preferredLocalizations.first ?? "zh").hasPrefix("zh") ? "zh-CN" : "en"
        func src(_ kind: SourceKind, _ address: String, _ name: String, _ weight: UInt8 = 3, _ limit: UInt32 = 10) -> ShowSource {
            ShowSource(kind: kind, address: address, name: name, weight: weight, limit: limit, paused: false)
        }
        return [
            ShowDraft(name: String(localized: "科技早报"),
                      sources: [src(.hackerNews, "top", "Hacker News", 4, 15), src(.feed, "https://sspai.com/feed", String(localized: "少数派"), 2)],
                      schedule: weekdays, minutes: 10, form: .duo, hosts: hosts, language: language,
                      brief: String(localized: "多讲开源工具，少讲融资"), avoid: [], device: nil),
            ShowDraft(name: String(localized: "开源动态"),
                      sources: [src(.feed, "https://github.com/rust-lang/rust/releases.atom", "rust-lang/rust", 3, 5)],
                      schedule: ShowSchedule(days: [], minute: 7 * 60), minutes: 5, form: .solo, hosts: [hosts[1]], language: language,
                      brief: "", avoid: [], device: nil),
        ]
    }

    // MARK: Writing an episode

    func isWriting(_ show: String) -> Bool { tasks[show] != nil }

    /// 现在写一集.
    func write(_ show: Show) {
        guard tasks[show.id] == nil else { return }
        failure[show.id] = nil
        let run = UUID()
        runs[show.id] = run
        tasks[show.id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run(show)
            } catch is CancellationError {
            } catch {
                self.failure[show.id] = Self.message(for: error)
                Self.log("failed: \(error)")
            }
            // Cancelled and started again meanwhile: the new run is the show's now.
            guard self.runs[show.id] == run else { return }
            self.runs[show.id] = nil
            self.writing[show.id] = nil
            self.tasks[show.id] = nil
            self.reload()
        }
    }

    func cancel(_ show: String) {
        tasks[show]?.cancel()
        tasks[show] = nil
        runs[show] = nil
        repick[show] = nil
        writing[show] = nil
    }

    /// 和编辑说话: the reader's message about today's pick. The editor answers and changes it.
    func say(_ text: String, to show: Show) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        talk[show.id, default: []].append(Message(fromEditor: false, text: text))
        Task { [weak self] in
            guard let self else { return }
            var work = self.load(show.id)
            guard let picked = self.repick[show.id] ?? work.picked else {
                self.talk[show.id, default: []].append(Message(fromEditor: true, text: String(localized: "还没挑好，等我挑完再说。")))
                return
            }
            let titles = picked.map { work.items[$0].title }
            let prompt = editorPrompt(show: show, picked: titles, skipped: work.skipped ?? "", message: text)
            do {
                let reply = try await Self.ask(CompanionConfig.current, prompt)
                let pick = try parsePick(answer: reply, offered: Array(1 ... UInt32(max(titles.count + 16, 1))))
                // Answers count from 1 in the list it was shown; anything past it is one it left out.
                let all = picked + work.items.indices.filter { !picked.contains($0) }
                let order = pick.pick.compactMap { n in all.indices.contains(Int(n) - 1) ? all[Int(n) - 1] : nil }
                if !order.isEmpty {
                    if self.tasks[show.id] != nil {
                        // Being written: the run takes it up at its next step.
                        self.repick[show.id] = order
                    } else {
                        work.picked = order
                        // What's written for articles still picked stays; the script is written again.
                        work.script = nil
                        self.save(show.id, work)
                    }
                }
                if var p = self.writing[show.id] {
                    p.picked = order.map { work.items[$0].title }
                    self.writing[show.id] = p
                }
                self.talk[show.id, default: []].append(Message(fromEditor: true, text: pick.reply ?? String(localized: "好。")))
            } catch {
                self.talk[show.id, default: []].append(Message(fromEditor: true, text: Self.message(for: error)))
            }
        }
    }

    private func run(_ show: Show) async throws {
        var config = CompanionConfig.current
        #if DEBUG
        // A test run can bring its own OpenAI-shaped service (YUYUE_PODCAST_URL, _KEY, _MODEL),
        // for this process only: nothing is written to the settings or the keychain.
        let env = ProcessInfo.processInfo.environment
        if let url = env["YUYUE_PODCAST_URL"], let key = env["YUYUE_PODCAST_KEY"] {
            config = CompanionConfig(provider: .custom("test"), key: key, model: env["YUYUE_PODCAST_MODEL"] ?? "", url: url)
        }
        NSLog("podcast: provider=%@ model=%@ ready=%d", config.provider.id, config.model, config.isReady ? 1 : 0)
        #endif
        guard config.isReady else { throw PodcastError.noModel }
        var work = load(show.id)
        if work.date != Self.today { work = Work(date: Self.today) }

        // 1 取新内容
        if work.items.isEmpty {
            writing[show.id] = Progress(step: .fetch, total: show.sources.filter { !$0.paused }.count)
            let told = Set((try? core.toldArticles(show: show.id)) ?? [])
            var seen = told
            for (i, source) in show.sources.enumerated() where !source.paused {
                try Task.checkCancellation()
                let items = (try? await Self.fetch(source)) ?? []
                for item in items.prefix(Int(source.limit)) {
                    let key = articleKey(url: item.url)
                    guard seen.insert(key).inserted else { continue }
                    if show.avoid.contains(where: { item.title.localizedCaseInsensitiveContains($0) }) { continue }
                    work.items.append(Work.Item(item, source: source, key: key))
                }
                writing[show.id]?.done = i + 1
            }
            guard !work.items.isEmpty else { throw PodcastError.nothingNew }
            save(show.id, work)
        }
        writing[show.id] = Progress(step: .pick, found: work.items.count)

        // 3 挑选 (only titles: cheap). 2 comes after, for the picked ones alone.
        let count = max(3, Int(show.minutes) * 7 / 10)
        if work.picked == nil {
            let candidates = work.items.enumerated().map { i, it in
                Candidate(index: UInt32(i), title: it.title, source: it.label, weight: it.weight)
            }
            if candidates.count <= count {
                work.picked = Array(work.items.indices)
                work.skipped = ""
            } else {
                let p = pickPrompt(show: show, candidates: candidates, count: UInt32(count))
                let reply = try await Self.ask(config, p)
                let pick = try parsePick(answer: reply, offered: candidates.map(\.index))
                work.picked = pick.pick.map(Int.init)
                work.skipped = pick.skipped
            }
            guard !(work.picked ?? []).isEmpty else { throw PodcastError.nothingNew }
            save(show.id, work)
            Self.log("picked \(work.picked ?? [])")
        }
        var picked = work.picked ?? []
        writing[show.id]?.picked = picked.map { work.items[$0].title }
        writing[show.id]?.skipped = work.skipped ?? ""
        if talk[show.id] == nil {
            let skippedCount = work.items.count - picked.count
            let line = skippedCount > 0
                ? String(localized: "今天收到 \(work.items.count) 篇新的。挑了这 \(picked.count) 篇，按这个顺序讲：")
                : String(localized: "今天收到 \(work.items.count) 篇新的，都讲：")
            talk[show.id] = [Message(fromEditor: true, text: line, list: picked.map { work.items[$0].title })]
            if let s = work.skipped, !s.isEmpty { talk[show.id]?.append(Message(fromEditor: true, text: s)) }
        }

        // 编辑部 said to change the pick: from here on the run follows it.
        func takeRepick() {
            guard let order = repick.removeValue(forKey: show.id) else { return }
            work.picked = order
            work.script = nil
            picked = order
            writing[show.id]?.picked = order.map { work.items[$0].title }
            save(show.id, work)
        }

        // 2 取正文 and 4 逐篇摘要, one article at a time, each saved when done.
        while true {
            try Task.checkCancellation()
            takeRepick()
            guard let i = picked.first(where: { work.items[$0].summary == nil }) else { break }
            let n = picked.count { work.items[$0].summary != nil }
            writing[show.id]?.step = .summarize
            writing[show.id]?.done = n
            writing[show.id]?.total = picked.count
            var item = work.items[i]
            if item.summaryOnly, let full = try? await Self.article(item.url), full.units > 200 {
                item.text = full.paragraphs.joined(separator: "\n")
            }
            if item.comments.isEmpty, let hn = item.hnID {
                item.comments = (try? await Self.hnComments(hn)) ?? []
            }
            let p = summaryPrompt(show: show, title: item.title, source: item.label, text: item.text, comments: item.comments)
            let reply = try await Self.ask(config, p)
            item.summary = reply
            work.items[i] = item
            save(show.id, work)
            Self.log("summary \(n + 1)/\(picked.count)")
        }
        // (A change asked for while the script is being written comes too late for this episode.)
        writing[show.id]?.done = picked.count

        // 5 写稿; asked again once if the answer doesn't check.
        writing[show.id]?.step = .write
        let articles = picked.map { ScriptArticle(title: work.items[$0].title, url: work.items[$0].url, source: work.items[$0].label) }
        let script: EpisodeScript
        if let saved = work.script, let s = try? parseScript(answer: saved, show: show, articles: articles) {
            script = s
        } else {
            let p = scriptPrompt(show: show, date: work.date, articles: articles, summaries: picked.map { work.items[$0].summary ?? "" })
            var attempt = 0
            var made: EpisodeScript?
            var lastError: Error?
            while made == nil && attempt < 2 {
                try Task.checkCancellation()
                let reply = try await Self.ask(config, p, maxTokens: 8192)
                do {
                    made = try parseScript(answer: reply, show: show, articles: articles)
                    work.script = reply
                } catch {
                    lastError = error
                    Self.log("script check failed: \(error)")
                }
                attempt += 1
            }
            save(show.id, work)
            guard let made else { throw lastError ?? PodcastError.badScript }
            script = made
        }

        // 6 存成一集
        Self.log("script ok, \(script.segments.count) segments")
        writing[show.id]?.step = .save
        _ = try core.saveEpisode(show: show.id, date: work.date, script: script)
        try core.markTold(show: show.id, keys: picked.map { work.items[$0].key })
        clear(show.id)
        repick[show.id] = nil
        talk[show.id] = nil
        Self.log("done")
    }

    private static func log(_ s: String) {
        #if DEBUG
        NSLog("podcast: %@", s)
        #endif
    }

    /// The model, asked again after a pause when the service says it's busy (429, 529): a whole
    /// episode is a dozen questions in a row, more than 书伴 ever asks at once.
    private static func ask(_ config: CompanionConfig, _ p: Prompt, maxTokens: Int = 1024) async throws -> String {
        var wait: UInt64 = 4
        for attempt in 0 ..< 4 {
            do {
                return try await Companion.answer(config, system: p.system, prompt: p.user, maxTokens: maxTokens)
            } catch where attempt < 3 && Self.worthRetrying(error) {
                log("\(error.localizedDescription), waiting \(wait)s")
                try await Task.sleep(nanoseconds: wait * 1_000_000_000)
                wait *= 3
            }
        }
        throw CompanionError.busy
    }

    /// Busy, or the line dropped: worth asking again. A wrong key or no credit isn't.
    private static func worthRetrying(_ error: Error) -> Bool {
        if case CompanionError.busy = error { return true }
        guard let e = error as? URLError else { return false }
        return [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed].contains(e.code)
    }

    // MARK: Downloading (the core never goes online)

    private static func get(_ url: URL) async throws -> Data {
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.setValue("Yuyue/1.0 (+https://yuyue.app)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: r)
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200 ..< 300).contains(code) else { throw PodcastError.download(url.host() ?? url.absoluteString) }
        return data
    }

    static func fetch(_ source: ShowSource) async throws -> [FeedItem] {
        switch source.kind {
        case .feed, .page:
            guard let url = URL(string: source.address) else { return [] }
            let data = try await get(url)
            if let feed = try? parseFeed(bytes: data, base: source.address) { return feed.items }
            // A web page: the feed it names.
            let html = String(decoding: data, as: UTF8.self)
            guard let link = feedLinks(html: html, base: source.address).first, let feedURL = URL(string: link.url) else { return [] }
            return try parseFeed(bytes: try await get(feedURL), base: link.url).items
        case .hackerNews:
            let list = ["top", "best", "new", "ask", "show"].contains(source.address) ? source.address : "top"
            let ids = try parseHnIds(bytes: try await get(URL(string: "https://hacker-news.firebaseio.com/v0/\(list)stories.json")!))
            var out: [FeedItem] = []
            try await withThrowingTaskGroup(of: (Int, FeedItem?).self) { group in
                for (i, id) in ids.prefix(Int(source.limit)).enumerated() {
                    group.addTask {
                        let data = try await get(URL(string: "https://hacker-news.firebaseio.com/v0/item/\(id).json")!)
                        return (i, try parseHnItem(bytes: data).map(hnFeedItem))
                    }
                }
                var got: [(Int, FeedItem)] = []
                for try await (i, item) in group { if let item { got.append((i, item)) } }
                out = got.sorted { $0.0 < $1.0 }.map(\.1)
            }
            return out
        case .highlights, .words:
            // 语阅里自己的东西: the second phase (方案 第五节 7).
            return []
        }
    }

    static func article(_ url: String) async throws -> Article? {
        guard let u = URL(string: url) else { return nil }
        let data = try await get(u)
        return extractArticle(String(decoding: data, as: UTF8.self))
    }

    /// A Hacker News story's top comments, as text.
    static func hnComments(_ id: UInt64) async throws -> [String] {
        let story = try parseHnItem(bytes: try await get(URL(string: "https://hacker-news.firebaseio.com/v0/item/\(id).json")!))
        var out: [String] = []
        for kid in story?.kids.prefix(8) ?? [] {
            if let c = try? parseHnItem(bytes: try await get(URL(string: "https://hacker-news.firebaseio.com/v0/item/\(kid).json")!)), !c.text.isEmpty {
                out.append(c.text)
            }
        }
        return out
    }

    // MARK: What's been done so far, on disk

    struct Work: Codable {
        struct Item: Codable {
            var title: String
            var url: String
            var label: String
            var weight: UInt8
            var key: String
            var text: String
            var summaryOnly: Bool
            var hnID: UInt64?
            var comments: [String] = []
            var summary: String?

            init(_ f: FeedItem, source: ShowSource, key: String) {
                title = f.title
                url = f.url
                label = f.comments.map { String(localized: "\(source.name) · \($0) 条评论") } ?? source.name
                weight = source.weight
                self.key = key
                text = f.text
                summaryOnly = f.summaryOnly
                hnID = f.discussion.flatMap { $0.split(separator: "=").last.flatMap { UInt64($0) } }
            }
        }

        var date: String
        var items: [Item] = []
        var picked: [Int]?
        var skipped: String?
        var script: String?
    }

    private func file(_ show: String) -> URL { workDir.appending(path: "work-\(show).json") }

    private func load(_ show: String) -> Work {
        (try? Data(contentsOf: file(show))).flatMap { try? JSONDecoder().decode(Work.self, from: $0) } ?? Work(date: Self.today)
    }

    private func save(_ show: String, _ work: Work) {
        try? JSONEncoder().encode(work).write(to: file(show), options: .atomic)
    }

    private func clear(_ show: String) {
        try? FileManager.default.removeItem(at: file(show))
    }

    static var today: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static func message(for error: Error) -> String {
        switch error {
        case let e as PodcastError: e.errorDescription ?? ""
        case let e as CoreError: Library.message(for: e)
        default: Companion.message(for: error)
        }
    }
}

/// `article(html:)`, named so it isn't taken for something of the type's.
private func extractArticle(_ html: String) -> Article { article(html: html) }

enum PodcastError: LocalizedError {
    case noModel, nothingNew, badScript, download(String)

    var errorDescription: String? {
        switch self {
        case .noModel: String(localized: "还没选写稿用的模型。设置 › 书伴 里选一个服务商")
        case .nothingNew: String(localized: "信息源里没有新内容")
        case .badScript: String(localized: "模型交回的稿子格式不对，再试一次")
        case .download(let host): String(localized: "取不到 \(host) 的内容")
        }
    }
}
