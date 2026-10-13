import SwiftUI
import AppKit

struct URLInputView: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsStore.self) private var settings
    @Environment(QueueManager.self) private var queueManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                TextEditor(text: Bindable(appState).currentURL)
                    .font(.body)
                    .frame(height: 80)
                    .border(Color.secondary.opacity(0.2))
                
                VStack {
                    Button(action: analyze) {
                        if appState.isAnalyzing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Analyze", systemImage: "magnifyingglass")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.isAnalyzing)
                    Button(action: pasteFromClipboard) {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    Button(action: clearURL) {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                }
            }
            
            if let error = appState.error {
                Label(error.localizedDescription, systemImage: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.callout)
            }

            if let info = appState.currentVideoInfo {
                HStack(spacing: 16) {
                    if settings.showThumbnail,
                       let thumbStr = info.thumbnail, let url = URL(string: thumbStr) {
                        AsyncImage(url: url) { image in
                            image.resizable()
                                .aspectRatio(contentMode: .fit)
                        } placeholder: {
                            ProgressView()
                        }
                        .frame(width: 120, height: 68)
                        .cornerRadius(8)
                    }
                    
                    VStack(alignment: .leading) {
                        Text(info.title ?? "Unknown").font(.headline).lineLimit(2)
                        Text(info.uploader ?? "").font(.subheadline).foregroundColor(.secondary)
                        HStack {
                            Text(info.durationString ?? "").font(.caption)
                            if let views = info.viewCount {
                                Text("•").font(.caption)
                                Text("\(views) views").font(.caption)
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            }
            
            HStack {
                Text("Output Directory:")
                Text(appState.outputDirectory).foregroundColor(.secondary).lineLimit(1)
                Button("Choose...") {
                    selectOutputDirectory()
                }
            }
        }
    }
    
    private func analyze() {
        Task { await appState.analyze(using: queueManager.ytdlpService) }
    }

    private func pasteFromClipboard() {
        if let string = NSPasteboard.general.string(forType: .string) {
            appState.currentURL = string
        }
    }
    
    private func clearURL() {
        appState.currentURL = ""
        appState.currentVideoInfo = nil
        appState.error = nil
    }
    
    private func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            appState.outputDirectory = url.path
        }
    }
}
