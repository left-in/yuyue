#if os(iOS)
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import YuyueCore

/// One book's highlights, as 笔记 lists them.
struct NotedBook: Identifiable {
    let book: BookSummary
    let detail: BookDetail?
    let marks: [Mark]
    var id: String { book.id }
    var latest: Int64 { marks.map(\.at).max() ?? 0 }

    func chapter(of mark: Mark) -> String? {
        let c = detail?.chapterTitle(for: mark.section)
        return c == book.title ? nil : c
    }

    func quote(_ mark: Mark) -> QuoteShare {
        QuoteShare(text: mark.text, note: mark.note, title: book.title, author: book.author,
                   chapter: chapter(of: mark), coverPath: book.coverPath)
    }

    /// The marks in reading order, under their chapters.
    func chapters(_ marks: [Mark]) -> [(String, [Mark])] {
        var out: [(String, [Mark])] = []
        let sorted = marks.sorted {
            ($0.section, $0.start.sentence, $0.start.offset) < ($1.section, $1.start.sentence, $1.start.offset)
        }
        for m in sorted {
            let title = detail?.chapterTitle(for: m.section) ?? book.title
            if out.last?.0 == title { out[out.count - 1].1.append(m) } else { out.append((title, [m])) }
        }
        return out
    }

    static func load(_ library: Library, only ids: Set<String>? = nil) -> [NotedBook] {
        library.books.filter { $0.available && (ids?.contains($0.id) ?? true) }.compactMap { book in
            guard let marks = try? library.core.marks(book: book.id), !marks.isEmpty else { return nil }
            return NotedBook(book: book, detail: try? library.core.book(id: book.id), marks: marks)
        }
        .sorted { $0.latest > $1.latest }
    }

    /// For 发到 Obsidian, Notion, flomo.
    var export: NoteExport.Book {
        NoteExport.Book(id: book.id, title: book.title, author: book.author, chapters: chapters(marks))
    }

    /// Markdown of the books' notes, chapter by chapter.
    static func markdown(_ books: [NotedBook], title: String) -> String {
        var out = "# \(title)\n"
        let one = books.count == 1
        for n in books {
            if !one { out += "\n## 《\(n.book.title)》\n" }
            for (chapter, marks) in n.chapters(n.marks) {
                out += "\n\(one ? "##" : "###") \(chapter)\n"
                for m in marks {
                    out += "\n> \(m.text)\n"
                    if let note = m.note { out += "\n\(note)\n" }
                }
            }
        }
        return out
    }
}

/// A highlight and its book.
struct NoteItem: Identifiable {
    let noted: NotedBook
    let mark: Mark
    var id: String { noted.id + "/" + mark.id }
}

/// What can be done to one note, from its swipe actions or when it is pressed.
enum NoteAction {
    case open, share, write, copy, delete
}

/// Which highlights show: all, those with a thought, or one colour.
enum NoteFilter: Hashable {
    case all, thoughts
    case style(MarkStyle)

    func keeps(_ m: Mark) -> Bool {
        switch self {
        case .all: true
        case .thoughts: m.note != nil
        case .style(let s): m.style == s
        }
    }
}

/// 笔记 on the phone (prototype 笔记 · 按时间 / 按书 / 一本书的笔记 / 左滑 / 长按多选): every book's
/// highlights and thoughts by day, or book by book; and the 生词本. A tap goes back to the page;
/// swipe left to share, edit or delete; 选择 to take several at once.
struct PhoneNotes: View {
    let library: Library

    enum Kind: String { case all, thoughts, words }

    @AppStorage("phone.notes.kind") private var kind = Kind.all
    @AppStorage("notes.byBook") private var byBook = false
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    @State private var notes: [NotedBook] = []
    @State private var deck: Review?
    @State private var reviewing: Review?
    @State private var sharing: QuoteShare?
    @State private var writing: NoteItem?
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var path = NavigationPath()
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    private var filter: NoteFilter { kind == .thoughts ? .thoughts : .all }

