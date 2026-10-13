import SwiftUI
import AppKit

struct FilesystemTabView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        @Bindable var options = appState.downloadOptions
        
        Form {
            Section("Output Template") {
                TextField("Template", text: $options.outputTemplate)
                    .help("e.g. %(title)s.%(ext)s")
                Text("Preview: \(previewTemplate(options.outputTemplate))")
                    .foregroundColor(.secondary)
                    .font(.caption)
                TextField("NA Placeholder", text: Binding(
                    get: { options.outputNaPlaceholder ?? "" },
                    set: { options.outputNaPlaceholder = $0.isEmpty ? nil : $0 }
                ))
            }
            
            Section("Paths") {
                HStack {
                    TextField("Home Path", text: Binding(
                        get: { options.paths ?? "" },
                        set: { options.paths = $0.isEmpty ? nil : $0 }
                    ))
                    Button("Browse...") {
                        if let dir = selectDirectory() { options.paths = dir }
                    }
                }
                HStack {
                    TextField("Temp Path", text: Binding(
                        get: { options.tempPath ?? "" },
                        set: { options.tempPath = $0.isEmpty ? nil : $0 }
                    ))
                    Button("Browse...") {
                        if let dir = selectDirectory() { options.tempPath = dir }
                    }
                }
            }
            
            Section("Filename") {
                Toggle("Restrict Filenames", isOn: $options.restrictFilenames)
                Toggle("Windows Filenames", isOn: $options.windowsFilenames)
                Stepper("Trim Filenames: \(options.trimFilenames ?? 0)", value: Binding(
                    get: { options.trimFilenames ?? 0 },
                    set: { options.trimFilenames = $0 }
                ), in: 0...255)
            }
            
            Section("File Handling") {
                Toggle("No Overwrites", isOn: $options.noOverwrites)
                Toggle("Force Overwrites", isOn: $options.forceOverwrites)
                Toggle("Continue Downloads", isOn: $options.continueDownload)
                Toggle("Use .part files", isOn: $options.usePart)
                Toggle("Use mtime", isOn: $options.useMtime)
            }
            
            Section("Metadata Files") {
                Toggle("Write Description", isOn: $options.writeDescription)
                Toggle("Write Info JSON", isOn: $options.writeInfoJson)
                Toggle("Write Comments", isOn: $options.writeComments)
                Toggle("Clean Info JSON", isOn: $options.cleanInfoJson)
            }
            
            Section("Archive") {
                HStack {
                    TextField("Download Archive", text: Binding(
                        get: { options.downloadArchive ?? "" },
                        set: { options.downloadArchive = $0.isEmpty ? nil : $0 }
                    ))
                    Button("Browse...") {
                        if let f = selectFile() { options.downloadArchive = f }
                    }
                }
                HStack {
                    TextField("Batch File", text: Binding(
                        get: { options.batchFile ?? "" },
                        set: { options.batchFile = $0.isEmpty ? nil : $0 }
                    ))
                    Button("Browse...") {
                        if let f = selectFile() { options.batchFile = f }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
    
    private func previewTemplate(_ template: String) -> String {
        return template.replacingOccurrences(of: "%(title)s", with: "Video_Title")
                       .replacingOccurrences(of: "%(ext)s", with: "mp4")
    }
    
    private func selectDirectory() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    
    private func selectFile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
