import SwiftUI
import AppKit

struct DownloadsPanel: View {
    @Environment(QueueManager.self) private var queueManager
    @Environment(AppState.self) private var appState

    private var summary: String {
        let c = Dictionary(grouping: queueManager.items, by: \.status).mapValues(\.count)
        var parts: [String] = []
        if let n = c[.downloading] { parts.append("\(n) downloading") }
        if let n = c[.postProcessing] { parts.append("\(n) merging") }
        if let n = (c[.queued] ?? 0) + (c[.analyzing] ?? 0) + (c[.paused] ?? 0) as Int?, n > 0 { parts.append("\(n) queued") }
        if let n = c[.completed] { parts.append("\(n) completed") }
        if let n = c[.failed] { parts.append("\(n) failed") }
        return parts.joined(separator: " · ")
    }

    private var listHeight: CGFloat { Self.listHeight(of: queueManager.items) }

    /// The rows' own height, up to about 4 of them, then the list scrolls.
    static func listHeight(of items: [DownloadItem]) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let all = items.map { DownloadRow.height(of: $0) + 6 }.reduce(0, +)
        let cap = items.prefix(4).map { DownloadRow.height(of: $0) + 6 }.reduce(0, +)
        return min(all, max(cap, 4 * 56)) - 6
    }

    /// The whole panel: header, padding and the list. The window keeps room for this.
    static func height(of items: [DownloadItem]) -> CGFloat {
        items.isEmpty ? 0 : listHeight(of: items) + 56
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloads").font(.system(size: 14, weight: .semibold))
                Text(summary).font(.system(size: 12.5)).foregroundStyle(Theme.text3)
                Spacer()
                if queueManager.items.contains(where: { $0.status == .completed || $0.status == .failed }) {
                    Button("Clear finished") { queueManager.clearCompleted() }
                        .buttonStyle(.plain).foregroundStyle(Theme.text2).font(.system(size: 13, weight: .semibold))
                }
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: appState.outputDirectory))
                } label: {
                    Label("Open downloads folder", systemImage: "folder")
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accentText).font(.system(size: 13, weight: .semibold))
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(queueManager.items) { item in DownloadRow(item: item) }
                }
            }
            // As tall as its rows (some are taller while their parts are shown), up to about 4 rows, then it scrolls.
            .frame(height: listHeight)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider() }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    @Environment(QueueManager.self) private var queueManager
    @Environment(SettingsStore.self) private var settings
    @Environment(PlayerModel.self) private var player

    /// Big file over several connections: the one progress bar is split into a segment per part.
    private var showsLanes: Bool { Self.showsLanes(item) }
    private static func showsLanes(_ item: DownloadItem) -> Bool { item.status == .downloading && item.lanes.count > 1 }
    static func height(of item: DownloadItem) -> CGFloat { 50 }

    private var title: String { item.displayTitle(masked: settings.maskDownloadTitles) }

    private var statusText: String {
        switch item.status {
        case .queued, .analyzing: return "Queued"
        case .downloading: return "Downloading"
        case .postProcessing: return "Merging files…"
        case .completed: return "Completed"
        case .paused: return "Paused"
        case .failed: return "Failed"
        }
    }

    private var color: Color {
        switch item.status {
        case .downloading, .postProcessing: return Theme.accentText
        case .queued, .analyzing, .paused: return Theme.warnText
        case .completed: return Theme.successText
        case .failed: return Theme.dangerText
        }
    }

    private var tint: Color {
        switch item.status {
        case .downloading, .postProcessing: return Theme.accentSoft
        case .queued, .analyzing, .paused: return Theme.warnSoft
        case .completed: return Theme.successSoft
        case .failed: return Theme.dangerSoft
        }
    }

    private var icon: String {
        switch item.status {
        case .downloading: return "arrow.down.to.line"
        case .postProcessing: return "gearshape"
        case .queued, .analyzing: return "clock"
        case .paused: return "pause"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }

    private var meta: String {
        switch item.status {
        case .downloading:
            var parts: [String] = []
            if let d = item.downloadedSize, let t = item.totalSize { parts.append("\(d) / \(t)") }
            if let e = item.eta, !e.isEmpty { parts.append("\(e) left") }
            return parts.isEmpty ? "Starting…" : parts.joined(separator: " • ")
        case .postProcessing: return "Combining video and sound, almost done"
        case .queued, .analyzing: return "Starts when another download finishes"
        case .paused: return "Interrupted — press Resume to continue"
        case .completed: return "Saved to \((item.outputDir as NSString).lastPathComponent)"
        case .failed: return item.error ?? "Something went wrong. Please try again."
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(tint, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(meta).font(.system(size: 12)).foregroundStyle(item.status == .failed ? Theme.dangerText : Theme.text2).lineLimit(1)
            }
            .frame(minWidth: 150, idealWidth: 230, maxWidth: 260, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(statusText).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                    Spacer(minLength: 4)
                    if item.status == .downloading, let speed = item.speed, !speed.isEmpty {
                        Text(speed).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.text)
                    }
                }
                if item.status == .postProcessing {
                    ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                } else if showsLanes {
                    SegmentedBar(parts: item.lanes)
                } else {
                    ProgressView(value: min(max(item.progress, 0), 100), total: 100).tint(color)
                }
            }
            .frame(minWidth: 170, maxWidth: .infinity)
            Text("\(Int(item.progress))%")
                .font(.system(size: 20, weight: .bold).monospacedDigit())
                .foregroundStyle(item.status == .failed ? Theme.dangerText : (item.status == .completed ? Theme.successText : Theme.text))
                .frame(width: 56, alignment: .trailing)
            actions.frame(width: 190, alignment: .trailing)
        }
        .padding(.horizontal, 10).frame(height: 50)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(item.status == .failed ? Theme.dangerBorder : Color.clear))
    }

    @ViewBuilder private var actions: some View {
        switch item.status {
        case .downloading, .queued, .analyzing:
            Button("Cancel") { queueManager.cancel(item.id) }.buttonStyle(SecondaryButtonStyle(height: 32))
        case .paused:
            HStack(spacing: 6) {
                Button("Resume") { queueManager.resume(item.id) }.buttonStyle(PrimaryButtonStyle(height: 32))
                Button("Cancel") { queueManager.cancel(item.id) }.buttonStyle(SecondaryButtonStyle(height: 32))
            }
        case .postProcessing:
            Button("Cancel") {}.buttonStyle(SecondaryButtonStyle(height: 32)).disabled(true)
        case .completed:
            HStack(spacing: 6) {
                if settings.useInternalPlayer {
                    Button { play() } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(PrimaryButtonStyle(height: 32))
                } else {
                    Button("Open File") { openFile() }.buttonStyle(PrimaryButtonStyle(height: 32))
                }
                Button("Open Folder") { openFolder() }.buttonStyle(SecondaryButtonStyle(height: 32))
            }
        case .failed:
            HStack(spacing: 6) {
                Button { queueManager.retry(item.id) } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                    .buttonStyle(PrimaryButtonStyle(height: 32))
                Button { queueManager.cancel(item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(SecondaryButtonStyle(height: 32))
                    .accessibilityLabel("Remove from list")
            }
        }
    }

    private func play() {
        guard let path = item.outputPath, FileManager.default.fileExists(atPath: path) else { openFolder(); return }
        player.openDownloaded(path: path, realExtension: item.realExtension)
    }

    private func openFile() {
        if let path = item.outputPath, FileManager.default.fileExists(atPath: path) {
            FileOpener.open(path, realExtension: item.realExtension)
        } else {
            openFolder()
        }
    }

    private func openFolder() {
        if let path = item.outputPath, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.outputDir))
        }
    }
}


/// One progress bar cut into segments, one per part of a file that is downloaded over several connections.
/// Each segment fills as its part arrives, so the parallel work is visible in a single bar.
private struct SegmentedBar: View {
    let parts: [Double]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(parts.indices, id: \.self) { i in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.track)
                        Rectangle().fill(Theme.accentText).frame(width: geo.size.width * min(max(parts[i], 0), 100) / 100)
                    }
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel("Download progress, \(parts.count) parts")
        .accessibilityValue("\(Int(parts.reduce(0, +) / Double(max(parts.count, 1)))) percent")
    }
}
