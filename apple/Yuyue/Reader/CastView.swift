import SwiftUI
import YuyueCore

/// 人物声音 (docs/design/听书-分角色与克隆声音.html, R2–R4): who has spoken so far in the book and
/// the voice each reads with. Everyone reads with the narrator's until given one; the narrator's
/// is the book's voice from the listen card. Spoilers stay out: only those up to this chapter.
struct CastSheet: View {
    let core: YuyueCore
    let bookID: String
    let section: UInt32
    let player: Player?
    let language: String
    /// Opened straight on someone (the Mac's cast panel).
    var start: [Route] = []
    let close: () -> Void

    enum Route: Hashable {
        case role(String)
        /// Choosing a voice for someone, or (nil) the narrator.
        case voice(String?)
        case clone(String?)
    }

    @State private var path: [Route] = []
    @State private var cast: [CastMember] = []
    @State private var roles: [Role] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .role(let name): RoleView(context: context, name: name, path: $path)
                    case .voice(let name): VoiceChoiceView(context: context, name: name, path: $path)
                    case .clone(let name): CloneVoiceView(context: context, forName: name, path: $path)
                    }
                }
        }
        .task { path = start; await load() }
        .onReceive(NotificationCenter.default.publisher(for: CastContext.changed)) { _ in Task { await load() } }
        #if os(macOS)
        .frame(width: 420, height: 600)
        #endif
    }

    private var context: CastContext {
        CastContext(core: core, bookID: bookID, section: section, player: player, language: language, cast: cast, roles: roles)
    }

    private var list: some View {
        YYPage {
            YYGroup {
                Button { path.append(.voice(nil)) } label: {
                    CastRow(avatar: nil, color: YYColor.t3, name: String(localized: "旁白"),
                            detail: String(localized: "没单独设声音的人物也用这个"),
                            voice: player?.currentVoice(for: language)?.name ?? String(localized: "没有声音"), own: true)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, YYUI.s(12))
            let here = cast.filter { $0.linesHere > 0 }
            let before = cast.filter { $0.linesHere == 0 }
            if !here.isEmpty {
                YYLabel(String(localized: "这一章"), String(localized: "\(here.count) 人"))
                YYGroup { ForEach(here, id: \.name) { row($0) } }
            }
            if !before.isEmpty {
                YYLabel(String(localized: "前面出场过"), String(localized: "读到这里共 \(cast.count) 人"))
                YYGroup { ForEach(before, id: \.name) { row($0) } }
            }
            if loaded, cast.isEmpty {
                YYNote(String(localized: "读到这里还没认出谁在说话。对话多的书读几章后，这里会列出说过话的人。"))
            } else {
                YYNote(String(localized: "点一个人：声音、快慢高低、气泡放左边还是右边。改了从下一段起生效，跟着同步到你的其他设备。"))
            }
        }
        .navigationTitle(String(localized: "人物"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "完成"), action: close)
            }
        }
    }

    private func row(_ m: CastMember) -> some View {
        let role = context.role(m.name)
        let voice = role?.voice.flatMap { Voices.find($0)?.name }
        var detail = ([m.aliases.prefix(2).joined(separator: "、")].filter { !$0.isEmpty } + [String(localized: "\(m.linesSoFar) 句")]).joined(separator: " · ")
        if role?.right == true { detail += " · " + String(localized: "右边") }
        return Button { path.append(.role(m.name)) } label: {
            CastRow(avatar: context.avatar(m.name), color: context.color(m.name), name: m.name, detail: detail,
                    voice: voice ?? String(localized: "跟旁白"), own: voice != nil)
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        let core = core, id = bookID, section = section
        let (c, r) = await Task.detached { ((try? core.bookCast(bookId: id, section: section)) ?? [], (try? core.bookRoles(bookId: id)) ?? []) }.value
        cast = c
        roles = r
        loaded = true
    }
}

/// What the cast pages share.
struct CastContext {
    static let changed = Notification.Name("yuyue.castChanged")

    let core: YuyueCore
    let bookID: String
    let section: UInt32
    let player: Player?
    let language: String
    let cast: [CastMember]
    let roles: [Role]

    func role(_ name: String) -> RoleVoice? { roles.first { $0.name == name }?.voice }

