#if os(macOS)
import SwiftUI
import AppKit

/// 设置 · 书伴. The middle is one list: this Mac's own (Apple 智能), the services added, 添加服务商.
/// Choosing one puts it in the right column: its model, 书伴用它, its key, 检查连接, 移除. Its
/// model opens a list there that can be searched: 在用, 最近用过, 推荐, then all it lists.
struct CompanionSettings: View {
    let library: Library
    private var focus: CompanionFocus { .shared }

    var body: some View {
        let choice = focus.choice
        let _ = focus.tick
        VStack(alignment: .leading, spacing: 12) {
            SettingsHeading(String(localized: "书伴用哪家"))
            SettingsCard {
                let apple = Companion.appleAvailability == nil
                ServiceRow(selected: focus.page == .service(CompanionProvider.apple.id) || focus.page == nil && choice.current.provider.kind == .apple,
                           dim: !apple) {
                    ServiceTile(mark: .thisMac)
                } title: {
                    Text("这台 Mac")
                    if apple && choice.current.provider.kind == .apple { InUsePill() }
                } detail: {
                    Text("Apple 智能 · 不花钱、不联网")
                } trailing: {
                    if !apple { SettingsPill(String(localized: "这台 Mac 不支持"), tone: .warn) }
                } action: { focus.page = .service(CompanionProvider.apple.id) }

                ForEach(choice.added) { p in
                    let config = CompanionConfig.saved(p)
                    ServiceRow(selected: focus.shows(p.id) || focus.page == nil && choice.current.provider == p) {
                        ServiceTile(mark: .provider(p))
                    } title: {
                        Text(p.title)
                        if choice.current.provider == p { InUsePill() }
                    } detail: {
                        Text(([config.model.isEmpty ? String(localized: "还没选模型") : ModelNames.name(config.model)]
                              + (config.key.isEmpty ? [] : ["Key " + config.maskedKey])).joined(separator: " · "))
                    } trailing: {
                        EmptyView()
                    } action: { focus.page = .service(p.id) }
                }

                ServiceRow(selected: false) {
                    ServiceTile(mark: .add)
                } title: {
                    Text("添加服务商").foregroundStyle(YYColor.t2)
                } detail: {
                    Text("Claude、OpenAI、DeepSeek、Gemini、Kimi、通义、本机 Ollama…")
                } trailing: {
                    EmptyView()
                } action: { focus.sheet = .add }
            }
            SettingsNote(String(localized: "Key 只存在这台 Mac 的钥匙串里，不同步、不上传；费用直接走你的账号，语阅不经手。写播客稿也用书伴在用的这个模型。"))
            Spacer(minLength: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            focus.tick &+= 1
        }
        .sheet(item: Binding(get: { focus.sheet }, set: { focus.sheet = $0 }), onDismiss: { focus.reload() }) {
            CompanionProviderSheet(start: $0).buttonStyle(.automatic)
        }
        .onAppear {
            focus.reload()
            #if DEBUG
            // `-debugCompanion add` opens 添加服务商, `edit:<id>` its form, `<id>` that service in the right column.
            if let d = UserDefaults.standard.string(forKey: "debugCompanion") {
                if d == "add" { focus.sheet = .add }
                else if d.hasPrefix("edit:"), let p = CompanionProvider.find(String(d.dropFirst(5))) { focus.sheet = .edit(p) }
                else { focus.page = .service(d) }
            }
            #endif
        }
    }
}

/// What the right column of 书伴 shows, and the state the two columns share.
@MainActor @Observable
final class CompanionFocus {
    static let shared = CompanionFocus()

    enum Page: Hashable {
        case service(String)
        case models(String)
    }

    /// nil: the service 书伴 uses.
    var page: Page?
    /// 添加服务商 stays a sheet; a service added is changed in the right column.
    var sheet: CompanionProviderSheet.Start?
    let choice = CompanionChoice()
    /// Bumped when the defaults change (an undo, a sheet), so both columns read them again.
    var tick = 0

    func reload() {
        choice.reload()
        if case .service(let id) = page, id != CompanionProvider.apple.id, CompanionProvider.find(id).map({ p in choice.added.contains(p) }) != true { page = nil }
        tick &+= 1
    }

    func shows(_ id: String) -> Bool { page == .service(id) || page == .models(id) }

