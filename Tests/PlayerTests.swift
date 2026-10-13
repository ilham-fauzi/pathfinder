import XCTest
@testable import Pathfinder

final class PlayerTests: XCTestCase {
    private func bytes(_ parts: [UInt8]..., padTo size: Int = 64) -> Data {
        var data = Data(parts.flatMap { $0 })
        if data.count < size { data.append(Data(count: size - data.count)) }
        return data
    }

    private func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: MediaDetector

    func testDetectsMP4AndQuickTimeAndM4A() {
        XCTAssertEqual(MediaDetector.detect(head: bytes([0, 0, 0, 0x20], ascii("ftyp"), ascii("isom")))?.ext, "mp4")
        XCTAssertEqual(MediaDetector.detect(head: bytes([0, 0, 0, 0x14], ascii("ftyp"), ascii("qt  ")))?.ext, "mov")
        XCTAssertEqual(MediaDetector.detect(head: bytes([0, 0, 0, 0x20], ascii("ftyp"), ascii("M4A ")))?.ext, "m4a")
    }

    func testPhotoBrandsAreNotVideos() {
        XCTAssertNil(MediaDetector.detect(head: bytes([0, 0, 0, 0x18], ascii("ftyp"), ascii("heic"))))
        XCTAssertNil(MediaDetector.detect(head: bytes([0, 0, 0, 0x18], ascii("ftyp"), ascii("avif"))))
    }

