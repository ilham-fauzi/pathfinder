import SwiftUI
import AppKit

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, output, player, binaries, tunnel, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .output: return "Output"
        case .player: return "Player"
        case .binaries: return "Binaries"
        case .tunnel: return "SSH Tunnel"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .output: return "folder"
        case .player: return "play.rectangle"
        case .binaries: return "terminal"
        case .tunnel: return "network.badge.shield.half.filled"
        case .about: return "info.circle"
        }
    }

    static let storageKey = "settingsSelectedTab"

    /// Brings the Settings tab to the front (set by the main window).
    @MainActor static var opener: (() -> Void)?

    /// Shows the Settings tab, on one section when given, otherwise on the last one used.
    @MainActor
    static func open(_ tab: SettingsTab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: storageKey) }
        opener?()
    }
}

/// The Settings tab of the main window: a list of sections on the left, the chosen one on the right.
struct SettingsView: View {
    @AppStorage(SettingsTab.storageKey) private var stored = SettingsTab.general.rawValue

    private var tab: SettingsTab { SettingsTab(rawValue: stored) ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.allCases) { item in
                    Button { stored = item.rawValue } label: {
                        Label(item.title, systemImage: item.icon)
                            .font(.system(size: 13, weight: item == tab ? .semibold : .regular))
                            .foregroundStyle(item == tab ? Theme.accentText : Theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).frame(height: 32)
                            .background(item == tab ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(10).frame(width: 180)
            .background(Theme.surface)

            Divider()

            content
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .general: GeneralSettingsTab()
        case .output: OutputSettingsTab()
        case .player: PlayerSettingsTab()
        case .binaries: BinariesSettingsTab()
        case .tunnel: VPNSettingsView()
        case .about: AboutSettingsTab()
        }
    }
}

struct GeneralSettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    
    var body: some View {
        @Bindable var s = settings
        Form {
            HStack {
                TextField("Default Output:", text: $s.defaultOutputDir)
                Button("Browse...") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK {
                        settings.defaultOutputDir = panel.url?.path ?? ""
                    }
                }
            }
            Picker("Default App Mode:", selection: $s.appMode) {
                Text("Simple").tag(AppMode.simple)
                Text("Advanced").tag(AppMode.advanced)
            }
            Toggle("Monitor Clipboard for URLs", isOn: $s.clipboardMonitoring)
            Picker("Appearance:", selection: $s.appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Show Video Thumbnail", isOn: $s.showThumbnail)
            Toggle("Show Notifications", isOn: $s.showNotifications)
            Toggle("Mask Download Titles", isOn: $s.maskDownloadTitles)
                .help("Show downloads as “Video #3F9A” in the app, menu bar and notifications. Files keep their real names.")
            Toggle("Show Menu Bar Icon", isOn: $s.showMenuBarExtra)
            Toggle("Experimental: Browser tab", isOn: $s.showBrowserTab)
            Toggle("Player: hide the playlist while a video plays", isOn: $s.playerAutoHidePlaylist)
                .help("The playlist slides over the picture when the pointer touches the right edge or you press L.")
            Picker("Browser search engine", selection: $s.browserSearchEngine) {
                ForEach(SearchEngine.allCases) { Text($0.name).tag($0.rawValue) }
            }
            .help("Used for text typed in the browser address bar. Some internet providers block DuckDuckGo.")
            Stepper("Max Concurrent Downloads: \(settings.maxConcurrentDownloads)", value: $s.maxConcurrentDownloads, in: 1...5)
        }
        .formStyle(.grouped)
    }
}

