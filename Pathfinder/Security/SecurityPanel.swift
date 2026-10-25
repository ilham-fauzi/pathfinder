import SwiftUI
import AppKit

extension Severity {
    var color: Color {
        switch self {
        case .info: return Theme.text3
        case .low: return Theme.accentText
        case .medium: return Theme.warnText
        case .high: return Theme.dangerText
        }
    }
}

/// The shield next to the address bar: color follows the worst finding on the page.
struct SecurityButton: View {
    @Environment(BrowserModel.self) private var browser
    @State private var open = false

    private var worst: Severity? { browser.selectedTab.security.worst }
    private var badge: Int { browser.selectedTab.security.findings.filter { $0.severity >= .medium }.count + browser.security.integrity.problemCount }

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(min(badge, 9))").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 11, height: 11).background(Theme.danger, in: Circle()).offset(x: 6, y: -5)
                    }
                }
        }
        .help(help)
        .accessibilityLabel("Security center")
        .popover(isPresented: $open, arrowEdge: .bottom) { SecurityPanel().environment(browser) }
    }

    private var icon: String {
        guard browser.security.filtering else { return "checkmark.shield" }
        return (worst ?? .info) >= .medium ? "exclamationmark.shield.fill" : "checkmark.shield.fill"
    }

    private var tint: Color {
        guard browser.security.filtering else { return Theme.text3 }
        switch worst {
        case .high: return Theme.dangerText
        case .medium: return Theme.warnText
        default: return browser.currentURL == nil ? Theme.text3 : Theme.successText
        }
    }

    private var help: String {
        let tab = browser.selectedTab.security
        if !browser.security.filtering { return "Security center (firewall is off)" }
        if tab.findings.isEmpty { return "Security center: nothing suspicious on this page" }
        return "Security center: \(tab.findings.count) finding\(tab.findings.count == 1 ? "" : "s") on this page"
    }
}

struct SecurityPanel: View {
    @Environment(BrowserModel.self) private var browser

    enum Section: String, CaseIterable, Identifiable {
        case threats = "Threats", apis = "APIs", firewall = "Firewall", files = "Files"
        var id: String { rawValue }
    }
    @State private var section = Section.threats

    private var tab: TabSecurity { browser.selectedTab.security }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            Group {
                switch section {
                case .threats: ThreatsList()
                case .apis: APIList()
                case .firewall: FirewallView()
                case .files: IntegrityView()
                }
            }
        }
        .frame(width: 520, height: 520)
        .background(Theme.bg)
    }

    private func label(_ s: Section) -> String {
        switch s {
        case .threats: return tab.findings.isEmpty ? "Threats" : "Threats (\(tab.findings.count))"
        case .apis: return tab.activeCount > 0 ? "APIs (\(tab.activeCount) active)" : "APIs"
        case .firewall: return "Firewall"
        case .files: return browser.security.integrity.problemCount > 0 ? "Files (\(browser.security.integrity.problemCount))" : "Files"
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 18)).foregroundStyle(Theme.accentText)
            VStack(alignment: .leading, spacing: 1) {
                Text("Security center").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text(browser.currentHost ?? "No page open").font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer()
            Text("Firewall: \(browser.security.wafMode.name)").font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(browser.security.filtering ? Theme.accentSoft : Theme.surface2, in: Capsule())
                .foregroundStyle(browser.security.filtering ? Theme.accentText : Theme.text3)
        }
        .padding(12)
    }
}

// MARK: - Threats

private struct ThreatsList: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        let tab = browser.selectedTab.security
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                scanners(tab)
                if tab.findings.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.seal").font(.system(size: 26)).foregroundStyle(Theme.successText)
                        Text(browser.currentURL == nil ? "Open a page to scan it" : "Nothing suspicious found on this page")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                        Text("The scan runs while the page loads and again a few seconds later. It looks for the signs of the threats above; it cannot prove a site is safe.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 24).padding(.horizontal, 20)
                } else {
                    ForEach(tab.findings) { FindingRow(finding: $0) }
                }
            }
            .padding(12)
        }
    }

    /// One chip per kind of threat: green when clean, colored when something was found.
    private func scanners(_ tab: TabSecurity) -> some View {
        let kinds: [ThreatKind] = [.webShell, .redirect, .malvertising, .injection, .driveBy, .cryptojacking]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(kinds, id: \.self) { kind in
                let worst = tab.findings.filter { $0.kind == kind }.map(\.severity).max()
                HStack(spacing: 6) {
                    Image(systemName: kind.icon).frame(width: 14)
                    Text(kind.name).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: worst == nil ? "checkmark" : "exclamationmark.triangle.fill")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(worst?.color ?? Theme.successText)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(worst?.color.opacity(0.5) ?? Theme.border))
            }
        }
    }
}

