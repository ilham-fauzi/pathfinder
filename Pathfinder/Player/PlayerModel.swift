import AVFoundation
import AppKit
import Observation
import SwiftUI

/// A file in the playlist. `realExtension` is set when the name lies about the content: the player then opens it
/// through a link that has the right extension, and the file itself stays untouched.
struct PlayerRequest: Codable, Hashable, Identifiable {
    var path: String
    var realExtension: String?
    var badge: String?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    /// "MP4", or "Disguised · MKV" for a file with a false extension.
    var kind: String { badge ?? (path as NSString).pathExtension.uppercased() }
}

enum PlayerStatus: Equatable {
    /// Nothing in the playlist is playing yet.
    case idle
    case loading, ready
    /// AVFoundation cannot decode it (MKV, WebM…).
    case unsupported
    case failed(String)

    /// A file that can't be played: the screen needs a way out (back, next, the playlist).
    var isProblem: Bool {
        switch self {
        case .unsupported, .failed: return true
        default: return false
        }
    }
}

/// The hold-to-scrub state shown in the HUD.
struct ScrubInfo: Equatable {
    var forward: Bool
    var speedIndex: Int
    /// The user picked the level with ↑ / ↓, so it no longer climbs by itself.
    var locked = false
    /// Started with the ⏪ ⏩ buttons: it keeps going until the user changes or stops it.
    var sticky = false
    /// Seconds travelled since the scan began.
    var delta = 0.0
    var speed: Int { HoldRamp.speeds[speedIndex] }
    /// Backward, or too fast for the player to play at: the picture is moved by seeking, frame to frame.
    var stepped: Bool { !forward || speed >= 32 }
    /// Audio is muted from 8× up and while rewinding.
    var muted: Bool { !forward || speed >= 8 }
}

struct UndoInfo: Equatable {
    var from: Double
    var to: Double
}

/// A line under the playlist about files that were skipped.
struct PlayerNotice: Equatable {
    var text: String
    var offersSettings: Bool
}

/// The one player of the app: it keeps playing state and the playlist while the user moves between tabs.
@Observable
@MainActor
final class PlayerModel {
    enum Arrow { case left, right, up, down }

    let player = AVPlayer()
    let settings: SettingsStore
    /// Brings the Player tab to the front (set by the app).
    @ObservationIgnored var showTab: () -> Void = {}

    private(set) var status = PlayerStatus.idle
    private(set) var playlist: [PlayerRequest] = []
    private(set) var currentPath: String?
    private(set) var title = ""
    private(set) var badge: String?
    private(set) var hasVideo = true
    /// Width over height of the picture (rotation applied); nil for audio.
    private(set) var videoAspect: Double?
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var isPlaying = false
    /// The user's playback speed (what "normal" means after a hold ends).
    private(set) var rate: Float = 1
    private(set) var volumePercent = UserDefaults.standard.object(forKey: "playerVolume") as? Double ?? 100
    private(set) var isMuted = false
    private(set) var scrub: ScrubInfo?
    private(set) var volumeHUD: Int?
    private(set) var flash: String?
    private(set) var undo: UndoInfo?
    private(set) var controlsVisible = true
    private(set) var isScanning = false
    var notice: PlayerNotice?
    var isFullScreen = false
    /// The playlist slides in beside the picture; hiding it gives the video the full width.
    private(set) var showPlaylist = UserDefaults.standard.object(forKey: "playerShowPlaylist") as? Bool ?? true
    /// The floating playlist is open over the picture (only used while the playlist hides during playback).
    var playlistPeek = false
    /// The playlist is out of the layout while a video plays; it floats over the picture when asked for.
    var floatsPlaylist: Bool { settings.playerAutoHidePlaylist && status != .idle && !status.isProblem }
    /// Whether the playlist can be seen right now, docked or floating.
    var playlistVisible: Bool { floatsPlaylist ? playlistPeek : (showPlaylist || status == .idle || status.isProblem) }
    /// True while the seek bar is being dragged, so the clock does not fight the thumb.
    var userSeeking = false

    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    private static let step = 30.0

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var seekKey: Arrow?
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var holdOrigin: (position: Double, wasPlaying: Bool)?
    @ObservationIgnored private var volumeKey: Arrow?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var volumeHUDTask: Task<Void, Never>?
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    /// The pointer rests on the control strip: it stays visible, as in a streaming player.
    @ObservationIgnored var pointerOverControls = false
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var seekDownAt = Date.distantPast

