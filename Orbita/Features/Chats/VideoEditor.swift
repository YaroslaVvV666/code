import SwiftUI
import AVFoundation
import UIKit
import Combine

// MARK: - Редактор видео перед отправкой (как у фото): обрезка, звук, поворот, «как GIF»

/// Что сделали с видео
struct VideoEdit: Equatable {
    var start: Double = 0
    var end: Double = 0
    var muted = false
    var rotation = 0          // 0, 90, 180, 270 — по часовой
    var asGIF = false         // без звука и по кругу у получателя
}

enum VideoEditExport {
    /// Собирает отредактированное видео в обычный mp4 (H.264, до 720p) — такой файл принимает любой сервер и плеер
    static func export(_ url: URL, edit: VideoEdit) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let vt = try? await asset.loadTracks(withMediaType: .video).first,
              let full = try? await asset.load(.duration) else { return nil }
        let start = CMTime(seconds: max(0, edit.start), preferredTimescale: 600)
        let endSec = edit.end > edit.start ? edit.end : full.seconds
        let range = CMTimeRange(start: start, end: CMTime(seconds: min(endSec, full.seconds), preferredTimescale: 600))

        let comp = AVMutableComposition()
        guard let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        do { try v.insertTimeRange(range, of: vt, at: .zero) } catch { return nil }
        if !edit.muted && !edit.asGIF, let at = try? await asset.loadTracks(withMediaType: .audio).first,
           let a = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? a.insertTimeRange(range, of: at, at: .zero)
        }

        // поворот: исходная ориентация + выбранные 90°
        let natural = (try? await vt.load(.naturalSize)) ?? CGSize(width: 1280, height: 720)
        let pt = (try? await vt.load(.preferredTransform)) ?? .identity
        let oriented = CGRect(origin: .zero, size: natural).applying(pt)
        var size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        var t = pt.concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
        switch edit.rotation % 360 {
        case 90:
            t = t.concatenating(CGAffineTransform(rotationAngle: .pi / 2)).concatenating(CGAffineTransform(translationX: size.height, y: 0))
            size = CGSize(width: size.height, height: size.width)
        case 180:
            t = t.concatenating(CGAffineTransform(rotationAngle: .pi)).concatenating(CGAffineTransform(translationX: size.width, y: size.height))
        case 270:
            t = t.concatenating(CGAffineTransform(rotationAngle: -.pi / 2)).concatenating(CGAffineTransform(translationX: 0, y: size.width))
            size = CGSize(width: size.height, height: size.width)
        default: break
        }
        // не больше 720p по короткой стороне — и чётные размеры (так требует кодек)
        let scale = min(1, 720 / max(1, min(size.width, size.height)))
        let render = CGSize(width: (size.width * scale / 2).rounded() * 2, height: (size.height * scale / 2).rounded() * 2)
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: v)
        layer.setTransform(t, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: range.duration)
        instruction.layerInstructions = [layer]
        let video = AVMutableVideoComposition()
        video.renderSize = render
        let fps = (try? await vt.load(.nominalFrameRate)) ?? 30
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(15, min(60, fps.rounded()))))
        video.instructions = [instruction]

        if let out = await run(comp, preset: AVAssetExportPreset1280x720, video: video) { return out }
        if let out = await run(comp, preset: AVAssetExportPresetHighestQuality, video: video) { return out }
        // запасной путь без сборки кадров (без поворота): старые и необычные видео тоже уходят
        if edit.rotation == 0 {
            v.preferredTransform = pt
            if let out = await run(comp, preset: AVAssetExportPresetMediumQuality, video: nil) { return out }
        }
        return nil
    }

    private static func run(_ asset: AVAsset, preset: String, video: AVVideoComposition?) async -> URL? {
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("edit-\(UUID().uuidString).mp4")
        if let video { export.videoComposition = video }
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await export.export()
        if export.status == .completed { return out }
        print("VideoEditExport \(preset):", export.error?.localizedDescription ?? "status \(export.status.rawValue)")
        return nil
    }
}

struct VideoEditorView: View {
    let url: URL
    var startAsGIF = false
    let onDone: (PreparedMedia) -> Void
    let onCancel: () -> Void

    @Environment(\.lang) private var lang
    @State private var edit = VideoEdit()
    @State private var duration: Double = 0
    @State private var frames: [UIImage] = []
    @State private var player: AVPlayer?
    @State private var clock: Any?
    @State private var playhead: Double = 0
    @State private var saving = false
    @State private var failed = false

    private var s: Strings { Strings(lang: lang) }
    private let minLength = 0.5

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                topBar
                ZStack {
                    if let player {
                        PlayerLayerView(player: player, gravity: .resizeAspect)
                            .rotationEffect(.degrees(Double(edit.rotation)))
                            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: edit.rotation)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { togglePlay() }

                timeline
                    .padding(.horizontal, 16)
                Text(timeLabel).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                tools
                if failed {
                    Text(s.t("Не получилось обработать видео", "Couldn't process the video"))
                        .font(.system(size: 13)).foregroundStyle(.red)
                }
            }
            .padding(.bottom, 12)
            if saving {
                Color.black.opacity(0.5).ignoresSafeArea()
                ProgressView(s.t("Готовим видео…", "Preparing video…")).tint(.white).foregroundStyle(.white)
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .onDisappear { stopClock(); player?.pause() }
    }

