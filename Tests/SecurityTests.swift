import XCTest
@testable import Pathfinder

final class SecurityTests: XCTestCase {
    private func ids(_ text: String) -> Set<String> { Set(WAFRules.scan(text).map(\.id)) }

    // MARK: Firewall rules

    func testSQLInjectionPayloadsAreCaught() {
        XCTAssertTrue(ids("id=1 UNION SELECT username,password FROM users").contains("sqli-union"))
        XCTAssertTrue(ids("id=1%20UNION%20ALL%20SELECT%20NULL--").contains("sqli-union"))
        XCTAssertTrue(ids("name=' OR '1'='1").contains("sqli-tautology") || ids("name=' OR '1'='1").contains("sqli-quote-or"))
        XCTAssertTrue(ids("id=1 or 1=1").contains("sqli-tautology"))
        XCTAssertTrue(ids("q=1; DROP TABLE users").contains("sqli-stacked"))
        XCTAssertTrue(ids("id=1 AND SLEEP(5)").contains("sqli-time"))
        XCTAssertTrue(ids("id=1 from information_schema.tables").contains("sqli-schema"))
    }

    func testScriptInjectionPayloadsAreCaught() {
        XCTAssertTrue(ids("q=<script>alert(1)</script>").contains("xss-script"))
        XCTAssertTrue(ids("q=%3Cscript%3Ealert(1)%3C%2Fscript%3E").contains("xss-script"))
        XCTAssertTrue(ids("q=%253Cscript%253E").contains("xss-script"))   // double-encoded
        XCTAssertTrue(ids("q=<img src=x onerror=alert(1)>").contains("xss-handler"))
        XCTAssertTrue(ids("q=\" onmouseover=\"alert(1)").contains("xss-handler"))
        XCTAssertTrue(ids("next=javascript:alert(1)").contains("xss-js-url"))
    }

    func testTraversalAndCommandInjectionAreCaught() {
        XCTAssertTrue(ids("file=../../../etc/passwd").contains("lfi-traversal"))
        XCTAssertTrue(ids("file=%2e%2e%2f%2e%2e%2fwin.ini").contains("lfi-traversal"))
        XCTAssertTrue(ids("host=1.1.1.1; cat /etc/hosts").contains("rce-shell"))
        XCTAssertTrue(ids("host=$(whoami)").contains("rce-shell"))
        XCTAssertTrue(ids("x=<?php system($_GET['c']); ?>").contains("rce-php"))
    }