    func testMatroskaVersusWebM() {
        let ebml: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3]
        XCTAssertEqual(MediaDetector.detect(head: bytes(ebml, [0x42, 0x82, 0x88], ascii("matroska")))?.ext, "mkv")
        XCTAssertEqual(MediaDetector.detect(head: bytes(ebml, [0x42, 0x82, 0x84], ascii("webm")))?.ext, "webm")
    }

    func testRIFFAndOtherContainers() {
        XCTAssertEqual(MediaDetector.detect(head: bytes(ascii("RIFF"), [0, 0, 0, 0], ascii("AVI ")))?.ext, "avi")
        XCTAssertEqual(MediaDetector.detect(head: bytes(ascii("RIFF"), [0, 0, 0, 0], ascii("WAVE")))?.ext, "wav")
        XCTAssertNil(MediaDetector.detect(head: bytes(ascii("RIFF"), [0, 0, 0, 0], ascii("WEBP"))))
        XCTAssertEqual(MediaDetector.detect(head: bytes(ascii("FLV"), [1, 5, 0, 0, 0, 9]))?.ext, "flv")
        XCTAssertEqual(MediaDetector.detect(head: bytes(ascii("OggS")))?.ext, "ogg")
        XCTAssertEqual(MediaDetector.detect(head: bytes(ascii("fLaC")))?.ext, "flac")
        XCTAssertEqual(MediaDetector.detect(head: bytes(ascii("ID3"), [4, 0]))?.ext, "mp3")
    }

    func testAudioFrameSyncSeparatesMP3FromAAC() {
        XCTAssertEqual(MediaDetector.detect(head: bytes([0xFF, 0xFB, 0x90, 0x00]))?.ext, "mp3")
        XCTAssertEqual(MediaDetector.detect(head: bytes([0xFF, 0xF1, 0x50, 0x80]))?.ext, "aac")
    }

    func testTransportStreamNeedsThreeSyncBytes() {
        var ts = Data(count: 400)
        ts[0] = 0x47; ts[188] = 0x47; ts[376] = 0x47
        XCTAssertEqual(MediaDetector.detect(head: ts)?.ext, "ts")
        ts[376] = 0
        XCTAssertNil(MediaDetector.detect(head: ts))
    }

    func testOrdinaryFilesAreNotMedia() {
        XCTAssertNil(MediaDetector.detect(head: bytes([0xFF, 0xD8, 0xFF, 0xE0])))               // JPEG
        XCTAssertNil(MediaDetector.detect(head: bytes([0x89], ascii("PNG"), [0x0D, 0x0A])))     // PNG
        XCTAssertNil(MediaDetector.detect(head: bytes(ascii("%PDF-1.7\n"))))                     // PDF
        XCTAssertNil(MediaDetector.detect(head: bytes(ascii("PK"), [3, 4])))                     // ZIP
        XCTAssertNil(MediaDetector.detect(head: Data([1, 2, 3])))                                // too short
    }

    // MARK: PlayerGate

    private func tempFile(named name: String, contents: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url.path
    }

    private let mkv = Data([0x1A, 0x45, 0xDF, 0xA3, 0x42, 0x82, 0x88] + Array("matroska".utf8) + [UInt8](repeating: 0, count: 64))
    private func rules(enabled: Bool, scope: DisguisedScope = .allowlist, _ extensions: [String] = ["dat"]) -> PlayerGate.Rules {
        .init(enabled: enabled, scope: scope, extensions: extensions)
    }

    func testRealMediaExtensionPlaysWithoutReadingAnything() throws {
        let path = try tempFile(named: "clip.mp4", contents: Data(count: 4))
        XCTAssertEqual(PlayerGate.evaluate(path: path, rules: rules(enabled: false)), .play(realExtension: nil, badge: nil))
    }

    func testDisguisedFileIsRefusedWhileTheSettingIsOff() throws {
        let path = try tempFile(named: "notes.dat", contents: mkv)
        XCTAssertEqual(PlayerGate.evaluate(path: path, rules: rules(enabled: false)), .disabled(ext: "dat"))
    }

    func testDisguisedFilePlaysWhenOnAndListed() throws {
        let path = try tempFile(named: "notes.dat", contents: mkv)
        XCTAssertEqual(PlayerGate.evaluate(path: path, rules: rules(enabled: true)),
                       .play(realExtension: "mkv", badge: "Disguised · Matroska"))
    }

    func testExtensionOutsideTheListIsNotAllowedUnlessScopeIsAll() throws {
        let path = try tempFile(named: "notes.xyz", contents: mkv)
        XCTAssertEqual(PlayerGate.evaluate(path: path, rules: rules(enabled: true)), .notAllowed(ext: "xyz"))
        XCTAssertEqual(PlayerGate.evaluate(path: path, rules: rules(enabled: true, scope: .all)),
                       .play(realExtension: "mkv", badge: "Disguised · Matroska"))
    }

    func testFileWithoutExtensionPassesTheList() throws {
        let path = try tempFile(named: "holiday", contents: mkv)
        XCTAssertEqual(PlayerGate.evaluate(path: path, rules: rules(enabled: true)),
                       .play(realExtension: "mkv", badge: "Disguised · Matroska"))
    }

    func testNonMediaContentAndMissingFiles() throws {
        let pdf = try tempFile(named: "report.dat", contents: Data("%PDF-1.7 and some more text".utf8))
        XCTAssertEqual(PlayerGate.evaluate(path: pdf, rules: rules(enabled: true)), .notMedia)
        XCTAssertEqual(PlayerGate.evaluate(path: "/nonexistent/file.dat", rules: rules(enabled: true)), .missing)
    }

    // MARK: PlayerIngest

    private func tempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private let mp4 = Data([0, 0, 0, 0x20] + Array("ftypisom".utf8) + [UInt8](repeating: 0, count: 64))

    func testFolderTakesEveryFileByContentWhateverItsExtension() throws {
        let dir = try tempFolder()
        try mp4.write(to: dir.appendingPathComponent("a.mp4"))
        try mp4.write(to: dir.appendingPathComponent("b.jpg"))      // disguised, not on the allow-list
        try mkv.write(to: dir.appendingPathComponent("c"))          // no extension
        try Data("just text, not media at all".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data(count: 4).write(to: dir.appendingPathComponent(".hidden"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)

        let result = PlayerIngest.scan([dir], rules: rules(enabled: true, ["dat"]))
        XCTAssertEqual(result.entries.map { ($0.path as NSString).lastPathComponent }, ["a.mp4", "b.jpg", "c"])
        XCTAssertEqual(result.entries.map(\.realExtension), [nil, "mp4", "mkv"])
        XCTAssertEqual(result.notVideo, 1)
    }

    func testFolderWithTheSettingOffKeepsOnlyRealMediaNames() throws {
        let dir = try tempFolder()
        try mp4.write(to: dir.appendingPathComponent("a.mp4"))
        try mp4.write(to: dir.appendingPathComponent("b.dat"))
        let result = PlayerIngest.scan([dir], rules: rules(enabled: false))
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.needsSetting, 1)
    }

    func testSeveralFilesAreKeptInOrderWithoutDuplicates() throws {
        let dir = try tempFolder()
        let a = dir.appendingPathComponent("a.mp4"), b = dir.appendingPathComponent("b.mp4")
        try mp4.write(to: a); try mp4.write(to: b)
        let result = PlayerIngest.scan([b, a, b], rules: rules(enabled: false))
        XCTAssertEqual(result.entries.map { ($0.path as NSString).lastPathComponent }, ["b.mp4", "a.mp4"])
    }

    func testOnePickedFileExplainsWhyItWasRefused() throws {
        let dir = try tempFolder()
        let file = dir.appendingPathComponent("x.dat")
        try mkv.write(to: file)
        XCTAssertEqual(PlayerIngest.scan([file], rules: rules(enabled: false)).rejections, [.disabled(ext: "dat")])
        XCTAssertEqual(PlayerIngest.scan([dir.appendingPathComponent("gone.mp4")], rules: rules(enabled: false)).missing, 1)
    }

    // MARK: HoldRamp

    func testTapIsShorterThanTheHoldDelay() {
        XCTAssertNil(HoldRamp.normal.speedIndex(heldFor: 0.1))
        XCTAssertEqual(HoldRamp.normal.speedIndex(heldFor: 0.2), 0)
    }

    func testNormalRampClimbsFrom2xTo64x() {
        let speeds = [0.3, 2.0, 3.5, 5.0, 6.5, 8.0, 9.5].compactMap { HoldRamp.normal.speedIndex(heldFor: $0) }.map { HoldRamp.speeds[$0] }
        XCTAssertEqual(speeds, [2, 3, 4, 8, 16, 32, 64])
        XCTAssertEqual(HoldRamp.normal.speedIndex(heldFor: 60), HoldRamp.speeds.count - 1, "stays at the top")
    }

    func testEveryClimbingRampReachesTheTopSpeed() {
        for ramp in [HoldRamp.slow, .normal, .fast] {
            XCTAssertEqual(ramp.speedIndex(heldFor: 1000), HoldRamp.speeds.count - 1, "\(ramp)")
        }
    }

    func testScanMovesByKeyframeAboveSixteenTimes() {
        XCTAssertFalse(ScrubInfo(forward: true, speedIndex: 4).stepped)   // 16×
        XCTAssertTrue(ScrubInfo(forward: true, speedIndex: 5).stepped)    // 32×
        XCTAssertTrue(ScrubInfo(forward: false, speedIndex: 0).stepped)   // any rewind
        XCTAssertFalse(ScrubInfo(forward: true, speedIndex: 2).muted)     // 4×: sound on
        XCTAssertTrue(ScrubInfo(forward: true, speedIndex: 3).muted)      // 8×: muted
    }

    func testFixedRampStaysAt2x() {
        XCTAssertEqual(HoldRamp.fixed2x.speedIndex(heldFor: 30), 0)
    }

    func testFastRampIsQuickerThanSlow() {
        XCTAssertGreaterThan(HoldRamp.fast.speedIndex(heldFor: 2) ?? 0, HoldRamp.slow.speedIndex(heldFor: 2) ?? 0)
    }

    func testTimeFormat() {
        XCTAssertEqual(PlayerTime.format(0), "0:00")
        XCTAssertEqual(PlayerTime.format(125), "2:05")
        XCTAssertEqual(PlayerTime.format(3725), "1:02:05")
        XCTAssertEqual(PlayerTime.format(.nan), "0:00")
    }
}
