import Foundation

/// Which files the "play videos with a different extension" setting looks at.
enum DisguisedScope: String, CaseIterable, Identifiable {
    case allowlist, all
    var id: String { rawValue }
    var title: String { self == .allowlist ? "Only these extensions" : "Any file" }
}

/// How quickly holding ← / → climbs from 2× to 64×.
enum HoldRamp: String, CaseIterable, Identifiable {
    case slow, normal, fast, fixed2x

    var id: String { rawValue }
    var title: String {
        switch self {
        case .slow: return "Slow"
        case .normal: return "Normal"
        case .fast: return "Fast"
        case .fixed2x: return "Always 2×"
        }
    }

    static let speeds = [2, 3, 4, 8, 16, 32, 64]
    /// A key held shorter than this is a tap.
    static let holdDelay = 0.2

    /// Seconds after key-down at which each speed in `speeds` is reached.
    private var thresholds: [Double] {
        switch self {
        case .normal: return [0.2, 2.0, 3.5, 5.0, 6.5, 8.0, 9.5]
        case .slow: return [0.2, 3.0, 5.25, 7.5, 9.75, 12.0, 14.25]
        case .fast: return [0.2, 1.0, 1.75, 2.5, 3.25, 4.0, 4.75]
        case .fixed2x: return [0.2]
        }
    }

    /// Index into `speeds` for a key held this long; nil while it is still a tap.
    func speedIndex(heldFor elapsed: Double) -> Int? {
        thresholds.lastIndex { elapsed >= $0 }
    }
}

/// Decides whether a file may be opened in the player, following the disguised-video settings.
enum PlayerGate {
    static let defaultExtensions = "jpg, png, dmg, pkg, zip, dat, bin, tmp, data, file, enc, pdf, txt, doc"

    struct Rules {
        var enabled: Bool
        var scope: DisguisedScope
        var extensions: [String]
    }

    enum Decision: Equatable {
        /// `realExtension` is set when the file's name lies about its type.
        case play(realExtension: String?, badge: String?)
        /// The name is not a media extension and the disguised-video setting is off.
        case disabled(ext: String)
        /// The setting is on but only for a list of extensions, and this one is not in it.
        case notAllowed(ext: String)
        /// The content is not a media file we recognise.
        case notMedia
        case missing
    }

    static func evaluate(path: String, rules: Rules) -> Decision {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        let ext = (path as NSString).pathExtension.lowercased()
        if FileNamer.mediaExtensions.contains(ext) { return .play(realExtension: nil, badge: nil) }
        // The file's content is only read once the user has turned the setting on.
        guard rules.enabled else { return .disabled(ext: ext) }
        // A file with no extension at all is the most common disguise, so it always passes the list.
        if rules.scope == .allowlist, !ext.isEmpty, !rules.extensions.contains(ext) { return .notAllowed(ext: ext) }
        guard let media = MediaDetector.detect(fileAt: path) else { return .notMedia }
        return .play(realExtension: media.ext, badge: "Disguised · \(media.container)")
    }
}

/// What came out of scanning files and folders the user picked.
struct IngestResult: Equatable {
    var entries: [PlayerRequest] = []
    /// Files skipped because the disguised-video setting is off.
    var needsSetting = 0
    /// Files that are not recognisable video or audio.
    var notVideo = 0
    var missing = 0
    /// Why single files were refused, so one picked file can explain itself.
    var rejections: [PlayerGate.Decision] = []

    var skipped: Int { needsSetting + notVideo + missing }
}

enum PlayerIngest {
    /// Files go through the gate as they are. A folder the user picked is taken as "videos in here": every file
    /// inside is looked at by its content, whatever its extension, as long as the disguised-video setting is on.
    /// Subfolders are not entered.
    static func scan(_ urls: [URL], rules: PlayerGate.Rules) -> IngestResult {
        var result = IngestResult()
        let folderRules = PlayerGate.Rules(enabled: rules.enabled, scope: .all, extensions: [])
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                result.missing += 1
                continue
            }
            if isDirectory.boolValue {
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
                for file in files.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
                where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    classify(file.path, rules: folderRules, into: &result, remember: false)
                }
            } else {
                classify(url.path, rules: rules, into: &result, remember: true)
            }
        }
        return result
    }

    private static func classify(_ path: String, rules: PlayerGate.Rules, into result: inout IngestResult, remember: Bool) {
        let decision = PlayerGate.evaluate(path: path, rules: rules)
        switch decision {
        case .play(let real, let badge):
            if !result.entries.contains(where: { $0.path == path }) {
                result.entries.append(PlayerRequest(path: path, realExtension: real, badge: badge))
            }
        case .disabled: result.needsSetting += 1
        case .notAllowed, .notMedia: result.notVideo += 1
        case .missing: result.missing += 1
        }
        if remember, case .play = decision {} else if remember { result.rejections.append(decision) }
    }
}
