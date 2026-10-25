import Foundation
import CryptoKit
import Observation

/// A file the monitor vouches for: its SHA-256 and size as they were when it was saved or adopted.
struct IntegrityEntry: Codable, Identifiable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case download, tool, manual }

    var id: String { path }
    let path: String
    var sha256: String
    var size: Int64
    var modified: TimeInterval
    var source: Source
    var origin: String?
    var addedAt: Date
    /// What the first bytes of the file said, when that is worth a warning.
    var note: String?
}

enum IntegrityState: Sendable, Equatable {
    case unchecked, ok, modified, missing
}

/// File Integrity Monitoring: every file the browser saves, and the tools the app depends on (yt-dlp, ffmpeg),
/// gets a SHA-256 fingerprint. Later checks report files that were changed, replaced or deleted since,
/// and files that appeared in a watched folder without going through the browser.
@Observable
@MainActor
final class FileIntegrityMonitor {
    private(set) var entries: [IntegrityEntry] = []
    private(set) var states: [String: IntegrityState] = [:]
    private(set) var unexpected: [String] = []
    private(set) var lastCheck: Date?
    private(set) var busy = false
    /// A "Trust all" is running.
    private(set) var trusting = false
    /// Writes of the store so far, for tests.
    @ObservationIgnored private(set) var saveCount = 0
    @ObservationIgnored private let storeURL: URL
    /// Folders scanned for files that nobody registered (the Downloads folder, the tools folder).
    @ObservationIgnored var watchedFolders: () -> [String] = { [] }
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// When monitoring began: older files in a watched folder are not reported as new.
    @ObservationIgnored private var watchSince: Date = {
        let key = "integrityWatchSince"
        if let saved = UserDefaults.standard.object(forKey: key) as? Date { return saved }
        let now = Date()
        UserDefaults.standard.set(now, forKey: key)
        return now
    }()

    var changedCount: Int { states.values.filter { $0 == .modified || $0 == .missing }.count }
    var problemCount: Int { changedCount + unexpected.count }

    /// What "Trust all" would take: new files, and watched files that changed. Missing files have nothing to trust.
    var trustAllCounts: (new: Int, changed: Int) {
        (unexpected.count, entries.filter { states[$0.path] == .modified }.count)
    }
    var canTrustAll: Bool { trustAllCounts.new + trustAllCounts.changed > 0 }

