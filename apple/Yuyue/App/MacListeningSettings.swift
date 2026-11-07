#if os(macOS)
import SwiftUI
import AppKit

/// What the right column of 朗读 shows, and the state the two columns share.
@MainActor @Observable
final class ListeningFocus {
    static let shared = ListeningFocus()

    /// The service shown in the right column (its key); nil: the voice card.
    var page: CloudVoice.Provider?
    /// The source whose voices the middle shows; nil: the list of sources.
    var source: VoiceSource?
    /// Which kind of book the voices are being chosen for.
    var book = VoiceBook.zh
    /// The voice last clicked to listen to, for the right column's card.
    var listening: String?
    /// The services with a key, in a fixed order.
    private(set) var added: [CloudVoice.Provider] = []
    var tick = 0
    /// This Mac's panel is in the right column (⚙).
    var macPanel = false
    /// What you sent, by book; none yet: the book's own line.
    private var lines: [VoiceBook: String] = [:]
    /// The voices heard since the line last changed; the others keep a red dot.
    private(set) var heard: Set<String> = []
    #if DEBUG
    var debugApplied = false
    #endif

    func line(_ book: VoiceBook) -> String { lines[book] ?? book.line }

    /// Plays a voice saying `text`, or stops it if that's what it's doing.
    func listen(_ voice: any Voice, text: String) {
        if PreviewState.shared.voiceID == voice.id { Voices.stopPreview(); return }
        page = nil
        macPanel = false
        listening = voice.id
        heard.insert(voice.id)
        Voices.preview(voice, text: text)
    }

    /// Everyone is to say this now; the one reading says it first. The others wait to be pressed,
    /// so a cloud voice costs only when it's listened to.
    func send(_ text: String, book: VoiceBook) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Voices.stopPreview()
        lines[book] = t
        heard = []
        if let v = book.current { listen(v, text: t) }
    }

    func pick(_ voice: any Voice, book: VoiceBook) {
        Voices.stopPreview()
        heard.insert(voice.id)
        withAnimation(.easeOut(duration: 0.38)) {
            book.choose(voice)
            listening = voice.id
            tick &+= 1
        }
    }

    func open(_ s: VoiceSource) {
        Voices.stopPreview()
        source = s
        listening = nil
        macPanel = false
        if case .cloud(let p) = s, page != p { page = nil }
    }

    func close() {
        Voices.stopPreview()
        source = nil
        listening = nil
        macPanel = false
    }

    func reload() {
        added = CloudVoice.Provider.allCases.filter { $0.key != nil }
        tick &+= 1
    }
}

extension CloudVoice.Provider {
    /// The voices it has here: OpenAI's fixed ten, the others' from the list fetched with the key.
    var voiceCount: Int { CloudVoice.all().filter { $0.provider == self }.count }

    /// 中文 or 英文 reads with one of its voices.
    var inUse: Bool {
        ["zh", "en"].contains { UserDefaults.standard.string(forKey: "player.voice.\($0)")?.hasPrefix("cloud.\(rawValue).") == true }
    }

    /// "sk-••••3f9a": the saved key, shown without giving it away.
    var maskedKey: String { Self.mask(key ?? "") }

    static func mask(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        return String(key.prefix(key.hasPrefix("sk") ? 3 : 0)) + "••••" + String(key.suffix(4))
    }

    /// Whose account it's paid from.
    var account: String {
        switch self {
        case .openai: "OpenAI"
        case .azure: "Microsoft Azure"
        case .elevenlabs: "ElevenLabs"
        }
    }

    /// A line under its name in 添加服务商.
    var blurb: String {
        switch self {
        case .openai: String(localized: "10 个声音，中英文都能读")
        case .azure: String(localized: "中文声音最多，有免费额度")
        case .elevenlabs: String(localized: "最像真人，英文最好")
        }
    }

