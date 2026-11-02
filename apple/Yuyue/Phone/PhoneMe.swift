#if os(iOS)
import AuthenticationServices
import SwiftUI
import Translation
import UniformTypeIdentifiers
import YuyueCore

/// 我的 (prototype 我的): this week's reading and listening on top, the year's totals under it,
/// then every setting in groups: 同步; 外观; 外文 and 引擎; 存储 and 关于.
struct PhoneMe: View {
    let library: Library
    @State private var week: [DayTime] = []
    @State private var marks = 0
    @State private var used: Int64?
    @State private var lastSnapshot: Int64?
    @AppStorage(ImmersivePrefs.alwaysKey) private var immersiveAlways = false
    @AppStorage(EInk.key) private var einkOn = false
    @State private var words = 0
    @AppStorage(AppAppearance.key) private var mode = AppAppearance.system
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    var body: some View {
        NavigationStack {
            YYPage {
                NavigationLink { PhoneStats(library: library) } label: { weekCard }
                    .buttonStyle(.plain)
                    .padding(.top, YYUI.s(14))
                    .padding(.bottom, YYUI.s(12))
                group {
                    link(String(localized: "同步"), "icloud", syncDetail) { PhoneSync(library: library) }
                    link(String(localized: "书库来源"), "server.rack", library.sources.all.isEmpty ? nil : String(localized: "\(library.sources.all.count) 个")) { PhoneSources(library: library) }
                    link(String(localized: "Wi‑Fi 传书"), "wifi", nil) { PhoneWifi(library: library) }
                }
                group {
                    link(String(localized: "外观"), "sun.max", "\(mode.title) · \(tint.name)") { PhoneAppearance() }
                    link(String(localized: "沉浸阅读"), "viewfinder", immersiveAlways ? String(localized: "开") : String(localized: "关")) { PhoneImmersiveSheet().navigationTitle("沉浸阅读").navigationBarTitleDisplayMode(.inline) }
                    link(String(localized: "墨水屏"), "rectangle.portrait.on.rectangle.portrait", einkOn ? String(localized: "开") : String(localized: "关")) { PhoneEInk(library: library) }
                    link(String(localized: "外文阅读"), "globe", nil) { PhoneForeign(library: library) }
                }
                group {
                    link(String(localized: "朗读"), "headphones", nil) { PhoneListening() }
                    link(String(localized: "引擎"), "cpu", String(localized: "书伴、朗读、翻译")) { PhoneEngines(library: library) }
                }
                group {
                    link(String(localized: "存储空间"), "internaldrive", used.map(PhoneStorage.size)) { PhoneStorage(library: library) }
                    link(String(localized: "数据快照"), "shippingbox", lastSnapshot.map(Snapshots.day) ?? String(localized: "换设备、备份")) { PhoneSnapshot(library: library) }
                    link(String(localized: "笔记导出"), "square.and.arrow.up", "Obsidian · Notion · flomo") { PhoneNoteExport() }
                }
                group {
                    link(String(localized: "关于"), "info.circle", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) { PhoneAbout() }
                }
            }
            .navigationTitle("我的")
        }
        .task(id: library.books.map(\.id)) { load() }
        .task {
            let dir = library.dataDir
            used = await StorageUsage.measure(dir: dir, active: [:]).total
            let snapshots = Snapshots(library: library)
            await snapshots.load()
            lastSnapshot = snapshots.saved.first?.about.madeAt
        }
        .onReceive(NotificationCenter.default.publisher(for: .notesChanged)) { _ in load() }
        .onReceive(NotificationCenter.default.publisher(for: .vocabChanged)) { _ in load() }
    }

    /// `.v-me-set`: one of the five groups of settings.
    private func group<Content: View>(@ViewBuilder _ rows: () -> Content) -> some View {
        YYGroup { rows() }.padding(.bottom, YYUI.s(10))
    }

    private func link<Destination: View>(_ title: String, _ symbol: String, _ value: String?,
                                         @ViewBuilder _ destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            YYRow(title, icon: symbol, value: value, chevron: true).frame(minHeight: YYUI.s(36))
        }
        .buttonStyle(.plain)
    }

    private func load() {
        let days = PhoneStats.Period.week.days(containing: Date())
        week = (try? library.core.dayTimes(from: Notes.day(days.first!), to: Notes.day(days.last!))) ?? []
        marks = library.books.filter(\.available).reduce(0) { $0 + ((try? library.core.marks(book: $1.id))?.count ?? 0) }
        words = ((try? library.core.words()) ?? []).count { !$0.known }
    }

    private var finishedThisYear: Int {
        let year = Calendar.current.component(.year, from: Date())
        return library.books.count { b in
            guard b.status == .finished else { return false }
            let at = b.finishedAt ?? b.openedAt ?? b.addedAt
            return Calendar.current.component(.year, from: Notes.date(at)) == year
        }
    }

    private var syncDetail: String {
        let sync = library.sync
        guard sync.isOn else { return String(localized: "没开") }
        let place = switch sync.method {
        case .webdav: "WebDAV"
        case .googleDrive: "Google Drive"
        default: "iCloud"
        }
        if case .failed = sync.state { return String(localized: "\(place) · 没同步上") }
        return [place, sync.lastSynced.map(PhoneSync.ago)].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: 这周

    /// `.v-me-wk`: this week's reading and listening, a column a day stacked, and under them the
    /// books finished this year, the lines marked and the words kept.
    private var weekCard: some View {
        let days = PhoneStats.Period.week.days(containing: Date())
        let read = week.reduce(0) { $0 + Int($1.readSeconds) }
        let listen = week.reduce(0) { $0 + Int($1.listenSeconds) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("这周").foregroundStyle(YYColor.t3)
                Spacer()
                HStack(spacing: 1) {
                    Text("阅读统计")
                    Image(systemName: "chevron.right").font(YYUI.font(8, .semibold))
                }
                .foregroundStyle(YYColor.t2)
            }
            .font(YYUI.font(10.5))
            HStack(spacing: YYUI.s(20)) {
                periodTotal(String(localized: "读"), read, tint.fill)
                periodTotal(String(localized: "听"), listen, YYColor.tint)
            }
            .padding(.top, YYUI.s(6))
            WeekBars(days: days, times: week, tint: tint)
                .frame(height: YYUI.s(70))
                .padding(.top, YYUI.s(10))
            HStack(spacing: 0) {
                tile("\(finishedThisYear)", String(localized: "本"), String(localized: "今年读完"))
                Rectangle().fill(YYColor.line).frame(width: 0.5)
                tile(marks.formatted(), String(localized: "句"), String(localized: "划线"))
                Rectangle().fill(YYColor.line).frame(width: 0.5)
                tile(words.formatted(), String(localized: "个"), String(localized: "生词"))
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, YYUI.s(11))
            .overlay(alignment: .top) { Rectangle().fill(YYColor.line).frame(height: 0.5) }
            .padding(.top, YYUI.s(12))
        }
        .padding(.vertical, YYUI.s(12))
        .padding(.horizontal, YYUI.s(14))
        .yyCard()
        .contentShape(.rect)
    }

    /// `.v-me-n3`: one of the three counts.
    private func tile(_ number: String, _ unit: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: YYUI.s(2)) {
                Text(number).font(YYUI.font(15, .bold).monospacedDigit()).foregroundStyle(YYColor.t1)
                Text(unit).font(YYUI.font(10, .medium)).foregroundStyle(YYColor.t2)
            }
            Text(label).font(YYUI.font(10)).foregroundStyle(YYColor.t3)
        }
        .frame(maxWidth: .infinity)
    }
}

/// `.v-me-ch`: seven columns, listening stacked on reading; today's column wider and its label
/// dark, the days to come empty.
private struct WeekBars: View {
    let days: [Date]
    let times: [DayTime]
    let tint: YYTint

    var body: some View {
        let sums = days.map { d -> (Int, Int) in
            let key = Notes.day(d)
            let t = times.filter { $0.day == key }
            return (t.reduce(0) { $0 + Int($1.readSeconds) }, t.reduce(0) { $0 + Int($1.listenSeconds) })
        }
        let most = max(1, sums.map { $0.0 + $0.1 }.max() ?? 1)
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                let today = Calendar.current.isDateInToday(day)
                VStack(spacing: 0) {
                    GeometryReader { g in
                        VStack(spacing: 1) {
                            Spacer(minLength: 0)
                            if sums[i].1 > 0 {
                                UnevenRoundedRectangle(topLeadingRadius: 2.5, topTrailingRadius: 2.5).fill(YYColor.tint)
                                    .frame(height: g.size.height * Double(sums[i].1) / Double(most))
                            }
                            if sums[i].0 > 0 {
                                UnevenRoundedRectangle(topLeadingRadius: sums[i].1 > 0 ? 0 : 2.5, bottomLeadingRadius: 1,
                                                       bottomTrailingRadius: 1, topTrailingRadius: sums[i].1 > 0 ? 0 : 2.5)
                                    .fill(tint.fill)
                                    .frame(height: g.size.height * Double(sums[i].0) / Double(most))
                            }
                        }
                        .frame(width: YYUI.s(today ? 12 : 8))
                        .frame(maxWidth: .infinity)
                    }
                    Text(today ? String(localized: "今天") : Self.weekday(day))
                        .font(YYUI.font(10, today ? .semibold : .regular))
                        .foregroundStyle(today ? YYColor.t1 : YYColor.t3)
                        .fixedSize()
                        .padding(.top, YYUI.s(5))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    static func weekday(_ d: Date) -> String {
        [String(localized: "日"), String(localized: "一"), String(localized: "二"), String(localized: "三"), String(localized: "四"), String(localized: "五"), String(localized: "六")][Calendar.current.component(.weekday, from: d) - 1]
    }
}

/// `.v-me-tt`: "■ 读 5 小时 12 分", the numbers big.
fileprivate func periodTotal(_ label: String, _ seconds: Int, _ color: Color) -> some View {
    let m = seconds / 60
    let parts: [(Int, String)] = m < 60 ? [(m, String(localized: "分"))] : m % 60 == 0 ? [(m / 60, String(localized: "小时"))] : [(m / 60, String(localized: "小时")), (m % 60, String(localized: "分"))]
    return HStack(alignment: .firstTextBaseline, spacing: YYUI.s(2)) {
        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: YYUI.s(7), height: YYUI.s(7))
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            .padding(.trailing, YYUI.s(3))
        Text(label)
        ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
            Text("\(part.0)").font(YYUI.font(19, .bold).monospacedDigit()).foregroundStyle(YYColor.t1)
                .padding(.leading, YYUI.s(i == 0 ? 4 : 5)).padding(.trailing, YYUI.s(1))
            Text(part.1)
        }
    }
    .font(YYUI.font(10.5))
    .foregroundStyle(YYColor.t2)
    .lineLimit(1)
}

