import SwiftUI
#if os(macOS)
import AppKit
#endif

/// What 设置 · 书伴 shows, the same on Mac and iPhone (the provider is
/// a menu and the model its own row): the service answering, its model with the ones it lists,
/// and 测试一下.
@MainActor @Observable
final class CompanionChoice {
    private(set) var current = CompanionConfig.current
    private(set) var added = CompanionProvider.added
    private(set) var models: [String] = []
    private(set) var listing = false
    private(set) var testing = false
    var result: Result<TimeInterval, Error>?

    /// What the 服务商 menu offers: this device's own where it can answer, then those added.
    var options: [CompanionProvider] { (Companion.appleAvailability == nil ? [.apple] : []) + added }

    func reload() {
        current = CompanionConfig.current
        added = CompanionProvider.added
        result = nil
        Task { await list() }
    }

    func choose(_ p: CompanionProvider) {
        CompanionConfig.current = CompanionConfig.saved(p)
        reload()
    }

    var model: String {
        get { current.model }
        set {
            current.model = newValue.trimmingCharacters(in: .whitespaces)
            current.save()
            result = nil
        }
    }

    /// The models the service lists; the first is taken when none was chosen yet.
    func list() async {
        let config = current
        guard config.provider.kind != .apple, config.isConnected else { models = []; return }
        listing = true
        let found = (try? await Companion.models(config)) ?? []
        guard config.provider == current.provider else { return }
        models = found.sorted()
        listing = false
        if current.model.isEmpty, let first = found.first { model = first }
    }

    func test() {
        testing = true
        result = nil
        let config = current
        Task {
            result = await CompanionTest.run(config)
            testing = false
        }
    }
}

/// 添加服务商, 管理服务商 and one service's form, in one sheet. 添加 is a picker: what's on
/// offer, searchable, grouped by how it's reached, with one of your own at the bottom; picking
/// one opens its form, ‹ goes back. A service added answers from then on.
struct CompanionProviderSheet: View {
    enum Start: Identifiable {
        case add, manage, edit(CompanionProvider)
        var id: String {
            switch self {
            case .add: "add"
            case .manage: "manage"
            case .edit(let p): p.id
            }
        }
    }