    func testOrdinaryAddressesAreNotFlagged() {
        let normal = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL123&t=42s",
            "https://example.com/search?q=cats+and+dogs&page=2",
            "https://example.com/path;id=5/page?x=1&y=2",
            "https://github.com/user/repo/blob/main/src/union_select.swift",
            "https://shop.example.com/cart?item=shirt&size=M&color=black",
            "https://example.com/redirect?url=https%3A%2F%2Fexample.org%2Fa%3Fb%3Dc",
            "https://cdn.example.com/video/master.m3u8?token=abc123-def_456",
            "https://example.com/a/b/c/../d",
        ]
        for url in normal {
            XCTAssertTrue(WAFRules.inspect(URL(string: url)!).isEmpty, "false positive: \(url) → \(WAFRules.inspect(URL(string: url)!).map(\.id))")
        }
    }

    func testRuleSeverityDecidesBlocking() {
        XCTAssertEqual(WAFRules.rules.first { $0.id == "sqli-union" }?.severity, .high)
        XCTAssertEqual(WAFRules.rules.first { $0.id == "xss-js-url" }?.severity, .medium)
    }

    func testEveryRuleCompilesInSwiftAndJSON() throws {
        for rule in WAFRules.rules {
            XCTAssertNoThrow(try NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]), rule.id)
        }
        let json = try JSONSerialization.jsonObject(with: Data(WAFRules.json.utf8)) as? [[String: String]]
        XCTAssertEqual(json?.count, WAFRules.rules.count)
    }

    func testMinerContentRulesAreValidJSON() throws {
        let rules = try JSONSerialization.jsonObject(with: Data(WAFRules.contentRulesJSON().utf8)) as? [[String: Any]]
        XCTAssertEqual(rules?.count, WAFRules.minerHosts.count + WAFRules.maliciousHosts.count)
        XCTAssertTrue(WAFRules.isMinerHost("pool.coinhive.com"))
        XCTAssertFalse(WAFRules.isMinerHost("notcoinhive.com.example.org"))
    }

    // MARK: Downloads

    func testExecutableAndDisguisedFiles() {
        XCTAssertTrue(RiskyFile.isExecutable("setup.exe"))
        XCTAssertTrue(RiskyFile.isExecutable("Installer.DMG"))
        XCTAssertFalse(RiskyFile.isExecutable("holiday.mp4"))
        XCTAssertTrue(RiskyFile.isDisguised("invoice.pdf.exe"))
        XCTAssertTrue(RiskyFile.isDisguised("photo.jpg.scr"))
        XCTAssertFalse(RiskyFile.isDisguised("setup.exe"))
        XCTAssertFalse(RiskyFile.isDisguised("archive.tar.gz"))
    }

    func testDispositionFileName() {
        XCTAssertEqual(SecurityCenter.fileName(fromDisposition: "attachment; filename=\"a b.pdf\""), "a b.pdf")
        XCTAssertEqual(SecurityCenter.fileName(fromDisposition: "attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf"), "résumé.pdf")
        XCTAssertNil(SecurityCenter.fileName(fromDisposition: "inline"))
    }

    func testSiteGrouping() {
        XCTAssertEqual(SecurityCenter.site(of: "api.example.com"), "example.com")
        XCTAssertEqual(SecurityCenter.site(of: "www.example.co.uk"), "example.co.uk")
        XCTAssertEqual(SecurityCenter.site(of: "localhost"), "localhost")
    }

    // MARK: Page script

    func testPageScriptIsInjectedWithSettings() {
        let script = PageGuardScript.source(mode: .block, allowedHosts: ["trusted.example"])
        XCTAssertTrue(script.contains("var MODE = 'block'"))
        XCTAssertTrue(script.contains("[\"trusted.example\"]"))
        XCTAssertFalse(script.contains("%MODE%") || script.contains("%RULES%") || script.contains("%ALLOWED%") || script.contains("%MINERHOSTS%"))
        if let dir = ProcessInfo.processInfo.environment["PF_SCRIPT_OUT"] {
            try? script.write(toFile: dir + "/guard.js", atomically: true, encoding: .utf8)
        }
    }

    // MARK: Response headers

    func testFirewallDetectionFromHeaders() {
        XCTAssertEqual(WAFRules.firewall(in: ["CF-Ray": "abc-LHR", "Server": "cloudflare"]), "Cloudflare")
        XCTAssertEqual(WAFRules.firewall(in: ["X-Sucuri-ID": "1"]), "Sucuri")
        XCTAssertNil(WAFRules.firewall(in: ["Server": "nginx"]))
    }

    // MARK: File integrity

    func testFileIntegrityDetectsChangeAndDeletion() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pf-fim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("report.pdf")
        try Data("original".utf8).write(to: file)

        let fim = await FileIntegrityMonitor()
        await fim.record(path: file.path, source: .manual)
        await fim.verify(deep: true)
        var state = await fim.states[file.path]
        XCTAssertEqual(state, .ok)

        try Data("tampered".utf8).write(to: file)   // same size, different contents
        await fim.verify(deep: true)
        state = await fim.states[file.path]
        XCTAssertEqual(state, .modified)

        await fim.accept(file.path)
        await fim.verify(deep: true)
        state = await fim.states[file.path]
        XCTAssertEqual(state, .ok)

        try FileManager.default.removeItem(at: file)
        await fim.verify(deep: false)
        state = await fim.states[file.path]
        XCTAssertEqual(state, .missing)
        await fim.remove(file.path)
    }

    func testProgramPretendingToBeADocumentIsNoted() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString).jpg")
        try Data([0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNotNil(FileIntegrityMonitor.inspect(file.path))
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: file)
        XCTAssertNil(FileIntegrityMonitor.inspect(file.path))
    }

    func testKnownSHA256() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString).txt")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(FileIntegrityMonitor.hash(of: file.path), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
