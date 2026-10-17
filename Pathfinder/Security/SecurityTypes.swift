import Foundation

enum Severity: Int, Comparable, Codable, Sendable {
    case info = 0, low, medium, high

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    var name: String {
        switch self {
        case .info: return "Info"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    init(name: String) {
        switch name {
        case "high": self = .high
        case "medium": self = .medium
        case "low": self = .low
        default: self = .info
        }
    }
}

/// What a finding is about, one per scanner the panel shows.
enum ThreatKind: String, Sendable, CaseIterable {
    case webShell, redirect, malvertising, injection, driveBy, cryptojacking, waf, transport

    var name: String {
        switch self {
        case .webShell: return "Web shell"
        case .redirect: return "Malicious redirect"
        case .malvertising: return "Malvertising"
        case .injection: return "SQLi / XSS payload"
        case .driveBy: return "Drive-by download"
        case .cryptojacking: return "Cryptojacking"
        case .waf: return "Firewall"
        case .transport: return "Connection"
        }
    }

    var icon: String {
        switch self {
        case .webShell: return "terminal"
        case .redirect: return "arrow.triangle.branch"
        case .malvertising: return "rectangle.badge.xmark"
        case .injection: return "syringe"
        case .driveBy: return "arrow.down.doc"
        case .cryptojacking: return "bitcoinsign.circle"
        case .waf: return "flame"
        case .transport: return "lock.open"
        }
    }

    init(name: String) { self = ThreatKind(rawValue: name) ?? .malvertising }
}

struct SecurityFinding: Identifiable, Equatable, Sendable {
    let id = UUID()
    let kind: ThreatKind
    let severity: Severity
    let title: String
    let detail: String
    /// The firewall stopped it (as opposed to only noticing it).
    var blocked = false
    let time = Date()
}

/// One endpoint the page talks to (fetch, XHR, WebSocket, event stream or beacon).
struct APIEndpoint: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case fetch = "fetch", xhr = "XHR", websocket = "WebSocket", sse = "SSE", beacon = "Beacon" }

    var id: String { "\(kind.rawValue) \(method) \(host)\(path)" }
    let kind: Kind
    let method: String
    let host: String
    let path: String
    let fullURL: String
    var count = 0
    var inFlight = 0
    var lastStatus: Int?
    var lastMillis: Int?
    var lastType: String?
    var failed = 0
    var blocked = false
    var lastSeen = Date()
    /// A WebSocket / event stream that is still open.
    var open = false

    /// Used right now: a request is on its way, or a live connection is open.
    var isActive: Bool { inFlight > 0 || open }
    var isThirdParty = false
}

/// What the page's response headers say about the site's own protection.
struct SiteProtection: Equatable, Sendable {
    var https = false
    var firewall: String?
    var present: [String] = []
    var missing: [String] = []
}
