import SwiftUI
import YuyueCore
#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// The shelf window: the library, reading status and the user's collections down the side;
/// the books being read and then all of them in the middle.
struct MacShelfView: View {
    @Bindable var library: Library
    @State private var filter: ShelfFilter? = .all
    /// M1: the sidebar's white selection slides from row to row.
    @Namespace private var sidebarSelection
    /// 搜索 · 问 ⌘K, and what to start it with.
    @State private var quick: String?
    @State private var sort = ShelfSort.recent
    @State private var importerShown = false
    @State private var menu: OpenMenu?
    @State private var picking: String?
    #if DEBUG
    @State private var debugPicking: String?
    #endif
    @State private var editing: BookSummary?
    @State private var mainFrame = CGRect.zero
    @State private var menuSize = CGSize(width: 214, height: 280)
    @State private var dropCount: Int?
    /// A book 在书架里显示 pointed at, ringed for a moment.
    @State private var revealed: String?
    @State private var newName = ""
    @State private var renaming: String?
    @State private var dropCollection: String?
    @FocusState private var nameFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private struct OpenMenu: Equatable {
        let book: String
        let at: CGPoint
    }

    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    @AppStorage("general.reopenLast") private var reopenLast = false
    @State private var reopened = false
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    var body: some View {
        // 首页导航 · A (docs/design/首页导航.html): the sidebar is written straight on the desk, no
        // card; the page is a sheet of paper lifted off it, 8 in from the window's edges. Put away,
        // the sidebar slides out to the left while the paper widens to the window's left edge.
        ZStack(alignment: .topLeading) {
            Group {
                switch filter {
                case .notes: MacNotesView(library: library)
                case .words: MacWordsView(library: library)
                case .podcasts: MacPodcastView(library: library)
                case .collections:
                    CollectionWall(library: library, pinnedRaw: $pinnedRaw, leading: headerInset) { filter = .collection($0) }
                default: main
                }
            }
            // M1: another page fades in a few points lower, rather than replacing this at once.
            .id(filter)
            .transition(YYMotion.swap)
            .animation(YYMotion.standard, value: filter)
            .environment(\.shelfHeaderInset, headerInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Clipped to the sheet before its shadow goes under, so the shadow isn't clipped too.
            .clipShape(.rect(cornerRadius: ShelfDesk.paperRadius))
            .background { ShelfDesk.Paper() }
            .padding([.top, .bottom, .trailing], ShelfDesk.margin)
            .padding(.leading, paperLeading)
            sidebar
                .frame(width: 212)
                .padding(8)
                .offset(x: sidebarShown ? 0 : -240)
                .opacity(sidebarShown ? 1 : 0)
                .allowsHitTesting(sidebarShown)
                .accessibilityHidden(!sidebarShown)
        }
        // Over every page beside the sidebar (书架, 笔记, 生词本, 合集), so deleting a mark, a
        // word or a collection shows its banner too, not only deleting a book.
        .overlay(alignment: .top) { toast.padding(.leading, sidebarShown ? 228 : 0).padding(.horizontal, 16) }
        .yyToastMotion(value: library.toast?.id)
        .ignoresSafeArea(.container, edges: .top)
        .onReceive(NotificationCenter.default.publisher(for: .toggleShelfSidebar)) { _ in toggleSidebar() }
        .onGeometryChange(for: Bool.self) { $0.size.width < 760 } action: { narrow in
            withAnimation(Self.slide) {
                narrowWindow = narrow
                if !narrow { openedWhileNarrow = false }
            }
        }
        .background(ShelfDesk.fill)
        // 显示侧栏 / 隐藏侧栏 sits in the page, just before its title on the title's line, and
        // moves with the page; put away, the sidebar takes the window's buttons with it, so the
        // button and the title start the page clean at its left edge.
        .overlay(alignment: .topLeading) {
            sidebarButton
                .padding(.leading, paperLeading + 16)
                .padding(.top, Self.lineY - 11)
                .ignoresSafeArea(.container, edges: .top)
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // `.v-mac-sb .v-lights`: in the sidebar card's top corner, inside the title bar so they
        // can be clicked; they fade out and back with the sidebar.
        .trafficLights(CGPoint(x: 30, y: 24), hidden: !sidebarShown)
        // The prototype has no fade where lists meet the title bar, the search field or the line
        // above 同步: what scrolls up just goes under, clean.
        .noScrollEdgeFade()
        .fileImporter(isPresented: $importerShown, allowedContentTypes: Library.importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await library.importFiles(urls, into: currentCollection) }
            }
        }
        .onAppear(perform: takeOpenedFiles)
        .onReceive(NotificationCenter.default.publisher(for: .filesOpened)) { _ in takeOpenedFiles() }
        .openingSnapshots(library)
        .audiobookSheets(library)
        .recordingImportSheet(library)
        .sheet(item: $editing) { book in
            EditInfoSheet(library: library, book: book)
        }
        .alert("出了点问题", isPresented: Binding(get: { library.alert != nil }, set: { if !$0 { library.alert = nil } })) {
            Button("好") {}
        } message: {
            Text(library.alert ?? "")
        }
        .tint(tint.accent)
        .onAppear {
            AppAppearance.apply()
            MacMenuBar.openWindow = openWindow
            // 打开语阅时接着读上次那本: once, when the app starts.
            guard reopenLast, !reopened else { return }
            reopened = true
            if let last = library.books.filter({ $0.openedAt != nil }).max(by: { ($0.openedAt ?? 0) < ($1.openedAt ?? 0) }) {
                openWindow(id: "reader", value: last.id)
            }
        }
        .task { await library.sync.keepUp() }
        .task(id: library.books.map(\.id)) { countNotes() }
        .onReceive(NotificationCenter.default.publisher(for: .notesChanged)) { _ in countNotes() }
        .onReceive(NotificationCenter.default.publisher(for: .vocabChanged)) { _ in countNotes() }
        #if DEBUG
        .task {
            // `-debugImport <file>|<file>` imports them as 导入 would, even onto an empty shelf;
            // `-debugOpen 红楼` opens the first book whose title has that in it.
            Task {
                if let path = UserDefaults.standard.string(forKey: "debugImport") { await library.importFiles(path.split(separator: "|").map { URL(filePath: String($0)) }) }
                // A recording goes in after the books, in a task of its own.
                try? await Task.sleep(for: .seconds(2))
                // `-debugAudiobook 1` shows the first 有声书's page; `-debugAudiobook remake` makes it again.
                if let what = UserDefaults.standard.string(forKey: "debugAudiobook"), let a = library.audiobooks.all.first {
                    if what == "remake", let book = library.books.first(where: { $0.id == a.book }) { library.audiobooks.make(a, with: book) } else { library.audiobooks.showing = a.id }
                }
                // `-debugPair 1` lays the first 有声书 on the shelf against the first e-book (合成).
                if UserDefaults.standard.bool(forKey: "debugPair") {
                    while library.pendingRecording != nil { try? await Task.sleep(for: .milliseconds(300)) }
                    if let audio = library.books.first(where: { $0.format == .audio }), let ebook = library.books.first(where: { $0.format != .audio }) {
                        library.pair(audio, with: ebook)
                    }
                }
                if let title = UserDefaults.standard.string(forKey: "debugOpen"), let book = library.books.first(where: { $0.title.contains(title) }) {
                    openWindow(id: "reader", value: book.id)
                }
            }
            // `-debugPodcast 1` opens on 播客; `desk` on its 编辑部, `make` with 配一档节目.
            if UserDefaults.standard.string(forKey: "debugPodcast") != nil { filter = .podcasts }
            // `-debugMenu 1` / `-debugPick 1` open the card or the picker on the first book,
            // to look at them without clicking.
            guard let first = shown.first else { return }
            if UserDefaults.standard.bool(forKey: "debugMenu") { menu = OpenMenu(book: first.id, at: CGPoint(x: 300, y: 300)) }
            // `-debugCollections "睡前|科幻|通勤听"` makes those (the first with the first book in it).
            if let names = UserDefaults.standard.string(forKey: "debugCollections"), library.collections.isEmpty {
                for (i, name) in names.split(separator: "|").enumerated() { library.createCollection(String(name), with: i == 0 ? first.id : nil) }
            }
            if UserDefaults.standard.bool(forKey: "debugPick") { debugPicking = first.id }
            // `-debugPop 1`: the real popover, beside the book.
            if UserDefaults.standard.bool(forKey: "debugPop") { picking = first.id }
            if UserDefaults.standard.bool(forKey: "debugEdit") { editing = first }
            // `-debugCover <image path>` puts that image on the first book, as 换封面 would.
            if let path = UserDefaults.standard.string(forKey: "debugCover"), let data = FileManager.default.contents(atPath: path) {
                library.setCover(first, image: data)
            }
            if UserDefaults.standard.bool(forKey: "debugToast") { library.debugToast() }
            // `-debugFilter notes|words` opens that page of the sidebar; `-notes.byBook 1` 按书.
            switch UserDefaults.standard.string(forKey: "debugFilter") {
            case "notes": filter = .notes
            case "words": filter = .words
            case "podcasts": filter = .podcasts
            case "audio": filter = .audio
            default: break
            }
            // `-debugSettings sync` opens 设置 on that page.
            if let page = UserDefaults.standard.string(forKey: "debugSettings") {
                UserDefaults.standard.set(page, forKey: "settings.page")
                openSettings()
            }
            // `-debugQuick 父亲` opens 搜索 · 问 with that typed.
            if let q = UserDefaults.standard.string(forKey: "debugQuick") { quick = q }
            // `-debugDrop 3` shows what dragging three files in looks like.
            if UserDefaults.standard.object(forKey: "debugDrop") != nil { dropCount = UserDefaults.standard.integer(forKey: "debugDrop") }
        }
        .overlay(alignment: .topTrailing) {
            if let id = debugPicking {
                CollectionPicker(library: library, bookID: id).clipShape(.rect(cornerRadius: 12)).padding(40)
            }
        }
        #endif
        .overlay {
            if let q = quick {
                QuickSearchPanel(library: library, query: q) { quick = nil } ask: { question in
                    ask(question)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickSearch)) { _ in quick = quick == nil ? "" : nil }
    }

    /// 问书伴 from ⌘K: in the book read last.
    private func ask(_ question: String) {
        guard let book = library.books.filter({ $0.available && $0.openedAt != nil }).max(by: { ($0.openedAt ?? 0) < ($1.openedAt ?? 0) }) else {
            library.note(icon: "sparkle", String(localized: "先打开一本书"), String(localized: "书伴陪你读一本书，打开以后再问"))
            return
        }
        library.ask(question, in: book.id)
        openWindow(id: "reader", value: book.id)
    }

    // MARK: Sidebar

    /// The list, then 同步 at its foot: below it, not over it, so a long list of 合集 stops
    /// above 同步 instead of running under. On the desk itself, no card behind it.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window's own buttons sit here.
            Color.clear.frame(height: 10)
            searchField
                .padding(.top, 16)
                .padding(.horizontal, 10)
            ScrollView {
                sidebarList
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            syncStatus
                .padding(.horizontal, 10)
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand(perform: moveFilter)
    }

    /// `.v-mac-sch`
    private var searchField: some View {
        Button { quick = "" } label: {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.yy(size: 11.5))
                Text("搜索 · 问").font(.yy(size: 12))
                Spacer()
                Text("⌘K").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
            }
            .foregroundStyle(YYColor.t2)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(ShelfDesk.field, in: .rect(cornerRadius: 9))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var sidebarList: some View {
        sidebarRows
            .environment(\.sidebarSelection, sidebarSelection)
            .animation(YYMotion.layout, value: filter)
    }

    private var sidebarRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarGroup(String(localized: "资料库"), key: "library")
            if !closedGroups.contains("library") {
                sidebarRow(.all, String(localized: "全部"), "asset." + PhoneTabIcon.shelf, library.shelfBooks.count)
                sidebarRow(.books, String(localized: "书"), ProtoIcon.book.rawValue, library.shelfBooks.count)
                // 播客: how many episodes not heard yet.
                sidebarRow(.podcasts, String(localized: "播客"), "asset.radio", library.podcasts.latest.count { !$0.heard })
                sidebarRow(.audio, String(localized: "有声"), ProtoIcon.wave.rawValue, library.shelfBooks.count(where: library.hasAudio))
            }
            sidebarGroup(String(localized: "状态"), key: "status")
            if !closedGroups.contains("status") {
                ForEach([ReadingStatus.reading, .want, .finished], id: \.self) { status in
                    sidebarRow(.status(status), status.name, status.symbol, library.shelfBooks.count { $0.status == status })
                }
            }
            sidebarGroup(String(localized: "笔记"), key: "notes")
            if !closedGroups.contains("notes") {
                // The phone's 笔记 tab icon.
                sidebarRow(.notes, String(localized: "笔记"), "highlighter", noteCount)
                sidebarRow(.words, String(localized: "生词本"), "translate", wordCount)
            }
            sidebarGroup(String(localized: "合集"), key: "collections")
            if !closedGroups.contains("collections") {
                allCollectionsRow
                ForEach(pinnedCollections, id: \.id) { c in
                    collectionRow(c)
                }
            }
        }
    }

    /// “合集 14 ›”: the 合集墙. A book held over it a moment brings up every 合集 to drop it on.
    private var allCollectionsRow: some View {
        Button { filter = .collections } label: {
            SidebarRow(symbol: "square.stack", trailing: "\(library.collections.count) ›",
                       on: filter == .collections || (currentCollection.map { id in !pinnedCollections.contains { $0.id == id } } ?? false),
                       drop: dropOverAll, tint: tint) {
                Text("合集")
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == .collections ? .isSelected : [])
        .onDrop(of: [.utf8PlainText, .plainText], isTargeted: Binding(get: { dropOverAll }, set: { over in
            dropOverAll = over
            dropTimer?.cancel()
            if over {
                dropTimer = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    if !Task.isCancelled { dropListShown = true }
                }
            }
        })) { _ in false }
        .popover(isPresented: $dropListShown, arrowEdge: .trailing) {
            CollectionDropList(library: library) { dropListShown = false }
                .presentationBackground(YYColor.card)
        }
    }

    /// `.v-mac-gt`: a click folds the group away or back; the arrow shows on hover, as in 访达.
    private func sidebarGroup(_ title: String, key: String) -> some View {
        SidebarGroupTitle(title: title, closed: closedGroups.contains(key)) { toggleGroup(key) }
    }

    private func sidebarRow(_ f: ShelfFilter, _ title: String, _ symbol: String, _ count: Int) -> some View {
        Button { filter = f } label: {
            SidebarRow(symbol: symbol, count: count, on: filter == f) { Text(title) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == f ? .isSelected : [])
    }

    /// The rows in order, for ↑ ↓ on the sidebar.
    private var filterOrder: [ShelfFilter] {
        [.all, .books, .podcasts, .audio, .status(.reading), .status(.want), .status(.finished), .notes, .words, .collections]
            + pinnedCollections.map { .collection($0.id) }
    }

    private func moveFilter(_ direction: MoveCommandDirection) {
        let order = filterOrder
        guard let i = order.firstIndex(of: filter ?? .all) else { return }
        switch direction {
        case .up where i > 0: filter = order[i - 1]
        case .down where i < order.count - 1: filter = order[i + 1]
        default: break
        }
    }

    /// `.v-mac-sync`: 同步 at the foot of the sidebar; a click opens 设置 · 同步.
    private var syncStatus: some View {
        let sync = library.sync
        let (dot, text): (Color, String) = switch sync.state {
        case .syncing: (tint.accent, String(localized: "正在同步…"))
        case .failed: (YYColor.danger, String(localized: "没同步上"))
        case .idle where !sync.isOn: (YYColor.t3, String(localized: "还没开同步"))
        case .idle: (YYColor.ok, syncPlace(sync.method) + " · " + syncedAgo(sync.lastSynced))
        }
        let devices = sync.isOn && sync.devices.count > 1 ? String(localized: "\(sync.devices.count) 台设备") : nil
        return Button {
            UserDefaults.standard.set(SettingsPage.sync.rawValue, forKey: "settings.page")
            openSettings()
        } label: {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(text)
                    .font(.yy(size: 11))
                    .foregroundStyle(YYColor.t2)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let devices {
                    Text(devices).font(.yy(size: 10)).foregroundStyle(YYColor.t3)
                }
            }
            .padding(8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func syncPlace(_ method: Sync.Method) -> String {
        switch method {
        case .icloud: "iCloud"
        case .webdav: "WebDAV"
        case .googleDrive: "Google Drive"
        case .none: String(localized: "同步")
        }
    }

    /// 刚刚同步, 5 分钟前同步, 今天 9:40 同步.
    private func syncedAgo(_ date: Date?) -> String {
        let ago = date.map(SyncSettings.ago) ?? String(localized: "刚刚")
        return ago + (ago.last?.isNumber == true ? String(localized: " 同步") : String(localized: "同步"))
    }

    private func collectionRow(_ c: BookCollection) -> some View {
        Group {
            if renaming == c.id {
                SidebarRow(symbol: CollectionIcon.symbol(for: c)) {
                    TextField("合集的名字", text: $newName)
                        .textFieldStyle(.plain)
                        .focused($nameFocused)
                        .onSubmit { finishRenaming(c) }
                        .onExitCommand { renaming = nil }
                }
                .onChange(of: nameFocused) { if !nameFocused { finishRenaming(c) } }
            } else {
                Button { filter = .collection(c.id) } label: {
                    SidebarRow(symbol: CollectionIcon.symbol(for: c), count: Int(c.count),
                               on: filter == .collection(c.id), drop: dropCollection == c.id, tint: tint) {
                        Text(c.name)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == .collection(c.id) ? .isSelected : [])
            }
        }
        // Books dragged here go in; it lights up while one hovers over it.
        // Files from Finder are imported straight into it.
        .onDrop(of: [.fileURL, .utf8PlainText, .plainText], delegate: ShelfDrop(hovering: Binding {
            dropCollection == c.id ? 0 : nil
        } set: { on in
            dropCollection = on != nil ? c.id : (dropCollection == c.id ? nil : dropCollection)
        }, acceptsBooks: true) { urls in
            Task { await library.importFiles(urls, into: c.id) }
        } books: { ids in
            for id in ids {
                if id.hasPrefix(PinnedCollections.dragPrefix) {
                    movePinned(String(id.dropFirst(PinnedCollections.dragPrefix.count)), before: c.id)
                } else if library.books.contains(where: { $0.id == id }) {
                    library.setBook(id, in: c.id, true)
                }
            }
        })
        // Pinned 合集 are put in order by dragging one onto another.
        .draggable(PinnedCollections.dragPrefix + c.id) {
            SidebarRow(symbol: CollectionIcon.symbol(for: c)) { Text(c.name) }.frame(width: 180)
        }
        .contextMenu {
            Button("取消固定") {
                pinnedRaw = PinnedCollections.raw(PinnedCollections.ids(pinnedRaw).filter { $0 != c.id })
            }
            Divider()
            Button("重命名") {
                newName = c.name
                renaming = c.id
                nameFocused = true
            }
            CollectionIconMenu(collection: c, library: library)
            Button("删除合集", role: .destructive) {
                if filter == .collection(c.id) { filter = .all }
                pinnedRaw = PinnedCollections.raw(PinnedCollections.ids(pinnedRaw).filter { $0 != c.id })
                library.deleteCollection(c)
            }
        }
    }

    /// A pinned 合集 dropped on another goes just before it.
    private func movePinned(_ id: String, before target: String) {
        guard id != target else { return }
        var ids = PinnedCollections.ids(pinnedRaw).filter { $0 != id }
        let i = ids.firstIndex(of: target) ?? ids.count
        ids.insert(id, at: i)
        withAnimation(.snappy(duration: 0.2)) { pinnedRaw = PinnedCollections.raw(ids) }
    }

    private func finishRenaming(_ c: BookCollection) {
        guard renaming == c.id else { return }
        renaming = nil
        let name = newName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != c.name { library.renameCollection(c.id, to: name) }
    }

    // MARK: 收起 / 展开

    /// 显示侧栏 / 隐藏侧栏 (⌘⌥N, as the prototype has it for both windows). A window too narrow
    /// for the sidebar puts it away by itself, until it's asked for again. Remembered.
    @AppStorage("shelf.sidebarShown") private var sidebarWanted = true
    @AppStorage("notes.byBook") private var notesByBook = false
    @AppStorage("notes.bookColumnShown") private var notesBookColumn = true
    @State private var narrowWindow = false
    @State private var openedWhileNarrow = false

    /// The middle of 显示侧栏 and the page's title, from the window's top (`.v-mac-hd`).
    static let lineY: CGFloat = 34
    /// Out and back with a little give at the end.
    static let slide = Animation.timingCurve(0.32, 1.18, 0.42, 1, duration: 0.42)

    private var sidebarShown: Bool { sidebarWanted && (!narrowWindow || openedWhileNarrow) }

    /// Where the paper starts: just past the sidebar, or 8 in from the window's edge without it.
    private var paperLeading: CGFloat { sidebarShown ? 220 : ShelfDesk.margin }

    /// The page's title leaves room for 显示侧栏 before it.
    private var headerInset: CGFloat { 30 }

    private func toggleSidebar() {
        // On 笔记 · 按书 the same key folds the book column instead.
        if filter == .notes && notesByBook {
            withAnimation(Self.slide) { notesBookColumn.toggle() }
            return
        }
        withAnimation(Self.slide) {
            if sidebarShown {
                sidebarWanted = false
                openedWhileNarrow = false
            } else {
                sidebarWanted = true
                openedWhileNarrow = narrowWindow
            }
        }
    }

    private var sidebarButton: some View {
        SidebarToggle(shown: sidebarShown, action: toggleSidebar)
    }

    /// 资料库, 状态, 笔记, 合集: each folds away by its title, and stays so.
    @AppStorage("shelf.closedGroups") private var closedGroupsRaw = ""
    private var closedGroups: Set<String> { Set(closedGroupsRaw.split(separator: ",").map(String.init)) }

    private func toggleGroup(_ key: String) {
        var set = closedGroups
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        withAnimation(.snappy(duration: 0.2)) { closedGroupsRaw = set.sorted().joined(separator: ",") }
    }

    // MARK: 合集 in the sidebar

    @AppStorage(PinnedCollections.key) private var pinnedRaw = ""
    private var pinnedCollections: [BookCollection] {
        PinnedCollections.ids(pinnedRaw).compactMap { id in library.collections.first { $0.id == id } }
    }
    /// A book held over “合集”: after a moment, every 合集 to drop it on.
    @State private var dropOverAll = false
    @State private var dropListShown = false
    @State private var dropTimer: Task<Void, Never>?

    @State private var noteCount = 0
    @State private var wordCount = 0

    private func countNotes() {
        noteCount = library.books.filter(\.available).reduce(0) { $0 + ((try? library.core.marks(book: $1.id).count) ?? 0) }
        wordCount = (try? library.core.words().count) ?? 0
    }

    // MARK: Main

    private var currentCollection: String? {
        if case .collection(let id) = filter { id } else { nil }
    }

    private var title: String {
        switch filter ?? .all {
        case .all: return String(localized: "全部")
        case .books: return String(localized: "书")
        case .podcasts: return String(localized: "播客")
        case .audio: return String(localized: "有声")
        case .status(let s): return s.name
        case .collection(let id): return library.collections.first { $0.id == id }?.name ?? String(localized: "合集")
        case .collections: return String(localized: "全部合集")
        case .notes: return String(localized: "笔记")
        case .words: return String(localized: "生词本")
        }
    }

    private var shown: [BookSummary] {
        var books = library.shelfBooks
        switch filter ?? .all {
        case .all: break
        case .books: break
        case .audio: books = books.filter(library.hasAudio)
        case .status(let s): books = books.filter { $0.status == s }
        case .collection(let id): books = books.filter { $0.collections.contains(id) }
        case .notes, .words, .collections, .podcasts: break
        }
        return sort.sorted(books)
    }

    /// Every book being read that this page would card; the cards show the first three.
    private var allReading: [BookSummary] {
        guard filter == .all || filter == .books || filter == .audio else { return [] }
        let all = filter == .all, audio = filter == .audio
        return library.shelfBooks.filter { b in
            b.status == .reading && (all || !audio || library.hasAudio(b))
        }
    }

    private var reading: [BookSummary] { Array(allReading.prefix(3)) }

    /// 设置 · 外观 · 书架封面大小 and 封面下面写进度.
    @AppStorage("shelf.coverSize") private var coverSize = 100.0
    @AppStorage("shelf.showProgress") private var showProgress = true
    /// 墨水屏 has no glass.
    @AppStorage(EInk.key) private var eink = false

    /// `.v-mac-g`: at the default size a 1040-wide window holds eight covers about 80 wide. The
    /// covers are sized from the window, room for a scroller always left: sized from inside the
    /// scroller, two rows that just fit grow taller without it, need it again, and never settle.
    /// The room left is generous and the width rounded down: with scrollers always shown, a grid
    /// even a point too wide widens the window's column, which widens the grid, without end.
    private var columns: [GridItem] {
        let room = max(0, mainFrame.width - 48 - 24)
        let count = max(1, Int((room + 18) / (coverSize - 24 + 18)))
        // Flexible, not fixed: fixed widths made the grid as wide as the window it was measured
        // in, so the window could grow (the sidebar put away) but never be made narrower again.
        // At most the cover size set in 设置: the room left over stays at the end of the row
        // rather than blowing the covers up.
        let width = max(40, ((room - 18 * CGFloat(count - 1)) / CGFloat(count)).rounded(.down))
        return Array(repeating: GridItem(.flexible(minimum: 40, maximum: width), spacing: 18, alignment: .top), count: count)
    }

    private var main: some View {
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title)
                        .font(.yy(size: 22, weight: .bold))
                        .foregroundStyle(YYColor.t1)
                        .lineLimit(1)
                        // Clear of the window's buttons and 显示侧栏 when the sidebar is away.
                        .padding(.leading, headerInset)
                    Spacer()
                    importButton
                }
                // `.v-mac-hd`: 64 high, 4 of it above, the title in the middle.
                .frame(height: 60)
                .padding(.top, 4)
                .padding(.bottom, 9)

                if !library.imports.isEmpty {
                    MacImportCard(library: library, tint: tint) { id in reveal(id, scroll) }
                        .padding(.bottom, 18)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if !reading.isEmpty {
                    readingHeader(count: allReading.count, shown: reading.count)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                        ForEach(reading) { book in
                            ReadingCard(book: book, listening: library.listening == book.id) { intent in
                                open(book, intent)
                            }
                            .overlay(RightClickCatcher { showMenu(for: book, at: $0) })
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                        }
                    }
                    // M2: a book moving into or out of the cards moves, not jumps.
                    .animation(YYMotion.layout, value: reading.map(\.id))
                    .padding(.bottom, 28)
                }

                // The books in the 在读 cards above aren't shown again below them.
                let carded = Set(reading.map(\.id))
                let books = shown.filter { !carded.contains($0.id) }
                if !books.isEmpty || carded.isEmpty {
                HStack {
                    Text(carded.isEmpty
                         ? String(localized: "\(books.count) 本")
                         : String(localized: "其余 \(books.count) 本"))
                        .font(.yy(size: 12.5, weight: .semibold))
                        .foregroundStyle(YYColor.t1)
                    Spacer()
                    sortMenu
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 14)

                if books.isEmpty {
                    empty
                } else if case .status(let s) = filter ?? .all {
                    statusShelves(s, books)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(books) { book in
                            cell(book).id(book.id)
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                    // M2: sorted another way, a book brought in or taken out, each moves to its place.
                    .animation(YYMotion.layout, value: books.map(\.id))
                }
                }
            }
            // `.v-mac-mn`: 22 in on the left, 26 on the right.
            .padding(.leading, 22)
            .padding(.trailing, 26)
            .padding(.bottom, 80)
        }
        // The title sits level with the window's buttons, as in the shelf's design.
        .ignoresSafeArea(.container, edges: .top)
        .blur(radius: dropCount != nil ? 5 : 0)
        .scrollDisabled(menu != nil)
        .background(YYColor.bg)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mainFrame = $0 }
        .overlay { menuLayer }
        .overlay { dropHint }
        .onDrop(of: [.fileURL], delegate: ShelfDrop(hovering: $dropCount) { urls in
            Task { await library.importFiles(urls, into: currentCollection) }
        })
        .animation(.easeOut(duration: 0.2), value: library.imports.isEmpty)
        }
        .toolbar(removing: .title)
        .toolbar(removing: .sidebarToggle)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private var importButton: some View {
        Button { importerShown = true } label: {
            HStack(spacing: 5) {
                if library.importing > 0 {
                    ProgressView().controlSize(.mini)
                    Text("正在导入")
                } else {
                    Image(systemName: "plus").font(.yy(size: 11, weight: .semibold))
                    Text("导入")
                }
            }
            .font(.yy(size: 12, weight: .medium))
            .foregroundStyle(YYColor.t1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            // Liquid Glass that answers the pointer, or the prototype's white capsule.
            .yyGlass(Capsule(), fill: YYColor.card, line: YYColor.line, shadow: 0, interactive: true, liquid: !eink)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("o")
        .help("导入书（⌘O）：EPUB、PDF、MOBI、AZW3、TXT；也可以直接拖进窗口")
    }

    /// A status page cut into 书, 有声书: each shelf with books in it, the empty ones left out.
    private func statusShelves(_ s: ReadingStatus, _ books: [BookSummary]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(StatusShelf.allCases, id: \.self) { shelf in
                let list = books.filter { shelf.holds($0, in: library) }
                if !list.isEmpty {
                    sectionHeader("\(shelf.name) · \(list.count)", trailing: shelf.verb(s))
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(list) { book in
                            cell(book).id(book.id)
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                    .animation(YYMotion.layout, value: list.map(\.id))
                    .padding(.bottom, 28)
                }
            }
        }
    }

    /// 在读, and when more are being read than the cards hold, the way to the rest of them.
    @ViewBuilder
    private func readingHeader(count: Int, shown: Int) -> some View {
        if count > shown {
            HStack {
                Text("在读")
                    .font(.yy(size: 12.5, weight: .semibold))
                    .foregroundStyle(YYColor.t1)
                Spacer()
                Button { filter = .status(.reading) } label: {
                    HStack(spacing: 2) {
                        Text("全部 \(count) 本")
                        Image(systemName: "chevron.right").font(.yy(size: 9, weight: .semibold))
                    }
                    .font(.yy(size: 11.5, weight: .medium))
                    .foregroundStyle(tint.accent)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 10)
        } else {
            sectionHeader(String(localized: "在读"), trailing: String(localized: "\(count) 本"))
        }
    }

    private func sectionHeader(_ text: String, trailing: String) -> some View {
        HStack {
            Text(text)
                .font(.yy(size: 12.5, weight: .semibold))
                .foregroundStyle(YYColor.t1)
            Spacer()
            Text(trailing)
                .font(.yy(size: 11))
                .foregroundStyle(YYColor.t3)
        }
        // `.v-mac-mn .v-lb`
        .padding(.horizontal, 2)
        .padding(.bottom, 10)
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $sort) {
                ForEach(ShelfSort.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(sort.name)
                Image(systemName: "chevron.up.chevron.down").font(.yy(size: 9, weight: .semibold))
            }
            .font(.yy(size: 11.5))
            .foregroundStyle(YYColor.t2)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder private var empty: some View {
        let (symbol, text): (String, String) = if library.books.isEmpty {
            ("books.vertical", String(localized: "书架是空的，把 EPUB、PDF、MOBI、TXT 拖进窗口就能开始读"))
        } else if currentCollection != nil {
            ("tray", String(localized: "还没有书。把书拖到左边这个合集上，或者把文件拖进来"))
        } else {
            ("book.closed", String(localized: "这里还没有书"))
        }
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.yy(size: 28, weight: .light)).foregroundStyle(YYColor.t3)
            Text(text).font(.yy(size: 12.5)).foregroundStyle(YYColor.t2)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private func cell(_ book: BookSummary) -> some View {
        Button { open(book, nil) } label: {
            VStack(alignment: .leading, spacing: 0) {
                BookCover(book: book)
                    .opacity(book.available ? 1 : 0.45)
                    // M7: the cover lifts under the pointer.
                    .yyLift()
                    .overlay {
                        if revealed == book.id {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(tint.accent, lineWidth: 2.5).padding(-4)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !book.available {
                            Image(systemName: "icloud.and.arrow.down")
                                .font(.yy(size: 11, weight: .semibold))
                                .foregroundStyle(YYColor.t2)
                                .padding(6)
                                .background(YYColor.card, in: .circle)
                                .padding(6)
                        } else if library.hasAudio(book) {
                            AudioBadge()
                        }
                    }
                    .padding(.bottom, 9)
                    .popover(isPresented: Binding(get: { picking == book.id }, set: { if !$0 { picking = nil } }), arrowEdge: .trailing) {
                        CollectionPicker(library: library, bookID: book.id) { picking = nil }
                            .presentationBackground(YYColor.bg)
                    }
                Text(book.title)
                    .font(.yy(size: 11.5, weight: .semibold))
                    .foregroundStyle(YYColor.t1)
                    .lineLimit(1)
                    .padding(.bottom, 2)
                if showProgress { note(book) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(YYPressStyle())
        .overlay(RightClickCatcher { showMenu(for: book, at: $0) })
        .draggable(book.id) {
            BookCover(book: book).frame(width: 60)
        }
        .accessibilityLabel("《\(book.title)》\(book.author.map { "，\($0)" } ?? "")，\(book.shelfNote)")
        .accessibilityAction(named: "更多") { showMenu(for: book, at: nil) }
    }

    @ViewBuilder private func note(_ book: BookSummary) -> some View {
        if library.listening == book.id {
            Label("听中 · \(book.percent)", systemImage: "headphones")
                .labelStyle(TightLabel())
                .font(.yy(size: 10.5))
                .foregroundStyle(tint.accent)
        } else {
            Text(library.shelfNote(book))
                .font(.yy(size: 10.5))
                .foregroundStyle(YYColor.t3)
        }
    }

    // MARK: Right-click card

    /// Opens the card where the click was (`point` in the window), or near the top when
    /// asked for from the keyboard or VoiceOver.
    private func showMenu(for book: BookSummary, at point: CGPoint?) {
        picking = nil
        let at = point.map { CGPoint(x: $0.x - mainFrame.minX, y: $0.y - mainFrame.minY) } ?? CGPoint(x: 40, y: 80)
        menu = OpenMenu(book: book.id, at: at)
    }

    @ViewBuilder private var menuLayer: some View {
        if let menu, let book = library.books.first(where: { $0.id == menu.book }) {
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    // A click anywhere else puts it away.
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { self.menu = nil }
                        .overlay(RightClickCatcher { _ in self.menu = nil })
                    BookMenuCard(book: book, perform: { perform($0, on: book) }, close: { self.menu = nil })
                        .onGeometryChange(for: CGSize.self, of: \.size) { menuSize = $0 }
                        .offset(menuOffset(at: menu.at, in: g.size))
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                }
            }
        }
    }

    /// From the pointer toward the lower right; to the left or up near the window's edges.
    private func menuOffset(at p: CGPoint, in size: CGSize) -> CGSize {
        let margin: CGFloat = 8
        var x = p.x + 2, y = p.y + 2
        if x + menuSize.width > size.width - margin { x = p.x - menuSize.width - 2 }
        if y + menuSize.height > size.height - margin { y = p.y - menuSize.height - 2 }
        return CGSize(width: max(margin, x), height: max(margin, y))
    }

    private func perform(_ action: BookAction, on book: BookSummary) {
        menu = nil
        switch action {
        case .resume: open(book, nil)
        case .listenFromStart: open(book, .listenFromStart)
        case .audiobook: library.audiobooks.showing = library.audiobooks.audiobook(for: book.id)?.id
        case .toggleFinished: library.setFinished(book, book.status != .finished)
        case .editInfo: editing = book
        case .addToCollection:
            // After the card has gone, so the two don't overlap.
            Task { picking = book.id }
        case .revealInFinder:
            if let url = library.originalFile(of: book) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .delete: library.delete(book)
        }
    }

    /// Files opened with 语阅 from 访达, all of them on one import card.
    private func takeOpenedFiles() {
        let urls = AppDelegate.waiting
        guard !urls.isEmpty else { return }
        AppDelegate.waiting = []
        Task { await library.importFiles(urls) }
    }

    private func open(_ book: BookSummary, _ intent: Library.OpenIntent?) {
        guard book.available else {
            library.note(icon: "icloud.and.arrow.down", String(localized: "《\(book.title)》在别的设备上"), String(localized: "把同一个文件拖进来，进度和笔记就接上了"))
            return
        }
        library.open(book, intent)
        openWindow(id: "reader", value: book.id)
    }

    // MARK: Overlays

    @ViewBuilder private var toast: some View {
        if let note = library.toast {
            UndoToast(toast: note, undo: { library.undo() })
                .padding(.top, 10)
                .transition(UndoToast.transition)
                .id(note.id)
        }
    }

    @ViewBuilder private var dropHint: some View {
        if let count = dropCount {
            MacDropHint(count: count, place: currentCollection == nil ? String(localized: "全部") : title, tint: tint)
        }
    }

    /// 在书架里显示: back to 全部, scrolled to the book, ringed for a moment.
    private func reveal(_ id: String, _ scroll: ScrollViewProxy) {
        filter = .all
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation { scroll.scrollTo(id, anchor: .center) }
            revealed = id
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { if revealed == id { revealed = nil } }
        }
    }
}

/// The two shelves a status page is cut into. A book is on one of them: a book with an audiobook
/// on 有声书, the rest on 书. The words for a shelf follow its kind: 在听 and 听完 for audiobooks.
private enum StatusShelf: CaseIterable {
    case books, audio

    var name: String {
        switch self {
        case .books: String(localized: "书")
        case .audio: String(localized: "有声书")
        }
    }

    func holds(_ book: BookSummary, in library: Library) -> Bool {
        switch self {
        case .books: !library.hasAudio(book)
        case .audio: library.hasAudio(book)
        }
    }

    /// The status in this shelf's words, as its header says it on the right.
    func verb(_ status: ReadingStatus) -> String {
        switch (status, self) {
        case (.reading, .audio): String(localized: "在听")
        case (.reading, _): String(localized: "在读")
        case (.want, .audio): String(localized: "想听")
        case (.want, _): String(localized: "想读")
        case (.finished, .audio): String(localized: "听完")
        case (.finished, _): String(localized: "读完")
        }
    }
}

/// 首页导航 · A: the shelf window is a desk a shade darker than the page, the sidebar written on
/// it, and the page a sheet of paper lying on it.
enum ShelfDesk {
    static let fill = Color.yyDynamic(light: YYRGBA(234, 232, 227), dark: YYRGBA(12, 12, 13))
    /// The row being shown: a faint wash, not a white card (white is for what's on the paper).
    static let on = Color.yyDynamic(light: YYRGBA(42, 43, 46, 0.07), dark: YYRGBA(255, 255, 255, 0.08))
    /// 搜索 · 问 on the desk: darker than the desk, as the page's own fields are than the page.
    static let field = Color.yyDynamic(light: YYRGBA(0, 0, 0, 0.05), dark: YYRGBA(255, 255, 255, 0.06))
    static let margin: CGFloat = 8
    static let paperRadius: CGFloat = 12

    /// The paper: the page's colour, a hairline edge and a soft shadow under it.
    struct Paper: View {
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: ShelfDesk.paperRadius)
            // The hairline is `box-shadow: 0 0 0 .5px`: just outside the paper, over the desk, so
            // the edge reads crisp. Drawn inside it fell on the paper and all but vanished.
            let ring = shape.inset(by: -0.25)
            if scheme == .dark {
                shape.fill(YYColor.bg)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
                    .overlay(ring.stroke(.white.opacity(0.07), lineWidth: 0.5))
            } else {
                shape.fill(YYColor.bg)
                    .shadow(color: Color(yy: YYRGBA(51, 46, 41, 0.06)), radius: 12, y: 8)
                    .shadow(color: Color(yy: YYRGBA(51, 46, 41, 0.06)), radius: 1.5, y: 1)
                    .overlay(ring.stroke(.black.opacity(0.07), lineWidth: 0.5))
            }
        }
    }
}

/// `.v-mac-it`: an icon in grey, the name, the count on the right. The row being shown is a
/// white card; a collection with a book dragged over it lights up in the accent.
/// `.v-mac-gt`, which folds its group away: a click on it, or on the arrow that shows while the
/// pointer is over it (as in 访达).
private struct SidebarGroupTitle: View {
    let title: String
    let closed: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.yy(size: 10.5, weight: .semibold))
                    .foregroundStyle(YYColor.t3)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.yy(size: 9, weight: .semibold))
                    .foregroundStyle(YYColor.t3)
                    .rotationEffect(.degrees(closed ? 0 : 90))
                    .opacity(hover || closed ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(closed ? String(localized: "已收起") : String(localized: "已展开"))
        .help(closed ? String(localized: "展开") : String(localized: "收起"))
    }
}

