import Foundation
import SwiftUI

enum UpdateChannel: String, CaseIterable, Codable {
    case stable, nightly, master
}

enum AppMode: String, CaseIterable, Codable {
    case simple, advanced
}

@Observable
class SettingsStore {
    var ytdlpPath: String {
        get {
            access(keyPath: \.ytdlpPath)
            return UserDefaults.standard.string(forKey: "ytdlpPath") ?? ""
        }
        set {
            withMutation(keyPath: \.ytdlpPath) { UserDefaults.standard.set(newValue, forKey: "ytdlpPath") }
        }
    }
    
    var ffmpegPath: String {
        get {
            access(keyPath: \.ffmpegPath)
            return UserDefaults.standard.string(forKey: "ffmpegPath") ?? ""
        }
        set {
            withMutation(keyPath: \.ffmpegPath) { UserDefaults.standard.set(newValue, forKey: "ffmpegPath") }
        }
    }
    
    var defaultOutputDir: String {
        get {
            access(keyPath: \.defaultOutputDir)
            return UserDefaults.standard.string(forKey: "defaultOutputDir") ?? (NSHomeDirectory() + "/Downloads/Pathfinder")
        }
        set {
            withMutation(keyPath: \.defaultOutputDir) { UserDefaults.standard.set(newValue, forKey: "defaultOutputDir") }
        }
    }
    
    var defaultPresetId: UUID? {
        get { 
            access(keyPath: \.defaultPresetId)
            if let str = UserDefaults.standard.string(forKey: "defaultPresetId") {
                return UUID(uuidString: str)
            }
            return nil
        }
        set {
            withMutation(keyPath: \.defaultPresetId) { UserDefaults.standard.set(newValue?.uuidString, forKey: "defaultPresetId") }
        }
    }
    
    var maxConcurrentDownloads: Int {
        get {
            access(keyPath: \.maxConcurrentDownloads)
            return UserDefaults.standard.integer(forKey: "maxConcurrentDownloads") == 0 ? 3 : UserDefaults.standard.integer(forKey: "maxConcurrentDownloads")
        }
        set {
            withMutation(keyPath: \.maxConcurrentDownloads) { UserDefaults.standard.set(newValue, forKey: "maxConcurrentDownloads") }
        }
    }
    
