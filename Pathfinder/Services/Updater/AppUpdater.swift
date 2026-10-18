import AppKit
import Foundation
import Observation

/// Checks GitHub for a newer release and installs it in place (download, verify signature, swap, relaunch).
@MainActor @Observable
final class AppUpdater {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(UpdateRelease)
        case downloading(Double)
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Only a real, writable .app can replace itself; a `swift run` binary can't.
    var canSelfInstall: Bool {
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app") && FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent)
    }

    var availableRelease: UpdateRelease? {
        if case .available(let release) = state { return release }
        return nil
    }

    private static let lastCheckKey = "updateLastCheck"
    private static let lastNotifiedKey = "updateLastNotified"

    private var feedURL: URL {
        ProcessInfo.processInfo.environment["PATHFINDER_UPDATE_FEED"].flatMap(URL.init(string:)) ?? UpdateLogic.feedURL
    }

    /// Quiet check at launch: at most once a day, and never for a bare binary.
    func checkIfDue(enabled: Bool, notify: Bool) async {
        guard enabled, Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        await check(userInitiated: false, notify: notify)
    }

    func check(userInitiated: Bool = true, notify: Bool = false) async {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        do {
            var request = URLRequest(url: feedURL, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Pathfinder/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError.badResponse(http.statusCode) }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            let release = try UpdateLogic.parseRelease(data)
            if UpdateLogic.isNewer(release.version, than: Self.currentVersion) {
                state = .available(release)
                if notify, UserDefaults.standard.string(forKey: Self.lastNotifiedKey) != release.version {
                    UserDefaults.standard.set(release.version, forKey: Self.lastNotifiedKey)
                    Notifier.notify(title: "Pathfinder \(release.version) is available",
                                    body: "Open Settings › About to update.", category: .updateAvailable)
                }
            } else {
                state = .upToDate
            }
        } catch {
            // A background check that fails (offline, rate limit, no release yet) stays silent.
            state = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    /// Downloads, verifies and stages the release, then hands over to a helper script and quits.
    func install() async {
        guard case .available(let release) = state else { return }
        guard canSelfInstall else { NSWorkspace.shared.open(release.pageURL); return }
        state = .downloading(0)
        do {
            let work = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Pathfinder/update", isDirectory: true)
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            let zipFile = work.appendingPathComponent("update.zip")
            try await FileDownloader.download(release.zipURL, to: zipFile) { [weak self] fraction in
                Task { @MainActor in
                    if case .downloading = self?.state { self?.state = .downloading(fraction) }
                }
            }
            let (sigData, sigResponse) = try await URLSession.shared.data(from: release.signatureURL)
            if let http = sigResponse as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError.badResponse(http.statusCode) }
            let signature = String(decoding: sigData, as: UTF8.self)

            state = .installing
            let target = Bundle.main.bundlePath
            let version = release.version
            let identifier = Bundle.main.bundleIdentifier
            let staged = try await Task.detached(priority: .userInitiated) {
                try Self.stage(zip: zipFile, signature: signature, in: work, expectedVersion: version, expectedIdentifier: identifier)
            }.value

            let script = work.appendingPathComponent("install.sh")
            try UpdateLogic.installScript.write(to: script, atomically: true, encoding: .utf8)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/bash")
            helper.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, target, work.path]
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func dismissError() {
        if case .failed = state { state = .idle }
    }

    /// Checks the signature, unpacks the zip and sanity-checks the app inside. Returns the staged app.
    nonisolated static func stage(zip: URL, signature: String, in work: URL,
                                  expectedVersion: String, expectedIdentifier: String?,
                                  publicKey: String = UpdateLogic.publicKey) throws -> URL {
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        guard UpdateLogic.verify(data, signature: signature, publicKey: publicKey) else { throw UpdateError.badSignature }

        let out = work.appendingPathComponent("staged", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])

        let apps = (try FileManager.default.contentsOfDirectory(atPath: out.path)).filter { $0.hasSuffix(".app") }
        guard apps.count == 1 else { throw UpdateError.badPackage("expected one app in the archive") }
        let app = out.appendingPathComponent(apps[0])

        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        if let expectedIdentifier, plist?["CFBundleIdentifier"] as? String != expectedIdentifier {
            throw UpdateError.badPackage("unexpected bundle identifier")
        }
        let version = plist?["CFBundleShortVersionString"] as? String ?? ""
        guard UpdateLogic.components(version) == UpdateLogic.components(expectedVersion) else {
            throw UpdateError.badPackage("version \(version) does not match the release")
        }
        do { try run("/usr/bin/codesign", ["--verify", "--deep", app.path]) }
        catch { throw UpdateError.badPackage("code signature is damaged") }
        return app
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.badPackage("\((path as NSString).lastPathComponent) failed")
        }
    }
}

/// Downloads one file and reports progress (0...1).
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void

    private init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    static func download(_ url: URL, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let downloader = FileDownloader(destination: destination, onProgress: onProgress)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            downloader.continuation = continuation
            let session = URLSession(configuration: .ephemeral, delegate: downloader, delegateQueue: nil)
            session.downloadTask(with: url).resume()
            session.finishTasksAndInvalidate()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            return finish(.failure(UpdateError.badResponse(http.statusCode)))
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