private struct SidebarRow<Title: View>: View {
    let symbol: String
    var count: Int?
    /// In place of the count: “14 ›”.
    var trailing: String?
    var on = false
    var drop = false
    var tint = YYTint.standard
    var color: Color?
    @ViewBuilder let title: Title
    @Environment(\.sidebarSelection) private var selection

    var body: some View {
        HStack(spacing: 8) {
            // `.v-mac-it svg`: every icon in the same 14 × 14 box, wide ones too.
            Group {
                if let drawn = ProtoIcon(rawValue: symbol) {
                    drawn.shape.stroke(style: StrokeStyle(lineWidth: drawn.line, lineCap: .round, lineJoin: .round))
                } else if symbol.hasPrefix("asset.") {
                    // 全部 (the phone's 书架 tab icon): an SVG in the asset catalogue.
                    Image(String(symbol.dropFirst(6))).resizable().renderingMode(.template).scaledToFit()
                } else {
                    Image(systemName: symbol).resizable().scaledToFit()
                }
            }
            .frame(width: 14, height: 14)
            .foregroundStyle(drop ? tint.accent : color ?? (on ? YYColor.t1 : YYColor.t2))
            title
                .font(.yy(size: 12, weight: on || drop ? .semibold : .regular))
                .foregroundStyle(drop ? tint.accent : color ?? YYColor.t1)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let text = trailing ?? count?.formatted() {
                Text(text)
                    .font(.yy(size: 10.5).monospacedDigit())
                    .foregroundStyle(drop ? tint.accent : YYColor.t3)
                    // M3: a count rolls when a book comes or goes.
                    .contentTransition(.numericText(value: Double(count ?? 0)))
                    .animation(YYMotion.standard, value: count)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background {
            if drop {
                RoundedRectangle(cornerRadius: 8).fill(tint.accentSoft)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.accent, lineWidth: 1.5))
            } else if on {
                // One white shape for the whole sidebar, so a new choice slides it there (M1).
                if let selection {
                    RoundedRectangle(cornerRadius: 8).fill(ShelfDesk.on)
                        .matchedGeometryEffect(id: "selection", in: selection)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(ShelfDesk.on)
                }
            }
        }
        .contentShape(.rect)
    }
}

