import AVFoundation
import MediaPlayer
import YuyueCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Reads a book aloud one sentence at a time, for every voice alike.
///
/// A sentence is rendered to audio before it plays, so its length is known exactly and the
/// reader's ink line keeps pace with the voice. Two sentences are kept rendered ahead, so
/// sentences and chapters follow one another without a gap. Speed is applied while playing,
/// so changing it takes effect at once. The lock screen shows the book and takes play, pause,
/// next and previous sentence.
@Observable
final class Player {
    enum State { case stopped, loading, playing, paused }

    /// A sentence of the book.
    struct Spot: Equatable {
        var section: UInt32
        var sentence: Int

        var position: Position { Position(section: section, sentence: UInt32(max(0, sentence))) }
    }

    private(set) var state = State.stopped
    /// The sentence being read or paused on.
    private(set) var spot: Spot?
    /// Speed, 0.5–3.
    var rate: Float = 1 {
        didSet { if rate != oldValue { rateChanged(from: oldValue) } }
    }
    var failure: String?
    /// 睡眠定时: when to stop on its own. It always stops between sentences.
    var sleep = Sleep.off
    /// 单句循环: reads the same sentence over and over.
    var loop = false
    /// 有声书: the narrator's recording of the book, read instead of a voice where it has the
    /// sentence. Sentences it doesn't have are read by the voice (用朗读补上).
    @ObservationIgnored var recording: Recording?
    /// 原声: listening to the recording rather than a voice.
    var usesRecording = true {
        didSet { if usesRecording != oldValue { restartHere() } }
    }
    /// Whether the narrator is reading now.
    var narrated: Bool { recording != nil && usesRecording }

    /// What is read, one section after another: a book's chapters from the core, or a PDF's
    /// pages, each a section of its own.
    struct Script {
        var sentences: (UInt32) -> [String]
        /// The next section with something to read, and the one before.
        var next: (UInt32) -> UInt32?
        var previous: (UInt32) -> UInt32?
        var language: (UInt32) -> String
        /// What the lock screen calls the section.
        var title: (UInt32) -> String?
        /// 播客: the voice for one sentence (its host's); none reads the whole book in one voice.
        var voice: ((UInt32, Int, String) -> (any Voice)?)? = nil
        /// 分角色: the characters' own voices, where the reader has given any.
        var roles: BookRoles? = nil

        static func book(_ core: YuyueCore, _ detail: BookDetail) -> Script {
            let id = detail.summary.id
            return Script(
                sentences: { (try? core.spokenSentences(bookId: id, section: $0)) ?? [] },
                next: { (try? core.nextSection(bookId: id, section: $0, speech: true)) ?? nil },
                previous: { (try? core.previousSection(bookId: id, section: $0, speech: true)) ?? nil },
                language: { i in detail.sections.indices.contains(Int(i)) ? detail.sections[Int(i)].lang : detail.summary.language },
                title: { detail.chapterTitle(for: $0) })
        }
    }

    enum Sleep: Equatable {
        case off
        /// 本句读完
        case sentence
        /// 本章结束
        case chapter
        /// After some minutes: the moment to stop.
        case until(Date, minutes: Int)
    }

    /// The ink line: the sentence, its length and how much of it has been read (both in ms at
    /// the current speed), and whether it is moving.
    @ObservationIgnored var onSentence: ((Spot, Double, Double, Bool) -> Void)?
    @ObservationIgnored var onStop: (() -> Void)?
    /// The book was read to its last sentence (after `onStop`): 连着听 moves on to the next episode.
    @ObservationIgnored var onFinish: (() -> Void)?
    /// The sleep timer stopped the voice, paused on this sentence.
    @ObservationIgnored var onSleep: ((Spot) -> Void)?
    /// 双击耳机 (下一曲 to the headphones): the sentence just heard, to highlight.
    @ObservationIgnored var onMarkHeard: ((Spot) -> Void)?

    @ObservationIgnored private let detail: BookDetail
    @ObservationIgnored private let script: Script
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private let speed = AVAudioUnitTimePitch()

    private struct Line {
        let spot: Spot
        let speech: Speech
    }

