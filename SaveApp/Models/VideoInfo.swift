// made by Kirby_swift

import Foundation

struct VideoInfo: Codable, Identifiable {
    let id: String?
    let title: String
    let thumbnail: String?
    let duration: Double?
    let uploader: String?
    let webpageUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, title, thumbnail, duration, uploader
        case webpageUrl = "webpage_url"
    }

    var durationFormatted: String {
        guard let duration = duration, duration > 0 else { return "—" }
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%d:%02d", m, s)
    }
}
