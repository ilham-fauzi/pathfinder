import XCTest
import WebKit
@testable import Pathfinder

final class ParsingTests: XCTestCase {
    func testProgressParse() throws {
        let u = try XCTUnwrap(ProgressUpdate.parse("YDLP|||  58.1%|||   2.62MiB/s|||00:03|||130048|||223779"))
        XCTAssertEqual(u.percent, 58.1, accuracy: 0.001)
        XCTAssertEqual(u.speed, "2.62MiB/s")
        XCTAssertEqual(u.eta, "00:03")
        XCTAssertNotNil(u.totalBytes)
    }

    func testProgressParseHandlesNA() throws {
        let u = try XCTUnwrap(ProgressUpdate.parse("YDLP|||100.0%|||1.38MiB/s|||NA|||223779|||NA"))
        XCTAssertEqual(u.eta, "")
        XCTAssertNil(u.totalBytes)
    }

    func testProgressParseIgnoresOtherLines() {
        XCTAssertNil(ProgressUpdate.parse("[download] Destination: x.mp4"))
    }

    func testOutputPath() {
        XCTAssertEqual(OutputPathParser.path(from: "[Merger] Merging formats into \"/tmp/a b.mp4\""), "/tmp/a b.mp4")
        XCTAssertEqual(OutputPathParser.path(from: "[ExtractAudio] Destination: /tmp/a.mp3"), "/tmp/a.mp3")
        XCTAssertEqual(OutputPathParser.path(from: "[download] /tmp/a.mp4 has already been downloaded"), "/tmp/a.mp4")
        XCTAssertNil(OutputPathParser.path(from: "[info] something"))
    }

    func testErrorMapper() {
        XCTAssertTrue(ErrorMapper.message(for: "ERROR: Unsupported URL: https://x.com").contains("doesn’t lead to a video"))
        XCTAssertTrue(ErrorMapper.message(for: "ERROR: HTTP Error 503").contains("Connection lost"))
        XCTAssertTrue(ErrorMapper.message(for: "ERROR: Private video").contains("private"))
        XCTAssertTrue(ErrorMapper.message(for: "ERROR: Sign in to confirm you’re not a bot").contains("not a bot"))
    }

    func testURLCheck() {
        XCTAssertEqual(ErrorMapper.check("  "), .empty)
        XCTAssertEqual(ErrorMapper.check("hello"), .invalid)
        XCTAssertEqual(ErrorMapper.check("https://vimeo.com/823415907"), .ok)
        XCTAssertEqual(ErrorMapper.check("youtu.be/abc"), .ok)
    }
}

final class QualityTests: XCTestCase {
    private func info(_ json: String) throws -> VideoInfo {
        try JSONDecoder().decode(VideoInfo.self, from: Data(json.utf8))
    }

    func testVideoOptionsAndRecommended() throws {
        let i = try info("""
        {"id":"x","duration":100,"formats":[
         {"format_id":"a","vcodec":"none","acodec":"opus","filesize":1000},
         {"format_id":"v1","vcodec":"avc1","acodec":"none","height":2160,"filesize":9000},
         {"format_id":"v2","vcodec":"avc1","acodec":"none","height":1080,"filesize":5000},
         {"format_id":"v3","vcodec":"avc1","acodec":"none","height":720,"filesize":2000},
         {"format_id":"v4","vcodec":"avc1","acodec":"none","height":144,"filesize":100}]}
        """)
        let v = QualityOptions.video(from: i)
        XCTAssertEqual(v.map(\.quality), ["2160p", "1080p", "720p"])   // 144p dropped
        XCTAssertEqual(v.first(where: \.isRecommended)?.quality, "1080p")
        XCTAssertEqual(v[1].estimatedBytes, 6000)                        // video + best audio
        XCTAssertEqual(v[0].label, "4K Ultra HD")
    }

