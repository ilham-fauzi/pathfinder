import Foundation
import AppKit

enum VPNStatus: Equatable {
    case disconnected
    case connecting
    /// `verified` is false when the tunnel is up but a test request through it failed.
    case connected(exitIP: String?, verified: Bool)
    case failed(String)

    var isConnected: Bool { if case .connected = self { return true } else { return false } }
    var isConnecting: Bool { self == .connecting }
}

/// Collects ssh's stderr off the main thread.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

private func isLocalPortOpen(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port)).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result == 0
}

/// Runs `ssh -D` as a child process to give yt-dlp and the in-app browser a SOCKS proxy that exits through
/// the user's own server. The rest of the Mac's network is untouched.
@Observable
@MainActor
final class SSHTunnelManager {
    private(set) var status: VPNStatus = .disconnected {
        didSet { if status != oldValue { publish() } }
    }
    /// What the user asked for (the toggle). While true, downloads never run outside the tunnel.
    private(set) var wantsVPN = false {
        didSet { if wantsVPN != oldValue { publish() } }
    }
    var testResult: String?
    private(set) var isTesting = false

    @ObservationIgnored let settings: VPNSettings
    /// Called with (vpn required, proxy URL when connected) whenever either changes.
    @ObservationIgnored var onUpdate: ((Bool, String?) -> Void)?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var tempDir: URL?
    @ObservationIgnored private var intentionalStop = false
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var output = OutputCollector()

