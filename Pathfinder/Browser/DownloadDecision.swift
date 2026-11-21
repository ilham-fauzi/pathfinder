import Foundation
import AVFoundation

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

/// Catches a saved file that is only a preview of the video the page was playing.
@MainActor
enum PreviewCheck {
    /// A file shorter than this share of the page's stated length is a preview.
    static let shortShare = 0.5

    /// The message for the Downloads list, or nil when the file is long enough (or a length is unknown).
    static func message(savedSeconds: Double?, expectedSeconds: Double?) -> String? {
        guard let saved = savedSeconds, let expected = expectedSeconds, expected > 0, saved < expected * shortShare else { return nil }
        return "The saved file looks like a preview: it is \(StreamCheckLog.clock(saved)) long, the page's video is "
            + "\(StreamCheckLog.clock(expected)). Try again."
    }

    /// Playing time of a saved media file; nil when it cannot be read.
    static func seconds(ofFileAt path: String) async -> Double? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let time = try? await asset.load(.duration), time.isNumeric, time.seconds > 0 else { return nil }
        return time.seconds
    }
}
