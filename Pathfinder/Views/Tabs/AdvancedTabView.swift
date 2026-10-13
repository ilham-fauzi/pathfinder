import SwiftUI

struct AdvancedTabView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        @Bindable var options = appState.downloadOptions
        
        Form {
            Section("Download Control") {
                Stepper("Concurrent Fragments: \(options.concurrentFragments)", value: $options.concurrentFragments, in: 1...32)
                TextField("Rate Limit (e.g. 5M)", text: Binding(
                    get: { options.limitRate ?? "" },
                    set: { options.limitRate = $0.isEmpty ? nil : $0 }
                ))
                Stepper("Retries: \(options.retries)", value: $options.retries, in: 0...100)
                TextField("Retry Sleep", text: Binding(
                    get: { options.retrySleep ?? "" },
                    set: { options.retrySleep = $0.isEmpty ? nil : $0 }
                ))
                TextField("Buffer Size", text: Binding(
                    get: { options.bufferSize ?? "" },
                    set: { options.bufferSize = $0.isEmpty ? nil : $0 }
                ))
                TextField("External Downloader", text: Binding(
                    get: { options.downloader ?? "" },
                    set: { options.downloader = $0.isEmpty ? nil : $0 }
                ))
                .help("native, aria2c, axel, etc.")
                TextField("Downloader Args", text: Binding(
                    get: { options.downloaderArgs ?? "" },
                    set: { options.downloaderArgs = $0.isEmpty ? nil : $0 }
                ))
            }
            
            Section("Video Selection") {
                TextField("Playlist Items (e.g. 1-3,7)", text: Binding(
                    get: { options.playlistItems ?? "" },
                    set: { options.playlistItems = $0.isEmpty ? nil : $0 }
                ))
                TextField("Min Filesize", text: Binding(
                    get: { options.minFilesize ?? "" },
                    set: { options.minFilesize = $0.isEmpty ? nil : $0 }
                ))
                TextField("Max Filesize", text: Binding(
                    get: { options.maxFilesize ?? "" },
                    set: { options.maxFilesize = $0.isEmpty ? nil : $0 }
                ))
                TextField("Date After", text: Binding(
                    get: { options.dateAfterFilter ?? "" },
                    set: { options.dateAfterFilter = $0.isEmpty ? nil : $0 }
                ))
                TextField("Match Filters", text: Binding(
                    get: { options.matchFilters ?? "" },
                    set: { options.matchFilters = $0.isEmpty ? nil : $0 }
                ))
                Stepper("Age Limit: \(options.ageLimit ?? 0)", value: Binding(
                    get: { options.ageLimit ?? 0 },
                    set: { options.ageLimit = $0 }
                ), in: 0...3650)
                Stepper("Max Downloads: \(options.maxDownloads ?? 0)", value: Binding(
                    get: { options.maxDownloads ?? 0 },
                    set: { options.maxDownloads = $0 }
                ), in: 0...1000)
                Toggle("No Playlist", isOn: $options.noPlaylist)
                Toggle("Playlist Random", isOn: $options.playlistRandom)
                Toggle("Break on Existing", isOn: $options.breakOnExisting)
            }
            
            Section("Livestream") {
                Toggle("Live from Start", isOn: $options.liveFromStart)
                TextField("Wait for Video (seconds)", text: Binding(
                    get: { options.waitForVideo ?? "" },
                    set: { options.waitForVideo = $0.isEmpty ? nil : $0 }
                ))
            }
            
            Section("Debug") {
                Toggle("Verbose", isOn: $options.verbose)
                Toggle("Quiet", isOn: $options.quiet)
                Toggle("Simulate", isOn: $options.simulate)
            }
            
            Section("Workarounds") {
                TextField("User Agent", text: Binding(
                    get: { options.userAgent ?? "" },
                    set: { options.userAgent = $0.isEmpty ? nil : $0 }
                ))
                TextField("Referer", text: Binding(
                    get: { options.referer ?? "" },
                    set: { options.referer = $0.isEmpty ? nil : $0 }
                ))
                Stepper("Sleep Interval: \(options.sleepInterval ?? 0)", value: Binding(
                    get: { options.sleepInterval ?? 0 },
                    set: { options.sleepInterval = $0 }
                ), in: 0...100)
                Stepper("Max Sleep Interval: \(options.maxSleepInterval ?? 0)", value: Binding(
                    get: { options.maxSleepInterval ?? 0 },
                    set: { options.maxSleepInterval = $0 }
                ), in: 0...100)
                Toggle("No Check Certificates", isOn: $options.noCheckCertificates)
            }
            
            Section("Extractor") {
                TextField("Use Extractors", text: Binding(
                    get: { options.useExtractors ?? "" },
                    set: { options.useExtractors = $0.isEmpty ? nil : $0 }
                ))
                TextField("Default Search", text: Binding(
                    get: { options.defaultSearch ?? "" },
                    set: { options.defaultSearch = $0.isEmpty ? nil : $0 }
                ))
                Toggle("Mark Watched", isOn: $options.markWatched)
                Toggle("Flat Playlist", isOn: $options.flatPlaylist)
                Toggle("Ignore Errors", isOn: $options.ignoreErrors)
            }
        }
        .formStyle(.grouped)
    }
}
