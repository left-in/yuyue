#if os(macOS)
import SwiftUI
import AppKit

// 设置 · 书伴, a service added: its key is changed straight in its row in the right column
// not in the sheet. Once what's typed looks whole it's
// tried, and kept only if the service answers. 添加服务商 stays a sheet.

extension CompanionProvider {
    /// Its address can be changed: every service but this Mac's own. Left as it is, the
    /// service's usual one.
    var hasAddress: Bool { kind != .apple }
}

extension CompanionConfig {
    /// Asks for its models with what's typed; what it found, in ticks.
    @MainActor func tryIt() async throws -> AutoConnect.Outcome {
        let models = try await Companion.models(self)
        let host = (url.isEmpty ? provider.defaultURL : URL(string: url))?.host() ?? provider.title
        var ticks: [AutoConnect.Tick] = [.init(title: String(localized: "连得上 \(host)"))]
        if !key.isEmpty { ticks.append(.init(title: String(localized: "Key 有效"))) }
        ticks.append(.init(title: String(localized: "找到 \(models.count) 个模型"),
                           detail: model.isEmpty ? nil : String(localized: "先用 \(ModelNames.name(model))，之后能换")))
        return .init(ticks: ticks, banner: String(localized: "\(provider.title) · 已连上"))
    }
}

/// A service's key and, for local ones and the user's own, its address, in their own card.
/// The key is shown masked; pressed, it's typed again in the row. The address is always a field:
/// change it and, once it reads as a whole address, it's tried. What answers is kept; Esc puts
/// back what was there.
struct ServiceKeyCard: View {
    let provider: CompanionProvider
    @State private var editingKey = false
    @State private var key = ""
    @State private var url = ""
    @State private var connect = AutoConnect()
    private var focus: CompanionFocus { .shared }

    var body: some View {
        let config = CompanionConfig.saved(provider)
        VStack(alignment: .leading, spacing: 10) {
            PanelCard {
                if editingKey {
                    PanelField(label: "Key", text: $key, prompt: provider.needsKey ? String(localized: "贴上新的 Key") : String(localized: "可不填"),
                               secure: true, bad: connect.failed, autofocus: true, submit: { attempt(now: true) }, cancel: stopKey)
                } else {
                    PanelButton {
                        Text(verbatim: "Key")
                        Spacer(minLength: 8)
                        Text(config.key.isEmpty ? (provider.needsKey ? String(localized: "还没填") : String(localized: "没填")) : config.maskedKey)
                            .font(.yy(size: 12, design: .monospaced)).foregroundStyle(YYColor.t2).lineLimit(1)
                        Image(systemName: "chevron.right").font(.yy(size: 9.5, weight: .semibold)).foregroundStyle(YYColor.t3)
                    } action: {
                        key = ""
                        editingKey = true
                    }
                    .help(Text("换一个 Key"))
                }
                if provider.hasAddress {
                    PanelField(label: String(localized: "接口地址"), text: $url, prompt: provider.urlHint, bad: connect.failed && !editingKey,
                               submit: { attempt(now: true) }, cancel: { url = savedURL; connect.reset() })
                }
            }
            AutoConnectStatus(connect: connect)
            if case .idle = connect.phase {
                if editingKey {
                    PanelHint(String(localized: "贴上就去试，能用才换掉原来的。Esc 不换了。"))
                } else if provider.hasAddress && url != savedURL {
                    PanelHint(String(localized: "回车去试这个地址，能连上才换。Esc 改回去。"))
                }
            }
        }
        .onAppear { url = savedURL }
        .onChange(of: key) { attempt(now: false) }
        .onChange(of: url) { attempt(now: false) }
    }

    /// What the address field starts from: the one kept, or the service's usual one.
    private var savedURL: String {
        let c = CompanionConfig.saved(provider)
        return c.url.isEmpty ? (provider.defaultURL?.absoluteString ?? "") : c.url
    }

    private func stopKey() {
        editingKey = false
        key = ""
        connect.reset()
    }

    private func attempt(now: Bool) {
        let saved = CompanionConfig.saved(provider)
        var c = saved
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if editingKey && !k.isEmpty { c.key = k }
        if provider.hasAddress {
            let u = url.trimmingCharacters(in: .whitespaces)
            c.url = u == provider.defaultURL?.absoluteString ? "" : u
        }
        guard c != saved, c.isConnected else { connect.reset(); return }
        if !now {
            if editingKey && !k.isEmpty && !AutoConnect.looksLikeKey(k) { connect.reset(); return }
            if c.url != saved.url && !AutoConnect.looksLikeAddress(c.url.isEmpty ? savedURL : c.url) { connect.reset(); return }
        }
        connect.start(String(localized: "正在试…"), delay: now ? .zero : .milliseconds(900), describe: Companion.message(for:)) {
            try await c.tryIt()
        } done: {
            c.save()
            stopKey()
            url = savedURL
            focus.reload()
        }
    }
}

