import SwiftUI
import YuyueCore

/// 加入合集: the collections a book is in on top, the rest below by when they were last used.
/// Clicking a row puts the book in or takes it out at once; rows keep their place until it
/// opens again. Typing anywhere searches (pinyin and first letters too), and a name nobody
/// has yet can be made into a collection with the book already in it.
struct CollectionPicker: View {
    let library: Library
    let bookID: String
    var close: () -> Void = {}

    @State private var query = ""
    @State private var searching = false
    @State private var cursor: Int?
    @State private var hovered: String?
    /// The order fixed when the picker opened: the book's collections, then the others.
    @State private var inside: [String] = []
    @State private var others: [String] = []
    @FocusState private var focus: Focus?

    private enum Focus { case list, field }
    private let tint = YYTint.standard

    private var book: BookSummary? { library.books.first { $0.id == bookID } }

    var body: some View {
        VStack(spacing: 12) {
            if searching { field } else { header }
            if searching { results } else { groups }
        }
        .padding(12)
        .frame(width: 340)
        .background(YYColor.bg)
        .focusable(!searching)
        .focusEffectDisabled()
        .focused($focus, equals: .list)
        .onKeyPress(phases: .down) { key(press: $0) }
        .onAppear {
            let mine = Set(book?.collections ?? [])
            inside = library.collections.filter { mine.contains($0.id) }.map(\.id)
            others = library.collections.filter { !mine.contains($0.id) }.sorted { $0.usedAt > $1.usedAt }.map(\.id)
            focus = .list
        }
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            VStack(spacing: 1) {
                Text("加入合集")
                    .font(.yy(size: 13, weight: .semibold))
                    .foregroundStyle(YYColor.t1)
                Text(book?.title ?? "")
                    .font(.yy(size: 10.5))
                    .foregroundStyle(YYColor.t3)
                    .lineLimit(1)
            }
            .padding(.horizontal, 96)
            HStack {
                Button { startSearch() } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.yy(size: 13, weight: .medium))
                        .foregroundStyle(YYColor.t1)
                        .frame(width: 30, height: 30)
                        .background(YYColor.card, in: .circle)
                        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 0.5)
                }
                .accessibilityLabel(Text("找合集"))
                .buttonStyle(.plain)
                .help("找合集")
                Spacer()
                Button { startSearch() } label: {
                    Text("新建合集")
                        .font(.yy(size: 12, weight: .semibold))
                        .foregroundStyle(YYColor.t1)
                        .padding(.horizontal, 13)
                        .frame(height: 30)
                        .background(YYColor.card, in: .capsule)
                        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 0.5)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var field: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.yy(size: 12, weight: .medium))
                .foregroundStyle(YYColor.t2)
            TextField("找合集，或打个新名字", text: $query)
                .textFieldStyle(.plain)
                .font(.yy(size: 13))
                .focused($focus, equals: .field)
                .onKeyPress(phases: .down) { key(press: $0) }
                .onSubmit { activate() }
                .onChange(of: query) { cursor = query.isEmpty ? nil : 0 }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.yy(size: 13))
                        .foregroundStyle(YYColor.t3)
                }
                .accessibilityLabel(Text("清空"))
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(YYColor.card, in: .rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(tint.accent, lineWidth: 1.5))
    }

    // MARK: Lists

    private var groups: some View {
        VStack(spacing: 12) {
            if !inside.isEmpty {
                group(inside.compactMap(collection))
            }
            if !others.isEmpty {
                ScrollView {
                    group(others.compactMap(collection))
                }
                .scrollIndicators(.never)
                .frame(height: othersHeight)
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: others.count > visibleRows ? 28 : 0)
                    }
                }
            }
            if library.collections.isEmpty {
                Text("还没有合集，点右上角建一个")
                    .font(.yy(size: 12))
                    .foregroundStyle(YYColor.t3)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(YYColor.card, in: .rect(cornerRadius: YYRadius.block))
            }
        }
    }

    private let rowHeight: CGFloat = 50
    private let visibleRows = 7

    private var othersHeight: CGFloat {
        rowHeight * CGFloat(min(others.count, visibleRows)) + (others.count > visibleRows ? rowHeight / 2 : 0)
    }

    private var results: some View {
        VStack(spacing: 12) {
            let found = matches
            if !found.isEmpty {
                ScrollView {
                    group(found, offset: 0)
                }
                .scrollIndicators(.never)
                .frame(height: rowHeight * CGFloat(min(found.count, visibleRows)))
            }
            if canCreate {
                Button { create() } label: {
                    HStack(spacing: 12) {
                        tile("plus", background: tint.accentSoft, color: tint.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("新建合集“\(name)”")
                                .font(.yy(size: 13, weight: .semibold))
                                .foregroundStyle(tint.accent)
                                .lineLimit(1)
                            Text("建好就把这本书放进去")
                                .font(.yy(size: 11))
                                .foregroundStyle(YYColor.t3)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: rowHeight - 8)
                    .background(highlight(cursor == found.count), in: .rect(cornerRadius: 10))
                    .padding(4)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .background(YYColor.card, in: .rect(cornerRadius: YYRadius.block))
            } else if found.isEmpty {
                Text("打个名字就能建一个合集")
                    .font(.yy(size: 12))
                    .foregroundStyle(YYColor.t3)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(YYColor.card, in: .rect(cornerRadius: YYRadius.block))
            }
        }
    }

    private func group(_ items: [BookCollection], offset: Int? = nil) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                if i > 0 {
                    Rectangle().fill(YYColor.line).frame(height: 0.5).padding(.horizontal, 16)
                }
                row(c, lit: offset.map { cursor == $0 + i } ?? false)
            }
        }
        .padding(.vertical, 0)
        .background(YYColor.card, in: .rect(cornerRadius: YYRadius.block))
    }

    private func row(_ c: BookCollection, lit: Bool) -> some View {
        let on = book?.collections.contains(c.id) == true
        let matcher = NameMatcher(query)
        return Button { toggle(c) } label: {
            HStack(spacing: 12) {
                tile(CollectionIcon.symbol(for: c), background: YYColor.inset, color: YYColor.t1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(searching ? matcher.highlighted(c.name, color: tint.accent) : AttributedString(c.name))
                        .font(.yy(size: 13, weight: .semibold))
                        .foregroundStyle(YYColor.t1)
                        .lineLimit(1)
                    Text("\(c.count) 本")
                        .font(.yy(size: 11))
                        .foregroundStyle(YYColor.t3)
                }
                Spacer(minLength: 0)
                if on {
                    Image(systemName: "checkmark")
                        .font(.yy(size: 13, weight: .semibold))
                        .foregroundStyle(tint.accent)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: rowHeight - 8)
            .background(highlight(lit || hovered == c.id), in: .rect(cornerRadius: 10))
            .padding(4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? c.id : (hovered == c.id ? nil : hovered) }
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(on ? String(localized: "点一下从这个合集拿出来") : String(localized: "点一下放进这个合集"))
    }

    private func tile(_ symbol: String, background: Color, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.yy(size: 14, weight: .regular))
            .foregroundStyle(color)
            .frame(width: 32, height: 32)
            .background(background, in: .rect(cornerRadius: 9))
    }

    private func highlight(_ on: Bool) -> Color {
        on ? YYColor.inset.opacity(0.7) : .clear
    }

    // MARK: Data

    private func collection(_ id: String) -> BookCollection? {
        library.collections.first { $0.id == id }
    }

    private var name: String {
        query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private var matches: [BookCollection] {
        let matcher = NameMatcher(query)
        let all = (inside + others).compactMap(collection)
        return matcher.isEmpty ? all : all.filter { matcher.match($0.name) != nil }
    }

    private var canCreate: Bool {
        !name.isEmpty && !library.collections.contains { $0.name.lowercased() == name.lowercased() }
    }

    private var rowCount: Int { matches.count + (canCreate ? 1 : 0) }

    // MARK: Actions

    private func toggle(_ c: BookCollection) {
        let on = book?.collections.contains(c.id) == true
        withAnimation(.snappy(duration: 0.2)) {
            library.setBook(bookID, in: c.id, !on)
        }
    }

    private func create() {
        guard canCreate, let id = library.createCollection(name, with: bookID) else { return }
        inside.append(id)
        query = ""
        searching = false
        focus = .list
    }

    private func startSearch(with text: String = "") {
        query = text
        searching = true
        cursor = text.isEmpty ? nil : 0
        focus = .field
    }

    private func activate() {
        guard searching, let cursor else { return }
        let found = matches
        if cursor < found.count {
            toggle(found[cursor])
        } else {
            create()
        }
    }

    private func key(press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape:
            if searching, !query.isEmpty {
                query = ""
            } else if searching {
                searching = false
                focus = .list
            } else {
                close()
            }
            return .handled
        case .downArrow, .upArrow:
            if !searching { startSearch() }
            let n = rowCount
            guard n > 0 else { return .handled }
            let step = press.key == .downArrow ? 1 : -1
            cursor = ((cursor ?? (step > 0 ? -1 : n)) + step + n) % n
            return .handled
        case .return:
            activate()
            return .handled
        default:
            // Typing anywhere starts a search with what was typed.
            guard !searching, press.modifiers.isDisjoint(with: [.command, .control]),
                  let c = press.characters.first, c.isLetter || c.isNumber else { return .ignored }
            startSearch(with: press.characters)
            return .handled
        }
    }
}
