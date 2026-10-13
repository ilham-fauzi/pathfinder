import Foundation

enum DownloadEvent {
    case progress(ProgressUpdate)
    case log(LogEntry)
    case postProcessing(String)
    case completed(outputPath: String?)
    case error(String)
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let message: String
    
    enum LogLevel: String {
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
        case download = "download"
        case debug = "DEBUG"
        case unknown
    }
    
    static func parse(_ line: String) -> LogEntry {
        var level: LogLevel = .unknown
        if line.contains("[download]") { level = .download }
        else if line.contains("[info]") { level = .info }
        else if line.contains("[warning]") || line.lowercased().contains("warning:") { level = .warning }
        else if line.contains("[error]") || line.lowercased().contains("error:") { level = .error }
        else if line.contains("[debug]") { level = .debug }
        
        return LogEntry(timestamp: Date(), level: level, message: line)
    }
}

/// Controls a running download process. Safe to share across tasks.
final class DownloadHandle: @unchecked Sendable {
    let process: Process
    private let lock = NSLock()
    private var cancelled = false
    private let exit: ProcessExitWaiter

    /// Create before `process.run()`: the exit handler must be in place before the process can exit.
    init(process: Process) {
        self.process = process
        exit = ProcessExitWaiter(process)
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Stop yt-dlp and any child processes (ffmpeg) it spawned.
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        DispatchQueue.global().async { [process] in
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-TERM", "-P", "\(pid)"]
            try? pkill.run()
            pkill.waitUntilExit()
            if process.isRunning { process.terminate() }
        }
    }

    func waitForExit() async -> Int32 { await exit.wait() }
}

