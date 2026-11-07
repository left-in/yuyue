import SwiftUI
import YuyueCore
#if os(macOS)

/// 编辑部 · 和编辑说话: the editor is a person. It says how many new
/// articles came, which it picked and in what order, and why the rest were left out; the
/// reader answers ("放最后", "不要这条", "短一点") and it changes the pick.
struct MacEditorDesk: View {
    let library: Library
    let show: Show
    let close: () -> Void
    @State private var typed = ""
    @State private var linesOpen = false
    @FocusState private var focused: Bool
    @AppStorage("appearance.tint") private var tintID = YYTint.pine.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .pine }
    private var podcasts: Podcasts { library.podcasts }

    private var messages: [Podcasts.Message] { podcasts.talk[show.id] ?? [] }
    private var progress: Podcasts.Progress? { podcasts.writing[show.id] }

    var body: some View {
        VStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Spacer(minLength: 0)
                        if messages.isEmpty { opening }
                        ForEach(messages) { m in bubble(m).id(m.id) }
                        if let p = progress, p.step != .save { typing(p) }
                        if let why = podcasts.failure[show.id] {
                            editor(Text(why).foregroundStyle(YYColor.danger))
                            PodcastGlassButton(title: String(localized: "再试一次"), symbol: "arrow.clockwise") { podcasts.write(show) }
                                .padding(.leading, 38)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: 660, minHeight: 0, alignment: .bottomLeading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 22)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: messages.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            input
        }
        .padding(.bottom, 20)
        .overlay {
            if linesOpen, canSuggest {
                Color.clear.contentShape(.rect).onTapGesture { linesOpen = false }
                ReadyLinesCard(width: 330) {
                    ForEach(Self.suggested, id: \.self) { s in
                        QuickLine(line: s) { linesOpen = false; send(s) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .frame(maxWidth: 660)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 22)
                .padding(.bottom, 20 + 40 + 8)
            }
        }
        #if DEBUG
        .onAppear { if UserDefaults.standard.bool(forKey: "debugEditorLines") { linesOpen = true } }
        #endif
    }

    private var opening: some View {
        VStack(alignment: .leading, spacing: 10) {
            editor(Text(podcasts.isWriting(show.id)
                ? String(localized: "我在看今天有什么新的，挑好了告诉你。")
                : String(localized: "今天还没写。要现在写一集吗？")))
            if !podcasts.isWriting(show.id) {
                PodcastGlassButton(title: String(localized: "现在写一集"), symbol: "sparkles") { podcasts.write(show) }
                    .padding(.leading, 38)
            }
        }
    }

    @ViewBuilder private func bubble(_ m: Podcasts.Message) -> some View {
        if m.fromEditor {
            editor(VStack(alignment: .leading, spacing: 6) {
                Text(m.text)
                if m.offersRewrite, m.id == messages.last(where: \.offersRewrite)?.id, podcasts.isWriting(show.id) {
                    PodcastGlassButton(title: String(localized: "重写这一集"), symbol: "arrow.clockwise") { podcasts.rewrite(show) }
                        .padding(.top, 2)
                }
                if !m.list.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(m.list.enumerated()), id: \.offset) { i, title in
                            let now = progress?.step == .summarize && progress?.done == i
                            let done = (progress?.step ?? .pick) > .summarize || (progress?.step == .summarize && i < progress?.done ?? 0)
                            Text("\(i + 1). \(title)\(now ? String(localized: " · 正在写") : "")")
                                .font(.yy(size: 12.5, weight: now ? .semibold : .regular))
                                .foregroundStyle(now ? tint.accent : done || progress == nil ? YYColor.t1 : YYColor.t3)
                        }
                    }
                }
            })
        } else {
            HStack {
                Spacer(minLength: 80)
                Text(m.text)
                    .font(.yy(size: 13)).foregroundStyle(.white).lineSpacing(3)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(tint.accent, in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 5, topTrailingRadius: 16))
            }
        }
    }

    private func editor(_ content: some View) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            Text(String(localized: "编")).font(.yy(size: 12, weight: .bold)).foregroundStyle(tint.accent)
                .frame(width: 28, height: 28).background(tint.accentSoft, in: .circle)
            content
                .font(.yy(size: 13)).foregroundStyle(YYColor.t1).lineSpacing(3)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(YYColor.card, in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 5, bottomTrailingRadius: 16, topTrailingRadius: 16))
                .yyShadow(YYShadow.cardLight)
            Spacer(minLength: 60)
        }
    }

    private func typing(_ p: Podcasts.Progress) -> some View {
        editor(HStack(spacing: 8) {
            TypingDots()
            Text(p.line).font(.yy(size: 12)).foregroundStyle(YYColor.t3)
        })
    }

    /// These only make sense once it has picked something.
    private var canSuggest: Bool { progress?.picked.isEmpty == false }

    private static let suggested = [String(localized: "多讲一点第一条"), String(localized: "不要最后一条"), String(localized: "短一点")]

    /// “ for a ready remark, what you type, ↑. While it writes: what it's doing in place of the
    /// prompt, 停下 at the right end, ↑ only once there's something to send.
    private var input: some View {
        let empty = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let writing = podcasts.isWriting(show.id)
        return HStack(spacing: 8) {
            if canSuggest { ReadyLinesToggle(open: $linesOpen, help: Text("挑一句现成的")) }
            TextField("", text: $typed, prompt: Text(prompt).font(.yy(size: 12)).foregroundStyle(YYColor.t3))
                .textFieldStyle(.plain)
                .font(.custom("Songti SC", size: 13))
                .foregroundStyle(YYColor.t1)
                .focused($focused)
                .onSubmit { send(typed) }
                .padding(.leading, 2)
                .offset(y: 2)
            if empty, !writing {
                Text("回车发").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3).fixedSize()
            }
            if writing {
                Button { podcasts.cancel(show.id) } label: {
                    RoundedRectangle(cornerRadius: 2.5).fill(YYColor.t2).frame(width: 10, height: 10)
                        .frame(width: 28, height: 28).contentShape(.rect)
                }
                .buttonStyle(HoverSquareStyle())
                .help(String(localized: "停下"))
                .accessibilityLabel(String(localized: "停下"))
            }
            if !writing || !empty {
                ComposerSendButton(ready: !empty, help: Text("发给编辑")) { send(typed) }
            }
        }
        .padding(.leading, canSuggest ? 6 : 14).padding(.trailing, 6)
        .composerBox()
            .frame(maxWidth: 660)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22)
    }

    private var prompt: String {
        guard let progress else { return String(localized: "跟编辑说…") }
        let line = progress.line.trimmingCharacters(in: CharacterSet(charactersIn: "…"))
        return String(localized: "\(line)，有话随时说…")
    }

    private func send(_ text: String) {
        podcasts.say(text, to: show)
        typed = ""
    }
}

/// The editor is writing: three dots on a little beige pill (the one picked for 播客's look).
struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2)) { t in
            let s = t.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0 ..< 3) { i in
                    Circle().fill(YYColor.t3).frame(width: 6, height: 6)
                        .opacity(0.35 + 0.65 * max(0, sin(s * 4 - Double(i) * 0.8)))
                }
            }
        }
        .accessibilityLabel(Text("正在写"))
    }
}
#endif
