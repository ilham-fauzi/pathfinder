import Foundation
import WebKit
import UniformTypeIdentifiers

// MARK: - HLS playlists

/// Just enough HLS parsing to save a stream: pick a variant, list what a media playlist needs, and rewrite it
/// to point at local copies so ffmpeg can join them.
enum HLS {
    struct Variant: Equatable {
        let uri: String
        let bandwidth: Int
        let audioGroup: String?
        /// Picture height from RESOLUTION=WxH, when the playlist says.
        var height: Int? = nil
    }

    struct Resource: Equatable {
        enum Kind: Equatable { case segment, key, map }
        let uri: String
        let kind: Kind
    }

    static func isPlaylist(_ text: String) -> Bool { text.hasPrefix("#EXTM3U") || text.hasPrefix("\u{FEFF}#EXTM3U") }
    static func isMaster(_ text: String) -> Bool { text.contains("#EXT-X-STREAM-INF") }

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Value of `name` in an attribute list such as `BANDWIDTH=800000,AUDIO="aud",URI="k.key"`.
    static func attribute(_ name: String, in line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        var rest = line[line.index(after: colon)...]
        while !rest.isEmpty {
            guard let eq = rest.firstIndex(of: "=") else { return nil }
            let key = rest[..<eq].trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: eq)...]
            let value: Substring
            if rest.first == "\"" {
                let body = rest.dropFirst()
                let end = body.firstIndex(of: "\"") ?? body.endIndex
                value = body[..<end]
                rest = end < body.endIndex ? body[body.index(after: end)...] : body[body.endIndex...]
            } else {
                let end = rest.firstIndex(of: ",") ?? rest.endIndex
                value = rest[..<end]
                rest = rest[end...]
            }
            if rest.first == "," { rest = rest.dropFirst() }
            if key == name { return String(value) }
        }
        return nil
    }

    static func variants(in text: String) -> [Variant] {
        let all = lines(text)
        var result: [Variant] = []
        for (i, line) in all.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
            guard let uri = all[(i + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else { continue }
            result.append(Variant(uri: uri,
                                  bandwidth: Int(attribute("BANDWIDTH", in: line) ?? "") ?? 0,
                                  audioGroup: attribute("AUDIO", in: line),
                                  height: attribute("RESOLUTION", in: line).flatMap { $0.split(separator: "x").last }.flatMap { Int($0) }))
        }
        return result
    }

    /// Length in seconds of a media playlist (sum of its #EXTINF); nil for a live one (no #EXT-X-ENDLIST).
    static func duration(of text: String) -> Double? {
        guard text.contains("#EXT-X-ENDLIST") else { return nil }
        return lines(text).reduce(0) { total, line in
            guard line.hasPrefix("#EXTINF:") else { return total }
            let value = line.dropFirst(8).prefix { $0 != "," }.trimmingCharacters(in: .whitespaces)
            return total + (Double(value) ?? 0)
        }
    }

    /// The best variant: highest bandwidth.
    static func bestVariant(in text: String, maxHeight: Int? = nil) -> Variant? {
        let all = variants(in: text)
        if let maxHeight {
            // The tallest variant that fits; if every one is taller, the smallest of them.
            let fitting = all.filter { ($0.height ?? 0) <= maxHeight && $0.height != nil }
            if let pick = fitting.max(by: { ($0.height ?? 0, $0.bandwidth) < ($1.height ?? 0, $1.bandwidth) }) { return pick }
        }
        return all.max { $0.bandwidth < $1.bandwidth }
    }

    /// Playlist of a separate audio track for `group`, preferring the default one. nil when audio is muxed in.
    static func audioURI(in text: String, group: String) -> String? {
        let media = lines(text).filter {
            $0.hasPrefix("#EXT-X-MEDIA") && attribute("TYPE", in: $0) == "AUDIO" && attribute("GROUP-ID", in: $0) == group
        }
        let preferred = media.first { attribute("DEFAULT", in: $0) == "YES" } ?? media.first
        return preferred.flatMap { attribute("URI", in: $0) }
    }

    /// Segments, keys and init maps of a media playlist, each once, in playlist order.
    static func resources(in text: String) -> [Resource] {
        var result: [Resource] = []
        var seen = Set<String>()
        func add(_ uri: String, _ kind: Resource.Kind) {
            if seen.insert(uri).inserted { result.append(Resource(uri: uri, kind: kind)) }
        }
        for line in lines(text) where !line.isEmpty {
            if line.hasPrefix("#EXT-X-KEY") {
                if attribute("METHOD", in: line) != "NONE", let uri = attribute("URI", in: line) { add(uri, .key) }
            } else if line.hasPrefix("#EXT-X-MAP") {
                if let uri = attribute("URI", in: line) { add(uri, .map) }
            } else if !line.hasPrefix("#") {
                add(line, .segment)
            }
        }
        return result
    }

    /// FairPlay / Widevine / PlayReady: the key comes from a licence server and cannot be fetched like a file.
    static func isDRMProtected(_ text: String) -> Bool {
        lines(text).contains { line in
            guard line.hasPrefix("#EXT-X-KEY") || line.hasPrefix("#EXT-X-SESSION-KEY") else { return false }
            let method = attribute("METHOD", in: line) ?? ""
            let format = attribute("KEYFORMAT", in: line) ?? "identity"
            let uri = attribute("URI", in: line) ?? ""
            return (method.hasPrefix("SAMPLE-AES") && method != "SAMPLE-AES") || format != "identity" || uri.hasPrefix("skd:")
        }
    }

    /// The playlist with every resource URI replaced by its local file name (from `names`, keyed by original URI).
    static func localPlaylist(_ text: String, names: [String: String]) -> String {
        lines(text).map { line -> String in
            if line.hasPrefix("#EXT-X-KEY") || line.hasPrefix("#EXT-X-MAP"),
               let uri = attribute("URI", in: line), let local = names[uri] {
                return line.replacingOccurrences(of: "URI=\"\(uri)\"", with: "URI=\"\(local)\"")
            }
            if !line.isEmpty, !line.hasPrefix("#"), let local = names[line] { return local }
            return line
        }.joined(separator: "\n")
    }

    /// Some hosts disguise MPEG-TS segments as images by putting a fake header (PNG, GIF…) in front.
    /// Drop it so the segment starts at the first TS sync byte. Encrypted or fMP4 data is left alone.
    static func strippingFakeHeader(_ data: Data) -> Data {
        let bytes = [UInt8](data.prefix(4096 + 377))
        guard bytes.count > 377, bytes[0] != 0x47 else { return data }
        for i in 1..<(bytes.count - 376) where bytes[i] == 0x47 && bytes[i + 188] == 0x47 && bytes[i + 376] == 0x47 {
            return data.dropFirst(i)
        }
        return data
    }
}

