import SwiftUI

@main
struct YuyueApp: App {
    @State private var library = Result { try Library() }
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        // The shelf and each book get their own windows.
        Window(String(localized: "书架"), id: "library") {
            root
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            ReaderCommands()
        }

        WindowGroup(String(localized: "读书"), id: "reader", for: String.self) { $bookID in
            if let bookID, case .success(let library) = library {
                // A window given another book starts over, rather than keep the last one's state.
                ReaderScreen(library: library, bookID: bookID)
                    .id(bookID)
                    .environment(\.switchBook) { $bookID.wrappedValue = $0 }
            }
        }
        // A landscape window, the column in the middle and room for the notes beside it.
        .defaultSize(width: 1040, height: 720)
        // 58 high: the standard bar, not the compact one.
        .windowToolbarStyle(.unified(showsTitle: true))

        // 有声书 · Mac 上微调.
        WindowGroup(String(localized: "对齐检查"), id: "align", for: AlignTarget.self) { $target in
            if let target, case .success(let library) = library {
                AlignCheckWindow(library: library, target: target)
            }
        }
        .defaultSize(width: 1120, height: 740)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))

        Settings {
            if case .success(let library) = library {
                MacSettings(library: library)
            }
        }
        #else
        WindowGroup {
            root
        }
        #endif
    }

    @ViewBuilder private var root: some View {
        switch library {
        case .success(let library):
            #if os(macOS)
            MacShelfView(library: library)
            #else
            PhoneRoot(library: library)
            #endif
        case .failure(let error):
            ContentUnavailableView("打不开书库", systemImage: "exclamationmark.triangle", description: Text(Library.message(for: error)))
        }
    }
}

#if os(macOS)
/// Files opened with 语阅 from 访达 (or dropped on its icon). SwiftUI's `onOpenURL` hears only the
/// first of several opened together; this hears them all.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opened before the shelf was there to take them.
    @MainActor static var waiting: [URL] = []

    /// Started by macOS as a login item (开机时打开语阅): no window, only the menu bar.
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        DebugShots.run()
        #endif
        guard LoginItem.launchedAtLogin else { return }
        DispatchQueue.main.async {
            for w in NSApp.windows where w.identifier?.rawValue.hasPrefix("library") == true { w.close() }
        }
    }

    /// Closing the shelf leaves 语阅 running (the menu bar, a show's time to be written).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            Self.waiting += urls
            NotificationCenter.default.post(name: .filesOpened, object: nil)
        }
    }
}

extension Notification.Name {
    static let filesOpened = Notification.Name("yuyue.filesOpened")
    /// An episode's ‹ 播客: the shelf window opens on 播客, not on 全部.
    static let showPodcasts = Notification.Name("yuyue.showPodcasts")
}
#endif