private struct SidebarSelectionKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// The sidebar's selection, shared by its rows so it slides between them.
    var sidebarSelection: Namespace.ID? {
        get { self[SidebarSelectionKey.self] }
        set { self[SidebarSelectionKey.self] = newValue }
    }
}

/// 编辑信息 (prototype 书的信息): the cover and 换封面, the title and author the shelf shows.
struct EditInfoSheet: View {
    let library: Library
    let book: BookSummary
    @State private var title: String
    @State private var author: String
    @Environment(\.dismiss) private var dismiss

    init(library: Library, book: BookSummary) {
        self.library = library
        self.book = book
        _title = State(initialValue: book.title)
        _author = State(initialValue: book.authors.joined(separator: "、"))
    }

    private var current: BookSummary { library.books.first { $0.id == book.id } ?? book }

    var body: some View {
        VStack(alignment: .leading, spacing: YYUI.s(12)) {
            YYSheetHeader(title: String(localized: "编辑信息")) { dismiss() }
            VStack(spacing: YYUI.s(8)) {
                BookCover(book: current)
                    .frame(width: YYUI.s(58))
                    .shadow(color: Color(yy: YYRGBA(30, 30, 30, 0.16)), radius: YYUI.s(6), y: YYUI.s(4))
                Button("换封面", action: pickCover)
                    .buttonStyle(.plain)
                    .font(YYUI.font(11, .semibold))
                    .foregroundStyle(YYTint.standard.accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, YYUI.s(4))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, let data = try? Data(contentsOf: url) else { return false }
                library.setCover(current, image: data)
                return true
            }
            YYGroup {
                YYField(label: String(localized: "书名"), labelWidth: 44) {
                    TextField("", text: $title, prompt: Text("留空就用文件里的")).textFieldStyle(.plain)
                }
                YYField(label: String(localized: "作者"), labelWidth: 44) {
                    TextField("", text: $author, prompt: Text("几位作者用顿号隔开")).textFieldStyle(.plain)
                }
            }
            .foregroundStyle(YYColor.t1)
            YYNote(String(localized: "只改书架上显示的名字，书的文件不动。封面也可以直接拖一张图到上面。"))
                .padding(.top, -YYUI.s(6))
            Button("好") {
                let authors = author.split(whereSeparator: { "、,，;；/".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
                if title != book.title || authors != book.authors {
                    library.editInfo(book, title: title, authors: authors)
                }
                dismiss()
            }
            .buttonStyle(YYButtonStyle(kind: .main, size: .large, wide: true))
            .keyboardShortcut(.defaultAction)
        }
        .padding(YYUI.s(16))
        .frame(width: 360)
        .background(YYColor.bg)
    }

    private func pickCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = String(localized: "用作封面")
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        library.setCover(current, image: data)
    }
}
#endif

enum ShelfSort: CaseIterable {
    case recent, added, title, author

