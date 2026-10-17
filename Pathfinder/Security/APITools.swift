import Foundation
import WebKit
import Observation

/// Tells advertising and tracking calls from the site's own backend.
enum TrafficFilter {
    private static let trackerHosts = [
        "google-analytics.com", "googletagmanager.com", "analytics.google.com", "stats.g.doubleclick.net", "segment.io", "segment.com",
        "amplitude.com", "mixpanel.com", "hotjar.com", "hotjar.io", "clarity.ms", "fullstory.com", "logrocket.com", "logrocket.io",
        "sentry.io", "datadoghq.com", "newrelic.com", "nr-data.net", "bugsnag.com", "heapanalytics.com", "branch.io", "adjust.com",
        "appsflyer.com", "braze.com", "onesignal.com", "facebook.net", "connect.facebook.net", "bat.bing.com", "px.ads.linkedin.com",
        "analytics.tiktok.com", "ads.twitter.com", "t.co", "snapchat.com", "pinterest.com", "optimizely.com", "crazyegg.com",
        "mouseflow.com", "quantcast.com", "scorecardresearch.com", "omtrdc.net", "demdex.net", "everesttech.net", "bluekai.com",
    ]
    private static let pathMarkers = [
        "/pagead/", "/ads/", "/adserver", "/adview", "/api/stats/ads", "/ptracking", "/log_event", "/gen_204", "/generate_204",
        "/collect", "/analytics", "/telemetry", "/pixel", "/track", "/beacon", "/impression", "/tr?id=", "/__utm", "/rum", "/csp-report",
    ]

    /// An address that serves ads, or only reports what the visitor does.
    static func isAdOrTracker(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        func matches(_ list: [String]) -> Bool { list.contains { host == $0 || host.hasSuffix("." + $0) } }
        if matches(AdBlocker.blockedHosts) || matches(trackerHosts) { return true }
        let path = url.path.lowercased()
        if pathMarkers.contains(where: { path.contains($0) || (url.query?.lowercased().contains($0) ?? false) }) { return true }
        return DetectedStream.looksLikeAd(url.absoluteString)
    }
}

/// Turns a captured call into a command that can be pasted in a terminal.
enum CurlBuilder {
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func command(for e: APIEndpoint, userAgent: String?, cookie: String?) -> String {
        switch e.kind {
        case .websocket: return "websocat \(quote(e.fullURL))   # WebSocket: cURL cannot open it"
        case .sse, .fetch, .xhr, .beacon: break
        }
        var parts = ["curl \(quote(e.fullURL))"]
        if e.kind == .sse { parts.append("-N") }
        if e.method != "GET" { parts.append("-X \(e.method)") }
        var names = Set<String>()
        for h in e.sample.requestHeaders {
            let lower = h.name.lowercased()
            // Cookies come from the browser's jar (when asked for), not from what the page script could see.
            if lower == "cookie" || lower == "content-length" || lower == "host" { continue }
            names.insert(lower)
            parts.append("-H \(quote("\(h.name): \(h.value)"))")
        }
        if !names.contains("user-agent"), let userAgent { parts.append("-H \(quote("User-Agent: \(userAgent)"))") }
        if !names.contains("referer"), let page = e.sample.pageURL { parts.append("-H \(quote("Referer: \(page)"))") }
        if !names.contains("origin"), e.method != "GET", let page = e.sample.pageURL, let u = URL(string: page),
           let scheme = u.scheme, let host = u.host {
            parts.append("-H \(quote("Origin: \(scheme)://\(host)\(u.port.map { ":\($0)" } ?? "")"))")
        }
        if let cookie, !cookie.isEmpty { parts.append("-b \(quote(cookie))") }
        var note = ""
        if let body = e.sample.requestBody, !body.isEmpty {
            if body.hasPrefix("[") && (body.hasPrefix("[binary") || body.hasPrefix("[multipart]") || body == "[body]") {
                note = "\n# The request body was \(body.hasPrefix("[binary") ? "binary" : "a form upload") and is not included."
            } else {
                parts.append("--data-raw \(quote(body))")
            }
        }
        parts.append("--compressed")
        return parts.joined(separator: " \\\n  ") + note
    }

    @MainActor
    static func cookie(forURL raw: String, store: WKHTTPCookieStore) async -> String? {
        guard let url = URL(string: raw) else { return nil }
        return await cookieHeader(for: url, store: store)
    }

    /// The Cookie header the browser would send to `url`.
    @MainActor
    static func cookieHeader(for url: URL, store: WKHTTPCookieStore) async -> String? {
        let all: [HTTPCookie] = await withCheckedContinuation { c in store.getAllCookies { c.resume(returning: $0) } }
        guard let host = url.host?.lowercased() else { return nil }
        let https = url.scheme == "https"
        let path = url.path.isEmpty ? "/" : url.path
        let matching = all.filter { cookie in
            let d = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return (host == d || host.hasSuffix("." + d)) && path.hasPrefix(cookie.path) && (https || !cookie.isSecure)
                && (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
        return matching.isEmpty ? nil : matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

/// One backend endpoint seen on a site, kept between launches. Only host and path are stored: the query string,
/// headers and bodies can hold tokens, so they exist in memory for the current visit only.
struct RegisteredEndpoint: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var kind: String
    var method: String
    var host: String
    var path: String
    var count: Int
    var firstSeen: Date
    var lastSeen: Date
    var lastStatus: Int?
    var type: String?
    var thirdParty: Bool

    var url: String { "https://\(host)\(path)" }
}

/// The backend APIs of every site visited.
@Observable
@MainActor
final class APIRegistry {
    private(set) var sites: [String: [RegisteredEndpoint]] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pathfinder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("api-registry.json")
    }

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.storeURL), let saved = try? decoder.decode([String: [RegisteredEndpoint]].self, from: data) {
            sites = saved
        }
    }

    var sortedSites: [(site: String, endpoints: [RegisteredEndpoint])] {
        sites.map { ($0.key, $0.value.sorted { $0.lastSeen > $1.lastSeen }) }
            .sorted { ($0.endpoints.first?.lastSeen ?? .distantPast) > ($1.endpoints.first?.lastSeen ?? .distantPast) }
    }

    func note(_ e: APIEndpoint, site: String) {
        var list = sites[site] ?? []
        if let i = list.firstIndex(where: { $0.id == e.id }) {
            list[i].count = max(list[i].count, e.count)
            list[i].lastSeen = e.lastSeen
            if let s = e.lastStatus { list[i].lastStatus = s }
            if let t = e.lastType { list[i].type = t }
        } else {
            guard list.count < 400, sites.count < 300 || sites[site] != nil else { return }
            list.append(RegisteredEndpoint(id: e.id, kind: e.kind.rawValue, method: e.method, host: e.host, path: e.path, count: e.count,
                                           firstSeen: e.firstSeen, lastSeen: e.lastSeen, lastStatus: e.lastStatus, type: e.lastType,
                                           thirdParty: e.isThirdParty))
        }
        sites[site] = list
        scheduleSave()
    }

    func remove(site: String) { sites[site] = nil; scheduleSave() }
    func clear() { sites = [:]; scheduleSave() }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(self.sites) { try? data.write(to: Self.storeURL, options: .atomic) }
        }
    }
}
