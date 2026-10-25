import SwiftUI
import YuyueCore

/// 搜索 · 问 ⌘K (prototype f95): what was typed, looked for everywhere at once. Book names and
/// chapters, the books' own sentences, highlights and thoughts; the first row always hands the
/// words to 书伴 instead.
@Observable
final class QuickSearch {
    struct TitleHit: Identifiable {
        let book: BookSummary
        /// A chapter whose name matched, rather than the book's.
        let chapter: TocItem?
        var id: String { book.id + "/" + (chapter.map { "\($0.section)/\($0.title)" } ?? "") }
    }

    struct LineHit: Identifiable {
        let book: BookSummary
        let hit: SearchHit
        let chapter: String?
        var id: String { "\(book.id)/\(hit.section)/\(hit.sentence)/\(hit.nth)" }
    }

    struct NoteHit: Identifiable {
        let book: BookSummary
        let mark: Mark
        let chapter: String?
        var id: String { mark.id }
    }

    enum Row: Identifiable {
        case ask
        case title(TitleHit)
        case line(LineHit)
        case note(NoteHit)

        var id: String {
            switch self {
            case .ask: "ask"
            case .title(let t): "t/" + t.id
            case .line(let l): "l/" + l.id
            case .note(let n): "n/" + n.id
            }
        }
    }

    var query = "" {
        didSet { if query != oldValue { find() } }
    }
    private(set) var titles: [TitleHit] = []
    private(set) var lines: [LineHit] = []
    private(set) var lineCount = 0
    private(set) var lineBooks = 0
    private(set) var notes: [NoteHit] = []
    private(set) var noteCount = 0
    /// 生词 that match: the phone's search lists them too.
    private(set) var words: [VocabWord] = []
    var selected = 0

    /// How many of each kind to list: a few in the ⌘K panel, a page of each on the phone.
    @ObservationIgnored private let limit: (titles: Int, lines: Int, notes: Int)
    @ObservationIgnored private let library: Library
    @ObservationIgnored private var vocab: [VocabWord] = []
    @ObservationIgnored private var books: [BookSummary] = []
    @ObservationIgnored private var details: [String: BookDetail] = [:]
    @ObservationIgnored private var marks: [String: [Mark]] = [:]
    @ObservationIgnored private var finding: Task<Void, Never>?

    init(library: Library, many: Bool = false) {
        self.library = library
        limit = many ? (40, 60, 60) : (4, 4, 3)
        if many { vocab = (try? library.core.words()) ?? [] }
        books = library.books.filter(\.available)
        for book in books {
            details[book.id] = try? library.core.book(id: book.id)
            marks[book.id] = (try? library.core.marks(book: book.id)) ?? []
        }
        find()
    }

    var allNotes: Int { marks.values.reduce(0) { $0 + $1.count } }
    var bookCount: Int { books.count }

    var rows: [Row] {
        [.ask] + titles.map(Row.title) + lines.map(Row.line) + notes.map(Row.note)
    }

    func move(_ by: Int) {
        selected = min(max(0, selected + by), rows.count - 1)
    }

    // MARK: Finding

    private func find() {
        finding?.cancel()
        selected = 0
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            // Nothing typed: the books last read.
            titles = books.filter { $0.openedAt != nil }.sorted { ($0.openedAt ?? 0) > ($1.openedAt ?? 0) }
                .prefix(5).map { TitleHit(book: $0, chapter: nil) }
            lines = []; lineCount = 0; lineBooks = 0
            notes = []; noteCount = 0
            words = []
            return
        }
        let matcher = NameMatcher(q)
        var t: [TitleHit] = books.filter { b in matcher.match(b.title) != nil || b.authors.contains { matcher.match($0) != nil } }
            .map { TitleHit(book: $0, chapter: nil) }
        for book in books {
            for item in details[book.id]?.toc ?? [] where item.title.localizedCaseInsensitiveContains(q) && item.title != book.title {
                t.append(TitleHit(book: book, chapter: item))
            }
        }
        titles = Array(t.prefix(limit.titles))