    /// Step 1 of connecting: where the key is made.
    var keyStep: (title: String, detail: String, url: URL) {
        switch self {
        case .openai: (String(localized: "拿一个 API Key"), String(localized: "platform.openai.com › API keys › 新建，拷下来"),
                       URL(string: "https://platform.openai.com/api-keys")!)
        case .azure: (String(localized: "建一个“语音服务”资源"), String(localized: "Azure 门户 › 创建资源 › 语音服务；打开它的“密钥和终结点”，拷“密钥 1”"),
                      URL(string: "https://portal.azure.com/#create/Microsoft.CognitiveServicesSpeechServices")!)
        case .elevenlabs: (String(localized: "拿一个 API Key"), String(localized: "ElevenLabs › 个人资料 › API Keys › 新建"),
                           URL(string: "https://elevenlabs.io/app/settings/api-keys")!)
        }
    }

    static let regions: [(id: String, name: String)] = [
        ("eastasia", String(localized: "东亚")), ("southeastasia", String(localized: "东南亚")),
        ("japaneast", String(localized: "日本东部")), ("koreacentral", String(localized: "韩国中部")),
        ("eastus", String(localized: "美国东部")), ("westus2", String(localized: "美国西部 2")),
        ("westeurope", String(localized: "西欧")), ("uksouth", String(localized: "英国南部")),
    ]

    static var region: String {
        get { UserDefaults.standard.string(forKey: regionName).flatMap { $0.isEmpty ? nil : $0 } ?? "eastasia" }
        set { UserDefaults.standard.set(newValue, forKey: regionName) }
    }

    /// Takes the key and the voices away; a language reading with one of them goes back to the system's.
    func remove() {
        Keychain.delete(keyName)
        UserDefaults.standard.removeObject(forKey: voicesName)
        if self == .azure { UserDefaults.standard.removeObject(forKey: Self.regionName) }
        for tag in ["zh", "en"] where UserDefaults.standard.string(forKey: "player.voice.\(tag)")?.hasPrefix("cloud.\(rawValue).") == true {
            UserDefaults.standard.removeObject(forKey: "player.voice.\(tag)")
        }
    }

    /// Tries a key (and Azure's region): keeps it if the voices come back, puts back what was
    /// there if not.
    @MainActor func tryKey(_ key: String, region: String?) async throws -> AutoConnect.Outcome {
        let oldKey = self.key, oldRegion = UserDefaults.standard.string(forKey: Self.regionName)
        Keychain.write(keyName, key)
        if let region { Self.region = region }
        do {
            let n = try await CloudVoice.refresh(self)
            let host = self == .azure ? "\(Self.region).tts.speech.microsoft.com" : self == .openai ? "api.openai.com" : "api.elevenlabs.io"
            return .init(ticks: [.init(title: String(localized: "连得上 \(host)")), .init(title: String(localized: "Key 有效")),
                                 .init(title: String(localized: "找到 \(n) 个声音"), detail: String(localized: "在左边“换声音”里挑"))],
                         banner: String(localized: "\(title) · 已连上"))
        } catch {
            if let oldKey { Keychain.write(keyName, oldKey) } else { Keychain.delete(keyName) }
            if self == .azure { UserDefaults.standard.set(oldRegion, forKey: Self.regionName) }
            throw error
        }
    }
}

// MARK: - The right column

/// 朗读's right column over 试听: the service chosen in the middle. Not set up: its key is typed
/// straight in; set up: its key, voices, 检查连接, 断开.
struct ListeningInspector: View {
    private var focus: ListeningFocus { .shared }

    var body: some View {
        let _ = focus.tick
        Group {
            if let p = focus.page {
                if focus.added.contains(p) { CloudVoicePanel(provider: p) } else { CloudVoiceKeyPanel(provider: p) }
            }
        }
        .id(focus.page.map { $0.id + (focus.added.contains($0) ? ".on" : "") })
        .transition(.opacity.combined(with: .offset(y: 3)))
    }
}

/// ↗, for a row that opens something outside.
private struct OutLinkGlyph: View {
    var body: some View {
        SVGShape(d: "M3.5 8.5l5-5M4.5 3.5h4v4", box: 12)
            .stroke(YYColor.t2, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 12, height: 12)
    }
}

