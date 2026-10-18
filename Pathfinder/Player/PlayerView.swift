import AVKit
import SwiftUI

/// The Player tab: the picture on the left, the playlist on the right. The player lives in `PlayerModel`,
/// so the playlist and the place in the video survive a trip to another tab.
struct PlayerTabView: View {
    @Environment(PlayerModel.self) private var model
    @FocusState private var focused: Bool
    @State private var dropTargeted = false
    @State private var lastPointer = CGPoint.zero
    @State private var lastTap = Date.distantPast
    @State private var stageSize = CGSize.zero
    @State private var hoverSide: Side?
    @State private var peekCloseTask: Task<Void, Never>?
    private enum Side { case left, right }
    /// The window's size before it was fitted to a video, to give back when leaving the tab.
    @State private var originalFrame: NSRect?
    private static let sidebarWidth: CGFloat = 320

    var body: some View {
        HStack(spacing: 0) {
            stage
            // A file that can't play brings the playlist back, so there is always somewhere to go.
            if !model.isFullScreen, !model.floatsPlaylist,
               model.showPlaylist || model.status == .idle || model.status.isProblem {
                Divider()
                PlaylistSidebar(model: model).frame(width: Self.sidebarWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.showPlaylist)
        .overlay(alignment: .trailing) { floatingPlaylist }
        .animation(.easeOut(duration: 0.2), value: model.playlistPeek)
        .clipped()
        .background(Theme.bg)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .background(Theme.accentSoft).padding(8).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.addURLs(files, playNow: model.currentPath == nil)
            return true
        } isTargeted: { dropTargeted = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in model.isFullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in model.isFullScreen = false }
        .onChange(of: model.videoAspect) { _, aspect in if let aspect { fitWindow(toAspect: aspect) } }
        .onChange(of: model.showPlaylist) { _, shown in resizeForPlaylist(shown: shown) }
        // The docked list leaves when a video starts (the window gives back its width) and returns for a problem file.
        .onChange(of: model.floatsPlaylist) { _, floats in
            if model.showPlaylist { resizeForPlaylist(shown: !floats) }
        }
        // A new video starts with the list out of the way.
        .onChange(of: model.currentPath) { _, _ in
            peekCloseTask?.cancel()
            model.playlistPeek = false
        }
        // Opened by the button or L the pointer is elsewhere, so the 2 s countdown starts now; reaching the list cancels it.
        .onChange(of: model.playlistPeek) { _, open in
            if open { peekHovered(false) } else { peekCloseTask?.cancel() }
        }
        .task {
            // Coming back to the tab with a video loaded: fit again once the layout is known.
            try? await Task.sleep(for: .milliseconds(200))
            if let aspect = model.videoAspect { fitWindow(toAspect: aspect) }
        }
        .onDisappear {
            model.leaveTab()
            restoreWindow()
        }
    }

    /// While a video plays the playlist floats over the picture. It opens only from the playlist button (or L),
    /// never from the pointer passing the edge, and closes 2 s after the pointer leaves it (or at once when the
    /// picture is clicked).
    @ViewBuilder private var floatingPlaylist: some View {
        if model.floatsPlaylist, !model.isFullScreen, model.playlistPeek {
            HStack(spacing: 0) {
                Divider()
                PlaylistSidebar(model: model).frame(width: Self.sidebarWidth)
            }
            .shadow(color: .black.opacity(0.35), radius: 10, x: -3)
            .transition(.move(edge: .trailing))
            .onHover { inside in peekHovered(inside) }
        }
    }

    private func peekHovered(_ inside: Bool) {
        peekCloseTask?.cancel()
        guard !inside else { return }
        peekCloseTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            model.playlistPeek = false
        }
    }

    /// Changes the window's height by exactly what the picture needs at the current stage width, keeping the top
    /// edge in place, so there are no empty bands above and below the video.
    private func fitWindow(toAspect aspect: Double) {
        guard stageSize.width > 0, let window = NSApp.keyWindow ?? NSApp.mainWindow,
              !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main else { return }
        let delta = (stageSize.width / aspect).rounded() - stageSize.height
        guard abs(delta) > 1 else { return }
        if originalFrame == nil { originalFrame = window.frame }
        let height = min(max(window.frame.height + delta, window.minSize.height), screen.visibleFrame.height)
        var frame = window.frame
        frame.origin.y = max(frame.origin.y + frame.height - height, screen.visibleFrame.minY)
        frame.size.height = height
        window.setFrame(frame, display: true, animate: true)
    }

