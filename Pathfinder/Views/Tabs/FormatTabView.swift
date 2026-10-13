import SwiftUI

struct FormatTabView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        @Bindable var options = appState.downloadOptions
        
        Form {
            Section("Format") {
                TextField("Format String (-f)", text: Binding(
                    get: { options.format ?? "" },
                    set: { options.format = $0.isEmpty ? nil : $0 }
                ))
                TextField("Format Sort (-S)", text: Binding(
                    get: { options.formatSort ?? "" },
                    set: { options.formatSort = $0.isEmpty ? nil : $0 }
                ))
                Toggle("Force Format Sort", isOn: $options.formatSortForce)
            }
            
            Section("Video") {
                Picker("Merge Output Format", selection: $options.mergeOutputFormat) {
                    Text("Auto").tag(nil as MergeFormat?)
                    Text("MP4").tag(Optional(MergeFormat.mp4))
                    Text("MKV").tag(Optional(MergeFormat.mkv))
                    Text("WebM").tag(Optional(MergeFormat.webm))
                    Text("FLV").tag(Optional(MergeFormat.flv))
                    Text("MOV").tag(Optional(MergeFormat.mov))
                    Text("AVI").tag(Optional(MergeFormat.avi))
                }
                TextField("Recode Video", text: Binding(
                    get: { options.recodeVideo ?? "" },
                    set: { options.recodeVideo = $0.isEmpty ? nil : $0 }
                ))
                TextField("Remux Video", text: Binding(
                    get: { options.remuxVideo ?? "" },
                    set: { options.remuxVideo = $0.isEmpty ? nil : $0 }
                ))
            }
            
            Section("Audio") {
                Toggle("Extract Audio Only", isOn: $options.extractAudio)
                
                Picker("Audio Format", selection: $options.audioFormat) {
                    Text("Auto").tag(nil as AudioFormat?)
                    Text("Best").tag(Optional(AudioFormat.best))
                    Text("MP3").tag(Optional(AudioFormat.mp3))
                    Text("AAC").tag(Optional(AudioFormat.aac))
                    Text("M4A").tag(Optional(AudioFormat.m4a))
                    Text("Opus").tag(Optional(AudioFormat.opus))
                    Text("Vorbis").tag(Optional(AudioFormat.vorbis))
                    Text("FLAC").tag(Optional(AudioFormat.flac))
                    Text("ALAC").tag(Optional(AudioFormat.alac))
                    Text("WAV").tag(Optional(AudioFormat.wav))
                }
                .disabled(!options.extractAudio)
                
                HStack {
                    Text("Audio Quality: \(options.audioQuality)")
                    Slider(value: Binding(
                        get: { Double(options.audioQuality) },
                        set: { options.audioQuality = Int($0) }
                    ), in: 0...10, step: 1)
                }
            }
            
            Section("Advanced Format") {
                Toggle("Prefer Free Formats", isOn: $options.preferFreeFormats)
                Toggle("Check Formats", isOn: $options.checkFormats)
                Toggle("Audio Multistreams", isOn: $options.audioMultistreams)
                Toggle("Video Multistreams", isOn: $options.videoMultistreams)
            }
        }
        .formStyle(.grouped)
    }
}
