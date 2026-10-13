import Foundation

/// One video (or playlist) row in a channel / playlist / search result list.
struct ListingEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let url: String
    let duration: Double?
    let thumbnail: String?
    let channel: String?
    let viewCount: Int?
    let isLive: Bool
    /// A playlist inside a list (e.g. the Playlists tab of a channel): opens another list.
    let isPlaylist: Bool

    var durationText: String? {
        guard let duration, duration > 0 else { return isLive ? "LIVE" : nil }
        let s = Int(duration)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    var viewsText: String? {
        guard let v = viewCount else { return nil }
        let text: String
        switch v {
        case 1_000_000...: text = String(format: "%.1fM", Double(v) / 1_000_000)
        case 1_000...: text = String(format: "%.1fK", Double(v) / 1_000)
        default: text = "\(v)"
        }
        return text.replacingOccurrences(of: ".0", with: "") + " views"
    }
}

struct ListingPage {
    let title: String?
    let entries: [ListingEntry]
    /// Rows yt-dlp returned before filtering, used to decide whether more pages may exist.
    let rawCount: Int
}

/// What the user asked to browse: a channel/playlist link, or a search phrase.
enum ListingSource: Equatable {
    case url(String)
    case search(String)

    static let pageSize = 30
    static let maxItems = 120

    /// yt-dlp target for items `1...end`.
    func target(end: Int) -> String {
        switch self {
        case .url(let u): return u
        case .search(let q): return "ytsearch\(end):\(q)"
        }
    }

    /// Decide whether the typed/pasted text is something to browse. nil = a single video link or invalid input.
    static func detect(_ input: String) -> ListingSource? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }

        // Plain words (no scheme, spaces or no dot) are a search.
        if !text.contains("://"), text.contains(where: \.isWhitespace) || !text.contains(".") {
            return .search(text)
        }

        guard let comps = URLComponents(string: text.contains("://") ? text : "https://" + text),
              let host = comps.host?.lowercased(),
              host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }

        let segments = comps.path.split(separator: "/").map(String.init)
        let query = comps.queryItems ?? []

        if comps.path == "/results", let q = query.first(where: { $0.name == "search_query" })?.value, !q.isEmpty {
            return .search(q)
        }
        if comps.path == "/playlist", query.contains(where: { $0.name == "list" }) {
            return .url(comps.url?.absoluteString ?? text)
        }

        let tabs: Set<String> = ["videos", "shorts", "streams", "playlists", "live", "featured"]
        var channelSegments: Int?
        if let first = segments.first {
            if first.hasPrefix("@") { channelSegments = 1 }
            else if ["channel", "c", "user"].contains(first), segments.count >= 2 { channelSegments = 2 }
        }
        guard let base = channelSegments else { return nil }

        var path = comps.path
        // A bare channel link lists its tabs; go straight to the videos.
        if segments.count == base { path += "/videos" }
        else if segments.count > base, !tabs.contains(segments[base]) { return nil }

        var out = URLComponents()
        out.scheme = "https"
        out.host = "www.youtube.com"
        out.path = path
        return .url(out.url?.absoluteString ?? text)
    }
}

enum ListingParser {
    private struct Raw: Decodable {
        let id: String?
        let title: String?
        let url: String?
        let duration: Double?
        let channel: String?
        let uploader: String?
        let viewCount: Int?
        let liveStatus: String?
        let ieKey: String?
        let type: String?
        let thumbnail: String?
        let thumbnails: [Thumb]?
        let entries: [Raw]?

        struct Thumb: Decodable { let url: String?; let width: Int? }

        enum CodingKeys: String, CodingKey {
            case id, title, url, duration, channel, uploader, thumbnail, thumbnails, entries
            case viewCount = "view_count"
            case liveStatus = "live_status"
            case ieKey = "ie_key"
            case type = "_type"
        }
    }

    static func parse(_ data: Data) throws -> ListingPage {
        let root = try JSONDecoder().decode(Raw.self, from: data)
        var rows = root.entries ?? []
        // A channel root returns one playlist per tab; flatten.
        if !rows.isEmpty, rows.allSatisfy({ $0.entries != nil }) {
            rows = rows.flatMap { $0.entries ?? [] }
        }
        let entries = rows.compactMap(entry(from:))
        return ListingPage(title: root.title, entries: entries, rawCount: rows.count)
    }

    private static func entry(from r: Raw) -> ListingEntry? {
        guard let id = r.id, let title = r.title, !title.isEmpty,
              title != "[Private video]", title != "[Deleted video]" else { return nil }
        let isPlaylist = r.type == "playlist" || (r.url?.contains("/playlist?list=") ?? false)
        let isYouTube = (r.ieKey ?? "").lowercased().hasPrefix("youtube")
        guard let url = r.url ?? (isYouTube ? "https://www.youtube.com/watch?v=\(id)" : nil) else { return nil }
        var thumb = r.thumbnail ?? r.thumbnails?.compactMap { $0.url }.last
        if thumb == nil, isYouTube, !isPlaylist, id.count == 11 { thumb = "https://i.ytimg.com/vi/\(id)/mqdefault.jpg" }
        return ListingEntry(id: id, title: title, url: url, duration: r.duration, thumbnail: thumb,
                            channel: r.channel ?? r.uploader, viewCount: r.viewCount,
                            isLive: r.liveStatus == "is_live", isPlaylist: isPlaylist)
    }
}
