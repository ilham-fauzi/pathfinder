import SwiftUI
import WebKit

private struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// A strip that reports the pointer entering it through an NSTrackingArea. It never takes clicks.
private struct EdgeHoverView: NSViewRepresentable {
    let onEnter: () -> Void
    func makeNSView(context: Context) -> NSView { let v = TrackingView(); v.onEnter = onEnter; return v }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? TrackingView)?.onEnter = onEnter }

    final class TrackingView: NSView {
        var onEnter: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
        override func mouseEntered(with event: NSEvent) { onEnter?() }
    }
}

/// Experimental browser tab. Video pages go to the downloader; plain files download right here.
struct BrowserView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(AppState.self) private var appState
    @Environment(QueueManager.self) private var queueManager
    @Environment(SettingsStore.self) private var settings
    @State private var address = ""
    /// The Download button is measuring the page's streams to tell the video from its ads.
    @State private var checkingStreams = false
    @State private var showQualities = false
    @State private var qualities: [BrowserModel.StreamQuality]?
    @FocusState private var addressFocused: Bool
    @State private var tabToClose: BrowserTab?
    @State private var sideHover = false
    @State private var sideCollapseTask: Task<Void, Never>?
    @State private var clickMonitor: Any?
    @State private var menuOpen = false

    var body: some View {
        HStack(spacing: 0) {
        if browser.verticalTabs {
            if browser.sideTabsMode == .auto {
                // Nothing is kept in the layout: the panel floats over the page while it is shown. Touching the
                // left edge (or the button at the left of the address bar) brings it, and it hides 1 s after the
                // pointer is away from it.
                Color.clear.frame(width: 0)
                    .overlay(alignment: .leading) {
                        if sideHover {
                            tabSidebar
                                .shadow(color: .black.opacity(0.3), radius: 8, x: 2)
                                .transition(.move(edge: .leading))
                                .onHover { inside in sideHovered(inside) }
                        }
                    }
                    .zIndex(1)
            } else {
                tabSidebar
            }
            Divider()
        }
        VStack(spacing: 0) {
            if !browser.verticalTabs { tabStrip }
            bar
            if browser.isLoading {
                ProgressView(value: browser.progress).progressViewStyle(.linear).controlSize(.mini)
            } else {
                Divider()
            }
            ZStack {
                WebViewContainer(webView: browser.webView)
                    .id(browser.selectedTab.id)
                if browser.verticalTabs, browser.sideTabsMode == .auto, !sideHover {
                    // A SwiftUI hover view would sit under the web view's AppKit hit-testing; a tracking area
                    // does not care what is drawn above it.
                    HStack(spacing: 0) {
                        EdgeHoverView { showSidePanelFromEdge() }.frame(width: 10)
                        Spacer(minLength: 0)
                    }
                }
                if browser.currentURL == nil && !browser.isLoading && browser.loadError == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "globe").font(.system(size: 40)).foregroundStyle(Theme.text3)
                        Text("Open any website").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("Type an address or a search above. Video pages and files can be downloaded from here.")
                            .font(.system(size: 13)).foregroundStyle(Theme.text2)
                            .multilineTextAlignment(.center).frame(maxWidth: 360)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg)
                }
                if let error = browser.loadError {
                    VStack(spacing: 10) {
                        Image(systemName: browser.blockedURL != nil ? "shield.slash" : "wifi.exclamationmark")
                            .font(.system(size: 28)).foregroundStyle(Theme.text3)
                        Text(error).font(.system(size: 13)).foregroundStyle(Theme.text2)
                            .multilineTextAlignment(.center).frame(maxWidth: 420)
                        if let blocked = browser.blockedURL {
                            Button("Load without ad blocking") { browser.loadWithoutAdBlock(blocked) }
                                .buttonStyle(PrimaryButtonStyle(height: 34))
                            Text("This turns the shield off. Click it again to block ads.")
                                .font(.system(size: 12)).foregroundStyle(Theme.text3)
                        }
                        Button("Try again") { browser.reload() }.buttonStyle(SecondaryButtonStyle(height: 34))
                    }
                    .padding(24)
                    .background(Theme.bg)
                }
            }
            if let message = browser.statusMessage {
                HStack {
                    Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                    Spacer()
                    Button { browser.dismissStatus() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle())
                }
                .padding(.horizontal, 12).padding(.vertical, 4).background(Theme.surface2)
            }
        }
        }
        .onAppear {
            syncAddress()
            watchPageClicks()
            browser.onDownloadStream = { sendStream($0) }
            if browser.currentURL == nil { addressFocused = true }
        }
        .onDisappear { stopWatchingPageClicks() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            menuTracking(true)
            // A menu listing the page's streams is open: look for ones the sniffer missed, so they appear in it.
            Task { await browser.recoverStreams() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in menuTracking(false) }
        .onChange(of: browser.currentURL) { _, _ in if !addressFocused { syncAddress() } }
        .onChange(of: browser.selectedTabID) { _, _ in
            syncAddress()
            if browser.currentURL == nil { addressFocused = true }
        }
        .confirmationDialog("A stream download is using this tab", isPresented: Binding(
            get: { tabToClose != nil }, set: { if !$0 { tabToClose = nil } })) {
            Button("Close Tab", role: .destructive) { if let tab = tabToClose { browser.closeTab(tab.id) } }
            Button("Keep Tab", role: .cancel) {}
        } message: {
            Text("The download fetches the video through this page. It usually keeps going after the tab closes, but keeping the tab open is the safest until it finishes.")
        }
    }

    // MARK: Tabs

    /// Stream downloads that fetch through this tab's page (only those; other downloads don't need a tab).
    private func streamDownloads(in tab: BrowserTab) -> Int {
        queueManager.items.filter { item in
            [.queued, .analyzing, .downloading, .postProcessing].contains(item.status)
                && (item.browserFrame as? WKFrameInfo)?.webView === tab.webView
        }.count
    }

    private var hasActiveStreamDownloads: Bool { browser.tabs.contains { streamDownloads(in: $0) > 0 } }

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(browser.tabs) { tab in tabChip(tab) }
                }
            }
            Button { browser.newTab() } label: { Image(systemName: "plus") }
                .buttonStyle(IconButtonStyle())
                .keyboardShortcut("t", modifiers: .command)
                .help("New tab (⌘T)")
                .accessibilityLabel("New tab")
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
        .background(Theme.surface2)
    }

    private func tabChip(_ tab: BrowserTab) -> some View {
        let selected = tab.id == browser.selectedTabID
        let downloading = streamDownloads(in: tab)
        return HStack(spacing: 6) {
            if downloading > 0 {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                    .help("\(downloading) stream download\(downloading == 1 ? "" : "s") running from this tab")
            } else if tab.isLoading {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "globe").foregroundStyle(Theme.text3)
            }
            if !tab.isPinned {
                Text(tab.displayTitle).lineLimit(1).truncationMode(.tail)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.text2)
                    .frame(maxWidth: 160, alignment: .leading)
                Button { requestClose(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.text3)
                .accessibilityLabel("Close tab")
            }
        }
        .padding(.horizontal, tab.isPinned ? 8 : 10).frame(height: 28)
        .help(tab.displayTitle)
        .contextMenu { tabMenu(tab) }
        .background(selected ? Theme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Theme.border : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { browser.select(tab.id) }
    }

    private func requestClose(_ tab: BrowserTab) {
        if streamDownloads(in: tab) > 0 { tabToClose = tab } else { browser.closeTab(tab.id) }
    }

    @ViewBuilder
    private func tabMenu(_ tab: BrowserTab) -> some View {
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { browser.togglePin(tab.id) }
        Button(browser.verticalTabs ? "Move Tabs to the Top" : "Move Tabs to the Side") { browser.verticalTabs.toggle() }
        Divider()
        Button("Close Tab") { requestClose(tab) }
    }

    /// Tabs listed down the side: pinned ones first, then the rest, with bookmarks below. Can collapse to icons.
    private var tabSidebar: some View {
        let collapsed = browser.sideTabsMode == .collapsed
        return VStack(alignment: collapsed ? .center : .leading, spacing: 2) {
            HStack {
                if !collapsed {
                    Text("Tabs").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3).padding(.leading, 10)
                    Spacer()
                    Button { browser.newTab() } label: { Image(systemName: "plus") }
                        .buttonStyle(IconButtonStyle()).help("New tab (⌘T)").accessibilityLabel("New tab")
                }
                Menu {
                    Picker("Tab panel", selection: Binding(get: { browser.sideTabsMode }, set: { browser.sideTabsMode = $0 })) {
                        ForEach(BrowserModel.SideTabsMode.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                } label: {
                    Image(systemName: browser.sideTabsMode == .auto ? "sidebar.squares.left" : "sidebar.left")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 32)
                .help("Tab panel: expanded, collapsed or auto")
                .accessibilityLabel("Tab panel mode")
            }
            if collapsed {
                Button { browser.newTab() } label: { Image(systemName: "plus") }
                    .buttonStyle(IconButtonStyle()).help("New tab (⌘T)").accessibilityLabel("New tab")
            }
            ScrollView {
                VStack(alignment: collapsed ? .center : .leading, spacing: 2) {
                    ForEach(browser.tabs) { tab in sideRow(tab, collapsed: collapsed) }
                    if !browser.bookmarks.isEmpty {
                        if collapsed {
                            Divider().padding(.vertical, 6)
                        } else {
                            Text("Bookmarks").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
                                .padding(.top, 14).padding(.leading, 10).padding(.bottom, 2)
                        }
                        ForEach(browser.bookmarks) { b in
                            HStack(spacing: 8) {
                                Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Theme.accentText)
                                if !collapsed {
                                    Text(b.title).lineLimit(1).font(.system(size: 12)).foregroundStyle(Theme.text2)
                                    Spacer(minLength: 0)
                                    Button { browser.removeBookmark(b.id) } label: {
                                        Image(systemName: "trash").font(.system(size: 10))
                                    }
                                    .buttonStyle(.plain).foregroundStyle(Theme.text3)
                                    .help("Delete bookmark").accessibilityLabel("Delete bookmark")
                                }
                            }
                            .padding(.horizontal, collapsed ? 0 : 10).frame(width: collapsed ? 36 : nil, height: 26)
                            .contentShape(Rectangle())
                            .onTapGesture { open(b.url) }
                            .help(b.title)
                            .contextMenu { bookmarkMenu(b) }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 6)
        .frame(width: collapsed ? 52 : 210)
        .frame(maxHeight: .infinity)
        .background(Theme.surface2)
    }

    /// The corner button: show the panel (it hides itself 1 s after the pointer is away from it), or hide it now.
    private func toggleSidePanel() {
        sideCollapseTask?.cancel()
        if sideHover {
            withAnimation(.easeOut(duration: 0.15)) { sideHover = false }
        } else {
            withAnimation(.easeOut(duration: 0.15)) { sideHover = true }
            sideHovered(false)   // starts the 1 s countdown; entering the panel cancels it
        }
    }

    /// A click on the web page hides an open auto panel straight away, without waiting for the 1 s.
    private func watchPageClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            let web = browser.webView
            guard browser.verticalTabs, browser.sideTabsMode == .auto, sideHover,
                  event.window != nil, event.window === web.window else { return event }
            // Where the click landed, in the page's own coordinates (the open panel floats over its left edge).
            let point = web.convert(event.locationInWindow, from: nil)
            let panelEdge = 210.0
            if web.bounds.contains(point), point.x > panelEdge {
                sideCollapseTask?.cancel()
                withAnimation(.easeOut(duration: 0.15)) { sideHover = false }
            }
            return event
        }
    }

    private func stopWatchingPageClicks() {
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
        clickMonitor = nil
    }

    /// The pointer touched the left edge: show the panel under it. The panel's own onHover may not fire until the
    /// pointer moves, so the 1 s countdown is armed right away (entering the panel cancels it).
    private func showSidePanelFromEdge() {
        guard !sideHover else { return }
        withAnimation(.easeOut(duration: 0.12)) { sideHover = true }
        sideHovered(false)
    }

    /// Opens at once; closes only after the pointer has been away for 1 s (coming back cancels it).
    private func sideHovered(_ inside: Bool) {
        sideCollapseTask?.cancel()
        if inside {
            withAnimation(.easeOut(duration: 0.12)) { sideHover = true }
        } else {
            sideCollapseTask = Task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                // A menu opened from the panel (its popup lies outside it) keeps the panel until it closes.
                guard !menuOpen else { return }
                withAnimation(.easeOut(duration: 0.15)) { sideHover = false }
            }
        }
    }

    private func menuTracking(_ open: Bool) {
        menuOpen = open
        guard !open, sideHover else { return }
        // The menu is gone: stay if the pointer is back over the panel, else start the countdown.
        let web = browser.webView
        guard let window = web.window else { return }
        let point = web.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        sideHovered(point.x >= 0 && point.x <= 210)
    }

    @ViewBuilder
    private func bookmarkMenu(_ b: Bookmark) -> some View {
        Button("Delete", role: .destructive) { browser.removeBookmark(b.id) }
    }

    private func sideRow(_ tab: BrowserTab, collapsed: Bool) -> some View {
        let selected = tab.id == browser.selectedTabID
        return HStack(spacing: 8) {
            if tab.isLoading { ProgressView().controlSize(.mini) }
            else { Image(systemName: tab.isPinned ? "pin.fill" : "globe").font(.system(size: 11)).foregroundStyle(selected ? Theme.accentText : Theme.text3) }
            if !collapsed {
                Text(tab.displayTitle).lineLimit(1).truncationMode(.tail)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.text2)
                Spacer(minLength: 0)
                if !tab.isPinned {
                    Button { requestClose(tab) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.text3).accessibilityLabel("Close tab")
                }
            }
        }
        .padding(.horizontal, collapsed ? 0 : 10).frame(width: collapsed ? 36 : nil, height: 30)
        .background(selected ? Theme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Theme.border : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { browser.select(tab.id) }
        .help(tab.displayTitle)
        .contextMenu { tabMenu(tab) }
    }

    /// Typing an address or clearing in a tab that feeds a stream download keeps that tab in the background
    /// and continues in a new tab, so the download isn't cut off.
    private var currentTabIsDownloading: Bool { streamDownloads(in: browser.selectedTab) > 0 }

    private func open(_ input: String) {
        if currentTabIsDownloading {
            browser.newTab(input)
            browser.statusMessage = "Opened in a new tab; the previous tab stays open for its stream download."
        } else {
            browser.go(input)
        }
    }

    private func clearBrowser() {
        if hasActiveStreamDownloads {
            // Deleting cookies would cut off the running stream downloads: only start fresh.
            if currentTabIsDownloading { browser.newTab() } else { browser.blank() }
            browser.statusMessage = "Stream downloads are running, so cookies are kept until they finish. Their tabs stay open in the background."
        } else {
            Task { await browser.clearEverything() }
        }
    }

    // MARK: Address bar

    /// Drops the button labels when the window is narrow.
    private var bar: some View {
        ViewThatFits(in: .horizontal) {
            barContent(compact: false)
            barContent(compact: true)
        }
    }

    /// Read from the observed setting, so the placeholder follows a change at once.
    private var engineName: String { (SearchEngine(rawValue: settings.browserSearchEngine) ?? .brave).name }

    private func barContent(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if browser.verticalTabs && browser.sideTabsMode == .auto {
                Button { toggleSidePanel() } label: {
                    Image(systemName: "sidebar.left").foregroundStyle(sideHover ? Theme.accentText : Theme.text3)
                }
                .help(sideHover ? "Hide the tabs" : "Show the tabs").accessibilityLabel("Show or hide tabs")
            }
            Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!browser.canGoBack).accessibilityLabel("Back")
            Button { browser.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!browser.canGoForward).accessibilityLabel("Forward")
            Button { browser.isLoading ? browser.stop() : browser.reload() } label: {
                Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
            }
            .accessibilityLabel(browser.isLoading ? "Stop" : "Reload")

            HStack(spacing: 8) {
                Menu {
                    Picker("Search engine", selection: Binding(get: { settings.browserSearchEngine },
                                                               set: { settings.browserSearchEngine = $0 })) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Search engine: \(engineName). Click to change.")
                .accessibilityLabel("Search engine")
                TextField("Search with \(engineName) or enter an address", text: $address)
                    .textFieldStyle(.plain)
                    .focused($addressFocused)
                    .onSubmit { open(address); addressFocused = false }
            }
            .padding(.horizontal, 12).frame(minWidth: 140, minHeight: 36, maxHeight: 36)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(addressFocused ? Theme.accent : Theme.border, lineWidth: 1.5))

            Menu {
                Picker("Video fullscreen", selection: Binding(get: { browser.fullscreenMode },
                                                              set: { browser.fullscreenMode = $0 })) {
                    ForEach(BrowserModel.FullscreenMode.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: browser.fullscreenMode == .tab ? "rectangle.inset.filled" : "arrow.up.left.and.arrow.down.right")
                    .foregroundStyle(Theme.text3)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Video fullscreen: \(browser.fullscreenMode.name). Click to change.")
            .accessibilityLabel("Video fullscreen mode")

            Button { browser.toggleBookmark() } label: {
                Image(systemName: browser.isBookmarked ? "star.fill" : "star")
                    .foregroundStyle(browser.isBookmarked ? Theme.accentText : Theme.text3)
            }
            .disabled(browser.currentURL == nil)
            .help(browser.isBookmarked ? "Remove bookmark" : "Bookmark this page")
            .accessibilityLabel(browser.isBookmarked ? "Remove bookmark" : "Add bookmark")

            Menu {
                if browser.bookmarks.isEmpty { Text("No bookmarks yet") }
                ForEach(browser.bookmarks) { b in
                    Button(b.title) { open(b.url) }
                }
                if !browser.bookmarks.isEmpty {
                    Divider()
                    Menu("Delete") {
                        ForEach(browser.bookmarks) { b in Button(b.title) { browser.removeBookmark(b.id) } }
                    }
                }
            } label: { Image(systemName: "book") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 32)
            .help("Bookmarks").accessibilityLabel("Bookmarks")

            Button { browser.verticalTabs.toggle() } label: {
                Image(systemName: browser.verticalTabs ? "sidebar.left" : "rectangle.split.1x2")
                    .foregroundStyle(browser.verticalTabs ? Theme.accentText : Theme.text3)
            }
            .help(browser.verticalTabs ? "Move tabs to the top" : "Move tabs to the side")
            .accessibilityLabel("Toggle side tabs")

            SecurityButton()

            Button { browser.setAdBlock(!browser.adBlockEnabled) } label: {
                Image(systemName: browser.adBlockEnabled ? "shield.lefthalf.filled" : "shield.slash")
                    .foregroundStyle(browser.adBlockEnabled ? Theme.accentText : Theme.text3)
            }
            .help(browser.adBlockEnabled
                  ? "Ad blocking is on. \(browser.adBlockDetail ?? "") Click to turn off"
                  : "Ad blocking is off. Click to turn on")
            .accessibilityLabel(browser.adBlockEnabled ? "Turn ad blocking off" : "Turn ad blocking on")

            Menu {
                Toggle("Mute all sites by default", isOn: Binding(
                    get: { browser.muteByDefault }, set: { browser.setMuteByDefault($0) }))
                Button("Reset choices for individual sites") { browser.resetSiteMuteChoices() }
                    .disabled(browser.siteMuteOverrides.isEmpty)
            } label: {
                Image(systemName: browser.isCurrentSiteMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(browser.isCurrentSiteMuted ? Theme.dangerText : Theme.text3)
            } primaryAction: {
                browser.toggleMute()
            }
            .menuStyle(.borderlessButton)
            .frame(width: 46)
            .disabled(browser.currentHost == nil || !browser.canMute)
            .help(muteHelp)
            .accessibilityLabel(browser.isCurrentSiteMuted ? "Unmute this site" : "Mute this site")

            Button { clearBrowser() } label: {
                Image(systemName: "xmark.circle")
            }
            .help("Clear browser: close the page and delete cookies and site data")
            .accessibilityLabel("Clear browser")

            actionButton(compact: compact)
        }
        .buttonStyle(IconButtonStyle())
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.surface2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { WindowSizer.toggleFill() }
    }

    private var muteHelp: String {
        guard let host = browser.currentHost else { return "Open a site to mute it" }
        if !browser.canMute { return "Muting is not available on this macOS version" }
        let action = browser.isCurrentSiteMuted ? "Unmute \(host)" : "Mute \(host)"
        return action + ". Click the arrow to mute every site by default."
    }

    private enum PageAction { case video, list, tryPage, none }

    private var pageAction: PageAction {
        guard let url = browser.currentURL, let host = url.host?.lowercased() else { return .none }
        let isYouTube = host == "youtube.com" || host.hasSuffix(".youtube.com")
        if ListingSource.detect(url.absoluteString) != nil { return .list }
        if host == "youtu.be" { return .video }
        if isYouTube {
            let path = url.path
            return path.hasPrefix("/watch") || path.hasPrefix("/shorts/") || path.hasPrefix("/live/") ? .video : .none
        }
        return url.path.count > 1 && url.scheme?.hasPrefix("http") == true ? .tryPage : .none
    }

    @ViewBuilder
    private func actionButton(compact: Bool) -> some View {
        if pageAction == .list {
            Button { send() } label: { actionLabel("Show as list", "square.grid.2x2", compact) }
                .buttonStyle(PrimaryButtonStyle(height: 36))
                .help("Show the videos on this page as a list")
        } else if pageAction == .video || pageAction == .tryPage || !browser.detectedStreams.isEmpty {
            // One Download button for everything: a video page, a detected stream or a file link.
            // The app picks the best source; a stream refused by yt-dlp is saved through the browser on its own.
            Button { download() } label: {
                actionLabel(checkingStreams ? "Checking…" : "Download", "arrow.down.circle.fill", compact)
            }
                .disabled(checkingStreams)
                .buttonStyle(PrimaryButtonStyle(height: 36))
                .help(downloadHelp)
                .contextMenu { manualChoices }
            if !browser.detectedStreams.isEmpty {
                Button { openQualities() } label: { Image(systemName: "list.bullet.below.rectangle") }
                    .help("Choose a quality or stream (\(browser.detectedStreams.count) found)")
                    .accessibilityLabel("Choose quality")
                    .popover(isPresented: $showQualities, arrowEdge: .bottom) { qualityPicker }
            }
        } else {
            Button {} label: { actionLabel("Download", "arrow.down.circle", compact) }
                .buttonStyle(SecondaryButtonStyle(height: 36))
                .disabled(true)
                .help("Open a video page to download it")
        }
    }

    private func openQualities() {
        qualities = nil
        showQualities = true
        Task { qualities = await browser.qualityChoices(among: browser.detectedStreams) }
    }

    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choose quality").font(.headline).padding(.bottom, 2)
            if let rows = qualities {
                if rows.isEmpty {
                    Text("No streams to list yet. Let the video start playing.").foregroundStyle(Theme.text3)
                }
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(rows) { row in
                            HStack(spacing: 10) {
                                Text(row.badge).font(.system(.callout, design: .rounded).weight(.semibold))
                                    .foregroundStyle(Theme.accentText).frame(width: 56, alignment: .leading)
                                Text(row.label).lineLimit(1)
                                Spacer(minLength: 8)
                                if let d = row.detail { Text(d).font(.caption).foregroundStyle(Theme.text3) }
                                Button("Download") {
                                    showQualities = false
                                    queueStream(row.stream, viaBrowser: false, maxHeight: row.height)
                                }
                                .buttonStyle(SecondaryButtonStyle(height: 28))
                            }
                            .padding(8)
                            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .frame(maxHeight: 320)
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the available qualities…") }
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(14).frame(width: 380)
    }

    private var downloadHelp: String {
        if pageAction == .video { return "Download this video" }
        if let stream = DetectedStream.best(of: browser.detectedStreams) {
            return "Download the video playing on this page (\(stream.displayName)). Right-click to choose another stream."
        }
        return "Find and download the video on this page"
    }

    /// The one-click choice: the page itself for known video sites, else the main stream found on the page.
    /// When there is none yet the browser stays put and says so; the page address is only tried by hand.
    private func download() {
        guard !checkingStreams else { return }
        checkingStreams = true
        browser.statusMessage = "Checking which stream is the main video…"
        Task {
            defer { checkingStreams = false }
            switch await browser.chooseDownload(knownVideoPage: pageAction == .video) {
            case .pageLink:
                browser.statusMessage = nil
                send()
            case .noStreamYet:
                browser.statusMessage = DownloadDecision.noStreamMessage
            case .shortClip(let choice):
                // Only short clips so far: the page is most likely still showing its ads.
                let what = (choice.duration ?? 0) > 0 ? "a short clip (\(Self.clock(choice.duration ?? 0)))" : "a small file"
                browser.statusMessage = "Only \(what) was found, probably an ad. Let the main video "
                    + "start playing, then press Download again. (Right-click Download to save this clip anyway.)"
            case .stream(let choice):
                var note = "Added to Downloads"
                if let d = choice.duration { note += ": main video, \(Self.clock(d))" }
                if choice.skippedAds > 0 { note += ". Skipped \(choice.skippedAds) ad stream\(choice.skippedAds == 1 ? "" : "s")" }
                // A playlist recognised by its content behind a disguised address: yt-dlp would save the playlist text
                // itself, so it goes straight to the browser engine, which joins the pieces.
                let disguised = choice.stream.type == .hls && !choice.stream.url.lowercased().contains(".m3u8")
                queueStream(choice.stream, viaBrowser: disguised, message: note + ". You can keep browsing.")
            }
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Right-click: pick a specific stream or method by hand.
    @ViewBuilder
    private var manualChoices: some View {
        if !browser.detectedStreams.isEmpty {
            Section("Streams on this page") {
                ForEach(browser.detectedStreams) { s in
                    Button(s.displayName) { sendStream(s) }
                }
            }
            let capturable = browser.detectedStreams.filter(\.canSaveThroughBrowser)
            if !capturable.isEmpty {
                Section("Save through browser") {
                    ForEach(capturable) { s in
                        Button(s.displayName) { saveThroughBrowser(s) }
                    }
                }
            }
        }
        if !browser.detectedStreams.isEmpty {
            Button("Choose quality…") { openQualities() }
        }
        if browser.currentURL != nil {
            Button("Use page link") {
                browser.notePageLinkByHand()
                send()
            }
        }
    }

    @ViewBuilder
    private func actionLabel(_ title: String, _ icon: String, _ compact: Bool) -> some View {
        if compact { Image(systemName: icon).accessibilityLabel(title) } else { Label(title, systemImage: icon) }
    }

    private func send() {
        guard let url = browser.currentURL else { return }
        let title = browser.title
        browser.clearDetectedStreams()
        Task {
            let cookies = await browser.exportCookies(for: [url])
            await appState.downloadFromBrowser(url.absoluteString, title: title, cookiesFile: cookies, using: queueManager.ytdlpService)
        }
    }

    /// Streams go straight to the Downloads list and run in the background, so browsing can go on.
    /// yt-dlp is tried first; if the site refuses it, the same item switches to the browser engine.
    private func sendStream(_ stream: DetectedStream) {
        queueStream(stream, viaBrowser: false)
    }

    /// Fetch the stream from inside the page (same cookies, Referer and connection as the site's player).
    private func saveThroughBrowser(_ stream: DetectedStream) {
        queueStream(stream, viaBrowser: true)
    }

    private func queueStream(_ stream: DetectedStream, viaBrowser: Bool, message: String? = nil, maxHeight: Int? = nil) {
        let pageTitle = stream.title.isEmpty ? browser.title : stream.title
        Task {
            // The stream is usually on a CDN host, so send cookies for both it and the page.
            let cookies = viaBrowser ? nil
                : await browser.exportCookies(for: [stream.url, stream.pageURL].compactMap(URL.init(string:)))
            queueManager.enqueueStream(url: stream.url, title: pageTitle, pageURL: stream.pageURL, isHLS: stream.type == .hls,
                                       outputDir: appState.outputDirectory, frame: stream.frame,
                                       cookiesFile: cookies, viaBrowser: viaBrowser, maxHeight: maxHeight)
            browser.statusMessage = message
                ?? "Added to Downloads: \(pageTitle.isEmpty ? stream.displayName : pageTitle). You can keep browsing."
        }
    }

    private func syncAddress() { address = browser.currentURL?.absoluteString ?? "" }
}
