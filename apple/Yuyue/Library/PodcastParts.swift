import SwiftUI
import YuyueCore

/// 播客's own pieces, the same on the Mac and the phone (docs/design/播客.html).

/// `.lg25`: the 液态玻璃 button chosen for 播客 (播客-按钮.html · A). Half see-through, a bright
/// line along the top and a soft shadow under; the action in ink, the one playing in the theme's
/// colour.
struct PodcastGlassButton: View {
    /// `main`: the screen's one action (建好了), in the theme's colour without the moving bars.
    enum Kind { case plain, main, playing, writing }
    let title: String
    var symbol: String?
    var kind = Kind.plain
    /// No glass: the prototype's white capsule with a hairline (`.imp`), sitting on the paper.
    var flat = false
    /// The key that presses it, written small after the title (配节目-排版.html: 建好了 ⌘↩).
    var key: String?
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                switch kind {
                case .playing: EqualizerBars().frame(width: 10, height: 10)
                case .writing: ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 10, height: 10)
                case .plain, .main: if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)) }
                }
                Text(title).font(.yy(size: 11.5, weight: kind == .writing ? .regular : .semibold)).monospacedDigit().lineLimit(1)
                if let key { Text(key).font(.yy(size: 10)).foregroundStyle(YYColor.t3).padding(.leading, -2) }
            }
            .foregroundStyle(kind == .playing || kind == .main ? tint.accent : kind == .writing ? YYColor.t2 : YYColor.t1)
            .padding(.leading, kind == .main && symbol == nil ? 16 : 10).padding(.trailing, kind == .main ? 16 : 12)
            .frame(height: 28)
            .background { if flat { paper } else { glass } }
            .contentShape(.capsule)
        }
        .buttonStyle(PressDown())
    }

    /// `.imp`: the card's white, `--zsh` round it (a hairline and the faintest shadow).
    private var paper: some View {
        Capsule()
            .fill(YYColor.card)
            .overlay(Capsule().strokeBorder(YYColor.line, lineWidth: 0.5))
            .shadow(color: Color(red: 51 / 255, green: 46 / 255, blue: 41 / 255).opacity(scheme == .dark ? 0 : 0.04), radius: 1, y: 1)
    }

    @ViewBuilder private var glass: some View {
        let dark = scheme == .dark
        Capsule()
            .fill(LinearGradient(colors: dark ? [.white.opacity(0.16), .white.opacity(0.05)] : [.white.opacity(0.78), .white.opacity(0.38)],
                                 startPoint: .top, endPoint: .bottom))
            .background(.ultraThinMaterial, in: .capsule)
            .overlay(alignment: .top) {
                Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.25 : 0.95), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
            }
            .overlay(Capsule().strokeBorder(dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08), lineWidth: 0.5))
            .shadow(color: Color(red: 30 / 255, green: 40 / 255, blue: 60 / 255).opacity(dark ? 0.2 : 0.05), radius: 2, y: 1)
    }

    private struct PressDown: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1).opacity(configuration.isPressed ? 0.85 : 1)
        }
    }
}

/// `.pb.t`: only words (取消) — a faint grey pad under the pointer.
struct PodcastTextButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.yy(size: 11.5, weight: .medium)).foregroundStyle(hovering ? YYColor.t1 : YYColor.t2)
                .padding(.horizontal, 8).frame(height: 28)
                .background(hovering ? YYColor.t1.opacity(0.05) : .clear, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
    }
}

/// Where an episode's articles came from: a small square each, one per site, as 配一档节目
/// marks its sources (Y for Hacker News). Hover lists the articles.
struct SourceMarks: View {
    let articles: [ScriptArticle]

    var body: some View {
        var seen: [String] = []
        for a in articles where !seen.contains(a.source) { seen.append(a.source) }
        let shown = Array(seen.prefix(4))
        return HStack(spacing: 3) {
            ForEach(shown, id: \.self) { s in Self.mark(s) }
            if seen.count > shown.count {
                Text("+\(seen.count - shown.count)").font(.yy(size: 10)).foregroundStyle(YYColor.t3)
            }
        }
        .help(articles.map { $0.source.isEmpty ? $0.title : "\($0.source) · \($0.title)" }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(localized: "来源：\(seen.joined(separator: "、"))")))
    }

    static func mark(_ source: String) -> some View {
        let hn = source.localizedCaseInsensitiveContains("hacker news")
        let letter = hn ? "Y" : String(source.prefix(1)).uppercased()
        let color = hn ? Color(red: 0.95, green: 0.4, blue: 0.13) : Color(white: 0.2)
        return Text(letter).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            .frame(width: 15, height: 15).background(color, in: .rect(cornerRadius: 4))
    }
}

