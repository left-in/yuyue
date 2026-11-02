import SwiftUI
import YuyueCore
#if os(macOS)

/// 编辑部 · 和编辑说话 (docs/design/播客.html): the editor is a person. It says how many new
/// articles came, which it picked and in what order, and why the rest were left out; the
/// reader answers ("放最后", "不要这条", "短一点") and it changes the pick.
struct MacEditorDesk: View {
    let library: Library
    let show: Show
    let close: () -> Void
    @State private var typed = ""
    @FocusState private var focused: Bool
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }
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
            suggestions
            input
        }
        .padding(.bottom, 20)
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

    /// 输入框上面一行行纯文字, like Claude's.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Self.suggested, id: \.self) { s in
                Button { send(s) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(YYColor.t3)
                        Text(s).font(.yy(size: 12.5)).foregroundStyle(YYColor.t2)
                    }
                    .padding(.horizontal, 8).frame(height: 26).contentShape(.rect)
                }
                .buttonStyle(HoverWash())
            }
        }
        .frame(maxWidth: 660, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .opacity(progress?.picked.isEmpty == false ? 1 : 0)
    }

    private static let suggested = [String(localized: "多讲一点第一条"), String(localized: "不要最后一条"), String(localized: "短一点")]

    private var input: some View {
        TextField(String(localized: "跟编辑说…"), text: $typed)
            .textFieldStyle(.plain)
            .font(.yy(size: 13))
            .focused($focused)
            .onSubmit { send(typed) }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(YYColor.card, in: .rect(cornerRadius: 14))
            .yyShadow(YYShadow.cardLight)
            .frame(maxWidth: 660)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22)
    }

    private func send(_ text: String) {
        podcasts.say(text, to: show)
        typed = ""
    }

    private struct HoverWash: ButtonStyle {
        @State private var hover = false
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(YYColor.t1.opacity(hover || configuration.isPressed ? 0.05 : 0), in: .rect(cornerRadius: 8))
                .onHover { hover = $0 }
        }
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