    func set(_ name: String, _ voice: RoleVoice) {
        try? core.setBookRole(bookId: bookID, name: name, voice: voice)
        player?.rolesChanged()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Their circle's character and colour, as core gives them (the bubbles use the same).
    func avatar(_ name: String) -> String {
        cast.first { $0.name == name }?.avatar ?? String(name.last ?? "?")
    }

    func color(_ name: String) -> Color {
        Color(hex: cast.first { $0.name == name }?.color ?? "#888888")
    }

    /// One of their own lines in this chapter, to try voices with; or a few plain words.
    func sample(_ name: String?) -> String {
        guard let name else { return Voices.sampleText(language) }
        if let script = try? core.sectionScript(bookId: bookID, section: section),
           let sentences = try? core.sentences(bookId: bookID, section: section),
           let line = script.lines.first(where: { ($0.who.map { $0 == name || $0.hasSuffix(name) || name.hasSuffix($0) } ?? false) && $0.first == $0.last }),
           sentences.indices.contains(Int(line.first)) {
            let s = Array(sentences[Int(line.first)])
            let a = min(Int(line.start), s.count), b = min(max(Int(line.end), a), s.count)
            let quote = String(s[a ..< b]).trimmingCharacters(in: .whitespaces)
            if quote.count >= 2 { return quote }
        }
        return language.hasPrefix("zh") ? "我是\(name)。" : "I am \(name)."
    }
}

private struct CastRow: View {
    let avatar: String?
    let color: Color
    let name: String
    let detail: String
    let voice: String
    let own: Bool

    var body: some View {
        HStack(spacing: YYUI.s(10)) {
            Group {
                if let avatar {
                    Text(avatar).font(YYUI.font(11.5, .semibold)).foregroundStyle(color)
                } else {
                    Image(systemName: "book").font(YYUI.font(11)).foregroundStyle(YYColor.t3)
                }
            }
            .frame(width: YYUI.s(26), height: YYUI.s(26))
            .background(avatar == nil ? YYColor.inset : color.opacity(0.18), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1)
                Text(detail).font(YYUI.font(10)).foregroundStyle(YYColor.t3).lineLimit(1)
            }
            Spacer(minLength: YYUI.s(8))
            HStack(spacing: 3) {
                Text(voice).font(YYUI.font(10, own ? .semibold : .regular)).foregroundStyle(own ? YYColor.t1 : YYColor.t3)
                Image(systemName: "chevron.right").font(YYUI.font(9, .semibold)).foregroundStyle(YYColor.t3)
            }
        }
        .padding(.vertical, YYUI.s(9))
        .contentShape(.rect)
    }
}

/// R3: one of the cast — voice, which side their bubbles go, pace, pitch — and one of their own
/// lines to try every change on.
private struct RoleView: View {
    let context: CastContext
    let name: String
    @Binding var path: [CastSheet.Route]
    @State private var voice = RoleVoice(voice: nil, rate: 1, pitch: 0, right: false)

