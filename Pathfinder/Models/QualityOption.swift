import Foundation

/// A simplified, human-friendly download choice shown in the Results list.
struct QualityOption: Identifiable, Hashable {
    enum Kind: String { case video, audio }

    let id: String
    let kind: Kind
    let quality: String        // "1080p" / "320 kbps"
    let label: String          // "Full HD"
    let container: String      // "MP4" / "MP3" / "M4A"
    let estimatedBytes: Int64?
    let isRecommended: Bool
    fileprivate let height: Int?
    fileprivate let audioKbps: Int?

    var sizeText: String {
        guard let b = estimatedBytes, b > 0 else { return "—" }
        return "~" + ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    var accessibilityLabel: String { "Download \(label), \(quality), \(container)" }

    /// A copy of `base` configured to download this option.
    func options(basedOn base: DownloadOptions) -> DownloadOptions {
        let o: DownloadOptions = {
            guard let data = try? JSONEncoder().encode(base),
                  let copy = try? JSONDecoder().decode(DownloadOptions.self, from: data) else { return DownloadOptions() }
            return copy
        }()
        // Simple-flow rows must not fail after a successful download: thumbnail embedding is only
        // supported for some containers, and subtitles aren't requested here.
        o.embedSubs = false
        switch kind {
        case .video:
            o.embedThumbnail = false
            o.extractAudio = false
            o.audioFormat = nil
            o.audioBitrate = nil
            if let h = height {
                o.format = "bv*[height<=\(h)][ext=mp4]+ba[ext=m4a]/bv*[height<=\(h)]+ba/b[height<=\(h)]"
            } else {
                o.format = "bv*+ba/b"
            }
            o.mergeOutputFormat = .mp4
        case .audio:
            o.embedThumbnail = true     // supported for mp3 and m4a
            o.extractAudio = true
            o.format = "ba/b"
            o.audioFormat = container == "M4A" ? .m4a : .mp3
            o.audioBitrate = audioKbps.map { "\($0)K" }
        }
        return o
    }
}

enum QualityOptions {
    private static let names: [Int: String] = [
        2160: "4K Ultra HD", 1440: "2K Quad HD", 1080: "Full HD", 720: "HD", 480: "Standard", 360: "Data saver"
    ]

    static func video(from info: VideoInfo) -> [QualityOption] {
        let formats = info.formats ?? []
        let bestAudio = formats.filter { $0.hasAudio && !$0.hasVideo }.compactMap(size).max() ?? 0

        var heights = Set(formats.filter { $0.hasVideo }.compactMap { $0.height })
        let usable = heights.filter { $0 >= 360 }
        if !usable.isEmpty { heights = usable }
        let top = Array(heights.sorted(by: >).prefix(6))

        guard !top.isEmpty else {
            return [QualityOption(id: "video-best", kind: .video, quality: "Best", label: "Best available",
                                  container: "MP4", estimatedBytes: nil, isRecommended: true, height: nil, audioKbps: nil)]
        }

        let recommendedHeight = top.first(where: { $0 <= 1080 }) ?? top.last!
        return top.map { h in
            let atHeight = formats.filter { $0.hasVideo && $0.height == h }
            let bytes = atHeight.map { f in (size(f) ?? 0) + (f.hasAudio ? 0 : bestAudio) }.max()
            return QualityOption(
                id: "video-\(h)", kind: .video, quality: "\(h)p", label: names[h] ?? "\(h)p",
                container: "MP4", estimatedBytes: bytes, isRecommended: h == recommendedHeight,
                height: h, audioKbps: nil)
        }
    }

    static func audio(from info: VideoInfo) -> [QualityOption] {
        let presets: [(kbps: Int, label: String, container: String)] = [
            (320, "Best quality", "MP3"), (256, "High quality", "M4A"),
            (192, "Good quality", "MP3"), (128, "Smaller file", "MP3")
        ]
        return presets.map { p in
            let bytes = info.duration.map { Int64($0 * Double(p.kbps) * 1000 / 8) }
            return QualityOption(
                id: "audio-\(p.kbps)", kind: .audio, quality: "\(p.kbps) kbps", label: p.label,
                container: p.container, estimatedBytes: bytes, isRecommended: p.kbps == 320,
                height: nil, audioKbps: p.kbps)
        }
    }

    private static func size(_ f: FormatInfo) -> Int64? { f.filesize ?? f.filesizeApprox }
}

/// One-click choices offered by the menu bar panel, where there is no quality picker.
enum QuickPreset: String, CaseIterable, Identifiable {
    case video1080, video720, audioMP3

    var id: String { rawValue }
    var isAudio: Bool { self == .audioMP3 }

    var title: String {
        switch self {
        case .video1080: return "Video · 1080p"
        case .video720: return "Video · 720p"
        case .audioMP3: return "Audio · MP3"
        }
    }

    var option: QualityOption {
        switch self {
        case .video1080:
            return QualityOption(id: "video-1080", kind: .video, quality: "1080p", label: "Full HD", container: "MP4",
                                 estimatedBytes: nil, isRecommended: true, height: 1080, audioKbps: nil)
        case .video720:
            return QualityOption(id: "video-720", kind: .video, quality: "720p", label: "HD", container: "MP4",
                                 estimatedBytes: nil, isRecommended: false, height: 720, audioKbps: nil)
        case .audioMP3:
            return QualityOption(id: "audio-320", kind: .audio, quality: "320 kbps", label: "Best quality", container: "MP3",
                                 estimatedBytes: nil, isRecommended: false, height: nil, audioKbps: 320)
        }
    }
}
