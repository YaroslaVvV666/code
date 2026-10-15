import SwiftUI
import AVFoundation
import Combine
import UIKit

// MARK: - Запись голосового

@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    /// Громкость и «хвост» уровней для анимации — намеренно не @Published: их читают лёгкие TimelineView,
    /// а строка ввода не перерисовывается 20 раз в секунду
    private(set) var level: Float = 0                         // 0...1
    private(set) var recent: [Float] = []                     // последние ~60 отсчётов для бегущей волны
    private(set) var startedAt: Date?
    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var samples: [Float] = []
    private var url: URL?
    private var tick = 0
    nonisolated static let maxDuration: TimeInterval = 300

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    func start() async -> Bool {
        guard await Self.requestPermission() else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            AudioSessionGate.willActivate()
            try session.setActive(true)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let recorder = try AVAudioRecorder(url: file, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else { return false }
            self.recorder = recorder
            url = file
            samples = []
            recent = []
            startedAt = Date()
            isRecording = true
            tick = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let r = self.recorder else { return }
                    r.updateMeters()
                    let power = r.averagePower(forChannel: 0)                   // дБ: -160...0
                    let linear = pow(10, power / 20)
                    self.level = min(1, sqrt(linear) * 1.5)
                    self.recent.append(self.level)
                    if self.recent.count > 60 { self.recent.removeFirst(self.recent.count - 60) }
                    self.tick += 1
                    if self.tick % 2 == 0 { self.samples.append(self.level) }       // 10 отсчётов в секунду
                    if r.currentTime >= Self.maxDuration { self.timer?.invalidate() }
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Останавливает запись. Слишком короткая (< 1 с) отбрасывается.
    func finish() -> (url: URL, duration: Double, waveform: [Int])? {
        guard let recorder, let url else { return nil }
        let duration = recorder.currentTime
        stopEngine()
        guard duration >= 1 else { try? FileManager.default.removeItem(at: url); return nil }
        return (url, duration, Self.waveform(from: samples))
    }

    func cancel() {
        let file = url
        stopEngine()
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private func stopEngine() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        level = 0
        recent = []
        startedAt = nil
        // деактивация сессии на главном потоке может подвесить интерфейс — делаем в фоне
        AudioSessionGate.deactivate()
    }

    /// Сжимает запись до 40 столбиков 0...31 (как рисует Telegram)
    static func waveform(from samples: [Float], buckets: Int = 40) -> [Int] {
        guard !samples.isEmpty else { return Array(repeating: 2, count: buckets) }
        var out: [Int] = []
        for i in 0..<buckets {
            let lo = i * samples.count / buckets
            let hi = max(lo + 1, (i + 1) * samples.count / buckets)
            let slice = samples[lo..<min(hi, samples.count)]
            let peak = slice.max() ?? 0
            out.append(max(2, min(31, Int(peak * 31))))
        }
        return out
    }
}

// MARK: - Воспроизведение голосовых

@MainActor
final class VoicePlayer: ObservableObject {
    static let shared = VoicePlayer()

    @Published private(set) var currentID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var rate: Float = {
        let v = UserDefaults.standard.double(forKey: "voice_rate")
        return v == 1.5 || v == 2 ? Float(v) : 1
    }()

    private var player: AVPlayer?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var total: Double = 1

    func isCurrent(_ id: String) -> Bool { currentID == id }

    /// Музыкальный плеер гасится, когда начинается голосовое
    var onStart: (() -> Void)?

    func resume() { player?.rate = rate; isPlaying = player != nil }
    func pause() { player?.pause(); isPlaying = false }
    func seek(toFraction f: Double) {
        let s = max(0, min(1, f)) * total
        progress = max(0, min(1, f))
        player?.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    var duration: Double { total }

    func toggle(id: String, mediaID: String, duration: Double) {
        if currentID == id, let player {
            if isPlaying { player.pause(); isPlaying = false } else { player.rate = rate; isPlaying = true }
            return
        }
        stop()
        onStart?()
        guard let url = ServerConfig.mediaURL(mediaID) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        AudioSessionGate.willActivate()
        try? AVAudioSession.sharedInstance().setActive(true)
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p
        currentID = id
        total = max(duration, 0.1)
        progress = 0
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.progress = min(1, time.seconds / self.total)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        p.rate = rate
        isPlaying = true
    }

    /// Скорость 1× → 1.5× → 2× (как в Telegram)
    func cycleRate() {
        rate = rate == 1 ? 1.5 : (rate == 1.5 ? 2 : 1)
        UserDefaults.standard.set(Double(rate), forKey: "voice_rate")
        if isPlaying { player?.rate = rate }
    }

    func stop() {
        if let observer, let player { player.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        observer = nil
        endObserver = nil
        player?.pause()
        player = nil
        currentID = nil
        isPlaying = false
        progress = 0
    }
}

// MARK: - Запись «кружка» (видеосообщения)

@MainActor
final class CircleRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    @Published private(set) var isRecording = false
    @Published private(set) var ready = false
    @Published private(set) var isFront = true
    /// Что пошло не так при подготовке камеры — показываем человеку, а не молчим
    private(set) var failure: String?
    /// Код последней ошибки записи (для сообщения человеку и отладки)
    private(set) var lastErrorCode: Int?

    /// Момент, когда AVFoundation реально начала писать (для счётчика с долями секунды)
    private(set) var startedAt: Date?
    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "orbita.circle.session")
    private var requestedAt: Date?
    private var observers: [NSObjectProtocol] = []
    private var finishing: CheckedContinuation<URL?, Never>?
    nonisolated static let maxDuration: TimeInterval = 60

    /// Разрешения и подготовка фронтальной камеры
    func prepare() async -> Bool {
        failure = nil
        let video = await AVCaptureDevice.requestAccess(for: .video)
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        guard video, audio else { failure = "denied"; return false }
        configureAudio()
        if ready, session.isRunning { return true }
        let session = session, output = output
        let ok: Bool = await withCheckedContinuation { continuation in
            queue.async {
                // настройка делается один раз; повторный запуск лишь включает сессию заново
                if session.inputs.isEmpty {
                    session.beginConfiguration()
                    session.automaticallyConfiguresApplicationAudioSession = false      // звук настраиваем сами (см. configureAudio)
                    session.sessionPreset = .high
                    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                            ?? AVCaptureDevice.default(for: .video),
                          let cameraInput = try? AVCaptureDeviceInput(device: camera), session.canAddInput(cameraInput) else {
                        session.commitConfiguration()
                        continuation.resume(returning: false)
                        return
                    }
                    session.addInput(cameraInput)
                    if let mic = AVCaptureDevice.default(for: .audio), let micInput = try? AVCaptureDeviceInput(device: mic),
                       session.canAddInput(micInput) {
                        session.addInput(micInput)
                    }
                    if session.canAddOutput(output) { session.addOutput(output) }
                    output.maxRecordedDuration = CMTime(seconds: CircleRecorder.maxDuration, preferredTimescale: 600)
                    session.commitConfiguration()
                }
                if let connection = output.connection(with: .video) {
                    if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                    if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = true }
                }
                if !session.isRunning { session.startRunning() }
                continuation.resume(returning: session.isRunning)
            }
        }
        ready = ok
        if !ok { failure = "camera" }
        else { observeSession() }
        return ok
    }

    /// Категория «только воспроизведение» (после голосового или музыки) оставляет микрофон без данных —
    /// из-за этого запись заканчивалась ошибкой -11805 «данные не получены». Возвращаем запись перед каждым стартом.
    private func configureAudio() {
        let av = AVAudioSession.sharedInstance()
        try? av.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
        AudioSessionGate.willActivate()
        try? av.setActive(true)
    }

    /// Если система остановила сессию (звонок, другая программа) — запускаем заново
    private func observeSession() {
        guard observers.isEmpty else { return }
        let session = session, queue = queue
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { _ in
            queue.async { if !session.isRunning { session.startRunning() } }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { _ in
            queue.async { if !session.isRunning { session.startRunning() } }
        })
    }

    private var autoFinished: URL?
    private var startRequested = false          // запись запрошена, но AVFoundation могла ещё не начать
    private var stopWhenStarted = false

    /// Переключает фронтальную и основную камеру (можно и во время записи)
    func flipCamera() {
        let session = session, output = output
        let wantFront = !isFront
        queue.async { [weak self] in
            session.beginConfiguration()
            if let old = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) }) {
                session.removeInput(old)
            }
            let position: AVCaptureDevice.Position = wantFront ? .front : .back
            if let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
               let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) {
                session.addInput(input)
            }
            if let connection = output.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = wantFront
                }
            }
            session.commitConfiguration()
            Task { @MainActor in self?.isFront = wantFront }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        Task { @MainActor in
            self.startedAt = Date()
            if self.stopWhenStarted { self.stopWhenStarted = false; self.scheduleStop() }
        }
    }

    /// Первые кадры и звук должны успеть записаться — иначе файл пустой (-11805). Ждём минимум 0,7 с от реального старта.
    private func scheduleStop() {
        let wait = max(0, 0.7 - (startedAt.map { Date().timeIntervalSince($0) } ?? 0))
        let output = output
        if wait <= 0.01 { output.stopRecording(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { output.stopRecording() }
    }

    func startRecording() {
        guard ready, !output.isRecording, !startRequested else { return }
        autoFinished = nil
        startRequested = true
        stopWhenStarted = false
        startedAt = nil
        requestedAt = Date()
        configureAudio()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("circle-\(UUID().uuidString).mov")
        output.startRecording(to: file, recordingDelegate: self)
        isRecording = true
    }

    /// Останавливает запись и возвращает файл (nil — не получилось)
    func stopRecording() async -> URL? {
        guard output.isRecording || startRequested else {
            // лимит времени уже остановил запись сам — отдаём готовый файл
            defer { autoFinished = nil }
            return autoFinished
        }
        return await withCheckedContinuation { continuation in
            finishing = continuation
            // если нажали «стоп», пока камера ещё стартует, — останавливаем после старта и минимального куска записи
            if output.isRecording, startedAt != nil { scheduleStop() } else { stopWhenStarted = true }
        }
    }

    func shutdown() {
        if output.isRecording { output.stopRecording() }
        startedAt = nil
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
        ready = false
        isRecording = false
        startRequested = false
        stopWhenStarted = false
        isFront = true
        // следующая запись снова начнётся с фронтальной камеры
        queue.async {
            if let old = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) }),
               old.device.position != .front {
                session.beginConfiguration()
                session.removeInput(old)
                if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                   let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) { session.addInput(input) }
                session.commitConfiguration()
            }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        // при достижении лимита времени AVFoundation сообщает «ошибку», но файл при этом цел
        let nsError = error as NSError?
        // файл годится, если он на месте и не пустой — даже когда AVFoundation сообщила об ошибке при остановке
        let size = (try? FileManager.default.attributesOfItem(atPath: outputFileURL.path)[.size] as? Int) ?? 0
        let usable = error == nil || (nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true || size > 4096
        let code = nsError?.code
        Task { @MainActor in
            self.lastErrorCode = usable ? nil : code
            self.isRecording = false
            self.startRequested = false
            self.stopWhenStarted = false
            if let finishing = self.finishing {
                finishing.resume(returning: usable ? outputFileURL : nil)
                self.finishing = nil
            } else if usable {
                self.autoFinished = outputFileURL
            }
        }
    }

    /// Квадратная обложка и длительность готового ролика
    static func thumbnail(for url: URL) async -> (data: Data, duration: Double) {
        let asset = AVURLAsset(url: url)
        let duration = ((try? await asset.load(.duration))?.seconds) ?? 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        var data = Data()
        if let result = try? await generator.image(at: .zero) {
            let image = UIImage(cgImage: result.image)
            let side = min(image.size.width, image.size.height)
            let rect = CGRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side)
            if let cropped = image.cgImage?.cropping(to: CGRect(x: rect.origin.x * image.scale, y: rect.origin.y * image.scale,
                                                                width: rect.width * image.scale, height: rect.height * image.scale)) {
                data = UIImage(cgImage: cropped).jpegData(compressionQuality: 0.8) ?? Data()
            } else {
                data = image.jpegData(compressionQuality: 0.8) ?? Data()
            }
        }
        return (data, duration.isFinite ? duration : 0)
    }
}

