import SwiftUI

struct SubtitlesTabView: View {
    @Environment(AppState.self) private var appState
    @State private var showSubtitleList = false
    
    var body: some View {
        @Bindable var options = appState.downloadOptions
        
        Form {
            Toggle("Write Subtitles", isOn: $options.writeSubs)
            Toggle("Write Auto Subtitles", isOn: $options.writeAutoSubs)
            
            TextField("Subtitle Languages", text: Binding(
                get: { options.subLangs ?? "" },
                set: { options.subLangs = $0.isEmpty ? nil : $0 }
            ))
            .help("Comma separated list, e.g. en,id,ja")
            
            TextField("Subtitle Format", text: Binding(
                get: { options.subFormat ?? "" },
                set: { options.subFormat = $0.isEmpty ? nil : $0 }
            ))
            .help("best, ass, srt, vtt, lrc")
            
            Button("List Available Subtitles") {
                showSubtitleList = true
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showSubtitleList) {
            VStack {
                Text("Available Subtitles")
                    .font(.headline)
                    .padding()
                Text("Analyze a URL first to see available subtitles.")
                    .foregroundColor(.secondary)
                Button("Close") {
                    showSubtitleList = false
                }
                .padding()
            }
            .frame(width: 400, height: 300)
        }
    }
}
