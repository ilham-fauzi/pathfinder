import Foundation
import SwiftUI

/// Downloads through the in-app browser (see `DownloadEngine.browser`).
@MainActor
protocol BrowserDownloadEngine: AnyObject {
    /// Fetch `item`, updating its progress; returns the saved file's path. Throws CancellationError when stopped.
    func download(_ item: DownloadItem) async throws -> String
}

@Observable
@MainActor
class QueueManager {
    private(set) var items: [DownloadItem] = []
    private(set) var activeCount: Int = 0

    /// Number of simultaneous downloads (1–5), driven by Settings when available.
    var maxConcurrent: Int {
        get { min(max(settings?.maxConcurrentDownloads ?? _maxConcurrent, 1), 5) }
        set { _maxConcurrent = min(max(newValue, 1), 5) }
    }
    @ObservationIgnored private var _maxConcurrent: Int = 3

    let ytdlpService: YTDLPService
    @ObservationIgnored var settings: SettingsStore?
    /// Receives every yt-dlp log line (hook up to `LogStore`).
    @ObservationIgnored var onLog: ((LogEntry) -> Void)?

    @ObservationIgnored var onCompleted: ((DownloadItem) -> Void)?
    @ObservationIgnored var onFailed: ((DownloadItem) -> Void)?
    @ObservationIgnored weak var browserEngine: BrowserDownloadEngine?
    /// Downloads WebKit started on its own (a link or "Download Video"), stopped through these.
    @ObservationIgnored private var externalCancels: [UUID: () -> Void] = [:]

    private let store: QueueStore
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var handles: [UUID: DownloadHandle] = [:]

    init(ytdlpService: YTDLPService = YTDLPService(), settings: SettingsStore? = nil, store: QueueStore = QueueStore()) {
        self.ytdlpService = ytdlpService
        self.settings = settings
        self.store = store
        items = store.load().map { r in
            let item = DownloadItem(id: r.id, url: r.url, options: r.options, outputDir: r.outputDir,
                                    status: r.status, progress: r.progress, error: r.error,
                                    outputPath: r.outputPath, createdAt: r.createdAt, completedAt: r.completedAt)
            item.title = r.title
            item.optionId = r.optionId
            item.qualityLabel = r.qualityLabel
            item.engine = r.engine ?? .ytdlp
            item.pageURL = r.pageURL
            item.isHLS = r.isHLS ?? false
            item.browserFallback = r.browserFallback ?? false
            item.realExtension = r.realExtension
            // A download interrupted by quitting is restored as paused; resume continues the partial file.
            if [.queued, .analyzing, .downloading, .postProcessing].contains(item.status) { item.status = .paused }
            return item
        }
    }

    private func save() {
        store.save(items.map { i in
            QueueStore.Record(id: i.id, url: i.url, title: i.title, options: i.options, outputDir: i.outputDir,
                              status: i.status, progress: i.progress, error: i.error, outputPath: i.outputPath,
                              createdAt: i.createdAt, completedAt: i.completedAt,
                              optionId: i.optionId, qualityLabel: i.qualityLabel,
                              engine: i.engine, pageURL: i.pageURL, isHLS: i.isHLS, browserFallback: i.browserFallback,
                              realExtension: i.realExtension)
        })
    }

    // MARK: - Public API

    /// Add item to queue
    func enqueue(url: String, options: DownloadOptions, outputDir: String, videoInfo: VideoInfo? = nil, title: String? = nil,
                 optionId: String? = nil, qualityLabel: String? = nil, cookiesFile: URL? = nil, referer: String? = nil) {
        // DownloadOptions is a reference type: copy it so later edits don't change queued items.
        let snapshot = Self.copy(options)
        if let referer, !referer.isEmpty { snapshot.referer = referer }
        if snapshot.ffmpegLocation == nil, let path = settings?.ffmpegPath, !path.isEmpty {
            snapshot.ffmpegLocation = path
        }

        // Ensure unique, descriptive output filename template
        let rawTitle = videoInfo?.title ?? title ?? ""
        let cleanTitle = Self.sanitizeFilename(rawTitle)
        let genericTitles = ["master", "index", "playlist", "video", "manifest", "vid_480p", "vid_720p", "vid_1080p", "vid_360p", "vid_240p"]
        let isGeneric = cleanTitle.isEmpty || genericTitles.contains(cleanTitle.lowercased())

        let baseName: String
        if isGeneric {
            let ts = Int(Date().timeIntervalSince1970)
            baseName = cleanTitle.isEmpty ? "video_\(ts)" : "\(cleanTitle)_\(ts)"
        } else {
            baseName = cleanTitle
        }

        var uniqueName = baseName
        var counter = 1
        while FileManager.default.fileExists(atPath: "\(outputDir)/\(uniqueName).mp4")
           || FileManager.default.fileExists(atPath: "\(outputDir)/\(uniqueName).mkv")
           || FileManager.default.fileExists(atPath: "\(outputDir)/\(uniqueName).webm") {
            uniqueName = "\(baseName) (\(counter))"
            counter += 1
        }

        snapshot.outputTemplate = "\(uniqueName).%(ext)s"

        let item = DownloadItem(url: url, videoInfo: videoInfo, options: snapshot, outputDir: outputDir)
        item.optionId = optionId
        item.qualityLabel = qualityLabel
        item.title = isGeneric ? uniqueName : rawTitle
        item.cookiesFile = cookiesFile.flatMap(Self.privateCopy)
        items.append(item)
        save()
        processNext()
    }

