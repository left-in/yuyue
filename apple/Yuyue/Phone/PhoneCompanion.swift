#if os(iOS)
import SwiftUI
import YuyueCore

/// 书伴 on the phone (prototype 与书对话): the same talk as the Mac's panel, in a sheet over the
/// page. Half height to keep the page in sight; a 出处 tag turns the page underneath.
struct PhoneCompanion: View {
    @Bindable var model: ReaderModel
    @State private var draft = ""
    @State private var settings = false
    @FocusState private var typing: Bool
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }
    private var companion: BookCompanion { model.companion }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mode.padding(.horizontal, 16).padding(.top, 4)
                chat
                VStack(alignment: .leading, spacing: 8) {
                    if let quote = model.companionQuote { quoted(quote) }
                    suggestions
                    input
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(YYColor.bg)
            .navigationTitle("书伴")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("清空这次的对话", systemImage: "trash") { companion.clear() }.disabled(companion.turns.isEmpty)
                        Button("书伴设置", systemImage: "gearshape") { settings = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel(Text("更多"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { model.panel = nil }
                }
            }
            .sheet(isPresented: $settings) {
                if let library = model.library {
                    NavigationStack {
                        PhoneEngines(library: library)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } } }
                    }
                }
            }
        }
        .onDisappear { model.pager.setSource(nil) }
    }

    private var mode: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: Bindable(companion).scope) {
                Text("只用读过的部分").tag(BookCompanion.Scope.read)
                Text("问全书").tag(BookCompanion.Scope.whole)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text(companion.scope == .read ? readUpTo + String(localized: "，后面的事它不会说") : String(localized: "会用到整本书，可能提前知道结尾"))
                .font(.yy(size: 12)).foregroundStyle(YYColor.t3).padding(.horizontal, 2)
        }
    }

    private var readUpTo: String {
        if let page = model.bookPage { return String(localized: "你读到第 \(page) 页") }
        return String(localized: "你读到这里")
    }

    // MARK: Turns

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if companion.turns.isEmpty { welcome }
                    ForEach(companion.turns) { turn in
                        VStack(alignment: .leading, spacing: 10) {
                            bubble(turn.question)
                            reply(turn)
                        }
                        .id(turn.id)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: companion.turns.map(\.id)) {
                if let last = companion.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onChange(of: companion.busy) {
                if let last = companion.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder private var welcome: some View {
        let config = CompanionConfig.current
        VStack(alignment: .leading, spacing: 8) {
            Text("读到哪儿问到哪儿").font(.yy(size: 15, weight: .semibold)).foregroundStyle(YYColor.t1)
            Text("可以问人物关系、这句是什么意思、前面发生了什么。回答标着出处，点一下就翻到那句。")
                .font(.yy(size: 14)).foregroundStyle(YYColor.t2).lineSpacing(3)
            if !config.isReady {
                Text(config.provider == .apple ? Companion.appleAvailability ?? "" : String(localized: "还没填好 \(config.provider.title) 的 Key"))
                    .font(.yy(size: 13)).foregroundStyle(YYColor.t3).lineSpacing(3)
                Button("去设置 · 书伴") { settings = true }
                    .buttonStyle(.bordered).padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YYColor.inset, in: .rect(cornerRadius: 16))
    }

    private func bubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.yy(size: 15))
                .lineSpacing(3)
                .foregroundStyle(tint.onBlack)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(tint.black, in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private func reply(_ turn: BookCompanion.Turn) -> some View {
        if let answer = turn.answer {
            VStack(alignment: .leading, spacing: 8) {
                if answer.notYet {
                    Text("\(readUpTo)，这件事可能要到后面才写。切到“问全书”就能回答，不过会提前知道后面的事。")
                        .font(.yy(size: 15)).lineSpacing(8).foregroundStyle(YYColor.t1)
                    Button { companion.ask(turn.question, quote: turn.quote, scope: .whole) } label: {
                        HStack(spacing: 8) {
                            Text("用全书回答").font(.yy(size: 13, weight: .semibold)).foregroundStyle(YYColor.t1)
                            Label("可能剧透", systemImage: "exclamationmark.triangle")
                                .font(.yy(size: 11, weight: .semibold)).foregroundStyle(YYColor.warn)
                        }
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(YYColor.card, in: .capsule)
                        .overlay(Capsule().strokeBorder(YYColor.line))
                    }
                    .buttonStyle(.plain)
                    .disabled(companion.busy)
                } else {
                    Text(cited(answer))
                        .font(.yy(size: 15))
                        .lineSpacing(8)
                        .foregroundStyle(YYColor.t1)
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in
                            if let n = Int(url.host() ?? ""), let source = answer.sources[n] { companion.show(source) }
                            return .handled
                        })
                    HStack(spacing: 4) {
                        Image(systemName: turn.scope == .whole ? "book" : "sparkle").font(.yy(size: 10))
                        Text(turn.scope == .whole ? answer.label + String(localized: " · 用了全书") : answer.label)
                    }
                    .font(.yy(size: 11)).foregroundStyle(YYColor.t3)
                }
            }
        } else if let failed = turn.failed {
            Label(failed, systemImage: "exclamationmark.circle")
                .font(.yy(size: 13)).foregroundStyle(YYColor.danger)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("正在翻书…").font(.yy(size: 13)).foregroundStyle(YYColor.t3)
            }
        }
    }

    /// The answer with each [n] turned into a little 第 N 页 tag that goes there.
    private func cited(_ answer: BookCompanion.Answer) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(answer.text)
        while let m = rest.firstMatch(of: /\s?\[(\d+)\]/) {
            out += AttributedString(String(rest[..<m.range.lowerBound]))
            if let n = Int(m.1), let source = answer.sources[n] {
                let place = source.page.map { String(localized: "第 \($0) 页") } ?? String(localized: "出处")
                let label = " " + place + (source.later == true ? String(localized: " · 没读到") : "") + " "
                var tag = AttributedString(label.replacingOccurrences(of: " ", with: "\u{00A0}"))
                tag.font = .yy(size: 11, weight: .semibold)
                if source.later == true, companion.shown != source {
                    tag.foregroundColor = tint.accent
                    tag.underlineStyle = Text.LineStyle(pattern: .dash, color: tint.accent)
                } else {
                    tag.foregroundColor = companion.shown == source ? YYColor.card : tint.accent
                    tag.backgroundColor = companion.shown == source ? tint.accent : tint.accentSoft
                }
                tag.link = URL(string: "yuyue-cite://\(n)")
                out += AttributedString(" ") + tag
            }
            rest = rest[m.range.upperBound...]
        }
        out += AttributedString(String(rest))
        return out
    }

    // MARK: Asking

    private func quoted(_ quote: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(quote)
                .font(YYUI.serif(13))
                .foregroundStyle(YYColor.t2)
                .lineLimit(2)
                .padding(.leading, 9)
                .overlay(alignment: .leading) { Rectangle().fill(tint.accent).frame(width: 1.5) }
            Spacer(minLength: 0)
            Button("不带这句", systemImage: "xmark") { model.companionQuote = nil }
                .labelStyle(.iconOnly)
                .font(.yy(size: 11, weight: .bold))
                .foregroundStyle(YYColor.t3)
                .buttonStyle(.plain)
        }
    }

    private var suggestions: some View {
        let list = model.companionQuote != nil ? [String(localized: "这句是什么意思？"), String(localized: "为什么这么写？")]
            : companion.turns.last?.answer?.next ?? [String(localized: "前面发生了什么？"), String(localized: "这一章讲了什么？")]
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(list, id: \.self) { s in
                    Button { send(s) } label: {
                        Text(s)
                            .font(.yy(size: 13)).foregroundStyle(YYColor.t2)
                            .padding(.horizontal, 13).frame(height: 32)
                            .background(YYColor.card, in: .capsule)
                            .overlay(Capsule().strokeBorder(YYColor.line, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(companion.busy)
                }
            }
        }
        .scrollIndicators(.never)
    }

    private var input: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("", text: $draft, prompt: Text(companion.turns.isEmpty ? String(localized: "问这本书…") : String(localized: "继续问…")), axis: .vertical)
                .font(.yy(size: 16))
                .lineLimit(1 ... 4)
                .focused($typing)
                .submitLabel(.send)
                .onSubmit { send(draft) }
                .padding(.vertical, 10)
            Button { send(draft) } label: {
                Image(systemName: "arrow.up").font(.yy(size: 14, weight: .bold))
                    .foregroundStyle(tint.onBlack)
                    .frame(width: 34, height: 34)
                    .background(tint.black, in: .circle)
            }
            .accessibilityLabel(Text("发送"))
            .buttonStyle(.plain)
            .padding(.bottom, 5)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || companion.busy)
        }
        .padding(.leading, 16).padding(.trailing, 6)
        .background(YYColor.card, in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(YYColor.line, lineWidth: 0.5))
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !companion.busy else { return }
        companion.ask(q, quote: model.companionQuote)
        draft = ""
        model.companionQuote = nil
    }
}
#endif
