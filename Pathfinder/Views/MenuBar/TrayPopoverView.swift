import SwiftUI
import AppKit

/// The panel that opens from the menu bar icon: quick download, running downloads and recent files.
struct TrayPopoverView: View {
    @Environment(TrayController.self) private var tray
    @Environment(QueueManager.self) private var queue
    @Environment(SettingsStore.self) private var settings
    @State private var link = ""

    /// The panel shows at most this many downloads and recent files; "See all" opens the window.
    private let maxActive = 3
    private let maxRecent = 3

    private var active: [DownloadItem] {
        queue.items.filter { [.queued, .analyzing, .downloading, .postProcessing, .paused].contains($0.status) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            quickDownload
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                if let clip = tray.clipboardLink { clipboardCard(clip) }
                downloading
                if !tray.recentItems.isEmpty { recent }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            Divider()
            footer
        }
        .frame(width: 380)
        .background(Theme.elevated)
        .foregroundStyle(Theme.text)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Theme.btn, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text("Pathfinder").font(.system(size: 14, weight: .semibold))
                Text(TrayController.summary(queue: queue, pending: tray.pending.count))
                    .font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            Button { tray.openMainWindow() } label: { Image(systemName: "macwindow") }
                .buttonStyle(IconButtonStyle())
                .help("Open Pathfinder")
                .accessibilityLabel("Open Pathfinder")
            Button { tray.openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(IconButtonStyle())
                .help("Settings")
                .accessibilityLabel("Settings")
        }
        .font(.system(size: 14))
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: Quick download

    private var quickDownload: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "link").foregroundStyle(Theme.text3)
                    TextField("Paste a link to download", text: $link)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .onSubmit(submit)
                        .accessibilityLabel("Video link")
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(tray.linkError == nil ? Theme.border : Theme.danger))

                // Secondary while the clipboard card offers its own primary button.
                if tray.clipboardLink == nil {
                    Button(action: submit) { Label("Download", systemImage: "arrow.down.to.line") }
                        .buttonStyle(PrimaryButtonStyle(height: 34))
                } else {
                    Button(action: submit) { Label("Download", systemImage: "arrow.down.to.line") }
                        .buttonStyle(SecondaryButtonStyle(height: 34))
                }
            }
            if let error = tray.linkError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                Text("Quick download saves as").foregroundStyle(Theme.text3)
                Text(settings.quickPreset.title).fontWeight(.semibold).foregroundStyle(Theme.text2)
                Text("·").foregroundStyle(Theme.text3)
                Menu {
                    Picker("Quick download", selection: Bindable(settings).quickPreset) {
                        ForEach(QuickPreset.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text("Change").fontWeight(.semibold).foregroundStyle(Theme.accentText)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Change quick download format")
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .onChange(of: link) { _, _ in tray.linkError = nil }
    }

    private func submit() {
        if tray.quickDownload(link) { link = "" }
    }

    // MARK: Clipboard

    private func clipboardCard(_ url: String) -> some View {
        let video = settings.quickPreset.isAudio ? QuickPreset.video1080 : settings.quickPreset
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Video link in your clipboard").font(.system(size: 13, weight: .semibold))
                    Text(TrayController.shortLink(url))
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Button { tray.dismissClipboardLink() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle())
                    .padding(.top, -6).padding(.trailing, -6)
                    .accessibilityLabel("Dismiss suggestion")
            }
            HStack(spacing: 8) {
                Button { tray.quickDownload(url, preset: video) } label: {
                    Label(video.title, systemImage: "play.rectangle").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(height: 32))
                Button { tray.quickDownload(url, preset: .audioMP3) } label: {
                    Label(QuickPreset.audioMP3.title, systemImage: "music.note").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(height: 32))
            }
        }
        .padding(14)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accentBorder))
    }

    // MARK: Downloading

    private var downloading: some View {
        let count = active.count + tray.pending.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionTitle("Downloading")
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.accentText)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.accentSoft, in: Capsule())
                }
                Spacer()
                if count > maxActive {
                    seeAll
                }
            }
            if count == 0 {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.text3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nothing downloading").font(.system(size: 13, weight: .semibold))
                        Text("Copy a video link and it will show up here.")
                            .font(.system(size: 12)).foregroundStyle(Theme.text2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                ForEach(tray.pending.prefix(maxActive)) { PendingCard(item: $0) }
                ForEach(active.prefix(max(0, maxActive - tray.pending.count))) { TrayDownloadCard(item: $0) }
            }
        }
    }

    // MARK: Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionTitle("Recent")
                Spacer()
                seeAll
            }
            .padding(.bottom, 4)
            ForEach(tray.recentItems.prefix(maxRecent)) { TrayRecentRow(item: $0) }
        }
    }

    private var seeAll: some View {
        Button("See all") { tray.openMainWindow() }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.accentText)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text2)
    }

    // MARK: Footer

    private var footer: some View {
        let waiting = queue.items.contains { [.queued, .analyzing, .downloading].contains($0.status) }
        let paused = queue.items.contains { $0.status == .paused }
        return HStack {
            if !waiting && paused {
                Button { queue.resumeAll() } label: { Label("Resume all", systemImage: "play.fill") }
                    .foregroundStyle(Theme.text)
            } else {
                Button { queue.pauseAll() } label: { Label("Pause all", systemImage: "pause.fill") }
                    .foregroundStyle(waiting ? Theme.text : Theme.text3)
                    .disabled(!waiting)
            }
            Spacer()
            Button { tray.openDownloadsFolder() } label: { Label("Open downloads folder", systemImage: "folder") }
                .foregroundStyle(Theme.text)
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 20).padding(.vertical, 13)
    }
}

