import Foundation

struct ThumbnailInfo: Codable, Identifiable {
    let id: String
    let url: String?
    let width: Int?
    let height: Int?
    let preference: Int?
}
