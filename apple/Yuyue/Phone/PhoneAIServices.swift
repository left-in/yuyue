#if os(iOS)
import SwiftUI
import UIKit

/// 我的 · 引擎 · 书伴: the services connected (设置 · AI 服务 on the Mac), which model answers,
/// and 添加服务.
struct PhoneAIServices: View {
    @State private var ai = AIServices.shared
    @State private var adding = false
    private let tint = YYTint.standard

    var body: some View {
        YYGroup {
            Menu {
                if Companion.appleAvailability == nil {
                    Button { ai.companion = .apple } label: { check(ai.companion == .apple, String(localized: "Apple 智能（这台设备上）")) }
                }
                ForEach(ai.services) { s in
                    Section(s.name) {
                        ForEach(s.models, id: \.self) { m in
                            Button { ai.companion = AIChoice(service: s.id, model: m) } label: {
                                check(ai.companion.service == s.id && ai.companion.model == m, m)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: YYUI.s(8)) {
                    VStack(alignment: .leading, spacing: YYUI.s(1)) {
                        Text("书伴用").font(YYUI.font(11.5)).foregroundStyle(YYColor.t1)
                        Text(ai.service(ai.companion.service) == nil && Companion.appleAvailability != nil
                             ? String(localized: "还没选：先添加一个服务") : ai.companionLabel)
                            .font(YYUI.font(10)).foregroundStyle(YYColor.t3).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(YYUI.font(9, .semibold)).foregroundStyle(YYColor.t3)
                }
                .padding(.vertical, YYUI.s(8))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            ForEach(ai.services) { s in
                HStack(spacing: YYUI.s(10)) {
                    ServiceBadge(kind: s.kind)
                    VStack(alignment: .leading, spacing: YYUI.s(1)) {
                        Text(s.name).font(YYUI.font(11.5)).foregroundStyle(YYColor.t1)
                        Text(s.detail).font(YYUI.font(10)).foregroundStyle(YYColor.t3).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, YYUI.s(8))
                .contextMenu {
                    Button("刷新模型") { Task { try? await ai.refresh(s) } }
                    Button("移除", role: .destructive) { ai.remove(s) }
                }
                .swipeActions { Button("移除", role: .destructive) { ai.remove(s) } }
            }
            Button { adding = true } label: {
                HStack(spacing: YYUI.s(6)) {
                    Image(systemName: "plus").font(YYUI.font(10.5, .semibold))
                    Text("添加服务").font(YYUI.font(11.5, .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(tint.accent)
                .padding(.vertical, YYUI.s(9))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $adding) { PhoneAddService(ai: ai) }
    }

    @ViewBuilder private func check(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

private struct ServiceBadge: View {
    let kind: AIPreset
    var size: CGFloat = 24

    var body: some View {
        Text(String(kind.name.prefix(1)).uppercased())
            .font(YYUI.font(size * 0.42, .bold))
            .foregroundStyle(.white)
            .frame(width: YYUI.s(size), height: YYUI.s(size))
            .background(kind.color, in: .rect(cornerRadius: YYUI.s(size * 0.27)))
    }
}

/// 添加服务: paste a key and it says whose it is, or pick the service first.
private struct PhoneAddService: View {
    let ai: AIServices
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var chosen: AIPreset?
    @State private var url = ""
    @State private var checking = false
    @State private var match: (AIPreset, [String])?
    @State private var failure: String?
    private let tint = YYTint.standard

    var body: some View {
        VStack(alignment: .leading, spacing: YYUI.s(12)) {
            YYSheetHeader(title: chosen.map { String(localized: "接上 \($0.name)") } ?? String(localized: "添加服务"),
                          subtitle: String(localized: "不用填模型名")) { dismiss() }
            HStack(spacing: YYUI.s(8)) {
                SecureField("", text: $key, prompt: Text(chosen.map { String(localized: "粘贴 \($0.name) 的 Key") } ?? String(localized: "粘贴 Key，自动认出是哪家")))
                    .font(YYUI.font(12, design: .monospaced))
                    .padding(.horizontal, YYUI.s(10)).frame(height: YYUI.s(36))
                    .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(9)))
                Button("粘贴") { if let s = UIPasteboard.general.string { key = s.trimmingCharacters(in: .whitespacesAndNewlines) } }
                    .buttonStyle(YYButtonStyle(kind: .soft, size: .small))
            }
            if chosen?.id == "custom" {
                TextField("", text: $url, prompt: Text(verbatim: "https://…/v1"))
                    .font(YYUI.font(12, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(.horizontal, YYUI.s(10)).frame(height: YYUI.s(36))
                    .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(9)))
            }
            status
            if chosen == nil {
                Text("或者先选是哪家").font(YYUI.font(10)).foregroundStyle(YYColor.t3)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: YYUI.s(6)), count: 3), spacing: YYUI.s(6)) {
                    ForEach(AIPreset.keyed) { p in
                        Button { chosen = p; url = p.id == "custom" ? "" : p.url; check() } label: {
                            HStack(spacing: YYUI.s(6)) {
                                RoundedRectangle(cornerRadius: 4).fill(p.color).frame(width: YYUI.s(12), height: YYUI.s(12))
                                Text(p.name).font(YYUI.font(10.5)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, YYUI.s(8)).frame(height: YYUI.s(32))
                            .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(8)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Button("换一家") { chosen = nil; check() }.font(YYUI.font(11)).foregroundStyle(tint.accent)
            }
            Spacer(minLength: 0)
            Button("接上", action: connect)
                .buttonStyle(YYButtonStyle(kind: .main, size: .large, wide: true))
                .disabled(match == nil)
        }
        .padding(YYUI.s(16))
        .presentationDetents([.medium, .large])
        .onChange(of: key) { check() }
        .onChange(of: url) { if chosen?.id == "custom" { check() } }
    }

    @ViewBuilder private var status: some View {
        if let (p, models) = match {
            HStack(spacing: YYUI.s(8)) {
                ServiceBadge(kind: p, size: 20)
                Text("\(p.name)：能用，找到 \(models.count) 个模型").font(YYUI.font(11)).foregroundStyle(YYColor.ok)
            }
        } else if checking {
            HStack(spacing: YYUI.s(8)) { ProgressView(); Text("正在核对…").font(YYUI.font(11)).foregroundStyle(YYColor.t2) }
        } else if let failure {
            Text(failure).font(YYUI.font(11)).foregroundStyle(YYColor.danger)
        }
    }

    private func check() {
        match = nil
        failure = nil
        let key = key, chosen = chosen, url = url
        if chosen?.id == "custom" {
            guard URL(string: url)?.scheme?.hasPrefix("http") == true else { return }
        } else if key.trimmingCharacters(in: .whitespaces).count < 8 {
            return
        }
        checking = true
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard key == self.key, url == self.url, chosen == self.chosen else { return }
            if let chosen {
                do { match = (chosen, try await AIServices.models(chosen, url: url, key: key)) } catch { failure = Companion.message(for: error) }
            } else {
                switch await AIServices.identify(key) {
                case .found(let p, let models): match = (p, models)
                case .refused(let p, let error): failure = String(localized: "是 \(p.name) 的 Key，但核对没通过：\(Companion.message(for: error))")
                case .unknown: failure = String(localized: "认不出是哪家的 Key：在下面选是哪家，再粘贴一次")
                }
            }
            checking = false
        }
    }

    private func connect() {
        guard let (p, models) = match else { return }
        ai.add(p, key: key.trimmingCharacters(in: .whitespacesAndNewlines), url: p.id == "custom" ? url : nil, models: models)
        dismiss()
    }
}
#endif
