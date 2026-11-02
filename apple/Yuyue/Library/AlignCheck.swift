#if os(macOS)
import SwiftUI

/// Which audiobook 对齐检查 opens, and on which sentence (an index into `Timings.sentences`).
struct AlignTarget: Codable, Hashable {
    let audiobook: String
    let at: Int
}

/// 有声书 · Mac 上微调 (A5): a window like the reader's. The chapter's words on the paper with
/// the stretch to look at framed in amber, a timeline floating below that lays the sentences
/// over the recording, and a panel on the right to move them. 空格 试听, ← → 0.1 秒.
struct AlignCheckWindow: View {
    let library: Library
    let target: AlignTarget

    var body: some View {
        if let a = library.audiobooks.all.first(where: { $0.id == target.audiobook }), a.book != nil,
           let t = library.audiobooks.timings(a), t.sentences.indices.contains(target.at) {
            AlignCheck(library: library, audiobook: a, timings: t, at: target.at)
        } else {
            ContentUnavailableView("这本有声书不在了", systemImage: "waveform")
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}

private struct AlignCheck: View {
    let library: Library
    let audiobook: Audiobook
    @State private var timings: Timings
    @State private var at: Int
    /// The stretches to look at, as they were when the window opened, so one fixed stays in
    /// the count; and the one being looked at.
    private let stops: [Issue]
    @State private var stop: Int?
    @State private var texts: [UInt32: [String]] = [:]
    @State private var window: ClosedRange<Double> = 0 ... 11
    @State private var levels: [Float] = []
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private let paper = YYPaper.plain
    private var tint: YYTint { .standard }
    private var books: Audiobooks { library.audiobooks }
    private var sentence: Timings.Sentence { timings.sentences[at] }
    /// Sentences of the stretch being looked at, as indexes into `timings.sentences`.
    private var stretch: ClosedRange<Int>? { stop.map { stops[$0].at ... stops[$0].last } }

    init(library: Library, audiobook: Audiobook, timings: Timings, at: Int) {
        self.library = library
        self.audiobook = audiobook
        _timings = State(initialValue: timings)
        _at = State(initialValue: at)
        let stops = Issue.all(in: timings, introSkipped: true).filter { if case .unsure = $0.kind { true } else { false } }
        self.stops = stops
        _stop = State(initialValue: stops.firstIndex { $0.at <= at && at <= $0.last })
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                page
                timeline
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }
            inspector
                .frame(width: 288)
                .padding([.vertical, .trailing], 14)
        }
        .background(paper.bg)
        .environment(\.colorScheme, .light)
        // `.v-mac-tb`, as in the reading window.
        .trafficLights(CGPoint(x: 24, y: 29))
        .navigationTitle("\(bookTitle) · 对齐检查")
        .navigationSubtitle("第 \(chapter) 章 · \(timings.sections.count - timings.troubled.count) 章对好了\(left > 0 ? String(localized: "，\(left) 处要看一下") : "")")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { stopper }
            ToolbarItem(placement: .primaryAction) {
                Button("完成") { finish() }
                    .buttonStyle(YYButtonStyle(kind: .main, size: .small))
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) { listen(); return .handled }
        .onKeyPress(.leftArrow) { nudgeStart(-0.1); return .handled }
        .onKeyPress(.rightArrow) { nudgeStart(0.1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onAppear { focused = true }
        .onDisappear { books.stopListening() }
        .task(id: at) { await look() }
        .frame(minWidth: 960, minHeight: 640)
    }

    /// Stretches not yet looked at.
    private var left: Int { stops.count { r in (r.at ... r.last).contains { Timings.unsure(timings.sentences[$0]) } } }

    private var bookTitle: String { library.books.first { $0.id == audiobook.book }?.title ?? audiobook.title }
    private func chapterNumber(_ section: UInt32) -> Int { (timings.sections.firstIndex { $0.section == section } ?? 0) + 1 }
    private var chapter: Int { chapterNumber(sentence.section) }

    // MARK: Toolbar

    /// `第 1 / 3 处 ‹ ›`.
    private var stopper: some View {
        HStack(spacing: 2) {
            Text(stops.isEmpty ? String(localized: "没有要看的地方") : String(localized: "第 \(stop.map { "\($0 + 1)" } ?? "–") / \(stops.count) 处"))
                .font(.yy(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(YYColor.t2)
                .padding(.leading, 10)
                .padding(.trailing, 4)
            Button { go(toStop: (stop ?? stops.count) - 1) } label: { Image(systemName: "chevron.left").frame(width: 26, height: 24) }
                .disabled((stop ?? stops.count) <= 0)
                .help("上一处")
            Button { go(toStop: (stop ?? -1) + 1) } label: { Image(systemName: "chevron.right").frame(width: 26, height: 24) }
                .disabled((stop ?? -1) + 1 >= stops.count)
                .help("下一处")
        }
        .buttonStyle(.plain)
        .font(.yy(size: 12, weight: .semibold))
    }

    // MARK: The page

    private var page: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("第 \(chapter) 章")
                        .font(.yy(size: 20, weight: .bold))
                        .foregroundStyle(paper.ink)
                        .padding(.bottom, 14)
                    words
                }
                .frame(width: 460, alignment: .leading)
                .padding(.top, 36)
                .padding(.bottom, 180)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .onChange(of: at, initial: true) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("here", anchor: .center) }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "yuyue-align", let i = Int(url.host() ?? ""), timings.sentences.indices.contains(i) { pick(i) }
            return .handled
        })
    }

    /// The sentences around this one: before the stretch, the stretch in its amber frame (with
    /// a few after it), and on.
    @ViewBuilder private var words: some View {
        let list = texts[sentence.section] ?? []
        let here = Int(sentence.sentence)
        let s = timings.sentences
        // The stretch's part in this chapter: it may run on into the next (notes nobody read, then
        // the next story), and the chapter's text may be shorter than its numbers.
        let box: Range<Int>? = stretch.flatMap { r in
            let inHere = r.filter { s[$0].section == sentence.section }.map { Int(s[$0].sentence) }
            guard let lo = inHere.min(), let hi = inHere.max(), lo < list.count else { return nil }
            return lo ..< min(list.count, hi + 1)
        }
        let focus = box ?? here ..< here + 1
        let from = max(0, focus.lowerBound - 8), to = min(list.count, focus.upperBound + 12)
        if let box, let stretch {
            let fixed = !stretch.contains { Timings.unsure(s[$0]) }
            let tone = fixed ? YYColor.ok : YYColor.warn
            VStack(alignment: .leading, spacing: 22) {
                if from < box.lowerBound { prose(list, from ..< box.lowerBound) }
                ZStack(alignment: .topLeading) {
                    prose(list, box.lowerBound ..< min(list.count, box.upperBound))
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 8)
                        .background(tone.opacity(0.04), in: .rect(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(tone, lineWidth: 1.5) }
                        .padding(.horizontal, -16)
                    Label(fixed ? String(localized: "调过了") : String(localized: "这一段对得不太准"), systemImage: fixed ? "checkmark" : "exclamationmark.triangle")
                        .labelStyle(TightLabel())
                        .font(.yy(size: 10.5, weight: .semibold))
                        .foregroundStyle(tone)
                        .padding(.horizontal, 8)
                        .frame(height: 21)
                        .background(paper.bg, in: .capsule)
                        .overlay { Capsule().strokeBorder(tone, lineWidth: 1.5) }
                        .offset(x: -2, y: -11)
                }
                .id("here")
                if box.upperBound < to { prose(list, box.upperBound ..< to) }
            }
        } else if !list.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if from < here { prose(list, from ..< here) }
                prose(list, here ..< min(list.count, here + 1)).id("here")
                if here + 1 < to { prose(list, here + 1 ..< to) }
            }
        }
    }

    /// `.v-al-sn`: one tint on every other sentence, the current one in the theme's blue; the
    /// rest can be clicked to look at them.
    private func prose(_ list: [String], _ range: Range<Int>) -> some View {
        var text = AttributedString()
        let section = sentence.section
        for k in range where list.indices.contains(k) {
            var part = AttributedString(list[k])
            let i = timings.index(section, k)
            if i == at {
                part.foregroundColor = paper.paperAccent
                part.backgroundColor = paper.paperAccent.opacity(0.13)
                part.font = .yy(size: 15, weight: .semibold)
            } else {
                part.foregroundColor = i.map { timings.sentences[$0].start < 0 } == true ? paper.ink2 : paper.ink
                if k % 2 == 1 { part.backgroundColor = paper.ink.opacity(0.06) }
                if let i { part.link = URL(string: "yuyue-align://\(i)") }
            }
            text += part
        }
        return Text(text)
            .font(.yy(size: 15))
            .tracking(0.3)
            .lineSpacing(15 * 1.05)
            .tint(paper.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The timeline

    /// `.v-al-tl`: the sentences as blocks over the recording, a few seconds either side.
    private var timeline: some View {
        VStack(spacing: 0) {
            GeometryReader { g in
                let w = g.size.width - 44
                let x = { (t: Double) in 44 + CGFloat((t - window.lowerBound) / (window.upperBound - window.lowerBound)) * w }
                ZStack(alignment: .topLeading) {
                    // Ruler, every 2 seconds.
                    ForEach(ticks, id: \.self) { t in
                        Text(Self.clock(t, tenths: false))
                            .font(.yy(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(paper.ink2)
                            .fixedSize()
                            .position(x: x(t), y: 7)
                    }
                    Rectangle().fill(paper.line).frame(width: w, height: 0.5).offset(x: 44, y: 16)
                    Text("句子").font(.yy(size: 10.5)).foregroundStyle(paper.ink2).offset(y: 32)
                    blocks(x: x, width: w)
                        .frame(width: w, height: 26)
                        .mask(Rectangle().padding(.vertical, -6))
                        .offset(x: 44, y: 26)
                    Text("录音").font(.yy(size: 10.5)).foregroundStyle(paper.ink2).offset(y: 73)
                    Canvas { ctx, size in
                        guard !levels.isEmpty else { return }
                        let step = size.width / CGFloat(levels.count)
                        for (k, v) in levels.enumerated() {
                            let h = max(1.5, CGFloat(v) * size.height)
                            let r = CGRect(x: CGFloat(k) * step + step / 2 - 1, y: (size.height - h) / 2, width: 2, height: h)
                            ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(paper.ink2.opacity(0.75)))
                        }
                    }
                    .frame(width: w, height: 46)
                    .offset(x: 44, y: 58)
                    // .v-al-ph: where this sentence begins.
                    let px = x(sentence.start)
                    if px >= 44, px <= 44 + w {
                        Rectangle().fill(paper.paperAccent).frame(width: 1.5, height: 98).offset(x: px - 0.75, y: 6)
                        Text(Self.clock(sentence.start))
                            .font(.yy(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(paper.paperAccent, in: UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4))
                            .fixedSize()
                            .frame(width: 0, alignment: .trailing)
                            .offset(x: px, y: 6)
                    }
                }
            }
        }
        .frame(height: 102)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .yyGlass(RoundedRectangle(cornerRadius: 18), fill: paper.glass, line: paper.line, material: .ultraThinMaterial,
                 shadow: 0.1, radius: 12, y: 8)
    }

    private var ticks: [Double] {
        let first = (window.lowerBound / 2).rounded(.up) * 2
        return Array(stride(from: first, through: window.upperBound - 0.6, by: 2))
    }

    private func blocks(x: @escaping (Double) -> CGFloat, width: CGFloat) -> some View {
        let s = timings.sentences
        let list = texts[sentence.section] ?? []
        let shown = s.indices.filter { s[$0].start >= 0 && s[$0].end > window.lowerBound && s[$0].start < window.upperBound }
        return ZStack(alignment: .topLeading) {
            if let r = stretch, let a = r.first(where: { s[$0].start >= 0 }), let b = r.last(where: { s[$0].start >= 0 }) {
                let left = x(s[a].start) - 44 - 5, right = x(s[b].end) - 44 + 5
                let tone = r.contains { Timings.unsure(s[$0]) } ? YYColor.warn : YYColor.ok
                RoundedRectangle(cornerRadius: 9)
                    .fill(tone.opacity(0.04))
                    .strokeBorder(tone, lineWidth: 1.5)
                    .frame(width: max(0, right - left), height: 34)
                    .offset(x: left, y: -4)
                    .allowsHitTesting(false)
            }
            ForEach(shown, id: \.self) { i in
                let left = x(s[i].start) - 44, right = x(s[i].end) - 44
                let current = i == at
                let words = s[i].section == sentence.section && list.indices.contains(Int(s[i].sentence)) ? list[Int(s[i].sentence)] : ""
                Button { pick(i) } label: {
                    Text(words)
                        .font(YYUI.serif(11, current ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(current ? paper.paperAccent : paper.ink)
                        .padding(.horizontal, 8)
                        .frame(width: max(2, right - left - 1), height: 26, alignment: .leading)
                        .background(current ? paper.paperAccent.opacity(0.13) : paper.ink.opacity(s[i].sentence % 2 == 1 ? 0.08 : 0.04), in: .rect(cornerRadius: 6))
                        .overlay {
                            if current { RoundedRectangle(cornerRadius: 6).strokeBorder(paper.paperAccent, lineWidth: 1.2) }
                        }
                }
                .buttonStyle(.plain)
                .offset(x: left + 1)
            }
        }
        .frame(width: width, height: 26, alignment: .topLeading)
    }

    // MARK: The panel

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("第 \(chapter) 章").font(.yy(size: 14, weight: .bold))
                    Text("\(timings.sections.count) 章 · \(timings.troubled.isEmpty ? String(localized: "都对好了") : String(localized: "\(timings.troubled.count) 章要看一下"))")
                        .font(.yy(size: 10.5))
                        .foregroundStyle(YYColor.t3)
                    Spacer(minLength: 0)
                    chapterMenu
                }
                map
            }
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(YYColor.line).frame(height: 0.5) }
            current
            if let r = stretch { part(r) }
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                HStack(spacing: 3) { Key(label: String(localized: "空格")); Text("试听这句") }
                HStack(spacing: 3) { Key(label: "←"); Key(label: "→"); Text("微调 0.1 秒") }
            }
            .font(.yy(size: 10.5))
            .foregroundStyle(YYColor.t3)
        }
        .foregroundStyle(YYColor.t1)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .yyFloatCard(.rect(cornerRadius: 16), shadow: scheme == .dark ? YYShadow.floatDark : YYShadow.floatLight)
    }

    private var chapterMenu: some View {
        Menu {
            ForEach(timings.sections, id: \.section) { c in
                Button("第 \(chapterNumber(c.section)) 章\(timings.troubled.contains(c.section) ? String(localized: " · 要看一下") : "")") { go(toChapter: c.section) }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.yy(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(YYColor.inset, in: .circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("换一章")
    }

    /// `.v-al-map`: a square for each chapter, amber where something is left to look at.
    private var map: some View {
        let troubled = timings.troubled
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 12), spacing: 4) {
            ForEach(timings.sections, id: \.section) { c in
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(troubled.contains(c.section) ? YYColor.warn : YYColor.ok.opacity(0.32))
                    .frame(height: 9)
                    .overlay {
                        if c.section == sentence.section {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(YYColor.t1, lineWidth: 1).padding(-2.5)
                        }
                    }
                    .contentShape(.rect)
                    .onTapGesture { go(toChapter: c.section) }
                    .help("第 \(chapterNumber(c.section)) 章")
            }
        }
    }

    private var current: some View {
        let list = texts[sentence.section] ?? []
        let words = list.indices.contains(Int(sentence.sentence)) ? list[Int(sentence.sentence)] : ""
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("当前句").font(.yy(size: 12, weight: .semibold))
                Spacer()
                Text("第 \(sentence.sentence + 1) 句").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
            }
            Text(words)
                .font(YYUI.serif(13))
                .lineSpacing(13 * 0.4)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(tint.accentSoft, in: .rect(cornerRadius: 8))
            if sentence.start >= 0 {
                time(String(localized: "开始"), sentence.start) { nudgeStart($0) }
                time(String(localized: "结束"), sentence.end) { nudgeEnd($0) }
                Button { listen() } label: { Label("试听这句", systemImage: "play.fill") }
                    .buttonStyle(YYButtonStyle(kind: .plain, wide: true))
            } else {
                Text("录音里没有这句，用朗读补上了。")
                    .font(.yy(size: 11))
                    .foregroundStyle(YYColor.t2)
            }
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(YYColor.line).frame(height: 0.5) }
    }

    /// `.v-al-tm`: `开始 0:15.7 −0.1 +0.1`.
    private func time(_ label: String, _ t: Double, nudge: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.yy(size: 11)).foregroundStyle(YYColor.t2).frame(width: 30, alignment: .leading)
            Text(Self.clock(t)).font(.yy(size: 12, weight: .semibold, design: .monospaced)).monospacedDigit()
            Spacer(minLength: 0)
            ForEach([-0.1, 0.1], id: \.self) { d in
                Button { nudge(d) } label: {
                    Text(d < 0 ? "−0.1" : "+0.1")
                        .font(.yy(size: 10.5))
                        .monospacedDigit()
                        .frame(minWidth: 40, minHeight: 24)
                        .background(YYColor.inset, in: .rect(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 这一段: the stretch as a whole.
    private func part(_ r: ClosedRange<Int>) -> some View {
        let s = timings.sentences
        let a = s[r.lowerBound].sentence + 1, b = s[r.upperBound].sentence + 1
        let fixed = !r.contains { Timings.unsure(s[$0]) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("这一段").font(.yy(size: 12, weight: .semibold))
                Spacer()
                Text(fixed ? String(localized: "调过了") : String(localized: "只听清一部分"))
                    .font(.yy(size: 10, weight: .medium))
                    .foregroundStyle(fixed ? YYColor.ok : YYColor.warn)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background((fixed ? YYColor.ok : YYColor.warn).opacity(0.12), in: .rect(cornerRadius: 5))
            }
            Text(a == b ? String(localized: "第 \(a) 句。录音里这句只听清一部分，墨线可能跟声音错开。整段一起挪就能对上。")
                : String(localized: "第 \(a)–\(b) 句。录音里这几句只听清一部分，墨线可能跟声音错开。整段一起挪就能对上。"))
                .font(.yy(size: 11))
                .lineSpacing(11 * 0.6)
                .foregroundStyle(YYColor.t2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("整段往前 0.5 秒") { change { $0.shift(r, by: -0.5) } }
                Button("整段往后 0.5 秒") { change { $0.shift(r, by: 0.5) } }
            }
            .buttonStyle(YYButtonStyle(kind: .raised, wide: true))
            Button("用朗读补上这段") { change { $0.readWithVoice(r) } }
                .buttonStyle(YYButtonStyle(kind: .raised, wide: true))
            Text("录音里缺了这段时用，换成听书里选的声音读。")
                .font(.yy(size: 10.5))
                .foregroundStyle(YYColor.t3)
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(YYColor.line).frame(height: 0.5) }
    }

    // MARK: Doing

    private func change(_ edit: (inout Timings) -> Void) {
        var t = timings
        edit(&t)
        guard t != timings else { return }
        timings = t
        books.save(t, for: audiobook)
    }

    private func nudgeStart(_ d: Double) {
        guard sentence.start >= 0 else { return }
        change { $0.moveStart(at, to: sentence.start + d, follow: false) }
    }

    private func nudgeEnd(_ d: Double) {
        guard sentence.start >= 0 else { return }
        change { $0.moveEnd(at, to: sentence.end + d) }
    }

    private func pick(_ i: Int) {
        books.stopListening()
        at = i
        if let k = stops.firstIndex(where: { $0.at <= i && i <= $0.last }) { stop = k } else if let r = stretch, !r.contains(i) { stop = nil }
        focused = true
    }

    private func step(_ d: Int) {
        let j = at + d
        guard timings.sentences.indices.contains(j) else { return }
        pick(j)
    }

    private func go(toStop k: Int) {
        guard stops.indices.contains(k) else { return }
        books.stopListening()
        stop = k
        at = stops[k].at
        focused = true
    }

    private func go(toChapter section: UInt32) {
        if let k = stops.firstIndex(where: { $0.section == section }) { return go(toStop: k) }
        if let i = timings.sentences.firstIndex(where: { $0.section == section && $0.start >= 0 }) ?? timings.sentences.firstIndex(where: { $0.section == section }) {
            pick(i)
        }
    }

    private func listen() {
        guard sentence.start >= 0 else { return }
        books.listen(audiobook, from: sentence.start, to: sentence.end)
    }

    private func finish() {
        books.stopListening()
        dismiss()
    }

    /// The words of the chapter, and the recording around the sentence when it moves out of view.
    private func look() async {
        let s = sentence
        if texts[s.section] == nil, let book = audiobook.book {
            texts[s.section] = (try? library.core.sentences(bookId: book, section: s.section)) ?? []
        }
        guard s.start >= 0 else { return }
        if levels.isEmpty || s.start < window.lowerBound + 1 || s.end > window.upperBound - 1 {
            let from = max(0, s.start - 3)
            window = from ... from + 11
            guard let book = audiobook.book, let r = books.recording(for: book) else { return }
            levels = await Audiobooks.levels(r, from, from + 11, bars: 230)
        }
    }

    /// `0:17.4`, or `0:18` on the ruler.
    static func clock(_ t: Double, tenths: Bool = true) -> String {
        let t = max(0, t)
        let m = Int(t) / 60
        if !tenths { return String(format: "%d:%02d", m, Int(t) % 60) }
        return String(format: "%d:%04.1f", m, t - Double(m * 60))
    }
}

/// `kbd`.
private struct Key: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.yy(size: 10))
            .foregroundStyle(YYColor.t1)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(YYColor.bg, in: .rect(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(YYColor.line, lineWidth: 0.5) }
    }
}
#endif
