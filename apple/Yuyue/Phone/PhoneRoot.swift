#if os(iOS)
import SwiftUI
import YuyueCore

/// The phone: 书架 · 笔记 · 我的, and 搜索 in its own circle (iOS 26 draws them as a floating
/// glass bar). A book opens over all of them, full screen; while one is read aloud with its
/// pages closed, a 播放条 sits above the tabs.
struct PhoneRoot: View {
    @Bindable var library: Library
    @State private var tab = PhoneTab.shelf
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    @AppStorage("phone.lastBook") private var lastBook = ""
    @AppStorage(AppAppearance.key) private var mode = AppAppearance.system
    @State private var reopened = false
    @Environment(\.scenePhase) private var phase
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    enum PhoneTab: Hashable { case shelf, notes, me, search }

    var body: some View {
        TabView(selection: $tab) {
            Tab("书架", image: PhoneTabIcon.shelf, value: .shelf) {
                PhoneShelf(library: library).nowPlayingBar(library)
            }
            Tab("笔记", systemImage: "highlighter", value: .notes) {
                PhoneNotes(library: library).nowPlayingBar(library)
            }
            Tab("我的", systemImage: "person", value: .me) {
                PhoneMe(library: library).nowPlayingBar(library)
            }
            Tab(value: .search, role: .search) {
                PhoneSearch(library: library).nowPlayingBar(library)
            }
        }
        .tint(tint.accent)
        .preferredColorScheme(mode.scheme)
        .fullScreenCover(item: Binding(get: { library.presented.map(Presented.init) }, set: { library.presented = $0?.id })) { book in
            ReaderScreen(library: library, bookID: book.id)
                .onAppear { lastBook = book.id }
                .onDisappear { if library.presented == nil { lastBook = "" } }
        }
        .onOpenURL { url in
            Task { await library.importFiles([url]) }
        }
        // One place for every tab: 书架, 我的 › 书库来源, 数据快照….
        .alert("出了点问题", isPresented: Binding(get: { library.alert != nil }, set: { if !$0 { library.alert = nil } })) {
            Button("好") {}
        } message: {
            Text(library.alert ?? "")
        }
        .onChange(of: phase, initial: true) { _, now in
            if now == .active { Task { await library.watched.scan(into: library) } }
        }
        .openingSnapshots(library)
        .audiobookSheets(library)
        .recordingImportSheet(library)
        .task { await library.sync.keepUp() }
        .onAppear {
            // 上次停在书页上，打开 App 就直接回到那一页.
            guard !reopened else { return }
            reopened = true
            if !lastBook.isEmpty, library.books.contains(where: { $0.id == lastBook && $0.available }) {
                library.presented = lastBook
            }
            #if DEBUG
            if let title = UserDefaults.standard.string(forKey: "debugOpen"),
               let book = library.books.first(where: { $0.title.contains(title) }) {
                library.presented = book.id
            }
            #endif
        }
    }

    private struct Presented: Identifiable { let id: String }
}

extension View {
    /// The 播放条 at the bottom of a tab, while a book is read aloud with its pages closed.
    func nowPlayingBar(_ library: Library) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if let playing = library.nowPlaying, let book = library.books.first(where: { $0.id == playing.bookID }) {
                NowPlayingBar(playing: playing, book: book) { library.presented = book.id }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: library.nowPlaying?.bookID)
    }
}

/// Cover, the sentence being read, ‹ ▶ ›, and a thin line for the chapter underneath. A tap
/// anywhere else goes back to the page.
struct NowPlayingBar: View {
    let playing: any NowPlaying
    let book: BookSummary
    let open: () -> Void
    private let tint = YYTint.standard
    /// 有声书: −15 s / +30 s, and the time.
    private var audio: AudiobookPlayer? { playing as? AudiobookPlayer }

    var body: some View {
        HStack(spacing: 10) {
            BookCover(book: book)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(audio.map { $0.title($0.chapter) } ?? playing.player?.line ?? book.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(YYColor.t1)
                    .lineLimit(1)
                Text(audio.map { "\(book.title) · \(AudiobookPlayer.clock($0.inChapter.at)) / \(AudiobookPlayer.clock($0.inChapter.of))" } ?? book.title)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(YYColor.t3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let audio {
                Button("后退 15 秒", systemImage: "gobackward.15") { audio.skip(-AudiobookPlayer.back) }
                    .frame(width: 34, height: 40)
            } else {
                Button("上一句", systemImage: "backward.end.fill") { playing.player?.skip(forward: false) }
                    .frame(width: 34, height: 40)
            }
            Button(playing.isPlaying ? String(localized: "暂停") : String(localized: "接着听"), systemImage: playing.isPlaying ? "pause.fill" : "play.fill") {
                playing.togglePlay()
            }
            .contentTransition(.symbolEffect(.replace))
            .animation(YYMotion.quick, value: playing.isPlaying)
            .font(.title3)
            .frame(width: 38, height: 40)
            if let audio {
                Button("前进 30 秒", systemImage: "goforward.30") { audio.skip(AudiobookPlayer.ahead) }
                    .frame(width: 34, height: 40)
            } else {
                Button("下一句", systemImage: "forward.end.fill") { playing.player?.skip(forward: true) }
                    .frame(width: 34, height: 40)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(YYColor.t1)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            GeometryReader { g in
                Capsule().fill(tint.accent)
                    .frame(width: g.size.width * (audio.map { $0.inChapter.of > 0 ? $0.inChapter.at / $0.inChapter.of : 0 } ?? playing.player?.sectionProgress ?? 0), height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, 22)
            .padding(.bottom, 2)
        }
        .contentShape(.capsule)
        .onTapGesture(perform: open)
        .modifier(CapsuleGlass())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("正在听《\(book.title)》")
        .accessibilityAction(named: Text("回到正在读的页"), open)
    }
}
#endif
