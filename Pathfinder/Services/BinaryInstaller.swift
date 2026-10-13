import Foundation

/// Downloads the official standalone yt-dlp build into Application Support.
enum BinaryInstaller {
    static let ytdlpURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    static var installDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pathfinder/bin")
    }

    static func installYTDLP() async throws -> URL {
        let (tmp, response) = try await URLSession.shared.download(from: ytdlpURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError.downloadError("Could not download yt-dlp. Check your internet connection.")
        }
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let dest = installDirectory.appendingPathComponent("yt-dlp")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        return dest
    }
}
