import SwiftUI

struct ResultsView: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsStore.self) private var settings
    @Environment(QueueManager.self) private var queueManager

    private var info: VideoInfo? { appState.currentVideoInfo }

    private var options: [QualityOption] {
        guard let info else { return [] }
        return appState.resultsTab == .video ? QualityOptions.video(from: info) : QualityOptions.audio(from: info)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if appState.listing != nil {
                    Button { appState.backToList() } label: { Label("Back to list", systemImage: "chevron.left") }
                        .buttonStyle(SecondaryButtonStyle(height: 44))
                }
                URLField(height: 44, fontSize: 14, disabled: appState.isAnalyzing, onSubmit: analyze)
                if appState.isAnalyzing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Analyzing…")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 20).frame(height: 44)
                    .background(Theme.btn.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Button("Analyze", action: analyze)
                        .buttonStyle(SecondaryButtonStyle(height: 44))
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Divider() }

            HStack(alignment: .top, spacing: 20) {
                Group {
                    if let info, !appState.isAnalyzing { VideoBox(info: info) } else { VideoBoxSkeleton(showThumbnail: settings.showThumbnail) }
                }
                .frame(width: 248)

                VStack(alignment: .leading, spacing: 10) {
                    if appState.isAnalyzing {
                        RoundedRectangle(cornerRadius: 12).fill(Theme.skeleton).frame(width: 232, height: 42)
                        ForEach(0..<6, id: \.self) { _ in SkeletonRow() }
                    } else if let info {
                        tabs(info)
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(options) { option in QualityRow(option: option, info: info) }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
    }

    private func tabs(_ info: VideoInfo) -> some View {
        HStack(spacing: 4) {
            tab(.video, "Video", "play.rectangle", QualityOptions.video(from: info).count)
            tab(.audio, "Audio only", "music.note", QualityOptions.audio(from: info).count)
        }
        .padding(4)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
        .accessibilityElement(children: .contain)
    }

    private func tab(_ kind: QualityOption.Kind, _ title: String, _ icon: String, _ count: Int) -> some View {
        let on = appState.resultsTab == kind
        return Button { appState.resultsTab = kind } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                    .background(on ? Theme.accentSoft : Theme.track, in: Capsule())
                    .foregroundStyle(on ? Theme.accentText : Theme.text2)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(on ? Theme.text : Theme.text2)
            .padding(.horizontal, 12).frame(height: 32)
            .background(on ? Theme.segActive : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func analyze() {
        Task { await appState.analyze(using: queueManager.ytdlpService) }
    }
}

// MARK: - Video box (honors the "Show Video Thumbnail" setting)

struct VideoBox: View {
    let info: VideoInfo
    @Environment(SettingsStore.self) private var settings

    private var thumbnailURL: URL? { info.thumbnail.flatMap(URL.init(string:)) }
    private var showImage: Bool { settings.showThumbnail && thumbnailURL != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showImage, let url = thumbnailURL {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Theme.skeleton)
                }
                .frame(width: 248, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomTrailing) {
                    if let d = info.durationString {
                        Text(d)
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 6).frame(height: 20)
                            .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 5))
                            .padding(8)
                    }
                }
                .accessibilityHidden(true)
            }
            Text(info.title ?? "Untitled")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
            HStack(spacing: 6) {
                Image(systemName: "person")
                Text(info.uploader ?? info.channel ?? "Unknown")
                // With no image, the duration moves into the text line.
                if !showImage, let d = info.durationString {
                    Text("·").foregroundStyle(Theme.text3)
                    Text(d).monospacedDigit()
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.text2)
            .lineLimit(1)
            if !showImage, let views = info.viewCount {
                Text("\(views.formatted()) views").font(.system(size: 12.5)).foregroundStyle(Theme.text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VideoBoxSkeleton: View {
    let showThumbnail: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showThumbnail {
                RoundedRectangle(cornerRadius: 10).fill(Theme.skeleton).frame(width: 248, height: 120)
            }
            RoundedRectangle(cornerRadius: 6).fill(Theme.skeleton).frame(width: 232, height: 14)
            RoundedRectangle(cornerRadius: 6).fill(Theme.skeleton).frame(width: 168, height: 14)
            RoundedRectangle(cornerRadius: 6).fill(Theme.skeleton).frame(width: 124, height: 12)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finding available qualities…").font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
        }
    }
}

struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 7).fill(Theme.skeleton).frame(width: 56, height: 24)
            RoundedRectangle(cornerRadius: 6).fill(Theme.skeleton).frame(width: 96, height: 12)
            Spacer()
            RoundedRectangle(cornerRadius: 6).fill(Theme.skeleton).frame(width: 60, height: 12)
            RoundedRectangle(cornerRadius: 9).fill(Theme.skeleton).frame(width: 132, height: 36)
        }
        .padding(.horizontal, 10).frame(height: 52)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }
}

// MARK: - Quality row

struct QualityRow: View {
    let option: QualityOption
    let info: VideoInfo
    @Environment(AppState.self) private var appState
    @Environment(QueueManager.self) private var queueManager

    private var busy: Bool {
        let url = appState.currentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return queueManager.items.contains {
            $0.url == url && $0.optionId == option.id
                && [.queued, .downloading, .postProcessing, .analyzing].contains($0.status)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(option.quality)
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.accentText)
                .padding(.horizontal, 9).frame(height: 28)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 7))
                .frame(width: 84, alignment: .leading)
            Text(option.label).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
            if option.isRecommended {
                Label("Recommended", systemImage: "star.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Theme.btn, in: Capsule())
            }
            Spacer(minLength: 8)
            Text(option.container)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 7).frame(height: 24)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.borderStrong))
            Text(option.sizeText)
                .font(.system(size: 13.5).monospacedDigit())
                .foregroundStyle(Theme.text2)
                .frame(width: 76, alignment: .trailing)
            if busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Processing…") }
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 132, height: 36)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
            } else {
                Group {
                    if option.isRecommended {
                        Button(action: download) { downloadLabel }.buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button(action: download) { downloadLabel }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                .accessibilityLabel(option.accessibilityLabel)
                .frame(width: 132)
            }
        }
        .padding(.leading, 10).padding(.trailing, 8)
        .frame(height: 52)
        .background(option.isRecommended ? Theme.accentSoft : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(option.isRecommended ? Theme.accentBorder : Theme.border))
    }

    private var downloadLabel: some View {
        Label("Download", systemImage: "arrow.down.to.line").frame(maxWidth: .infinity)
    }

    private func download() {
        queueManager.enqueue(
            url: appState.currentURL.trimmingCharacters(in: .whitespacesAndNewlines),
            options: option.options(basedOn: appState.downloadOptions),
            outputDir: appState.outputDirectory,
            videoInfo: info,
            optionId: option.id,
            qualityLabel: option.quality,
            cookiesFile: appState.pendingCookiesFile,
            referer: appState.pendingReferer
        )
    }
}
