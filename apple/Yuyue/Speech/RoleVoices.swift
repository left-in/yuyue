import AVFoundation
import YuyueCore

/// 分角色朗读: each sentence read by the voice of whoever says it. Nobody has
/// one of their own until the reader gives it: by default everything is the narrator's, so a
/// book sounds as it always did. Lines the script isn't sure of stay the narrator's too.
@MainActor final class BookRoles {
    private let core: YuyueCore
    private let bookID: String
    private var roles: [Role] = []
    private var speakers: [UInt32: [String?]] = [:]

    init(core: YuyueCore, bookID: String) {
        self.core = core
        self.bookID = bookID
        reload()
    }

    func reload() {
        roles = (try? core.bookRoles(bookId: bookID)) ?? []
        speakers = [:]
    }

    /// Whether anyone has a voice, pace or pitch of their own: when not, the script isn't even
    /// read, and the book plays exactly as before.
    var any: Bool { !roles.isEmpty }

    func role(_ name: String) -> RoleVoice? { roles.first { $0.name == name }?.voice }

    /// The voice for one sentence, or nil for the narrator's.
    func voice(section: UInt32, sentence: Int, language: String, narrator: () -> (any Voice)?) -> (any Voice)? {
        guard any else { return nil }
        if speakers[section] == nil { speakers[section] = (try? core.sectionRoles(bookId: bookID, section: section)) ?? [] }
        guard let list = speakers[section], list.indices.contains(sentence), let who = list[sentence], let role = role(who) else { return nil }
        var base: (any Voice)?
        if let id = role.voice, let v = Voices.find(id), v.speaks(language), (v as? ClonedVoice)?.isReady ?? true { base = v }
        if base == nil, abs(role.rate - 1) < 0.01, abs(role.pitch) < 0.01 { return nil }
        guard let voice = base ?? narrator() else { return nil }
        if abs(role.rate - 1) < 0.01, abs(role.pitch) < 0.01 { return voice }
        return TunedVoice(base: voice, rate: Float(role.rate), pitch: Float(role.pitch))
    }
}

/// A voice a little faster or slower, higher or lower: one character's own 快慢 and 高低 on top
/// of whichever voice reads them.
nonisolated struct TunedVoice: Voice {
    let base: any Voice
    let rate: Float
    /// Semitones.
    let pitch: Float

    var id: String { base.id + "#\(rate)#\(pitch)" }
    var name: String { base.name }
    var qualityName: String? { base.qualityName }
    var isOffline: Bool { base.isOffline }
    func speaks(_ language: String) -> Bool { base.speaks(language) }

    func render(_ text: String, language: String) async throws -> Speech? {
        guard let speech = try await base.render(text, language: language) else { return nil }
        return Self.tune(speech, rate: rate, pitch: pitch) ?? speech
    }

    /// The sentence through a time-pitch unit, offline.
    static func tune(_ speech: Speech, rate: Float, pitch: Float) -> Speech? {
        let format = Speech.format
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let unit = AVAudioUnitTimePitch()
        unit.rate = rate
        unit.pitch = pitch * 100
        engine.attach(node)
        engine.attach(unit)
        engine.connect(node, to: unit, format: format)
        engine.connect(unit, to: engine.mainMixerNode, format: format)
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try engine.start()
        } catch { return nil }
        node.scheduleBuffer(speech.buffer)
        node.play()
        let expected = AVAudioFramePosition(Double(speech.buffer.frameLength) / Double(rate)) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(expected) + 4096),
              let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else { return nil }
        while engine.manualRenderingSampleTime < expected {
            let frames = AVAudioFrameCount(min(4096, expected - engine.manualRenderingSampleTime))
            guard (try? engine.renderOffline(frames, to: chunk)) == .success else { break }
            let room = out.frameCapacity - out.frameLength
            let n = min(chunk.frameLength, room)
            if n == 0 { break }
            if let src = chunk.floatChannelData?[0], let dst = out.floatChannelData?[0] {
                (dst + Int(out.frameLength)).update(from: src, count: Int(n))
            }
            out.frameLength += n
        }
        engine.stop()
        return out.frameLength > 0 ? Speech(buffer: out) : nil
    }
}

extension Player.Script {
    /// A book read by its characters' voices, where the reader has given them any.
    static func book(_ core: YuyueCore, _ detail: BookDetail, roles: BookRoles) -> Player.Script {
        var script = Player.Script.book(core, detail)
        script.roles = roles
        return script
    }
}
