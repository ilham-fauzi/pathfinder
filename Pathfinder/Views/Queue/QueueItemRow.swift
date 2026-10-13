import SwiftUI
import AppKit

struct QueueItemRow: View {
    let item: DownloadItem
    @Environment(QueueManager.self) private var queueManager
    @Environment(SettingsStore.self) private var settings
    
    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 24, height: 24)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle(masked: settings.maskDownloadTitles))
                    .font(.headline)
                    .lineLimit(1)
                
                HStack {
                    Text(item.status.rawValue.capitalized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if item.status == .downloading {
                        if let speed = item.speed {
                            Text("• \(speed)").font(.caption).foregroundColor(.blue)
                        }
                        if let eta = item.eta {
                            Text("• ETA: \(eta)").font(.caption).foregroundColor(.blue)
                        }
                    }
                }
                
                if item.status == .downloading {
                    ProgressView(value: item.progress, total: 100)
                        .progressViewStyle(.linear)
                }
            }
            
            Spacer()
            
            HStack {
                if item.status == .downloading {
                    Button(action: { queueManager.pause(item.id) }) {
                        Image(systemName: "pause.circle")
                    }
                } else if item.status == .paused {
                    Button(action: { queueManager.resume(item.id) }) {
                        Image(systemName: "play.circle")
                    }
                }
                
                Button(action: { queueManager.cancel(item.id) }) {
                    Image(systemName: "xmark.circle")
                }
                
                if item.status == .failed {
                    Button(action: { queueManager.retry(item.id) }) {
                        Image(systemName: "arrow.clockwise.circle")
                    }
                }
                
                Button(action: revealInFinder) {
                    Image(systemName: "folder")
                }
            }
            .buttonStyle(.plain)
            .font(.title3)
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .queued: Image(systemName: "clock").foregroundColor(.gray)
        case .analyzing: ProgressView().controlSize(.small)
        case .downloading: Image(systemName: "arrow.down.circle.fill").foregroundColor(.blue)
        case .postProcessing: Image(systemName: "gearshape.fill").foregroundColor(.orange)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .paused: Image(systemName: "pause.circle.fill").foregroundColor(.yellow)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
        }
    }
    
    private func revealInFinder() {
        if let path = item.outputPath {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        }
    }
}
