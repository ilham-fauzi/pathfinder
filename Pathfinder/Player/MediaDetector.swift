import Foundation

/// What a media file really is, judged from its first bytes and never from its name.
struct DetectedMedia: Equatable {
    /// Extension that matches the content ("mkv", "mp4"…): players pick their demuxer from it.
    let ext: String
    /// Name shown in the "Disguised · MKV" badge.
    let container: String
}

enum MediaDetector {
    /// Bytes read from the start of a file.
    static let headerSize = 4096

    /// Brands of images that share the MP4 box layout (HEIC photos, AVIF, Canon RAW): not videos.
    private static let imageBrands: Set<String> = ["heic", "heix", "heim", "heis", "mif1", "msf1", "avif", "crx "]

    static func detect(fileAt path: String) -> DetectedMedia? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headerSize) else { return nil }
        return detect(head: head)
    }

    static func detect(head: Data) -> DetectedMedia? {
        let b = [UInt8](head.prefix(headerSize))
        guard b.count >= 12 else { return nil }

        func has(_ text: String, at offset: Int) -> Bool {
            let t = Array(text.utf8)
            return b.count >= offset + t.count && Array(b[offset..<offset + t.count]) == t
        }

        // MP4 family: a box size, then "ftyp" and a brand.
        if has("ftyp", at: 4) {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            if imageBrands.contains(brand) { return nil }
            switch brand {
            case "qt  ": return DetectedMedia(ext: "mov", container: "QuickTime")
            case "M4A ", "M4B ", "M4P ": return DetectedMedia(ext: "m4a", container: "M4A")
            case "3gp4", "3gp5", "3gp6", "3g2a": return DetectedMedia(ext: "3gp", container: "3GP")
            default: return DetectedMedia(ext: "mp4", container: "MP4")
            }
        }
        // Older QuickTime files start with an atom other than ftyp.
        if has("moov", at: 4) || has("mdat", at: 4) || has("wide", at: 4) {
            return DetectedMedia(ext: "mov", container: "QuickTime")
        }
        // Matroska and WebM share the EBML header; the DocType near its start tells them apart.
        if b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 {
            let docType = b[0..<min(b.count, 64)]
            let isWebM = docType.indices.contains { i in
                i + 4 <= docType.endIndex && Array(docType[i..<i + 4]) == Array("webm".utf8)
            }
            return isWebM ? DetectedMedia(ext: "webm", container: "WebM") : DetectedMedia(ext: "mkv", container: "Matroska")
        }
        if has("RIFF", at: 0) {
            if has("AVI ", at: 8) { return DetectedMedia(ext: "avi", container: "AVI") }
            if has("WAVE", at: 8) { return DetectedMedia(ext: "wav", container: "WAV") }
            return nil
        }
        if has("FLV", at: 0), b[3] == 0x01 { return DetectedMedia(ext: "flv", container: "FLV") }
        if has("OggS", at: 0) { return DetectedMedia(ext: "ogg", container: "Ogg") }
        if has("fLaC", at: 0) { return DetectedMedia(ext: "flac", container: "FLAC") }
        if has("ID3", at: 0) { return DetectedMedia(ext: "mp3", container: "MP3") }
        // Raw audio frames: 11 sync bits, then the layer tells MP3 from AAC (ADTS has layer 00).
        if b[0] == 0xFF, b[1] & 0xE0 == 0xE0 {
            let layer = (b[1] >> 1) & 0x3
            if layer == 0 { return b[1] & 0xF6 == 0xF0 ? DetectedMedia(ext: "aac", container: "AAC") : nil }
            if (b[1] >> 3) & 0x3 != 1 { return DetectedMedia(ext: "mp3", container: "MP3") }
        }
        // MPEG transport stream: a sync byte every 188 bytes.
        if b.count > 376, b[0] == 0x47, b[188] == 0x47, b[376] == 0x47 {
            return DetectedMedia(ext: "ts", container: "MPEG-TS")
        }
        if b[0] == 0x00, b[1] == 0x00, b[2] == 0x01, b[3] == 0xBA { return DetectedMedia(ext: "mpg", container: "MPEG-PS") }
        return nil
    }
}
