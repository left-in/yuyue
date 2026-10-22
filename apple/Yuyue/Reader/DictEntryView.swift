import SwiftUI
import WebKit

/// 完整释义: an MDict entry as the dictionary wrote it (HTML), in the card's own type and colours.
/// Its links and images stay inert; the entry is read, not browsed.
struct DictEntryView: View {
    let html: String

    var body: some View {
        EntryWeb(page: Self.page(html))
    }

    static func page(_ html: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; padding: 2px 2px 12px; font: 14px/1.6 -apple-system, "PingFang SC", sans-serif; color: #2A2B2E; background: transparent; overflow-wrap: anywhere; }
        @media (prefers-color-scheme: dark) { body { color: #E8E6E1; } a { color: #8FB0E0; } }
        img { max-width: 100%; height: auto; }
        a { color: #2B4C7E; pointer-events: none; text-decoration: none; }
        </style></head><body>\(html)</body></html>
        """
    }
}

#if os(macOS)
private struct EntryWeb: NSViewRepresentable {
    let page: String

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: Self.configuration)
        web.setValue(false, forKey: "drawsBackground")
        web.loadHTMLString(page, baseURL: nil)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}

    static var configuration: WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.defaultWebpagePreferences.allowsContentJavaScript = false
        return c
    }
}
#else
private struct EntryWeb: UIViewRepresentable {
    let page: String

    func makeUIView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: c)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.loadHTMLString(page, baseURL: nil)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
}
#endif