    var body: some View {
        YYPage {
            HStack(spacing: YYUI.s(10)) {
                Text(context.avatar(name)).font(YYUI.font(14, .semibold)).foregroundStyle(context.color(name))
                    .frame(width: YYUI.s(34), height: YYUI.s(34)).background(context.color(name).opacity(0.18), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(YYUI.font(14, .semibold))
                    if let m = context.cast.first(where: { $0.name == name }) {
                        Text(([m.aliases.joined(separator: "、")].filter { !$0.isEmpty } + [String(localized: "\(m.linesSoFar) 句")]).joined(separator: " · "))
                            .font(YYUI.font(10)).foregroundStyle(YYColor.t3).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, YYUI.s(12))
            YYGroup {
                Button { path.append(.voice(name)) } label: {
                    YYRow(String(localized: "声音"), icon: "waveform", value: voiceName, chevron: true)
                }
                .buttonStyle(.plain)
                YYRow(title: String(localized: "气泡放在"), icon: "rectangle.split.2x1") {
                    YYSegments(items: [(false, String(localized: "左边")), (true, String(localized: "右边"))], selection: binding(\.right), small: true)
                        .frame(width: YYUI.s(118))
                }
            }
            VStack(spacing: YYUI.s(20)) {
                slider(String(localized: "快慢"), value: "\(String(format: "%.1f", voice.rate))×", note: String(localized: "在全书速度上再快或慢一点"), range: 0.7 ... 1.4, binding: binding(\.rate))
                slider(String(localized: "高低"), value: voice.pitch == 0 ? "0" : String(format: "%+.0f", voice.pitch), note: String(localized: "声音高一点或低一点"), range: -6 ... 6, binding: binding(\.pitch), step: 1)
            }
            .padding(YYUI.s(14))
            .yyCard()
            .padding(.top, YYUI.s(12))
            Button(action: preview) {
                HStack(spacing: YYUI.s(10)) {
                    Image(systemName: "play.fill").font(YYUI.font(10)).frame(width: YYUI.s(28), height: YYUI.s(28)).background(YYColor.inset, in: .circle)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("“\(context.sample(name))”").font(YYUI.font(11.5)).foregroundStyle(YYColor.t1).lineLimit(2)
                        Text("\(name)的一句 · 点一下试听").font(YYUI.font(10)).foregroundStyle(YYColor.t3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, YYUI.s(12)).padding(.vertical, YYUI.s(10))
                .yyCard()
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.top, YYUI.s(12))
            if voice != RoleVoice(voice: nil, rate: 1, pitch: 0, right: false) {
                Button(String(localized: "改回跟旁白")) {
                    voice = RoleVoice(voice: nil, rate: 1, pitch: 0, right: false)
                    context.set(name, voice)
                }
                .buttonStyle(YYButtonStyle(kind: .plain))
                .padding(.top, YYUI.s(12))
            }
        }
        .navigationTitle(name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { voice = context.role(name) ?? RoleVoice(voice: nil, rate: 1, pitch: 0, right: false) }
        .onReceive(NotificationCenter.default.publisher(for: CastContext.changed)) { _ in
            if let v = try? context.core.bookRoles(bookId: context.bookID).first(where: { $0.name == name })?.voice { voice = v }
        }
    }

    private var voiceName: String {
        voice.voice.flatMap { Voices.find($0)?.name } ?? String(localized: "跟旁白")
    }

    private func binding<T>(_ key: WritableKeyPath<RoleVoice, T>) -> Binding<T> {
        Binding(get: { voice[keyPath: key] }, set: { voice[keyPath: key] = $0; context.set(name, voice) })
    }

    private func slider(_ title: String, value: String, note: String, range: ClosedRange<Double>, binding: Binding<Double>, step: Double = 0.05) -> some View {
        VStack(alignment: .leading, spacing: YYUI.s(8)) {
            HStack(alignment: .firstTextBaseline, spacing: YYUI.s(8)) {
                Text("\(title) \(value)").font(YYUI.font(15, .bold)).monospacedDigit()
                Spacer()
                Text(note).font(YYUI.font(10)).foregroundStyle(YYColor.t3)
            }
            Slider(value: binding, in: range, step: step).tint(YYTint.standard.fill)
        }
    }

    private func preview() {
        guard let player = context.player else { return }
        let base = voice.voice.flatMap(Voices.find) ?? player.currentVoice(for: context.language)
        guard let base else { return }
        let v: any Voice = (abs(voice.rate - 1) < 0.01 && voice.pitch == 0) ? base : TunedVoice(base: base, rate: Float(voice.rate), pitch: Float(voice.pitch))
        player.preview(v, text: context.sample(name))
    }
}

/// R4 / C1: choosing a voice for someone (or the narrator). 跟旁白 first, then the voices cloned on
/// this device with 克隆一个声音 at the end, then the rest; every 试听 reads their own line.
private struct VoiceChoiceView: View {
    let context: CastContext
    let name: String?
    @Binding var path: [CastSheet.Route]
    @State private var cloned: [ClonedVoice] = []
    @State private var chosen: String?

    var body: some View {
        YYPage {
            if let name {
                YYGroup {
                    choice(id: nil, title: String(localized: "跟旁白"),
                           detail: String(localized: "现在旁白是\(context.player?.currentVoice(for: context.language)?.name ?? "")，旁白换了\(name)也跟着换"),
                           voice: context.player?.currentVoice(for: context.language))
                }
                .padding(.top, YYUI.s(12))
            }
            YYLabel(String(localized: "我的声音"))
            YYGroup {
                ForEach(cloned, id: \.id) { v in
                    choice(id: v.id, title: v.name, detail: v.isReady ? String(localized: "克隆") : String(localized: "克隆 · 还不能念，先用旁白的"), voice: v)
                }
                Button { path.append(.clone(name)) } label: {
                    HStack(spacing: YYUI.s(10)) {
                        Image(systemName: "mic").font(YYUI.font(12)).frame(width: YYUI.s(28), height: YYUI.s(28)).background(YYColor.inset, in: .circle)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("克隆一个声音").font(YYUI.font(11.5, .semibold))
                            Text("照着念一小段，或者导入一段录音").font(YYUI.font(10)).foregroundStyle(YYColor.t3)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(YYUI.font(9, .semibold)).foregroundStyle(YYColor.t3)
                    }
                    .padding(.vertical, YYUI.s(8))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            YYLabel(String(localized: "声音"))
            YYGroup {
                ForEach(Voices.all(for: context.language), id: \.id) { v in
                    choice(id: v.id, title: Voices.title(v), detail: usedBy(v.id) ?? (v.isOffline ? String(localized: "离线") : String(localized: "云端")), voice: v)
                }
            }
        }
        .navigationTitle(name.map { String(localized: "\($0)的声音") } ?? String(localized: "旁白的声音"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            cloned = ClonedVoices.all()
            chosen = name.map { context.role($0)?.voice } ?? context.player?.currentVoice(for: context.language)?.id
        }
        .onReceive(NotificationCenter.default.publisher(for: ClonedVoices.changed)) { _ in cloned = ClonedVoices.all() }
    }

    /// 宝玉在用: someone else already reads with it.
    private func usedBy(_ id: String) -> String? {
        let who = context.roles.filter { $0.voice.voice == id && $0.name != name }.map(\.name)
        return who.isEmpty ? nil : String(localized: "\(who.joined(separator: "、"))在用")
    }

    private func choice(id: String?, title: String, detail: String, voice: (any Voice)?) -> some View {
        HStack(spacing: YYUI.s(10)) {
            Button {
                if let voice, let player = context.player { player.preview(voice, text: context.sample(name)) }
            } label: {
                Image(systemName: "play.fill").font(YYUI.font(9)).foregroundStyle(YYColor.t1)
                    .frame(width: YYUI.s(28), height: YYUI.s(28)).background(YYColor.inset, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("试听")
            Button { pick(id: id, voice: voice) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1)
                        Text(detail).font(YYUI.font(10)).foregroundStyle(YYColor.t3).lineLimit(1)
                    }
                    Spacer()
                    if chosen == id { Image(systemName: "checkmark").font(YYUI.font(12, .semibold)).foregroundStyle(YYTint.standard.accent) }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, YYUI.s(8))
    }

    private func pick(id: String?, voice: (any Voice)?) {
        chosen = id
        if let name {
            var v = context.role(name) ?? RoleVoice(voice: nil, rate: 1, pitch: 0, right: false)
            v.voice = id
            context.set(name, v)
        } else if let voice {
            context.player?.choose(voice, for: context.language)
            NotificationCenter.default.post(name: CastContext.changed, object: nil)
        }
    }
}

extension Voices {
    /// A few words to try a voice with.
    static func sampleText(_ language: String) -> String {
        language.hasPrefix("zh") ? "你好，这是我的声音。" : "Hello, this is how I sound."
    }
}


/// 人物 on the Mac (B5): a float panel beside the page, the narrator at the top and each of the
/// cast with their voice; a click opens their page.
struct CastPanel: View {
    let model: ReaderModel
    @State private var cast: [CastMember] = []
    @State private var roles: [Role] = []
    @State private var open: CastSheet.Route?

    private var section: UInt32 { model.player?.spot?.section ?? model.section ?? 0 }
    private var language: String { model.player?.language ?? model.detail?.summary.language ?? "zh" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("人物").font(.yy(size: 15, weight: .bold))
                Text("读到这里 · \(cast.count) 人").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
            }
            ScrollView {
                VStack(spacing: 10) {
                    YYGroup {
                        Button { open = .voice(nil) } label: {
                            row(avatar: nil, color: YYColor.t3, name: String(localized: "旁白"), detail: String(localized: "全书默认"),
                                voice: model.player?.currentVoice(for: language)?.name ?? "", own: true)
                        }
                        .buttonStyle(.plain)
                    }
                    YYGroup {
                        ForEach(cast, id: \.name) { m in
                            let id = roles.first { $0.name == m.name }?.voice.voice
                            let name = id.flatMap { Voices.find($0)?.name }
                            Button { open = .role(m.name) } label: {
                                row(avatar: m.avatar, color: Color(hex: m.color), name: m.name,
                                    detail: [m.aliases.prefix(1).joined(), String(localized: "\(m.linesSoFar) 句")].filter { !$0.isEmpty }.joined(separator: " · "),
                                    voice: name ?? String(localized: "跟旁白"), own: name != nil)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(14)
        .task(id: section) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: CastContext.changed)) { _ in Task { await load() } }
        .sheet(item: Binding(get: { open.map(Opened.init) }, set: { open = $0?.route })) { o in
            CastSheet(core: model.core, bookID: model.bookID, section: section, player: model.player, language: language, start: [o.route]) { open = nil }
                .presentationBackground(YYColor.bg)
        }
    }

    private struct Opened: Identifiable {
        let route: CastSheet.Route
        var id: String { "\(route)" }
    }

    private func row(avatar: String?, color: Color, name: String, detail: String, voice: String, own: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if let avatar { Text(avatar).font(.yy(size: 11.5, weight: .semibold)).foregroundStyle(color) } else { Image(systemName: "book").font(.yy(size: 11)).foregroundStyle(YYColor.t3) }
            }
            .frame(width: 26, height: 26)
            .background(avatar == nil ? YYColor.inset : color.opacity(0.18), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.yy(size: 11.5, weight: .semibold)).foregroundStyle(YYColor.t1)
                Text(detail).font(.yy(size: 10)).foregroundStyle(YYColor.t3).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(voice).font(.yy(size: 10, weight: own ? .semibold : .regular)).foregroundStyle(own ? YYColor.t1 : YYColor.t3).lineLimit(1)
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
    }

    private func load() async {
        let core = model.core, id = model.bookID, s = section
        let (c, r) = await Task.detached { ((try? core.bookCast(bookId: id, section: s)) ?? [], (try? core.bookRoles(bookId: id)) ?? []) }.value
        cast = c
        roles = r
    }
}
