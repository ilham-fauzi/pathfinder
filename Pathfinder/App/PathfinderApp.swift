import SwiftUI
import AppKit

/// A SwiftPM-built executable starts as a background process: it has no focus and no working
/// keyboard shortcuts (⌘C/⌘V/⌘A). Promote it to a regular, active app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        TrayController.shared?.install()
    }

    /// Closing the last window keeps the app running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TrayController.shared?.applicationShouldTerminate() ?? .terminateNow
    }

    /// The download list is written in the background; finish the last write before exiting.
    func applicationWillTerminate(_ notification: Notification) {
        QueueStore.flush()
    }
}

@main
struct PathfinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // MARK: - State

    @State private var appState = AppState()
    @State private var ytdlpService = YTDLPService()
    @State private var queueManager: QueueManager
    @State private var commandBuilder: CommandBuilder
    @State private var settingsStore = SettingsStore()
    @State private var logStore = LogStore()
    @State private var presetManager = PresetManager()
    @State private var clipboardMonitor = ClipboardMonitor()
    @State private var tunnel: SSHTunnelManager
    @State private var browser: BrowserModel
    @State private var tray: TrayController
    @State private var player: PlayerModel

    // MARK: - Init

    init() {
        let service = YTDLPService()
        let appState = AppState()
        let settings = SettingsStore()
        let clipboard = ClipboardMonitor()
        let logs = LogStore()
        let queue = QueueManager(ytdlpService: service, settings: settings)
        queue.onLog = { logs.append($0) }
        let vpnSettings = VPNSettings()
        let tunnel = SSHTunnelManager(settings: vpnSettings)
        let browser = BrowserModel()
        browser.downloadDirectory = { settings.defaultOutputDir }
        browser.queue = queue
        queue.browserEngine = browser
        tunnel.onUpdate = { required, proxy in
            Task { await service.setVPN(required: required, proxy: proxy) }
            Task { @MainActor in browser.applyProxy(required: required, port: vpnSettings.localPort) }
        }
        let player = PlayerModel(settings: settings)
        player.showTab = { appState.section = .player }
        let tray = TrayController(appState: appState, queue: queue, settings: settings, clipboard: clipboard)
        TrayController.shared = tray
        _tray = State(initialValue: tray)
        _player = State(initialValue: player)
        _appState = State(initialValue: appState)
        _clipboardMonitor = State(initialValue: clipboard)
        _browser = State(initialValue: browser)
        _tunnel = State(initialValue: tunnel)
        _ytdlpService = State(initialValue: service)
        _settingsStore = State(initialValue: settings)
        _logStore = State(initialValue: logs)
        _queueManager = State(initialValue: queue)
        _commandBuilder = State(initialValue: CommandBuilder(
            options: DownloadOptions(),
            url: "",
            outputDir: NSHomeDirectory() + "/Downloads/Pathfinder"
        ))
    }

    // MARK: - Body

    private var windowMinimum: NSSize {
        WindowSizer.minimumSize(for: appState, downloadsHeight: DownloadsPanel.height(of: queueManager.items))
    }

    var body: some Scene {
        WindowGroup("Pathfinder", id: "main") {
            ContentView()
                .environment(appState)
                .environment(queueManager)
                .environment(commandBuilder)
                .environment(settingsStore)
                .environment(logStore)
                .environment(presetManager)
                .environment(clipboardMonitor)
                .environment(tunnel)
                .environment(browser)
                .environment(player)
                .preferredColorScheme(settingsStore.appearance.colorScheme)
                .frame(minWidth: windowMinimum.width, minHeight: windowMinimum.height)
                .background(WindowSizer(minimum: windowMinimum))
                .modifier(RegistersWindowOpener())
                .onAppear {
                    appState.outputDirectory = settingsStore.defaultOutputDir
                    appState.mode = settingsStore.appMode
                    let outputDir = appState.outputDirectory
                    try? FileManager.default.createDirectory(
                        atPath: outputDir,
                        withIntermediateDirectories: true
                    )
                }
        }
        .defaultSize(width: WindowSizer.normalSize.width, height: WindowSizer.normalSize.height)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))


        .commands {
            PlayerCommands(model: player)
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    SettingsTab.open()
                }
                .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("Paste URL") {
                    if let content = NSPasteboard.general.string(forType: .string) {
                        appState.currentURL = content
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Button("Start Download") {
                    guard !appState.currentURL.isEmpty else { return }
                    queueManager.enqueue(
                        url: appState.currentURL,
                        options: appState.downloadOptions,
                        outputDir: appState.outputDirectory,
                        videoInfo: appState.currentVideoInfo,
                        cookiesFile: appState.pendingCookiesFile,
                        referer: appState.pendingReferer
                    )
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button("Analyze URL") {
                    Task { await appState.analyze(using: queueManager.ytdlpService) }
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Divider()

                Button("Toggle Mode") {
                    appState.mode = appState.mode == .simple ? .advanced : .simple
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .help) {
                Button("Pathfinder Help") {
                    // Open help
                }
            }
        }

    }
}
