#if os(iOS)
import SwiftUI
import YuyueCore

/// 搜索 · 问 on the phone (prototype 搜索结果): book names, every book's own sentences, highlights
/// and thoughts, and 生词, looked for at once; the chips under the field keep one kind. The first
/// row always hands the words to 书伴 instead. A tap goes to the page.
struct PhoneSearch: View {
    let library: Library
    @State private var search: QuickSearch?
    @State private var query = ""
    @State private var scope = Scope.all
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    enum Scope: Hashable { case all, books, lines, notes, words }

    private var q: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Group {
                if let search {
                    results(search)
                } else {
                    Color.clear
                }
            }
            .background(YYColor.bg)
            .navigationTitle("搜索")
            .searchable(text: $query, prompt: String(localized: "书名、原文、笔记、生词"))
            .safeAreaInset(edge: .top, spacing: 0) {
                if let search, !q.isEmpty { chips(search) }
            }
        }
        .onAppear {
            // The library may have changed since: books, marks and words are read again.
            let s = QuickSearch(library: library, many: true)
            s.query = query
            search = s
        }
        .onChange(of: query) {
            search?.query = query
            if q.isEmpty { scope = .all }
        }
    }

    // MARK: Chips

    /// `.v-fx-scope`: one kind at a time.
    private func chips(_ s: QuickSearch) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: YYUI.s(6)) {
                chip(.all, String(localized: "全部"), nil)
                chip(.books, String(localized: "书"), s.titles.count)
                chip(.lines, String(localized: "全文"), s.lineCount)
                chip(.notes, String(localized: "笔记"), s.noteCount)
                chip(.words, String(localized: "生词"), s.words.count)
            }
            .padding(.horizontal, YYUI.s(16))
            .padding(.top, YYUI.s(4))
            .padding(.bottom, YYUI.s(8))
        }
        .scrollIndicators(.never)
        .background(YYColor.bg)
    }

    private func chip(_ value: Scope, _ title: String, _ count: Int?) -> some View {
        let on = scope == value
        return Button { scope = value } label: {
            HStack(spacing: YYUI.s(4)) {
                Text(title)
                if let count, count > 0 {
                    Text(count.formatted()).monospacedDigit().foregroundStyle(on ? tint.onBlack.opacity(0.55) : YYColor.t3)
                }
            }
            .font(YYUI.font(10.5, on ? .semibold : .regular))
            .foregroundStyle(on ? tint.onBlack : YYColor.t2)
            .padding(.horizontal, YYUI.s(11))
            .frame(height: YYUI.s(28))
            .background(on ? AnyShapeStyle(tint.black) : AnyShapeStyle(YYColor.card), in: .capsule)
            .overlay(Capsule().strokeBorder(on ? .clear : YYColor.line, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(value != .all && (count ?? 0) == 0)
    }

    // MARK: Results

    /// `.v-fx-sr`: 问书伴 on top, then each kind under its own label, in white cards.
    private func results(_ s: QuickSearch) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if q.isEmpty {
                    if !s.titles.isEmpty {
                        label(String(localized: "最近读过"), nil)
                        card { ForEach(s.titles) { titleRow($0) } }
                    }
                } else {
                    if scope == .all, let book = askBook(s) { askCard(book) }
                    if (scope == .all || scope == .books), !s.titles.isEmpty {
                        label(String(localized: "书"), "\(s.titles.count)")
                        card { ForEach(s.titles) { titleRow($0) } }
                    }
                    if (scope == .all || scope == .lines), !s.lines.isEmpty {
                        label(String(localized: "全文"), String(localized: "\(s.lineCount) 处 · \(s.lineBooks) 本书"))
                        card { ForEach(scope == .all ? Array(s.lines.prefix(4)) : s.lines) { lineRow($0) } }
                    }
                    if (scope == .all || scope == .notes), !s.notes.isEmpty {
                        label(String(localized: "笔记"), String(localized: "\(s.noteCount) 条"))
                        card { ForEach(scope == .all ? Array(s.notes.prefix(3)) : s.notes) { noteRow($0) } }
                    }
                    if (scope == .all || scope == .words), !s.words.isEmpty {
                        label(String(localized: "生词"), String(localized: "\(s.words.count) 个"))
                        card { ForEach(scope == .all ? Array(s.words.prefix(3)) : s.words, id: \.word) { wordRow($0) } }
                    }
                    if s.titles.isEmpty, s.lines.isEmpty, s.notes.isEmpty, s.words.isEmpty {
                        Text("书名、原文、笔记里都没有“\(q)”。可以问问书伴")
                            .font(YYUI.font(10.5)).foregroundStyle(YYColor.t3)
                            .frame(maxWidth: .infinity)
                            .padding(.top, YYUI.s(24))
                    }
                }
            }
            .padding(.horizontal, YYUI.s(16))
            .padding(.bottom, YYUI.s(24))
        }
        .scrollDismissesKeyboard(.immediately)
    }

    /// `.v-fx-ask`: the row that's always first, handing the words to 书伴.
    private func askCard(_ book: BookSummary) -> some View {
        Button { library.ask(q, in: book.id) } label: {
            HStack(spacing: YYUI.s(10)) {
                Image(systemName: "sparkle")
                    .font(YYUI.font(14, .semibold))
                    .foregroundStyle(tint.accent)
                    .frame(width: YYUI.s(32), height: YYUI.s(32))
                    .background(tint.accentSoft, in: .rect(cornerRadius: YYUI.s(10)))
                VStack(alignment: .leading, spacing: YYUI.s(1)) {
                    Text("问书伴“\(q)”").font(YYUI.font(12, .semibold)).foregroundStyle(tint.accent).lineLimit(1)
                    Text("只用《\(book.title)》里你读过的部分回答，带出处").font(YYUI.font(10)).foregroundStyle(YYColor.t3).lineLimit(1)
                }
                Spacer(minLength: 0)
                chevron
            }
            .padding(.vertical, YYUI.s(10))
            .padding(.horizontal, YYUI.s(12))
            .yyCard()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, YYUI.s(6))
    }

    /// The book 书伴 answers from: one whose name was typed, else the one read last.
    private func askBook(_ s: QuickSearch) -> BookSummary? {
        if let t = s.titles.first(where: { $0.chapter == nil && Self.canAsk($0.book) }) { return t.book }
        return library.books.filter { $0.available && Self.canAsk($0) && $0.openedAt != nil }
            .max { ($0.openedAt ?? 0) < ($1.openedAt ?? 0) }
    }

    /// 书伴 reads books set as text: not comics, not PDFs.
    private static func canAsk(_ book: BookSummary) -> Bool {
        !book.isComic && book.format != .pdf
    }

    /// `.v-lb`, a little closer to its card than elsewhere.
    private func label(_ title: String, _ detail: String?) -> some View {
        YYLabel(title, detail)
            .monospacedDigit()
            .padding(.top, -YYUI.s(2))
            .padding(.bottom, -YYUI.s(1))
    }

    /// `.grp`: rows in one white card, a hairline between.
    private func card(@ViewBuilder _ rows: () -> some View) -> some View {
        YYGroup { rows() }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(YYUI.font(10, .semibold)).foregroundStyle(YYColor.t3)
    }

    // MARK: Rows

    private func titleRow(_ t: QuickSearch.TitleHit) -> some View {
        Button {
            if let chapter = t.chapter {
                library.open(t.book.id, at: Position(section: chapter.section, sentence: 0))
            } else {
                library.open(t.book, nil)
            }
        } label: {
            HStack(spacing: YYUI.s(10)) {
                BookCover(book: t.book).frame(width: YYUI.s(26))
                VStack(alignment: .leading, spacing: YYUI.s(2)) {
                    Group {
                        if let chapter = t.chapter {
                            Text(t.book.title + " · ") + Text(hit(chapter.title))
                        } else {
                            Text(NameMatcher(q).highlighted(t.book.title, color: tint.accent))
                        }
                    }
                    .font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                    Text([t.book.author, t.book.shelfNote].compactMap { $0 }.joined(separator: " · "))
                        .font(YYUI.font(10)).monospacedDigit().foregroundStyle(YYColor.t3).lineLimit(1)
                }
                Spacer(minLength: 0)
                chevron
            }
            .padding(.vertical, YYUI.s(9))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// `.v-fx-hit p`: the book's own sentence, two lines at most.
    private func passage(_ text: Text) -> some View {
        text
            .font(YYUI.font(12.5, design: .serif))
            .tracking(YYUI.s(12.5) * 0.02)
            .lineSpacing(YYUI.s(12.5) * 0.8)
            .foregroundStyle(YYColor.t1)
            .lineLimit(2)
    }

    private func hitRow(_ action: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: YYUI.s(4)) { content() }
                .padding(.top, YYUI.s(10))
                .padding(.bottom, YYUI.s(9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func lineRow(_ l: QuickSearch.LineHit) -> some View {
        hitRow {
            library.open(l.book.id, at: Position(section: l.hit.section, sentence: l.hit.sentence))
        } content: {
            passage(Text(l.hit.before) + Text(mark(l.hit.matched)) + Text(l.hit.after))
            source(l.book, l.chapter)
        }
    }

    private func noteRow(_ n: QuickSearch.NoteHit) -> some View {
        hitRow {
            library.open(n.book.id, at: Position(section: n.mark.section, sentence: n.mark.start.sentence))
        } content: {
            MarkText(mark: n.mark)
                .font(YYUI.font(12.5, design: .serif))
                .lineSpacing(YYUI.s(12.5) * 0.8)
                .foregroundStyle(YYColor.t1)
                .lineLimit(2)
            if let note = n.mark.note {
                Text(hit(note))
                    .font(.custom("Kaiti SC", size: YYUI.s(12)))
                    .lineSpacing(YYUI.s(12) * 0.7)
                    .foregroundStyle(tint.accent).lineLimit(2)
                    .padding(.leading, YYUI.s(9))
                    .overlay(alignment: .leading) { Rectangle().fill(tint.accent).frame(width: 1.5) }
                    .padding(.top, YYUI.s(1))
            }
            source(n.book, n.chapter)
        }
    }

    private func wordRow(_ w: VocabWord) -> some View {
        hitRow {
            guard library.books.contains(where: { $0.id == w.book && $0.available }) else { return }
            library.open(w.book, at: Position(section: w.section, sentence: w.sentence))
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: YYUI.s(6)) {
                Text(hit(w.word)).font(.custom("Georgia", size: YYUI.s(14)).weight(.bold)).foregroundStyle(YYColor.t1)
                if let p = w.phonetic { Text(p).font(YYUI.font(10)).foregroundStyle(YYColor.t3) }
            }
            if let m = w.meaning {
                Text(m).font(YYUI.font(11)).foregroundStyle(YYColor.t2).lineLimit(2)
            }
        }
    }

    /// `.v-fx-at`: a tiny cover, the book, where in it.
    private func source(_ book: BookSummary, _ chapter: String?) -> some View {
        HStack(spacing: YYUI.s(5)) {
            BookCover(book: book).frame(width: YYUI.s(10))
            Text([book.title, chapter == book.title ? nil : chapter].compactMap { $0 }.joined(separator: " · "))
                .font(YYUI.font(10)).monospacedDigit().foregroundStyle(YYColor.t3).lineLimit(1)
        }
    }

    /// The words typed, in the accent wherever they appear.
    private func hit(_ s: String) -> AttributedString {
        var text = AttributedString(s)
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
}
#endif
