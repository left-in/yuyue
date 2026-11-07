import SwiftUI
import YuyueCore
#if os(macOS)

/// 配一档节目: three steps on the left — 听什么, 谁来讲, 什么时候、多长 —
/// and on the right what tomorrow's episode would sound like. 什么时候 is one line, changed
/// only when asked: the template has chosen already.
struct MacShowEditor: View {
    let library: Library
    @State var edit: ShowDraftEdit
    let close: () -> Void
    @State private var adding = ""
    @State private var finding = false
    @State private var addError: String?
    @State private var changingTime = false
    /// The template this started from, by its own name: renaming the show doesn't rename it.
    @State private var template: String?
    @State private var failure: String?
    @AppStorage("appearance.tint") private var tintID = YYTint.pine.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .pine }
    private var draft: Binding<ShowDraft> { $edit.draft }

    var body: some View {
        // 配节目-排版.html · 重排后: the two columns, and under both one bar for 取消 / 建好了.
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        title
                        step(1, String(localized: "听什么")) { sources }
                        step(2, String(localized: "谁来讲")) { hosts }
                        step(3, String(localized: "什么时候、多长")) { when }
                    }
                    // Room under step 3, so all of it shows above the bar.
                    .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 24)
                }
                .frame(width: 520)
                Rectangle().fill(YYColor.line).frame(width: 0.5)
                preview.frame(width: 300)
            }
            .frame(maxHeight: .infinity)
            footer
        }
        .frame(height: 600)
        .background(YYColor.bg)
        // The sheet gives the name the keyboard on its own, with all of it selected: the
        // title opened as a grey highlighted block. Nothing has it until the reader clicks.
        .onAppear {
            if template == nil, edit.id == nil { template = edit.draft.name }
            // The sheet's window takes the field a beat after it appears; let go after that.
            for delay in [0.0, 0.15, 0.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    for w in NSApp.windows where w.isSheet && w.isVisible { w.makeFirstResponder(nil) }
                }
            }
        }
    }

    /// `.mk2-ft`: a hairline over it, across both columns. Which model writes on the left; 取消
    /// (only words) and 建好了 (the white capsule, in the theme's colour, ⌘↩) on the right.
    private var footer: some View {
        HStack(spacing: 10) {
            if let failure {
                Text(failure).font(.yy(size: 11)).foregroundStyle(YYColor.danger).lineLimit(1)
            } else {
                (Text("写稿用 ") + Text(CompanionConfig.current.label).foregroundStyle(YYColor.t2).fontWeight(.medium))
                    .font(.yy(size: 11)).foregroundStyle(YYColor.t3).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            PodcastTextButton(title: String(localized: "取消")) { close() }
                .keyboardShortcut(.cancelAction)
            PodcastGlassButton(title: edit.id == nil ? String(localized: "建好了") : String(localized: "好了"), kind: .main, flat: true, key: "⌘↩") { save() }
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.leading, 24).padding(.trailing, 20)
        .frame(height: 56)
        .background(YYColor.bg)
        .overlay(alignment: .top) { Rectangle().fill(YYColor.line).frame(height: 0.5) }
    }

    private var title: some View {
        HStack(spacing: 10) {
            TextField(String(localized: "节目名"), text: draft.name)
                .textFieldStyle(.plain).font(.yy(size: 19, weight: .bold)).foregroundStyle(YYColor.t1)
                .focusEffectDisabled()
                .fixedSize()
            if edit.id == nil {
                Menu {
                    ForEach(Array(Podcasts.templates().enumerated()), id: \.offset) { _, t in
                        Button(t.name) { edit.draft = t; template = t.name }
                    }
                } label: {
                    Text("从“\(template ?? edit.draft.name)”开始").font(.yy(size: 10.5)).foregroundStyle(YYColor.t2)
                        .padding(.horizontal, 7).frame(height: 20).background(YYColor.inset, in: .rect(cornerRadius: 5))
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
            }
            Spacer()
        }
    }

    private func step(_ n: Int, _ name: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("\(n)").font(.yy(size: 11.5, weight: .bold)).foregroundStyle(YYColor.bg)
                    .frame(width: 22, height: 22).background(YYColor.t1, in: .circle)
                Text(name).font(.yy(size: 13, weight: .semibold)).foregroundStyle(YYColor.t1)
            }
            content().padding(.leading, 32)
        }
    }

    // MARK: 1 听什么

    private var sources: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(edit.draft.sources.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 10) {
                    sourceMark(s)
                    Text(s.name).font(.yy(size: 12.5)).foregroundStyle(s.paused ? YYColor.t3 : YYColor.t1).lineLimit(1)
                    Text(sourceKind(s)).font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
                    Spacer()
                    // 多一点少一点: five steps.
                    HStack(spacing: 3) {
                        ForEach(1 ... 5, id: \.self) { w in
                            Capsule().fill(w <= s.weight ? tint.accent : YYColor.line).frame(width: 20, height: 5)
                                .contentShape(.rect.inset(by: -6))
                                .onTapGesture { edit.draft.sources[i].weight = UInt8(w) }
                        }
                    }
                    .accessibilityElement().accessibilityLabel(Text("多一点少一点")).accessibilityValue(Text("\(s.weight)"))
                    .accessibilityAdjustableAction { d in
                        let w = Int(edit.draft.sources[i].weight) + (d == .increment ? 1 : -1)
                        edit.draft.sources[i].weight = UInt8(min(5, max(1, w)))
                    }
                    Menu {
                        Button(s.paused ? String(localized: "接着用") : String(localized: "先停一停")) { edit.draft.sources[i].paused.toggle() }
                        Button(String(localized: "去掉"), role: .destructive) { edit.draft.sources.remove(at: i) }
                    } label: { Image(systemName: "ellipsis").foregroundStyle(YYColor.t3) }
                        .menuStyle(.button).buttonStyle(.plain).fixedSize()
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(tint.accent)
                TextField(String(localized: "粘贴网址：博客、新闻站、RSS"), text: $adding)
                    .textFieldStyle(.plain).font(.yy(size: 12.5))
                    .onSubmit(addSource)
                if finding { ProgressView().controlSize(.small) }
                Menu(String(localized: "Hacker News")) {
                    Button(String(localized: "首页热门")) { addHN("top", "Hacker News") }
                    Button("Show HN") { addHN("show", "Show HN") }
                    Button("Ask HN") { addHN("ask", "Ask HN") }
                }
                .menuStyle(.button).buttonStyle(.plain).font(.yy(size: 11.5)).foregroundStyle(tint.accent).fixedSize()
            }
            if let addError { Text(addError).font(.yy(size: 11)).foregroundStyle(YYColor.danger) }
            Text("右边五格是“多讲一点还是少讲一点”。还可以写一句给编辑：")
                .font(.yy(size: 11)).foregroundStyle(YYColor.t3).padding(.top, 4)
            TextField(String(localized: "多讲开源工具，少讲融资"), text: draft.brief, axis: .vertical)
                .textFieldStyle(.plain).font(.custom("Kaiti SC", size: 13)).foregroundStyle(YYColor.t1)
                .padding(10).background(YYColor.card, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(YYColor.line, lineWidth: 0.5))
        }
    }

    private func sourceMark(_ s: ShowSource) -> some View {
        let (letter, color): (String, Color) = switch s.kind {
        case .hackerNews: ("Y", Color(red: 0.95, green: 0.4, blue: 0.13))
        case .highlights: (String(localized: "划"), tint.accent)
        case .words: (String(localized: "词"), tint.accent)
        default: (String(s.name.prefix(1)).uppercased(), Color(white: 0.2))
        }
        return Text(letter).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            .frame(width: 15, height: 15).background(color, in: .rect(cornerRadius: 4))
    }

    private func sourceKind(_ s: ShowSource) -> String {
        switch s.kind {
        case .hackerNews: String(localized: "连评论")
        case .feed: s.address.contains("github.com") ? String(localized: "发布更新") : "RSS"
        case .page: String(localized: "网页")
        case .highlights: String(localized: "不联网")
        case .words: String(localized: "不联网")
        }
    }

    private func addHN(_ list: String, _ name: String) {
        edit.draft.sources.append(ShowSource(kind: .hackerNews, address: list, name: name, weight: 3, limit: 15, paused: false))
    }

    /// A pasted address: the feed itself, or a page that names one.
    private func addSource() {
        var text = adding.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.host() != nil else { addError = String(localized: "这不是一个网址"); return }
        finding = true
        addError = nil
        Task {
            defer { finding = false }
            do {
                var r = URLRequest(url: url, timeoutInterval: 20)
                r.setValue("Yuyue/1.0 (+https://yuyue.app)", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: r)
                if let feed = try? parseFeed(bytes: data, base: text) {
                    let name = feed.title.isEmpty ? (url.host() ?? text) : feed.title
                    edit.draft.sources.append(ShowSource(kind: .feed, address: text, name: name, weight: 3, limit: 10, paused: false))
                } else if let link = feedLinks(html: String(decoding: data, as: UTF8.self), base: text).first {
                    let feedData = try await URLSession.shared.data(from: URL(string: link.url)!).0
                    let feed = try parseFeed(bytes: feedData, base: link.url)
                    edit.draft.sources.append(ShowSource(kind: .feed, address: link.url, name: link.title ?? feed.title, weight: 3, limit: 10, paused: false))
                } else {
                    addError = String(localized: "这个网页没写它的 RSS 在哪")
                    return
                }
                adding = ""
            } catch {
                addError = Podcasts.message(for: error)
            }
        }
    }

    // MARK: 2 谁来讲

    private var hosts: some View {
        VStack(alignment: .leading, spacing: 10) {
            YYSegments(items: [(ShowForm.duo, String(localized: "两人对谈")), (ShowForm.solo, String(localized: "单人播报"))],
                       selection: Binding(get: { edit.draft.form }, set: setForm), small: true)
                .frame(width: 200)
            HStack(alignment: .top, spacing: 10) {
                ForEach(edit.draft.hosts.indices, id: \.self) { i in hostCard(i) }
            }
        }
    }

    private func setForm(_ f: ShowForm) {
        edit.draft.form = f
        if f == .solo { edit.draft.hosts = Array(edit.draft.hosts.prefix(1)) }
        if f == .duo && edit.draft.hosts.count == 1 { edit.draft.hosts.append(Podcasts.templates()[0].hosts[1]) }
    }

    private func hostCard(_ i: Int) -> some View {
        let h = edit.draft.hosts[i]
        let language = edit.draft.language
        let voices = Voices.all(for: language)
        let showID = edit.id ?? "new"
        let current = HostVoices.voice(show: showID, host: h.name, index: i, language: language)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(String(h.name.prefix(1))).font(.custom("Songti SC", size: 13).weight(.bold)).foregroundStyle(i == 0 ? tint.accent : YYColor.hlR)
                    .frame(width: 24, height: 24).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(i == 0 ? tint.accent : YYColor.hlR, lineWidth: 1.2))
                TextField(String(localized: "名字"), text: draft.hosts[i].name).textFieldStyle(.plain).font(.yy(size: 13, weight: .semibold))
            }
            TextField(String(localized: "他是什么样的人"), text: draft.hosts[i].about, axis: .vertical)
                .textFieldStyle(.plain).font(.custom("Kaiti SC", size: 12.5)).foregroundStyle(YYColor.t2).lineLimit(2 ... 3)
            HStack(spacing: 6) {
                Button { if let current { Voices.preview(current, text: "\(h.name)：\(String(localized: "早上好，今天讲几件事。"))") } } label: {
                    Image(systemName: "play.fill").font(.system(size: 8)).frame(width: 22, height: 22).background(YYColor.inset, in: .circle)
                }
                .buttonStyle(.plain)
                Menu(current.map(Voices.title) ?? String(localized: "没有声音")) {
                    ForEach(voices, id: \.id) { v in
                        Button(Voices.title(v)) { HostVoices.choose(v, show: showID, host: h.name) }
                    }
                }
                .menuStyle(.button).buttonStyle(.plain).font(.yy(size: 11)).foregroundStyle(YYColor.t2).fixedSize()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YYColor.card, in: .rect(cornerRadius: 12))
        .yyShadow(YYShadow.cardLight)
    }

    // MARK: 3 什么时候、多长

    private var when: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock").font(.system(size: 16)).foregroundStyle(tint.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(edit.draft.schedule.line) · \(String(localized: "约 \(edit.draft.minutes) 分钟"))").font(.yy(size: 13, weight: .semibold))
                Text("这台 Mac 来写 · 模板已经替你定好").font(.yy(size: 11)).foregroundStyle(YYColor.t3)
            }
            Spacer()
            PodcastGlassButton(title: String(localized: "更改"), flat: true) { changingTime = true }
                .popover(isPresented: $changingTime, arrowEdge: .bottom) { timePanel }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(YYColor.card, in: .rect(cornerRadius: 12))
        .yyShadow(YYShadow.cardLight)
    }

    private var timePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            DatePicker(String(localized: "时间"), selection: Binding(get: {
                Calendar.current.date(bySettingHour: Int(edit.draft.schedule.minute / 60), minute: Int(edit.draft.schedule.minute % 60), second: 0, of: Date()) ?? Date()
            }, set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                edit.draft.schedule.minute = UInt32((c.hour ?? 7) * 60 + (c.minute ?? 0))
            }), displayedComponents: .hourAndMinute)
            HStack(spacing: 6) {
                let names = PodcastSchedule.weekdayNames
                ForEach(1 ... 7, id: \.self) { d in
                    let on = edit.draft.schedule.days.contains(UInt32(d))
                    Button {
                        if on { edit.draft.schedule.days.removeAll { $0 == UInt32(d) } } else { edit.draft.schedule.days.append(UInt32(d)) }
                    } label: {
                        Text(names[d - 1]).font(.yy(size: 12, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? .white : YYColor.t2)
                            .frame(width: 28, height: 28).background(on ? tint.accent : YYColor.inset, in: .circle)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(edit.draft.schedule.days.isEmpty ? String(localized: "一天都不选：只在点“现在写一集”的时候写") : " ")
                .font(.yy(size: 11)).foregroundStyle(YYColor.t3)
            YYSegments(items: [(UInt32(5), String(localized: "5 分钟")), (UInt32(10), String(localized: "10 分钟")), (UInt32(20), String(localized: "20 分钟"))],
                       selection: draft.minutes, small: true)
        }
        .padding(16)
        .frame(width: 300)
    }

    // MARK: 右边：明早大概是这样

    /// Where source `i` would start in an episode of `minutes`: each gets time by its 五格 weight.
    private static func start(of i: Int, in sources: [ShowSource], minutes: Int) -> String {
        let total = max(1, sources.reduce(0) { $0 + Int($1.weight) })
        let before = sources.prefix(i).reduce(0) { $0 + Int($1.weight) }
        let seconds = max(1, minutes) * 60 * before / total
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("按现在这样，\(edit.draft.schedule.days.isEmpty ? String(localized: "下一集") : String(localized: "明早 \(edit.draft.schedule.line.split(separator: " ").last.map(String.init) ?? "")")) 大概是这样")
                .font(.yy(size: 11)).foregroundStyle(YYColor.t3)
            Text(edit.draft.name.isEmpty ? String(localized: "这一集的标题") : String(localized: "\(edit.draft.name) · 今天讲这几件事"))
                .font(.custom("Songti SC", size: 18).weight(.bold)).foregroundStyle(YYColor.t1)
            VStack(alignment: .leading, spacing: 8) {
                let live = Array(edit.draft.sources.filter { !$0.paused }.prefix(4))
                ForEach(Array(live.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 8) {
                        Text(Self.start(of: i, in: live, minutes: Int(edit.draft.minutes))).font(.yy(size: 11)).monospacedDigit().foregroundStyle(YYColor.t3)
                        sourceMark(s)
                        Text(String(localized: "\(s.name) 上最新的一条")).font(.yy(size: 12, weight: .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(edit.draft.hosts.enumerated()), id: \.offset) { i, h in
                    HStack(alignment: .top, spacing: 8) {
                        Text(String(h.name.prefix(1))).font(.custom("Songti SC", size: 11).weight(.bold)).foregroundStyle(i == 0 ? tint.accent : YYColor.hlR)
                            .frame(width: 18, height: 18).overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(i == 0 ? tint.accent : YYColor.hlR, lineWidth: 1))
                        Text(i == 0 ? String(localized: "早上好。先从一个有点反常识的事说起。") : String(localized: "有个小团队，把 SQLite 当消息队列用了三年……"))
                            .font(.custom("Songti SC", size: 13)).foregroundStyle(i == 0 ? YYColor.t1 : YYColor.t3).lineSpacing(4)
                    }
                }
            }
            .padding(.top, 6)
            // 听这两句, right under the two lines it reads, saying whose voices they are.
            HStack(spacing: 10) {
                PodcastGlassButton(title: String(localized: "听这两句"), symbol: "headphones", flat: true) {
                    let showID = edit.id ?? "new"
                    if let h = edit.draft.hosts.first, let v = HostVoices.voice(show: showID, host: h.name, index: 0, language: edit.draft.language) {
                        Voices.preview(v, text: String(localized: "早上好。先从一个有点反常识的事说起。"))
                    }
                }
                if !voiceNames.isEmpty {
                    Text(String(localized: "用\(voiceNames)的声音")).font(.yy(size: 10.5)).foregroundStyle(YYColor.t3).lineLimit(2)
                }
            }
            .padding(.top, 2)
            Spacer()
        }
        .padding(20)
        .frame(maxHeight: .infinity)
        .background(Color(red: 0.96, green: 0.957, blue: 0.93).opacity(0.6))
    }

    /// 婷婷和 Eddy: the voices the hosts read with on this Mac.
    private var voiceNames: String {
        let showID = edit.id ?? "new"
        let names = edit.draft.hosts.enumerated().compactMap { i, h in
            HostVoices.voice(show: showID, host: h.name, index: i, language: edit.draft.language)?.name
        }
        return names.joined(separator: String(localized: "和"))
    }

    private func save() {
        do {
            if let id = edit.id {
                try library.podcasts.update(id, edit.draft)
            } else {
                let s = try library.podcasts.add(edit.draft)
                // Voices chosen while it had no id move to it.
                for h in s.hosts {
                    if let v = HostVoices.chosen(show: "new", host: h.name) { HostVoices.choose(v, show: s.id, host: h.name) }
                }
            }
            close()
        } catch {
            failure = Podcasts.message(for: error)
        }
    }
}
#endif
