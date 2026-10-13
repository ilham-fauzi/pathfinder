import Foundation

/// Saves the download list so it survives quitting the app.
struct QueueStore {
    struct Record: Codable {
        var id: UUID
        var url: String
        var title: String?
        var options: DownloadOptions
        var outputDir: String
        var status: DownloadStatus
        var progress: Double
        var error: String?
        var outputPath: String?
        var createdAt: Date
        var completedAt: Date?
        var optionId: String?
        var qualityLabel: String?
        var engine: DownloadEngine? = nil
        var pageURL: String? = nil
        var isHLS: Bool? = nil
        var browserFallback: Bool? = nil
        var realExtension: String? = nil
    }

    let fileURL: URL

    init(fileURL: URL = QueueStore.defaultURL) { self.fileURL = fileURL }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Pathfinder/queue.json")
    }

    /// Writes happen in order on one background queue, so the main thread never waits on the disk.
    private static let writeQueue = DispatchQueue(label: "Pathfinder.QueueStore", qos: .utility)

    /// Encodes now (the records hold reference-type options that may change later), writes in the background.
    func save(_ records: [Record]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(records) else { return }
        let fileURL = fileURL
        Self.writeQueue.async {
            // Persistence is best-effort; never block downloads on it.
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Wait for pending writes (tests, and before the app quits).
    static func flush() { writeQueue.sync {} }

    func load() -> [Record] {
        Self.flush()
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Record].self, from: data)) ?? []
    }
}