    var autoStartQueue: Bool {
        get {
            access(keyPath: \.autoStartQueue)
            return UserDefaults.standard.object(forKey: "autoStartQueue") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.autoStartQueue) { UserDefaults.standard.set(newValue, forKey: "autoStartQueue") }
        }
    }
    
    var updateChannel: UpdateChannel {
        get { 
            access(keyPath: \.updateChannel)
            if let str = UserDefaults.standard.string(forKey: "updateChannel"), let channel = UpdateChannel(rawValue: str) {
                return channel
            }
            return .stable
        }
        set {
            withMutation(keyPath: \.updateChannel) { UserDefaults.standard.set(newValue.rawValue, forKey: "updateChannel") }
        }
    }
    
    var autoUpdateYtdlp: Bool {
        get {
            access(keyPath: \.autoUpdateYtdlp)
            return UserDefaults.standard.object(forKey: "autoUpdateYtdlp") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.autoUpdateYtdlp) { UserDefaults.standard.set(newValue, forKey: "autoUpdateYtdlp") }
        }
    }
    
    /// Look for a new Pathfinder release in the background (at most once a day).
    var autoCheckUpdates: Bool {
        get {
            access(keyPath: \.autoCheckUpdates)
            return UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.autoCheckUpdates) { UserDefaults.standard.set(newValue, forKey: "autoCheckUpdates") }
        }
    }

    var appMode: AppMode {
        get {
            access(keyPath: \.appMode)
            if let str = UserDefaults.standard.string(forKey: "appMode"), let mode = AppMode(rawValue: str) {
                return mode
            }
            return .simple
        }
        set {
            withMutation(keyPath: \.appMode) { UserDefaults.standard.set(newValue.rawValue, forKey: "appMode") }
        }
    }
    
    var clipboardMonitoring: Bool {
        get {
            access(keyPath: \.clipboardMonitoring)
            return UserDefaults.standard.object(forKey: "clipboardMonitoring") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.clipboardMonitoring) { UserDefaults.standard.set(newValue, forKey: "clipboardMonitoring") }
        }
    }
    
    var showMenuBarExtra: Bool {
        get {
            access(keyPath: \.showMenuBarExtra)
            return UserDefaults.standard.object(forKey: "showMenuBarExtra") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.showMenuBarExtra) { UserDefaults.standard.set(newValue, forKey: "showMenuBarExtra") }
        }
    }
    
    /// How finished video/audio files are named on disk.
    var fileNaming: FileNaming {
        get {
            access(keyPath: \.fileNaming)
            return FileNaming(rawValue: UserDefaults.standard.string(forKey: "fileNaming") ?? "") ?? .original
        }
        set {
            withMutation(keyPath: \.fileNaming) { UserDefaults.standard.set(newValue.rawValue, forKey: "fileNaming") }
        }
    }

    /// Save finished video/audio files with a random extension from `disguiseExtensions`.
    var disguiseExtension: Bool {
        get {
            access(keyPath: \.disguiseExtension)
            return UserDefaults.standard.bool(forKey: "disguiseExtension")
        }
        set {
            withMutation(keyPath: \.disguiseExtension) { UserDefaults.standard.set(newValue, forKey: "disguiseExtension") }
        }
    }

    /// Comma-separated extensions to pick from, e.g. "jpg, png, dmg".
    var disguiseExtensions: String {
        get {
            access(keyPath: \.disguiseExtensions)
            return UserDefaults.standard.string(forKey: "disguiseExtensions") ?? FileNamer.defaultDisguiseExtensions
        }
        set {
            withMutation(keyPath: \.disguiseExtensions) { UserDefaults.standard.set(newValue, forKey: "disguiseExtensions") }
        }
    }

    /// Show downloads under a neutral name ("Video #3F9A") in the app, tray and notifications.
    /// Only the display changes: files are still saved under their real title.
    var maskDownloadTitles: Bool {
        get {
            access(keyPath: \.maskDownloadTitles)
            return UserDefaults.standard.bool(forKey: "maskDownloadTitles")
        }
        set {
            withMutation(keyPath: \.maskDownloadTitles) { UserDefaults.standard.set(newValue, forKey: "maskDownloadTitles") }
        }
    }

    var showNotifications: Bool {
        get {
            access(keyPath: \.showNotifications)
            return UserDefaults.standard.object(forKey: "showNotifications") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.showNotifications) { UserDefaults.standard.set(newValue, forKey: "showNotifications") }
        }
    }
    
    /// Show the video thumbnail in the video info box. Stored property so SwiftUI
    /// observes changes immediately; persisted to UserDefaults.
    var showThumbnail: Bool = UserDefaults.standard.object(forKey: "showThumbnail") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showThumbnail, forKey: "showThumbnail") }
    }

    /// Search engine for text typed in the browser's address bar (see `SearchEngine`).
    var browserSearchEngine: String = UserDefaults.standard.string(forKey: "browserSearchEngine") ?? SearchEngine.brave.rawValue {
        didSet { UserDefaults.standard.set(browserSearchEngine, forKey: "browserSearchEngine") }
    }

    /// Player: the playlist stays out of the way while a video plays and slides over the picture on request.
    var playerAutoHidePlaylist: Bool = UserDefaults.standard.object(forKey: "playerAutoHidePlaylist") as? Bool ?? true {
        didSet { UserDefaults.standard.set(playerAutoHidePlaylist, forKey: "playerAutoHidePlaylist") }
    }

    /// Experimental: show the Browser tab.
    var showBrowserTab: Bool = UserDefaults.standard.object(forKey: "showBrowserTab") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showBrowserTab, forKey: "showBrowserTab") }
    }

    // MARK: Player

    /// Play finished downloads in the built-in player instead of the system's default app.
    var useInternalPlayer: Bool = UserDefaults.standard.object(forKey: "useInternalPlayer") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useInternalPlayer, forKey: "useInternalPlayer") }
    }

    /// Seconds skipped by tapping ← or →.
    var playerTapSeekSeconds: Int = {
        let stored = UserDefaults.standard.integer(forKey: "playerTapSeekSeconds")
        return stored == 0 ? 5 : stored
    }() {
        didSet { UserDefaults.standard.set(playerTapSeekSeconds, forKey: "playerTapSeekSeconds") }
    }

    var playerHoldRamp: HoldRamp = HoldRamp(rawValue: UserDefaults.standard.string(forKey: "playerHoldRamp") ?? "") ?? .normal {
        didSet { UserDefaults.standard.set(playerHoldRamp.rawValue, forKey: "playerHoldRamp") }
    }

    /// Off by default: the player only opens files whose extension says they are media.
    var playDisguisedVideos: Bool = UserDefaults.standard.bool(forKey: "playDisguisedVideos") {
        didSet { UserDefaults.standard.set(playDisguisedVideos, forKey: "playDisguisedVideos") }
    }

    var disguisedScope: DisguisedScope = DisguisedScope(rawValue: UserDefaults.standard.string(forKey: "disguisedScope") ?? "") ?? .allowlist {
        didSet { UserDefaults.standard.set(disguisedScope.rawValue, forKey: "disguisedScope") }
    }

    /// Comma-separated extensions the player may look inside when the scope is "Only these extensions".
    var disguisedPlayExtensions: String = UserDefaults.standard.string(forKey: "disguisedPlayExtensions") ?? PlayerGate.defaultExtensions {
        didSet { UserDefaults.standard.set(disguisedPlayExtensions, forKey: "disguisedPlayExtensions") }
    }

    var disguiseRules: PlayerGate.Rules {
        PlayerGate.Rules(enabled: playDisguisedVideos, scope: disguisedScope,
                         extensions: FileNamer.parseExtensions(disguisedPlayExtensions))
    }

    func allowDisguisedExtension(_ ext: String) {
        let current = FileNamer.parseExtensions(disguisedPlayExtensions)
        let clean = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        guard !clean.isEmpty, !current.contains(clean) else { return }
        disguisedPlayExtensions = (current + [clean]).joined(separator: ", ")
    }

    /// What the menu bar panel's Download button saves.
    var quickPreset: QuickPreset = QuickPreset(rawValue: UserDefaults.standard.string(forKey: "quickPreset") ?? "") ?? .video1080 {
        didSet { UserDefaults.standard.set(quickPreset.rawValue, forKey: "quickPreset") }
    }

    /// The "still running in the tray" notice is shown only once.
    var trayHintShown: Bool = UserDefaults.standard.bool(forKey: "trayHintShown") {
        didSet { UserDefaults.standard.set(trayHintShown, forKey: "trayHintShown") }
    }

    var appearance: AppearanceMode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }

    var defaultOutputTemplate: String {
        get {
            access(keyPath: \.defaultOutputTemplate)
            return UserDefaults.standard.string(forKey: "defaultOutputTemplate") ?? "%(title)s [%(id)s].%(ext)s"
        }
        set {
            withMutation(keyPath: \.defaultOutputTemplate) { UserDefaults.standard.set(newValue, forKey: "defaultOutputTemplate") }
        }
    }
}

/// Some providers block DuckDuckGo by DNS, so the engine is a setting. Brave Search is the default: private and not blocked.
enum SearchEngine: String, CaseIterable, Identifiable {
    case brave, duckduckgo, ecosia, bing, google
    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: return "Google"
        case .brave: return "Brave Search"
        case .bing: return "Bing"
        case .duckduckgo: return "DuckDuckGo"
        case .ecosia: return "Ecosia"
        }
    }

    var base: String {
        switch self {
        case .google: return "https://www.google.com/search"
        case .brave: return "https://search.brave.com/search"
        case .bing: return "https://www.bing.com/search"
        case .duckduckgo: return "https://duckduckgo.com/"
        case .ecosia: return "https://www.ecosia.org/search"
        }
    }

    /// The engine saved in settings (Brave Search if none or unknown).
    static var current: SearchEngine {
        SearchEngine(rawValue: UserDefaults.standard.string(forKey: "browserSearchEngine") ?? "") ?? .brave
    }
}
