import SwiftUI
import AppKit

/// Simple mode: Home → Analyzing → Results, with the Downloads panel underneath.
struct SimpleRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(QueueManager.self) private var queueManager

    var body: some View {
        VStack(spacing: 0) {
            if appState.currentVideoInfo == nil && !appState.isAnalyzing {
                if appState.listing != nil { ListingView() } else { HomeView() }
            } else {
                ResultsView()
            }
            if !queueManager.items.isEmpty {
                DownloadsPanel()
            }
        }
        .background(Theme.bg)
        .overlay(alignment: .bottomTrailing) {
            if let toast = appState.toast {
                ToastView(toast: toast) { appState.toast = nil }
                    .padding(.trailing, 20)
                    .padding(.bottom, queueManager.items.isEmpty ? 20 : 14 + panelHeight)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: appState.toast)
        .onChange(of: appState.toast?.id) { _, id in
            guard let id else { return }
            Task {
                try? await Task.sleep(for: .seconds(6))
                if appState.toast?.id == id { appState.toast = nil }
            }
        }
    }

    private var panelHeight: CGFloat {
        CGFloat(min(queueManager.items.count, 4)) * 56 + 56
    }
}

struct ToastView: View {
    let toast: Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.successText)
                .frame(width: 28, height: 28)
                .background(Theme.successSoft, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Download complete").font(.system(size: 14, weight: .semibold))
                Text(toast.name).font(.system(size: 12.5)).foregroundStyle(Theme.text2).lineLimit(1)
                Button("Open file") {
                    if let p = toast.path, FileManager.default.fileExists(atPath: p) {
                        FileOpener.open(p)
                    }
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accentText)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Dismiss notification")
        }
        .padding(.top, 14).padding(.bottom, 12).padding(.leading, 14).padding(.trailing, 6)
        .frame(width: 340)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
    }
}
