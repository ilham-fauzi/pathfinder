import Foundation
import ContentBlockerConverter

struct FilterList: Sendable {
    let id: String
    let name: String
    let url: URL
}

/// EasyList, EasyPrivacy, uBlock filters and AdGuard Base: downloaded by the app, cached on disk, converted to WebKit content-blocker rules.
enum FilterLists {
    static let all = [
        FilterList(id: "easylist", name: "EasyList", url: URL(string: "https://easylist.to/easylist/easylist.txt")!),
        FilterList(id: "easyprivacy", name: "EasyPrivacy", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
        FilterList(id: "ublock", name: "uBlock filters", url: URL(string: "https://ublockorigin.github.io/uAssets/filters/filters.txt")!),
        FilterList(id: "adguard", name: "AdGuard Base", url: URL(string: "https://filters.adtidy.org/extension/safari/filters/2.txt")!),
    ]

    /// Lists are refreshed when older than this.
    static let maxAge: TimeInterval = 7 * 24 * 3600

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pathfinder/filters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func file(for list: FilterList) -> URL { directory.appendingPathComponent("\(list.id).txt") }

    static func modified(_ list: FilterList) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file(for: list).path))?[.modificationDate] as? Date
    }

    static func isStale(_ list: FilterList) -> Bool {
        guard let date = modified(list) else { return true }
        return Date().timeIntervalSince(date) > maxAge
    }

    enum DownloadError: LocalizedError {
        case badResponse
        var errorDescription: String? { "The filter list could not be downloaded." }
    }

    static func download(_ list: FilterList) async throws {
        let (data, response) = try await URLSession.shared.data(from: list.url)
        // Filter lists start with "[Adblock…" or with "! " comment lines (uBlock, AdGuard).
        let head = String(decoding: data.prefix(20), as: UTF8.self)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count > 100_000,
              head.hasPrefix("[Adblock") || head.hasPrefix("!") else { throw DownloadError.badResponse }
        try data.write(to: file(for: list), options: .atomic)
    }

    /// Rules in WebKit format, or nil when the list is missing. Heavy: run off the main thread.
    static func convertedRules(from file: URL) async -> (json: String, count: Int)? {
        await Task.detached(priority: .utility) { () -> (String, Int)? in
            guard var text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            text.makeContiguousUTF8()
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            let result = ContentBlockerConverter().convertArray(
                rules: lines, safariVersion: .safari16_4, advancedBlocking: false)
            guard result.safariRulesCount > 0 else { return nil }
            return (AdBlocker.sparingPages(result.safariRulesJSON), result.safariRulesCount)
        }.value
    }
}