private struct FindingRow: View {
    let finding: SecurityFinding

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.kind.icon).foregroundStyle(finding.severity.color).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(finding.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(finding.severity.name.uppercased()).font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(finding.severity.color.opacity(0.15), in: Capsule()).foregroundStyle(finding.severity.color)
                    if finding.blocked {
                        Text("BLOCKED").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Theme.successSoft, in: Capsule()).foregroundStyle(Theme.successText)
                    }
                }
                if !finding.detail.isEmpty {
                    Text(finding.detail).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text2)
                        .lineLimit(3).textSelection(.enabled)
                }
                Text(finding.kind.name).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }
}

// MARK: - APIs

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct APIList: View {
    @Environment(BrowserModel.self) private var browser
    enum Scope: String, CaseIterable, Identifiable { case page = "This page", sites = "All sites"; var id: String { rawValue } }
    @State private var scope = Scope.page
    @State private var onlyActive = false
    @State private var showAds = false
    @State private var withCookies = true
    @State private var query = ""
    @State private var copied: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $scope) { ForEach(Scope.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10).padding(.top, 8)
            if scope == .page { pageList } else { SitesList() }
        }
    }

    private var pageList: some View {
        let tab = browser.selectedTab.security
        let list = tab.sortedEndpoints.filter { e in
            (showAds || !e.isAd) && (!onlyActive || e.isActive) && (query.isEmpty || e.id.localizedCaseInsensitiveContains(query))
        }
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Filter", text: $query).textFieldStyle(.roundedBorder).font(.system(size: 12))
                    Button(copied == "all" ? "Copied" : "Copy all cURL") { copyAll(list) }
                        .disabled(list.isEmpty).font(.system(size: 12))
                }
                HStack(spacing: 12) {
                    Toggle("Active only", isOn: $onlyActive)
                    Toggle(tab.adCount > 0 ? "Show ads & trackers (\(tab.adCount) hidden)" : "Show ads & trackers", isOn: $showAds)
                    Toggle("Include cookies", isOn: $withCookies).help("Add the browser's cookies for the address to the copied cURL")
                    Spacer()
                    Text("\(tab.activeCount) active").font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                .toggleStyle(.checkbox).font(.system(size: 11.5))
            }
            .padding(10)
            Divider()
            if list.isEmpty {
                Spacer()
                Text(tab.endpoints.isEmpty ? "No API calls yet. Calls made by the page (fetch, XHR, WebSocket, event streams) appear here."
                     : "Nothing to show. Ads and trackers are hidden; change the filters above.")
                    .font(.system(size: 12)).foregroundStyle(Theme.text3).multilineTextAlignment(.center).padding(30)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(list) { APIRow(endpoint: $0, withCookies: withCookies); Divider() }
                    }
                }
            }
        }
    }

    private func copyAll(_ list: [APIEndpoint]) {
        let agent = browser.webView.customUserAgent
        let store = browser.webView.configuration.websiteDataStore.httpCookieStore
        let useCookies = withCookies
        Task {
            var blocks: [String] = []
            for e in list {
                let cookie = useCookies ? await CurlBuilder.cookie(forURL: e.fullURL, store: store) : nil
                blocks.append(CurlBuilder.command(for: e, userAgent: agent, cookie: cookie))
            }
            copyToPasteboard(blocks.joined(separator: "\n\n"))
            copied = "all"
            try? await Task.sleep(for: .seconds(1.5))
            copied = nil
        }
    }
}

private struct APIRow: View {
    @Environment(BrowserModel.self) private var browser
    let endpoint: APIEndpoint
    let withCookies: Bool
    @State private var expanded = false
    @State private var copied = false

