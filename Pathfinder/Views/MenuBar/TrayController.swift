import SwiftUI
import AppKit
import ServiceManagement

/// A link from the panel that is being looked up before it joins the queue.
struct PendingDownload: Identifiable, Equatable {
    let id = UUID()
    let url: String
    let preset: QuickPreset
}

/// The menu bar icon: left click opens the panel, right click opens the menu.
/// Also keeps the app running in the menu bar when its window is closed, and asks before quitting
/// while downloads are running.
@Observable
@MainActor
final class TrayController: NSObject {
    /// Set by the App so the AppKit delegate can reach it.
    static var shared: TrayController?

    let appState: AppState
    let queue: QueueManager
    let settings: SettingsStore
    let clipboard: ClipboardMonitor

    private(set) var pending: [PendingDownload] = []
    /// Shown under the link field when a pasted link can't be downloaded.
    var linkError: String?
    /// A downloadable link sitting in the clipboard, offered as a one-click card.
    private(set) var clipboardLink: String?
    /// A download finished while the panel was closed (green dot on the icon).
    private var hasUnseenCompletion = false

    /// Opens a new main window; registered by the window's content (`RegistersWindowOpener`).
    @ObservationIgnored var openWindowAction: (() -> Void)?
    @ObservationIgnored private var statusItem: NSStatusItem?
    @ObservationIgnored private let popover = NSPopover()
    @ObservationIgnored private var dismissedLinks: Set<String> = []
    @ObservationIgnored private var lastNotifiedLink: String?
    @ObservationIgnored private var quitWindow: NSWindow?

    init(appState: AppState, queue: QueueManager, settings: SettingsStore, clipboard: ClipboardMonitor) {
        self.appState = appState
        self.queue = queue
        self.settings = settings
        self.clipboard = clipboard
        super.init()
        queue.onCompleted = { [weak self] in self?.downloadCompleted($0) }
        queue.onFailed = { [weak self] in self?.downloadFailed($0) }
    }

