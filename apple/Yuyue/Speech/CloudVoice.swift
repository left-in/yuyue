import AVFoundation
import CryptoKit
import Foundation

/// 用户自带 Key 的云端语音: OpenAI, Microsoft (Azure Speech) and ElevenLabs, each with the
/// reader's own key from the keychain. Every sentence is kept once rendered, by voice and
/// text, so a chapter heard (or fetched ahead, see `prefetch`) plays again offline and costs
/// nothing the second time.
nonisolated final class CloudVoice: Voice, @unchecked Sendable {
    enum Provider: String, CaseIterable, Identifiable, Sendable {
        case openai, azure, elevenlabs
        var id: String { rawValue }

        var title: String {
            switch self {
            case .openai: "OpenAI"
            case .azure: String(localized: "微软 Azure")
            case .elevenlabs: "ElevenLabs"
            }
        }

        var keyName: String { "tts.\(rawValue).key" }
        /// Azure's region, such as eastasia.
        static let regionName = "tts.azure.region"
        var voicesName: String { "tts.\(rawValue).voices" }

        var key: String? { Keychain.read(keyName).flatMap { $0.isEmpty ? nil : $0 } }
        var isSetUp: Bool { key != nil && (self != .azure || !(UserDefaults.standard.string(forKey: Self.regionName) ?? "").isEmpty) }

        var keyHint: String {
            switch self {
            case .openai: "sk-…"
            case .azure: String(localized: "资源的密钥 1")
            case .elevenlabs: "sk_…"
            }
        }

        var help: String {
            switch self {
            case .openai: String(localized: "platform.openai.com › API keys 里建一个。费用按字数算，走你的账号。")
            case .azure: String(localized: "Azure 门户里建一个“语音”资源，拷它的密钥和区域（比如 eastasia）。有免费额度。")
            case .elevenlabs: String(localized: "elevenlabs.io › 个人资料 › API Keys。额度按字数算。")
            }
        }
    }

    let id: String
    let name: String
    let provider: Provider
    /// The voice's own language (Azure), or nil for one that reads every language.
    let language: String?
    /// The provider's id for it: OpenAI's voice name, Azure's ShortName, ElevenLabs' voice_id.
    let voiceID: String

    init(provider: Provider, voiceID: String, name: String, language: String?) {
        self.provider = provider
        self.voiceID = voiceID
        self.name = name
        self.language = language
        id = "cloud.\(provider.rawValue).\(voiceID)"
    }

    var qualityName: String? { provider.title }
    var isOffline: Bool { false }

    func speaks(_ tag: String) -> Bool {
        language.map { SpokenLanguage.matches($0, tag) } ?? true
    }

    func render(_ text: String, language: String) async throws -> Speech? {
        guard text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
        let file = cacheFile(text)
        if let data = try? Data(contentsOf: file) {
            return try Self.decode(data)
        }
        let data = try await fetch(text, language: language)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return try Self.decode(data)
    }

    /// Renders the sentences not kept yet, two at a time, so the chapter plays on without the
    /// network. Stops at the first failure; the player reports its own.
    func prefetch(_ texts: [String], language: String) async {
        let missing = texts.filter { t in
            t.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) && !FileManager.default.fileExists(atPath: cacheFile(t).path)
        }
        var i = 0
        while i < missing.count, !Task.isCancelled {
            let pair = missing[i ..< min(i + 2, missing.count)]
            let ok = await withTaskGroup(of: Bool.self) { group in
                for t in pair { group.addTask { (try? await self.render(t, language: language)) != nil } }
                return await group.reduce(true) { $0 && $1 }
            }
            if !ok { return }
            i += 2
        }
    }

    // MARK: Cache

    static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "yuyue-voices", directoryHint: .isDirectory)
    }

    private func cacheFile(_ text: String) -> URL {
        let hash = SHA256.hash(data: Data((id + "\u{1}" + text).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return Self.cacheDir.appending(path: provider.rawValue).appending(path: "\(hash).wav")
    }

    // MARK: Fetching

    enum Failure: LocalizedError {
        case noKey(Provider)
        case badKey(Provider)
        case noCredit(Provider)
        case busy(Provider)
        case server(Provider, Int, String?)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noKey(let p): String(localized: "还没填 \(p.title) 的 Key")
            case .badKey(let p): String(localized: "\(p.title) 的 Key 不对")
            case .noCredit(let p): String(localized: "\(p.title) 的额度用完了")
            case .busy(let p): String(localized: "\(p.title) 说太忙，等一会儿再试")
            case .server(let p, let code, let message): message.map { "\(p.title) \(code): \($0)" } ?? "\(p.title) \(code)"
            case .unreadable: String(localized: "声音数据读不出来")
            }
        }
    }

    private func fetch(_ text: String, language: String) async throws -> Data {
        guard let key = provider.key else { throw Failure.noKey(provider) }
        var request: URLRequest
        switch provider {
        case .openai:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "gpt-4o-mini-tts", "voice": voiceID, "input": text, "response_format": "wav",
            ])
        case .azure:
            let region = UserDefaults.standard.string(forKey: Provider.regionName) ?? ""
            request = URLRequest(url: URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1")!)
            request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
            request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
            request.setValue("riff-24khz-16bit-mono-pcm", forHTTPHeaderField: "X-Microsoft-OutputFormat")
            request.setValue("Yuyue", forHTTPHeaderField: "User-Agent")
            let lang = self.language ?? SpokenLanguage.voiceLanguages(for: language).first ?? "en-US"
            let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            request.httpBody = Data("<speak version='1.0' xml:lang='\(lang)'><voice name='\(voiceID)'>\(escaped)</voice></speak>".utf8)
        case .elevenlabs:
            request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)?output_format=pcm_24000")!)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "model_id": "eleven_multilingual_v2"])
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else { throw Self.failure(provider, code, data) }
        // ElevenLabs sends bare 16-bit samples; keep every voice's audio as WAV.
        return provider == .elevenlabs ? Self.wav(pcm: data, rate: 24_000) : data
    }

    static func failure(_ p: Provider, _ code: Int, _ data: Data) -> Failure {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = json?["detail"] as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String ?? detail?["message"] as? String ?? json?["message"] as? String
        switch code {
        case 401, 403: return (detail?["status"] as? String) == "quota_exceeded" ? .noCredit(p) : .badKey(p)
        case 402: return .noCredit(p)
        case 429: return message?.contains("quota") == true ? .noCredit(p) : .busy(p)
        default: return .server(p, code, message)
        }
    }

    // MARK: Audio

    static func decode(_ data: Data) throws -> Speech? {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).wav")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = try AVAudioFile(forReading: tmp)
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw Failure.unreadable
        }
        try file.read(into: buffer)
        return Speech.make(from: [buffer])
    }

    /// 16-bit mono samples in a WAV header.
    static func wav(pcm: Data, rate: Int) -> Data {
        var d = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); put(UInt32(pcm.count))
        d.append(pcm)
        return d
    }

    // MARK: The voices

    /// OpenAI's voices read every language.
    static let openAIVoices = ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer"]

    /// The voices of the providers that have a key, from the lists fetched when it was saved.
    static func all() -> [CloudVoice] {
        Provider.allCases.filter(\.isSetUp).flatMap { p -> [CloudVoice] in
            switch p {
            case .openai:
                return openAIVoices.map { CloudVoice(provider: p, voiceID: $0, name: $0.capitalized, language: nil) }
            case .azure, .elevenlabs:
                let saved = UserDefaults.standard.array(forKey: p.voicesName) as? [[String]] ?? []
                return saved.compactMap { v in
                    guard v.count >= 2 else { return nil }
                    return CloudVoice(provider: p, voiceID: v[0], name: v[1], language: v.count > 2 && !v[2].isEmpty ? v[2] : nil)
                }
            }
        }
    }

    /// Checks the key by fetching the provider's voices, and keeps the list.
    static func refresh(_ p: Provider) async throws -> Int {
        guard let key = p.key else { throw Failure.noKey(p) }
        switch p {
        case .openai:
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models/gpt-4o-mini-tts")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200 ..< 300).contains(code) else { throw failure(p, code, data) }
            return openAIVoices.count
        case .azure:
            let region = UserDefaults.standard.string(forKey: Provider.regionName) ?? ""
            var request = URLRequest(url: URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/voices/list")!)
            request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200 ..< 300).contains(code) else { throw failure(p, code, data) }
            let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            // Only the neural voices for Chinese and English: the rest are hundreds.
            let voices: [[String]] = list.compactMap { v in
                guard let short = v["ShortName"] as? String, let locale = v["Locale"] as? String,
                      locale.hasPrefix("zh") || locale.hasPrefix("en") || locale.hasPrefix("ja") else { return nil }
                return [short, (v["LocalName"] as? String ?? short), locale]
            }
            UserDefaults.standard.set(voices, forKey: p.voicesName)
            return voices.count
        case .elevenlabs:
            var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200 ..< 300).contains(code) else { throw failure(p, code, data) }
            let list = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["voices"] as? [[String: Any]] ?? []
            let voices: [[String]] = list.compactMap { v in
                guard let id = v["voice_id"] as? String, let name = v["name"] as? String else { return nil }
                return [id, name, ""]
            }
            UserDefaults.standard.set(voices, forKey: p.voicesName)
            return voices.count
        }
    }
}
