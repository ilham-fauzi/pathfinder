import Foundation
import WebKit
import Observation

/// What the security tools know about one tab's current page.
@Observable
@MainActor
final class TabSecurity {
    private(set) var findings: [SecurityFinding] = []
    private(set) var endpoints: [String: APIEndpoint] = [:]
    var protection: SiteProtection?
    private(set) var blockedCount = 0
    var lastGesture = Date.distantPast
    var redirectChain: [String] = []
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored var pageKey = ""

    var worst: Severity? { findings.map(\.severity).max() }

    var sortedEndpoints: [APIEndpoint] {
        endpoints.values.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.lastSeen > $1.lastSeen
        }
    }

    var activeCount: Int { endpoints.values.filter { $0.isActive && !$0.isAd }.count }
    var adCount: Int { endpoints.values.filter(\.isAd).count }

    func reset() {
        findings = []
        endpoints = [:]
        protection = nil
        blockedCount = 0
        redirectChain = []
        seen = []
    }

    func add(_ finding: SecurityFinding) {
        let key = "\(finding.kind.rawValue)|\(finding.title)|\(finding.detail.prefix(60))"
        guard findings.count < 120, seen.insert(key).inserted else {
            return
        }
        if finding.blocked { blockedCount += 1 }
        findings.insert(finding, at: 0)
    }

    func mutate(_ id: String, create: @autoclosure () -> APIEndpoint, _ change: (inout APIEndpoint) -> Void) {
        guard endpoints[id] != nil || endpoints.count < 300 else { return }
        var endpoint = endpoints[id] ?? create()
        change(&endpoint)
        endpoint.lastSeen = Date()
        endpoints[id] = endpoint
    }
}

/// Security settings and the decisions that need no page: the firewall mode, trusted sites, address checks.
@Observable
@MainActor
final class SecurityCenter {
    private static let modeKey = "browserWAFMode"
    private static let allowedKey = "browserWAFAllowed"

    var wafMode = WAFMode(rawValue: UserDefaults.standard.string(forKey: SecurityCenter.modeKey) ?? "") ?? .monitor {
        didSet {
            guard wafMode != oldValue else { return }
            UserDefaults.standard.set(wafMode.rawValue, forKey: Self.modeKey)
            onScriptsChanged?()
        }
    }
    private(set) var allowedHosts: [String] = UserDefaults.standard.stringArray(forKey: SecurityCenter.allowedKey) ?? []
    /// The address the user typed or picked themselves: it is never treated as an attack.
    @ObservationIgnored var typedURL: URL?
    /// Called when the page script has to be rebuilt (mode or trusted sites changed).
    @ObservationIgnored var onScriptsChanged: (() -> Void)?
    let integrity = FileIntegrityMonitor()
    /// Backend APIs of every site visited, kept between launches.
    let registry = APIRegistry()

