// made by Kirby_swift

import Foundation
import UIKit
import Photos
import YouTubeKit

final class DownloadService {
    private let session: URLSession
    private let decoder = JSONDecoder()

    private static let tiktokAPIPrimary = "https://tdownv4.sl-bjs.workers.dev"
    private static let tiktokAPIFallback = "https://www.tikwm.com/api"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchVideoInfo(url: String) async throws -> VideoInfo {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let parsed = URL(string: trimmed) else {
            throw DownloadError.invalidURL
        }
        if isYouTubeURL(trimmed) {
            return try await fetchYouTubeInfo(url: parsed)
        }
        if isTikTokURL(trimmed) {
            return try await fetchTikTokInfo(url: trimmed)
        }
        throw DownloadError.unsupportedService
    }

    func downloadVideo(url: String) async throws -> Data {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw DownloadError.invalidURL }
        if isYouTubeURL(trimmed) {
            return try await downloadYouTube(url: trimmed)
        }
        if isTikTokURL(trimmed) {
            return try await downloadTikTok(url: trimmed)
        }
        throw DownloadError.unsupportedService
    }

    func saveVideoToGallery(data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized else {
                    continuation.resume(throwing: DownloadError.photoLibraryDenied)
                    return
                }
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                do {
                    try data.write(to: tempURL)
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: tempURL)
                    }) { success, error in
                        try? FileManager.default.removeItem(at: tempURL)
                        if success {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: error ?? DownloadError.photoLibraryFailed)
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func isYouTubeURL(_ url: String) -> Bool {
        url.contains("youtube.com") || url.contains("youtu.be")
    }

    private func makeYouTube(url: URL) -> YouTube {
        YouTube(url: url, methods: [.remote, .local])
    }

    private func fetchYouTubeInfo(url: URL) async throws -> VideoInfo {
        let yt = makeYouTube(url: url)
        let metadata = try? await yt.metadata
        async let oembed = fetchYouTubeOEmbed(videoID: yt.videoID)
        async let durationSeconds = fetchYouTubeDuration(watchURL: url)

        let o = await oembed
        let duration = await durationSeconds

        let title: String
        let thumbnail: String?
        if let meta = metadata, !meta.title.isEmpty {
            title = meta.title
            thumbnail = meta.thumbnail?.url.absoluteString
        } else {
            title = o?.title ?? "YouTube видео"
            thumbnail = o?.thumbnailUrl ?? "https://img.youtube.com/vi/\(yt.videoID)/mqdefault.jpg"
        }

        return VideoInfo(
            id: yt.videoID,
            title: title,
            thumbnail: thumbnail,
            duration: duration,
            uploader: o?.authorName,
            webpageUrl: url.absoluteString
        )
    }

    private func fetchYouTubeOEmbed(videoID: String) async -> YouTubeOEmbed? {
        guard let url = URL(string: "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=\(videoID)&format=json") else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? decoder.decode(YouTubeOEmbed.self, from: data)
    }

    private func fetchYouTubeDuration(watchURL: URL) async -> Double? {
        var request = URLRequest(url: watchURL)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: request),
              let html = String(data: data, encoding: .utf8) else { return nil }
        let patterns = ["\"lengthSeconds\":\"(\\d+)\"", "\"lengthSeconds\":(\\d+)", "\"length_seconds\":(\\d+)"]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                return Double(html[range])
            }
        }
        return nil
    }

    private func downloadYouTube(url: String) async throws -> Data {
        guard let parsed = URL(string: url) else { throw DownloadError.invalidURL }
        let yt = makeYouTube(url: parsed)
        let streams: [YouTubeKit.Stream]
        do {
            streams = try await yt.streams
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw DownloadError.serverError("Нет подключения к интернету. Проверьте сеть или попробуйте на устройстве.")
        } catch {
            throw DownloadError.serverError("Не удалось загрузить видео с YouTube. Проверьте ссылку и попробуйте позже.")
        }
        guard !streams.isEmpty else {
            throw DownloadError.serverError("Не удалось получить форматы. Попробуйте позже или другое видео.")
        }
        let withSound = streams.filter { $0.includesVideoAndAudioTrack }
        let candidates = withSound.isEmpty ? streams.filter { $0.includesVideoTrack } : withSound
        let chosen = (candidates.isEmpty ? streams : candidates)
            .max(by: { ($0.videoResolution ?? 0) < ($1.videoResolution ?? 0) }) ?? streams[0]
        let (data, _) = try await session.data(from: chosen.url)
        return data
    }

    private func isTikTokURL(_ url: String) -> Bool {
        url.contains("tiktok.com") || url.contains("vt.tiktok.com")
    }

    private func fetchTikTokInfo(url: String) async throws -> VideoInfo {
        if let info = try? await fetchTikTokInfoPrimary(url: url) { return info }
        if let info = try? await fetchTikTokInfoFallback(url: url) { return info }
        throw DownloadError.serverError("TikTok: не удалось получить данные. Проверьте ссылку или попробуйте позже.")
    }

    private func fetchTikTokInfoPrimary(url: String) async throws -> VideoInfo {
        guard let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let apiURL = URL(string: "\(Self.tiktokAPIPrimary)/?down=\(encoded)") else {
            throw DownloadError.invalidURL
        }
        let (data, response) = try await session.data(from: apiURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw DownloadError.badResponse }
        let tiktok = try decoder.decode(TikTokAPIResponse.self, from: data)
        return tiktok.toVideoInfo(webpageUrl: url)
    }

    private func fetchTikTokInfoFallback(url: String) async throws -> VideoInfo {
        guard let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let apiURL = URL(string: "\(Self.tiktokAPIFallback)/?url=\(encoded)") else {
            throw DownloadError.invalidURL
        }
        var request = URLRequest(url: apiURL)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw DownloadError.badResponse }
        let tikwm = try decoder.decode(TikWMResponse.self, from: data)
        return tikwm.toVideoInfo(webpageUrl: url)
    }

    private func downloadTikTok(url: String) async throws -> Data {
        if let data = try? await downloadTikTokPrimary(url: url) { return data }
        if let data = try? await downloadTikTokFallback(url: url) { return data }
        throw DownloadError.serverError("TikTok: не удалось скачать. Проверьте ссылку или попробуйте позже.")
    }

    private func downloadTikTokPrimary(url: String) async throws -> Data {
        guard let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let apiURL = URL(string: "\(Self.tiktokAPIPrimary)/?down=\(encoded)") else {
            throw DownloadError.invalidURL
        }
        let (data, _) = try await session.data(from: apiURL)
        let tiktok = try decoder.decode(TikTokAPIResponse.self, from: data)
        guard let downloadURLString = tiktok.downloadUrl, let downloadURL = URL(string: downloadURLString) else {
            throw DownloadError.serverError("Нет ссылки на скачивание")
        }
        let (videoData, _) = try await session.data(from: downloadURL)
        return videoData
    }

    private func downloadTikTokFallback(url: String) async throws -> Data {
        guard let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let apiURL = URL(string: "\(Self.tiktokAPIFallback)/?url=\(encoded)") else {
            throw DownloadError.invalidURL
        }
        var request = URLRequest(url: apiURL)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        let tikwm = try decoder.decode(TikWMResponse.self, from: data)
        let playURLString = tikwm.data?.play ?? tikwm.data?.wmplay
        guard let link = playURLString, let downloadURL = URL(string: link) else {
            throw DownloadError.serverError("Нет ссылки на скачивание")
        }
        let (videoData, _) = try await session.data(from: downloadURL)
        return videoData
    }
}

