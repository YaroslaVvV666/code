import SwiftUI
import Combine
import AVFoundation
import UIKit

// MARK: - Дуэты (как в TikTok)
// Слева — чужой шортс, справа — твоя фронтальная камера. Нажимаешь «запись» — оригинал играет с начала, ты снимаешь
// себя рядом. Потом оба видео склеиваются в одно 9:16 (две половины), звук — оригинала и твой микрофон вместе.
// Публикуется как шортс с пометкой «Дуэт с @автор» — нажатие ведёт к оригиналу.

@MainActor
final class DuetCamera: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "orbita.duet")
    @Published var recording = false
    @Published var denied = false
    private var finish: ((URL?) -> Void)?

    func start() {
        Task {
            let cam = await AVCaptureDevice.requestAccess(for: .video)
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            guard cam else { denied = true; return }
            configure(withMic: mic)
        }
    }

    private func configure(withMic: Bool) {
        // звук настраиваем сами: оригинал играет в динамик, а микрофон его не слышит (эхоподавление, как в видеозвонке) —
        // в дуэте нет «двойного» звука оригинала и гула
        session.automaticallyConfiguresApplicationAudioSession = false
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        AudioSessionGate.willActivate()
        try? audio.setActive(true)
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .hd1280x720     // чётко, не мыльно
        if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
           let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) { session.addInput(input) }
        if withMic, let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        if let c = output.connection(with: .video) {
            // сразу вертикально и зеркально: тогда склейка не возится с поворотами
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = true }
        }
        session.commitConfiguration()
        queue.async { [session] in session.startRunning() }
    }

    func record(_ done: @escaping (URL?) -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("duet-\(UUID().uuidString).mov")
        finish = done
        output.startRecording(to: url, recordingDelegate: self)
        recording = true
    }

    func stop() { if output.isRecording { output.stopRecording() } }

    func shutdown() {
        stop()
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in
            self.recording = false
            self.finish?(FileManager.default.fileExists(atPath: url.path) ? url : nil)
            self.finish = nil
        }
    }
}

/// Превью фронтальной камеры
private struct DuetPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class V: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> V {
        let v = V()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ v: V, context: Context) {}
}

/// Склейка двух видео в одно 9:16 1080×1920: слева оригинал, справа ты — каждое ЦЕЛИКОМ (без обрезки),
/// вписано в свою половину 540×960 по центру по высоте, вокруг — чёрное (как дуэт в TikTok)
enum DuetComposer {
    static func compose(original: URL, mine: URL) async throws -> URL {
        let a = AVURLAsset(url: original), b = AVURLAsset(url: mine)
        let comp = AVMutableComposition()
        guard let va = try await a.loadTracks(withMediaType: .video).first,
              let vb = try await b.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let durA = try await a.load(.duration), durB = try await b.load(.duration)
        let duration = CMTimeMinimum(durA, durB)
        let range = CMTimeRange(start: .zero, duration: duration)
        let ta = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let tb = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try ta?.insertTimeRange(range, of: va, at: .zero)
        try tb?.insertTimeRange(range, of: vb, at: .zero)
        // звук: оригинал + твой микрофон
        for asset in [a, b] {
            if let audio = try await asset.loadTracks(withMediaType: .audio).first,
               let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? t.insertTimeRange(range, of: audio, at: .zero)
            }
        }
        let render = CGSize(width: 1080, height: 1920)
        let box = CGSize(width: render.width / 2, height: render.width / 2 * 16 / 9)       // 540×960 — половина под 9:16
        let boxY = (render.height - box.height) / 2
        func layer(_ track: AVCompositionTrack?, source: AVAssetTrack, x: CGFloat) async throws -> AVMutableVideoCompositionLayerInstruction {
            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: track!)
            let size = try await source.load(.naturalSize)
            let pt = try await source.load(.preferredTransform)
            // учитываем поворот исходника
            let oriented = CGRect(origin: .zero, size: size).applying(pt)
            let w = abs(oriented.width), h = abs(oriented.height)
            // вписать целиком (ничего не срезаем); горизонтальное видео — по центру с полосами
            let scale = min(box.width / w, box.height / h)
            let dx = x + (box.width - w * scale) / 2
            let dy = boxY + (box.height - h * scale) / 2
            let t = pt.concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: dx, y: dy))
            li.setTransform(t, at: .zero)
            return li
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = range
        instruction.layerInstructions = [try await layer(ta, source: va, x: 0), try await layer(tb, source: vb, x: half.width)]
        instruction.backgroundColor = UIColor.black.cgColor
        let video = AVMutableVideoComposition()
        video.renderSize = render
        video.frameDuration = CMTime(value: 1, timescale: 30)
        video.instructions = [instruction]

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("duet-out-\(UUID().uuidString).mp4")
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        export.videoComposition = video
        // громкость: оригинал чуть тише, голос — полностью (как в TikTok), без перегруза
        let mix = AVMutableAudioMix()
        mix.inputParameters = comp.tracks(withMediaType: .audio).enumerated().map { i, track in
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(i == 0 ? 0.8 : 1.0, at: .zero)
            return p
        }
        export.audioMix = mix
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await export.export()
        guard export.status == .completed else { throw export.error ?? CocoaError(.fileWriteUnknown) }
        return out
    }
}