enum OutputPathParser {
    /// Extract a file path from yt-dlp lines that announce the output file.
    static func path(from line: String) -> String? {
        if let r = line.range(of: "[Merger] Merging formats into \"") {
            return String(line[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        if let r = line.range(of: "[ExtractAudio] Destination: ") ?? line.range(of: "[download] Destination: ") {
            return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if line.hasPrefix("[download] "), let r = line.range(of: " has already been downloaded") {
            return String(line[line.index(line.startIndex, offsetBy: 11)..<r.lowerBound])
        }
        return nil
    }

    static func isPostProcessing(_ line: String) -> Bool {
        ["[Merger]", "[ExtractAudio]", "[VideoConvertor]", "[VideoRemuxer]", "[Fixup",
         "[EmbedSubtitle]", "[Metadata]", "[ThumbnailsConvertor]", "[EmbedThumbnail]"]
            .contains { line.hasPrefix($0) }
    }
}

actor YTDLPService {
    private var binaryPath: URL?
    private var customPath: String = ""
    private var cache: [String: VideoInfo] = [:]
    private var vpnRequired = false
    private var vpnProxy: String?

    /// VPN state from the SSH tunnel. While `required`, nothing may run outside the tunnel.
    func setVPN(required: Bool, proxy: String?) {
        vpnRequired = required
        vpnProxy = proxy
    }

    /// `--proxy` for the tunnel, or an error when VPN is on but not connected (never fall back to the open network).
    private func vpnArguments() throws -> [String] {
        guard vpnRequired else { return [] }
        guard let proxy = vpnProxy else { throw AppError.vpnUnavailable }
        return ["--proxy", proxy]
    }

    /// Path chosen by the user in Settings (empty = auto-detect).
    func setCustomPath(_ path: String) {
        customPath = path
        binaryPath = nil
    }

    /// Find yt-dlp binary in known locations
    func findBinary() -> URL? {
        if let path = binaryPath { return path }

        if !customPath.isEmpty, FileManager.default.isExecutableFile(atPath: customPath) {
            binaryPath = URL(fileURLWithPath: customPath)
            return binaryPath
        }

        let paths = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Pathfinder/bin/yt-dlp"),
            URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"),
            URL(fileURLWithPath: "/usr/local/bin/yt-dlp"),
            URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/yt-dlp")
        ]

        for url in paths {
            if let p = url, FileManager.default.isExecutableFile(atPath: p.path) {
                binaryPath = p
                return p
            }
        }

        return nil
    }

    /// Get yt-dlp version string
    func getVersion() async throws -> String {
        guard let binary = findBinary() else { throw AppError.binaryNotFound }

        let result = try await ProcessRunner.run(executable: binary, arguments: ["--version"])
        guard result.isSuccess, let output = result.stdoutString?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw AppError.analysisError("Failed to get version")
        }
        return output
    }

    /// Safari user agent sent on both analyze and download, so stream hosts see the same client twice.
    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// `--referer` plus a matching `Origin` header; many HLS/DASH CDNs check both.
    static func refererArguments(_ referer: String?) -> [String] {
        guard let referer, !referer.isEmpty else { return [] }
        var args = ["--referer", referer]
        if let u = URL(string: referer), let scheme = u.scheme, let host = u.host {
            args += ["--add-header", "Origin:\(scheme)://\(host)"]
        }
        return args
    }

    /// Referers to try for a bare stream link (.m3u8/.mpd) pasted without its page:
    /// the stream's own origin, then its parent domain (s4.maxstream.org → maxstream.org).
    static func fallbackReferers(for url: String) -> [String] {
        let lower = url.lowercased()
        guard lower.contains(".m3u8") || lower.contains(".mpd"),
              let u = URL(string: url), let scheme = u.scheme, let host = u.host else { return [] }
        var candidates = ["\(scheme)://\(host)/"]
        let labels = host.split(separator: ".")
        if labels.count > 2 {
            candidates.append("\(scheme)://\(labels.suffix(2).joined(separator: "."))/")
        }
        return candidates
    }

    /// Analyze, and if a bare stream link is refused (HTTP 403) without a referer, retry with
    /// guessed referers. Returns the referer that worked so the download can reuse it.
    func analyzeWithRefererFallback(url: String, referer: String?, cookiesFile: URL?) async throws -> (VideoInfo, String?) {
        do {
            return (try await analyze(url: url, referer: referer, cookiesFile: cookiesFile, forceRefresh: true), referer)
        } catch let first as AppError {
            guard referer == nil || referer?.isEmpty == true, first.localizedDescription.contains("403") else { throw first }
            for candidate in Self.fallbackReferers(for: url) {
                if let info = try? await analyze(url: url, referer: candidate, cookiesFile: cookiesFile, forceRefresh: true) {
                    return (info, candidate)
                }
            }
            throw AppError.analysisError("Access denied (HTTP 403 Forbidden). This stream only plays from the page that embeds it — open that page in the in-app Browser tab and download the detected stream from there.")
        }
    }

    /// Analyze URL - returns VideoInfo with all metadata. Results are cached per URL.
    func analyze(url: String, referer: String? = nil, cookiesFile: URL? = nil, forceRefresh: Bool = false) async throws -> VideoInfo {
        if !forceRefresh, let cached = cache[url] { return cached }
        guard let binary = findBinary() else { throw AppError.binaryNotFound }

        var args = [
            "--dump-single-json", "--no-playlist", "--no-warnings", "--no-download",
            "--user-agent", Self.safariUserAgent
        ] + Self.refererArguments(referer)
        if let cookiesFile = cookiesFile {
            args += ["--cookies", cookiesFile.path]
        }

        let result = try await ProcessRunner.run(
            executable: binary,
            arguments: args + (try vpnArguments()) + [url]
        )
        guard result.isSuccess else {
            throw AppError.analysisError(ErrorMapper.message(for: result.stderrString ?? ""))
        }
        guard !result.stdout.isEmpty else {
            throw AppError.analysisError("No video information was returned.")
        }

        do {
            let info = try JSONDecoder().decode(VideoInfo.self, from: result.stdout)
            cache[url] = info
            return info
        } catch {
            throw AppError.analysisError("Could not read the video information.")
        }
    }

    /// One page (`start...end`, 1-based) of a channel / playlist / search, without downloading anything.
    func list(source: ListingSource, start: Int, end: Int) async throws -> ListingPage {
        guard let binary = findBinary() else { throw AppError.binaryNotFound }
        let result = try await ProcessRunner.run(
            executable: binary,
            arguments: ["--flat-playlist", "--dump-single-json", "--no-warnings",
                        "--playlist-start", "\(start)", "--playlist-end", "\(end)"]
                + (try vpnArguments()) + [source.target(end: end)]
        )
        guard result.isSuccess else {
            throw AppError.analysisError(ErrorMapper.message(for: result.stderrString ?? ""))
        }
        guard !result.stdout.isEmpty else { throw AppError.analysisError("No videos were returned.") }
        do { return try ListingParser.parse(result.stdout) }
        catch { throw AppError.analysisError("Could not read the list.") }
    }

    /// List available formats for URL (uses the cached analysis)
    func listFormats(url: String) async throws -> [FormatInfo] {
        let info = try await analyze(url: url)
        return info.formats ?? []
    }

    /// List available subtitles (uses the cached analysis)
    func listSubtitles(url: String) async throws -> [String: [SubtitleTrack]] {
        let info = try await analyze(url: url)
        return info.subtitles ?? [:]
    }

    /// Start download with progress streaming. Use the handle to cancel.
    func download(url: String, options: DownloadOptions, outputDir: String, cookiesFile: URL? = nil) -> (handle: DownloadHandle, events: AsyncStream<DownloadEvent>) {
        let binary = findBinary() ?? URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        // The cookies file belongs to this download; remove it on every exit path.
        let discardCookies: @Sendable () -> Void = { if let cookiesFile { try? FileManager.default.removeItem(at: cookiesFile) } }
        let vpnArgs: [String]
        do { vpnArgs = try vpnArguments() } catch {
            discardCookies()
            let message = error.localizedDescription
            let dead = Process()
            return (DownloadHandle(process: dead), AsyncStream { $0.yield(.error(message)); $0.finish() })
        }
        var cookiesArgs: [String] = []
        if let cookiesFile = cookiesFile {
            cookiesArgs = ["--cookies", cookiesFile.path]
        }
        // Match the analyze request: same user agent, and an Origin header to go with the referer.
        if options.userAgent == nil { cookiesArgs += ["--user-agent", Self.safariUserAgent] }
        if let referer = options.referer, !options.customHeaders.keys.contains(where: { $0.lowercased() == "origin" }) {
            cookiesArgs += Self.refererArguments(referer).dropFirst(2)
        }
        let (process, lines) = ProcessRunner.stream(
            executable: binary,
            arguments: options.toArgs() + vpnArgs + cookiesArgs + ["--newline", "--no-playlist", "--progress", "--progress-template", ProgressUpdate.template, "-P", outputDir, url]
        )
        let handle = DownloadHandle(process: process)

        do {
            try process.run()
        } catch {
            discardCookies()
            let message = error.localizedDescription
            return (handle, AsyncStream { $0.yield(.error(message)); $0.finish() })
        }

        let events = AsyncStream<DownloadEvent> { continuation in
            Task.detached {
                var lastPath: String?
                var lastError: String?
                // A video+audio download runs as separate streams, each going 0→100%.
                // Scale them into one overall percentage.
                var streamCount = 1
                var streamIndex = 0
                // yt-dlp prints progress for every chunk (dozens per second); each update redraws the
                // row, the tray icon and the dock. A few updates per second look the same.
                let clock = ContinuousClock()
                var lastProgressAt = clock.now - .seconds(1)
                var newStream = true
                for await line in lines {
                    if line.contains("Downloading "), line.contains("format(s):"),
                       let spec = line.components(separatedBy: "format(s):").last {
                        streamCount = max(1, spec.split(separator: "+").count)
                    }
                    if line.hasPrefix("[download] Destination:") { streamIndex += 1; newStream = true }
                    if let update = ProgressUpdate.parse(line) {
                        let now = clock.now
                        // Always pass the first and last update of each stream, so the bar never skips a step.
                        guard newStream || update.percent >= 100 || now - lastProgressAt >= .milliseconds(250) else { continue }
                        lastProgressAt = now
                        newStream = false
                        let done = Double(max(streamIndex - 1, 0))
                        let overall = (done + update.percent / 100) / Double(streamCount) * 100
                        continuation.yield(.progress(ProgressUpdate(
                            percent: min(overall, 100), speed: update.speed, eta: update.eta,
                            downloadedBytes: update.downloadedBytes, totalBytes: update.totalBytes)))
                        continue
                    }
                    continuation.yield(.log(LogEntry.parse(line)))
                    if let path = OutputPathParser.path(from: line) { lastPath = path }
                    if OutputPathParser.isPostProcessing(line) { continuation.yield(.postProcessing(line)) }
                    if line.contains("ERROR:") { lastError = line }
                }

                let status = await handle.waitForExit()
                discardCookies()
                if handle.isCancelled {
                    // Cancelled/paused by the user: no completion or error event.
                } else if status == 0 {
                    continuation.yield(.completed(outputPath: lastPath))
                } else {
                    continuation.yield(.error(ErrorMapper.message(for: lastError ?? "")))
                }
                continuation.finish()
            }
        }
        return (handle, events)
    }

    /// Update yt-dlp binary
    func updateBinary(channel: String) async throws -> String {
        guard let binary = findBinary() else { throw AppError.binaryNotFound }

        let result = try await ProcessRunner.run(executable: binary, arguments: ["--update-to", channel] + (try vpnArguments()))
        return (result.stdoutString ?? "") + (result.stderrString ?? "")
    }
}
