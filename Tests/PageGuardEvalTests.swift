import XCTest
import WebKit
@testable import Pathfinder

/// The guard script must leave the page's own code running as it would without it, while still reporting
/// obfuscated and miner code it finds in the page's scripts.
@MainActor
final class PageGuardEvalTests: XCTestCase {
    final class Collector: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { messages.append(body) }
        }
        func findings(_ kind: String) -> [[String: Any]] { messages.filter { $0["t"] as? String == "finding" && $0["kind"] as? String == kind } }
    }

    private func load(_ html: String, guarded: Bool = true, wait: TimeInterval = 1.5) async -> (WKWebView, Collector) {
        let collector = Collector()
        let config = WKWebViewConfiguration()
        config.userContentController.add(collector, name: PageGuardScript.handlerName)
        if guarded {
            config.userContentController.addUserScript(WKUserScript(
                source: PageGuardScript.source(mode: .monitor, allowedHosts: []), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        view.loadHTMLString(html, baseURL: URL(string: "https://site.test/watch"))
        try? await Task.sleep(for: .seconds(wait))
        return (view, collector)
    }

    private static let evalPage = """
    <html><body><script>
    function declares() { eval("var x = 41"); return x + 1; }
    function assigns() { var y = 1; eval("y = 2"); return y; }
    // Like a packed player script: the address is decoded into the caller's own variable.
    function player() { var source; eval("source = 'https://cdn.test/v/playlist.m3u8'"); return source || 'none'; }
    window.results = [declares(), assigns(), player(), typeof window.x];
    </script></body></html>
    """

    // SC-1: eval inside a function sees that function's variables, exactly as without the guard.
    func testSC1EvalKeepsLocalScope() async throws {
        let (plain, _) = await load(Self.evalPage, guarded: false)
        let (guarded, _) = await load(Self.evalPage)
        let expected = try await plain.evaluateJavaScript("JSON.stringify(window.results)") as? String
        let actual = try await guarded.evaluateJavaScript("JSON.stringify(window.results)") as? String
        XCTAssertEqual(expected, #"[42,2,"https://cdn.test/v/playlist.m3u8","undefined"]"#)
        XCTAssertEqual(actual, expected)
        let native = try await guarded.evaluateJavaScript("Function.prototype.toString.call(window.eval)") as? String
        XCTAssertTrue(native?.contains("[native code]") == true, native ?? "")
    }

    // SC-2: packed code in a page script is still reported.
    func testSC2PackedScriptIsReported() async {
        let (_, c) = await load("""
        <html><body><script>
        var before = 1;
        eval(function(p,a,c,k,e,d){e=function(c){return c};if(!''.replace(/^/,String)){while(c--){d[c]=k[c]||c}k=[function(e){return d[e]}];e=function(){return'\\\\w+'};c=1};while(c--){if(k[c]){p=p.replace(new RegExp('\\\\b'+e(c)+'\\\\b','g'),k[c])}}return p}('0 1=2',3,3,'var|packed|1'.split('|'),0,{}))
        </script></body></html>
        """, wait: 2)
        let hits = c.findings("malvertising").filter { ($0["title"] as? String)?.hasPrefix("Obfuscated code") == true }
        XCTAssertFalse(hits.isEmpty, "\(c.messages)")
        XCTAssertEqual(hits.first?["sev"] as? String, "low")
    }

    func testSC2ScriptAddedLaterIsReported() async {
        let (_, c) = await load("""
        <html><body><script>
        setTimeout(function () {
          var s = document.createElement('script');
          s.textContent = "var unused = function(){}; // eval(function(p,a,c,k,e,d){})";
          document.body.appendChild(s);
        }, 100);
        </script></body></html>
        """, wait: 1)
        XCTAssertFalse(c.findings("malvertising").filter { ($0["title"] as? String)?.hasPrefix("Obfuscated code") == true }.isEmpty,
                       "\(c.messages)")
    }

    func testSC2OrdinaryScriptIsNotReported() async {
        let (_, c) = await load("<html><body><script>var n = 0; for (var i = 0; i < 3; i++) n += i;</script></body></html>", wait: 2)
        XCTAssertTrue(c.messages.filter { $0["t"] as? String == "finding" }.isEmpty, "\(c.messages)")
    }

    // SC-3: miner code in a page script is still reported as high.
    func testSC3MinerCodeInScriptIsReported() async {
        let (_, c) = await load("""
        <html><body><script>
        if (window.CoinHive) { var miner = new CoinHive.Anonymous('key'); miner.start(); }
        </script></body></html>
        """, wait: 2)
        let hits = c.findings("cryptojacking")
        XCTAssertFalse(hits.isEmpty, "\(c.messages)")
        XCTAssertEqual(hits.first?["sev"] as? String, "high")
    }
}