    private var statusColor: Color {
        if endpoint.blocked { return Theme.dangerText }
        guard let s = endpoint.lastStatus else { return Theme.text3 }
        return s >= 500 ? Theme.dangerText : s >= 400 ? Theme.warnText : Theme.successText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.text3).frame(width: 10)
                Circle().fill(endpoint.isActive ? Theme.success : Theme.track).frame(width: 7, height: 7)
                    .help(endpoint.isActive ? "In use right now" : "Idle")
                Text(endpoint.kind == .websocket || endpoint.kind == .sse ? endpoint.kind.rawValue : endpoint.method)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accentText)
                    .frame(width: 58, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(endpoint.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(endpoint.host)
                        if endpoint.isAd { Text("ad / tracker").foregroundStyle(Theme.dangerText) }
                        else if endpoint.isThirdParty { Text("third party").foregroundStyle(Theme.warnText) }
                        if let type = endpoint.lastType { Text(type) }
                    }
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(endpoint.blocked ? "blocked" : endpoint.lastStatus.map(String.init) ?? (endpoint.isActive ? "…" : "–"))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(statusColor)
                    Text("×\(endpoint.count)" + (endpoint.lastMillis.map { " · \($0) ms" } ?? ""))
                        .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                }
                Button { copyCurl() } label: { Text(copied ? "Copied" : "cURL").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(.bordered).controlSize(.small).help("Copy this call as a cURL command")
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() } }
            if expanded { details.padding(.leading, 28).padding(.top, 8) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .contextMenu {
            Button("Copy cURL") { copyCurl() }
            Button("Copy URL") { copyToPasteboard(endpoint.fullURL) }
        }
    }

    private func copyCurl() {
        let agent = browser.webView.customUserAgent
        let store = browser.webView.configuration.websiteDataStore.httpCookieStore
        let e = endpoint, useCookies = withCookies
        Task {
            let cookie = useCookies ? await CurlBuilder.cookie(forURL: e.fullURL, store: store) : nil
            copyToPasteboard(CurlBuilder.command(for: e, userAgent: agent, cookie: cookie))
            copied = true
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private var query: [URLQueryItem] { URLComponents(string: endpoint.fullURL)?.queryItems ?? [] }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            block("URL", endpoint.fullURL)
            if !query.isEmpty {
                block("Query parameters", query.map { "\($0.name) = \($0.value ?? "")" }.joined(separator: "\n"))
            }
            if !endpoint.sample.requestHeaders.isEmpty {
                block("Request headers", endpoint.sample.requestHeaders.map { "\($0.name): \($0.value)" }.joined(separator: "\n"))
            }
            if let body = endpoint.sample.requestBody, !body.isEmpty { block("Request body", body) }
            if !endpoint.sample.responseHeaders.isEmpty {
                block("Response headers", endpoint.sample.responseHeaders.map { "\($0.name): \($0.value)" }.joined(separator: "\n"))
            }
            if let preview = endpoint.sample.responsePreview, !preview.isEmpty { block("Response preview", Self.pretty(preview)) }
            if endpoint.sample.requestHeaders.isEmpty && endpoint.sample.responseHeaders.isEmpty && endpoint.sample.requestBody == nil {
                Text("No headers captured for this kind of call.").font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            Text("Captured in memory for this visit only. Headers added by the browser itself (such as cookies) are not visible to the page.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
        }
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text3)
            Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text2)
                .lineLimit(14).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    static func pretty(_ text: String) -> String {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return text }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Every site visited, with the backend endpoints found on it.
private struct SitesList: View {
    @Environment(BrowserModel.self) private var browser
    @State private var query = ""

    var body: some View {
        let registry = browser.security.registry
        let sites = registry.sortedSites.filter { query.isEmpty || $0.site.localizedCaseInsensitiveContains(query)
            || $0.endpoints.contains { $0.host.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) } }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search sites and endpoints", text: $query).textFieldStyle(.roundedBorder).font(.system(size: 12))
                Text("\(registry.sites.count) sites").font(.system(size: 11)).foregroundStyle(Theme.text3)
                Button("Clear") { registry.clear() }.font(.system(size: 12)).disabled(registry.sites.isEmpty)
            }
            .padding(10)
            Divider()
            if sites.isEmpty {
                Spacer()
                Text("The backend APIs of each site you visit are collected here. Ads and trackers are left out. Only host and path are kept on disk.")
                    .font(.system(size: 12)).foregroundStyle(Theme.text3).multilineTextAlignment(.center).padding(30)
                Spacer()
            } else {
                List {
                    ForEach(sites, id: \.site) { entry in
                        DisclosureGroup {
                            ForEach(entry.endpoints) { e in
                                RegisteredRow(endpoint: e)
                            }
                        } label: {
                            HStack {
                                Text(entry.site).font(.system(size: 12.5, weight: .medium))
                                Spacer()
                                Text("\(entry.endpoints.count) endpoints").font(.system(size: 11)).foregroundStyle(Theme.text3)
                            }
                            .contextMenu { Button("Forget this site") { registry.remove(site: entry.site) } }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

private struct RegisteredRow: View {
    let endpoint: RegisteredEndpoint

    var body: some View {
        HStack(spacing: 8) {
            Text(endpoint.kind == "WebSocket" || endpoint.kind == "SSE" ? endpoint.kind : endpoint.method)
                .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accentText)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(endpoint.path).font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                Text(endpoint.host + (endpoint.thirdParty ? " · third party" : "")).font(.system(size: 10)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("×\(endpoint.count)").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            Button("cURL") { copyToPasteboard("curl \(CurlBuilder.quote(endpoint.url)) \\\n  -X \(endpoint.method) \\\n  --compressed\n# Headers, body and query are only available while the page is open.") }
                .buttonStyle(.bordered).controlSize(.mini)
        }
        .contextMenu { Button("Copy URL") { copyToPasteboard(endpoint.url) } }
    }
}

// MARK: - Firewall

private struct FirewallView: View {
    @Environment(BrowserModel.self) private var browser

    var body: some View {
        let security = browser.security
        let tab = browser.selectedTab.security
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Browser firewall").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Picker("", selection: Binding(get: { security.wafMode }, set: { security.wafMode = $0 })) {
                        ForEach(WAFMode.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text(modeText(security.wafMode)).font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                    Text("Applies to pages opened from now on. Pages you open by typing the address are never blocked.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                }
                .card()

                if let host = browser.currentHost {
                    Toggle(isOn: Binding(get: { security.isAllowed(host) }, set: { security.setAllowed($0, host: host) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Trust \(host)").font(.system(size: 12.5, weight: .medium))
                            Text("The firewall does not inspect or block anything for this site.")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                        }
                    }
                    .card()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Stopped on this page: \(tab.blockedCount)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    ForEach(["SQL injection, script injection, path traversal and command injection in links, forms and API calls",
                             "Pop-ups and downloads the page starts without a click",
                             "Programs disguised as documents",
                             "Frames that take over the whole tab",
                             "\(WAFRules.minerHosts.count + WAFRules.maliciousHosts.count) known mining and IP-grabber hosts"], id: \.self) { rule in
                        Label(rule, systemImage: "checkmark").font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                    }
                }
                .card()

                siteProtection(tab)
            }
            .padding(12)
        }
    }

    private func modeText(_ mode: WAFMode) -> String {
        switch mode {
        case .off: return "Nothing is checked."
        case .monitor: return "Attacks and risky requests are reported in Threats. Nothing is stopped."
        case .block: return "High-risk requests are stopped before they leave the browser, and reported."
        }
    }

    /// What the site itself does to protect its visitors (read from its response headers).
    @ViewBuilder
    private func siteProtection(_ tab: TabSecurity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This site's own protection").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            if let p = tab.protection {
                row(p.https ? "checkmark.circle.fill" : "xmark.circle.fill", p.https ? Theme.successText : Theme.dangerText,
                    p.https ? "Encrypted connection (HTTPS)" : "Not encrypted (HTTP)")
                row(p.firewall != nil ? "checkmark.circle.fill" : "minus.circle", p.firewall != nil ? Theme.successText : Theme.text3,
                    p.firewall.map { "Firewall / CDN detected: \($0)" } ?? "No firewall or CDN detected in the response")
                ForEach(p.present, id: \.self) { row("checkmark.circle.fill", Theme.successText, "\($0) set") }
                ForEach(p.missing, id: \.self) { row("exclamationmark.circle.fill", Theme.warnText, "\($0) missing") }
            } else {
                Text("Open a page to see its headers.").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
            }
        }
        .card()
    }

    private func row(_ icon: String, _ color: Color, _ text: String) -> some View {
        Label { Text(text).font(.system(size: 12)).foregroundStyle(Theme.text2) } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
    }
}

// MARK: - File integrity

private struct IntegrityView: View {
    @Environment(BrowserModel.self) private var browser
    @State private var showAll = false
    @State private var confirmClear = false

    var body: some View {
        let fim = browser.security.integrity
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(fim.entries.count) files watched").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(status(fim)).font(.system(size: 11)).foregroundStyle(fim.problemCount > 0 ? Theme.dangerText : Theme.text3)
                }
                Spacer()
                Toggle("Show all", isOn: $showAll).toggleStyle(.checkbox).font(.system(size: 12))
                Button { addFile(fim) } label: { Image(systemName: "plus") }.help("Watch another file")
                Button { Task { await fim.verify(deep: true) } } label: {
                    if fim.busy { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .help("Check every file now (re-reads each one)")
                Button { confirmClear = true } label: { Image(systemName: "trash") }
                    .disabled(fim.entries.allSatisfy { $0.source == .tool } && fim.unexpected.isEmpty)
                    .help("Clear the list of watched files")
            }
            .buttonStyle(IconButtonStyle())
            .confirmationDialog("Clear the list of watched files?", isPresented: $confirmClear) {
                Button("Clear list", role: .destructive) { fim.clear() }
            } message: {
                Text("The files themselves are not touched. The app's own tools stay under watch.")
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(fim.unexpected, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: "questionmark.circle.fill").foregroundStyle(Theme.warnText)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent).font(.system(size: 12.5)).foregroundStyle(Theme.text).lineLimit(1)
                                Text("New file that did not come through the browser").font(.system(size: 10.5)).foregroundStyle(Theme.warnText)
                            }
                            Spacer()
                            Button("Trust") { Task { await fim.record(path: path, source: .manual) } }.buttonStyle(.link)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        Divider()
                    }
                    ForEach(fim.entries.filter { showAll || (fim.states[$0.path] ?? .unchecked) != .ok }) { entry in
                        IntegrityRow(entry: entry, state: fim.states[entry.path] ?? .unchecked)
                        Divider()
                    }
                    if fim.entries.isEmpty && fim.unexpected.isEmpty {
                        Text("Files saved by the browser are fingerprinted (SHA-256) here, together with yt-dlp and the other tools the app uses. If one of them changes or disappears later, it shows up in this list.")
                            .font(.system(size: 12)).foregroundStyle(Theme.text3).multilineTextAlignment(.center).padding(30)
                    } else if !showAll && fim.problemCount == 0 {
                        Text("Every watched file matches its fingerprint.").font(.system(size: 12)).foregroundStyle(Theme.successText).padding(24)
                    }
                }
            }
        }
    }

    private func status(_ fim: FileIntegrityMonitor) -> String {
        if fim.problemCount > 0 { return "\(fim.changedCount) changed or missing, \(fim.unexpected.count) new" }
        guard let last = fim.lastCheck else { return "Checking…" }
        return "All unchanged · checked \(last.formatted(date: .omitted, time: .standard))"
    }

    private func addFile(_ fim: FileIntegrityMonitor) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        Task { for url in panel.urls { await fim.record(path: url.path, source: .manual) } }
    }
}

