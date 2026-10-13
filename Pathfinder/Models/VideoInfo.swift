import Foundation

struct VideoInfo: Codable, Identifiable {
    let id: String
    var title: String?
    let fulltitle: String?
    let description: String?
    let thumbnail: String?
    let duration: Double?
    let durationString: String?
    let uploadDate: String?
    let uploader: String?
    let uploaderUrl: String?
    let uploaderId: String?
    let channel: String?
    let channelId: String?
    let channelUrl: String?
    let viewCount: Int?
    let likeCount: Int?
    let commentCount: Int?
    let ageLimit: Int?
    let isLive: Bool?
    let wasLive: Bool?
    let webpageUrl: String?
    let originalUrl: String?
    let categories: [String]?
    let tags: [String]?
    let formats: [FormatInfo]?
    let subtitles: [String: [SubtitleTrack]]?
    let automaticCaptions: [String: [SubtitleTrack]]?
    let chapters: [ChapterInfo]?
    let thumbnails: [ThumbnailInfo]?
    let requestedFormats: [FormatInfo]?
    
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case fulltitle
        case description
        case thumbnail
        case duration
        case durationString = "duration_string"
        case uploadDate = "upload_date"
        case uploader
        case uploaderUrl = "uploader_url"
        case uploaderId = "uploader_id"
        case channel
        case channelId = "channel_id"
        case channelUrl = "channel_url"
        case viewCount = "view_count"
        case likeCount = "like_count"
        case commentCount = "comment_count"
        case ageLimit = "age_limit"
        case isLive = "is_live"
        case wasLive = "was_live"
        case webpageUrl = "webpage_url"
        case originalUrl = "original_url"
        case categories
        case tags
        case formats
        case subtitles
        case automaticCaptions = "automatic_captions"
        case chapters
        case thumbnails
        case requestedFormats = "requested_formats"
    }
}
