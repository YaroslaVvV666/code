import SwiftUI
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Фильтры шортса (CoreImage) — одинаково работают в предпросмотре и при сохранении
enum ReelFilter: String, CaseIterable, Identifiable {
    case none, vivid, warm, cool, mono, noir, fade, vintage
    var id: String { rawValue }

    func title(_ s: Strings) -> String {
        switch self {
        case .none: return s.t("Без фильтра", "None")
        case .vivid: return s.t("Яркий", "Vivid")
        case .warm: return s.t("Тёплый", "Warm")
        case .cool: return s.t("Холодный", "Cool")
        case .mono: return s.t("Моно", "Mono")
        case .noir: return s.t("Нуар", "Noir")
        case .fade: return s.t("Выцвет", "Fade")
        case .vintage: return s.t("Ретро", "Vintage")
        }
    }

    /// Цвет-подсказка для кружка в списке
    var tint: Color {
        switch self {
        case .none: return .gray
        case .vivid: return .pink
        case .warm: return .orange
        case .cool: return .cyan
        case .mono: return Color(white: 0.7)
        case .noir: return Color(white: 0.25)
        case .fade: return Color(red: 0.75, green: 0.7, blue: 0.8)
        case .vintage: return Color(red: 0.8, green: 0.6, blue: 0.4)
        }
    }

    func apply(_ image: CIImage) -> CIImage {
        switch self {
        case .none:
            return image
        case .vivid:
            let f = CIFilter.colorControls()
            f.inputImage = image; f.saturation = 1.4; f.contrast = 1.1; f.brightness = 0.01
            return f.outputImage ?? image
        case .warm:
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 4300, y: 0)
            return f.outputImage ?? image
        case .cool:
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 9500, y: 0)
            return f.outputImage ?? image
        case .mono:
            let f = CIFilter.photoEffectMono(); f.inputImage = image
            return f.outputImage ?? image
        case .noir:
            let f = CIFilter.photoEffectNoir(); f.inputImage = image
            return f.outputImage ?? image
        case .fade:
            let f = CIFilter.photoEffectFade(); f.inputImage = image
            return f.outputImage ?? image
        case .vintage:
            let f = CIFilter.photoEffectInstant(); f.inputImage = image
            return f.outputImage ?? image
        }
    }
}

/// Накладываемые на видео элементы
struct ReelText: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var color = 0
    var style = 0          // 0 — обычный, 1 — на плашке, 2 — свечение
    var font = 0
    var cx = 0.5
    var cy = 0.45
    var scale = 1.0
    var rotation = 0.0     // радианы
}

struct ReelSticker: Identifiable, Equatable {
    let id = UUID()
    var image: UIImage
    var cx = 0.5
    var cy = 0.5
    var scale = 1.0
    var rotation = 0.0
}

enum ReelPalette {
    static let colors: [Color] = [
        .white, .black, Color(red: 1, green: 0.85, blue: 0.2), Color(red: 1, green: 0.27, blue: 0.3),
        Color(red: 1, green: 0.55, blue: 0.15), Color(red: 0.3, green: 0.85, blue: 0.4),
        Color(red: 0.2, green: 0.85, blue: 0.95), Color(red: 0.25, green: 0.45, blue: 1),
        Color(red: 0.62, green: 0.4, blue: 1), Color(red: 1, green: 0.45, blue: 0.75)
    ]
    private static let lightFlags = [true, false, true, false, true, true, true, false, false, true]
    static func color(_ i: Int) -> Color { colors[min(max(i, 0), colors.count - 1)] }
    static func isLight(_ i: Int) -> Bool { lightFlags[min(max(i, 0), lightFlags.count - 1)] }

    static func design(_ i: Int) -> Font.Design {
        switch i { case 1: return .rounded; case 2: return .serif; case 3: return .monospaced; default: return .default }
    }
    static let fontCount = 4
}

/// Один текст — используется и в редакторе, и при «запекании» в видео, поэтому выглядит одинаково
struct ReelTextView: View {
    let item: ReelText
    let unit: CGFloat          // ширина кадра

    var body: some View {
        let fg = ReelPalette.color(item.color)
        let size = unit * 0.07 * item.scale
        let filled = item.style == 1
        let label = Text(item.text)
            .font(.system(size: size, weight: .bold, design: ReelPalette.design(item.font)))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: unit * 0.88)
        Group {
            if filled {
                label.foregroundStyle(ReelPalette.isLight(item.color) ? Color.black : Color.white)
                    .padding(.horizontal, size * 0.45).padding(.vertical, size * 0.2)
                    .background(fg, in: RoundedRectangle(cornerRadius: size * 0.38, style: .continuous))
            } else if item.style == 2 {
                label.foregroundStyle(fg)
                    .shadow(color: fg.opacity(0.95), radius: size * 0.25)
                    .shadow(color: fg.opacity(0.7), radius: size * 0.6)
            } else {
                label.foregroundStyle(fg)
                    .shadow(color: .black.opacity(ReelPalette.isLight(item.color) ? 0.55 : 0.0), radius: size * 0.08, x: 0, y: size * 0.04)
                    .shadow(color: (ReelPalette.isLight(item.color) ? Color.clear : Color.white.opacity(0.55)), radius: size * 0.08)
            }
        }
    }
}

