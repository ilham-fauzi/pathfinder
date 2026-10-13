import Foundation
import AppKit
import UniformTypeIdentifiers

/// How finished downloads are named on disk.
enum FileNaming: String, CaseIterable, Identifiable {
    /// The video title, as before.
    case original
    /// A code found in the title ("RDS-09888"), else the title's initials ("KRB"), else a random unique name.
    case short

    var id: String { rawValue }
    var title: String { self == .original ? "Original title" : "Short name" }
}

/// Renames finished media files according to the naming settings.
enum FileNamer {
    static let mediaExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "ts", "avi", "flv", "3gp",
        "mp3", "m4a", "aac", "opus", "ogg", "oga", "wav", "flac", "alac",
    ]

    static let defaultDisguiseExtensions = "jpg, png, dmg, pkg, zip, dat"

    // MARK: Short names

    /// Words that look like codes but are not: "EP 12", "Part 2", "Top 10", "FHD 60"…
    private static let notCodes: Set<String> = [
        "ep", "eps", "part", "pt", "vol", "ch", "chap", "no", "nr", "season", "top", "best", "fps", "hd", "fhd", "uhd",
        "sd", "qhd", "mp", "aac", "ac", "dts", "hevc", "avc", "av", "cd", "dvd", "bd", "web", "rip", "year", "the",
        "and", "page", "day", "week", "live", "full", "new",
    ]

    /// A code in the title, normalized: "[RDS-09888]" → "RDS-09888", "shkd 658" → "SHKD-658", "(09888)" → "09888".
    static func code(in title: String) -> String? {
        // 1. Inside brackets: the most explicit form.
        for match in matches(#"[\[\(\{【]\s*([A-Za-z0-9][A-Za-z0-9 _.\-]{1,24}?)\s*[\]\)\}】]"#, in: title) {
            if let code = letterCode(match, requireUppercaseWithSpace: false) ?? numberCode(match) { return code }
        }
        // 2. Letters followed by digits anywhere: "RDS-09888", "abc_123", "SHKD 658".
        for match in matches(#"(?<![A-Za-z0-9])([A-Za-z]{2,6}[-_ ]?\d{2,6}[A-Za-z]?)(?![A-Za-z0-9])"#, in: title) {
            if let code = letterCode(match, requireUppercaseWithSpace: true) { return code }
        }
        // 3. A number on its own: "09888", "4471230".
        for match in matches(#"(?<![A-Za-z0-9.])(\d{4,8})(?![A-Za-z0-9])"#, in: title) {
            if let code = numberCode(match) { return code }
        }
        return nil
    }

    /// "RDS-09888" style: 2–6 letters, optional separator, 2–6 digits, optional letter.
    private static func letterCode(_ text: String, requireUppercaseWithSpace: Bool) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let m = firstMatch(#"^([A-Za-z]{2,6})([-_ ]?)(\d{2,6})([A-Za-z]?)$"#, in: t), m.count == 5 else { return nil }
        let letters = m[1], separator = m[2], digits = m[3], suffix = m[4]
        guard !notCodes.contains(letters.lowercased()) else { return nil }
        // "Best 2024" is a phrase; "SHKD 658" (capitals) is a code.
        if separator == " ", requireUppercaseWithSpace, letters != letters.uppercased() { return nil }
        return "\(letters.uppercased())-\(digits)\(suffix.uppercased())"
    }

    /// A bare number of 4–8 digits that isn't a year or a resolution.
    private static func numberCode(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 3, t.count <= 8, t.allSatisfy(\.isNumber), t.allSatisfy(\.isASCII) else { return nil }
        if t.count == 4, let year = Int(t), (1900...2099).contains(year) { return nil }
        if ["1080", "2160", "1440", "4320", "0720", "0480"].contains(t) { return nil }
        return t
    }

    /// Initials of the title's words, ignoring bracketed parts: "Kebun Raya Bogor (Official)" → "KRB".
    static func initials(of title: String) -> String? {
        let withoutBrackets = title.replacingOccurrences(of: #"[\[\(\{【][^\]\)\}】]*[\]\)\}】]"#, with: " ",
                                                         options: .regularExpression)
        let words = withoutBrackets.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        guard letters.count >= 2 else { return nil }
        return String(letters.prefix(8))
    }

    /// Six characters without look-alikes (0/O, 1/I): "Q7K2XM".
    static func randomName() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }

    static func shortName(for title: String) -> String {
        code(in: title) ?? initials(of: title) ?? randomName()
    }

    // MARK: Renaming

    static func parseExtensions(_ list: String) -> [String] {
        list.split { $0 == "," || $0 == " " || $0 == ";" }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber } }
    }

    /// Rename a finished file. Returns the new path and, when the extension was disguised, the real one.
    /// Non-media files and files that can't be renamed are left as they are.
    static func apply(to path: String, title: String?, naming: FileNaming, disguise: Bool,
                      extensions: [String]) -> (path: String, realExtension: String?) {
        let url = URL(fileURLWithPath: path)
        let realExt = url.pathExtension.lowercased()
        guard mediaExtensions.contains(realExt), naming != .original || disguise,
              FileManager.default.fileExists(atPath: path) else { return (path, nil) }

        let dir = url.deletingLastPathComponent()
        let sourceTitle = title.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent
        let pool = extensions.filter { $0 != realExt }
        let newExt = disguise && !pool.isEmpty ? pool.randomElement()! : url.pathExtension

        var base: String
        var randomBase = false
        switch naming {
        case .original:
            base = url.deletingPathExtension().lastPathComponent
        case .short:
            if let c = code(in: sourceTitle) { base = c }
            else if let i = initials(of: sourceTitle) { base = i }
            else { base = randomName(); randomBase = true }
        }

        var target = dir.appendingPathComponent(base).appendingPathExtension(newExt)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) && target.path != path {
            // Random names get a fresh draw; others are numbered.
            let next = randomBase ? randomName() : "\(base)-\(n)"
            target = dir.appendingPathComponent(next).appendingPathExtension(newExt)
            n += 1
        }
        guard target.path != path else { return (path, nil) }
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            return (path, nil)
        }
        return (target.path, newExt.lowercased() == realExt ? nil : realExt)
    }

    // MARK: Helpers

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        return (0..<m.numberOfRanges).map {
            m.range(at: $0).location == NSNotFound ? "" : (text as NSString).substring(with: m.range(at: $0))
        }
    }
}

