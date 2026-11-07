import SwiftUI
import YuyueCore
#if os(macOS)

/// 播客 on the Mac (docs/design/播客.html · Mac · 最新): the shows' covers along the top, then
/// every episode, the newest first. An episode opens in a reader window, the script as a chat,
/// each host in their own voice. 配一档节目 makes a show; 编辑部 shows one being written.
struct MacPodcastView: View {
    @Bindable var library: Library
    @Environment(\.shelfHeaderInset) private var headerInset
    @Environment(\.openWindow) private var openWindow
    @State private var making: ShowDraftEdit?
    /// 编辑部 for this show, over the list.
    @State private var desk: String?
    /// 节目页: a cover clicked.
    @State private var showPage: String?
    /// 单集: an episode clicked.
    @State private var opened: String?
    /// Each episode's 条, for “停在第 2 条 · Rust 1.91”.
    @State private var segments: [String: [EpisodeSegment]] = [:]
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }
    private var podcasts: Podcasts { library.podcasts }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: 56)
                .padding(.top, 8)
                .padding(.leading, 22)
                .padding(.trailing, 28)
            if let id = desk, let show = podcasts.shows.first(where: { $0.id == id }) {
                MacEditorDesk(library: library, show: show) { desk = nil }
            } else if let b = opened, let e = podcasts.latest.first(where: { $0.book == b }) {
                MacEpisodePage(library: library, episode: e)
            } else if let id = showPage, let show = podcasts.shows.first(where: { $0.id == id }) {
                MacShowPage(library: library, show: show,
                            openDesk: { desk = show.id },
                            edit: { making = ShowDraftEdit(id: show.id, draft: show.draft) },
                            row: { AnyView(row($0)) })
            } else if podcasts.shows.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        // Found out now, not at 7:00 when the episode can't be written.
                        if podcasts.scheduledHere, !CompanionConfig.current.isReady {
                            Label("节目到点要写，但还没选写稿用的模型。设置 › 书伴 里选一个服务商", systemImage: "exclamationmark.circle")
                                .font(.yy(size: 12)).foregroundStyle(YYColor.danger)
                                .padding(.top, 8)
                        }
                        covers
                        latest
                    }
                    .padding(.leading, 22).padding(.trailing, 28).padding(.bottom, 28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let m = library.nowPlaying as? ReaderModel, m.detail?.summary.format == .podcast {
                MacPodcastBar(library: library, model: m)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(YYMotion.quick, value: library.nowPlaying?.bookID)
        // As 笔记 and 生词本: the title on the line of 显示侧栏 and the window's buttons.
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $making) { edit in
            MacShowEditor(library: library, edit: edit) { making = nil }
        }
        .onAppear {
            podcasts.reload()
            #if DEBUG
            switch UserDefaults.standard.string(forKey: "debugPodcast") {
            case "desk": desk = podcasts.shows.first?.id
            // `writing`: 编辑部 with a run under way, on its second 条; nothing is really written.
            case "writing":
                if let s = podcasts.shows.first(where: { !$0.sources.isEmpty }) {
                    podcasts.debugShowWriting(s.id)
                    desk = s.id
                }
            case "show": showPage = podcasts.shows.first?.id
            case "episode": opened = podcasts.latest.first?.book
            // `play`: the newest episode in the 播放条, as its play button would.
            case "play": if let e = podcasts.latest.first { library.playEpisode(e.book) }
            // `radio`: 连着听, every episode not heard.
            case "radio": library.playUnheard()
            case "make": making = ShowDraftEdit(id: nil, draft: Podcasts.templates()[0])
            // `write`: makes 科技早报 if there's no show, and writes an episode now.
            case "write":
                if podcasts.shows.isEmpty { _ = try? podcasts.add(Podcasts.templates()[0]) }
                if let s = podcasts.shows.first {
                    podcasts.write(s)
                    desk = s.id
                }
            default: break
            }
            #endif
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if desk != nil || opened != nil || showPage != nil {
                    // Back one step: 编辑部 → 单集 or 节目 → 播客.
                    SquareBackButton(help: backTitle) { back() }
                        .keyboardShortcut("[", modifiers: .command)
                        // On the title's middle, without making the line taller than 播客's.
                        .padding(.vertical, -6)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 7 }
                }
                Text(pageTitle)
                    .font(.yy(size: 22, weight: .bold)).foregroundStyle(YYColor.t1).lineLimit(1)
            }
            .padding(.leading, headerInset)
            if let id = desk, let show = podcasts.shows.first(where: { $0.id == id }) {
                Text(podcasts.writing[id].map { "\(show.name) · \($0.line)" } ?? show.name)
                    .font(.yy(size: 12)).foregroundStyle(YYColor.t2).lineLimit(1)
            }
            Spacer()
            if desk == nil, opened == nil, showPage == nil {
                PodcastGlassButton(title: String(localized: "配一档节目"), symbol: "plus", flat: true) { making = ShowDraftEdit(id: nil, draft: Podcasts.templates()[0]) }
            } else {
                // Holds the line to 播客's height, so the title stays where it was going in.
                PodcastGlassButton(title: " ") {}.hidden()
            }
        }
    }

    private var pageTitle: String {
        if desk != nil { return String(localized: "编辑部") }
        if opened != nil { return String(localized: "单集") }
        if let id = showPage, let show = podcasts.shows.first(where: { $0.id == id }) { return show.name }
        return String(localized: "播客")
    }

    private var backTitle: String {
        if desk != nil, showPage != nil { return String(localized: "回到节目") }
        if opened != nil, showPage != nil { return String(localized: "回到节目") }
        return String(localized: "回到播客")
    }

    private func back() {
        if desk != nil { desk = nil } else if opened != nil { opened = nil } else { showPage = nil }
    }

    // MARK: 节目

    private var covers: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 18) {
                radioCover
                ForEach(podcasts.shows, id: \.id) { show in
                    let fresh = podcasts.episodes(of: show.id).count { !$0.heard }
                    VStack(alignment: .leading, spacing: 6) {
                        ShowCover(name: show.name, size: 92)
                            .overlay(alignment: .topTrailing) {
                                if fresh > 0 {
                                    Text("\(fresh)").font(.yy(size: 10, weight: .bold)).foregroundStyle(.white)
                                        .frame(minWidth: 18, minHeight: 18).background(YYTint.standard.accent, in: .circle)
                                        .overlay(Circle().strokeBorder(YYColor.card, lineWidth: 2)).offset(x: 6, y: -6)
                                }
                            }
                        Text(show.name).font(.yy(size: 12, weight: .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                        Text(subtitle(show)).font(.yy(size: 11)).foregroundStyle(YYColor.t3).lineLimit(1)
                    }
                    .frame(width: 92, alignment: .leading)
                    .contentShape(.rect)
                    .contextMenu {
                        Button("打开节目") { showPage = show.id }
                        Button("现在写一集") { podcasts.write(show); desk = show.id }
                        Button("编辑部") { desk = show.id }
                        Button("改设置…") { making = ShowDraftEdit(id: show.id, draft: show.draft) }
                        Divider()
                        Button("删除这档节目", role: .destructive) { podcasts.remove(show.id) }
                    }
                    .onTapGesture { showPage = show.id }
                    // One thing to VoiceOver: the show, how many not heard, and opening it.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(fresh > 0 ? "\(show.name)，\(subtitle(show))，\(fresh) 集没听" : "\(show.name)，\(subtitle(show))")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { showPage = show.id }
                }
            }
            .padding(.top, 8)
        }
    }

    /// 连着听, the radio way: every episode not heard, one after another. First among the shows,
    /// laid out as a cover is: its name at the top, what it does at the bottom.
    @ViewBuilder private var radioCover: some View {
        let unheard = podcasts.latest.filter { !$0.heard }
        if !unheard.isEmpty {
            let running = !library.upNext.isEmpty
            let books = running ? library.upNext : unheard.map(\.book)
            let minutes = books.reduce(0) { n, id in n + Int(library.books.first { $0.id == id }?.listenMinutes ?? 0) }
            let line = running ? String(localized: "后面还有 \(library.upNext.count) 集") : String(localized: "\(unheard.count) 集没听")
            let length = String(localized: "约 \(max(1, minutes)) 分钟")
            Button { library.playUnheard() } label: {
                VStack(alignment: .leading, spacing: 6) {
                    RadioCover(running: running, size: 92)
                    Text(line).font(.yy(size: 12, weight: .semibold)).foregroundStyle(YYColor.t1).lineLimit(1).monospacedDigit()
                    Text(length).font(.yy(size: 11)).foregroundStyle(YYColor.t3).lineLimit(1).monospacedDigit()
                }
                .frame(width: 92, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("没听的几集一集接一集放完，老的在前")
            .accessibilityLabel(String(localized: "连着听，\(line)，\(length)"))
        }
    }

    private func subtitle(_ show: Show) -> String {
        if let p = podcasts.writing[show.id] { return p.short }
        if podcasts.failure[show.id] != nil { return String(localized: "没写成") }
        return show.scheduleLine
    }

    // MARK: 最新

    private var latest: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最新").font(.yy(size: 14, weight: .semibold)).foregroundStyle(YYColor.t1)
            NoteCard {
                ForEach(podcasts.shows.filter { podcasts.writing[$0.id] != nil || podcasts.failure[$0.id] != nil }, id: \.id) { show in
                    writingRow(show)
                }
                ForEach(podcasts.latest, id: \.book) { e in
                    row(e)
                }
                .task(id: podcasts.latest.map(\.book)) {
                    var out: [String: [EpisodeSegment]] = [:]
                    for e in podcasts.latest { out[e.book] = segments[e.book] ?? (try? library.core.episodeSegments(book: e.book)) ?? [] }
                    segments = out
                }
                if podcasts.latest.isEmpty && podcasts.writing.isEmpty && podcasts.failure.isEmpty {
                    Text("还没有一集。点节目封面，再点“现在写一集”")
                        .font(.yy(size: 12)).foregroundStyle(YYColor.t3).padding(.vertical, 22)
                }
            }
        }
    }

    private func row(_ e: Episode) -> some View {
        let show = podcasts.shows.first { $0.id == e.show }
        let book = library.books.first { $0.id == e.book }
        let playing = library.nowPlaying?.bookID == e.book && library.listening == e.book
        let stop = e.heard ? nil : stoppedAt(e)
        return HStack(spacing: 14) {
            ShowCover(name: show?.name ?? "", size: 48)
                .opacity(e.heard ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(show?.name ?? "") · \(e.day)").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
                Text(e.title).font(.yy(size: 13, weight: .bold)).foregroundStyle(e.heard ? YYColor.t3 : YYColor.t1).lineLimit(1)
                if let stop {
                    // Half heard: which 条 it stopped in says more than minutes do.
                    Text(stop).font(.yy(size: 11.5, weight: .medium)).foregroundStyle(tint.accent).lineLimit(1)
                } else if !e.summary.isEmpty {
                    Text(e.summary).font(.yy(size: 11.5)).foregroundStyle(e.heard ? YYColor.t3 : YYColor.t2).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            SourceMarks(articles: e.articles).opacity(e.heard ? 0.5 : 1)
            EpisodeTicksButton(state: tickState(e, book, playing: playing), count: segments[e.book]?.count ?? 0,
                               done: heardSegments(e, playing: playing)) {
                // Plays in the 播放条; 文稿 (double-click, the menu, the bar) opens the window.
                // Picking one by hand ends 连着听.
                library.upNext = []
                library.playEpisode(e.book)
            }
        }
        .padding(.vertical, 12)
        // The one playing: a wash of the theme's colour under the whole row.
        .padding(.horizontal, 10)
        .background(playing ? tint.accentSoft.opacity(0.7) : .clear, in: .rect(cornerRadius: 10))
        .padding(.horizontal, -10)
        .contentShape(.rect)
        // Once: the episode's page here. Twice: its 文稿 in a window, as before.
        .gesture(TapGesture(count: 2).onEnded { openWindow(id: "reader", value: e.book) }
            .exclusively(before: TapGesture().onEnded { opened = e.book }))
        .contextMenu {
            Button("打开单集") { opened = e.book }
            Button("打开文稿") { openWindow(id: "reader", value: e.book) }
            Button(e.heard ? "标为没听" : "标为听完") {
                try? library.core.setEpisodeHeard(book: e.book, heard: !e.heard)
                podcasts.reload()
            }
            if let book {
                Divider()
                Button("删除这一集", role: .destructive) { library.delete(book) }
            }
        }
    }

    /// "停在第 2 条 · Rust 1.91", for an episode listened into and left.
    private func stoppedAt(_ e: Episode) -> String? {
        guard let segs = segments[e.book], segs.count > 1,
              let at = (try? library.core.progress(bookId: e.book))?.position, at.sentence > 0,
              let i = segs.lastIndex(where: { $0.first <= at.sentence }) else { return nil }
        let topic = segs[i].topic
        return topic.isEmpty ? String(localized: "停在第 \(i + 1) 条") : String(localized: "停在第 \(i + 1) 条 · \(topic)")
    }

    /// 一条一道: what the words under the pointer say.
    private func tickState(_ e: Episode, _ book: BookSummary?, playing: Bool) -> EpisodeTicksButton.State {
        let total = max(1, Int(book?.listenMinutes ?? 1))
        let left = max(1, Int((1 - (book?.progress ?? 0)) * Double(total)))
        if playing { return .playing(minutesLeft: left) }
        if e.heard { return .heard }
        if (book?.progress ?? 0) > 0.01 { return .partway(minutesLeft: left) }
        return .fresh(minutes: total)
    }

    /// The 条 before the one being told (or where it was left): the marks in ink.
    private func heardSegments(_ e: Episode, playing: Bool) -> Int {
        guard let segs = segments[e.book], !segs.isEmpty else { return 0 }
        let sentence: Int
        if playing, let s = (library.nowPlaying as? ReaderModel)?.player?.spot?.sentence {
            sentence = s
        } else if let p = (try? library.core.progress(bookId: e.book))?.position {
            sentence = Int(p.sentence)
        } else {
            return 0
        }
        if sentence == 0, !playing { return 0 }
        return segs.lastIndex(where: { Int($0.first) <= sentence }) ?? 0
    }

    private func remaining(_ e: Episode, _ book: BookSummary?) -> String {
        guard let book else { return String(localized: "听") }
        if library.nowPlaying?.bookID == e.book, library.listening == e.book { return String(localized: "正在听") }
        if e.heard { return String(localized: "听完了") }
        let total = max(1, Int(book.listenMinutes))
        if book.progress > 0.01 {
            return String(localized: "还剩 \(max(1, Int((1 - book.progress) * Double(total)))) 分")
        }
        return String(localized: "\(total) 分钟")
    }

    private func writingRow(_ show: Show) -> some View {
        HStack(spacing: 14) {
            ShowCover(name: show.name, size: 48).opacity(0.85)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(show.name) · \(String(localized: "今天"))").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
                Text(podcasts.writing[show.id]?.line ?? String(localized: "没写成")).font(.yy(size: 13, weight: .bold)).foregroundStyle(YYColor.t1)
                if let why = podcasts.failure[show.id] {
                    Text(why).font(.yy(size: 11.5)).foregroundStyle(YYColor.danger).lineLimit(2)
                } else if let p = podcasts.writing[show.id], !p.picked.isEmpty {
                    Text(p.picked.prefix(3).joined(separator: "、")).font(.yy(size: 11.5)).foregroundStyle(YYColor.t2).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Button(String(localized: "看它怎么挑的 ›")) { desk = show.id }
                .buttonStyle(.plain).font(.yy(size: 11)).foregroundStyle(YYColor.t3)
            if podcasts.failure[show.id] != nil {
                let at = podcasts.failedAt[show.id]
                EpisodeTicksButton(state: .failed, count: at?.total ?? 0, done: at?.done ?? 0) { podcasts.write(show) }
            } else {
                let p = podcasts.writing[show.id]
                // Marks once the 条 are picked: one lights as each is written.
                let total = max(p?.total ?? 0, p?.picked.count ?? 0)
                let done = p.map { $0.step > .summarize ? total : $0.step == .summarize ? $0.done : 0 } ?? 0
                EpisodeTicksButton(state: .writing(p?.short ?? ""), count: (p?.step ?? .fetch) >= .summarize ? total : 0, done: done) { desk = show.id }
            }
        }
        .padding(.vertical, 12)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image("radio").resizable().renderingMode(.template).scaledToFit().frame(width: 30, height: 30).foregroundStyle(YYColor.t3)
            Text("一档只给你听的节目").font(.yy(size: 14, weight: .semibold)).foregroundStyle(YYColor.t1)
            Text("你定从哪些网站、博客取新内容，书伴里选的模型来写稿，两位主持人念给你听。都在这台 Mac 上做，不发布出去。")
                .font(.yy(size: 12)).foregroundStyle(YYColor.t2).multilineTextAlignment(.center).frame(maxWidth: 380)
            HStack(spacing: 10) {
                ForEach(Array(Podcasts.templates().enumerated()), id: \.offset) { _, t in
                    PodcastGlassButton(title: String(localized: "从“\(t.name)”开始"), symbol: "plus") { making = ShowDraftEdit(id: nil, draft: t) }
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A show being set up: a new one (no id) or one being changed.
struct ShowDraftEdit: Identifiable {
    let id: String?
    var draft: ShowDraft
    var key: String { id ?? "new" }
}

extension ShowDraftEdit: Hashable {
    static func == (a: ShowDraftEdit, b: ShowDraftEdit) -> Bool { a.id == b.id && a.draft == b.draft }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// 设置 · 通用 · 开机时打开语阅. Shows are written at their time only while 语阅 runs, so this
/// used to sit on a 播客 page of its own; it starts the whole app, so it's in 通用 now.
struct LoginItemRow: View {
    @State private var atLogin = LoginItem.isOn || LoginItem.needsApproval
    @State private var problem: String?

    private var detail: String {
        if let problem { return problem }
        if LoginItem.needsApproval { return String(localized: "还要在 系统设置 › 通用 › 登录项 里允许语阅") }
        return String(localized: "只在菜单栏，不开窗口；播客到点自己写")
    }

    var body: some View {
        SettingsRow(String(localized: "开机时打开语阅"), detail: detail) {
            HStack(spacing: 10) {
                if LoginItem.needsApproval {
                    Button("去允许") { LoginItem.openSettings() }
                }
                SettingsSwitch(isOn: Binding(get: { atLogin }, set: { on in
                    do {
                        try LoginItem.set(on)
                        atLogin = on
                        problem = nil
                    } catch {
                        problem = error.localizedDescription
                    }
                }))
            }
        }
    }
}

/// 设置 · 存储 · 听过的节目一直保留 (U6): heard episodes are cleared after 30 days unless this is on.
struct KeepHeardRow: View {
    @AppStorage(Podcasts.keepHeardKey) private var keepHeard = false

    var body: some View {
        SettingsRow(String(localized: "听过的播客一直保留"),
                    detail: keepHeard ? String(localized: "听过的都留着")
                                      : String(localized: "关着时，听完 30 天自动清掉；划过线、加过书签的留着")) {
            SettingsSwitch(isOn: $keepHeard)
        }
    }
}
#endif
