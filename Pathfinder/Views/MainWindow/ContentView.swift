import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(QueueManager.self) private var queueManager
    @Environment(CommandBuilder.self) private var commandBuilder
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(LogStore.self) private var logStore
    @Environment(PresetManager.self) private var presetManager
    @Environment(AppUpdater.self) private var updater
    @State private var showVPN = false
    
    var body: some View {
        @Bindable var state = appState
        
        Group {
            if appState.section == .browser && settingsStore.showBrowserTab {
                BrowserView()
            } else if appState.section == .player {
                PlayerTabView()
            } else if appState.section == .settings {
                SettingsView()
            } else if appState.mode == .simple {
                SimpleRootView()
            } else {
                advancedBody
            }
        }
        // The mode switch only matters to the downloader, so it lives at the top of that page, not in the toolbar.
        .safeAreaInset(edge: .top, spacing: 0) {
            if appState.section == .downloader {
                HStack {
                    Spacer()
                    Picker("Mode", selection: $state.mode) {
                        Text("Simple").tag(AppMode.simple)
                        Text("Advanced").tag(AppMode.advanced)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 180)
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Theme.surface)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if appState.section != .settings, let release = updater.availableRelease {
                UpdateBanner(release: release)
            }
        }
        .toolbar {
            // One group of tabs in the middle, one small status button on the right.
            ToolbarItem(placement: .principal) {
                HStack(spacing: 4) {
                    FlatTab(title: "Downloader", tag: .downloader, selection: $state.section)
                    FlatTab(title: "Player", tag: .player, selection: $state.section)
                    if settingsStore.showBrowserTab {
                        FlatTab(title: "Browser", tag: .browser, selection: $state.section)
                    }
                    FlatTab(title: "Settings", tag: .settings, selection: $state.section)
                }
            }
            .flatToolbarItem()
            ToolbarItem(placement: .primaryAction) { VPNToolbarButton(open: $showVPN) }
                .flatToolbarItem()
        }
        // Drawn inside the window (a system popover is a glass bubble that can leave the app frame).
        .overlay(alignment: .topTrailing) {
            if showVPN {
                ZStack(alignment: .topTrailing) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { showVPN = false }
                    VPNPopover { showVPN = false }.padding(.top, 6).padding(.trailing, 10)
                }
            }
        }
        .onAppear { SettingsTab.opener = { appState.section = .settings } }
        .onChange(of: appState.mode) { _, mode in settingsStore.appMode = mode }
        .sheet(isPresented: $state.showSetupAssistant) {
            SetupAssistantSheet()
        }
        .task {
            let status = await DependencyChecker.check()
            if !status.isReady { appState.showSetupAssistant = true }
        }
    }

    @ViewBuilder
    private var advancedBody: some View {
        @Bindable var state = appState
        NavigationSplitView {
            SidebarView()
        } detail: {
            VStack(spacing: 0) {
                URLInputView()
                    .padding()
                
                Divider()
                
                if appState.mode == .advanced, appState.listing != nil {
                    ListingView(embedded: true)
                        .padding(.horizontal)
                } else if appState.mode == .advanced {
                    TabView(selection: $state.selectedTab) {
                        FormatTabView()
                            .tabItem { Text("Format") }
                            .tag(OptionsTab.format)
                        
                        PostProcessingTabView()
                            .tabItem { Text("Post-Processing") }
                            .tag(OptionsTab.postProcessing)
                        
                        SubtitlesTabView()
                            .tabItem { Text("Subtitles") }
                            .tag(OptionsTab.subtitles)
                        
                        NetworkTabView()
                            .tabItem { Text("Network") }
                            .tag(OptionsTab.network)
                        
                        FilesystemTabView()
                            .tabItem { Text("Filesystem") }
                            .tag(OptionsTab.filesystem)
                        
                        AdvancedTabView()
                            .tabItem { Text("Advanced") }
                            .tag(OptionsTab.advanced)
                    }
                    .padding()
                } else {
                    Spacer()
                }
                
                Divider()
                
                CLIPreviewView()
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: {
                        guard !appState.currentURL.isEmpty else { return }
                        queueManager.enqueue(
                            url: appState.currentURL,
                            options: appState.downloadOptions,
                            outputDir: appState.outputDirectory,
                            videoInfo: appState.currentVideoInfo,
                            cookiesFile: appState.pendingCookiesFile,
                            referer: appState.pendingReferer
                        )
                    }) {
                        Label("Download", systemImage: "arrow.down.circle.fill")
                    }
                }
            }
        }
    }
}

/// A flat text tab: the active one is bold with an accent underline, no capsule or glass.
private struct FlatTab: View {
    let title: String
    let tag: AppSection
    @Binding var selection: AppSection

    var body: some View {
        let active = selection == tag
        Button { selection = tag } label: {
            Text(title)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.text : Theme.text3)
                .padding(.horizontal, 12).frame(height: 28)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(active ? Theme.accent : .clear).frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private extension ToolbarContent {
    /// Drops the glass capsule macOS 26 puts behind toolbar items.
    @ToolbarContentBuilder
    func flatToolbarItem() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
