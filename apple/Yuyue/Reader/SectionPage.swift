import Foundation
import WebKit
import YuyueCore

/// A message from the reader script (docs/dev/reader-contract.md §5).
struct ReaderMessage: Decodable {
    enum Kind: String, Decodable {
        case ready, layout, tap, doubleTap, activePage, page, scroll, log, selection
    }

    struct Link: Decodable {
        let target: String?
        let external: String?
        /// A note marker: what it shows and the words before it.
        let note: Note?
    }

    struct Note: Decodable {
        let label: String
        let before: String
    }

    struct Point: Codable, Equatable {
        let s: Int
        let o: Int
    }

    struct Rect: Decodable {
        let x, y, width, height: Double
    }

    /// 点词: the word clicked in a book read in another language.
    struct Word: Decodable {
        let text: String
        let start: Point
        let end: Point
        /// The sentence it is in.
        let sentence: String
        let rect: Rect
    }

    let type: Kind
    let section: UInt32?
    let pageCount: Int?
    let pageWidth: Double?
    let sentencePages: [Int]?
    let pageFirstSentence: [Int]?
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let sentence: Int?
    let link: Link?
    let mark: String?
    let word: Word?
    let start: Point?
    let end: Point?
    let text: String?
    let rect: Rect?
    let page: Int?
    let progress: Double?
    let level: String?
    let message: String?

    init?(body: Any) {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              let message = try? JSONDecoder().decode(ReaderMessage.self, from: data)
        else { return nil }
        self = message
    }
}

/// Where the pages of a laid-out section fall (from `ready` / `layout`).
struct SectionLayout: Equatable {
    var pageCount: Int
    var sentencePages: [Int]
    var pageFirstSentence: [Int]

    init?(_ m: ReaderMessage) {
        guard let pageCount = m.pageCount else { return nil }
        self.pageCount = max(1, pageCount)
        sentencePages = m.sentencePages ?? []
        pageFirstSentence = m.pageFirstSentence ?? []
    }

    func page(of sentence: Int) -> Int {
        sentencePages.indices.contains(sentence) ? sentencePages[sentence] : 0
    }

    /// The sentence that stands for a page, as a reading position and as the place to start
    /// reading aloud: the first one that starts on it, so going back to it brings back this
    /// page rather than the one before. The reader keeps the same sentence in view through a
    /// new layout. A page inside one long sentence stands for that sentence; a page of
    /// pictures, for the page before it.
    func firstSentence(on page: Int) -> Int {
        var p = min(page, pageFirstSentence.count - 1)
        while p >= 0, pageFirstSentence[p] < 0 { p -= 1 }
        guard p >= 0 else { return 0 }
        let first = pageFirstSentence[p]
        // The first sentence visible may have begun on the page before, and sentences without
        // a box count as on the page of the one before them.
        var s = first
        while sentencePages.indices.contains(s), sentencePages[s] <= p {
            if sentencePages[s] == p { return s }
            s += 1
        }
        return first
    }
}

/// The WebView for one section. On the Mac it also takes the page-turn keys.
final class ReaderWebView: WKWebView {
    #if os(macOS)
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    // In the key window, arrow and page keys can arrive here before `keyDown`, and WebKit
    // takes what it gets here to scroll the page by itself. Turning pages is the pager's job.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.firstResponder === self, onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override var acceptsFirstResponder: Bool { true }

    /// The reader's own right-click items, in place of WebKit's.
    var menuItems: (() -> [NSMenuItem])?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let items = menuItems?(), !items.isEmpty else { return }
        menu.removeAllItems()
        items.forEach(menu.addItem)
    }
    #else
    /// Selected words get 语阅's own card (划线 · 想法 · 从这读 · 翻译 · 复制), not the system's
    /// bubble over it.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        builder.remove(menu: .standardEdit)
        builder.remove(menu: .lookup)
        builder.remove(menu: .share)
        builder.remove(menu: .learn)
        builder.remove(menu: .replace)
    }
    #endif
}

#if os(macOS)
/// A menu item that runs a closure.
func ActionMenuItem(_ title: String, symbol: String? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = [], run: @escaping () -> Void) -> NSMenuItem {
    let action = MenuAction(run)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    item.target = action
    // The item holds on to its target this way; `target` itself is weak.
    item.representedObject = action
    if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    return item
}

private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}
#endif

