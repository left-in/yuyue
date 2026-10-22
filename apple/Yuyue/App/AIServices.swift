import Foundation
import SwiftUI

/// 设置 · AI 服务: the services the reader has connected, once, for everything that asks a model
/// (书伴 today). Each is a preset (Claude, DeepSeek, magpie on this Mac…) with its own address and
/// the models it said it has; keys live in the keychain. Connecting asks the service for its
/// models, so nobody types a model name or an address unless they add a 自定义 one.
nonisolated struct AIPreset: Identifiable, Hashable {
    enum Style { case anthropic, openAI }

    let id: String
    let name: String
    let style: Style
    let url: String
    /// Starts of its keys, to tell whose a pasted key is.
    var prefixes: [String] = []
    /// Runs on this computer: found by asking its port, no key.
    var local = false
    /// Its key, when it takes a fixed one (magpie's gateway).
    var fixedKey: String?
    /// The model to start 书伴 on, if the service has it.
    var preferred: [String] = []
    var color: Color

    static let all: [AIPreset] = [
        AIPreset(id: "magpie", name: "magpie", style: .openAI, url: "http://127.0.0.1:3425/v1/", local: true, fixedKey: "magpie",
                 color: Color(red: 0.11, green: 0.11, blue: 0.13)),
        AIPreset(id: "ollama", name: "Ollama", style: .openAI, url: "http://localhost:11434/v1/", local: true,
                 color: Color(red: 0.36, green: 0.43, blue: 0.31)),
        AIPreset(id: "lmstudio", name: "LM Studio", style: .openAI, url: "http://localhost:1234/v1/", local: true,
                 color: Color(red: 0.29, green: 0.35, blue: 0.43)),
        AIPreset(id: "claude", name: "Claude", style: .anthropic, url: "https://api.anthropic.com/v1/", prefixes: ["sk-ant-"],
                 preferred: ["claude-opus-5-5", "claude-sonnet-5-5"], color: Color(red: 0.79, green: 0.39, blue: 0.26)),
        AIPreset(id: "openai", name: "OpenAI", style: .openAI, url: "https://api.openai.com/v1/", prefixes: ["sk-proj-", "sk-svcacct-"],
                 color: Color(red: 0.11, green: 0.11, blue: 0.13)),
        AIPreset(id: "gemini", name: "Gemini", style: .openAI, url: "https://generativelanguage.googleapis.com/v1beta/openai/", prefixes: ["AIza"],
                 preferred: ["gemini-2.5-flash"], color: Color(red: 0.29, green: 0.48, blue: 0.82)),
        AIPreset(id: "deepseek", name: "DeepSeek", style: .openAI, url: "https://api.deepseek.com/v1/", prefixes: ["sk-"],
                 preferred: ["deepseek-chat"], color: Color(red: 0.30, green: 0.42, blue: 1.0)),
        AIPreset(id: "kimi", name: "Kimi", style: .openAI, url: "https://api.moonshot.ai/v1/", prefixes: ["sk-"],
                 color: Color(red: 0.16, green: 0.13, blue: 0.14)),
        AIPreset(id: "qwen", name: String(localized: "通义千问"), style: .openAI, url: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/", prefixes: ["sk-"],
                 color: Color(red: 0.42, green: 0.31, blue: 0.90)),
        AIPreset(id: "zhipu", name: String(localized: "智谱 GLM"), style: .openAI, url: "https://api.z.ai/api/paas/v4/",
                 color: Color(red: 0.17, green: 0.42, blue: 0.69)),
        AIPreset(id: "openrouter", name: "OpenRouter", style: .openAI, url: "https://openrouter.ai/api/v1/", prefixes: ["sk-or-"],
                 color: Color(red: 0.42, green: 0.45, blue: 0.50)),
        AIPreset(id: "xai", name: "xAI Grok", style: .openAI, url: "https://api.x.ai/v1/", prefixes: ["xai-"],
                 color: Color(red: 0.07, green: 0.07, blue: 0.07)),
        AIPreset(id: "mistral", name: "Mistral", style: .openAI, url: "https://api.mistral.ai/v1/",
                 color: Color(red: 0.94, green: 0.54, blue: 0.14)),
        AIPreset(id: "siliconflow", name: String(localized: "硅基流动"), style: .openAI, url: "https://api.siliconflow.com/v1/", prefixes: ["sk-"],
                 color: Color(red: 0.48, green: 0.23, blue: 0.18)),
        AIPreset(id: "custom", name: String(localized: "自定义"), style: .openAI, url: "",
                 color: Color(red: 0.79, green: 0.77, blue: 0.74)),
    ]

    static func find(_ id: String) -> AIPreset { all.first { $0.id == id } ?? all.last! }

    /// The ones a key is pasted into, in the 添加服务 grid.
    static var keyed: [AIPreset] { all.filter { !$0.local } }
}