private struct YouTubeOEmbed: Codable {
    let title: String?
    let authorName: String?
    let thumbnailUrl: String?

    enum CodingKeys: String, CodingKey {
        case title
        case authorName = "author_name"
        case thumbnailUrl = "thumbnail_url"
    }
}

private struct TikTokAPIResponse: Codable {
    let title: String?
    let videoId: String?
    let author: TikTokAuthor?
    let downloadUrl: String?

    enum CodingKeys: String, CodingKey {
        case title, author
        case videoId = "video_id"
        case downloadUrl = "download_url"
    }

    func toVideoInfo(webpageUrl: String) -> VideoInfo {
        let durationSeconds = author?.duration.flatMap { Double($0) }
        let thumb = author?.avatar
        return VideoInfo(
            id: videoId,
            title: title ?? "Без названия",
            thumbnail: thumb,
            duration: durationSeconds,
            uploader: author?.nickname ?? author?.username,
            webpageUrl: webpageUrl
        )
    }
}

private struct TikTokAuthor: Codable {
    let username: String?
    let nickname: String?
    let avatar: String?
    let duration: Int?
}

private struct TikWMResponse: Codable {
    let code: Int?
    let data: TikWMData?
}

private struct TikWMData: Codable {
    let play: String?
    let wmplay: String?
    let title: String?
    let duration: Int?
    let author: TikWMAuthor?
}

private struct TikWMAuthor: Codable {
    let nickname: String?
    let avatar: String?
}

private extension TikWMResponse {
    func toVideoInfo(webpageUrl: String) -> VideoInfo {
        let d = data
        let durationSeconds = d?.duration.flatMap { Double($0) }
        return VideoInfo(
            id: nil,
            title: d?.title ?? "TikTok видео",
            thumbnail: d?.author?.avatar,
            duration: durationSeconds,
            uploader: d?.author?.nickname,
            webpageUrl: webpageUrl
        )
    }
}

enum DownloadError: LocalizedError {
    case invalidURL
    case badResponse
    case serverError(String)
    case unsupportedService
    case photoLibraryDenied
    case photoLibraryFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Неверная ссылка"
        case .badResponse: return "Ошибка ответа"
        case .serverError(let msg): return msg
        case .unsupportedService: return "Поддерживаются только YouTube и TikTok"
        case .photoLibraryDenied: return "Нет доступа к фото"
        case .photoLibraryFailed: return "Не удалось сохранить в галерею"
        }
    }
}