    var name: String {
        switch self {
        case .recent: String(localized: "最近读过")
        case .added: String(localized: "加入时间")
        case .title: String(localized: "书名")
        case .author: String(localized: "作者")
        }
    }

    func sorted(_ books: [BookSummary]) -> [BookSummary] {
        switch self {
        case .recent: books
        case .added: books.sorted { $0.addedAt > $1.addedAt }
        case .title: books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author: books.sorted { ($0.author ?? "").localizedStandardCompare($1.author ?? "") == .orderedAscending }
        }
    }
}

/// A book being read: cover, how far, and buttons to read or listen on.
struct ReadingCard: View {
    let book: BookSummary
    let listening: Bool
    let open: (Library.OpenIntent?) -> Void
    @Environment(\.colorScheme) private var scheme
    private let tint = YYTint.standard
    #if os(macOS)
    /// The cover's own colour, which the card is dyed in.
    @State private var hue: CoverHue?
    @AppStorage(EInk.key) private var eink = false
    #endif

    var body: some View {
        #if os(macOS)
        macBody
        #else
        phoneBody
        #endif
    }

    #if os(macOS)
    /// 封面色 + 进度按钮 · 底线 (docs/design/在读卡片按钮.html · F): the card in its cover's colour,
    /// the progress line grown into the 接着读 bar, drawn along its bottom edge; 听 a square beside it.
    private var macBody: some View {
        let colors = (hue ?? .paper).card(dark: scheme == .dark, grey: eink)
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                BookCover(book: book)
                    .frame(width: 36)
                    .onTapGesture { open(nil) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.yy(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(meta)
                        .font(.yy(size: 10.5))
                        .opacity(0.62)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                Button { open(audio ? .listen : nil) } label: {
                    HStack {
                        if audio, listening {
                            Image(systemName: "waveform").symbolEffect(.variableColor.iterative, options: .repeating)
                                .font(.yy(size: 11.5, weight: .semibold))
                        }
                        Text(audio ? (listening ? String(localized: "正在听") : String(localized: "接着听")) : String(localized: "接着读")).font(.yy(size: 11.5, weight: .semibold))
                        Spacer(minLength: 8)
                        Text(book.percent).font(.yy(size: 11.5, weight: .medium)).monospacedDigit().opacity(0.7)
                            // M3: the number rolls to the next one.
                            .contentTransition(.numericText(value: book.progress))
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(colors.fg.opacity(0.13))
                    .overlay(alignment: .bottomLeading) {
                        // I1: a faint track the whole length, and the line never shorter than 10, so
                        // 1% still reads as begun.
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(colors.fg.opacity(0.08))
                                UnevenRoundedRectangle(bottomTrailingRadius: 1.5, topTrailingRadius: 1.5)
                                    .fill(colors.fg)
                                    .frame(width: min(g.size.width, max(10, g.size.width * book.progress)))
                            }
                            .frame(height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                    .animation(YYMotion.standard, value: book.progress)
                    .clipShape(.rect(cornerRadius: 9))
                    .contentShape(.rect(cornerRadius: 9))
                }
                .buttonStyle(CardPress())
                if !audio { listenButton(colors) }
            }
        }
        .foregroundStyle(colors.fg)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: YYRadius.block)
                .fill(colors.bg)
                .overlay(LinearGradient(colors: [.white.opacity(0.12), .clear], startPoint: .topLeading, endPoint: .center).clipShape(.rect(cornerRadius: YYRadius.block)))
        }
        .animation(.easeOut(duration: 0.25), value: hue)
        .task(id: book.coverPath) {
            hue = await CoverHue.load(book.coverPath)
        }
    }

