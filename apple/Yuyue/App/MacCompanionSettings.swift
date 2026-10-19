#if os(macOS)
import AppKit
import SwiftUI

/// 设置 · 书伴 (prototype 引擎 / 填 Key): which engine answers. The one on this Mac by default;
/// or the user's own key, kept in the keychain. 测试一下 really asks, and says how long it took
/// or what went wrong.
struct CompanionSettings: View {
    let library: Library
    @State private var current = CompanionConfig.current
    @State private var editing: CompanionConfig?
    @State private var cached: Int64 = 0
    private let tint = YYTint.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("书伴默认用这台 Mac 自带的，不花钱，不联网也能用。想换更强的，就填你自己的 Key，费用直接走你的账号，语阅不经手。")
                .font(.system(size: 12)).foregroundStyle(YYColor.t2).lineSpacing(3)
                .padding(.horizontal, 8)
            SettingsHeading(String(localized: "书伴用哪个"))
            SettingsCard {
                ForEach(CompanionProvider.allCases) { p in row(p) }
            }
            if let editing {
                KeyForm(config: editing, done: { saved in
                    if let saved {
                        CompanionConfig.current = saved
                        current = saved
                    }
                    self.editing = nil
                })
                .id(editing.provider)
            }
            SettingsCard {
                SettingsRow(String(localized: "存下的回答"), detail: String(localized: "同一本书、读到同一章问同样的问题，直接用存下的，不再花钱")) {
                    HStack(spacing: 10) {
                        Text(ByteCountFormatter.string(fromByteCount: cached, countStyle: .file))
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(YYColor.t2)
                        Button("清掉") {
                            try? FileManager.default.removeItem(at: cacheDir)
                            measure()
                        }
                        .disabled(cached == 0)
                    }
                }
            }
            Label("Key 只存在这台设备的钥匙串里，不同步、不上传", systemImage: "lock")
                .font(.system(size: 11)).foregroundStyle(YYColor.t3)
                .padding(.leading, 8)
            Spacer(minLength: 0)
        }
        .onAppear(perform: measure)
    }

    private var cacheDir: URL { library.dataDir.appending(path: "companion", directoryHint: .isDirectory) }

    private func measure() {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        cached = files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func row(_ p: CompanionProvider) -> some View {
        let saved = CompanionConfig.saved(p)
        let on = current.provider == p
        let detail: String? = p == .apple ? (Companion.appleAvailability ?? p.detail) : p.detail
        return Button {
            if p == .apple {
                guard Companion.appleAvailability == nil else { return }
                CompanionConfig.current = saved
                current = saved
                editing = nil
            } else {
                editing = saved
            }
        } label: {
            SettingsRow(p.title, detail: detail) {
                HStack(spacing: 8) {
                    if p != .apple {
                        Text(saved.isReady ? String(localized: "已填 Key") : String(localized: "填 Key"))
                            .font(.system(size: 12)).foregroundStyle(editing?.provider == p ? tint.accent : YYColor.t2)
                    }
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint.accent)
                        .opacity(on && current.isReady ? 1 : 0)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(p == .apple && Companion.appleAvailability != nil ? 0.6 : 1)
    }
}

/// 填 Key: 服务商, API Key, 模型, 接口地址; 测试一下, 保存.
private struct KeyForm: View {
    @State var config: CompanionConfig
    let done: (CompanionConfig?) -> Void
    @State private var testing = false
    @State private var result: Result<TimeInterval, Error>?
    private let tint = YYTint.standard

    var body: some View {
        SettingsCard {
            SettingsRow(String(localized: "服务商")) {
                Text(config.provider.title).font(.system(size: 12.5)).foregroundStyle(YYColor.t1)
            }
            SettingsRow(config.provider == .openai ? String(localized: "API Key（可不填）") : "API Key") {
                HStack(spacing: 6) {
                    SecureField("", text: $config.key, prompt: Text(config.provider.keyHint))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    Button("粘贴") {
                        if let s = NSPasteboard.general.string(forType: .string) { config.key = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                }
                .frame(width: 300)
            }
            SettingsRow(String(localized: "模型")) {
                TextField("", text: $config.model, prompt: Text(config.provider == .openai ? String(localized: "比如 qwen3:8b") : config.provider.defaultModel))
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    .frame(width: 300)
            }
            SettingsRow(String(localized: "接口地址")) {
                TextField("", text: $config.url, prompt: Text(config.provider == .openai ? String(localized: "比如 http://localhost:11434/v1") : String(localized: "空着就用官方的")))
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    .frame(width: 300)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button("测试一下", action: test)
                        .disabled(!config.isReady || testing)
                    if testing { ProgressView().controlSize(.small) }
                    switch result {
                    case .success(let t):
                        Label("能用 · 回答用了 \(t.formatted(.number.precision(.fractionLength(1)))) 秒", systemImage: "checkmark.circle")
                            .font(.system(size: 11.5)).foregroundStyle(YYColor.ok)
                    case .failure(let e):
                        Label(Companion.message(for: e), systemImage: "exclamationmark.circle")
                            .font(.system(size: 11.5)).foregroundStyle(YYColor.danger).lineLimit(2)
                    case nil:
                        EmptyView()
                    }
                    Spacer()
                    Button("取消") { done(nil) }
                        .buttonStyle(YYButtonStyle(kind: .plain))
                    Button("保存") { done(config) }
                        .buttonStyle(YYButtonStyle(kind: .main))
                        .disabled(!config.isReady)
                }
                Text(config.provider == .openai
                     ? String(localized: "Key 只存在这台设备的钥匙串里。Ollama 这类本机模型不用 Key，填上地址和模型名就行。")
                     : String(localized: "Key 只存在这台设备的钥匙串里。费用走你自己的 \(config.provider.account) 账号，语阅不经手，也看不到。"))
                    .font(.system(size: 11)).foregroundStyle(YYColor.t3)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private func test() {
        testing = true
        result = nil
        let config = config
        Task {
            let start = Date()
            do {
                _ = try await Companion.answer(config, system: String(localized: "你是一个简短的助手。"), prompt: String(localized: "用一个词回答：天空通常是什么颜色？"))
                result = .success(Date().timeIntervalSince(start))
            } catch {
                result = .failure(error)
            }
            testing = false
        }
    }
}
#endif
