import AVFoundation
import Foundation
import Observation
import UserNotifications
import YuyueCore
#if canImport(UIKit)
import UIKit
#endif

/// 有声书 (prototypes 17, 18): a recording of a book laid against the e-book on the shelf, so it
/// can be listened to in the narrator's voice with the ink line following along.
///
/// The recording is kept on this device beside the library, in `audiobooks/<id>/`: its files,
/// `info.json`, what the transcriber heard of each file (so a stopped job picks up where it was),
/// and `timings.json`, where each sentence is in the recording.
struct Audiobook: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var author: String?
    /// The recording's files, in order, and how long each is in seconds.
    var files: [String]
    var seconds: [Double]
    /// The e-book it's laid against.
    var book: String?
    /// When it was made, and how long that took in seconds.
    var made: Date?
    var took: Double?
    /// 片头 looked at and skipped.
    var introSkipped = false

    var total: Double { seconds.reduce(0, +) }

    /// `6 小时 12 分`, `38 分钟`.
    static func length(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        return m >= 60 ? String(localized: "\(m / 60) 小时\(m % 60 > 0 ? String(localized: " \(m % 60) 分") : "")") : String(localized: "\(max(1, m)) 分钟")
    }
}

/// Where each sentence of the book is in the recording, from `alignRecording`, plus any 微调.
nonisolated struct Timings: Codable, Equatable, Sendable {
    struct Sentence: Codable, Equatable {
        var section: UInt32
        var sentence: UInt32
        /// Seconds from the start of the whole recording; negative when it isn't there.
        var start: Double
        var end: Double
        var heard: Float
        /// Moved by hand.
        var adjusted = false
    }

    struct Section: Codable, Equatable, Sendable {
        var section: UInt32
        var sentences: UInt32
        var heard: Float
        var missing: UInt32
        var unsure: UInt32
    }

    var sentences: [Sentence]
    var sections: [Section]
    var intro: Double
    /// Up to where the recording has been heard, in seconds; the whole of it once made.
    var through: Double

    init(_ a: Alignment, through: Double) {
        sentences = a.sentences.map { Sentence(section: $0.section, sentence: $0.sentence, start: $0.start, end: $0.end, heard: $0.heard) }
        sections = a.sections.map { Section(section: $0.section, sentences: $0.sentences, heard: $0.heard, missing: $0.missing, unsure: $0.unsure) }
        intro = a.intro
        self.through = through
        // A sentence ends by the time the next one starts.
        var next: Double?
        for i in sentences.indices.reversed() where sentences[i].start >= 0 {
            if let n = next, sentences[i].end > n, n > sentences[i].start { sentences[i].end = n }
            next = sentences[i].start
        }
    }

    func index(_ section: UInt32, _ sentence: Int) -> Int? {
        sentences.firstIndex { $0.section == section && $0.sentence == UInt32(sentence) }
    }

    /// Whether the sentence was heard well enough to trust where it is.
    static func unsure(_ s: Sentence) -> Bool { s.start >= 0 && s.heard < 0.5 && !s.adjusted }
}