    static func key(_ host: String?) -> String? {
        guard var h = host?.lowercased(), !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    func isAllowed(_ host: String?) -> Bool {
        guard let key = Self.key(host) else { return false }
        return allowedHosts.contains(key)
    }

    func setAllowed(_ allowed: Bool, host: String?) {
        guard let key = Self.key(host) else { return }
        allowedHosts.removeAll { $0 == key }
        if allowed { allowedHosts.append(key) }
        UserDefaults.standard.set(allowedHosts, forKey: Self.allowedKey)
        onScriptsChanged?()
    }

    var filtering: Bool { wafMode != .off }
    var blocking: Bool { wafMode == .block }

    // MARK: Messages from the page script

    func handle(_ body: [String: Any], in tab: TabSecurity, pageHost: String?) {
        switch body["t"] as? String {
        case "gesture":
            tab.lastGesture = Date()
        case "finding":
            let kind = ThreatKind(name: body["kind"] as? String ?? "")
            let finding = SecurityFinding(kind: kind, severity: Severity(name: body["sev"] as? String ?? ""),
                                          title: body["title"] as? String ?? "Finding",
                                          detail: body["detail"] as? String ?? "",
                                          blocked: body["blocked"] as? Bool ?? false)
            tab.add(finding)
        case "api":
            handleAPI(body, in: tab, pageHost: pageHost)
        default:
            break
        }
    }

    private func handleAPI(_ body: [String: Any], in tab: TabSecurity, pageHost: String?) {
        guard let raw = body["url"] as? String, let url = URL(string: raw),
              let kind = APIEndpoint.Kind(rawValue: (body["kind"] as? String) ?? "") else { return }
        let method = (body["method"] as? String) ?? "GET"
        let host = url.host ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let id = "\(kind.rawValue) \(method) \(host)\(path)"
        let thirdParty = Self.site(of: host) != Self.site(of: pageHost ?? "")
        let ad = TrafficFilter.isAdOrTracker(url)
        let phase = body["phase"] as? String
        func pairs(_ key: String) -> [HeaderPair] {
            (body[key] as? [[String]] ?? []).compactMap { $0.count == 2 ? HeaderPair(name: $0[0], value: $0[1]) : nil }
        }
        tab.mutate(id, create: APIEndpoint(kind: kind, method: method, host: host, path: path, fullURL: raw)) { e in
            e.isThirdParty = thirdParty
            e.isAd = ad
            switch phase {
            case "start":
                e.inFlight += 1
                e.count = max(e.count, body["n"] as? Int ?? e.count + 1)
                // The latest call is what a cURL copy should reproduce.
                e.sample = APISample(pageURL: body["page"] as? String, requestHeaders: pairs("headers"),
                                     requestBody: body["body"] as? String)
            case "body":
                if let text = body["body"] as? String { e.sample.requestBody = text }
            case "resp":
                e.sample.responseHeaders = pairs("rheaders")
                e.sample.responsePreview = body["preview"] as? String
            case "end":
                e.inFlight = max(0, e.inFlight - 1)
                if let status = body["status"] as? Int, status > 0 { e.lastStatus = status }
                if let ms = body["ms"] as? Int { e.lastMillis = ms }
                if let type = body["ctype"] as? String, !type.isEmpty { e.lastType = type }
                if body["failed"] as? Bool == true { e.failed += 1 }
                if body["blocked"] as? Bool == true { e.blocked = true }
            case "open":
                e.open = true
                e.count = max(e.count, 1)
            case "close":
                e.open = false
            default:
                break
            }
        }
        if !ad, phase != "resp", phase != "body", let endpoint = tab.endpoints[id], let site = Self.key(pageHost) {
            registry.note(endpoint, site: site)
        }
    }

    /// "api.example.co.uk" and "www.example.co.uk" are the same site; this is a close-enough guess without a public-suffix list.
    nonisolated static func site(of host: String) -> String {
        let parts = host.lowercased().split(separator: ".").map(String.init)
        guard parts.count > 2 else { return parts.joined(separator: ".") }
        let twoPartSuffixes: Set<String> = ["co", "com", "org", "net", "gov", "ac", "or", "go"]
        let n = (parts[parts.count - 2].count <= 3 && twoPartSuffixes.contains(parts[parts.count - 2]) && parts.last!.count == 2) ? 3 : 2
        return parts.suffix(n).joined(separator: ".")
    }

    // MARK: Navigation checks

    enum Verdict { case allow, block(String) }

    /// Checks a navigation before it starts: attack patterns in the address, miner hosts, script-made redirects and
    /// downloads nobody asked for. Findings are recorded on the tab; the verdict says whether to stop it.
    func review(_ action: WKNavigationAction, tab: TabSecurity, pageURL: URL?) -> Verdict {
        guard filtering, let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .allow }
        let isMain = action.targetFrame?.isMainFrame ?? true
        let topHost = isMain ? url.host : pageURL?.host
        if isAllowed(topHost) || isAllowed(url.host) { return .allow }

        var stop: String?
        let type = action.navigationType
        let userMade = type == .backForward || type == .reload || type == .formResubmitted || url == typedURL

        // 1. Attack patterns in the address.
        if !userMade {
            let hits = WAFRules.inspect(url)
            if let worst = hits.max(by: { $0.severity < $1.severity }) {
                let blockIt = blocking && worst.severity == .high
                tab.add(SecurityFinding(kind: .injection, severity: worst.severity,
                                        title: "\(worst.category): \(worst.name) in a link",
                                        detail: String(WAFRules.decode(url.absoluteString).prefix(160)), blocked: blockIt))
                if blockIt { stop = "\(worst.category) payload (\(worst.name))" }
            }
        }

        // 2. Miner / IP-grabber hosts reached by navigation (subresources are covered by the content rules).
        if let host = url.host, WAFRules.isMinerHost(host) {
            tab.add(SecurityFinding(kind: .cryptojacking, severity: .high, title: "Link to a known mining or tracking host",
                                    detail: host, blocked: blocking))
            if blocking { stop = "known mining or tracking host" }
        }

        // 3. A frame that takes over the whole tab without a click (typical of malicious ads).
        let idle = Date().timeIntervalSince(tab.lastGesture) > 1.5
        let source = action.sourceFrame
        if isMain, !source.isMainFrame, type == .other || type == .linkActivated, idle,
           let from = pageURL?.host, let to = url.host, Self.site(of: from) != Self.site(of: to) {
            tab.add(SecurityFinding(kind: .redirect, severity: .high, title: "A frame on the page redirected the whole tab",
                                    detail: "\(source.request.url?.host ?? "frame") → \(to)", blocked: blocking))
            if blocking { stop = "redirect started by an embedded frame" }
        }

        // 4. Downloads that start by themselves.
        let name = url.lastPathComponent
        if RiskyFile.isExecutable(name) && idle && type != .formSubmitted {
            tab.add(SecurityFinding(kind: .driveBy, severity: .high, title: "Program download started without a click",
                                    detail: name, blocked: blocking))
            if blocking { stop = "download started without a click" }
        }
        if let stop { return .block(stop) }
        return .allow
    }