    init(settings: SettingsStore) {
        self.settings = settings
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    var current: PlayerRequest? { playlist.first { $0.path == currentPath } }

    // MARK: Playlist

    /// Scan what the user picked (files, folders) and add the videos found. `playNow` starts the first one;
    /// otherwise they are queued behind whatever is playing.
    func addURLs(_ urls: [URL], playNow: Bool) {
        guard !urls.isEmpty else { return }
        let rules = settings.disguiseRules
        isScanning = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { PlayerIngest.scan(urls, rules: rules) }.value
            isScanning = false
            if urls.count == 1, result.entries.isEmpty, let reason = result.rejections.first {
                PlayerLauncher.explain(reason, for: urls[0], model: self)
                return
            }
            let fresh = result.entries.filter { entry in !playlist.contains { $0.path == entry.path } }
            playlist.append(contentsOf: fresh)
            noticeAboutSkipped(result, added: result.entries.count)
            // Files added while a video plays: show the list so the user sees what arrived.
            if !fresh.isEmpty, floatsPlaylist { playlistPeek = true }
            if let first = result.entries.first, playNow || currentPath == nil {
                play(playlist.first { $0.path == first.path } ?? first)
            }
        }
    }

    /// A finished download: the app knows the real type when it saved the file under a false extension.
    func openDownloaded(path: String, realExtension: String?) {
        guard let realExtension else { addURLs([URL(fileURLWithPath: path)], playNow: true); return }
        let entry = PlayerRequest(path: path, realExtension: realExtension, badge: "Disguised · \(realExtension.uppercased())")
        if !playlist.contains(where: { $0.path == path }) { playlist.append(entry) }
        play(entry)
    }

    private func noticeAboutSkipped(_ result: IngestResult, added: Int) {
        guard result.skipped > 0 else { notice = nil; return }
        var parts: [String] = []
        if added > 0 { parts.append("Added \(added)") }
        if result.needsSetting > 0 {
            parts.append("\(result.needsSetting) skipped: not video by their extension")
        }
        if result.notVideo > 0 { parts.append("\(result.notVideo) skipped: not a video") }
        if result.missing > 0 { parts.append("\(result.missing) missing") }
        notice = PlayerNotice(text: parts.joined(separator: " · "), offersSettings: result.needsSetting > 0)
    }

    func remove(_ entry: PlayerRequest) {
        let wasCurrent = entry.path == currentPath
        let next = adjacent(1) ?? adjacent(-1)
        playlist.removeAll { $0.path == entry.path }
        guard wasCurrent else { return }
        if let next { play(next) } else { clear() }
    }

    func clear() {
        closeCurrent()
        playlist = []
        notice = nil
    }

    /// Leaves the file on screen (one that can't play, or any other): back to the start screen, playlist kept.
    func closeCurrent() {
        loadToken &+= 1
        releaseKeys()
        cancelScan()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentPath = nil
        status = .idle
        isPlaying = false
        position = 0
        duration = 0
        title = ""
        badge = nil
        videoAspect = nil
    }

    var hasNext: Bool { adjacent(1) != nil }

    /// Other media next to the playing file, for next / previous.
    private func adjacent(_ offset: Int) -> PlayerRequest? {
        guard let index = playlist.firstIndex(where: { $0.path == currentPath }) else { return nil }
        let target = index + offset
        return playlist.indices.contains(target) ? playlist[target] : nil
    }

    func next() { if let entry = adjacent(1) { play(entry) } }

    /// Past the first 3 seconds, "previous" restarts the video; right at the start it goes to the earlier file.
    func previous() {
        if position > 3 || adjacent(-1) == nil { seek(to: 0) } else if let entry = adjacent(-1) { play(entry) }
    }

    // MARK: Loading

    func play(_ entry: PlayerRequest) {
        showTab()
        Task { await load(entry) }
    }

