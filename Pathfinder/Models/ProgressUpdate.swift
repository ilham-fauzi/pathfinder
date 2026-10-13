import Foundation

struct ProgressUpdate {
    let percent: Double
    let speed: String
    let eta: String
    let downloadedBytes: String?
    let totalBytes: String?

    /// Prefix that identifies our progress lines in yt-dlp output.
    static let marker = "YDLP|||"

    /// Value for `--progress-template`. Fields are separated by `|||`.
    static let template = "download:\(marker)%(progress._percent_str)s|||%(progress._speed_str)s|||%(progress._eta_str)s|||%(progress.downloaded_bytes)s|||%(progress.total_bytes)s"

    static func parse(_ line: String) -> ProgressUpdate? {
        guard let range = line.range(of: marker) else { return nil }
        let components = line[range.upperBound...]
            .components(separatedBy: "|||")
            .map { Self.clean($0) }
        guard components.count >= 3,
              let percent = Double(components[0].replacingOccurrences(of: "%", with: "")) else {
            return nil
        }

        return ProgressUpdate(
            percent: percent,
            speed: Self.display(components[1]) ?? "",
            eta: Self.display(components[2]) ?? "",
            downloadedBytes: components.count > 3 ? Self.bytes(components[3]) : nil,
            totalBytes: components.count > 4 ? Self.bytes(components[4]) : nil
        )
    }

    /// Strip ANSI colour codes and whitespace.
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func display(_ s: String) -> String? {
        (s.isEmpty || s == "NA" || s.hasPrefix("Unknown")) ? nil : s
    }

    private static func bytes(_ s: String) -> String? {
        guard let n = Int64(s) else { return nil }
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
