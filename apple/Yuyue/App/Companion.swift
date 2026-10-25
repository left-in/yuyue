import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Where 书伴's answers come from (FEATURES §3.8): the model on this device, or the user's own
/// key with one of a few services. No service of ours sits in between; keys stay in the
/// keychain and are not synced.
enum CompanionProvider: String, CaseIterable, Identifiable {
    case apple, claude, deepseek, gemini, openai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: String(localized: "Apple 智能")
        case .claude: "Claude"
        case .deepseek: "DeepSeek"
        case .gemini: "Gemini"
        case .openai: String(localized: "OpenAI 兼容接口")
        }
    }

    var detail: String? {
        switch self {
        case .apple: String(localized: "在这台设备上，不联网")
        case .openai: String(localized: "可以接 Ollama 和自己部署的模型")
        default: nil
        }
    }

    /// Who the bill goes to, for the key form.
    var account: String {
        switch self {
        case .claude: "Anthropic"
        case .deepseek: "DeepSeek"
        case .gemini: "Google"
        default: String(localized: "服务商")
        }
    }

    var needsKey: Bool { self != .apple && self != .openai }

    var defaultModel: String {
        switch self {
        case .apple: ""
        case .claude: "claude-opus-5-5"
        case .deepseek: "deepseek-chat"
        case .gemini: "gemini-2.5-flash"
        case .openai: ""
        }
    }

    var defaultURL: URL? {
        switch self {
        case .claude: URL(string: "https://api.anthropic.com/v1/")
        case .deepseek: URL(string: "https://api.deepseek.com/v1/")
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")
        case .apple, .openai: nil
        }
    }

    var keyHint: String {
        switch self {
        case .claude: "sk-ant-…"
        case .gemini: "AIza…"
        case .openai: String(localized: "Ollama 不用填")
        default: "sk-…"
        }
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
            let p = UserDefaults.standard.string(forKey: "companion.provider").flatMap(CompanionProvider.init) ?? .apple
            return saved(p)
        }
        set {
            let d = UserDefaults.standard
            d.set(newValue.provider.rawValue, forKey: "companion.provider")
            d.set(newValue.model, forKey: "companion.model.\(newValue.provider.rawValue)")
            d.set(newValue.url, forKey: "companion.url.\(newValue.provider.rawValue)")
            Keychain.write("companion.key.\(newValue.provider.rawValue)", newValue.key)
        }
    }

    /// What was filled in for a provider before, or its defaults.
    static func saved(_ p: CompanionProvider) -> CompanionConfig {
        let d = UserDefaults.standard
        let model = d.string(forKey: "companion.model.\(p.rawValue)").flatMap { $0.isEmpty ? nil : $0 } ?? p.defaultModel
        return CompanionConfig(provider: p, key: Keychain.read("companion.key.\(p.rawValue)") ?? "", model: model,
                               url: d.string(forKey: "companion.url.\(p.rawValue)") ?? "")
    }

    /// Filled in enough to ask.
    var isReady: Bool {
        switch provider {
        case .apple: Companion.appleAvailability == nil
        case .openai: URL(string: url)?.scheme?.hasPrefix("http") == true && !model.isEmpty
        default: !key.isEmpty && !model.isEmpty
        }
    }

    /// "Apple 智能 · 在这台 Mac 上", "DeepSeek · deepseek-chat": under each answer.
    var label: String {
        switch provider {
        case .apple:
            #if os(macOS)
            String(localized: "Apple 智能 · 在这台 Mac 上")
            #else
            String(localized: "Apple 智能 · 在这台设备上")
            #endif
        case .openai: model
        default: "\(provider.title) · \(model)"
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
        case .notReady: String(localized: "书伴还没接上：在设置 · 书伴里选一个")
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

    static func answer(_ config: CompanionConfig, system: String, prompt: String) async throws -> String {
        let text: String
        switch config.provider {
        case .apple: text = try await apple(system: system, prompt: prompt)
        case .claude: text = try await claude(config, system: system, prompt: prompt)
        case .deepseek, .gemini, .openai: text = try await openAI(config, system: system, prompt: prompt)
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

    private static func claude(_ config: CompanionConfig, system: String, prompt: String) async throws -> String {
        var r = URLRequest(url: try base(config).appending(path: "messages"), timeoutInterval: 90)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(config.key, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model, "max_tokens": 1024, "system": system,
            "messages": [["role": "user", "content": prompt]],
        ])
        let json = try await send(r)
        let blocks = json["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined()
    }

    /// DeepSeek, Gemini (its OpenAI-shaped endpoint), Ollama and the rest.
    private static func openAI(_ config: CompanionConfig, system: String, prompt: String) async throws -> String {
        var r = URLRequest(url: try base(config).appending(path: "chat/completions"), timeoutInterval: 120)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.key.isEmpty { r.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization") }
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model, "temperature": 0.3,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
        ])
        let json = try await send(r)
        let choices = json["choices"] as? [[String: Any]] ?? []
        return (choices.first?["message"] as? [String: Any])?["content"] as? String ?? ""
    }

    private static func send(_ r: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
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
        return json
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