        let n = books.flatMap { book in
            (marks[book.id] ?? []).filter { $0.text.localizedCaseInsensitiveContains(q) || ($0.note?.localizedCaseInsensitiveContains(q) ?? false) }
                .map { NoteHit(book: book, mark: $0, chapter: details[book.id]?.chapterTitle(for: $0.section)) }
        }
        .sorted { $0.mark.at > $1.mark.at }
        noteCount = n.count
        notes = Array(n.prefix(limit.notes))
        words = vocab.filter { $0.word.localizedCaseInsensitiveContains(q) || ($0.meaning?.localizedCaseInsensitiveContains(q) ?? false) }

        // 全文 can take a moment over a big library: wait for the typing to stop.
        let core = library.core
        let ids = books.map(\.id)
        finding = Task {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            let found = await Self.search(core: core, books: ids, query: q)
            guard !Task.isCancelled else { return }
            lineCount = found.reduce(0) { $0 + $1.1.count }
            lineBooks = found.count { !$0.1.isEmpty }
            // The first sentence from each book, then the second…
            var picked: [LineHit] = []
            var round = 0
            let most = limit.lines
            while picked.count < most, found.contains(where: { $0.1.count > round }) {
                for (id, hits) in found where hits.count > round && picked.count < most {
                    guard let book = books.first(where: { $0.id == id }) else { continue }
                    picked.append(LineHit(book: book, hit: hits[round], chapter: details[id]?.chapterTitle(for: hits[round].section)))
                }
                round += 1
            }
            lines = picked
        }
    }

    @concurrent private static func search(core: YuyueCore, books: [String], query: String) async -> [(String, [SearchHit])] {
        var out: [(String, [SearchHit])] = []
        for id in books {
            if Task.isCancelled { break }
            out.append((id, (try? core.searchBook(book: id, query: query)) ?? []))
        }
        return out
    }
}

#if os(macOS)