struct AIService: Codable, Identifiable, Hashable {
    var id: String
    var preset: String
    var name: String
    var url: String
    var models: [String]

    var kind: AIPreset { AIPreset.find(preset) }
    var key: String { kind.fixedKey ?? Keychain.read("ai.key.\(id)") ?? "" }

    /// What 书伴 needs to ask this service with `model`.
    func config(_ model: String) -> CompanionConfig {
        CompanionConfig(provider: kind.style == .anthropic ? .claude : .openai, key: key, model: model, url: url, name: name)
    }

    /// "Key …a8F2 · 6 个模型", "127.0.0.1:3425 · 23 个模型"
    var detail: String {
        let place: String
        if kind.local {
            place = URL(string: url).map { "\($0.host() ?? ""):\($0.port.map(String.init) ?? "")" } ?? url
        } else {
            let k = key
            place = k.count > 4 ? String(localized: "Key …\(String(k.suffix(4)))") : (URL(string: url)?.host() ?? url)
        }
        return String(localized: "\(place) · \(models.count) 个模型")
    }
}

/// Who uses which: "apple", or a service's id and one of its models.
struct AIChoice: Equatable {
    var service: String
    var model: String

    static let apple = AIChoice(service: "apple", model: "")
}

@MainActor @Observable
final class AIServices {
    static let shared = AIServices()

    private(set) var services: [AIService] = []
    /// 书伴's.
    var companion: AIChoice {
        didSet { save() }
    }

