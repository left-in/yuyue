import AVFoundation
import Foundation
import YuyueCore

/// 有声书 onto the shelf (prototype v0.30 C1): reads what the system's player can tell of the
/// files (how long each is, the chapter marks of an M4B, title, author, cover) and hands it to
/// the core, which copies the files in and keeps the order.
enum AudioImporter {
    /// One recording: an M4B, a folder of files, or loose files taken together.
    @concurrent static func read(_ core: YuyueCore, files urls: [URL], folderName: String?) async throws -> AudioImport {
        let paths = core.sortAudioFiles(paths: urls.map { $0.path(percentEncoded: false) })
        let ordered = paths.map { URL(filePath: $0) }
        guard let first = ordered.first else { throw CocoaError(.fileNoSuchFile) }
        var files: [AudioFile] = []
        var marks: [AudioMark] = []
        var at = 0.0
        for url in ordered {
            let asset = AVURLAsset(url: url)
            let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            guard seconds.isFinite, seconds > 0 else { throw AudiobookError.unreadable(url.lastPathComponent) }
            files.append(AudioFile(path: url.path(percentEncoded: false), seconds: seconds))
            var own = await chapterMarks(asset).map { AudioMark(title: $0.title, start: $0.start) }
            // Nero's list (`chpl`) the system's player doesn't read; the core does.
            if own.count < 2 { own = core.audioChapterMarks(path: url.path(percentEncoded: false)) }
            marks += own.map { AudioMark(title: $0.title, start: at + $0.start) }
            at += seconds
        }
        // One mark says no more than the files do.
        if marks.count < 2 { marks = [] }
        let (title, author) = await metadata(first, folderName: folderName)
        return AudioImport(files: files, title: title, authors: author.map { [$0] } ?? [], marks: marks, cover: await cover(first))
    }

    private static func chapterMarks(_ asset: AVURLAsset) async -> [(title: String?, start: Double)] {
        let languages = (try? await asset.load(.availableChapterLocales)) ?? []
        guard let groups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: languages.map(\.identifier) + Locale.preferredLanguages) else { return [] }
        var out: [(String?, Double)] = []
        for g in groups {
            let item = AVMetadataItem.metadataItems(from: g.items, withKey: AVMetadataKey.commonKeyTitle, keySpace: .common).first
            let title = try? await item?.load(.stringValue)
            out.append((title, CMTimeGetSeconds(g.timeRange.start)))
        }
        return out
    }

    private static func metadata(_ url: URL, folderName: String?) async -> (String, String?) {
        let items = (try? await AVURLAsset(url: url).load(.commonMetadata)) ?? []
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

    private static func cover(_ url: URL) async -> Data? {
        let items = (try? await AVURLAsset(url: url).load(.commonMetadata)) ?? []
        guard let item = AVMetadataItem.metadataItems(from: items, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common).first else { return nil }
        return try? await item.load(.dataValue)
    }
}