    /// Hiding the playlist makes the window narrower by the sidebar's width (showing it, wider), so the picture
    /// keeps its size; then the height is fitted again.
    private func resizeForPlaylist(shown: Bool) {
        guard model.status != .idle, let window = NSApp.keyWindow ?? NSApp.mainWindow,
              !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main else { return }
        if originalFrame == nil { originalFrame = window.frame }
        let change = Self.sidebarWidth + 1
        var frame = window.frame
        let width = shown ? frame.width + change : frame.width - change
        frame.size.width = min(max(width, shown ? 700 : window.minSize.width), screen.visibleFrame.width)
        frame.origin.x = min(frame.origin.x, screen.visibleFrame.maxX - frame.width)
        window.setFrame(frame, display: true, animate: true)
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            if let aspect = model.videoAspect { fitWindow(toAspect: aspect) }
        }
    }

    private func restoreWindow() {
        guard let frame = originalFrame else { return }
        originalFrame = nil
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, !window.styleMask.contains(.fullScreen) else { return }
        window.setFrame(frame, display: true, animate: true)
    }

    private var stage: some View {
        ZStack {
            Theme.bg
            stageContent
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat, .up]) { model.handle($0) }
        .onAppear { focused = true }
        .onChange(of: model.currentPath) { _, _ in focused = true }
        .onChange(of: focused) { _, isFocused in if !isFocused { model.releaseKeys() } }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { stageSize = geo.size }
                    .onChange(of: geo.size) { _, size in stageSize = size }
            }
        }
    }

    @ViewBuilder private var stageContent: some View {
        switch model.status {
        case .idle:
            EmptyStage(model: model)
        case .loading:
            ProgressView().controlSize(.large)
        case .unsupported:
            message(icon: "film.stack", title: "This format needs another player",
                    detail: "The built-in player can't decode this file yet. Pick another item, or open it with the app your Mac uses for it.",
                    action: ("Open with Default App", model.openExternally))
        case .failed(let reason):
            message(icon: "exclamationmark.triangle", title: "Can't play this file", detail: reason, action: nil)
        case .ready:
            playback
        }
    }

    private func message(icon: String, title: String, detail: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(Theme.text3)
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            Text(detail).font(.system(size: 13)).foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            if let action {
                Button(action.0, action: action.1).buttonStyle(PrimaryButtonStyle(height: 34))
            }
            HStack(spacing: 8) {
                Button { model.closeCurrent() } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(SecondaryButtonStyle(height: 34))
                if model.hasNext {
                    Button { model.next() } label: { Label("Next", systemImage: "forward.end.fill") }
                        .buttonStyle(SecondaryButtonStyle(height: 34))
                }
            }
        }
        .padding(24)
    }

    private var playback: some View {
        ZStack {
            VideoSurface(player: model.player)
            if !model.hasVideo {
                Image(systemName: "music.note").font(.system(size: 64)).foregroundStyle(Theme.text3)
            }
            PlayerHUDs(model: model)
            sideSkips
            PlayerControls(model: model)
                .opacity(model.controlsVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: model.controlsVisible)
                .allowsHitTesting(model.controlsVisible)
        }
        .contentShape(Rectangle())
        // A tap on any part of the picture without a control of its own plays or pauses. Two quick taps also go
        // full screen; the first one has already acted, so nothing waits for the second.
        .onTapGesture {
            focused = true
            if model.playlistPeek { peekCloseTask?.cancel(); model.playlistPeek = false }
            let now = Date()
            model.togglePlay()
            if now.timeIntervalSince(lastTap) < 0.3 {
                model.togglePlay()
                model.toggleFullScreen()
                lastTap = .distantPast
            } else {
                lastTap = now
            }
        }
        .onContinuousHover { phase in
            guard case .active(let point) = phase else { hoverSide = nil; return }
            let side: Side? = point.x < stageSize.width * 0.3 ? .left : (point.x > stageSize.width * 0.7 ? .right : nil)
            if side != hoverSide { hoverSide = side }
            // Only real movement counts: fading the controls re-sends a hover at the same spot.
            guard hypot(point.x - lastPointer.x, point.y - lastPointer.y) > 3 else { return }
            lastPointer = point
            model.pokeControls()
        }
    }

    /// Skip buttons on the left and right of the picture, shown while the pointer is on that side.
    private var sideSkips: some View {
        HStack {
            skipButton(forward: false).opacity(hoverSide == .left ? 1 : 0).allowsHitTesting(hoverSide == .left)
            Spacer()
            skipButton(forward: true).opacity(hoverSide == .right ? 1 : 0).allowsHitTesting(hoverSide == .right)
        }
        .padding(.horizontal, max(stageSize.width * 0.1, 24))
        .animation(.easeOut(duration: 0.15), value: hoverSide)
    }

    private func skipButton(forward: Bool) -> some View {
        let seconds = model.settings.playerTapSeekSeconds
        return Button { model.skip(by: forward ? Double(seconds) : -Double(seconds)) } label: {
            Image(systemName: skipSymbol(forward: forward, seconds: seconds))
                .font(.system(size: 30)).foregroundStyle(.white)
                .frame(width: 66, height: 66)
                .background(Color.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .help(forward ? "Forward \(seconds) s" : "Back \(seconds) s")
        .accessibilityLabel(forward ? "Forward \(seconds) seconds" : "Back \(seconds) seconds")
    }
}

/// SF Symbols only has numbered skip arrows for some values.
private func skipSymbol(forward: Bool, seconds: Int) -> String {
    let base = forward ? "goforward" : "gobackward"
    return [5, 10, 15, 30, 45, 60, 75, 90].contains(seconds) ? "\(base).\(seconds)" : base
}

// MARK: - Empty state

private struct EmptyStage: View {
    let model: PlayerModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.rectangle.fill").font(.system(size: 44)).foregroundStyle(Theme.accentText)
            Text(model.playlist.isEmpty ? "Add videos to start" : "Pick a video")
                .font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.text)
            Text(!model.playlist.isEmpty
                 ? "Choose one from the playlist, or add more files."
                 : model.settings.playDisguisedVideos
                 ? "Drop files or a folder anywhere. Videos saved under another extension play too."
                 : "Drop video or audio files, or a folder, anywhere in this window.")
                .font(.system(size: 13)).foregroundStyle(Theme.text2).multilineTextAlignment(.center).frame(maxWidth: 360)
            HStack(spacing: 8) {
                Button { PlayerLauncher.chooseFiles(model: model, playNow: true) } label: {
                    Label("Add Files…", systemImage: "doc.badge.plus")
                }
                .buttonStyle(PrimaryButtonStyle(height: 36))
                Button { PlayerLauncher.chooseFolder(model: model, playNow: true) } label: {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(SecondaryButtonStyle(height: 36))
            }
            if model.isScanning { ProgressView().controlSize(.small) }
            keys.padding(.top, 10)
        }
        .padding(24)
    }

    private var keys: some View {
        VStack(alignment: .leading, spacing: 5) {
            keyRow("← →", "Tap to skip, hold to speed up (2× to 16×)")
            keyRow("↑ ↓", "Volume, slowly")
            keyRow("⌫", "Go back after a jump")
            keyRow("Space M F", "Play · mute · full screen")
            keyRow("N P", "Next · previous")
        }
    }

    private func keyRow(_ keys: String, _ what: String) -> some View {
        HStack(spacing: 12) {
            Text(keys).font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.accentText).frame(width: 88, alignment: .trailing)
            Text(what).font(.system(size: 12.5)).foregroundStyle(Theme.text3)
        }
    }
}

