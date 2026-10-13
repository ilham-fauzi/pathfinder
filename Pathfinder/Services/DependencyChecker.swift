import Foundation

struct DependencyStatus {
    var ytdlpPath: URL?
    var ytdlpVersion: String?
    var ffmpegPath: URL?
    var ffmpegVersion: String?
    var aria2cPath: URL?
    var isReady: Bool { ytdlpPath != nil && ffmpegPath != nil }
}

enum DependencyChecker {
    static func check() async -> DependencyStatus {
        var status = DependencyStatus()
        
        status.ytdlpPath = await findExecutable(named: "yt-dlp")
        if let path = status.ytdlpPath {
            let res = try? await ProcessRunner.run(executable: path, arguments: ["--version"])
            status.ytdlpVersion = res?.stdoutString?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        status.ffmpegPath = await findExecutable(named: "ffmpeg")
        if let path = status.ffmpegPath {
            let res = try? await ProcessRunner.run(executable: path, arguments: ["-version"])
            status.ffmpegVersion = res?.stdoutString?.components(separatedBy: "\n").first
        }

        status.aria2cPath = await findExecutable(named: "aria2c")

        return status
    }

    static func findExecutable(named: String) async -> URL? {
        let paths = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Pathfinder/bin/\(named)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(named)"),
            URL(fileURLWithPath: "/usr/local/bin/\(named)"),
            URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/\(named)")
        ]
        
        for url in paths {
            if let p = url, FileManager.default.isExecutableFile(atPath: p.path) {
                return p
            }
        }
        
        // Fallback to which
        if let res = try? await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/which"), arguments: [named]), res.isSuccess {
            let path = res.stdoutString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        
        return nil
    }
}
