import Foundation

struct ChapterInfo: Codable {
    let title: String?
    let startTime: Double?
    let endTime: Double?
    
    enum CodingKeys: String, CodingKey {
        case title
        case startTime = "start_time"
        case endTime = "end_time"
    }
}