/// The ⌘K panel: floats near the top of the window over a dimmed page.
struct QuickSearchPanel: View {
    let library: Library
    @State private var search: QuickSearch
    let close: () -> Void
    /// ⌘↩, or the first row: hand the words to 书伴.
    let ask: (String) -> Void
    @FocusState private var focused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    init(library: Library, query: String = "", close: @escaping () -> Void, ask: @escaping (String) -> Void) {
        self.library = library
        let s = QuickSearch(library: library)
        s.query = query
        _search = State(initialValue: s)
        self.close = close
        self.ask = ask
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(scheme == .dark ? 0.5 : 0.2)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            panel.padding(.top, 50)
        }
        .task {
            // In a reading window the page (a web view) holds the keyboard; asking once as the
            // panel appears can lose to it, so ask again when it has settled.
            focused = true
            try? await Task.sleep(for: .milliseconds(100))
            focused = true
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            field
            Rectangle().fill(YYColor.line).frame(height: 1)
            results
            Rectangle().fill(YYColor.line).frame(height: 1)
            footer
        }
        .frame(width: 640)
        .background(YYColor.card.opacity(0.92))
        .background(.ultraThinMaterial)
        .clipShape(.rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.black.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.38), radius: 40, y: 32)
        .shadow(color: .black.opacity(0.12), radius: 12, y: 10)
    }

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.yy(size: 18)).foregroundStyle(YYColor.t2)
            TextField("", text: $search.query, prompt: Text("搜书名、原文、笔记，或者问书伴"))
                .textFieldStyle(.plain)
                .font(.yy(size: 20))
                .focused($focused)
                .onKeyPress(.upArrow) { search.move(-1); return .handled }
                .onKeyPress(.downArrow) { search.move(1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) { askNow() } else { choose(search.selected) }
                    return .handled
                }
            Key("esc")
        }
        .padding(.leading, 20).padding(.trailing, 16)
        .frame(height: 52)
    }

    // MARK: Rows

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let rows = search.rows
                    row(0) { askRow }
                    if !search.titles.isEmpty {
                        group(search.query.isEmpty ? String(localized: "最近读过") : String(localized: "书名和篇目"), search.query.isEmpty ? "" : "\(search.titles.count)")
                        ForEach(Array(search.titles.enumerated()), id: \.element.id) { i, t in
                            row(1 + i) { titleRow(t) }
                        }
                    }
                    if !search.lines.isEmpty {
                        group(String(localized: "全文"), String(localized: "\(search.lineCount) 处 · \(search.lineBooks) 本书"))
                        ForEach(Array(search.lines.enumerated()), id: \.element.id) { i, l in
                            row(1 + search.titles.count + i) { lineRow(l) }
                        }
                    }
                    if !search.notes.isEmpty {
                        group(String(localized: "笔记"), String(localized: "\(search.noteCount) 条"))
                        ForEach(Array(search.notes.enumerated()), id: \.element.id) { i, n in
                            row(1 + search.titles.count + search.lines.count + i) { noteRow(n) }
                        }
                    }
                    if !search.query.isEmpty && rows.count == 1 {
                        Text("书里和笔记里都没找到。按 ⌘↩ 问书伴试试")
                            .font(.yy(size: 12)).foregroundStyle(YYColor.t3)
                            .padding(.horizontal, 10).padding(.vertical, 14)
                    }
                }
                .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 6)
            }
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
            .scrollIndicators(.never)
            .onChange(of: search.selected) {
                let rows = search.rows
                if rows.indices.contains(search.selected) { proxy.scrollTo(rows[search.selected].id) }
            }
        }
    }

    private func row(_ i: Int, @ViewBuilder content: () -> some View) -> some View {
        let on = search.selected == i
        let rows = search.rows
        return HStack(spacing: 12) {
            content()
            if on, i > 0 {
                Text("↩ 打开")
                    .font(.yy(size: 10.5, weight: .semibold))
                    .foregroundStyle(tint.accent)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(YYColor.card, in: .rect(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tint.accent.opacity(0.3), lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(minHeight: i == 0 ? 46 : 38)
        .background(on ? tint.soft : .clear, in: .rect(cornerRadius: 10))
        .contentShape(.rect)
        .onTapGesture { choose(i) }
        .onHover { if $0 { search.selected = i } }
        .id(rows.indices.contains(i) ? rows[i].id : "\(i)")
    }

    private func group(_ title: String, _ count: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.yy(size: 10.5, weight: .semibold))
            Spacer()
            Text(count).font(.yy(size: 10.5)).monospacedDigit()
        }
        .foregroundStyle(YYColor.t3)
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
    }

    private var askRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle").font(.yy(size: 14))
                .foregroundStyle(tint.accent)
                .frame(width: 30, height: 30)
                .background(tint.soft, in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(search.query.isEmpty ? String(localized: "问书伴") : String(localized: "问书伴：“\(search.query)”"))
                    .font(.yy(size: 13, weight: .semibold)).foregroundStyle(tint.accent).lineLimit(1)
                Text("只用你读过的部分回答，带出处").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
            }
            Spacer(minLength: 0)
            Key("⌘↩")
        }
    }

    private func titleRow(_ t: QuickSearch.TitleHit) -> some View {
        HStack(spacing: 12) {
            BookCover(book: t.book).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if let chapter = t.chapter {
                        Text(t.book.title + " · ") + Text(hit(chapter.title))
                    } else {
                        Text(NameMatcher(search.query).highlighted(t.book.title, color: tint.accent))
                    }
                }
                .font(.yy(size: 13, weight: .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                Text(detail(t)).font(.yy(size: 10.5)).monospacedDigit().foregroundStyle(YYColor.t3).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func detail(_ t: QuickSearch.TitleHit) -> String {
        var parts: [String] = []
        if let author = t.book.author { parts.append(author) }
        if let chapter = t.chapter {
            let toc = (try? library.core.book(id: t.book.id))?.toc ?? []
            if let n = toc.firstIndex(where: { $0.section == chapter.section && $0.title == chapter.title }) { parts.append(String(localized: "第 \(n + 1) 篇")) }
        }
        parts.append(t.book.shelfNote)
        return parts.joined(separator: " · ")
    }

    private func lineRow(_ l: QuickSearch.LineHit) -> some View {
        HStack(spacing: 12) {
            BookCover(book: l.book).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                (Text(l.hit.before) + Text(mark(l.hit.matched)) + Text(l.hit.after))
                    .font(YYUI.serif(13)).tracking(0.26)
                    .foregroundStyle(YYColor.t1).lineLimit(1)
                Text([l.book.title, l.chapter].compactMap { $0 }.uniqued().joined(separator: " · "))
                    .font(.yy(size: 10.5)).foregroundStyle(YYColor.t3).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func noteRow(_ n: QuickSearch.NoteHit) -> some View {
        HStack(spacing: 12) {
            BookCover(book: n.book).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                MarkText(mark: n.mark)
                    .font(YYUI.serif(13)).foregroundStyle(YYColor.t1).lineLimit(1)
                if let note = n.mark.note {
                    Text(note)
                        .font(.custom("Kaiti SC", size: 12.5)).foregroundStyle(tint.accent).lineLimit(1)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(tint.accent).frame(width: 1.5) }
                }
            }
            Spacer(minLength: 8)
            Text([n.book.title, n.chapter].compactMap { $0 }.uniqued().joined(separator: " · "))
                .font(.yy(size: 10.5)).foregroundStyle(YYColor.t3).lineLimit(1)
        }
    }

    /// The words typed, bold and underlined in the accent wherever they appear.
    private func hit(_ s: String) -> AttributedString {
        var text = AttributedString(s)
        let q = search.query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return text }
        var from = text.startIndex
        while let r = text[from...].range(of: q, options: .caseInsensitive) {
            text[r].foregroundColor = tint.accent
            text[r].inlinePresentationIntent = .stronglyEmphasized
            text[r].underlineStyle = .single
            from = r.upperBound
        }
        return text
    }

    private func mark(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        a.foregroundColor = tint.accent
        a.inlinePresentationIntent = .stronglyEmphasized
        a.underlineStyle = .single
        return a
    }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) { Key("↑"); Key("↓"); Text("选择") }
            HStack(spacing: 4) { Key("↩"); Text("打开") }
            HStack(spacing: 4) { Key("⌘↩"); Text("问书伴") }
            Spacer()
            Text("在 \(search.bookCount) 本书和 \(search.allNotes) 条笔记里搜")
        }
        .font(.yy(size: 10.5))
        .foregroundStyle(YYColor.t3)
        .padding(.horizontal, 18)
        .frame(height: 36)
    }

    // MARK: Going

    private func askNow() {
        let q = search.query.trimmingCharacters(in: .whitespaces)
        close()
        ask(q)
    }

    private func choose(_ i: Int) {
        let rows = search.rows
        guard rows.indices.contains(i) else { return }
        switch rows[i] {
        case .ask:
            askNow()
            return
        case .title(let t):
            if let chapter = t.chapter {
                library.open(t.book.id, at: Position(section: chapter.section, sentence: 0))
            } else {
                library.open(t.book, nil)
            }
            openWindow(id: "reader", value: t.book.id)
        case .line(let l):
            library.open(l.book.id, at: Position(section: l.hit.section, sentence: l.hit.sentence))
            openWindow(id: "reader", value: l.book.id)
        case .note(let n):
            library.open(n.book.id, at: Position(section: n.mark.section, sentence: n.mark.start.sentence))
            openWindow(id: "reader", value: n.book.id)
        }
        close()
    }
}

/// A key cap in the hints.
private struct Key: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.yy(size: 10.5)).monospacedDigit()
            .foregroundStyle(YYColor.t2)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(YYColor.inset, in: .rect(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(YYColor.line, lineWidth: 0.5))
    }
}

extension Array where Element == String {
    /// Drops a chapter named the same as its book.
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

extension Notification.Name {
    /// ⌘K with no book window in front: the shelf shows 搜索 · 问.
    static let quickSearch = Notification.Name("yuyue.quickSearch")
}
#endif
