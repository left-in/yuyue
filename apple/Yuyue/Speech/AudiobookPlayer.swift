import AVFoundation
import MediaPlayer
import YuyueCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 有声书 listened to on its own (prototype v0.30 C3–C6): the recording's files one after
/// another, by time. A position is a chapter and the milliseconds into it, saved like any book's,
/// so progress, 书签 and 听了多久 follow the book to other devices.
///
/// Speed doesn't change the pitch; −15 s and +30 s; after a pause of a while it goes back a few
/// seconds; 定时 stops after some minutes or at the end of the chapter. The lock screen, the
/// headphones and the media keys take the same controls.
@Observable
final class AudiobookPlayer {
    let bookID: String
    private(set) var summary: BookSummary
    private(set) var recording: AudioRecording?
    private(set) var isPlaying = false
    /// Seconds from the start of the whole recording.
    private(set) var time: Double = 0
    var failure: String?
    var rate: Float = 1 {
        didSet {
            UserDefaults.standard.set(rate, forKey: Self.rateKey)
            if isPlaying { queue.rate = rate }
            updateNowPlaying()
        }
    }
    var sleep = Sleep.off {
        didSet { armSleep() }
    }
    private(set) var bookmarks: [Bookmark] = []

    enum Sleep: Equatable {
        case off
        /// 本集完
        case chapter
        case until(Date, minutes: Int)
    }

    static let back: Double = 15
    static let ahead: Double = 30

    @ObservationIgnored private let library: Library
    @ObservationIgnored private var core: YuyueCore { library.core }
    @ObservationIgnored private let queue = AVQueuePlayer()
    /// Where each file starts in the whole recording.
    @ObservationIgnored private var starts: [Double] = []
    @ObservationIgnored private var items: [AVPlayerItem] = []
    @ObservationIgnored private var ticker: Any?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var pausedAt: Date?
    @ObservationIgnored private var listenSince: Date?
    @ObservationIgnored private var savedAt = Date.distantPast
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    private static weak var remoteOwner: AudiobookPlayer?
    private static let rateKey = "audiobook.rate"

