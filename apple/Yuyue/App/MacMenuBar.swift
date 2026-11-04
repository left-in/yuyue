#if os(macOS)
import ServiceManagement
import SwiftUI
import YuyueCore

/// 菜单栏里的语阅 (播客开发方案 §3.4): shows written here at set times need 语阅 running, not its
/// windows. While there are any, a radio sits in the menu bar: each show's next time or how far
/// its episode has got, the new episodes to play, and the way back to the shelf. Closing every
/// window leaves 语阅 running there. (AppKit's status item: SwiftUI's MenuBarExtra put nothing
/// in the menu bar here.)
@MainActor
final class MacMenuBar: NSObject, NSMenuDelegate {
    private let library: Library
    private var item: NSStatusItem?
    /// SwiftUI's way to open a window, handed over by the shelf when it first shows.
    static var openWindow: OpenWindowAction?
    private var podcasts: Podcasts { library.podcasts }

    init(library: Library) {
        self.library = library
        super.init()
        follow()
    }

    /// Shown while some show is written here at set times, or an episode is playing.
    private func follow() {
        // Also while an episode is in the 播放条, so it can be paused with the windows closed.
        let on = withObservationTracking { podcasts.scheduledHere || library.nowPlaying != nil } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        if on, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(named: "radio")
            image?.isTemplate = true
            image?.size = NSSize(width: 16, height: 16)
            item.button?.image = image
            item.button?.toolTip = String(localized: "语阅 · 播客")
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        } else if !on, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // 正在放: the 播放条's episode, playable from here with every window closed.
        if let m = library.nowPlaying as? ReaderModel, m.detail?.summary.format == .podcast, let player = m.player {
            let e = podcasts.latest.first { $0.book == m.bookID }
            menu.addItem(.sectionHeader(title: m.isPlaying ? String(localized: "正在放") : String(localized: "暂停在")))
            menu.addItem(NSMenuItem(title: e?.title ?? m.detail?.summary.title ?? "", action: nil, keyEquivalent: ""))
            if let at = nowTopic(m) { menu.addItem(NSMenuItem(title: at, action: nil, keyEquivalent: "")) }
            menu.addItem(action(m.isPlaying ? String(localized: "暂停") : String(localized: "接着放")) { [weak self] in
                self?.library.playEpisode(m.bookID)
            })
            if player.state != .stopped {
                menu.addItem(action(String(localized: "下一条")) { [weak self] in self?.nextSegment(m) })
            }
            menu.addItem(.separator())
        }
        for show in podcasts.shows where podcasts.writtenHere(show) && !show.schedule.days.isEmpty {
            menu.addItem(.sectionHeader(title: show.name))
            menu.addItem(NSMenuItem(title: line(show), action: nil, keyEquivalent: ""))
            if !podcasts.isWriting(show.id) {
                menu.addItem(action(String(localized: "现在写一集")) { [weak self] in self?.podcasts.write(show) })
            }
        }
        let fresh = podcasts.latest.filter { !$0.heard }.prefix(5)
        if !fresh.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: String(localized: "没听的")))
            for e in fresh {
                menu.addItem(action(e.title) { [weak self] in self?.play(e) })
            }
        }
        menu.addItem(.separator())
        menu.addItem(action(String(localized: "打开书架")) {
            Self.openWindow?(id: "library")
            NSApp.activate()
        })
        let quit = NSMenuItem(title: String(localized: "退出语阅"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// 下一集 明天 7:00 · 正在读第 3 / 7 篇 · 没写成：……
    private func line(_ show: Show) -> String {
        if let p = podcasts.writing[show.id] { return p.line }
        if let why = podcasts.failure[show.id] { return String(localized: "没写成：\(why)") }
        guard let next = podcasts.nextSlot(show) else { return show.scheduleLine }
        let day = Calendar.current.isDateInToday(next) ? String(localized: "今天")
            : Calendar.current.isDateInTomorrow(next) ? String(localized: "明天")
            : next.formatted(.dateTime.weekday(.wide))
        return String(localized: "下一集 \(day) \(next.formatted(date: .omitted, time: .shortened))")
    }

    /// "第 2 / 7 条 · Rust 1.91", where the voice is.
    private func nowTopic(_ m: ReaderModel) -> String? {
        guard let s = m.player?.spot?.sentence,
              let segs = try? library.core.episodeSegments(book: m.bookID), !segs.isEmpty,
              let i = segs.lastIndex(where: { Int($0.first) <= s }) else { return nil }
        let topic = segs[i].topic
        return topic.isEmpty ? String(localized: "第 \(i + 1) / \(segs.count) 条") : String(localized: "第 \(i + 1) / \(segs.count) 条 · \(topic)")
    }

    private func nextSegment(_ m: ReaderModel) {
        guard let player = m.player, let s = player.spot?.sentence,
              let segs = try? library.core.episodeSegments(book: m.bookID),
              let next = segs.first(where: { Int($0.first) > s }) else {
            library.episodeFinished(m.bookID)
            return
        }
        let paused = player.state == .paused
        player.play(from: Position(section: 0, sentence: next.first))
        if paused { player.pause() }
    }

    /// Plays where 播客's 播放条 plays: no window needed, so the menu bar alone can be the radio.
    private func play(_ e: Episode) {
        library.playEpisode(e.book)
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(Run.go), keyEquivalent: "")
        let target = Run(run)
        item.target = target
        item.representedObject = target
        return item
    }

    private final class Run: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func go() { run() }
    }
}

/// 开机时打开语阅: a login item, so shows are written at their time after a restart too. Started
/// that way it opens no window, only the menu bar (see `AppDelegate`).
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }
    /// Turned on, but macOS wants it allowed in 系统设置 › 通用 › 登录项.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// This launch was macOS starting the login items.
    @MainActor static var launchedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
#endif