    /// A stream found in the browser: tried with yt-dlp at the best quality, then through the browser if refused
    /// (or straight through the browser when `viaBrowser`). Runs in the background like any other download.
    func enqueueStream(url: String, title: String, pageURL: String?, isHLS: Bool, outputDir: String,
                       frame: AnyObject?, cookiesFile: URL?, viaBrowser: Bool, maxHeight: Int? = nil) {
        let options = DownloadOptions()
        if let h = maxHeight { options.format = "bv*[height<=\(h)]+ba/b[height<=\(h)]/bv*+ba/b" }
        if !viaBrowser {
            enqueue(url: url, options: options, outputDir: outputDir, title: title, cookiesFile: cookiesFile, referer: pageURL)
        } else {
            let item = DownloadItem(url: url, options: options, outputDir: outputDir)
            item.title = Self.sanitizeFilename(title).isEmpty ? "video" : Self.sanitizeFilename(title)
            items.append(item)
            item.engine = .browser
        }
        guard let item = items.last else { return }
        item.pageURL = pageURL
        item.isHLS = isHLS
        item.hlsHeight = maxHeight
        item.browserFallback = !viaBrowser
        item.browserFrame = frame
        save()
        processNext()
    }

    /// A download WebKit already started (it can't be queued); listed here so every download is in one place.
    func addExternal(_ item: DownloadItem, cancel: @escaping () -> Void) {
        item.engine = .browser
        item.status = .downloading
        externalCancels[item.id] = cancel
        items.append(item)
        save()
    }

    /// End of a download added with `addExternal`.
    func finishExternal(_ id: UUID, path: String?, error: String?) {
        externalCancels.removeValue(forKey: id)
        guard let item = items.first(where: { $0.id == id }), item.status == .downloading else { return }
        if let path {
            item.status = .completed
            item.progress = 100
            item.outputPath = finalPath(path, for: item)
            item.completedAt = Date()
            onCompleted?(item)
        } else {
            item.status = .failed
            item.error = error
            onFailed?(item)
        }
        save()
    }

    /// Each item gets its own cookies file: the service deletes it when that download ends,
    /// and the same browser export may be queued more than once.
    private static func privateCopy(of file: URL) -> URL? {
        let copy = file.deletingLastPathComponent().appendingPathComponent("adv_cookies_\(UUID().uuidString).txt")
        return (try? FileManager.default.copyItem(at: file, to: copy)) != nil ? copy : nil
    }

    static func sanitizeFilename(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
            .union(.newlines)
            .union(.illegalCharacters)
            .union(.controlCharacters)
        var clean = name.components(separatedBy: invalidCharacters).joined(separator: " ")
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.contains("  ") {
            clean = clean.replacingOccurrences(of: "  ", with: " ")
        }
        return clean
    }

    /// Start processing the queue
    func startQueue() {
        processNext()
    }

    /// Pause a specific download
    func pause(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .paused
        cancelTask(for: id)
        save()
    }

    /// Resume a paused download
    func resume(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .queued
        save()
        processNext()
    }

    /// Cancel and remove from queue
    func cancel(_ id: UUID) {
        cancelTask(for: id)
        items.removeAll(where: { $0.id == id })
        save()
        processNext()
    }

    /// Downloads using the network or ffmpeg right now.
    var runningCount: Int {
        items.filter { [.analyzing, .downloading, .postProcessing].contains($0.status) }.count
    }

    /// Pause everything that is downloading or waiting. Files being merged are left to finish.
    func pauseAll() {
        for item in items where [.queued, .analyzing, .downloading].contains(item.status) {
            item.status = .paused
            cancelTask(for: item.id)
        }
        save()
    }

    func resumeAll() {
        for item in items where item.status == .paused { item.status = .queued }
        save()
        processNext()
    }

    /// Cancel and remove every unfinished download, except files being merged.
    func cancelAll() {
        let ids = items.filter { [.queued, .analyzing, .downloading, .paused].contains($0.status) }.map(\.id)
        ids.forEach(cancelTask(for:))
        items.removeAll { ids.contains($0.id) }
        save()
    }

