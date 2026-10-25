import SwiftUI
import YuyueCore

/// 今天回顾 (prototype 每日回顾 / 回顾完成): five old highlights a day, one at a time, each asking
/// one thing: 留下, or 不要了. 留下 comes back in a while; 不要了 only stops it coming back. When
/// the five are done it says so and stops: no streaks, no "come back tomorrow".
@Observable
final class Review: Identifiable {
    static let perDay: UInt32 = 5

    let id = UUID()
    /// Only this book's highlights (回顾这本书), else every book's.
    let book: BookSummary?
    private(set) var items: [ReviewItem] = []
    private(set) var doneToday: UInt32 = 0
    /// What was chosen for each highlight, by mark id.
    private(set) var kept: [String: Bool] = [:]
    var index = 0

    @ObservationIgnored private let core: YuyueCore

    init(core: YuyueCore, book: BookSummary? = nil) {
        self.core = core
        self.book = book
        reload()
    }

    func reload() {
        // One book's review is not today's five: everything not seen lately is due.
        let start = book == nil ? Calendar.current.startOfDay(for: Date()) : Date()
        let deck = try? core.reviewToday(book: book?.id, dayStart: Int64(start.timeIntervalSince1970 * 1000), count: Self.perDay)
        items = deck?.items ?? []
        doneToday = book == nil ? deck?.doneToday ?? 0 : 0
        kept = [:]
        index = 0
    }

    var current: ReviewItem? { index < items.count ? items[index] : nil }
    var finished: Bool { !items.isEmpty && index >= items.count }

    /// 约 2 分钟: about 25 seconds each.
    var minutes: Int { max(1, Int((Double(items.count) * 25 / 60).rounded())) }

    func choose(_ keep: Bool) {
        guard let item = current else { return }
        set(item, keep)
        index += 1
    }

    /// Changing one's mind on the 看完了 page.
    func flip(_ item: ReviewItem) {
        set(item, !(kept[item.mark.id] ?? true))
    }

    #if DEBUG
    /// Shows step `n` without writing anything (screenshots); past the end, the last one dropped.
    func preview(step n: Int) {
        index = min(n, items.count)
        for (i, item) in items.prefix(index).enumerated() { kept[item.mark.id] = i != items.count - 1 }
    }
    #endif

    private func set(_ item: ReviewItem, _ keep: Bool) {
        try? core.setMarkReview(book: item.book, id: item.mark.id, keep: keep)
        kept[item.mark.id] = keep
    }
}

/// The stack of cards on top of 笔记 · 按时间: the first sentence showing, 开始 to go through them.
struct ReviewDeckCard: View {
    let review: Review
    let library: Library
    let start: () -> Void
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("今天回顾").font(.yy(size: 13, weight: .bold)).foregroundStyle(YYColor.t1)
                Text(review.items.isEmpty ? String(localized: "看完了") : String(localized: "\(review.items.count) 条 · 约 \(review.minutes) 分钟"))
                    .font(.yy(size: 10.5)).monospacedDigit().foregroundStyle(YYColor.t3)
            }
            .padding(.trailing, 18)
            .overlay(alignment: .trailing) { Rectangle().fill(YYColor.line).frame(width: 1) }
            if let first = review.items.first {
                // The book's words verbatim: interpolated into a localized string they lose Songti.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: "“" + first.mark.text + "”").font(YYUI.serif(13.5)).foregroundStyle(YYColor.t1)
                    Text(title(first)).font(.yy(size: 10.5)).foregroundStyle(YYColor.t3).layoutPriority(-1)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: -6) {
                    ForEach(covers, id: \.id) { BookCover(book: $0).frame(width: 18) }
                }
                Button(action: start) {
                    Text("开始")
                        .font(.yy(size: 12, weight: .semibold))
                        .foregroundStyle(tint.onBlack)
                        .padding(.horizontal, 16).frame(height: 28)
                        .background(tint.black, in: .capsule)
                }
                .buttonStyle(.plain)
            } else {
                Text("今天的 \(review.doneToday) 条看完了。留下的以后还会再出现。")
                    .font(.yy(size: 12.5)).foregroundStyle(YYColor.t2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 18).padding(.trailing, 14).padding(.vertical, 12)
        .background {
            ZStack {
                // The cards underneath, two edges showing.
                RoundedRectangle(cornerRadius: 14).fill(YYColor.card).opacity(0.45)
                    .padding(.horizontal, 28).offset(y: 11)
                RoundedRectangle(cornerRadius: 14).fill(YYColor.card).opacity(0.75)
                    .padding(.horizontal, 14).offset(y: 6)
                    .yyShadow(scheme == .dark ? YYShadow.ringDark : YYShadow.ringLight)
                RoundedRectangle(cornerRadius: 16).fill(YYColor.card)
                    .yyShadow(scheme == .dark ? YYShadow.ringDark : YYShadow.ringLight)
            }
        }
        .padding(.bottom, 12)
    }

    private func title(_ item: ReviewItem) -> String {
        library.books.first { $0.id == item.book }?.title ?? ""
    }

    private var covers: [BookSummary] {
        var seen = Set<String>()
        return review.items.compactMap { item in
            guard seen.insert(item.book).inserted else { return nil }
            return library.books.first { $0.id == item.book }
        }
        .prefix(3).map { $0 }
    }
}