// MARK: - Playlist

private struct PlaylistSidebar: View {
    let model: PlayerModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.playlist.isEmpty {
                VStack(spacing: 6) {
                    Text("No videos yet").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
                    Text("Add files or a folder to build a list.").font(.system(size: 12.5)).foregroundStyle(Theme.text3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.playlist) { entry in
                            PlaylistRow(entry: entry, isCurrent: entry.path == model.currentPath,
                                        isPlaying: entry.path == model.currentPath && model.isPlaying, model: model)
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
            }
            footer
        }
        .background(Theme.surface)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Playlist").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text(model.playlist.isEmpty ? "Empty" : "\(model.playlist.count) item\(model.playlist.count == 1 ? "" : "s")")
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            Spacer()
            Menu {
                Button("Add Files…") { PlayerLauncher.chooseFiles(model: model, playNow: false) }
                Button("Add Folder…") { PlayerLauncher.chooseFolder(model: model, playNow: false) }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .buttonStyle(IconButtonStyle()).help("Add files or a folder")
            .accessibilityLabel("Add to playlist")
            Button { model.clear() } label: { Image(systemName: "trash") }
                .buttonStyle(IconButtonStyle()).disabled(model.playlist.isEmpty)
                .help("Clear the playlist").accessibilityLabel("Clear playlist")
            if model.status != .idle {
                Button { model.togglePlaylist() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(IconButtonStyle()).help("Hide playlist (L)").accessibilityLabel("Hide playlist")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isScanning {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading files…").font(.system(size: 12)).foregroundStyle(Theme.text2) }
            }
            if let notice = model.notice {
                HStack(alignment: .top, spacing: 8) {
                    Text(notice.text).font(.system(size: 12)).foregroundStyle(Theme.warnText)
                    Spacer(minLength: 0)
                    Button { model.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.text3).accessibilityLabel("Dismiss")
                }
                if notice.offersSettings {
                    Button("Open Settings") { PlayerLauncher.openSettings() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accentText)
                }
            }
            HStack {
                Text("N next · P previous").font(.system(size: 12)).foregroundStyle(Theme.text3)
                Spacer()
                Button("+ Add files") { PlayerLauncher.chooseFiles(model: model, playNow: false) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accentText)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct PlaylistRow: View {
    let entry: PlayerRequest
    let isCurrent: Bool
    let isPlaying: Bool
    let model: PlayerModel
    @State private var hovering = false

    var body: some View {
        Button { model.play(entry) } label: {
            HStack(spacing: 10) {
                Image(systemName: isCurrent ? (isPlaying ? "speaker.wave.2.fill" : "pause.fill") : "film")
                    .font(.system(size: 14)).foregroundStyle(isCurrent ? Theme.accentText : Theme.text3)
                    .frame(width: 44, height: 44)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.leading)
                    Text(entry.kind).font(.system(size: 11.5, weight: entry.badge == nil ? .regular : .semibold))
                        .foregroundStyle(entry.badge == nil ? Theme.text3 : Theme.warnText)
                }
                Spacer(minLength: 0)
                if hovering {
                    Button { model.remove(entry) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.text3)
                        .help("Remove from playlist").accessibilityLabel("Remove from playlist")
                }
            }
            .padding(8)
            .background(isCurrent ? Theme.accentSoft : (hovering ? Theme.surface2 : .clear), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(isCurrent ? Theme.accentBorder : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Remove from Playlist") { model.remove(entry) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
        }
    }
}

// MARK: - Video

private struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// Draws the picture on a transparent layer, so the bars around it show the app's background (light or dark),
/// and nothing else: keys and clicks stay with the SwiftUI layer above it.
private final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Controls

private enum Overlay {
    static let amber = Color(red: 0.984, green: 0.749, blue: 0.141)
    static let panel = Color.black.opacity(0.74)
    static let line = Color.white.opacity(0.16)
    static let quiet = Color.white.opacity(0.72)
}

/// Controls drawn straight over the picture on a dark fade, like a streaming player. They hide when the
/// pointer rests; moving it, pressing a key or pausing brings them back.
private struct PlayerControls: View {
    let model: PlayerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let badge = model.badge {
                    Text(badge).font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Overlay.amber)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Overlay.amber.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 56)
            .background(LinearGradient(colors: [.black.opacity(model.badge == nil ? 0 : 0.5), .clear], startPoint: .top, endPoint: .bottom))

            Spacer(minLength: 0)

            VStack(spacing: 0) {
                HStack {
                    Text(PlayerTime.format(model.position))
                    Spacer()
                    Text("−" + PlayerTime.format(max(model.duration - model.position, 0)))
                }
                .font(.system(size: 12.5, design: .monospaced))
                .padding(.horizontal, 20)
                SeekBar(model: model)
                HStack(spacing: 0) {
                    button(model.isPlaying ? "pause.fill" : "play.fill", model.isPlaying ? "Pause (Space)" : "Play (Space)", size: 24) { model.togglePlay() }
                    scanButton(forward: false)
                    scanButton(forward: true)
                    VolumeControl(model: model)
                    Spacer(minLength: 12)
                    Text(model.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(Overlay.quiet)
                    Spacer(minLength: 12)
                    button("backward.end.fill", "Previous (P)", size: 18) { model.previous() }
                    button("forward.end.fill", "Next (N)", size: 18) { model.next() }
                    speedMenu
                    button("sidebar.right", model.playlistVisible ? "Hide playlist (L)" : "Show playlist (L)", size: 18) { model.togglePlaylist() }
                    button("arrow.up.left.and.arrow.down.right", "Full screen (F)", size: 18) { model.toggleFullScreen() }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 10).padding(.top, 72)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.62), .black.opacity(0.86)], startPoint: .top, endPoint: .bottom))
            .onHover { inside in
                model.pointerOverControls = inside
                if !inside { model.pokeControls() }
            }
        }
        .foregroundStyle(.white)
    }

    /// ⏪ / ⏩: click for 2×, click again for faster; shows the speed it is at while it is on.
    private func scanButton(forward: Bool) -> some View {
        let scan = model.scrub
        let active = scan?.sticky == true && scan?.forward == forward
        return Button { model.scanStep(forward: forward) } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: forward ? "forward.fill" : "backward.fill").font(.system(size: 18))
                    .foregroundStyle(active ? Theme.accent : .white)
                    .frame(width: 42, height: 42)
                if active, let scan {
                    Text("\(scan.speed)×").font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Theme.btn, in: Capsule()).offset(x: 2, y: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(forward ? "Fast forward: click again for faster (up to 64×)" : "Rewind: click again for faster (up to 64×)")
        .accessibilityLabel(forward ? "Fast forward" : "Rewind")
    }

    private func button(_ symbol: String, _ label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).frame(width: 42, height: 42).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(PlayerModel.rates, id: \.self) { value in
                Button { model.setRate(value) } label: {
                    Text(String(format: "%g×", value)) + Text(model.rate == value ? "  ✓" : "")
                }
            }
        } label: {
            Text(String(format: "%g×", model.rate))
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10).frame(height: 28)
                .overlay(Capsule().stroke(.white.opacity(0.45)))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(.horizontal, 6)
        .accessibilityLabel("Playback speed")
    }
}

