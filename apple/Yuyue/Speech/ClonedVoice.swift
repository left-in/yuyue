import AVFoundation
import Foundation

/// 克隆声音: a voice made from a short recording
/// of someone reading. The recording and what it says stay on this device, in Application
/// Support/clones/<id>; nothing about it syncs. A book that gives one of its characters a cloned
/// voice reads them with the narrator's on a device that doesn't have it.
///
/// What turns the recording into speech is behind `CloneEngine`, to be swapped for a model on
/// the device later. For now that's the reader's own ElevenLabs, when they
/// have a key there; without one the voice is kept and waits, and the narrator reads instead.
nonisolated struct ClonedVoice: Voice {
    nonisolated struct Meta: Codable, Sendable {
        var id: String
        var name: String
        var created: Date
        /// What the recording says, when it was read from the script (导入的 don't know).
        var text: String?
        var seconds: Double
        /// The engine's own id for it, once it has made one.
        var remote: String?
        var engine: String?
    }

    let meta: Meta
    var id: String { meta.id }
    var name: String { meta.name }
    var qualityName: String? { String(localized: "克隆") }
    var isOffline: Bool { false }
    /// Whether it can read yet: an engine has made something of the recording.
    var isReady: Bool { meta.remote != nil }

    func speaks(_ language: String) -> Bool { true }

    func render(_ text: String, language: String) async throws -> Speech? {
        guard let remote = meta.remote else { throw CloneEngine.Failure.notReady }
        return try await CloudVoice(provider: .elevenlabs, voiceID: remote, name: name, language: nil).render(text, language: language)
    }
}

enum ClonedVoices {
    static let changed = Notification.Name("yuyue.clonedVoicesChanged")

    nonisolated static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Yuyue", directoryHint: .isDirectory)
            .appending(path: "clones", directoryHint: .isDirectory)
    }

    nonisolated static func folder(_ id: String) -> URL { dir.appending(path: id, directoryHint: .isDirectory) }
    nonisolated static func sample(_ id: String) -> URL { folder(id).appending(path: "sample.m4a") }

    /// Every cloned voice on this device, newest first.
    nonisolated static func all() -> [ClonedVoice] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return ids.compactMap { id in
            guard let data = try? Data(contentsOf: folder(id).appending(path: "meta.json")),
                  let meta = try? JSONDecoder().decode(ClonedVoice.Meta.self, from: data) else { return nil }
            return ClonedVoice(meta: meta)
        }
        .sorted { $0.meta.created > $1.meta.created }
    }

    nonisolated static func find(_ id: String) -> ClonedVoice? { all().first { $0.meta.id == id } }

    /// Keeps a recording as a new voice and asks the engine to make it. The voice is kept even
    /// when the engine can't yet; it reads once one can.
    static func save(recording: URL, name: String, text: String?, seconds: Double) async throws -> ClonedVoice {
        let id = "cloned." + UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: recording, to: sample(id))
        var meta = ClonedVoice.Meta(id: id, name: name, created: Date(), text: text, seconds: seconds)
        if CloneEngine.available {
            meta.remote = try await CloneEngine.make(name: name, sample: sample(id))
            meta.engine = CloneEngine.name
        }
        try write(meta)
        NotificationCenter.default.post(name: changed, object: nil)
        return ClonedVoice(meta: meta)
    }

    static func rename(_ voice: ClonedVoice, to name: String) throws {
        var meta = voice.meta
        meta.name = name
        try write(meta)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func delete(_ voice: ClonedVoice) {
        try? FileManager.default.removeItem(at: folder(voice.id))
        NotificationCenter.default.post(name: changed, object: nil)
    }

    nonisolated private static func write(_ meta: ClonedVoice.Meta) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(meta).write(to: folder(meta.id).appending(path: "meta.json"), options: .atomic)
    }
}

/// What makes a voice of a recording. Only the reader's own ElevenLabs for now.
enum CloneEngine {
    enum Failure: LocalizedError {
        case notReady
        case engine(String)

