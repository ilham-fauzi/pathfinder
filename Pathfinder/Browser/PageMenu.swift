import AppKit
import SwiftUI
import WebKit

/// The browser's own right-click menu on a page. Many video sites replace or cancel the page's right-click;
/// Option-right-click always gets WebKit's native menu (with Inspect Element) plus the streams found on the page.
enum PageMenu {
    static let handlerName = "pfPageMenu"

    /// Runs first in every frame (document start), so its listener is ahead of any the site adds.
    /// It notes the video under the pointer, and with Option held it stops the event before the site sees it,
    /// which leaves the default action (WebKit's menu) in place.
    static let script = #"""
    (function () {
        if (window.__pfPageMenu) return;
        window.__pfPageMenu = true;
        window.addEventListener('contextmenu', function (e) {
            var src = '';
            try {
                var under = document.elementsFromPoint ? document.elementsFromPoint(e.clientX, e.clientY) : [e.target];
                for (var i = 0; i < under.length; i++) {
                    var el = under[i];
                    if (el && (el.tagName === 'VIDEO' || el.tagName === 'AUDIO')) { src = el.currentSrc || el.src || ''; break; }
                }
            } catch (x) {}
            try { window.webkit.messageHandlers.pfPageMenu.postMessage({ src: /^https?:/i.test(src) ? src : '' }); } catch (x) {}
            if (e.altKey) e.stopImmediatePropagation();
        }, true);
    })();
    """#

    /// What the menu lists: every detected stream, the one under the pointer first.
    static func ordered(_ streams: [DetectedStream], underCursor: String?) -> [DetectedStream] {
        guard let underCursor, let i = streams.firstIndex(where: { $0.url == underCursor }) else { return streams }
        var result = streams
        result.insert(result.remove(at: i), at: 0)
        return result
    }

    /// "Streams on this page", then one submenu per stream with Download and Copy Stream Link. Empty without streams.
    @MainActor
    static func items(streams: [DetectedStream], underCursor: String?,
                      download: @escaping (DetectedStream) -> Void, copy: @escaping (DetectedStream) -> Void) -> [NSMenuItem] {
        let list = ordered(streams, underCursor: underCursor)
        guard !list.isEmpty else { return [] }
        let header = NSMenuItem(title: "Streams on this page", action: nil, keyEquivalent: "")
        header.isEnabled = false
        var items = [header]
        for stream in list {
            let item = NSMenuItem(title: stream.displayName, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: stream.displayName)
            sub.addItem(ClosureMenuItem("Download") { download(stream) })
            sub.addItem(ClosureMenuItem("Copy Stream Link") { copy(stream) })
            item.submenu = sub
            item.toolTip = stream.url
            items.append(item)
        }
        items.append(.separator())
        return items
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc func run() { handler() }
}

/// A tab's web view: adds the page's streams to WebKit's own right-click menu.
final class PageWebView: WKWebView {
    var extraMenuItems: (() -> [NSMenuItem])?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for (i, item) in (extraMenuItems?() ?? []).enumerated() { menu.insertItem(item, at: i) }
    }
}

final class PageMenuScriptHandler: NSObject, WKScriptMessageHandler {
    weak var model: BrowserModel?

    init(model: BrowserModel? = nil) {
        self.model = model
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let src = (message.body as? [String: Any])?["src"] as? String
        let webView = message.webView
        MainActor.assumeIsolated { model?.noteMenuVideo(src, in: webView) }
    }
}

/// View ▸ Show Web Inspector, for pages whose right-click menu is taken over by the site.
struct BrowserCommands: Commands {
    static let inspectorShortcut = KeyboardShortcut("i", modifiers: [.command, .option])
    let browser: BrowserModel

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Show Web Inspector") { browser.showWebInspector() }
                .keyboardShortcut(Self.inspectorShortcut)
        }
    }
}
