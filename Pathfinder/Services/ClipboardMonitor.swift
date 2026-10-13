import Foundation
import AppKit
import SwiftUI

@Observable
@MainActor
class ClipboardMonitor {
    var detectedURL: String?
    var isMonitoring: Bool = false
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private let pasteboard = NSPasteboard.general

    func startMonitoring() {
        // Starting twice used to leave the first timer running forever.
        guard timer == nil else { return }
        isMonitoring = true
        lastChangeCount = pasteboard.changeCount

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkClipboard() }
        }
        // Polling the pasteboard needs no precision; let the system batch the wake-ups.
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopMonitoring() {
        isMonitoring = false
        timer?.invalidate()
        timer = nil
    }

    private func checkClipboard() {
        guard isMonitoring, pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        if let string = pasteboard.string(forType: .string), isVideoURL(string) {
            detectedURL = string
        }
    }
    
    private static let supportedHosts = [
        "youtube.com", "youtu.be",
        "vimeo.com",
        "tiktok.com",
        "twitter.com", "x.com",
        "instagram.com",
        "facebook.com",
        "twitch.tv"
    ]

    /// A link to a page on a well-known video site (not just its home page).
    /// Used to decide whether a copied link is worth a notification.
    static func isKnownVideoLink(_ string: String) -> Bool {
        guard let url = URL(string: string), let host = url.host?.lowercased(),
              url.path.count > 1 || url.query != nil else { return false }
        return supportedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
    }

    /// Check if string looks like a supported URL
    private func isVideoURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let host = url.host?.lowercased() else { return false }

        // Direct match or subdomain match
        if Self.supportedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            return true
        }

        // Generic fallback for any http/https URL that might be supported by yt-dlp
        return url.scheme == "http" || url.scheme == "https"
    }
}