/// Three bars that move while something plays.
struct EqualizerBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { t in
            let s = t.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0 ..< 3) { i in
                    Capsule().frame(width: 2, height: 3 + 7 * abs(sin(s * 4 + Double(i) * 1.3)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// 节目封面: made from the show's name, square, the radio mark in the corner (`.v-sqc.pc`).
struct ShowCover: View {
    let name: String
    var size: CGFloat = 52

    var body: some View {
        let c = Self.colour(name)
        RoundedRectangle(cornerRadius: size * 0.17)
            .fill(c.fill)
            .frame(width: size, height: size)
            .overlay(alignment: .topLeading) {
                // Only where it can be read: a small cover in a list sits beside the show's name
                // anyway, and 6-point 宋体 was a smudge.
                if size >= 64 {
                Text(name).font(.custom("Songti SC", size: max(6.5, size * 0.14)).weight(.semibold)).tracking(size * 0.007)
                    .foregroundStyle(c.ink.opacity(0.92)).lineLimit(2)
                    .padding(.top, size * 0.1).padding(.leading, size * 0.11).padding(.trailing, size * 0.1)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if size >= 40 {
                    Image("radio").resizable().renderingMode(.template).scaledToFit()
                        .frame(width: size * 0.24, height: size * 0.24).foregroundStyle(c.ink.opacity(0.6))
                        .padding(size * 0.09)
                }
            }
            .accessibilityHidden(true)
    }

    /// The prototype's five: 墨蓝、砖红、苔绿、米、紫.
    private static let palette: [(Color, Color)] = [
        (Color(red: 0x2F / 255, green: 0x45 / 255, blue: 0x60 / 255), .white),
        (Color(red: 0x8C / 255, green: 0x4A / 255, blue: 0x33 / 255), .white),
        (Color(red: 0x5B / 255, green: 0x6E / 255, blue: 0x4E / 255), .white),
        (Color(red: 0xE6 / 255, green: 0xDC / 255, blue: 0xCB / 255), Color(red: 30 / 255, green: 28 / 255, blue: 24 / 255)),
        (Color(red: 0x6B / 255, green: 0x5A / 255, blue: 0x82 / 255), .white),
    ]

    static func colour(_ name: String) -> (fill: Color, ink: Color) {
        let n = name.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        let p = palette[Int(n % UInt32(palette.count))]
        return (p.0, p.1)
    }
}

extension Show {
    var draft: ShowDraft {
        ShowDraft(name: name, sources: sources, schedule: schedule, minutes: minutes, form: form, hosts: hosts,
                  language: language, brief: brief, avoid: avoid, device: device)
    }

    /// "工作日早上 7:00", "每天 7:00", "点了才写".
    var scheduleLine: String { schedule.line }
}

extension ShowSchedule {
    var line: String {
        let time = String(format: "%d:%02d", minute / 60, minute % 60)
        let d = Set(days)
        if d.isEmpty { return String(localized: "点了才写") }
        if d == [1, 2, 3, 4, 5] { return String(localized: "工作日 \(time)") }
        if d.count == 7 { return String(localized: "每天 \(time)") }
        let names = [String(localized: "一"), String(localized: "二"), String(localized: "三"), String(localized: "四"),
                     String(localized: "五"), String(localized: "六"), String(localized: "日")]
        return String(localized: "每周\(days.sorted().map { names[Int($0) - 1] }.joined(separator: "、")) \(time)")
    }
}

extension Episode {
    /// "今天", "昨天", "10 月 27 日".
    var day: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: date) else { return date }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return String(localized: "今天") }
        if cal.isDateInYesterday(d) { return String(localized: "昨天") }
        return d.formatted(.dateTime.month().day())
    }
}

extension Podcasts.Progress {
    /// "正在写第 4 / 7 条", "正在取新内容".
    var line: String {
        switch step {
        case .fetch: String(localized: "正在取新内容 \(done) / \(max(total, 1))")
        case .read, .pick: String(localized: "收到 \(found) 篇，正在挑")
        case .summarize: String(localized: "正在读第 \(min(done + 1, total)) / \(total) 篇")
        case .write: String(localized: "正在写稿")
        case .save: String(localized: "快好了")
        }
    }

    /// "正在写 4 / 7" for the small button.
    var short: String {
        switch step {
        case .summarize: String(localized: "正在写 \(min(done + 1, total)) / \(total)")
        case .write, .save: String(localized: "正在写稿")
        default: String(localized: "正在准备")
        }
    }
}
