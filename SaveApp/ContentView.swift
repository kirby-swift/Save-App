// made by Kirby_swift

import SwiftUI

struct ContentView: View {
    @State private var videoURL = ""
    @State private var videoInfo: VideoInfo?
    @State private var isLoadingInfo = false
    @State private var isDownloading = false
    @State private var errorMessage: String?
    @State private var showSavedAlert = false

    private let downloadService = DownloadService()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "link")
                            .foregroundStyle(.secondary)
                        TextField("Вставьте ссылку на видео (YouTube, TikTok, …)", text: $videoURL)
                            .textContentType(.URL)
                            .autocapitalization(.none)
                            .keyboardType(.URL)
                            .onSubmit { fetchInfo() }
                    }
                    .padding()
                    .background(.bar, in: RoundedRectangle(cornerRadius: 12))

                    Button(action: fetchInfo) {
                        HStack {
                            if isLoadingInfo {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "magnifyingglass")
                            }
                            Text("Получить информацию")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(videoURL.trimmingCharacters(in: .whitespaces).isEmpty || isLoadingInfo)

                    if let error = errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }

                    if let info = videoInfo {
                        videoInfoCard(info)
                    }
                }
                .padding()
            }
            .navigationTitle("SaveApp")
            .alert("Сохранено", isPresented: $showSavedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Видео сохранено в галерею.")
            }
        }
    }

    private func videoInfoCard(_ info: VideoInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let thumbURLString = info.thumbnail, let thumbURL = URL(string: thumbURLString) {
                AsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                            .frame(height: 120)
                            .frame(maxWidth: .infinity)
                    case .empty:
                        ProgressView()
                            .frame(height: 120)
                            .frame(maxWidth: .infinity)
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(height: 180)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Text(info.title)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 16) {
                if let uploader = info.uploader, !uploader.isEmpty {
                    Label(uploader, systemImage: "person.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Label(info.durationFormatted, systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button(action: downloadVideo) {
                HStack {
                    if isDownloading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    Text("Скачать в галерею")
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDownloading)
        }
        .padding()
        .background(.bar, in: RoundedRectangle(cornerRadius: 16))
    }

    private func fetchInfo() {
        let url = videoURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        errorMessage = nil
        videoInfo = nil
        isLoadingInfo = true
        Task {
            do {
                let info = try await downloadService.fetchVideoInfo(url: url)
                await MainActor.run {
                    videoInfo = info
                    isLoadingInfo = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = Self.friendlyMessage(for: error)
                    isLoadingInfo = false
                }
            }
        }
    }

    private static func friendlyMessage(for error: Error) -> String {
        if let downloadError = error as? DownloadError {
            return downloadError.errorDescription ?? error.localizedDescription
        }
        let text = error.localizedDescription
        if text.contains("YouTubeKit") || text.contains("couldn't be completed") {
            return "Не удалось загрузить данные с YouTube. Проверьте ссылку и попробуйте позже."
        }
        return text
    }

    private func downloadVideo() {
        let url = videoURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        errorMessage = nil
        isDownloading = true
        Task {
            do {
                let data = try await downloadService.downloadVideo(url: url)
                try await downloadService.saveVideoToGallery(data: data)
                await MainActor.run {
                    isDownloading = false
                    showSavedAlert = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = Self.friendlyMessage(for: error)
                    isDownloading = false
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
