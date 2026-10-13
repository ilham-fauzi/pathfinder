import Foundation

/// Turns raw yt-dlp output into plain-language messages for the UI.
enum ErrorMapper {
    static func message(for raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("unsupported url") || s.contains("is not a valid url") {
            return "This link doesn’t lead to a video. Open the video itself, copy its link and paste it here."
        }
        if s.contains("not a bot") {
            return "This site is asking to confirm you’re not a bot. Try again later, or try a different link."
        }
        if s.contains("only works when logged-in") || s.contains("--cookies") {
            return "This video needs you to be signed in, which this app can’t do yet."
        }
        if s.contains("private video") || s.contains("sign in") || s.contains("login required") {
            return "This video is private or needs a login."
        }
        if s.contains("not available in your country") || s.contains("geo") && s.contains("restrict") {
            return "This video isn’t available in your region."
        }
        if s.contains("ffmpeg") && (s.contains("not found") || s.contains("not installed")) {
            return "A required tool (ffmpeg) is missing. Install it from the setup assistant."
        }
        if s.contains("socks") || s.contains("proxy") {
            return "The SSH tunnel isn’t working. Turn it off and on again, or check the SSH tunnel settings."
        }
        if s.contains("blob url") || s.contains("[blob]") {
            return "Blob URLs exist only in browser memory and cannot be downloaded directly. Open the webpage in the built-in Browser tab to detect the stream."
        }
        if s.contains("403: forbidden") || s.contains("http error 403") {
            return "Access denied (HTTP 403 Forbidden). The website may block automated downloads or require browser cookies."
        }
        if s.contains("404: not found") || s.contains("http error 404") {
            return "Video not found (HTTP 404). Check if the link has expired or changed."
        }
        if s.contains("429: too many requests") || s.contains("http error 429") {
            return "Rate limited (HTTP 429). The website is temporarily blocking requests. Please wait a moment."
        }
        if s.contains("cloudflare") || s.contains("just a moment") || s.contains("ddos-guard") {
            return "This site is protected by Cloudflare/anti-bot. Try using the in-app browser to detect the video stream."
        }
        if s.contains("http error") || s.contains("unable to download") || s.contains("timed out")
            || s.contains("connection") || s.contains("network is unreachable") || s.contains("name or service not known") {
            return "Connection lost. Check your internet, then try again."
        }
        if s.contains("no space left") {
            return "Not enough disk space to save this file."
        }
        if s.contains("video unavailable") || s.contains("has been removed") {
            return "This video is no longer available."
        }
        let trimmed = raw.replacingOccurrences(of: "ERROR:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Something went wrong. Please try again." : trimmed
    }

    /// Basic client-side check so obviously invalid input never reaches yt-dlp.
    enum URLCheck { case empty, blob, invalid, ok }

    static func check(_ input: String) -> URLCheck {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.lowercased().hasPrefix("blob:") { return .blob }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), let host = url.host, host.contains("."),
              url.scheme == "http" || url.scheme == "https" else { return .invalid }
        return .ok
    }
}