struct ReelStickerView: View {
    let item: ReelSticker
    let unit: CGFloat

    var body: some View {
        Image(uiImage: item.image).resizable().scaledToFit()
            .frame(width: unit * 0.42 * item.scale)
            .clipShape(RoundedRectangle(cornerRadius: unit * 0.025 * item.scale, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: unit * 0.012)
    }
}

/// Полный слой поверх кадра: рисуется в картинку 720×1280 и накладывается на каждый кадр
struct ReelOverlayCanvas: View {
    let texts: [ReelText]
    let stickers: [ReelSticker]
    let size: CGSize

    var body: some View {
        ZStack {
            ForEach(stickers) { st in
                ReelStickerView(item: st, unit: size.width)
                    .rotationEffect(.radians(st.rotation))
                    .position(x: st.cx * size.width, y: st.cy * size.height)
            }
            ForEach(texts) { t in
                ReelTextView(item: t, unit: size.width)
                    .rotationEffect(.radians(t.rotation))
                    .position(x: t.cx * size.width, y: t.cy * size.height)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

enum ReelRenderError: Error { case failed, download, empty }

/// Всё, что работает с видео вне главного потока
enum ReelRender {
    static let canvas = CGSize(width: 720, height: 1280)

    /// Композиция: вписать/заполнить кадр 9:16, фильтр, наложение
    static func composition(for asset: AVAsset, filter: ReelFilter, overlay: CIImage?, fill: Bool) -> AVMutableVideoComposition {
        let rect = CGRect(origin: .zero, size: canvas)
        let comp = AVMutableVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
            let src = request.sourceImage
            let e = src.extent
            guard e.width > 0, e.height > 0 else { request.finish(with: src, context: nil); return }
            let k = fill ? max(rect.width / e.width, rect.height / e.height) : min(rect.width / e.width, rect.height / e.height)
            var img = src
                .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .transformed(by: CGAffineTransform(scaleX: k, y: k))
            img = img.transformed(by: CGAffineTransform(translationX: (rect.width - e.width * k) / 2,
                                                        y: (rect.height - e.height * k) / 2))
            img = filter.apply(img)
            var out = img.composited(over: CIImage(color: .black).cropped(to: rect)).cropped(to: rect)
            if let overlay { out = overlay.composited(over: out) }
            request.finish(with: out, context: nil)
        })
        comp.renderSize = canvas
        return comp
    }

    /// Скачивает трек из плейлиста во временный файл с правильным расширением
    static func download(_ track: Track) async throws -> URL {
        guard let remote = ServerConfig.mediaURL(track.mediaID) else { throw ReelRenderError.download }
        let (tmp, resp) = try await URLSession.shared.download(from: remote)
        let mime = (resp.mimeType ?? "").lowercased()
        let ext = mime.contains("mpeg") || mime.contains("mp3") ? "mp3"
            : mime.contains("wav") ? "wav"
            : mime.contains("flac") ? "flac"
            : mime.contains("ogg") ? "ogg" : "m4a"
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try FileManager.default.moveItem(at: tmp, to: target)
        return target
    }

    // MARK: Слайд-шоу из фото

    /// Кадр 720×1280: фото по центру, а фон — его же увеличенная размытая копия
    private static func frameImage(_ photo: UIImage) -> CGImage? {
        let size = canvas
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1; format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let fillK = max(size.width / photo.size.width, size.height / photo.size.height)
        let fillRect = CGRect(x: (size.width - photo.size.width * fillK) / 2, y: (size.height - photo.size.height * fillK) / 2,
                              width: photo.size.width * fillK, height: photo.size.height * fillK)
        let bgImage = renderer.image { _ in
            UIColor.black.setFill(); UIRectFill(CGRect(origin: .zero, size: size))
            photo.draw(in: fillRect)
        }
        var background = bgImage.cgImage
        if let ci = CIImage(image: bgImage) {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = ci.clampedToExtent(); blur.radius = 28
            if let out = blur.outputImage?.cropped(to: CGRect(origin: .zero, size: size)),
               let cg = CIContext().createCGImage(out, from: CGRect(origin: .zero, size: size)) { background = cg }
        }
        let fitK = min(size.width / photo.size.width, size.height / photo.size.height)
        let fitRect = CGRect(x: (size.width - photo.size.width * fitK) / 2, y: (size.height - photo.size.height * fitK) / 2,
                             width: photo.size.width * fitK, height: photo.size.height * fitK)
        let final = renderer.image { ctx in
            if let background { UIImage(cgImage: background).draw(in: CGRect(origin: .zero, size: size)) }
            UIColor.black.withAlphaComponent(0.25).setFill(); UIRectFillUsingBlendMode(CGRect(origin: .zero, size: size), .normal)
            _ = ctx
            photo.draw(in: fitRect)
        }
        return final.cgImage
    }

    /// Беззвучный mp4 из фото: каждое показывается `seconds` секунд
    static func makeSlideshow(_ photos: [UIImage], seconds: Double) async throws -> URL {
        guard !photos.isEmpty else { throw ReelRenderError.empty }
        let width = Int(canvas.width), height = Int(canvas.height)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        guard writer.startWriting() else { throw ReelRenderError.failed }
        writer.startSession(atSourceTime: .zero)

        let step = 0.5
        let frames = max(1, Int((seconds / step).rounded()))
        var t = 0.0
        for photo in photos {
            try Task.checkCancellation()
            guard let cg = frameImage(photo) else { continue }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw ReelRenderError.failed }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            for _ in 0..<frames {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 4_000_000) }
                adaptor.append(buffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600))
                t += step
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: t, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw ReelRenderError.failed
        }
        return url
    }