    let start: Start
    @State private var picked: CompanionProvider?
    @State private var adding = false
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let picked {
                #if os(macOS)
                MacProviderForm(provider: picked, adding: adding, back: back, close: { dismiss() }, done: done)
                    .id(picked.id)
                #else
                ProviderForm(provider: picked, adding: adding, back: back, close: { dismiss() }, done: done)
                    .id(picked.id)
                #endif
            } else if adding {
                picker
            } else {
                manage
            }
        }
        .padding(YYUI.s(16))
        #if os(macOS)
        .frame(width: 440, height: 460)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .background(YYColor.bg)
        .onAppear {
            switch start {
            case .add: adding = true
            case .manage: break
            case .edit(let p): picked = p
            }
        }
    }

    /// After 添加, 保存 or 移除: back to 管理服务商 when that's where it started.
    private func done() {
        if case .manage = start {
            picked = nil
            adding = false
        } else {
            dismiss()
        }
    }

    /// ‹ from a form: to the picker it came from, or to 管理服务商.
    private var back: (() -> Void)? {
        switch start {
        case .edit: nil
        case .add: { picked = nil }
        case .manage: { picked = nil }
        }
    }

    // MARK: 添加服务商

    private var picker: some View {
        let matches = CompanionProvider.available(matching: query)
        return VStack(alignment: .leading, spacing: 0) {
            SheetTitle(title: String(localized: "添加服务商"), back: start.id == "manage" ? { adding = false } : nil) { dismiss() }
            HStack(spacing: YYUI.s(6)) {
                Image(systemName: "magnifyingglass").font(YYUI.font(10.5, .medium)).foregroundStyle(YYColor.t3)
                TextField("", text: $query, prompt: Text("搜索服务商，比如 千问、Kimi、magpie"))
                    .textFieldStyle(.plain)
                    .font(YYUI.font(11.5))
                    .plainEntry()
                    .onSubmit { if let first = matches.first { open(first) } }
            }
            .padding(.horizontal, YYUI.s(9))
            .frame(height: YYUI.s(30))
            .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(8)))
            .padding(.top, YYUI.s(10))
            ScrollView {
                VStack(alignment: .leading, spacing: YYUI.s(10)) {
                    ForEach(CompanionProvider.Group.allCases, id: \.self) { group in
                        let list = matches.filter { $0.group == group }
                        if !list.isEmpty {
                            VStack(alignment: .leading, spacing: YYUI.s(2)) {
                                Text(group.title).font(YYUI.font(10, .semibold)).foregroundStyle(YYColor.t3)
                                    .padding(.leading, YYUI.s(8)).padding(.bottom, YYUI.s(2))
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: YYUI.s(2)), count: Self.columns), spacing: YYUI.s(2)) {
                                    ForEach(list) { tile($0) }
                                }
                            }
                        }
                    }
                    if matches.isEmpty {
                        Text("没找到。在下面自己添加，填上接口地址就行")
                            .font(YYUI.font(11)).foregroundStyle(YYColor.t3)
                            .frame(maxWidth: .infinity).padding(.vertical, YYUI.s(36))
                    }
                }
                .padding(.vertical, YYUI.s(12))
            }
            .scrollBounceBehavior(.basedOnSize)
            Rectangle().fill(YYColor.line).frame(height: 0.5).padding(.horizontal, -YYUI.s(16))
            Button { open(.custom("")) } label: {
                HStack(spacing: YYUI.s(8)) {
                    Image(systemName: "plus").font(YYUI.font(10.5, .semibold)).foregroundStyle(YYColor.t2)
                        .frame(width: YYUI.s(16), height: YYUI.s(16))
                    Text("自己添加").font(YYUI.font(11.5)).foregroundStyle(YYColor.t1)
                    Text("任何 OpenAI 兼容接口").font(YYUI.font(10.5)).foregroundStyle(YYColor.t3)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(PickRow())
            .padding(.top, YYUI.s(8))
        }
    }

    #if os(macOS)
    private static let columns = 3
    #else
    private static let columns = 2
    #endif

    private func open(_ p: CompanionProvider) {
        adding = true
        picked = p
    }

    private func tile(_ p: CompanionProvider) -> some View {
        Button { open(p) } label: {
            HStack(spacing: YYUI.s(8)) {
                ProviderLogo(provider: p)
                Text(p.title).font(YYUI.font(11.5)).foregroundStyle(YYColor.t1).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(PickRow())
        .help(p.blurb.map(Text.init) ?? Text(p.title))
    }

    // MARK: 管理服务商

    private var manage: some View {
        let added = CompanionProvider.added
        return VStack(alignment: .leading, spacing: YYUI.s(10)) {
            SheetTitle(title: String(localized: "管理服务商"), back: nil) { dismiss() }
            if added.isEmpty {
                Text("还没添加服务商").font(YYUI.font(11)).foregroundStyle(YYColor.t3)
                    .frame(maxWidth: .infinity).padding(.vertical, YYUI.s(30))
            } else {
                ScrollView {
                    VStack(spacing: YYUI.s(2)) {
                        ForEach(added) { p in
                            let saved = CompanionConfig.saved(p)
                            Button { picked = p } label: {
                                HStack(spacing: YYUI.s(8)) {
                                    ProviderLogo(provider: p)
                                    Text(p.title).font(YYUI.font(11.5)).foregroundStyle(YYColor.t1)
                                    Spacer(minLength: YYUI.s(8))
                                    Text(saved.key.isEmpty ? (saved.url.isEmpty ? p.urlHint : saved.url) : saved.maskedKey)
                                        .font(YYUI.font(10, design: .monospaced)).foregroundStyle(YYColor.t3).lineLimit(1)
                                    Image(systemName: "chevron.right").font(YYUI.font(8.5, .semibold)).foregroundStyle(YYColor.t3)
                                }
                            }
                            .buttonStyle(PickRow())
                        }
                    }
                    .padding(.top, YYUI.s(4))
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button { adding = true } label: { Label("添加服务商", systemImage: "plus") }
                    .buttonStyle(YYButtonStyle(kind: .raised))
            }
        }
    }
}

/// A row to pick: no box, the inset grey under it on hover and press.
private struct PickRow: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, YYUI.s(8))
                .frame(height: YYUI.s(32))
                .background(hovering || configuration.isPressed ? YYColor.inset : .clear, in: .rect(cornerRadius: YYUI.s(7)))
                .contentShape(.rect)
                .onHover { hovering = $0 }
        }
    }
}

