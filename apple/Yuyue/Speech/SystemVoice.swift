import AVFoundation

/// A voice that comes with the system. AVSpeechSynthesizer renders it into buffers instead of
/// playing it, so it plays through the same player as every other voice.
nonisolated final class SystemVoice: Voice, @unchecked Sendable {
    let id: String
    let name: String
    /// The voice's own language tag, such as zh-CN.
    let language: String
    let quality: AVSpeechSynthesisVoiceQuality
    let gender: AVSpeechSynthesisVoiceGender

    /// One synthesizer renders for every system voice, one sentence at a time (the player
    /// waits for each sentence before asking for the next).
    nonisolated(unsafe) private static let synthesizer = AVSpeechSynthesizer()

    init(_ voice: AVSpeechSynthesisVoice) {
        id = voice.identifier
        name = voice.name
        language = voice.language
        quality = voice.quality
        gender = voice.gender
    }

    var isOffline: Bool { true }

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

    /// The system voices worth offering, best first within each language. Asking the system is
    /// slow (a hundred and more voices), and a page asks often, so the list is kept until the
    /// system says its voices changed (one downloaded in 系统设置).
    static func all() -> [SystemVoice] {
        cacheLock.withLock {
            if let cached { return cached }
            let fresh = load()
            cached = fresh
            return fresh
        }
    }

    nonisolated(unsafe) private static var cached: [SystemVoice]?
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static let voicesChanged: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: nil
    ) { _ in SystemVoice.cacheLock.withLock { SystemVoice.cached = nil } }

    /// Starts listening for voices being added or removed.
    static func watch() { _ = voicesChanged }

    private static func load() -> [SystemVoice] {
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
    @MainActor static func preview(_ voice: SystemVoice, text: String) {
        previewer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voice.id)
        utterance.prefersAssistiveTechnologySettings = false
        // How long it will take isn't known ahead; a rough guess, as the reader does without timings.
        PreviewState.shared.began(voice.id, seconds: max(1.8, Double(text.count) * (voice.speaks("zh") ? 0.22 : 0.065)))
        previewWatcher.id = voice.id
        previewer.delegate = previewWatcher
        previewer.speak(utterance)
    }

    @MainActor static func stopPreview() {
        previewer.stopSpeaking(at: .immediate)
    }

    nonisolated(unsafe) private static let previewer = AVSpeechSynthesizer()
    nonisolated(unsafe) private static let previewWatcher = PreviewWatcher()

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

/// Tells `PreviewState` when a system 试听 is done.
private nonisolated final class PreviewWatcher: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var id = ""

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { end() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { end() }

    private func end() {
        let id = id
        Task { @MainActor in PreviewState.shared.ended(id) }
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
