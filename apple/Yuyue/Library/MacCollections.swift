import SwiftUI
import YuyueCore
#if os(macOS)
import UniformTypeIdentifiers

/// 合集 kept in the shelf's sidebar (合集墙 › 固定到侧栏), in their order. The rest are on the
/// 合集墙 only. Kept on this Mac: the core's 合集 have no field for it, so it doesn't sync.
enum PinnedCollections {
    static let key = "shelf.pinnedCollections"

    static func ids(_ raw: String) -> [String] {
        raw.split(separator: "\n").map(String.init)
    }

    static func raw(_ ids: [String]) -> String {
        ids.joined(separator: "\n")
    }
}

/// 全部合集 (合集墙): each 合集 a little stack of its covers, its name, how many and when it was
/// last used. New, rename, delete and the order are here; a pin at the top right of the one under
/// the pointer (or 右键) keeps it in the sidebar.
struct CollectionWall: View {
    @Bindable var library: Library
    @Binding var pinnedRaw: String
    /// Room for the window's buttons when the sidebar is away.
    var leading: CGFloat = 0
    let open: (String) -> Void
    @AppStorage("collections.sort") private var sort = Sort.recent
    @State private var hovering: String?
    @State private var naming: Naming?
    @State private var name = ""
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }
    @AppStorage(EInk.key) private var eink = false

    enum Sort: String, CaseIterable {
        case recent, name, count, own

        var title: String {
            switch self {
            case .recent: String(localized: "最近用过")
            case .name: String(localized: "名字")
            case .count: String(localized: "书的多少")
            case .own: String(localized: "自己排的")
            }
        }
    }

    /// 新建合集, or 重命名 of one.
    private struct Naming: Identifiable {
        var id: String { collection ?? "" }
        let collection: String?
    }

    private var pinned: [String] { PinnedCollections.ids(pinnedRaw) }

    private var shown: [BookCollection] {
        let all = library.collections
        switch sort {
        case .recent: return all.sorted { $0.usedAt > $1.usedAt }
        case .name: return all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .count: return all.sorted { $0.count > $1.count }
        case .own: return all
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The same head as 生词本 · 笔记 · 播客: 56 high, down 8, 28 on the right.
            header
                .frame(height: 56)
                .padding(.top, 8)
                .padding(.leading, 22 + leading)
                .padding(.trailing, 28)
            if library.collections.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.stack").font(.yy(size: 28, weight: .light)).foregroundStyle(YYColor.t3)
                    Text("还没有合集。点右上角“新建合集”，或者在一本书上右键“加入合集…”")
                        .font(.yy(size: 12.5)).foregroundStyle(YYColor.t2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    HStack {
                        Text("\(library.collections.count) 个")
                            .font(.yy(size: 12.5, weight: .semibold))
                            .foregroundStyle(YYColor.t1)
                        Spacer()
                        sortMenu
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 160), spacing: 22, alignment: .top)], alignment: .leading, spacing: 26) {
                        ForEach(shown, id: \.id) { stack($0) }
                    }
                    .padding(.leading, 26)
                    .padding(.trailing, 26)
                    .padding(.bottom, 40)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(.container, edges: .top)
        .background(YYColor.bg)
        .alert(naming?.collection == nil ? String(localized: "新建合集") : String(localized: "重命名合集"), isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("合集的名字", text: $name)
            Button("取消", role: .cancel) { naming = nil }
            Button(naming?.collection == nil ? String(localized: "新建") : String(localized: "好")) { finishNaming() }
        }
    }

    /// The shelf's 最近读过 ⇅: grey words, a menu.
    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $sort) {
                ForEach(Sort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(sort.title)
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

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("全部合集")
                .font(.yy(size: 22, weight: .bold))
                .foregroundStyle(YYColor.t1)
            Spacer()
            // The same as 导入 on the shelf.
            Button {
                name = ""
                naming = Naming(collection: nil)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.yy(size: 11, weight: .semibold))
                    Text("新建合集")
                }
                .font(.yy(size: 12, weight: .medium))
                .foregroundStyle(YYColor.t1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .yyGlass(Capsule(), fill: YYColor.card, line: YYColor.line, shadow: 0, interactive: true, liquid: !eink)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
        }
    }

    /// Three covers fanned back from the front one, the pin over the top right.
    private func stack(_ c: BookCollection) -> some View {
        let books = library.books.filter { $0.collections.contains(c.id) }.sorted { ($0.openedAt ?? 0) > ($1.openedAt ?? 0) }
        let isPinned = pinned.contains(c.id)
        let hover = hovering == c.id
        return Button { open(c.id) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if hover {
                        RoundedRectangle(cornerRadius: 10).fill(tint.accentSoft.opacity(0.6))
                            .padding(EdgeInsets(top: -6, leading: -6, bottom: -4, trailing: -8))
                    }
                    ForEach(Array(books.prefix(3).enumerated().reversed()), id: \.offset) { i, book in
                        BookCover(book: book)
                            .frame(width: 72)
                            .shadow(color: .black.opacity(0.12 + 0.03 * Double(2 - i)), radius: 3, y: 2)
                            .offset(x: 2 + 16 * CGFloat(i), y: 16 - 6 * CGFloat(i))
                    }
                    if books.isEmpty {
                        RoundedRectangle(cornerRadius: 4).fill(YYColor.inset)
                            .frame(width: 72, height: 108)
                            .overlay(Image(systemName: CollectionIcon.symbol(for: c)).font(.yy(size: 20, weight: .light)).foregroundStyle(YYColor.t3))
                            .offset(x: 2, y: 16)
                    }
                }
                .frame(width: 128, height: 128, alignment: .topLeading)
                .overlay(alignment: .topTrailing) { pin(c, isPinned: isPinned, hover: hover) }
                Text(c.name)
                    .font(.yy(size: 12, weight: .semibold))
                    .foregroundStyle(YYColor.t1)
                    .lineLimit(1)
                Text(String(localized: "\(Int(c.count)) 本") + " · " + used(c))
                    .font(.yy(size: 10.5).monospacedDigit())
                    .foregroundStyle(YYColor.t3)
                    .lineLimit(1)
                    .padding(.top, -4)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 ? c.id : (hovering == c.id ? nil : hovering) }
        // Books dragged onto a stack go in.
        .onDrop(of: [.utf8PlainText, .plainText], isTargeted: nil) { providers in
            BookDrag.ids(providers) { ids in
                for id in ids where !id.hasPrefix(PinnedCollections.dragPrefix) { library.setBook(id, in: c.id, true) }
            }
            return true
        }
        .contextMenu {
            Button(isPinned ? String(localized: "取消固定") : String(localized: "固定到侧栏")) { togglePin(c.id) }
            Divider()
            Button("重命名") {
                name = c.name
                naming = Naming(collection: c.id)
            }
            CollectionIconMenu(collection: c, library: library)
            if sort == .own {
                Button("往前挪") { move(c.id, by: -1) }
                Button("往后挪") { move(c.id, by: 1) }
            }
            Divider()
            Button("删除合集", role: .destructive) {
                pinnedRaw = PinnedCollections.raw(pinned.filter { $0 != c.id })
                library.deleteCollection(c)
            }
        }
        .accessibilityLabel("\(c.name)，\(Int(c.count)) 本")
        .accessibilityAction(named: isPinned ? String(localized: "取消固定") : String(localized: "固定到侧栏")) { togglePin(c.id) }
    }

    @ViewBuilder private func pin(_ c: BookCollection, isPinned: Bool, hover: Bool) -> some View {
        if hover {
            Button { togglePin(c.id) } label: {
                Image(systemName: isPinned ? "pin.slash" : "pin")
                    .accessibilityLabel(isPinned ? Text("取消固定") : Text("固定到侧栏"))
                    .font(.yy(size: 12, weight: .medium))
                    .foregroundStyle(tint.accent)
                    .frame(width: 26, height: 26)
                    .background(YYColor.card, in: .circle)
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help(isPinned ? String(localized: "取消固定") : String(localized: "固定到侧栏"))
        } else if isPinned {
            Image(systemName: "pin.fill")
                .font(.yy(size: 11))
                .foregroundStyle(tint.accent)
                .padding(4)
                .accessibilityHidden(true)
        }
    }

    private func used(_ c: BookCollection) -> String {
        guard c.usedAt > 0 else { return String(localized: "没用过") }
        return ShortAgo.short(Date(timeIntervalSince1970: Double(c.usedAt) / 1000))
    }

    private func togglePin(_ id: String) {
        var ids = pinned
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
        pinnedRaw = PinnedCollections.raw(ids)
    }

    /// 自己排的: one place earlier or later.
    private func move(_ id: String, by step: Int) {
        var ids = library.collections.map(\.id)
        guard let i = ids.firstIndex(of: id), ids.indices.contains(i + step) else { return }
        ids.swapAt(i, i + step)
        library.reorderCollections(ids)
    }

    private func finishNaming() {
        let text = name.trimmingCharacters(in: .whitespaces)
        defer { naming = nil }
        guard !text.isEmpty else { return }
        if let id = naming?.collection {
            library.renameCollection(id, to: text)
        } else {
            _ = library.createCollection(text)
        }
    }
}