    /// Call once the app has finished launching.
    func install() {
        Notifier.setUp()
        Notifier.onResponse = { [weak self] in self?.handleNotification($0, action: $1, info: $2) }

        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(rootView: TrayPopoverView()
            .environment(self)
            .environment(queue)
            .environment(settings))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        if settings.clipboardMonitoring, !clipboard.isMonitoring { clipboard.startMonitoring() }
        observeMenuBarSetting()
        observeIcon()
        observeClipboard()

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.windowClosed() }
        }
    }

    // MARK: - Status item

    private func observeMenuBarSetting() {
        let visible = withObservationTracking {
            settings.showMenuBarExtra
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeMenuBarSetting() }
        }
        setStatusItemVisible(visible)
    }

    private func setStatusItemVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItem = item
            updateIcon()
        } else if !visible, let item = statusItem {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem?.button else { openMainWindow(); return }
        refreshClipboard()
        hasUnseenCompletion = false
        popover.appearance = settings.appearance.nsAppearance
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() { popover.performClose(nil) }

    // MARK: - Icon

    private func observeIcon() {
        withObservationTracking {
            updateIcon()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeIcon() }
        }
    }

    /// Plain arrow when idle; a progress ring while downloading; a dot for a copied link (blue)
    /// or a download that finished while the panel was closed (green).
    private func updateIcon() {
        let running = queue.items.filter { [.downloading, .postProcessing].contains($0.status) }
        let busy = !pending.isEmpty || queue.items.contains { [.queued, .analyzing, .downloading, .postProcessing].contains($0.status) }
        let progress: Double? = busy
            ? (running.isEmpty ? 0 : running.map { min(max($0.progress, 0), 100) }.reduce(0, +) / Double(running.count) / 100)
            : nil
        let dot: NSColor? = hasUnseenCompletion ? .systemGreen : (clipboardLink != nil ? .systemBlue : nil)
        let summary = Self.summary(queue: queue, pending: pending.count)
        guard let button = statusItem?.button else { return }
        // The ring is 18 pt wide: redraw the image only when it would visibly change (1% steps),
        // not on every progress update of every download.
        let key = IconKey(progress: progress.map { Int(($0 * 100).rounded()) }, dot: dot)
        if key != lastIconKey {
            lastIconKey = key
            button.image = Self.icon(progress: progress, dot: dot)
        }
        button.toolTip = "Pathfinder — \(summary)"
        button.setAccessibilityLabel("Pathfinder, \(summary)")
    }

    private struct IconKey: Equatable {
        let progress: Int?
        let dot: NSColor?
    }
    @ObservationIgnored private var lastIconKey: IconKey?

    private static func icon(progress: Double?, dot: NSColor?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let symbolSize: CGFloat = progress == nil ? 14 : 9.5
        let symbol = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: "Pathfinder")?
            .withSymbolConfiguration(.init(pointSize: symbolSize, weight: .semibold)) ?? NSImage()

        if progress == nil && dot == nil {
            symbol.isTemplate = true
            return symbol
        }

        let image = NSImage(size: size, flipped: false) { rect in
            // Tint the arrow with the menu bar's text color (resolved for the current appearance).
            let s = symbol.size
            let symbolRect = NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height)
            let tinted = NSImage(size: s, flipped: false) { r in
                symbol.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: symbolRect)

            if let progress {
                let center = NSPoint(x: rect.midX, y: rect.midY)
                let radius = rect.width / 2 - 1.2
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                track.lineWidth = 1.6
                NSColor.labelColor.withAlphaComponent(0.25).setStroke()
                track.stroke()
                if progress > 0 {
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                                  endAngle: 90 - 360 * CGFloat(min(progress, 1)), clockwise: true)
                    arc.lineWidth = 1.6
                    arc.lineCapStyle = .round
                    NSColor.systemBlue.setStroke()
                    arc.stroke()
                }
            }
            if let dot {
                dot.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 5.5, height: 5.5)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Right-click menu

    private func showMenu() {
        popover.performClose(nil)
        guard let item = statusItem else { return }
        refreshClipboard()
        item.menu = buildMenu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let open = ActionItem("Open Pathfinder") { [weak self] in self?.openMainWindow() }
        open.attributedTitle = NSAttributedString(string: open.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        menu.addItem(open)

        let fromClipboard = NSMenuItem(title: "Download from clipboard", action: nil, keyEquivalent: "")
        if let link = clipboardLink {
            let sub = NSMenu()
            sub.autoenablesItems = false
            sub.addItem(Self.header("From your clipboard"))
            sub.addItem(Self.header(Self.shortLink(link), secondary: true))
            for preset in QuickPreset.allCases {
                let item = ActionItem(preset.title) { [weak self] in self?.quickDownload(link, preset: preset) }
                if preset == settings.quickPreset {
                    item.attributedTitle = Self.titled(preset.title, detail: "Recommended", color: .controlAccentColor)
                }
                sub.addItem(item)
            }
            sub.addItem(.separator())
            sub.addItem(ActionItem("Choose quality…") { [weak self] in self?.openInWindow(link) })
            fromClipboard.submenu = sub
        } else {
            fromClipboard.isEnabled = false
        }
        menu.addItem(fromClipboard)
        menu.addItem(.separator())

        let running = queue.runningCount
        let waiting = queue.items.contains { [.queued, .analyzing, .downloading].contains($0.status) }
        let paused = queue.items.contains { $0.status == .paused }
        if !waiting && paused {
            menu.addItem(ActionItem("Resume all downloads") { [weak self] in self?.queue.resumeAll() })
        } else {
            let pause = ActionItem("Pause all downloads", enabled: waiting) { [weak self] in self?.queue.pauseAll() }
            if running > 0 { pause.attributedTitle = Self.titled(pause.title, detail: "\(running) running", color: .secondaryLabelColor) }
            menu.addItem(pause)
        }
        let cancellable = queue.items.contains { [.queued, .analyzing, .downloading, .paused].contains($0.status) }
        menu.addItem(ActionItem("Cancel all downloads", enabled: cancellable) { [weak self] in self?.queue.cancelAll() })
        menu.addItem(.separator())

        menu.addItem(ActionItem("Open downloads folder") { [weak self] in self?.openDownloadsFolder() })
        let recentItem = NSMenuItem(title: "Recent downloads", action: nil, keyEquivalent: "")
        let finished = recentItems.filter { $0.status == .completed }.prefix(8)
        if finished.isEmpty {
            recentItem.isEnabled = false
        } else {
            let sub = NSMenu()
            sub.autoenablesItems = false
            for d in finished {
                sub.addItem(ActionItem(d.displayFileName(masked: settings.maskDownloadTitles)) { Self.openFile(d) })
            }
            sub.addItem(.separator())
            sub.addItem(ActionItem("See all…") { [weak self] in self?.openMainWindow() })
            recentItem.submenu = sub
        }
        menu.addItem(recentItem)
        menu.addItem(.separator())

        let watch = ActionItem("Watch clipboard for links") { [weak self] in self?.toggleClipboardWatching() }
        watch.state = settings.clipboardMonitoring ? .on : .off
        menu.addItem(watch)
        let login = ActionItem("Start with my computer") { [weak self] in self?.toggleLaunchAtLogin() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(ActionItem("Settings…") { [weak self] in self?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Pathfinder") { NSApp.terminate(nil) })
        return menu
    }

    private static func header(_ title: String, secondary: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if secondary {
            item.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor])
        }
        return item
    }

    /// "Title            detail" with the detail right-aligned.
    private static func titled(_ title: String, detail: String, color: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 240)]
        let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: style])
        s.append(NSAttributedString(string: "\t" + detail, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: color, .paragraphStyle: style]))
        return s
    }

    // MARK: - Actions

    /// Look up the link's title, then queue it with the chosen preset.
    /// Channels and playlists open in the main window instead, where items can be picked.
    @discardableResult
    func quickDownload(_ raw: String, preset: QuickPreset? = nil) -> Bool {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch ErrorMapper.check(url) {
        case .ok: break
        case .empty: linkError = "Paste a link first."; return false
        case .blob, .invalid: linkError = "This link doesn’t lead to a video."; return false
        }
        if ListingSource.detect(url) != nil { openInWindow(url); return true }

        linkError = nil
        dismissedLinks.insert(url)
        if clipboardLink == url { clipboardLink = nil }
        let item = PendingDownload(url: url, preset: preset ?? settings.quickPreset)
        pending.append(item)
        Task {
            defer { pending.removeAll { $0.id == item.id } }
            do {
                let (info, referer) = try await queue.ytdlpService.analyzeWithRefererFallback(
                    url: url, referer: appState.downloadOptions.referer, cookiesFile: nil)
                let option = item.preset.option
                queue.enqueue(url: url, options: option.options(basedOn: appState.downloadOptions),
                              outputDir: settings.defaultOutputDir, videoInfo: info,
                              optionId: option.id, qualityLabel: option.quality, referer: referer)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                linkError = message
                if !popover.isShown, settings.showNotifications {
                    Notifier.notify(title: "Download failed", body: "\(Self.shortLink(url)). \(message)")
                }
            }
        }
        return true
    }

    func dismissClipboardLink() {
        if let link = clipboardLink { dismissedLinks.insert(link) }
        clipboardLink = nil
    }

    func openMainWindow() {
        popover.performClose(nil)
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: { Self.isMainWindow($0) && ($0.isVisible || $0.isMiniaturized) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open the link in the main window's quality picker.
    func openInWindow(_ url: String) {
        openMainWindow()
        appState.section = .downloader
        appState.currentURL = url
        Task { await appState.analyze(using: queue.ytdlpService) }
    }

    func openSettings() {
        popover.performClose(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openMainWindow()
        appState.section = .settings
    }

    func openDownloadsFolder() {
        let dir = settings.defaultOutputDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    private func toggleClipboardWatching() {
        settings.clipboardMonitoring.toggle()
        if settings.clipboardMonitoring {
            if !clipboard.isMonitoring { clipboard.startMonitoring() }
        } else {
            clipboard.stopMonitoring()
            clipboardLink = nil
        }
    }

    private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t change the login setting"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Clipboard

    private func observeClipboard() {
        withObservationTracking {
            _ = clipboard.detectedURL
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.clipboardChanged()
                self?.observeClipboard()
            }
        }
    }

    /// A link was copied: offer it in the panel, and notify when the user is in another app.
    private func clipboardChanged() {
        refreshClipboard()
        guard let link = clipboardLink, link != lastNotifiedLink, !NSApp.isActive,
              settings.showNotifications, ClipboardMonitor.isKnownVideoLink(link) else { return }
        lastNotifiedLink = link
        Notifier.notify(title: "Video link copied", body: "\(Self.shortLink(link)). Download it now?",
                        category: .linkCopied, info: ["url": link])
    }

    func refreshClipboard() {
        guard settings.clipboardMonitoring,
              let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.lowercased().hasPrefix("http"), ErrorMapper.check(s) == .ok,
              let u = URL(string: s), u.path.count > 1 || u.query != nil,
              !dismissedLinks.contains(s),
              !queue.items.contains(where: { $0.url == s }),
              !pending.contains(where: { $0.url == s }) else {
            if clipboardLink != nil { clipboardLink = nil }
            return
        }
        if clipboardLink != s { clipboardLink = s }
    }

    // MARK: - Queue events

    /// Finished and failed downloads, newest first.
    var recentItems: [DownloadItem] {
        queue.items
            .filter { $0.status == .completed || $0.status == .failed }
            .sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
    }

    private func downloadCompleted(_ item: DownloadItem) {
        let masked = settings.maskDownloadTitles
        appState.toast = Toast(name: item.displayTitle(masked: masked), path: item.outputPath)
        if !popover.isShown { hasUnseenCompletion = true }
        guard settings.showNotifications else { return }
        let size = Self.fileSize(of: item).map { " · \($0)" } ?? ""
        var info = ["dir": item.outputDir]
        if let path = item.outputPath { info["path"] = path }
        Notifier.notify(title: "Download complete", body: item.displayFileName(masked: masked) + size, category: .completed, info: info)
    }

    private func downloadFailed(_ item: DownloadItem) {
        guard settings.showNotifications else { return }
        let name = item.displayTitle(masked: settings.maskDownloadTitles)
        Notifier.notify(title: "Download failed", body: "\(name). \(item.error ?? "Something went wrong.")",
                        category: .failed, info: ["id": item.id.uuidString])
    }

    private func handleNotification(_ category: Notifier.Category, action: String, info: [String: String]) {
        switch (category, action) {
        case (.linkCopied, Notifier.Action.downloadVideo):
            if let url = info["url"] { quickDownload(url, preset: settings.quickPreset.isAudio ? .video1080 : settings.quickPreset) }
        case (.linkCopied, Notifier.Action.downloadAudio):
            if let url = info["url"] { quickDownload(url, preset: .audioMP3) }
        case (.completed, Notifier.Action.openFile):
            if let path = info["path"], FileManager.default.fileExists(atPath: path) {
                FileOpener.open(path)
            } else { revealInFinder(info) }
        case (.completed, _):
            revealInFinder(info)
        case (.failed, Notifier.Action.retry):
            if let id = info["id"].flatMap(UUID.init(uuidString:)) { queue.retry(id) }
        case (.linkCopied, Notifier.Action.open), (.failed, Notifier.Action.open):
            showPopover()
        default:
            break
        }
    }

    private func revealInFinder(_ info: [String: String]) {
        if let path = info["path"], FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else if let dir = info["dir"] {
            NSWorkspace.shared.open(URL(fileURLWithPath: dir))
        }
    }

    // MARK: - Windows and quitting

    private static func isMainWindow(_ w: NSWindow) -> Bool {
        w.identifier?.rawValue.hasPrefix("main") == true || w.title == "Pathfinder"
    }

    /// With the last window closed, keep running in the menu bar without a Dock icon.
    private func windowClosed() {
        guard statusItem != nil else { return }
        let hasWindow = NSApp.windows.contains {
            $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) && $0 !== quitWindow
        }
        guard !hasWindow, NSApp.activationPolicy() == .regular else { return }
        NSApp.setActivationPolicy(.accessory)
        if !settings.trayHintShown {
            settings.trayHintShown = true
            Notifier.notify(title: "Still running in the menu bar",
                            body: "Closing the window doesn’t stop your downloads. Click the icon in the menu bar to see them anytime.",
                            category: .trayHint)
        }
    }

    /// Ask before quitting while downloads are running.
    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        let running = queue.items.filter { [.analyzing, .downloading, .postProcessing].contains($0.status) }
        guard !running.isEmpty || !pending.isEmpty else { return .terminateNow }
        guard quitWindow == nil else { return .terminateCancel }

        popover.performClose(nil)
        let view = QuitConfirmView(items: running, onKeep: { [weak self] in
            self?.closeQuitWindow()
            NSApp.reply(toApplicationShouldTerminate: false)
        }, onQuit: { [weak self] in
            self?.queue.pauseAll()
            self?.closeQuitWindow()
            NSApp.reply(toApplicationShouldTerminate: true)
        })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view.environment(settings)))
        window.styleMask = [.titled, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .modalPanel
        window.appearance = settings.appearance.nsAppearance
        window.center()
        quitWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return .terminateLater
    }

    private func closeQuitWindow() {
        quitWindow?.close()
        quitWindow = nil
    }

    // MARK: - Formatting

    static func summary(queue: QueueManager, pending: Int) -> String {
        let c = Dictionary(grouping: queue.items, by: \.status).mapValues(\.count)
        var parts: [String] = []
        if pending > 0 { parts.append("\(pending) starting") }
        if let n = c[.downloading] { parts.append("\(n) downloading") }
        if let n = c[.postProcessing] { parts.append("\(n) merging") }
        let queued = (c[.queued] ?? 0) + (c[.analyzing] ?? 0)
        if queued > 0 { parts.append("\(queued) queued") }
        if let n = c[.paused] { parts.append("\(n) paused") }
        return parts.isEmpty ? "Nothing downloading" : parts.joined(separator: " · ")
    }

    /// "vimeo.com/823415907"
    static func shortLink(_ url: String) -> String {
        guard let u = URL(string: url), var host = u.host else { return url }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let rest = u.path + (u.query.map { "?" + $0 } ?? "")
        return host + (rest == "/" ? "" : rest)
    }

    static func fileSize(of item: DownloadItem) -> String? {
        guard let path = item.outputPath,
              let bytes = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "Just now", "5 min ago", "Today, 14:05", "Yesterday", "3 Oct"
    static func when(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if Calendar.current.isDateInToday(date) { return "Today, " + date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func openFile(_ item: DownloadItem) {
        if let path = item.outputPath, FileManager.default.fileExists(atPath: path) {
            FileOpener.open(path, realExtension: item.realExtension)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.outputDir))
        }
    }

    static func revealFile(_ item: DownloadItem) {
        if let path = item.outputPath, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.outputDir))
        }
    }
}

/// A menu item that runs a closure.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

/// Lets the menu bar reopen the main window after it was closed.
struct RegistersWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            TrayController.shared?.openWindowAction = { openWindow(id: "main") }
        }
    }
}

extension AppearanceMode {
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }
}
