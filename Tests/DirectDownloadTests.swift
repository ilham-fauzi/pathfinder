import XCTest
@testable import Pathfinder

/// A server that answers a request without a Range header with a short trailer and a ranged request with the
/// file. With `onlyFromStart`, a range that does not begin at byte 0 is refused (no parallel pieces).
private final class TrailerServer {
    let url: URL
    let full: Data
    private let process = Process()

    init(size: Int, onlyFromStart: Bool) async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("python3 not available") }
        full = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
        let file = writableTemporaryDirectory().appendingPathComponent("pf-trailer-\(UUID().uuidString).bin")
        try full.write(to: file)
        let port = Int.random(in: 20000...40000)
        process.executableURL = python
        process.arguments = ["-c", """
        import http.server, re
        DATA = open('\(file.path)', 'rb').read()
        ONLY_FROM_START = \(onlyFromStart ? "True" : "False")
        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_GET(self):
                rng = self.headers.get('Range')
                m = re.match(r'bytes=(\\d+)-(\\d*)$', rng or '')
                if not m:
                    body = DATA[:1000]
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers(); self.wfile.write(body); return
                start = int(m.group(1))
                end = int(m.group(2)) if m.group(2) else len(DATA) - 1
                if ONLY_FROM_START and start != 0:
                    self.send_response(403); self.send_header('Content-Length', '0'); self.end_headers(); return
                end = min(end, len(DATA) - 1)
                body = DATA[start:end + 1]
                self.send_response(206)
                self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, len(DATA)))
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers(); self.wfile.write(body)
        http.server.ThreadingHTTPServer(('127.0.0.1', \(port)), H).serve_forever()
        """]
        try process.run()
        url = URL(string: "http://127.0.0.1:\(port)/film.mp4")!
        for _ in 0..<50 {
            if (try? await URLSession.shared.data(from: url)) != nil { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func stop() { process.terminate() }
}

final class DirectDownloadTests: XCTestCase {
    private func destination() -> URL {
        writableTemporaryDirectory().appendingPathComponent("pf-film-\(UUID().uuidString).mp4")
    }

    /// Several connections: every piece is a ranged request, so the film arrives, not the trailer.
    func testSegmentedPathSavesFullFile() async throws {
        let size = 3 * 1_048_576 + 12_345
        let server = try await TrailerServer(size: size, onlyFromStart: false)
        defer { server.stop() }
        let out = destination()
        defer { try? FileManager.default.removeItem(at: out) }
        let downloader = SegmentedDownloader(url: server.url, headers: [:], length: Int64(size), socksPort: nil)
        try await downloader.run(to: out) { _ in }
        XCTAssertEqual(try Data(contentsOf: out), server.full)
    }

    /// One connection (the server refuses pieces): the whole-file request is still the player's "bytes=0-".
    func testSingleConnectionPathSavesFullFile() async throws {
        let size = 2 * 1_048_576 + 777
        let server = try await TrailerServer(size: size, onlyFromStart: true)
        defer { server.stop() }
        let out = destination()
        defer { try? FileManager.default.removeItem(at: out) }
        let downloader = SegmentedDownloader(url: server.url, headers: [:], length: Int64(size), socksPort: nil)
        try await downloader.run(to: out) { _ in }
        XCTAssertEqual(try Data(contentsOf: out), server.full)
    }

    @MainActor
    func testPlayerRequestMatchesWhatAPlayerSends() {
        let request = BrowserModel.playerRequest(for: URL(string: "https://cdn.example/v.mp4?t=1")!,
                                                 referer: "https://site.example/embed/9")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://site.example/embed/9")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://site.example")
        XCTAssertFalse((request.value(forHTTPHeaderField: "User-Agent") ?? "").isEmpty)
    }

    func testRangedAnswerQualifiesWithItsFullLength() {
        let url = URL(string: "https://cdn.example/v.mp4")!
        let big = 100 * 1_048_576
        let partial = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
            "Content-Range": "bytes 0-\(big - 1)/\(big)", "Accept-Ranges": "bytes"])!
        XCTAssertEqual(SegmentedDownloader.fullLength(of: partial), Int64(big))
        XCTAssertTrue(SegmentedDownloader.qualifies(partial))
        let preview = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "1000"])!
        XCTAssertFalse(SegmentedDownloader.qualifies(preview))
    }

    @MainActor
    func testResponseLogLineShortensTheAddress() {
        let url = URL(string: "https://cdn.example/path/video.mp4?token=abcdefghijklmnopqrstuvwxyz")!
        let http = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
            "Content-Type": "video/mp4", "Content-Length": "10", "Content-Range": "bytes 0-9/10", "Accept-Ranges": "bytes"])!
        let line = StreamCheckLog.describe(http)
        for part in ["status 206", "video/mp4", "Content-Length 10", "bytes 0-9/10", "Accept-Ranges bytes", "cdn.example/path/video.mp4"] {
            XCTAssertTrue(line.contains(part), line)
        }
        XCTAssertFalse(line.contains("abcdefghijklmnopqrstuvwxyz"), line)
    }

    @MainActor
    func testPreviewIsReportedWithBothLengths() {
        let message = PreviewCheck.message(savedSeconds: 32, expectedSeconds: 6273)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("0:32") == true && message?.contains("1:44:33") == true, message ?? "")
        XCTAssertNil(PreviewCheck.message(savedSeconds: 6270, expectedSeconds: 6273))
        XCTAssertNil(PreviewCheck.message(savedSeconds: nil, expectedSeconds: 6273))
        XCTAssertNil(PreviewCheck.message(savedSeconds: 32, expectedSeconds: nil))
    }
}
