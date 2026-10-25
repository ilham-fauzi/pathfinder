import XCTest
import WebKit
@testable import Pathfinder

/// Where tests may write: `TMPDIR` when set (a sandboxed run gives its own), else the user's temporary folder.
func writableTemporaryDirectory() -> URL {
    if let dir = ProcessInfo.processInfo.environment["TMPDIR"], !dir.isEmpty {
        return URL(fileURLWithPath: dir, isDirectory: true)
    }
    return FileManager.default.temporaryDirectory
}

/// A small local site served by python3, for loading real pages into the browser.
final class LocalSite {
    let root: URL
    let base: String
    private let server: Process

    init(files: [String: String]) async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("python3 not available") }
        root = writableTemporaryDirectory().appendingPathComponent("pf-site-\(UUID().uuidString)", isDirectory: true)
        for (path, body) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        let port = Int.random(in: 20000...40000)
        server = Process()
        server.executableURL = python
        server.arguments = ["-c", """
        import http.server, functools
        class H(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *a): pass
        http.server.ThreadingHTTPServer(('127.0.0.1', \(port)), functools.partial(H, directory='\(root.path)')).serve_forever()
        """]
        try server.run()
        base = "http://127.0.0.1:\(port)"
        for _ in 0..<50 {
            if (try? await URLSession.shared.data(from: URL(string: base + "/")!)) != nil { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func stop() {
        server.terminate()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
final class StreamDiscoveryTests: XCTestCase {
    private var site: LocalSite?
    private var logURL: URL!

    override func setUp() async throws {
        logURL = writableTemporaryDirectory().appendingPathComponent("stream-check-\(UUID()).log")
        StreamCheckLog.fileURLOverride = logURL
    }

    override func tearDown() async throws {
        site?.stop()
        StreamCheckLog.fileURLOverride = nil
        try? FileManager.default.removeItem(at: logURL)
    }

    /// 200 s of video: long enough to be taken as the main video.
    private static let playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:100\n#EXTINF:100.0,\nseg0.ts\n#EXTINF:100.0,\nseg1.ts\n#EXT-X-ENDLIST\n"

    private func serve(_ files: [String: String]) async throws -> LocalSite {
        let s = try await LocalSite(files: files)
        site = s
        return s
    }

    /// A browser with ad blocking off, on `path` of the site, with its scripts in place.
    private func open(_ path: String, on site: LocalSite) async throws -> BrowserModel {
        UserDefaults.standard.set(false, forKey: "browserAdBlock")
        let browser = BrowserModel()
        try await Task.sleep(for: .milliseconds(300))
        browser.go(site.base + path)
        for _ in 0..<100 where browser.webView.isLoading || browser.webView.url?.path != path {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(500))
        return browser
    }

    // SC-1: a <video> playing an address the sniffer does not recognise, in the page and in a frame.
    func testSC1VideoSourceInPageAndFrameIsRecovered() async throws {
        let site = try await serve([
            "page.html": "<html><body><video src='/get_file/1/abc/'></video><iframe src='/frame.html'></iframe></body></html>",
            "frame.html": "<html><body><video src='/get_file/2/def/'></video></body></html>",
        ])
        let browser = try await open("/page.html", on: site)
        XCTAssertFalse(browser.detectedStreams.contains { $0.url.contains("/get_file/") }, "the sniffer should miss these")

        await browser.recoverStreams()
        let urls = browser.detectedStreams.map(\.url)
        XCTAssertTrue(urls.contains(site.base + "/get_file/1/abc/"), "\(urls)")
        XCTAssertTrue(urls.contains(site.base + "/get_file/2/def/"), "\(urls)")
        let frameStream = try XCTUnwrap(browser.detectedStreams.first { $0.url.hasSuffix("/get_file/2/def/") })
        XCTAssertEqual(frameStream.frame?.isMainFrame, false)

        // Offered by the page's right-click menu as well.
        let titles = PageMenu.items(streams: browser.detectedStreams, underCursor: nil, download: { _ in }, copy: { _ in })
            .compactMap { $0.toolTip }
        XCTAssertTrue(titles.contains(site.base + "/get_file/1/abc/"))
    }

    func testSC1BlobSourceIsNotRecovered() async throws {
        let site = try await serve(["page.html": "<html><body><video id='v'></video></body></html>"])
        let browser = try await open("/page.html", on: site)
        _ = try await browser.webView.evaluateJavaScript(
            "document.getElementById('v').src = URL.createObjectURL(new Blob(['x'])); 1")
        await browser.recoverStreams()
        XCTAssertFalse(browser.detectedStreams.contains { $0.url.hasPrefix("blob:") })
    }

    // SC-2: a playlist the page loaded without fetch/XHR (an <img>), found in the Resource Timing list.
    func testSC2PlaylistFromResourceTimingIsRecovered() async throws {
        let site = try await serve([
            "page.html": "<html><body><img src='/s/video.m3u8' style='display:none'></body></html>",
            "s/video.m3u8": Self.playlist,
        ])
        let browser = try await open("/page.html", on: site)
        XCTAssertTrue(browser.detectedStreams.isEmpty, "\(browser.detectedStreams.map(\.url))")

        await browser.recoverStreams()
        let stream = try XCTUnwrap(browser.detectedStreams.first { $0.url == site.base + "/s/video.m3u8" })
        XCTAssertEqual(stream.type, .hls)
    }

    // SC-3: only `.other` streams were found; the one that answers as a playlist becomes the main video.
    func testSC3OtherStreamsAreProbed() async throws {
        let site = try await serve([
            "page.html": "<html><body>player</body></html>",
            "v/abc": Self.playlist,
            "api/playlist": "{\"items\": []}",
        ])
        let browser = try await open("/page.html", on: site)
        browser.handleDetectedStream(url: site.base + "/api/playlist", pageURL: site.base + "/page.html", title: "", in: browser.webView)
        browser.handleDetectedStream(url: site.base + "/v/abc", pageURL: site.base + "/page.html", title: "", in: browser.webView)
        XCTAssertTrue(browser.detectedStreams.allSatisfy { $0.type == .other })

        let decision = await browser.chooseDownload(knownVideoPage: false)
        guard case .stream(let choice) = decision else { return XCTFail("got \(decision.logName)") }
        XCTAssertEqual(choice.stream.url, site.base + "/v/abc")
        XCTAssertEqual(choice.stream.type, .hls)
        XCTAssertEqual(choice.duration ?? 0, 200, accuracy: 0.5)
        XCTAssertTrue(StreamCheckLog.lastEntry?.contains("not a playlist or video, skipped: \(site.base)/api/playlist") == true,
                      StreamCheckLog.lastEntry ?? "")
    }

    // SC-4: nothing found means "no stream yet", not the page link; known video sites still use the page link.
    func testSC4NoStreamStaysInBrowser() async throws {
        let site = try await serve(["page.html": "<html><body>An article</body></html>"])
        let browser = try await open("/page.html", on: site)

        guard case .noStreamYet = await browser.chooseDownload(knownVideoPage: false) else { return XCTFail("expected no stream yet") }
        guard case .pageLink = await browser.chooseDownload(knownVideoPage: true) else { return XCTFail("expected page link") }
        XCTAssertTrue(DownloadDecision.noStreamMessage.contains("No video stream found yet"))
        XCTAssertTrue(DownloadDecision.noStreamMessage.contains("Let the video play, then press Download again"))
        XCTAssertTrue(DownloadDecision.noStreamMessage.contains("Use page link"))
    }

    func testSC4DecisionFromChoice() {
        let stream = DetectedStream(url: "https://cdn.test/a.m3u8", pageURL: "", title: "", type: .hls)
        guard case .noStreamYet = DownloadDecision(nil) else { return XCTFail() }
        guard case .shortClip = DownloadDecision(.init(stream: stream, duration: 20, skippedAds: 0)) else { return XCTFail() }
        guard case .stream = DownloadDecision(.init(stream: stream, duration: 3600, skippedAds: 0)) else { return XCTFail() }
        guard case .stream = DownloadDecision(.init(stream: stream, duration: nil, skippedAds: 0)) else { return XCTFail() }
    }

    // SC-5: yt-dlp's "Unsupported URL" for a page sent from the browser points back to the browser.
    func testSC5UnsupportedPageFromBrowserPointsToBrowser() {
        let raw = AppError.analysisError(ErrorMapper.message(for: "ERROR: Unsupported URL: https://site.test/v/1"))
        let mapped = AppState.fromBrowser(raw)
        XCTAssertEqual(mapped.localizedDescription, AppState.browserNoVideoMessage)
        let shown = ErrorPresentation(mapped.localizedDescription)
        XCTAssertEqual(shown.title, "No video found at this page address")
        XCTAssertTrue(shown.hint?.contains("Browser tab") == true)
        XCTAssertFalse(shown.hint?.contains("address bar") == true)
        // Other errors, and the same error outside the browser, are unchanged.
        XCTAssertEqual(AppState.fromBrowser(.analysisError("Video not found (HTTP 404).")).localizedDescription,
                       "Video not found (HTTP 404).")
        XCTAssertTrue(ErrorPresentation(raw.localizedDescription).hint?.contains("address bar") == true)
    }

    // SC-6: every Download press is logged with the path taken, the fallbacks included.
    func testSC6EveryPressIsLogged() async throws {
        let site = try await serve(["page.html": "<html><body>An article</body></html>"])
        let browser = try await open("/page.html", on: site)

        _ = await browser.chooseDownload(knownVideoPage: false)
        XCTAssertTrue(StreamCheckLog.lastEntry?.contains("DECISION: no stream yet") == true, StreamCheckLog.lastEntry ?? "")
        XCTAssertTrue(StreamCheckLog.lastEntry?.contains("Page: \(site.base)/page.html") == true)
        _ = await browser.chooseDownload(knownVideoPage: true)
        XCTAssertTrue(StreamCheckLog.lastEntry?.contains("DECISION: page link (known video site)") == true)
        browser.notePageLinkByHand()
        XCTAssertTrue(StreamCheckLog.lastEntry?.contains("DECISION: page link (chosen by hand)") == true)

        var text = ""
        for _ in 0..<30 {
            text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if text.contains("chosen by hand") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(text.contains("DECISION: no stream yet"), text)
        XCTAssertTrue(text.contains("DECISION: page link (known video site)"), text)
        XCTAssertTrue(text.contains("DECISION: page link (chosen by hand)"), text)
    }

    // SC-7: the client-side error uses the apostrophe the home view matches, so its hint shows.
    func testSC7InvalidLinkErrorGetsItsHint() async {
        let state = AppState()
        // Not a search (it has a scheme) and not http(s): refused before yt-dlp.
        state.currentURL = "ftp://files.example.com/a"
        await state.analyze(using: YTDLPService())
        let message = state.error?.localizedDescription ?? ""
        XCTAssertTrue(message.hasPrefix("This link doesn’t lead to a video"), message)
        XCTAssertNotNil(ErrorPresentation(message).hint)
    }
}
