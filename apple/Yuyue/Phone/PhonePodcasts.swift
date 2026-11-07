#if os(iOS)
import SwiftUI
import YuyueCore

/// 书架 · 播客 on the phone (in the
/// shelf's 全部 / 书 / 有声 / 播客, not a tab of its own). The shows along the top, a number on
/// those with episodes not heard; then every episode, newest first, to play. Shows are set up and
/// written on the Mac; their episodes come here through sync.
struct PhonePodcasts: View {
    @Bindable var library: Library
    private var podcasts: Podcasts { library.podcasts }
    @AppStorage("appearance.tint") private var tintID = YYTint.blue.id
    private var tint: YYTint { YYTint.all.first { $0.id == tintID } ?? .blue }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !podcasts.shows.isEmpty {
                shows.padding(.bottom, 22)
            }
            if podcasts.latest.isEmpty {
                empty
            } else {
                Text("最新").font(.headline).foregroundStyle(YYColor.t1)
                    .padding(.horizontal, 20).padding(.bottom, 4)
                LazyVStack(spacing: 0) {
                    ForEach(podcasts.latest, id: \.book) { e in
                        row(e)
                        if e.book != podcasts.latest.last?.book {
                            Divider().overlay(YYColor.line).padding(.leading, 82)
                        }
                    }
                }
                .padding(.horizontal, 20)
                if waiting > 0 {
                    Text(waitingNote).font(.footnote).foregroundStyle(YYColor.t3)
                        .padding(.horizontal, 20).padding(.top, 12)
                }
            }
        }
        .onAppear { podcasts.reload() }
    }

    // MARK: 节目

    private var shows: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(podcasts.shows, id: \.id) { show in
                    let fresh = podcasts.episodes(of: show.id).count { !$0.heard }
                    VStack(alignment: .leading, spacing: 5) {
                        ShowCover(name: show.name, size: 76)
                            .overlay(alignment: .topTrailing) {
                                if fresh > 0 {
                                    Text("\(fresh)").font(.caption2.bold()).foregroundStyle(.white)
                                        .frame(minWidth: 20, minHeight: 20).background(tint.accent, in: .circle)
                                        .overlay(Circle().strokeBorder(YYColor.bg, lineWidth: 2)).offset(x: 6, y: -6)
                                }
                            }
                        Text(show.name).font(.caption.weight(.semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                        Text(show.scheduleLine).font(.caption2).foregroundStyle(YYColor.t3).lineLimit(1)
                    }
                    .frame(width: 76, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(fresh > 0 ? "\(show.name)，\(fresh) 集没听" : show.name)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .scrollIndicators(.never)
    }

    // MARK: 最新

    private func row(_ e: Episode) -> some View {
        let show = podcasts.shows.first { $0.id == e.show }
        let book = library.books.first { $0.id == e.book }
        let here = book?.available == true
        let playing = library.nowPlaying?.bookID == e.book
        return HStack(alignment: .top, spacing: 12) {
            ShowCover(name: show?.name ?? "", size: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(show?.name ?? "") · \(e.day)").font(.caption2).foregroundStyle(YYColor.t3)
                Text(e.title).font(.subheadline.weight(.semibold)).foregroundStyle(e.heard ? YYColor.t2 : YYColor.t1).lineLimit(2)
                if !e.summary.isEmpty {
                    Text(e.summary).font(.footnote).foregroundStyle(YYColor.t2).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if here {
                        PodcastGlassButton(title: remaining(e, book), symbol: e.heard ? "checkmark" : "play.fill", kind: playing ? .playing : .plain) {
                            play(book)
                        }
                    } else {
                        Text("还没传到这台设备").font(.caption).foregroundStyle(YYColor.t3).frame(height: 28)
                    }
                    Text("\(e.articles.count) 条").font(.caption2).monospacedDigit().foregroundStyle(YYColor.t3)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .contentShape(.rect)
        .onTapGesture { play(book) }
        .contextMenu {
            if here { Button("听", systemImage: "play") { play(book) } }
            Button(e.heard ? "标为没听" : "标为听完", systemImage: e.heard ? "circle" : "checkmark.circle") {
                try? library.core.setEpisodeHeard(book: e.book, heard: !e.heard)
                podcasts.reload()
            }
            if let book {
                Button("删除这一集", systemImage: "trash", role: .destructive) {
                    library.delete(book)
                    podcasts.reload()
                }
            }
        }
    }

    private func play(_ book: BookSummary?) {
        guard let book, book.available else { return }
        library.open(book, .listen)
    }

    private func remaining(_ e: Episode, _ book: BookSummary?) -> String {
        guard let book else { return String(localized: "听") }
        if e.heard { return String(localized: "听完了") }
        let total = max(1, Int(book.listenMinutes))
        if book.progress > 0.01 {
            return String(localized: "还剩 \(max(1, Int((1 - book.progress) * Double(total)))) 分")
        }
        return String(localized: "\(total) 分钟")
    }

    /// Episodes the log knows of whose script hasn't come yet.
    private var waiting: Int {
        podcasts.latest.count { e in library.books.first { $0.id == e.book }?.available != true }
    }

    private var waitingNote: String {
        library.sync.isOn
            ? String(localized: "有 \(waiting) 集还在路上，下次同步就到")
            : String(localized: "有 \(waiting) 集在别的设备上。打开同步（我的 › 同步）就能在这里听")
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image("radio").resizable().renderingMode(.template).scaledToFit().frame(width: 30, height: 30).foregroundStyle(YYColor.t3)
            Text("一档只给你听的节目").font(.subheadline.weight(.semibold)).foregroundStyle(YYColor.t1)
            Text(podcasts.shows.isEmpty
                 ? String(localized: "节目在 Mac 上配：书架窗口左边的“播客”。到点写好的每一集，同步到这里来听")
                 : String(localized: "还没有一集。节目在 Mac 上到点写好后，同步到这里来听"))
                .font(.footnote).foregroundStyle(YYColor.t2).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}
#endif
