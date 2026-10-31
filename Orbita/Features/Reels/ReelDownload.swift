import Foundation
import AVFoundation
import Photos
import UIKit

/// Скачивание шортса в галерею: на видео накладывается движущийся по краю водяной знак «Focus» и ник автора
enum ReelDownload {
    enum Failure: Error { case noMedia, noAccess, export }

    static func run(_ post: Post) async throws {
        guard let item = post.media.first(where: { $0.kind == .video }), let url = ServerConfig.mediaURL(item.id) else { throw Failure.noMedia }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.noAccess }

        let (tmp, _) = try await URLSession.shared.download(from: url)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("dl-src-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: source)
        try FileManager.default.moveItem(at: tmp, to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let who = post.creator
        let handle = who.username.map { "@" + $0 } ?? who.name
        let output = try await watermark(source, handle: handle)
        defer { try? FileManager.default.removeItem(at: output) }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: output)
        }
    }

    private static func watermark(_ url: URL, handle: String) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableVideoComposition(propertiesOf: asset)      // размер и поворот уже учтены
        let size = composition.renderSize
        guard size.width > 0, size.height > 0 else { throw Failure.export }

        let unit = min(size.width, size.height * 9 / 16) / 390          // единица, чтобы знак выглядел одинаково на любом разрешении
        let margin = 16 * unit

        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        let video = CALayer()
        video.frame = parent.frame
        parent.addSublayer(video)

        // Знак: крупное «Focus» и ник автора. Он едет по краю кадра по кругу
        let titleFont = UIFont.systemFont(ofSize: 30 * unit, weight: .heavy)
        let handleFont = UIFont.systemFont(ofSize: 19 * unit, weight: .semibold)
        let title = "✦ Focus"
        let tw = (title as NSString).size(withAttributes: [.font: titleFont]).width
        let hw = (handle as NSString).size(withAttributes: [.font: handleFont]).width
        let boxW = ceil(min(max(tw, hw) + 8 * unit, size.width - margin * 2))
        let boxH = ceil((30 + 19) * unit * 1.35 + 4 * unit)

        func text(_ string: String, font: UIFont, alpha: CGFloat, y: CGFloat, height: CGFloat) -> CATextLayer {
            let layer = CATextLayer()
            layer.string = NSAttributedString(string: string, attributes: [
                .font: font, .foregroundColor: UIColor.white.withAlphaComponent(alpha).cgColor
            ])
            layer.contentsScale = 2
            layer.alignmentMode = .left
            layer.truncationMode = .end
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.6
            layer.shadowRadius = 4 * unit
            layer.shadowOffset = .zero
            layer.frame = CGRect(x: 0, y: y, width: boxW, height: height)
            return layer
        }
        let mark = CALayer()
        mark.bounds = CGRect(x: 0, y: 0, width: boxW, height: boxH)
        mark.addSublayer(text(title, font: titleFont, alpha: 0.92, y: boxH - 30 * unit * 1.35, height: 30 * unit * 1.35))
        mark.addSublayer(text(handle, font: handleFont, alpha: 0.85, y: 0, height: 19 * unit * 1.35))
        parent.addSublayer(mark)

        // путь центра знака — прямоугольник вдоль края кадра (начало координат слева снизу), по часовой стрелке
        let minX = margin + boxW / 2, maxX = size.width - margin - boxW / 2
        let minY = margin + boxH / 2, maxY = size.height - margin - boxH / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: minX, y: maxY))
        path.addLine(to: CGPoint(x: maxX, y: maxY))
        path.addLine(to: CGPoint(x: maxX, y: minY))
        path.addLine(to: CGPoint(x: minX, y: minY))
        path.closeSubpath()
        mark.position = CGPoint(x: minX, y: maxY)
        let lap = 9.0                                                  // секунд на полный круг
        let total = max(1, (try? await asset.load(.duration).seconds) ?? 30)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.calculationMode = .paced
        move.duration = lap
        move.repeatCount = Float(total / lap) + 1
        move.beginTime = AVCoreAnimationBeginTimeAtZero
        move.isRemovedOnCompletion = false
        mark.add(move, forKey: "edge")

        composition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { throw Failure.export }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("dl-out-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: out)
        export.outputURL = out
        export.outputFileType = .mp4
        export.videoComposition = composition
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        guard export.status == .completed else { throw export.error ?? Failure.export }
        return out
    }
}