    // MARK: Итоговая сборка

    struct Job {
        var baseURL: URL
        var fill: Bool
        var trimStart: Double
        var trimEnd: Double
        var filter: ReelFilter
        var overlay: CIImage?
        var musicFile: URL?
        var musicStart: Double
        var musicVolume: Float
        var originalVolume: Float
    }

    static func export(_ job: Job, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: job.baseURL)
        let comp = AVMutableComposition()
        let start = CMTime(seconds: job.trimStart, preferredTimescale: 600)
        let length = CMTime(seconds: max(0.5, job.trimEnd - job.trimStart), preferredTimescale: 600)
        let range = CMTimeRange(start: start, duration: length)

        guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first,
              let videoTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ReelRenderError.failed }
        try videoTrack.insertTimeRange(range, of: srcVideo, at: .zero)
        videoTrack.preferredTransform = try await srcVideo.load(.preferredTransform)

        var params: [AVMutableAudioMixInputParameters] = []
        if job.originalVolume > 0.001,
           let srcAudio = try await asset.loadTracks(withMediaType: .audio).first,
           let audioTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try audioTrack.insertTimeRange(range, of: srcAudio, at: .zero)
            let p = AVMutableAudioMixInputParameters(track: audioTrack)
            p.setVolume(job.originalVolume, at: .zero)
            params.append(p)
        }
        if let file = job.musicFile, job.musicVolume > 0.001 {
            let musicAsset = AVURLAsset(url: file)
            if let src = try await musicAsset.loadTracks(withMediaType: .audio).first,
               let musicTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let total = try await musicAsset.load(.duration)
                var cursor = CMTime.zero
                var from = CMTime(seconds: min(job.musicStart, max(0, total.seconds - 1)), preferredTimescale: 600)
                while cursor < length {
                    let piece = min(total - from, length - cursor)
                    if piece.seconds <= 0.01 { break }
                    try musicTrack.insertTimeRange(CMTimeRange(start: from, duration: piece), of: src, at: cursor)
                    cursor = cursor + piece
                    from = .zero
                }
                let p = AVMutableAudioMixInputParameters(track: musicTrack)
                p.setVolume(job.musicVolume, at: .zero)
                // плавный конец, чтобы музыка не обрывалась
                if length.seconds > 3 {
                    p.setVolumeRamp(fromStartVolume: job.musicVolume, toEndVolume: 0,
                                    timeRange: CMTimeRange(start: length - CMTime(seconds: 1, preferredTimescale: 600),
                                                           duration: CMTime(seconds: 1, preferredTimescale: 600)))
                }
                params.append(p)
            }
        }

        let videoComposition = composition(for: comp, filter: job.filter, overlay: job.overlay, fill: job.fill)
        let mix = AVMutableAudioMix()
        mix.inputParameters = params

        for preset in [AVAssetExportPresetHighestQuality, AVAssetExportPresetMediumQuality] {
            guard let session = AVAssetExportSession(asset: comp, presetName: preset) else { continue }
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
            session.outputURL = output
            session.outputFileType = .mp4
            session.videoComposition = videoComposition
            if !params.isEmpty { session.audioMix = mix }
            session.shouldOptimizeForNetworkUse = true
            session.fileLengthLimit = Int64(MediaPreparer.maxVideoBytes - 4 * 1024 * 1024)

            let watcher = Task {
                while !Task.isCancelled {
                    progress(Double(session.progress))
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { c.resume() }
            }
            watcher.cancel()
            if session.status == .completed,
               ((try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0) > 0 {
                progress(1)
                return output
            }
            try? FileManager.default.removeItem(at: output)
        }
        throw ReelRenderError.failed
    }

    /// Миниатюра и размеры готового файла
    static func describe(_ url: URL) async -> PreparedMedia? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        var frame: CGImage?
        for t in [min(0.5, duration / 2), 0] {
            if let r = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) { frame = r.image; break }
        }
        guard let frame, let thumb = UIImage(cgImage: frame).jpegData(compressionQuality: 0.75) else { return nil }
        return PreparedMedia(source: .video(url), width: Int(canvas.width), height: Int(canvas.height),
                             duration: duration, thumbnail: thumb)
    }
}
