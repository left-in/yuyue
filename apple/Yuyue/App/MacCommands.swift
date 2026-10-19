#if os(macOS)
import SwiftUI

extension FocusedValues {
    /// The book in the front window, for the menu bar.
    @Entry var reader: ReaderModel?
}

/// 阅读 and 听书 in the menu bar: every shortcut of the book window, written next to what it
/// does (FEATURES §5 快捷键). They act on the book in front and are greyed out without one.
struct ReaderCommands: Commands {
    @FocusedValue(\.reader) private var model

    var body: some Commands {
        CommandMenu("阅读") {
            // In the shelf window too.
            Button("搜索 · 问") {
                if let model { model.quickSearchShown = true } else { NotificationCenter.default.post(name: .quickSearch, object: nil) }
            }
            .keyboardShortcut("k")
            Divider()
            Group { reading }.disabled(model == nil)
        }
        CommandMenu("听书") {
            Group { listening }.disabled(model == nil)
        }
    }

    @ViewBuilder private var reading: some View {
        Button("目录") { model?.togglePanel(.toc) }
            .keyboardShortcut("t", modifiers: [.command, .option])
        Button("显示或收起笔记栏") { model?.togglePanel(.notes) }
            .keyboardShortcut("n", modifiers: [.command, .option])
        Button("书伴") { model?.togglePanel(.companion) }
        Divider()
        Button("书内搜索") { model?.startSearch() }
            .keyboardShortcut("f")
        Button("下一处") { model?.nextHit(forward: true) }
            .keyboardShortcut("g")
            .disabled(model?.hits.isEmpty ?? true)
        Button("上一处") { model?.nextHit(forward: false) }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(model?.hits.isEmpty ?? true)
        Divider()
        Button(model?.bookmarkHere != nil ? String(localized: "拿掉书签") : String(localized: "加书签")) { model?.toggleBookmark() }
            .keyboardShortcut("d")
        Button("上一章") { model?.goToChapter(forward: false) }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        Button("下一章") { model?.goToChapter(forward: true) }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        Divider()
        Button("字号大一号") { model?.stepFont(1) }
            .keyboardShortcut("+")
        Button("字号小一号") { model?.stepFont(-1) }
            .keyboardShortcut("-")
        Button(model?.immersive == true ? String(localized: "退出沉浸阅读") : String(localized: "沉浸阅读")) { model?.immersive.toggle() }
            .disabled(model == nil)
            .keyboardShortcut("f", modifiers: [.command, .control])
        Divider()
        Button("替换规则…") { model?.rulesShown = true }
            .disabled(model?.detail?.summary.format == .pdf)
        Button("编码和目录…") { model?.txtShown = true }
            .disabled(model?.detail?.summary.format != .txt)
    }

    @ViewBuilder private var listening: some View {
        // 空格 is handled by the page: as a menu key it would take spaces from the search field.
        Button(model?.isPlaying == true ? String(localized: "暂停（空格）") : String(localized: "朗读（空格）")) { model?.togglePlay() }
        Button("上一句") { model?.player?.skip(forward: false) }
            .keyboardShortcut("[")
        Button("下一句") { model?.player?.skip(forward: true) }
            .keyboardShortcut("]")
        Divider()
        if let player = model?.player {
            Picker("睡眠定时", selection: Binding(get: { SleepChoice(player.sleep) }, set: { player.sleep = $0.value })) {
                ForEach(SleepChoice.allCases) { Text($0.title).tag($0) }
            }
            Toggle("单句循环", isOn: Binding(get: { player.loop }, set: { player.loop = $0 }))
        }
        if let model {
            Toggle("只听，隐藏原文", isOn: Binding(get: { model.listenOnly }, set: { model.listenOnly = $0 }))
        }
    }
}

/// The sleep timer's choices, for a menu.
enum SleepChoice: Int, CaseIterable, Identifiable {
    case off, sentence, chapter, m15, m30, m60

    var id: Int { rawValue }

    init(_ sleep: Player.Sleep) {
        switch sleep {
        case .off: self = .off
        case .sentence: self = .sentence
        case .chapter: self = .chapter
        case .until(_, let m): self = m <= 15 ? .m15 : m <= 30 ? .m30 : .m60
        }
    }

    var title: String {
        switch self {
        case .off: String(localized: "关")
        case .sentence: String(localized: "本句读完")
        case .chapter: String(localized: "本章结束")
        case .m15: String(localized: "15 分钟")
        case .m30: String(localized: "30 分钟")
        case .m60: String(localized: "60 分钟")
        }
    }

    var value: Player.Sleep {
        switch self {
        case .off: .off
        case .sentence: .sentence
        case .chapter: .chapter
        case .m15: .until(Date().addingTimeInterval(15 * 60), minutes: 15)
        case .m30: .until(Date().addingTimeInterval(30 * 60), minutes: 30)
        case .m60: .until(Date().addingTimeInterval(60 * 60), minutes: 60)
        }
    }
}
#endif