struct DuetRecorderView: View {
    let original: Post
    var onPosted: () async -> Void = {}

    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @StateObject private var camera = DuetCamera()
    @State private var player: AVPlayer?
    @State private var localOriginal: URL?
    @State private var progress: Double = 0
    @State private var phase: Phase = .loading
    @State private var result: URL?
    @State private var caption = ""
    @State private var errorText: String?
    @State private var timeObserver: Any?

    private enum Phase { case loading, ready, recording, composing, review, posting }
    private var s: Strings { Strings(lang: lang) }
    private var video: MediaItem? { original.media.first { $0.kind == .video } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if phase == .review || phase == .posting, let result {
                review(result)
            } else {
                // как будет в готовом дуэте: две половины 9:16 рядом, каждое видео целиком
                GeometryReader { geo in
                    let w = geo.size.width / 2 - 1
                    HStack(spacing: 2) {
                        ZStack {
                            if let player { PlayerLayerView(player: player, gravity: .resizeAspect) }
                            else { ProgressView().tint(.white) }
                        }
                        .frame(width: w, height: w * 16 / 9).clipped()
                        ZStack {
                            DuetPreview(session: camera.session)
                            if camera.denied {
                                Text(s.cameraDenied).font(.system(size: 13)).foregroundStyle(.white).multilineTextAlignment(.center).padding()
                            }
                        }
                        .frame(width: w, height: w * 16 / 9).clipped()
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .ignoresSafeArea()
                controls
            }
        }
        .preferredColorScheme(.dark)
        .task { await prepare() }
        .onDisappear { cleanup() }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 42, height: 42).glassCircle()
                }
                .buttonStyle(.plain)
                Spacer()
                Label(s.t("Дуэт с ", "Duet with ") + (original.author.username.map { "@" + $0 } ?? original.author.name), systemImage: "rectangle.split.2x1")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 34).glass(Capsule())
                Spacer()
                Color.clear.frame(width: 42, height: 42)
            }
            .padding(.horizontal, 16).padding(.top, 8)
            // полоса записи
            GeometryReader { g in
                Capsule().fill(.white.opacity(0.25))
                    .overlay(alignment: .leading) { Capsule().fill(Color.red).frame(width: g.size.width * progress) }
            }
            .frame(height: 4).padding(.horizontal, 16)
            Spacer()
            if let errorText {
                Text(errorText).font(.system(size: 13)).foregroundStyle(.white)
                    .padding(10).background(.black.opacity(0.6), in: Capsule())
            }
            if phase == .composing {
                HStack(spacing: 8) { ProgressView().tint(.white); Text(s.t("Склеиваем дуэт…", "Making your duet…")).foregroundStyle(.white) }
                    .padding(.horizontal, 16).frame(height: 44).glass(Capsule())
                    .padding(.bottom, 40)
            } else {
                Button(action: toggleRecord) {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 5).frame(width: 82, height: 82)
                        RoundedRectangle(cornerRadius: phase == .recording ? 8 : 34, style: .continuous)
                            .fill(Color.red).frame(width: phase == .recording ? 34 : 68, height: phase == .recording ? 34 : 68)
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: phase == .recording)
                }
                .buttonStyle(.plain)
                .disabled(phase == .loading || camera.denied)
                .opacity(phase == .loading ? 0.4 : 1)
                .padding(.bottom, 40)
            }
        }
    }

    private func review(_ url: URL) -> some View {
        VStack(spacing: 14) {
            HStack {
                Button { result = nil; phase = .ready; player?.seek(to: .zero) } label: {
                    Label(s.t("Переснять", "Retake"), systemImage: "arrow.counterclockwise")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 8)
            LoopingVideo(url: url)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 40)
            TextField(s.t("Подпись к дуэту", "Duet caption"), text: $caption)
                .padding(.horizontal, 14).frame(height: 46)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
            if let errorText { Text(errorText).font(.system(size: 13)).foregroundStyle(.red) }
            Button(action: publish) {
                HStack {
                    if phase == .posting { ProgressView().tint(.white) }
                    Text(s.t("Опубликовать дуэт", "Post duet")).font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 52)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressStyle())
            .disabled(phase == .posting)
            .padding(.horizontal, 16).padding(.bottom, 20)
        }
    }

    private func prepare() async {
        // всё постороннее — на паузу: музыка, голосовые, кружки, видео в ленте
        session.player.stop()
        VoicePlayer.shared.pause()
        CircleFocus.shared.stop()
        MediaSilence.pauseAll()
        NotificationCenter.default.post(name: .orbitaVideoWithSound, object: nil)
        camera.start()
        guard let v = video, let url = ServerConfig.mediaURL(v.id) else { errorText = s.mediaFailed; return }
        // оригинал нужен файлом — для склейки
        do {
            let (tmp, _) = try await URLSession.shared.download(from: url)
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("duet-orig-\(UUID().uuidString).mp4")
            try FileManager.default.moveItem(at: tmp, to: local)
            localOriginal = local
            let p = AVPlayer(url: local)
            p.isMuted = false
            p.volume = 1
            player = p
            phase = .ready
        } catch {
            errorText = s.mediaFailed
        }
    }

    private func toggleRecord() {
        if phase == .recording { finishRecording(); return }
        guard phase == .ready, let player else { return }
        Haptics.impact(.medium)
        errorText = nil
        player.seek(to: .zero)
        player.play()
        phase = .recording
        let total = video?.duration ?? 60
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { t in
            Task { @MainActor in
                progress = min(1, t.seconds / max(1, total))
                if t.seconds >= total - 0.05 { finishRecording() }     // оригинал кончился — дуэт тоже
            }
        }
        camera.record { url in
            Task { @MainActor in
                guard let url, let original = localOriginal else { phase = .ready; errorText = s.mediaFailed; return }
                phase = .composing
                do {
                    result = try await DuetComposer.compose(original: original, mine: url)
                    try? FileManager.default.removeItem(at: url)
                    phase = .review
                } catch {
                    phase = .ready
                    errorText = s.t("Не получилось склеить видео", "Couldn't build the duet")
                }
            }
        }
    }

    private func finishRecording() {
        guard phase == .recording else { return }
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        camera.stop()
        Haptics.impact(.light)
    }

    private func publish() {
        guard let result else { return }
        phase = .posting
        errorText = nil
        Task { @MainActor in
            do {
                let prepared = try await MediaPreparer.prepare(videoFile: result)
                let item = try await session.feedRepo.uploadMedia(prepared)
                _ = try await session.extras.createReel(text: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                                                        media: [item], duetOf: original.id)
                Haptics.notify(.success)
                await onPosted()
                dismiss()
            } catch {
                phase = .review
                errorText = s.api((error as? APIError) ?? .offline)
            }
        }
    }

    private func cleanup() {
        camera.shutdown()
        player?.pause()
        // вернуть обычный звук приложения (без микрофона)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        for u in [localOriginal, result] { if let u { try? FileManager.default.removeItem(at: u) } }
    }
}

/// Готовый дуэт по кругу (для предпросмотра перед публикацией)
private struct LoopingVideo: View {
    let url: URL
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        ZStack {
            Color.black
            if let player { PlayerLayerView(player: player, gravity: .resizeAspect) }
        }
        .onAppear {
            let q = AVQueuePlayer()
            looper = AVPlayerLooper(player: q, templateItem: AVPlayerItem(url: url))
            player = q
            q.play()
        }
        .onDisappear { player?.pause() }
    }
}