// MARK: - 阅读统计

/// 阅读统计 (prototype 阅读统计): by week, month or year, reading and listening apart; the books
/// finished; each book's time; and, at the bottom, how the time is counted.
struct PhoneStats: View {
    let library: Library
    @State private var period = Period.week
    @State private var anchor = Date()
    @State private var times: [DayTime] = []
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    enum Period: String, CaseIterable, Identifiable {
        case week, month, year
        var id: String { rawValue }
        var name: String {
            switch self {
            case .week: String(localized: "周")
            case .month: String(localized: "月")
            case .year: String(localized: "年")
            }
        }

        /// Weeks start on Monday.
        static var calendar: Calendar {
            var c = Calendar.current
            c.firstWeekday = 2
            return c
        }

        var component: Calendar.Component {
            switch self {
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
        }

        /// Every day of the period `date` falls in.
        func days(containing date: Date) -> [Date] {
            let cal = Self.calendar
            guard let range = cal.dateInterval(of: component, for: date) else { return [date] }
            var out: [Date] = []
            var d = range.start
            while d < range.end {
                out.append(d)
                d = cal.date(byAdding: .day, value: 1, to: d) ?? range.end
            }
            return out
        }
    }

    private var days: [Date] { period.days(containing: anchor) }
    private var isCurrent: Bool { days.contains { Calendar.current.isDateInToday($0) } }

    var body: some View {
        YYPage {
            YYSegments(items: Period.allCases.map { ($0, $0.name) }, selection: $period)
                .padding(.top, YYUI.s(10))
            periodCard.padding(.top, YYUI.s(12))
            if !perBook.isEmpty {
                YYLabel(String(localized: "每本书"), String(localized: "\(periodWord) · 按时长"))
                YYGroup {
                    ForEach(perBook, id: \.0.id) { book, read, listen in bookRow(book, read, listen) }
                }
                .padding(.bottom, YYUI.s(12))
            }
            how.padding(.top, perBook.isEmpty ? YYUI.s(12) : YYUI.s(2))
        }
        .navigationTitle("阅读统计")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(period.rawValue)\(Notes.day(anchor))") { load() }
        .onChange(of: period) { anchor = Date() }
    }

    /// `.v-me-mo`: the period, its way back and on, reading and listening, a column a day (a
    /// month in a year), and the books finished in it.
    private var periodCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: YYUI.s(6)) {
                Text(heading.0).font(YYUI.font(13, .bold)).foregroundStyle(YYColor.t1)
                Text(heading.1).font(YYUI.font(10).monospacedDigit()).foregroundStyle(YYColor.t3)
                Spacer()
                HStack(spacing: YYUI.s(4)) {
                    step("chevron.left", String(localized: "往前")) { move(-1) }
                    step("chevron.right", String(localized: "往后")) { move(1) }.disabled(isCurrent)
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + YYUI.s(4) }
            }
            HStack(spacing: YYUI.s(20)) {
                periodTotal(String(localized: "读"), times.reduce(0) { $0 + Int($1.readSeconds) }, tint.fill)
                periodTotal(String(localized: "听"), times.reduce(0) { $0 + Int($1.listenSeconds) }, YYColor.tint)
            }
            .padding(.top, YYUI.s(6))
            columns.frame(height: YYUI.s(50)).padding(.top, YYUI.s(12))
            axis.padding(.top, YYUI.s(5))
            if finished.isEmpty {
                Color.clear.frame(height: YYUI.s(12))
            } else {
                HStack(spacing: YYUI.s(10)) {
                    HStack(spacing: -YYUI.s(6)) {
                        ForEach(finished.prefix(3), id: \.id) { b in
                            BookCover(book: b).frame(width: YYUI.s(20))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(YYColor.card, lineWidth: 1.5))
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(periodWord)读完 \(finished.count) 本").font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1)
                        Text(finished.map(\.title).joined(separator: " · ")).font(YYUI.font(10)).foregroundStyle(YYColor.t3).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, YYUI.s(10))
                .padding(.bottom, YYUI.s(11))
                .overlay(alignment: .top) { Rectangle().fill(YYColor.line).frame(height: 0.5) }
                .padding(.top, YYUI.s(12))
            }
        }
        .padding(.top, YYUI.s(12))
        .padding(.horizontal, YYUI.s(14))
        .yyCard()
    }

    private func step(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(YYUI.font(9, .semibold)).foregroundStyle(YYColor.t1)
                .frame(width: YYUI.s(24), height: YYUI.s(24))
                .background(YYColor.inset, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// "10 月" and "1 日 – 11 日"; "这周" and the days; "2026 年" and the months so far.
    private var heading: (String, String) {
        guard let first = days.first, let last = days.last else { return ("", "") }
        let cal = Calendar.current
        let end = isCurrent ? min(Date(), last) : last
        // Other languages go by month names: "October", "Oct 1 – 21", "Jan – Oct".
        if !(Bundle.main.preferredLocalizations.first ?? "zh").hasPrefix("zh") {
            let day = { (d: Date) in String(cal.component(.day, from: d)) }
            let short = { (d: Date) in d.formatted(.dateTime.month(.abbreviated)) }
            switch period {
            case .week:
                return (periodWord, "\(short(first)) \(day(first)) – \(cal.isDate(first, equalTo: last, toGranularity: .month) ? "" : short(last) + " ")\(day(last))")
            case .month:
                return (first.formatted(.dateTime.month(.wide)), "\(short(first)) 1 – \(day(end))")
            case .year:
                return (String(cal.component(.year, from: first)), "\(short(first)) – \(short(end))")
            }
        }
        switch period {
        case .week:
            return (periodWord, String(localized: "\(Notes.monthDay(first)) – \(cal.component(.month, from: first) == cal.component(.month, from: last) ? String(localized: "\(cal.component(.day, from: last)) 日") : Notes.monthDay(last))"))
        case .month:
            return (String(localized: "\(cal.component(.month, from: first)) 月"), String(localized: "1 日 – \(cal.component(.day, from: end)) 日"))
        case .year:
            return (String(localized: "\(cal.component(.year, from: first)) 年"), String(localized: "1 – \(cal.component(.month, from: end)) 月"))
        }
    }

    /// One slot per day (per month over a year): listening on top of reading, today wider, the
    /// days to come a nub.
    private var slots: [(read: Int, listen: Int, today: Bool, future: Bool)] {
        let cal = Calendar.current
        let now = Date()
        if period == .year {
            return (0 ..< 12).map { m in
                let start = cal.date(byAdding: .month, value: m, to: days[0]) ?? days[0]
                let prefix = String(Notes.day(start).prefix(7))
                let t = times.filter { $0.day.hasPrefix(prefix) }
                return (t.reduce(0) { $0 + Int($1.readSeconds) }, t.reduce(0) { $0 + Int($1.listenSeconds) },
                        cal.isDate(start, equalTo: now, toGranularity: .month), start > now)
            }
        }
        return days.map { d in
            let key = Notes.day(d)
            let t = times.filter { $0.day == key }
            return (t.reduce(0) { $0 + Int($1.readSeconds) }, t.reduce(0) { $0 + Int($1.listenSeconds) },
                    cal.isDateInToday(d), d > now)
        }
    }

    private var columns: some View {
        let slots = slots
        let most = max(1, slots.map { $0.read + $0.listen }.max() ?? 1)
        let width: CGFloat = period == .week ? 8 : 5
        return GeometryReader { g in
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, s in
                    VStack(spacing: 1) {
                        Spacer(minLength: 0)
                        if s.future {
                            RoundedRectangle(cornerRadius: 1).fill(YYColor.line).frame(height: 2)
                        } else {
                            if s.listen > 0 {
                                UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2).fill(YYColor.tint)
                                    .frame(height: g.size.height * Double(s.listen) / Double(most))
                            }
                            if s.read > 0 {
                                UnevenRoundedRectangle(topLeadingRadius: s.listen > 0 ? 0 : 2, topTrailingRadius: s.listen > 0 ? 0 : 2)
                                    .fill(tint.fill)
                                    .frame(height: g.size.height * Double(s.read) / Double(most))
                            }
                        }
                    }
                    .frame(width: YYUI.s(s.today ? width + 2 : width))
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Under the columns: the weekdays; 1, 8, 15, 22, 29 of a month; every other month of a year.
    private var axis: some View {
        let n = period == .year ? 12 : days.count
        return HStack(spacing: 0) {
            ForEach(0 ..< n, id: \.self) { i in
                Text(axisLabel(i)).font(YYUI.font(10).monospacedDigit()).foregroundStyle(YYColor.t3)
                    .fixedSize()
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func axisLabel(_ i: Int) -> String {
        switch period {
        case .week: WeekBars.weekday(days[i])
        case .month: i % 7 == 0 ? "\(i + 1)" : ""
        case .year:
            i % 2 != 0 ? ""
                : (Bundle.main.preferredLocalizations.first ?? "zh").hasPrefix("zh") ? String(localized: "\(i + 1) 月")
                : (Calendar.current.date(byAdding: .month, value: i, to: days[0]) ?? days[0]).formatted(.dateTime.month(.abbreviated))
        }
    }

    /// `.v-me-bk`: a book, how far and how long to go, and the time read and listened.
    private func bookRow(_ book: BookSummary, _ read: Int, _ listen: Int) -> some View {
        HStack(spacing: YYUI.s(10)) {
            BookCover(book: book).frame(width: YYUI.s(24))
            VStack(alignment: .leading, spacing: YYUI.s(2)) {
                HStack(alignment: .firstTextBaseline, spacing: YYUI.s(8)) {
                    Text(book.title).font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(book.status == .finished ? finishedLine(book) : String(localized: "\(book.percent) · \(book.remaining.replacingOccurrences(of: String(localized: "还剩"), with: String(localized: "还要")))"))
                        .font(YYUI.font(10.5).monospacedDigit()).foregroundStyle(YYColor.t2).lineLimit(1)
                }
                Text([read > 0 ? String(localized: "读 ") + Self.duration(read) : nil, listen > 0 ? String(localized: "听 ") + Self.duration(listen) : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(YYUI.font(10).monospacedDigit()).foregroundStyle(YYColor.t3).lineLimit(1)
            }
        }
        .padding(.vertical, YYUI.s(8))
    }

    /// `.v-me-how`: how the time is counted, on a grey card.
    private var how: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("怎么算的", systemImage: "info.circle")
                .font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1)
                .padding(.bottom, YYUI.s(3))
            ForEach([String(localized: "只在翻页、滚动或朗读的时候计时。"), String(localized: "一页停了 5 分钟没翻，或者锁屏又没在听，就停表。"), String(localized: "倍速按实际时间算：1.5× 听 1 小时，记 1 小时。")], id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: YYUI.s(6)) {
                    Circle().fill(YYColor.t3).frame(width: 3, height: 3).alignmentGuide(.firstTextBaseline) { $0[.bottom] + YYUI.s(4) }
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
                .font(YYUI.font(10.5)).foregroundStyle(YYColor.t2)
                .padding(.vertical, YYUI.s(2))
            }
        }
        .padding(.top, YYUI.s(11))
        .padding(.bottom, YYUI.s(12))
        .padding(.horizontal, YYUI.s(13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YYColor.inset, in: .rect(cornerRadius: YYUI.s(14)))
    }

    private func load() {
        guard let first = days.first, let last = days.last else { return }
        times = (try? library.core.dayTimes(from: Notes.day(first), to: Notes.day(last))) ?? []
    }

    private func move(_ by: Int) {
        anchor = Period.calendar.date(byAdding: period.component, value: by, to: anchor) ?? anchor
    }

    private var periodWord: String {
        switch period {
        case .week: isCurrent ? String(localized: "这周") : String(localized: "那一周")
        case .month: isCurrent ? String(localized: "这个月") : String(localized: "那个月")
        case .year: isCurrent ? String(localized: "今年") : String(localized: "那年")
        }
    }

    private var finished: [BookSummary] {
        guard let first = days.first, let last = days.last,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: last) else { return [] }
        return library.books.filter { b in
            guard b.status == .finished, let at = b.finishedAt else { return false }
            let d = Notes.date(at)
            return d >= first && d < end
        }
    }

    private func finishedLine(_ b: BookSummary) -> String {
        b.finishedAt.map { Notes.monthDay(Notes.date($0)) + String(localized: "读完") } ?? String(localized: "读完了")
    }

    private var perBook: [(BookSummary, Int, Int)] {
        var sums: [String: (Int, Int)] = [:]
        for t in times {
            sums[t.book, default: (0, 0)].0 += Int(t.readSeconds)
            sums[t.book, default: (0, 0)].1 += Int(t.listenSeconds)
        }
        return sums.compactMap { id, s in library.books.first { $0.id == id }.map { ($0, s.0, s.1) } }
            .sorted { $0.1 + $0.2 > $1.1 + $1.2 }
    }

    /// 5 小时 12 分.
    static func duration(_ seconds: Int) -> String {
        let m = seconds / 60
        if m < 60 { return String(localized: "\(m) 分") }
        return m % 60 == 0 ? String(localized: "\(m / 60) 小时") : String(localized: "\(m / 60) 小时 \(m % 60) 分")
    }
}

// MARK: - 外观

/// 外观 (prototype 外观): light, dark or the system's; 墨蓝 or 墨黑; and a look at both.
struct PhoneAppearance: View {
    @AppStorage(AppAppearance.key) private var mode = AppAppearance.system
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    @AppStorage(LiquidGlass.key) private var liquid = true
    @State private var sample = true
    @Environment(\.colorScheme) private var scheme
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    var body: some View {
        YYPage {
            groupLabel(String(localized: "界面")).padding(.top, YYUI.s(14))
            HStack(spacing: YYUI.s(10)) {
                ForEach(AppAppearance.allCases) { m in modeTile(m) }
            }
            .padding(.bottom, YYUI.s(16))
            groupLabel(String(localized: "主题色"))
            YYGroup {
                ForEach(YYTint.all) { t in
                    Button { tintID = t.id } label: {
                        HStack(spacing: YYUI.s(10)) {
                            Circle().fill(t.black).frame(width: YYUI.s(18), height: YYUI.s(18))
                                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                            Text(t.name).font(YYUI.font(11.5)).foregroundStyle(YYColor.t1)
                            Spacer(minLength: YYUI.s(8))
                            Text(t.id == YYTint.blue.id ? String(localized: "默认") : String(localized: "你确认过的原样")).font(YYUI.font(10.5)).foregroundStyle(YYColor.t3)
                            Image(systemName: "checkmark").font(YYUI.font(11, .bold)).foregroundStyle(tint.accent)
                                .opacity(t.id == tintID ? 1 : 0)
                        }
                        .frame(minHeight: YYUI.s(38))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(t.id == tintID ? .isSelected : [])
                }
            }
            groupLabel(String(localized: "看一眼")).padding(.top, YYUI.s(16))
            preview
            YYNote(String(localized: "书页的颜色在阅读页的 Aa 里换。书页上只有播放键跟着主题色，字、划线和纸色都不动。"))
            if LiquidGlass.supported {
                YYGroup {
                    YYRow(title: String(localized: "液态玻璃效果")) { YYSwitch(isOn: $liquid, label: String(localized: "液态玻璃效果")) }
                }
                .padding(.top, YYUI.s(16))
                YYNote(String(localized: "胶囊、播放条这些浮着的东西用系统的液态玻璃；关掉照原型画：毛玻璃。"))
            }
        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy(duration: 0.2), value: tintID)
    }

    /// `.gl`: the small grey name over a group.
    private func groupLabel(_ text: String) -> some View {
        Text(text).font(YYUI.font(10)).foregroundStyle(YYColor.t3)
            .padding(.horizontal, YYUI.s(4)).padding(.bottom, YYUI.s(6))
    }

    /// `.v-me-mi`: a little page in light, dark, or both split down a slant; the chosen one ringed.
    private func modeTile(_ m: AppAppearance) -> some View {
        let on = m == mode
        let light = (bg: Color(yy: YYRGBA(246, 245, 243)), bar: Color.white, title: Color(yy: YYRGBA(42, 43, 46)).opacity(0.75))
        let dark = (bg: Color(yy: YYRGBA(16, 17, 18)), bar: Color(yy: YYRGBA(27, 28, 30)), title: Color(yy: YYRGBA(237, 237, 238)).opacity(0.75))
        func page(_ c: (bg: Color, bar: Color, title: Color)) -> some View {
            ZStack(alignment: .topLeading) {
                c.bg
                GeometryReader { g in
                    VStack(alignment: .leading, spacing: YYUI.s(5)) {
                        RoundedRectangle(cornerRadius: 3).fill(c.title).frame(width: g.size.width * 0.55, height: YYUI.s(7)).padding(.bottom, YYUI.s(3))
                        RoundedRectangle(cornerRadius: 3).fill(c.bar).frame(height: YYUI.s(9))
                        RoundedRectangle(cornerRadius: 3).fill(c.bar).frame(height: YYUI.s(9))
                    }
                }
                .padding(.top, YYUI.s(13)).padding(.horizontal, YYUI.s(11))
            }
        }
        return Button { mode = m } label: {
            VStack(spacing: YYUI.s(7)) {
                ZStack {
                    switch m {
                    case .light: page(light)
                    case .dark: page(dark)
                    case .system:
                        page(light)
                        page(dark).mask(Slant())
                    }
                }
                .frame(height: YYUI.s(74))
                .clipShape(.rect(cornerRadius: YYUI.s(13)))
                .overlay(RoundedRectangle(cornerRadius: YYUI.s(13)).strokeBorder(YYColor.line, lineWidth: 0.5))
                .padding(on ? YYUI.s(4.5) : 0)
                .overlay {
                    if on {
                        RoundedRectangle(cornerRadius: YYUI.s(13) + YYUI.s(4.5)).strokeBorder(tint.accentSoft, lineWidth: YYUI.s(2.5))
                        RoundedRectangle(cornerRadius: YYUI.s(13) + YYUI.s(2)).strokeBorder(tint.accent, lineWidth: YYUI.s(2)).padding(YYUI.s(2.5))
                    }
                }
                .padding(on ? 0 : YYUI.s(4.5))
                Text(m.title).font(YYUI.font(11, on ? .semibold : .regular)).foregroundStyle(on ? YYColor.t1 : YYColor.t2)
            }
            .padding(.horizontal, -YYUI.s(4.5))
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The dark half of 跟随系统: right of a line leaning 20° off upright.
    private nonisolated struct Slant: Shape {
        func path(in r: CGRect) -> Path {
            let lean = r.height * tan(.pi / 9) / 2
            var p = Path()
            p.move(to: CGPoint(x: r.midX + lean, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.midX - lean, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }

    /// `.v-me-pv`: a book with its progress and 接着读, a switch, the shelf's chips, and the
    /// reading capsule on a page — all in the chosen colour.
    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: YYUI.s(10)) {
                RoundedRectangle(cornerRadius: 3).fill(Color(yy: YYRGBA(205, 196, 180)))
                    .overlay(Text("背影").font(YYUI.font(8, .semibold, design: .serif)).foregroundStyle(Color(yy: YYRGBA(70, 60, 48))).padding(.top, YYUI.s(6)), alignment: .top)
                    .frame(width: YYUI.s(28), height: YYUI.s(42))
                VStack(alignment: .leading, spacing: YYUI.s(3)) {
                    Text("背影").font(YYUI.font(12, .semibold)).foregroundStyle(YYColor.t1)
                    Text("朱自清 · 42%").font(YYUI.font(10)).foregroundStyle(YYColor.t3)
                    GeometryReader { g in
                        Capsule().fill(YYColor.inset)
                        Capsule().fill(tint.fill).frame(width: g.size.width * 0.42)
                    }
                    .frame(height: 3)
                    .padding(.top, YYUI.s(3))
                }
                Text("接着读")
                    .font(YYUI.font(10.5, .semibold)).foregroundStyle(tint.onBlack)
                    .padding(.horizontal, YYUI.s(10)).frame(height: YYUI.s(26))
                    .background(tint.black, in: .capsule)
            }
            .padding(YYUI.s(12))
            Rectangle().fill(YYColor.line).frame(height: 0.5)
            HStack {
                Text("睡前自动停止").font(YYUI.font(11.5)).foregroundStyle(YYColor.t1)
                Spacer()
                Toggle("睡前自动停止", isOn: $sample).labelsHidden().tint(tint.fill)
            }
            .frame(minHeight: YYUI.s(38))
            .padding(.horizontal, YYUI.s(12))
            Rectangle().fill(YYColor.line).frame(height: 0.5)
            HStack(spacing: YYUI.s(6)) {
                ForEach([String(localized: "全部"), String(localized: "书")], id: \.self) { c in
                    let on = c == String(localized: "全部")
                    Text(c).font(YYUI.font(10.5, on ? .semibold : .regular))
                        .foregroundStyle(on ? tint.onBlack : YYColor.t2)
                        .padding(.horizontal, YYUI.s(11)).frame(height: YYUI.s(28))
                        .background(on ? tint.black : YYColor.card, in: .capsule)
                        .shadow(color: on ? .clear : .black.opacity(0.07), radius: 1.5, y: 1)
                }
                Spacer()
            }
            .padding(.vertical, YYUI.s(10))
            .padding(.horizontal, YYUI.s(12))
            pagePreview
        }
        .background(YYColor.card, in: .rect(cornerRadius: YYUI.s(14)))
        .clipShape(.rect(cornerRadius: YYUI.s(14)))
        .overlay(RoundedRectangle(cornerRadius: YYUI.s(14)).strokeBorder(YYColor.line, lineWidth: 0.5))
        .allowsHitTesting(true)
    }

    /// `.v-me-pvp`: the reading capsule on a plain page; only its play button takes the colour.
    private var pagePreview: some View {
        let paper = scheme == .dark ? YYPaper.dark : YYPaper.plain
        return ZStack(alignment: .bottom) {
            paper.bg
            HStack(spacing: YYUI.s(4)) {
                Image(systemName: "list.bullet").font(YYUI.font(11, .semibold)).frame(width: YYUI.s(26))
                VStack(alignment: .leading, spacing: 1) {
                    Text("第 2 / 24 句").font(YYUI.font(10, .semibold))
                    Text("42% · 本章还剩 6 分钟").font(YYUI.font(8.5)).foregroundStyle(paper.ink2)
                }
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "pause.fill").font(YYUI.font(10, .semibold)).foregroundStyle(paper.onMain)
                    .frame(width: YYUI.s(30), height: YYUI.s(30))
                    .background(tint.play(on: paper), in: .circle)
                Text("Aa").font(YYUI.font(11, .semibold)).frame(width: YYUI.s(28))
            }
            .foregroundStyle(paper.ink)
            .padding(.horizontal, YYUI.s(5))
            .frame(height: YYUI.s(40))
            .background(paper.glass, in: .capsule)
            .overlay(Capsule().stroke(paper.line, lineWidth: 0.5))
            .shadow(color: .black.opacity(paper.isDark ? 0.4 : 0.1), radius: 8, y: 3)
            .padding(.horizontal, YYUI.s(10))
            .padding(.bottom, YYUI.s(9))
        }
        .frame(height: YYUI.s(66))
        .overlay(alignment: .top) { Rectangle().fill(YYColor.line).frame(height: 0.5) }
        .accessibilityHidden(true)
    }
}

// MARK: - 朗读

/// 朗读: how fast, and which of the system's voices reads each language.
struct PhoneListening: View {
    @AppStorage("player.rate") private var rate = 1.0

    private static let languages = [("zh", String(localized: "中文"), String(localized: "从前有一座山，山里有一座庙。")),
                                    ("en", String(localized: "英文"), "It was the best of times, it was the worst of times.")]

    var body: some View {
        YYPage {
            YYGroup {
                HStack(spacing: YYUI.s(10)) {
                    Text("语速").font(YYUI.font(11.5)).foregroundStyle(YYColor.t1)
                    Slider(value: Binding(get: { rate == 0 ? 1 : rate }, set: { rate = ($0 * 10).rounded() / 10 }), in: 0.8 ... 2.0)
                        .tint(YYTint.standard.fill)
                        .accessibilityLabel(Text("语速"))
                        .accessibilityValue(Text(String(format: "%.1f×", rate == 0 ? 1 : rate)))
                    Text(String(format: "%.1f×", rate == 0 ? 1 : rate)).font(YYUI.font(10.5, .medium).monospacedDigit()).foregroundStyle(YYColor.t2)
                        .frame(width: YYUI.s(30), alignment: .trailing)
                }
                .frame(minHeight: YYUI.s(38))
            }
            .padding(.top, YYUI.s(12))
            YYNote(String(localized: "读书时在听书面板里调的也是这一个。"))
            ForEach(Self.languages, id: \.0) { tag, name, sample in
                PhoneVoiceSection(tag: tag, name: name, sample: sample)
            }
            YYNote(String(localized: "系统声音在这台设备上合成，不联网。想要更自然的声音：设置 › 辅助功能 › 朗读内容 › 声音，下载“高级”的那几个。"))
            YYLabel(String(localized: "云端声音"))
            YYGroup {
                ForEach(CloudVoice.Provider.allCases) { p in
                    NavigationLink { PhoneCloudVoice(provider: p) } label: {
                        YYRow(p.title, icon: "cloud", value: p.isSetUp ? String(localized: "已连上") : String(localized: "填 Key"), chevron: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            YYNote(String(localized: "填你自己的 Key，费用直接走你的账号，语阅不经手。读过的句子存在这台设备上，再听不花钱，断网也能听；听书时会把这一章提前合成好。"))
        }
        .navigationTitle("朗读")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 云端声音: one provider's key (and Azure's region); 连接 checks it and fetches the voices.
private struct PhoneCloudVoice: View {
    let provider: CloudVoice.Provider
    @State private var key = ""
    @AppStorage(CloudVoice.Provider.regionName) private var region = ""
    @State private var checking = false
    @State private var outcome: String?
    @State private var failed = false

    var body: some View {
        YYPage {
            YYGroup {
                YYField(label: "Key", labelWidth: 44) {
                    SecureField("", text: $key, prompt: Text(provider.keyHint))
                        .font(YYUI.font(11.5, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if provider == .azure {
                    YYField(label: String(localized: "区域"), labelWidth: 44) {
                        TextField("", text: $region, prompt: Text(verbatim: "eastasia"))
                            .font(YYUI.font(11.5, design: .monospaced))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
            }
            .foregroundStyle(YYColor.t1)
            .padding(.top, YYUI.s(10))
            YYNote(outcome ?? provider.help)
                .foregroundStyle(failed ? YYColor.danger : YYColor.t3)
            Button {
                connect()
            } label: {
                if checking { ProgressView() } else { Text(key.isEmpty ? String(localized: "清掉") : String(localized: "连接")) }
            }
            .buttonStyle(YYButtonStyle(kind: .main, size: .large, wide: true))
            .disabled(checking)
            .padding(.top, YYUI.s(18))
        }
        .navigationTitle(provider.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { key = Keychain.read(provider.keyName) ?? "" }
    }

    private func connect() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        region = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else {
            Keychain.delete(provider.keyName)
            outcome = nil
            return
        }
        Keychain.write(provider.keyName, k)
        checking = true
        Task {
            defer { checking = false }
            do {
                let n = try await CloudVoice.refresh(provider)
                failed = false
                outcome = String(localized: "已连上 · \(n) 个声音")
            } catch {
                failed = true
                outcome = error.localizedDescription
            }
        }
    }
}

private struct PhoneVoiceSection: View {
    let tag: String
    let name: String
    let sample: String
    @State private var chosen: String?

    private var key: String { "player.voice." + tag }

    var body: some View {
        let voices = Voices.all(for: tag)
        let current = voices.first { $0.id == chosen } ?? SystemVoice.best(for: tag) ?? voices.first
        VStack(alignment: .leading, spacing: 0) {
            YYLabel(name, voices.isEmpty ? nil : String(localized: "\(voices.count) 个声音"))
            YYGroup {
                if voices.isEmpty {
                    YYRow(String(localized: "这台设备上没有这种语言的声音"))
                }
                ForEach(voices, id: \.id) { v in
                    HStack(spacing: YYUI.s(10)) {
                        Button {
                            chosen = v.id
                            UserDefaults.standard.set(v.id, forKey: key)
                        } label: {
                            HStack(spacing: YYUI.s(8)) {
                                Text(v.name).font(YYUI.font(11.5)).foregroundStyle(YYColor.t1).lineLimit(1)
                                if let q = v.qualityName { YYTag(text: q) }
                                Spacer(minLength: 0)
                                if v.id == current?.id {
                                    Image(systemName: "checkmark").font(YYUI.font(11, .bold)).foregroundStyle(YYTint.standard.accent)
                                }
                            }
                            .frame(minHeight: YYUI.s(38))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        Button { Voices.preview(v, text: sample) } label: {
                            Image(systemName: "play.fill").font(YYUI.font(9)).foregroundStyle(YYColor.t1)
                                .frame(width: YYUI.s(24), height: YYUI.s(24))
                                .background(YYColor.inset, in: .circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("试听 \(v.name)")
                    }
                }
            }
        }
        .onAppear { chosen = UserDefaults.standard.string(forKey: key) }
    }
}

// MARK: - 外文阅读

/// 外文阅读 (prototype 外文阅读设置): saying a word aloud, 难词注释, the 生词 marks, and the
/// system's offline translation.
struct PhoneForeign: View {
    let library: Library
    @AppStorage(ForeignPrefs.speakKey) private var speak = true
    @AppStorage(ForeignPrefs.accentKey) private var accent = ForeignPrefs.Accent.british
    @AppStorage(ForeignPrefs.markKey) private var mark = true
    @AppStorage(ForeignPrefs.glossKey) private var gloss = true
    @AppStorage(ForeignPrefs.levelKey) private var level = 3
    @AppStorage(ForeignPrefs.glossVocabKey) private var glossVocab = false
    @State private var status: LanguageAvailability.Status?
    @State private var download: TranslationSession.Configuration?
    @State private var failed: String?

    var body: some View {
        YYPage {
            groupLabel(String(localized: "点词")).padding(.top, YYUI.s(12))
            YYGroup {
                YYRow(title: String(localized: "点词时读出来")) { YYSwitch(isOn: $speak, label: String(localized: "点词时读出来")) }
                YYRow(title: String(localized: "发音")) {
                    YYSegments(items: [(ForeignPrefs.Accent.british, String(localized: "英音")), (ForeignPrefs.Accent.american, String(localized: "美音"))], selection: $accent, small: true)
                        .frame(width: YYUI.s(110))
                }
            }
            .padding(.bottom, YYUI.s(14))
            groupLabel(String(localized: "MDict 词典"))
            PhoneMDictList(core: library.core)
            YYNote(String(localized: "点词先查这里导入的词典，查不到再用系统翻译。左滑一本可以移除。"))
                .padding(.bottom, YYUI.s(14))
            groupLabel(String(localized: "难词注释"))
            YYGroup {
                YYRow(title: String(localized: "在难词上方写释义")) { YYSwitch(isOn: $gloss, label: String(localized: "在难词上方写释义")) }
                YYRow(title: String(localized: "级别")) {
                    YYSegments(items: ForeignPrefs.levels.map { (Int($0.level), $0.name) }, selection: $level, small: true)
                        .frame(width: YYUI.s(200))
                        .disabled(!gloss || glossVocab)
                        .opacity(!gloss || glossVocab ? 0.5 : 1)
                }
                YYRow(title: String(localized: "只标生词本里的词")) { YYSwitch(isOn: $glossVocab, label: String(localized: "只标生词本里的词")).disabled(!gloss) }
                glossPreview
            }
            .padding(.bottom, YYUI.s(14))
            groupLabel(String(localized: "生词"))
            YYGroup {
                HStack(spacing: YYUI.s(10)) {
                    VStack(alignment: .leading, spacing: YYUI.s(3)) {
                        Text("在所有书里标出来").font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1)
                        Text("…this truth is so well \(Text("fixed").foregroundStyle(YYColor.t1).underline(mark, pattern: .dot, color: YYTint.standard.accent)) in the minds…")
                            .font(.custom("Georgia", size: YYUI.s(11)))
                            .foregroundStyle(YYColor.t2)
                    }
                    Spacer(minLength: 0)
                    YYSwitch(isOn: $mark, label: String(localized: "在所有书里标出来"))
                }
                .padding(.vertical, YYUI.s(8))
            }
            YYNote(String(localized: "生词本里在学的词，在任何一本书里再遇到，都用虚线标出来；掌握了就不再标。"))
                .padding(.bottom, YYUI.s(14))
            groupLabel(String(localized: "翻译"))
            YYGroup {
                HStack(spacing: YYUI.s(10)) {
                    VStack(alignment: .leading, spacing: YYUI.s(1)) {
                        Text("系统离线翻译").font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1)
                        Text("免费、不限量，在这台设备上翻").font(YYUI.font(10)).foregroundStyle(YYColor.t3)
                    }
                    Spacer(minLength: 0)
                    translationState
                }
                .padding(.vertical, YYUI.s(8))
                if let failed {
                    Label(failed, systemImage: "exclamationmark.circle").font(YYUI.font(10.5)).foregroundStyle(YYColor.danger)
                        .frame(minHeight: YYUI.s(34))
                }
            }
            YYNote(String(localized: "原文不出这台设备。"))
        }
        .navigationTitle("外文阅读")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: "\(gloss)\(level)\(glossVocab)\(mark)") { NotificationCenter.default.post(name: .vocabChanged, object: nil) }
        .task { await check() }
        .translationTask(download) { session in
            nonisolated(unsafe) let session = session
            do {
                try await session.prepareTranslation()
                failed = nil
            } catch {
                failed = Translator.message(for: error)
            }
            download = nil
            await check()
        }
    }

    /// `.gl`: the small grey name over a group.
    private func groupLabel(_ text: String) -> some View {
        Text(text).font(YYUI.font(10)).foregroundStyle(YYColor.t3)
            .padding(.horizontal, YYUI.s(4)).padding(.bottom, YYUI.s(6))
    }

    /// `.v-fx-pv`: a line of Austen with the gloss over the hard word, changing as the settings do.
    private var glossPreview: some View {
        VStack(alignment: .leading, spacing: YYUI.s(4)) {
            Text("预览").font(YYUI.font(10)).foregroundStyle(YYColor.t3).padding(.top, YYUI.s(6))
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                Text(verbatim: "It is a truth universally ")
                VStack(spacing: 0) {
                    Text(verbatim: "公认").font(YYUI.font(9.5)).foregroundStyle(YYTint.standard.accent)
                        .opacity(gloss && !glossVocab && level <= 4 ? 1 : 0)
                    Text(verbatim: "acknowledged")
                }
                Text(verbatim: ", that a…")
            }
            .font(.custom("Georgia", size: YYUI.s(12)))
            .foregroundStyle(YYColor.t1)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.bottom, YYUI.s(6))
        }
        .animation(.snappy(duration: 0.2), value: "\(gloss)\(level)\(glossVocab)")
    }

    @ViewBuilder private var translationState: some View {
        switch status {
        case .installed?:
            Image(systemName: "checkmark").font(YYUI.font(11, .bold)).foregroundStyle(YYTint.standard.accent)
                .accessibilityLabel("英文 → 中文 已下载")
        case .supported?:
            Button("下载英文 → 中文") {
                download = .init(source: Locale.Language(identifier: "en"), target: Translator.target)
            }
            .buttonStyle(YYButtonStyle(kind: .soft, size: .small))
            .disabled(download != nil)
        case .unsupported?:
            Text("这台设备不支持").font(YYUI.font(10.5)).foregroundStyle(YYColor.t3)
        default:
            ProgressView().controlSize(.small)
        }
    }

    private func check() async {
        status = await LanguageAvailability().status(from: Locale.Language(identifier: "en"), to: Translator.target)
    }
}

// MARK: - 引擎

/// 引擎 (prototype 引擎): who answers as 书伴, which voice reads, what translates. The device's own
/// by default; or the user's own key, kept in the keychain.
struct PhoneEngines: View {
    let library: Library
    @State private var choice = CompanionChoice()
    @State private var sheet: CompanionProviderSheet.Start?
    @State private var cached: Int64 = 0
    private let tint = YYTint.standard

    var body: some View {
        YYPage {
            Text("书伴、朗读、翻译用的引擎都在这里。全部免费，没有会员；用设备自带的，或者填你自己的 Key。")
                .font(YYUI.font(11)).lineSpacing(YYUI.s(11) * 0.7).foregroundStyle(YYColor.t2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, YYUI.s(4)).padding(.top, YYUI.s(12)).padding(.bottom, YYUI.s(16))
            groupLabel(String(localized: "书伴"), spark: true)
            YYGroup {
                YYRow(title: String(localized: "服务商")) { providerMenu }
                if choice.current.provider.kind != .apple {
                    YYField(label: String(localized: "模型"), labelWidth: 52) { modelField }
                }
                YYRow(title: String(localized: "测试一下"), value: testDetail) {
                    if choice.testing { ProgressView().controlSize(.small) }
                    Button("测试") { choice.test() }
                        .buttonStyle(YYButtonStyle(kind: .plain, size: .small))
                        .disabled(!choice.current.isReady || choice.testing)
                }
                Button { sheet = .manage } label: { YYRow(String(localized: "管理服务商"), chevron: true) }
                    .buttonStyle(.plain)
            }
            .padding(.bottom, YYUI.s(14))
            groupLabel(String(localized: "朗读"))
            YYGroup {
                NavigationLink { PhoneListening() } label: { inUse(String(localized: "系统语音"), String(localized: "在这台设备上，不联网")) }
                    .buttonStyle(.plain)
            }
            .padding(.bottom, YYUI.s(14))
            groupLabel(String(localized: "翻译"))
            YYGroup {
                NavigationLink { PhoneForeign(library: library) } label: { inUse(String(localized: "系统翻译"), String(localized: "离线，不限量")) }
                    .buttonStyle(.plain)
            }
            .padding(.bottom, YYUI.s(14))
            YYGroup {
                YYRow(title: String(localized: "书伴存下的回答"), value: ByteCountFormatter.string(fromByteCount: cached, countStyle: .file)) {
                    Button("清掉") {
                        try? FileManager.default.removeItem(at: cacheDir)
                        measure()
                    }
                    .buttonStyle(YYButtonStyle(kind: .plain, size: .small))
                    .disabled(cached == 0)
                }
            }
            YYNote(String(localized: "Key 只存在这台设备的钥匙串里，不同步、不上传。书伴的回答按“书 + 章节”存下，问过的不再花钱。"))
        }
        .navigationTitle("引擎")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: measure)
        .sheet(item: $sheet, onDismiss: choice.reload) { CompanionProviderSheet(start: $0) }
        .task { await choice.list() }
    }

    /// nanobot's ProviderPicker: those to choose from, a line, 配置 the one in use, 添加服务商.
    private var providerMenu: some View {
        Menu {
            ForEach(choice.options) { p in
                Button { choice.choose(p) } label: {
                    if choice.current.provider == p { Label(p.title, systemImage: "checkmark") } else { Text(p.title) }
                }
            }
            if !choice.options.isEmpty { Divider() }
            if choice.current.provider.kind != .apple {
                Button("配置 \(choice.current.provider.title)…", systemImage: "pencil") { sheet = .edit(choice.current.provider) }
            }
            Button("添加服务商…", systemImage: "plus") { sheet = .add }
        } label: {
            HStack(spacing: YYUI.s(6)) {
                if choice.options.isEmpty {
                    Text("添加服务商…").foregroundStyle(tint.accent)
                } else {
                    ProviderLogo(provider: choice.current.provider, size: 18)
                    Text(choice.current.provider.title).foregroundStyle(YYColor.t1)
                }
                Image(systemName: "chevron.up.chevron.down").font(YYUI.font(8.5, .semibold)).foregroundStyle(YYColor.t3)
            }
            .font(YYUI.font(11.5))
        }
    }

    /// Typed, or one of those the service lists.
    private var modelField: some View {
        HStack(spacing: YYUI.s(6)) {
            TextField("", text: Bindable(choice).model, prompt: Text(choice.current.provider.modelHint))
                .font(YYUI.font(10.5, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(YYColor.t1)
            if choice.listing { ProgressView().controlSize(.small) }
            Menu {
                ForEach(choice.models, id: \.self) { m in Button(m) { choice.model = m } }
            } label: {
                Image(systemName: "chevron.down.circle").font(YYUI.font(13)).foregroundStyle(YYColor.t3)
            }
            .disabled(choice.models.isEmpty)
            .accessibilityLabel(Text("它列出的模型"))
        }
    }

    private var testDetail: String? {
        switch choice.result {
        case .success(let t): String(localized: "能用 · 回答用了 \(t.formatted(.number.precision(.fractionLength(1)))) 秒")
        case .failure(let e): Companion.message(for: e)
        case nil: choice.current.isReady ? nil : choice.current.provider.kind == .apple ? Companion.appleAvailability : String(localized: "还没选好模型")
        }
    }

    /// `.gl`, with 书伴's spark in front.
    private func groupLabel(_ text: String, spark: Bool = false) -> some View {
        HStack(spacing: YYUI.s(4)) {
            if spark { Image(systemName: "sparkle").font(YYUI.font(9.5, .semibold)).foregroundStyle(tint.accent) }
            Text(text)
        }
        .font(YYUI.font(10)).foregroundStyle(YYColor.t3)
        .padding(.horizontal, YYUI.s(4)).padding(.bottom, YYUI.s(6))
    }

    /// `.v-r2` in `.v-me-eng`: the engine in use, a grey line, the tick.
    private func inUse(_ title: String, _ detail: String) -> some View {
        HStack(spacing: YYUI.s(10)) {
            VStack(alignment: .leading, spacing: YYUI.s(1)) {
                Text(title).font(YYUI.font(11.5)).foregroundStyle(YYColor.t1)
                Text(detail).font(YYUI.font(10)).foregroundStyle(YYColor.t3)
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark").font(YYUI.font(11, .bold)).foregroundStyle(tint.accent)
        }
        .padding(.vertical, YYUI.s(8))
        .contentShape(.rect)
    }

    private var cacheDir: URL { library.dataDir.appending(path: "companion", directoryHint: .isDirectory) }

    private func measure() {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        cached = files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

}

// MARK: - 同步

/// 同步 (prototype 同步): how it is going and each device's last book on top, the three ways in the
/// middle, what goes along below.
struct PhoneSync: View {
    let library: Library
    @State private var picking = false
    @State private var signingIn = false
    @State private var problem: String?
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    private let tint = YYTint.standard

    private var sync: Sync { library.sync }

    var body: some View {
        YYPage {
            statusCard.padding(.top, YYUI.s(10)).padding(.bottom, YYUI.s(10))
            ConflictsBanner(library: library, spacing: YYUI.s(10))
            groupLabel(String(localized: "同步方式")).padding(.top, YYUI.s(8))
            YYGroup {
                method(.icloud, "icloud", "iCloud", sync.method == .icloud && sync.isOn ? String(localized: "iCloud 云盘里你选的文件夹") : String(localized: "苹果设备之间，选 iCloud 云盘里一个文件夹"))
                NavigationLink { PhoneWebDAV(sync: sync) } label: {
                    methodLabel(.webdav, "server.rack", "WebDAV",
                                sync.method == .webdav ? (sync.webdav.map { $0.url.host() ?? $0.url.absoluteString } ?? "") : String(localized: "坚果云、群晖、Nextcloud…"))
                }
                .buttonStyle(.plain)
                method(.googleDrive, "globe", "Google Drive",
                       GoogleAuth.clientID == nil ? String(localized: "有 Android 设备时用 · 还没开通") : sync.method == .googleDrive ? (sync.googleEmail ?? String(localized: "已登录")) : String(localized: "用你自己的 Google 账号"))
                    .disabled(GoogleAuth.clientID == nil || signingIn)
                if signingIn {
                    HStack(spacing: YYUI.s(8)) {
                        ProgressView().controlSize(.small)
                        Text("在弹出的页面里登录 Google…").font(YYUI.font(11)).foregroundStyle(YYColor.t2)
                    }
                    .frame(minHeight: YYUI.s(38))
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle").font(YYUI.font(11)).foregroundStyle(YYColor.danger)
                        .frame(minHeight: YYUI.s(38))
                }
            }
            .padding(.bottom, YYUI.s(14))
            groupLabel(String(localized: "同步这些"))
            YYGroup {
                included(String(localized: "进度和书签"), .reading)
                included(String(localized: "笔记和生词"), .notes)
                included(String(localized: "设置和替换规则"), .settings)
                YYRow(title: String(localized: "书文件"), value: String(localized: "只在 Wi-Fi 下")) {
                    YYSwitch(isOn: Binding(get: { sync.syncsFiles }, set: { sync.syncFiles($0) }), label: String(localized: "书文件"))
                }
            }
            .padding(.bottom, YYUI.s(14))
            if sync.isOn {
                YYGroup {
                    Button { sync.stop() } label: {
                        Text("停止同步").font(YYUI.font(11.5)).foregroundStyle(YYColor.danger)
                            .frame(maxWidth: .infinity, minHeight: YYUI.s(38), alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, YYUI.s(14))
            }
            HStack(alignment: .firstTextBaseline, spacing: YYUI.s(5)) {
                Image(systemName: "lock").font(YYUI.font(9.5))
                Text("不用注册账号，数据只在你的设备和你自己的网盘之间走。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(YYUI.font(10))
            .foregroundStyle(YYColor.t3)
            .padding(.horizontal, YYUI.s(4))
        }
        .navigationTitle("同步")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { sync.loadDevices() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            do { try sync.choose(folder: url) } catch { library.alert = Library.message(for: error) }
        }
    }

    /// `.v-sy-st`: how it went and when, 立即同步, then every device and how long since it synced.
    /// Red when it failed; for WebDAV a tap goes to the connection check.
    private var statusCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: YYUI.s(10)) {
                statusIcon
                VStack(alignment: .leading, spacing: YYUI.s(2)) {
                    Text(headline).font(YYUI.font(14, .bold)).foregroundStyle(failed ? YYColor.danger : YYColor.t1)
                    Text(subline).font(YYUI.font(10).monospacedDigit()).foregroundStyle(YYColor.t3).lineLimit(2)
                }
                Spacer(minLength: 0)
                if sync.isOn {
                    if failed, sync.method == .webdav {
                        NavigationLink { PhoneWebDAV(sync: sync, checkNow: true) } label: { Text("查一查") }
                            .buttonStyle(YYButtonStyle(kind: .plain, size: .small))
                    } else {
                        Button("立即同步") { sync.now() }
                            .buttonStyle(YYButtonStyle(kind: .plain, size: .small))
                            .disabled(sync.state == .syncing)
                    }
                }
            }
            if !sync.devices.isEmpty {
                VStack(spacing: 0) {
                    ForEach(sync.devices, id: \.id) { d in
                        Rectangle().fill(YYColor.line).frame(height: 0.5)
                        HStack(spacing: YYUI.s(9)) {
                            Image(systemName: Self.symbol(d.platform)).font(YYUI.font(12)).foregroundStyle(YYColor.t2).frame(width: YYUI.s(14))
                            Text(d.thisDevice ? String(localized: "这台 \(d.name.isEmpty ? String(localized: "设备") : d.name)") : (d.name.isEmpty ? String(localized: "设备") : d.name))
                                .font(YYUI.font(11)).foregroundStyle(YYColor.t1).lineLimit(1)
                            Spacer(minLength: YYUI.s(8))
                            Text(detail(of: d)).font(YYUI.font(10).monospacedDigit()).foregroundStyle(YYColor.t3).lineLimit(1)
                        }
                        .frame(height: YYUI.s(34))
                    }
                }
                .padding(.top, YYUI.s(12))
            }
        }
        .padding(.top, YYUI.s(14))
        .padding(.bottom, YYUI.s(sync.devices.isEmpty ? 14 : 2))
        .padding(.horizontal, YYUI.s(14))
        .yyCard()
    }

    private var failed: Bool {
        if case .failed = sync.state { return true }
        return false
    }

    /// `.gl`: the small grey name over a group.
    private func groupLabel(_ text: String) -> some View {
        Text(text).font(YYUI.font(10)).foregroundStyle(YYColor.t3)
            .padding(.horizontal, YYUI.s(4)).padding(.bottom, YYUI.s(6))
    }

    private func included(_ title: String, _ part: SyncPart) -> some View {
        YYRow(title: title) {
            YYSwitch(isOn: Binding(get: { sync.includes(part) }, set: { sync.include(part, $0) }), label: title)
        }
    }

    private func method(_ m: Sync.Method, _ symbol: String, _ title: String, _ detail: String) -> some View {
        Button { pick(m) } label: { methodLabel(m, symbol, title, detail) }
            .buttonStyle(.plain)
    }

    /// `.v-r2` in `.v-sy-way`: a small icon tile, the name and a grey line, a tick on the one in use.
    private func methodLabel(_ m: Sync.Method, _ symbol: String, _ title: String, _ detail: String) -> some View {
        let on = sync.method == m && sync.isOn
        return HStack(spacing: YYUI.s(10)) {
            Image(systemName: symbol)
                .font(YYUI.font(12, .medium))
                .foregroundStyle(on ? tint.accent : YYColor.t1)
                .frame(width: YYUI.s(26), height: YYUI.s(26))
                .background(on ? tint.accentSoft : YYColor.inset, in: .rect(cornerRadius: YYUI.s(7)))
            VStack(alignment: .leading, spacing: YYUI.s(1)) {
                Text(title).font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1)
                Text(detail).font(YYUI.font(10)).foregroundStyle(YYColor.t3).lineLimit(1)
            }
            Spacer(minLength: 0)
            if on { Image(systemName: "checkmark").font(YYUI.font(11, .bold)).foregroundStyle(tint.accent) }
        }
        .padding(.vertical, YYUI.s(8))
        .contentShape(.rect)
    }

    private func pick(_ m: Sync.Method) {
        switch m {
        case .icloud:
            picking = true
        case .googleDrive:
            guard !signingIn else { return }
            signingIn = true
            problem = nil
            Task {
                do {
                    try await sync.connectGoogle { url, scheme in
                        try await webAuthenticationSession.authenticate(using: url, callback: .customScheme(scheme), additionalHeaderFields: [:])
                    }
                } catch {
                    problem = Sync.message(for: error)
                }
                signingIn = false
            }
        default:
            break
        }
    }

    /// `.v-sy-bdg`: a tick on green, a turning arrow, or ! on red.
    @ViewBuilder private var statusIcon: some View {
        let (symbol, color): (String, Color) = switch sync.state {
        case .syncing: ("arrow.triangle.2.circlepath", tint.accent)
        case .failed: ("exclamationmark", YYColor.danger)
        case .idle: sync.isOn ? ("checkmark", YYColor.ok) : ("icloud.slash", YYColor.t3)
        }
        Image(systemName: symbol)
            .font(YYUI.font(12, .bold))
            .foregroundStyle(color)
            .symbolEffect(.rotate, isActive: sync.state == .syncing)
            .frame(width: YYUI.s(32), height: YYUI.s(32))
            .background(color.opacity(0.14), in: .circle)
    }

    private var headline: String {
        switch sync.state {
        case .syncing: return String(localized: "正在同步…")
        case .failed: return String(localized: "没同步上")
        case .idle: return sync.isOn ? (sync.lastSynced == nil ? String(localized: "已连上") : String(localized: "已同步")) : String(localized: "还没开同步")
        }
    }

    /// "2 分钟前 · iCloud", or why it failed.
    private var subline: String {
        if case .failed(let why) = sync.state { return why }
        guard sync.isOn else { return String(localized: "下面选一种方式，进度、笔记和设置就在你的设备之间同步") }
        let place = switch sync.method {
        case .webdav: "WebDAV"
        case .googleDrive: "Google Drive"
        default: "iCloud"
        }
        return [sync.lastSynced.map(Self.ago), place].compactMap { $0 }.joined(separator: " · ")
    }

    private func detail(of d: DeviceInfo) -> String {
        if d.thisDevice { return String(localized: "刚刚") }
        guard let at = d.lastAt else { return String(localized: "还没同步过") }
        return Self.ago(Date(timeIntervalSince1970: Double(at) / 1000))
    }

    static func ago(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return String(localized: "刚刚") }
        if s < 3600 { return String(localized: "\(Int(s / 60)) 分钟前") }
        if Calendar.current.isDateInToday(date) { return String(localized: "今天 ") + date.formatted(.dateTime.hour().minute()) }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "昨天 ") + date.formatted(.dateTime.hour().minute()) }
        return date.formatted(.dateTime.month().day())
    }

    private static func symbol(_ platform: String) -> String {
        switch platform {
        case "ios": "iphone"
        case "ipados": "ipad"
        case "android": "smartphone"
        default: "laptopcomputer"
        }
    }
}

/// WebDAV (prototype 连接诊断): 地址, 账号, 密码, 文件夹; 连接 runs the check step by step and
/// keeps the account once every step passes.
private struct PhoneWebDAV: View {
    let sync: Sync
    /// Opened from a failed sync: check straight away.
    var checkNow = false
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var user = ""
    @State private var password = ""
    @State private var folder = String(localized: "语阅")
    @State private var showPassword = false
    @State private var check: WebDAVCheck?
    @State private var checking = false

    private var account: Sync.WebDAVAccount? {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)), u.scheme?.hasPrefix("http") == true, u.host() != nil else { return nil }
        return Sync.WebDAVAccount(url: u, user: user.trimmingCharacters(in: .whitespaces), password: password,
                                  folder: folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")))
    }

    var body: some View {
        YYPage {
            YYGroup {
                YYField(label: String(localized: "地址"), labelWidth: 44) {
                    TextField("", text: $url, prompt: Text("https://dav.jianguoyun.com/dav/"))
                        .font(YYUI.font(11, design: .monospaced))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                YYField(label: String(localized: "账号"), labelWidth: 44) {
                    TextField("", text: $user, prompt: Text("邮箱或用户名"))
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                YYField(label: String(localized: "密码"), labelWidth: 44) {
                    HStack(spacing: YYUI.s(8)) {
                        Group {
                            if showPassword {
                                TextField("", text: $password).textInputAutocapitalization(.never).autocorrectionDisabled()
                            } else {
                                SecureField("", text: $password, prompt: Text("坚果云填应用密码"))
                            }
                        }
                        .font(YYUI.font(11.5, design: .monospaced))
                        Button { showPassword.toggle() } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye").font(YYUI.font(12)).foregroundStyle(YYColor.t3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showPassword ? String(localized: "藏起密码") : String(localized: "显示密码"))
                    }
                }
                YYField(label: String(localized: "文件夹"), labelWidth: 44) {
                    HStack(spacing: 0) {
                        Text("/").foregroundStyle(YYColor.t3)
                        TextField("", text: $folder).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
            }
            .foregroundStyle(YYColor.t1)
            .padding(.top, YYUI.s(10))
            if let check {
                YYLabel(String(localized: "连接检查"), check.summary).padding(.top, -YYUI.s(4))
                WebDAVCheckCard(check: check)
            } else {
                YYNote(String(localized: "密码存在这台设备的钥匙串里。点连接会一项一项查：服务器、证书、账号密码、文件夹读写。"))
            }
            Button(buttonTitle) {
                if check?.passed == true { dismiss() } else { run() }
            }
            .buttonStyle(YYButtonStyle(kind: .main, size: .large, wide: true))
            .disabled(account == nil || checking)
            .padding(.top, YYUI.s(18))
        }
        .navigationTitle("WebDAV")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let a = sync.webdav {
                url = a.url.absoluteString
                user = a.user
                password = a.password
                folder = a.folder
                if checkNow, check == nil { run() }
            }
        }
        .onChange(of: [url, user, password, folder]) { if !checking, check?.passed == true { check = nil } }
    }

    private var buttonTitle: String {
        if checking { return String(localized: "正在检查…") }
        guard let check else { return sync.method == .webdav ? String(localized: "重新连接") : String(localized: "连接") }
        return check.passed ? String(localized: "好了") : String(localized: "重试")
    }

    private func run() {
        guard let account else { return }
        checking = true
        Task {
            let result = await WebDAVCheck.run(account) { check = $0 }
            check = result
            checking = false
            if result.passed { sync.keep(account) }
        }
    }
}

// MARK: - 存储空间

/// 存储空间: what 语阅 takes, the books deleted (kept 30 days), and each book from the largest.
struct PhoneStorage: View {
    let library: Library
    @State private var usage: StorageUsage?
    @State private var cleaning = false
    private let tint = YYTint.standard

    @State private var info: BookSummary?

    var body: some View {
        YYPage {
            useCard.padding(.top, YYUI.s(10)).padding(.bottom, YYUI.s(14))
            YYGroup {
                HStack(spacing: YYUI.s(10)) {
                    VStack(alignment: .leading, spacing: YYUI.s(1)) {
                        Text("已删除的书 · \(usage?.deleted.count ?? 0) 本 · \(Self.size(usage?.deletedBytes ?? 0))")
                            .font(YYUI.font(11.5, .medium).monospacedDigit()).foregroundStyle(YYColor.t1)
                        Text("留 30 天可以撤销，过了自动清掉").font(YYUI.font(10)).foregroundStyle(YYColor.t3)
                    }
                    Spacer(minLength: 0)
                    Button("现在清掉") { purge() }
                        .buttonStyle(YYButtonStyle(kind: .danger, size: .small))
                        .disabled((usage?.deleted.isEmpty ?? true) || cleaning)
                }
                .padding(.vertical, YYUI.s(9))
            }
            if let usage, !usage.books.isEmpty {
                YYLabel(String(localized: "每本书"), String(localized: "从大到小"))
                YYGroup {
                    ForEach(usage.books.prefix(30), id: \.id) { b in bookRow(b) }
                }
            }
        }
        .navigationTitle("存储空间")
        .navigationBarTitleDisplayMode(.inline)
        .task { await measure() }
        .sheet(item: $info) { PhoneBookInfo(library: library, book: $0) }
    }

    /// `.v-sy-use`: the total, what is left on the device, one bar split by kind and its legend.
    private var useCard: some View {
        let parts = parts
        let total = max(1, parts.reduce(0) { $0 + $1.1 })
        return VStack(alignment: .leading, spacing: 0) {
            Text("语阅一共用了").font(YYUI.font(10.5)).foregroundStyle(YYColor.t3)
            HStack(alignment: .firstTextBaseline, spacing: YYUI.s(3)) {
                let (number, unit) = Self.split(usage?.total ?? 0)
                Text(usage == nil ? "…" : number).font(YYUI.font(26, .bold).monospacedDigit()).foregroundStyle(YYColor.t1)
                Text(usage == nil ? "" : unit).font(YYUI.font(12, .semibold)).foregroundStyle(YYColor.t1)
                Spacer(minLength: YYUI.s(8))
                if let free = usage?.free {
                    Text("这台 \(UIDevice.current.model) 还剩 \(Self.size(free))").font(YYUI.font(10).monospacedDigit()).foregroundStyle(YYColor.t3)
                }
            }
            .padding(.top, 1)
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(Array(parts.enumerated()).filter { $0.element.1 > 0 }, id: \.offset) { i, p in
                        Rectangle().fill(shade(i)).frame(width: max(3, (g.size.width - 6) * Double(p.1) / Double(total)))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: YYUI.s(10))
            .clipShape(.rect(cornerRadius: YYUI.s(5)))
            .padding(.top, YYUI.s(10))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: YYUI.s(16)), GridItem(.flexible())], alignment: .leading, spacing: YYUI.s(7)) {
                ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                    HStack(spacing: YYUI.s(6)) {
                        RoundedRectangle(cornerRadius: 2).fill(shade(i)).frame(width: YYUI.s(8), height: YYUI.s(8))
                        Text(p.0).foregroundStyle(YYColor.t2)
                        Spacer(minLength: 0)
                        Text(Self.size(p.1)).fontWeight(.medium).monospacedDigit().foregroundStyle(YYColor.t1)
                    }
                    .font(YYUI.font(10.5))
                }
            }
            .padding(.top, YYUI.s(12))
        }
        .padding(.vertical, YYUI.s(13))
        .padding(.horizontal, YYUI.s(14))
        .yyCard()
    }

    /// 书文件, the books deleted, and everything else (the library, notes, covers).
    private var parts: [(String, Int64)] {
        guard let u = usage else { return [(String(localized: "书文件"), 0), (String(localized: "已删除"), 0), (String(localized: "其他"), 0)] }
        return [(String(localized: "书文件"), u.bookBytes), (String(localized: "已删除"), u.deletedBytes),
                (String(localized: "其他"), max(0, u.total - u.bookBytes - u.deletedBytes))]
    }

    /// The prototype's four greys, from the ink down.
    private func shade(_ i: Int) -> Color {
        [YYColor.t1, YYColor.t1.opacity(0.62), YYColor.t1.opacity(0.36), YYColor.t1.opacity(0.21)][min(i, 3)]
    }

    /// `.v-sy-bk`: cover, title and kind, the size in ink.
    private func bookRow(_ b: StorageUsage.Book) -> some View {
        let book = library.books.first { $0.id == b.id }
        return Button { info = book } label: {
            HStack(spacing: YYUI.s(10)) {
                if let book { BookCover(book: book).frame(width: YYUI.s(24)) }
                VStack(alignment: .leading, spacing: YYUI.s(1)) {
                    Text(b.title).font(YYUI.font(11.5, .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                    Text(book.map(Self.kind) ?? "").font(YYUI.font(10)).foregroundStyle(YYColor.t3).lineLimit(1)
                }
                Spacer(minLength: YYUI.s(8))
                Text(Self.size(b.bytes)).font(YYUI.font(11, .semibold).monospacedDigit()).foregroundStyle(YYColor.t1)
            }
            .padding(.vertical, YYUI.s(7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private static func kind(_ b: BookSummary) -> String {
        switch b.format {
        case .pdf: "PDF"
        case .txt: "TXT"
        case .mobi: "MOBI"
        case .epub: "EPUB"
        }
    }

    /// "6.8" and "GB".
    private static func split(_ bytes: Int64) -> (String, String) {
        let s = size(bytes)
        guard let space = s.lastIndex(of: " ") else { return (s, "") }
        return (String(s[..<space]), String(s[s.index(after: space)...]))
    }

    private func measure() async {
        let active = Dictionary(library.books.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        usage = await StorageUsage.measure(dir: library.dataDir, active: active)
    }

    private func purge() {
        cleaning = true
        _ = try? library.core.purgeDeleted(olderThanMs: 0)
        Task {
            await measure()
            cleaning = false
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - 关于

/// 关于 (prototype 关于): free, no server, nothing collected; the licences, privacy, and feedback
/// by mail, as there is no server to send it to.
struct PhoneAbout: View {
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return b.map { "\(v) (\($0))" } ?? v
    }

    var body: some View {
        YYPage {
            VStack(spacing: 0) {
                // `.v-me-logo`: 阅 on paper, the blue rule under it.
                Text("阅")
                    .font(YYUI.font(30, .bold, design: .serif))
                    .foregroundStyle(Color(yy: YYRGBA(28, 29, 32)))
                    .padding(.bottom, YYUI.s(6))
                    .frame(width: YYUI.s(64), height: YYUI.s(64))
                    .overlay(alignment: .bottom) {
                        Capsule().fill(Color(yy: YYRGBA(43, 76, 126))).frame(height: YYUI.s(2.5))
                            .padding(.horizontal, YYUI.s(20)).padding(.bottom, YYUI.s(13))
                    }
                    .background(Color(yy: YYRGBA(251, 250, 247)), in: .rect(cornerRadius: YYUI.s(15)))
                    .overlay(RoundedRectangle(cornerRadius: YYUI.s(15)).strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: Color(yy: YYRGBA(30, 28, 24, 0.14)), radius: YYUI.s(10), y: YYUI.s(8))
                Text("语阅").font(YYUI.font(17, .bold)).foregroundStyle(YYColor.t1).padding(.top, YYUI.s(10))
                Text("版本 \(version)").font(YYUI.font(10).monospacedDigit()).foregroundStyle(YYColor.t3).padding(.top, 2)
                Text("免费，没有服务器，不收集任何数据。")
                    .font(YYUI.font(12.5, .semibold)).foregroundStyle(YYColor.t1)
                    .padding(.top, YYUI.s(22)).padding(.bottom, YYUI.s(26))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, YYUI.s(24))
            YYGroup {
                NavigationLink { PhoneTextPage(title: String(localized: "开源许可"), text: Self.licences) } label: {
                    YYRow(String(localized: "开源许可"), icon: "chevron.left.forwardslash.chevron.right", chevron: true)
                }
                .buttonStyle(.plain)
                NavigationLink { PhoneTextPage(title: String(localized: "隐私说明"), text: Self.privacy) } label: {
                    YYRow(String(localized: "隐私说明"), icon: "checkmark.shield", chevron: true)
                }
                .buttonStyle(.plain)
                if let mail = URL(string: "mailto:yuyue.app@icloud.com?subject=%E8%AF%AD%E9%98%85%E5%8F%8D%E9%A6%88") {
                    Link(destination: mail) { YYRow(String(localized: "反馈"), icon: "envelope", value: String(localized: "发邮件给开发者"), chevron: true) }
                        .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    static var licences: String {
        String(localized: "语阅用到了这些开源项目，感谢它们的作者：") + "\n\n"
            + "UniFFI (MPL-2.0) · rusqlite / SQLite (MIT / Public Domain) · serde, serde_json, regex, encoding_rs, chardetng, zip, html5ever, roxmltree, ICU4X, blake3, percent-encoding, thiserror (MIT / Apache-2.0) · Lucide “radio” icon (ISC) · LobeHub Icons (MIT) · magpie icon (MIT)"
            + "\n\n" + String(localized: "完整的许可文本随源代码一起发布。")
    }

    static var privacy: String {
        [String(localized: "语阅没有服务器，也不收集任何数据：没有账号、没有统计、没有广告。"),
         String(localized: "书、进度、笔记和生词都存在这台设备上。打开同步时，它们只在你的设备和你自己选的网盘（iCloud 云盘、WebDAV 或 Google Drive）之间传，语阅看不到。"),
         String(localized: "书伴默认用设备自带的模型，不联网。你填了自己的 Key 时，提问和书里相关的几段原文会直接发给你选的服务商，费用和隐私条款按你和它的约定；Key 只存在这台设备的钥匙串里。"),
         String(localized: "云端声音和笔记导出（Notion、flomo）也只在你填了 Key 或链接时联网：要读的句子、要发的笔记直接发给你选的服务。读过的声音存在这台设备上。"),
         String(localized: "翻译用系统的离线翻译，原文不出这台设备。")].joined(separator: "\n\n")
    }
}

private struct PhoneTextPage: View {
    let title: String
    let text: String

    var body: some View {
        YYPage {
            Text(text)
                .font(YYUI.font(11.5))
                .lineSpacing(YYUI.s(11.5) * 0.7)
                .foregroundStyle(YYColor.t1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, YYUI.s(14))
                .padding(.horizontal, YYUI.s(14))
                .yyCard()
                .padding(.top, YYUI.s(10))
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