/// Opens downloaded files, including ones saved with a disguised extension: those are opened through a
/// temporary link that has the real extension, so the right player picks them up. The file itself is untouched.
enum FileOpener {
    static func open(_ path: String, realExtension: String? = nil) {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        guard !FileNamer.mediaExtensions.contains(ext) else { NSWorkspace.shared.open(url); return }
        let real = realExtension ?? sniffedExtension(of: path)
        guard let real, FileNamer.mediaExtensions.contains(real), let link = link(to: url, ext: real) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open(link)
    }

    /// The real type from the file's first bytes, for files opened without their item (toast, notification).
    private static func sniffedExtension(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return MediaSniff.fileExtension(for: handle.readData(ofLength: 512))
    }

    static func link(to file: URL, ext: String) -> URL? {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("Pathfinder/open", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Links from earlier days are no longer in use; recent ones may still be open in a player.
        let dayAgo = Date().addingTimeInterval(-86_400)
        for old in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            let created = (try? old.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < dayAgo { try? fm.removeItem(at: old) }
        }
        let link = dir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(file.deletingPathExtension().lastPathComponent)")
            .appendingPathExtension(ext)
        // A hard link looks like a normal file to every player; fall back to a symbolic link across volumes.
        if (try? fm.linkItem(at: file, to: link)) != nil { return link }
        if (try? fm.createSymbolicLink(at: link, withDestinationURL: file)) != nil { return link }
        return nil
    }
}