/// Живое изображение с камеры
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/// Видео в круге/прямоугольнике (воспроизведение кружков)
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer.videoGravity = gravity
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}

// MARK: - Кнопка «нажми / удерживай» (микрофон ↔ камера)

struct HoldOverlay: UIViewRepresentable {
    var onTap: () -> Void
    var onBegin: () -> Void
    var onMove: (CGSize) -> Void
    var onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let long = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.long(_:)))
        long.minimumPressDuration = 0.25
        long.allowableMovement = .greatestFiniteMagnitude
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        view.addGestureRecognizer(long)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: HoldOverlay?
        private var origin: CGPoint = .zero
        private var suppressTap = false

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard !suppressTap else { return }
            parent?.onTap()
        }

        @objc func long(_ g: UILongPressGestureRecognizer) {
            let point = g.location(in: g.view?.window)
            switch g.state {
            case .began:
                suppressTap = true
                origin = point
                parent?.onBegin()
            case .changed:
                parent?.onMove(CGSize(width: point.x - origin.x, height: point.y - origin.y))
            case .ended, .cancelled, .failed:
                parent?.onEnd()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.suppressTap = false }
            default:
                break
            }
        }
    }
}


/// Деактивация аудиосессии в фоне (на главном потоке она может подвесить интерфейс).
/// Если за это время кто-то снова включил сессию — отложенное выключение отменяется.
enum AudioSessionGate {
    private static let queue = DispatchQueue(label: "orbita.audiosession", qos: .utility)
    private static let lock = NSLock()
    private static var generation = 0

    private static func current() -> Int { lock.lock(); defer { lock.unlock() }; return generation }

    static func willActivate() {
        lock.lock(); generation += 1; lock.unlock()
    }

    static func deactivate() {
        let g = current()
        queue.async {
            guard g == current() else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
