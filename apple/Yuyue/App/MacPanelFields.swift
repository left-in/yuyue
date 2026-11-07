#if os(macOS)
import SwiftUI
import AppKit

// The right column's typing pieces: a key is typed
// straight into its row, no box, no sheet; once it looks whole it's tried on its own, and the
// row says how that went. No 连接, no 取消, no 粘贴 or 👁 buttons: ⌘V pastes, Esc puts it back.

/// A row of a `PanelCard` that is typed into: its name on the left, the words on the right.
/// Lit softly while typing in it; red when what's in it didn't work.
struct PanelField: View {
    let label: String
    @Binding var text: String
    var prompt = ""
    var secure = false
    var mono = true
    var bad = false
    var autofocus = false
    var submit: () -> Void = {}
    var cancel: (() -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.yy(size: 12.5)).foregroundStyle(bad ? YYColor.danger : YYColor.t1).fixedSize()
            // Not being typed in, a long address shows its two ends, not its start cut off.
            let shown = !focused && !secure && !text.isEmpty
            ZStack(alignment: .trailing) {
                Group {
                    if secure {
                        SecureField("", text: $text, prompt: Text(prompt))
                    } else {
                        TextField("", text: $text, prompt: Text(prompt))
                    }
                }
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit(submit)
                .onKeyPress(.escape) {
                    guard let cancel else { return .ignored }
                    cancel()
                    return .handled
                }
                .opacity(shown ? 0 : 1)
                if shown {
                    Text(text).lineLimit(1).truncationMode(.middle).allowsHitTesting(false)
                }
            }
            .font(mono ? .yy(size: 12, design: .monospaced) : .yy(size: 12.5))
            .foregroundStyle(YYColor.t1)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 38)
        .background(bad ? YYColor.danger.opacity(0.08) : focused ? YYColor.t1.opacity(0.05) : .clear, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onTapGesture { focused = true }
        // A moment late: a sheet hands the first field the focus once it's up, after this.
        .task {
            guard autofocus else { return }
            try? await Task.sleep(for: .milliseconds(250))
            focused = true
        }
    }
}

/// Tries what was typed once it looks whole, a moment after the typing stops; a new keystroke
/// starts over. What it found goes up as ticks, then a green line, then `done`.
@MainActor @Observable
final class AutoConnect {
    struct Tick: Identifiable {
        let id = UUID()
        let title: String
        var detail: String?
    }
    struct Outcome {
        var ticks: [Tick]
        var banner: String
    }
    enum Phase {
        case idle
        case checking(String)
        case ok(Outcome)
        case failed(String)
    }

    private(set) var phase = Phase.idle
    private var task: Task<Void, Never>?

    var failed: Bool { if case .failed = phase { true } else { false } }
    var busy: Bool { if case .checking = phase { true } else { false } }

    func start(_ checking: String, delay: Duration = .milliseconds(600),
               describe: @escaping (Error) -> String = { $0.localizedDescription },
               work: @escaping @MainActor () async throws -> Outcome,
               done: @escaping @MainActor () -> Void) {
        task?.cancel()
        phase = .idle
        task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { phase = .checking(checking) }
            do {
                let o = try await work()
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { phase = .ok(o) }
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                done()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                withAnimation(.easeOut(duration: 0.2)) { phase = .failed(describe(error)) }
            }
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    /// Long enough and in one piece: worth trying.
    static func looksLikeKey(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 20 && !t.contains(where: \.isWhitespace)
    }

    /// http(s), with a host that could be reached: worth trying.
    static func looksLikeAddress(_ s: String) -> Bool {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespaces)), let scheme = u.scheme, scheme.hasPrefix("http"),
              let host = u.host(), !host.isEmpty else { return false }
        return host.contains(".") || host == "localhost" || u.port != nil
    }
}

/// Under the fields: why it didn't work, in red; or the ticks and the green line.
struct AutoConnectStatus: View {
    let connect: AutoConnect

    var body: some View {
        switch connect.phase {
        case .idle:
            EmptyView()
        case .failed(let why):
            Text(why).font(.yy(size: 11)).lineSpacing(2).foregroundStyle(YYColor.danger)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.top, -4)
        case .checking(let what):
            card {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.mini).frame(width: 15)
                    Text(what).font(.yy(size: 12)).foregroundStyle(YYColor.t3)
                }
            }
        case .ok(let o):
            card {
                ForEach(o.ticks) { t in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "checkmark").font(.yy(size: 8, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 15, height: 15).background(YYColor.ok, in: .circle)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).font(.yy(size: 12)).foregroundStyle(YYColor.t1)
                            if let d = t.detail { Text(d).font(.yy(size: 11)).foregroundStyle(YYColor.t3) }
                        }
                    }
                }
                HStack(spacing: 7) {
                    Image(systemName: "checkmark").font(.yy(size: 10.5, weight: .bold))
                    Text(o.banner).font(.yy(size: 12, weight: .medium))
                }
                .foregroundStyle(YYColor.ok)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(YYColor.ok.opacity(0.12), in: .rect(cornerRadius: 8))
                .padding(.top, 2)
            }
        }
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) { c() }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(YYColor.card, in: .rect(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(YYColor.line, lineWidth: 0.5))
            .transition(.opacity.combined(with: .offset(y: -3)))
    }
}

#endif
