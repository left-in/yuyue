import SwiftUI
import YuyueCore
#if os(macOS)

/// 单集 (docs/design/播客.html · Mac · 单集): at a desk, what one wants to know is "what are they
/// on now, and what does the article say". Left, the 节目单: every 条 with the time it starts,
/// heard ones in ink, the one playing in the theme's colour; click one to listen from there.
/// Right, one 条 in full: its topic, the articles (看原文 opens each), what the hosts say in it
/// with the sentence being read picked out, and what comes next.
struct MacEpisodePage: View {
    let library: Library
    let episode: Episode
    @Environment(\.openWindow) private var openWindow
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }
    @State private var segments: [EpisodeSegment] = []
    @State private var sentences: [String] = []
    @State private var speakers: [String?] = []
    /// The 条 looked at while nothing of this episode plays.
    @State private var picked: Int?

    private var book: BookSummary? { library.books.first { $0.id == episode.book } }
    private var model: ReaderModel? { (library.nowPlaying as? ReaderModel).flatMap { $0.bookID == episode.book ? $0 : nil } }
    private var playing: Bool { model?.isPlaying ?? false }
    /// The sentence the voice is on, or where it was left.
    private var sentence: Int {
        if let s = model?.player?.spot?.sentence { return s }
        return Int((try? library.core.progress(bookId: episode.book))?.position.sentence ?? 0)
    }
    private var current: Int? { segments.lastIndex { Int($0.first) <= sentence } }
    /// The 条 on the right: the one playing, else the one clicked, else where it was left.
    private var shown: Int? { model?.player?.spot != nil ? current : picked ?? current ?? (segments.isEmpty ? nil : 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            top
            HStack(alignment: .top, spacing: 14) {
                rundown.frame(width: 250)
                detail
            }
        }
        .padding(.leading, 22).padding(.trailing, 28).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: episode.book) {
            segments = (try? library.core.episodeSegments(book: episode.book)) ?? []
            sentences = (try? library.core.sentences(bookId: episode.book, section: 0)) ?? []
            speakers = (try? library.core.sectionSpeakers(bookId: episode.book, section: 0)) ?? []
        }
    }

    // MARK: Top

    private var top: some View {
        HStack(alignment: .center, spacing: 14) {
            ShowCover(name: book?.authors.first ?? "", size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(meta).font(.yy(size: 11)).foregroundStyle(YYColor.t3).monospacedDigit()
                Text(episode.title).font(.yy(size: 18, weight: .bold)).foregroundStyle(YYColor.t1).lineLimit(2)
                if !episode.summary.isEmpty {
                    Text(episode.summary).font(.yy(size: 12)).foregroundStyle(YYColor.t2).lineLimit(2)
                }
            }
            Spacer(minLength: 16)
            PodcastGlassButton(title: playTitle, symbol: playing ? "pause.fill" : "play.fill", kind: playing ? .playing : .plain) {
                library.playEpisode(episode.book)
            }
            PodcastGlassButton(title: String(localized: "文稿"), symbol: "quote.bubble") {
                openWindow(id: "reader", value: episode.book)
            }
        }
    }

    /// "科技早报 · 今天 · 12 分钟 · 7 条"
    private var meta: String {
        var parts = [book?.authors.first ?? "", episode.day]
        if let m = book?.listenMinutes, m > 0 { parts.append(String(localized: "\(Int(m)) 分钟")) }
        if !segments.isEmpty { parts.append(String(localized: "\(segments.count) 条")) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var playTitle: String {
        if playing { return String(localized: "暂停") }
        if episode.heard { return String(localized: "再听一遍") }
        if sentence > 0, let c = current { return String(localized: "接着听 · 第 \(c + 1) 条") }
        return String(localized: "播放")
    }

    // MARK: 节目单

    private var rundown: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "节目单 · 点一条从那里听")).font(.yy(size: 11)).foregroundStyle(YYColor.t3)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { i, s in
                        rundownRow(i, s)
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(YYColor.card, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(YYColor.line, lineWidth: 0.5))
    }

    private func rundownRow(_ i: Int, _ s: EpisodeSegment) -> some View {
        let now = i == current && model?.player?.spot != nil
        let heard = current.map { i < $0 } ?? false || episode.heard
        let on = i == shown
        return Button {
            picked = i
            play(from: i)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // A thin line down the left: heard in ink, playing in the theme's colour.
                Capsule().fill(now ? tint.accent : heard ? YYColor.t1.opacity(0.5) : YYColor.t1.opacity(0.1))
                    .frame(width: 2.5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(clock(start(of: i))).font(.yy(size: 10.5)).monospacedDigit()
                        .foregroundStyle(now ? tint.accent : YYColor.t3)
                    Text(s.topic.isEmpty ? String(localized: "第 \(i + 1) 条") : s.topic)
                        .font(.yy(size: 12.5, weight: now || on ? .semibold : .regular))
                        .foregroundStyle(now ? tint.accent : heard ? YYColor.t2 : YYColor.t1)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if let a = s.articles.first, episode.articles.indices.contains(Int(a)) {
                        Text(episode.articles[Int(a)].source).font(.yy(size: 10.5)).foregroundStyle(YYColor.t3).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7).padding(.horizontal, 8)
            .background(on ? YYColor.t1.opacity(0.05) : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: This 条

    @ViewBuilder private var detail: some View {
        if let i = shown, segments.indices.contains(i) {
            let s = segments[i]
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 6) {
                        Text(String(localized: "第 \(i + 1) 条")).foregroundStyle(tint.accent).fontWeight(.semibold)
                        Text(i == current && playing ? String(localized: "正在讲") : clock(start(of: i)))
                    }
                    .font(.yy(size: 11)).foregroundStyle(YYColor.t3).monospacedDigit()
                    Text(s.topic.isEmpty ? String(localized: "第 \(i + 1) 条") : s.topic)
                        .font(.yy(size: 17, weight: .bold)).foregroundStyle(YYColor.t1)
                    ForEach(s.articles.filter { episode.articles.indices.contains(Int($0)) }, id: \.self) { a in
                        articleCard(episode.articles[Int(a)])
                    }
                    lines(of: s)
                    if segments.indices.contains(i + 1) {
                        let n = segments[i + 1]
                        Button { picked = i + 1; play(from: i + 1) } label: {
                            HStack(spacing: 6) {
                                Text(String(localized: "下一条 · \(clock(start(of: i + 1)))")).foregroundStyle(YYColor.t3)
                                Text(n.topic).foregroundStyle(YYColor.t1).fontWeight(.medium)
                            }
                            .font(.yy(size: 11.5)).monospacedDigit()
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(YYColor.card, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(YYColor.line, lineWidth: 0.5))
        } else {
            Color.clear
        }
    }

    /// The article a 条 tells: where it's from, its title, 看原文.
    private func articleCard(_ a: ScriptArticle) -> some View {
        HStack(spacing: 10) {
            SourceMarks.mark(a.source)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title).font(.yy(size: 12.5, weight: .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                Text([a.source, URL(string: a.url)?.host() ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.yy(size: 10.5)).foregroundStyle(YYColor.t3).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let url = URL(string: a.url) {
                PodcastGlassButton(title: String(localized: "看原文"), symbol: "arrow.up.right", flat: true) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(YYColor.inset.opacity(0.6), in: .rect(cornerRadius: 10))
    }

    /// What the hosts say in this 条: who, then the words; the sentence being read in ink and
    /// bold, the rest grey. Click a line to listen from it.
    private func lines(of s: EpisodeSegment) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Int(s.first) ... Int(max(s.first, s.last)), id: \.self) { k in
                if sentences.indices.contains(k), let who = speakers.indices.contains(k) ? speakers[k] : nil {
                    let now = k == sentence && model?.player?.spot != nil
                    Button {
                        playSentence(k)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(who).font(.yy(size: 11, weight: .semibold))
                                .foregroundStyle(now ? tint.accent : YYColor.t3)
                                .frame(width: 44, alignment: .leading)
                            Text(sentences[k]).font(.yy(size: 13, weight: now ? .semibold : .regular))
                                .foregroundStyle(now ? YYColor.t1 : YYColor.t2)
                                .lineSpacing(3).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 2)
    }

    // MARK: Time and moving

    /// Seconds into the episode where 条 `i` starts, by how much comes before it.
    private func start(of i: Int) -> Double {
        let total = Double(max(1, book?.listenMinutes ?? 1)) * 60 / Double(max(0.5, model?.rate ?? 1))
        let units = Double(max(1, segments.reduce(0) { $0 + Int($1.units) }))
        let before = segments.prefix(i).reduce(0) { $0 + Double($1.units) }
        return total * before / units
    }

    private func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func play(from i: Int) {
        guard segments.indices.contains(i) else { return }
        playSentence(Int(segments[i].first))
    }

    /// Plays from sentence `k`, starting the episode in the 播放条 if it isn't there yet.
    private func playSentence(_ k: Int) {
        if model == nil { library.playEpisode(episode.book) }
        model?.player?.play(from: Position(section: 0, sentence: UInt32(k)))
    }
}
#endif