private struct IntegrityRow: View {
    @Environment(BrowserModel.self) private var browser
    let entry: IntegrityEntry
    let state: IntegrityState

    private var color: Color {
        switch state {
        case .ok: return Theme.successText
        case .modified, .missing: return Theme.dangerText
        case .unchecked: return Theme.text3
        }
    }

    private var text: String {
        switch state {
        case .ok: return "Unchanged"
        case .modified: return "Changed since it was saved"
        case .missing: return "Missing"
        case .unchecked: return "Not checked yet"
        }
    }

    var body: some View {
        let fim = browser.security.integrity
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: state == .ok ? "checkmark.circle.fill" : state == .unchecked ? "circle.dotted" : "exclamationmark.triangle.fill")
                .foregroundStyle(color).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text((entry.path as NSString).lastPathComponent).font(.system(size: 12.5)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(text) · \(entry.source.rawValue) · \(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))")
                    .font(.system(size: 10.5)).foregroundStyle(color)
                if let note = entry.note { Text(note).font(.system(size: 10.5)).foregroundStyle(Theme.warnText) }
                Text(entry.sha256).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Theme.text3)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer(minLength: 4)
            if state == .modified {
                Button("Accept") { Task { await fim.accept(entry.path) } }.buttonStyle(.link).help("The change was expected: save the new fingerprint")
            }
            Button { fim.remove(entry.path) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(Theme.text3).help("Stop watching this file")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
            Button("Copy SHA-256") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.sha256, forType: .string) }
        }
    }
}

private extension View {
    func card() -> some View {
        self.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }
}