enum DASH {
    /// `mediaPresentationDuration="PT1H2M3.5S"` of a manifest, in seconds; nil for a live one.
    static func duration(of mpd: String) -> Double? {
        guard let r = mpd.range(of: "mediaPresentationDuration=\"") else { return nil }
        let value = mpd[r.upperBound...].prefix { $0 != "\"" }
        return isoDuration(String(value))
    }

    /// ISO 8601 duration ("P1DT2H3M4.5S") in seconds.
    static func isoDuration(_ text: String) -> Double? {
        guard text.hasPrefix("P") else { return nil }
        var total = 0.0, number = "", inTime = false
        for c in text.dropFirst() {
            if c == "T" { inTime = true; continue }
            if c.isNumber || c == "." { number.append(c); continue }
            guard let n = Double(number) else { return nil }
            number = ""
            switch (c, inTime) {
            case ("D", false): total += n * 86_400
            case ("H", true): total += n * 3_600
            case ("M", true): total += n * 60
            case ("S", true): total += n
            default: return nil   // years/months/weeks: not used by streams
            }
        }
        return number.isEmpty ? total : nil
    }
}

/// Plain-text record of the last Download-button checks: what the page offered, what each stream measured,
/// what was chosen. Kept in Application Support (Pathfinder/stream-check.log), last 200 KB.
@MainActor
final class StreamCheckLog {
    private var lines: [String] = []

    /// Tests point the log elsewhere.
    static var fileURLOverride: URL?
    /// The last entry written, for tests.
    private(set) static var lastEntry: String?
    private static let writer = DispatchQueue(label: "Pathfinder.StreamCheckLog", qos: .utility)

    static var fileURL: URL {
        fileURLOverride ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("Pathfinder/stream-check.log")
    }

    func add(_ line: String) { lines.append(line) }

