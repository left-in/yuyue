#if DEBUG && os(macOS)
import AppKit
import ScreenCaptureKit

/// `-debugShots <dir> -debugShotName <名字> [-debugShotDelay 秒]`：等界面稳下来（启动参数、
/// 延迟出现的卡片都到位），把这个 app 的每个窗口——sheet、popover 也算——存进
/// `<dir>/<名字>/1.png、2.png`（最前面的在前），然后退出。截自己的窗口走 ScreenCaptureKit
/// 不需要屏幕录制权限；万一不行就退回 NSView 自绘（会少标题栏那一条）。
/// window-catalog.sh 一次开一个弹窗，就能攒出一套全窗口图册。搭配 `-debugLibrary`
/// 指一个临时书库，不碰真的。
enum DebugShots {
    static func run() {
        let d = UserDefaults.standard
        guard let dir = d.string(forKey: "debugShots"), let name = d.string(forKey: "debugShotName") else { return }
        // -debugListen、-debugFlag 那些卡片要一秒半才出现，所以至少等 2.5 秒。
        let wait = max(d.double(forKey: "debugShotDelay"), 2.5)
        // 截图参数会顺带写下这两处偏好（读者面板、设置页），走之前还原成启动前的样子。
        let saved = ["reader.panel": d.object(forKey: "reader.panel"), "settings.page": d.object(forKey: "settings.page")]
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            Task { @MainActor in
                await shoot(into: URL(filePath: dir, directoryHint: .isDirectory).appendingPathComponent(name))
                for (key, value) in saved {
                    if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
                }
                NSApp.terminate(nil)
            }
        }
    }

    private static func shoot(into folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var images: [(id: Int, cg: CGImage)] = []
        do {
            // z 序 CGWindowList 还给得出，拿它来把最前的排最前。
            let pid = Int(ProcessInfo.processInfo.processIdentifier)
            let info = (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
            let order = info.filter { ($0["kCGWindowOwnerPID"] as? Int) == pid as Int? && ($0["kCGWindowLayer"] as? Int) == 0 }
                            .compactMap { $0["kCGWindowNumber"] as? Int }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let mine = content.windows
                .filter { w in
                    guard let own = w.owningApplication?.processID, own == pid_t(pid) else { return false }
                    return w.frame.width > 150 && w.frame.height > 80
                }
                .sorted { (order.firstIndex(of: Int($0.windowID)) ?? .max) < (order.firstIndex(of: Int($1.windowID)) ?? .max) }
            // 被盖住、屏幕睡着的窗 macOS 不渲染,截出来是黑的:先把 app 激活,逐扇置前,
            // 等一拍再截。
            NSApp.activate(ignoringOtherApps: true)
            for w in mine {
                if let live = NSApp.windows.first(where: { $0.windowNumber == w.windowID }) {
                    live.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(for: .milliseconds(400))
                }
                var config = SCStreamConfiguration()
                // 输出就照窗口的尺寸来(2x),不指定的话给的是整屏的缓冲,黑边得自己裁。
                config.width = Int(w.frame.width) * 2
                config.height = Int(w.frame.height) * 2
                config.showsCursor = false
                if let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: config) {
                    images.append((id: Int(w.windowID), cg: img))
                }
            }
        } catch {
            NSLog("debugShots: ScreenCaptureKit 不行（\(error)），退回自绘")
        }
        if images.isEmpty { images = selfDrawn() }
        for (i, shot) in images.enumerated() {
            let rep = NSBitmapImageRep(cgImage: shot.cg)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("\(i + 1).png"))
            }
        }
        NSLog("debugShots: \(images.count) 个窗口 → \(folder.path)")
    }

    /// 没有权限时的保底：自己画 contentView 的上一层（连标题栏一起）。SC 给不出才用。
    private static func selfDrawn() -> [(id: Int, cg: CGImage)] {
        var shots: [(id: Int, cg: CGImage)] = []
        for w in NSApp.windows {
            guard w.isVisible, let frameView = w.contentView?.superview else { continue }
            let rect = frameView.bounds
            guard rect.width > 150, rect.height > 80, let rep = frameView.bitmapImageRepForCachingDisplay(in: rect), let cg = rep.cgImage else { continue }
            frameView.cacheDisplay(in: rect, to: rep)
            shots.append((id: Int(w.windowNumber), cg: cg))
        }
        return shots
    }
}
#endif
