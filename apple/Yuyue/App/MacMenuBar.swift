#if os(macOS)
import ServiceManagement
import SwiftUI
import YuyueCore

/// 菜单栏里的语阅: shows written here at set times need 语阅 running, not its
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
        followPlaying()
    }

    /// Shown while some show is written here at set times, or an episode is playing.
    private func follow() {
        // Also while an episode is in the 播放条, so it can be paused with the windows closed.
        let on = withObservationTracking { podcasts.scheduledHere || library.nowPlaying != nil } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        if on, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = MenuBarIcon.still
            item.button?.toolTip = String(localized: "语阅 · 播客")
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        } else if !on, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
        animate()
    }

    /// The three lines in the 门 move while a voice is playing, and stand still when it stops.
    private var frames: Timer?
    private var playing = false
    private func followPlaying() {
        playing = withObservationTracking { library.nowPlaying?.isPlaying == true } onChange: { [weak self] in
            Task { @MainActor in self?.followPlaying() }
        }
        animate()
    }

    private func animate() {
        let moving = playing && item != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if moving, frames == nil {
            let start = Date()
            let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.item?.button?.image = MenuBarIcon.frame(at: Date().timeIntervalSince(start))
                }
            }
            // .common: keeps moving while the menu is open.
            RunLoop.main.add(timer, forMode: .common)
            frames = timer
        } else if !moving, let timer = frames {
            timer.invalidate()
            frames = nil
            item?.button?.image = MenuBarIcon.still
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

/// 门里出声: 阅's 门 (ResourceHanRounded Medium) with three lines of voice inside, short, long,
/// middle. `menubar` is the whole still icon; `menubar-door` is the 门 alone, with the lines drawn
/// over it here, a little longer and shorter each frame, so they move like a voice speaking.
enum MenuBarIcon {
    private static let size = NSSize(width: 18, height: 18)

    static let still: NSImage? = {
        let image = NSImage(named: "menubar")
        image?.isTemplate = true
        image?.size = size
        return image
    }()

    private static let door = NSImage(named: "menubar-door")

    /// x in points, half the still length, how long one rise and fall takes, where it starts.
    /// From menubar.svg: 1000 units over 18 pt, lines centred 0.59 down, 64 units wide.
    private static let lines: [(x: CGFloat, half: CGFloat, period: Double, phase: Double)] = [
        (5.94, 1.44, 0.62, 0.0), (9.04, 3.6, 0.9, 1.9), (12.13, 2.34, 0.74, 3.7),
    ]
    private static let middle: CGFloat = 18 * 0.59
    private static let width: CGFloat = 18 * 0.064

    /// The icon `t` seconds into playing.
    static func frame(at t: TimeInterval) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            door?.draw(in: rect)
            NSColor.black.setStroke()
            for l in lines {
                // Between about half and a little over the still length.
                let k = 0.8 + 0.32 * sin(2 * .pi * t / l.period + l.phase)
                let half = max(l.half * k, 0.5)
                let path = NSBezierPath()
                path.move(to: NSPoint(x: l.x, y: middle - half))
                path.line(to: NSPoint(x: l.x, y: middle + half))
                path.lineWidth = width
                path.lineCapStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
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