    func save() {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "=== \(stamp)\n" + lines.joined(separator: "\n") + "\n\n"
        Self.lastEntry = entry
        let url = Self.fileURL
        // One write at a time: two presses in a row must not overwrite each other's entry.
        Self.writer.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = (try? Data(contentsOf: url)) ?? Data()
            data.append(Data(entry.utf8))
            if data.count > 200_000 { data = data.suffix(200_000) }
            try? data.write(to: url, options: .atomic)
        }
    }

    static func describe(_ m: BrowserModel.Measurement) -> String {
        switch m {
        case .seconds(let d): return clock(d)
        case .bytes(let b): return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - File types

enum MediaSniff {
    /// File extension from the first bytes of a file, for downloads saved without one.
    static func fileExtension(for head: Data) -> String? {
        let b = [UInt8](head.prefix(400))
        guard b.count >= 8 else { return nil }
        if b[4...7].elementsEqual("ftyp".utf8) { return "mp4" }
        if b[0...3].elementsEqual([0x1A, 0x45, 0xDF, 0xA3]) { return "webm" }
        if b.count > 376, b[0] == 0x47, b[188] == 0x47, b[376] == 0x47 { return "ts" }
        if b[0...6].elementsEqual("#EXTM3U".utf8) { return "m3u8" }
        if b[0...2].elementsEqual("ID3".utf8) || (b[0] == 0xFF && b[1] & 0xE0 == 0xE0) { return "mp3" }
        return nil
    }

    static func fileExtension(forMIME mime: String?) -> String? {
        guard let mime, mime != "application/octet-stream", let type = UTType(mimeType: mime) else { return nil }
        return type.preferredFilenameExtension
    }

    static func isHLS(mime: String?, url: URL?) -> Bool {
        let m = mime?.lowercased() ?? ""
        if m.contains("mpegurl") { return true }
        return url?.path.lowercased().hasSuffix(".m3u8") ?? false
    }
}

// MARK: - Capture through the page

enum CaptureError: LocalizedError {
    case http(Int, String)
    case notPlaylist
    case drm
    case noFFmpeg
    case ffmpeg(String)
    /// The page's own request failed (blocked by the site, no answer…), with the browser's reason.
    case page(String)
    /// A direct download turned out to be an HLS playlist (internal: switch to joining the pieces).
    case isPlaylist

    var errorDescription: String? {
        switch self {
        case .http(let code, let what): return "The site refused \(what) (HTTP \(code)). Play the video in the page first, then try again."
        case .notPlaylist: return "The stream link did not return a playlist."
        case .drm: return "This stream is DRM-protected (licensed key), so it cannot be saved."
        case .noFFmpeg: return "FFmpeg is needed to join this stream. Install it in Settings › Binaries."
        case .ffmpeg(let m): return "Joining the video failed: \(m)"
        case .isPlaylist: return "The link is an HLS playlist."
        case .page(let m): return "The site did not give the stream to the browser (\(m)). It may only play in its own video player, which can't be saved."
        }
    }
}

/// A place to run page requests from: a frame of a web view (nil frame = its main frame).
@MainActor
private struct FetchTarget {
    let webView: WKWebView
    let frame: WKFrameInfo?
}

/// The targets to try, best first. Shared by all requests of one capture, so once a target stops working
/// (the user navigated away from the original page) every later request goes straight to the next one.
@MainActor
private final class FetchRoute {
    var targets: [FetchTarget]
    init(_ targets: [FetchTarget]) { self.targets = targets }
}

/// A hidden web view holding an empty document at the stream page's address. Requests made from it carry that
/// page's origin, Referer and cookies (same website data store, same SSH tunnel proxy), so a capture keeps going
/// whatever the visible browser does next.
@MainActor
final class CaptureContext: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var loading: CheckedContinuation<Void, Error>?

    init(dataStore: WKWebsiteDataStore, userAgent: String?) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.customUserAgent = userAgent
        webView.navigationDelegate = self
    }

    func open(as pageURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loading = continuation
            webView.loadHTMLString("<!doctype html><html><head><title></title></head><body></body></html>", baseURL: pageURL)
        }
    }

    private func finish(_ error: Error?) {
        if let error { loading?.resume(throwing: error) } else { loading?.resume() }
        loading = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }
}

/// A media address found again in the page by `recoverStreams()`.
private struct RecoveredSource: Sendable {
    let url: String
    let page: String?
    let title: String
    let kind: String
}

private struct PageFetch: Sendable {
    let status: Int
    let base64: String?
}

extension BrowserModel: BrowserDownloadEngine {
    /// Runs inside the frame that plays the video, so the request carries that frame's cookies, Referer,
    /// Origin and network path (SSH tunnel included), exactly like the site's own player.
    /// Some sites never answer a script's request (only their native video player gets the stream), so every
    /// request gives up after 90 seconds instead of leaving the download stuck at 0%.
    private static let fetchScript = """
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), 90000);
    try {
    let r = null, err = null;
    try { r = await fetch(url, { cache: 'no-store', signal: ac.signal }); } catch (e) { err = e; }
    if ((!r || !r.ok) && !ac.signal.aborted) {
        try { const r2 = await fetch(url, { cache: 'no-store', credentials: 'include', signal: ac.signal }); if (r2.ok || !r) r = r2; }
        catch (e) { if (!r) err = e; }
    }
    if (!r) throw (ac.signal.aborted ? new Error('the site did not answer') : (err || new Error('fetch failed')));
    if (!r.ok) return { status: r.status };
    const blob = await r.blob();
    const dataURL = await new Promise((resolve, reject) => {
        const fr = new FileReader();
        fr.onload = () => resolve(fr.result);
        fr.onerror = () => reject(fr.error);
        fr.readAsDataURL(blob);
    });
    return { status: r.status, data: dataURL.slice(dataURL.indexOf(',') + 1) };
    } finally { clearTimeout(timer); }
    """

