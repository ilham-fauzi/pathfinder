import XCTest
@testable import Pathfinder

@MainActor
final class TrustAllTests: XCTestCase {
    private var root: URL!
    private var folder: URL!

    /// `TMPDIR` when set (a sandboxed run gives its own writable folder), else the user's temporary folder.
    private static var temporaryDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["TMPDIR"], !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.temporaryDirectory
    }

    override func setUp() async throws {
        root = Self.temporaryDirectory.appendingPathComponent("pf-trust-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A monitor with its own store, watching the test's Downloads folder.
    private func monitor() -> FileIntegrityMonitor {
        let fim = FileIntegrityMonitor(storeURL: root.appendingPathComponent("integrity.json"))
        fim.watchedFolders = { [folder] in [folder!.path] }
        return fim
    }

    @discardableResult
    private func file(_ name: String, _ text: String) throws -> String {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    private func newFiles(_ count: Int, after fim: FileIntegrityMonitor) async throws -> [String] {
        // Files count as new only when created after monitoring began.
        try await Task.sleep(for: .milliseconds(50))
        return try (0..<count).map { try file("new-\($0).bin", "new \($0)") }
    }

    // SC-1: new files become manual entries; changed files keep source and origin; nothing is left to report.
    func testSC1TrustsNewAndChangedFiles() async throws {
        let fim = monitor()
        let saved = try file("movie.mp4", "original")
        await fim.record(path: saved, source: .download, origin: "https://site.test/v/1")
        let fresh = try await newFiles(3, after: fim)
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: saved))
        await fim.verify(deep: true)
        XCTAssertEqual(fim.trustAllCounts.new, 3)
        XCTAssertEqual(fim.trustAllCounts.changed, 1)

        await fim.trustAll()
        XCTAssertEqual(fim.problemCount, 0)
        XCTAssertTrue(fim.unexpected.isEmpty)
        let movie = try XCTUnwrap(fim.entries.first { $0.path == saved })
        XCTAssertEqual(movie.source, .download)
        XCTAssertEqual(movie.origin, "https://site.test/v/1")
        XCTAssertEqual(movie.sha256, FileIntegrityMonitor.hash(of: saved))
        for path in fresh {
            XCTAssertEqual(fim.entries.first { $0.path == path }?.source, .manual)
            XCTAssertEqual(fim.states[path], .ok)
        }

        // A later check agrees: the trusted contents are the new reference.
        await fim.verify(deep: true)
        XCTAssertEqual(fim.problemCount, 0)
    }

    // SC-2: missing files stay missing; an unchanged tool is not re-recorded.
    func testSC2MissingAndUnchangedToolsAreLeftAlone() async throws {
        let fim = monitor()
        let gone = try file("gone.mp4", "soon deleted")
        await fim.record(path: gone, source: .download)
        let tool = try file("yt-dlp", "tool")
        await fim.record(path: tool, source: .tool)
        let toolAdded = try XCTUnwrap(fim.entries.first { $0.path == tool }?.addedAt)
        try FileManager.default.removeItem(atPath: gone)
        _ = try await newFiles(1, after: fim)
        await fim.verify(deep: true)

        await fim.trustAll()
        XCTAssertEqual(fim.states[gone], .missing)
        XCTAssertTrue(fim.entries.contains { $0.path == gone })
        XCTAssertEqual(fim.problemCount, 1, "only the missing file is left")
        XCTAssertEqual(fim.entries.first { $0.path == tool }?.addedAt, toolAdded)
        XCTAssertFalse(fim.canTrustAll)
    }

    // SC-3: the button shows only when there is something to trust, and the prompt names the counts.
    func testSC3ButtonVisibilityAndPrompt() async throws {
        let fim = monitor()
        XCTAssertFalse(fim.canTrustAll)
        let saved = try file("a.mp4", "a")
        await fim.record(path: saved, source: .download)
        await fim.verify(deep: true)
        XCTAssertFalse(fim.canTrustAll, "unchanged files need no trust")
        try FileManager.default.removeItem(atPath: saved)
        await fim.verify(deep: true)
        XCTAssertFalse(fim.canTrustAll, "missing files can't be trusted")
        _ = try await newFiles(1, after: fim)
        await fim.verify(deep: true)
        XCTAssertTrue(fim.canTrustAll)

        XCTAssertEqual(TrustAllPrompt.title(new: 14, changed: 2), "Trust 14 new files and 2 changed files?")
        XCTAssertEqual(TrustAllPrompt.title(new: 1, changed: 0), "Trust 1 new file?")
        XCTAssertEqual(TrustAllPrompt.title(new: 0, changed: 1), "Trust 1 changed file?")
        XCTAssertTrue(TrustAllPrompt.message.contains("Missing files are not affected"))
    }

    // SC-4: one write for the whole list, no second run while one is going, `trusting` shown meanwhile.
    func testSC4OneSaveNoDoubleRun() async throws {
        let fim = monitor()
        _ = try await newFiles(14, after: fim)
        await fim.verify(deep: true)
        XCTAssertEqual(fim.trustAllCounts.new, 14)
        let before = fim.saveCount

        let first = Task { await fim.trustAll() }
        var sawTrusting = false
        for _ in 0..<50 where !sawTrusting {
            await Task.yield()
            sawTrusting = fim.trusting
        }
        await fim.trustAll()   // pressed again while the first runs: does nothing
        await first.value

        XCTAssertTrue(sawTrusting)
        XCTAssertFalse(fim.trusting)
        XCTAssertEqual(fim.saveCount - before, 1)
        XCTAssertEqual(fim.problemCount, 0)
        XCTAssertEqual(fim.entries.count, 14)
    }
}