/// The mute button; resting the pointer on it opens a vertical bar that shows the level and can be dragged.
private struct VolumeControl: View {
    let model: PlayerModel
    @State private var overButton = false
    @State private var overBar = false
    @State private var open = false
    @State private var closeTask: Task<Void, Never>?

    private var muted: Bool { model.isMuted || model.volumePercent == 0 }

    var body: some View {
        Button { model.toggleMute() } label: {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 20)).frame(width: 42, height: 42).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Mute (M)").accessibilityLabel("Mute (M)")
        .onHover { overButton = $0; update() }
        .overlay(alignment: .bottom) {
            if open {
                VolumeBar(model: model)
                    .onHover { overBar = $0; update() }
                    .offset(y: -46)
            }
        }
    }

    /// A short delay lets the pointer cross the gap between the button and the bar.
    private func update() {
        closeTask?.cancel()
        if overButton || overBar { open = true } else {
            closeTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { open = false }
            }
        }
    }
}

private struct VolumeBar: View {
    let model: PlayerModel

    var body: some View {
        let level = model.isMuted ? 0 : model.volumePercent / 100
        VStack(spacing: 8) {
            Text("\(Int((level * 100).rounded()))%").font(.system(size: 12, weight: .bold, design: .monospaced))
            GeometryReader { geo in
                let height = max(geo.size.height, 1)
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.25)).frame(width: 5)
                    Capsule().fill(Theme.accent).frame(width: 5, height: height * level)
                    Circle().fill(.white).frame(width: 13, height: 13)
                        .offset(y: 6.5 - height * level)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    model.setVolume((1 - value.location.y / height) * 100)
                })
            }
            .frame(width: 28, height: 120)
        }
        .padding(.vertical, 10).padding(.horizontal, 8)
        .background(Overlay.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Overlay.line))
        .foregroundStyle(.white)
    }
}

