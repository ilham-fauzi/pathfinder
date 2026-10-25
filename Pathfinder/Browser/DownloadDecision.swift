import Foundation

/// What one press of the browser's Download button does.
enum DownloadDecision {
    /// Send the page address to yt-dlp (known video sites, or "Use page link").
    case pageLink
    /// Queue this stream: the main video.
    case stream(BrowserModel.MainStreamChoice)
    /// Only something shorter than a video was found, most likely an ad: refuse it and explain.
    case shortClip(BrowserModel.MainStreamChoice)
    /// Nothing playable was found on the page yet.
    case noStreamYet

    /// From the main-stream check on a page that is not a known video site.
    @MainActor
    init(_ choice: BrowserModel.MainStreamChoice?) {
        guard let choice else { self = .noStreamYet; return }
        if let d = choice.duration, d < BrowserModel.minimumMainLength { self = .shortClip(choice) } else { self = .stream(choice) }
    }

    var logName: String {
        switch self {
        case .pageLink: return "page link"
        case .stream: return "stream"
        case .shortClip: return "short clip only"
        case .noStreamYet: return "no stream yet"
        }
    }

    static let noStreamMessage = "No video stream found yet. Let the video play, then press Download again. "
        + "(Right-click Download and choose Use page link to try the page address.)"
}