/// The review itself, one card at a time, then 看完了.
struct MacReviewSheet: View {
    let review: Review
    let library: Library
    /// 回原文.
    let open: (ReviewItem) -> Void
    /// 只回顾某一本书.
    let only: (BookSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    var body: some View {
        VStack(spacing: 0) {
            top
            dots.padding(.top, 14)
            Group {
                if let item = review.current {
                    card(item)
                } else {
                    summary
                }
            }
            .padding(.top, 22)
            actions.padding(.top, 28)
        }
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 24)
        #if os(macOS)
        .frame(width: 440, height: 560)
        #endif
        .background(YYColor.bg)
    }

    private var heading: String {
        let name = review.book.map { String(localized: "回顾《\($0.title)》") } ?? String(localized: "今天回顾")
        return "\(name) · \(min(review.index + 1, review.items.count)) / \(review.items.count)"
    }

    private var top: some View {
        HStack {
            roundButton("xmark") { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            Text(heading).font(.yy(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(YYColor.t1)
            Spacer()
            if let item = review.current {
                ShareLink(item: shareText(item)) {
                    Image(systemName: "square.and.arrow.up").font(.yy(size: 12, weight: .medium))
                        .foregroundStyle(YYColor.t2)
                        .frame(width: 30, height: 30)
                        .background(YYColor.card, in: .circle)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 30, height: 30)
            }
        }
    }

    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.yy(size: 11, weight: .semibold))
                .foregroundStyle(YYColor.t2)
                .frame(width: 30, height: 30)
                .background(YYColor.card, in: .circle)
        }
        .buttonStyle(.plain)
    }

