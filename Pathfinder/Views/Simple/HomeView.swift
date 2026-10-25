import SwiftUI
import AppKit

/// Splits an error into a short title and an optional helper sentence.
struct ErrorPresentation {
    let title: String
    let hint: String?

    init(_ message: String) {
        if message.hasPrefix("Paste a link first") {
            title = "Paste a link first"
            hint = "Open the video in your browser, copy the link from the address bar, then paste it in the box above."
        } else if message.hasPrefix("This link doesn’t lead to a video") {
            title = "This link doesn’t lead to a video"
            hint = "Open the video itself in your browser, copy the link from the address bar, and paste it here. Links to a homepage, search results or an article won’t work."
        } else if message.hasPrefix("No video found at this page address") {
            title = "No video found at this page address"
            hint = "This site plays its video from a stream the page loads. Open it in the Browser tab, let the video play, then press Download there."
        } else if message.contains("404") || message.contains("Cloudflare") || message.contains("403") || message.contains("Blob") {
            title = message
            hint = "This site may have bot verification or a custom blob player. Open it in the in-app Browser tab to trace and download the stream."
        } else {
            title = message
            hint = nil
        }
    }
}

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(BrowserModel.self) private var browser
    @Environment(SettingsStore.self) private var settings
    @Environment(QueueManager.self) private var queueManager
    @Environment(ClipboardMonitor.self) private var clipboard
    @State private var clipURL: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.btn)
                Text("Find and download video or audio")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("Paste a video, channel or playlist link, or type what you are looking for. Pick a video, then choose the quality.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.text2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    URLField(height: 56, fontSize: 15, hasError: appState.error != nil, onSubmit: analyze)
                        .focused($focused)
                    Button("Go", action: analyze)
                        .buttonStyle(PrimaryButtonStyle(height: 56))
                        .keyboardShortcut(.defaultAction)
                }

                if let error = appState.error {
                    let p = ErrorPresentation(error.localizedDescription)
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(Theme.dangerText)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.dangerText)
                            if let hint = p.hint {
                                Text(hint).font(.system(size: 13)).foregroundStyle(Theme.text2)
                            }
                        }
                        Spacer(minLength: 0)
                        if !appState.currentURL.isEmpty {
                            Button {
                                let target = appState.currentURL
                                appState.section = .browser
                                browser.go(target)
                            } label: {
                                Label("Open in Browser", systemImage: "globe")
                            }
                            .buttonStyle(SecondaryButtonStyle(height: 32))
                        }
                    }
                    .padding(14)
                    .background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.dangerBorder))
                    .accessibilityElement(children: .combine)
                }

                if let clip = clipURL, appState.currentURL.isEmpty, !appState.clipboardDismissed {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.on.clipboard").foregroundStyle(Theme.accentText)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Use the link from your clipboard?").font(.system(size: 13.5, weight: .semibold))
                            Text(clip).font(.system(size: 12.5)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Button("Use this link") {
                            appState.currentURL = clip
                            analyze()
                        }
                        .buttonStyle(SecondaryButtonStyle(height: 34))
                        Button { appState.clipboardDismissed = true } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(IconButtonStyle())
                        .accessibilityLabel("Dismiss suggestion")
                    }
                    .padding(.vertical, 10).padding(.leading, 14).padding(.trailing, 10)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accentBorder))
                }
            }
            .frame(maxWidth: 640)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 64)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true; refreshClipboard() }
        .onChange(of: clipboard.detectedURL) { _, _ in refreshClipboard() }
        .task {
            if settings.clipboardMonitoring, !clipboard.isMonitoring { clipboard.startMonitoring() }
        }
    }

    private func analyze() {
        Task { await appState.analyze(using: queueManager.ytdlpService) }
    }

    /// Offer the current clipboard text if it looks like a link.
    private func refreshClipboard() {
        guard settings.clipboardMonitoring,
              let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.lowercased().hasPrefix("http"), ErrorMapper.check(s) == .ok else { clipURL = nil; return }
        clipURL = s
    }
}

/// The rounded link input shared by Home and Results.
struct URLField: View {
    @Environment(AppState.self) private var appState
    @Environment(QueueManager.self) private var queueManager
    var height: CGFloat
    var fontSize: CGFloat
    var hasError: Bool = false
    var disabled: Bool = false
    var onSubmit: () -> Void

    var body: some View {
        @Bindable var state = appState
        HStack(spacing: 10) {
            Image(systemName: "link").foregroundStyle(Theme.text3)
            TextField("Paste a link, or type to search...", text: $state.currentURL)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize))
                .foregroundStyle(Theme.text)
                .disabled(disabled)
                .onSubmit(onSubmit)
                .accessibilityLabel("Video link")
            if !appState.currentURL.isEmpty && !disabled {
                Button {
                    appState.currentURL = ""
                    appState.currentVideoInfo = nil
                    appState.error = nil
                } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Clear link")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: height)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(hasError ? Theme.danger : Theme.border, lineWidth: 1.5))
        .opacity(disabled ? 0.6 : 1)
        .onChange(of: appState.currentURL) { old, new in
            appState.linkChanged(from: old, to: new, using: queueManager.ytdlpService)
        }
    }
}
