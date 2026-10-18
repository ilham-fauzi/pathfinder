// Ed25519 signing for in-app updates.
//   swift scripts/update-key.swift keygen            create the key pair (private key stays in ~/.config/pathfinder)
//   swift scripts/update-key.swift public            print the public key to embed in the app
//   swift scripts/update-key.swift sign <file>       write <file>.sig (base64 signature)
import CryptoKit
import Foundation

let keyURL = URL(fileURLWithPath: NSHomeDirectory() + "/.config/pathfinder/update-signing.key")
let args = CommandLine.arguments.dropFirst()

func privateKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyURL, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        FileHandle.standardError.write(Data("No signing key at \(keyURL.path). Run: swift scripts/update-key.swift keygen\n".utf8))
        exit(1)
    }
    return key
}

switch args.first {
case "keygen":
    if FileManager.default.fileExists(atPath: keyURL.path) {
        FileHandle.standardError.write(Data("Key already exists at \(keyURL.path); refusing to overwrite.\n".utf8))
        exit(1)
    }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try key.rawRepresentation.base64EncodedString().write(to: keyURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    print("Private key: \(keyURL.path)  (back this up; losing it means users must reinstall manually)")
    print("Public key:  \(key.publicKey.rawRepresentation.base64EncodedString())")
case "public":
    print(privateKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let path = args.dropFirst().first, let data = FileManager.default.contents(atPath: path) else {
        FileHandle.standardError.write(Data("usage: sign <file>\n".utf8)); exit(1)
    }
    let signature = try privateKey().signature(for: data)
    try Data(signature).base64EncodedString().write(toFile: path + ".sig", atomically: true, encoding: .utf8)
    print("wrote \(path).sig")
default:
    FileHandle.standardError.write(Data("usage: keygen | public | sign <file>\n".utf8)); exit(1)
}