    /// Retry a failed download
    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .queued
        items[index].progress = 0
        items[index].error = nil
        save()
        processNext()
    }

    /// Remove completed/failed items
    func clearCompleted() {
        items.removeAll { $0.status == .completed || $0.status == .failed }
        save()
    }

    /// Reorder items
    func move(from offsets: IndexSet, to offset: Int) {
        items.move(fromOffsets: offsets, toOffset: offset)
        save()
    }

    // MARK: - Private

    private static func copy(_ options: DownloadOptions) -> DownloadOptions {
        guard let data = try? JSONEncoder().encode(options),
              let copy = try? JSONDecoder().decode(DownloadOptions.self, from: data) else { return options }
        return copy
    }

    private func processNext() {
        // An item paused and resumed quickly may still have its old task winding down: start it again only
        // once that task has finished (it calls processNext), so two runs never share one item's handle.
        while activeCount < maxConcurrent,
              let nextIndex = items.firstIndex(where: { $0.status == .queued && runningTasks[$0.id] == nil }) {
            items[nextIndex].status = .downloading
            let item = items[nextIndex]
            activeCount += 1

            let task = Task { [weak self] in
                guard let self else { return }
                await self.processItem(item)
                self.activeCount -= 1
                self.runningTasks.removeValue(forKey: item.id)
                self.handles.removeValue(forKey: item.id)
                self.processNext()
            }

            runningTasks[item.id] = task
        }
    }

    private func processItem(_ item: DownloadItem) async {
        if item.engine == .browser {
            await processInBrowser(item)
            return
        }
        let (handle, stream) = await ytdlpService.download(
            url: item.url,
            options: item.options,
            outputDir: item.outputDir,
            cookiesFile: item.cookiesFile
        )
        handles[item.id] = handle
        // The user may have cancelled/paused while the process was starting.
        if Task.isCancelled || item.status != .downloading { handle.cancel() }

        defer { save() }
        // `item` is a reference, so updates go straight to it (no index lookup per progress line).
        // After a pause/cancel the process may still print a few lines: drain them without touching the
        // item, or a paused download would flip back to "downloading" with nothing running it.
        for await event in stream {
            guard !handle.isCancelled else { continue }
            switch event {
            case .progress(let update):
                item.status = .downloading
                item.progress = update.percent
                item.speed = update.speed
                item.eta = update.eta
                item.downloadedSize = update.downloadedBytes
                item.totalSize = update.totalBytes
            case .log(let entry):
                onLog?(entry)
            case .postProcessing:
                item.status = .postProcessing
                item.progress = 100
                item.speed = nil
                item.eta = nil
            case .completed(let path):
                item.status = .completed
                item.progress = 100
                item.outputPath = finalPath(path, for: item)
                item.completedAt = Date()
                save()
                onCompleted?(item)
            case .error(let msg) where item.browserFallback && browserEngine != nil:
                // Refused by yt-dlp (token bound to the page, 403…): fetch it the way the site's player does.
                onLog?(LogEntry(timestamp: Date(), level: .warning, message: "yt-dlp failed (\(msg)); trying through the browser"))
                item.engine = .browser
                item.browserFallback = false
                item.status = .queued
                item.progress = 0
                item.speed = nil
                item.eta = nil
            case .error(let msg):
                item.status = .failed
                item.error = msg
                save()
                onFailed?(item)
            }
        }
    }

    private func processInBrowser(_ item: DownloadItem) async {
        defer { save() }
        guard let engine = browserEngine else {
            item.status = .failed
            item.error = "The browser is not available."
            return
        }
        do {
            let path = try await engine.download(item)
            guard item.status == .downloading || item.status == .postProcessing else { return }
            item.status = .completed
            item.progress = 100
            item.outputPath = finalPath(path, for: item)
            item.completedAt = Date()
            item.speed = nil
            item.eta = nil
            onCompleted?(item)
        } catch is CancellationError {
            // Paused or cancelled: the status was already set by pause()/cancel().
        } catch {
            guard item.status == .downloading || item.status == .postProcessing else { return }
            item.status = .failed
            item.error = error.localizedDescription
            onFailed?(item)
        }
    }

    /// Apply the file-naming settings (short name, disguised extension) to a finished file.
    private func finalPath(_ path: String?, for item: DownloadItem) -> String? {
        guard let path, let settings else { return path }
        let title = item.videoInfo?.title ?? item.title
        let result = FileNamer.apply(to: path, title: title, naming: settings.fileNaming,
                                     disguise: settings.disguiseExtension,
                                     extensions: FileNamer.parseExtensions(settings.disguiseExtensions))
        if let real = result.realExtension { item.realExtension = real }
        return result.path
    }

    private func cancelTask(for id: UUID) {
        externalCancels.removeValue(forKey: id)?()
        handles[id]?.cancel()
        handles.removeValue(forKey: id)
        runningTasks[id]?.cancel()
    }
}