struct BinariesSettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(QueueManager.self) private var queueManager
    @State private var message: String = ""
    @State private var busy = false
    
    var body: some View {
        @Bindable var s = settings
        Form {
            Section("yt-dlp") {
                HStack {
                    TextField("Path:", text: $s.ytdlpPath)
                    Button("Detect") {
                        Task {
                            if let url = await DependencyChecker.findExecutable(named: "yt-dlp") {
                                settings.ytdlpPath = url.path
                                await queueManager.ytdlpService.setCustomPath(url.path)
                                message = "Found yt-dlp at \(url.path)"
                            } else {
                                message = "yt-dlp was not found. Install it with Homebrew: brew install yt-dlp"
                            }
                        }
                    }
                }
                Picker("Update Channel", selection: $s.updateChannel) {
                    Text("Stable").tag(UpdateChannel.stable)
                    Text("Nightly").tag(UpdateChannel.nightly)
                    Text("Master").tag(UpdateChannel.master)
                }
                Toggle("Auto-update", isOn: $s.autoUpdateYtdlp)
                HStack {
                    Button("Update Now") {
                        Task {
                            busy = true; defer { busy = false }
                            do {
                                message = try await queueManager.ytdlpService.updateBinary(channel: settings.updateChannel.rawValue)
                            } catch { message = error.localizedDescription }
                        }
                    }
                    Button("Check Version") {
                        Task {
                            do { message = "yt-dlp " + (try await queueManager.ytdlpService.getVersion()) }
                            catch { message = error.localizedDescription }
                        }
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                }
            }
            
            Section("FFmpeg") {
                HStack {
                    TextField("Path:", text: $s.ffmpegPath)
                    Button("Detect") {
                        Task {
                            if let url = await DependencyChecker.findExecutable(named: "ffmpeg") {
                                settings.ffmpegPath = url.path
                                message = "Found ffmpeg at \(url.path)"
                            } else {
                                message = "ffmpeg was not found. Install it with Homebrew: brew install ffmpeg"
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct OutputSettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    
    var body: some View {
        @Bindable var s = settings
        Form {
            TextField("Default Output Template", text: $s.defaultOutputTemplate)
            Button("Template Variables Reference") {
                // show reference
            }
            Section {
                Picker("Name", selection: $s.fileNaming) {
                    ForEach(FileNaming.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Disguise extension", isOn: $s.disguiseExtension)
                TextField("Extensions to use", text: $s.disguiseExtensions, prompt: Text(FileNamer.defaultDisguiseExtensions))
                    .disabled(!s.disguiseExtension)
            } header: {
                Text("Finished video and audio files")
            } footer: {
                FileNamingExamples()
            }
        }
        .formStyle(.grouped)
    }
}

/// Live examples of the current naming settings.
struct FileNamingExamples: View {
    @Environment(SettingsStore.self) private var settings

    private let samples = ["Kebun Raya Bogor [RDS-09888].mp4", "Kebun Raya Bogor.mp4", "日本の旅.webm"]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Short name uses a code from the title (like RDS-09888, SHKD 658 or 09888), else the initials, else a random name. Names never repeat. Other files (PDF, ZIP…) are not renamed.")
            ForEach(samples, id: \.self) { sample in
                Text("\(sample) → \(example(sample))").font(.system(.caption, design: .monospaced))
            }
            if settings.disguiseExtension {
                Text("The app still opens these files with your video player.")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func example(_ file: String) -> String {
        let url = URL(fileURLWithPath: file)
        let base = settings.fileNaming == .short ? FileNamer.shortName(for: url.deletingPathExtension().lastPathComponent)
                                                 : url.deletingPathExtension().lastPathComponent
        let pool = FileNamer.parseExtensions(settings.disguiseExtensions)
        let ext = settings.disguiseExtension && !pool.isEmpty ? (pool.first ?? url.pathExtension) + " (random)" : url.pathExtension
        return "\(base).\(ext)"
    }
}

struct AboutSettingsTab: View {
    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            Text("Pathfinder").font(.title).bold()
            Text("Version \(Self.versionString)").foregroundColor(.secondary)
            
            HStack {
                Link("GitHub", destination: URL(string: "https://github.com")!)
                Text("•")
                Link("Report Issue", destination: URL(string: "https://github.com/issues")!)
            }
            
            Text("License: GPL-3.0")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct PlayerSettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    @State private var confirmDisguised = false

    var body: some View {
        @Bindable var s = settings
        Form {
            Section("Playback") {
                Toggle("Play finished downloads in the built-in player", isOn: $s.useInternalPlayer)
                Picker("Hold ← / → to speed up", selection: $s.playerHoldRamp) {
                    ForEach(HoldRamp.allCases) { Text($0.title).tag($0) }
                }
                .help("How fast the speed climbs from 2× to 16× while the key is held. A short tap just skips.")
                Stepper("Tap ← / → skips \(settings.playerTapSeekSeconds) s", value: $s.playerTapSeekSeconds, in: 1...30)
            }

            Section {
                Toggle("Play videos with a different extension", isOn: Binding(
                    get: { settings.playDisguisedVideos },
                    set: { turnedOn in
                        if turnedOn { confirmDisguised = true } else { settings.playDisguisedVideos = false }
                    }))
                if settings.playDisguisedVideos {
                    Picker("Look inside", selection: $s.disguisedScope) {
                        ForEach(DisguisedScope.allCases) { Text($0.title).tag($0) }
                    }
                    if settings.disguisedScope == .allowlist {
                        TextField("Extensions:", text: $s.disguisedPlayExtensions, axis: .vertical)
                            .lineLimit(2...4)
                        HStack {
                            Spacer()
                            Button("Reset") { settings.disguisedPlayExtensions = PlayerGate.defaultExtensions }
                        }
                    }
                }
            } header: {
                Text("Disguised videos")
            } footer: {
                Text("A video saved as .dat or .pdf can still play. The player reads the first few KB of a file you open to recognise it. Files are never changed. This is not encryption.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Play videos with a different extension?", isPresented: $confirmDisguised) {
            Button("Turn On") { settings.playDisguisedVideos = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("When you open a file, the app reads its first few KB to check whether it is a video, even if its name ends in something else. Nothing is changed or sent anywhere.")
        }
    }
}
