import SwiftUI
import YuyueCore
#if os(iOS)
import UIKit
#endif

// MARK: Presenting

extension View {
    /// The 有声书 sheet wherever the shelf is: 配对 when a recording comes in, then 合成中 and
    /// 合成好了 in the same sheet.
    func audiobookSheets(_ library: Library) -> some View { modifier(AudiobookSheets(library: library)) }
}

private struct AudiobookSheets: ViewModifier {
    let library: Library

    struct Shown: Identifiable { let id: String }

    func body(content: Content) -> some View {
        let books = library.audiobooks
        content.sheet(item: Binding(
            get: { (books.pairing?.id ?? books.showing).map(Shown.init) },
            set: { if $0 == nil { books.dismiss() } }
        )) { shown in
            AudiobookSheet(library: library, id: shown.id)
        }
    }
}

private struct AudiobookSheet: View {
    let library: Library
    let id: String

    var body: some View {
        let books = library.audiobooks
        if let a = books.pairing, a.id == id {
            AudiobookPair(library: library, audiobook: a)
        } else if let a = books.all.first(where: { $0.id == id }) {
            AudiobookPage(library: library, audiobook: a)
        }
    }
}

/// Where the work is done: `在这台 Mac 上处理`.
private enum ThisDevice {
    #if os(macOS)
    static let name = "Mac"
    static let icon = "laptopcomputer"
    /// How many times faster than the recording plays it transcribes, roughly.
    static let speed = 40.0
    #else
    @MainActor static var name: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    @MainActor static var icon: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }
    static let speed = 12.0
    #endif
}

/// `.zib`: a round white button.
private struct RoundButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { RoundIcon(icon: icon) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }
}

private struct RoundIcon: View {
    let icon: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: icon)
            .font(YYUI.font(13, .medium))
            .foregroundStyle(YYColor.t1)
            .frame(width: YYUI.s(34), height: YYUI.s(34))
            .background(YYColor.card, in: .circle)
            .overlay(Circle().strokeBorder(scheme == .dark ? Color.white.opacity(0.06) : YYColor.line, lineWidth: 0.5))
            .contentShape(.circle)
    }
}

/// The recording's own cover, or a pair of headphones.
struct AudiobookCover: View {
    let url: URL?
    @State private var image: CGImage?

    var body: some View {
        YYColor.inset
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: "headphones").font(YYUI.font(20, .light)).foregroundStyle(YYColor.t3)
                }
            }
            .task(id: url) { image = await Thumbnail.load(url?.path(percentEncoded: false), maxPixels: 400) }
    }
}

private extension View {
    /// The covers' lifted look: `0 8px 18px rgba(30,28,24,.2)` and a hairline.
    func liftedCover(_ radius: CGFloat) -> some View {
        clipShape(.rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            .shadow(color: Color(yy: YYRGBA(30, 28, 24, 0.2)), radius: YYUI.s(9), y: YYUI.s(8))
    }
}

/// A button that is only its words.
private struct TextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(YYUI.font(11.5, .medium))
            .foregroundStyle(YYColor.t2)
            .padding(.horizontal, YYUI.s(6))
            .frame(height: YYUI.s(32))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(.rect)
    }
}

/// `约 25 分钟`, `约 1 小时 40 分`.
private func about(_ seconds: Double) -> String { String(localized: "约 ") + Audiobook.length(seconds) }