    private var dots: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< review.items.count, id: \.self) { i in
                Capsule().fill(i < review.index ? YYColor.t1 : YYColor.line).frame(height: 3)
            }
        }
    }

    // MARK: One card

    private func card(_ item: ReviewItem) -> some View {
        let book = library.books.first { $0.id == item.book }
        return VStack(alignment: .leading, spacing: 0) {
            Text("“").font(.custom("Georgia", size: 40)).foregroundStyle(tint.accent).frame(height: 22, alignment: .top)
            VStack(alignment: .leading, spacing: 14) {
                    Text(item.mark.text)
                        .font(YYUI.serif(19, .semibold))
                        .lineSpacing(15)
                        .tracking(0.4)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(YYColor.t1)
                    if let note = item.mark.note {
                        Text(note)
                            .font(.custom("Kaiti SC", size: 13))
                            .lineSpacing(6)
                            .foregroundStyle(tint.accent)
                            .padding(.leading, 10)
                            .overlay(alignment: .leading) { Rectangle().fill(tint.accent).frame(width: 1.5) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 10)
            Rectangle().fill(YYColor.line).frame(height: 1)
            HStack(spacing: 10) {
                if let book { BookCover(book: book).frame(width: 26) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(book?.title ?? "").font(.yy(size: 12, weight: .semibold)).foregroundStyle(YYColor.t1)
                    Text(source(item, book)).font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
                }
                .lineLimit(1)
                Spacer()
                Button { open(item) } label: {
                    HStack(spacing: 2) {
                        Text("回原文")
                        Image(systemName: "chevron.right").font(.yy(size: 9, weight: .semibold))
                    }
                    .font(.yy(size: 11)).foregroundStyle(YYColor.t2)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { stack }
        .id(item.mark.id)
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
    }

    /// The white card with two more under it.
    private var stack: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(YYColor.card).opacity(0.4).padding(.horizontal, 24).offset(y: 17)
            RoundedRectangle(cornerRadius: 16).fill(YYColor.card).opacity(0.7).padding(.horizontal, 12).offset(y: 9)
                .yyShadow(scheme == .dark ? YYShadow.ringDark : YYShadow.ringLight)
            RoundedRectangle(cornerRadius: 16).fill(YYColor.card)
                .yyShadow(scheme == .dark ? YYShadow.ringDark : YYShadow.ringLight)
        }
    }

    private func source(_ item: ReviewItem, _ book: BookSummary?) -> String {
        var parts: [String] = []
        if let author = book?.author { parts.append(author) }
        if let book, let chapter = (try? library.core.book(id: book.id))?.chapterTitle(for: item.mark.section), chapter != book.title {
            parts.append(chapter)
        }
        parts.append(Self.whenMarked(item.mark.at))
        return parts.joined(separator: " · ")
    }

    /// 90 天前划的.
    static func whenMarked(_ ms: Int64) -> String {
        let date = Notes.date(ms)
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date), to: Calendar.current.startOfDay(for: Date())).day ?? 0
        switch days {
        case ..<1: return String(localized: "今天划的")
        case 1: return String(localized: "昨天划的")
        case ..<365: return String(localized: "\(days) 天前划的")
        default: return String(localized: "\(days / 365) 年前划的")
        }
    }

    private func shareText(_ item: ReviewItem) -> String {
        let title = library.books.first { $0.id == item.book }?.title
        return "“\(item.mark.text)”" + (title.map { "\n——《\($0)》" } ?? "")
    }

    // MARK: 看完了

    private var summary: some View {
        let kept = review.items.count { review.kept[$0.mark.id] ?? true }
        let dropped = review.items.count - kept
        return VStack(alignment: .leading, spacing: 0) {
            Text(review.book == nil ? String(localized: "今天的 \(review.items.count) 条看完了") : String(localized: "这本书的 \(review.items.count) 条看完了"))
                .font(YYUI.serif(19, .semibold)).tracking(0.4).foregroundStyle(YYColor.t1)
            Text(String(localized: "留下 \(kept) 条") + (dropped > 0 ? String(localized: " · 不要了 \(dropped) 条") : ""))
                .font(.yy(size: 11.5)).monospacedDigit().foregroundStyle(YYColor.t2).padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(Array(review.items.enumerated()), id: \.element.mark.id) { i, item in
                    if i > 0 { Rectangle().fill(YYColor.line).frame(height: 1) }
                    summaryRow(item)
                }
            }
            .padding(.top, 18)
            Text("留下的以后还会再出现。不要了的只是不再回顾，笔记还在；点一条可以改主意。")
                .font(.yy(size: 11)).lineSpacing(4).foregroundStyle(YYColor.t3).padding(.top, 14)
            Spacer(minLength: 12)
            Rectangle().fill(YYColor.line).frame(height: 1)
            Menu {
                ForEach(booksWithNotes, id: \.id) { book in
                    Button(book.title) { only(book) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "book").font(.yy(size: 13)).foregroundStyle(YYColor.t2)
                    Text("只回顾某一本书").font(.yy(size: 12.5, weight: .medium)).foregroundStyle(YYColor.t1)
                    Spacer()
                    Image(systemName: "chevron.right").font(.yy(size: 10, weight: .semibold)).foregroundStyle(YYColor.t3)
                }
                .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .padding(.top, 13)
        }
        .padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { stack }
    }

    private func summaryRow(_ item: ReviewItem) -> some View {
        let keep = review.kept[item.mark.id] ?? true
        let book = library.books.first { $0.id == item.book }
        return Button { review.flip(item) } label: {
            HStack(spacing: 9) {
                if let book { BookCover(book: book).frame(width: 14).opacity(keep ? 1 : 0.45) }
                Text(item.mark.text)
                    .font(YYUI.serif(12.5))
                    .foregroundStyle(keep ? YYColor.t1 : YYColor.t3)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if keep {
                    Image(systemName: "checkmark").font(.yy(size: 11, weight: .semibold)).foregroundStyle(YYColor.t2)
                } else {
                    Text("不要了").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3)
                }
            }
            .frame(height: 40)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var booksWithNotes: [BookSummary] {
        library.books.filter(\.available).filter { book in
            !((try? library.core.marks(book: book.id)) ?? []).isEmpty
        }
    }

    // MARK: Buttons

    @ViewBuilder private var actions: some View {
        if review.current != nil {
            HStack(spacing: 10) {
                Button { withAnimation(.snappy) { review.choose(false) } } label: {
                    Label("不要了", systemImage: "xmark")
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .foregroundStyle(YYColor.t2)
                        .background(YYColor.card, in: .capsule)
                        .yyShadow(scheme == .dark ? YYShadow.ringDark : YYShadow.ringLight)
                }
                .keyboardShortcut(.delete, modifiers: [])
                Button { withAnimation(.snappy) { review.choose(true) } } label: {
                    Label("留下", systemImage: "checkmark")
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .foregroundStyle(tint.onBlack)
                        .background(tint.black, in: .capsule)
                }
                .keyboardShortcut(.defaultAction)
            }
            .font(.yy(size: 13, weight: .semibold))
            .buttonStyle(.plain)
        } else {
            Button { dismiss() } label: {
                Text("完成")
                    .font(.yy(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .foregroundStyle(tint.onBlack)
                    .background(tint.black, in: .capsule)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }
}
