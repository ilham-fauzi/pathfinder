import XCTest
import WebKit
@testable import Pathfinder

/// Loads real pages in WebKit with the guard script injected, and checks what it reports.
@MainActor
final class PageGuardRuntimeTests: XCTestCase {
    final class Collector: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { messages.append(body) }
        }
        func findings(_ kind: String) -> [[String: Any]] { messages.filter { $0["t"] as? String == "finding" && $0["kind"] as? String == kind } }
    }

    private func load(_ html: String, mode: WAFMode = .monitor, url: String = "https://site.test/page", wait: TimeInterval = 3.5) async -> Collector {
        let collector = Collector()
        let config = WKWebViewConfiguration()
        config.userContentController.add(collector, name: PageGuardScript.handlerName)
        config.userContentController.addUserScript(WKUserScript(
            source: PageGuardScript.source(mode: mode, allowedHosts: []), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700), configuration: config)
        view.loadHTMLString(html, baseURL: URL(string: url))
        try? await Task.sleep(for: .seconds(wait))
        withExtendedLifetime(view) {}
        return collector
    }

    func testWebShellPageIsRecognised() async {
        let c = await load("""
        <html><head><title>c99shell v.2</title></head><body>
        <pre>uname -a  Linux box 5.4  Safe-mode: OFF</pre>
        <form><input name="cmd"><input type="file"></form></body></html>
        """, url: "https://site.test/uploads/c99.php")
        XCTAssertFalse(c.findings("webShell").isEmpty, "\(c.messages)")
    }

    func testOrdinaryPageHasNoFindings() async {
        let c = await load("<html><head><title>Cat photos</title></head><body><h1>Cats</h1><a href='/x'>more</a></body></html>")
        XCTAssertTrue(c.messages.filter { $0["t"] as? String == "finding" }.isEmpty, "\(c.messages)")
    }

    func testMinerScriptAndMetaRefreshAndOverlay() async {
        let c = await load("""
        <html><head><meta http-equiv="refresh" content="1;url=https://evil.example/landing"></head><body>
        <script src="https://coinhive.com/lib/coinhive.min.js"></script>
        </body></html>
        """, wait: 3)
        XCTAssertFalse(c.findings("cryptojacking").isEmpty, "miner: \(c.messages)")
        XCTAssertFalse(c.findings("redirect").isEmpty, "redirect: \(c.messages)")
    }

    func testInvisibleClickCatchingLayerIsDetected() async {
        let c = await load("""
        <html><body><p>Watch the video</p>
        <a href="https://ads.example/x" style="position:fixed;top:0;left:0;width:100vw;height:100vh;opacity:0;z-index:99999"></a>
        </body></html>
        """, wait: 4)
        XCTAssertFalse(c.findings("malvertising").isEmpty, "overlay: \(c.messages)")
    }

    func testPayloadInFetchIsReportedAndBlockedInBlockMode() async {
        let page = """
        <html><body><script>
        window.result = 'pending';
        fetch('https://api.site.test/items?id=1%20UNION%20SELECT%20password%20FROM%20users')
          .then(function () { window.result = 'sent'; }, function (e) { window.result = 'blocked:' + e.message; });
        fetch('https://api.site.test/ok').catch(function () {});
        </script></body></html>
        """
        let monitor = await load(page, mode: .monitor, wait: 1.5)
        let hit = monitor.findings("injection").first
        XCTAssertNotNil(hit, "\(monitor.messages)")
        XCTAssertEqual(hit?["blocked"] as? Bool, false)
        let apis = monitor.messages.filter { $0["t"] as? String == "api" && $0["phase"] as? String == "start" }
        XCTAssertGreaterThanOrEqual(apis.count, 2)

        let block = await load(page, mode: .block, wait: 1.5)
        XCTAssertEqual(block.findings("injection").first?["blocked"] as? Bool, true, "\(block.messages)")
    }

    func testBlockModeStopsPopupWithoutClick() async {
        let c = await load("<html><body><script>window.open('https://ads.example/'); </script></body></html>", mode: .block, wait: 1)
        XCTAssertEqual(c.findings("malvertising").first?["blocked"] as? Bool, true, "\(c.messages)")
    }

    func testFirewallOffReportsNothingAboutPayloads() async {
        let c = await load("<html><body><script>fetch('https://api.site.test/?q=<script>alert(1)</script>').catch(function(){});</script></body></html>",
                           mode: .off, wait: 1)
        XCTAssertTrue(c.findings("injection").isEmpty)
    }

    func testReflectedXSSIsDetected() async {
        let payload = "%3Cimg%20src%3Dx%20onerror%3Dalert(1)%3E"
        let c = await load("<html><body><img src=x onerror=alert(1)></body></html>", url: "https://site.test/s?q=\(payload)")
        XCTAssertFalse(c.findings("injection").isEmpty, "\(c.messages)")
    }

    func testApiCallsCarryHeadersBodyAndResponse() async {
        let c = await load("""
        <html><body><script>
        fetch('https://api.site.test/v1/items?id=7', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Token': 'abc' },
                                                        body: JSON.stringify({ name: 'x' }) }).catch(function () {});
        var x = new XMLHttpRequest(); x.open('PUT', 'https://api.site.test/v1/other'); x.setRequestHeader('X-Req', '1'); x.send('a=b');
        </script></body></html>
        """, wait: 1.5)
        let starts = c.messages.filter { $0["t"] as? String == "api" && $0["phase"] as? String == "start" }
        let post = starts.first { $0["method"] as? String == "POST" }
        XCTAssertEqual(post?["body"] as? String, #"{"name":"x"}"#, "\(c.messages)")
        let headers = (post?["headers"] as? [[String]]) ?? []
        XCTAssertTrue(headers.contains(["Content-Type", "application/json"]) && headers.contains(["X-Token", "abc"]), "\(headers)")
        XCTAssertEqual(post?["page"] as? String, "https://site.test/page")
        let put = starts.first { $0["method"] as? String == "PUT" }
        XCTAssertEqual(put?["body"] as? String, "a=b")
        XCTAssertTrue(((put?["headers"] as? [[String]]) ?? []).contains(["X-Req", "1"]))
    }
}