    func testAudioOptionsApplyBitrate() throws {
        let i = try info(#"{"id":"x","duration":60}"#)
        let a = QualityOptions.audio(from: i)
        XCTAssertEqual(a.count, 4)
        XCTAssertEqual(a.first(where: \.isRecommended)?.quality, "320 kbps")
        let opts = a[0].options(basedOn: DownloadOptions())
        XCTAssertTrue(opts.extractAudio)
        let args = opts.toArgs()
        XCTAssertTrue(args.contains("320K"))
    }

    func testVideoOptionDoesNotMutateBase() throws {
        let i = try info(#"{"id":"x","formats":[{"format_id":"v","vcodec":"avc1","acodec":"none","height":720}]}"#)
        let base = DownloadOptions()
        let before = base.format
        let o = QualityOptions.video(from: i)[0].options(basedOn: base)
        XCTAssertEqual(base.format, before)
        XCTAssertTrue(o.format?.contains("height<=720") == true)
        XCTAssertFalse(o.toArgs().contains("--embed-thumbnail"))   // would fail on non-mp4 containers
    }
}

final class QueueStoreTests: XCTestCase {
    @MainActor
    func testRoundTripAndInterruptedRestore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = QueueStore(fileURL: url)
        store.save([QueueStore.Record(id: UUID(), url: "https://a.com/v", title: "T", options: DownloadOptions(),
                                      outputDir: "/tmp", status: .downloading, progress: 42, error: nil, outputPath: nil,
                                      createdAt: Date(), completedAt: nil, optionId: "video-1080", qualityLabel: "1080p")])
        XCTAssertEqual(store.load().first?.title, "T")

        let restored = QueueManager(store: store).items
        XCTAssertEqual(restored.first?.status, .paused)    // interrupted downloads come back paused
        XCTAssertEqual(restored.first?.progress, 42)
    }
}

/// Runs the real YTDLPService against a stub "yt-dlp" shell script.
final class ServiceStubTests: XCTestCase {
    private func stub(_ body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stub-\(UUID()).sh")
        try ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    private func collect(_ path: String) async -> [DownloadEvent] {
        let service = YTDLPService()
        await service.setCustomPath(path)
        let (_, events) = await service.download(url: "https://x.com/v", options: DownloadOptions(), outputDir: "/tmp")
        var out: [DownloadEvent] = []
        for await e in events { out.append(e) }
        return out
    }

    func testSuccessScalesTwoStreamsAndReportsPath() async throws {
        let path = try stub("""
        echo '[info] x: Downloading 1 format(s): 1+2'
        echo '[download] Destination: /tmp/a.f1.mp4'
        echo 'YDLP|||100.0%|||1MiB/s|||00:00|||10|||10'
        echo '[download] Destination: /tmp/a.f2.m4a'
        echo 'YDLP|||50.0%|||1MiB/s|||00:00|||5|||10'
        echo '[Merger] Merging formats into "/tmp/a.mp4"'
        exit 0
        """)
        let events = await collect(path)
        let percents = events.compactMap { if case .progress(let u) = $0 { return u.percent } else { return nil } }
        XCTAssertEqual(percents, [50, 75])
        XCTAssertTrue(events.contains { if case .postProcessing = $0 { return true } else { return false } })
        guard case .completed(let p)? = events.last else { return XCTFail("expected completed, got \(String(describing: events.last))") }
        XCTAssertEqual(p, "/tmp/a.mp4")
    }

    func testNonZeroExitIsFailureWithFriendlyMessage() async throws {
        let path = try stub("echo 'ERROR: [x] HTTP Error 503: Service Unavailable'; exit 1")
        let events = await collect(path)
        guard case .error(let msg)? = events.last else { return XCTFail("expected error") }
        XCTAssertTrue(msg.contains("Connection lost"))
        XCTAssertFalse(events.contains { if case .completed = $0 { return true } else { return false } })
    }

    func testCancelKillsProcessAndEmitsNoCompletion() async throws {
        let path = try stub("echo 'YDLP|||1.0%|||1MiB/s|||00:99|||1|||100'; sleep 30")
        let service = YTDLPService()
        await service.setCustomPath(path)
        let (handle, events) = await service.download(url: "https://x.com/v", options: DownloadOptions(), outputDir: "/tmp")
        var seen: [DownloadEvent] = []
        let start = Date()
        for await e in events {
            seen.append(e)
            if case .progress = e { handle.cancel() }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertFalse(seen.contains { if case .completed = $0 { return true } else { return false } })
        XCTAssertFalse(seen.contains { if case .error = $0 { return true } else { return false } })
    }
}

final class VPNTests: XCTestCase {
    func testKeyNormalizationAddsTrailingNewlineAndFixesCRLF() throws {
        let raw = "  -----BEGIN OPENSSH PRIVATE KEY-----\r\nabc\r\n-----END OPENSSH PRIVATE KEY-----  "
        let key = try VPNSettings.normalizedKey(raw)
        XCTAssertTrue(key.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
        XCTAssertFalse(key.contains("\r"))
    }

    func testPublicKeyAndGarbageAreRejected() {
        XCTAssertThrowsError(try VPNSettings.normalizedKey("ssh-ed25519 AAAA user@host"))
        XCTAssertThrowsError(try VPNSettings.normalizedKey("hello"))
        XCTAssertThrowsError(try VPNSettings.normalizedKey("   "))
    }

    func testSSHErrorsAreMapped() {
        XCTAssertTrue(SSHTunnelManager.friendlyError(from: "user@h: Permission denied (publickey).", code: 255).contains("Login failed"))
        XCTAssertTrue(SSHTunnelManager.friendlyError(from: "ssh: connect to host h port 22: Connection refused", code: 255).contains("refused"))
        XCTAssertTrue(SSHTunnelManager.friendlyError(from: "Could not resolve hostname x", code: 255).contains("not found"))
    }
}

final class ListingTests: XCTestCase {
    func testDetectSearchAndLinks() {
        XCTAssertEqual(ListingSource.detect("swift tutorial"), .search("swift tutorial"))
        XCTAssertEqual(ListingSource.detect("music"), .search("music"))
        XCTAssertEqual(ListingSource.detect("https://www.youtube.com/results?search_query=cats"), .search("cats"))
        XCTAssertEqual(ListingSource.detect("https://www.youtube.com/@Apple"), .url("https://www.youtube.com/@Apple/videos"))
        XCTAssertEqual(ListingSource.detect("youtube.com/@Apple/shorts"), .url("https://www.youtube.com/@Apple/shorts"))
        XCTAssertEqual(ListingSource.detect("https://www.youtube.com/channel/UC123"), .url("https://www.youtube.com/channel/UC123/videos"))
        XCTAssertEqual(ListingSource.detect("https://www.youtube.com/playlist?list=PL1"), .url("https://www.youtube.com/playlist?list=PL1"))
    }

    func testSingleVideoLinksAreNotLists() {
        XCTAssertNil(ListingSource.detect("https://www.youtube.com/watch?v=abc12345678"))
        XCTAssertNil(ListingSource.detect("https://www.youtube.com/watch?v=abc12345678&list=PL1"))
        XCTAssertNil(ListingSource.detect("https://youtu.be/abc12345678"))
        XCTAssertNil(ListingSource.detect("https://vimeo.com/12345"))
        XCTAssertNil(ListingSource.detect(""))
    }

    func testParseFlattensChannelTabsAndDropsPrivate() throws {
        let json = """
        {"_type":"playlist","title":"Apple - Videos","entries":[
          {"_type":"playlist","title":"Videos","entries":[
            {"id":"aaaaaaaaaaa","title":"One","url":"https://www.youtube.com/watch?v=aaaaaaaaaaa","ie_key":"Youtube","duration":3725,"view_count":1500000,"channel":"Apple"},
            {"id":"bbbbbbbbbbb","title":"[Private video]","url":"https://www.youtube.com/watch?v=bbbbbbbbbbb","ie_key":"Youtube"}]}]}
        """
        let page = try ListingParser.parse(Data(json.utf8))
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(page.rawCount, 2)
        XCTAssertEqual(page.entries[0].durationText, "1:02:05")
        XCTAssertEqual(page.entries[0].viewsText, "1.5M views")
        XCTAssertEqual(page.entries[0].thumbnail, "https://i.ytimg.com/vi/aaaaaaaaaaa/mqdefault.jpg")
    }

    func testLiveSearchReturnsVideos() async throws {
        let service = YTDLPService()
        guard await service.findBinary() != nil else { throw XCTSkip("yt-dlp not installed") }
        let page = try await service.list(source: .search("swift tutorial"), start: 1, end: 5)
        XCTAssertFalse(page.entries.isEmpty)
        XCTAssertTrue(page.entries.allSatisfy { $0.url.hasPrefix("http") })
    }
}

final class BrowserTests: XCTestCase {
    /// Heavy: converts a real EasyList copy and compiles it in WebKit. Skipped unless YDL_EASYLIST points to a file.
    @MainActor
    func testEasyListConvertsAndCompiles() async throws {
        guard let path = ProcessInfo.processInfo.environment["YDL_EASYLIST"] else { throw XCTSkip("set YDL_EASYLIST") }
        let start = Date()
        let rules = await FilterLists.convertedRules(from: URL(fileURLWithPath: path))
        let converted = try XCTUnwrap(rules)
        print("CONVERTED \(converted.count) rules in \(Date().timeIntervalSince(start))s")
        let compileStart = Date()
        let list = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "ydl-test-easylist", encodedContentRuleList: converted.json)
        print("COMPILED in \(Date().timeIntervalSince(compileStart))s")
        XCTAssertNotNil(list)
        try await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: "ydl-test-easylist")
    }

    @MainActor
    func testAdBlockRulesCompile() async throws {
        let list = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "ydl-test-rules", encodedContentRuleList: AdBlocker.rulesJSON())
        XCTAssertNotNil(list)
        try await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: "ydl-test-rules")
    }