    private var topBar: some View {
        HStack {
            Button(s.t("Отмена", "Cancel")) { onCancel() }
                .font(.system(size: 17)).foregroundStyle(.white)
            Spacer()
            Button { Task { await save() } } label: {
                Text(s.t("Готово", "Done")).font(.system(size: 17, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 16).frame(height: 34).background(Color.white, in: Capsule())
            }
            .disabled(saving || duration == 0)
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    // MARK: Лента кадров с ручками обрезки

    private var timeline: some View {
        GeometryReader { g in
            let w = g.size.width
            let x0 = duration > 0 ? CGFloat(edit.start / duration) * w : 0
            let x1 = duration > 0 ? CGFloat((edit.end > 0 ? edit.end : duration) / duration) * w : w
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(Array(frames.enumerated()), id: \.offset) { _, img in
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(width: w / CGFloat(max(1, frames.count)), height: 52).clipped()
                    }
                }
                .frame(width: w, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                // затемнение вырезанного
                Rectangle().fill(.black.opacity(0.6)).frame(width: max(0, x0), height: 52)
                Rectangle().fill(.black.opacity(0.6)).frame(width: max(0, w - x1), height: 52).offset(x: x1)
                // рамка выбранного куска
                RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.yellow, lineWidth: 3)
                    .frame(width: max(12, x1 - x0), height: 52).offset(x: x0)
                // текущая позиция
                if duration > 0 {
                    Capsule().fill(.white).frame(width: 3, height: 60)
                        .offset(x: CGFloat(playhead / duration) * w - 1.5)
                        .allowsHitTesting(false)
                }
                handle.offset(x: x0 - 10)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        let t = Double(max(0, min(v.location.x, x1 - 1)) / w) * duration
                        edit.start = min(t, (edit.end > 0 ? edit.end : duration) - minLength)
                        seek(edit.start)
                    }.onEnded { _ in Haptics.select() })
                handle.offset(x: x1 - 10)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        let t = Double(max(x0 + 1, min(v.location.x, w)) / w) * duration
                        edit.end = max(t, edit.start + minLength)
                        seek(edit.end)
                    }.onEnded { _ in Haptics.select(); seek(edit.start) })
            }
        }
        .frame(height: 60)
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.yellow).frame(width: 20, height: 60)
            .overlay(Capsule().fill(.black.opacity(0.5)).frame(width: 3, height: 20))
            .contentShape(Rectangle().inset(by: -10))
    }

    private var timeLabel: String {
        let len = max(0, (edit.end > 0 ? edit.end : duration) - edit.start)
        return mmss(Int(len.rounded())) + (len < duration - 0.05 ? s.t(" из ", " of ") + mmss(Int(duration.rounded())) : "")
    }

    // MARK: Звук, поворот, GIF

    private var tools: some View {
        HStack(spacing: 26) {
            tool(edit.muted || edit.asGIF ? "speaker.slash.fill" : "speaker.wave.2.fill",
                 edit.muted || edit.asGIF ? s.t("Без звука", "Muted") : s.t("Звук", "Sound"), on: edit.muted || edit.asGIF) {
                edit.muted.toggle()
                if !edit.muted { edit.asGIF = false }
                player?.isMuted = edit.muted || edit.asGIF
            }
            tool("rotate.right", s.t("Повернуть", "Rotate"), on: edit.rotation != 0) {
                edit.rotation = (edit.rotation + 90) % 360
            }
            tool("square.stack.3d.forward.dottedline", "GIF", on: edit.asGIF) {
                edit.asGIF.toggle()
                player?.isMuted = edit.muted || edit.asGIF
            }
        }
        .padding(.top, 4)
    }

    private func tool(_ icon: String, _ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.select(); action() } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(on ? Color.yellow.opacity(0.25) : Color.white.opacity(0.12), in: Circle())
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(on ? Color.yellow : Color.white)
        }
        .buttonStyle(PressStyle())
    }

    // MARK: Проигрывание выбранного куска по кругу

    private func load() async {
        let asset = AVURLAsset(url: url)
        duration = (try? await asset.load(.duration).seconds) ?? 0
        edit.end = duration
        edit.asGIF = startAsGIF
        let p = AVPlayer(url: url)
        p.isMuted = startAsGIF
        player = p
        clock = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { t in
            MainActor.assumeIsolated {
                playhead = t.seconds
                let end = edit.end > 0 ? edit.end : duration
                if t.seconds >= end - 0.02 { seek(edit.start); player?.play() }
            }
        }
        p.play()
        frames = await thumbnails(asset, count: 10)
    }

    private func thumbnails(_ asset: AVURLAsset, count: Int) async -> [UIImage] {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 160)
        var out: [UIImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            if let cg = try? await gen.image(at: t).image { out.append(UIImage(cgImage: cg)) }
        }
        return out
    }

    private func seek(_ t: Double) {
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = t
    }

    private func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    private func stopClock() {
        if let clock, let player { player.removeTimeObserver(clock) }
        clock = nil
    }

    private func save() async {
        saving = true
        failed = false
        player?.pause()
        defer { saving = false }
        guard let out = await VideoEditExport.export(url, edit: edit),
              var media = try? await MediaPreparer.prepare(videoFile: out, compress: false) else {
            failed = true
            return
        }
        media.gif = edit.asGIF
        onDone(media)
    }
}
