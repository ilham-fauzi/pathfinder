import CryptoKit
import Foundation

/// A published GitHub release that can be installed in place.
struct UpdateRelease: Equatable, Sendable {
    let version: String
    let notes: String
    let pageURL: URL
    let zipURL: URL
    let signatureURL: URL
}

enum UpdateError: LocalizedError {
    case badResponse(Int)
    case noInstallableAsset
    case badSignature
    case badPackage(String)
    case notWritable

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "The update server answered with HTTP \(code)."
        case .noInstallableAsset: return "The release has no signed download."
        case .badSignature: return "The download failed its signature check and was discarded."
        case .badPackage(let why): return "The downloaded app is not valid: \(why)"
        case .notWritable: return "Pathfinder can't replace itself in this location."
        }
    }
}

/// Pure pieces of the updater (no I/O) so they can be tested.
enum UpdateLogic {
    /// Ed25519 public key (base64) matching the private key that `scripts/release.sh` signs releases with.
    static let publicKey = "DD/j14TGEilqc5/KIx9aCwoWPX1sQOoopoC5inwHmzs="

    static let feedURL = URL(string: "https://api.github.com/repos/ilham-fauzi/pathfinder/releases/latest")!

    /// "v1.2.3", "1.2" or "1.2.3-beta" -> [1, 2, 3]. Non-numeric parts count as 0.
    static func components(_ version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let dash = text.firstIndex(of: "-") { text = String(text[..<dash]) }
        return text.split(separator: ".").map { Int($0) ?? 0 }
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = components(remote), b = components(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let body: String?
        let html_url: URL
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    /// Reads GitHub's "latest release" JSON. Needs a `.zip` and a sibling `.zip.sig`.
    static func parseRelease(_ data: Data) throws -> UpdateRelease {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard release.draft != true, release.prerelease != true,
              let zip = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let sig = release.assets.first(where: { $0.name == zip.name + ".sig" })
        else { throw UpdateError.noInstallableAsset }
        return UpdateRelease(
            version: components(release.tag_name).map(String.init).joined(separator: "."),
            notes: release.body ?? "",
            pageURL: release.html_url,
            zipURL: zip.browser_download_url,
            signatureURL: sig.browser_download_url
        )
    }

    /// `signature` is the base64 text of the `.sig` file.
    static func verify(_ data: Data, signature: String, publicKey: String = UpdateLogic.publicKey) -> Bool {
        guard let sig = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    /// Runs after the app quits: waits for it to exit, swaps the bundle, relaunches. Restores the old app on failure.
    /// Arguments: pid, new app, target app, work dir.
    static let installScript = """
    #!/bin/bash
    PID="$1"; NEW="$2"; TARGET="$3"; WORK="$4"
    exec >>"$WORK/install.log" 2>&1
    echo "== $(date) pid=$PID new=$NEW target=$TARGET"
    for i in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.3; done
    if kill -0 "$PID" 2>/dev/null; then echo "app did not quit"; exit 1; fi
    BACKUP="$WORK/previous.app"
    rm -rf "$BACKUP"
    if ! mv "$TARGET" "$BACKUP"; then echo "cannot move old app"; open "$TARGET"; exit 1; fi
    if ! ditto "$NEW" "$TARGET"; then
        echo "copy failed, restoring"; rm -rf "$TARGET"; mv "$BACKUP" "$TARGET"; open "$TARGET"; exit 1
    fi
    xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
    open "$TARGET"
    rm -rf "$BACKUP" "$NEW"
    echo "done"
    """
}