    private func load(_ entry: PlayerRequest) async {
        loadToken &+= 1
        let token = loadToken
        releaseKeys()
        cancelScan()
        player.pause()
        currentPath = entry.path
        status = .loading
        title = entry.name
        badge = entry.badge
        position = 0
        duration = 0
        undo = nil
        videoAspect = nil

        var url = URL(fileURLWithPath: entry.path)
        if let real = entry.realExtension, url.pathExtension.lowercased() != real {
            guard let link = FileOpener.link(to: url, ext: real) else {
                status = .failed("The file could not be opened.")
                return
            }
            url = link
        }

        let asset = AVURLAsset(url: url)
        let length: Double
        let video: Bool
        var aspect: Double?
        do {
            let playable = try await asset.load(.isPlayable)
            guard token == loadToken else { return }
            guard playable else { status = .unsupported; return }
            length = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .video)
            video = !tracks.isEmpty
            if let track = tracks.first {
                let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
                if size.height != 0 { aspect = abs(size.width / size.height) }
            }
        } catch {
            if token == loadToken { status = .failed(error.localizedDescription) }
            return
        }
        guard token == loadToken else { return }

        let item = AVPlayerItem(asset: asset)
        duration = length.isFinite ? length : 0
        hasVideo = video
        videoAspect = aspect
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        }
        applyVolume()
        status = .ready
        play()
        pokeControls()
    }

    private func tick(_ seconds: Double) {
        // While rewinding or dragging the bar, position is set by our own seeks.
        guard status == .ready, !userSeeking, scrub?.stepped != true, seconds.isFinite else { return }
        position = seconds
        if player.timeControlStatus == .paused, scrub == nil { isPlaying = false }
        if duration <= 0, let d = player.currentItem?.duration.seconds, d.isFinite { duration = d }
    }

    private func finished() {
        cancelScan()
        if let entry = adjacent(1) { play(entry) } else {
            isPlaying = false
            controlsVisible = true
        }
    }

    /// The user left the Player tab: stop the sound but keep the place.
    func leaveTab() {
        releaseKeys()
        if isPlaying { pause() }
    }

    // MARK: Transport

    func play() {
        player.rate = rate
        isPlaying = true
        pokeControls()
    }

    func pause() {
        if scrub?.sticky == true { finishScrub(then: .pause); return }
        player.pause()
        isPlaying = false
        controlsVisible = true
    }

    /// Space, the play button and a tap on the picture. During a button scan it stops the scan and pauses there.
    func togglePlay() {
        if let scan = scrub {
            if scan.sticky { finishScrub(then: .pause) }
            return
        }
        isPlaying ? pause() : play()
    }

    func setRate(_ value: Float) {
        rate = value
        if isPlaying { player.rate = value }
        showFlash(String(format: "%g×", value))
    }

    func stepRate(_ direction: Int) {
        let index = Self.rates.firstIndex(of: rate) ?? 2
        setRate(Self.rates[min(max(index + direction, 0), Self.rates.count - 1)])
    }

    func seek(to seconds: Double, precise: Bool = true) {
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        position = target
        let time = CMTime(seconds: target, preferredTimescale: 600)
        let tolerance = precise ? CMTime.zero : CMTime.positiveInfinity
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func seek(toFraction fraction: Double, precise: Bool) {
        seek(to: min(max(fraction, 0), 1) * duration, precise: precise)
    }

    func skip(by seconds: Double) {
        seek(to: position + seconds)
        showFlash(seconds > 0 ? "+\(Int(seconds)) s" : "−\(Int(-seconds)) s")
    }

    // MARK: Volume

    func adjustVolume(by delta: Double) {
        volumePercent = min(max(volumePercent + delta, 0), 100)
        if volumePercent > 0 { isMuted = false }
        applyVolume()
        UserDefaults.standard.set(volumePercent, forKey: "playerVolume")
        volumeHUD = Int(volumePercent.rounded())
        volumeHUDTask?.cancel()
        volumeHUDTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            if !Task.isCancelled { self?.volumeHUD = nil }
        }
    }

    /// Set from the volume bar next to the mute button.
    func setVolume(_ percent: Double) {
        volumePercent = min(max(percent, 0), 100)
        isMuted = false
        applyVolume()
        UserDefaults.standard.set(volumePercent, forKey: "playerVolume")
    }

    func toggleMute() {
        isMuted.toggle()
        applyVolume()
        showFlash(isMuted ? "Muted" : "Sound on")
    }

    /// The slider position maps to amplitude with a square curve, so equal steps sound about equally loud.
    private func applyVolume() {
        player.volume = Float(pow(volumePercent / 100, 2))
        player.isMuted = isMuted || (scrub?.muted ?? false)
    }

    // MARK: Keyboard

    func handle(_ press: KeyPress) -> KeyPress.Result {
        let arrow: Arrow?
        switch press.key {
        case .leftArrow: arrow = .left
        case .rightArrow: arrow = .right
        case .upArrow: arrow = .up
        case .downArrow: arrow = .down
        default: arrow = nil
        }
        if let arrow {
            let sideways = arrow == .left || arrow == .right
            if press.phase == .down {
                if sideways, press.modifiers.contains(.command) {
                    arrow == .right ? next() : previous()
                } else if sideways, press.modifiers.contains(.shift) {
                    skip(by: arrow == .right ? Self.step : -Self.step)
                } else {
                    arrowDown(arrow)
                }
            } else if press.phase == .up {
                arrowUp(arrow)
            }
            return .handled
        }

        let handledKeys: Set<String> = [" ", "m", "f", "n", "p", "l", "[", "]"]
        let isDelete = press.key == .delete
        guard isDelete || handledKeys.contains(press.characters.lowercased()) else { return .ignored }
        guard press.phase == .down else { return .handled }
        if isDelete { undoJump(); return .handled }
        switch press.characters.lowercased() {
        case " ": togglePlay()
        case "m": toggleMute()
        case "f": toggleFullScreen()
        case "n": next()
        case "p": previous()
        case "l": togglePlaylist()
        case "[": stepRate(-1)
        default: stepRate(1)
        }
        return .handled
    }

    private func arrowDown(_ key: Arrow) {
        pokeControls()
        switch key {
        case .left, .right:
            guard seekKey == nil else { return }
            // A key press ends a scan started with the buttons and goes on at normal speed.
            if scrub?.sticky == true { finishScrub(then: .play) }
            seekKey = key
            let since = Date()
            seekDownAt = since
            seekTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(HoldRamp.holdDelay))
                guard !Task.isCancelled else { return }
                await self?.runScan(forward: key == .right, since: since, sticky: false)
            }
        case .up, .down:
            if let scan = scrub, !scan.sticky { shiftScrubLevel(key == .up ? 1 : -1) } else { startVolume(key) }
        }
    }

    private func arrowUp(_ key: Arrow) {
        switch key {
        case .left, .right:
            guard seekKey == key else { return }
            seekKey = nil
            seekTask?.cancel()
            seekTask = nil
            if scrub != nil { finishScrub() } else if Date().timeIntervalSince(seekDownAt) < HoldRamp.holdDelay {
                let tap = Double(settings.playerTapSeekSeconds)
                skip(by: key == .right ? tap : -tap)
            }
        case .up, .down:
            guard volumeKey == key else { return }
            stopVolume()
        }
    }

    /// Window lost focus mid-press: no key-up will arrive, so end whatever was running.
    func releaseKeys() {
        stopVolume()
        seekKey = nil
        seekTask?.cancel()
        seekTask = nil
        if let scan = scrub, !scan.sticky { finishScrub() }
    }

    // MARK: Scanning

    /// ⏪ / ⏩ buttons: the first click starts at 2×, every further click goes one level faster, a click on the
    /// other button switches direction, and past the top level playback returns to normal.
    func scanStep(forward: Bool) {
        guard status == .ready else { return }
        guard var scan = scrub else {
            scanTask?.cancel()
            scanTask = Task { [weak self] in await self?.runScan(forward: forward, since: nil, sticky: true) }
            return
        }
        guard scan.sticky else { return }
        if scan.forward != forward {
            scan.forward = forward
            scan.speedIndex = 0
        } else if scan.speedIndex + 1 < HoldRamp.speeds.count {
            scan.speedIndex += 1
        } else {
            finishScrub(then: .play)
            return
        }
        scrub = scan
        applyVolume()
    }

    /// Moves through the video faster than playing it. Up to 16× the player's own rate does it; faster, and
    /// rewinding, are series of keyframe seeks (most files can't play in reverse). A held key raises the speed
    /// by the clock; a button scan stays where it is until clicked again.
    private func runScan(forward: Bool, since: Date?, sticky: Bool) async {
        guard status == .ready else { return }
        let ramp = settings.playerHoldRamp
        holdOrigin = (position, isPlaying)
        let start = position
        var cursor = position
        var stepping = false
        scrub = ScrubInfo(forward: forward, speedIndex: 0, sticky: sticky)
        isPlaying = true
        applyVolume()

        while !Task.isCancelled {
            guard var s = scrub else { return }
            if let since, !s.locked, let index = ramp.speedIndex(heldFor: Date().timeIntervalSince(since)) { s.speedIndex = index }
            if s.stepped {
                if !stepping { cursor = position; player.pause(); stepping = true }
                cursor = min(max(cursor + Double(s.speed) * 0.25 * (s.forward ? 1 : -1), 0), max(duration, 0))
                seek(to: cursor, precise: false)
                s.delta = cursor - start
                scrub = s
                applyVolume()
                if s.forward, duration > 0, cursor >= duration - 0.3 {
                    finishScrub(then: .pause)
                    finished()
                    return
                }
                if !s.forward, cursor <= 0 { finishScrub(then: .play); return }
                try? await Task.sleep(for: .milliseconds(250))
            } else {
                if stepping { seek(to: cursor); stepping = false }
                if player.rate != Float(s.speed) { player.rate = Float(s.speed) }
                s.delta = position - start
                scrub = s
                applyVolume()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// ↑ / ↓ while → or ← is held choose the level by hand and stop it from climbing on its own.
    private func shiftScrubLevel(_ direction: Int) {
        guard var s = scrub else { return }
        s.speedIndex = min(max(s.speedIndex + direction, 0), HoldRamp.speeds.count - 1)
        s.locked = true
        scrub = s
        applyVolume()
    }

    private enum After { case restore, play, pause }

    /// Ends a scan: back to what it was before (`restore`), playing, or paused where it stopped.
    private func finishScrub(then after: After = .restore) {
        guard let s = scrub, let origin = holdOrigin else { return }
        scanTask?.cancel()
        scanTask = nil
        scrub = nil
        holdOrigin = nil
        applyVolume()
        switch after {
        case .restore: if origin.wasPlaying { play() } else { pause() }
        case .play: play()
        case .pause: pause()
        }
        if abs(s.delta) >= 5 { showUndo(from: origin.position, to: position) }
    }

    /// Drops a scan without moving or resuming anything (a new file is about to load).
    private func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scrub = nil
        holdOrigin = nil
        applyVolume()
    }

    private func showUndo(from: Double, to: Double) {
        undo = UndoInfo(from: from, to: to)
        undoTask?.cancel()
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self?.undo = nil }
        }
    }

    func undoJump() {
        guard let undo else { return }
        seek(to: undo.from)
        self.undo = nil
        undoTask?.cancel()
    }

    // MARK: Volume keys

    /// A tap changes the volume by 2%; held, it keeps going 1% every 100 ms after a short pause. No acceleration.
    private func startVolume(_ key: Arrow) {
        guard volumeKey == nil else { return }
        volumeKey = key
        let direction: Double = key == .up ? 1 : -1
        adjustVolume(by: direction * 2)
        volumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                self?.adjustVolume(by: direction)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopVolume() {
        volumeKey = nil
        volumeTask?.cancel()
        volumeTask = nil
    }

    // MARK: Chrome

    func showFlash(_ text: String) {
        flash = text
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled { self?.flash = nil }
        }
    }

    /// Show the controls; they hide again after 2.5 s while playing.
    func pokeControls() {
        controlsVisible = true
        hideTask?.cancel()
        guard isPlaying else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled, let self, self.isPlaying, !self.userSeeking, !self.pointerOverControls else { return }
            self.controlsVisible = false
            self.pointerOverControls = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    func togglePlaylist() {
        if floatsPlaylist { playlistPeek.toggle(); return }
        showPlaylist.toggle()
        UserDefaults.standard.set(showPlaylist, forKey: "playerShowPlaylist")
    }

    func toggleFullScreen() {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
    }

    func openExternally() {
        guard let current else { return }
        FileOpener.open(current.path, realExtension: current.realExtension)
    }
}

enum PlayerTime {
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
