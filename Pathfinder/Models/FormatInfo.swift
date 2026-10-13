import Foundation

struct FormatInfo: Codable, Identifiable, Comparable {
    let formatId: String
    let url: String?
    let ext: String?
    let resolution: String?
    let width: Int?
    let height: Int?
    let fps: Double?
    let vcodec: String?
    let acodec: String?
    let filesize: Int64?
    let filesizeApprox: Int64?
    let tbr: Double?
    let vbr: Double?
    let abr: Double?
    let asr: Double?
    let formatNote: String?
    let dynamicRange: String?
    let container: String?
    let protocol_: String?
    let language: String?
    let audioChannels: Int?
    let quality: Double?
    
    enum CodingKeys: String, CodingKey {
        case formatId = "format_id"
        case url
        case ext
        case resolution
        case width
        case height
        case fps
        case vcodec
        case acodec
        case filesize
        case filesizeApprox = "filesize_approx"
        case tbr
        case vbr
        case abr
        case asr
        case formatNote = "format_note"
        case dynamicRange = "dynamic_range"
        case container
        case protocol_ = "protocol"
        case language
        case audioChannels = "audio_channels"
        case quality
    }
    
    var id: String { formatId }
    
    var hasVideo: Bool {
        vcodec != "none" && vcodec != nil
    }
    
    var hasAudio: Bool {
        acodec != "none" && acodec != nil
    }
    
    var humanSize: String {
        let size = filesize ?? filesizeApprox ?? 0
        if size == 0 { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    
    var qualityLabel: String {
        if let res = resolution, res != "audio only" {
            return res
        }
        if hasAudio && !hasVideo {
            return "Audio"
        }
        return "Unknown"
    }
    
    static func < (lhs: FormatInfo, rhs: FormatInfo) -> Bool {
        return (lhs.quality ?? 0) < (rhs.quality ?? 0)
    }
    
    static func == (lhs: FormatInfo, rhs: FormatInfo) -> Bool {
        return lhs.formatId == rhs.formatId
    }
}
