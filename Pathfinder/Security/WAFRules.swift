import Foundation
import WebKit

/// The browser-side firewall.
/// - Off: nothing is checked.
/// - Monitor: attack patterns and risky requests are reported, nothing is stopped.
/// - Block: they are stopped before they leave the browser.
enum WAFMode: String, CaseIterable, Identifiable, Sendable {
    case off, monitor, block
    var id: String { rawValue }
    var name: String {
        switch self {
        case .off: return "Off"
        case .monitor: return "Monitor"
        case .block: return "Block"
        }
    }
}

struct WAFRule: Sendable {
    let id: String
    let category: String
    let name: String
    let pattern: String
    let severity: Severity
}

enum WAFRules {
    /// Patterns for SQL injection, script injection, path traversal and command injection. They run on the
    /// decoded address, form fields and request bodies, so `%27%20OR%201%3D1` is seen as `' OR 1=1`.
    static let rules: [WAFRule] = [
        WAFRule(id: "sqli-union", category: "SQL injection", name: "UNION SELECT",
                pattern: #"\bunion\b[\s/*+()]+(all[\s/*+()]+|distinct[\s/*+()]+)?select\b"#, severity: .high),
        WAFRule(id: "sqli-tautology", category: "SQL injection", name: "Always-true condition",
                pattern: #"['"]?\s*\b(or|and)\b\s+['"]?(\w+)['"]?\s*=\s*['"]?\2['"]?"#, severity: .high),
        WAFRule(id: "sqli-quote-or", category: "SQL injection", name: "Quote break-out",
                pattern: #"'\s*(or|and|union|having|order\s+by)\b"#, severity: .medium),
        WAFRule(id: "sqli-stacked", category: "SQL injection", name: "Stacked query",
                pattern: #";\s*(drop|alter|truncate|insert|update|delete|exec|create)\s+(table|database|into|from|xp_|user)\b"#,
                severity: .high),
        WAFRule(id: "sqli-time", category: "SQL injection", name: "Time-based probe",
                pattern: #"\b(pg_sleep|sleep|benchmark)\s*\(\s*\d|waitfor\s+delay\s+['"]"#, severity: .high),
        WAFRule(id: "sqli-comment", category: "SQL injection", name: "Comment terminator",
                pattern: #"['"]\s*(--|#|/\*)"#, severity: .medium),
        WAFRule(id: "sqli-schema", category: "SQL injection", name: "Schema or file access",
                pattern: #"information_schema|\bxp_cmdshell\b|\bload_file\s*\(|into\s+(out|dump)file|sqlite_master"#,
                severity: .high),
        WAFRule(id: "xss-script", category: "XSS", name: "<script> tag",
                pattern: #"<\s*/?\s*script\b"#, severity: .high),
        WAFRule(id: "xss-handler", category: "XSS", name: "Event-handler injection",
                pattern: #"<[^>]*\bon[a-z]{3,}\s*=|["'\s/]on(error|load|click|mouseover|focus|toggle|animationstart|pointerover)\s*="#,
                severity: .high),
        WAFRule(id: "xss-js-url", category: "XSS", name: "javascript: address",
                pattern: #"javascript\s*:"#, severity: .medium),
        WAFRule(id: "xss-tag", category: "XSS", name: "Active HTML element",
                pattern: #"<\s*(iframe|object|embed|svg|img|body|details|math|link|meta|base)\b[^>]*"#, severity: .medium),
        WAFRule(id: "xss-dom", category: "XSS", name: "Script API call",
                pattern: #"document\s*\.\s*(cookie|domain|write)|\beval\s*\(|fromCharCode\s*\(|\batob\s*\("#, severity: .medium),
        WAFRule(id: "xss-data", category: "XSS", name: "data:text/html",
                pattern: #"data:\s*text/html"#, severity: .medium),
        WAFRule(id: "lfi-traversal", category: "Path traversal", name: "../ sequence",
                pattern: #"(\.\.[/\\]){2,}"#, severity: .high),
        WAFRule(id: "lfi-files", category: "Path traversal", name: "System file",
                pattern: #"/etc/(passwd|shadow|hosts)\b|\bboot\.ini\b|\bwin\.ini\b|/proc/self/"#, severity: .high),
        WAFRule(id: "rce-shell", category: "Command injection", name: "Shell command",
                pattern: #"(;|\|\||&&|`|\$\()\s*(cat|ls|wget|curl|nc|ncat|bash|sh|zsh|whoami|id|uname|powershell|cmd(\.exe)?|python\d?|perl|php)(?=[\s;|&)]|$)"#,
                severity: .high),
        WAFRule(id: "rce-php", category: "Command injection", name: "PHP code",
                pattern: #"<\?php|\b(system|passthru|shell_exec|popen|proc_open|assert)\s*\(|base64_decode\s*\("#, severity: .high),
    ]

    /// Same list, as JSON for the page script (`i` flag is applied there).
    static var json: String {
        let list = rules.map { ["id": $0.id, "cat": $0.category, "name": $0.name, "re": $0.pattern, "sev": $0.severity.name.lowercased()] }
        let data = (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static let compiled: [(WAFRule, NSRegularExpression)] = rules.compactMap { rule in
        (try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive])).map { (rule, $0) }
    }

    /// Percent-decoded up to three times, so double-encoded payloads are caught too.
    static func decode(_ text: String) -> String {
        var current = text.replacingOccurrences(of: "+", with: " ")
        for _ in 0..<3 {
            guard let next = current.removingPercentEncoding, next != current else { break }
            current = next
        }
        return current
    }

    /// Rules that match `text` (already decoded or not).
    static func scan(_ text: String) -> [WAFRule] {
        let decoded = decode(text)
        let range = NSRange(decoded.startIndex..., in: decoded)
        return compiled.filter { $0.1.firstMatch(in: decoded, range: range) != nil }.map(\.0)
    }

    /// The part of an address an attacker controls: path, query and fragment.
    static func inspect(_ url: URL) -> [WAFRule] {
        var text = url.path
        if let q = url.query { text += "?" + q }
        if let f = url.fragment { text += "#" + f }
        return scan(text)
    }

    // MARK: Hosts that only mine coins or serve malware

    /// In-browser miners and their pools (cryptojacking).
    static let minerHosts = [
        "coinhive.com", "coin-hive.com", "authedmine.com", "cryptoloot.pro", "crypto-loot.com", "coinimp.com",
        "jsecoin.com", "minero.cc", "webmine.pro", "mineralt.io", "monerominer.rocks", "minemytraffic.com",
        "ppoi.org", "2giga.link", "papoto.com", "coinerra.com", "cnhv.co", "coin-have.com", "hashforcash.us",
    ]

    /// IP-grabber / tracking-link services that exist to unmask visitors.
    static let maliciousHosts = [
        "grabify.link", "iplogger.org", "iplogger.com", "2no.co", "yip.su", "blasze.com", "lovebird.guru", "stopify.co",
    ]

    static let identifier = "pf-waf-v1"

    /// WebKit content-blocker rules: miners and trackers-of-attackers are refused before they connect.
    static func contentRulesJSON() -> String {
        let hosts = minerHosts + maliciousHosts
        let rules: [[String: Any]] = hosts.map { host in
            ["trigger": ["url-filter": "^[a-z]+://([^/]*\\.)?" + host.replacingOccurrences(of: ".", with: "\\.") + "([:/]|$)"],
             "action": ["type": "block"]]
        }
        // Rules that do not name a resource type would also stop a page from opening at all.
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return AdBlocker.sparingPages(String(decoding: data, as: UTF8.self))
    }

    static func isMinerHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return (minerHosts + maliciousHosts).contains { h == $0 || h.hasSuffix("." + $0) }
    }

    // MARK: Site protection (response headers)

    /// Firewall / CDN the site sits behind, read from its response headers.
    static func firewall(in headers: [AnyHashable: Any]) -> String? {
        let h = Dictionary(uniqueKeysWithValues: headers.compactMap { key, value -> (String, String)? in
            guard let k = key as? String, let v = value as? String else { return nil }
            return (k.lowercased(), v.lowercased())
        })
        let server = h["server"] ?? ""
        if h["cf-ray"] != nil || server.contains("cloudflare") { return "Cloudflare" }
        if h["x-sucuri-id"] != nil || h["x-sucuri-cache"] != nil || server.contains("sucuri") { return "Sucuri" }
        if h["x-iinfo"] != nil || h["x-cdn"]?.contains("imperva") == true || h["x-cdn"]?.contains("incapsula") == true { return "Imperva" }
        if server.contains("akamai") || h["x-akamai-transformed"] != nil || h["akamai-grn"] != nil { return "Akamai" }
        if h["x-amz-cf-id"] != nil || h["x-amz-cf-pop"] != nil { return "AWS CloudFront / WAF" }
        if h["x-azure-ref"] != nil { return "Azure Front Door" }
        if h["x-fw-version"] != nil || h["x-waf-event-info"] != nil || h["x-waf"] != nil { return "Web application firewall" }
        if server.contains("barracuda") { return "Barracuda" }
        if server.contains("fastly") || h["x-served-by"]?.contains("cache-") == true { return "Fastly" }
        if h["x-vercel-id"] != nil { return "Vercel" }
        if server.contains("awselb") || server.contains("bigip") || h["x-wa-info"] != nil { return "Load balancer / WAF" }
        return nil
    }

    static func protection(for response: HTTPURLResponse) -> SiteProtection {
        let headers = response.allHeaderFields
        func has(_ name: String) -> Bool { response.value(forHTTPHeaderField: name) != nil }
        var report = SiteProtection()
        report.https = response.url?.scheme == "https"
        report.firewall = firewall(in: headers)
        let checks: [(String, Bool)] = [
            ("Content-Security-Policy", has("Content-Security-Policy")),
            ("Strict-Transport-Security", has("Strict-Transport-Security") || !report.https),
            ("X-Frame-Options", has("X-Frame-Options") || (response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("frame-ancestors") ?? false)),
            ("X-Content-Type-Options", has("X-Content-Type-Options")),
            ("Referrer-Policy", has("Referrer-Policy")),
        ]
        for (name, ok) in checks {
            if ok { report.present.append(name) } else { report.missing.append(name) }
        }
        return report
    }
}

/// File types that can run code on a Mac or Windows PC.
enum RiskyFile {
    static let executable: Set<String> = [
        "exe", "msi", "scr", "bat", "cmd", "com", "pif", "dll", "jar", "apk", "ps1", "vbs", "vbe", "js", "jse", "wsf", "hta",
        "lnk", "reg", "dmg", "pkg", "mpkg", "app", "command", "sh", "scpt", "workflow", "terminal", "action", "iso", "appimage", "deb", "rpm",
    ]
    static let documents: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "jpg", "jpeg", "png", "gif", "txt", "mp4", "mp3", "zip", "rtf"]

    static func isExecutable(_ name: String) -> Bool { executable.contains((name as NSString).pathExtension.lowercased()) }

    /// `invoice.pdf.exe`: an executable dressed up as a document.
    static func isDisguised(_ name: String) -> Bool {
        let parts = (name as NSString).lastPathComponent.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 3, let last = parts.last, executable.contains(last) else { return false }
        return documents.contains(parts[parts.count - 2])
    }
}