/// Reads a sentence's stretch of the recording as audio the player can play. Off the main actor:
/// the player asks for the next sentences while one plays.
nonisolated final class Recording: @unchecked Sendable {
    private let dir: URL
    private let files: [String]
    private let starts: [Double]
    private let lock = NSLock()
    private var timings: Timings
    private var open: [Int: AVAudioFile] = [:]

    init(dir: URL, audiobook: Audiobook, timings: Timings) {
        self.dir = dir
        files = audiobook.files
        var at = 0.0
        starts = audiobook.seconds.map { s in defer { at += s }; return at }
        self.timings = timings
    }

    func update(_ timings: Timings) {
        lock.withLock { self.timings = timings }
    }

    /// The sentence in the narrator's voice, or nil when the recording doesn't have it.
    func speech(section: UInt32, sentence: Int) -> Speech? {
        let t: Timings.Sentence? = lock.withLock {
            timings.index(section, sentence).map { timings.sentences[$0] }
        }
        guard let t, t.start >= 0, t.end > t.start else { return nil }
        return clip(from: t.start, to: t.end)
    }

    /// Seconds of the recording from this sentence to the end of its chapter, for 本章还剩.
    func secondsLeft(section: UInt32, sentence: Int) -> Double? {
        lock.withLock {
            let here = timings.sentences.filter { $0.section == section && $0.start >= 0 }
            guard let end = here.last?.end, let from = here.first(where: { $0.sentence >= UInt32(sentence) })?.start else { return nil }
            return max(0, end - from)
        }
    }

    /// Any stretch of the recording, for 试听.
    func clip(from start: Double, to end: Double) -> Speech? {
        lock.lock()
        defer { lock.unlock() }
        guard let i = starts.lastIndex(where: { $0 <= start }), let file = file(i) else { return nil }
        let rate = file.processingFormat.sampleRate
        let from = AVAudioFramePosition((start - starts[i]) * rate)
        let count = AVAudioFrameCount(max(0, min((end - start) * rate, Double(file.length - from))))
        guard count > 0, from < file.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return nil }
        file.framePosition = max(0, from)
        do { try file.read(into: buffer, frameCount: count) } catch { return nil }
        return Speech.make(from: [buffer])
    }

    /// Loudness around a moment, for the 微调 waveform: `bars` values 0–1 from `start` to `end`.
    func levels(from start: Double, to end: Double, bars: Int) -> [Float] {
        guard let speech = clip(from: max(0, start), to: end), let data = speech.buffer.floatChannelData?[0] else { return [] }
        let n = Int(speech.buffer.frameLength)
        let per = max(1, n / bars)
        var out: [Float] = []
        for b in 0 ..< bars {
            let lo = b * per, hi = min(n, lo + per)
            guard lo < hi else { out.append(0); continue }
            var peak: Float = 0
            for k in stride(from: lo, to: hi, by: 8) { peak = max(peak, abs(data[k])) }
            out.append(peak)
        }
        let top = max(out.max() ?? 1, 0.01)
        return out.map { $0 / top }
    }

    private func file(_ i: Int) -> AVAudioFile? {
        if let f = open[i] { return f }
        guard files.indices.contains(i), let f = try? AVAudioFile(forReading: dir.appending(path: files[i])) else { return nil }
        open[i] = f
        return f
    }
}

@Observable
final class Audiobooks {
    /// The one the app uses; set when the library opens.
    static var shared: Audiobooks?

    private(set) var all: [Audiobook] = []
    /// The one being made, while it is.
    private(set) var job: Job?
    /// Just imported, waiting to be paired with an e-book.
    var pairing: Audiobook?
    /// The 合成 page to show: the one being made, or how one came out.
    var showing: String?

    @ObservationIgnored private let core: YuyueCore
    @ObservationIgnored let dir: URL
    /// The library's folder, where the alignment model is kept.
    @ObservationIgnored let dataDir: URL
    @ObservationIgnored private var recordings: [String: Recording] = [:]

    nonisolated static let extensions: Set<String> = ["m4b", "m4a", "mp3", "aac", "wav", "aiff", "flac"]
    /// 以后同名的书都这样配.
    static let autoPairKey = "audiobooks.autoPair"

