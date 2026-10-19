import AVFoundation

/// Something that reads a sentence aloud: the system voices now, offline voices later. Every
/// voice hands its audio to the same `Player`, which plays it, shows it on the lock screen and
/// tells the reader how long each sentence takes.
protocol Voice: Sendable {
    var id: String { get }
    var name: String { get }
    /// Whether the voice can read text in `language` (a BCP 47 tag such as zh-Hans).
    func speaks(_ language: String) -> Bool
    /// The sentence as audio in `Speech.format`; nil when there is nothing to say.
    func render(_ text: String, language: String) async throws -> Speech?
}

/// One rendered sentence.
nonisolated final class Speech: @unchecked Sendable {
    /// Every voice renders to this format, so the player never needs reconnecting.
    static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    /// Immutable once made; the player only reads it.
    let buffer: AVAudioPCMBuffer

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    var seconds: Double { Double(buffer.frameLength) / buffer.format.sampleRate }

    /// Joins a voice's buffers and converts them to `format`.
    static func make(from buffers: [AVAudioPCMBuffer]) -> Speech? {
        guard let first = buffers.first else { return nil }
        let frames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard frames > 0, let converter = AVAudioConverter(from: first.format, to: format) else { return nil }
        let ratio = format.sampleRate / first.format.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var next = 0
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            guard next < buffers.count else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            next += 1
            return buffers[next - 1]
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return Speech(buffer: out)
    }
}

/// Book languages are BCP 47 tags (zh-Hans, zh-Hant, en, …); voices use regional ones (zh-CN, en-US).
nonisolated enum SpokenLanguage {
    /// The voice languages that can read `tag`, best first.
    static func voiceLanguages(for tag: String) -> [String] {
        let t = tag.replacingOccurrences(of: "_", with: "-").lowercased()
        if t == "yue" || t.hasPrefix("zh-hk") || t.hasPrefix("zh-mo") || t.hasPrefix("zh-yue") { return ["zh-HK", "zh-TW", "zh-CN"] }
        if t.hasPrefix("zh-hant") || t.hasPrefix("zh-tw") { return ["zh-TW", "zh-HK", "zh-CN"] }
        if t == "zh" || t.hasPrefix("zh-") || t == "cmn" || t.hasPrefix("cmn-") { return ["zh-CN", "zh-TW"] }
        if t == "en" || t.hasPrefix("en-") { return ["en-US", "en-GB", "en"] }
        return [String(t.split(separator: "-").first ?? "")]
    }

    /// Whether a voice for `voiceLanguage` (zh-CN) can read text in `tag` (zh-Hans).
    static func matches(_ voiceLanguage: String, _ tag: String) -> Bool {
        voiceLanguages(for: tag).contains { voiceLanguage.lowercased().hasPrefix($0.lowercased()) }
    }
}