        var errorDescription: String? {
            switch self {
            case .notReady: String(localized: "这个克隆的声音还不能念：要先在设置里接上 ElevenLabs")
            case .engine(let m): m
            }
        }
    }

    static let name = "ElevenLabs"
    static var available: Bool { CloudVoice.Provider.elevenlabs.key != nil }

    /// ElevenLabs' 即时克隆: the recording goes to the reader's own account; the voice it makes
    /// is theirs.
    static func make(name: String, sample: URL) async throws -> String {
        guard let key = CloudVoice.Provider.elevenlabs.key else { throw Failure.notReady }
        let boundary = "yuyue-" + UUID().uuidString
        var body = Data()
        func field(_ k: String, _ v: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
        }
        field("name", "语阅 · \(name)")
        field("remove_background_noise", "true")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"sample.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(try Data(contentsOf: sample))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices/add")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else { throw CloudVoice.failure(.elevenlabs, code, data) }
        guard let id = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["voice_id"] as? String else {
            throw Failure.engine(String(localized: "ElevenLabs 没有给回声音"))
        }
        return id
    }
}

/// 检查录音: what can be told from the samples alone. It never refuses a recording; it says
/// what's off and how to do better.
nonisolated struct SampleCheck: Sendable {
    enum Level: Sendable { case ok, warn }
    struct Item: Sendable, Identifiable {
        let id = UUID()
        let level: Level
        let title: String
        var detail: String?
    }

    let seconds: Double
    let items: [Item]

    static func of(_ url: URL) -> SampleCheck {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let samples = buffer.floatChannelData?[0] else {
            return SampleCheck(seconds: 0, items: [Item(level: .warn, title: String(localized: "录音读不出来"), detail: String(localized: "重录一段试试"))])
        }
        let rate = file.processingFormat.sampleRate
        let n = Int(buffer.frameLength)
        let seconds = Double(n) / rate
        // Loudness of each 50 ms: the quiet ones are the room, the loud ones the voice.
        let hop = max(1, Int(rate * 0.05))
        var frames: [Float] = []
        var peak: Float = 0
        var i = 0
        while i + hop <= n {
            var sum: Float = 0
            for k in i ..< i + hop {
                let s = samples[k]
                sum += s * s
                peak = max(peak, abs(s))
            }
            frames.append((sum / Float(hop)).squareRoot())
            i += hop
        }
        let sorted = frames.sorted()
        func at(_ q: Double) -> Float { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        let room = at(0.1), voice = at(0.9)
        var items: [Item] = []
        if seconds < 8 {
            items.append(Item(level: .warn, title: String(localized: "只有 \(Int(seconds)) 秒"), detail: String(localized: "多念几句，8 秒以上更像")))
        } else {
            items.append(Item(level: .ok, title: String(localized: "长度 \(Int(seconds.rounded())) 秒")))
        }
        if voice < 0.02 {
            items.append(Item(level: .warn, title: String(localized: "声音有点小"), detail: String(localized: "离手机近一点，或者大声一点")))
        } else if peak > 0.99 {
            items.append(Item(level: .warn, title: String(localized: "声音太大，有的地方破了"), detail: String(localized: "离远一点再录")))
        } else {
            items.append(Item(level: .ok, title: String(localized: "音量合适")))
        }
        // How far the voice stands above the room.
        let snr = voice > 0 && room > 0 ? 20 * log10(Double(voice / room)) : 60
        if voice < 0.02 {
            // Without a voice to compare with, nothing can be said about the room.
        } else if snr < 20 {
            items.append(Item(level: .warn, title: String(localized: "背景有点吵"), detail: String(localized: "能用；换个安静的地方再录会更像")))
        } else {
            items.append(Item(level: .ok, title: String(localized: "背景很安静")))
        }
        return SampleCheck(seconds: seconds, items: items)
    }
}
