#if os(iOS)
import SwiftUI
import UIKit

/// 书库来源: the libraries filled in, each opening onto its catalogue, and a way to add one.
struct PhoneSources: View {
    let library: Library
    @State private var editing: RemoteSource?
    @State private var adding = false

    var body: some View {
        YYPage {
            YYGroup {
                ForEach(library.sources.all) { source in
                    NavigationLink { PhoneRemoteBrowser(library: library, source: source) } label: { row(source) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("修改", systemImage: "pencil") { editing = source }
                            Button("删除", systemImage: "trash", role: .destructive) { library.sources.remove(source) }
                        }
                }
                Button { adding = true } label: {
                    YYRow(String(localized: "添加书库"), icon: "plus", chevron: true)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, YYUI.s(10))
            YYNote(String(localized: "Calibre、Kavita、Komga 用 OPDS；坚果云、群晖、NAS 用 WebDAV。一次填好，以后在导入里直接翻。"))
        }
        .navigationTitle("书库来源")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $adding) { PhoneSourceForm(library: library, source: nil) }
        .navigationDestination(item: $editing) { PhoneSourceForm(library: library, source: $0) }
    }

    /// `.v-r2`: the tile, the name, what kind and where.
    private func row(_ source: RemoteSource) -> some View {
        HStack(spacing: YYUI.s(10)) {
            Image(systemName: "server.rack")
                .font(YYUI.font(12, .medium))
                .foregroundStyle(YYColor.t1)
                .frame(width: YYUI.s(28), height: YYUI.s(28))
                .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(8)))
            VStack(alignment: .leading, spacing: YYUI.s(1)) {
                Text(source.name).font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                Text(source.line).font(YYUI.font(10)).foregroundStyle(YYColor.t3).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(YYUI.font(9, .semibold)).foregroundStyle(YYColor.t3)
        }
        .padding(.vertical, YYUI.s(8))
        .contentShape(.rect)
    }
}

/// Filling a library in: which kind, what to call it, where it is, the login. Saved once it
/// answers; when it doesn't, which step failed.
struct PhoneSourceForm: View {
    let library: Library
    let source: RemoteSource?
    @State private var kind = RemoteSource.Kind.opds
    @State private var name = ""
    @State private var address = ""
    @State private var user = ""
    @State private var password = ""
    @State private var checking = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    init(library: Library, source: RemoteSource?) {
        self.library = library
        self.source = source
        if let source {
            _kind = State(initialValue: source.kind)
            _name = State(initialValue: source.name)
            _address = State(initialValue: source.url.absoluteString)
            _user = State(initialValue: source.user)
            _password = State(initialValue: source.password)
        }
    }

