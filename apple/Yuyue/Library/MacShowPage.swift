import SwiftUI
import YuyueCore
#if os(macOS)

/// 节目页: the big name, the
/// blurb, who hosts, the cover on the right — but the blurb is what the reader told the editor,
/// the notice is when the next one comes and what's come in for it, and the big button writes
/// one now instead of subscribing. Below, where it reads from, then every episode.
struct MacShowPage: View {
    let library: Library
    let show: Show
    let openDesk: () -> Void
    let edit: () -> Void
    /// One episode's row, the same as in 最新.
    let row: (Episode) -> AnyView
    private var podcasts: Podcasts { library.podcasts }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                top
                notice
                sources
                episodes
            }
            .padding(.leading, 22).padding(.trailing, 28).padding(.bottom, 28).padding(.top, 4)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private var top: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                if !show.brief.isEmpty {
                    // What the reader asked the editor for, in the hand it was written in (配一档节目).
                    Text(show.brief).font(.custom("Kaiti SC", size: 14)).foregroundStyle(YYColor.t2)
                }
                Text(hostsLine).font(.yy(size: 12)).foregroundStyle(YYColor.t3)
            }
            Spacer(minLength: 0)
            ShowCover(name: show.name, size: 120)
        }
    }

    /// "小林、老周 主持 · 两人对谈 · 约 10 分钟"
    private var hostsLine: String {
        var parts: [String] = []
        let names = show.hosts.map(\.name).filter { !$0.isEmpty }
        if !names.isEmpty { parts.append(String(localized: "\(names.joined(separator: "、")) 主持")) }
        parts.append(show.form == .duo ? String(localized: "两人对谈") : String(localized: "单人播报"))
        parts.append(String(localized: "约 \(Int(show.minutes)) 分钟"))
        return parts.joined(separator: " · ")
    }

    // MARK: 公告

    /// Where a show's 公告 would be: when the next one comes, what's happening now.
    private var notice: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(nextLine).font(.yy(size: 13, weight: .semibold)).foregroundStyle(YYColor.t1)
                Text(stateLine).font(.yy(size: 11.5))
                    .foregroundStyle(podcasts.failure[show.id] != nil ? YYColor.danger : YYColor.t2).lineLimit(2)
            }
            Spacer(minLength: 12)
            PodcastTextButton(title: String(localized: "改设置…"), action: edit)
            PodcastGlassButton(title: String(localized: "编辑部"), symbol: "bubble.left") { openDesk() }
            if podcasts.isWriting(show.id) {
                PodcastGlassButton(title: podcasts.writing[show.id]?.short ?? "", kind: .writing) { openDesk() }
            } else {
                PodcastGlassButton(title: String(localized: "现在写一集"), symbol: "sparkles", kind: .main, flat: true) {
                    podcasts.write(show)
                    openDesk()
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(YYColor.card, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(YYColor.line, lineWidth: 0.5))
    }

    private var nextLine: String {
        guard !show.schedule.days.isEmpty else { return String(localized: "点了才写") }
        guard podcasts.writtenHere(show) else { return String(localized: "\(show.scheduleLine) · 在别的设备上写") }
        guard let next = podcasts.nextSlot(show) else { return show.scheduleLine }
        let day = Calendar.current.isDateInToday(next) ? String(localized: "今天")
            : Calendar.current.isDateInTomorrow(next) ? String(localized: "明天")
            : next.formatted(.dateTime.weekday(.wide))
        return String(localized: "下一集 \(day) \(next.formatted(date: .omitted, time: .shortened))")
    }

    private var stateLine: String {
        if let p = podcasts.writing[show.id] { return p.line }
        if let why = podcasts.failure[show.id] { return String(localized: "上一集没写成：\(why)") }
        let n = podcasts.episodes(of: show.id).count
        return n == 0 ? String(localized: "还没有一集") : String(localized: "写过 \(n) 集 · \(show.scheduleLine)")
    }

    // MARK: 来源

    private var sources: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("从哪里取").font(.yy(size: 14, weight: .semibold)).foregroundStyle(YYColor.t1)
            HStack(spacing: 8) {
                ForEach(Array(show.sources.enumerated()), id: \.offset) { _, s in
                    HStack(spacing: 6) {
                        SourceMarks.mark(s.kind == .hackerNews ? "Hacker News" : s.name)
                        Text(s.name).font(.yy(size: 12)).foregroundStyle(s.paused ? YYColor.t3 : YYColor.t1)
                        if s.paused { Text("停着").font(.yy(size: 10.5)).foregroundStyle(YYColor.t3) }
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(YYColor.card, in: .capsule)
                    .overlay(Capsule().strokeBorder(YYColor.line, lineWidth: 0.5))
                }
            }
        }
    }

    // MARK: 单集

    private var episodes: some View {
        let list = podcasts.episodes(of: show.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("单集").font(.yy(size: 14, weight: .semibold)).foregroundStyle(YYColor.t1)
                Text("\(list.count)").font(.yy(size: 12)).foregroundStyle(YYColor.t3).monospacedDigit()
            }
            NoteCard {
                ForEach(list, id: \.book) { e in row(e) }
                if list.isEmpty {
                    Text("还没有一集。点“现在写一集”，或者等到点").font(.yy(size: 12)).foregroundStyle(YYColor.t3).padding(.vertical, 22)
                }
            }
        }
    }
}
#endif
