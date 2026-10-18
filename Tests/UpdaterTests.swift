import CryptoKit
import XCTest
@testable import Pathfinder

final class UpdaterTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateLogic.isNewer("0.3.0", than: "0.2.0"))
        XCTAssertTrue(UpdateLogic.isNewer("v1.0", than: "0.9.9"))
        XCTAssertTrue(UpdateLogic.isNewer("0.2.1", than: "0.2"))
        XCTAssertTrue(UpdateLogic.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertFalse(UpdateLogic.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertFalse(UpdateLogic.isNewer("0.2", than: "0.2.0"))
        XCTAssertFalse(UpdateLogic.isNewer("0.1.9", than: "0.2.0"))
        XCTAssertFalse(UpdateLogic.isNewer("1.0.0-beta", than: "1.0.0"))
    }

    private func releaseJSON(assets: String, extra: String = "") -> Data {
        Data("""
        {"tag_name":"v0.3.0","body":"Notes","html_url":"https://github.com/x/y/releases/tag/v0.3.0",\(extra)"assets":[\(assets)]}
        """.utf8)
    }

    func testParseRelease() throws {
        let json = releaseJSON(assets: """
        {"name":"Pathfinder.pkg","browser_download_url":"https://x/p.pkg"},
        {"name":"pathfinder-v0.3.0.zip","browser_download_url":"https://x/p.zip"},
        {"name":"pathfinder-v0.3.0.zip.sig","browser_download_url":"https://x/p.zip.sig"}
        """)
        let release = try UpdateLogic.parseRelease(json)
        XCTAssertEqual(release.version, "0.3.0")
        XCTAssertEqual(release.zipURL.absoluteString, "https://x/p.zip")
        XCTAssertEqual(release.signatureURL.absoluteString, "https://x/p.zip.sig")
        XCTAssertEqual(release.notes, "Notes")
    }

    func testReleaseWithoutSignatureIsRejected() {
        let json = releaseJSON(assets: #"{"name":"pathfinder-v0.3.0.zip","browser_download_url":"https://x/p.zip"}"#)
        XCTAssertThrowsError(try UpdateLogic.parseRelease(json))
    }

    func testPrereleaseIsRejected() {
        let json = releaseJSON(assets: """
        {"name":"a.zip","browser_download_url":"https://x/a.zip"},{"name":"a.zip.sig","browser_download_url":"https://x/a.sig"}
        """, extra: #""prerelease":true,"#)
        XCTAssertThrowsError(try UpdateLogic.parseRelease(json))
    }

    func testSignatureVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let payload = Data("pathfinder".utf8)
        let signature = try Data(key.signature(for: payload)).base64EncodedString() + "\n"
        XCTAssertTrue(UpdateLogic.verify(payload, signature: signature, publicKey: publicKey))
        XCTAssertFalse(UpdateLogic.verify(Data("tampered".utf8), signature: signature, publicKey: publicKey))
        XCTAssertFalse(UpdateLogic.verify(payload, signature: "not base64!", publicKey: publicKey))
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(UpdateLogic.verify(payload, signature: signature, publicKey: other))
    }

    /// Runs the real install script against fake app folders: swap succeeds, old copy is removed.
    func testInstallScriptSwapsApp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pf-install-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("Applications/Pathfinder.app")
        let new = root.appendingPathComponent("work/staged/Pathfinder.app")
        let work = root.appendingPathComponent("work")
        for (dir, marker) in [(target, "old"), (new, "new")] {
            try fm.createDirectory(at: dir.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try marker.write(to: dir.appendingPathComponent("Contents/marker"), atomically: true, encoding: .utf8)
        }
        let script = work.appendingPathComponent("install.sh")
        try UpdateLogic.installScript.replacingOccurrences(of: "open \"$TARGET\"", with: "true")
            .write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // pid 999999 does not exist, so the script proceeds immediately.
        process.arguments = [script.path, "999999", new.path, target.path, work.path]
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("Contents/marker"), encoding: .utf8), "new")
        XCTAssertFalse(fm.fileExists(atPath: work.appendingPathComponent("previous.app").path))
    }

    /// Real zip + codesign + signature through `AppUpdater.stage`.
    func testStageAcceptsSignedPackageAndRejectsTampering() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pf-stage-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("src/Pathfinder.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: app.appendingPathComponent("Contents/MacOS/Pathfinder"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appendingPathComponent("Contents/MacOS/Pathfinder").path)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.pathfinder.Pathfinder", "CFBundleShortVersionString": "0.3.0",
                                    "CFBundleExecutable": "Pathfinder", "CFBundlePackageType": "APPL"]
        (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        func run(_ path: String, _ args: [String]) throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
            try p.run(); p.waitUntilExit(); XCTAssertEqual(p.terminationStatus, 0, "\(path) \(args)")
        }
        try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
        let zip = root.appendingPathComponent("update.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])

        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let signature = try Data(key.signature(for: Data(contentsOf: zip))).base64EncodedString()

        let staged = try AppUpdater.stage(zip: zip, signature: signature, in: root, expectedVersion: "0.3.0",
                                          expectedIdentifier: "com.pathfinder.Pathfinder", publicKey: publicKey)
        XCTAssertTrue(fm.fileExists(atPath: staged.appendingPathComponent("Contents/Info.plist").path))

        XCTAssertThrowsError(try AppUpdater.stage(zip: zip, signature: signature, in: root, expectedVersion: "0.4.0",
                                                  expectedIdentifier: "com.pathfinder.Pathfinder", publicKey: publicKey))
        XCTAssertThrowsError(try AppUpdater.stage(zip: zip, signature: signature, in: root, expectedVersion: "0.3.0",
                                                  expectedIdentifier: "com.other.App", publicKey: publicKey))
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertThrowsError(try AppUpdater.stage(zip: zip, signature: signature, in: root, expectedVersion: "0.3.0",
                                                  expectedIdentifier: "com.pathfinder.Pathfinder", publicKey: other))
    }
}