    var body: some View {
        YYPage {
            YYSegments(items: [(RemoteSource.Kind.opds, "OPDS"), (.webdav, "WebDAV")], selection: $kind)
                .padding(.top, YYUI.s(10))
                .padding(.bottom, YYUI.s(10))
            YYGroup {
                YYField(label: String(localized: "名称")) { TextField("", text: $name, prompt: Text(kind == .opds ? String(localized: "家里的 Calibre") : String(localized: "坚果云"))) }
                YYField(label: String(localized: "地址")) {
                    TextField("", text: $address, prompt: Text(kind == .opds ? "http://192.168.1.8:8080/opds" : "https://dav.jianguoyun.com/dav/"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                YYField(label: String(localized: "用户名")) {
                    TextField("", text: $user, prompt: Text("没有就空着"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                }
                YYField(label: String(localized: "密码")) { SecureField("", text: $password, prompt: Text(kind == .webdav ? String(localized: "坚果云填应用密码") : String(localized: "没有就空着"))).textContentType(.password) }
            }
            YYNote(kind == .opds
                   ? String(localized: "Calibre：http://电脑地址:8080/opds\nKavita：设置里的 OPDS 地址，带着 API 密钥\nKomga：http://地址:25600/opds/v1.2/catalog")
                   : String(localized: "填到放书的那个文件夹。坚果云的密码要在网页版“安全选项”里生成应用密码。"))
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(YYUI.font(11)).foregroundStyle(YYColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, YYUI.s(4))
                    .padding(.top, YYUI.s(12))
            }
            Button {
                Task { await connect() }
            } label: {
                if checking { ProgressView().controlSize(.small).tint(YYTint.standard.onBlack) } else { Text("连接并保存") }
            }
            .buttonStyle(YYButtonStyle(kind: .main, size: .large, wide: true))
            .disabled(checking || address.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.top, YYUI.s(18))
        }
        .navigationTitle(source == nil ? String(localized: "添加书库") : String(localized: "修改书库"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func connect() async {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        if kind == .webdav, !text.hasSuffix("/") { text += "/" }
        guard let url = URL(string: text), url.host() != nil else {
            problem = String(localized: "地址不对，像这样：http://192.168.1.8:8080/opds")
            return
        }
        var made = source ?? RemoteSource(name: "", kind: kind, url: url)
        made.kind = kind
        made.url = url
        made.user = user.trimmingCharacters(in: .whitespaces)
        made.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? (url.host() ?? String(localized: "书库")) : name.trimmingCharacters(in: .whitespaces)
        checking = true
        problem = nil
        defer { checking = false }
        do {
            _ = try await RemoteClient(made, password: password).feed()
            library.sources.save(made, password: password)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// 远程书库 (prototype): the catalogue's ways in as chips at the top, then its books — each with
/// a download button, a ring while it comes, or 在书架.
struct PhoneRemoteBrowser: View {
    let library: Library
    let source: RemoteSource
    /// A page further in; the start when nil.
    var url: URL?
    var title: String?
    @State private var feed: RemoteFeed?
    @State private var chips: [RemoteEntry] = []
    @State private var chip: RemoteEntry?
    @State private var problem: String?
    @State private var loadingMore = false
    @State private var query = ""
    @State private var searching = false
    private let tint = YYTint.standard

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if chips.count > 1 { chipRow }
                if let problem {
                    VStack(spacing: YYUI.s(12)) {
                        Image(systemName: "exclamationmark.triangle").font(.yy(size: 26, weight: .light)).foregroundStyle(YYColor.t3)
                        Text(problem).font(YYUI.font(11.5)).foregroundStyle(YYColor.t2).multilineTextAlignment(.center)
                        Button("再试一次") { Task { await load() } }.buttonStyle(YYButtonStyle(kind: .raised))
                    }
                    .padding(.horizontal, YYUI.s(30))
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else if let feed {
                    if feed.entries.isEmpty {
                        Text(searching ? String(localized: "没有找到") : String(localized: "这里没有书")).font(YYUI.font(11.5)).foregroundStyle(YYColor.t3)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        list(feed)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
                if url == nil {
                    YYNote(String(localized: "书库在“我的 › 书库来源”里添加，一次填好，以后在这里直接翻。"))
                        .padding(.horizontal, YYUI.s(6))
                }
            }
            .padding(.horizontal, YYUI.s(16))
            .padding(.bottom, YYUI.s(24))
        }
        .background(YYColor.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(title ?? source.name).font(YYUI.font(13, .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                    if url == nil { Text(source.line).font(YYUI.font(10)).foregroundStyle(YYColor.t3) }
                }
            }
        }
        .modifier(Searchable(on: feed?.search != nil, query: $query) { Task { await search() } } cancel: {
            guard searching else { return }
            searching = false
            Task { await load() }
        })
        .task { if feed == nil { await load() } }
    }

    /// `.v-chips`: the start page's ways in — 最新, 作者, 系列 — one at a time.
    private var chipRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: YYUI.s(6)) {
                ForEach(chips) { c in
                    let on = chip?.id == c.id
                    Button {
                        chip = c
                        Task { await open(c) }
                    } label: {
                        Text(c.title)
                            .font(YYUI.font(10.5, on ? .semibold : .regular))
                            .foregroundStyle(on ? tint.onBlack : YYColor.t2)
                            .padding(.horizontal, YYUI.s(11))
                            .frame(height: YYUI.s(28))
                            .background(on ? AnyShapeStyle(tint.black) : AnyShapeStyle(YYColor.card), in: .capsule)
                            .overlay(Capsule().strokeBorder(on ? .clear : YYColor.line, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, YYUI.s(16))
            .padding(.vertical, YYUI.s(2))
        }
        .scrollIndicators(.never)
        .padding(.horizontal, -YYUI.s(16))
        .padding(.top, YYUI.s(8))
    }

    /// `.v-lib-ol`: one white card, a row a line.
    private func list(_ feed: RemoteFeed) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(feed.entries.enumerated()), id: \.element.id) { i, entry in
                if i > 0 { Rectangle().fill(YYColor.line).frame(height: 0.5) }
                row(entry)
                    .onAppear {
                        if entry.id == feed.entries.last?.id, feed.next != nil { Task { await more() } }
                    }
            }
            if loadingMore { ProgressView().padding(.vertical, YYUI.s(10)) }
        }
        .padding(.horizontal, YYUI.s(14))
        .yyCard()
        .padding(.top, YYUI.s(12))
    }

    @ViewBuilder private func row(_ entry: RemoteEntry) -> some View {
        switch entry.kind {
        case .folder:
            NavigationLink {
                PhoneRemoteBrowser(library: library, source: source, url: folderURL(entry), title: entry.title)
            } label: {
                HStack(spacing: YYUI.s(10)) {
                    Image(systemName: "folder").font(YYUI.font(12, .medium)).foregroundStyle(YYColor.t1)
                        .frame(width: YYUI.s(28), height: YYUI.s(28))
                        .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(8)))
                    Text(entry.title).font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(YYUI.font(9, .semibold)).foregroundStyle(YYColor.t3)
                }
                .padding(.vertical, YYUI.s(10))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        case .book:
            HStack(spacing: YYUI.s(10)) {
                RemoteCover(source: source, entry: entry).frame(width: YYUI.s(34), height: YYUI.s(51))
                VStack(alignment: .leading, spacing: YYUI.s(2)) {
                    Text(entry.title).font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1).lineLimit(2)
                    Text(detail(entry)).font(YYUI.font(10).monospacedDigit()).foregroundStyle(YYColor.t3).lineLimit(1)
                }
                Spacer(minLength: 0)
                action(entry)
            }
            .padding(.vertical, YYUI.s(10))
        }
    }

    private func folderURL(_ entry: RemoteEntry) -> URL? {
        if case .folder(let url) = entry.kind { url } else { nil }
    }

    /// `萧红 · EPUB · 1.6 MB`, or `正在下载 40%` while it comes.
    private func detail(_ entry: RemoteEntry) -> String {
        var parts = [entry.author, entry.format].compactMap { $0 }
        if let fraction = library.sources.downloading[RemoteSources.key(source, entry)] {
            parts.append(String(localized: "正在下载 \(Int(fraction * 100))%"))
        } else if let size = entry.size, size > 0 {
            parts.append(Snapshots.size(UInt64(size)))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func action(_ entry: RemoteEntry) -> some View {
        if let fraction = library.sources.downloading[RemoteSources.key(source, entry)] {
            // `.v-ring`
            ZStack {
                Circle().stroke(YYColor.inset, lineWidth: YYUI.s(3))
                Circle().trim(from: 0, to: max(0.03, fraction)).stroke(tint.accent, style: StrokeStyle(lineWidth: YYUI.s(3)))
                    .rotationEffect(.degrees(-90))
            }
            .padding(YYUI.s(1.5))
            .frame(width: YYUI.s(30), height: YYUI.s(30))
            .animation(.linear(duration: 0.25), value: fraction)
            .accessibilityLabel("正在下载 \(Int(fraction * 100))%")
        } else if library.sources.has(entry, from: source, in: library) {
            // `.v-have`
            HStack(spacing: YYUI.s(2)) {
                Image(systemName: "checkmark").font(YYUI.font(9, .semibold))
                Text("在书架")
            }
            .font(YYUI.font(10))
            .foregroundStyle(YYColor.t3)
        } else {
            // `.v-get`
            Button {
                Task {
                    do { try await library.sources.take(entry, from: source, into: library) } catch is CancellationError {} catch {
                        library.alert = String(localized: "《\(entry.title)》没有下载下来：\(error.localizedDescription)")
                    }
                }
            } label: {
                Image(systemName: "arrow.down").font(YYUI.font(12, .semibold)).foregroundStyle(YYColor.t1)
                    .frame(width: YYUI.s(30), height: YYUI.s(30))
                    .background(YYColor.inset, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下载《\(entry.title)》")
        }
    }

    // MARK: Loading

    private func load() async {
        problem = nil
        do {
            let page = try await RemoteClient(source).feed(url)
            // At the start, a catalogue of only ways in shows them as chips, the first one open.
            if url == nil, !page.entries.isEmpty, page.entries.allSatisfy({ !$0.isBook }), source.kind == .opds {
                chips = page.entries
                let first = chip.flatMap { c in chips.first { $0.id == c.id } } ?? chips[0]
                chip = first
                var opened = try await RemoteClient(source).feed(folderURL(first))
                opened.search = opened.search ?? page.search
                feed = opened
            } else {
                feed = page
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    private func open(_ c: RemoteEntry) async {
        let search = feed?.search
        feed = nil
        problem = nil
        do {
            var opened = try await RemoteClient(source).feed(folderURL(c))
            opened.search = opened.search ?? search
            if chip?.id == c.id { feed = opened }
        } catch {
            problem = error.localizedDescription
        }
    }

    private func more() async {
        guard !loadingMore, let next = feed?.next else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await RemoteClient(source).feed(next) else { return }
        feed?.entries += page.entries.filter { e in !(feed?.entries.contains { $0.id == e.id } ?? false) }
        feed?.next = page.next
    }

    private func search() async {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty, let template = feed?.search, let target = RemoteClient(source).search(template, words) else { return }
        searching = true
        let keep = template
        feed = nil
        do {
            var found = try await RemoteClient(source).feed(target)
            found.search = found.search ?? keep
            feed = found
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A search field only where the catalogue has a search.
private struct Searchable: ViewModifier {
    let on: Bool
    @Binding var query: String
    let submit: () -> Void
    let cancel: () -> Void

    func body(content: Content) -> some View {
        if on {
            content
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: String(localized: "搜书名、作者"))
                .onSubmit(of: .search, submit)
                .onChange(of: query) { _, q in if q.isEmpty { cancel() } }
        } else {
            content
        }
    }
}

/// The catalogue's cover, through the same login; a coloured block with the title until then.
struct RemoteCover: View {
    let source: RemoteSource
    let entry: RemoteEntry
    @State private var image: UIImage?
    private static let cache = NSCache<NSString, UIImage>()
    private static let colors: [Color] = [Color(red: 0.48, green: 0.23, blue: 0.18), Color(red: 0.24, green: 0.30, blue: 0.37),
                                          Color(red: 0.36, green: 0.43, blue: 0.31), Color(red: 0.16, green: 0.13, blue: 0.14),
                                          Color(red: 0.55, green: 0.42, blue: 0.25)]

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                let color = Self.colors[abs(entry.title.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % Self.colors.count]
                color.overlay {
                    Text(entry.title)
                        .font(YYUI.serif(YYUI.s(6.5), .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(YYUI.s(3))
                }
            }
        }
        .clipShape(.rect(cornerRadius: YYUI.s(3)))
        .overlay(RoundedRectangle(cornerRadius: YYUI.s(3)).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
        .task(id: entry.cover) {
            guard let url = entry.cover else { return }
            if let hit = Self.cache.object(forKey: url.absoluteString as NSString) { image = hit; return }
            guard let data = try? await RemoteClient(source).data(url), let made = UIImage(data: data) else { return }
            let small = made.preparingThumbnail(of: CGSize(width: 120, height: 180)) ?? made
            Self.cache.setObject(small, forKey: url.absoluteString as NSString)
            image = small
        }
    }
}
#endif

#if os(iOS)
/// 导入 › 远程书库: straight into the one library there is, or the list to pick from.
struct PhoneRemoteStart: View {
    let library: Library

    var body: some View {
        if library.sources.all.count == 1, let only = library.sources.all.first {
            PhoneRemoteBrowser(library: library, source: only)
        } else {
            PhoneSources(library: library)
        }
    }
}
#endif
