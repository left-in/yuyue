#if os(iOS)
import SwiftUI
import YuyueCore

/// 书架 on the phone: the books being read across the top, to read or listen on at a tap; all
/// the books below, by kind and in an order. Tapping the title picks what the shelf shows: all,
/// a reading status or one of your 合集.
struct PhoneShelf: View {
    @Bindable var library: Library
    @State private var filter = ShelfFilter.all
    @AppStorage("shelf.sort") private var sortName = "recent"
    @State private var importerShown = false
    @State private var importShown = false
    @State private var wifiShown = false
    @State private var remoteShown = false
    @State private var watchShown = false
    @State private var choosing = false
    @State private var editing: BookSummary?
    @State private var picking: BookSummary?
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @AppStorage("shelf.showProgress") private var showProgress = true
    private let tint = YYTint.standard

    private var sort: ShelfSort {
        get { ShelfSort.allCases.first { "\($0)" == sortName } ?? .recent }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    titleButton
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                    if !reading.isEmpty, !selecting {
                        readingRow.padding(.top, 18)
                    }
                    if library.books.isEmpty, filter == .all {
                        welcome
                    } else {
                        kinds
                            .padding(.horizontal, 20)
                            .padding(.top, 22)
                            .padding(.bottom, 14)
                    }
                    if library.books.isEmpty, filter == .all {
                    } else if shown.isEmpty {
                        empty
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
                            ForEach(shown) { book in cell(book) }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 24)
            }
            .background(YYColor.bg)
            .toolbar { toolbar }
            .toolbar(selecting ? .hidden : .automatic, for: .tabBar)
            .safeAreaInset(edge: .bottom) {
                if selecting { selectionBar }
            }
            .overlay(alignment: .bottom) { toast }
            .navigationDestination(isPresented: $wifiShown) { PhoneWifi(library: library) }
            .navigationDestination(isPresented: $remoteShown) { PhoneRemoteStart(library: library) }
            .navigationDestination(isPresented: $watchShown) { PhoneWatchedFolder(library: library) }
        }
        .sheet(isPresented: $importShown) {
            PhoneImportSheet(watching: library.watched.name) {
                importShown = false
                importerShown = true
            } overWifi: {
                importShown = false
                wifiShown = true
            } remote: {
                importShown = false
                remoteShown = true
            } watch: {
                importShown = false
                watchShown = true
            }
        }
        .fileImporter(isPresented: $importerShown, allowedContentTypes: Library.importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await library.importFiles(urls, into: currentCollection) }
            }
        }
        .sheet(isPresented: $choosing) {
            ShelfChooser(library: library, filter: $filter)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $editing) { book in
            PhoneBookInfo(library: library, book: book)
        }
        .sheet(item: $picking) { book in
            CollectionPicker(library: library, bookID: book.id) { picking = nil }
                .frame(maxWidth: .infinity)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(YYColor.bg)
        }
    }

    // MARK: What is shown

    private var currentCollection: String? {
        if case .collection(let id) = filter { id } else { nil }
    }

    private var title: String {
        switch filter {
        case .status(let s): s.name
        case .collection(let id): library.collections.first { $0.id == id }?.name ?? String(localized: "合集")
        default: String(localized: "书架")
        }
    }

    /// 全部 · 书 · 漫画 · 有声, within what the title picked.
    @State private var kind = Kind.all
    private enum Kind: CaseIterable { case all, books, comics, audio
        var name: String { switch self { case .all: String(localized: "全部"); case .books: String(localized: "书"); case .comics: String(localized: "漫画"); case .audio: String(localized: "有声") } }
    }

    private var shown: [BookSummary] {
        var books = library.books
        switch filter {
        case .status(let s): books = books.filter { $0.status == s }
        case .collection(let id): books = books.filter { $0.collections.contains(id) }
        default: break
        }
        switch kind {
        case .all: break
        case .books: books = books.filter { !$0.isComic }
        case .comics: books = books.filter(\.isComic)
        case .audio: books = books.filter(library.hasAudio)
        }
        return sort.sorted(books)
    }

    private var reading: [BookSummary] {
        guard filter == .all else { return [] }
        return library.books.filter { b in
            guard b.status == .reading else { return false }
            return switch kind {
            case .all: true
            case .books: !b.isComic
            case .comics: b.isComic
            case .audio: library.hasAudio(b)
            }
        }
    }

    // MARK: Top

    private var titleButton: some View {
        Button { choosing = true } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(YYColor.t1)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(YYColor.t3)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，换一个看")
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(selected.count == shown.count ? String(localized: "全不选") : String(localized: "全选")) {
                    selected = selected.count == shown.count ? [] : Set(shown.map(\.id))
                }
            }
            ToolbarItem(placement: .principal) {
                Text(selected.isEmpty ? String(localized: "选择书") : String(localized: "已选 \(selected.count) 本")).font(.headline)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { stopSelecting() }.fontWeight(.semibold)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                if library.importing > 0 {
                    ProgressView()
                } else {
                    Button("导入", systemImage: "plus") { importShown = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("选择", systemImage: "checkmark.circle") { selecting = true }
                    .disabled(shown.isEmpty)
            }
        }
    }

    private var readingRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("在读").font(.subheadline.weight(.semibold)).foregroundStyle(YYColor.t1)
                Spacer()
                Text("\(reading.count) \(kind == .comics ? "部" : "本")").font(.footnote).foregroundStyle(YYColor.t3)
            }
            .padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(reading) { book in
                        ReadingCard(book: book, listening: library.listening == book.id || library.nowPlaying?.bookID == book.id) { intent in
                            open(book, intent)
                        }
                        .frame(width: 268)
                        .contextMenu { actions(for: book) } preview: { BookPreview(book: book) }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.never)
        }
    }

    private var kinds: some View {
        HStack(spacing: 8) {
            ForEach(Kind.allCases, id: \.self) { k in
                Button { kind = k } label: {
                    Text(k.name)
                        .font(.footnote.weight(kind == k ? .semibold : .regular))
                        .foregroundStyle(kind == k ? tint.onBlack : YYColor.t1)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(kind == k ? tint.black : YYColor.inset, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            Menu {
                Picker("排序", selection: $sortName) {
                    ForEach(ShelfSort.allCases, id: \.self) { Text($0.name).tag("\($0)") }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(sort.name)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .font(.footnote)
                .foregroundStyle(YYColor.t2)
            }
        }
    }

    /// `.v-lib-wel` (prototype 第一次打开): what this is and where things are kept, then the
    /// three ways to put books in.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("把书放进来，\n读或者听都行。")
                .font(YYUI.serif(YYUI.s(21), .bold))
                .tracking(YYUI.s(21) * 0.02)
                .lineSpacing(YYUI.s(21) * 0.5)
                .foregroundStyle(YYColor.t1)
            Text("不用注册。书、进度和笔记都存在你自己的设备里。")
                .font(YYUI.font(11)).lineSpacing(YYUI.s(11) * 0.7).foregroundStyle(YYColor.t2)
                .padding(.top, YYUI.s(6))
            HStack(alignment: .top, spacing: YYUI.s(8)) {
                way("folder", String(localized: "从文件导入"), String(localized: "本机或云盘里的")) { importerShown = true }
                way("wifi", String(localized: "Wi‑Fi 传书"), String(localized: "用电脑浏览器传")) { wifiShown = true }
                way("server.rack", String(localized: "远程书库"), "Calibre、NAS") { remoteShown = true }
            }
            .padding(.top, YYUI.s(16))
            .padding(.horizontal, -YYUI.s(4))
        }
        .padding(.horizontal, 20)
        .padding(.top, YYUI.s(14))
    }

    /// `.v-lib-imp > span`: a tile, then the name and a grey line.
    private func way(_ symbol: String, _ title: String, _ detail: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: YYUI.s(10)) {
                Image(systemName: symbol)
                    .font(YYUI.font(12, .medium))
                    .foregroundStyle(YYColor.t1)
                    .frame(width: YYUI.s(28), height: YYUI.s(28))
                    .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(8)))
                VStack(alignment: .leading, spacing: YYUI.s(2)) {
                    Text(title).font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1).lineLimit(1).minimumScaleFactor(0.8)
                    Text(detail).font(YYUI.font(10)).foregroundStyle(YYColor.t3).lineLimit(2)
                }
            }
            .padding(.horizontal, YYUI.s(10))
            .padding(.top, YYUI.s(12))
            .padding(.bottom, YYUI.s(11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .yyCard()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var empty: some View {
        let (symbol, text): (String, String) = if library.books.isEmpty {
            ("books.vertical", String(localized: "书架是空的。点右上角的加号，导入 EPUB、PDF、MOBI、TXT 或漫画"))
        } else if currentCollection != nil {
            ("tray", String(localized: "这个合集里还没有书。长按一本书，点「加入合集」"))
        } else {
            ("book.closed", String(localized: "这里还没有书"))
        }
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(YYColor.t3)
            Text(text).font(.subheadline).foregroundStyle(YYColor.t2).multilineTextAlignment(.center)
            if library.books.isEmpty {
                Button("导入书") { importerShown = true }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    // MARK: Books

    private func cell(_ book: BookSummary) -> some View {
        Button {
            if selecting {
                if selected.contains(book.id) { selected.remove(book.id) } else { selected.insert(book.id) }
            } else {
                open(book, nil)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                BookCover(book: book)
                    .comicStack(book)
                    .opacity(book.available ? 1 : 0.45)
                    .overlay(alignment: .bottomTrailing) {
                        if selecting {
                            Image(systemName: selected.contains(book.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22))
                                .foregroundStyle(selected.contains(book.id) ? tint.accent : .white)
                                .background(Circle().fill(selected.contains(book.id) ? .white : .black.opacity(0.25)).padding(2))
                                .padding(6)
                        } else if !book.available {
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
                    .padding(.bottom, 8)
                Text(book.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(YYColor.t1)
                    .lineLimit(1)
                    .padding(.bottom, 2)
                if showProgress { note(book) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !selecting { actions(for: book) }
        } preview: {
            BookPreview(book: book)
        }
        .accessibilityLabel("《\(book.title)》\(book.author.map { "，\($0)" } ?? "")，\(book.shelfNote)")
    }

    @ViewBuilder private func note(_ book: BookSummary) -> some View {
        if library.listening == book.id || library.nowPlaying?.bookID == book.id {
            Label("听中 · \(book.percent)", systemImage: "headphones")
                .labelStyle(TightLabel())
                .font(.caption2)
                .foregroundStyle(tint.accent)
        } else {
            Text(book.isComic && book.episode > 0 ? book.comicPlace : library.shelfNote(book))
                .font(.caption2)
                .foregroundStyle(YYColor.t3)
                .lineLimit(1)
        }
    }

    /// 长按: three common ones in a row (接着读 · 从头听 · 标为读完), then 编辑信息 · 加入合集 ·
    /// 删除, as confirmed in the design.
    @ViewBuilder private func actions(for book: BookSummary) -> some View {
        ControlGroup {
            Button(resumeTitle(book), systemImage: "book") { open(book, nil) }
            if book.canListen {
                Button("从头听", systemImage: "headphones") { open(book, .listenFromStart) }
            }
            Button(BookAction.toggleFinished.title(for: book), systemImage: BookAction.toggleFinished.symbol(for: book)) {
                library.setFinished(book, book.status != .finished)
            }
        }
        .controlGroupStyle(.compactMenu)
        if let recording = library.audiobooks.audiobook(for: book.id) {
            Button("有声书", systemImage: "waveform") { library.audiobooks.showing = recording.id }
        }
        Section {
            Button("编辑信息", systemImage: "pencil") { editing = book }
            Button("加入合集", systemImage: "tray.full") { picking = book }
            Button("删除", systemImage: "trash", role: .destructive) { library.delete(book) }
        }
    }

    /// 没读过的写"开始读"，读完的写"重读".
    private func resumeTitle(_ book: BookSummary) -> String {
        if book.status == .finished { return book.isComic ? String(localized: "重看") : String(localized: "重读") }
        return BookAction.resume.title(for: book)
    }

    private func open(_ book: BookSummary, _ intent: Library.OpenIntent?) {
        guard book.available else {
            library.note(icon: "icloud.and.arrow.down", String(localized: "《\(book.title)》在别的设备上"), String(localized: "把同一个文件导入这台手机，进度和笔记就接上了"))
            return
        }
        library.open(book, intent)
    }

    // MARK: 多选

    private var selectionBar: some View {
        let books = library.books.filter { selected.contains($0.id) }
        return HStack(spacing: 0) {
            barButton(String(localized: "标为读完"), "checkmark") {
                for book in books { library.setFinished(book, true) }
                stopSelecting()
            }
            barButton(String(localized: "删除"), "trash", danger: true) {
                for book in books { library.delete(book) }
                stopSelecting()
            }
        }
        .disabled(books.isEmpty)
        .padding(.horizontal, 8)
        .modifier(CapsuleGlass())
        .padding(.horizontal, 60)
        .padding(.bottom, 8)
    }

    private func barButton(_ title: String, _ symbol: String, danger: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 17))
                Text(title).font(.caption2)
            }
            .foregroundStyle(danger ? YYColor.danger : YYColor.t1)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func stopSelecting() {
        selecting = false
        selected = []
    }

    @ViewBuilder private var toast: some View {
        if let note = library.toast {
            UndoToast(toast: note, undo: { library.undo() })
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(note.id)
        }
    }
}

/// What floats up when a book is pressed: the cover a size smaller, the title, and how far —
/// a thin line and how long is left, not a percentage.
struct BookPreview: View {
    let book: BookSummary

    var body: some View {
        HStack(spacing: 12) {
            BookCover(book: book).frame(width: 44)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(book.title).font(.subheadline.weight(.semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                    if let author = book.author {
                        Text(author).font(.caption).foregroundStyle(YYColor.t3).lineLimit(1)
                    }
                }
                HStack(spacing: 10) {
                    if book.progress > 0, book.status != .finished {
                        ProgressLine(value: book.progress, height: 2.5)
                    }
                    Text(book.remaining)
                        .font(.caption)
                        .foregroundStyle(YYColor.t2)
                        .fixedSize()
                    if book.progress == 0 || book.status == .finished { Spacer(minLength: 0) }
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(YYColor.card)
    }
}

/// 看哪些书: all, a status the app keeps, or one of your 合集 — which can be named, renamed,
/// dragged into order and deleted here.
struct ShelfChooser: View {
    let library: Library
    @Binding var filter: ShelfFilter
    @Environment(\.dismiss) private var dismiss
    @State private var editMode = EditMode.inactive
    @State private var naming = false
    @State private var newName = ""
    @State private var renaming: BookCollection?
    private let tint = YYTint.standard

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(String(localized: "全部"), "square.stack.3d.up", library.books.count, .all)
                }
                Section {
                    ForEach([ReadingStatus.reading, .want, .finished], id: \.self) { status in
                        row(status.name, status.symbol, library.books.count { $0.status == status }, .status(status))
                    }
                } header: { groupLabel(String(localized: "按状态")) }
                Section {
                    ForEach(library.collections, id: \.id) { c in
                        row(c.name, CollectionIcon.symbol(for: c), Int(c.count), .collection(c.id))
                            .swipeActions {
                                Button("删除", role: .destructive) {
                                    if filter == .collection(c.id) { filter = .all }
                                    library.deleteCollection(c)
                                }
                                Button("重命名") {
                                    newName = c.name
                                    renaming = c
                                }
                                .tint(.gray)
                            }
                    }
                    .onMove { from, to in
                        var ids = library.collections.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        library.reorderCollections(ids)
                    }
                    Button {
                        newName = ""
                        naming = true
                    } label: {
                        HStack(spacing: YYUI.s(10)) {
                            Image(systemName: "plus").font(YYUI.font(13)).frame(width: YYUI.s(16))
                            Text("新建合集").font(YYUI.font(11.5, .semibold))
                        }
                        .foregroundStyle(tint.accent)
                    }
                } header: {
                    groupLabel(String(localized: "合集"))
                } footer: {
                    Text("点「编辑」后按住右边的把手拖动排序。一本书可以同时放进几个合集。")
                        .font(YYUI.font(10)).lineSpacing(YYUI.s(10) * 0.6).foregroundStyle(YYColor.t3)
                        .padding(.horizontal, -YYUI.s(12))
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(YYUI.s(14))
            .environment(\.defaultMinListRowHeight, YYUI.s(38))
            .scrollContentBackground(.hidden)
            .background(YYColor.bg)
            .environment(\.editMode, $editMode)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                // `.v-sh`: the title, 编辑 at the right.
                HStack {
                    Text("看哪些书").font(YYUI.font(14, .bold))
                    Spacer()
                    Button(editMode.isEditing ? String(localized: "完成") : String(localized: "编辑")) {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                    .buttonStyle(.plain)
                    .font(YYUI.font(12, .semibold))
                }
                .foregroundStyle(YYColor.t1)
                .padding(.horizontal, YYUI.s(20))
                .padding(.top, YYUI.s(22))
                .padding(.bottom, YYUI.s(4))
                .background(YYColor.bg)
            }
            .alert("新建合集", isPresented: $naming) {
                TextField("合集的名字", text: $newName)
                Button("取消", role: .cancel) {}
                Button("好") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, let id = library.createCollection(name) {
                        filter = .collection(id)
                        dismiss()
                    }
                }
            }
            .alert("重命名合集", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("合集的名字", text: $newName)
                Button("取消", role: .cancel) {}
                Button("好") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    if let c = renaming, !name.isEmpty, name != c.name { library.renameCollection(c.id, to: name) }
                }
            }
        }
    }

    private func row(_ name: String, _ symbol: String, _ count: Int, _ value: ShelfFilter) -> some View {
        let on = filter == value
        return Button {
            filter = value
            dismiss()
        } label: {
            HStack(spacing: YYUI.s(10)) {
                Image(systemName: symbol).font(YYUI.font(13)).foregroundStyle(YYColor.t2).frame(width: YYUI.s(16))
                Text(name).font(YYUI.font(11.5, on ? .semibold : .regular)).foregroundStyle(YYColor.t1).lineLimit(1)
                Spacer(minLength: YYUI.s(8))
                Text("\(count)").font(YYUI.font(10.5)).monospacedDigit().foregroundStyle(YYColor.t3)
                if on {
                    Image(systemName: "checkmark").font(YYUI.font(11, .bold)).foregroundStyle(tint.accent)
                        .padding(.leading, YYUI.s(4))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// `.gl`: the grey words over a group.
    private func groupLabel(_ text: String) -> some View {
        Text(text).font(YYUI.font(10)).foregroundStyle(YYColor.t3).textCase(nil)
            .padding(.horizontal, -YYUI.s(12))
    }
}
#endif
