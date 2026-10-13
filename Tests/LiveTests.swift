import XCTest
@testable import Pathfinder

/// Hits the network and the real yt-dlp. Run with: LIVE=1 swift test --filter LiveTests
final class LiveTests: XCTestCase {
    func testAnalyzeAndDownloadRealVideo() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE"] == "1", "set LIVE=1 to run")
        let service = YTDLPService()
        let url = "https://archive.org/details/BigBuckBunny_124"
        let info = try await service.analyze(url: url)
        XCTAssertEqual(info.title, "Big Buck Bunny")
        XCTAssertFalse(QualityOptions.video(from: info).isEmpty)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID())").path
        let opt = QualityOptions.video(from: info).last!.options(basedOn: DownloadOptions())
        let (_, events) = await service.download(url: url, options: opt, outputDir: dir)
        var last: DownloadEvent?
        var sawProgress = false
        for await e in events { if case .progress = e { sawProgress = true }; last = e }
        XCTAssertTrue(sawProgress)
        guard case .completed(let path)? = last else { return XCTFail("not completed: \(String(describing: last))") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(path)), "output path \(path ?? "nil") missing")
    }
}

/// The Download button's main-video check against a real HLS stream, through a real web view.
/// Run with: LIVE=1 swift test --filter LiveMainStreamTests
final class LiveMainStreamTests: XCTestCase {
    /// A real 47-second playlist, standing in for a pre-roll ad.
    private let shortAd = "https://test-streams.mux.dev/issue666/playlists/cisq0gim60007xzvi505emlxx.m3u8"
    /// Big Buck Bunny master playlist (about 10 minutes).
    private let movie = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"

    @MainActor
    private func pageBrowser() async throws -> BrowserModel {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE"] == "1", "set LIVE=1 to run")
        UserDefaults.standard.set(false, forKey: "browserAdBlock")
        let browser = BrowserModel()
        browser.webView.loadHTMLString("<html><body>player</body></html>", baseURL: URL(string: "https://example.com/watch"))
        for _ in 0..<100 where browser.webView.isLoading || browser.webView.url == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        return browser
    }

    @MainActor
    func testPicksTheLongStreamOverTheAd() async throws {
        let browser = try await pageBrowser()
        // Order as the page reports them: the ad first, then the movie (HLS is inserted at the front).
        browser.handleDetectedStream(url: shortAd, pageURL: "https://example.com/watch", title: "", in: browser.webView)
        browser.handleDetectedStream(url: movie, pageURL: "https://example.com/watch", title: "", in: browser.webView)
        XCTAssertEqual(browser.detectedStreams.count, 2)

        let found = await browser.mainStream(among: browser.detectedStreams)
        let choice = try XCTUnwrap(found)
        print("chosen:", choice.stream.url, "duration:", choice.duration ?? -1, "skipped:", choice.skippedAds)
        XCTAssertEqual(choice.stream.url, movie)
        XCTAssertGreaterThan(try XCTUnwrap(choice.duration), 500)
        XCTAssertEqual(choice.skippedAds, 1)
    }

    @MainActor
    func testOnlyAdMeasuredButAnotherStreamCannotBe() async throws {
        let browser = try await pageBrowser()
        let live = "https://live.invalid/stream/index.m3u8"   // no answer: like a live stream or a site refusing the check
        browser.handleDetectedStream(url: shortAd, pageURL: "https://example.com/watch", title: "", in: browser.webView)
        browser.handleDetectedStream(url: live, pageURL: "https://example.com/watch", title: "", in: browser.webView)

        let found = await browser.mainStream(among: browser.detectedStreams)
        let choice = try XCTUnwrap(found)
        print("chosen:", choice.stream.url, "duration:", choice.duration ?? -1, "skipped:", choice.skippedAds)
        XCTAssertEqual(choice.stream.url, live)
    }

    @MainActor
    func testOnlyAShortClipIsReportedAsShort() async throws {
        let browser = try await pageBrowser()
        browser.handleDetectedStream(url: shortAd, pageURL: "https://example.com/watch", title: "", in: browser.webView)
        let found = await browser.mainStream(among: browser.detectedStreams)
        let choice = try XCTUnwrap(found)
        print("chosen:", choice.stream.url.prefix(40), "duration:", choice.duration ?? -1)
        XCTAssertEqual(try XCTUnwrap(choice.duration), 47.24, accuracy: 0.1)
        XCTAssertLessThan(choice.duration!, BrowserModel.minimumMainLength)   // the button refuses it and explains
    }
}

/// A detected stream sent through the Downloads queue, as the Download button does, down to a saved file.
final class LiveStreamQueueTests: XCTestCase {
    @MainActor
    func testStreamDownloadsThroughQueue() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE"] == "1", "set LIVE=1 to run")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-queue-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = QueueManager(store: QueueStore(fileURL: root.appendingPathComponent("queue.json")))
        queue.enqueueStream(url: "https://test-streams.mux.dev/issue666/playlists/cisq0gim60007xzvi505emlxx.m3u8",
                            title: "Live queue test", pageURL: "https://example.com/watch", isHLS: true,
                            outputDir: root.path, frame: nil, cookiesFile: nil, viaBrowser: false)
        let item = try XCTUnwrap(queue.items.last)
        var seen = Set<DownloadStatus>()
        for _ in 0..<1200 where item.status != .completed && item.status != .failed {
            seen.insert(item.status)
            try await Task.sleep(for: .milliseconds(100))
        }
        print("status:", item.status, "seen:", seen, "error:", item.error ?? "-", "file:", item.outputPath ?? "-")
        XCTAssertEqual(item.status, .completed, item.error ?? "")
        let path = try XCTUnwrap(item.outputPath)
        let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        print("size:", size)
        XCTAssertGreaterThan(size, 100_000)
    }
}

/// Playlists behind addresses that say nothing (".txt", ".png") are found by their content.
/// Run with: LIVE=1 swift test --filter LiveDisguisedPlaylistTests
final class LiveDisguisedPlaylistTests: XCTestCase {
    @MainActor
    func testFindsPlaylistsByContent() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE"] == "1", "set LIVE=1 to run")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disguised-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\na.ts\n#EXT-X-ENDLIST\n"
        try playlist.write(to: root.appendingPathComponent("stream.txt"), atomically: true, encoding: .utf8)
        try playlist.write(to: root.appendingPathComponent("cover.png"), atomically: true, encoding: .utf8)
        try """
        <html><body><script>
        fetch('/control.m3u8').catch(() => {});
        fetch('/stream.txt').then(r => r.text());
        var x = new XMLHttpRequest(); x.open('GET', '/cover.png'); x.send();
        </script></body></html>
        """.write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let port = Int.random(in: 20000...40000)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", root.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        try await Task.sleep(for: .seconds(1))

        UserDefaults.standard.set(false, forKey: "browserAdBlock")
        let browser = BrowserModel()
        // Wait for the stream detector script to be installed (it is set up just after the browser starts).
        for _ in 0..<50 where browser.webView.configuration.userContentController.userScripts.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        browser.go("http://127.0.0.1:\(port)/index.html")
        for _ in 0..<80 where browser.detectedStreams.count < 2 { try await Task.sleep(for: .milliseconds(100)) }

        let found = browser.detectedStreams.map { "\($0.type.rawValue) \($0.url)" }
        print("detected:", found)
        XCTAssertTrue(browser.detectedStreams.contains { $0.url.hasSuffix("/stream.txt") && $0.type == .hls }, "\(found)")
        XCTAssertTrue(browser.detectedStreams.contains { $0.url.hasSuffix("/cover.png") && $0.type == .hls }, "\(found)")
    }
}