    init(library: Library, book: BookSummary) {
        self.library = library
        bookID = book.id
        summary = book
        let saved = UserDefaults.standard.float(forKey: Self.rateKey)
        rate = saved > 0 ? saved : 1
        queue.actionAtItemEnd = .advance
        queue.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        do {
            let r = try core.audioRecording(bookId: book.id)
            recording = r
            var at = 0.0
            for f in r.files {
                starts.append(at)
                at += f.seconds
            }
            if let p = try? core.progress(bookId: book.id) ?? core.latestProgress(bookId: book.id) {
                time = seconds(at: p.position)
            }
        } catch {
            failure = Library.message(for: error)
        }
        bookmarks = (try? core.bookmarks(book: book.id)) ?? []
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.finished(item) }
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let began = type == AVAudioSession.InterruptionType.began.rawValue
            let resume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            MainActor.assumeIsolated {
                if began { self?.pause() } else if resume { self?.play() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            // Headphones out: don't go on out loud.
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            MainActor.assumeIsolated { self?.pause() }
        })
        #endif
    }

    // MARK: Where it is

    var total: Double { recording?.seconds ?? 0 }
    var chapters: [AudioChapter] { recording?.chapters ?? [] }

    /// The chapter `time` is in.
    var chapter: Int { chapter(at: time) }

    func chapter(at t: Double) -> Int {
        max(0, (chapters.lastIndex { $0.start <= t + 0.05 }) ?? 0)
    }

    /// `第 3 集`, or the recording's own name for it.
    func title(_ i: Int) -> String {
        chapters.indices.contains(i) ? chapters[i].title ?? String(localized: "第 \(i + 1) 集") : summary.title
    }

    /// Seconds into the chapter being heard, and how long it is.
    var inChapter: (at: Double, of: Double) {
        guard chapters.indices.contains(chapter) else { return (0, 0) }
        let c = chapters[chapter]
        return (time - c.start, c.seconds)
    }

    private func seconds(at p: Position) -> Double {
        guard chapters.indices.contains(Int(p.section)) else { return 0 }
        return min(total, chapters[Int(p.section)].start + Double(p.sentence) / 1000)
    }

    private func position(at t: Double) -> Position {
        let i = chapter(at: t)
        let into = chapters.indices.contains(i) ? t - chapters[i].start : 0
        return Position(section: UInt32(i), sentence: UInt32(max(0, into * 1000).rounded()))
    }

    // MARK: Controls

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let recording, !recording.files.isEmpty, !isPlaying else { return }
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            failure = String(localized: "没法播放声音（\(error.localizedDescription)）")
            return
        }
        #endif
        #if os(iOS)
        // One voice at a time.
        if let held = library.nowPlaying, held !== self { library.nowPlaying = nil; held.stopAndClose() }
        #endif
        // Picked up after a while: a few seconds back, to hear where it was.
        var moved = false
        if let pausedAt {
            let gap = Date().timeIntervalSince(pausedAt)
            let back = gap > 3600 ? 10.0 : gap > 300 ? 5 : gap > 30 ? 2 : 0
            if back > 0 {
                time = max(chapters.indices.contains(chapter) ? chapters[chapter].start : 0, time - back)
                moved = true
            }
        }
        // Heard to the end: from the start again.
        if time >= total - 0.5 {
            time = 0
            moved = true
        }
        pausedAt = nil
        // The queue goes where `time` is: changing `time` alone doesn't move what's heard, and a
        // queue played to its end has nothing left in it.
        if items.isEmpty || moved || queue.currentItem == nil { load(at: time) }
        queue.playImmediately(atRate: rate)
        isPlaying = true
        library.listening = bookID
        listened()
        startTicking()
        claimRemote()
        loadArtwork()
        armSleep()
        updateNowPlaying()
    }

    func pause() {
        guard isPlaying else { return }
        queue.pause()
        isPlaying = false
        pausedAt = Date()
        readTime()
        listened()
        save()
        if library.listening == bookID { library.listening = nil }
        updateNowPlaying()
    }

    func skip(_ by: Double) { seek(to: time + by) }

    func seek(to t: Double) {
        time = min(max(0, t), max(0, total - 0.1))
        pausedAt = nil
        load(at: time)
        if isPlaying { queue.playImmediately(atRate: rate) }
        save(now: !isPlaying)
        updateNowPlaying()
    }

    func go(toChapter i: Int) {
        guard chapters.indices.contains(i) else { return }
        seek(to: chapters[i].start)
        if !isPlaying { play() }
    }

    func close() {
        if isPlaying {
            readTime()
            listened(stopping: true)
        }
        queue.pause()
        isPlaying = false
        save(now: true)
        if library.listening == bookID { library.listening = nil }
        sleepTask?.cancel()
        if let ticker { queue.removeTimeObserver(ticker) }
        ticker = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        releaseRemote()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        queue.removeAllItems()
        items = []
    }

    /// 长按改名: a chapter's own name, or empty to have it called 第 n 集.
    func renameChapter(_ i: Int, _ name: String) {
        do {
            summary = try core.renameAudioChapter(bookId: bookID, chapter: UInt32(i), title: name)
            recording = try core.audioRecording(bookId: bookID)
            updateNowPlaying()
        } catch {
            failure = Library.message(for: error)
        }
    }

    // MARK: 书签

    func addBookmark() {
        let p = position(at: time)
        do {
            _ = try core.addBookmark(book: bookID, section: p.section, sentence: p.sentence)
            bookmarks = (try? core.bookmarks(book: bookID)) ?? bookmarks
        } catch {
            failure = Library.message(for: error)
        }
    }

    func deleteBookmark(_ b: Bookmark) {
        try? core.deleteBookmark(book: bookID, id: b.id)
        bookmarks.removeAll { $0.id == b.id }
    }

    func seconds(of b: Bookmark) -> Double { seconds(at: Position(section: b.section, sentence: b.sentence)) }

    // MARK: Playing the files

    /// The queue from the file `t` falls in, sought to `t`.
    private func load(at t: Double) {
        guard let recording else { return }
        let i = max(0, (starts.lastIndex { $0 <= t }) ?? 0)
        queue.removeAllItems()
        items = recording.files[i...].map { f in
            let item = AVPlayerItem(url: URL(filePath: f.path))
            item.audioTimePitchAlgorithm = .timeDomain
            return item
        }
        for item in items { queue.insert(item, after: nil) }
        let into = t - starts[i]
        if into > 0.05 {
            queue.seek(to: CMTime(seconds: into, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func finished(_ item: AVPlayerItem?) {
        guard let item, item === items.last else { return }
        // The last file heard to its end: the book is done.
        time = total
        isPlaying = false
        pausedAt = nil
        listened()
        save(now: true)
        if library.listening == bookID { library.listening = nil }
        sleep = .off
        updateNowPlaying()
    }

    private func startTicking() {
        guard ticker == nil else { return }
        ticker = queue.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard isPlaying else { return }
        let before = chapter
        readTime()
        if sleep == .chapter, chapter != before {
            // 本集完: stop at the start of the next one.
            seek(to: chapters[chapter].start)
            sleep = .off
            pause()
            return
        }
        if chapter != before { updateNowPlaying() }
        if Date().timeIntervalSince(savedAt) > 10 { save() }
        if let since = listenSince, Date().timeIntervalSince(since) > 60 { listened() }
    }

    /// `time` from the file playing and how far into it.
    private func readTime() {
        guard let item = queue.currentItem, let i = items.firstIndex(where: { $0 === item }) else { return }
        let offset = starts.count - items.count
        let at = CMTimeGetSeconds(item.currentTime())
        guard at.isFinite else { return }
        time = min(total, starts[offset + i] + max(0, at))
    }

    // MARK: Progress and time listened

    private func save(now: Bool = false) {
        guard recording != nil else { return }
        savedAt = Date()
        do {
            try core.saveProgress(bookId: bookID, position: position(at: time))
        } catch {
            failure = Library.message(for: error)
        }
        if now { library.reload() }
    }

    private func listened(stopping: Bool = false) {
        let now = Date()
        if let since = listenSince {
            let seconds = now.timeIntervalSince(since)
            if seconds > 0, seconds < 600 {
                try? core.addTime(book: bookID, section: UInt32(chapter), readSeconds: 0, listenSeconds: UInt32(seconds.rounded()), day: Notes.today)
            }
        }
        listenSince = isPlaying && !stopping ? now : nil
    }

    // MARK: 定时

    private func armSleep() {
        sleepTask?.cancel()
        guard case .until(let date, _) = sleep, isPlaying else { return }
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.pause()
            self?.sleep = .off
        }
    }

    // MARK: Lock screen

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard Self.remoteOwner === self else { return }
        let (at, of) = inChapter
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title(chapter),
            MPMediaItemPropertyAlbumTitle: summary.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPMediaItemPropertyPlaybackDuration: of,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: at,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyChapterNumber: chapter,
            MPNowPlayingInfoPropertyChapterCount: chapters.count,
        ]
        if let author = summary.authors.first { info[MPMediaItemPropertyArtist] = author }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = isPlaying ? .playing : .paused
        #endif
    }

    private func loadArtwork() {
        guard artwork == nil, let cover = summary.coverPath else { return }
        Task { [weak self] in
            guard let image = await Thumbnail.load(cover, maxPixels: 600) else { return }
            self?.artwork = Self.artwork(image)
            self?.updateNowPlaying()
        }
    }

    /// The lock screen and media keys go to the one that last started playing.
    private func claimRemote() {
        guard Self.remoteOwner !== self else { return }
        Self.remoteOwner?.releaseRemote()
        Self.remoteOwner = self
        let center = MPRemoteCommandCenter.shared()
        let handlers: [(MPRemoteCommand, @MainActor @Sendable (AudiobookPlayer) -> Void)] = [
            (center.playCommand, { $0.play() }),
            (center.pauseCommand, { $0.pause() }),
            (center.togglePlayPauseCommand, { $0.togglePlay() }),
            (center.skipBackwardCommand, { $0.skip(-Self.back) }),
            (center.skipForwardCommand, { $0.skip(Self.ahead) }),
            // Headphones and cars send 上一曲 / 下一曲; for a recording that's 15 and 30 seconds.
            (center.previousTrackCommand, { $0.skip(-Self.back) }),
            (center.nextTrackCommand, { $0.skip(Self.ahead) }),
        ]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.back)]
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.ahead)]
        for (command, action) in handlers {
            command.isEnabled = true
            let target = command.addTarget(handler: Self.command { [weak self] in
                if let self { action(self) }
            })
            remoteTargets.append((command, target))
        }
        let position = center.changePlaybackPositionCommand
        position.isEnabled = true
        remoteTargets.append((position, position.addTarget(handler: Self.positionCommand { [weak self] t in
            guard let self, self.chapters.indices.contains(self.chapter) else { return }
            self.seek(to: self.chapters[self.chapter].start + t)
        })))
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

    // MediaPlayer calls back on its own threads; these hop to the main actor for the work.

    nonisolated private static func command(_ work: @escaping @MainActor @Sendable () -> Void) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { _ in
            Task { @MainActor in work() }
            return .success
        }
    }

    nonisolated private static func positionCommand(_ work: @escaping @MainActor @Sendable (Double) -> Void) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            guard let t = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in work(t) }
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

    /// `14:22`, `1:02:05`.
    static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
