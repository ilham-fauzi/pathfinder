import SwiftUI

struct PostProcessingTabView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        @Bindable var options = appState.downloadOptions
        
        Form {
            Section("Embedding") {
                Toggle("Embed Subtitles", isOn: $options.embedSubs)
                Toggle("Embed Thumbnail", isOn: $options.embedThumbnail)
                Toggle("Embed Metadata", isOn: $options.embedMetadata)
                Toggle("Embed Chapters", isOn: $options.embedChapters)
                Toggle("Embed Info JSON", isOn: $options.embedInfoJson)
            }
            
            Section("SponsorBlock") {
                Text("Mark: \(options.sponsorblockMark.joined(separator: ", "))")
                    .foregroundColor(.secondary)
                Text("Remove: \(options.sponsorblockRemove.joined(separator: ", "))")
                    .foregroundColor(.secondary)
            }
            
            Section("Conversion") {
                TextField("Convert Subs", text: Binding(
                    get: { options.convertSubs ?? "" },
                    set: { options.convertSubs = $0.isEmpty ? nil : $0 }
                ))
                TextField("Convert Thumbnails", text: Binding(
                    get: { options.convertThumbnails ?? "" },
                    set: { options.convertThumbnails = $0.isEmpty ? nil : $0 }
                ))
                TextField("Fixup Policy", text: Binding(
                    get: { options.fixup ?? "" },
                    set: { options.fixup = $0.isEmpty ? nil : $0 }
                ))
                TextField("FFmpeg Location", text: Binding(
                    get: { options.ffmpegLocation ?? "" },
                    set: { options.ffmpegLocation = $0.isEmpty ? nil : $0 }
                ))
                TextField("Postprocessor Args", text: Binding(
                    get: { options.postprocessorArgs ?? "" },
                    set: { options.postprocessorArgs = $0.isEmpty ? nil : $0 }
                ))
            }
            
            Section("Chapters") {
                Toggle("Split Chapters", isOn: $options.splitChapters)
                TextField("Remove Chapters (Regex)", text: Binding(
                    get: { options.removeChapters ?? "" },
                    set: { options.removeChapters = $0.isEmpty ? nil : $0 }
                ))
                Toggle("Force Keyframes at Cuts", isOn: $options.forceKeyframesAtCuts)
            }
            
            Section("Commands") {
                TextField("Exec Command", text: Binding(
                    get: { options.execCommand ?? "" },
                    set: { options.execCommand = $0.isEmpty ? nil : $0 }
                ))
                Toggle("Keep Video", isOn: $options.keepVideo)
                Toggle("No Post-overwrites", isOn: $options.noPostOverwrites)
            }
        }
        .formStyle(.grouped)
    }
}