/// The sheet's form on the Mac, in the right column's way: rows typed straight into, no 👁, no
/// 粘贴, no 取消 / 添加. Once the key (or the address) reads as whole it's tried; what answers is
/// added and 书伴 uses it, and the sheet closes. OpenRouter's sign-in is a row, not a bar.
struct MacProviderForm: View {
    let provider: CompanionProvider
    let adding: Bool
    let back: (() -> Void)?
    let close: () -> Void
    let done: () -> Void
    @State private var name = ""
    @State private var key = ""
    @State private var url = ""
    @State private var signingIn = false
    @State private var signIn = OpenRouterSignIn()
    @State private var connect = AutoConnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetTitle(title: provider.isCustom && adding ? String(localized: "自己添加") : provider.title,
                       logo: provider.isCustom ? nil : provider, back: back, close: close)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if provider.group == .signIn {
                        PanelCard {
                            PanelButton(systemImage: "person.crop.circle", tint: YYColor.t1) {
                                Text("用 \(provider.title) 账号登录")
                                Spacer(minLength: 6)
                                if signingIn { ProgressView().controlSize(.mini) } else {
                                    Image(systemName: "arrow.up.forward").font(.yy(size: 9.5, weight: .semibold)).foregroundStyle(YYColor.t3)
                                }
                            } action: { signInNow() }
                        }
                        PanelLabel(String(localized: "或者贴一个已有的 Key"))
                    }
                    PanelCard {
                        if provider.isCustom {
                            PanelField(label: String(localized: "名称"), text: $name, prompt: String(localized: "比如 公司的模型"), mono: false, autofocus: true)
                        }
                        PanelField(label: "API Key", text: $key, prompt: provider.needsKey ? provider.keyHint : String(localized: "可不填"),
                                   secure: true, bad: connect.failed, autofocus: !provider.isCustom && provider.group != .signIn,
                                   submit: { attempt(now: true) })
                        PanelField(label: String(localized: "接口地址"), text: $url, prompt: provider.urlHint, bad: connect.failed,
                                   submit: { attempt(now: true) })
                    }
                    AutoConnectStatus(connect: connect)
                    if case .idle = connect.phase {
                        PanelHint(note)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.top, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onAppear { url = provider.defaultURL?.absoluteString ?? "" }
        .onChange(of: key) { attempt(now: false) }
        .onChange(of: url) { attempt(now: false) }
        .onChange(of: name) { if provider.isCustom { attempt(now: false) } }
    }

    private var note: String {
        let start = String(localized: "填好就自己去连，连上就加上。")
        if provider.group == .local { return start + String(localized: "本机或局域网里跑的，提问和书里相关的几段原文只发到这个地址。") }
        if provider.isCustom { return start + String(localized: "提问和书里相关的几段原文直接发到这个地址，语阅不经手。") }
        return (provider.blurb.map { $0 + String(localized: "。") } ?? "") + start
            + String(localized: "Key 只存在这台 Mac 的钥匙串里，费用走你自己的 \(provider.account) 账号。")
    }

    private var draft: CompanionConfig {
        var c = CompanionConfig.saved(provider)
        if provider.isCustom {
            let n = name.trimmingCharacters(in: .whitespaces)
            let host = URL(string: url.trimmingCharacters(in: .whitespaces))?.host()
            c.provider = .custom(n.isEmpty ? (host ?? "") : n, id: provider.id)
        }
        c.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = url.trimmingCharacters(in: .whitespaces)
        c.url = u == provider.defaultURL?.absoluteString ? "" : u
        return c
    }

    private func attempt(now: Bool) {
        let c = draft
        guard c.isConnected else { connect.reset(); return }
        if !now {
            let typedKey = !c.key.isEmpty
            if provider.needsKey && !AutoConnect.looksLikeKey(c.key) { connect.reset(); return }
            if typedKey && !AutoConnect.looksLikeKey(c.key) { connect.reset(); return }
            if !c.url.isEmpty && !AutoConnect.looksLikeAddress(c.url) { connect.reset(); return }
            if !provider.needsKey && !typedKey && c.url.isEmpty { connect.reset(); return }
        }
        connect.start(String(localized: "正在连 \(c.provider.title)…"), delay: now ? .zero : .milliseconds(800), describe: Companion.message(for:)) {
            try await c.tryIt()
        } done: {
            if adding { CompanionConfig.current = c } else { c.save() }
            done()
        }
    }

    private func signInNow() {
        guard !signingIn else { return }
        signingIn = true
        Task {
            defer { signingIn = false }
            do {
                key = try await signIn.run()
                attempt(now: true)
            } catch {
                connect.reset()
            }
        }
    }
}
#endif
