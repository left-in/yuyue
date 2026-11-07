import SwiftUI
import YuyueCore
#if os(macOS)

/// 播客's 播放条: along the bottom of the window. Left, back a 条,
/// play, on a 条; in the middle a card with the episode — its cover, title, which 条 and who's
/// speaking, and a thin bar cut where each 条 starts (hover for its topic, click to go there);
/// right, speed, the sleep timer, 文稿 (the episode's window) and letting it go.
///
/// It plays `library.nowPlaying`: an episode started from the list without a window, or one
/// playing in its window. The voice reads sentence by sentence, so back and on move by 条, not
/// by seconds — the unit a news show is listened in.
struct MacPodcastBar: View {
    let library: Library
    let model: ReaderModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }
    @State private var segments: [EpisodeSegment] = []
    @State private var speakers: [String?] = []
    @State private var hovered: Int?

    private var player: Player? { model.player }
    private var episode: Episode? { library.podcasts.latest.first { $0.book == model.bookID } }
    private var show: Show? { episode.flatMap { e in library.podcasts.shows.first { $0.id == e.show } } }
    private var book: BookSummary? { library.books.first { $0.id == model.bookID } }
    private var sentence: Int { player?.spot?.sentence ?? model.sentence }
    private var playing: Bool { player?.state == .playing || player?.state == .loading }

    /// The 条 the voice is in.
    private var current: Int? {
        segments.lastIndex { Int($0.first) <= sentence } ?? (segments.isEmpty ? nil : 0)
    }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                tool("backward.end.fill", String(localized: "上一条"), size: 12) { go(by: -1) }
                tool(playing ? "pause.fill" : "play.fill", playing ? String(localized: "暂停") : String(localized: "播放"), size: 17) {
                    library.playEpisode(model.bookID)
                }
                tool("forward.end.fill", String(localized: "下一条"), size: 12) { go(by: 1) }
            }
            now
            HStack(spacing: 2) {
                speed
                sleep
                tool("quote.bubble", String(localized: "文稿"), size: 13) { openWindow(id: "reader", value: model.bookID) }
                tool("xmark", String(localized: "不听了"), size: 11) { library.stopEpisode() }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(YYColor.bg)
        .overlay(alignment: .top) { Rectangle().fill(YYColor.line).frame(height: 0.5) }
        .task(id: model.bookID) {
            segments = (try? library.core.episodeSegments(book: model.bookID)) ?? []
            speakers = (try? library.core.sectionSpeakers(bookId: model.bookID, section: 0)) ?? []
        }
    }

    // MARK: 正在播放

    private var now: some View {
        HStack(spacing: 10) {
            ShowCover(name: show?.name ?? book?.authors.first ?? "", size: 32)
            Text(clock(elapsed)).frame(width: 40, alignment: .leading)
            VStack(spacing: 0) {
                Text(episode?.title ?? book?.title ?? "")
                    .font(.yy(size: 12, weight: .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                Text(line).font(.yy(size: 10.5)).foregroundStyle(YYColor.t3).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            Text("−" + clock(max(0, total - elapsed))).frame(width: 44, alignment: .trailing)
        }
        .font(.yy(size: 10.5)).monospacedDigit().foregroundStyle(YYColor.t3)
        .padding(.leading, 5).padding(.trailing, 12)
        // Room under the two lines for the bar, so it never runs through the words.
        .padding(.bottom, 5)
        .frame(height: 48)
        .frame(maxWidth: 560)
        .background(YYColor.card, in: .rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(YYColor.line, lineWidth: 0.5))
        .overlay(alignment: .bottom) { track.padding(.leading, 47 + 50).padding(.trailing, 12 + 54).padding(.bottom, 2) }
        .contentShape(.rect)
        .onTapGesture(count: 2) { openWindow(id: "reader", value: model.bookID) }
        .accessibilityElement(children: .combine)
    }

    /// "科技早报 · 2 / 7 Rust 1.91 · 老周在说"
    private var line: String {
        var parts: [String] = []
        if let name = show?.name { parts.append(name) }
        if let i = hovered ?? current, segments.indices.contains(i) {
            let topic = segments[i].topic
            parts.append(topic.isEmpty ? "\(i + 1) / \(segments.count)" : "\(i + 1) / \(segments.count) \(topic)")
        }
        if hovered == nil, speakers.indices.contains(sentence), let who = speakers[sentence] {
            parts.append(String(localized: "\(who)在说"))
        }
        if hovered == nil, !library.upNext.isEmpty {
            parts.append(String(localized: "后面还有 \(library.upNext.count) 集"))
        }
        return parts.joined(separator: " · ")
    }

    /// The thin bar: one piece a 条, as long as it takes to say; heard in ink, the rest faint.
    private var track: some View {
        GeometryReader { g in
            let units = max(1, segments.reduce(0) { $0 + Int($1.units) })
            let gap: CGFloat = segments.count > 1 ? 2 : 0
            let usable = g.size.width - gap * CGFloat(max(0, segments.count - 1))
            HStack(spacing: gap) {
                if segments.isEmpty {
                    piece(width: g.size.width, filled: fraction, index: nil)
                } else {
                    ForEach(Array(segments.enumerated()), id: \.offset) { i, s in
                        piece(width: max(2, usable * CGFloat(s.units) / CGFloat(units)), filled: filled(i), index: i)
                    }
                }
            }
        }
        .frame(height: 6)
    }

    private func piece(width: CGFloat, filled: Double, index: Int?) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(YYColor.t1.opacity(0.1))
            Capsule().fill(index == current ? tint.accent : YYColor.t1.opacity(0.55)).frame(width: width * filled)
        }
        .frame(width: width, height: hovered == index && index != nil ? 3 : 2)
        .frame(height: 6)
        .contentShape(.rect)
        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
        .onTapGesture { if let index { jump(to: index) } }
        .help(index.flatMap { segments.indices.contains($0) ? segments[$0].topic : nil } ?? "")
    }

    /// How much of 条 `i` has been heard, 0–1.
    private func filled(_ i: Int) -> Double {
        guard let c = current else { return 0 }
        if i < c { return 1 }
        if i > c { return 0 }
        let s = segments[i]
        let n = Double(Int(s.last) - Int(s.first) + 1)
        return min(1, max(0, Double(sentence - Int(s.first)) / max(1, n)))
    }

    /// Of the whole episode, 0–1, by how much there is to say.
    private var fraction: Double {
        guard !segments.isEmpty, let c = current else { return player?.sectionProgress ?? 0 }
        let units = Double(max(1, segments.reduce(0) { $0 + Int($1.units) }))
        let before = segments[..<c].reduce(0) { $0 + Double($1.units) }
        return min(1, (before + Double(segments[c].units) * filled(c)) / units)
    }

    /// Seconds, at this speed.
    private var total: Double {
        Double(max(1, book?.listenMinutes ?? 1)) * 60 / Double(max(0.5, model.rate))
    }

    private var elapsed: Double { total * fraction }

    private func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: Moving

    /// 上一条 goes to the start of this 条 when it's under way, as a track's back button does.
    private func go(by step: Int) {
        guard let c = current else {
            if let player { player.skip(forward: step > 0) }
            return
        }
        var target = c + step
        if step < 0, sentence > Int(segments[c].first) + 1 { target = c }
        // On from the last 条: the next episode, when 连着听 has one.
        if step > 0, target >= segments.count, !library.upNext.isEmpty {
            return library.episodeFinished(model.bookID)
        }
        guard segments.indices.contains(target) else { return }
        jump(to: target)
    }

    private func jump(to i: Int) {
        guard let player else { return }
        let paused = player.state == .paused
        player.play(from: Position(section: 0, sentence: segments[i].first))
        if paused { player.pause() }
    }

    // MARK: Right

    private var speed: some View {
        Menu {
            ForEach([Float(0.8), 1.0, 1.2, 1.5, 2.0], id: \.self) { r in
                Toggle(isOn: Binding(get: { abs(model.rate - r) < 0.01 }, set: { if $0 { model.rate = r } })) {
                    Text(String(format: "%.1f×", r))
                }
            }
        } label: {
            Text(String(format: "%.1f×", model.rate)).font(.yy(size: 11.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(YYColor.t1).frame(minWidth: 34, minHeight: 28)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("倍速")
    }

    private var sleep: some View {
        let on = player.map { $0.sleep != .off } ?? false
        return Menu {
            if let player {
                Button("关") { player.sleep = .off }
                Button("本集结束") { player.sleep = .chapter }
                Divider()
                ForEach([15, 30, 60], id: \.self) { m in
                    Button(String(localized: "\(m) 分钟")) { player.sleep = .until(Date().addingTimeInterval(Double(m) * 60), minutes: m) }
                }
            }
        } label: {
            Image(systemName: on ? "moon.fill" : "moon").font(.system(size: 12.5))
                .foregroundStyle(on ? tint.accent : YYColor.t1).frame(width: 28, height: 28)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("睡眠定时")
    }

    private func tool(_ symbol: String, _ title: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
                .font(.system(size: size, weight: .medium)).foregroundStyle(YYColor.t1)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
#endif