    /// Bumped whenever the queue is thrown away, so late callbacks for it are ignored.
    @ObservationIgnored private var generation = 0
    /// Sentences handed to the audio node, in order; the first is the one playing.
    @ObservationIgnored private var queued: [Line] = []
    /// Whether the first queued sentence has started.
    @ObservationIgnored private var started = false
    @ObservationIgnored private var nextToRender: Spot?
    @ObservationIgnored private var rendering: Task<Void, Never>?
    /// Seconds of the playing sentence's audio heard before the last resume.
    @ObservationIgnored private var heard: Double = 0
    @ObservationIgnored private var resumedAt: Date?
    @ObservationIgnored private var texts: [UInt32: [String]] = [:]
    @ObservationIgnored private var voices: [String: (any Voice)?] = [:]
    @ObservationIgnored private var fetchingAhead: (section: UInt32, voice: String, task: Task<Void, Never>)?
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private static weak var remoteOwner: Player?
    private static let ahead = 2

    init(core: YuyueCore, detail: BookDetail, script: Script? = nil) {
        self.detail = detail
        self.script = script ?? .book(core, detail, roles: BookRoles(core: core, bookID: detail.summary.id))
        engine.attach(node)
        engine.attach(speed)
        engine.connect(node, to: speed, format: Speech.format)
        engine.connect(speed, to: engine.mainMixerNode, format: Speech.format)
        #if DEBUG
        // `-debugMute 1`: plays without a sound, for trying the player while someone works nearby.
        if UserDefaults.standard.bool(forKey: "debugMute") { node.volume = 0 }
        #endif
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // The output changed (headphones, AirPlay): the engine stopped, so start again where we were.
            MainActor.assumeIsolated { self?.restartHere() }
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let began = type == AVAudioSession.InterruptionType.began.rawValue
            let resume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            MainActor.assumeIsolated {
                if began { self?.pause() } else if resume { self?.resume() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            // Headphones unplugged: stop talking out loud.
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            MainActor.assumeIsolated { self?.pause() }
        })
        #endif
    }

    // MARK: Controls

    /// Starts reading at `position`, or at the first sentence after it with something to read.
    func play(from position: Position) {
        failure = nil
        reset()
        guard let start = first(from: Spot(section: position.section, sentence: Int(position.sentence))) else {
            return stop()
        }
        spot = start
        nextToRender = start
        state = .loading
        claimRemote()
        loadArtwork()
        updateNowPlaying()
        render()
    }

    func pause() {
        guard state == .playing || state == .loading else { return }
        heard = heardNow()
        resumedAt = nil
        node.pause()
        state = .paused
        report()
        updateNowPlaying()
    }

    func resume() {
        guard state == .paused else { return }
        guard !queued.isEmpty else {
            state = .loading
            return render()
        }
        guard startEngine() else { return }
        node.play()
        if started {
            resumedAt = Date()
            state = .playing
            report()
        } else {
            began()
        }
        updateNowPlaying()
    }

    func stop() {
        let wasStopped = state == .stopped
        fetchingAhead?.task.cancel()
        fetchingAhead = nil
        reset()
        state = .stopped
        spot = nil
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        updateNowPlaying()
        if !wasStopped { onStop?() }
    }

    /// The sentence being read or paused on, for the 播放条 under the shelf.
    var line: String? {
        guard let spot else { return nil }
        let all = sentences(spot.section)
        return all.indices.contains(spot.sentence) ? all[spot.sentence] : nil
    }

    /// How far into its section the voice is, 0–1.
    var sectionProgress: Double {
        guard let spot else { return 0 }
        let n = sentences(spot.section).count
        return n > 0 ? Double(spot.sentence + 1) / Double(n) : 0
    }

    /// 双击耳机: the sentence just heard is the one playing, or the one before when this one has
    /// only just begun. With nothing to highlight it in, moves on a sentence instead.
    func markHeard() {
        guard let spot, let onMarkHeard else { return skip(forward: true) }
        onMarkHeard(started && heardNow() < 1 ? before(spot) ?? spot : spot)
    }

    /// Moves on, or back, by one sentence.
    func skip(forward: Bool) {
        guard let spot, let target = forward ? after(spot) : before(spot) else { return }
        let paused = state == .paused
        play(from: target.position)
        if paused { pause() }
    }