/// `1:12:40`, `4:59`.
private func clock(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: 找到配对

/// The recording and the e-book side by side, where it'll be made, and 开始合成.
private struct AudiobookPair: View {
    let library: Library
    let audiobook: Audiobook
    @State private var chosen: BookSummary?
    @State private var picking = false
    @State private var autoPair = UserDefaults.standard.object(forKey: Audiobooks.autoPairKey) as? Bool ?? true
    @State private var height: CGFloat = 520

    var body: some View {
        VStack(spacing: YYUI.s(14)) {
            duo
            headline
            if chosen != nil {
                VStack(alignment: .leading, spacing: 0) {
                    Text("在哪里处理")
                        .font(YYUI.font(10))
                        .foregroundStyle(YYColor.t3)
                        .padding(.horizontal, YYUI.s(4))
                        .padding(.bottom, YYUI.s(6))
                    places
                }
                YYGroup {
                    YYRow(title: String(localized: "以后同名的书都这样配")) { YYSwitch(isOn: $autoPair, label: String(localized: "以后同名的书都这样配")) }
                }
                VStack(spacing: YYUI.s(4)) {
                    Button("开始合成", action: start)
                        .buttonStyle(YYButtonStyle(kind: .main, size: .large, wide: true))
                        .keyboardShortcut(.defaultAction)
                    Button("换一本电子书") { picking = true }
                        .buttonStyle(TextButtonStyle())
                }
            } else {
                VStack(spacing: YYUI.s(4)) {
                    Button("从书架上选一本") { picking = true }
                        .buttonStyle(YYButtonStyle(kind: .main, size: .large, wide: true))
                    Button("不导入了") { library.audiobooks.dismiss() }
                        .buttonStyle(TextButtonStyle())
                }
            }
        }
        .padding(.horizontal, YYUI.s(14))
        .padding(.top, YYUI.s(22))
        .padding(.bottom, YYUI.s(20))
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
        .background(YYColor.bg)
        .onAppear { chosen = library.audiobooks.match(audiobook, in: library.books) }
        .sheet(isPresented: $picking) {
            AudiobookBookPicker(library: library, chosen: chosen?.id) { book in
                chosen = book
                library.audiobooks.remember(audiobook, book)
            }
        }
        #if os(macOS)
        .frame(width: 380)
        #else
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
        .presentationBackground(YYColor.bg)
        #endif
    }

    private var duo: some View {
        HStack(alignment: .top, spacing: YYUI.s(16)) {
            VStack(spacing: YYUI.s(7)) {
                AudiobookCover(url: library.audiobooks.coverURL(audiobook))
                    .frame(width: YYUI.s(78), height: YYUI.s(78))
                    .liftedCover(YYUI.s(6))
                caption(String(localized: "有声书 · \(Audiobook.length(audiobook.total))"))
            }
            Image(systemName: "link")
                .font(YYUI.font(12, .medium))
                .foregroundStyle(YYColor.t2)
                .frame(width: YYUI.s(28), height: YYUI.s(28))
                .background(YYColor.card, in: .circle)
                .overlay(Circle().strokeBorder(YYColor.line, lineWidth: 0.5))
                .padding(.top, YYUI.s(25))
            VStack(spacing: YYUI.s(7)) {
                Group {
                    if let chosen {
                        BookCover(book: chosen).shadow(color: .clear, radius: 0)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(YYColor.t3, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .overlay { Image(systemName: "questionmark").font(YYUI.font(14)).foregroundStyle(YYColor.t3) }
                    }
                }
                .frame(width: YYUI.s(52), height: YYUI.s(78))
                .liftedCover(4)
                caption(chosen.map { String(localized: "电子书 · \(format($0))") } ?? String(localized: "电子书 · 还没有"))
            }
        }
        .padding(.top, YYUI.s(6))
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(YYUI.font(10)).foregroundStyle(YYColor.t3).lineLimit(1).fixedSize()
    }

    private func format(_ book: BookSummary) -> String {
        switch book.format {
        case .epub: "EPUB"
        case .txt: "TXT"
        case .mobi: "Kindle"
        case .pdf: "PDF"
        case .audio: String(localized: "有声书")
        case .podcast: String(localized: "播客")
        }
    }

    private var headline: some View {
        VStack(spacing: YYUI.s(5)) {
            Text(chosen.map { String(localized: "书架上有同一本《\($0.title)》") } ?? String(localized: "书架上没找到《\(audiobook.title)》"))
                .font(YYUI.font(15, .bold))
                .foregroundStyle(YYColor.t1)
            Text(chosen == nil
                 ? String(localized: "有声书要配上同一本电子书才能听：听到哪句，书页上就走到哪句。先导入电子书再来，或者从书架上选一本。")
                 : String(localized: "合成一本听读书：听到哪句，书页上就走到哪句，点一句就从那句听。全部在你的设备上做，不上传。"))
                .font(YYUI.font(10.5))
                .lineSpacing(YYUI.s(10.5) * 0.65)
                .foregroundStyle(YYColor.t2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, YYUI.s(8))
    }

    /// Only this device can do it — the recording stays where it was brought in —
    /// so on a phone the Mac card says how to use it instead of being picked.
    @ViewBuilder private var places: some View {
        #if os(macOS)
        place(icon: ThisDevice.icon, title: String(localized: "这台 Mac"), recommended: true, value: about(audiobook.total / ThisDevice.speed), note: String(localized: "可以去做别的，好了会通知你"), noteIcon: nil, on: true)
        #else
        HStack(alignment: .top, spacing: YYUI.s(8)) {
            place(icon: "laptopcomputer", title: String(localized: "Mac 上"), recommended: true, value: about(audiobook.total / 40), note: String(localized: "把录音拖进 Mac 上的语阅"), noteIcon: nil, on: false)
            place(icon: ThisDevice.icon, title: String(localized: "这台 \(ThisDevice.name)"), recommended: false, value: about(audiobook.total / ThisDevice.speed), note: String(localized: "要接上电源"), noteIcon: "battery.100percent.bolt", on: true)
        }
        #endif
    }

    private func place(icon: String, title: String, recommended: Bool, value: String, note: String, noteIcon: String?, on: Bool) -> some View {
        VStack(alignment: .leading, spacing: YYUI.s(2)) {
            Image(systemName: icon)
                .font(YYUI.font(13))
                .foregroundStyle(YYColor.t1)
                .frame(width: YYUI.s(28), height: YYUI.s(28))
                .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(8)))
                .padding(.bottom, YYUI.s(8))
            HStack(spacing: YYUI.s(5)) {
                Text(title).font(YYUI.font(12, .semibold)).foregroundStyle(YYColor.t1)
                if recommended { YYTag(text: String(localized: "推荐")) }
            }
            .lineLimit(1)
            Text(value).font(YYUI.font(11).monospacedDigit()).foregroundStyle(YYColor.t1)
            HStack(spacing: YYUI.s(3)) {
                if let noteIcon { Image(systemName: noteIcon) }
                Text(note).lineLimit(1).minimumScaleFactor(0.85)
            }
            .font(YYUI.font(10))
            .foregroundStyle(YYColor.t3)
        }
        .padding(.horizontal, YYUI.s(12))
        .padding(.top, YYUI.s(11))
        .padding(.bottom, YYUI.s(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YYColor.card, in: .rect(cornerRadius: YYUI.s(14)))
        .overlay(alignment: .topTrailing) {
            if on {
                Image(systemName: "checkmark.circle.fill")
                    .font(YYUI.font(16))
                    .foregroundStyle(YYTint.standard.accent)
                    .padding(.top, YYUI.s(10))
                    .padding(.trailing, YYUI.s(10))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: YYUI.s(14)).strokeBorder(on ? YYColor.t1 : YYColor.line, lineWidth: on ? 1.5 : 0.5))
        .opacity(on ? 1 : 0.7)
    }

    private func start() {
        guard let chosen else { return }
        UserDefaults.standard.set(autoPair, forKey: Audiobooks.autoPairKey)
        library.audiobooks.make(audiobook, with: chosen)
    }
}

/// 换一本电子书: the shelf's books, the chosen one ticked.
private struct AudiobookBookPicker: View {
    let library: Library
    let chosen: String?
    let pick: (BookSummary) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var books: [BookSummary] {
        let all = library.books.filter { $0.available && $0.format != .pdf }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.authors.contains { $0.localizedCaseInsensitiveContains(q) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: YYUI.s(12)) {
            YYSheetHeader(title: String(localized: "选一本电子书"), subtitle: String(localized: "听的时候书页跟着走")) { dismiss() }
            HStack(spacing: YYUI.s(6)) {
                Image(systemName: "magnifyingglass").foregroundStyle(YYColor.t3)
                TextField("书名或作者", text: $query).textFieldStyle(.plain)
            }
            .font(YYUI.font(12))
            .padding(.horizontal, YYUI.s(10))
            .frame(height: YYUI.s(34))
            .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(10)))
            ScrollView {
                YYGroup {
                    ForEach(books, id: \.id) { book in
                        Button {
                            pick(book)
                            dismiss()
                        } label: {
                            HStack(spacing: YYUI.s(10)) {
                                BookCover(book: book).frame(width: YYUI.s(24))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(book.title).font(YYUI.font(11.5, .medium)).foregroundStyle(YYColor.t1)
                                    if !book.authors.isEmpty {
                                        Text(book.authors.joined(separator: "、")).font(YYUI.font(10)).foregroundStyle(YYColor.t3)
                                    }
                                }
                                .lineLimit(1)
                                Spacer(minLength: 8)
                                if book.id == chosen {
                                    Image(systemName: "checkmark").font(YYUI.font(12, .semibold)).foregroundStyle(YYTint.standard.accent)
                                }
                            }
                            .padding(.vertical, YYUI.s(7))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, YYUI.s(14))
        .padding(.top, YYUI.s(16))
        .background(YYColor.bg)
        #if os(macOS)
        .frame(width: 360, height: 460)
        #else
        .presentationDetents([.medium, .large])
        .presentationBackground(YYColor.bg)
        #endif
    }
}

// MARK: 合成中 · 合成好了

/// What the 合成中 page shows, from the job running or from what was saved when it stopped.
private struct Making {
    var fraction: Double
    var step: Job.Step
    var heard: Double
    var transcribed: Double?
    var downloaded: Double?
    var left: Double?
    var problem: String?
    var running: Bool
}

private struct AudiobookPage: View {
    let library: Library
    let audiobook: Audiobook
    @State private var timings: Timings?
    @State private var adjusting: Adjusting?
    @State private var spin = false
    @Environment(\.colorScheme) private var scheme
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    struct Adjusting: Identifiable { let id: Int }

    private var books: Audiobooks { library.audiobooks }
    private var job: Job? { books.job?.audiobook == audiobook.id ? books.job : nil }
    private var book: BookSummary? { library.books.first { $0.id == audiobook.book } }
    private var tint: YYTint { .standard }

    var body: some View {
        Group {
            if job == nil, audiobook.made != nil, let timings {
                result(timings)
            } else {
                making(progress)
            }
        }
        .background(YYColor.bg)
        .task(id: audiobook.made) { timings = books.timings(audiobook) }
        .onChange(of: job?.timings) { _, t in if let t { timings = t } }
        .onReceive(NotificationCenter.default.publisher(for: Audiobooks.timingsChanged)) { n in
            if n.object as? String == audiobook.id { timings = books.timings(audiobook) }
        }
        .sheet(item: $adjusting) { a in
            if let timings {
                TimingAdjust(library: library, audiobook: audiobook, timings: timings, at: a.id) { t in
                    books.save(t, for: audiobook)
                    self.timings = t
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 640)
        #else
        .presentationDetents([.large])
        .presentationBackground(YYColor.bg)
        #endif
    }

    private var progress: Making {
        if let job {
            return Making(fraction: job.step == .done ? 1 : job.step == .checking ? 0.99 : job.fraction, step: job.step, heard: job.heard,
                          transcribed: job.transcribed, downloaded: job.downloaded, left: job.left, problem: job.problem, running: job.problem == nil)
        }
        let through = timings?.through ?? 0
        return Making(fraction: audiobook.total > 0 ? min(1, through / audiobook.total) : 0, step: .transcribing, heard: through,
                      transcribed: nil, downloaded: nil, left: nil, problem: nil, running: false)
    }

    // MARK: Chapters

    enum Chapter { case done, check, now, todo }

    /// Each chapter as far as it's got: laid out once the recording is heard past it.
    private func chapters(_ t: Timings?, finished: Bool) -> [Chapter] {
        guard let t else { return Array(repeating: .todo, count: max(job?.sections ?? 0, 0)) }
        var heard = Set<UInt32>()
        for s in t.sentences where s.start >= 0 { heard.insert(s.section) }
        var later = false
        var past = Array(repeating: false, count: t.sections.count)
        for k in t.sections.indices.reversed() {
            past[k] = later
            if heard.contains(t.sections[k].section) { later = true }
        }
        let troubled = t.troubled
        var out: [Chapter] = []
        var now = false
        for (k, section) in t.sections.enumerated() {
            if finished || past[k] {
                let intro = k == 0 && t.intro > 15 && !audiobook.introSkipped
                out.append(troubled.contains(section.section) || intro ? .check : .done)
            } else if !now {
                now = true
                out.append(.now)
            } else {
                out.append(.todo)
            }
        }
        return out
    }

    // MARK: 合成中

    private func making(_ p: Making) -> some View {
        let states = chapters(timings, finished: p.step == .done)
        let ready = states.count { $0 == .done || $0 == .check }
        return VStack(spacing: 0) {
            nav(icon: "chevron.left", title: nil, subtitle: nil, running: p.running)
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(Int(p.fraction * 100))").font(YYUI.font(58, .bold)).kerning(-1)
                            Text("%").font(YYUI.font(20, .semibold)).foregroundStyle(YYColor.t2)
                        }
                        .monospacedDigit()
                        .foregroundStyle(YYColor.t1)
                        Text(subline(p))
                            .font(YYUI.font(11))
                            .foregroundStyle(p.problem == nil ? YYColor.t2 : YYColor.warn)
                            .multilineTextAlignment(.center)
                            .padding(.top, YYUI.s(9))
                        Capsule().fill(YYColor.inset)
                            .frame(height: 3)
                            .overlay(alignment: .leading) {
                                GeometryReader { g in Capsule().fill(tint.fill).frame(width: g.size.width * p.fraction) }
                            }
                            .padding(.top, YYUI.s(16))
                    }
                    .padding(.horizontal, YYUI.s(26))
                    .padding(.top, YYUI.s(30))
                    .padding(.bottom, YYUI.s(22))
                    VStack(alignment: .leading, spacing: 0) {
                        YYGroup {
                            step(String(localized: "读取章节"), p.downloaded.map { String(localized: "下载对齐模型 \(Int($0 * 100))%") } ?? String(localized: "\(states.count) 章 · \(Audiobook.length(audiobook.total))"), p.step.rawValue > Job.Step.reading.rawValue ? .done : .now)
                            step(String(localized: "找出每集念的是哪一段"), transcribeValue(p), p.step.rawValue > Job.Step.transcribing.rawValue && p.heard >= audiobook.total - 1 ? .done : p.step.rawValue >= Job.Step.transcribing.rawValue && p.step != .done && p.step != .checking ? .now : p.step.rawValue > Job.Step.transcribing.rawValue ? .done : .todo)
                            step(String(localized: "逐句对齐"), p.step == .done || p.step == .checking ? String(localized: "\(states.count) 章") : ready > 0 ? String(localized: "第 \(min(ready + 1, states.count)) / \(states.count) 章") : String(localized: "一集一集来"),
                                 p.step.rawValue >= Job.Step.checking.rawValue ? .done : ready > 0 ? .now : .todo)
                            step(String(localized: "检查"), String(localized: "最后一步"), p.step == .done ? .done : p.step == .checking ? .now : .todo)
                        }
                        YYLabel(String(localized: "\(states.count) 章"), String(localized: "\(ready) 章已经能听"))
                        grid(states)
                        if let problem = p.problem {
                            HStack(alignment: .top, spacing: YYUI.s(7)) {
                                Circle().fill(YYColor.warn).frame(width: 6, height: 6).padding(.top, YYUI.s(5))
                                Text(problem).font(YYUI.font(11)).foregroundStyle(YYColor.t1).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(YYUI.s(12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .yyCard()
                            .padding(.top, YYUI.s(12))
                        }
                        YYNote(note)
                    }
                    .padding(.horizontal, YYUI.s(16))
                }
                .padding(.bottom, YYUI.s(100))
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .overlay(alignment: .bottom) {
            if p.running {
                foot(ready == 0 ? String(localized: "对好一章就能先听") : String(localized: "先听对好的 \(ready) 章"), icon: "headphones", action: listen)
                    .disabled(ready == 0)
            } else {
                foot(p.problem == nil ? String(localized: "接着合成") : String(localized: "再试一次"), icon: "arrow.clockwise", action: resume)
                    .disabled(book == nil)
            }
        }
    }

    private func subline(_ p: Making) -> String {
        let place = String(localized: "在这台 \(ThisDevice.name) 上处理")
        if p.problem != nil { return String(localized: "停下了 · ") + place }
        if !p.running { return String(localized: "停下了，做好的部分都留着 · ") + place }
        if p.step == .checking { return String(localized: "就快好了 · ") + place }
        guard let left = p.left else { return String(localized: "正在估算还要多久 · ") + place }
        return (left < 60 ? String(localized: "还要不到 1 分钟") : String(localized: "还要约 \(Int(left / 60) + 1) 分钟")) + " · " + place
    }

    private func transcribeValue(_ p: Making) -> String {
        if p.step.rawValue > Job.Step.transcribing.rawValue, let took = p.transcribed {
            return took < 60 ? String(localized: "用了不到 1 分钟") : String(localized: "用了 \(Int(took / 60)) 分钟")
        }
        return "\(clock(p.heard)) / \(clock(audiobook.total))"
    }

    private var note: String {
        #if os(macOS)
        String(localized: "可以离开这一页，也可以去做别的，好了会通知你。")
        #else
        String(localized: "可以离开这一页，好了会通知你。离开语阅一会儿后会先停下，回来接着做。")
        #endif
    }

    private func step(_ name: String, _ value: String, _ state: Chapter) -> some View {
        HStack(spacing: YYUI.s(10)) {
            stepMark(state)
            Text(name).font(YYUI.font(11.5, state == .now ? .semibold : .regular))
                .foregroundStyle(state == .todo ? YYColor.t3 : YYColor.t1)
            Spacer(minLength: 8)
            Text(value).font(YYUI.font(10.5, state == .now ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(state == .now ? tint.accent : YYColor.t3)
                .lineLimit(1)
        }
        .frame(height: YYUI.s(38))
    }

    /// ✓ done, a turning arc for now, an empty ring to come.
    @ViewBuilder private func stepMark(_ state: Chapter) -> some View {
        let size = YYUI.s(18)
        switch state {
        case .done, .check:
            Image(systemName: "checkmark")
                .font(.yy(size: YYUI.s(9), weight: .bold))
                .foregroundStyle(tint.onBlack)
                .frame(width: size, height: size)
                .background(tint.fill, in: .circle)
        case .now:
            Circle().strokeBorder(tint.accentSoft, lineWidth: 2)
                .overlay {
                    Circle().trim(from: 0, to: 0.25).stroke(tint.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .padding(1)
                        .rotationEffect(.degrees(spin ? 380 : 20))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                }
                .frame(width: size, height: size)
                .onAppear { spin = true }
        case .todo:
            Circle().strokeBorder(YYColor.tint, lineWidth: 1.2).frame(width: size, height: size)
        }
    }

    /// A square for each chapter, and what the colours mean.
    private func grid(_ states: [Chapter]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: YYUI.s(4)), count: 12), spacing: YYUI.s(5)) {
                ForEach(Array(states.enumerated()), id: \.offset) { i, state in
                    Text("\(i + 1)")
                        .font(YYUI.font(9.5, state == .check || state == .now ? .semibold : .regular).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(cellText(state))
                        .frame(maxWidth: .infinity)
                        .frame(height: YYUI.s(22))
                        .background(cellFill(state), in: .rect(cornerRadius: YYUI.s(5)))
                        .overlay {
                            if state == .now { RoundedRectangle(cornerRadius: YYUI.s(5)).strokeBorder(tint.accent, lineWidth: 1.5) }
                        }
                }
            }
            HStack(spacing: YYUI.s(12)) {
                legend(.done, String(localized: "对好了"))
                legend(.check, String(localized: "要看一下"))
                legend(.now, String(localized: "正在对"))
                legend(.todo, String(localized: "还没到"))
            }
            .padding(.top, YYUI.s(10))
        }
        .padding(.horizontal, YYUI.s(12))
        .padding(.top, YYUI.s(13))
        .padding(.bottom, YYUI.s(12))
        .yyCard()
    }

    private func cellFill(_ state: Chapter) -> Color {
        switch state {
        case .done: tint.fill
        case .check: YYColor.warn
        case .now: tint.accentSoft
        case .todo: YYColor.inset
        }
    }

    private func cellText(_ state: Chapter) -> Color {
        switch state {
        case .done: tint.onBlack
        case .check: .white
        case .now: tint.accent
        case .todo: YYColor.t3
        }
    }

    private func legend(_ state: Chapter, _ text: String) -> some View {
        HStack(spacing: YYUI.s(4)) {
            RoundedRectangle(cornerRadius: 2).fill(cellFill(state))
                .overlay { if state == .now { RoundedRectangle(cornerRadius: 2).strokeBorder(tint.accent, lineWidth: 1.2) } }
                .frame(width: YYUI.s(8), height: YYUI.s(8))
            Text(text)
        }
        .font(YYUI.font(10))
        .foregroundStyle(YYColor.t2)
        .fixedSize()
    }

    // MARK: 合成好了

    private func result(_ t: Timings) -> some View {
        let issues = Issue.all(in: t, introSkipped: audiobook.introSkipped)
        let good = t.sections.count - t.troubled.count
        let took = audiobook.took.map { $0 < 60 ? String(localized: "用了不到 1 分钟") : String(localized: "用了 \(Int($0 / 60)) 分钟") }
        return VStack(spacing: 0) {
            nav(icon: "xmark", title: String(localized: "合成好了"), subtitle: [book?.title ?? audiobook.title, took].compactMap(\.self).joined(separator: " · "), running: false)
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ZStack(alignment: .bottomTrailing) {
                            Group {
                                if let book { BookCover(book: book).shadow(color: .clear, radius: 0) } else { AudiobookCover(url: books.coverURL(audiobook)) }
                            }
                            .frame(width: YYUI.s(58), height: YYUI.s(87))
                            .liftedCover(4)
                            Image(systemName: "headphones")
                                .font(.yy(size: YYUI.s(11), weight: .semibold))
                                .foregroundStyle(tint.onBlack)
                                .frame(width: YYUI.s(24), height: YYUI.s(24))
                                .background(tint.black, in: .circle)
                                .overlay(Circle().stroke(YYColor.bg, lineWidth: 2.5))
                                .offset(x: YYUI.s(8), y: YYUI.s(6))
                        }
                        Text(issues.isEmpty ? String(localized: "\(t.sections.count) 章都对好了") : String(localized: "\(good) 章对得很好\n\(issues.count) 处要你看一下"))
                            .font(YYUI.font(17, .bold))
                            .lineSpacing(YYUI.s(17) * 0.45)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(YYColor.t1)
                            .padding(.top, YYUI.s(16))
                        if issues.isEmpty {
                            Text("听到哪句，书页上就走到哪句。")
                                .font(YYUI.font(11)).foregroundStyle(YYColor.t2).padding(.top, YYUI.s(6))
                        }
                    }
                    .padding(.horizontal, YYUI.s(20))
                    .padding(.top, YYUI.s(12))
                    .padding(.bottom, YYUI.s(16))
                    VStack(spacing: YYUI.s(8)) {
                        ForEach(issues) { issue in card(issue, t) }
                    }
                    .padding(.horizontal, YYUI.s(16))
                    .animation(.snappy, value: issues)
                }
                .padding(.bottom, YYUI.s(100))
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .overlay(alignment: .bottom) {
            foot(String(localized: "开始听"), icon: "headphones", action: listen).disabled(book == nil)
        }
    }

    private func chapterNumber(_ section: UInt32, _ t: Timings) -> Int {
        (t.sections.firstIndex { $0.section == section } ?? 0) + 1
    }

    /// Where, why, and what can be done.
    private func card(_ issue: Issue, _ t: Timings) -> some View {
        let chapter = chapterNumber(issue.section, t)
        let s = t.sentences[issue.at]
        let (dot, title, place, why): (Color, String, String, String) = switch issue.kind {
        case .intro(let d):
            (YYColor.warn, d < 60 ? String(localized: "片头多出 \(Int(d)) 秒") : String(localized: "片头多出 \(Int(d / 60)) 分钟"), String(localized: "第 1 章开头"), String(localized: "录音开头是出品方的介绍，书里没有。听的时候从正文开始。"))
        case .missing(let n):
            (YYColor.ok, String(localized: "电子书这段，录音里没有"), String(localized: "第 \(chapter) 章 · \(n) 句"), String(localized: "朗读的人跳过了这几句，这里改用朗读声音补上。"))
        case .unsure(let n):
            (YYColor.warn, String(localized: "这一段没听清，可能对得不准"), String(localized: "第 \(chapter) 章 · 第 \(s.sentence + 1) 句起"), String(localized: "这 \(n) 句的墨线可能和声音对不上，听一下，不准就微调。"))
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: YYUI.s(7)) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(title).font(YYUI.font(12, .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                Spacer(minLength: 6)
                Text(place).font(YYUI.font(10)).foregroundStyle(YYColor.t3).lineLimit(1)
            }
            Text(why)
                .font(YYUI.font(10.5))
                .lineSpacing(YYUI.s(10.5) * 0.6)
                .foregroundStyle(YYColor.t2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, YYUI.s(3))
                .padding(.leading, YYUI.s(13))
            HStack(spacing: YYUI.s(6)) {
                switch issue.kind {
                case .intro(let d):
                    listenButton { books.listen(audiobook, from: 0, to: min(d, 30)) }
                    Spacer(minLength: 0)
                    Button("跳过这段") { withAnimation(.snappy) { books.skipIntro(audiobook) } }
                        .buttonStyle(YYButtonStyle(kind: .raised, size: .small))
                case .missing:
                    Spacer(minLength: 0)
                    Label("已用朗读补上", systemImage: "checkmark")
                        .font(YYUI.font(10.5, .semibold))
                        .foregroundStyle(YYColor.ok)
                        .padding(.horizontal, YYUI.s(10))
                        .frame(height: YYUI.s(26))
                        .background(YYColor.inset, in: .capsule)
                case .unsure(let n):
                    listenButton {
                        let last = t.sentences[min(t.sentences.count - 1, issue.at + max(0, n - 1))]
                        books.listen(audiobook, from: s.start, to: min(max(last.end, s.start + 3), s.start + 15))
                    }
                    Spacer(minLength: 0)
                    Button("微调") {
                        #if os(macOS)
                        openWindow(id: "align", value: AlignTarget(audiobook: audiobook.id, at: issue.at))
                        #else
                        adjusting = Adjusting(id: issue.at)
                        #endif
                    }
                        .buttonStyle(YYButtonStyle(kind: .raised, size: .small))
                }
            }
            .padding(.top, YYUI.s(8))
            .padding(.leading, YYUI.s(13))
        }
        .padding(.horizontal, YYUI.s(12))
        .padding(.top, YYUI.s(11))
        .padding(.bottom, YYUI.s(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .yyCard()
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func listenButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label("试听", systemImage: "play.fill").labelStyle(Tight()) }
            .buttonStyle(YYButtonStyle(kind: .plain, size: .small))
    }

    private struct Tight: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: YYUI.s(5)) { configuration.icon.imageScale(.small); configuration.title }
        }
    }

    // MARK: Both

    /// Back on the left, the title in the middle, and what else can be done on the right.
    private func nav(icon: String, title: String?, subtitle: String?, running: Bool) -> some View {
        HStack(spacing: YYUI.s(10)) {
            RoundButton(icon: icon, label: String(localized: "收起")) { books.dismiss() }
                .keyboardShortcut(.cancelAction)
            VStack(spacing: 0) {
                if let title { Text(title).font(YYUI.font(13, .semibold)).foregroundStyle(YYColor.t1) }
                if let subtitle { Text(subtitle).font(YYUI.font(10)).foregroundStyle(YYColor.t3) }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            Menu {
                if running {
                    Button("停下合成", systemImage: "pause") { books.cancel() }
                } else if audiobook.made != nil, book != nil {
                    Button("重新合成", systemImage: "arrow.clockwise", action: resume)
                }
                Button("删掉这本有声书", systemImage: "trash", role: .destructive) {
                    books.remove(audiobook)
                    books.dismiss()
                }
            } label: {
                RoundIcon(icon: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("更多")
        }
        .padding(.horizontal, YYUI.s(14))
        .padding(.top, YYUI.s(14))
        .frame(minHeight: YYUI.s(40))
    }

    /// The big button over a fade at the bottom.
    private func foot(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: YYUI.s(5)) {
                Image(systemName: icon)
                Text(title)
            }
        }
        .buttonStyle(YYButtonStyle(kind: .main, size: .large, wide: true))
        .padding(.horizontal, YYUI.s(16))
        .padding(.bottom, YYUI.s(22))
        .background(alignment: .bottom) {
            LinearGradient(stops: [.init(color: YYColor.bg.opacity(0), location: 0), .init(color: YYColor.bg, location: 0.52)], startPoint: .top, endPoint: .bottom)
                .frame(height: YYUI.s(104))
                .allowsHitTesting(false)
        }
    }

    private func listen() {
        guard let book else { return }
        books.dismiss()
        library.open(book, .listen)
        #if os(macOS)
        openWindow(id: "reader", value: book.id)
        #endif
    }

    private func resume() {
        guard let book else { return }
        books.make(audiobook, with: book)
    }
}

// MARK: 微调

/// One sentence's start against the sound around it — drag the handle to where it
/// begins, ±0.1 秒, 试听这句; with 跟着挪 the rest of the chapter moves with it.
struct TimingAdjust: View {
    let library: Library
    let audiobook: Audiobook
    @State var timings: Timings
    @State var at: Int
    let done: (Timings) -> Void
    @State private var follow = true
    @State private var window: ClosedRange<Double> = 0 ... 6
    @State private var levels: [Float] = []
    @State private var texts: [UInt32: [String]] = [:]
    /// Where each touched sentence began before, for the dashed line.
    @State private var before: [Int: Double] = [:]
    @State private var height: CGFloat = 560
    @Environment(\.dismiss) private var dismiss

    private var books: Audiobooks { library.audiobooks }
    private var tint: YYTint { .standard }
    private var sentence: Timings.Sentence { timings.sentences[at] }

    init(library: Library, audiobook: Audiobook, timings: Timings, at: Int, done: @escaping (Timings) -> Void) {
        self.library = library
        self.audiobook = audiobook
        _timings = State(initialValue: timings)
        _at = State(initialValue: at)
        self.done = done
    }

    var body: some View {
        VStack(spacing: YYUI.s(11)) {
            YYSheetHeader(title: String(localized: "微调"), subtitle: String(localized: "第 \(chapter) 章 · 第 \(sentence.sentence + 1) 句")) { finish() }
            words
            wave
            nudges
            YYGroup {
                YYRow(title: String(localized: "这一段后面的句子跟着挪")) { YYSwitch(isOn: $follow, label: String(localized: "这一段后面的句子跟着挪")) }
            }
            HStack(spacing: YYUI.s(8)) {
                Button { go(-1) } label: { Image(systemName: "chevron.left").frame(maxWidth: .infinity) }
                    .buttonStyle(YYButtonStyle(kind: .plain, wide: true))
                    .disabled(neighbour(-1) == nil)
                    .accessibilityLabel("上一句")
                Button { go(1) } label: { Image(systemName: "chevron.right").frame(maxWidth: .infinity) }
                    .buttonStyle(YYButtonStyle(kind: .plain, wide: true))
                    .disabled(neighbour(1) == nil)
                    .accessibilityLabel("下一句")
                Button("完成", action: finish)
                    .buttonStyle(YYButtonStyle(kind: .main, wide: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, YYUI.s(14))
        .padding(.top, YYUI.s(18))
        .padding(.bottom, YYUI.s(20))
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
        .background(YYColor.bg)
        .task(id: at) { await look() }
        .onDisappear { books.stopListening() }
        #if os(macOS)
        .frame(width: 440)
        #else
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
        .presentationBackground(YYColor.bg)
        #endif
    }

    private var chapter: Int { (timings.sections.firstIndex { $0.section == sentence.section } ?? 0) + 1 }

    /// The sentence among its neighbours, as the page shows them.
    private var words: some View {
        let list = texts[sentence.section] ?? []
        let i = Int(sentence.sentence)
        var text = AttributedString()
        func add(_ k: Int, current: Bool) {
            guard list.indices.contains(k) else { return }
            var part = AttributedString(list[k])
            part.foregroundColor = current ? YYColor.t1 : YYColor.t3
            if current { part.backgroundColor = tint.accentSoft }
            text += part
        }
        add(i - 1, current: false)
        add(i, current: true)
        add(i + 1, current: false)
        return Text(text)
            .font(YYUI.font(12.5))
            .lineSpacing(YYUI.s(12.5) * 0.5)
            .lineLimit(4)
            .frame(maxWidth: .infinity, minHeight: YYUI.s(40), alignment: .topLeading)
            .padding(YYUI.s(12))
            .yyCard()
    }

    // MARK: The sound

    private var wave: some View {
        VStack(spacing: 0) {
            GeometryReader { g in
                let w = g.size.width
                let x = { (t: Double) in CGFloat((t - window.lowerBound) / (window.upperBound - window.lowerBound)) * w }
                let start = sentence.start, end = sentence.end
                let old = before[at]
                ZStack(alignment: .topLeading) {
                    // The sentence.
                    RoundedRectangle(cornerRadius: 4).fill(tint.accentSoft)
                        .frame(width: max(0, x(end) - x(start)), height: YYUI.s(56) + 8)
                        .offset(x: x(start), y: -4)
                    Canvas { ctx, size in
                        guard !levels.isEmpty else { return }
                        let step = size.width / CGFloat(levels.count)
                        for (k, v) in levels.enumerated() {
                            let h = max(2, CGFloat(v) * size.height)
                            let mid = CGFloat(k) * step + step / 2
                            let t = window.lowerBound + Double(mid / size.width) * (window.upperBound - window.lowerBound)
                            let inside = t >= start && t <= end
                            let bar = CGRect(x: mid - step * 0.3, y: (size.height - h) / 2, width: step * 0.6, height: h)
                            ctx.fill(Path(roundedRect: bar, cornerRadius: step * 0.3), with: .color(inside ? tint.accent : YYColor.t3.opacity(0.6)))
                        }
                    }
                    .frame(height: YYUI.s(56))
                    // Where it ends.
                    Rectangle().fill(tint.accent.opacity(0.55)).frame(width: 1, height: YYUI.s(56) + 8).offset(x: x(end), y: -4)
                    if let old, abs(old - start) >= 0.05 {
                        // Where it was, and how far it moved.
                        Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: YYUI.s(56) + 10)) }
                            .stroke(YYColor.t3, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                            .frame(width: 2, height: YYUI.s(56) + 10)
                            .offset(x: x(old), y: -6)
                        let gap = abs(x(start) - x(old))
                        arrow
                            .frame(width: gap, height: YYUI.s(14))
                            .scaleEffect(x: start < old ? -1 : 1)
                            .offset(x: min(x(start), x(old)), y: -YYUI.s(24))
                        // In the gap when it's wide enough and clear of the time by the
                        // handle; otherwise just left of both.
                        let roomy = start > old && gap >= YYUI.s(64)
                        Text(String(format: String(localized: "%@%.1f 秒"), start > old ? "+" : "−", abs(start - old)))
                            .font(YYUI.font(10).monospacedDigit())
                            .foregroundStyle(YYColor.t2)
                            .padding(.horizontal, 4)
                            .background(YYColor.card)
                            .fixedSize()
                            .frame(width: roomy ? gap : YYUI.s(70), height: YYUI.s(14), alignment: roomy ? .center : .trailing)
                            .offset(x: roomy ? x(old) : min(x(start), x(old)) - YYUI.s(70) - 2, y: -YYUI.s(24))
                    }
                    handle.offset(x: x(start) - 1, y: -YYUI.s(17))
                }
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let t = window.lowerBound + Double(v.location.x / w) * (window.upperBound - window.lowerBound)
                    move(to: (t * 10).rounded() / 10)
                })
            }
            .frame(height: YYUI.s(56))
            ruler.padding(.top, YYUI.s(9))
        }
        .padding(.horizontal, YYUI.s(14))
        .padding(.top, YYUI.s(30))
        .padding(.bottom, YYUI.s(10))
        .yyCard()
        .accessibilityElement()
        .accessibilityLabel("这句从 \(stamp(sentence.start)) 开始")
        .accessibilityAdjustableAction { d in move(to: sentence.start + (d == .increment ? 0.1 : -0.1)) }
    }

    /// An arrow from where it was.
    private var arrow: some View {
        ZStack(alignment: .trailing) {
            Rectangle().fill(YYColor.t3).frame(height: 1).padding(.leading, 3).padding(.trailing, 8)
            Image(systemName: "chevron.right").font(.yy(size: 7)).foregroundStyle(YYColor.t3).padding(.trailing, 6)
        }
    }

    /// The line at the start, a knob on top, and the time beside it.
    private var handle: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 1).fill(tint.accent)
                .frame(width: 2, height: YYUI.s(56) + YYUI.s(17) + 4)
            Circle().fill(YYColor.card)
                .overlay(Circle().stroke(tint.accent, lineWidth: 2))
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                .frame(width: 11, height: 11)
                .offset(x: -4.5, y: -1)
            Text(stamp(sentence.start))
                .font(YYUI.font(10, .semibold).monospacedDigit())
                .foregroundStyle(tint.accent)
                .fixedSize()
                .offset(x: 9, y: -2)
        }
        .allowsHitTesting(false)
    }

    private var ruler: some View {
        GeometryReader { g in
            let span = window.upperBound - window.lowerBound
            ForEach(Array(stride(from: ceil(window.lowerBound), through: window.upperBound, by: 1)), id: \.self) { t in
                Text(clock(t))
                    .font(YYUI.font(10).monospacedDigit())
                    .foregroundStyle(YYColor.t3)
                    .fixedSize()
                    .position(x: CGFloat((t - window.lowerBound) / span) * g.size.width, y: YYUI.s(6.5))
            }
        }
        .frame(height: YYUI.s(13))
    }

    /// `0:17.2`.
    private func stamp(_ t: Double) -> String {
        let tenths = Int((max(0, t) * 10).rounded())
        let s = tenths / 10
        return (s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)) + ".\(tenths % 10)"
    }

    /// −0.1 秒, 试听这句, +0.1 秒 at 1 : 1.5 : 1.
    private var nudges: some View {
        GeometryReader { g in
            let unit = (g.size.width - YYUI.s(16)) / 3.5
            HStack(spacing: YYUI.s(8)) {
                Button("−0.1 秒") { move(to: sentence.start - 0.1) }
                    .buttonStyle(YYButtonStyle(kind: .plain, wide: true)).frame(width: unit)
                Button { books.listen(audiobook, from: sentence.start, to: max(sentence.end, sentence.start + 1)) } label: {
                    HStack(spacing: YYUI.s(5)) { Image(systemName: "play.fill").imageScale(.small); Text("试听这句") }
                }
                .buttonStyle(YYButtonStyle(kind: .raised, wide: true)).frame(width: unit * 1.5)
                Button("+0.1 秒") { move(to: sentence.start + 0.1) }
                    .buttonStyle(YYButtonStyle(kind: .plain, wide: true)).frame(width: unit)
            }
        }
        .frame(height: YYUI.s(32))
    }

    // MARK: Moving it

    private func move(to wanted: Double) {
        let was = sentence.start
        var t = timings
        let delta = t.moveStart(at, to: min(max(wanted, window.lowerBound), window.upperBound), follow: follow)
        guard delta != 0 else { return }
        if before[at] == nil { before[at] = was }
        timings = t
    }

    /// The next or previous sentence that's in the recording.
    private func neighbour(_ step: Int, sameChapter: Bool = false) -> Int? {
        timings.neighbour(of: at, step, sameChapter: sameChapter)
    }

    private func go(_ step: Int) {
        books.stopListening()
        if let j = neighbour(step) { at = j }
    }

    private func finish() {
        books.stopListening()
        if !before.isEmpty { done(timings) }
        dismiss()
    }

    /// The sound and words around the sentence, when it changes.
    private func look() async {
        let s = sentence
        let from = max(0, s.start - 2.5)
        window = from ... from + 6
        if texts[s.section] == nil, let book = audiobook.book {
            texts[s.section] = (try? library.core.sentences(bookId: book, section: s.section)) ?? []
        }
        guard let book = audiobook.book, let r = books.recording(for: book) else { return }
        levels = await Audiobooks.levels(r, from, from + 6, bars: 72)
    }
}
