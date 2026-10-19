import Foundation

/// 监听一个文件夹: books put in it are taken in the next time 语阅 comes to the front. Each
/// file is taken once — by name, size and date — so one deleted from the shelf stays deleted.
@Observable
final class WatchedFolder {
    /// The folder's name, while there is one.
    private(set) var name: String?
    private var scanning = false
    private static let bookmarkKey = "watch.bookmark"
    private static let nameKey = "watch.name"
    private static let seenKey = "watch.seen"

    init() {
        name = UserDefaults.standard.string(forKey: Self.nameKey)
    }

    /// Starts watching the folder, and takes in what is there already.
    func choose(_ url: URL, into library: Library) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        let data = try url.bookmarkData(options: .withSecurityScope)
        #else
        let data = try url.bookmarkData()
        #endif
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: Self.nameKey)
        UserDefaults.standard.removeObject(forKey: Self.seenKey)
        name = url.lastPathComponent
        await scan(into: library)
    }

    func stop() {
        for key in [Self.bookmarkKey, Self.nameKey, Self.seenKey] { UserDefaults.standard.removeObject(forKey: key) }
        name = nil
    }

    /// Takes in the books put in the folder since last time.
    func scan(into library: Library) async {
        guard !scanning, let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        scanning = true
        defer { scanning = false }
        var stale = false
        #if os(macOS)
        let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        #else
        let resolved = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
        #endif
        guard let folder = resolved else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        if stale, let fresh = try? folder.bookmarkData() { UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey) }

        var seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [])
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let found = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var fresh: [URL] = []
        while let url = found?.nextObject() as? URL {
            guard RemoteFormats.extensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let key = "\(url.lastPathComponent)|\(values.fileSize ?? 0)|\(Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0))"
            guard seen.insert(key).inserted else { continue }
            fresh.append(url)
        }
        UserDefaults.standard.set(Array(seen), forKey: Self.seenKey)
        guard !fresh.isEmpty else { return }
        await library.importFiles(fresh, from: folder.lastPathComponent)
    }
}
