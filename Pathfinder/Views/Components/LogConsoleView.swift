import SwiftUI
import AppKit

struct LogConsoleView: View {
    @Environment(LogStore.self) private var logStore
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search logs...", text: Bindable(logStore).searchText)
                    .textFieldStyle(.roundedBorder)
                
                Button("Clear") { logStore.clear() }
                Button("Copy All") { logStore.copyAll() }
                Button("Export") { exportLogs() }
            }
            .padding()
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(logStore.filteredEntries) { entry in
                            HStack(alignment: .top) {
                                Text(entry.timestamp, style: .time)
                                    .foregroundColor(.secondary)
                                
                                Text("[\(entry.level.rawValue.uppercased())]")
                                    .foregroundColor(colorForLevel(entry.level))
                                    .bold()
                                
                                Text(entry.message)
                                    .foregroundColor(.primary)
                            }
                            .font(.system(.caption, design: .monospaced))
                            .id(entry.id)
                        }
                    }
                    .padding()
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: logStore.entries.count) { _, _ in
                    if let last = logStore.filteredEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    private func colorForLevel(_ level: LogEntry.LogLevel) -> Color {
        switch level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .download: return .green
        case .debug: return .gray
        case .unknown: return .primary
        }
    }
    
    private func exportLogs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "pathfinder-logs.txt"
        if panel.runModal() == .OK, let url = panel.url {
            let logText = logStore.entries.map { "\($0.timestamp) [\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n")
            try? logText.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
