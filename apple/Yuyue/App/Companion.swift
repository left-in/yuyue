import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Where 书伴's answers come from (FEATURES §3.8): the model on this device, or a service the
/// user added with their own key. No service of ours sits in between; keys stay in the
/// keychain and are not synced. 添加服务商 picks from `catalog`, grouped by how it's reached as
/// nanobot's webui groups them (登录 / API Key / 本机和局域网), or adds one of the user's own
/// (any OpenAI-shaped address). The logos are LobeHub Icons, from shared/provider-icons.
struct CompanionProvider: Hashable, Identifiable {
    /// How it's asked.
    enum Kind { case apple, anthropic, openAI }
    /// Its group in 添加服务商: how it's reached.
    enum Group: CaseIterable {
        /// Signed in to on its own page (OpenRouter's sign-in for apps); a key can still be pasted.
        case signIn
        case key
        /// A model or gateway on this computer or the network: Ollama, LM Studio, magpie.
        case local

        var title: String {
            switch self {
            case .signIn: String(localized: "登录账号")
            case .key: "API Key"
            case .local: String(localized: "本机和局域网")
            }
        }
    }

    let id: String
    let title: String
    var kind = Kind.openAI
    var group = Group.key
    /// Who the bill goes to, for the key form.
    var account = String(localized: "服务商")
    var defaultModel = ""
    var defaultURL: URL?
    var keyHint = "sk-…"
    /// What else it's searched by: its company, its Chinese name.
    var aliases = ""
    /// A line under its name in 添加服务商.
    var blurb: String?
    /// Sent when no key is filled in: magpie's gateway takes any.
    var defaultKey = ""

    static let apple = CompanionProvider(id: "apple", title: String(localized: "Apple 智能"), kind: .apple, group: .local)

