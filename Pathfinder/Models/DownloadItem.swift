import Foundation

// MARK: - Download Status

enum DownloadStatus: String, Codable {
    case queued
    case analyzing
    case downloading
    case postProcessing
    case completed
    case paused
    case failed
}

/// What fetches the file: yt-dlp, or the in-app browser (requests made by the page itself, with its
/// cookies, Referer and connection, for streams that refuse yt-dlp).
enum DownloadEngine: String, Codable {
    case ytdlp, browser
}

// MARK: - Download Item

@Observable
final class DownloadItem: Identifiable {
    let id: UUID
    var url: String
    var videoInfo: VideoInfo?
    var options: DownloadOptions
    var outputDir: String
    var status: DownloadStatus
    var progress: Double
    var speed: String?
    /// Progress (0-100) of each part of the file when it is fetched over several connections; empty otherwise.
    var lanes: [Double] = []
    var eta: String?
    var downloadedSize: String?
    var totalSize: String?
    var error: String?
    var outputPath: String?
    var createdAt: Date
    var completedAt: Date?
    /// Which quality row created this item (used to disable that row's button while busy).
    var title: String?
    var optionId: String?
    var qualityLabel: String?
    /// Temporary Netscape cookies file exported from WKWebView for cookie-protected streams.
    /// Deleted after download completes (managed by YTDLPService).
    var cookiesFile: URL?
    var engine: DownloadEngine = .ytdlp
    /// Page the stream was found on (Referer, and where the browser engine fetches it from).
    var pageURL: String?
    /// An HLS playlist: the browser engine joins its pieces instead of saving the file as is.
    var isHLS = false
    /// Quality picked in the browser (picture height); nil takes the best.
    @ObservationIgnored var hlsHeight: Int?
    /// When yt-dlp is refused, switch this item to the browser engine instead of failing.
    var browserFallback = false
    /// The file's real extension when it was saved under a disguised one (".jpg" for an mp4).
    var realExtension: String?
    /// The page frame that played the stream (a WKFrameInfo), only while the app runs.
    @ObservationIgnored var browserFrame: AnyObject?

    init(
        id: UUID = UUID(),
        url: String,
        videoInfo: VideoInfo? = nil,
        options: DownloadOptions = DownloadOptions(),
        outputDir: String = NSHomeDirectory() + "/Downloads/Pathfinder",
        status: DownloadStatus = .queued,
        progress: Double = 0.0,
        speed: String? = nil,
        eta: String? = nil,
        downloadedSize: String? = nil,
        totalSize: String? = nil,
        error: String? = nil,
        outputPath: String? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.videoInfo = videoInfo
        self.options = options
        self.outputDir = outputDir
        self.status = status
        self.progress = progress
        self.speed = speed
        self.eta = eta
        self.downloadedSize = downloadedSize
        self.totalSize = totalSize
        self.error = error
        self.outputPath = outputPath
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

// MARK: - Display title

extension DownloadItem {
    /// The real title (also the saved file's name).
    var realTitle: String { videoInfo?.title ?? title ?? url }

    /// A neutral name that never reveals the title or site, stable for this item: "Video #3F9A".
    var maskedTitle: String {
        "\(options.extractAudio ? "Audio" : "Video") #\(id.uuidString.prefix(4))"
    }

    /// What the app shows: the real or masked title, with the chosen quality.
    func displayTitle(masked: Bool) -> String {
        let base = masked ? maskedTitle : realTitle
        return qualityLabel.map { "\(base) (\($0))" } ?? base
    }

    /// The saved file's name for display; masked keeps only the extension ("Video #3F9A.mp4").
    func displayFileName(masked: Bool) -> String {
        guard let path = outputPath else { return displayTitle(masked: masked) }
        let name = (path as NSString).lastPathComponent
        guard masked else { return name }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? maskedTitle : "\(maskedTitle).\(ext)"
    }
}