/// This Mac in the right column: what it has, and where to get better voices.
struct MacVoicePanel: View {
    private let source = VoiceSource.mac

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: source.title, detail: String(localized: "系统自带")) {
                ServiceTile(mark: source.mark, size: 34)
            }
            PanelCard {
                PanelRow { Text("声音") } trailing: {
                    Text("\(source.voiceCount) 个，在左边听").font(.yy(size: 12)).foregroundStyle(YYColor.t2)
                }
                PanelRow { Text("费用") } trailing: {
                    Text("免费 · 不联网").font(.yy(size: 12)).foregroundStyle(YYColor.t2)
                }
            }
            PanelCard {
                PanelButton {
                    OutLinkGlyph()
                    Text("下载更自然的声音").foregroundStyle(YYColor.t1)
                    Spacer(minLength: 0)
                } action: {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
                }
            }
            PanelHint(String(localized: "系统设置 › 辅助功能 › 朗读内容 › 管理声音，下“高级”的那几个，回来就在左边。"))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }
}

/// One not set up yet: its Key row (and Azure's region), typed into straight away, tried once
/// it looks whole; where to get a key, as a line under it.
private struct CloudVoiceKeyPanel: View {
    let provider: CloudVoice.Provider
    @State private var key = ""
    @State private var region = CloudVoice.Provider.region
    @State private var connect = AutoConnect()
    private var focus: ListeningFocus { .shared }

    var body: some View {
        let step = provider.keyStep
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: provider.title, detail: provider.blurb) {
                ServiceTile(mark: .cloud(provider), size: 34)
            }
            PanelCard {
                if provider == .azure { RegionRow(region: $region) }
                PanelField(label: "Key", text: $key, prompt: provider == .azure ? String(localized: "密钥 1") : provider.keyHint,
                           secure: true, bad: connect.failed, autofocus: true, submit: { attempt(now: true) })
            }
            AutoConnectStatus(connect: connect)
            PanelCard {
                PanelButton {
                    OutLinkGlyph()
                    Text(step.title).foregroundStyle(YYColor.t1)
                    Spacer(minLength: 0)
                } action: { NSWorkspace.shared.open(step.url) }
            }
            PanelHint(step.detail + String(localized: "。Key 只存在这台 Mac 上，费用走你自己的账号。"))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .onChange(of: key) { attempt(now: false) }
        .onChange(of: region) { if !key.isEmpty { attempt(now: true) } }
    }

    private func attempt(now: Bool) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard now ? !k.isEmpty : AutoConnect.looksLikeKey(k) else { connect.reset(); return }
        let p = provider, r: String? = provider == .azure ? region : nil
        connect.start(String(localized: "正在连 \(p.title)…"), delay: now ? .zero : .milliseconds(600)) {
            try await p.tryKey(k, region: r)
        } done: {
            focus.reload()
            focus.page = nil
            focus.open(.cloud(p))
        }
    }
}

/// Azure's region, chosen from a menu at the end of the row.
private struct RegionRow: View {
    @Binding var region: String