    /// The service the right column is about.
    var provider: CompanionProvider {
        switch page {
        case .service(let id), .models(let id): CompanionProvider.find(id) ?? choice.current.provider
        case nil: choice.current.provider
        }
    }
}

// MARK: - The right column

/// 书伴 in the right column: the service chosen in the middle, or its models.
struct CompanionInspector: View {
    private var focus: CompanionFocus { .shared }

    var body: some View {
        let _ = focus.tick
        let p = focus.provider
        Group {
            if case .models = focus.page {
                ModelList(provider: p)
            } else {
                ServicePanel(provider: p)
            }
        }
        .id(p.id + (focus.page.map { "\($0)" } ?? ""))
        .transition(.opacity.combined(with: .offset(y: 3)))
    }
}

/// One service: its model, 书伴用它, its key, 检查连接, 移除.
private struct ServicePanel: View {
    let provider: CompanionProvider
    @State private var checking = false
    @State private var result: Result<TimeInterval, Error>?
    @State private var removing = false
    private var focus: CompanionFocus { .shared }

    var body: some View {
        let _ = focus.tick
        let config = CompanionConfig.saved(provider)
        let inUse = focus.choice.current.provider == provider
        let apple = provider.kind == .apple
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: apple ? String(localized: "这台 Mac") : provider.title,
                        detail: inUse ? String(localized: "书伴在用") : (apple ? String(localized: "Apple 智能") : provider.account)) {
                ServiceTile(mark: apple ? .thisMac : .provider(provider), size: 28)
            }
            if apple, let why = Companion.appleAvailability {
                PanelCard {
                    PanelRow { Text("Apple 智能") } trailing: { SettingsPill(String(localized: "用不了"), tone: .warn) }
                }
                PanelHint(why + String(localized: "。打开以后书伴不花钱、不联网也能用。"))
                PanelCard {
                    PanelButton(systemImage: "arrow.up.forward.app", tint: YYColor.t1) {
                        Text("打开系统设置")
                    } action: {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                    }
                }
            } else {
                PanelCard {
                    if !apple {
                        PanelButton {
                            Text("模型")
                            Spacer(minLength: 8)
                            Text(config.model.isEmpty ? String(localized: "选一个") : ModelNames.name(config.model))
                                .foregroundStyle(config.model.isEmpty ? YYColor.t3 : YYColor.t1).lineLimit(1)
                            Image(systemName: "chevron.right").font(.yy(size: 9.5, weight: .semibold)).foregroundStyle(YYColor.t3)
                        } action: { focus.page = .models(provider.id) }
                    }
                    PanelRow { Text("书伴用它") } trailing: {
                        Toggle("书伴用它", isOn: Binding(get: { inUse }, set: { on in
                            guard on, !inUse else { return }
                            CompanionConfig.current = CompanionConfig.saved(provider)
                            focus.reload()
                        }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(YYTint.standard.fill)
                        .disabled(inUse)
                    }
                }
                if !apple {
                    ServiceKeyCard(provider: provider)
                }
                PanelCard { check(config) }
                if !apple {
                    PanelCard {
                        PanelButton(tint: YYColor.danger, destructive: true) {
                            Text("移除 \(provider.title)")
                        } action: { removing = true }
                    }
                    .confirmationDialog(String(localized: "移除 \(provider.title)？"), isPresented: $removing) {
                        Button("移除", role: .destructive) {
                            CompanionConfig.remove(provider)
                            focus.page = nil
                            focus.reload()
                        }
                    } message: {
                        Text("它的 Key 也从钥匙串里删掉。")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    /// 检查连接, in green: asks it one short question; the answer is how long it took.
    private func check(_ config: CompanionConfig) -> some View {
        PanelButton(systemImage: "waveform.path.ecg", tint: YYColor.ok) {
            Text("检查连接").foregroundStyle(YYColor.ok)
            Spacer(minLength: 8)
            if checking {
                ProgressView().controlSize(.mini)
            } else {
                switch result {
                case .success(let t)?:
                    SettingsPill(String(localized: "正常 · \(t.formatted(.number.precision(.fractionLength(1)))) 秒"), tone: .ok)
                case .failure(let e)?:
                    Text(Companion.message(for: e)).font(.yy(size: 11)).foregroundStyle(YYColor.danger)
                        .lineLimit(2).multilineTextAlignment(.trailing)
                case nil:
                    Text(config.isReady ? "" : String(localized: "还没填好")).font(.yy(size: 11)).foregroundStyle(YYColor.t3)
                }
            }
        } action: {
            guard config.isReady, !checking else { return }
            checking = true
            result = nil
            Task {
                result = await CompanionTest.run(config)
                checking = false
            }
        }
    }
}

/// A service's models in the right column: a search line; then 在用, 最近用过, 推荐 and all of
/// them (grouped by maker when the service resells others'). Typing narrows the list; return
/// takes the first; a name not in it can still be used.
private struct ModelList: View {
    let provider: CompanionProvider
    @State private var query = ""
    @State private var models: [String] = []
    @State private var loading = true
    @State private var failed = false
    @FocusState private var searching: Bool
    private var focus: CompanionFocus { .shared }

    var body: some View {
        let _ = focus.tick
        let current = CompanionConfig.saved(provider).model
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { focus.page = .service(provider.id) } label: {
                    Image(systemName: "chevron.left").font(.yy(size: 11, weight: .semibold)).foregroundStyle(YYColor.t2)
                        .frame(width: 24, height: 24).contentShape(.circle)
                }
                .buttonStyle(HoverCircleStyle())
                .help(Text("回到 \(provider.title)"))
                ServiceTile(mark: .provider(provider), size: 26)
                Text("选一个模型").font(.yy(size: 13.5, weight: .semibold)).foregroundStyle(YYColor.t1)
                Spacer(minLength: 0)
            }
            .padding(.leading, -4)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.yy(size: 11.5)).foregroundStyle(YYColor.t3)
                TextField("", text: $query, prompt: Text(models.isEmpty ? String(localized: "搜模型名或 id") : String(localized: "搜 \(models.count) 个模型：名字或 id")))
                    .textFieldStyle(.plain).font(.yy(size: 12.5))
                    .focused($searching)
                    .onSubmit { if let first = hits.first { choose(first) } else if !trimmed.isEmpty { choose(trimmed) } }
                    .onKeyPress(.escape) {
                        if query.isEmpty { focus.page = .service(provider.id) } else { query = "" }
                        return .handled
                    }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(YYColor.inset, in: .rect(cornerRadius: 8))

            if trimmed.isEmpty { sections(current: current) } else { results(current: current) }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .task {
            searching = true
            let config = CompanionConfig.saved(provider)
            do {
                models = try await Companion.models(config).sorted()
                failed = false
            } catch {
                failed = true
            }
            loading = false
        }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var hits: [String] {
        let q = trimmed.lowercased()
        return models.filter { $0.lowercased().contains(q) || ModelNames.name($0).lowercased().contains(q) }
    }

    @ViewBuilder private func sections(current: String) -> some View {
        let recs = ModelNames.recommended[provider.id, default: []].filter { r in models.isEmpty || models.contains(r.id) }
        let recent = ModelNames.recent(provider.id).filter { $0 != current }
        if !current.isEmpty && !recs.contains(where: { $0.id == current }) {
            PanelLabel(String(localized: "在用"))
            PanelCard { item(current, current: current) }
        }
        if !recent.isEmpty {
            PanelLabel(String(localized: "最近用过"))
            PanelCard { ForEach(recent, id: \.self) { item($0, current: current) } }
        }
        if !recs.isEmpty {
            PanelLabel(String(localized: "推荐"))
            PanelCard { ForEach(recs, id: \.id) { item($0.id, why: $0.why, current: current) } }
        }
        if loading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("正在问 \(provider.title) 有哪些模型…").font(.yy(size: 11)).foregroundStyle(YYColor.t3)
            }
            .padding(.leading, 12)
        } else if failed {
            PanelHint(String(localized: "没问到它有哪些模型：检查一下 Key 和网络。也可以直接在上面打模型的名字，回车就用它。"))
        } else if models.count > recs.count {
            PanelLabel(String(localized: "全部 \(models.count) 个"))
            let groups = ModelNames.groups(models)
            if groups.count > 1 {
                ForEach(groups, id: \.maker) { g in
                    HStack(spacing: 6) {
                        Text(g.maker).font(.yy(size: 11, weight: .semibold)).foregroundStyle(YYColor.t3)
                        Spacer()
                        Text("\(g.models.count)").font(.yy(size: 11)).foregroundStyle(YYColor.t3).monospacedDigit()
                    }
                    .padding(.horizontal, 12).padding(.bottom, -4)
                    PanelCard { ForEach(g.models, id: \.self) { item($0, current: current) } }
                }
            } else {
                PanelCard { ForEach(models, id: \.self) { item($0, current: current) } }
            }
        }
    }

    @ViewBuilder private func results(current: String) -> some View {
        let found = hits
        Text(found.isEmpty ? String(localized: "没有叫这个的") : String(localized: "找到 \(found.count) 个 · 回车选第一个"))
            .font(.yy(size: 11)).foregroundStyle(YYColor.t3).padding(.leading, 12)
        PanelCard {
            ForEach(Array(found.prefix(40).enumerated()), id: \.element) { i, m in
                item(m, current: current, first: i == 0, highlight: trimmed)
            }
            if !models.contains(trimmed) {
                PanelButton {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("用“\(trimmed)”这个名字").foregroundStyle(YYColor.t1)
                        Text("列表里没有的新模型，照这个名字去问").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
                    }
                    Spacer(minLength: 0)
                } action: { choose(trimmed) }
            }
        }
    }

    private func item(_ id: String, why: String? = nil, current: String, first: Bool = false, highlight: String = "") -> some View {
        let on = id == current
        return PanelButton(selected: on, outlined: first) {
            VStack(alignment: .leading, spacing: 1) {
                Text(ModelNames.name(id)).font(.yy(size: 12.5, weight: on ? .semibold : .regular)).foregroundStyle(YYColor.t1).lineLimit(1)
                if let why {
                    Text(why).font(.yy(size: 10.5)).foregroundStyle(YYColor.t2)
                } else if ModelNames.name(id) != id {
                    Text(id).font(.yy(size: 10, design: .monospaced)).foregroundStyle(YYColor.t3).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            if on { Image(systemName: "checkmark").font(.yy(size: 11, weight: .bold)).foregroundStyle(YYColor.t1) }
        } action: { choose(id) }
    }

    private func choose(_ id: String) {
        var config = CompanionConfig.saved(provider)
        let old = config.model
        if old != id {
            ModelNames.used(old, provider: provider.id)
            config.model = id
            config.save()
            SettingsLog.shared.record(title: String(localized: "\(provider.title) 的模型"), to: ModelNames.name(id), from: ModelNames.name(old),
                                      undo: .defaults(key: "companion.model.\(provider.id)", old: .string(old)))
        }
        focus.page = .service(provider.id)
        focus.reload()
    }
}

// MARK: - Model names

/// Model ids as people say them, the few worth suggesting per service, and the ones used lately.
enum ModelNames {
    struct Pick { let id: String; let name: String; let why: String }

    static let recommended: [String: [Pick]] = [
        "claude": [.init(id: "claude-opus-5-5", name: "Claude Opus 5.5", why: String(localized: "最聪明，读懂难书")),
                   .init(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", why: String(localized: "聪明又快，平时就用它")),
                   .init(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", why: String(localized: "最快最便宜，查词够用"))],
        "openai": [.init(id: "gpt-5", name: "GPT-5", why: String(localized: "最聪明")),
                   .init(id: "gpt-5-mini", name: "GPT-5 mini", why: String(localized: "快又便宜"))],
        "deepseek": [.init(id: "deepseek-chat", name: "DeepSeek Chat", why: String(localized: "中文好，平时就用它")),
                     .init(id: "deepseek-reasoner", name: "DeepSeek Reasoner", why: String(localized: "想得深，慢一点"))],
        "gemini": [.init(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro", why: String(localized: "最聪明")),
                   .init(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", why: String(localized: "快又便宜"))],
        "openrouter": [.init(id: "anthropic/claude-sonnet-5-5", name: "Claude Sonnet 5.5", why: String(localized: "读书最稳")),
                       .init(id: "google/gemini-2.5-flash", name: "Gemini 2.5 Flash", why: String(localized: "快又便宜")),
                       .init(id: "deepseek/deepseek-chat", name: "DeepSeek Chat", why: String(localized: "中文好，很便宜"))],
        "moonshot": [.init(id: "kimi-k2-turbo-preview", name: "Kimi K2 Turbo", why: String(localized: "长书一口气读完"))],
        "dashscope": [.init(id: "qwen-max", name: String(localized: "通义 Max"), why: String(localized: "最聪明")),
                      .init(id: "qwen-plus", name: String(localized: "通义 Plus"), why: String(localized: "快又便宜"))],
        "zhipu": [.init(id: "glm-4.6", name: "GLM-4.6", why: String(localized: "中文好"))],
    ]

    private static let names: [String: String] = Dictionary(
        recommended.values.flatMap { $0 }.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })

    /// "Claude Sonnet 5.5" for the ones known; otherwise the id.
    static func name(_ id: String) -> String { names[id] ?? id }

    // The last three used, newest first.
    static func recent(_ provider: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: "companion.recent.\(provider)") ?? []
    }

    static func used(_ id: String, provider: String) {
        guard !id.isEmpty else { return }
        let list = [id] + recent(provider).filter { $0 != id }
        UserDefaults.standard.set(Array(list.prefix(3)), forKey: "companion.recent.\(provider)")
    }

    /// "anthropic/claude-…" by the part before the slash, when enough of them have one.
    static func groups(_ ids: [String]) -> [(maker: String, models: [String])] {
        guard ids.count > 12, ids.filter({ $0.contains("/") }).count * 2 > ids.count else { return [("", ids)] }
        let grouped = Dictionary(grouping: ids) { $0.split(separator: "/").first.map(String.init) ?? "" }
        return grouped.keys.sorted().map { ($0.isEmpty ? String(localized: "其他") : $0, grouped[$0]!) }
    }
}

// MARK: - Pieces

/// A service's logo on a white tile, as System Settings shows apps; this Mac's own is Apple 智能's
/// many-coloured mark.
struct ServiceTile: View {
    enum Mark { case provider(CompanionProvider), cloud(CloudVoice.Provider), thisMac, laptop, add }
    let mark: Mark
    var size: CGFloat = 30

    var body: some View {
        let r = size * 0.25
        Group {
            switch mark {
            case .add:
                Image(systemName: "plus").font(.yy(size: size * 0.4, weight: .medium)).foregroundStyle(YYColor.t2)
                    .frame(width: size, height: size)
                    .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(YYColor.tint, style: .init(lineWidth: 1)))
            case .thisMac:
                Image(systemName: NSImage(systemSymbolName: "apple.intelligence", accessibilityDescription: nil) == nil ? "sparkles" : "apple.intelligence")
                    .font(.system(size: size * 0.52, weight: .medium))
                    .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.2), Color(red: 0.98, green: 0.3, blue: 0.5),
                                                             Color(red: 0.62, green: 0.36, blue: 0.98), Color(red: 0.2, green: 0.6, blue: 1)],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: size, height: size)
                    .background(tile(r))
            case .laptop:
                let glyph: CGFloat = size <= 20 ? 12 : size * 19 / 32
                ZStack {
                    RoundedRectangle(cornerRadius: 1.2 * glyph / 16).stroke(lineWidth: 1.3 * glyph / 16)
                        .frame(width: 11 * glyph / 16, height: 7.5 * glyph / 16)
                        .offset(y: -1.25 * glyph / 16)
                    Rectangle().frame(width: 14 * glyph / 16, height: 1.3 * glyph / 16)
                        .offset(y: 4.8 * glyph / 16)
                }
                .foregroundStyle(Color(yy: YYRGBA(42, 43, 46, 1)))
                .frame(width: size, height: size)
                .background(tile(r))
            case .cloud(let p):
                Group {
                    if NSImage(named: "brand-\(p.id)") != nil {
                        Image("brand-\(p.id)").resizable().scaledToFit()
                    } else if NSImage(named: "provider-\(p.id)") != nil {
                        Image("provider-\(p.id)").resizable().scaledToFit().foregroundStyle(Color(yy: YYRGBA(42, 43, 46, 1)))
                    } else {
                        Text(String(p.title.prefix(1)).uppercased()).font(.yy(size: size * 0.42, weight: .semibold)).foregroundStyle(Color(yy: YYRGBA(110, 107, 104, 1)))
                    }
                }
                .frame(width: size * 0.6, height: size * 0.6)
                .frame(width: size, height: size)
                .background(tile(r))
            case .provider(let p):
                Group {
                    if NSImage(named: "brand-\(p.id)") != nil {
                        Image("brand-\(p.id)").resizable().scaledToFit()
                    } else if let logo = p.logo {
                        Image(logo).resizable().scaledToFit().foregroundStyle(Color(yy: YYRGBA(42, 43, 46, 1)))
                    } else {
                        Text(p.mark).font(.yy(size: size * 0.42, weight: .semibold)).foregroundStyle(Color(yy: YYRGBA(110, 107, 104, 1)))
                    }
                }
                .frame(width: size * 0.6, height: size * 0.6)
                .frame(width: size, height: size)
                .background(tile(r))
            }
        }
        .frame(width: size, height: size)
    }

    private func tile(_ r: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: r).fill(.white)
            .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(size > 20 ? 0.05 : 0), radius: 1, y: 1)
    }
}

/// A row of 书伴's list: tile, name, a line; the whole row is the button. The chosen one is tinted.
struct ServiceRow<Tile: View, Title: View, Detail: View, Trailing: View>: View {
    var selected: Bool
    var dim = false
    @ViewBuilder var tile: Tile
    @ViewBuilder var title: Title
    @ViewBuilder var detail: Detail
    @ViewBuilder var trailing: Trailing
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                tile.opacity(dim ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) { title }
                        .font(.yy(size: 13, weight: .medium)).foregroundStyle(dim ? YYColor.t3 : YYColor.t1)
                    detail.font(.yy(size: 11)).foregroundStyle(YYColor.t3).lineLimit(1)
                }
                Spacer(minLength: 8)
                trailing
                Image(systemName: "chevron.right").font(.yy(size: 10, weight: .semibold)).foregroundStyle(YYColor.t3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 52)
            .background(selected ? YYColor.t1.opacity(0.06) : hovering ? YYColor.t1.opacity(0.04) : .clear,
                        in: .rect(cornerRadius: 9))
            .padding(4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// "书伴在用", green.
private struct InUsePill: View {
    var body: some View { SettingsPill(String(localized: "书伴在用"), tone: .ok) }
}

/// A small status capsule: says a state, isn't pressed.
struct SettingsPill: View {
    enum Tone { case ok, warn, quiet }
    let text: String
    let tone: Tone
    init(_ text: String, tone: Tone) { self.text = text; self.tone = tone }

    var body: some View {
        let color: Color = switch tone {
        case .ok: YYColor.ok
        case .warn: YYColor.warn
        case .quiet: YYColor.t3
        }
        Text(text)
            .font(.yy(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(tone == .quiet ? YYColor.inset : color.opacity(0.13), in: .capsule)
            .fixedSize()
    }
}

/// The right column's header: a tile, a name, a line.
struct PanelHeader<Mark: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var mark: Mark

    var body: some View {
        HStack(spacing: 10) {
            mark
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.yy(size: 14, weight: .semibold)).foregroundStyle(YYColor.t1)
                if let detail { Text(detail).font(.yy(size: 11)).foregroundStyle(YYColor.t3) }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }
}

/// The right column's small white card of rows.
struct PanelCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Rectangle().fill(YYColor.line).frame(height: 0.5).padding(.horizontal, 10) }
                    row
                }
            }
        }
        .padding(3)
        .background(YYColor.card, in: .rect(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(scheme == .dark ? Color(yy: YYRGBA(255, 255, 255, 0.06)) : YYColor.line, lineWidth: 0.5))
    }
}

