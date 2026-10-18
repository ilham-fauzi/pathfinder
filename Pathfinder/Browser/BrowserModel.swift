import Foundation
import WebKit
import Network
import Observation

/// A WKDownload in progress, linked to its row in the Downloads list.
@MainActor
final class ActiveDownload {
    let download: WKDownload
    /// Frame that started it, so an HLS playlist can be fetched through the same page.
    let frame: WKFrameInfo?
    var item: DownloadItem?
    var destination: URL?
    /// Set when the queue started this download and is waiting for the saved path.
    var continuation: CheckedContinuation<String, Error>?
    var progressObservation: NSKeyValueObservation?
    /// The multi-connection download that replaced the single WebKit one, when there is one.
    var segmentTask: Task<Void, Never>?
    /// Last progress shown, so the row is redrawn per visible step instead of per network chunk.
    var lastShownProgress = -1.0
    private var sample: (time: Date, bytes: Int64)?
    private var smoothedRate = 0.0

    /// Current speed in bytes per second, smoothed over the last few seconds (0 until two samples exist).
    func rate(done: Int64) -> Double {
        let now = Date()
        guard let last = sample else { sample = (now, done); return 0 }
        let dt = now.timeIntervalSince(last.time)
        if dt >= 0.5 {
            let instant = Double(max(done - last.bytes, 0)) / dt
            smoothedRate = smoothedRate == 0 ? instant : smoothedRate * 0.7 + instant * 0.3
            sample = (now, done)
        }
        return smoothedRate
    }

    init(download: WKDownload, frame: WKFrameInfo?) {
        self.download = download
        self.frame = frame
    }

    func resume(_ result: Result<String, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// A media stream (HLS .m3u8, DASH .mpd, or direct video) traced from network traffic or DOM.
@Observable
final class DetectedStream: Identifiable, Equatable {
    let id = UUID()
    let url: String
    let pageURL: String
    let title: String
    let type: StreamType
    /// The frame (often an embedded player iframe) that requested the stream.
    let frame: WKFrameInfo?
    /// When the page asked for it: pre-roll ads come before the video.
    let foundAt = Date()

    enum StreamType: String, Equatable {
        case hls = "HLS (.m3u8)"
        case dash = "DASH (.mpd)"
        case direct = "Video"
        case other = "Stream"
    }

    init(url: String, pageURL: String, title: String, type: StreamType, frame: WKFrameInfo? = nil) {
        self.url = url
        self.pageURL = pageURL
        self.title = title
        self.type = type
        self.frame = frame
    }

    var displayName: String {
        if let u = URL(string: url) {
            let last = u.lastPathComponent
            if !last.isEmpty && last.count < 35 {
                return "\(type.rawValue): \(last)"
            }
        }
        return type.rawValue
    }

    /// HLS is fetched through the page and joined; direct files are downloaded with the page's cookies and Referer.
    var canSaveThroughBrowser: Bool { type == .hls || type == .direct }

    /// The stream the one Download button takes. An HLS master playlist first (yt-dlp and the browser engine both
    /// pick its best quality); otherwise the most recent playlist, since the video starts after its pre-roll ads.
    /// Then DASH, then a direct file. Used when nothing on the page could be measured.
    /// Addresses used by ad servers and video-ad players (VAST/VPAID creatives, pre-rolls).
    private static let adMarkers = [
        "/ads/", "/ad/", "/adv/", "/advert", "adserver", "adsystem", "adservice", "doubleclick", "googlesyndication",
        "imasdk", "preroll", "pre-roll", "midroll", "mid-roll", "postroll", "/vast", "vast.xml", "vast_", "vpaid", "/creative", "adnxs",
        "springserve", "spotx", "tremorhub", "adform", "pubmatic", "rubiconproject", "exoclick", "juicyads",
        "trafficjunky", "popads", "adsterra", "/commercial",
    ]

    /// The address looks like an ad rather than the video itself.
    static func looksLikeAd(_ url: String) -> Bool {
        let u = url.lowercased()
        return adMarkers.contains { u.contains($0) }
    }

    static func best(of streams: [DetectedStream]) -> DetectedStream? {
        let clean = streams.filter { !looksLikeAd($0.url) }
        let streams = clean.isEmpty ? streams : clean
        // HLS/DASH are inserted at the front as they are found, so the earliest of them is the last in the list.
        let hls = streams.filter { $0.type == .hls }
        if let master = hls.first(where: { $0.url.lowercased().contains("master") }) { return master }
        if let latest = hls.max(by: { $0.foundAt < $1.foundAt }) { return latest }
        if let dash = streams.filter({ $0.type == .dash }).max(by: { $0.foundAt < $1.foundAt }) { return dash }
        return streams.max { $0.foundAt < $1.foundAt }
    }

    static func == (lhs: DetectedStream, rhs: DetectedStream) -> Bool {
        lhs.id == rhs.id || lhs.url == rhs.url
    }
}

final class MediaSnifferScriptHandler: NSObject, WKScriptMessageHandler {
    weak var model: BrowserModel?

    init(model: BrowserModel? = nil) {
        self.model = model
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let url = dict["url"] as? String else { return }
        let pageUrl = dict["pageUrl"] as? String ?? ""
        let title = dict["title"] as? String ?? ""
        let kind = dict["kind"] as? String ?? ""
        let frame = message.frameInfo
        let webView = message.webView
        MainActor.assumeIsolated {
            model?.handleDetectedStream(url: url, pageURL: pageUrl, title: title, kind: kind, frame: frame, in: webView)
        }
    }
}

struct Bookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var url: String
}

/// One browser tab: its own page, history and detected streams.
@Observable
@MainActor
final class BrowserTab: Identifiable {
    let id = UUID()
    let webView: WKWebView
    fileprivate(set) var currentURL: URL?
    fileprivate(set) var title = ""
    fileprivate(set) var canGoBack = false
    fileprivate(set) var canGoForward = false
    fileprivate(set) var isLoading = false
    fileprivate(set) var progress = 0.0
    fileprivate(set) var loadError: String?
    /// Set when the page was stopped by the ad blocker (so the error can offer to load it anyway).
    fileprivate(set) var blockedURL: URL?
    /// Opened by a page on its own (a script's pop-up), not by a click: if the ad blocker stops it, the tab just goes away.
    fileprivate(set) var openedByScript = false
    /// Pinned tabs sit first, show only an icon in the horizontal strip, and come back after a restart.
    fileprivate(set) var isPinned = false
    /// The saved address of a pinned tab that has not finished loading yet, so saving never drops it.
    fileprivate var restoreURL: URL?
    /// Media streams (HLS .m3u8, DASH .mpd, or direct video) detected on this tab's page.
    fileprivate(set) var detectedStreams: [DetectedStream] = []
    /// What the security tools found on this tab's page (API calls, threats, site protection).
    let security = TabSecurity()
    @ObservationIgnored fileprivate var observations: [NSKeyValueObservation] = []

    init(webView: WKWebView) { self.webView = webView }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return currentURL?.host ?? "New Tab"
    }
}