    var body: some View {
        PanelRow { Text("区域") } trailing: {
            Menu {
                ForEach(CloudVoice.Provider.regions, id: \.id) { r in
                    Button { region = r.id } label: {
                        if r.id == region { Label("\(r.name) · \(r.id)", systemImage: "checkmark") } else { Text("\(r.name) · \(r.id)") }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(CloudVoice.Provider.regions.first { $0.id == region }.map { "\($0.name) · \($0.id)" } ?? region)
                        .font(.yy(size: 12)).foregroundStyle(YYColor.t2)
                    Image(systemName: "chevron.up.chevron.down").font(.yy(size: 8.5, weight: .semibold)).foregroundStyle(YYColor.t3)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// One connected service: its Key (pressed, it's typed again in the row), Azure's region,
/// its voices, 检查连接, 断开.
struct CloudVoicePanel: View {
    let provider: CloudVoice.Provider
    @State private var editing = false
    @State private var key = ""
    @State private var region = CloudVoice.Provider.region
    @State private var connect = AutoConnect()
    @State private var check = AutoConnect()
    @State private var removing = false
    private var focus: ListeningFocus { .shared }

    var body: some View {
        let _ = focus.tick
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title: provider.title, detail: provider.inUse ? String(localized: "朗读在用") : provider.account) {
                ServiceTile(mark: .cloud(provider), size: 34)
            }
            PanelCard {
                if editing {
                    PanelField(label: "Key", text: $key, prompt: String(localized: "贴上新的 Key"), secure: true, bad: connect.failed,
                               autofocus: true, submit: { attempt(now: true) }, cancel: stopEditing)
                } else {
                    PanelButton {
                        Text(verbatim: "Key")
                        Spacer(minLength: 8)
                        Text(provider.maskedKey)
                            .font(.yy(size: 12, design: .monospaced)).foregroundStyle(YYColor.t2).lineLimit(1)
                        Image(systemName: "chevron.right").font(.yy(size: 9.5, weight: .semibold)).foregroundStyle(YYColor.t3)
                    } action: { editing = true }
                    .help(Text("换一个 Key"))
                }
                if provider == .azure { RegionRow(region: $region) }
                PanelRow { Text("声音") } trailing: {
                    Text("\(provider.voiceCount) 个，在左边听").font(.yy(size: 12)).foregroundStyle(YYColor.t2)
                }
            }
            if editing {
                AutoConnectStatus(connect: connect)
                if case .idle = connect.phase {
                    PanelHint(String(localized: "贴上就去试，能用才换掉原来的。Esc 不换了。"))
                }
            }
            PanelCard { checkRow }
            PanelCard {
                PanelButton(tint: YYColor.danger, destructive: true) {
                    Text("断开 \(provider.title)")
                } action: { removing = true }
            }
            .confirmationDialog(String(localized: "断开 \(provider.title)？"), isPresented: $removing) {
                Button("断开", role: .destructive) {
                    provider.remove()
                    focus.page = nil
                    if focus.source == .cloud(provider) { focus.close() }
                    focus.reload()
                }
            } message: {
                Text("它的 Key 也一起删掉。正在用它的声音的，换回这台 Mac 的声音。")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .onChange(of: key) { attempt(now: false) }
        .onChange(of: region) {
            guard let k = provider.key else { return }
            let p = provider, r = region
            check.start("", delay: .zero) { try await p.tryKey(k, region: r) } done: { focus.reload() }
        }
    }

    private func stopEditing() {
        editing = false
        key = ""
        connect.reset()
    }

    private func attempt(now: Bool) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard now ? !k.isEmpty : AutoConnect.looksLikeKey(k) else { connect.reset(); return }
        let p = provider, r: String? = provider == .azure ? region : nil
        connect.start(String(localized: "正在试新的 Key…"), delay: now ? .zero : .milliseconds(600)) {
            try await p.tryKey(k, region: r)
        } done: {
            stopEditing()
            focus.reload()
        }
    }

    /// 检查连接: fetches its voices again; the answer stays on the row.
    private var checkRow: some View {
        PanelButton(systemImage: "waveform.path.ecg", tint: YYColor.ok) {
            Text("检查连接").foregroundStyle(YYColor.ok)
            Spacer(minLength: 8)
            switch check.phase {
            case .idle: EmptyView()
            case .checking: ProgressView().controlSize(.mini)
            case .ok: SettingsPill(String(localized: "正常 · \(provider.voiceCount) 个声音"), tone: .ok)
            case .failed(let why):
                Text(why).font(.yy(size: 11)).foregroundStyle(YYColor.danger).lineLimit(2).multilineTextAlignment(.trailing)
            }
        } action: {
            guard !check.busy, let k = provider.key else { return }
            let p = provider, r: String? = provider == .azure ? region : nil
            check.start("", delay: .zero) { try await p.tryKey(k, region: r) } done: { focus.reload() }
        }
    }
}
#endif