/// A row of a `PanelCard` that says something.
struct PanelRow<Label: View, Trailing: View>: View {
    @ViewBuilder var label: Label
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            label.font(.yy(size: 12.5)).foregroundStyle(YYColor.t1)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 38)
    }
}

/// A row of a `PanelCard` that is pressed: the whole row, lit on hover.
struct PanelButton<Label: View>: View {
    var systemImage: String?
    var tint: Color = YYColor.t1
    var destructive = false
    var selected = false
    /// The one return would take.
    var outlined = false
    @ViewBuilder var label: Label
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let systemImage {
                    Image(systemName: systemImage).font(.yy(size: 12.5, weight: .medium)).foregroundStyle(tint).frame(width: 16)
                }
                label
            }
            .font(.yy(size: 12.5))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(background, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(YYColor.t1, lineWidth: outlined ? 1.5 : 0))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if selected { return YYColor.t1.opacity(0.06) }
        if hovering { return destructive ? YYColor.danger.opacity(0.08) : YYColor.t1.opacity(0.045) }
        return .clear
    }
}

/// The small grey label over a `PanelCard`.
struct PanelLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.yy(size: 11, weight: .semibold)).foregroundStyle(YYColor.t3)
            .padding(.leading, 12).padding(.top, 2).padding(.bottom, -4)
    }
}

/// A line of help under a `PanelCard`.
struct PanelHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.yy(size: 11)).lineSpacing(2).foregroundStyle(YYColor.t3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.top, -4)
    }
}

/// A round button that only shows itself on hover: ‹ in the right column's header.
struct HoverCircleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverCircle(configuration: configuration)
    }

    private struct HoverCircle: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(Circle().fill(YYColor.t1.opacity(configuration.isPressed ? 0.1 : hovering ? 0.06 : 0)))
                .onHover { hovering = $0 }
        }
    }
}
#endif
