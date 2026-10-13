import Foundation

enum VPNAuthMethod: String, CaseIterable, Identifiable {
    /// A key file already on this Mac (~/.ssh), also unlocked by ssh-agent / the macOS keychain.
    case localKey
    /// A private key pasted or generated in the app, stored in the Keychain. Raw value kept for existing settings.
    case key = "key"
    case password
    var id: String { rawValue }
    var title: String {
        switch self {
        case .localKey: return "Key on this Mac"
        case .key: return "Pasted Key"
        case .password: return "Password"
        }
    }
}

/// Connection details for the SSH tunnel. Non-secret fields live in UserDefaults;
/// the private key, passphrase and password live in the Keychain.
@Observable
final class VPNSettings {
    enum Account {
        static let privateKey = "privateKey"
        static let passphrase = "passphrase"
        static let password = "password"
        static let localKeyPassphrase = "localKeyPassphrase"
    }

    var host: String = UserDefaults.standard.string(forKey: "vpnHost") ?? "" {
        didSet { UserDefaults.standard.set(host, forKey: "vpnHost") }
    }
    var sshPort: Int = UserDefaults.standard.object(forKey: "vpnSSHPort") as? Int ?? 22 {
        didSet { UserDefaults.standard.set(sshPort, forKey: "vpnSSHPort") }
    }
    var username: String = UserDefaults.standard.string(forKey: "vpnUser") ?? "" {
        didSet { UserDefaults.standard.set(username, forKey: "vpnUser") }
    }
    var localPort: Int = UserDefaults.standard.object(forKey: "vpnLocalPort") as? Int ?? 1080 {
        didSet { UserDefaults.standard.set(localPort, forKey: "vpnLocalPort") }
    }
    var authMethod: VPNAuthMethod = VPNAuthMethod(rawValue: UserDefaults.standard.string(forKey: "vpnAuth") ?? "") ?? .key {
        didSet { UserDefaults.standard.set(authMethod.rawValue, forKey: "vpnAuth") }
    }

    /// Path of the key file used by `.localKey`.
    var localKeyPath: String = UserDefaults.standard.string(forKey: "vpnLocalKeyPath") ?? VPNSettings.discoverLocalKeys().first ?? "" {
        didSet { UserDefaults.standard.set(localKeyPath, forKey: "vpnLocalKeyPath") }
    }
    /// Public half of the key saved in the Keychain, when known (generated in the app or derived from it).
    var storedPublicKey: String? = UserDefaults.standard.string(forKey: "vpnPublicKey") {
        didSet { UserDefaults.standard.set(storedPublicKey, forKey: "vpnPublicKey") }
    }

    var hasPrivateKey: Bool = KeychainStore.has(Account.privateKey)
    var hasLocalKeyPassphrase: Bool = KeychainStore.has(Account.localKeyPassphrase)
    var hasPassphrase: Bool = KeychainStore.has(Account.passphrase)
    var hasPassword: Bool = KeychainStore.has(Account.password)

    var proxyURL: String { "socks5h://127.0.0.1:\(localPort)" }