    static var defaultStoreURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pathfinder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("integrity.json")
    }

    static var toolsFolder: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pathfinder/bin").path
    }

    init(storeURL: URL = FileIntegrityMonitor.defaultStoreURL) {
        self.storeURL = storeURL
        if let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder.iso.decode([IntegrityEntry].self, from: data) {
            entries = saved
        }
    }

    private func save() {
        saveCount += 1
        // A plain write: it also works where only this folder is writable.
        if let data = try? JSONEncoder.iso.encode(entries) { try? data.write(to: storeURL) }
    }

    /// Start the periodic quick check (size and modification time; a changed file is then hashed).
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.adoptTools()
            await self?.verify(deep: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.verify(deep: false)
            }
        }
    }

    // MARK: Recording

    /// Fingerprint a file that was just saved.
    func record(path: String, source: IntegrityEntry.Source, origin: String? = nil) async {
        guard let fingerprint = await Task.detached(priority: .utility, operation: { Self.fingerprint(path) }).value else { return }
        let entry = IntegrityEntry(path: path, sha256: fingerprint.hash, size: fingerprint.size, modified: fingerprint.modified,
                                   source: source, origin: origin, addedAt: Date(), note: fingerprint.note)
        entries.removeAll { $0.path == path }
        entries.insert(entry, at: 0)
        states[path] = .ok
        unexpected.removeAll { $0 == path }
        save()
    }

    /// Put the tools the app downloaded under watch.
    func adoptTools() async {
        let folder = Self.toolsFolder
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
        for name in names where !name.hasPrefix(".") {
            let path = folder + "/" + name
            if !entries.contains(where: { $0.path == path }) { await record(path: path, source: .tool) }
        }
    }

    /// Accept the file as it is now: the change was expected (for example, a tool update).
    func accept(_ path: String) async {
        let previous = entries.first { $0.path == path }
        await record(path: path, source: previous?.source ?? .manual, origin: previous?.origin)
    }

    /// Trust every new file and accept every changed one as it is now, in one go: fingerprints are made off the
    /// main thread and the store is written once. Missing files are left as they are. A file that can no longer be
    /// read is skipped and keeps its state.
    func trustAll() async {
        guard !trusting, !busy else { return }
        trusting = true
        defer { trusting = false }
        let newPaths = unexpected
        let changed = entries.filter { states[$0.path] == .modified }
        let paths = newPaths + changed.map(\.path)
        guard !paths.isEmpty else { return }
        let prints = await Task.detached(priority: .utility) { () -> [String: Fingerprint] in
            var result: [String: Fingerprint] = [:]
            for path in paths { result[path] = Self.fingerprint(path) }
            return result
        }.value

        let now = Date()
        for old in changed {
            guard let f = prints[old.path], let i = entries.firstIndex(where: { $0.path == old.path }) else { continue }
            entries[i].sha256 = f.hash
            entries[i].size = f.size
            entries[i].modified = f.modified
            entries[i].note = f.note
            states[old.path] = .ok
        }
        var trusted = Set<String>()
        for path in newPaths {
            guard let f = prints[path] else { continue }
            entries.removeAll { $0.path == path }
            entries.insert(IntegrityEntry(path: path, sha256: f.hash, size: f.size, modified: f.modified,
                                          source: .manual, origin: nil, addedAt: now, note: f.note), at: 0)
            states[path] = .ok
            trusted.insert(path)
        }
        unexpected.removeAll { trusted.contains($0) }
        save()
    }

    func remove(_ path: String) {
        entries.removeAll { $0.path == path }
        states[path] = nil
        save()
    }

    /// Stop watching every saved file and forget the "new file" alerts. The app's own tools stay under watch.
    /// Monitoring restarts from now, so files already in the watched folders are not reported as new afterwards.
    func clear() {
        let kept = entries.filter { $0.source == .tool }
        let keptPaths = Set(kept.map(\.path))
        entries = kept
        states = states.filter { keptPaths.contains($0.key) }
        unexpected = []
        watchSince = Date()
        UserDefaults.standard.set(watchSince, forKey: "integrityWatchSince")
        save()
    }

    // MARK: Checking

    func verify(deep: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let snapshot = entries
        let folders = watchedFolders()
        let known = Set(snapshot.map(\.path))
        let since = watchSince
        let result = await Task.detached(priority: .utility) { () -> ([String: IntegrityState], [String]) in
            var states: [String: IntegrityState] = [:]
            for entry in snapshot {
                let attributes = try? FileManager.default.attributesOfItem(atPath: entry.path)
                guard let attributes else { states[entry.path] = .missing; continue }
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                if !deep, size == entry.size, abs(modified - entry.modified) < 0.001 { states[entry.path] = .ok; continue }
                if size != entry.size { states[entry.path] = .modified; continue }
                states[entry.path] = Self.hash(of: entry.path) == entry.sha256 ? .ok : .modified
            }
            var fresh: [String] = []
            for folder in folders {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
                for name in names where !name.hasPrefix(".") {
                    let path = folder + "/" + name
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                          !known.contains(path), !name.hasSuffix(".part"), !name.hasSuffix(".crdownload"), !name.hasSuffix(".download")
                    else { continue }
                    // Only files that showed up after monitoring began: the folder's older contents are not alarming.
                    let created = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
                    guard let created, created > since, fresh.count < 200 else { continue }
                    fresh.append(path)
                }
            }
            return (states, fresh)
        }.value
        states = result.0
        unexpected = result.1.sorted()
        lastCheck = Date()
    }

    // MARK: Hashing

    struct Fingerprint: Sendable {
        let hash: String
        let size: Int64
        let modified: TimeInterval
        let note: String?
    }

    nonisolated static func fingerprint(_ path: String) -> Fingerprint? {
        guard let hash = hash(of: path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return Fingerprint(hash: hash, size: size, modified: modified, note: inspect(path))
    }

    nonisolated static func hash(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch { return nil }
            // nil (or empty) is the end of the file; a read error is the `catch` above.
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A downloaded file whose contents are a program, or a script, even though its name says otherwise.
    nonisolated static func inspect(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = [UInt8](((try? handle.read(upToCount: 8)) ?? Data()))
        guard head.count >= 2 else { return nil }
        let kind: String?
        if head.count >= 4, [[0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCF], [0xFE, 0xED, 0xFA, 0xCE]]
            .contains(where: { Array(head.prefix(4)) == $0 }) {
            kind = "a macOS program (Mach-O)"
        } else if head.count >= 4, Array(head.prefix(4)) == [0xCA, 0xFE, 0xBA, 0xBE] {
            kind = "a universal macOS program or Java class"
        } else if head.prefix(2) == [0x4D, 0x5A] {
            kind = "a Windows program (PE)"
        } else if head.count >= 4, Array(head.prefix(4)) == [0x7F, 0x45, 0x4C, 0x46] {
            kind = "a Linux program (ELF)"
        } else if head.prefix(2) == [0x23, 0x21] {
            kind = "a script (#!)"
        } else {
            kind = nil
        }
        guard let kind else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        if RiskyFile.documents.contains(ext) { return "Named .\(ext) but the contents are \(kind). Do not open it." }
        if RiskyFile.executable.contains(ext) || ext.isEmpty { return "Contents are \(kind)." }
        return nil
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}
