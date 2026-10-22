#if os(macOS)
import AppKit
import SwiftUI

/// 设置 · AI 服务: the services connected once (已接上), 添加服务, and who uses which (谁用哪个).
/// Connecting asks the service for its models; nothing is typed but a key.
struct CompanionSettings: View {
    let library: Library
    @State private var ai = AIServices.shared
    @State private var adding = false
    @State private var testing = false
    @State private var result: Result<TimeInterval, Error>?
    private let tint = YYTint.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("接上一次，书伴就能用。可以接本机的 magpie、Ollama，或者填你自己的 Key；费用直接走你的账号，语阅不经手。")
                .font(.system(size: 12)).foregroundStyle(YYColor.t2).lineSpacing(3)
                .padding(.horizontal, 8)

            SettingsHeading(String(localized: "已接上"))
            SettingsCard {
                ForEach(ai.services) { ServiceRow(service: $0, ai: ai) }
                Button { adding = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        Text("添加服务").font(.system(size: 13, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(tint.accent)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            SettingsHeading(String(localized: "谁用哪个"))
            SettingsCard {
                SettingsRow(String(localized: "书伴"), detail: String(localized: "回答关于这本书的问题")) {
                    HStack(spacing: 10) {
                        if testing { ProgressView().controlSize(.small) }
                        switch result {
                        case .success(let t):
                            Label("\(t.formatted(.number.precision(.fractionLength(1)))) 秒", systemImage: "checkmark.circle")
                                .font(.system(size: 11.5)).foregroundStyle(YYColor.ok)
                        case .failure(let e):
                            Label(Companion.message(for: e), systemImage: "exclamationmark.circle")
                                .font(.system(size: 11.5)).foregroundStyle(YYColor.danger).lineLimit(1)
                                .help(Companion.message(for: e))
                        case nil: EmptyView()
                        }
                        ModelPicker(ai: ai, choice: $ai.companion)
                        Button("试一下", action: test).disabled(testing)
                    }
                }
            }
            .onChange(of: ai.companion) { result = nil }

            Label("Key 只存在这台设备的钥匙串里，不同步、不上传；本机的 magpie、Ollama 不出这台 Mac", systemImage: "lock")
                .font(.system(size: 11)).foregroundStyle(YYColor.t3)
                .padding(.leading, 8)
            Spacer(minLength: 0)
        }
        .sheet(isPresented: $adding) { AddServiceSheet(ai: ai) }
    }

    private func test() {
        testing = true
        result = nil
        let config = CompanionConfig.current
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

/// The service's first letter on its colour.
struct ServiceMark: View {
    let kind: AIPreset
    var size: CGFloat = 28

    var body: some View {
        Text(String(kind.name.prefix(1)).uppercased())
            .font(.system(size: size * 0.43, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(kind.color, in: .rect(cornerRadius: size * 0.27))
    }
}

/// One connected service: what it is, how many models, 刷新 and 移除 on hover.
private struct ServiceRow: View {
    let service: AIService
    let ai: AIServices
    @State private var hover = false
    @State private var state: String?
    @State private var failed = false

    var body: some View {
        HStack(spacing: 12) {
            ServiceMark(kind: service.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.kind.local ? String(localized: "\(service.name)（本机）") : service.name)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(YYColor.t1)
                Text(state ?? service.detail).font(.system(size: 11)).foregroundStyle(failed ? YYColor.danger : YYColor.t2)
                    .lineLimit(1)
            }
            Spacer()
            if hover {
                Button("刷新模型", action: refresh).controlSize(.small)
                Button("移除") { ai.remove(service) }.controlSize(.small).foregroundStyle(YYColor.danger)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .contentShape(.rect)
        .onHover { hover = $0 }
        .contextMenu {
            Button("刷新模型", action: refresh)
            Button("移除", role: .destructive) { ai.remove(service) }
        }
    }

    private func refresh() {
        state = String(localized: "正在问它有哪些模型…")
        failed = false
        Task {
            do {
                try await ai.refresh(service)
                state = nil
            } catch {
                state = Companion.message(for: error)
                failed = true
            }
        }
    }
}

/// 书伴用哪个模型: Apple 智能 where it can be used, then every connected service's models.
private struct ModelPicker: View {
    let ai: AIServices
    @Binding var choice: AIChoice

    var body: some View {
        Menu {
            if Companion.appleAvailability == nil {
                Button { choice = .apple } label: { check(choice == .apple, String(localized: "Apple 智能（这台 Mac 上）")) }
            }
            ForEach(ai.services) { s in
                Section(s.name) {
                    ForEach(s.models, id: \.self) { m in
                        Button { choice = AIChoice(service: s.id, model: m) } label: {
                            check(choice.service == s.id && choice.model == m, m)
                        }
                    }
                }
            }
        } label: {
            Text(ai.service(choice.service) == nil && Companion.appleAvailability != nil
                 ? String(localized: "还没选") : ai.companionLabel)
                .lineLimit(1)
        }
        .menuStyle(.button)
        .fixedSize()
        .frame(maxWidth: 300, alignment: .trailing)
    }

    @ViewBuilder private func check(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

/// 添加服务: paste a key and it says whose it is; or one found running on this Mac; or pick a
/// service and paste its key.
private struct AddServiceSheet: View {
    let ai: AIServices
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var found: [(AIPreset, [String])] = []
    @State private var looking = true
    @State private var chosen: AIPreset?
    @State private var url = ""
    @State private var checking = false
    @State private var match: (AIPreset, [String])?
    @State private var failure: String?
    private let tint = YYTint.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(chosen.map { String(localized: "接上 \($0.name)") } ?? String(localized: "添加服务"))
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                if chosen != nil {
                    Button("换一家") { chosen = nil; match = nil; failure = nil }.buttonStyle(.link)
                }
            }

            keyField
            if chosen?.id == "custom" {
                TextField("", text: $url, prompt: Text(verbatim: "https://…/v1"))
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            }
            status

            if chosen == nil {
                if looking || !found.isEmpty {
                    label(String(localized: "这台 Mac 上找到的"))
                    if looking {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在找本机的 magpie、Ollama、LM Studio…").font(.system(size: 11.5)).foregroundStyle(YYColor.t3) }
                    }
                    ForEach(found, id: \.0.id) { item in localRow(item.0, item.1) }
                }
                label(String(localized: "用 Key 接"))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(AIPreset.keyed) { p in
                        Button { chosen = p; match = nil; failure = nil; url = p.id == "custom" ? "" : p.url } label: {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 5).fill(p.color).frame(width: 16, height: 16)
                                Text(p.name).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).frame(height: 34)
                            .background(YYColor.inset, in: .rect(cornerRadius: 9))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Text("不用填模型名：接上时会问它有哪些模型。").font(.system(size: 11)).foregroundStyle(YYColor.t3)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("接上", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(match == nil)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 560)
        .task {
            found = await ai.discover()
            looking = false
        }
        .onChange(of: key) { check() }
        .onChange(of: url) { if chosen?.id == "custom" { check() } }
    }

    private var keyField: some View {
        HStack(spacing: 8) {
            SecureField("", text: $key, prompt: Text(chosen.map { $0.id == "custom" ? String(localized: "Key（没有就空着）") : String(localized: "粘贴 \($0.name) 的 Key") }
                                                     ?? String(localized: "在这里粘贴 Key，自动认出是哪家")))
                .textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced))
            Button("粘贴") {
                if let s = NSPasteboard.general.string(forType: .string) { key = s.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if checking || match != nil || failure != nil {
            HStack(spacing: 10) {
                if let (p, models) = match {
                    ServiceMark(kind: p, size: 22)
                    Text("认出是 \(p.name)").font(.system(size: 12.5))
                    Spacer()
                    Label("能用，找到 \(models.count) 个模型", systemImage: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(YYColor.ok)
                } else if checking {
                    ProgressView().controlSize(.small)
                    Text(chosen == nil ? String(localized: "正在认是哪家、核对 Key…") : String(localized: "正在核对…")).font(.system(size: 12.5)).foregroundStyle(YYColor.t2)
                    Spacer()
                } else if let failure {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(YYColor.danger)
                    Text(failure).font(.system(size: 12)).foregroundStyle(YYColor.danger).lineLimit(2)
                    Spacer()
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(YYColor.inset, in: .rect(cornerRadius: 10))
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(YYColor.t3).padding(.top, 4)
    }

    private func localRow(_ p: AIPreset, _ models: [String]) -> some View {
        HStack(spacing: 12) {
            ServiceMark(kind: p)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(size: 13, weight: .semibold))
                Text(p.id == "magpie"
                     ? String(localized: "在运行，\(models.count) 个模型；背后接着你在 magpie 里配的所有 Key 和订阅")
                     : String(localized: "在运行，\(models.count) 个模型"))
                    .font(.system(size: 11)).foregroundStyle(YYColor.t2).lineLimit(1)
            }
            Spacer()
            Button("接上") {
                ai.add(p, key: "", models: models)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(tint.accent.opacity(0.06), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.accent.opacity(0.18)))
    }

    private func check() {
        match = nil
        failure = nil
        let key = key, chosen = chosen, url = url
        if let chosen, chosen.id == "custom" {
            guard URL(string: url)?.scheme?.hasPrefix("http") == true else { return }
        } else if key.trimmingCharacters(in: .whitespaces).count < 8 {
            return
        }
        checking = true
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard key == self.key, url == self.url else { return }
            if let chosen {
                do {
                    let models = try await AIServices.models(chosen, url: url, key: key)
                    if key == self.key { match = (chosen, models) }
                } catch {
                    if key == self.key { failure = Companion.message(for: error) }
                }
            } else if let found = await AIServices.identify(key) {
                if key == self.key { match = found }
            } else if key == self.key {
                failure = String(localized: "认不出是哪家的 Key：在下面选是哪家，再粘贴一次")
            }
            if key == self.key { checking = false }
        }
    }

    private func connect() {
        guard let (p, models) = match else { return }
        ai.add(p, key: key.trimmingCharacters(in: .whitespacesAndNewlines), url: p.id == "custom" ? url : nil, models: models)
        dismiss()
    }
}
#endif
