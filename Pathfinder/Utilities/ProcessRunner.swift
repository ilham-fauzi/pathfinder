import Foundation

struct ProcessResult {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
    var stdoutString: String? { String(data: stdout, encoding: .utf8) }
    var stderrString: String? { String(data: stderr, encoding: .utf8) }
    var isSuccess: Bool { exitCode == 0 }
}

/// Accumulates raw pipe chunks and returns only complete lines.
/// yt-dlp progress lines can be split across reads, and terminate with \r or \n.
private final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        // One pass over the chunk, then drop everything consumed at once (removing line by line
        // from the front of `Data` is quadratic on large chunks).
        var lines: [String] = []
        var lineStart = buffer.startIndex
        for idx in buffer.indices where buffer[idx] == 0x0A || buffer[idx] == 0x0D {
            if idx > lineStart, let s = String(data: buffer[lineStart..<idx], encoding: .utf8), !s.isEmpty {
                lines.append(s)
            }
            lineStart = buffer.index(after: idx)
        }
        if lineStart > buffer.startIndex { buffer = Data(buffer[lineStart...]) }
        return lines
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        defer { buffer.removeAll() }
        guard !buffer.isEmpty, let s = String(data: buffer, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
}

/// Reports a process's exit without blocking a thread. `waitUntilExit()` parks a thread (a cooperative one,
/// when called from async code) and, on a GCD thread, could hang forever after the process had exited.
final class ProcessExitWaiter: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    /// Create before `process.run()`, so the handler is in place before the process can exit.
    init(_ process: Process) {
        self.process = process
        process.terminationHandler = { [self] p in
            p.terminationHandler = nil
            lock.lock()
            status = p.terminationStatus
            let ready = waiters
            waiters = []
            lock.unlock()
            ready.forEach { $0.resume(returning: p.terminationStatus) }
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else if process.processIdentifier == 0 {
                lock.unlock()
                continuation.resume(returning: -1)   // never launched
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

enum ProcessRunner {
    /// GUI apps launch with a minimal PATH, so yt-dlp can't find ffmpeg/python installed by Homebrew.
    static func environment(merging extra: [String: String]? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        let current = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [current]).joined(separator: ":")
        if let extra { env.merge(extra) { _, new in new } }
        return env
    }

    /// Run a process and collect all output
    static func run(executable: URL, arguments: [String], environment: [String: String]? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = Self.environment(merging: environment)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exit = ProcessExitWaiter(process)
        try process.run()

        // Read both pipes concurrently off the cooperative pool to avoid deadlocking
        // on full pipe buffers, then wait for the process to exit.
        async let stdoutData = Self.readAllData(from: stdoutPipe)
        async let stderrData = Self.readAllData(from: stderrPipe)

        let (outData, errData) = await (stdoutData, stderrData)
        let status = await exit.wait()

        return ProcessResult(
            exitCode: status,
            stdout: outData,
            stderr: errData
        )
    }

    private static func readAllData(from pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: data)
            }
        }
    }

    /// Run a process and stream stdout/stderr lines via AsyncStream
    static func stream(executable: URL, arguments: [String], environment: [String: String]? = nil) -> (process: Process, lines: AsyncStream<String>) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = Self.environment(merging: environment)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = LineBuffer()
        let stream = AsyncStream<String> { continuation in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    if let rest = buffer.flush() { continuation.yield(rest) }
                    continuation.finish()
                } else {
                    for line in buffer.append(data) {
                        continuation.yield(line)
                    }
                }
            }
        }

        return (process, stream)
    }
}