    private init() {
        let d = UserDefaults.standard
        services = (d.data(forKey: "ai.services")).flatMap { try? JSONDecoder().decode([AIService].self, from: $0) } ?? []
        let raw = d.string(forKey: "ai.companion") ?? "apple"
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        companion = parts.count == 2 ? AIChoice(service: parts[0], model: parts[1]) : .apple
        migrate()
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(services), forKey: "ai.services")
        d.set(companion == .apple ? "apple" : "\(companion.service)|\(companion.model)", forKey: "ai.companion")
    }

    /// Keys filled in on the old 书伴 page come across as services, once.
    private func migrate() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "ai.migrated") else { return }
        d.set(true, forKey: "ai.migrated")
        let was = d.string(forKey: "companion.provider")
        for p in [CompanionProvider.claude, .deepseek, .gemini, .openai] {
            let old = CompanionConfig.saved(p)
            guard old.isReady else { continue }
            let preset = p == .openai ? (old.url.contains("11434") ? "ollama" : "custom") : p.rawValue
            let kind = AIPreset.find(preset)
            let service = AIService(id: UUID().uuidString, preset: preset, name: kind.name,
                                    url: old.url.isEmpty ? kind.url : old.url, models: [old.model])
            Keychain.write("ai.key.\(service.id)", old.key)
            services.append(service)
            if was == p.rawValue { companion = AIChoice(service: service.id, model: old.model) }
        }
        save()
    }

    func service(_ id: String) -> AIService? { services.first { $0.id == id } }

    /// What 书伴 asks with now.
    var companionConfig: CompanionConfig {
        if let s = service(companion.service) { return s.config(companion.model) }
        return CompanionConfig(provider: .apple, key: "", model: "", url: "")
    }

    var companionLabel: String {
        guard let s = service(companion.service) else { return CompanionConfig(provider: .apple, key: "", model: "", url: "").label }
        return "\(s.name) · \(companion.model)"
    }

    @discardableResult
    func add(_ kind: AIPreset, key: String, url: String? = nil, models: [String]) -> AIService {
        let service = AIService(id: UUID().uuidString, preset: kind.id, name: kind.name, url: url ?? kind.url, models: models)
        if kind.fixedKey == nil, !key.isEmpty { Keychain.write("ai.key.\(service.id)", key) }
        services.append(service)
        // The first one connected answers 书伴 straight away, on its best model.
        if self.service(companion.service) == nil && (Companion.appleAvailability != nil || services.count == 1) {
            companion = AIChoice(service: service.id, model: Self.pick(models, kind))
        }
        save()
        return service
    }

    func remove(_ s: AIService) {
        services.removeAll { $0.id == s.id }
        Keychain.delete("ai.key.\(s.id)")
        if companion.service == s.id { companion = .apple }
        save()
    }

    func refresh(_ s: AIService) async throws {
        let models = try await Self.models(s.kind, url: s.url, key: s.key)
        guard let i = services.firstIndex(where: { $0.id == s.id }) else { return }
        services[i].models = models
        save()
    }

    /// The model to start on: the preset's favourite it has, a magpie group, or the first.
    static func pick(_ models: [String], _ kind: AIPreset) -> String {
        kind.preferred.first(where: models.contains)
            ?? models.first { $0.hasPrefix("group/") }
            ?? models.first ?? ""
    }

    // MARK: Asking the services

    /// The models a service says it has.
    nonisolated static func models(_ kind: AIPreset, url: String, key: String) async throws -> [String] {
        guard let base = URL(string: url.hasSuffix("/") ? url : url + "/") else { throw CompanionError.notReady }
        var r = URLRequest(url: base.appending(path: "models"), timeoutInterval: kind.local ? 2 : 12)
        if kind.style == .anthropic {
            r.setValue(key, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !key.isEmpty {
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw CompanionError.badKey }
        guard (200 ..< 300).contains(code) else { throw CompanionError.status(code, nil) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let list = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) ?? []
        let ids = list.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
            // Chat models only: not the ones that draw, speak, hear or embed.
            .filter { id in !["embed", "tts", "whisper", "dall-e", "image", "audio", "moderation", "transcribe", "realtime"].contains { id.lowercased().contains($0) } }
        guard !ids.isEmpty else { throw CompanionError.empty }
        return ids
    }

    /// The services running on this computer that aren't connected yet.
    func discover() async -> [(AIPreset, [String])] {
        #if os(macOS)
        let wanted = AIPreset.all.filter { p in p.local && !services.contains { $0.preset == p.id } }
        return await withTaskGroup(of: (AIPreset, [String])?.self) { group in
            for p in wanted {
                group.addTask {
                    guard let models = try? await Self.models(p, url: p.url, key: p.fixedKey ?? "") else { return nil }
                    return (p, models)
                }
            }
            var found: [(AIPreset, [String])] = []
            for await f in group { if let f { found.append(f) } }
            return found.sorted { a, b in AIPreset.all.firstIndex(of: a.0)! < AIPreset.all.firstIndex(of: b.0)! }
        }
        #else
        return []
        #endif
    }

    /// Whose a pasted key is: its start says it outright, or the services that take its shape
    /// are each asked, and the one that answers is it.
    nonisolated static func identify(_ key: String) async -> (AIPreset, [String])? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count > 8 else { return nil }
        let exact = AIPreset.keyed.filter { p in p.prefixes.contains { $0 != "sk-" && key.hasPrefix($0) } }
        let candidates: [AIPreset]
        if !exact.isEmpty {
            candidates = exact
        } else if key.hasPrefix("sk-") {
            candidates = AIPreset.keyed.filter { $0.prefixes.contains("sk-") || $0.id == "openai" }
        } else {
            candidates = AIPreset.keyed.filter { $0.prefixes.isEmpty && $0.id != "custom" }
        }
        return await withTaskGroup(of: (AIPreset, [String])?.self) { group in
            for p in candidates {
                group.addTask { (try? await models(p, url: p.url, key: key)).map { (p, $0) } }
            }
            for await found in group {
                if let found { group.cancelAll(); return found }
            }
            return nil
        }
    }
}
