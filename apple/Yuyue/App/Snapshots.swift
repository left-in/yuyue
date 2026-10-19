import Foundation
import UniformTypeIdentifiers
import YuyueCore

/// 数据快照: making one, the ones made before, and bringing one back. The files live where the
/// person can see them: on iPhone in 文件 › 语阅, on Mac in the app's 文稿 folder.
@Observable
final class Snapshots {
    struct Saved: Identifiable {
        let url: URL
        let about: SnapshotAbout
        var id: URL { url }
    }

    let library: Library
    private(set) var counts: SnapshotCounts?
    private(set) var saved: [Saved] = []
    private(set) var making = false
    var parts = SnapshotParts(progress: true, notes: true, words: true, settings: true, files: false)
    var problem: String?

    init(library: Library) {
        self.library = library
    }

    nonisolated static let fileExtension = "yuyue"

    var folder: URL {
        #if DEBUG
        // A scratch library keeps its snapshots to itself.
        if UserDefaults.standard.string(forKey: "debugLibrary") != nil {
            return library.dataDir.appending(path: "snapshots", directoryHint: .isDirectory)
        }
        #endif
        return URL.documentsDirectory
    }

    func load() async {
        let core = library.core
        let folder = folder
        let (counts, saved) = await Task.detached {
            let counts = try? core.snapshotCounts()
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let saved = files.filter { $0.pathExtension == Self.fileExtension }
                .compactMap { url in (try? core.peekSnapshot(path: url.path(percentEncoded: false))).map { Saved(url: url, about: $0) } }
                .sorted { $0.about.madeAt > $1.about.madeAt }
            return (counts, saved)
        }.value
        self.counts = counts
        self.saved = saved
    }

    /// What a snapshot of the chosen parts comes to, roughly: the registers compress well.
    var estimate: Int64 {
        guard let counts else { return 0 }
        let data = Int64(Double(counts.dataBytes) * 0.15)
        return data + (parts.files ? Int64(counts.fileBytes) : 0)
    }

    func make() async {
        making = true
        problem = nil
        defer { making = false }
        let url = folder.appending(path: Self.name(Date()))
        let core = library.core
        let parts = parts
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = try await Task.detached { try core.makeSnapshot(path: url.path(percentEncoded: false), parts: parts) }.value
            await load()
        } catch {
            problem = Library.message(for: error)
        }
    }

    func delete(_ s: Saved) {
        try? FileManager.default.removeItem(at: s.url)
        saved.removeAll { $0.url == s.url }
    }

    /// Reads one picked from 文件 or dropped in, copying it out of where it was first.
    func preview(_ picked: URL) throws -> (URL, SnapshotInfo) {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let local: URL
        if picked.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
            local = picked
        } else {
            local = FileManager.default.temporaryDirectory.appending(path: picked.lastPathComponent)
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.copyItem(at: picked, to: local)
        }
        return (local, try library.core.readSnapshot(path: local.path(percentEncoded: false)))
    }

    /// 合并 or 覆盖. Before 覆盖 the library as it is goes into a snapshot of its own, so a
    /// wrong choice can be taken back.
    func restore(_ url: URL, replace: Bool) async throws {
        let core = library.core
        if replace {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let backup = folder.appending(path: Self.name(Date(), note: String(localized: "覆盖前")))
            let all = SnapshotParts(progress: true, notes: true, words: true, settings: true, files: false)
            _ = try await Task.detached { try core.makeSnapshot(path: backup.path(percentEncoded: false), parts: all) }.value
        }
        _ = try await Task.detached { try core.restoreSnapshot(path: url.path(percentEncoded: false), replace: replace) }.value
        library.reload()
        NotificationCenter.default.post(name: .notesChanged, object: nil)
        NotificationCenter.default.post(name: .vocabChanged, object: nil)
        await load()
    }

    static func name(_ date: Date, note: String? = nil) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return String(localized: "语阅快照-\(note.map { "\($0)-" } ?? "")\(f.string(from: date)).\(fileExtension)")
    }

    // MARK: Words for the pages

    /// `10 月 2 日 21:40`, with the year when it isn't this one.
    static func when(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let year = c.year == cal.component(.year, from: Date()) ? "" : String(localized: "\(c.year ?? 0) 年 ")
        return String(localized: "\(year)\(c.month ?? 0) 月 \(c.day ?? 0) 日 ") + String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// `10 月 2 日`, for a row's value.
    static func day(_ ms: Int64) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: Date(timeIntervalSince1970: Double(ms) / 1000))
        return String(localized: "\(c.month ?? 0) 月 \(c.day ?? 0) 日")
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func number(_ n: UInt32) -> String {
        n.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    /// `这台 iPhone` for this device's own, the device's name otherwise.
    static func from(_ about: SnapshotAbout) -> String { from(about.deviceName) }

    static func from(_ device: String) -> String {
        device == Library.deviceName ? String(localized: "这台 \(Library.platformWord)") : device
    }

    /// What 合并 or 覆盖 would do to the counts that change, in a line.
    static func change(_ info: SnapshotInfo, replace: Bool) -> String {
        let after = replace ? info.replaced : info.merged
        if after == info.now, !replace { return String(localized: "这份快照里的，这台设备上都已经有了") }
        var parts: [String] = []
        if info.parts.notes { parts.append(String(localized: "笔记 \(number(info.now.notes)) → \(number(after.notes)) 条")) }
        if info.parts.words { parts.append(String(localized: "生词 \(number(info.now.words)) → \(number(after.words)) 个")) }
        if parts.isEmpty || after.books != info.now.books { parts.insert(String(localized: "书 \(number(info.now.books)) → \(number(after.books)) 本"), at: 0) }
        return (replace ? String(localized: "覆盖后：") : String(localized: "合并后：")) + parts.joined(separator: "，")
    }
}

extension UTType {
    /// A 语阅 snapshot: `.yuyue`, a zip inside.
    static let yuyueSnapshot = UTType(exportedAs: "app.yuyue.snapshot", conformingTo: .data)
}
