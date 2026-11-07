#if os(macOS)
import SwiftUI
import AppKit

/// 最近改过: a clock beside 已存在这台 Mac, with how
/// many things were changed today; it opens a card of the changes, a day at a time. Each one
/// says which page and what, and draws the old and the new value (the colour, the font, the
/// switch, the voice to hear); 改回 is always there, and once taken back it's 再改过来.
/// Clicking a change goes to its page.
struct SettingsHistoryButton: View {
    @State private var open = false
    @State private var hovering = false
    private var log: SettingsLog { .shared }

    var body: some View {
        let today = log.entries.filter { $0.undone != true && Calendar.current.isDateInToday($0.date) }.count
        Button { open.toggle() } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.yy(size: 13.5, weight: .regular))
                .foregroundStyle(open || hovering ? YYColor.t1 : YYColor.t2)
                .frame(width: 28, height: 28)
                .background(YYColor.t1.opacity(open ? 0.07 : hovering ? 0.05 : 0), in: .rect(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    if today > 0 {
                        Text("\(today)")
                            .font(.yy(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(YYColor.card)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(YYColor.t2, in: .capsule)
                            .offset(x: 3, y: -2)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text("最近改过（⌘Z 改回最近一条）"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SettingsHistoryCard { open = false }
        }
        #if DEBUG
        // `-debugHistory 1` opens the card with 设置.
        .task { if UserDefaults.standard.bool(forKey: "debugHistory") { try? await Task.sleep(for: .seconds(1)); open = true } }
        #endif
    }
}

private struct SettingsHistoryCard: View {
    let close: () -> Void
    private var log: SettingsLog { .shared }

    var body: some View {
        let days = Dictionary(grouping: log.entries) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("最近改过").font(.yy(size: 13.5, weight: .semibold)).foregroundStyle(YYColor.t1)
                Text("这台 Mac · 点一条去那一页").font(.yy(size: 11)).foregroundStyle(YYColor.t3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
            if log.entries.isEmpty {
                Text("改了什么会记在这里，\n每一条都能改回去。")
                    .font(.yy(size: 12)).foregroundStyle(YYColor.t3).multilineTextAlignment(.center).lineSpacing(3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            } else {
                ScrollView {
                    // The day is a quiet word over its rows, not a pinned band: a solid strip
                    // across the see-through card read as a bar and pulled the eye off the rows.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(days.enumerated()), id: \.element.key) { i, group in
                            Text(Self.dayName(group.key))
                                .font(.yy(size: 11, weight: .medium)).foregroundStyle(YYColor.t3)
                                // Level with the rows' titles, past their icons.
                                .padding(.leading, 44)
                                .padding(.top, i == 0 ? 4 : 14)
                                .padding(.bottom, 2)
                            ForEach(group.value) { HistoryRow(entry: $0, close: close) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 400)
                .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(YYColor.line).frame(height: 0.5)
            HStack(spacing: 7) {
                Text(verbatim: "⌘Z").font(.yy(size: 10.5)).foregroundStyle(YYColor.t2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(YYColor.inset, in: .rect(cornerRadius: 4))
                Text("改回最近一条").font(.yy(size: 11)).foregroundStyle(YYColor.t3)
                Spacer(minLength: 8)
                if !log.entries.isEmpty {
                    Button("清空记录") { withAnimation(.snappy(duration: 0.2)) { log.clear() } }
                        .buttonStyle(.plain).font(.yy(size: 11)).foregroundStyle(YYColor.t3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 340)
    }

    static func dayName(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return String(localized: "今天") }
        if Calendar.current.isDateInYesterday(day) { return String(localized: "昨天") }
        return day.formatted(.dateTime.month().day())
    }
}

/// One change: the page's icon; what, on which page, when; old → new; 改回 or 再改过来.
private struct HistoryRow: View {
    let entry: SettingsLog.Entry
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        let page = entry.page.flatMap(SettingsPage.init(rawValue:))
        let undone = entry.undone == true
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: page?.symbol ?? "slider.horizontal.3")
                .font(.yy(size: 12, weight: .regular)).foregroundStyle(YYColor.t2)
                .frame(width: 26, height: 26)
                .background(YYColor.inset, in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.title).font(.yy(size: 12.5, weight: .semibold)).foregroundStyle(YYColor.t1).lineLimit(1)
                    if let page { Text(page.title).font(.yy(size: 10.5)).foregroundStyle(YYColor.t3) }
                    Spacer(minLength: 4)
                    Text(entry.date.formatted(date: .omitted, time: .shortened))
                        .font(.yy(size: 10.5).monospacedDigit()).foregroundStyle(YYColor.t3)
                }
                HStack(spacing: 6) {
                    HistoryValue(look: entry.look, raw: entry.fromRaw, text: entry.from).foregroundStyle(YYColor.t2)
                    Image(systemName: "arrow.right").font(.yy(size: 9, weight: .medium)).foregroundStyle(YYColor.t3)
                    HistoryValue(look: entry.look, raw: entry.toRaw, text: entry.to)
                        .foregroundStyle(YYColor.t1).fontWeight(.medium)
                        .strikethrough(undone, color: YYColor.t3)
                }
                .font(.yy(size: 12))
                .lineLimit(1)
            }
            .opacity(undone ? 0.5 : 1)
            action(undone)
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(hovering ? YYColor.t1.opacity(0.045) : .clear, in: .rect(cornerRadius: 10))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture {
            guard let page = entry.page else { return }
            UserDefaults.standard.set(page, forKey: "settings.page")
            close()
        }
        .help(Text(page.map { "去“\($0.title)”页" } ?? ""))
    }

    @ViewBuilder private func action(_ undone: Bool) -> some View {
        if undone, entry.redo != nil {
            Button { withAnimation(.snappy(duration: 0.2)) { SettingsLog.shared.redo(entry) } } label: {
                Label("再改过来", systemImage: "arrow.uturn.forward")
                    .font(.yy(size: 11.5)).foregroundStyle(YYColor.t2)
                    .padding(.horizontal, 9).frame(height: 24)
                    .overlay(Capsule().strokeBorder(YYColor.line, lineWidth: 0.5))
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
        } else if !undone, entry.undo != nil {
            Button { withAnimation(.snappy(duration: 0.2)) { SettingsLog.shared.undo(entry) } } label: {
                Label("改回", systemImage: "arrow.uturn.backward")
                    .font(.yy(size: 11.5, weight: .medium)).foregroundStyle(YYColor.t1)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(YYColor.t1.opacity(0.06), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help(Text("改回 \(entry.from)"))
        }
    }
}

/// A value drawn as what it is: a colour's dot, a font in itself, a little switch, a voice with
/// a ▶ to hear it; plain words otherwise.
private struct HistoryValue: View {
    let look: SettingsLog.Look?
    let raw: String?
    let text: String

    var body: some View {
        switch look {
        case .tint?:
            // 主题色 is gone; old entries keep their words.
            Text(text)
        case .paper?:
            HStack(spacing: 5) {
                dot(raw.flatMap { r in YYPaper.all.first { $0.id == r }?.bg ?? Papers.shared.paper(r).map { YYPaper(custom: $0).bg } })
                Text(text)
            }
        case .font?:
            Text(text).font(font)
        case .toggle?:
            HStack(spacing: 5) {
                let on = raw == "1"
                Capsule().fill(on ? YYColor.ok : YYColor.tint)
                    .frame(width: 20, height: 12)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 9, height: 9).padding(1.5).shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
                    }
                Text(text)
            }
        case .voice?:
            HStack(spacing: 5) {
                Text(text)
                if let raw, let voice = Voices.find(raw) {
                    Button {
                        Voices.preview(voice, text: voice.speaks("en") && !voice.speaks("zh") ? "It was the best of times." : "我冒了严寒，回到相隔二千余里的故乡去。")
                    } label: {
                        Image(systemName: "play.fill").font(.yy(size: 6.5)).foregroundStyle(YYColor.t1)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(YYColor.line, lineWidth: 0.5))
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .help(Text("听一句"))
                }
            }
        case nil:
            Text(text)
        }
    }

    private func dot(_ color: Color?) -> some View {
        Circle().fill(color ?? YYColor.inset).frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
    }

    private var font: Font {
        switch raw {
        case "serif": .custom("Songti SC", size: 12.5)
        case "kai": .custom("Kaiti SC", size: 12.5)
        case "wenKai": WenKai.shared.installed ? .custom("LXGW WenKai Lite", size: 12.5) : .custom("Kaiti SC", size: 12.5)
        default: .yy(size: 12)
        }
    }
}
#endif