    func testAddressResolution() {
        XCTAssertEqual(BrowserModel.resolve("example.com/a")?.absoluteString, "https://example.com/a")
        XCTAssertEqual(BrowserModel.resolve("http://example.com")?.absoluteString, "http://example.com")
        UserDefaults.standard.set("duckduckgo", forKey: "browserSearchEngine")
        defer { UserDefaults.standard.removeObject(forKey: "browserSearchEngine") }
        XCTAssertEqual(BrowserModel.resolve("swift tutorial")?.absoluteString, "https://duckduckgo.com/?q=swift%20tutorial")
        XCTAssertNil(BrowserModel.resolve("  "))
    }
}

final class StreamCaptureTests: XCTestCase {
    let master = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="en",DEFAULT=YES,URI="audio/en.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=800000,AVERAGE-BANDWIDTH=700000,RESOLUTION=640x360,AUDIO="aud"
    low/index.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aud"
    https://cdn.example.com/hi/index.m3u8?t=abc
    """

    let media = """
    #EXTM3U
    #EXT-X-TARGETDURATION:6
    #EXT-X-KEY:METHOD=AES-128,URI="https://k.example.com/key?id=1",IV=0x0123
    #EXT-X-MAP:URI="init.mp4"
    #EXTINF:6.0,
    seg1.png
    #EXTINF:6.0,
    seg2.png
    #EXT-X-ENDLIST
    """

    func testPicksHighestBandwidthAndAudioTrack() throws {
        XCTAssertTrue(HLS.isMaster(master))
        let best = try XCTUnwrap(HLS.bestVariant(in: master))
        XCTAssertEqual(best.uri, "https://cdn.example.com/hi/index.m3u8?t=abc")
        XCTAssertEqual(best.bandwidth, 2_500_000)
        XCTAssertEqual(HLS.audioURI(in: master, group: "aud"), "audio/en.m3u8")
        XCTAssertNil(HLS.audioURI(in: master, group: "other"))
    }

    func testAttributeParsingRespectsQuotesAndNames() {
        let line = #"#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=1,CODECS="a,b",BANDWIDTH=2"#
        XCTAssertEqual(HLS.attribute("BANDWIDTH", in: line), "2")
        XCTAssertEqual(HLS.attribute("CODECS", in: line), "a,b")
    }

    func testResourcesAndLocalPlaylist() {
        let res = HLS.resources(in: media)
        XCTAssertEqual(res.map(\.kind), [.key, .map, .segment, .segment])
        XCTAssertEqual(res.first?.uri, "https://k.example.com/key?id=1")
        let local = HLS.localPlaylist(media, names: [
            "https://k.example.com/key?id=1": "key0.key", "init.mp4": "init1.mp4",
            "seg1.png": "seg00002.ts", "seg2.png": "seg00003.ts",
        ])
        XCTAssertTrue(local.contains(#"#EXT-X-KEY:METHOD=AES-128,URI="key0.key",IV=0x0123"#))
        XCTAssertTrue(local.contains(#"#EXT-X-MAP:URI="init1.mp4""#))
        XCTAssertTrue(local.contains("\nseg00002.ts\n"))
        XCTAssertFalse(local.contains("seg1.png"))
        XCTAssertFalse(HLS.isDRMProtected(media))
    }

    func testDetectsDRM() {
        XCTAssertTrue(HLS.isDRMProtected(#"#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://abc",KEYFORMAT="com.apple.streamingkeydelivery""#))
        XCTAssertTrue(HLS.isDRMProtected(#"#EXT-X-KEY:METHOD=SAMPLE-AES-CTR,URI="data:x""#))
    }

    func testStripsFakeImageHeaderFromTSSegment() {
        var ts = Data(repeating: 0, count: 188 * 3)
        for i in 0..<3 { ts[i * 188] = 0x47 }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 1, count: 60))
        XCTAssertEqual(HLS.strippingFakeHeader(png + ts), ts)
        XCTAssertEqual(HLS.strippingFakeHeader(ts), ts)
    }

    func testSniffsFileTypes() {
        XCTAssertEqual(MediaSniff.fileExtension(for: Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8)), "mp4")
        XCTAssertEqual(MediaSniff.fileExtension(for: Data("#EXTM3U\n#EXT".utf8)), "m3u8")
        XCTAssertEqual(MediaSniff.fileExtension(for: Data([0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0])), "webm")
        XCTAssertEqual(MediaSniff.fileExtension(forMIME: "video/mp4"), "mp4")
        XCTAssertNil(MediaSniff.fileExtension(forMIME: "application/octet-stream"))
        XCTAssertTrue(MediaSniff.isHLS(mime: "application/vnd.apple.mpegurl", url: nil))
        XCTAssertTrue(MediaSniff.isHLS(mime: nil, url: URL(string: "https://x/master.m3u8?t=1")))
    }

    func testFileNameIsSafe() {
        XCTAssertEqual(BrowserModel.fileName(from: "a/b: c?", fallback: "x", ext: "mp4"), "a b  c .mp4")
        XCTAssertEqual(BrowserModel.fileName(from: "  ", fallback: "master", ext: "mp4"), "master.mp4")
    }
}

/// End to end: a local site that only serves its stream to its own player page (Referer + session cookie),
/// with an AES-128 encrypted video track and an audio track disguised as PNG images.
@MainActor
final class StreamCaptureEndToEndTests: XCTestCase {
    private var server: Process?

    override func tearDown() async throws {
        server?.terminate()
    }

    private func run(_ exe: URL, _ args: [String]) async throws {
        let r = try await ProcessRunner.run(executable: exe, arguments: args)
        XCTAssertTrue(r.isSuccess, r.stderrString ?? "")
    }

    func testCapturesProtectedEncryptedStreamThroughPage() async throws {
        guard let ffmpeg = BrowserModel.ffmpegURL() else { throw XCTSkip("ffmpeg not installed") }
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("python3 not available") }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ydl-e2e-\(UUID().uuidString)", isDirectory: true)
        let site = root.appendingPathComponent("site", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: site.appendingPathComponent("v"), withIntermediateDirectories: true)
        try fm.createDirectory(at: site.appendingPathComponent("a"), withIntermediateDirectories: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Video: AES-128 encrypted HLS. Audio: plain TS segments renamed to .png with a fake PNG header.
        try Data((0..<16).map { UInt8($0 * 7 & 0xFF) }).write(to: site.appendingPathComponent("v/key.bin"))
        try "key.bin?sig=1\n\(site.appendingPathComponent("v/key.bin").path)\n".write(
            to: root.appendingPathComponent("keyinfo"), atomically: true, encoding: .utf8)
        try await run(ffmpeg, ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=duration=6:size=320x240:rate=25",
                               "-c:v", "libx264", "-g", "50", "-hls_time", "2", "-hls_playlist_type", "vod",
                               "-hls_key_info_file", root.appendingPathComponent("keyinfo").path,
                               "-hls_segment_filename", site.appendingPathComponent("v/s%d.ts").path,
                               site.appendingPathComponent("v/index.m3u8").path])
        try await run(ffmpeg, ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=duration=6",
                               "-c:a", "aac", "-hls_time", "2", "-hls_playlist_type", "vod",
                               "-hls_segment_filename", site.appendingPathComponent("a/s%d.ts").path,
                               site.appendingPathComponent("a/index.m3u8").path])
        let fakePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0xAB, count: 120)
        var audioPlaylist = try String(contentsOf: site.appendingPathComponent("a/index.m3u8"), encoding: .utf8)
        for name in try fm.contentsOfDirectory(atPath: site.appendingPathComponent("a").path) where name.hasSuffix(".ts") {
            let ts = try Data(contentsOf: site.appendingPathComponent("a/\(name)"))
            let png = name.replacingOccurrences(of: ".ts", with: ".png")
            try (fakePNG + ts).write(to: site.appendingPathComponent("a/\(png)"))
            try fm.removeItem(at: site.appendingPathComponent("a/\(name)"))
            audioPlaylist = audioPlaylist.replacingOccurrences(of: name, with: png)
        }
        try audioPlaylist.write(to: site.appendingPathComponent("a/index.m3u8"), atomically: true, encoding: .utf8)
        try """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="main",DEFAULT=YES,URI="a/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=300000,AUDIO="aud"
        v/index.m3u8
        """.write(to: site.appendingPathComponent("master.m3u8"), atomically: true, encoding: .utf8)
        try "<html><head><title>Player</title></head><body>player<script>fetch('master.m3u8')</script></body></html>"
            .write(to: site.appendingPathComponent("player.html"), atomically: true, encoding: .utf8)

        // Server: the page sets a session cookie; everything else needs that cookie and the page as Referer.
        let port = Int.random(in: 20000...40000)
        let script = """
        import http.server, functools
        class H(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *a): pass
            def end_headers(self):
                if self.path.startswith('/player.html'):
                    self.send_header('Set-Cookie', 'sess=ok; Path=/')
                super().end_headers()
            def do_GET(self):
                if not self.path.startswith('/player.html'):
                    ref = self.headers.get('Referer', '')
                    if not ref.startswith('http://127.0.0.1:\(port)/player.html') or 'sess=ok' not in self.headers.get('Cookie', ''):
                        self.send_error(403); return
                super().do_GET()
        http.server.ThreadingHTTPServer(('127.0.0.1', \(port)), functools.partial(H, directory='\(site.path)')).serve_forever()
        """
        let p = Process()
        p.executableURL = python
        p.arguments = ["-c", script]
        try p.run()
        server = p
        let base = "http://127.0.0.1:\(port)"

        // Outside the page (like yt-dlp or curl without the page's cookie) the stream is refused.
        var refused = 0
        for _ in 0..<50 {
            if let (_, r) = try? await URLSession.shared.data(from: URL(string: "\(base)/master.m3u8")!) {
                refused = (r as? HTTPURLResponse)?.statusCode ?? 0; break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(refused, 403)

        UserDefaults.standard.set(false, forKey: "browserAdBlock")
        let browser = BrowserModel()
        browser.downloadDirectory = { out.path }
        browser.go("\(base)/player.html")
        for _ in 0..<100 where browser.webView.isLoading || browser.webView.url?.path != "/player.html" {
            try await Task.sleep(for: .milliseconds(100))
        }

        // Queued like the "Download stream" button: yt-dlp first (refused by this site), then the browser.
        let queue = QueueManager(store: QueueStore(fileURL: root.appendingPathComponent("queue.json")))
        queue.browserEngine = browser
        browser.queue = queue
        let hasYTDLP = await queue.ytdlpService.findBinary() != nil
        // The page's own player request is detected, with the frame it came from.
        for _ in 0..<50 where browser.detectedStreams.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        let stream = try XCTUnwrap(browser.detectedStreams.first)
        XCTAssertNotNil(stream.frame)
        queue.enqueueStream(url: stream.url, title: "Capture: test", pageURL: stream.pageURL, isHLS: true,
                            outputDir: out.path, frame: stream.frame, cookiesFile: nil, viaBrowser: !hasYTDLP)
        let item = try XCTUnwrap(queue.items.first)
        // Leave the page right away: the download must not depend on what the browser shows next.
        browser.blank()
        for _ in 0..<900 where item.status != .completed && item.status != .failed {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(item.status, .completed, item.error ?? "")
        XCTAssertEqual(item.engine, .browser)
        let path = try XCTUnwrap(item.outputPath)
        XCTAssertEqual((path as NSString).lastPathComponent, "Capture  test.mp4")

        // The result has both tracks and the full length.
        let probe = try await ProcessRunner.run(
            executable: ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe"),
            arguments: ["-v", "error", "-show_entries", "stream=codec_type:format=duration", "-of", "default=nw=1", path])
        let info = probe.stdoutString ?? ""
        XCTAssertTrue(info.contains("codec_type=video"), info)
        XCTAssertTrue(info.contains("codec_type=audio"), info)
        let duration = Double(info.components(separatedBy: "duration=").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        XCTAssertEqual(duration, 6, accuracy: 0.5)
    }
}

@MainActor
final class BrowserTabsTests: XCTestCase {
    func testOpenSelectAndCloseTabs() {
        UserDefaults.standard.set(false, forKey: "browserAdBlock")
        let browser = BrowserModel()
        XCTAssertEqual(browser.tabs.count, 1)
        let first = browser.selectedTab

        browser.newTab()
        XCTAssertEqual(browser.tabs.count, 2)
        let second = browser.selectedTab
        XCTAssertNotIdentical(first, second)
        XCTAssertNotIdentical(first.webView, second.webView)
        XCTAssertIdentical(browser.webView, second.webView)

        // Streams are kept per tab.
        browser.handleDetectedStream(url: "https://cdn.example.com/a/master.m3u8", pageURL: "https://example.com/v",
                                     title: "A", in: first.webView)
        XCTAssertTrue(browser.detectedStreams.isEmpty)
        browser.select(first.id)
        XCTAssertEqual(browser.detectedStreams.first?.type, .hls)

        browser.closeTab(first.id)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertEqual(browser.selectedTabID, second.id)

        // Closing the last tab leaves a fresh empty one.
        browser.closeTab(second.id)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertNotEqual(browser.selectedTabID, second.id)
        XCTAssertNil(browser.currentURL)
    }
}

final class TitleMaskTests: XCTestCase {
    func testMaskHidesTitleButKeepsFileName() {
        let item = DownloadItem(url: "https://site.example/watch/secret-title", outputPath: "/tmp/Secret Title.mp4")
        item.title = "Secret Title"
        item.qualityLabel = "1080p"
        XCTAssertEqual(item.displayTitle(masked: false), "Secret Title (1080p)")
        let masked = item.displayTitle(masked: true)
        XCTAssertTrue(masked.hasPrefix("Video #"))
        XCTAssertFalse(masked.contains("Secret"))
        XCTAssertEqual(masked, item.displayTitle(masked: true))           // stable for the item
        XCTAssertEqual(item.displayFileName(masked: false), "Secret Title.mp4")
        XCTAssertEqual(item.displayFileName(masked: true), "\(item.maskedTitle).mp4")
        XCTAssertEqual(item.outputPath, "/tmp/Secret Title.mp4")          // the real file is untouched

        item.options.extractAudio = true
        XCTAssertTrue(item.maskedTitle.hasPrefix("Audio #"))
    }
}

final class FileNamerTests: XCTestCase {
    func testFindsCodesInTitles() {
        XCTAssertEqual(FileNamer.code(in: "Kebun Raya Bogor [RDS-09888]"), "RDS-09888")
        XCTAssertEqual(FileNamer.code(in: "Kebun Raya Bogor RDS-09888"), "RDS-09888")
        XCTAssertEqual(FileNamer.code(in: "rds09888 kebun raya"), "RDS-09888")
        XCTAssertEqual(FileNamer.code(in: "Clip SHKD 658 uncut"), "SHKD-658")
        XCTAssertEqual(FileNamer.code(in: "Kebun Raya Bogor (09888)"), "09888")
        XCTAssertEqual(FileNamer.code(in: "Kebun Raya Bogor 4471230"), "4471230")
        // Not codes: years, resolutions, episodes, phrases.
        XCTAssertNil(FileNamer.code(in: "Kebun Raya Bogor 2024"))
        XCTAssertNil(FileNamer.code(in: "Kebun Raya Bogor [1080p]"))
        XCTAssertNil(FileNamer.code(in: "Kebun Raya Bogor EP 12"))
        XCTAssertNil(FileNamer.code(in: "Best 2024 moments"))
        XCTAssertNil(FileNamer.code(in: "video_1791536238"))
    }

    func testShortNameFallsBackToInitialsThenRandom() {
        XCTAssertEqual(FileNamer.shortName(for: "Kebun Raya Bogor"), "KRB")
        XCTAssertEqual(FileNamer.shortName(for: "Kebun Raya Bogor (Official Video)"), "KRB")
        let random = FileNamer.shortName(for: "日本の旅")
        XCTAssertEqual(random.count, 6)
        XCTAssertTrue(random.allSatisfy { $0.isUppercase || $0.isNumber })
    }

    func testRenamesUniquelyAndDisguisesExtension() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("namer-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func make(_ name: String) throws -> String {
            let p = dir.appendingPathComponent(name).path
            try Data("x".utf8).write(to: URL(fileURLWithPath: p)); return p
        }

        let a = FileNamer.apply(to: try make("Kebun Raya Bogor [RDS-09888].mp4"), title: "Kebun Raya Bogor [RDS-09888]",
                                naming: .short, disguise: false, extensions: [])
        XCTAssertEqual((a.path as NSString).lastPathComponent, "RDS-09888.mp4")
        XCTAssertNil(a.realExtension)

        // Same short name again: numbered, never overwritten.
        let b = FileNamer.apply(to: try make("Kebun Raya Bogor.mp4"), title: "Kebun Raya Bogor", naming: .short,
                                disguise: false, extensions: [])
        let c = FileNamer.apply(to: try make("Kebun Raya Bogor 2.mp4"), title: "Kebun Raya Bogor", naming: .short,
                                disguise: false, extensions: [])
        XCTAssertEqual((b.path as NSString).lastPathComponent, "KRB.mp4")
        XCTAssertEqual((c.path as NSString).lastPathComponent, "KRB-2.mp4")

        // Disguised extension, real one remembered; the title is kept with "Original title".
        let d = FileNamer.apply(to: try make("Trip.webm"), title: "Trip", naming: .original, disguise: true,
                                extensions: FileNamer.parseExtensions(".jpg, dmg;pkg"))
        XCTAssertTrue(["jpg", "dmg", "pkg"].contains((d.path as NSString).pathExtension))
        XCTAssertEqual(((d.path as NSString).lastPathComponent as NSString).deletingPathExtension, "Trip")
        XCTAssertEqual(d.realExtension, "webm")
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.path))

        // Non-media files are left alone.
        let pdf = try make("Report 2024.pdf")
        XCTAssertEqual(FileNamer.apply(to: pdf, title: "Report", naming: .short, disguise: true, extensions: ["jpg"]).path, pdf)
    }
}

final class BestStreamTests: XCTestCase {
    private func s(_ url: String, _ type: DetectedStream.StreamType) -> DetectedStream {
        DetectedStream(url: url, pageURL: "https://site.com/v", title: "", type: type)
    }

    func testPrefersMasterPlaylist() {
        let streams = [s("https://cdn/v/720/video.m3u8", .hls), s("https://cdn/v/master.m3u8", .hls), s("https://cdn/a.mp4", .direct)]
        XCTAssertEqual(DetectedStream.best(of: streams)?.url, "https://cdn/v/master.m3u8")
    }

    func testMostRecentPlaylistWhenNoMaster() {
        // The pre-roll ad's playlist is found first; the video's comes after it.
        let ad = s("https://cdn/v/video.m3u8", .hls)
        Thread.sleep(forTimeInterval: 0.01)
        let movie = s("https://cdn/m/playlist.m3u8", .hls)
        XCTAssertEqual(DetectedStream.best(of: [movie, ad])?.url, movie.url)
    }

    func testFallsBackToDirectFile() {
        XCTAssertEqual(DetectedStream.best(of: [s("https://cdn/a.mp4", .direct)])?.url, "https://cdn/a.mp4")
        XCTAssertNil(DetectedStream.best(of: []))
    }
}

final class AdDetectionTests: XCTestCase {
    func testHLSDurationSumsSegmentsAndSkipsLive() {
        let vod = "#EXTM3U\n#EXTINF:10.0,\na.ts\n#EXTINF:9.5,\nb.ts\n#EXTINF:4,title\nc.ts\n#EXT-X-ENDLIST"
        XCTAssertEqual(HLS.duration(of: vod), 23.5)
        XCTAssertNil(HLS.duration(of: "#EXTM3U\n#EXTINF:10.0,\na.ts"))
    }

    func testDASHDuration() {
        XCTAssertEqual(DASH.duration(of: #"<MPD mediaPresentationDuration="PT1H2M3.5S" type="static">"#), 3723.5)
        XCTAssertEqual(DASH.isoDuration("PT30S"), 30)
        XCTAssertEqual(DASH.isoDuration("P1DT1M"), 86_460)
        XCTAssertNil(DASH.duration(of: "<MPD type=\"dynamic\">"))
    }

    func testAdAddressesAreRecognizedAndAvoided() {
        XCTAssertTrue(DetectedStream.looksLikeAd("https://imasdk.googleapis.com/x/video.m3u8"))
        XCTAssertTrue(DetectedStream.looksLikeAd("https://cdn.site.com/preroll/master.m3u8"))
        XCTAssertFalse(DetectedStream.looksLikeAd("https://cdn.site.com/hls/movie/master.m3u8"))
        let ad = DetectedStream(url: "https://ads.x.com/vast/master.m3u8", pageURL: "", title: "", type: .hls)
        let main = DetectedStream(url: "https://cdn.x.com/v/playlist.m3u8", pageURL: "", title: "", type: .hls)
        XCTAssertEqual(DetectedStream.best(of: [main, ad])?.url, main.url)
    }
}

/// The stream detector is JavaScript inside a Swift string: an escape gone wrong (a real tab or newline in a
/// regex) makes WebKit reject the whole script and nothing is ever detected. Parse it with WebKit itself.
final class SnifferScriptTests: XCTestCase {
    @MainActor
    func testSnifferScriptParsesInWebKit() async throws {
        let view = WKWebView()
        let source = Data(BrowserModel.mediaSnifferScript.utf8).base64EncodedString()
        let result = try await view.evaluateJavaScript(
            "try { new Function(decodeURIComponent(escape(atob('\(source)')))); 'ok' } catch (e) { String(e) }") as? String
        XCTAssertEqual(result, "ok")
    }
}

final class SSHRouteErrorTests: XCTestCase {
    func testNoRouteErrorsAreExplained() {
        let msg = SSHTunnelManager.friendlyError(
            from: "ssh: connect to host 168.110.217.160 port 22: Can't assign requested address", code: 255)
        XCTAssertTrue(msg.contains("no working route"), msg)
        XCTAssertTrue(SSHTunnelManager.friendlyError(from: "ssh: connect to host x port 22: No route to host", code: 255)
            .contains("no route"))
    }
}