private struct SeekBar: View {
    let model: PlayerModel
    @State private var hoverX: CGFloat?
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let fraction = model.duration > 0 ? min(model.position / model.duration, 1) : 0
            let active = hoverX != nil || dragging
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3)).frame(height: active ? 6 : 4)
                Capsule().fill(Theme.accent).frame(width: width * fraction, height: active ? 6 : 4)
                Circle().fill(Theme.accent).frame(width: 14, height: 14)
                    .scaleEffect(active ? 1 : 0.01)
                    .offset(x: min(max(width * fraction, 7), width - 7) - 7)
            }
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.12), value: active)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragging = true
                    model.userSeeking = true
                    model.seek(toFraction: value.location.x / width, precise: false)
                }
                .onEnded { value in
                    model.seek(toFraction: value.location.x / width, precise: true)
                    model.userSeeking = false
                    dragging = false
                })
            .onContinuousHover { phase in
                if case .active(let point) = phase { hoverX = point.x } else { hoverX = nil }
            }
            .overlay(alignment: .topLeading) {
                if let hoverX, model.duration > 0 {
                    Text(PlayerTime.format(Double(hoverX / width) * model.duration))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Overlay.panel, in: RoundedRectangle(cornerRadius: 6))
                        .offset(x: min(max(hoverX - 28, 0), width - 60), y: -30)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 22)
    }
}