/// The sheet's title, with ‹ when there's somewhere to go back to, and the service's logo in a form.
struct SheetTitle: View {
    let title: String
    var logo: CompanionProvider?
    let back: (() -> Void)?
    let close: () -> Void

    var body: some View {
        HStack(spacing: YYUI.s(6)) {
            if let back {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(YYUI.font(11, .semibold)).foregroundStyle(YYColor.t2)
                        .frame(width: YYUI.s(20), height: YYUI.s(26))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("返回"))
            }
            if let logo { ProviderLogo(provider: logo, size: 18).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + YYUI.s(5) } }
            YYSheetHeader(title: title, subtitle: String(localized: "书伴"), close: close)
        }
    }
}

/// A service's logo, bare as the menu bar draws its icons; the user's own get their first letter
/// on a small grey disc, the device's own the Apple logo.
struct ProviderLogo: View {
    let provider: CompanionProvider
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let logo = provider.logo {
                Image(logo).resizable().scaledToFit().foregroundStyle(YYColor.t1)
            } else if provider.kind == .apple {
                Image(systemName: "apple.logo").resizable().scaledToFit().foregroundStyle(YYColor.t1).padding(YYUI.s(size * 0.06))
            } else {
                Text(String(provider.title.prefix(1)).uppercased())
                    .font(YYUI.font(size * 0.55, .semibold)).foregroundStyle(YYColor.t2)
                    .frame(width: YYUI.s(size), height: YYUI.s(size))
                    .background(YYColor.inset, in: .circle)
            }
        }
        .frame(width: YYUI.s(size), height: YYUI.s(size))
    }
}

/// One service's key and address (the model is chosen in 设置 · 书伴).
/// A key saved before shows as "sk-…3f9a" with 更换, so opening the form never wipes it.
/// OpenRouter signs in instead; a key can still be pasted.
private struct ProviderForm: View {
    let provider: CompanionProvider
    let adding: Bool
    let back: (() -> Void)?
    let close: () -> Void
    let done: () -> Void
    @State private var config: CompanionConfig
    @State private var name: String
    @State private var keyLocked: Bool
    @State private var showKey = false
    @State private var signingIn = false
    @State private var failed: String?
    @State private var removing = false
    @State private var signIn = OpenRouterSignIn()

    init(provider: CompanionProvider, adding: Bool, back: (() -> Void)?, close: @escaping () -> Void, done: @escaping () -> Void) {
        self.provider = provider
        self.adding = adding
        self.back = back
        self.close = close
        self.done = done
        let saved = CompanionConfig.saved(provider)
        _config = State(initialValue: saved)
        _name = State(initialValue: provider.title)
        _keyLocked = State(initialValue: !saved.key.isEmpty)
    }

    /// What 添加 keeps: the name typed in for one of the user's own.
    private var draft: CompanionConfig {
        var c = config
        if provider.isCustom { c.provider = .custom(name.trimmingCharacters(in: .whitespaces), id: provider.id) }
        c.key = c.key.trimmingCharacters(in: .whitespacesAndNewlines)
        c.url = c.url.trimmingCharacters(in: .whitespaces)
        return c
    }

