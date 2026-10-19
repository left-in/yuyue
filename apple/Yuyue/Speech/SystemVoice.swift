import AVFoundation

/// A voice that comes with the system. AVSpeechSynthesizer renders it into buffers instead of
/// playing it, so it plays through the same player as every other voice.
nonisolated final class SystemVoice: Voice, @unchecked Sendable {
    let id: String
    let name: String
    /// The voice's own language tag, such as zh-CN.
    let language: String
    let quality: AVSpeechSynthesisVoiceQuality

    /// One synthesizer renders for every system voice, one sentence at a time (the player
    /// waits for each sentence before asking for the next).
    nonisolated(unsafe) private static let synthesizer = AVSpeechSynthesizer()

    init(_ voice: AVSpeechSynthesisVoice) {
        id = voice.identifier
        name = voice.name
        language = voice.language
        quality = voice.quality
    }

    func speaks(_ tag: String) -> Bool {
        SpokenLanguage.matches(language, tag)
    }

    func render(_ text: String, language: String) async throws -> Speech? {
        // Text with nothing to pronounce never produces audio, or even the closing callback.
        guard text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: id)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.prefersAssistiveTechnologySettings = false
        let collector = Collector()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                collector.start(continuation)
                Self.synthesizer.write(utterance) { buffer in collector.add(buffer) }
                // A sentence that never finishes must not stall the book.
                DispatchQueue.global().asyncAfter(deadline: .now() + 20 + Double(text.count) * 0.3) { collector.finish() }
            }
        } onCancel: {
            Self.synthesizer.stopSpeaking(at: .immediate)
            collector.finish()
        }
    }

    /// The system voices worth offering, best first within each language.
    static func all() -> [SystemVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .sorted { a, b in
                a.language != b.language ? a.language < b.language : a.quality.rawValue > b.quality.rawValue
            }
            .map(SystemVoice.init)
    }

    /// The system voices that can read `tag`, best first.
    static func all(for tag: String) -> [SystemVoice] {
        let voices = all()
        return SpokenLanguage.voiceLanguages(for: tag).flatMap { language in
            voices.filter { $0.language.lowercased().hasPrefix(language.lowercased()) }
                .sorted { $0.quality.rawValue > $1.quality.rawValue }
        }
    }

    /// Plays a few words straight through the system, for 试听.
    static func preview(_ voice: SystemVoice, text: String) {
        previewer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voice.id)
        utterance.prefersAssistiveTechnologySettings = false
        previewer.speak(utterance)
    }

    nonisolated(unsafe) private static let previewer = AVSpeechSynthesizer()

    /// "增强" · "高级": how good the voice sounds, when it is better than the default.
    var qualityName: String? {
        switch quality {
        case .premium: String(localized: "高级")
        case .enhanced: String(localized: "增强")
        default: nil
        }
    }

    /// The best system voice for text in `tag`.
    static func best(for tag: String) -> SystemVoice? {
        let voices = all()
        for language in SpokenLanguage.voiceLanguages(for: tag) {
            let matching = voices.filter { $0.language.lowercased().hasPrefix(language.lowercased()) }
            if let best = matching.max(by: { $0.quality.rawValue < $1.quality.rawValue }) { return best }
        }
        return nil
    }
}

/// Collects one sentence's buffers from the synthesizer's queue and hands them over once.
private nonisolated final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var continuation: CheckedContinuation<Speech?, Never>?

    func start(_ continuation: CheckedContinuation<Speech?, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func add(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        // The last callback of an utterance carries an empty buffer.
        if pcm.frameLength == 0 { return finish() }
        lock.withLock { buffers.append(pcm) }
    }

    func finish() {
        let (continuation, buffers) = lock.withLock {
            defer { self.continuation = nil; self.buffers = [] }
            return (self.continuation, self.buffers)
        }
        continuation?.resume(returning: Speech.make(from: buffers))
    }
}