/// One section of the book, shown by the pager.
final class SectionPage {
    enum Target: Equatable {
        case start, end
        case page(Int)
        case sentence(Int, align: Align = .top)
        case anchor(String, align: Align = .top)
    }

    /// Where a sentence or an anchor goes when scrolling (paginated mode shows its page either way):
    /// `top` starts the screen with its line, for a reading position or a chapter; `third` puts it a
    /// third of the way down, so what leads up to it stays in view, for the voice or a link.
    enum Align: String {
        case top, third
    }

    let webView: ReaderWebView
    private(set) var section: UInt32?
    private(set) var layout: SectionLayout?
    /// The page showing, as far as native knows.
    var page = 0
    /// In scrolled mode, the first sentence in view (from `scroll`).
    var scrolledTo: Int?
    /// Where to go once the section is laid out.
    private var target: Target?
    /// Goes up with every load and every clear. It is in the document's address, so messages
    /// from a document this view has since replaced can be told apart, and work that awaited
    /// the WebView can tell whether the page still shows what it started on.
    private(set) var generation = 0
    /// Called when a newly loaded section has been laid out and positioned.
    var onReady: ((SectionPage) -> Void)?

    init(configuration: WKWebViewConfiguration, background: PlatformColor) {
        webView = ReaderWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), configuration: configuration)
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = background
        let scroll = webView.scrollView
        scroll.backgroundColor = background
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.isDirectionalLockEnabled = true
        scroll.decelerationRate = .fast
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 1
        scroll.pinchGestureRecognizer?.isEnabled = false
        #else
        webView.underPageBackgroundColor = background
        #endif
        webView.allowsLinkPreview = false
        #if DEBUG
        webView.isInspectable = true
        // WebKit stops drawing in a window that is fully covered. Debug builds keep drawing, so the
        // app can be checked from screenshots while it runs behind other windows.
        let occlusion = Selector(("_setWindowOcclusionDetectionEnabled:"))
        if webView.responds(to: occlusion) { webView.perform(occlusion, with: nil) }
        #endif
    }

    func load(bookID: String, section: UInt32, target: Target) {
        generation += 1
        self.section = section
        self.target = target
        layout = nil
        settling = false
        page = 0
        scrolledTo = nil
        webView.alphaValue = 0
        // The query is for telling documents apart only; the scheme handler serves by path.
        let url = "\(SchemeHandler.origin)/book/\(bookID)/s/\(section).html?g=\(generation)"
        webView.load(URLRequest(url: URL(string: url)!))
    }

    /// Forget the section, so the view can be reused.
    func clear() {
        generation += 1
        section = nil
        layout = nil
        settling = false
        target = nil
        webView.stopLoading()
    }

    /// Whether a message comes from the document this page loaded last. Until the next one
    /// takes its place, the one before can still be sending messages about another section.
    func sentByCurrentDocument(_ frame: WKFrameInfo) -> Bool {
        guard frame.isMainFrame, let url = frame.request.url,
              let g = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "g" })?.value
        else { return false }
        return g == String(generation)
    }

    /// Takes the pages a `ready` or `layout` message describes, as the message arrives: a `page`
    /// message right behind it is then read against these pages, not the ones before.
    func take(_ m: ReaderMessage) {
        guard m.type == .ready || m.type == .layout, let layout = SectionLayout(m) else { return }
        self.layout = layout
        settling = true
    }

    /// From `take` until `settle` is done. A `page` message meanwhile reports where the new layout
    /// left the reader, not a move of the reader's own.
    private(set) var settling = false

    /// After `take`: a newly loaded section goes to its target and shows itself (returns true); one
    /// laid out again learns which page the reader kept in view.
    func settle() async -> Bool {
        guard let layout else { return false }
        let generation = generation
        defer { if generation == self.generation { settling = false } }
        if let target {
            self.target = nil
            await go(to: target, animated: false)
            // Recycled meanwhile: the new section shows itself when it is ready.
            guard generation == self.generation else { return false }
            webView.alphaValue = 1
            onReady?(self)
            return true
        }
        // A re-layout keeps the first visible sentence in view, which may move it to another page.
        if let p = await ask("yy.currentPage()") as? Int, generation == self.generation {
            page = min(p, layout.pageCount - 1)
        }
        return false
    }

    var isReady: Bool { layout != nil && target == nil }

    func go(to target: Target, animated: Bool) async {
        guard let layout else {
            self.target = target
            return
        }
        let generation = generation
        let last = layout.pageCount - 1
        let landed: Any?
        switch target {
        case .start: landed = await ask("yy.scrollToPage(p, a), p", ["p": 0, "a": animated])
        case .end: landed = await ask("yy.scrollToPage(p, a), p", ["p": last, "a": animated])
        case .page(let p): landed = await ask("yy.scrollToPage(p, a), p", ["p": min(max(p, 0), last), "a": animated])
        case .sentence(let s, let align): landed = await ask("yy.scrollToSentence(s, a, { align })", ["s": s, "a": animated, "align": align.rawValue])
        case .anchor(let id, let align): landed = await ask("yy.scrollToAnchor(id, a, { align })", ["id": id, "a": animated, "align": align.rawValue])
        }
        if let p = landed as? Int, p >= 0, generation == self.generation { page = min(p, last) }
    }

    /// Runs `expression` with `window.yy`; arguments arrive as JavaScript values.
    func call(_ expression: String, _ arguments: [String: Any] = [:]) {
        webView.callAsyncJavaScript("if (window.yy) \(expression);", arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }

    /// Like `call`, for calls whose answer matters.
    func ask(_ expression: String, _ arguments: [String: Any] = [:]) async -> Any? {
        let value = try? await webView.callAsyncJavaScript("return window.yy ? (\(expression)) : null;", arguments: arguments, contentWorld: .page)
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        return value
    }
}