    /// What 添加服务商 offers, in its order. The OpenAI-shaped ones differ only in address.
    static let catalog: [CompanionProvider] = [
        .init(id: "openrouter", title: "OpenRouter", group: .signIn, account: "OpenRouter", defaultModel: "openrouter/auto",
              defaultURL: URL(string: "https://openrouter.ai/api/v1/"), keyHint: "sk-or-…",
              blurb: String(localized: "登录就能用，几百个模型一个账号")),
        .init(id: "claude", title: "Claude", kind: .anthropic, account: "Anthropic", defaultModel: "claude-opus-5-5",
              defaultURL: URL(string: "https://api.anthropic.com/v1/"), keyHint: "sk-ant-…", aliases: "anthropic 克劳德"),
        .init(id: "openai", title: "OpenAI", account: "OpenAI", defaultModel: "gpt-5-mini",
              defaultURL: URL(string: "https://api.openai.com/v1/"), aliases: "chatgpt gpt"),
        .init(id: "gemini", title: "Gemini", account: "Google", defaultModel: "gemini-2.5-flash",
              defaultURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/"), keyHint: "AIza…", aliases: "google 谷歌"),
        .init(id: "deepseek", title: "DeepSeek", account: "DeepSeek", defaultModel: "deepseek-chat",
              defaultURL: URL(string: "https://api.deepseek.com/v1/"), aliases: "深度求索"),
        .init(id: "dashscope", title: String(localized: "通义千问"), account: String(localized: "阿里云百炼"), defaultModel: "qwen-plus",
              defaultURL: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/"), aliases: "qwen 阿里 百炼 dashscope"),
        .init(id: "moonshot", title: "Kimi", account: String(localized: "月之暗面"), defaultModel: "kimi-k2-turbo-preview",
              defaultURL: URL(string: "https://api.moonshot.cn/v1/"), aliases: "moonshot 月之暗面"),
        .init(id: "zhipu", title: String(localized: "智谱 GLM"), account: String(localized: "智谱"), defaultModel: "glm-4.6",
              defaultURL: URL(string: "https://open.bigmodel.cn/api/paas/v4/"), aliases: "zhipu glm z.ai 清言"),
        .init(id: "volcengine", title: String(localized: "豆包"), account: String(localized: "火山引擎"), defaultModel: "doubao-seed-1-6-250615",
              defaultURL: URL(string: "https://ark.cn-beijing.volces.com/api/v3/"), aliases: "doubao 火山引擎 volcengine 字节"),
        .init(id: "siliconflow", title: String(localized: "硅基流动"), account: String(localized: "硅基流动"), defaultModel: "deepseek-ai/DeepSeek-V3",
              defaultURL: URL(string: "https://api.siliconflow.cn/v1/"), aliases: "siliconflow"),
        .init(id: "minimax", title: "MiniMax", account: "MiniMax", defaultModel: "MiniMax-M2",
              defaultURL: URL(string: "https://api.minimaxi.com/v1/"), aliases: "海螺 稀宇"),
        .init(id: "xai", title: "Grok", account: "xAI", defaultModel: "grok-4",
              defaultURL: URL(string: "https://api.x.ai/v1/"), keyHint: "xai-…", aliases: "xai"),
        .init(id: "mistral", title: "Mistral", account: "Mistral", defaultModel: "mistral-small-latest",
              defaultURL: URL(string: "https://api.mistral.ai/v1/"), keyHint: ""),
        .init(id: "groq", title: "Groq", account: "Groq", defaultModel: "llama-3.3-70b-versatile",
              defaultURL: URL(string: "https://api.groq.com/openai/v1/"), keyHint: "gsk_…"),
        // On a phone "localhost" is the phone: the address is left to fill.
        .init(id: "magpie", title: "magpie", group: .local, defaultURL: local(3425, host: "127.0.0.1"),
              keyHint: String(localized: "局域网里用才要填网关 Key"), aliases: "喜鹊 网关 gateway",
              blurb: String(localized: "转接你在 magpie 里登录的 Claude、ChatGPT 账号"), defaultKey: "magpie"),
        .init(id: "ollama", title: "Ollama", group: .local, defaultURL: local(11434), keyHint: String(localized: "不用填")),
        .init(id: "lmstudio", title: "LM Studio", group: .local, defaultURL: local(1234), keyHint: String(localized: "不用填")),
    ]

    private static func local(_ port: Int, host: String = "localhost") -> URL? {
        #if os(macOS)
        URL(string: "http://\(host):\(port)/v1/")
        #else
        nil
        #endif
    }

    /// One of the user's own: any OpenAI-shaped address, under a name they give it.
    static func custom(_ title: String, id: String = "custom." + UUID().uuidString.prefix(8).lowercased()) -> CompanionProvider {
        CompanionProvider(id: id, title: title, keyHint: String(localized: "可不填"))
    }

    var isCustom: Bool { id.hasPrefix("custom.") }

    /// Local models and the user's own addresses may go without.
    var needsKey: Bool { group != .local && !isCustom && kind != .apple }

    /// Its logo in the asset catalogue (`scripts/provider-icons.py`); the user's own have none.
    var logo: String? { isCustom || kind == .apple ? nil : "provider-\(id)" }

    var modelHint: String { defaultModel.isEmpty ? String(localized: "比如 qwen3:8b") : defaultModel }

    var urlHint: String {
        if let defaultURL { return defaultURL.absoluteString }
        if id == "magpie" { return String(localized: "比如 http://192.168.1.5:3425/v1") }
        return group == .local ? String(localized: "比如 http://192.168.1.5:11434/v1") : "https://…/v1"
    }

    var detail: String? {
        kind == .apple ? String(localized: "在这台设备上，不联网") : nil
    }

    /// The first letter, on its little square.
    var mark: String { String(title.prefix(1)).uppercased() }

    /// A catalog entry or one of the user's own, by its id.
    static func find(_ id: String) -> CompanionProvider? {
        if id == apple.id { return apple }
        if let p = catalog.first(where: { $0.id == id }) { return p }
        guard id.hasPrefix("custom."), let name = UserDefaults.standard.string(forKey: "companion.name.\(id)") else { return nil }
        return custom(name, id: id)
    }

    /// The services the user added, in the order they were added.
    static var added: [CompanionProvider] {
        migrate()
        return (UserDefaults.standard.stringArray(forKey: "companion.added") ?? []).compactMap(find)
    }

    /// `catalog` less what's already added, matching what's typed in its name, id or aliases.
    static func available(matching query: String) -> [CompanionProvider] {
        let taken = Set(added.map(\.id))
        let q = query.lowercased().filter { !" -_.".contains($0) }
        return catalog.filter { p in
            !taken.contains(p.id) && (q.isEmpty || "\(p.id)\(p.title)\(p.aliases)".lowercased().filter { $0 != " " }.contains(q))
        }
    }

    /// Before 添加服务商 every service had its row and a key was simply filled in. Those with a key
    /// are now added; what was 「OpenAI 兼容接口」 becomes one of the user's own.
    private static func migrate() {
        let d = UserDefaults.standard
        guard d.stringArray(forKey: "companion.added") == nil else { return }
        var ids = ["claude", "deepseek", "gemini"].filter { !(Keychain.read("companion.key.\($0)") ?? "").isEmpty }
        if let url = d.string(forKey: "companion.url.openai"), !url.isEmpty {
            let id = "custom.openai"
            d.set(String(localized: "OpenAI 兼容接口"), forKey: "companion.name.\(id)")
            d.set(url, forKey: "companion.url.\(id)")
            d.set(d.string(forKey: "companion.model.openai"), forKey: "companion.model.\(id)")
            if let key = Keychain.read("companion.key.openai") { Keychain.write("companion.key.\(id)", key) }
            if d.string(forKey: "companion.provider") == "openai" { d.set(id, forKey: "companion.provider") }
            ids.append(id)
        }
        for k in ["companion.url.openai", "companion.model.openai"] { d.removeObject(forKey: k) }
        Keychain.delete("companion.key.openai")
        d.set(ids, forKey: "companion.added")
    }
}

/// The chosen engine and how to reach it.
struct CompanionConfig: Equatable {
    var provider: CompanionProvider
    var key: String
    var model: String
    /// Empty: the service's own address.
    var url: String

    static var current: CompanionConfig {
        get {
            let id = UserDefaults.standard.string(forKey: "companion.provider") ?? ""
            let p = CompanionProvider.added.first { $0.id == id } ?? .apple
            return saved(p)
        }
        set {
            newValue.save()
            UserDefaults.standard.set(newValue.provider.id, forKey: "companion.provider")
        }
    }

    /// What was filled in for a provider before, or its defaults.
    static func saved(_ p: CompanionProvider) -> CompanionConfig {
        let d = UserDefaults.standard
        let model = d.string(forKey: "companion.model.\(p.id)").flatMap { $0.isEmpty ? nil : $0 } ?? p.defaultModel
        return CompanionConfig(provider: p, key: Keychain.read("companion.key.\(p.id)") ?? "", model: model,
                               url: d.string(forKey: "companion.url.\(p.id)") ?? "")
    }

    /// Adds the service, or keeps the changes to one added before.
    func save() {
        guard provider.kind != .apple else { return }
        let d = UserDefaults.standard
        let id = provider.id
        if provider.isCustom { d.set(provider.title, forKey: "companion.name.\(id)") }
        d.set(model, forKey: "companion.model.\(id)")
        d.set(url, forKey: "companion.url.\(id)")
        if key.isEmpty { Keychain.delete("companion.key.\(id)") } else { Keychain.write("companion.key.\(id)", key) }
        let ids = CompanionProvider.added.map(\.id)
        if !ids.contains(id) { d.set(ids + [id], forKey: "companion.added") }
    }

    /// Forgets the service and its key. If it was answering, the device's own takes over.
    static func remove(_ p: CompanionProvider) {
        let d = UserDefaults.standard
        d.set(CompanionProvider.added.map(\.id).filter { $0 != p.id }, forKey: "companion.added")
        for k in ["model", "url", "name"] { d.removeObject(forKey: "companion.\(k).\(p.id)") }
        Keychain.delete("companion.key.\(p.id)")
        if d.string(forKey: "companion.provider") == p.id { d.removeObject(forKey: "companion.provider") }
    }

    /// Its key and address are in: enough to add it, and to list its models.
    var isConnected: Bool {
        switch provider.kind {
        case .apple: return Companion.appleAvailability == nil
        default:
            let typed = url.trimmingCharacters(in: .whitespaces)
            let reachable = typed.isEmpty ? provider.defaultURL != nil : URL(string: typed)?.scheme?.hasPrefix("http") == true
            return reachable && (!provider.needsKey || !key.isEmpty) && !provider.title.isEmpty
        }
    }

    /// Filled in enough to ask: connected, and a model chosen.
    var isReady: Bool { isConnected && (provider.kind == .apple || !model.isEmpty) }

    /// What goes in the request: the key typed in, or the one the service takes without one.
    var sentKey: String { key.isEmpty ? provider.defaultKey : key }

    /// "sk-ant-…3f9a": the saved key, shown without giving it away.
    var maskedKey: String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        return String(key.prefix(key.hasPrefix("sk-") ? 3 : 0)) + "…" + String(key.suffix(4))
    }

    /// "Apple 智能 · 在这台 Mac 上", "DeepSeek · deepseek-chat": under each answer.
    var label: String {
        switch provider.kind {
        case .apple:
            #if os(macOS)
            String(localized: "Apple 智能 · 在这台 Mac 上")
            #else
            String(localized: "Apple 智能 · 在这台设备上")
            #endif
        default: "\(provider.title) · \(model)"
        }
    }
}

/// 测试一下: one short question, how long it took or what went wrong.
enum CompanionTest {
    static func run(_ config: CompanionConfig) async -> Result<TimeInterval, Error> {
        let start = Date()
        do {
            _ = try await Companion.answer(config, system: String(localized: "你是一个简短的助手。"), prompt: String(localized: "用一个词回答：天空通常是什么颜色？"))
            return .success(Date().timeIntervalSince(start))
        } catch {
            return .failure(error)
        }
    }
}

enum CompanionError: LocalizedError {
    case notReady
    case unavailable(String)
    case badKey
    case noCredit
    case busy
    case status(Int, String?)
    case empty

