import SwiftUI

/// Videos of a channel, playlist or search. Clicking one opens its quality picker.
/// `embedded` is the Advanced-mode variant that sits under the existing link box.
struct ListingView: View {
    @Environment(AppState.self) private var appState
    @Environment(QueueManager.self) private var queueManager
    @Environment(SettingsStore.self) private var settings
    var embedded = false

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 16, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            if embedded { embeddedHeader } else { simpleHeader }
            content
        }
        .background(embedded ? Color.clear : Theme.bg)
    }

    // MARK: Headers

    private var simpleHeader: some View {
        HStack(spacing: 10) {
            Button { appState.closeListing() } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(SecondaryButtonStyle(height: 44))
            URLField(height: 44, fontSize: 14, onSubmit: reload)
            Button("Search", action: reload)
                .buttonStyle(SecondaryButtonStyle(height: 44))
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var embeddedHeader: some View {
        HStack {
            Text(titleText).font(.headline).lineLimit(1)
            Spacer()
            Button { appState.closeListing() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Close list")
        }
        .padding(.vertical, 8)
    }

    private var titleText: String {
        guard let l = appState.listing else { return "" }
        switch l.source {
        case .search(let q): return "Results for “\(q)”"
        case .url: return l.title ?? "Videos"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let l = appState.listing {
            if l.entries.isEmpty {
                if l.isLoading { skeleton }
                else if let e = l.error { errorView(e) }
                else { message("No videos found", "Try another search or link.") }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !embedded {
                            Text(titleText).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(l.entries) { entry in
                                EntryCard(entry: entry, showImage: settings.showThumbnail) { open(entry) }
                                    .onAppear { if entry.id == l.entries.last?.id { loadMore() } }
                            }
                        }
                        footer(l)
                    }
                    .padding(embedded ? 0 : 20)
                }
            }
        }
    }

    @ViewBuilder
    private func footer(_ l: ListingState) -> some View {
        HStack {
            Spacer()
            if l.isLoading {
                ProgressView().controlSize(.small)
            } else if let e = l.error {
                VStack(spacing: 6) {
                    Text(e).font(.system(size: 13)).foregroundStyle(Theme.dangerText)
                    Button("Try again") { retry() }.buttonStyle(SecondaryButtonStyle(height: 34))
                }
            } else if l.canLoadMore {
                Button("Load more") { loadMore() }.buttonStyle(SecondaryButtonStyle(height: 36))
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var skeleton: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(0..<9, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 10).fill(Theme.skeleton).aspectRatio(16.0 / 9.0, contentMode: .fit)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.skeleton).frame(height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.skeleton).frame(width: 110, height: 10)
                    }
                }
            }
            .padding(embedded ? 0 : 20)
        }
        .accessibilityLabel("Loading videos")
    }

    private func errorView(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 28)).foregroundStyle(Theme.dangerText)
            Text(text).font(.system(size: 14)).foregroundStyle(Theme.text2).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Try again") { retry() }.buttonStyle(SecondaryButtonStyle(height: 36))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            Text(detail).font(.system(size: 13)).foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func open(_ entry: ListingEntry) {
        Task { await appState.open(entry, using: queueManager.ytdlpService) }
    }
    private func loadMore() { Task { await appState.loadMore(using: queueManager.ytdlpService) } }
    private func retry() { Task { await appState.retryListing(using: queueManager.ytdlpService) } }
    private func reload() { Task { await appState.analyze(using: queueManager.ytdlpService) } }
}

private struct EntryCard: View {
    let entry: ListingEntry
    let showImage: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                thumbnail
                Text(entry.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let sub = subtitle {
                    Text(sub).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1)
                }
            }
            .padding(8)
            .background(hovering ? Theme.surface2 : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(entry.isPlaylist ? "Playlist \(entry.title)" : "\(entry.title), \(entry.durationText ?? "")")
        .accessibilityHint(entry.isPlaylist ? "Opens the playlist" : "Choose quality and download")
    }

    private var subtitle: String? {
        [entry.channel, entry.viewsText].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(Theme.skeleton)
            if showImage, let s = entry.thumbnail, let url = URL(string: s) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.clear }
            } else {
                Image(systemName: entry.isPlaylist ? "list.and.film" : "play.rectangle")
                    .font(.system(size: 26)).foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if entry.isPlaylist {
                badge("Playlist", icon: "list.bullet")
            } else if let d = entry.durationText {
                badge(d)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func badge(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5))
        .padding(6)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