// MARK: - HUDs

private struct PlayerHUDs: View {
    let model: PlayerModel

    var body: some View {
        ZStack {
            if let scrub = model.scrub {
                ScrubHUD(info: scrub, rate: model.rate)
            }
            if let volume = model.volumeHUD {
                VolumeHUD(percent: volume).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 28)
            }
            if let flash = model.flash, model.scrub == nil {
                Text(flash).font(.system(size: 20, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Overlay.panel, in: Capsule())
            }
            if let undo = model.undo {
                UndoToast(info: undo, rate: model.rate) { model.undoJump() }
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 120)
            }
        }
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.15), value: model.scrub)
        .animation(.easeOut(duration: 0.15), value: model.volumeHUD)
        .animation(.easeOut(duration: 0.15), value: model.undo)
    }
}

private struct ScrubHUD: View {
    let info: ScrubInfo
    let rate: Float

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: info.forward ? "forward.fill" : "backward.fill").font(.system(size: 20))
                Text("\(info.speed)×").font(.system(size: 30, weight: .bold, design: .monospaced))
                Text((info.delta >= 0 ? "+" : "−") + PlayerTime.format(abs(info.delta)))
                    .font(.system(size: 15, design: .monospaced)).foregroundStyle(Overlay.quiet)
                if info.muted {
                    Label("Scrub", systemImage: "speaker.slash.fill").font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Overlay.amber)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Overlay.amber.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            // The ladder is only for a held key, where ↑ ↓ pick the level; a button scan shows just its speed.
            if !info.sticky { ladder }
            Text(info.sticky ? "⏪ ⏩ change speed · Space or a tap pauses"
                             : "↑ ↓ change level · release returns to \(String(format: "%g", rate))×")
                .font(.system(size: 12)).foregroundStyle(Overlay.quiet)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(Overlay.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Overlay.line))
    }

    private var ladder: some View {
        HStack(spacing: 5) {
            ForEach(Array(HoldRamp.speeds.enumerated()), id: \.offset) { index, speed in
                let reached = index <= info.speedIndex
                Text("\(speed)×").font(.system(size: 12, weight: index == info.speedIndex ? .bold : .semibold))
                    .frame(width: 40, height: 26)
                    .background(index == info.speedIndex ? Theme.btn : (reached ? Theme.accent.opacity(0.25) : .clear),
                                in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(reached ? .clear : .white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: index >= 3 ? [3, 3] : [])))
            }
        }
    }
}

private struct VolumeHUD: View {
    let percent: Int

    var body: some View {
        VStack(spacing: 12) {
            Text("\(percent)%").font(.system(size: 15, weight: .bold, design: .monospaced))
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.25)).frame(width: 8, height: 160)
                Capsule().fill(Theme.accent).frame(width: 8, height: 160 * CGFloat(percent) / 100)
            }
            Image(systemName: percent == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 16))
        }
        .padding(.vertical, 14).frame(width: 64)
        .background(Overlay.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Overlay.line))
    }
}

private struct UndoToast: View {
    let info: UndoInfo
    let rate: Float
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.right").foregroundStyle(Theme.accentText)
            VStack(alignment: .leading, spacing: 2) {
                Text("Jumped \(PlayerTime.format(info.from)) → \(PlayerTime.format(info.to))")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("Back to \(String(format: "%g", rate))×").font(.system(size: 12)).foregroundStyle(Overlay.quiet)
            }
            Button(action: action) {
                Text("Go back  ⌫").font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Theme.btn, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Overlay.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Overlay.line))
    }
}