    private func pageFetch(_ url: URL, target: FetchTarget) async throws -> PageFetch {
        try await withCheckedThrowingContinuation { continuation in
            target.webView.callAsyncJavaScript(Self.fetchScript, arguments: ["url": url.absoluteString],
                                               in: target.frame, in: .defaultClient) { result in
                switch result {
                case .success(let value):
                    let dict = value as? [String: Any] ?? [:]
                    let status = (dict["status"] as? NSNumber)?.intValue ?? 0
                    continuation.resume(returning: PageFetch(status: status, base64: dict["data"] as? String))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Fetch through the first target that answers; a target that worked moves to the front for later requests.
    private func fetchData(_ url: URL, what: String, route: FetchRoute) async throws -> Data {
        var lastError: Error = CaptureError.http(0, what)
        for target in route.targets {
            do {
                let result = try await pageFetch(url, target: target)
                if (200..<300).contains(result.status), let b64 = result.base64, let data = await Self.decode(b64) {
                    if let i = route.targets.firstIndex(where: { $0.webView === target.webView && $0.frame === target.frame }), i > 0 {
                        route.targets.insert(route.targets.remove(at: i), at: 0)
                    }
                    return data
                }
                lastError = CaptureError.http(result.status, what)
            } catch let error as NSError where error.domain == WKError.errorDomain {
                lastError = CaptureError.page(error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: Finding the main video

    /// Small requests made while choosing a stream, run inside the page:
    /// `text`: a playlist's text. `size`: a file's size (HEAD, else a one-byte range request).
    /// `media`: the duration of a <video>/<audio> on the page playing this address (what the player itself knows).
    /// `kind`: what the address answers with, from its content type or first bytes: "hls", "dash", "video" or null.
    /// Gives up after 10 seconds so the Download button never hangs on a silent server.
    private static let probeScript = """
    if (mode === 'media') {
        for (const el of document.querySelectorAll('video, audio')) {
            if ((el.currentSrc === url || el.src === url) && isFinite(el.duration) && el.duration > 0) return String(el.duration);
        }
        return null;
    }
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), 10000);
    async function get(init) {
        let r = null;
        try { r = await fetch(url, { cache: 'no-store', signal: ac.signal, ...init }); } catch (e) {}
        if ((!r || !r.ok) && !ac.signal.aborted) {
            try { r = await fetch(url, { cache: 'no-store', credentials: 'include', signal: ac.signal, ...init }); } catch (e) {}
        }
        return r && r.ok ? r : null;
    }
    try {
        if (mode === 'kind') {
            const r = await get({ headers: { Range: 'bytes=0-2047' } });
            if (!r) return null;
            const ct = (r.headers.get('content-type') || '').toLowerCase();
            let bytes = new Uint8Array(0);
            if (!ct.startsWith('video/') && !ct.startsWith('audio/') && r.body) {
                const reader = r.body.getReader();
                const chunk = await reader.read();
                if (chunk.value) bytes = chunk.value;
            }
            try { r.body && r.body.cancel(); } catch (e) {}
            if (ct.indexOf('mpegurl') !== -1) return 'hls';
            if (ct.indexOf('dash+xml') !== -1) return 'dash';
            if (ct.startsWith('video/') || ct.startsWith('audio/')) return 'video';
            let head = new TextDecoder().decode(bytes.slice(0, 2048));
            if (head.charCodeAt(0) === 0xFEFF) head = head.slice(1);
            head = head.trimStart();
            if (head.startsWith('#EXTM3U')) return 'hls';
            if (head.indexOf('<MPD') !== -1) return 'dash';
            const ftyp = bytes.length > 8 && bytes[4] === 0x66 && bytes[5] === 0x74 && bytes[6] === 0x79 && bytes[7] === 0x70;
            const ebml = bytes.length > 4 && bytes[0] === 0x1A && bytes[1] === 0x45 && bytes[2] === 0xDF && bytes[3] === 0xA3;
            const ts = bytes.length > 376 && bytes[0] === 0x47 && bytes[188] === 0x47 && bytes[376] === 0x47;
            return ftyp || ebml || ts ? 'video' : null;
        }
        if (mode === 'size') {
            const h = await get({ method: 'HEAD' });
            const len = h && h.headers.get('content-length');
            if (len && Number(len) > 1) return len;
            const r = await get({ headers: { Range: 'bytes=0-0' } });
            if (!r) return null;
            const range = r.headers.get('content-range');
            try { r.body && r.body.cancel(); } catch (e) {}
            const total = range && range.split('/')[1];
            return total && total !== '*' ? total : null;
        }
        const r = await get({});
        return r ? (await r.text()).slice(0, 4000000) : null;
    } catch (e) { return null; } finally { clearTimeout(timer); }
    """

    private func probe(_ url: URL, mode: String, targets: [FetchTarget]) async -> String? {
        for target in targets {
            let text: String? = await withCheckedContinuation { continuation in
                target.webView.callAsyncJavaScript(Self.probeScript, arguments: ["url": url.absoluteString, "mode": mode],
                                                   in: target.frame, in: .defaultClient) { result in
                    continuation.resume(returning: (try? result.get()) as? String)
                }
            }
            if let text { return text }
        }
        return nil
    }

    /// What a check learned about one stream.
    enum Measurement: Equatable {
        /// Playing time in seconds (playlist, manifest or the page's own player).
        case seconds(Double)
        /// File size in bytes, when the length could not be known.
        case bytes(Double)
    }

    /// How long a stream plays, asked through the frame that played it; for a direct file without a known
    /// length, how big it is. nil when the site doesn't answer or the stream is live.
    /// A `.other` stream is first asked what it is; it keeps `.other` when it is not a playlist or a video.
    private func measure(_ stream: DetectedStream) async -> Measurement? {
        guard let url = URL(string: stream.url) else { return nil }
        var targets: [FetchTarget] = []
        if let frame = stream.frame, let view = frame.webView { targets.append(FetchTarget(webView: view, frame: frame)) }
        targets.append(FetchTarget(webView: webView, frame: nil))
        switch stream.type {
        case .direct:
            if let d = await probe(url, mode: "media", targets: targets).flatMap(Double.init) { return .seconds(d) }
            return await probe(url, mode: "size", targets: targets).flatMap(Double.init).map(Measurement.bytes)
        case .dash:
            return await probe(url, mode: "text", targets: targets).flatMap(DASH.duration(of:)).map(Measurement.seconds)
        case .other:
            guard let kind = await probe(url, mode: "kind", targets: targets),
                  let type = DetectedStream.StreamType(probedKind: kind) else { return nil }
            stream.type = type
            return await measure(stream)
        case .hls:
            guard let text = await probe(url, mode: "text", targets: targets), HLS.isPlaylist(text) else { return nil }
            guard HLS.isMaster(text) else { return HLS.duration(of: text).map(Measurement.seconds) }
            guard let variant = HLS.bestVariant(in: text), let vURL = URL(string: variant.uri, relativeTo: url)?.absoluteURL,
                  let vText = await probe(vURL, mode: "text", targets: targets) else { return nil }
            return HLS.duration(of: vText).map(Measurement.seconds)
        }
    }

    /// One selectable quality of a detected stream, for the picker.
    struct StreamQuality: Identifiable {
        let id = UUID()
        let stream: DetectedStream
        /// "720p", or "Auto" when the stream has a single quality.
        let badge: String
        let label: String
        let detail: String?
        let height: Int?
    }

    private static let heightNames: [Int: String] = [
        2160: "4K Ultra HD", 1440: "2K Quad HD", 1080: "Full HD", 720: "HD", 480: "Standard", 360: "Data saver",
    ]

    /// What the page's streams offer, so the user can pick: an HLS master playlist is opened and each of its
    /// variants listed by height; other streams get one row with their length or size. Ads are left out.
    func qualityChoices(among streams: [DetectedStream]) async -> [StreamQuality] {
        let clean = streams.filter { !DetectedStream.looksLikeAd($0.url) }
        var rows: [StreamQuality] = []
        for stream in (clean.isEmpty ? streams : clean) {
            guard let url = URL(string: stream.url) else { continue }
            var targets: [FetchTarget] = []
            if let frame = stream.frame, let view = frame.webView { targets.append(FetchTarget(webView: view, frame: frame)) }
            targets.append(FetchTarget(webView: webView, frame: nil))
            if stream.type == .hls || stream.type == .other,
               let text = await probe(url, mode: "text", targets: targets), HLS.isMaster(text) {
                var seen = Set<Int>()
                let variants = HLS.variants(in: text).sorted { ($0.height ?? 0, $0.bandwidth) > ($1.height ?? 0, $1.bandwidth) }
                for v in variants {
                    guard let h = v.height, seen.insert(h).inserted else { continue }
                    let rate = v.bandwidth > 0 ? String(format: "%.1f Mbps", Double(v.bandwidth) / 1_000_000) : nil
                    rows.append(StreamQuality(stream: stream, badge: "\(h)p", label: Self.heightNames[h] ?? "Video",
                                              detail: rate, height: h))
                }
                if !seen.isEmpty { continue }
            }
            var detail: String?
            switch await measure(stream) {
            case .seconds(let d): detail = d > 0 ? Self.clockText(d) : nil
            case .bytes(let b): detail = ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
            case nil: break
            }
            let name = stream.type == .direct ? "Video file" : stream.type.rawValue
            rows.append(StreamQuality(stream: stream, badge: "Auto", label: name, detail: detail, height: nil))
        }
        return rows
    }

    private static func clockText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// What the page's <video> elements play right now, in every frame that reported a stream (for the log):
    /// a "blob:" source with a long duration means the video is fed by script (MSE).
    private func pagePlayers() async -> String {
        let script = """
        return Array.from(document.querySelectorAll('video')).map(v =>
            (v.currentSrc || v.src || '(none)').slice(0, 120) + ' ' + (isFinite(v.duration) ? Math.round(v.duration) + 's' : '?') +
            (v.paused ? ' paused' : ' playing')).join(' | ');
        """
        var frames: [FetchTarget] = [FetchTarget(webView: webView, frame: nil)]
        for s in selectedTab.detectedStreams {
            if let f = s.frame, let v = f.webView, !frames.contains(where: { $0.frame === f }) { frames.append(FetchTarget(webView: v, frame: f)) }
        }
        var parts: [String] = []
        for target in frames.prefix(6) {
            let text: String? = await withCheckedContinuation { continuation in
                target.webView.callAsyncJavaScript(script, arguments: [:], in: target.frame, in: .defaultClient) { result in
                    continuation.resume(returning: (try? result.get()) as? String)
                }
            }
            if let text, !text.isEmpty { parts.append((target.frame?.request.url?.host ?? "page") + ": " + text) }
        }
        return parts.isEmpty ? "none found" : parts.joined(separator: " || ")
    }

    /// Ads run 5–30 s (some 60 s); a stream shorter than this is not taken as the main video on its own.
    static let minimumMainLength = 75.0
    /// Video ad files are a few MB; a direct file of unknown length above this is taken as the video.
    static let minimumMainBytes = 25.0 * 1_048_576

    /// What the Download button found on the page.
    struct MainStreamChoice {
        let stream: DetectedStream
        /// Seconds of the chosen stream, when known.
        let duration: Double?
        /// Streams left out as ads (short, small, or an ad server's address).
        let skippedAds: Int
    }

    /// The stream that is the actual video, not an ad. Pre-roll ads play first in the same player, so their
    /// streams look alike; what differs is length. Every stream on the page is measured (playlists by their
    /// segments, direct files by the page's own player or their size) and the longest wins. Each step is written
    /// to the stream-check log so a wrong pick on a given site can be looked into.
    /// `log`: the caller's entry to add to; without one the check writes its own.
    func mainStream(among streams: [DetectedStream], log shared: StreamCheckLog? = nil) async -> MainStreamChoice? {
        let log = shared ?? StreamCheckLog()
        if shared == nil { log.add("Page: \(currentURL?.absoluteString ?? "-")") }
        log.add("Players: \(await pagePlayers())")
        let clean = streams.filter { !DetectedStream.looksLikeAd($0.url) }
        let pool = clean.isEmpty ? streams : clean
        let filteredByURL = streams.count - clean.count
        for s in streams where !clean.contains(where: { $0 === s }) { log.add("ad address, skipped: \(s.url)") }
        // `.other` streams are asked what they are when measured; those that turn out to be neither
        // a playlist nor a video are left out below.
        let candidates = Array(pool.sorted { $0.foundAt < $1.foundAt }.suffix(12))

        var timed: [(stream: DetectedStream, seconds: Double)] = []
        var sized: [(stream: DetectedStream, bytes: Double)] = []
        var unmeasured: [DetectedStream] = []
        for stream in candidates {
            let m = await measure(stream)
            if stream.type == .other {
                log.add("not a playlist or video, skipped: \(stream.url)")
                continue
            }
            switch m {
            case .seconds(let d)?: timed.append((stream, d))
            case .bytes(let b)?: sized.append((stream, b))
            case nil: unmeasured.append(stream)
            }
            log.add("\(stream.type.rawValue) \(m.map(StreamCheckLog.describe) ?? "not measurable"): \(stream.url)")
        }

        func choose(_ stream: DetectedStream, _ duration: Double?, _ why: String) -> MainStreamChoice {
            let skipped = filteredByURL + timed.filter { $0.stream !== stream && $0.seconds < Self.minimumMainLength }.count
                + sized.filter { $0.stream !== stream && $0.bytes < Self.minimumMainBytes }.count
            log.add("CHOSEN (\(why)): \(stream.url)")
            if shared == nil { log.save() }
            return MainStreamChoice(stream: stream, duration: duration, skippedAds: skipped)
        }

        // 1. A stream long enough to be the video: the longest one.
        if let longest = timed.max(by: { $0.seconds < $1.seconds }), longest.seconds >= Self.minimumMainLength {
            return choose(longest.stream, longest.seconds, "longest, \(StreamCheckLog.clock(longest.seconds))")
        }
        // 2. A direct file too big to be an ad.
        if let biggest = sized.max(by: { $0.bytes < $1.bytes }), biggest.bytes >= Self.minimumMainBytes {
            return choose(biggest.stream, nil, "largest file")
        }
        // 3. Something that could not be measured (live, or the site refused the check): the most recent one,
        //    since the video starts after its ads.
        if let latest = unmeasured.max(by: { $0.foundAt < $1.foundAt }) {
            return choose(latest, nil, "not measurable, most recent")
        }
        // 4. Only short clips: return the longest; the button refuses it and explains.
        if let longest = timed.max(by: { $0.seconds < $1.seconds }) {
            return choose(longest.stream, longest.seconds, "only short clips")
        }
        if let biggest = sized.max(by: { $0.bytes < $1.bytes }) {
            // A small file of unknown length: treat as a short clip so it isn't saved by surprise.
            return choose(biggest.stream, 0, "only small files")
        }
        log.add("CHOSEN: nothing")
        if shared == nil { log.save() }
        return nil
    }

    /// One press of the browser's Download button: known video sites go to yt-dlp as a page link; elsewhere the
    /// streams the page loaded are gathered (including ones the sniffer missed) and the main one is chosen.
    /// Every press is written to stream-check.log with the path taken.
    func chooseDownload(knownVideoPage: Bool) async -> DownloadDecision {
        let log = StreamCheckLog()
        defer { log.save() }
        log.add("Page: \(currentURL?.absoluteString ?? "-")")
        if knownVideoPage {
            log.add("DECISION: \(DownloadDecision.pageLink.logName) (known video site)")
            return .pageLink
        }
        let recovered = await recoverStreams()
        log.add("Recovered from the page: \(recovered)")
        let streams = detectedStreams
        let choice = streams.isEmpty ? nil : await mainStream(among: streams, log: log)
        let decision = DownloadDecision(choice)
        log.add("DECISION: \(decision.logName)")
        return decision
    }

    /// "Use page link" from the Download button's menu: the person chose to send the page address to yt-dlp.
    func notePageLinkByHand() {
        let log = StreamCheckLog()
        log.add("Page: \(currentURL?.absoluteString ?? "-")")
        log.add("DECISION: \(DownloadDecision.pageLink.logName) (chosen by hand)")
        log.save()
    }

    /// Looks again in the page and each of its frames for streams the sniffer did not report: what the
    /// <video>/<audio> elements play (http only, not blob:) and the playlists in the page's Resource Timing list.
    /// They are added like any detected stream. Returns how many were new.
    @discardableResult
    func recoverStreams() async -> Int {
        let tab = selectedTab
        let before = tab.detectedStreams.count
        var targets = [FetchTarget(webView: tab.webView, frame: nil)]
        for frame in tab.knownFrames where frame.webView === tab.webView {
            targets.append(FetchTarget(webView: tab.webView, frame: frame))
        }
        for target in targets {
            let found: [RecoveredSource] = await withCheckedContinuation { continuation in
                target.webView.callAsyncJavaScript(Self.recoverScript, arguments: [:], in: target.frame, in: .defaultClient) { result in
                    let rows = (try? result.get()) as? [[String: Any]] ?? []
                    continuation.resume(returning: rows.compactMap { row in
                        (row["url"] as? String).map {
                            RecoveredSource(url: $0, page: row["page"] as? String, title: row["title"] as? String ?? "",
                                            kind: row["kind"] as? String ?? "")
                        }
                    })
                }
            }
            for entry in found {
                handleDetectedStream(url: entry.url, pageURL: entry.page ?? tab.currentURL?.absoluteString ?? "",
                                     title: entry.title, kind: entry.kind, frame: target.frame, in: tab.webView)
            }
        }
        return tab.detectedStreams.count - before
    }

    private static let recoverScript = #"""
    const out = [];
    const page = location.href, title = document.title || '';
    for (const el of document.querySelectorAll('video, audio, source')) {
        const s = el.currentSrc || el.src;
        if (s && /^https?:/i.test(s)) out.push({ url: s, kind: '', page, title });
    }
    try {
        const skip = /\.(ts|m4s|aac|m4a|vtt|webvtt|key|jpg|jpeg|png|gif|webp|js|css)$/;
        for (const e of performance.getEntriesByType('resource')) {
            const path = e.name.toLowerCase().split('#')[0].split('?')[0];
            if (!/^https?:/.test(e.name)) continue;
            if (path.indexOf('.m3u8') !== -1) out.push({ url: e.name, kind: 'hls', page, title });
            else if (path.indexOf('.mpd') !== -1) out.push({ url: e.name, kind: 'dash', page, title });
            else if ((e.initiatorType === 'xmlhttprequest' || e.initiatorType === 'fetch') && !skip.test(path)
                     && /\/(hls|dash)\/|playlist|manifest/.test(path)) out.push({ url: e.name, kind: '', page, title });
        }
    } catch (e) {}
    return out;
    """#

    // MARK: Queue engine

    /// Run a Downloads-list item through the page: HLS is fetched piece by piece and joined; other files are
    /// downloaded with the page's cookies and Referer.
    func download(_ item: DownloadItem) async throws -> String {
        guard let url = URL(string: item.url) else { throw CaptureError.notPlaylist }
        if !item.isHLS && !MediaSniff.isHLS(mime: nil, url: url) {
            do {
                return try await downloadDirect(item, url: url)
            } catch CaptureError.isPlaylist {
                // The server answered with a playlist; join it instead.
            }
        }
        let name = Self.fileName(from: item.title ?? "", fallback: url.deletingPathExtension().lastPathComponent, ext: "mp4")
        let output = try await runHLSCapture(url, pageURL: item.pageURL, frame: item.browserFrame as? WKFrameInfo,
                                             name: name, outputDir: item.outputDir,
                                             maxHeight: item.hlsHeight,
                                             progress: { [weak item] done, total in
            item?.progress = Double(done) / Double(max(total, 1)) * 95
            item?.downloadedSize = "\(done)"
            item?.totalSize = "\(total) parts"
        }, merging: { [weak item] in
            item?.status = .postProcessing
        })
        return output.path
    }

    // MARK: HLS capture

    func runHLSCapture(_ url: URL, pageURL: String?, frame: WKFrameInfo?, name: String, outputDir: String,
                       maxHeight: Int? = nil, progress: (Int, Int) -> Void, merging: () -> Void) async throws -> URL {
        guard let ffmpeg = Self.ffmpegURL() else { throw CaptureError.noFFmpeg }

        // The original player frame first (exactly what the site expects), then a hidden copy of the page that
        // lives as long as this capture, so leaving or clearing the page in the browser doesn't stop it.
        var targets: [FetchTarget] = []
        if let frame { targets.append(FetchTarget(webView: webView, frame: frame)) }
        var context: CaptureContext?
        if let page = pageURL.flatMap(URL.init(string:)), page.scheme?.hasPrefix("http") == true {
            let ctx = CaptureContext(dataStore: webView.configuration.websiteDataStore, userAgent: webView.customUserAgent)
            if (try? await ctx.open(as: page)) != nil {
                context = ctx
                targets.append(FetchTarget(webView: ctx.webView, frame: nil))
            }
        }
        if targets.isEmpty { targets.append(FetchTarget(webView: webView, frame: nil)) }
        let route = FetchRoute(targets)
        defer { withExtendedLifetime(context) {} }

        let first = String(decoding: try await fetchData(url, what: "the playlist", route: route), as: UTF8.self)
        guard HLS.isPlaylist(first) else { throw CaptureError.notPlaylist }

        // Master playlist: take the best variant, plus its separate audio track if it has one.
        var tracks: [(url: URL, text: String)] = []
        if HLS.isMaster(first) {
            guard let variant = HLS.bestVariant(in: first, maxHeight: maxHeight), let vURL = URL(string: variant.uri, relativeTo: url)?.absoluteURL else {
                throw CaptureError.notPlaylist
            }
            tracks.append((vURL, String(decoding: try await fetchData(vURL, what: "the video playlist", route: route), as: UTF8.self)))
            if let group = variant.audioGroup, let a = HLS.audioURI(in: first, group: group),
               let aURL = URL(string: a, relativeTo: url)?.absoluteURL {
                tracks.append((aURL, String(decoding: try await fetchData(aURL, what: "the audio playlist", route: route), as: UTF8.self)))
            }
        } else {
            tracks.append((url, first))
        }
        if tracks.contains(where: { HLS.isDRMProtected($0.text) }) { throw CaptureError.drm }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ydl-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let total = tracks.reduce(0) { $0 + HLS.resources(in: $1.text).count }
        var done = 0
        var localPlaylists: [URL] = []

        for (index, track) in tracks.enumerated() {
            let dir = work.appendingPathComponent("t\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let resources = HLS.resources(in: track.text)
            let encrypted = resources.contains { $0.kind == .key }
            var names: [String: String] = [:]
            for (n, res) in resources.enumerated() {
                switch res.kind {
                case .key: names[res.uri] = "key\(n).key"
                case .map: names[res.uri] = "init\(n).mp4"
                case .segment:
                    let ext = URL(string: res.uri)?.pathExtension.lowercased() ?? ""
                    names[res.uri] = String(format: "seg%05d.", n) + (["m4s", "mp4", "aac", "m4a"].contains(ext) ? ext : "ts")
                }
            }

            // A few requests at a time, like a player buffering ahead. A sliding window: a new piece starts as
            // soon as one finishes, instead of each batch waiting for its slowest piece. Child tasks inherit
            // cancellation, and a failure stops the others before the work folder is deleted.
            let jobs = resources.map { (resource: $0, file: dir.appendingPathComponent(names[$0.uri]!)) }
            let base = track.url, strip = !encrypted
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0, inFlight = 0
                while true {
                    while inFlight < Self.captureConcurrency, next < jobs.count {
                        let job = jobs[next]
                        next += 1
                        group.addTask {
                            try await self.saveResource(job.resource, base: base, to: job.file, route: route, stripFakeHeader: strip)
                        }
                        inFlight += 1
                    }
                    guard inFlight > 0 else { break }
                    try await group.next()
                    inFlight -= 1
                    done += 1
                    progress(done, total)
                }
            }

            let playlist = dir.appendingPathComponent("local.m3u8")
            try HLS.localPlaylist(track.text, names: names).write(to: playlist, atomically: true, encoding: .utf8)
            localPlaylists.append(playlist)
        }

        try Task.checkCancellation()
        merging()
        let output = uniqueDestination(for: name, in: outputDir)
        var args = ["-y", "-loglevel", "error"]
        for p in localPlaylists {
            args += ["-allowed_extensions", "ALL", "-protocol_whitelist", "file,crypto,data", "-i", p.path]
        }
        if localPlaylists.count > 1 { args += ["-map", "0:v:0?", "-map", "1:a:0?"] }
        args += ["-c", "copy", "-bsf:a", "aac_adtstoasc", "-movflags", "+faststart", output.path]
        let result = try await ProcessRunner.run(executable: ffmpeg, arguments: args)
        guard result.isSuccess else {
            try? FileManager.default.removeItem(at: output)
            let message = (result.stderrString ?? "").split(separator: "\n").last.map(String.init) ?? "exit code \(result.exitCode)"
            throw CaptureError.ffmpeg(message)
        }
        return output
    }

    private func saveResource(_ res: HLS.Resource, base: URL, to file: URL, route: FetchRoute, stripFakeHeader: Bool) async throws {
        guard let url = URL(string: res.uri, relativeTo: base)?.absoluteURL else { return }
        let data = try await fetchData(url, what: res.kind == .key ? "the decryption key" : "a video segment", route: route)
        let strip = res.kind == .segment && stripFakeHeader
        // Segments are megabytes each: scanning and writing them off the main thread keeps the UI smooth.
        try await Task.detached(priority: .utility) {
            try (strip ? HLS.strippingFakeHeader(data) : data).write(to: file)
        }.value
    }

    /// Simultaneous page requests while saving an HLS stream.
    private static let captureConcurrency = 6

    /// Base64 from the page is decoded off the main thread (segments are megabytes each).
    nonisolated private static func decode(_ base64: String) async -> Data? {
        await Task.detached(priority: .utility) { Data(base64Encoded: base64) }.value
    }

    // MARK: Helpers

    nonisolated static func ffmpegURL() -> URL? {
        let custom = UserDefaults.standard.string(forKey: "ffmpegPath") ?? ""
        let candidates = [
            custom,
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Pathfinder/bin/ffmpeg").path ?? "",
            "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", NSHomeDirectory() + "/.local/bin/ffmpeg",
        ]
        return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    nonisolated static func fileName(from title: String, fallback: String, ext: String) -> String {
        var base = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = fallback.isEmpty ? "video" : fallback }
        base = base.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r")).joined(separator: " ")
        if base.count > 120 { base = String(base.prefix(120)) }
        return "\(base).\(ext)"
    }
}
