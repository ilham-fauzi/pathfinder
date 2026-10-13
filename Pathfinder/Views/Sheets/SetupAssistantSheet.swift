import SwiftUI
import AppKit

struct SetupAssistantSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(SettingsStore.self) private var settings
    @Environment(QueueManager.self) private var queueManager
    @State private var currentStep = 1
    @State private var status = DependencyStatus()
    @State private var checking = true
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Welcome to Pathfinder")
                .font(.largeTitle)
                .bold()
            
            ProgressView(value: Double(currentStep), total: 5.0)
                .padding(.horizontal)
            
            TabView(selection: $currentStep) {
                StepOneView(status: status, checking: checking).tag(1)
                ToolStepView(title: "yt-dlp Setup", tool: "yt-dlp", found: status.ytdlpPath, onChange: recheck).tag(2)
                ToolStepView(title: "FFmpeg Setup", tool: "ffmpeg", found: status.ffmpegPath, onChange: recheck).tag(3)
                StepFourView().tag(4)
                StepFiveView().tag(5)
            }
            .tabViewStyle(.automatic)
            
            HStack {
                if currentStep > 1 {
                    Button("Back") { currentStep -= 1 }
                }
                
                Spacer()
                
                if currentStep < 5 {
                    Button("Next") { currentStep += 1 }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Start Using Pathfinder") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 500, height: 400)
        .padding()
        .task { await recheck() }
    }

    private func recheck() async {
        checking = true
        status = await DependencyChecker.check()
        if let p = status.ytdlpPath { await queueManager.ytdlpService.setCustomPath(p.path) }
        if let p = status.ffmpegPath, settings.ffmpegPath.isEmpty { settings.ffmpegPath = p.path }
        checking = false
    }
}

struct StepOneView: View {
    let status: DependencyStatus
    let checking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Checking Dependencies...").font(.title2)
            Text("Pathfinder needs yt-dlp and FFmpeg to work correctly.")
            if checking {
                ProgressView().controlSize(.small)
            } else {
                row("yt-dlp", status.ytdlpPath, status.ytdlpVersion)
                row("FFmpeg", status.ffmpegPath, status.ffmpegVersion)
            }
        }
    }

    private func row(_ name: String, _ path: URL?, _ version: String?) -> some View {
        Label {
            Text(path != nil ? "\(name) — \(version ?? path!.path)" : "\(name) — not found")
        } icon: {
            Image(systemName: path != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(path != nil ? .green : .red)
        }
    }
}

/// Install a tool with Homebrew or point to an existing binary.
struct ToolStepView: View {
    let title: String
    let tool: String
    let found: URL?
    let onChange: () async -> Void

    @Environment(SettingsStore.self) private var settings
    @State private var installing = false
    @State private var message = ""

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.title2)
            if let found {
                Label("Installed at \(found.path)", systemImage: "checkmark.circle.fill").foregroundColor(.green)
            } else {
                if tool == "yt-dlp" {
                    Button("Auto-install (Download Binary)") { Task { await autoInstall() } }
                        .disabled(installing)
                }
                Button("Install via Homebrew") { Task { await brewInstall() } }
                    .disabled(installing)
                Button("Specify Manual Path") { choosePath() }
                if installing { ProgressView().controlSize(.small) }
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
            }
        }
    }

    private func autoInstall() async {
        installing = true
        defer { installing = false }
        do {
            let url = try await BinaryInstaller.installYTDLP()
            settings.ytdlpPath = url.path
            message = "Installed yt-dlp to \(url.path)"
        } catch {
            message = error.localizedDescription
        }
        await onChange()
    }

    private func brewInstall() async {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        guard let brew = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            message = "Homebrew was not found. Install it from brew.sh, or choose a path manually."
            return
        }
        installing = true
        defer { installing = false }
        do {
            let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: brew), arguments: ["install", tool])
            message = result.isSuccess ? "Installed \(tool)." : (result.stderrString ?? "Install failed.")
        } catch {
            message = error.localizedDescription
        }
        await onChange()
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose the \(tool) executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if tool == "yt-dlp" { settings.ytdlpPath = url.path } else { settings.ffmpegPath = url.path }
        message = "Using \(url.path)"
        Task { await onChange() }
    }
}

struct StepFourView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 12) {
            Text("Default Output Directory").font(.title2)
            Text(settings.defaultOutputDir).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            Button("Choose Folder...") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let url = panel.url {
                    settings.defaultOutputDir = url.path
                    appState.outputDirectory = url.path
                }
            }
        }
    }
}

struct StepFiveView: View {
    var body: some View {
        VStack {
            Text("All Set!").font(.title2)
            Text("You are ready to start downloading.")
        }
    }
}
