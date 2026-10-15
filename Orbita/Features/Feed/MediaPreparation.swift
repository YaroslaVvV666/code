import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

enum MediaError: Error {
    case unsupported, tooLong, tooLarge, failed
}

/// Подготовка фото: уменьшение, перекодирование в JPEG (без метаданных и геолокации), аватар
enum ImageProcessing {
    static func prepare(_ data: Data, maxSide: CGFloat = 1600) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxSide / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.8)
    }

    /// Квадратный аватар 512×512 по центру кадра
    static func avatar(_ data: Data, side: CGFloat = 512) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let w = image.size.width, h = image.size.height
        let crop = min(w, h)
        guard crop > 0 else { return nil }
        let scale = side / crop

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let result = renderer.image { _ in
            image.draw(in: CGRect(x: -(w - crop) / 2 * scale, y: -(h - crop) / 2 * scale,
                                  width: w * scale, height: h * scale))
        }
        return result.jpegData(compressionQuality: 0.85)
    }
}

/// Видео из галереи как файл
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return MovieFile(url: destination)
        }
    }
}

enum MediaPreparer {
    static let maxVideoSeconds: Double = 300
    static let maxVideoBytes = 75 * 1024 * 1024

    static func prepare(_ item: PhotosPickerItem) async throws -> PreparedMedia {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            return try await prepareVideo(item)
        }
        guard let data = try await item.loadTransferable(type: Data.self) else { throw MediaError.unsupported }
        return try prepareImage(data)
    }

    private static func prepareImage(_ data: Data) throws -> PreparedMedia {
        guard let jpeg = ImageProcessing.prepare(data, maxSide: 1920),
              let image = UIImage(data: jpeg),
              let thumb = ImageProcessing.prepare(jpeg, maxSide: 500) else { throw MediaError.unsupported }
        return PreparedMedia(source: .image(jpeg), width: Int(image.size.width), height: Int(image.size.height),
                             duration: nil, thumbnail: thumb)
    }

    private static func prepareVideo(_ item: PhotosPickerItem) async throws -> PreparedMedia {
        guard let movie = try await item.loadTransferable(type: MovieFile.self) else { throw MediaError.unsupported }
        defer { try? FileManager.default.removeItem(at: movie.url) }

        let source = AVURLAsset(url: movie.url)
        let seconds = try await source.load(.duration).seconds
        if seconds > maxVideoSeconds { throw MediaError.tooLong }

        // сжимаем до 720p mp4
        let output = try await compress(source)
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        if size > maxVideoBytes {
            try? FileManager.default.removeItem(at: output)
            throw MediaError.tooLarge
        }

        let asset = AVURLAsset(url: output)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaError.unsupported }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: natural).applying(transform)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        var frame: CGImage?
        for t in [min(0.5, seconds / 2), 0] {
            if let result = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) { frame = result.image; break }
        }
        guard let frame, let thumb = UIImage(cgImage: frame).jpegData(compressionQuality: 0.75) else { throw MediaError.failed }

        return PreparedMedia(source: .video(output), width: Int(abs(oriented.width)), height: Int(abs(oriented.height)),
                             duration: seconds, thumbnail: thumb)
    }

    /// Сжатие с запасными вариантами: на симуляторе и на части устройств пресет 720p не срабатывает
    /// (в консоли CVPixelBufferCreate -6680 / -12900) — пробуем другие, а в крайнем случае берём исходный файл.
    private static func compress(_ asset: AVURLAsset) async throws -> URL {
        let presets = [AVAssetExportPreset1280x720, AVAssetExportPresetMediumQuality,
                       AVAssetExportPreset640x480, AVAssetExportPresetHighestQuality, AVAssetExportPresetPassthrough]
        for preset in presets {
            guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            let types = export.supportedFileTypes
            let type: AVFileType = types.contains(.mp4) ? .mp4 : (types.contains(.mov) ? .mov : (types.first ?? .mp4))
            let ext = type == .mov ? "mov" : "mp4"
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
            export.outputURL = output
            export.outputFileType = type
            export.shouldOptimizeForNetworkUse = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                export.exportAsynchronously { continuation.resume() }
            }
            if export.status == .completed,
               ((try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0) > 0 {
                return output
            }
            try? FileManager.default.removeItem(at: output)
        }
        // ничего не получилось — отправляем как есть (копия исходного файла)
        let ext = asset.url.pathExtension.isEmpty ? "mov" : asset.url.pathExtension
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: asset.url, to: copy)
            return copy
        } catch {
            throw MediaError.failed
        }
    }
}