/// Experimental in-app browser with tabs. All tabs share cookies, the SSH tunnel proxy, ad blocking and the
/// stream detector; a tab stays alive in the background, so a stream download from it can keep going.
@Observable
@MainActor
final class BrowserModel: NSObject {
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Tabs listed down the side instead of across the top.
    var verticalTabs = UserDefaults.standard.bool(forKey: "browserVerticalTabs") {
        didSet { UserDefaults.standard.set(verticalTabs, forKey: "browserVerticalTabs") }
    }
    /// How the side tab panel behaves: always open, icons only, or icons that open while the pointer is over them.
    enum SideTabsMode: String, CaseIterable, Identifiable {
        case expanded, collapsed, auto
        var id: String { rawValue }
        var name: String {
            switch self {
            case .expanded: return "Expanded"
            case .collapsed: return "Collapsed"
            case .auto: return "Auto (hover the left edge)"
            }
        }
    }
    var sideTabsMode = SideTabsMode(rawValue: UserDefaults.standard.string(forKey: "browserSideTabsMode") ?? "") ?? .expanded {
        didSet { UserDefaults.standard.set(sideTabsMode.rawValue, forKey: "browserSideTabsMode") }
    }
    /// What a site's fullscreen button does: fill the whole screen, or only the page area of this tab.
    enum FullscreenMode: String, CaseIterable, Identifiable {
        case screen, tab
        var id: String { rawValue }
        var name: String { self == .screen ? "Fill the screen" : "Fill this tab only" }
    }
    var fullscreenMode = FullscreenMode(rawValue: UserDefaults.standard.string(forKey: "browserFullscreenMode") ?? "") ?? .screen {
        didSet {
            guard fullscreenMode != oldValue else { return }
            UserDefaults.standard.set(fullscreenMode.rawValue, forKey: "browserFullscreenMode")
            // Open pages switch at once; the script is rebuilt so pages opened later start in the new mode.
            let message = "window.postMessage({__pfFSMode:'\(fullscreenMode.rawValue)'},'*')"
            for tab in tabs { tab.webView.evaluateJavaScript(message, completionHandler: nil) }
            Task { await applyAdBlock() }
        }
    }
    private(set) var bookmarks: [Bookmark] = {
        (UserDefaults.standard.data(forKey: "browserBookmarks")).flatMap { try? JSONDecoder().decode([Bookmark].self, from: $0) } ?? []
    }()
    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedTabID = UUID()
    var selectedTab: BrowserTab { tabs.first { $0.id == selectedTabID } ?? tabs[0] }

    // The shown tab's state.
    var webView: WKWebView { selectedTab.webView }
    var currentURL: URL? { selectedTab.currentURL }
    var title: String { selectedTab.title }
    var canGoBack: Bool { selectedTab.canGoBack }
    var canGoForward: Bool { selectedTab.canGoForward }
    var isLoading: Bool { selectedTab.isLoading }
    var progress: Double { selectedTab.progress }
    var loadError: String? { selectedTab.loadError }
    var blockedURL: URL? { selectedTab.blockedURL }
    var detectedStreams: [DetectedStream] { selectedTab.detectedStreams }

