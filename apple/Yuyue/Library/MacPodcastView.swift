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
            Text(desk == nil ? String(localized: "播客") : String(localized: "编辑部"))
                .font(.yy(size: 22, weight: .bold)).foregroundStyle(YYColor.t1)
                .padding(.leading, headerInset)
            if let id = desk, let show = podcasts.shows.first(where: { $0.id == id }) {
                Text(podcasts.writing[id].map { "\(show.name) · \($0.line)" } ?? show.name)
                    .font(.yy(size: 12)).foregroundStyle(YYColor.t2).lineLimit(1)
            } else {
                let fresh = podcasts.latest.count { !$0.heard }
                if fresh > 0 {
                    Text("\(fresh) 集没听").font(.yy(size: 12)).monospacedDigit().foregroundStyle(YYColor.t2)
                }
            }
            Spacer()
            if let id = desk {
                if podcasts.isWriting(id) {
                    PodcastGlassButton(title: String(localized: "停下"), symbol: "pause.fill") { podcasts.cancel(id) }
                }
                PodcastGlassButton(title: String(localized: "回到播客"), symbol: "chevron.left") { desk = nil }
            } else {
                PodcastGlassButton(title: String(localized: "配一档节目"), symbol: "plus", flat: true) { making = ShowDraftEdit(id: nil, draft: Podcasts.templates()[0]) }
            }
        }
    }

    // MARK: 节目

    private var covers: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 18) {
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
                        Button("现在写一集") { podcasts.write(show); desk = show.id }
                        Button("编辑部") { desk = show.id }
                        Button("改设置…") { making = ShowDraftEdit(id: show.id, draft: show.draft) }
                        Divider()
                        Button("删除这档节目", role: .destructive) { podcasts.remove(show.id) }
                    }
                    .onTapGesture { desk = show.id }
                }
            }
            .padding(.top, 8)
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
        let playing = library.listening == e.book
        return HStack(spacing: 14) {
            ShowCover(name: show?.name ?? "", size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(show?.name ?? "") · \(e.day)").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
                Text(e.title).font(.yy(size: 13, weight: .bold)).foregroundStyle(e.heard ? YYColor.t2 : YYColor.t1).lineLimit(1)
                if !e.summary.isEmpty {
                    Text(e.summary).font(.yy(size: 11.5)).foregroundStyle(YYColor.t2).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text(String(localized: "\(e.articles.count) 条")).font(.yy(size: 10.5)).foregroundStyle(YYColor.t3).monospacedDigit()
            PodcastGlassButton(title: remaining(e, book), symbol: e.heard ? "checkmark" : "play.fill", kind: playing ? .playing : .plain) {
                if let book { library.open(book, .listen) }
                openWindow(id: "reader", value: e.book)
            }
        }
        .padding(.vertical, 12)
        .contentShape(.rect)
        .onTapGesture(count: 2) { openWindow(id: "reader", value: e.book) }
        .contextMenu {
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

    private func remaining(_ e: Episode, _ book: BookSummary?) -> String {
        guard let book else { return String(localized: "听") }
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
                PodcastGlassButton(title: String(localized: "再试一次"), symbol: "arrow.clockwise") { podcasts.write(show) }
            } else {
                PodcastGlassButton(title: podcasts.writing[show.id]?.short ?? "", kind: .writing) { desk = show.id }
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

/// 设置 · 播客: the shows are on their own page now.
struct MacPodcastSettingsNote: View {
    /// Shows are written at their time only while 语阅 runs.
    private var loginDetail: String {
        if let loginProblem { return loginProblem }
        if LoginItem.needsApproval { return String(localized: "还要在 系统设置 › 通用 › 登录项 里允许语阅") }
        return String(localized: "节目到点自己写，要语阅开着。开机后只在菜单栏，不开窗口；关掉窗口语阅也还在菜单栏")
    }

    /// U6: heard episodes are cleared after 30 days unless this is on.
    @AppStorage(Podcasts.keepHeardKey) private var keepHeard = false
    @State private var atLogin = LoginItem.isOn || LoginItem.needsApproval
    @State private var loginProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard {
                SettingsRow(String(localized: "开机时打开语阅"), detail: loginDetail) {
                    HStack(spacing: 8) {
                        if LoginItem.needsApproval {
                            Button("去允许") { LoginItem.openSettings() }
                        }
                        SettingsSwitch(isOn: Binding(get: { atLogin }, set: { on in
                            do {
                                try LoginItem.set(on)
                                atLogin = on
                                loginProblem = nil
                            } catch {
                                loginProblem = error.localizedDescription
                            }
                        }))
                    }
                }
                SettingsRow(String(localized: "节目"), detail: String(localized: "在书架窗口左边的“播客”里配节目、写新一集")) { EmptyView() }
                SettingsRow(String(localized: "写稿用的模型"), detail: String(localized: "和书伴用同一个：设置 › 书伴")) { EmptyView() }
                SettingsRow(String(localized: "主持人的声音"), detail: String(localized: "每台设备自己选，在配节目的“谁来讲”里试听")) { EmptyView() }
                SettingsRow(String(localized: "听过的节目一直保留"),
                            detail: keepHeard ? String(localized: "听过的节目都留着")
                                              : String(localized: "关着时，听完 30 天的节目自动清掉；划过线、加过书签的留着")) {
                    SettingsSwitch(isOn: $keepHeard)
                }
            }
        }
    }
}
#endif
