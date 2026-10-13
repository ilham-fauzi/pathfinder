import SwiftUI
import AppKit

struct CLIPreviewView: View {
    @Environment(CommandBuilder.self) private var commandBuilder
    @State private var isExpanded = false
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    Text(commandBuilder.cliPreview)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.8))
                        .foregroundColor(.green)
                        .cornerRadius(8)
                }
                .frame(maxHeight: 150)
                
                HStack {
                    Button(action: copyToClipboard) {
                        Label("Copy Command", systemImage: "doc.on.doc")
                    }
                    Button(action: saveAsScript) {
                        Label("Save as Script", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        } label: {
            Text("CLI Preview")
                .font(.headline)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
    }
    
    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(commandBuilder.cliSingleLine, forType: .string)
    }
    
    private func saveAsScript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.shellScript]
        panel.nameFieldStringValue = "download.sh"
        if panel.runModal() == .OK, let url = panel.url {
            try? commandBuilder.shellScript.write(to: url, atomically: true, encoding: .utf8)
            var attributes = [FileAttributeKey : Any]()
            attributes[.posixPermissions] = 0o755
            try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }
}