// MARK: - Rows

/// A thin rounded progress bar.
struct TrayProgressBar: View {
    var value: Double   // 0...1
    var color: Color = Theme.accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 4)
    }
}

private struct TrayDownloadCard: View {
    let item: DownloadItem
    @Environment(QueueManager.self) private var queue
    @Environment(SettingsStore.self) private var settings

    private var title: String { item.displayTitle(masked: settings.maskDownloadTitles) }

    private var isWaiting: Bool { [.queued, .analyzing, .paused].contains(item.status) }

    private var meta: String {
        switch item.status {
        case .downloading:
            var parts: [String] = []
            if let d = item.downloadedSize, let t = item.totalSize { parts.append("\(d) / \(t)") }
            if let s = item.speed, !s.isEmpty { parts.append(s) }
            if let e = item.eta, !e.isEmpty { parts.append("\(e) left") }
            return parts.isEmpty ? "Starting…" : parts.joined(separator: " • ")
        case .postProcessing: return [item.totalSize, "Merging files…"].compactMap { $0 }.joined(separator: " • ")
        case .queued, .analyzing: return "Queued • starts when a download finishes"
        case .paused: return "Paused"
        case .completed, .failed: return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int(item.progress))%")
                    .font(.system(size: 13.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(isWaiting ? Theme.text3 : Theme.text)
            }
            if item.status == .postProcessing {
                ProgressView().progressViewStyle(.linear).tint(Theme.accent).controlSize(.small)
            } else {
                TrayProgressBar(value: item.progress / 100, color: item.status == .paused ? Theme.text3 : Theme.accent)
            }
            HStack(spacing: 4) {
                Text(meta)
                    .font(.system(size: 12))
                    .foregroundStyle(isWaiting && item.status != .paused ? Theme.warnText : Theme.text2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                switch item.status {
                case .downloading:
                    Button { queue.pause(item.id) } label: { Image(systemName: "pause.fill") }
                        .buttonStyle(IconButtonStyle()).accessibilityLabel("Pause")
                case .paused:
                    Button { queue.resume(item.id) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(IconButtonStyle()).accessibilityLabel("Resume")
                default:
                    EmptyView()
                }
                if item.status != .postProcessing {
                    Button { queue.cancel(item.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle()).accessibilityLabel("Cancel download")
                }
            }
            .frame(minHeight: 24)
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A link being looked up before it joins the queue.
private struct PendingCard: View {
    let item: PendingDownload
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(settings.maskDownloadTitles ? "New download" : TrayController.shortLink(item.url))
                .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            ProgressView().progressViewStyle(.linear).tint(Theme.accent).controlSize(.small)
            Text("Getting video info • \(item.preset.title)")
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct TrayRecentRow: View {
    let item: DownloadItem
    @Environment(QueueManager.self) private var queue
    @Environment(SettingsStore.self) private var settings

    private var failed: Bool { item.status == .failed }

    /// "412 MB · Today, 14:05" or "Connection lost · 12 min ago"
    private var meta: String {
        let when = TrayController.when(item.completedAt ?? item.createdAt)
        if failed {
            let reason = (item.error ?? "Failed").split(separator: ".").first.map(String.init) ?? "Failed"
            return "\(reason) · \(when)"
        }
        return [TrayController.fileSize(of: item), when].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: failed ? "exclamationmark" : (item.options.extractAudio ? "music.note" : "play.rectangle"))
                .font(.system(size: 14, weight: failed ? .bold : .medium))
                .foregroundStyle(failed ? Theme.dangerText : Theme.successText)
                .frame(width: 36, height: 36)
                .background(failed ? Theme.dangerSoft : Theme.successSoft, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayFileName(masked: settings.maskDownloadTitles)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(meta).font(.system(size: 12)).foregroundStyle(failed ? Theme.dangerText : Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 4)
            if failed {
                Button { queue.retry(item.id) } label: { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(PrimaryButtonStyle(height: 28))
            } else {
                Button { TrayController.openFile(item) } label: { Image(systemName: "play") }
                    .buttonStyle(IconButtonStyle()).help("Open file").accessibilityLabel("Open file")
                Button { TrayController.revealFile(item) } label: { Image(systemName: "folder") }
                    .buttonStyle(IconButtonStyle()).help("Show in folder").accessibilityLabel("Show in folder")
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Quit confirmation

/// Shown when quitting while downloads are running.
struct QuitConfirmView: View {
    let items: [DownloadItem]
    let onKeep: () -> Void
    let onQuit: () -> Void
    @Environment(SettingsStore.self) private var settings

    private var message: String {
        let n = items.count
        let what = n == 1 ? "1 download is" : "\(n) downloads are"
        return "\(what) still running. If you quit now \(n == 1 ? "it" : "they") will stop, and you’ll need to resume \(n == 1 ? "it" : "them") next time."
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Theme.btn, in: RoundedRectangle(cornerRadius: 14))
            Text("Quit Pathfinder?").font(.system(size: 15, weight: .bold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !items.isEmpty {
                VStack(spacing: 10) {
                    ForEach(items.prefix(4)) { item in
                        HStack(spacing: 10) {
                            Text(item.displayTitle(masked: settings.maskDownloadTitles))
                                .font(.system(size: 12.5)).lineLimit(1)
                            Spacer(minLength: 4)
                            TrayProgressBar(value: item.progress / 100).frame(width: 50)
                            Text("\(Int(item.progress))%")
                                .font(.system(size: 12.5, weight: .bold).monospacedDigit())
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                }
                .padding(12)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(spacing: 8) {
                Button(action: onKeep) { Text("Keep Downloading").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButtonStyle(height: 34))
                    .keyboardShortcut(.defaultAction)
                Button(action: onQuit) {
                    Text("Quit Anyway").foregroundStyle(Theme.dangerText).frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(height: 34))
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 340)
        .background(Theme.elevated)
        .foregroundStyle(Theme.text)
        .onExitCommand(perform: onKeep)
    }
}
