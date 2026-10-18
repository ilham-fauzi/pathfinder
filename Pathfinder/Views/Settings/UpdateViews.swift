import SwiftUI

/// Thin bar at the top of the window when a newer release exists.
struct UpdateBanner: View {
    let release: UpdateRelease

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accentText)
            Text("Pathfinder \(release.version) is available.").font(.callout)
            Spacer()
            Button("View update") { SettingsTab.open(.about) }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Theme.accentSoft)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// "Updates" block of the About tab: status, release notes and the update button.
struct UpdateSection: View {
    @Environment(AppUpdater.self) private var updater
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var s = settings
        VStack(spacing: 10) {
            statusRow

            if let release = updater.availableRelease, !release.notes.isEmpty {
                ScrollView {
                    Text(release.notes)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 110)
                .padding(8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            }

            Toggle("Check for updates automatically", isOn: $s.autoCheckUpdates)
                .toggleStyle(.checkbox).font(.callout)
        }
        .frame(maxWidth: 380)
    }

    @ViewBuilder private var statusRow: some View {
        switch updater.state {
        case .idle:
            Button("Check for Updates") { Task { await updater.check() } }
        case .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
        case .upToDate:
            HStack(spacing: 10) {
                Label("You're up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                Button("Check Again") { Task { await updater.check() } }
            }
        case .available(let release):
            VStack(spacing: 6) {
                Text("Version \(release.version) is available").bold()
                if updater.canSelfInstall {
                    Button("Update and Restart") { Task { await updater.install() } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Open Download Page") { NSWorkspace.shared.open(release.pageURL) }
                        .buttonStyle(.borderedProminent)
                    Text("Pathfinder can't replace itself from this location.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .downloading(let fraction):
            VStack(spacing: 4) {
                ProgressView(value: fraction).frame(width: 220)
                Text("Downloading… \(Int(fraction * 100))%").font(.caption).foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Installing — Pathfinder will restart…").foregroundStyle(.secondary) }
        case .failed(let message):
            VStack(spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    .multilineTextAlignment(.center)
                Button("Try Again") { updater.dismissError(); Task { await updater.check() } }
            }
        }
    }
}
