#if DEBUG
import Foundation

/// Test data made on launch, so a round between two scratch libraries (`-debugLibrary`,
/// `-debugSyncDir`) needs no clicking: the things one device makes for the other to receive.
///
///   -debugAudiobook <audio file> -debugAudiobookBook <part of a shelf book's title>
///       adds the recording and lays it against that book (合成), once.
///   -debugPodcast 1
///       makes the 开源动态 show from its template, if there's no show, and writes an episode.
extension Library {
    func debugSeed() {
        let d = UserDefaults.standard
        if let path = d.string(forKey: "debugAudiobook"), let title = d.string(forKey: "debugAudiobookBook"),
           let book = books.first(where: { $0.title.contains(title) }),
           audiobooks.audiobook(for: book.id) == nil {
            Task {
                do {
                    let a = try await audiobooks.add([URL(filePath: path)])
                    NSLog("debugSeed: audiobook \(a.id) → \(book.title)")
                    audiobooks.make(a, with: book)
                } catch {
                    NSLog("debugSeed: audiobook failed: \(error)")
                }
            }
        }
        // -debugRemoveAudiobooks 1: removes every 有声书 here, as 删除 would.
        if d.bool(forKey: "debugRemoveAudiobooks") {
            for a in audiobooks.all {
                NSLog("debugSeed: removing audiobook \(a.id)")
                audiobooks.remove(a)
            }
        }
        if d.bool(forKey: "debugPodcast"), podcasts.shows.isEmpty, let draft = Podcasts.templates().last {
            do {
                let show = try podcasts.add(draft)
                NSLog("debugSeed: show \(show.id), writing")
                podcasts.write(show)
            } catch {
                NSLog("debugSeed: show failed: \(error)")
            }
        }
    }
}
#endif