    private func listenButton(_ colors: (bg: Color, fg: Color)) -> some View {
        Button { open(listening ? nil : .listen) } label: {
            // M4: one image, the headphones turning into the moving wave and back.
            Image(systemName: listening ? "waveform" : "headphones")
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: listening)
            .font(.yy(size: 13, weight: .medium))
            .foregroundStyle(listening ? colors.bg : colors.fg)
            .frame(width: 32, height: 32)
            .background(listening ? colors.fg : colors.fg.opacity(0.13), in: .rect(cornerRadius: 9))
            .contentShape(.rect(cornerRadius: 9))
            .animation(YYMotion.quick, value: listening)
        }
        .buttonStyle(CardPress())
        .help(listening ? String(localized: "听中") : String(localized: "听"))
        .accessibilityLabel(listening ? String(localized: "听中") : String(localized: "听"))
    }
    #endif

    private var phoneBody: some View {
        HStack(alignment: .top, spacing: 12) {
            BookCover(book: book)
                .frame(width: 44)
                .onTapGesture { open(nil) }
            VStack(alignment: .leading, spacing: 0) {
                Text(book.title)
                    .font(.yy(size: 12.5, weight: .semibold))
                    .foregroundStyle(YYColor.t1)
                    .lineLimit(1)
                    .padding(.bottom, 3)
                Text(meta)
                    .font(.yy(size: 10.5))
                    .foregroundStyle(YYColor.t3)
                    .lineLimit(1)
                    .padding(.bottom, 8)
                ProgressLine(value: book.progress)
                    .padding(.bottom, 10)
                HStack(spacing: 6) {
                    // 有声书 has only 接着听, moving while it plays.
                    if audio, listening {
                        pill(String(localized: "正在听"), symbol: "waveform", fill: tint.accentSoft, text: tint.accent) { open(nil) }
                    } else if audio {
                        pill(String(localized: "接着听"), fill: tint.black, text: tint.onBlack) { open(.listen) }
                    } else {
                        pill(String(localized: "接着读"), fill: tint.black, text: tint.onBlack) { open(nil) }
                        if listening {
                            pill(String(localized: "听中"), symbol: "waveform", fill: tint.accentSoft, text: tint.accent) { open(nil) }
                        } else {
                            pill(String(localized: "听"), fill: YYColor.inset, text: YYColor.t1) { open(.listen) }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YYColor.card, in: .rect(cornerRadius: YYRadius.block))
        .yyShadow(scheme == .dark ? YYShadow.ringDark : YYShadow.ringLight)
    }

    private var audio: Bool { book.format == .audio }

    private var meta: String {
        if book.format == .pdf, book.page > 0 { return [book.author, String(localized: "第 \(book.page) 页"), book.percent].compactMap { $0 }.joined(separator: " · ") }
        // The percentage is on 接着读 already; here, how long is left.
        return [book.author, book.remaining, listening ? String(localized: "听中") : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private func pill(_ title: String, symbol: String? = nil, fill: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).symbolEffect(.variableColor.iterative, options: .repeating)
                }
                Text(title).fixedSize()
            }
            .font(.yy(size: 11.5, weight: .medium))
            .foregroundStyle(text)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(fill, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

#if os(macOS)
/// A 在读 card's buttons: a little lighter on hover, a little smaller while pressed.
private struct CardPress: ButtonStyle {
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(hover ? 0.03 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}

/// The colour of a cover, averaged, and the card and ink a 在读 card takes from it.
struct CoverHue: Equatable {
    var hue: Double
    var saturation: Double
    var brightness: Double

    /// No cover: the 纸本 paper the placeholder is drawn on.
    static let paper = CoverHue(hue: 0.11, saturation: 0.1, brightness: 0.93)

    /// A light cover gives a pale card with dark ink in its hue; a dark one stays dark with pale ink.
    /// In dark mode every card is dark. Greys get a touch of warmth so they don't read as blank.
    func card(dark: Bool, grey: Bool) -> (bg: Color, fg: Color) {
        let s = grey ? 0 : max(saturation, 0.06)
        // I3: the shelf is warm grey paper; a card may take a cover's hue but never be louder than
        // the shelf around it. Cool hues (green through violet) stand out more, so they're kept
        // paler still.
        let cool = hue > 0.2 && hue < 0.9
        let k = cool ? 0.6 : 1.0
        if dark {
            return (Color(hue: hue, saturation: min(s, 0.32 * k), brightness: 0.22),
                    Color(hue: hue, saturation: min(s, 0.12), brightness: 0.94))
        }
        if brightness > 0.55 {
            return (Color(hue: hue, saturation: min(s, 0.16 * k), brightness: 0.91),
                    Color(hue: hue, saturation: min(max(s, 0.2), 0.45 * k), brightness: 0.24))
        }
        return (Color(hue: hue, saturation: min(s, 0.45 * k), brightness: min(max(brightness, 0.22), 0.36)),
                Color(hue: hue, saturation: min(s, 0.15), brightness: 0.96))
    }

    /// The cover drawn down to one pixel, off the main thread.
    @concurrent nonisolated static func load(_ path: String?) async -> CoverHue? {
        guard let image = await Thumbnail.load(path, maxPixels: 48) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let color = NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        return CoverHue(hue: color.hueComponent, saturation: color.saturationComponent, brightness: color.brightnessComponent)
    }
}
#endif

extension Notification.Name {
    /// 显示或收起侧栏 from the menu bar (⌘⌥N) while the shelf window is in front.
    static let toggleShelfSidebar = Notification.Name("yuyue.toggleShelfSidebar")
}

/// 显示侧栏 / 隐藏侧栏: a small plain icon, the page's grey, a pad under it on hover and while the
/// sidebar is away, as the window's buttons are small and quiet beside it.
private struct SidebarToggle: View {
    let shown: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.yy(size: 12.5, weight: .regular))
                .foregroundStyle(hover ? YYColor.t1 : YYColor.t2)
                .frame(width: 28, height: 22)
                .background(hover ? YYColor.inset : .clear, in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(shown ? String(localized: "隐藏侧栏 ⌘⌥N") : String(localized: "显示侧栏 ⌘⌥N"))
        .accessibilityLabel(shown ? String(localized: "隐藏侧栏") : String(localized: "显示侧栏"))
    }
}

/// The prototype's own icons where no system one matches, drawn as its SVGs are (16 × 16, lines).
nonisolated enum ProtoIcon: String {
    /// `#i-wavef`: 有声.
    case wave = "proto.wave"
    /// 书: a closed book, a bookmark ribbon hanging from its top (待定方案 7 · A).
    case book = "proto.book"

    var shape: some Shape { ProtoShape(icon: self) }

    /// The line at the sidebar's 14 points, matched by eye to the system icons beside it.
    var line: CGFloat {
        switch self {
        case .wave: 1.6
        case .book: 1.3
        }
    }
}

nonisolated struct ProtoShape: Shape {
    let icon: ProtoIcon

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch icon {
        case .wave:
            // M2 8h.5 M4.5 5.5v5 M7 3v10 M9.5 5v6 M12 6.5v3 M14 8h.01
            p.move(to: CGPoint(x: 2, y: 8)); p.addLine(to: CGPoint(x: 2.5, y: 8))
            for (x, y0, y1) in [(4.5, 5.5, 10.5), (7.0, 3.0, 13.0), (9.5, 5.0, 11.0), (12.0, 6.5, 9.5)] {
                p.move(to: CGPoint(x: x, y: y0)); p.addLine(to: CGPoint(x: x, y: y1))
            }
            p.move(to: CGPoint(x: 14, y: 8)); p.addLine(to: CGPoint(x: 14.01, y: 8))
        case .book:
            // In a 24 box: M6 3.5h11a1 1 0 0 1 1 1v15a1 1 0 0 1-1 1H6.5A1.5 1.5 0 0 1 5 19V5
            // a1.5 1.5 0 0 1 1-1.5z M5 17.5h13 M14 3.5v7l-1.75-1.4L10.5 10.5v-7
            var b = Path()
            b.move(to: CGPoint(x: 6.5, y: 3.5))
            b.addLine(to: CGPoint(x: 17, y: 3.5))
            b.addQuadCurve(to: CGPoint(x: 18, y: 4.5), control: CGPoint(x: 18, y: 3.5))
            b.addLine(to: CGPoint(x: 18, y: 19.5))
            b.addQuadCurve(to: CGPoint(x: 17, y: 20.5), control: CGPoint(x: 18, y: 20.5))
            b.addLine(to: CGPoint(x: 6.5, y: 20.5))
            b.addQuadCurve(to: CGPoint(x: 5, y: 19), control: CGPoint(x: 5, y: 20.5))
            b.addLine(to: CGPoint(x: 5, y: 5))
            b.addQuadCurve(to: CGPoint(x: 6.5, y: 3.5), control: CGPoint(x: 5, y: 3.5))
            b.closeSubpath()
            b.move(to: CGPoint(x: 5, y: 17.5)); b.addLine(to: CGPoint(x: 18, y: 17.5))
            b.move(to: CGPoint(x: 14, y: 3.5)); b.addLine(to: CGPoint(x: 14, y: 10.5))
            b.addLine(to: CGPoint(x: 12.25, y: 9.1)); b.addLine(to: CGPoint(x: 10.5, y: 10.5))
            b.addLine(to: CGPoint(x: 10.5, y: 3.5))
            // Its 13 × 17 body centred and filling the 16 box, as tall as the icons beside it.
            p.addPath(b.applying(CGAffineTransform(translationX: 8, y: 8).scaledBy(x: 16 / 18.5, y: 16 / 18.5).translatedBy(x: -11.5, y: -12)))
        }
        return p.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: rect.width / 16, y: rect.height / 16))
    }
}
