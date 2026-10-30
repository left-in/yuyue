#if os(macOS)
import SwiftUI

/// 设置 · 书伴, after nanobot's webui: the service is a menu (this Mac's own, those added, then
/// 配置… and 添加服务商…), the model its own row with the ones the service lists, then 测试一下.
/// 管理服务商 lists what was added. Keys stay in the keychain.
struct CompanionSettings: View {
    let library: Library
    @State private var choice = CompanionChoice()
    @State private var sheet: CompanionProviderSheet.Start?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Companion.appleAvailability == nil
                 ? String(localized: "书伴默认用这台 Mac 自带的，不花钱，不联网也能用。想换更强的，就添加一个服务商，填你自己的 Key，费用直接走你的账号，语阅不经手。")
                 : String(localized: "这台 Mac 用不了 Apple 智能，书伴要接一个：添加一个服务商填你自己的 Key，或接本机的 Ollama、magpie。费用直接走你的账号，语阅不经手。"))
                .font(.yy(size: 12)).foregroundStyle(YYColor.t2).lineSpacing(3)
                .padding(.horizontal, 8)
            SettingsHeading(String(localized: "书伴"))
            SettingsCard {
                SettingsRow(String(localized: "服务商"), detail: choice.current.provider.kind == .apple ? choice.current.provider.detail : nil) {
                    providerMenu
                }
                if choice.current.provider.kind != .apple {
                    SettingsRow(String(localized: "模型"), detail: choice.listing ? String(localized: "正在问它有哪些模型…") : nil) {
                        modelField
                    }
                }
                SettingsRow(String(localized: "测试一下"), detail: testDetail) {
                    HStack(spacing: 8) {
                        if choice.testing { ProgressView().controlSize(.small) }
                        Button("测试") { choice.test() }
                            .buttonStyle(YYButtonStyle(kind: .raised, size: .small))
                            .disabled(!choice.current.isReady || choice.testing)
                    }
                }
            }
            HStack {
                Label("Key 只存在这台设备的钥匙串里，不同步、不上传", systemImage: "lock")
                    .font(.yy(size: 11)).foregroundStyle(YYColor.t3)
                Spacer()
                Button("管理服务商") { sheet = .manage }
                    .buttonStyle(.plain)
                    .font(.yy(size: 12)).foregroundStyle(YYColor.t2)
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        .sheet(item: $sheet, onDismiss: choice.reload) { CompanionProviderSheet(start: $0) }
        .task { await choice.list() }
    }

    /// nanobot's ProviderPicker: those to choose from, a line, 配置 the one in use, 添加服务商.
    private var providerMenu: some View {
        Menu {
            ForEach(choice.options) { p in
                Button { choice.choose(p) } label: {
                    if choice.current.provider == p { Label(p.title, systemImage: "checkmark") } else { Text(p.title) }
                }
            }
            if !choice.options.isEmpty { Divider() }
            if choice.current.provider.kind != .apple {
                Button("配置 \(choice.current.provider.title)…", systemImage: "pencil") { sheet = .edit(choice.current.provider) }
            }
            Button("添加服务商…", systemImage: "plus") { sheet = .add }
        } label: {
            HStack(spacing: 7) {
                if choice.options.isEmpty {
                    Text("添加服务商…").foregroundStyle(YYColor.t2)
                } else {
                    ProviderLogo(provider: choice.current.provider, size: 18)
                    Text(choice.current.provider.title).foregroundStyle(YYColor.t1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.yy(size: 9, weight: .semibold)).foregroundStyle(YYColor.t3)
            }
            .font(.yy(size: 12.5))
            .padding(.horizontal, 8)
            .frame(width: 220, height: 28)
            .background(YYColor.card, in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(YYColor.line, lineWidth: 0.5))
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Typed, or one of those the service lists.
    private var modelField: some View {
        HStack(spacing: 4) {
            TextField("", text: Bindable(choice).model, prompt: Text(choice.current.provider.modelHint))
                .textFieldStyle(.roundedBorder).font(.yy(size: 12, design: .monospaced))
                .autocorrectionDisabled()
            Menu {
                ForEach(choice.models, id: \.self) { m in Button(m) { choice.model = m } }
            } label: {
                Image(systemName: "chevron.down").font(.yy(size: 10, weight: .semibold))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(choice.models.isEmpty)
            .help(Text("它列出的模型"))
        }
        .frame(width: 220)
    }

    private var testDetail: String? {
        switch choice.result {
        case .success(let t): String(localized: "能用 · 回答用了 \(t.formatted(.number.precision(.fractionLength(1)))) 秒")
        case .failure(let e): Companion.message(for: e)
        case nil: choice.current.isReady ? nil : choice.current.provider.kind == .apple ? Companion.appleAvailability : String(localized: "还没选好模型")
        }
    }
}
#endif