    /// Stops reading and lets go of the lock screen. The player can't be used afterwards.
    func close() {
        stop()
        releaseRemote()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    // MARK: The queue

    private func reset() {
        generation += 1
        rendering?.cancel()
        rendering = nil
        node.stop()
        queued = []
        started = false
        nextToRender = nil
        heard = 0
        resumedAt = nil
    }

    /// Renders sentences until enough are queued.
    private func render() {
        guard rendering == nil else { return }
        let generation = generation
        rendering = Task { [weak self] in
            while let self, self.generation == generation, self.queued.count <= Self.ahead, let spot = self.nextToRender {
                let language = self.language(of: spot.section)
                var speech: Speech?
                if self.narrated, let recording = self.recording {
                    speech = await Self.narrate(recording, spot)
                }
                if speech == nil {
                    let role = self.script.roles?.voice(section: spot.section, sentence: spot.sentence, language: language) { self.voice(for: language) }
                    guard let voice = self.script.voice?(spot.section, spot.sentence, language) ?? role ?? self.voice(for: language) else {
                        let name = Locale.current.localizedString(forLanguageCode: language) ?? language
                        self.failed(String(localized: "这台设备还没有\(name)声音。在设置的“辅助功能 › 朗读内容”里可以下载一个。"))
                        return
                    }
                    if let cloud = voice as? CloudVoice { self.fetchAhead(cloud, from: spot, language: language) }
                    do {
                        speech = try await voice.render(self.text(at: spot), language: language)
                    } catch {
                        self.failed(String(localized: "朗读出错了（\(error.localizedDescription)）"))
                        return
                    }
                }
                guard self.generation == generation else { return }
                self.nextToRender = self.after(spot)
                // A sentence with nothing to say (a lone dash, say) is skipped.
                if let speech { self.schedule(Line(spot: spot, speech: speech)) }
            }
            guard let self, self.generation == generation else { return }
            self.rendering = nil
            // The book is over once the last sentence has played.
            if self.queued.isEmpty && self.nextToRender == nil && self.state == .loading { self.stop() }
        }
    }

    /// 整章缓存: a cloud voice fetches the rest of the chapter in the background, so it plays on
    /// offline and without waiting.
    private func fetchAhead(_ voice: CloudVoice, from spot: Spot, language: String) {
        guard fetchingAhead?.section != spot.section || fetchingAhead?.voice != voice.id else { return }
        fetchingAhead?.task.cancel()
        let texts = Array(sentences(spot.section).dropFirst(spot.sentence + 1))
        fetchingAhead = (spot.section, voice.id, Task.detached(priority: .utility) { await voice.prefetch(texts, language: language) })
    }

    @concurrent private static func narrate(_ recording: Recording, _ spot: Spot) async -> Speech? {
        recording.speech(section: spot.section, sentence: spot.sentence)
    }

    /// 试听 a stretch of the recording, without moving the book.
    func preview(from start: Double, to end: Double) {
        guard let recording else { return }
        if state == .playing || state == .loading { pause() }
        Task {
            guard let speech = await Self.clip(recording, start, end) else { return }
            Self.previewing.play(speech)
        }
    }

    @concurrent private static func clip(_ recording: Recording, _ start: Double, _ end: Double) async -> Speech? {
        recording.clip(from: start, to: end)
    }

    private static let previewing = ClipPlayer()

    private func schedule(_ line: Line) {
        let generation = generation
        node.scheduleBuffer(line.speech.buffer, completionCallbackType: .dataPlayedBack,
                            completionHandler: Self.onMain { [weak self] in self?.played(generation) })
        queued.append(line)
        guard queued.count == 1, state == .loading || state == .playing else { return }
        guard startEngine() else { return }
        node.play()
        began()
    }

    private func played(_ generation: Int) {
        guard generation == self.generation, !queued.isEmpty else { return }
        let done = queued[0].spot
        if loop {
            // Throws away what was rendered ahead and starts this sentence again.
            return play(from: done.position)
        }
        let next = queued.count > 1 ? queued[1].spot : nextToRender
        if shouldSleep(after: done, next: next) {
            return fallAsleep(at: next ?? done)
        }
        queued.removeFirst()
        started = false
        if !queued.isEmpty {
            // The node is already playing the next one.
            began()
        } else if nextToRender == nil && rendering == nil {
            // Read to the very end, not stopped by hand or by the timer.
            let finish = onFinish
            stop()
            finish?()
            return
        } else {
            // Rendering fell behind; the next sentence starts as soon as it's ready.
            state = .loading
        }
        render()
    }

    private func shouldSleep(after done: Spot, next: Spot?) -> Bool {
        switch sleep {
        case .off: false
        case .sentence: true
        case .chapter: next == nil || next?.section != done.section
        case .until(let date, _): Date() >= date
        }
    }

    /// Stops between sentences for the sleep timer, paused where it would have gone on.
    private func fallAsleep(at spot: Spot) {
        reset()
        sleep = .off
        self.spot = spot
        nextToRender = spot
        state = .paused
        updateNowPlaying()
        onSleep?(spot)
    }

    private func began() {
        guard let line = queued.first else { return }
        let newSection = spot?.section != line.spot.section
        spot = line.spot
        started = true
        heard = 0
        resumedAt = Date()
        state = .playing
        report()
        if newSection { updateNowPlaying() }
    }

    private func failed(_ message: String) {
        stop()
        failure = message
    }

    private func heardNow() -> Double {
        heard + (resumedAt.map { Date().timeIntervalSince($0) * Double(rate) } ?? 0)
    }

    private func report() {
        guard started, let line = queued.first else { return }
        let rate = Double(rate)
        onSentence?(line.spot, line.speech.seconds / rate * 1000, heardNow() / rate * 1000, state == .playing)
    }

    private func rateChanged(from old: Float) {
        // What was heard so far was heard at the old speed.
        if let resumedAt {
            heard += Date().timeIntervalSince(resumedAt) * Double(old)
            self.resumedAt = Date()
        }
        speed.rate = rate
        report()
        updateNowPlaying()
    }

    /// 分角色: someone's voice, pace or pitch changed; read on from this sentence with it.
    func rolesChanged() {
        script.roles?.reload()
        restartHere()
    }

    private func restartHere() {
        guard let spot, state != .stopped else { return }
        let paused = state == .paused
        play(from: spot.position)
        if paused { pause() }
    }

    private func startEngine() -> Bool {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            failed(String(localized: "没法播放声音（\(error.localizedDescription)）"))
            return false
        }
        #endif
        if engine.isRunning { return true }
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            failed(String(localized: "没法播放声音（\(error.localizedDescription)）"))
            return false
        }
    }

    // MARK: The book's sentences

    /// The words changed (替换规则): sentences not yet rendered are read anew.
    func textsChanged() {
        texts = [:]
    }

    private func sentences(_ section: UInt32) -> [String] {
        if let cached = texts[section] { return cached }
        let loaded = script.sentences(section)
        texts[section] = loaded
        return loaded
    }

    private func text(at spot: Spot) -> String {
        let all = sentences(spot.section)
        return all.indices.contains(spot.sentence) ? all[spot.sentence] : ""
    }

    private func language(of section: UInt32) -> String {
        script.language(section)
    }

    // MARK: Voices

    private static func voiceKey(_ language: String) -> String { "player.voice." + language }

    /// The language of the section being read, or of the book.
    var language: String {
        spot.map { language(of: $0.section) } ?? detail.summary.language
    }

    /// The voice reading `language` now.
    func currentVoice(for language: String) -> (any Voice)? {
        voice(for: language)
    }

    /// Reads `language` with another voice from now on, starting the sentence again in it.
    func choose(_ voice: any Voice, for language: String) {
        UserDefaults.standard.set(voice.id, forKey: Self.voiceKey(language))
        voices[language] = voice
        restartHere()
    }

    /// 试听: a few words in `voice`, without moving the book.
    func preview(_ voice: any Voice, text: String) {
        if state == .playing || state == .loading { pause() }
        Voices.preview(voice, text: text) { [weak self] in self?.failure = $0 }
    }

    private func voice(for language: String) -> (any Voice)? {
        if let known = voices[language] { return known }
        let chosen = UserDefaults.standard.string(forKey: Self.voiceKey(language)).flatMap(Voices.find)
        let voice: (any Voice)? = chosen ?? SystemVoice.best(for: language)
        voices[language] = voice
        return voice
    }

    /// `spot` itself when it can be read, or the first sentence after it that can.
    private func first(from spot: Spot) -> Spot? {
        spot.sentence < sentences(spot.section).count
            ? Spot(section: spot.section, sentence: max(0, spot.sentence))
            : firstSentence(after: spot.section)
    }

    private func after(_ spot: Spot) -> Spot? {
        spot.sentence + 1 < sentences(spot.section).count
            ? Spot(section: spot.section, sentence: spot.sentence + 1)
            : firstSentence(after: spot.section)
    }

    private func before(_ spot: Spot) -> Spot? {
        if spot.sentence > 0 { return Spot(section: spot.section, sentence: spot.sentence - 1) }
        var section = spot.section
        while let previous = script.previous(section) {
            let count = sentences(previous).count
            if count > 0 { return Spot(section: previous, sentence: count - 1) }
            section = previous
        }
        return nil
    }

    private func firstSentence(after section: UInt32) -> Spot? {
        var section = section
        while let next = script.next(section) {
            if !sentences(next).isEmpty { return Spot(section: next, sentence: 0) }
            section = next
        }
        return nil
    }

    // MARK: Lock screen

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard state != .stopped, let spot else {
            center.nowPlayingInfo = nil
            #if os(macOS)
            center.playbackState = .stopped
            #endif
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: script.title(spot.section) ?? detail.summary.title,
            MPMediaItemPropertyAlbumTitle: detail.summary.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let author = detail.summary.authors.first { info[MPMediaItemPropertyArtist] = author }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = state == .paused ? .paused : .playing
        #endif
    }

    private func loadArtwork() {
        guard artwork == nil, let cover = detail.summary.coverPath else { return }
        Task { [weak self] in
            guard let image = await Thumbnail.load(cover, maxPixels: 600) else { return }
            self?.artwork = Self.artwork(image)
            self?.updateNowPlaying()
        }
    }

    /// Several books can be open on a Mac; the lock screen and media keys go to the one that
    /// last started reading.
    private func claimRemote() {
        guard Self.remoteOwner !== self else { return }
        Self.remoteOwner?.releaseRemote()
        Self.remoteOwner = self
        let center = MPRemoteCommandCenter.shared()
        let handlers: [(MPRemoteCommand, @MainActor @Sendable (Player) -> Void)] = [
            (center.playCommand, { $0.resume() }),
            (center.pauseCommand, { $0.pause() }),
            (center.togglePlayPauseCommand, { $0.state == .playing || $0.state == .loading ? $0.pause() : $0.resume() }),
            (center.nextTrackCommand, { $0.markHeard() }),
            (center.previousTrackCommand, { $0.skip(forward: false) }),
        ]
        for (command, action) in handlers {
            command.isEnabled = true
            let target = command.addTarget(handler: Self.command { [weak self] in
                if let self { action(self) }
            })
            remoteTargets.append((command, target))
        }
        let speeds = center.changePlaybackRateCommand
        speeds.isEnabled = true
        speeds.supportedPlaybackRates = [0.75, 1, 1.25, 1.5, 2, 3]
        remoteTargets.append((speeds, speeds.addTarget(handler: Self.rateCommand { [weak self] in self?.rate = $0 })))
    }

    private func releaseRemote() {
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets = []
        if Self.remoteOwner === self { Self.remoteOwner = nil }
    }

    // AVFoundation and MediaPlayer call back on their own threads. These build the callbacks
    // outside the main actor, so they can run there, and hop to the main actor for the work.

    nonisolated private static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { _ in Task { @MainActor in work() } }
    }

    nonisolated private static func command(_ work: @escaping @MainActor @Sendable () -> Void) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { _ in
            Task { @MainActor in work() }
            return .success
        }
    }

    nonisolated private static func rateCommand(_ work: @escaping @MainActor @Sendable (Float) -> Void) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            guard let rate = (event as? MPChangePlaybackRateCommandEvent)?.playbackRate else { return .commandFailed }
            Task { @MainActor in work(rate) }
            return .success
        }
    }

    nonisolated private static func artwork(_ cgImage: CGImage) -> MPMediaItemArtwork {
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        #if os(iOS)
        let image = UIImage(cgImage: cgImage)
        #else
        let image = NSImage(cgImage: cgImage, size: size)
        #endif
        return MPMediaItemArtwork(boundsSize: size) { _ in image }
    }
}

/// Plays a clip on its own, for 试听.
final class ClipPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: Speech.format)
    }

    func play(_ speech: Speech) {
        node.stop()
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
        node.scheduleBuffer(speech.buffer, completionHandler: nil)
        node.play()
    }

    func stop() { node.stop() }
}
