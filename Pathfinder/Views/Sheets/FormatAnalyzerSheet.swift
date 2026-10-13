import SwiftUI

struct FormatAnalyzerSheet: View {
    let videoInfo: VideoInfo
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFormatId: String = ""
    @State private var customFormatString: String = ""
    @State private var showVideo = true
    @State private var showAudio = true
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text(videoInfo.title ?? "Unknown").font(.title3).bold()
                    Text(videoInfo.uploader ?? "").foregroundColor(.secondary)
                    Text(videoInfo.durationString ?? "").font(.caption)
                }
                Spacer()
            }
            .padding()
            
            HStack {
                Toggle("Video", isOn: $showVideo)
                Toggle("Audio", isOn: $showAudio)
            }
            .padding(.horizontal)
            
            List(filteredFormats) { format in
                HStack {
                    Button(action: { selectedFormatId = format.id }) {
                        Image(systemName: selectedFormatId == format.id ? "largecircle.fill.circle" : "circle")
                    }
                    .buttonStyle(.plain)
                    
                    Text(format.formatId).frame(width: 60, alignment: .leading)
                    Text(format.ext ?? "-").frame(width: 50, alignment: .leading)
                    Text(format.resolution ?? "-").frame(width: 80, alignment: .leading)
                    if let fps = format.fps {
                        Text("\(Int(fps))fps").frame(width: 50, alignment: .leading)
                    } else {
                        Text("-").frame(width: 50, alignment: .leading)
                    }
                    Text(format.vcodec ?? format.acodec ?? "-").frame(width: 80, alignment: .leading)
                    Text(format.humanSize).frame(width: 80, alignment: .trailing)
                    
                    if format.hasVideo && format.hasAudio {
                        Text("V+A").foregroundColor(.green).font(.caption)
                    } else if format.hasVideo {
                        Text("Video").foregroundColor(.blue).font(.caption)
                    } else {
                        Text("Audio").foregroundColor(.orange).font(.caption)
                    }
                }
            }
            
            HStack {
                TextField("Custom Format String", text: $customFormatString)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 800, height: 600)
    }
    
    private var filteredFormats: [FormatInfo] {
        (videoInfo.formats ?? []).filter { format in
            (showVideo && format.hasVideo) || (showAudio && format.hasAudio)
        }
    }
}