    /// The books with what the filter keeps, nothing else.
    private var shown: [NotedBook] {
        notes.compactMap { n in
            let marks = n.marks.filter(filter.keeps)
            return marks.isEmpty ? nil : NotedBook(book: n.book, detail: n.detail, marks: marks)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if kind == .words {
                    PhoneWords(library: library)
                } else if shown.isEmpty {
                    empty
                } else if byBook {
                    bookList
                } else {
                    timeline
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(YYColor.bg)
            .navigationTitle("笔记")
            .safeAreaInset(edge: .top, spacing: 0) {
                if !selecting { picker }
            }
            .toolbar {
                if kind != .words, !shown.isEmpty {
                    if selecting {
                        ToolbarItem(placement: .confirmationAction) { Button("完成") { stopSelecting() } }
                    } else {
                        ToolbarItem(placement: .primaryAction) {
                            NoteExportMenu(sender: library.noteSender,
                                           markdown: NotedBook.markdown(shown, title: kind == .thoughts ? String(localized: "语阅 · 想法") : String(localized: "语阅笔记")),
                                           name: String(localized: "语阅笔记.md"), books: { shown.map(\.export) }) {
                                Label("导出", systemImage: "square.and.arrow.up")
                            }
                        }
                        if !byBook {
                            ToolbarItem(placement: .primaryAction) {
                                Button("选择", systemImage: "checkmark.circle") { selecting = true }
                            }
                        }
                    }
                }
            }
            .toolbar(selecting ? .hidden : .automatic, for: .tabBar)
            .safeAreaInset(edge: .bottom) {
                if selecting { selectionBar }
            }
            .overlay(alignment: .top) { toast }
            .animation(.spring(duration: 0.4, bounce: 0.3), value: library.toast?.id)
            .navigationDestination(for: String.self) { id in
                PhoneBookNotes(library: library, bookID: id, thoughtsOnly: kind == .thoughts)
            }
        }
        .task(id: library.books.map(\.id)) { load() }
        .onReceive(NotificationCenter.default.publisher(for: .notesChanged)) { _ in load() }
        .onChange(of: kind) { stopSelecting() }
        .onChange(of: byBook) { stopSelecting() }
        .noteSheets(library: library, sharing: $sharing, writing: $writing)
        .sheet(item: $reviewing, onDismiss: load) { review in
            MacReviewSheet(review: review, library: library) { item in
                reviewing = nil
                library.open(item.book, at: Position(section: item.mark.section, sentence: item.mark.start.sentence))
            } only: { book in
                reviewing = Review(core: library.core, book: book)
            }
            .presentationDragIndicator(.visible)
        }
    }

    private func load() {
        notes = NotedBook.load(library)
        deck = Review(core: library.core)
        selected = selected.filter { id in notes.contains { n in n.marks.contains { n.id + "/" + $0.id == id } } }
    }

    // MARK: Header

    private var picker: some View {
        HStack(spacing: 10) {
            Picker("看什么", selection: $kind) {
                Text("全部").tag(Kind.all)
                Text("想法").tag(Kind.thoughts)
                Text("生词").tag(Kind.words)
            }
            .pickerStyle(.segmented)
            if kind != .words {
                Picker("排法", selection: $byBook) {
                    Text("按时间").tag(false)
                    Text("按书").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 128)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(YYColor.bg)
    }

    // MARK: 按时间

    private struct Day: Identifiable {
        let id: Date
        var items: [NoteItem]
    }

    private var days: [Day] {
        let cal = Calendar.current
        var out: [Day] = []
        let items = shown.flatMap { n in n.marks.map { NoteItem(noted: n, mark: $0) } }.sorted { $0.mark.at > $1.mark.at }
        for item in items {
            let day = cal.startOfDay(for: Notes.date(item.mark.at))
            if out.last?.id == day { out[out.count - 1].items.append(item) } else { out.append(Day(id: day, items: [item])) }
        }
        return out
    }

    private var timeline: some View {
        List(selection: $selected) {
            if let deck, !selecting, kind == .all, !deck.items.isEmpty || deck.doneToday > 0 {
                Section {
                    PhoneDeckCard(review: deck, library: library) { reviewing = deck }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            ForEach(days) { day in
                Section {
                    ForEach(day.items) { item in
                        NoteRow(mark: item.mark, selecting: selecting) { act($0, item) } footer: {
                            HStack(spacing: 7) {
                                BookCover(book: item.noted.book).frame(width: 13)
                                Text(item.noted.book.title).font(.yy(size: 12, weight: .semibold)).foregroundStyle(YYColor.t2)
                                if let chapter = item.noted.chapter(of: item.mark) {
                                    Text("· \(chapter)").font(.yy(size: 12)).foregroundStyle(YYColor.t3)
                                }
                                Spacer(minLength: 6)
                                NoteStamp(mark: item.mark, text: Notes.time(item.mark.at), size: 11.5)
                            }
                            .lineLimit(1)
                        }
                        .tag(item.id)
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Notes.dayName(day.id)).font(.yy(size: 15, weight: .semibold)).foregroundStyle(YYColor.t1)
                        Text(Notes.monthDay(day.id)).font(.yy(size: 12)).foregroundStyle(YYColor.t3)
                        Spacer()
                        Text("\(day.items.count) 条").font(.yy(size: 12)).monospacedDigit().foregroundStyle(YYColor.t3)
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(selecting ? .active : .inactive))
    }

    // MARK: 按书

    private var bookList: some View {
        List {
            Section {
                ForEach(shown) { n in
                    NavigationLink(value: n.id) {
                        HStack(spacing: 12) {
                            BookCover(book: n.book).frame(width: 38)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(n.book.title).font(.yy(size: 15, weight: .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                                Text(Notes.counts(n.marks)).font(.yy(size: 12)).monospacedDigit().foregroundStyle(YYColor.t3)
                            }
                            Spacer(minLength: 8)
                            Text(Notes.shortDay(Notes.date(n.latest))).font(.yy(size: 12)).foregroundStyle(YYColor.t3)
                        }
                        .padding(.vertical, 3)
                    }
                }
            } header: {
                HStack {
                    Text("\(shown.count) 本书 · \(shown.reduce(0) { $0 + $1.marks.count }) 条")
                    Spacer()
                    Text("最近记的在上面")
                }
                .font(.yy(size: 12))
                .foregroundStyle(YYColor.t3)
                .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: 选择

    private var picked: [NoteItem] {
        days.flatMap(\.items).filter { selected.contains($0.id) }
    }

    private var selectionBar: some View {
        let items = picked
        let text = items.map { item in
            "“\(item.mark.text)”" + (item.mark.note.map { "\n\($0)" } ?? "") + "\n——《\(item.noted.book.title)》"
        }
        .joined(separator: "\n\n")
        return VStack(spacing: 0) {
            Text(items.isEmpty ? String(localized: "点笔记来选") : String(localized: "选了 \(items.count) 条"))
                .font(.footnote).foregroundStyle(YYColor.t2)
                .padding(.top, 8)
            HStack(spacing: 0) {
                ShareLink(item: text) { barLabel(String(localized: "分享"), "square.and.arrow.up") }
                    .disabled(items.isEmpty)
                ShareLink(item: TextFile(text: NotedBook.markdown(grouped(items), title: String(localized: "语阅笔记")), name: String(localized: "语阅笔记.md")),
                          preview: SharePreview(String(localized: "选中的笔记"))) { barLabel(String(localized: "导出"), "doc.text") }
                    .disabled(items.isEmpty)
                Button {
                    library.deleteMarks(items.map { ($0.noted.id, $0.mark) })
                    stopSelecting()
                } label: { barLabel(String(localized: "删除"), "trash", danger: true) }
                .disabled(items.isEmpty)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
        }
        .background(.bar)
    }

    /// The picked notes back under their books, for 导出.
    private func grouped(_ items: [NoteItem]) -> [NotedBook] {
        var out: [NotedBook] = []
        for item in items {
            if let i = out.firstIndex(where: { $0.id == item.noted.id }) {
                out[i] = NotedBook(book: out[i].book, detail: out[i].detail, marks: out[i].marks + [item.mark])
            } else {
                out.append(NotedBook(book: item.noted.book, detail: item.noted.detail, marks: [item.mark]))
            }
        }
        return out
    }

    private func barLabel(_ title: String, _ symbol: String, danger: Bool = false) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.yy(size: 17))
            Text(title).font(.caption2)
        }
        .foregroundStyle(danger ? YYColor.danger : YYColor.t1)
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .contentShape(.rect)
    }

    private func stopSelecting() {
        selecting = false
        selected = []
    }

    // MARK: Actions

    private func act(_ action: NoteAction, _ item: NoteItem) {
        switch action {
        case .open:
            library.open(item.noted.id, at: Position(section: item.mark.section, sentence: item.mark.start.sentence))
        case .share: sharing = item.noted.quote(item.mark)
        case .write: writing = item
        case .copy: UIPasteboard.general.string = item.mark.text + (item.mark.note.map { "\n\n" + $0 } ?? "")
        case .delete: library.deleteMarks([(item.noted.id, item.mark)])
        }
    }

    @ViewBuilder private var toast: some View {
        if let note = library.toast {
            UndoToast(toast: note, undo: { library.undo() })
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .transition(UndoToast.transition)
                .id(note.id)
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label(kind == .thoughts ? String(localized: "还没有想法") : String(localized: "还没有笔记"), systemImage: kind == .thoughts ? "pencil.line" : "quote.opening")
        } description: {
            Text(kind == .thoughts ? String(localized: "划线后点“写想法”，想到的就记在这里") : String(localized: "读书时选中文字点“划线”；所有书的划线和想法都会在这里"))
        }
    }
}

// MARK: - 一本书的笔记

/// One book's notes in book order, under their chapters (prototype 一本书的笔记). The dots keep one
/// colour; 导出 takes this book; 回顾这本书 goes through its highlights.
struct PhoneBookNotes: View {
    let library: Library
    let bookID: String
    let thoughtsOnly: Bool
    @State private var noted: NotedBook?
    @State private var only: NoteFilter = .all
    @State private var reviewing: Review?
    @State private var sharing: QuoteShare?
    @State private var writing: NoteItem?
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    var body: some View {
        Group {
            if let noted {
                let marks = noted.marks.filter { (!thoughtsOnly || $0.note != nil) && only.keeps($0) }
                List {
                    Section {
                        header(noted).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                        actions(noted).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        chips(noted.marks.filter { !thoughtsOnly || $0.note != nil })
                            .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                    }
                    ForEach(noted.chapters(marks), id: \.0) { title, marks in
                        Section {
                            ForEach(marks, id: \.id) { mark in
                                NoteRow(mark: mark, selecting: false) { act($0, NoteItem(noted: noted, mark: mark)) } footer: {
                                    HStack {
                                        Spacer()
                                        NoteStamp(mark: mark, text: Notes.monthDay(Notes.date(mark.at)), size: 11.5)
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text(title).font(.yy(size: 14, weight: .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                                Spacer()
                                Text("\(marks.count) 条").font(.yy(size: 12)).foregroundStyle(YYColor.t3)
                            }
                            .textCase(nil)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("更多", systemImage: "ellipsis") {
                            Button("打开书", systemImage: "book") { library.open(noted.book, nil) }
                            Button("回顾这本书", systemImage: "arrow.trianglehead.2.clockwise") {
                                reviewing = Review(core: library.core, book: noted.book)
                            }
                            NoteExportMenu(sender: library.noteSender,
                                           markdown: NotedBook.markdown([noted], title: String(localized: "《\(noted.book.title)》的笔记")),
                                           name: String(localized: "\(noted.book.title) 笔记.md"), books: { [noted.export] }, book: noted.book) {
                                Label("导出", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("这本书没有笔记了", systemImage: "quote.opening")
            }
        }
        .background(YYColor.bg)
        .navigationTitle(noted?.book.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .onReceive(NotificationCenter.default.publisher(for: .notesChanged)) { _ in load() }
        .noteSheets(library: library, sharing: $sharing, writing: $writing)
        .sheet(item: $reviewing) { review in
            MacReviewSheet(review: review, library: library) { item in
                reviewing = nil
                library.open(item.book, at: Position(section: item.mark.section, sentence: item.mark.start.sentence))
            } only: { book in
                reviewing = Review(core: library.core, book: book)
            }
        }
    }

    private func load() {
        noted = NotedBook.load(library, only: [bookID]).first
    }

    private func header(_ n: NotedBook) -> some View {
        HStack(spacing: 14) {
            BookCover(book: n.book).frame(width: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(n.book.title).font(.yy(size: 19, weight: .bold)).foregroundStyle(YYColor.t1).lineLimit(2)
                Text([n.book.author, String(localized: "读到 \(n.book.percent)")].compactMap { $0 }.joined(separator: " · "))
                    .font(.yy(size: 12)).foregroundStyle(YYColor.t2)
                Text(Notes.counts(n.marks) + String(localized: " · 按书里的顺序")).font(.yy(size: 12)).foregroundStyle(YYColor.t2)
            }
            Spacer(minLength: 0)
        }
    }

    /// 回顾这本书 · 导出, side by side under the book.
    private func actions(_ n: NotedBook) -> some View {
        HStack(spacing: YYUI.s(8)) {
            Button {
                reviewing = Review(core: library.core, book: n.book)
            } label: {
                Label("回顾这本书", systemImage: "arrow.trianglehead.2.clockwise")
            }
            NoteExportMenu(sender: library.noteSender,
                           markdown: NotedBook.markdown([n], title: String(localized: "《\(n.book.title)》的笔记")),
                           name: String(localized: "\(n.book.title) 笔记.md"), books: { [n.export] }, book: n.book) {
                Label("导出", systemImage: "square.and.arrow.up")
            }
        }
        .buttonStyle(YYButtonStyle(kind: .raised, size: .regular, wide: true))
        .labelStyle(.titleAndIcon)
    }

    private func chips(_ marks: [Mark]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(.all, String(localized: "全部 \(marks.count)"))
                ForEach(MarkStyle.colours + MarkStyle.lines, id: \.self) { style in
                    let n = marks.count { $0.style == style }
                    if n > 0 { chip(.style(style), "\(n)", dot: style) }
                }
            }
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.never)
    }

    private func chip(_ value: NoteFilter, _ text: String, dot: MarkStyle? = nil) -> some View {
        let on = only == value
        return Button { only = on && value != .all ? .all : value } label: {
            HStack(spacing: 6) {
                if let dot {
                    if dot.fills {
                        Circle().fill(dot.dot).frame(width: 9, height: 9)
                    } else {
                        Image(systemName: dot == .wave ? "scribble" : "underline").font(.yy(size: 10, weight: .bold)).foregroundStyle(dot.dot)
                    }
                }
                Text(text).monospacedDigit()
            }
            .font(.yy(size: 13, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? tint.onBlack : YYColor.t2)
            .padding(.horizontal, 13).frame(height: 30)
            .background(on ? AnyShapeStyle(tint.black) : AnyShapeStyle(YYColor.card), in: .capsule)
            .overlay(Capsule().strokeBorder(on ? .clear : YYColor.line))
        }
        .buttonStyle(.plain)
    }

    private func act(_ action: NoteAction, _ item: NoteItem) {
        switch action {
        case .open:
            library.open(item.noted.id, at: Position(section: item.mark.section, sentence: item.mark.start.sentence))
        case .share: sharing = item.noted.quote(item.mark)
        case .write: writing = item
        case .copy: UIPasteboard.general.string = item.mark.text + (item.mark.note.map { "\n\n" + $0 } ?? "")
        case .delete: library.deleteMarks([(item.noted.id, item.mark)])
        }
    }
}

// MARK: - One note

/// A highlight as the book set it, the thought under it in 楷体, and a line of where it came from.
/// Tap to go back to the page; swipe left for 分享 · 编辑 · 删除.
struct NoteRow<Footer: View>: View {
    let mark: Mark
    let selecting: Bool
    let act: (NoteAction) -> Void
    @ViewBuilder let footer: Footer
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkText(mark: mark)
                .font(YYUI.serif(16))
                .lineSpacing(7)
                .foregroundStyle(YYColor.t1)
            if let note = mark.note {
                Text(note)
                    .font(.custom("Kaiti SC", size: 15))
                    .foregroundStyle(tint.accent)
                    .padding(.leading, 11)
                    .overlay(alignment: .leading) { Rectangle().fill(tint.accent).frame(width: 1.5) }
            }
            footer
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onTapGesture { if !selecting { act(.open) } }
        .swipeActions(edge: .trailing) {
            if !selecting {
                Button("删除", systemImage: "trash", role: .destructive) { act(.delete) }
                Button("编辑", systemImage: "pencil") { act(.write) }.tint(.orange)
                Button("分享", systemImage: "square.and.arrow.up") { act(.share) }.tint(tint.accent)
            }
        }
        .contextMenu {
            if !selecting {
                Button("回到书里这一页", systemImage: "book") { act(.open) }
                Button(mark.note == nil ? String(localized: "写想法") : String(localized: "改想法"), systemImage: "pencil") { act(.write) }
                Button("复制", systemImage: "doc.on.doc") { act(.copy) }
                Button("分享书摘…", systemImage: "square.and.arrow.up") { act(.share) }
                Divider()
                Button("删除划线", systemImage: "trash", role: .destructive) { act(.delete) }
            }
        }
    }
}

extension View {
    /// 分享书摘 and 写想法 for a list of notes.
    func noteSheets(library: Library, sharing: Binding<QuoteShare?>, writing: Binding<NoteItem?>) -> some View {
        sheet(item: sharing) { quote in
            PhoneQuoteShare(quote: quote)
        }
        .sheet(item: writing) { item in
            PhoneThoughtSheet(mark: item.mark) { text in
                let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
                library.setNote(text?.isEmpty == false ? text : nil, book: item.noted.id, mark: item.mark)
                writing.wrappedValue = nil
            } cancel: {
                writing.wrappedValue = nil
            }
        }
    }
}

// MARK: - 今天回顾

/// The stack of cards on top of 按时间, set upright for the phone: how many and how long, the first
/// sentence, the books they come from, 开始.
struct PhoneDeckCard: View {
    let review: Review
    let library: Library
    let start: () -> Void
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("今天回顾").font(.yy(size: 15, weight: .bold)).foregroundStyle(YYColor.t1)
                Text(review.items.isEmpty ? String(localized: "看完了") : String(localized: "\(review.items.count) 条 · 约 \(review.minutes) 分钟"))
                    .font(.yy(size: 12)).monospacedDigit().foregroundStyle(YYColor.t3)
            }
            if let first = review.items.first {
                Text(verbatim: "“" + first.mark.text + "”")
                    .font(YYUI.serif(16))
                    .lineSpacing(6)
                    .foregroundStyle(YYColor.t1)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    HStack(spacing: -6) {
                        ForEach(covers, id: \.id) { BookCover(book: $0).frame(width: 18) }
                    }
                    Text("来自 \(covers.count) 本书").font(.yy(size: 12)).foregroundStyle(YYColor.t3)
                    Spacer()
                    Button(action: start) {
                        Text("开始")
                            .font(.yy(size: 14, weight: .semibold))
                            .foregroundStyle(tint.onBlack)
                            .padding(.horizontal, 20).frame(height: 34)
                            .background(tint.black, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("今天的 \(review.doneToday) 条看完了。留下的以后还会再出现。")
                    .font(.yy(size: 13)).foregroundStyle(YYColor.t2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                // The cards underneath, two edges showing.
                RoundedRectangle(cornerRadius: 16).fill(YYColor.card).opacity(0.45)
                    .padding(.horizontal, 24).offset(y: 12)
                RoundedRectangle(cornerRadius: 16).fill(YYColor.card).opacity(0.75)
                    .padding(.horizontal, 12).offset(y: 6)
                    .yyShadow(scheme == .dark ? YYShadow.ringDark : YYShadow.ringLight)
                RoundedRectangle(cornerRadius: 18).fill(YYColor.card)
                    .yyShadow(scheme == .dark ? YYShadow.ringDark : YYShadow.ringLight)
            }
        }
        .padding(.bottom, 12)
    }

    private var covers: [BookSummary] {
        var seen = Set<String>()
        return review.items.compactMap { item in
            guard seen.insert(item.book).inserted else { return nil }
            return library.books.first { $0.id == item.book }
        }
        .prefix(4).map { $0 }
    }
}

// MARK: - 书摘分享

/// 书摘分享 on the phone: the card as it will look, its colours and shape, and the system's share
/// sheet for the picture.
struct PhoneQuoteShare: View {
    let quote: QuoteShare
    @Environment(\.dismiss) private var dismiss
    @AppStorage("share.look") private var look = QuoteLook.cover
    @AppStorage("share.shape") private var shape = QuoteShape.portrait
    @State private var withNote = true
    @State private var cover: CGImage?
    @State private var picture: Image?

    private var card: QuoteCard {
        QuoteCard(quote: quote, look: look, shape: shape, withNote: withNote && quote.note != nil,
                  cover: cover, coverColor: cover.flatMap(QuoteColors.deep))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    let scale = min(1, 340 / shape.size.width)
                    card
                        .scaleEffect(scale)
                        .frame(width: shape.size.width * scale, height: shape.size.height * scale)
                        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
                        .padding(.top, 12)
                    VStack(spacing: 14) {
                        Picker("样子", selection: $look) {
                            ForEach(QuoteLook.allCases) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Picker("尺寸", selection: $shape) {
                            ForEach(QuoteShape.allCases) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if quote.note != nil {
                            Toggle("带上想法", isOn: $withNote)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 24)
            }
            .background(YYColor.bg)
            .navigationTitle("书摘分享")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if let picture {
                        ShareLink(item: picture, subject: Text("《\(quote.title)》"), message: Text(quote.plain),
                                  preview: SharePreview(String(localized: "《\(quote.title)》书摘"), image: picture)) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .presentationDetents([.large])
        .task {
            cover = await Thumbnail.load(quote.coverPath, maxPixels: 360)
            render()
        }
        .onChange(of: look) { render() }
        .onChange(of: shape) { render() }
        .onChange(of: withNote) { render() }
    }

    private func render() {
        let r = ImageRenderer(content: card)
        r.scale = 3
        picture = r.uiImage.map { Image(uiImage: $0) }
    }
}

// MARK: - 生词

/// The 生词本 on the phone: the words kept while reading in another language, by the day they were
/// kept, with the sound, the meaning and the sentence they came from. Swipe right for 掌握了, left to
/// delete; a tap goes back to the sentence.
struct PhoneWords: View {
    let library: Library
    @State private var words: [VocabWord] = []
    @State private var details: [String: BookDetail] = [:]
    @State private var showKnown = false
    @State private var speaker = AVSpeechSynthesizer()
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    private var learning: [VocabWord] { words.filter { !$0.known } }
    private var known: [VocabWord] { words.filter(\.known) }
    private var shown: [VocabWord] { showKnown ? known : learning }

    private struct Day: Identifiable {
        let id: Date
        var words: [VocabWord]
    }

    private var days: [Day] {
        var out: [Day] = []
        for w in shown {
            let day = Calendar.current.startOfDay(for: Notes.date(w.at))
            if out.last?.id == day { out[out.count - 1].words.append(w) } else { out.append(Day(id: day, words: [w])) }
        }
        return out
    }

    var body: some View {
        Group {
            if words.isEmpty {
                ContentUnavailableView {
                    Label("还没有生词", systemImage: "character.book.closed")
                } description: {
                    Text("读外文书时点一个词，在释义卡片里点“加入生词本”，就记在这里，带着原句")
                }
            } else {
                List {
                    Section {
                        Picker("哪些词", selection: $showKnown) {
                            Text("在学 \(learning.count)").tag(false)
                            Text("掌握了 \(known.count)").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                    if shown.isEmpty {
                        Text(showKnown ? String(localized: "还没有掌握的词。在学的词右滑“掌握了”，就挪到这里") : String(localized: "都掌握了。新查的词加进生词本，会出现在这里"))
                            .font(.footnote).foregroundStyle(YYColor.t3)
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(days) { day in
                        Section {
                            ForEach(day.words, id: \.word) { row($0) }
                        } header: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(Notes.dayName(day.id)).font(.yy(size: 15, weight: .semibold)).foregroundStyle(YYColor.t1)
                                Text(Notes.monthDay(day.id)).font(.yy(size: 12)).foregroundStyle(YYColor.t3)
                                Spacer()
                                Text("\(day.words.count) 个").font(.yy(size: 12)).foregroundStyle(YYColor.t3)
                            }
                            .textCase(nil)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .toolbar {
            if !shown.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ShareLink(item: TextFile(text: Vocab.anki(shown, title: source), name: String(localized: "语阅生词 Anki.txt")),
                                  preview: SharePreview(String(localized: "Anki 卡片"))) { Label("Anki 卡片", systemImage: "rectangle.stack") }
                        ShareLink(item: TextFile(text: Vocab.csv(shown, title: source), name: String(localized: "语阅生词.csv")),
                                  preview: SharePreview(String(localized: "CSV 表格"))) { Label("CSV 表格", systemImage: "tablecells") }
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task(id: library.books.map(\.id)) { load() }
        .onReceive(NotificationCenter.default.publisher(for: .vocabChanged)) { _ in load() }
    }

    private func load() {
        words = (try? library.core.words()) ?? []
        for book in Set(words.map(\.book)) where details[book] == nil {
            details[book] = try? library.core.book(id: book)
        }
    }

    private func title(of book: String) -> String {
        library.books.first { $0.id == book }?.title ?? details[book]?.summary.title ?? String(localized: "已删除的书")
    }

    private func source(_ w: VocabWord) -> String {
        let title = title(of: w.book)
        guard let chapter = details[w.book]?.chapterTitle(for: w.section), chapter != title else { return title }
        return "\(title) · \(chapter)"
    }

    private func row(_ w: VocabWord) -> some View {
        let meaning = Vocab.split(meaning: w.meaning)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(w.word).font(.custom("Georgia", size: 20).weight(.bold)).foregroundStyle(YYColor.t1)
                if let p = w.phonetic {
                    Text(p).font(.yy(size: 13)).foregroundStyle(YYColor.t2)
                }
                Spacer(minLength: 8)
                Button { say(w) } label: {
                    Image(systemName: "speaker.wave.2").font(.yy(size: 13, weight: .medium)).foregroundStyle(YYColor.t1)
                        .frame(width: 32, height: 32).background(YYColor.inset, in: .circle)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("读一遍")
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            }
            if let meaning {
                (Text(meaning.pos.map { $0 + " " } ?? "").font(.custom("Georgia", size: 14)).italic().foregroundStyle(YYColor.t3)
                    + Text(meaning.text).font(.yy(size: 14)).foregroundStyle(YYColor.t1))
                    .padding(.top, 4)
            }
            if !w.context.isEmpty {
                Text(Vocab.attributed(w.context, word: w.word, accent: tint.accent, limit: 200))
                    .font(.custom("Georgia", size: 14.5)).foregroundStyle(YYColor.t2)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)
            }
            Text(source(w))
                .font(.yy(size: 12, weight: .semibold)).foregroundStyle(YYColor.t3).lineLimit(1)
                .padding(.top, 10)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onTapGesture { open(w) }
        .swipeActions(edge: .leading) {
            Button(w.known ? String(localized: "再学一遍") : String(localized: "掌握了"), systemImage: w.known ? "arrow.uturn.backward" : "checkmark") { setKnown(w, !w.known) }
                .tint(w.known ? .orange : .green)
        }
        .swipeActions(edge: .trailing) {
            Button("删除", systemImage: "trash", role: .destructive) { library.deleteWord(w.word) }
        }
        .contextMenu {
            Button("回到书里这一句", systemImage: "book") { open(w) }
                .disabled(!library.books.contains { $0.id == w.book && $0.available })
            Button("读一遍", systemImage: "speaker.wave.2") { say(w) }
            Button(w.known ? String(localized: "再学一遍") : String(localized: "掌握了"), systemImage: w.known ? "arrow.uturn.backward" : "checkmark") { setKnown(w, !w.known) }
            Button("复制", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = [w.word, w.phonetic, w.meaning].compactMap { $0 }.joined(separator: " ")
            }
            Divider()
            Button("删除", systemImage: "trash", role: .destructive) { library.deleteWord(w.word) }
        }
    }

    private func setKnown(_ w: VocabWord, _ on: Bool) {
        try? library.core.setWordKnown(word: w.word, known: on)
        NotificationCenter.default.post(name: .vocabChanged, object: nil)
    }

    private func open(_ w: VocabWord) {
        guard library.books.contains(where: { $0.id == w.book && $0.available }) else { return }
        library.open(w.book, at: Position(section: w.section, sentence: w.sentence))
    }

    private func say(_ w: VocabWord) {
        speaker.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: w.word)
        u.voice = ForeignPrefs.voice(for: details[w.book]?.summary.language)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        speaker.speak(u)
    }
}

/// A text file handed to the share sheet (导出): saved to Files, sent to Anki, and so on.
nonisolated struct TextFile: Transferable, Sendable {
    let text: String
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { file in
            let dir = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(path: file.name.replacingOccurrences(of: "/", with: "-"))
            try Data(file.text.utf8).write(to: url)
            return SentTransferredFile(url)
        }
    }
}
#endif