    var body: some View {
        VStack(alignment: .leading, spacing: YYUI.s(12)) {
            SheetTitle(title: provider.isCustom && adding ? String(localized: "自己添加") : provider.title,
                       logo: provider.isCustom ? nil : provider, back: back, close: close)
            ScrollView {
                VStack(alignment: .leading, spacing: YYUI.s(10)) {
                    if provider.group == .signIn && !keyLocked {
                        Button(action: signInNow) {
                            HStack(spacing: YYUI.s(6)) {
                                if signingIn { ProgressView().controlSize(.small) }
                                Text("用 \(provider.title) 登录")
                            }
                        }
                        .buttonStyle(YYButtonStyle(kind: .main, wide: true))
                        .disabled(signingIn)
                        Text("或者粘贴一个已有的 Key").font(YYUI.font(10)).foregroundStyle(YYColor.t3).padding(.leading, YYUI.s(4)).padding(.top, -YYUI.s(4))
                    }
                    YYGroup {
                        if provider.isCustom {
                            YYField(label: String(localized: "名称"), labelWidth: 52) {
                                TextField("", text: $name, prompt: Text("比如 公司的模型"))
                            }
                        }
                        YYField(label: "API Key", labelWidth: 52) { keyField }
                        YYField(label: String(localized: "接口地址"), labelWidth: 52) {
                            TextField("", text: $config.url, prompt: Text(provider.urlHint))
                                .font(YYUI.font(10.5, design: .monospaced))
                                .plainEntry()
                                #if os(iOS)
                                .keyboardType(.URL)
                                #endif
                        }
                    }
                    .textFieldStyle(.plain)
                    .foregroundStyle(YYColor.t1)
                    if let failed {
                        Label(failed, systemImage: "exclamationmark.circle").font(YYUI.font(10.5)).foregroundStyle(YYColor.danger)
                    }
                    Text((provider.blurb.map { $0 + String(localized: "。") } ?? "") + note)
                        .font(YYUI.font(10)).lineSpacing(YYUI.s(10) * 0.6).foregroundStyle(YYColor.t3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, YYUI.s(4))
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack(spacing: YYUI.s(8)) {
                if !adding {
                    Button("移除") { removing = true }
                        .buttonStyle(.plain)
                    .font(YYUI.font(11.5)).foregroundStyle(YYColor.danger)
                }
                Spacer()
                Button("取消", action: back ?? close)
                    .buttonStyle(YYButtonStyle(kind: .plain))
                Button(adding ? String(localized: "添加") : String(localized: "保存"), action: save)
                    .buttonStyle(YYButtonStyle(kind: .main))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isConnected)
            }
        }
        .confirmationDialog(String(localized: "移除 \(provider.title)？"), isPresented: $removing) {
            Button("移除", role: .destructive) {
                CompanionConfig.remove(provider)
                done()
            }
        } message: {
            Text("它的 Key 也会从钥匙串里删掉。正在用它的话，书伴换回设备自带的。")
        }
    }

    @ViewBuilder private var keyField: some View {
        if keyLocked {
            HStack(spacing: YYUI.s(8)) {
                Text(config.maskedKey).font(YYUI.font(10.5, design: .monospaced)).foregroundStyle(YYColor.t2)
                Spacer(minLength: 0)
                Button("更换") {
                    config.key = ""
                    keyLocked = false
                }
                .buttonStyle(YYButtonStyle(kind: .plain, size: .small))
            }
        } else {
            HStack(spacing: YYUI.s(6)) {
                Group {
                    let hint = provider.needsKey ? provider.keyHint : provider.keyHint == "sk-…" ? String(localized: "可不填") : provider.keyHint
                    if showKey {
                        TextField("", text: $config.key, prompt: Text(hint))
                    } else {
                        SecureField("", text: $config.key, prompt: Text(hint))
                    }
                }
                .font(YYUI.font(10.5, design: .monospaced))
                .plainEntry()
                Button { showKey.toggle() } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye").font(YYUI.font(10.5)).foregroundStyle(YYColor.t3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showKey ? Text("藏起 Key") : Text("显示 Key"))
                #if os(macOS)
                Button("粘贴") {
                    if let s = NSPasteboard.general.string(forType: .string) { config.key = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .buttonStyle(YYButtonStyle(kind: .plain, size: .small))
                #else
                PasteButton(payloadType: String.self) { strings in
                    if let s = strings.first { config.key = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .labelStyle(.titleOnly)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                #endif
            }
        }
    }

    private var note: String {
        if provider.group == .local {
            return String(localized: "本机或局域网里跑的，提问和书里相关的几段原文只发到这个地址。")
        }
        if provider.isCustom {
            return String(localized: "提问和书里相关的几段原文直接发到这个地址，语阅不经手。")
        }
        return String(localized: "Key 只存在这台设备的钥匙串里。费用走你自己的 \(provider.account) 账号，语阅不经手，也看不到。")
    }

    private func signInNow() {
        signingIn = true
        failed = nil
        Task {
            do {
                config.key = try await signIn.run()
                keyLocked = true
                save()
            } catch {
                failed = Companion.message(for: error)
            }
            signingIn = false
        }
    }

    private func save() {
        let c = draft
        guard c.isConnected else { return }
        // A service just added answers from now on; editing one leaves the choice alone.
        if adding { CompanionConfig.current = c } else { c.save() }
        done()
    }
}

private extension View {
    /// Keys, model names and addresses: typed as they are.
    func plainEntry() -> some View {
        self.autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
    }
}
