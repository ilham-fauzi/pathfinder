import XCTest
import SwiftUI
import WebKit
@testable import Pathfinder

@MainActor
final class PageMenuTests: XCTestCase {
    /// A page that takes over right-click, the way many video sites do.
    private static let hijackingPage = """
    <html><body><div id='t'>video</div><script>
    window.pageSaw = 0;
    document.addEventListener('contextmenu', function (e) { window.pageSaw++; e.preventDefault(); });
    document.oncontextmenu = function () { window.pageSaw++; return false; };
    </script></body></html>
    """

    private func load(_ html: String) async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(
            source: PageMenu.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        view.loadHTMLString(html, baseURL: URL(string: "https://site.test/watch"))
        for _ in 0..<50 where view.isLoading { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(200))
        return view
    }

    /// Fires a right-click at the page and returns whether its default (WebKit's menu) was cancelled.
    private func rightClick(_ view: WKWebView, option: Bool) async throws -> (cancelled: Bool, pageSaw: Int) {
        let result = try await view.callAsyncJavaScript("""
        const before = window.pageSaw;
        const e = new MouseEvent('contextmenu', { bubbles: true, cancelable: true, altKey: alt, button: 2 });
        document.getElementById('t').dispatchEvent(e);
        return [e.defaultPrevented, window.pageSaw - before];
        """, arguments: ["alt": option], contentWorld: .page) as? [Any]
        let cancelled = (result?.first as? NSNumber)?.boolValue ?? true
        let saw = (result?.last as? NSNumber)?.intValue ?? -1
        return (cancelled, saw)
    }

    // SC-9: Option-right-click gets past the site's handlers; a plain right-click is still the site's.
    func testSC9OptionRightClickBypassesSiteMenu() async throws {
        let view = try await load(Self.hijackingPage)
        let option = try await rightClick(view, option: true)
        XCTAssertFalse(option.cancelled)
        XCTAssertEqual(option.pageSaw, 0)

        let plain = try await rightClick(view, option: false)
        XCTAssertTrue(plain.cancelled)
        XCTAssertEqual(plain.pageSaw, 2)
    }

    func testSC9ScriptIsInstalledInBrowserTabs() async throws {
        UserDefaults.standard.set(false, forKey: "browserAdBlock")
        let browser = BrowserModel()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(browser.webView is PageWebView)
        browser.webView.loadHTMLString(Self.hijackingPage, baseURL: URL(string: "https://site.test/watch"))
        for _ in 0..<50 where browser.webView.isLoading { try await Task.sleep(for: .milliseconds(100)) }
        let option = try await rightClick(browser.webView, option: true)
        XCTAssertFalse(option.cancelled)
        XCTAssertEqual(option.pageSaw, 0)
    }

    // SC-10: Option-Command-I opens the inspector of the shown tab.
    func testSC10ShowWebInspectorCommand() async throws {
        XCTAssertEqual(BrowserCommands.inspectorShortcut, KeyboardShortcut("i", modifiers: [.command, .option]))
        UserDefaults.standard.set(false, forKey: "browserAdBlock")
        let browser = BrowserModel()
        XCTAssertTrue(browser.webView.isInspectable)
        XCTAssertNotNil(BrowserModel.inspector(of: browser.webView), "WebKit's inspector should be reachable for the tab")
    }

    // SC-11: the page menu lists the streams, the one under the pointer first, each with Download and Copy Stream Link.
    func testSC11MenuListsStreamsWithActions() throws {
        let first = DetectedStream(url: "https://cdn.test/a/master.m3u8", pageURL: "https://site.test/watch", title: "", type: .hls)
        let second = DetectedStream(url: "https://cdn.test/b/movie.mp4", pageURL: "https://site.test/watch", title: "", type: .direct)
        var downloaded: [String] = []
        var copied: [String] = []
        let items = PageMenu.items(streams: [first, second], underCursor: second.url,
                                   download: { downloaded.append($0.url) }, copy: { copied.append($0.url) })

        XCTAssertEqual(items.first?.title, "Streams on this page")
        let streamItems = items.filter { $0.submenu != nil }
        XCTAssertEqual(streamItems.map(\.toolTip), [second.url, first.url])
        for item in streamItems {
            XCTAssertEqual(item.submenu?.items.map(\.title), ["Download", "Copy Stream Link"])
        }
        let sub = try XCTUnwrap(streamItems.first?.submenu)
        (sub.items[0] as? ClosureMenuItem)?.run()
        (sub.items[1] as? ClosureMenuItem)?.run()
        XCTAssertEqual(downloaded, [second.url])
        XCTAssertEqual(copied, [second.url])

        XCTAssertTrue(PageMenu.items(streams: [], underCursor: nil, download: { _ in }, copy: { _ in }).isEmpty)
        XCTAssertEqual(PageMenu.ordered([first, second], underCursor: nil).map(\.url), [first.url, second.url])
    }

    func testSC11PageWebViewAddsItemsToNativeMenu() {
        let view = PageWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let stream = DetectedStream(url: "https://cdn.test/a.m3u8", pageURL: "", title: "", type: .hls)
        view.extraMenuItems = { PageMenu.items(streams: [stream], underCursor: nil, download: { _ in }, copy: { _ in }) }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Inspect Element", action: nil, keyEquivalent: ""))
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.willOpenMenu(menu, with: event)
        XCTAssertEqual(menu.items.first?.title, "Streams on this page")
        XCTAssertEqual(menu.items.last?.title, "Inspect Element")
    }
}