/// Serves `yuyue://local/…` (reader contract §1): the reader bundle from the app, books from the core.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "yuyue"
    static let origin = "yuyue://local"
    /// `reader/dist`, copied into the app as a folder.
    private static let bundle = Bundle.main.resourceURL!.appending(path: "dist", directoryHint: .isDirectory)

    private let core: YuyueCore
    var geometry: () -> PageGeometry

    init(core: YuyueCore, geometry: @escaping () -> PageGeometry) {
        self.core = core
        self.geometry = geometry
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = url.path(percentEncoded: true)
        if path.hasPrefix("/app/") {
            let name = String(path.dropFirst("/app/".count))
            let file = Self.bundle.appending(path: name)
            guard !name.contains(".."), let data = try? Data(contentsOf: file) else { return respond(task, url, status: 404) }
            return respond(task, url, data: data, mime: name.hasSuffix(".css") ? "text/css" : "text/javascript")
        }
        switch core.serve(path: path, geometry: geometry()) {
        case .html(let body):
            respond(task, url, data: Data(body.utf8), mime: "text/html; charset=utf-8")
        case .file(let file, let mime):
            if let data = try? Data(contentsOf: URL(filePath: file), options: .mappedIfSafe) {
                respond(task, url, data: data, mime: mime)
            } else {
                respond(task, url, status: 404)
            }
        case .notFound:
            respond(task, url, status: 404)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, _ url: URL, status: Int = 200, data: Data = Data(), mime: String = "text/plain") {
        let headers = ["Content-Type": mime, "Content-Length": String(data.count), "Cache-Control": "no-store"]
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}

/// Receives the reader's messages for every page of one pager. WebKit keeps its handlers
/// alive, so this holds the pager weakly.
final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var receiver: ReaderPager?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let m = ReaderMessage(body: message.body) else { return }
        if m.type == .log {
            #if DEBUG
            FileHandle.standardError.write(Data("reader \(m.level ?? ""): \(m.message ?? "")\n".utf8))
            #endif
            return
        }
        receiver?.received(m, from: webView, frame: message.frameInfo)
    }
}

extension WKWebViewConfiguration {
    static func reader(schemeHandler: SchemeHandler, messages: MessageProxy) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: SchemeHandler.scheme)
        configuration.userContentController.add(messages, name: "yy")
        configuration.suppressesIncrementalRendering = true
        // Nothing in a book needs to reach the network; the documents' CSP forbids it as well.
        configuration.websiteDataStore = .nonPersistent()
        #if os(iOS)
        configuration.dataDetectorTypes = []
        configuration.allowsInlineMediaPlayback = true
        #endif
        return configuration
    }
}

#if os(iOS)
import UIKit
typealias PlatformColor = UIColor

extension UIView {
    /// Matches AppKit's name, so shared code can fade views on both platforms.
    var alphaValue: CGFloat {
        get { alpha }
        set { alpha = newValue }
    }
}
#else
import AppKit
typealias PlatformColor = NSColor
#endif