    init(settings: VPNSettings) {
        self.settings = settings
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.killProcess() }
        }
    }

    private func publish() {
        onUpdate?(wantsVPN, status.isConnected ? settings.proxyURL : nil)
    }

    // MARK: - Public API

    /// Toggle handler for the UI.
    func setOn(_ on: Bool) {
        if on {
            wantsVPN = true
            reconnectAttempts = 0
            Task { await connect() }
        } else {
            wantsVPN = false
            disconnect()
        }
    }

    func disconnect() {
        intentionalStop = true
        killProcess()
        cleanupTemp()
        status = .disconnected
    }

    /// Try the connection; leave it as it was afterwards (on if it was on, off if it was off).
    func test() async {
        guard !isTesting else { return }
        isTesting = true
        testResult = nil
        defer { isTesting = false }

        if case .connected = status {
            let ip = await fetchExitIP()
            status = .connected(exitIP: ip, verified: ip != nil)
            testResult = ip.map { "Connected. Your downloads exit from \($0)." }
                ?? "The tunnel is up, but traffic could not pass through it. The server may block TCP forwarding."
            return
        }
        if status.isConnecting { return }

        await connect()
        switch status {
        case .connected(let ip, let verified):
            testResult = verified
                ? (wantsVPN
                    ? "Success. Downloads and the browser exit from \(ip ?? "your server")."
                    : "Test passed: traffic would exit from \(ip ?? "your server"). The test connection is closed again; switch on “Use SSH tunnel” to use it.")
                : "Logged in, but traffic could not pass through the tunnel. The server may block TCP forwarding (AllowTcpForwarding)."
        case .failed(let message):
            testResult = message
        default:
            testResult = "Cancelled."
        }
        let keep = wantsVPN
        if !keep { let result = testResult; disconnect(); testResult = result }
    }

    /// Forget the trusted server key, e.g. after the server was reinstalled.
    func forgetServer() async {
        let host = settings.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, FileManager.default.fileExists(atPath: knownHostsPath) else { return }
        _ = try? await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                                         arguments: ["-R", hostPattern(host), "-f", knownHostsPath])
        try? FileManager.default.removeItem(atPath: knownHostsPath + ".old")
        testResult = "Server forgotten. You will be asked to confirm its fingerprint on the next connection."
    }

    // MARK: - Connecting

    private func connect() async {
        guard !status.isConnecting, !status.isConnected else { return }
        if let missing = settings.missingField { fail(missing, resetToggle: true); return }

        status = .connecting
        intentionalStop = false

        do { try await ensureHostKeyTrusted() }
        catch let e as TunnelError {
            if case .declined = e { status = .disconnected; wantsVPN = false; return }
            fail(e.message, resetToggle: true); return
        } catch { fail(error.localizedDescription, resetToggle: true); return }

        let port = settings.localPort
        if isLocalPortOpen(port) {
            await killOrphanedTunnels(port: port)
            try? await Task.sleep(for: .milliseconds(300))
        }
        if isLocalPortOpen(port) {
            fail("Port \(port) is already in use. Choose another local port in the SSH tunnel settings.", resetToggle: true)
            return
        }

        let session = UUID()
        sessionID = session
        let collector = OutputCollector()
        output = collector

        do {
            let (args, env) = try prepareLaunch()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = args
            p.environment = ProcessRunner.environment(merging: env)
            p.standardInput = FileHandle.nullDevice
            let errPipe = Pipe()
            p.standardError = errPipe
            p.standardOutput = FileHandle.nullDevice
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { collector.append(d) }
            }
            p.terminationHandler = { [weak self] proc in
                let code = proc.terminationStatus
                Task { @MainActor in self?.processExited(session: session, code: code) }
            }
            try p.run()
            process = p
        } catch {
            cleanupTemp()
            fail((error as? TunnelError)?.message ?? "Could not start ssh: \(error.localizedDescription)", resetToggle: true)
            return
        }

        // ssh opens the local SOCKS port only after authentication succeeded.
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(250))
            guard sessionID == session, status.isConnecting else { return }
            guard process?.isRunning == true else { return }   // processExited reports the error
            if isLocalPortOpen(port) {
                cleanupTemp()   // the key file is no longer needed once logged in
                reconnectAttempts = 0
                let ip = await fetchExitIP()
                guard sessionID == session, process?.isRunning == true else { return }
                status = .connected(exitIP: ip, verified: ip != nil)
                return
            }
        }
        guard sessionID == session else { return }
        killProcess()
        cleanupTemp()
        fail("The server did not respond in time.", resetToggle: true)
    }

    private func fail(_ message: String, resetToggle: Bool) {
        status = .failed(message)
        if resetToggle { wantsVPN = false }
    }

    private func processExited(session: UUID, code: Int32) {
        guard session == sessionID else { return }
        process = nil
        cleanupTemp()
        if intentionalStop { return }

        let message = Self.friendlyError(from: output.text, code: code)
        if status.isConnecting {
            fail(message, resetToggle: true)
        } else if wantsVPN, reconnectAttempts < 3 {
            // Lost an established tunnel: downloads stay blocked, retry a few times.
            reconnectAttempts += 1
            status = .connecting
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard wantsVPN, status.isConnecting else { return }
                status = .disconnected
                await connect()
            }
        } else {
            status = .failed("Connection lost. \(message)")
        }
    }

    private func killProcess() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    /// An ssh tunnel left behind by an earlier run of this app (crash, force quit, kill) keeps holding the port.
    /// Stop it, but only when it is clearly ours: an orphaned /usr/bin/ssh using this app's known_hosts file and this port.
    private func killOrphanedTunnels(port: Int) async {
        guard let lsof = try? await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
                                                      arguments: ["-t", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]),
              let out = lsof.stdoutString else { return }
        for pid in out.split(whereSeparator: \.isNewline).compactMap({ Int32($0) }) {
            guard let ps = try? await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/ps"),
                                                        arguments: ["-o", "ppid=,command=", "-p", "\(pid)"]),
                  let line = ps.stdoutString?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0] == "1" else { continue }
            let command = String(parts[1])
            guard command.hasPrefix("/usr/bin/ssh "), command.contains(knownHostsPath),
                  command.contains("-D 127.0.0.1:\(port)") else { continue }
            kill(pid, SIGTERM)
        }
    }

    // MARK: - Launch arguments

    private var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pathfinder", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private var knownHostsPath: String { supportDir.appendingPathComponent("known_hosts").path }

    private func hostPattern(_ host: String) -> String {
        settings.sshPort == 22 ? host : "[\(host)]:\(settings.sshPort)"
    }

    private func prepareLaunch() throws -> ([String], [String: String]) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ydl-ssh-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        tempDir = dir

        var args = [
            "-F", "/dev/null",
            // Quoted: the path has a space ("Application Support") and ssh splits this option on whitespace.
            "-o", "UserKnownHostsFile=\"\(knownHostsPath)\"",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-p", "\(settings.sshPort)",
            "-N", "-D", "127.0.0.1:\(settings.localPort)",
        ]
        var secret: String?

        switch settings.authMethod {
        case .localKey:
            let path = settings.localKeyPath
            guard !path.isEmpty, fm.fileExists(atPath: path) else {
                throw TunnelError.message("The key file was not found. Choose another one in the SSH tunnel settings.")
            }
            // Keep ssh-agent and the macOS keychain, so a key unlocked with `ssh-add --apple-use-keychain` needs no prompt.
            args += ["-i", path, "-o", "IdentitiesOnly=yes", "-o", "PreferredAuthentications=publickey",
                     "-o", "UseKeychain=yes", "-o", "AddKeysToAgent=no"]
            secret = KeychainStore.get(VPNSettings.Account.localKeyPassphrase)
        case .key:
            guard let key = KeychainStore.get(VPNSettings.Account.privateKey) else {
                throw TunnelError.message("No private key is saved.")
            }
            let keyPath = dir.appendingPathComponent("id").path
            guard fm.createFile(atPath: keyPath, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw TunnelError.message("Could not prepare the key file.")
            }
            args += ["-i", keyPath, "-o", "IdentitiesOnly=yes", "-o", "PreferredAuthentications=publickey",
                     "-o", "IdentityAgent=none"]
            secret = KeychainStore.get(VPNSettings.Account.passphrase)
        case .password:
            guard let pw = KeychainStore.get(VPNSettings.Account.password) else {
                throw TunnelError.message("No password is saved.")
            }
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no",
                     "-o", "IdentityAgent=none"]
            secret = pw
        }

        var env: [String: String] = [:]
        if let secret {
            let askpass = dir.appendingPathComponent("askpass.sh").path
            let script = "#!/bin/sh\nprintf '%s\\n' \"$YD_SSH_SECRET\"\n"
            guard fm.createFile(atPath: askpass, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]) else {
                throw TunnelError.message("Could not prepare the login helper.")
            }
            env = ["SSH_ASKPASS": askpass, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0", "YD_SSH_SECRET": secret]
        } else {
            args += ["-o", "BatchMode=yes"]
        }

        args.append("\(settings.username.trimmingCharacters(in: .whitespaces))@\(settings.host.trimmingCharacters(in: .whitespaces))")
        return (args, env)
    }

    private func cleanupTemp() {
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
        tempDir = nil
    }

    // MARK: - Host key confirmation

    private enum TunnelError: Error {
        case declined
        case message(String)
        var message: String { if case .message(let m) = self { return m } else { return "Cancelled." } }
    }

    /// First connection to a server: show its fingerprint and ask the user to trust it.
    private func ensureHostKeyTrusted() async throws {
        let host = settings.host.trimmingCharacters(in: .whitespaces)
        let known = try? await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                                                 arguments: ["-F", hostPattern(host), "-f", knownHostsPath])
        if let known, known.isSuccess { return }

        let scan = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/ssh-keyscan"),
                                               arguments: ["-T", "8", "-p", "\(settings.sshPort)", host])
        guard let keys = scan.stdoutString, keys.contains("ssh-") || keys.contains("ecdsa-") else {
            throw TunnelError.message("Could not reach the server to read its fingerprint. Check the address and SSH port.")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ydl-scan-\(UUID().uuidString)")
        try keys.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fp = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                                             arguments: ["-lf", tmp.path])
        let fingerprints = (fp.stdoutString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let alert = NSAlert()
        alert.messageText = "Trust this server?"
        alert.informativeText = "First connection to \(host). Compare this fingerprint with your server (run ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub there) before continuing.\n\n\(fingerprints)"
        alert.addButton(withTitle: "Trust and Connect")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { throw TunnelError.declined }

        let existing = (try? String(contentsOfFile: knownHostsPath, encoding: .utf8)) ?? ""
        let lines = keys.split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: "\n")
        try (existing + lines + "\n").write(toFile: knownHostsPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Verification

    /// Ask the outside world which IP we appear from, through the tunnel. nil = traffic doesn't pass.
    private func fetchExitIP() async -> String? {
        let result = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: ["-s", "--max-time", "8", "--socks5-hostname", "127.0.0.1:\(settings.localPort)", "https://api.ipify.org"])
        guard let result, result.isSuccess,
              let ip = result.stdoutString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ip.isEmpty, ip.count < 64, ip.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" || $0.isHexDigit }) else { return nil }
        return ip
    }

    // MARK: - Messages

    nonisolated static func friendlyError(from stderr: String, code: Int32) -> String {
        let s = stderr.lowercased()
        if s.contains("host key is known") && !s.contains("remote host identification has changed") {
            return "The server's fingerprint is not saved for this app. Use “Forget server”, then connect again to confirm it."
        }
        if s.contains("host key verification failed") || s.contains("remote host identification has changed") {
            return "The server's identity changed. If you did not reinstall it, do not continue. Otherwise use “Forget server” in the SSH tunnel settings."
        }
        if s.contains("permission denied") {
            return "Login failed. Check the username and the password or key passphrase. For a key, its public key must be in ~/.ssh/authorized_keys on the server."
        }
        if s.contains("incorrect passphrase") || s.contains("bad passphrase") {
            return "Wrong key passphrase."
        }
        if s.contains("invalid format") || s.contains("error in libcrypto") || s.contains("load key") {
            return "The private key could not be read. Choose the key file again, or paste it including the BEGIN and END lines."
        }
        if s.contains("could not resolve hostname") { return "Server address not found. Check the address." }
        if s.contains("connection refused") { return "The server refused the connection. Check the address and SSH port." }
        if s.contains("timed out") { return "Could not reach the server (timed out)." }
        // EADDRNOTAVAIL: macOS has no usable way out to the server. Usually a VPN app left a route to it through the
        // router of a previous network (after switching Wi-Fi), or the Mac is offline.
        if s.contains("can't assign requested address") {
            return "Your Mac has no working route to the server. This usually happens after switching networks while "
                + "another VPN is on: reconnect or turn off that VPN, or turn Wi-Fi off and on, then try again."
        }
        if s.contains("no route to host") || s.contains("network is unreachable") {
            return "Your Mac has no route to the server. Check your internet connection or any other VPN that is on."
        }
        if s.contains("address already in use") || s.contains("cannot listen") {
            return "The local port is already in use. Choose another one in the SSH tunnel settings."
        }
        let last = stderr.split(separator: "\n").map(String.init).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        return last ?? "ssh stopped unexpectedly (code \(code))."
    }
}
