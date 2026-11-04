#if DEBUG
import Foundation
import YuyueCore

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
        // -debugEpisodes 1: two shows and a few written episodes, no model needed — for looking
        // at 播客's screens in a scratch library.
        if d.bool(forKey: "debugEpisodes"), podcasts.shows.isEmpty {
            seedEpisodes()
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
extension Library {
    private func seedEpisodes() {
        let drafts = Podcasts.templates()
        guard let tech = try? podcasts.add(drafts[0]), let oss = try? podcasts.add(drafts[1]) else { return }
        let a = [
            ScriptArticle(title: "Show HN: A tiny SQLite-backed queue", url: "https://news.ycombinator.com/item?id=1", source: "Hacker News"),
            ScriptArticle(title: "Rust 1.91 发布：更快的增量编译", url: "https://blog.rust-lang.org/2026/10/30/Rust-1.91.0.html", source: "Rust Blog"),
            ScriptArticle(title: "我的 macOS 效率工具 2026 版", url: "https://sspai.com/post/1", source: "少数派"),
        ]
        func seg(_ topic: String, _ refs: [UInt32], _ lines: [(String, String)]) -> ScriptSegment {
            ScriptSegment(topic: topic, articles: refs, lines: lines.map { ScriptLine(who: $0.0, text: $0.1) })
        }
        let duo = EpisodeScript(title: "一个文件就是一条队列，Rust 编译又快了", summary: "SQLite 做消息队列靠不靠谱；Rust 1.91 的增量编译；少数派作者的效率工具清单。", articles: a, segments: [
            seg("SQLite 当队列", [0], [("小林", "今天第一条挺有意思，有人用一个 SQLite 文件做了个消息队列。"),
                                     ("老周", "听着像玩具，其实小项目里很够用。一个文件，备份就是复制。"),
                                     ("小林", "评论区也吵起来了，有人说并发一上来就不行。"),
                                     ("老周", "对，写锁是整库的。每秒几百条以内，它比 Redis 还省心。")]),
            seg("Rust 1.91", [1], [("老周", "第二条，Rust 1.91 发布了，增量编译又快了一截。"),
                                   ("小林", "快多少？我每天等编译的时间够泡三杯茶。"),
                                   ("老周", "官方说大项目改一行，重新编译平均少了两成。")]),
            seg("效率工具", [2], [("小林", "最后是少数派的一篇效率工具清单，我挑两个说。"),
                                ("老周", "你先说，我听听有没有我还没装的。")]),
        ])
        let solo = EpisodeScript(title: "rust 1.91.0 发布", summary: "这一版的三处变化，和升级前要注意的一件事。", articles: [a[1]], segments: [
            seg("1.91.0", [0], [("老周", "rust 发布了 1.91.0。"), ("老周", "这一版主要有三处变化。"), ("老周", "第一，增量编译更快。")]),
        ])
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        func day(_ ago: Int) -> String { f.string(from: cal.date(byAdding: .day, value: -ago, to: .now)!) }
        for ago in [0, 1, 2, 5] {
            _ = try? core.saveEpisode(show: tech.id, date: day(ago), script: duo)
        }
        _ = try? core.saveEpisode(show: oss.id, date: day(1), script: solo)
        podcasts.reload()
        if let old = podcasts.episodes(of: tech.id).last { try? core.setEpisodeHeard(book: old.book, heard: true) }
        podcasts.reload()
        reload()
        NSLog("debugSeed: episodes made")
    }
}
#endif