    /// Download of a main-frame response (attachment or a type the view cannot show) before it is saved.
    func reviewResponse(_ response: URLResponse, tab: TabSecurity) -> Verdict {
        guard filtering, let url = response.url, !isAllowed(url.host) else { return .allow }
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let name = Self.fileName(fromDisposition: disposition) ?? response.suggestedFilename ?? url.lastPathComponent
        return reviewDownload(name: name, tab: tab)
    }

    func reviewDownload(name: String, tab: TabSecurity) -> Verdict {
        guard filtering else { return .allow }
        let idle = Date().timeIntervalSince(tab.lastGesture) > 1.5
        if RiskyFile.isDisguised(name) {
            tab.add(SecurityFinding(kind: .driveBy, severity: .high, title: "Program disguised as a document",
                                    detail: name, blocked: blocking))
            if blocking { return .block("program disguised as a document") }
        } else if RiskyFile.isExecutable(name) {
            if idle {
                tab.add(SecurityFinding(kind: .driveBy, severity: .high, title: "Program download started without a click",
                                        detail: name, blocked: blocking))
                if blocking { return .block("download started without a click") }
            } else {
                tab.add(SecurityFinding(kind: .driveBy, severity: .medium, title: "You are downloading a program",
                                        detail: "\(name) can run code when opened. Only keep it if you trust the site.", blocked: false))
            }
        } else if idle {
            tab.add(SecurityFinding(kind: .driveBy, severity: .low, title: "Download started without a click", detail: name))
        }
        return .allow
    }

    nonisolated static func fileName(fromDisposition header: String) -> String? {
        guard let range = header.range(of: "filename*=", options: .caseInsensitive) ?? header.range(of: "filename=", options: .caseInsensitive) else { return nil }
        var value = String(header[range.upperBound...]).components(separatedBy: ";")[0]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        if let marker = value.range(of: "''") { value = String(value[marker.upperBound...]).removingPercentEncoding ?? value }
        return value.isEmpty ? nil : (value as NSString).lastPathComponent
    }

    // MARK: Redirect chains

    func noteRedirect(to url: URL?, tab: TabSecurity) {
        guard let host = url?.host else { return }
        tab.redirectChain.append(host)
    }

    func finishChain(tab: TabSecurity) {
        let chain = tab.redirectChain
        defer { tab.redirectChain = [] }
        guard filtering, chain.count >= 3 else { return }
        let sites = Set(chain.map { Self.site(of: $0) })
        guard chain.count >= 5 || sites.count >= 4 else { return }
        tab.add(SecurityFinding(kind: .redirect, severity: sites.count >= 4 ? .high : .medium,
                                title: "Long redirect chain (\(chain.count) hops, \(sites.count) sites)",
                                detail: chain.joined(separator: " → ")))
    }

    func noteInsecure(_ url: URL, tab: TabSecurity) {
        guard url.scheme == "http", let host = url.host, !["localhost", "127.0.0.1", "::1"].contains(host),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost") else { return }
        tab.add(SecurityFinding(kind: .transport, severity: .low, title: "Connection is not encrypted (HTTP)",
                                detail: "Anything you type on \(host) can be read on the way."))
    }

    func notePopup(url: URL?, tab: TabSecurity, blocked: Bool) {
        tab.add(SecurityFinding(kind: .malvertising, severity: .medium, title: "A page tried to open a new tab by itself",
                                detail: url?.absoluteString ?? "(blank)", blocked: blocked))
    }
}

/// Receives the page script's messages.
final class SecurityScriptHandler: NSObject, WKScriptMessageHandler {
    weak var model: BrowserModel?
    init(model: BrowserModel) { self.model = model }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let webView = message.webView
        MainActor.assumeIsolated { model?.handleSecurityMessage(body, in: webView) }
    }
}
