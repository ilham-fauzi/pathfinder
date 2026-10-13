import Foundation

enum SegmentedDownloadError: LocalizedError {
    case rangesNotSupported
    case badStatus(Int)
    case shortData

    var errorDescription: String? {
        switch self {
        case .rangesNotSupported: return "The server does not allow downloading in parts."
        case .badStatus(let code): return "The server answered with an error (\(code))."
        case .shortData: return "The server sent less data than expected."
        }
    }
}

/// Downloads one large file over several connections at once. The file is cut into pieces; each connection
/// fetches pieces with an HTTP Range request and writes them into place. A single connection often cannot use
/// the full line speed (per-connection limits, distance), so this is usually much faster for big files.
final class SegmentedDownloader: Sendable {
    /// Files smaller than this are not worth splitting.
    static let minimumLength: Int64 = 32 * 1_048_576
    static let connections = 8
    static let pieceLength: Int64 = 4 * 1_048_576
    /// The file is shown as this many equal parts, each with its own progress bar.
    static let laneCount = 8

    /// Bytes saved so far and how far along each part of the file is (0-100).
    struct Snapshot: Sendable {
        let done: Int64
        let lanes: [Double]
    }

    let url: URL
    let headers: [String: String]
    let length: Int64
    private let session: URLSession

    /// Whether the response to the browser's own request allows this: a plain 200 with a known big size,
    /// byte ranges accepted, and no transfer compression (which would make byte offsets meaningless).
    static func qualifies(_ response: HTTPURLResponse) -> Bool {
        guard response.statusCode == 200, response.expectedContentLength >= minimumLength,
              let scheme = response.url?.scheme, scheme == "http" || scheme == "https" else { return false }
        let ranges = (response.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased()
        let encoding = (response.value(forHTTPHeaderField: "Content-Encoding") ?? "").lowercased()
        return ranges.contains("bytes") && (encoding.isEmpty || encoding == "identity")
    }

    /// `socksPort`: the SSH tunnel's SOCKS port when the tunnel is required, so these connections use it too.
    init(url: URL, headers: [String: String], length: Int64, socksPort: Int?) {
        self.url = url
        self.headers = headers
        self.length = length
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpMaximumConnectionsPerHost = Self.connections
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        if let socksPort {
            config.connectionProxyDictionary = [
                "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": socksPort,
            ]
        }
        session = URLSession(configuration: config)
    }

    private func request(range: ClosedRange<Int64>? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range { req.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        return req
    }

    /// Saves the file to `destination` (written as `.part` first). `progress` gets the bytes saved so far.
    /// Falls back to one connection when the server turns out not to honour ranges.
    func run(to destination: URL, progress: @escaping @Sendable (Snapshot) -> Void) async throws {
        let part = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        guard FileManager.default.createFile(atPath: part.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        defer { session.finishTasksAndInvalidate() }
        do {
            do {
                try await segmented(into: part, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Ranges refused, or the server limits parallel connections (429/403/503): one connection still works.
                try Task.checkCancellation()
                try await single(into: part, progress: progress)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: part, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }
    }

    // MARK: Pieces

    /// Hands out pieces. The file is split into `laneCount` regions; each connection starts in its own region and
    /// works through it in order, so every part of the file moves at once. A connection that finishes its region
    /// helps the region with the most work left.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private let pieces: Int
        private let length: Int64
        private let lanes: Int
        private var next: [Int]
        private let upper: [Int]
        private let lower: [Int]
        private var laneDone: [Int64]
        private var done: Int64 = 0

        init(pieces: Int, length: Int64) {
            self.pieces = pieces
            self.length = length
            lanes = min(SegmentedDownloader.laneCount, pieces)
            lower = (0..<lanes).map { $0 * pieces / min(SegmentedDownloader.laneCount, pieces) }
            upper = (0..<lanes).map { ($0 + 1) * pieces / min(SegmentedDownloader.laneCount, pieces) }
            next = lower
            laneDone = [Int64](repeating: 0, count: lanes)
        }

        private func lane(of piece: Int) -> Int { (0..<lanes).first { piece < upper[$0] } ?? lanes - 1 }

        /// The next piece for this connection, or nil when nothing is left.
        func take(worker: Int) -> Int? {
            lock.lock(); defer { lock.unlock() }
            let own = worker % lanes
            if next[own] < upper[own] { defer { next[own] += 1 }; return next[own] }
            guard let busiest = (0..<lanes).max(by: { upper[$0] - next[$0] < upper[$1] - next[$1] }),
                  next[busiest] < upper[busiest] else { return nil }
            defer { next[busiest] += 1 }
            return next[busiest]
        }

        /// A piece finished with `n` bytes.
        func add(_ n: Int64, piece: Int) -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            done += n
            laneDone[lane(of: piece)] += n
            let result = (0..<lanes).map { i -> Double in
                let start = min(Int64(lower[i]) * SegmentedDownloader.pieceLength, length)
                let end = min(Int64(upper[i]) * SegmentedDownloader.pieceLength, length)
                return min(Double(laneDone[i]) / Double(max(end - start, 1)) * 100, 100)
            }
            return Snapshot(done: done, lanes: result)
        }
    }

    private func segmented(into file: URL, progress: @escaping @Sendable (Snapshot) -> Void) async throws {
        let fd = open(file.path, O_WRONLY)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(length)) == 0 else { throw CocoaError(.fileWriteOutOfSpace) }

        let pieces = Int((length + Self.pieceLength - 1) / Self.pieceLength)
        let counter = Counter(pieces: pieces, length: length)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<min(Self.connections, pieces) {
                group.addTask { [self] in
                    while let index = counter.take(worker: worker) {
                        let start = Int64(index) * Self.pieceLength
                        let end = min(start + Self.pieceLength, length) - 1
                        try await fetch(start...end, fd: fd) { progress(counter.add($0, piece: index)) }
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// One piece, tried up to 3 times.
    private func fetch(_ range: ClosedRange<Int64>, fd: Int32, counted: @Sendable (Int64) -> Void) async throws {
        var attempt = 0
        while true {
            do {
                let (tmp, response) = try await session.download(for: request(range: range))
                defer { try? FileManager.default.removeItem(at: tmp) }
                guard let http = response as? HTTPURLResponse else { throw SegmentedDownloadError.badStatus(0) }
                if http.statusCode == 200 { throw SegmentedDownloadError.rangesNotSupported }
                guard http.statusCode == 206 else { throw SegmentedDownloadError.badStatus(http.statusCode) }
                let handle = try FileHandle(forReadingFrom: tmp)
                defer { try? handle.close() }
                var offset = range.lowerBound
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    let written = chunk.withUnsafeBytes { pwrite(fd, $0.baseAddress, chunk.count, off_t(offset)) }
                    guard written == chunk.count else { throw CocoaError(.fileWriteOutOfSpace) }
                    offset += Int64(chunk.count)
                }
                guard offset == range.upperBound + 1 else { throw SegmentedDownloadError.shortData }
                counted(Int64(range.count))
                return
            } catch SegmentedDownloadError.rangesNotSupported {
                throw SegmentedDownloadError.rangesNotSupported
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                attempt += 1
                if attempt >= 3 { throw error }
                try await Task.sleep(for: .seconds(Double(attempt)))
            }
        }
    }

    /// The whole file over one connection (server without range support).
    private func single(into file: URL, progress: @escaping @Sendable (Snapshot) -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request())
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SegmentedDownloadError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        var buffer = Data(), total: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 262_144 {
                try handle.write(contentsOf: buffer)
                total += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress(Snapshot(done: total, lanes: []))
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); total += Int64(buffer.count); progress(Snapshot(done: total, lanes: [])) }
    }
}