/// 最近用过: 今天, 昨天, 3 天前, 10 月 2 日.
enum ShortAgo {
    static func short(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return String(localized: "今天") }
        if cal.isDateInYesterday(date) { return String(localized: "昨天") }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: .now)).day ?? 0
        if days < 7 { return String(localized: "\(days) 天前") }
        return date.formatted(.dateTime.month().day())
    }
}

/// The ids of books dragged from the shelf (each a cover's `draggable(book.id)`).
enum BookDrag {
    static func ids(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([String]) -> Void) {
        let group = DispatchGroup()
        nonisolated(unsafe) var ids: [String] = []
        let lock = NSLock()
        for p in providers where p.canLoadObject(ofClass: String.self) {
            group.enter()
            _ = p.loadObject(ofClass: String.self) { s, _ in
                if let s { lock.lock(); ids.append(s); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { done(ids) } }
    }
}

/// A book held over the sidebar's “合集” for a moment: every 合集, to drop it on one. Typing
/// finds one; the last row makes a new one with the book in it.
struct CollectionDropList: View {
    @Bindable var library: Library
    let done: () -> Void
    @State private var query = ""
    @State private var target: String?
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    private var shown: [BookCollection] {
        let all = library.collections.sorted { $0.usedAt > $1.usedAt }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("", text: $query, prompt: Text("放进哪个合集… 打字找"))
                .textFieldStyle(.plain)
                .font(.yy(size: 11.5))
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(YYColor.inset, in: .rect(cornerRadius: 8))
                .padding(.bottom, 2)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(shown, id: \.id) { c in
                        row(c.name, count: Int(c.count), id: c.id) { ids in
                            for id in ids { library.setBook(id, in: c.id, true) }
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
            row(query.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "＋ 新建合集并放进去") : String(localized: "＋ 新建合集“\(query.trimmingCharacters(in: .whitespaces))”并放进去"),
                count: nil, id: "+new", accent: true) { ids in
                let name = query.trimmingCharacters(in: .whitespaces)
                guard let first = ids.first, let id = library.createCollection(name.isEmpty ? String(localized: "新合集") : name, with: first) else { return }
                for book in ids.dropFirst() { library.setBook(book, in: id, true) }
            }
        }
        .padding(8)
        .frame(width: 230)
    }

    private func row(_ title: String, count: Int?, id: String, accent: Bool = false, put: @escaping @MainActor ([String]) -> Void) -> some View {
        let hot = target == id
        return HStack {
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            if let count { Text("\(count)").font(.yy(size: 10.5)).foregroundStyle(hot ? .white.opacity(0.8) : YYColor.t3) }
        }
        .font(.yy(size: 12))
        .foregroundStyle(hot ? .white : accent ? tint.accent : YYColor.t1)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(hot ? tint.fill : .clear, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onDrop(of: [.utf8PlainText, .plainText], isTargeted: Binding(get: { hot }, set: { target = $0 ? id : (target == id ? nil : target) })) { providers in
            BookDrag.ids(providers) { ids in
                put(ids)
                done()
            }
            return true
        }
    }
}

extension PinnedCollections {
    /// What a pinned row carries when dragged, to tell it from a book's id.
    static let dragPrefix = "yuyue-pinned:"
}
#endif

extension EnvironmentValues {
    /// Room the shelf window's pages leave at the left of their title for the window's buttons
    /// (and 显示侧栏) when the sidebar is put away.
    @Entry var shelfHeaderInset: CGFloat = 0
}
