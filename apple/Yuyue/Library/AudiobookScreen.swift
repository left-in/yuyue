import SwiftUI
import YuyueCore

/// 有声书 open (prototype v0.30 C3, C4, C6): the cover, the chapter, the scrubber with the
/// 书签 on it, and the controls. On a Mac the chapters and 书签 sit in a column on the right; on
/// the phone they come up from the bottom.
struct AudiobookScreen: View {
    let library: Library
    let player: AudiobookPlayer
    var close: (() -> Void)?
    @State private var list: ListKind?
    @State private var scrubbing: Double?
    @State private var timer = false
    private let tint = YYTint.standard

    enum ListKind: String, Identifiable, CaseIterable {
        case chapters, bookmarks
        var id: String { rawValue }
    }

    var body: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            controls(cover: 240, width: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { keys.padding(.bottom, 18) }
            VStack(spacing: 10) {
                ChapterList(player: player, kind: Binding(get: { list ?? .chapters }, set: { list = $0 }))
                pairCard
            }
                .frame(width: 300)
                .padding(.vertical, 12)
                .padding(.trailing, 12)
        }
        .background(YYColor.bg)
        // ⌘D, as in a book's window.
        .background { Button("加书签") { player.addBookmark() }.keyboardShortcut("d").hidden() }
        .onKeyPress(.space) { player.togglePlay(); return .handled }
        .onKeyPress(.leftArrow) { player.skip(-AudiobookPlayer.back); return .handled }
        .onKeyPress(.rightArrow) { player.skip(AudiobookPlayer.ahead); return .handled }
        .focusable()
        .focusEffectDisabled()
        .navigationTitle(player.summary.title)
        // 合成 here shows how it's going in this window too.
        .audiobookSheets(library)
        #else
        VStack(spacing: 0) {
            HStack {
                Button("收起", systemImage: "chevron.down") { close?() }
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                Spacer()
            }
            .padding(.horizontal, 12)
            controls(cover: 188, width: nil)
                .padding(.horizontal, 22)
            tiles
                .padding(.horizontal, 22)
            pairCard
                .padding(.horizontal, 22)
                .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .foregroundStyle(YYColor.t1)
        .background(YYColor.bg)
        .sheet(item: $list) { kind in
            ChapterList(player: player, kind: Binding(get: { list ?? kind }, set: { list = $0 }))
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #endif
    }

    // MARK: Parts

    /// 书架上有同一本电子书: 合成 lays the recording against it (v0.30 C3 / C6).
    @ViewBuilder private var pairCard: some View {
        if let ebook = library.ebook(for: player.summary) {
            HStack(spacing: 10) {
                BookCover(book: ebook).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("书架上有《\(ebook.title)》电子书").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text("合成以后听到哪句，书页就走到哪句").font(.system(size: 10)).foregroundStyle(YYColor.t3).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("合成") { library.pair(player.summary, with: ebook) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(YYColor.bg)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(YYColor.t1, in: .capsule)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .yyCard()
        }
    }

    private func controls(cover: CGFloat, width: CGFloat?) -> some View {
        VStack(spacing: 0) {
            SquareCover(book: player.summary)
                .frame(width: cover, height: cover)
                .padding(.top, 14)
                .padding(.bottom, 18)
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: width == nil ? .leading : .center, spacing: 2) {
                    Text(player.title(player.chapter))
                        .font(.system(size: width == nil ? 17 : 19, weight: .bold))
                        .lineLimit(1)
                    Text([player.summary.title, player.summary.authors.first].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(YYColor.t2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: width == nil ? .leading : .center)
                #if os(iOS)
                Button("加书签", systemImage: "bookmark") { player.addBookmark() }
                    .labelStyle(.iconOnly)
                    .frame(width: 30, height: 30)
                #endif
            }
            scrubber
                .padding(.top, 18)
                .padding(.bottom, 6)
            times
            buttons
                .padding(.vertical, 14)
                .padding(.horizontal, width == nil ? 4 : 40)
            if let failure = player.failure {
                Text(failure).font(.footnote).foregroundStyle(YYColor.danger)
            }
        }
        .frame(width: width)
    }

    /// The chapter: what's been heard, the 书签 in it as small marks, and a knob to drag.
    private var scrubber: some View {
        let (at, of) = player.inChapter
        let start = player.chapters.indices.contains(player.chapter) ? player.chapters[player.chapter].start : 0
        let shown = scrubbing ?? at
        let marks = player.bookmarks.map { player.seconds(of: $0) - start }.filter { $0 >= 0 && $0 <= of }
        return GeometryReader { g in
            let x = { (t: Double) in of > 0 ? g.size.width * min(1, max(0, t / of)) : 0 }
            ZStack(alignment: .leading) {
                Capsule().fill(YYColor.inset).frame(height: 4)
                Capsule().fill(YYColor.t1).frame(width: x(shown), height: 4)
                ForEach(marks, id: \.self) { m in
                    RoundedRectangle(cornerRadius: 1).fill(YYColor.card).frame(width: 2, height: 6).offset(x: x(m) - 1)
                }
                Circle().fill(YYColor.t1)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(YYColor.bg, lineWidth: 3).padding(-3))
                    .offset(x: x(shown) - 6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in scrubbing = of * min(1, max(0, v.location.x / max(1, g.size.width))) }
                .onEnded { _ in
                    if let s = scrubbing { player.seek(to: start + s) }
                    scrubbing = nil
                })
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel("本集进度")
        .accessibilityValue(AudiobookPlayer.clock(at))
        .accessibilityAdjustableAction { d in player.skip(d == .increment ? AudiobookPlayer.ahead : -AudiobookPlayer.back) }
    }

    private var times: some View {
        let (at, of) = player.inChapter
        let left = player.total - player.time
        return HStack {
            Text(AudiobookPlayer.clock(scrubbing ?? at)).fontWeight(.medium).foregroundStyle(YYColor.t2)
            Spacer()
            #if os(iOS)
            Text("本集还剩 \(AudiobookPlayer.clock(of - at)) · 全书还剩 \(Audiobook.length(left))")
            #else
            Text("全书还剩 \(Audiobook.length(left))")
            #endif
            Spacer()
            Text(AudiobookPlayer.clock(of)).fontWeight(.medium).foregroundStyle(YYColor.t2)
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(YYColor.t3)
    }

    private var buttons: some View {
        HStack {
            Menu {
                Picker("倍速", selection: Binding(get: { player.rate }, set: { player.rate = $0 })) {
                    ForEach([0.75, 1, 1.1, 1.2, 1.25, 1.5, 1.75, 2, 2.5, 3] as [Float], id: \.self) { r in
                        Text(Self.rate(r)).tag(r)
                    }
                }
            } label: {
                Text(Self.rate(player.rate))
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .frame(width: 40, height: 40)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
            Button("后退 15 秒", systemImage: "gobackward.15") { player.skip(-AudiobookPlayer.back) }
                .font(.system(size: 22))
                .frame(width: 40, height: 40)
            Spacer()
            Button(player.isPlaying ? String(localized: "暂停") : String(localized: "播放"), systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                player.togglePlay()
            }
            .contentTransition(.symbolEffect(.replace))
            .animation(YYMotion.quick, value: player.isPlaying)
            .font(.system(size: 20))
            .foregroundStyle(YYColor.bg)
            .frame(width: 60, height: 60)
            .background(YYColor.t1, in: .circle)
            Spacer()
            Button("前进 30 秒", systemImage: "goforward.30") { player.skip(AudiobookPlayer.ahead) }
                .font(.system(size: 22))
                .frame(width: 40, height: 40)
            Spacer()
            sleepMenu
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(YYColor.t1)
    }

    private var sleepMenu: some View {
        Menu {
            Button("关闭") { player.sleep = .off }
            Button("本集完") { player.sleep = .chapter }
            ForEach([15, 30, 45, 60, 90], id: \.self) { m in
                Button("\(m) 分钟") { player.sleep = .until(Date().addingTimeInterval(Double(m) * 60), minutes: m) }
            }
        } label: {
            Image(systemName: player.sleep == .off ? "moon.zzz" : "moon.zzz.fill")
                .font(.system(size: 20))
                .frame(width: 40, height: 40)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("定时")
    }

    #if os(iOS)
    private var tiles: some View {
        HStack(spacing: 6) {
            tile("list.bullet", "章节", String(localized: "\(player.chapters.count) 集")) { list = .chapters }
            tile("bookmark", "书签", String(localized: "\(player.bookmarks.count) 个")) { list = .bookmarks }
            tile("moon.zzz", "定时", sleepName) { timer = true }
            RoutePicker()
                .frame(maxWidth: .infinity, minHeight: 56)
                .yyCard()
        }
        .confirmationDialog("定时", isPresented: $timer) {
            Button("本集完") { player.sleep = .chapter }
            ForEach([15, 30, 45, 60, 90], id: \.self) { m in
                Button("\(m) 分钟") { player.sleep = .until(Date().addingTimeInterval(Double(m) * 60), minutes: m) }
            }
            if player.sleep != .off { Button("关闭定时", role: .destructive) { player.sleep = .off } }
        }
    }

    private func tile(_ icon: String, _ name: LocalizedStringKey, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 16))
                Text(name).font(.system(size: 10, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(YYColor.t3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .yyCard()
        }
    }
    #endif

    private var sleepName: String {
        switch player.sleep {
        case .off: String(localized: "关")
        case .chapter: String(localized: "本集完")
        case .until(_, let m): String(localized: "\(m) 分钟")
        }
    }

    #if os(macOS)
    private var keys: some View {
        HStack(spacing: 16) {
            key(["空格"], "暂停")
            key(["←", "→"], "后退 15 秒 / 前进 30 秒")
            key(["⌘D"], "加书签")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(YYColor.t3)
    }

    private func key(_ keys: [String], _ what: LocalizedStringKey) -> some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { k in
                Text(k).font(.system(size: 10)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(YYColor.inset, in: .rect(cornerRadius: 4))
                    .foregroundStyle(YYColor.t2)
            }
            Text(what)
        }
    }
    #endif

    static func rate(_ r: Float) -> String {
        (r == r.rounded() ? String(format: "%.0f", r) : String(format: "%g", r)) + "×"
    }
}

/// 章节 and 书签: the one being heard has the moving bars, the ones heard are grey.
struct ChapterList: View {
    let player: AudiobookPlayer
    @Binding var kind: AudiobookScreen.ListKind
    /// 长按改名: the chapter being named, and the name typed.
    @State private var renaming: Int?
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $kind) {
                Text("章节 \(player.chapters.count)").tag(AudiobookScreen.ListKind.chapters)
                Text("书签 \(player.bookmarks.count)").tag(AudiobookScreen.ListKind.bookmarks)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 12)
            List {
                switch kind {
                case .chapters: chapters
                case .bookmarks: bookmarks
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .alert("给这一集起个名字", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(renaming.map { String(localized: "第 \($0 + 1) 集") } ?? "", text: $newName)
            Button("好") {
                if let i = renaming { player.renameChapter(i, newName) }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        } message: {
            Text("留空就叫“第几集”")
        }
        .background(YYColor.card)
        #if os(macOS)
        .clipShape(.rect(cornerRadius: 14))
        #endif
    }

    @ViewBuilder private var chapters: some View {
        let now = player.chapter
        ForEach(Array(player.chapters.enumerated()), id: \.offset) { i, c in
            Button { player.go(toChapter: i) } label: {
                HStack(spacing: 10) {
                    Group {
                        if i == now {
                            Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                        } else {
                            Text("\(i + 1)")
                        }
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(i == now ? YYColor.t1 : YYColor.t3)
                    .frame(width: 20, alignment: .leading)
                    Text(player.title(i))
                        .fontWeight(i == now ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer()
                    Text(i == now ? String(localized: "还剩 \(AudiobookPlayer.clock(player.inChapter.of - player.inChapter.at))") : AudiobookPlayer.clock(c.seconds))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(YYColor.t3)
                }
                .font(.system(size: 13))
                .foregroundStyle(i < now ? YYColor.t3 : YYColor.t1)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .contextMenu {
                Button("改名", systemImage: "pencil") {
                    newName = c.title ?? ""
                    renaming = i
                }
            }
        }
    }

    @ViewBuilder private var bookmarks: some View {
        if player.bookmarks.isEmpty {
            Text("听到想记住的地方，点书签按钮记一下。")
                .font(.footnote)
                .foregroundStyle(YYColor.t3)
                .listRowBackground(Color.clear)
        }
        ForEach(player.bookmarks, id: \.id) { b in
            Button { player.seek(to: player.seconds(of: b)) } label: {
                HStack {
                    Text(player.title(Int(b.section))).lineLimit(1)
                    Spacer()
                    Text(AudiobookPlayer.clock(Double(b.sentence) / 1000))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(YYColor.t3)
                }
                .font(.system(size: 13))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .swipeActions { Button("删除", role: .destructive) { player.deleteBookmark(b) } }
            .contextMenu { Button("删除", role: .destructive) { player.deleteBookmark(b) } }
        }
    }
}

/// The cover square, as recordings' covers are; the book's colour when it has none.
struct SquareCover: View {
    let book: BookSummary
    var shadow = true
    @State private var image: CGImage?
    @AppStorage(EInk.key) private var eink = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    ZStack {
                        YYColor.inset
                        Image(systemName: "headphones").font(.system(size: 28)).foregroundStyle(YYColor.t3)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: shadow ? 10 : 4))
            .overlay(RoundedRectangle(cornerRadius: shadow ? 10 : 4).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            .grayscale(eink ? 1 : 0)
            .shadow(color: .black.opacity(eink || !shadow ? 0 : 0.18), radius: 17, y: 14)
            .task(id: book.coverPath) { image = await Thumbnail.load(book.coverPath, maxPixels: 600) }
    }
}

#if os(iOS)
import AVKit

/// 输出: AirPods, the speaker, AirPlay.
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        v.tintColor = UIColor(YYColor.t1)
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