    /// One content controller for every tab: the stream detector, ad-block rules and scripts apply to all of them.
    @ObservationIgnored private let contentController = WKUserContentController()
    /// Every download goes to the shared Downloads list (set by the app).
    @ObservationIgnored weak var queue: QueueManager?
    @ObservationIgnored var activeDownloads: [ObjectIdentifier: ActiveDownload] = [:]
    var vpnBlocking = false
    /// SOCKS port of the SSH tunnel while it is required (parallel downloads go through it too).
    @ObservationIgnored private var socksPort: Int?
    /// Every site starts muted unless the user unmutes it. Per-site choices are remembered between launches.
    private(set) var muteByDefault = UserDefaults.standard.object(forKey: "browserMuteByDefault") as? Bool ?? true
    private(set) var siteMuteOverrides: [String: Bool] =
        UserDefaults.standard.dictionary(forKey: "browserMuteOverrides") as? [String: Bool] ?? [:]
    private(set) var canMute = true
    /// Block ads and trackers with built-in content-blocker rules.
    /// "Load without ad blocking" used to save the shield as off for good, which left every site unprotected.
    /// Blocking is now only paused for that one site, so the old saved "off" is reset once.
    private(set) var adBlockEnabled: Bool = {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "browserAdBlockResetV2") {
            defaults.set(true, forKey: "browserAdBlockResetV2")
            defaults.removeObject(forKey: "browserAdBlock")
        }
        return defaults.object(forKey: "browserAdBlock") as? Bool ?? true
    }()
    /// Site that blocking is paused for; blocking comes back as soon as the browser goes to another site.
    @ObservationIgnored private var adBlockPausedHost: String?
    private(set) var adBlockReady = false
    /// Progress / result of the filter lists, shown as the shield's tooltip.
    private(set) var adBlockDetail: String?
    @ObservationIgnored private var adBlockGeneration = 0
    var statusMessage: String?

    /// Folder for direct file downloads (set by the app).
    @ObservationIgnored var downloadDirectory: () -> String = { NSHomeDirectory() + "/Downloads" }
    @ObservationIgnored private var snifferHandler: MediaSnifferScriptHandler?
    @ObservationIgnored private var securityHandler: SecurityScriptHandler?
    /// Page scanner, firewall and file-integrity monitor.
    let security = SecurityCenter()

    static let mediaSnifferScript = """
    (function() {
        if (window.__advSnifferInjected) return;
        window.__advSnifferInjected = true;

        // An HLS player requests hundreds of pieces; only playlists and whole files are worth reporting.
        var segmentExt = /\\.(ts|m4s|aac|m4a|vtt|webvtt|key|jpg|jpeg|png|gif|webp)(\\?|#|$)/;
        function isStreamURL(url) {
            if (!url || typeof url !== 'string') return false;
            if (url.startsWith('data:') || url.startsWith('blob:')) return false;
            var u = url.toLowerCase();
            if (u.indexOf('google-analytics') !== -1 || u.indexOf('googlesyndication') !== -1 ||
                u.indexOf('doubleclick') !== -1 || u.indexOf('/ads/') !== -1) return false;
            var path = u.split('?')[0].split('#')[0];
            if (segmentExt.test(path) && path.indexOf('.m3u8') === -1 && path.indexOf('.mpd') === -1) return false;
            return u.indexOf('.m3u8') !== -1 || u.indexOf('.mpd') !== -1 ||
                   u.indexOf('.mp4') !== -1 || u.indexOf('.webm') !== -1 ||
                   u.indexOf('/hls/') !== -1 || u.indexOf('playlist') !== -1;
        }

        var reported = new Set();
        function report(rawUrl, kind) {
            if (!kind && !isStreamURL(rawUrl)) return;
            if (!rawUrl || typeof rawUrl !== 'string' || rawUrl.startsWith('blob:') || rawUrl.startsWith('data:')) return;
            var fullUrl = rawUrl;
            try {
                fullUrl = new URL(rawUrl, window.location.href).href;
            } catch(e) {}
            // Players re-request the same playlist every few seconds: tell the app once.
            if (reported.has(fullUrl) || reported.size > 200) return;
            reported.add(fullUrl);
            try {
                window.webkit.messageHandlers.mediaSniffer.postMessage({
                    url: fullUrl,
                    pageUrl: window.location.href,
                    title: document.title || '',
                    kind: kind || ''
                });
            } catch(e) {}
        }

        // Many hosts hide the playlist behind an address that says nothing (".txt", ".png", "/v/8f3a…").
        // What gives it away is the answer: an HLS/DASH content type, or text that starts with #EXTM3U / <MPD.
        function kindOf(contentType, head) {
            var ct = (contentType || '').toLowerCase();
            if (ct.indexOf('mpegurl') !== -1) return 'hls';
            if (ct.indexOf('dash+xml') !== -1) return 'dash';
            if (head) {
                if (head.charCodeAt(0) === 0xFEFF) head = head.slice(1);
                head = head.replace(/^\\s+/, '');
                if (head.indexOf('#EXTM3U') === 0) return 'hls';
                if (head.indexOf('<MPD') !== -1 && head.indexOf('urn:mpeg:dash') !== -1) return 'dash';
            }
            return null;
        }
        // Only answers small enough to be a playlist are read (segments are hundreds of KB and are skipped).
        var maxPlaylistBytes = 300000;

        var origOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
            this.__advUrl = url;
            report(url);
            return origOpen.apply(this, arguments);
        };
        var origSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.send = function() {
            var xhr = this;
            try {
                xhr.addEventListener('load', function() {
                    try {
                        var u = xhr.responseURL || xhr.__advUrl;
                        if (!u || reported.has(u)) return;
                        var k = kindOf(xhr.getResponseHeader('content-type'), null);
                        if (!k && (xhr.responseType === '' || xhr.responseType === 'text')) {
                            var t = xhr.responseText;
                            if (t && t.length < maxPlaylistBytes) k = kindOf('', t.slice(0, 2048));
                        } else if (!k && xhr.responseType === 'arraybuffer' && xhr.response &&
                                   xhr.response.byteLength < maxPlaylistBytes) {
                            k = kindOf('', String.fromCharCode.apply(null, new Uint8Array(xhr.response, 0, Math.min(64, xhr.response.byteLength))));
                        }
                        if (k) report(u, k);
                    } catch (e) {}
                });
            } catch (e) {}
            return origSend.apply(this, arguments);
        };

        var origFetch = window.fetch;
        window.fetch = function(input, init) {
            var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
            report(url);
            var promise = origFetch.apply(this, arguments);
            promise.then(function(r) {
                try {
                    var u = r.url || url;
                    if (!u || reported.has(u) || !r.ok) return;
                    var k = kindOf(r.headers.get('content-type'), null);
                    if (k) { report(u, k); return; }
                    var len = Number(r.headers.get('content-length') || 0);
                    var ct = (r.headers.get('content-type') || '').toLowerCase();
                    var smallEnough = len > 0 ? len < maxPlaylistBytes : (ct.indexOf('text') === 0 || ct === '');
                    if (!smallEnough) return;
                    r.clone().text().then(function(t) {
                        var k2 = kindOf('', t.slice(0, 2048));
                        if (k2) report(u, k2);
                    }).catch(function() {});
                } catch (e) {}
            }, function() {});
            return promise;
        };

        var origSrcDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
        if (origSrcDescriptor && origSrcDescriptor.set) {
            Object.defineProperty(HTMLMediaElement.prototype, 'src', {
                set: function(val) {
                    report(val);
                    return origSrcDescriptor.set.apply(this, arguments);
                },
                get: origSrcDescriptor.get,
                configurable: true,
                enumerable: true
            });
        }

        function scanElements() {
            var elems = document.querySelectorAll('video, audio, source');
            for (var i = 0; i < elems.length; i++) {
                if (elems[i].src) report(elems[i].src);
            }
        }
        // Players also set the source with setAttribute or a new <source>, which the src hook above misses:
        // every media element announces its load, so listen for that.
        document.addEventListener('loadstart', function(e) {
            var el = e.target;
            if (el && (el.currentSrc || el.src)) report(el.currentSrc || el.src);
        }, true);

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', scanElements);
        } else {
            scanElements();
        }
    })();
    """

    override init() {
        super.init()
        let handler = MediaSnifferScriptHandler(model: self)
        contentController.add(handler, name: "mediaSniffer")
        snifferHandler = handler
        let guardHandler = SecurityScriptHandler(model: self)
        contentController.add(guardHandler, name: PageGuardScript.handlerName)
        securityHandler = guardHandler
        security.onScriptsChanged = { [weak self] in Task { await self?.applyAdBlock(reload: true) } }
        security.integrity.watchedFolders = { [weak self] in
            [self?.downloadDirectory() ?? NSHomeDirectory() + "/Downloads", FileIntegrityMonitor.toolsFolder]
        }
        security.integrity.start()
        let first = makeTab()
        tabs = [first]
        selectedTabID = first.id
        let pinnedURLs = UserDefaults.standard.stringArray(forKey: "browserPinnedURLs") ?? []
        if !pinnedURLs.isEmpty {
            let pinned = pinnedURLs.compactMap { raw -> BrowserTab? in
                guard let url = URL(string: raw) else { return nil }
                let tab = makeTab()
                tab.isPinned = true
                tab.restoreURL = url
                tab.webView.load(URLRequest(url: url))
                return tab
            }
            tabs = pinned + [first]
        }
        Task { await applyAdBlock() }
    }

    private func makeTab() -> BrowserTab {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController = contentController
        // Lets video players go fullscreen (the HTML Fullscreen API is off by default in WKWebView).
        config.preferences.isElementFullscreenEnabled = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = Self.userAgent
        // Right-click a page and choose Inspect Element to open Safari's Web Inspector.
        view.isInspectable = true
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = self
        view.uiDelegate = self
        let tab = BrowserTab(webView: view)
        tab.observations = [
            view.observe(\.url) { [weak self, weak tab] _, _ in Task { @MainActor in if let tab { self?.sync(tab) } } },
            view.observe(\.title) { [weak self, weak tab] _, _ in Task { @MainActor in if let tab { self?.sync(tab) } } },
            view.observe(\.canGoBack) { [weak self, weak tab] _, _ in Task { @MainActor in if let tab { self?.sync(tab) } } },
            view.observe(\.canGoForward) { [weak self, weak tab] _, _ in Task { @MainActor in if let tab { self?.sync(tab) } } },
            view.observe(\.isLoading) { [weak self, weak tab] _, _ in Task { @MainActor in if let tab { self?.sync(tab) } } },
            view.observe(\.estimatedProgress) { [weak self, weak tab] _, _ in Task { @MainActor in if let tab { self?.sync(tab) } } },
        ]
        return tab
    }

    fileprivate func tab(for webView: WKWebView?) -> BrowserTab? {
        guard let webView else { return nil }
        return tabs.first { $0.webView === webView }
    }

    // MARK: Tabs

    /// Open a tab (optionally with a page) and show it.
    func newTab(_ input: String? = nil) {
        let tab = makeTab()
        tabs.append(tab)
        select(tab.id)
        if let input { go(input) }
    }

    // MARK: Security

    nonisolated static func pageKey(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        return c?.string ?? url.absoluteString
    }

    func handleSecurityMessage(_ body: [String: Any], in webView: WKWebView?) {
        guard let tab = tab(for: webView) else { return }
        security.handle(body, in: tab.security, pageHost: tab.currentURL?.host)
    }

    /// Fingerprint a file saved by the browser, so a later change to it is noticed.
    private func recordIntegrity(_ path: String, entry: ActiveDownload) {
        let origin = entry.item?.url ?? entry.download.originalRequest?.url?.absoluteString
        Task { await security.integrity.record(path: path, source: .download, origin: origin) }
    }

    // MARK: Pinned tabs

    func togglePin(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.isPinned.toggle()
        // Pinned tabs first; the order inside each group is kept.
        tabs = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
        savePinned()
    }

    private func savePinned() {
        let urls = tabs.filter { $0.isPinned }.compactMap { ($0.currentURL ?? $0.restoreURL)?.absoluteString }
        UserDefaults.standard.set(urls, forKey: "browserPinnedURLs")
    }

    // MARK: Bookmarks

    var isBookmarked: Bool { currentURL.map { url in bookmarks.contains { $0.url == url.absoluteString } } ?? false }

    func toggleBookmark() {
        guard let url = currentURL else { return }
        if let index = bookmarks.firstIndex(where: { $0.url == url.absoluteString }) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.append(Bookmark(title: selectedTab.displayTitle, url: url.absoluteString))
        }
        saveBookmarks()
    }

    func removeBookmark(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        saveBookmarks()
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) { UserDefaults.standard.set(data, forKey: "browserBookmarks") }
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
        applyMute()
    }

    /// Close a tab. Closing the last one leaves an empty tab.
    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        defer { if tab.isPinned { savePinned() } }
        tab.observations = []
        tab.webView.stopLoading()
        tab.webView.loadHTMLString("", baseURL: nil)   // stop any media still playing
        if tabs.isEmpty {
            let fresh = makeTab()
            tabs = [fresh]
            selectedTabID = fresh.id
        } else if selectedTabID == id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
        applyMute()
    }

    /// Host without "www.", used as the mute key.
    var currentHost: String? { Self.key(for: currentURL) }

    nonisolated static func key(for url: URL?) -> String? {
        guard var h = url?.host?.lowercased(), !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    private func isMuted(host: String?) -> Bool {
        host.flatMap { siteMuteOverrides[$0] } ?? muteByDefault
    }

    var isCurrentSiteMuted: Bool { isMuted(host: currentHost) }

    /// Flip the mute state of the site being shown.
    func toggleMute() {
        guard let host = currentHost else { return }
        let newState = !isCurrentSiteMuted
        if newState == muteByDefault { siteMuteOverrides[host] = nil } else { siteMuteOverrides[host] = newState }
        persistMute()
        applyMute()
    }

    /// Whether sites without their own choice start muted.
    func setMuteByDefault(_ muted: Bool) {
        muteByDefault = muted
        persistMute()
        applyMute()
    }

    /// Forget per-site choices; every site follows the default again.
    func resetSiteMuteChoices() {
        siteMuteOverrides = [:]
        persistMute()
        applyMute()
    }

    private func persistMute() {
        UserDefaults.standard.set(muteByDefault, forKey: "browserMuteByDefault")
        UserDefaults.standard.set(siteMuteOverrides, forKey: "browserMuteOverrides")
    }

    /// Mute state follows the site of each tab (or the one about to load in it).
    private func applyMute(host: String? = nil, in tab: BrowserTab? = nil) {
        let tab = tab ?? selectedTab
        let muted = isMuted(host: host ?? Self.key(for: tab.currentURL))
        let ok = setPageMuted(muted, in: tab.webView)
        if tab === selectedTab { canMute = ok }
    }

    /// Uses WebKit's page-level mute (what Safari's tab speaker uses). It is an internal selector, so it is
    /// looked up at runtime and the button is disabled if a future macOS removes it.
    private func setPageMuted(_ muted: Bool, in webView: WKWebView) -> Bool {
        let selector = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: selector), let imp = webView.method(for: selector) else { return false }
        typealias SetMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(imp, to: SetMuted.self)(webView, selector, muted ? 1 : 0)
        return true
    }

    private func sync(_ tab: BrowserTab) {
        let view = tab.webView
        let previousURL = tab.currentURL
        let previousHost = Self.key(for: previousURL)
        let url = view.url
        let newURL = (url == nil || url?.absoluteString == "about:blank") ? nil : url
        if newURL != previousURL {
            tab.currentURL = newURL
            tab.detectedStreams.removeAll()
            if tab.isPinned { savePinned() }
        }
        if Self.key(for: tab.currentURL) != previousHost {
            applyMute(in: tab)
            if let paused = adBlockPausedHost, tab === selectedTab, Self.key(for: tab.currentURL) != paused {
                adBlockPausedHost = nil
                adBlockEnabled = UserDefaults.standard.object(forKey: "browserAdBlock") as? Bool ?? true
                Task { await applyAdBlock() }
            }
        }
        // Every KVO change lands here (estimatedProgress many times per load). An @Observable property
        // redraws its views on every set, even with the same value, so only write what changed.
        let title = view.title ?? ""
        if tab.title != title { tab.title = title }
        if tab.canGoBack != view.canGoBack { tab.canGoBack = view.canGoBack }
        if tab.canGoForward != view.canGoForward { tab.canGoForward = view.canGoForward }
        if tab.isLoading != view.isLoading { tab.isLoading = view.isLoading }
        if tab.progress != view.estimatedProgress { tab.progress = view.estimatedProgress }
    }

    // MARK: Navigation

    func go(_ input: String) {
        guard let url = Self.resolve(input) else { return }
        security.typedURL = url
        selectedTab.loadError = nil
        selectedTab.blockedURL = nil
        webView.load(URLRequest(url: url))
    }

    /// Empty the browser: stop loading, drop the page and show the blank start screen.
    func blank() {
        webView.stopLoading()
        selectedTab.loadError = nil
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    /// One click: blank page, then delete cookies, cache, local storage and other site data
    /// (this also signs you out of every site).
    func clearEverything() async {
        blank()
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        statusMessage = "Browser cleared: page closed, cookies and site data deleted."
    }

    func dismissStatus() { statusMessage = nil }

    /// The ad blocker stopped a page the user wants: turn blocking off (the shield turns it back on) and load it.
    func loadWithoutAdBlock(_ url: URL) {
        let tab = selectedTab
        tab.loadError = nil
        tab.blockedURL = nil
        adBlockEnabled = false
        adBlockPausedHost = Self.key(for: url)
        Task {
            await applyAdBlock()
            tab.webView.load(URLRequest(url: url))
            statusMessage = "Ad blocking is paused for this site only. It comes back when you go to another site."
        }
    }

    func setAdBlock(_ enabled: Bool) {
        adBlockEnabled = enabled
        adBlockPausedHost = nil
        UserDefaults.standard.set(enabled, forKey: "browserAdBlock")
        Task { await applyAdBlock(reload: true) }
    }

    /// Turn ad blocking on or off. The small built-in rules and the YouTube script apply at once;
    /// EasyList and EasyPrivacy are downloaded in the background the first time and then refreshed weekly.
    func applyAdBlock(reload: Bool = false) async {
        adBlockGeneration += 1
        let generation = adBlockGeneration
        let controller = contentController
        controller.removeAllContentRuleLists()
        controller.removeAllUserScripts()

        // Always inject media stream tracer across all frames
        controller.addUserScript(WKUserScript(
            source: Self.mediaSnifferScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        controller.addUserScript(WKUserScript(
            source: TabFullscreen.script(mode: fullscreenMode),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        // The security script and the firewall's rules do not depend on the ad blocker being on.
        controller.addUserScript(WKUserScript(
            source: PageGuardScript.source(mode: security.wafMode, allowedHosts: security.allowedHosts),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        if security.filtering, let store = WKContentRuleListStore.default() {
            if let waf = try? await store.compileContentRuleList(
                forIdentifier: WAFRules.identifier, encodedContentRuleList: WAFRules.contentRulesJSON()),
               generation == adBlockGeneration { controller.add(waf) }
        }

        adBlockReady = false
        adBlockDetail = nil
        guard adBlockEnabled else {
            if reload, currentURL != nil { webView.reload() }
            return
        }

        controller.addUserScript(WKUserScript(source: AdBlocker.youTubeScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        let store = WKContentRuleListStore.default()!
        do {
            if let builtIn = try await store.compileContentRuleList(
                forIdentifier: AdBlocker.identifier, encodedContentRuleList: AdBlocker.rulesJSON()),
               generation == adBlockGeneration { controller.add(builtIn) }
        } catch {
            statusMessage = "Ad blocking could not start: \(error.localizedDescription)"
        }
        adBlockReady = true
        if reload, currentURL != nil { webView.reload() }

        // Cached lists first, then fetch whatever is missing or old.
        var loadedAny = await addCachedLists(to: controller, generation: generation)
        let stale = FilterLists.all.filter(FilterLists.isStale)
        if !stale.isEmpty {
            adBlockDetail = "Downloading ad filter lists…"
            var downloaded = false
            for list in stale {
                do { try await FilterLists.download(list); downloaded = true } catch { /* offline: keep the old copy */ }
                guard generation == adBlockGeneration else { return }
            }
            if downloaded {
                loadedAny = await addCachedLists(to: controller, generation: generation) || loadedAny
                if generation == adBlockGeneration, currentURL != nil { webView.reload() }
            }
        }
        guard generation == adBlockGeneration else { return }
        adBlockDetail = loadedAny ? "EasyList, EasyPrivacy, uBlock and AdGuard lists are active." : "Only the basic ad rules are active (filter lists are unavailable)."
    }

    /// Compile (or reuse) the cached filter lists and add them to the page. Returns true if any list was added.
    private func addCachedLists(to controller: WKUserContentController, generation: Int) async -> Bool {
        let store = WKContentRuleListStore.default()!
        var added = false
        for list in FilterLists.all {
            guard generation == adBlockGeneration, let modified = FilterLists.modified(list) else { continue }
            let identifier = "ydl-\(list.id)-v2-\(Int(modified.timeIntervalSince1970))"
            var compiled: WKContentRuleList? = await withCheckedContinuation { continuation in
                store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in continuation.resume(returning: list) }
            }
            if compiled == nil {
                adBlockDetail = "Preparing \(list.name)… the first time takes a minute."
                guard let rules = await FilterLists.convertedRules(from: FilterLists.file(for: list)),
                      generation == adBlockGeneration else { continue }
                compiled = try? await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules.json)
                // Drop older copies of this list.
                for old in await store.availableIdentifiers() ?? [] where old.hasPrefix("ydl-\(list.id)-") && old != identifier {
                    try? await store.removeContentRuleList(forIdentifier: old)
                }
            }
            if let compiled, generation == adBlockGeneration { controller.add(compiled); added = true }
        }
        return added
    }

    /// `kind` is "hls"/"dash" when the page saw a playlist by its content (its address may say nothing).
    func handleDetectedStream(url: String, pageURL: String, title: String, kind: String = "",
                              frame: WKFrameInfo? = nil, in webView: WKWebView? = nil) {
        guard let tab = tab(for: webView ?? frame?.webView) ?? Optional(selectedTab),
              !url.isEmpty, tab.detectedStreams.count < Self.maxDetectedStreams,
              !tab.detectedStreams.contains(where: { $0.url == url }) else { return }
        let lower = url.lowercased()
        let type: DetectedStream.StreamType
        if kind == "hls" || lower.contains(".m3u8") || lower.contains("/hls/") {
            type = .hls
        } else if kind == "dash" || lower.contains(".mpd") {
            type = .dash
        } else if lower.contains(".mp4") || lower.contains(".webm") {
            type = .direct
        } else {
            type = .other
        }

        let stream = DetectedStream(url: url, pageURL: pageURL, title: title, type: type, frame: frame)
        if type == .hls || type == .dash {
            tab.detectedStreams.insert(stream, at: 0)
        } else {
            tab.detectedStreams.append(stream)
        }
        if tab === selectedTab { statusMessage = "Found video stream: \(stream.displayName)" }
    }

    /// Enough for any real page; stops a page that fetches endless unique media URLs from growing the list.
    private static let maxDetectedStreams = 60

    func clearDetectedStreams() {
        selectedTab.detectedStreams.removeAll()
    }

    // MARK: Cookie export

    /// Export WebKit session cookies for the given URLs (page and stream host) into a Netscape-format
    /// cookies file that yt-dlp can consume via `--cookies <path>`. Returns the file URL, or nil on failure.
    func exportCookies(for urls: [URL]) async -> URL? {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let allCookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }

        // Include cookies whose domain overlaps with any of the hosts (handle leading-dot domains too).
        let hosts = Set(urls.compactMap { $0.host?.lowercased() })
        let relevant = allCookies.filter { cookie in
            let d = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return hosts.contains { $0 == d || $0.hasSuffix("." + d) || d.hasSuffix("." + $0) }
        }

        guard !relevant.isEmpty else { return nil }

        // Netscape HTTP Cookie File format (understood by yt-dlp / curl / wget).
        var lines = ["# Netscape HTTP Cookie File", "# Generated by Pathfinder"]
        for cookie in relevant {
            let httpOnlyPrefix = cookie.isHTTPOnly ? "#HttpOnly_" : ""
            let includeSubdomains = cookie.domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let secure = cookie.isSecure ? "TRUE" : "FALSE"
            let expiry = Int(cookie.expiresDate?.timeIntervalSince1970 ?? 0)
            // Fields: domain  includeSubdomains  path  secure  expiry  name  value
            lines.append("\(httpOnlyPrefix)\(cookie.domain)\t\(includeSubdomains)\t\(cookie.path)\t\(secure)\t\(expiry)\t\(cookie.name)\t\(cookie.value)")
        }

        let content = lines.joined(separator: "\n") + "\n"
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("adv_cookies_\(UUID().uuidString).txt")
        do {
            try content.write(to: tmpURL, atomically: true, encoding: .utf8)
            return tmpURL
        } catch {
            return nil
        }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { selectedTab.loadError = nil; selectedTab.blockedURL = nil; webView.reload() }
    func stop() { webView.stopLoading() }

    /// URL as typed, a bare domain, or a web search.
    nonisolated static func resolve(_ input: String) -> URL? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if t.contains("://") { return URL(string: t) }
        if !t.contains(where: \.isWhitespace), t.contains("."), let u = URL(string: "https://" + t), u.host != nil { return u }
        var c = URLComponents(string: SearchEngine.current.base)!
        c.queryItems = [URLQueryItem(name: "q", value: t)]
        return c.url
    }

    // MARK: Proxy (VPN tunnel)

    /// Route the browser through the SSH tunnel's SOCKS port. While VPN is required but not up, the proxy
    /// points at a port nobody listens on, so pages fail instead of loading outside the tunnel.
    func applyProxy(required: Bool, port: Int) {
        vpnBlocking = required
        socksPort = required ? port : nil
        if required, let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) {
            webView.configuration.websiteDataStore.proxyConfigurations =
                [ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: p))]
        } else {
            webView.configuration.websiteDataStore.proxyConfigurations = []
        }
    }

    // MARK: Downloads

    func register(_ download: WKDownload, frame: WKFrameInfo?) {
        download.delegate = self
        activeDownloads[ObjectIdentifier(download)] = ActiveDownload(download: download, frame: frame)
    }

    private func active(_ download: WKDownload) -> ActiveDownload? { activeDownloads[ObjectIdentifier(download)] }

    private func track(_ entry: ActiveDownload, item: DownloadItem) {
        entry.item = item
        entry.progressObservation = entry.download.progress.observe(\.fractionCompleted) { [weak entry] p, _ in
            let fraction = p.fractionCompleted, done = p.completedUnitCount, total = p.totalUnitCount
            Task { @MainActor in
                guard let entry, let item = entry.item else { return }
                let percent = fraction * 100
                guard percent - entry.lastShownProgress >= 0.5 || percent >= 100 else { return }
                entry.lastShownProgress = percent
                item.progress = percent
                if total > 0 {
                    item.downloadedSize = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
                    item.totalSize = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                    let rate = entry.rate(done: done)
                    if rate > 0 {
                        item.speed = ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file) + "/s"
                        item.eta = Self.clockText(Double(total - done) / rate)
                    }
                }
            }
        }
    }

    /// Queue engine for direct files: download with the page as Referer and the browser's cookies.
    func downloadDirect(_ item: DownloadItem, url: URL) async throws -> String {
        var request = URLRequest(url: url)
        if let referer = item.pageURL, let ref = URL(string: referer) {
            request.setValue(referer, forHTTPHeaderField: "Referer")
            if let scheme = ref.scheme, let host = ref.host { request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin") }
        }
        let download = await webView.startDownload(using: request)
        register(download, frame: item.browserFrame as? WKFrameInfo)
        guard let entry = active(download) else { throw CancellationError() }
        track(entry, item: item)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                entry.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor in
                download.cancel { _ in }
                entry.segmentTask?.cancel()
                entry.resume(.failure(CancellationError()))
            }
        }
    }

    func uniqueDestination(for name: String, in directory: String? = nil) -> URL {
        let dir = URL(fileURLWithPath: directory ?? downloadDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = (name as NSString).lastPathComponent.isEmpty ? "download" : (name as NSString).lastPathComponent
        let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
        var candidate = dir.appendingPathComponent(safe)
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }
}

// MARK: - WebKit delegates

extension BrowserModel: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let tab = tab(for: webView) {
            if navigationAction.targetFrame?.isMainFrame ?? false, let url = navigationAction.request.url,
               Self.pageKey(url) != tab.security.pageKey {
                tab.security.reset()
                tab.security.pageKey = Self.pageKey(url)
            }
            if case .block(let reason) = security.review(navigationAction, tab: tab.security, pageURL: tab.currentURL) {
                statusMessage = "Firewall stopped a request: \(reason)."
                decisionHandler(.cancel)
                return
            }
        }
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        if navigationAction.targetFrame?.isMainFrame ?? false, let host = Self.key(for: navigationAction.request.url),
           let tab = tab(for: webView) {
            applyMute(host: host, in: tab)
        }
        // Only web pages load in the view; other schemes (mailto:, app links) are ignored.
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "blob", "data", "file"].contains(scheme) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse,
           let tab = tab(for: webView) {
            tab.security.protection = WAFRules.protection(for: http)
        }
        if disposition.hasPrefix("attachment") || !navigationResponse.canShowMIMEType {
            if let tab = tab(for: webView),
               case .block(let reason) = security.reviewResponse(navigationResponse.response, tab: tab.security) {
                statusMessage = "Firewall stopped a download: \(reason)."
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        register(download, frame: navigationAction.sourceFrame)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        register(download, frame: nil)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        tab.security.redirectChain = webView.url?.host.map { [$0] } ?? []
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        security.noteRedirect(to: webView.url, tab: tab.security)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        security.finishChain(tab: tab.security)
        if let url = webView.url { security.noteInsecure(url, tab: tab.security) }
        tab.loadError = nil
        tab.blockedURL = nil
        tab.detectedStreams.removeAll()
        applyMute(in: tab)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error, in: webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error, in: webView)
    }

    private func report(_ error: Error, in webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        let ns = error as NSError
        // -999 = cancelled (a new navigation started); 102 = handed over to a download;
        // 204 = handed over to the media player (direct video or .m3u8 link), which is still playing it.
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain", ns.code == 102 || ns.code == 204 { return }
        // The ad blocker stopped the page itself: its rules (EasyList and the like) matched this address.
        if ns.localizedDescription.localizedCaseInsensitiveContains("content blocker") {
            let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
                ?? (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
            // A pop-up ad that the blocker caught: nobody asked for it, so it just disappears.
            if tab.openedByScript, tab.id != selectedTabID {
                closeTab(tab.id)
                return
            }
            tab.blockedURL = failing
            tab.loadError = "The ad blocker stopped this page" + (failing?.host.map { " (\($0))" } ?? "")
                + ". Its address matches a rule in the filter lists."
            return
        }
        tab.blockedURL = nil
        // The SSH hint only fits network failures: it used to be added to every error.
        tab.loadError = vpnBlocking && ns.domain == NSURLErrorDomain
            ? "The page could not load. The SSH tunnel is on; if it is not connected, the browser is blocked on purpose. (\(ns.localizedDescription))"
            : ns.localizedDescription
    }

    /// A new window never takes over the page being watched. A link the user clicked (target=_blank) opens in a
    /// new tab and is shown. A pop-up a script opened by itself (mostly ads) loads in a background tab: if the ad
    /// blocker stops it, that tab is dropped without a trace; otherwise it waits in the tab strip.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        let clicked = navigationAction.navigationType == .linkActivated
        if !clicked, security.filtering, let source = tab(for: webView), !security.isAllowed(source.currentURL?.host) {
            let hijacks = Date().timeIntervalSince(source.security.lastGesture) > 1.5
            if hijacks {
                security.notePopup(url: navigationAction.request.url, tab: source.security, blocked: security.blocking)
                if security.blocking { statusMessage = "Firewall stopped a pop-up the page opened by itself."; return nil }
            }
        }
        let tab = makeTab()
        tab.openedByScript = !clicked
        tabs.append(tab)
        if clicked { select(tab.id) } else {
            statusMessage = "A page tried to open a new tab. It was kept in the background."
        }
        tab.webView.load(navigationAction.request)
        return nil
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard let entry = active(download) else { completionHandler(nil); return }
        let sourceTab = tab(for: entry.frame?.webView) ?? selectedTab
        if entry.item == nil, case .block(let reason) = security.reviewDownload(name: suggestedFilename, tab: sourceTab.security) {
            activeDownloads.removeValue(forKey: ObjectIdentifier(download))
            statusMessage = "Firewall stopped a download: \(reason)."
            completionHandler(nil)
            return
        }
        // "Download Video" on an HLS player only gets the playlist (a text file listing the pieces).
        // Fetch the whole stream through the page instead and join it into one video.
        if MediaSniff.isHLS(mime: response.mimeType, url: response.url), let streamURL = response.url {
            completionHandler(nil)
            activeDownloads.removeValue(forKey: ObjectIdentifier(download))
            if let item = entry.item {
                item.isHLS = true
                entry.resume(.failure(CaptureError.isPlaylist))
            } else {
                // The page the request came from (the player iframe, not the outer page) is what the site checks.
                let page = entry.frame?.request.url?.absoluteString ?? sourceTab.currentURL?.absoluteString
                queue?.enqueueStream(url: streamURL.absoluteString, title: sourceTab.title, pageURL: page,
                                     isHLS: true, outputDir: downloadDirectory(), frame: entry.frame,
                                     cookiesFile: nil, viaBrowser: true)
                statusMessage = "Added to Downloads: the video is being saved through the browser."
            }
            return
        }
        // Players often serve video from links without an extension; name the file by its type.
        var name = suggestedFilename
        if (name as NSString).pathExtension.isEmpty, let ext = MediaSniff.fileExtension(forMIME: response.mimeType) {
            name += "." + ext
        }
        if let item = entry.item, let title = item.title, !title.isEmpty {
            let ext = (name as NSString).pathExtension
            name = Self.fileName(from: title, fallback: name, ext: ext.isEmpty ? "mp4" : ext)
        }
        let url = uniqueDestination(for: name, in: entry.item?.outputDir)
        // A big file that allows byte ranges is fetched over several connections instead of one.
        if let http = response as? HTTPURLResponse, SegmentedDownloader.qualifies(http), let remote = http.url {
            activeDownloads.removeValue(forKey: ObjectIdentifier(download))
            entry.progressObservation = nil
            entry.destination = url
            completionHandler(nil)   // ends WebKit's single-connection download
            startSegmented(entry, remote: remote, length: http.expectedContentLength, destination: url,
                           referer: entry.item?.pageURL ?? entry.frame?.request.url?.absoluteString ?? sourceTab.currentURL?.absoluteString)
            return
        }
        entry.destination = url
        if entry.item == nil, let queue {
            // Started by the page (a link or "Download Video"): list it with the other downloads.
            let item = DownloadItem(url: response.url?.absoluteString ?? "", outputDir: url.deletingLastPathComponent().path)
            item.title = url.lastPathComponent
            item.pageURL = sourceTab.currentURL?.absoluteString
            track(entry, item: item)
            queue.addExternal(item) { download.cancel { _ in } }
            statusMessage = "Added to Downloads: \(url.lastPathComponent)"
        }
        completionHandler(url)
    }

    // MARK: Parallel download of big files

    /// Cookies the page would send to `url`, as a Cookie header.
    private func cookieHeader(for url: URL) async -> String? {
        let all: [HTTPCookie] = await withCheckedContinuation { c in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { c.resume(returning: $0) }
        }
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

    private func startSegmented(_ entry: ActiveDownload, remote: URL, length: Int64, destination: URL, referer: String?) {
        if entry.item == nil, let queue {
            let item = DownloadItem(url: remote.absoluteString, outputDir: destination.deletingLastPathComponent().path)
            item.title = destination.lastPathComponent
            item.pageURL = referer
            entry.item = item
            queue.addExternal(item) { [weak entry] in entry?.segmentTask?.cancel() }
            statusMessage = "Added to Downloads: \(destination.lastPathComponent)"
        }
        let socks = socksPort
        // The task keeps `entry` alive itself: it is no longer in `activeDownloads` once WebKit's own download is dropped.
        entry.segmentTask = Task { [weak self] in
            guard let self else { return }
            var headers = ["User-Agent": Self.userAgent]
            if let referer, let ref = URL(string: referer) {
                headers["Referer"] = referer
                if let scheme = ref.scheme, let host = ref.host { headers["Origin"] = "\(scheme)://\(host)" }
            }
            if let cookie = await self.cookieHeader(for: remote) { headers["Cookie"] = cookie }
            let downloader = SegmentedDownloader(url: remote, headers: headers, length: length, socksPort: socks)
            let result: Result<String, Error>
            do {
                try await downloader.run(to: destination) { snapshot in
                    Task { @MainActor [weak entry] in
                        guard let entry, let item = entry.item else { return }
                        let done = snapshot.done
                        let rate = entry.rate(done: done)
                        if !snapshot.lanes.isEmpty { item.lanes = snapshot.lanes }
                        let percent = Double(done) / Double(max(length, 1)) * 100
                        guard percent - entry.lastShownProgress >= 0.3 || percent >= 100 else { return }
                        entry.lastShownProgress = percent
                        item.progress = percent
                        item.downloadedSize = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
                        item.totalSize = ByteCountFormatter.string(fromByteCount: length, countStyle: .file)
                        if rate > 0 {
                            item.speed = ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file) + "/s"
                            item.eta = Self.clockText(Double(length - done) / rate)
                        }
                    }
                }
                result = .success(self.addMissingExtension(destination.path))
            } catch {
                result = .failure(error)
            }
            self.finishSegmented(entry, result)
        }
    }

    private static func clockText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func finishSegmented(_ entry: ActiveDownload, _ result: Result<String, Error>) {
        defer { entry.segmentTask = nil }   // breaks the entry <-> task reference
        if case .success(let path) = result { recordIntegrity(path, entry: entry) }
        entry.item?.lanes = []
        let cancelled = { () -> Bool in
            if case .failure(let e) = result { return e is CancellationError || (e as NSError).code == NSURLErrorCancelled }
            return false
        }()
        if entry.continuation != nil {
            switch result {
            case .success(let path): entry.resume(.success(path))
            case .failure(let e): entry.resume(.failure(cancelled ? CancellationError() : e))
            }
        } else if let item = entry.item {
            switch result {
            case .success(let path): queue?.finishExternal(item.id, path: path, error: nil)
            case .failure(let e): queue?.finishExternal(item.id, path: nil, error: cancelled ? "Cancelled" : e.localizedDescription)
            }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = activeDownloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        entry.progressObservation = nil
        let path = entry.destination.map { addMissingExtension($0.path) } ?? ""
        if !path.isEmpty { recordIntegrity(path, entry: entry) }
        if entry.continuation != nil {
            entry.resume(.success(path))
        } else if let item = entry.item {
            queue?.finishExternal(item.id, path: path, error: nil)
        }
    }

    /// Still no extension (the server said octet-stream): look at the first bytes and name it accordingly.
    private func addMissingExtension(_ path: String) -> String {
        guard (path as NSString).pathExtension.isEmpty, let handle = FileHandle(forReadingAtPath: path) else { return path }
        let head = handle.readData(ofLength: 512)
        try? handle.close()
        guard let ext = MediaSniff.fileExtension(for: head) else { return path }
        let target = uniqueDestination(for: (path as NSString).lastPathComponent + "." + ext,
                                       in: (path as NSString).deletingLastPathComponent)
        return (try? FileManager.default.moveItem(atPath: path, toPath: target.path)) != nil ? target.path : path
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let entry = activeDownloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        entry.progressObservation = nil
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        if entry.continuation != nil {
            entry.resume(.failure(cancelled ? CancellationError() : error))
        } else if let item = entry.item {
            queue?.finishExternal(item.id, path: nil, error: cancelled ? "Cancelled" : error.localizedDescription)
        }
    }
}