    init(core: YuyueCore, dataDir: URL) {
        self.core = core
        self.dataDir = dataDir
        dir = dataDir.appending(path: "audiobooks", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
        all = ids.compactMap { id in
            (try? Data(contentsOf: folder(id).appending(path: "info.json"))).flatMap { try? JSONDecoder().decode(Audiobook.self, from: $0) }
        }
        .sorted { $0.title < $1.title }
    }

    /// After 同步 brought one in, or changed one's timings.
    func reload() {
        recordings = [:]
        load()
    }

    func folder(_ id: String) -> URL { dir.appending(path: id, directoryHint: .isDirectory) }

    func save(_ a: Audiobook) {
        if let data = try? JSONEncoder().encode(a) { try? data.write(to: folder(a.id).appending(path: "info.json"), options: .atomic) }
        if let i = all.firstIndex(where: { $0.id == a.id }) { all[i] = a } else { all.append(a) }
    }

    /// The recording laid against `book`.
    func audiobook(for book: String) -> Audiobook? {
        all.first { $0.book == book }
    }

    func timings(_ a: Audiobook) -> Timings? {
        (try? Data(contentsOf: folder(a.id).appending(path: "timings.json"))).flatMap { try? JSONDecoder().decode(Timings.self, from: $0) }
    }

    func save(_ t: Timings, for a: Audiobook) {
        if let data = try? JSONEncoder().encode(t) { try? data.write(to: folder(a.id).appending(path: "timings.json"), options: .atomic) }
        recordings[a.id]?.update(t)
        NotificationCenter.default.post(name: Self.timingsChanged, object: a.id)
    }

    /// Posted with the audiobook's id after 微调 saves its timings, for the pages showing them.
    static let timingsChanged = Notification.Name("yuyue.audiobook.timings")

    /// For the player: the narrator's voice for `book`, once some of it has been laid out.
    func recording(for book: String) -> Recording? {
        guard let a = audiobook(for: book) else { return nil }
        if let r = recordings[a.id] { return r }
        guard let t = timings(a) else { return nil }
        let r = Recording(dir: folder(a.id), audiobook: a, timings: t)
        recordings[a.id] = r
        return r
    }

    // MARK: Bringing one in

    /// A recording's files (one book in one or more files) into the library, waiting to be paired.
    func add(_ urls: [URL]) async throws -> Audiobook {
        let files = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let first = files.first else { throw CocoaError(.fileNoSuchFile) }
        let id = UUID().uuidString.lowercased()
        let folder = folder(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var names: [String] = []
        var seconds: [Double] = []
        do {
            for (i, url) in files.enumerated() {
                let name = String(format: "%03d.", i) + url.pathExtension.lowercased()
                try FileManager.default.copyItem(at: url, to: folder.appending(path: name))
                guard let f = try? AVAudioFile(forReading: folder.appending(path: name)), f.length > 0 else {
                    throw AudiobookError.unreadable(url.lastPathComponent)
                }
                names.append(name)
                seconds.append(Double(f.length) / f.processingFormat.sampleRate)
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        let (title, author) = await Self.metadata(first, folderName: urls.count > 1 ? first.deletingLastPathComponent().lastPathComponent : nil)
        let a = Audiobook(id: id, title: title, author: author, files: names, seconds: seconds)
        save(a)
        if let cover = await Self.cover(first) { try? cover.write(to: folder.appending(path: "cover.jpg")) }
        return a
    }

    /// An 有声书 on the shelf, to lay against its e-book: its files linked in (the same disk, so
    /// no second copy), under the shelf book's id.
    func add(shelf book: BookSummary) throws -> Audiobook {
        if let a = all.first(where: { $0.id == book.id }) { return a }
        let r = try core.audioRecording(bookId: book.id)
        let folder = folder(book.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var names: [String] = []
        for f in r.files {
            let source = URL(filePath: f.path)
            let name = source.lastPathComponent
            let target = folder.appending(path: name)
            if !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                do { try FileManager.default.linkItem(at: source, to: target) } catch { try FileManager.default.copyItem(at: source, to: target) }
            }
            names.append(name)
        }
        if let cover = book.coverPath { try? FileManager.default.copyItem(at: URL(filePath: cover), to: folder.appending(path: "cover.jpg")) }
        let a = Audiobook(id: book.id, title: book.title, author: book.authors.first, files: names, seconds: r.files.map(\.seconds))
        save(a)
        return a
    }

    func coverURL(_ a: Audiobook) -> URL? {
        let url = folder(a.id).appending(path: "cover.jpg")
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    func remove(_ a: Audiobook) {
        if job?.audiobook == a.id { job?.cancel() }
        try? FileManager.default.removeItem(at: folder(a.id))
        recordings[a.id] = nil
        all.removeAll { $0.id == a.id }
    }

    /// The e-book on the shelf that is the same book: same title once the extras are taken off
    /// (有声书, 播讲, brackets), and the same author when both say one.
    func match(_ a: Audiobook, in books: [BookSummary]) -> BookSummary? {
        let want = Self.plain(a.title)
        if let id = (UserDefaults.standard.dictionary(forKey: Self.pairsKey) as? [String: String])?[want],
           let book = books.first(where: { $0.id == id && $0.available }) {
            return book
        }
        let candidates = books.filter { $0.available && $0.format != .pdf && $0.format != .audio }
        let same = candidates.filter { Self.plain($0.title) == want }
        let near = same.isEmpty ? candidates.filter { want.count >= 2 && (Self.plain($0.title).contains(want) || want.contains(Self.plain($0.title))) && Self.plain($0.title).count >= 2 } : same
        guard !near.isEmpty else { return nil }
        if let author = a.author.map(Self.plain), !author.isEmpty,
           let both = near.first(where: { $0.authors.contains { author.contains(Self.plain($0)) || Self.plain($0).contains(author) } }) {
            return both
        }
        return near.first
    }

    static func plain(_ s: String) -> String {
        var t = s.lowercased()
        for pattern in [#"[（(【\[《].*?[)）】\]》]"#, #"有声(书|小说|版)?"#, #"(全集|完整版|精品|播讲|朗读|演播)"#, #"^\d+[\s._-]*"#] {
            t = t.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return t.filter { $0.isLetter || $0.isNumber }
    }

    nonisolated private static func metadata(_ url: URL, folderName: String?) async -> (String, String?) {
        let asset = AVURLAsset(url: url)
        let items = (try? await asset.load(.commonMetadata)) ?? []
        func value(_ key: AVMetadataKey) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: items, withKey: key, keySpace: .common).first else { return nil }
            return try? await item.load(.stringValue)
        }
        let album = await value(.commonKeyAlbumName)
        let title = await value(.commonKeyTitle)
        var author = await value(.commonKeyArtist)
        if author == nil { author = await value(.commonKeyCreator) }
        if author == nil { author = await value(.commonKeyAuthor) }
        // A book in several files names each file a chapter; the album or folder is the book.
        let name = folderName.map { _ in album } ?? title ?? album
        let fallback = folderName ?? url.deletingPathExtension().lastPathComponent
        return ((name?.isEmpty == false ? name : nil) ?? fallback, author)
    }

    nonisolated private static func cover(_ url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        let items = (try? await asset.load(.commonMetadata)) ?? []
        guard let item = AVMetadataItem.metadataItems(from: items, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common).first else { return nil }
        return try? await item.load(.dataValue)
    }

    // MARK: Making it

    /// Lays the recording against `book` on this device (强制对齐): a file at a time through the
    /// alignment model, the sentences laid out again after each, so chapters can be listened to
    /// as they come.
    func make(_ a: Audiobook, with book: BookSummary) {
        var a = a
        a.book = book.id
        a.made = nil
        // Another recording of the same book gives way.
        for other in all where other.book == book.id && other.id != a.id { remove(other) }
        save(a)
        pairing = nil
        showing = a.id
        let job = Job(audiobook: a.id, total: a.total, sections: (try? core.book(id: book.id).sections.filter { $0.sentences > 0 }.count) ?? 0)
        self.job = job
        job.task = Task { [weak self] in
            await self?.run(job, a, book)
        }
    }

    private func run(_ job: Job, _ a: Audiobook, _ book: BookSummary) async {
        let started = Date()
        #if os(iOS)
        // A little longer when the app is left; past that it waits until it's back.
        let background = BackgroundTime()
        defer { background.end() }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        Self.askToNotify()
        do {
            // The alignment model, fetched the first time (about 270 MB).
            if !Aligner.installed(dataDir) {
                job.step = .reading
                try await Aligner.ensure(dataDir) { f in Task { @MainActor in job.downloaded = f } }
                job.downloaded = nil
            }
            try Task.checkCancellation()
            // 找出每集念的是哪一段, then 逐句对齐: each file through the model (kept, so a stopped
            // job picks up where it was), the whole book laid out again after each.
            job.step = .transcribing
            var files: [Emissions] = []
            var offset = 0.0
            for (i, name) in a.files.enumerated() {
                let cache = folder(a.id).appending(path: "emissions-\(i).f32")
                let em: Emissions
                if let data = try? Data(contentsOf: cache), data.count % (4 * Aligner.letters) == 0, !data.isEmpty {
                    let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                    em = Emissions(values: values, frames: UInt32(values.count / Aligner.letters), seconds: a.seconds[i])
                } else {
                    let base = offset
                    let out = try await Aligner.emissions(dataDir, file: folder(a.id).appending(path: name)) { done in
                        Task { @MainActor in job.heard = base + done }
                    }
                    try Task.checkCancellation()
                    out.em.withUnsafeBufferPointer { try? Data(buffer: $0).write(to: cache, options: .atomic) }
                    em = Emissions(values: out.em, frames: UInt32(out.frames), seconds: out.seconds)
                }
                files.append(em)
                offset += a.seconds[i]
                job.heard = offset
                job.transcribed = Date().timeIntervalSince(started)
                job.step = .aligning
                layOut(a, files, through: offset, job: job)
            }
            job.step = .checking
            layOut(a, files, through: a.total, job: job)
            var done = a
            done.made = .now
            done.took = Date().timeIntervalSince(started)
            save(done)
            job.step = .done
            self.job = nil
            Self.notify(String(localized: "《\(book.title)》的有声书合成好了"), Timings.summary(timings(done)))
        } catch is CancellationError {
        } catch {
            job.problem = Library.isOutOfSpace(error) ? String(localized: "存储空间不够：对齐用的模型要约 800 MB 空间才装得下")
                : (error as? AudiobookError)?.message ?? (Library.offline(error) != nil ? String(localized: "对齐用的模型没下载下来，连上网再试一次")
                : String(localized: "合成没做完（\(error.localizedDescription)）"))
        }
    }

    private func layOut(_ a: Audiobook, _ files: [Emissions], through: Double, job: Job) {
        guard let book = a.book, let alignment = try? core.alignRecordingFiles(bookId: book, files: files) else { return }
        var t = Timings(alignment, through: through)
        // Moves made by hand stay.
        if let old = timings(a) {
            for s in old.sentences where s.adjusted {
                if let i = t.index(s.section, Int(s.sentence)) { t.sentences[i] = s }
            }
        }
        save(t, for: a)
        job.timings = t
    }

    func cancel() {
        job?.cancel()
        job = nil
    }

    /// The sheet put away. A recording not paired stays: it's on the shelf as an 有声书 of its own.
    func dismiss() {
        pairing = nil
        showing = nil
        stopListening()
    }

    /// 换一本电子书: remembered, so the next recording of the same name goes to the same book.
    func remember(_ a: Audiobook, _ book: BookSummary) {
        var pairs = UserDefaults.standard.dictionary(forKey: Self.pairsKey) as? [String: String] ?? [:]
        pairs[Self.plain(a.title)] = book.id
        UserDefaults.standard.set(pairs, forKey: Self.pairsKey)
    }

    private static let pairsKey = "audiobooks.pairs"

    /// 以后同名的书都这样配, once it's been seen on the 配对 sheet.
    static var autoPair: Bool { UserDefaults.standard.object(forKey: autoPairKey) as? Bool == true }

    /// 片头 looked at: it's left out when listening anyway, so it only stops being asked about.
    func skipIntro(_ a: Audiobook) {
        var a = a
        a.introSkipped = true
        save(a)
    }

    // MARK: 试听

    @ObservationIgnored private lazy var clips = ClipPlayer()

    /// A stretch of the recording on its own, for 试听 on the result and 微调 pages.
    func listen(_ a: Audiobook, from start: Double, to end: Double) {
        guard let book = a.book, let r = recording(for: book) else { return }
        Task {
            guard let speech = await Self.clip(r, max(0, start), end) else { return }
            clips.play(speech)
        }
    }

    func stopListening() { clips.stop() }

    @concurrent private static func clip(_ r: Recording, _ start: Double, _ end: Double) async -> Speech? {
        r.clip(from: start, to: end)
    }

    @concurrent static func levels(_ r: Recording, _ start: Double, _ end: Double, bars: Int) async -> [Float] {
        r.levels(from: start, to: end, bars: bars)
    }

    private static func askToNotify() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// 合成中: the four steps, how far, and each chapter as it's laid out.
@Observable
final class Job {
    enum Step: Int { case reading, transcribing, aligning, checking, done }

    let audiobook: String
    let total: Double
    let sections: Int
    var step = Step.reading
    /// Seconds of the recording heard so far.
    var heard = 0.0
    /// How long running the model took, once it's done.
    var transcribed: Double?
    /// 0–1 while the alignment model is being fetched.
    var downloaded: Double?
    var timings: Timings?
    var problem: String?
    let started = Date()
    @ObservationIgnored var task: Task<Void, Never>?

    init(audiobook: String, total: Double, sections: Int) {
        self.audiobook = audiobook
        self.total = total
        self.sections = sections
    }

    var fraction: Double { total > 0 ? min(1, heard / total) : 0 }

    /// Seconds left, from how fast it's gone so far.
    var left: Double? {
        let spent = Date().timeIntervalSince(started)
        guard fraction > 0.02, spent > 5 else { return nil }
        return spent / fraction * (1 - fraction)
    }

    func cancel() { task?.cancel() }
}

enum AudiobookError: Error {
    case unreadable(String)
    case language(String)
    case model

    var message: String {
        switch self {
        case .unreadable(let name): String(localized: "“\(name)”读不出声音，换一个 M4B、MP3 或 M4A 文件试试")
        case .language(let l): String(localized: "这台设备还不能转写这种语言（\(l)）")
        case .model: String(localized: "对齐用的模型没下载完整，连上网再试一次")
        }
    }
}

extension Timings {
    /// `21 章对得很好，3 处要你看一下`.
    static func summary(_ t: Timings?) -> String {
        guard let t else { return "" }
        let issues = Issue.all(in: t, introSkipped: false).count
        let good = t.sections.count - t.troubled.count
        return issues == 0 ? String(localized: "\(good) 章都对好了") : String(localized: "\(good) 章对得很好，\(issues) 处要你看一下")
    }
}

extension Timings {
    /// The chapters with sentences missing or not trusted — after any 微调, not as first laid out.
    var troubled: Set<UInt32> {
        Set(Issue.all(in: self, introSkipped: true).map(\.section))
    }
}

// MARK: 微调

extension Timings {
    /// The next or previous sentence that's in the recording.
    func neighbour(of at: Int, _ step: Int, sameChapter: Bool = false) -> Int? {
        var j = at + step
        while sentences.indices.contains(j) {
            let s = sentences[j]
            if sameChapter, s.section != sentences[at].section { return nil }
            if s.start >= 0, s.end > s.start { return j }
            j += step
        }
        return nil
    }

    /// Sentence `at` begins at `wanted` (kept after the one before it). With `follow` the rest
    /// of its chapter moves the same way, though not over where the next chapter starts;
    /// without, it stays before its own end. The one before ends where it now begins, when
    /// they met. Returns how far it moved.
    @discardableResult
    mutating func moveStart(_ at: Int, to wanted: Double, follow: Bool) -> Double {
        let s = sentences[at]
        let p = neighbour(of: at, -1, sameChapter: true)
        let low = (p.map { sentences[$0].start } ?? 0) + 0.1
        let start = min(max(wanted, low), follow ? .infinity : s.end - 0.1)
        let delta = start - s.start
        guard abs(delta) > 0.001 else { return 0 }
        sentences[at].start = start
        sentences[at].adjusted = true
        if follow {
            sentences[at].end += delta
            var j = at + 1
            while j < sentences.count, sentences[j].section == s.section {
                if sentences[j].start >= 0 {
                    sentences[j].start += delta
                    sentences[j].end += delta
                    sentences[j].adjusted = true
                }
                j += 1
            }
            if j < sentences.count, sentences[j].start >= 0 {
                var k = j - 1
                while k >= at, sentences[k].start < 0 { k -= 1 }
                if k >= at { sentences[k].end = min(sentences[k].end, max(sentences[k].start + 0.1, sentences[j].start)) }
            }
        }
        if let p, sentences[p].end >= s.start - 0.05 {
            sentences[p].end = max(sentences[p].start + 0.1, start)
        }
        return delta
    }

    /// Sentence `at` ends at `wanted`, after its start and not over the next one's.
    mutating func moveEnd(_ at: Int, to wanted: Double) {
        let s = sentences[at]
        let next = neighbour(of: at, 1, sameChapter: true).map { sentences[$0].start } ?? .infinity
        let end = min(max(wanted, s.start + 0.1), next)
        guard abs(end - s.end) > 0.001 else { return }
        sentences[at].end = end
        sentences[at].adjusted = true
    }

    /// 整段挪: sentences `range` move together by `delta`, between their neighbours.
    mutating func shift(_ range: ClosedRange<Int>, by delta: Double) {
        let inRecording = range.filter { sentences[$0].start >= 0 }
        guard let first = inRecording.first, let last = inRecording.last else { return }
        let p = neighbour(of: first, -1, sameChapter: true)
        let n = neighbour(of: last, 1, sameChapter: true)
        let low = (p.map { sentences[$0].start + 0.1 } ?? 0) - sentences[first].start
        let high = (n.map { sentences[$0].start - 0.1 } ?? .infinity) - sentences[last].start
        let d = min(max(delta, low), high)
        guard abs(d) > 0.001 else { return }
        let firstStart = sentences[first].start
        for i in inRecording {
            sentences[i].start += d
            sentences[i].end += d
            sentences[i].adjusted = true
        }
        if let n { sentences[last].end = min(sentences[last].end, sentences[n].start) }
        if let p, sentences[p].end >= firstStart - 0.05 {
            sentences[p].end = max(sentences[p].start + 0.1, sentences[first].start)
        }
    }

    /// 用朗读补上这段: the recording is left out for these sentences; a voice reads them.
    mutating func readWithVoice(_ range: ClosedRange<Int>) {
        for i in range {
            sentences[i].start = -1
            sentences[i].end = -1
            sentences[i].heard = 0
            sentences[i].adjusted = true
        }
    }
}

/// One thing the result page asks to be looked at.
struct Issue: Identifiable, Equatable {
    enum Kind: Equatable {
        /// 片头: seconds of recording before the book starts.
        case intro(Double)
        /// Sentences the recording doesn't have, read with a system voice instead.
        case missing(count: Int)
        /// Sentences only partly heard.
        case unsure(count: Int)
    }

    let kind: Kind
    let section: UInt32
    /// The first sentence it's about, an index into `Timings.sentences`.
    let at: Int
    /// The last, likewise.
    var last: Int
    var id: String {
        if case .intro = kind { return "intro" }
        return "\(section).\(at)"
    }

    static func all(in t: Timings, introSkipped: Bool) -> [Issue] {
        var out: [Issue] = []
        if t.intro > 15, !introSkipped, let first = t.sentences.indices.first {
            out.append(Issue(kind: .intro(t.intro), section: t.sentences[first].section, at: first, last: first))
        }
        var i = 0
        let s = t.sentences
        let gone = { (x: Timings.Sentence) in x.start < 0 && x.heard < 1 }
        let blank = { (x: Timings.Sentence) in x.start >= 0 && x.start == x.end }
        while i < s.count {
            let missing = gone(s[i])
            guard missing || Timings.unsure(s[i]) else { i += 1; continue }
            var j = i + 1
            while j < s.count, s[j].section == s[i].section, blank(s[j]) || (missing ? gone(s[j]) : Timings.unsure(s[j])) { j += 1 }
            let count = s[i ..< j].count { missing ? gone($0) : Timings.unsure($0) }
            out.append(Issue(kind: missing ? .missing(count: count) : .unsure(count: count), section: s[i].section, at: i, last: j - 1))
            i = j
        }
        return out
    }
}

#if os(iOS)
/// The extra time iOS gives when the app is left mid-合成, ended when it runs out.
private final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid

    init() {
        id = UIApplication.shared.beginBackgroundTask(withName: String(localized: "有声书合成")) { [weak self] in self?.end() }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