    /// nil when ready to connect, otherwise what is still missing.
    var missingField: String? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the server address." }
        if username.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the username." }
        if !(1...65535).contains(sshPort) || !(1024...65535).contains(localPort) { return "Check the port numbers." }
        switch authMethod {
        case .localKey:
            if localKeyPath.isEmpty { return "Choose a key file from this Mac." }
            if !FileManager.default.fileExists(atPath: localKeyPath) { return "The key file no longer exists. Choose another one." }
        case .key: if !hasPrivateKey { return "Paste your private key and save it." }
        case .password: if !hasPassword { return "Enter your password and save it." }
        }
        return nil
    }

    // MARK: - Keys on this Mac

    static var sshDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true) }

    /// Private keys in ~/.ssh: files that have a matching `.pub` next to them. Common names first.
    static func discoverLocalKeys() -> [String] {
        let dir = sshDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let preferred = ["id_ed25519", "id_ecdsa", "id_rsa", "id_ed25519_sk", "id_ecdsa_sk"]
        let keys = names.filter { !$0.hasSuffix(".pub") && names.contains($0 + ".pub") }
        let sorted = keys.sorted {
            let a = preferred.firstIndex(of: $0) ?? Int.max, b = preferred.firstIndex(of: $1) ?? Int.max
            return a != b ? a < b : $0 < $1
        }
        return sorted.map { dir.appendingPathComponent($0).path }
    }

    /// Public key for the current method, to copy into the server's authorized_keys.
    var publicKey: String? {
        switch authMethod {
        case .localKey:
            guard !localKeyPath.isEmpty else { return nil }
            return (try? String(contentsOfFile: localKeyPath + ".pub", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .key: return hasPrivateKey ? storedPublicKey : nil
        case .password: return nil
        }
    }

    // MARK: - Credentials

    enum KeyError: LocalizedError {
        case empty, publicKey, notAKey
        var errorDescription: String? {
            switch self {
            case .empty: return "The key is empty."
            case .publicKey: return "That is the public key (.pub). Paste the private key instead, the file without .pub."
            case .notAKey: return "This does not look like a private key. Include the BEGIN and END lines."
            }
        }
    }

    /// Normalise line endings and make sure the key ends with a newline (ssh rejects it otherwise).
    static func normalizedKey(_ raw: String) throws -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if key.isEmpty { throw KeyError.empty }
        if key.hasPrefix("ssh-") || key.hasPrefix("ecdsa-") { throw KeyError.publicKey }
        guard key.hasPrefix("-----BEGIN"), key.contains("PRIVATE KEY-----"), key.contains("-----END") else {
            throw KeyError.notAKey
        }
        key += "\n"
        return key
    }

    func saveKey(_ raw: String, publicKey: String? = nil) throws {
        let key = try Self.normalizedKey(raw)
        KeychainStore.set(key, for: Account.privateKey)
        hasPrivateKey = true
        storedPublicKey = publicKey ?? Self.derivePublicKey(key)
    }

    /// The public key of an unencrypted private key; nil when it has a passphrase or can't be read.
    private static func derivePublicKey(_ key: String) -> String? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ydl-pub-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        defer { try? fm.removeItem(at: dir) }
        let path = dir.appendingPathComponent("id").path
        guard fm.createFile(atPath: path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600]) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-y", "-P", "", "-f", path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let pub = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return pub.isEmpty ? nil : pub
    }

    /// Create a new ed25519 key pair, keep the private half in the Keychain and return the public half.
    @MainActor @discardableResult
    func generateKey() async throws -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ydl-gen-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let path = dir.appendingPathComponent("id").path
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                                                 arguments: ["-q", "-t", "ed25519", "-N", "", "-C", "Pathfinder", "-f", path])
        guard result.isSuccess,
              let priv = try? String(contentsOfFile: path, encoding: .utf8),
              let pub = try? String(contentsOfFile: path + ".pub", encoding: .utf8) else {
            throw KeyError.notAKey
        }
        let publicKey = pub.trimmingCharacters(in: .whitespacesAndNewlines)
        removeKey()
        try saveKey(priv, publicKey: publicKey)
        return publicKey
    }

    func savePassphrase(_ value: String) {
        if value.isEmpty { KeychainStore.remove(Account.passphrase) } else { KeychainStore.set(value, for: Account.passphrase) }
        hasPassphrase = !value.isEmpty
    }

    func savePassword(_ value: String) {
        if value.isEmpty { KeychainStore.remove(Account.password) } else { KeychainStore.set(value, for: Account.password) }
        hasPassword = !value.isEmpty
    }

    func removeKey() {
        KeychainStore.remove(Account.privateKey)
        KeychainStore.remove(Account.passphrase)
        hasPrivateKey = false
        hasPassphrase = false
        storedPublicKey = nil
    }

    func saveLocalKeyPassphrase(_ value: String) {
        if value.isEmpty { KeychainStore.remove(Account.localKeyPassphrase) } else { KeychainStore.set(value, for: Account.localKeyPassphrase) }
        hasLocalKeyPassphrase = !value.isEmpty
    }

    func removePassword() { savePassword("") }
}