/// "Fill this tab only": the page's own fullscreen request is answered by stretching the element over the page
/// area (the window, the tab bar and the address bar stay), instead of taking over the screen. It works in the
/// page by replacing the Fullscreen API calls; in "Fill the screen" mode the original calls run untouched.
/// A player inside an iframe asks its parent frame to stretch the iframe too.
enum TabFullscreen {
    static func script(mode: BrowserModel.FullscreenMode) -> String {
        """
        (function () {
          if (window.__pfFS) { window.__pfFS.mode = '\(mode.rawValue)'; return; }
          var st = window.__pfFS = { mode: '\(mode.rawValue)', el: null, saved: null };
          var isTop = window.top === window;
          var FILL = 'position:fixed!important;top:0!important;left:0!important;right:0!important;bottom:0!important;' +
            'width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;' +
            'margin:0!important;padding:0!important;z-index:2147483647!important;background:#000!important;' +
            'transform:none!important;border:0!important;';
          var FREE = 'transform:none!important;filter:none!important;perspective:none!important;contain:none!important;' +
            'overflow:visible!important;';
          var orig = {};
          function tab() { return st.mode === 'tab'; }
          function fire(el) {
            ['fullscreenchange', 'webkitfullscreenchange'].forEach(function (n) {
              // Bubbles up to the document, so listeners there hear it once.
              (el && el.isConnected ? el : document).dispatchEvent(new Event(n, { bubbles: true }));
            });
          }
          function restore() {
            if (!st.saved) return;
            var el = st.el, list = st.saved;
            st.saved = null; st.el = null;
            list.reverse().forEach(function (p) {
              if (p[1] === null) p[0].removeAttribute('style'); else p[0].setAttribute('style', p[1]);
            });
            fire(el);
          }
          function stretch(el) {
            if (st.el === el) return;
            restore();
            var saved = [];
            function set(n, css) { saved.push([n, n.getAttribute('style')]); n.style.cssText += ';' + css; }
            for (var a = el.parentElement; a; a = a.parentElement) set(a, FREE);
            set(el, FILL);
            if (document.body) set(document.body, 'overflow:hidden!important;');
            st.saved = saved; st.el = el;
            fire(el);
          }
          function frameOf(win) {
            var f = document.querySelectorAll('iframe,frame');
            for (var i = 0; i < f.length; i++) if (f[i].contentWindow === win) return f[i];
            return null;
          }
          function request(el) {
            stretch(el);
            if (!isTop) window.parent.postMessage({ __pfFS: 'enter' }, '*');
            return Promise.resolve();
          }
          function exit() {
            restore();
            if (!isTop) window.parent.postMessage({ __pfFS: 'exit' }, '*');
            return Promise.resolve();
          }
          function wrapMethod(proto, name, fn) {
            var o = proto[name];
            if (!o) return;
            orig[name] = o;
            proto[name] = function () { return tab() ? fn.apply(this, arguments) : o.apply(this, arguments); };
          }
          function wrapGetter(proto, name, fn) {
            var d = Object.getOwnPropertyDescriptor(proto, name);
            if (!d || !d.get) return;
            Object.defineProperty(proto, name, { configurable: true, enumerable: d.enumerable,
              get: function () { return tab() ? fn.call(this) : d.get.call(this); } });
          }
          ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen'].forEach(function (n) {
            wrapMethod(Element.prototype, n, function () { return request(this); });
          });
          ['webkitEnterFullscreen', 'webkitEnterFullScreen'].forEach(function (n) {
            if (window.HTMLVideoElement) wrapMethod(HTMLVideoElement.prototype, n, function () { request(this); });
          });
          ['exitFullscreen', 'webkitExitFullscreen', 'webkitCancelFullScreen'].forEach(function (n) {
            wrapMethod(Document.prototype, n, exit);
          });
          ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement'].forEach(function (n) {
            wrapGetter(Document.prototype, n, function () { return st.el; });
          });
          ['fullscreen', 'webkitIsFullScreen'].forEach(function (n) {
            wrapGetter(Document.prototype, n, function () { return !!st.el; });
          });
          ['fullscreenEnabled', 'webkitFullscreenEnabled'].forEach(function (n) {
            wrapGetter(Document.prototype, n, function () { return true; });
          });
          window.addEventListener('message', function (e) {
            var d = e.data;
            if (!d || typeof d !== 'object') return;
            if (d.__pfFSMode) {
              st.mode = d.__pfFSMode;
              if (!tab()) exit();
              var f = document.querySelectorAll('iframe,frame');
              for (var i = 0; i < f.length; i++) try { f[i].contentWindow.postMessage(d, '*'); } catch (x) {}
            } else if (d.__pfFS === 'enter' && tab()) {
              var host = frameOf(e.source);
              if (host) { stretch(host); if (!isTop) window.parent.postMessage({ __pfFS: 'enter' }, '*'); }
            } else if (d.__pfFS === 'exit' && tab()) {
              exit();
            }
          });
          window.addEventListener('keydown', function (e) {
            if (e.key === 'Escape' && st.el && tab()) exit();
          }, true);
        })();
        """
    }
}
