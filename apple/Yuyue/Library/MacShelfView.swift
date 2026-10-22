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
    @State private var naming = false
    @State private var newName = ""
    @State private var renaming: String?
    @State private var dropCollection: String?
    @FocusState private var nameFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var scheme

    private struct OpenMenu: Equatable {
        let book: String
        let at: CGPoint
    }

    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    @AppStorage("general.reopenLast") private var reopenLast = false
    @State private var reopened = false
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    var body: some View {
        // `.v-mac-sb`: the sidebar floats in the window, 8 in from its edges, and the page starts
        // beside it at 228.
        HStack(spacing: 0) {
            sidebar
                .frame(width: 212)
                .padding(8)
                .ignoresSafeArea(.container, edges: .top)
            Group {
                switch filter {
                case .notes: MacNotesView(library: library)
                case .words: MacWordsView(library: library)
                default: main
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(YYColor.bg)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // `.v-mac-sb .v-lights`: inside the sidebar card, 24 in from the window's corner. They
        // sit lower than a plain title bar reaches, and a button outside it can't be clicked: an
        // empty toolbar makes the bar tall enough.
        .toolbar {
            ToolbarItem { Color.clear.frame(width: 1, height: 1) }
                .withoutGlass()
        }
        .trafficLights(CGPoint(x: 30, y: 30))
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
            case "comics": filter = .comics
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
            // `-debugImport <file>|<file>` imports them as 导入 would; `-debugOpen 红楼` opens the first book
            // whose title has that in it.
            Task {
                if let path = UserDefaults.standard.string(forKey: "debugImport") { await library.importFiles(path.split(separator: "|").map { URL(filePath: String($0)) }) }
                // `-debugAudiobook 1` shows the first 有声书's page; `-debugAudiobook remake` makes it again.
                if let what = UserDefaults.standard.string(forKey: "debugAudiobook"), let a = library.audiobooks.all.first {
                    if what == "remake", let book = library.books.first(where: { $0.id == a.book }) { library.audiobooks.make(a, with: book) } else { library.audiobooks.showing = a.id }
                }
                if let title = UserDefaults.standard.string(forKey: "debugOpen"), let book = library.books.first(where: { $0.title.contains(title) }) {
                    openWindow(id: "reader", value: book.id)
                }
            }
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

    /// The list, then 同步 under a line: below it, not over it, so a long list of 合集 stops at
    /// the line instead of running under.
    /// `.v-mac-sb`: a card a shade off white, the window's buttons in its top corner, 同步 at
    /// its foot under a line. The list scrolls above the line rather than under it.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window's own buttons sit here.
            Color.clear.frame(height: 14)
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
        .background {
            // On the shape alone, so the rows inside don't each cast one.
            RoundedRectangle(cornerRadius: 14).fill(SidebarPanel.fill)
                .yyShadow(scheme == .dark ? YYShadow.ringDark : YYShadow.ringLight)
        }
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand(perform: moveFilter)
    }

    /// `.v-mac-sch`
    private var searchField: some View {
        Button { quick = "" } label: {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11.5))
                Text("搜索 · 问").font(.system(size: 12))
                Spacer()
                Text("⌘K").font(.system(size: 10.5)).foregroundStyle(YYColor.t3)
            }
            .foregroundStyle(YYColor.t2)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(YYColor.inset, in: .rect(cornerRadius: 9))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var sidebarList: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarGroup(String(localized: "资料库"))
            sidebarRow(.all, String(localized: "全部"), "square.stack.3d.up", library.books.count)
            sidebarRow(.books, String(localized: "书"), "book.closed", library.books.count { !$0.isComic })
            sidebarRow(.comics, String(localized: "漫画"), "rectangle.split.2x2", library.books.count(where: \.isComic))
            sidebarRow(.audio, String(localized: "有声"), "waveform", library.books.count(where: library.hasAudio))
            sidebarGroup(String(localized: "状态"))
            ForEach([ReadingStatus.reading, .want, .finished], id: \.self) { status in
                sidebarRow(.status(status), status.name, status.symbol, library.books.count { $0.status == status })
            }
            sidebarGroup(String(localized: "笔记"))
            sidebarRow(.notes, String(localized: "笔记"), "quote.opening", noteCount)
            sidebarRow(.words, String(localized: "生词本"), "translate", wordCount)
            sidebarGroup(String(localized: "合集"))
            ForEach(library.collections, id: \.id) { c in
                collectionRow(c)
            }
            if naming {
                SidebarRow(symbol: CollectionIcon.guess(for: newName) ?? CollectionIcon.fallback) {
                    TextField("合集的名字", text: $newName)
                        .textFieldStyle(.plain)
                        .focused($nameFocused)
                        .onSubmit(finishNaming)
                        .onExitCommand { naming = false }
                }
                .onChange(of: nameFocused) { if !nameFocused { finishNaming() } }
            }
            Button {
                newName = ""
                naming = true
                nameFocused = true
            } label: {
                SidebarRow(symbol: "plus", color: tint.accent) { Text("新建合集") }
                    .foregroundStyle(tint.accent)
            }
            .buttonStyle(.plain)
        }
    }

    /// `.v-mac-gt`
    private func sidebarGroup(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(YYColor.t3)
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
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
        [.all, .books, .comics, .audio, .status(.reading), .status(.want), .status(.finished), .notes, .words]
            + library.collections.map { .collection($0.id) }
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
                    .font(.system(size: 11))
                    .foregroundStyle(YYColor.t2)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let devices {
                    Text(devices).font(.system(size: 10)).foregroundStyle(YYColor.t3)
                }
            }
            .padding(8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(YYColor.line).frame(height: 0.5) }
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
            for id in ids where library.books.contains(where: { $0.id == id }) {
                library.setBook(id, in: c.id, true)
            }
        })
        .contextMenu {
            Button("重命名") {
                newName = c.name
                renaming = c.id
                nameFocused = true
            }
            Button("删除合集", role: .destructive) {
                if filter == .collection(c.id) { filter = .all }
                library.deleteCollection(c)
            }
        }
    }

    private func finishNaming() {
        guard naming else { return }
        naming = false
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let id = library.createCollection(name) else { return }
        filter = .collection(id)
    }

    private func finishRenaming(_ c: BookCollection) {
        guard renaming == c.id else { return }
        renaming = nil
        let name = newName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != c.name { library.renameCollection(c.id, to: name) }
    }

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
        case .comics: return String(localized: "漫画")
        case .audio: return String(localized: "有声")
        case .status(let s): return s.name
        case .collection(let id): return library.collections.first { $0.id == id }?.name ?? String(localized: "合集")
        case .notes: return String(localized: "笔记")
        case .words: return String(localized: "生词本")
        }
    }

    private var shown: [BookSummary] {
        var books = library.books
        switch filter ?? .all {
        case .all: break
        case .books: books = books.filter { !$0.isComic }
        case .comics: books = books.filter(\.isComic)
        case .audio: books = books.filter(library.hasAudio)
        case .status(let s): books = books.filter { $0.status == s }
        case .collection(let id): books = books.filter { $0.collections.contains(id) }
        case .notes, .words: break
        }
        return sort.sorted(books)
    }

    private var reading: [BookSummary] {
        guard filter == .all || filter == .books || filter == .comics || filter == .audio else { return [] }
        let comics = filter == .comics, all = filter == .all, audio = filter == .audio
        return Array(library.books.filter { b in
            b.status == .reading && (all || (audio ? library.hasAudio(b) : b.isComic == comics))
        }.prefix(3))
    }

    /// 设置 · 外观 · 书架封面大小 and 封面下面写进度.
    @AppStorage("shelf.coverSize") private var coverSize = 100.0
    @AppStorage("shelf.showProgress") private var showProgress = true

    /// `.v-mac-g`: at the default size a 1040-wide window holds eight covers about 80 wide. The
    /// covers are sized from the window, room for a scroller always left: sized from inside the
    /// scroller, two rows that just fit grow taller without it, need it again, and never settle.
    /// The room left is generous and the width rounded down: with scrollers always shown, a grid
    /// even a point too wide widens the window's column, which widens the grid, without end.
    private var columns: [GridItem] {
        let room = max(0, mainFrame.width - 48 - 24)
        let count = max(1, Int((room + 18) / (coverSize - 24 + 18)))
        let width = max(1, ((room - 18 * CGFloat(count - 1)) / CGFloat(count)).rounded(.down))
        return Array(repeating: GridItem(.fixed(width), spacing: 18, alignment: .top), count: count)
    }

    private var main: some View {
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(YYColor.t1)
                        .lineLimit(1)
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
                    sectionHeader(String(localized: "在读"), trailing: filter == .comics
                        ? String(localized: "\(library.books.count { $0.status == .reading && $0.isComic }) 部")
                        : String(localized: "\(library.books.count { $0.status == .reading && (filter == .all || !$0.isComic) }) 本"))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                        ForEach(reading) { book in
                            ReadingCard(book: book, listening: library.listening == book.id) { intent in
                                open(book, intent)
                            }
                            .overlay(RightClickCatcher { showMenu(for: book, at: $0) })
                        }
                    }
                    .padding(.bottom, 28)
                }

                let books = shown
                HStack {
                    Text(filter == .comics ? String(localized: "\(books.count) 部") : String(localized: "\(books.count) 本"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(YYColor.t1)
                    Spacer()
                    sortMenu
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 14)

                if books.isEmpty {
                    empty
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(books) { book in
                            cell(book).id(book.id)
                        }
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
        .overlay(alignment: .bottom) { toast }
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
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    Text("导入")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(YYColor.t1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(YYColor.card, in: .capsule)
            .overlay(Capsule().strokeBorder(YYColor.line, lineWidth: 0.5))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("o")
        .help("导入书或漫画（⌘O）：EPUB、PDF、MOBI、AZW3、TXT，漫画的 CBZ、CBR、ZIP，或一文件夹图片；也可以直接拖进窗口")
    }

    private func sectionHeader(_ text: String, trailing: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(YYColor.t1)
            Spacer()
            Text(trailing)
                .font(.system(size: 11))
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
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11.5))
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
            ("books.vertical", String(localized: "书架是空的，把 EPUB、PDF、MOBI、TXT 或漫画拖进窗口就能开始读"))
        } else if currentCollection != nil {
            ("tray", String(localized: "还没有书。把书拖到左边这个合集上，或者把文件拖进来"))
        } else {
            ("book.closed", String(localized: "这里还没有书"))
        }
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(YYColor.t3)
            Text(text).font(.system(size: 12.5)).foregroundStyle(YYColor.t2)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private func cell(_ book: BookSummary) -> some View {
        Button { open(book, nil) } label: {
            VStack(alignment: .leading, spacing: 0) {
                BookCover(book: book)
                    .comicStack(book)
                    .opacity(book.available ? 1 : 0.45)
                    .overlay {
                        if revealed == book.id {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(tint.accent, lineWidth: 2.5).padding(-4)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !book.available {
                            Image(systemName: "icloud.and.arrow.down")
                                .font(.system(size: 11, weight: .semibold))
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
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(YYColor.t1)
                    .lineLimit(1)
                    .padding(.bottom, 2)
                if showProgress { note(book) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
                .font(.system(size: 10.5))
                .foregroundStyle(tint.accent)
        } else {
            Text(library.shelfNote(book))
                .font(.system(size: 10.5))
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
                .frame(width: 360)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
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

/// `.v-mac-sb`'s fill: the card colour, 55% of it over the window's.
enum SidebarPanel {
    static let fill = Color.yyDynamic(light: YYRGBA(251, 250, 249), dark: YYRGBA(22, 23, 25))
}

/// `.v-mac-it`: an icon in grey, the name, the count on the right. The row being shown is a
/// white card; a collection with a book dragged over it lights up in the accent.
private struct SidebarRow<Title: View>: View {
    let symbol: String
    var count: Int?
    var on = false
    var drop = false
    var tint = YYTint.standard
    var color: Color?
    @ViewBuilder let title: Title
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            // `.v-mac-it svg`: every icon in the same 14 × 14 box, wide ones too.
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundStyle(drop ? tint.accent : color ?? (on ? YYColor.t1 : YYColor.t2))
            title
                .font(.system(size: 12, weight: on || drop ? .semibold : .regular))
                .foregroundStyle(drop ? tint.accent : color ?? YYColor.t1)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let count {
                Text(count.formatted())
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(drop ? tint.accent : YYColor.t3)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background {
            if drop {
                RoundedRectangle(cornerRadius: 8).fill(tint.accentSoft)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.accent, lineWidth: 1.5))
            } else if on {
                RoundedRectangle(cornerRadius: 8).fill(YYColor.card)
                    .shadow(color: scheme == .dark ? .clear : Color(yy: YYRGBA(51, 46, 41, 0.04)), radius: 1, y: 1)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(scheme == .dark ? Color(yy: YYRGBA(255, 255, 255, 0.06)) : YYColor.line, lineWidth: 0.5))
            }
        }
        .contentShape(.rect)
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BookCover(book: book)
                .frame(width: 44)
                .onTapGesture { open(nil) }
            VStack(alignment: .leading, spacing: 0) {
                Text(book.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(YYColor.t1)
                    .lineLimit(1)
                    .padding(.bottom, 3)
                Text(meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(YYColor.t3)
                    .lineLimit(1)
                    .padding(.bottom, 8)
                ProgressLine(value: book.progress)
                    .padding(.bottom, 10)
                HStack(spacing: 6) {
                    pill(book.isComic ? String(localized: "续看") : String(localized: "接着读"), fill: tint.black, text: tint.onBlack) { open(nil) }
                    if !book.canListen {
                    } else if listening {
                        pill(String(localized: "听中"), symbol: "waveform", fill: tint.accentSoft, text: tint.accent) { open(nil) }
                    } else {
                        pill(String(localized: "听"), fill: YYColor.inset, text: YYColor.t1) { open(.listen) }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YYColor.card, in: .rect(cornerRadius: YYRadius.block))
        .yyShadow(scheme == .dark ? YYShadow.ringDark : YYShadow.ringLight)
    }

    private var meta: String {
        if book.isComic { return book.comicPlace }
        if book.format == .pdf, book.page > 0 { return [book.author, String(localized: "第 \(book.page) 页"), book.percent].compactMap { $0 }.joined(separator: " · ") }
        return [book.author, book.percent, listening ? String(localized: "听中") : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private func pill(_ title: String, symbol: String? = nil, fill: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).symbolEffect(.variableColor.iterative, options: .repeating)
                }
                Text(title).fixedSize()
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(text)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(fill, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}