    var errorDescription: String? {
        switch self {
        case .notReady: String(localized: "书伴还没接上：在设置 · 书伴里添加一个服务商")
        case .unavailable(let why): why
        case .badKey: String(localized: "Key 不对，去设置 · 书伴里重新填")
        case .noCredit: String(localized: "账号余额不够了")
        case .busy: String(localized: "问得太快了，等一会儿再问")
        case .status(let code, let message): message.map { String(localized: "服务器回了 \(code)：\($0)") } ?? String(localized: "服务器回了 \(code)")
        case .empty: String(localized: "没有回答，换个问法试试")
        }
    }
}

enum Companion {
    /// Why the model on this device can't answer, or nil when it can.
    static var appleAvailability: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return String(localized: "这台设备用不了 Apple 智能，可以填一个 Key")
            case .unavailable(.appleIntelligenceNotEnabled): return String(localized: "Apple 智能还没打开：系统设置 › Apple 智能")
            case .unavailable(.modelNotReady): return String(localized: "Apple 智能还在下载模型，过一会儿再试")
            case .unavailable: return String(localized: "Apple 智能现在用不了")
            }
        }
        #endif
        return String(localized: "要 macOS 26 或 iOS 26 以上才有 Apple 智能，可以填一个 Key")
    }

    /// One answer: `system` says how to behave, `prompt` carries the excerpts and the question.
    /// The language the companion answers in: the interface's. The prompts stay Chinese, and so
    /// do the markers in them (没读到, 接着问) that the replies are read back by.
    nonisolated static var replyLanguage: String {
        (Bundle.main.preferredLocalizations.first ?? "zh").hasPrefix("zh") ? "简体中文" : "英文（English）"
    }

    /// `maxTokens`: how long the answer may be; 播客's script is longer than 书伴's answers.
    static func answer(_ config: CompanionConfig, system: String, prompt: String, maxTokens: Int = 1024) async throws -> String {
        let text: String
        switch config.provider.kind {
        case .apple: text = try await apple(system: system, prompt: prompt)
        case .anthropic: text = try await claude(config, system: system, prompt: prompt, maxTokens: maxTokens)
        case .openAI: text = try await openAI(config, system: system, prompt: prompt, maxTokens: maxTokens)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CompanionError.empty }
        return trimmed
    }

    private static func apple(system: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            if let why = appleAvailability { throw CompanionError.unavailable(why) }
            let session = LanguageModelSession(instructions: system)
            return try await session.respond(to: prompt).content
        }
        #endif
        throw CompanionError.unavailable(appleAvailability ?? "")
    }

    private static func base(_ config: CompanionConfig) throws -> URL {
        let typed = config.url.trimmingCharacters(in: .whitespaces)
        guard let url = typed.isEmpty ? config.provider.defaultURL : URL(string: typed.hasSuffix("/") ? typed : typed + "/") else {
            throw CompanionError.notReady
        }
        return url
    }

    private static func claude(_ config: CompanionConfig, system: String, prompt: String, maxTokens: Int) async throws -> String {
        var r = URLRequest(url: try base(config).appending(path: "messages"), timeoutInterval: maxTokens > 1024 ? 240 : 90)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(config.sentKey, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let long = maxTokens > 2048
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model, "max_tokens": maxTokens, "system": system,
            "messages": [["role": "user", "content": prompt]], "stream": long,
        ])
        // A long answer (播客's script) takes minutes; streamed, the line stays busy and isn't dropped.
        if long {
            return try await stream(r) { event in
                (event["type"] as? String) == "content_block_delta" ? (event["delta"] as? [String: Any])?["text"] as? String : nil
            }
        }
        let json = try await send(r)
        let blocks = json["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined()
    }

    /// OpenAI, DeepSeek, Gemini (its OpenAI-shaped endpoint), Ollama and the rest.
    private static func openAI(_ config: CompanionConfig, system: String, prompt: String, maxTokens: Int) async throws -> String {
        var r = URLRequest(url: try base(config).appending(path: "chat/completions"), timeoutInterval: maxTokens > 1024 ? 240 : 120)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.sentKey.isEmpty { r.setValue("Bearer \(config.sentKey)", forHTTPHeaderField: "Authorization") }
        let long = maxTokens > 2048
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model, "temperature": 0.3, "max_tokens": maxTokens, "stream": long,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
        ])
        if long {
            return try await stream(r) { event in
                ((event["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["content"] as? String
            }
        }
        let json = try await send(r)
        let choices = json["choices"] as? [[String: Any]] ?? []
        return (choices.first?["message"] as? [String: Any])?["content"] as? String ?? ""
    }

    /// The models the service lists (`GET …/models`, the same shape from Anthropic, OpenAI and the
    /// rest), for the 模型 menu. Ollama, LM Studio and magpie list what's there to use.
    static func models(_ config: CompanionConfig) async throws -> [String] {
        var r = URLRequest(url: try base(config).appending(path: "models"), timeoutInterval: 20)
        if config.provider.kind == .anthropic {
            r.setValue(config.sentKey, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !config.sentKey.isEmpty {
            r.setValue("Bearer \(config.sentKey)", forHTTPHeaderField: "Authorization")
        }
        let json = try await send(r)
        let list = json["data"] as? [[String: Any]] ?? json["models"] as? [[String: Any]] ?? []
        return list.compactMap { ($0["id"] ?? $0["name"]) as? String }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
    }

    /// A streamed answer (server-sent events), joined: `text` takes what each event adds.
    private static func stream(_ request: URLRequest, text: ([String: Any]) -> String?) async throws -> String {
        var r = request
        r.timeoutInterval = 120
        let (bytes, response) = try await URLSession.shared.bytes(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else {
            // Read what it says, and fail the way `send` would.
            var body = Data()
            for try await b in bytes { body.append(b) }
            try check(code, body)
            throw CompanionError.status(code, nil)
        }
        var out = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let event = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
            if let piece = text(event) { out += piece }
        }
        return out
    }

    private static func send(_ r: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        try check(code, data)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Throws what an error status means: a wrong key, no credit, busy.
    private static func check(_ code: Int, _ data: Data) throws {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200 ..< 300).contains(code) else {
            let error = json["error"] as? [String: Any]
            let message = error?["message"] as? String ?? json["message"] as? String
            let kind = "\(error?["type"] ?? "") \(error?["code"] ?? "") \(message ?? "")".lowercased()
            switch code {
            case 401, 403: throw CompanionError.badKey
            case 402: throw CompanionError.noCredit
            case 429 where kind.contains("quota") || kind.contains("credit") || kind.contains("balance"): throw CompanionError.noCredit
            case 429, 529: throw CompanionError.busy
            case 400 where kind.contains("credit") || kind.contains("balance"): throw CompanionError.noCredit
            default: throw CompanionError.status(code, message)
            }
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case let e as CompanionError: e.errorDescription ?? String(localized: "出错了")
        case let e as URLError where e.code == .notConnectedToInternet: String(localized: "没有联网")
        case let e as URLError where e.code == .timedOut: String(localized: "等太久没回答，再问一次")
        case let e as URLError where e.code == .cannotFindHost || e.code == .cannotConnectToHost: String(localized: "连不上服务器，看看接口地址")
        default: error.localizedDescription
        }
    }
}
