import Combine
import SwiftUI
import AVFoundation
import ReplayKit

// Движок звонка поверх WebRTC. Пакет подключается в Xcode: File ▸ Add Package Dependencies ▸
// https://github.com/stasel/WebRTC  (продукт WebRTC). Пока пакета нет, приложение собирается
// с заглушкой и звонок честно сообщает, что WebRTC не подключён.

enum RTCEngineError: Error { case unavailable, failed }

#if canImport(WebRTC)
import WebRTC

@MainActor
final class RTCEngine: NSObject, ObservableObject {
    static let isAvailable = true

    @Published private(set) var remoteVideo: RTCVideoTrack?
    @Published private(set) var localVideo: RTCVideoTrack?
    @Published private(set) var usingFront = true
    /// Короткая строка состояния для экрана видеозвонка: камера / ICE / входящее видео
    @Published private(set) var debug = ""
    @Published private(set) var sharing = false

    var onIce: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    private var camNote = ""
    private var iceNote = ""
    private var remoteNote = ""
    private func refreshDebug() { debug = [camNote, iceNote, remoteNote].filter { !$0.isEmpty }.joined(separator: " · ") }

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private var pc: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var capturer: RTCCameraVideoCapturer?
    private var videoSource: RTCVideoSource?
    private var haveRemote = false
    private var pendingIce: [RTCIceCandidate] = []

    // MARK: Подготовка

    func prepare(servers: [IceServer], video: Bool) {
        close()
        let config = RTCConfiguration()
        config.iceServers = servers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.iceCandidatePoolSize = 1                // кандидаты собираются заранее — соединение между сетями быстрее
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)

        configureAudioSession(video: video)

        let audioSource = Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audio = Self.factory.audioTrack(with: audioSource, trackId: "audio0")
        audioTrack = audio
        pc?.add(audio, streamIds: ["s0"])

        if video { startCamera(front: true) }
    }

    private func configureAudioSession(video: Bool) {
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        try? s.setCategory(.playAndRecord, with: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
        try? s.setMode(video ? .videoChat : .voiceChat)
        try? s.setActive(true)
        s.unlockForConfiguration()
    }

    func startCamera(front: Bool) {
        guard let pc else { return }
        if videoSource == nil {
            let source = Self.factory.videoSource()
            videoSource = source
            let track = Self.factory.videoTrack(with: source, trackId: "video0")
            localVideo = track
            pc.add(track, streamIds: ["s0"])
            capturer = RTCCameraVideoCapturer(delegate: source)
        }
        let position: AVCaptureDevice.Position = front ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position })
                ?? RTCCameraVideoCapturer.captureDevices().first else {
            camNote = "камера: нет устройства"; refreshDebug(); return
        }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        func width(_ f: AVCaptureDevice.Format) -> Int32 { CMVideoFormatDescriptionGetDimensions(f.formatDescription).width }
        // ближайший к 960 px по ширине, чтобы и картинка была чёткой, и мобильная сеть справлялась
        guard let format = formats.min(by: { abs(Int(width($0)) - 960) < abs(Int(width($1)) - 960) }),
              let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() else {
            camNote = "камера: нет формата"; refreshDebug(); return
        }
        capturer?.startCapture(with: device, format: format, fps: Int(min(30, fps))) { [weak self] error in
            Task { @MainActor in
                self?.camNote = error == nil ? "камера ✓" : "камера: ошибка"
                self?.refreshDebug()
            }
        }
        usingFront = front
        localVideo?.isEnabled = true
    }

    func flipCamera() { startCamera(front: !usingFront) }

    // MARK: Демонстрация экрана

    /// Кадры экрана приложения идут в ту же видеодорожку, что и камера (ReplayKit, без отдельного расширения)
    nonisolated private static func frameHandler(source: RTCVideoSource, capturer: RTCVideoCapturer)
        -> @Sendable (CMSampleBuffer, RPSampleBufferType, Error?) -> Void {
        return { buffer, type, _ in
            guard type == .video, CMSampleBufferIsValid(buffer), let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
            let ns = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer)) * 1_000_000_000)
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: ns)
            source.capturer(capturer, didCapture: frame)
        }
    }

    /// Формат кадров экрана: та же пропорция, что у телефона (раньше жёстко 9:16, из-за чего края обрезались)
    private static func screenSize(width: CGFloat = 720) -> (Int32, Int32) {
        let b = UIScreen.main.bounds
        let w = b.width > 0 ? b.width : 390, h = b.height > 0 ? b.height : 844
        let height = Int((width * h / w).rounded()) & ~1
        return (Int32(width), Int32(height))
    }

    private var broadcastMode = false

    func startScreenShare() async -> Bool {
        guard let source = videoSource, !sharing else { return false }
        let (w, h) = Self.screenSize()

        // Весь экран и в фоне — через расширение (если оно добавлено в проект); иначе — только экран самого приложения
        if ScreenBroadcast.available {
            await capturer?.stopCapture()
            source.adaptOutputFormat(toWidth: w, height: h, fps: 10)
            let capturer = RTCVideoCapturer(delegate: source)
            let started = ScreenBroadcast.shared.begin(
                onStart: { [weak self] in
                    Task { @MainActor in
                        self?.sharing = true
                        self?.broadcastMode = true
                        self?.localVideo?.isEnabled = true
                        self?.camNote = "экран ✓"
                        self?.refreshDebug()
                    }
                },
                onFrame: { buffer, ns in
                    source.capturer(capturer, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: ns))
                },
                onEnd: { [weak self] in Task { @MainActor in self?.broadcastEnded() } })
            if started { return true }
            startCamera(front: usingFront)
        }

        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else { return false }
        await capturer?.stopCapture()
        source.adaptOutputFormat(toWidth: w, height: h, fps: 15)
        let handler = Self.frameHandler(source: source, capturer: RTCVideoCapturer(delegate: source))
        let ok: Bool = await withCheckedContinuation { c in
            recorder.startCapture(handler: handler, completionHandler: { error in c.resume(returning: error == nil) })
        }
        if ok {
            sharing = true
            localVideo?.isEnabled = true
            camNote = "экран ✓"
        } else {
            startCamera(front: usingFront)      // не вышло — возвращаем камеру
        }
        refreshDebug()
        return ok
    }

    /// Расширение закончило вещание само (кнопка в строке состояния или конец звонка)
    private func broadcastEnded() {
        guard broadcastMode || sharing else { return }
        broadcastMode = false
        sharing = false
        videoSource?.adaptOutputFormat(toWidth: 1280, height: 720, fps: 30)
        startCamera(front: usingFront)
    }

    func stopScreenShare(restoreCamera: Bool = true) {
        if broadcastMode {
            broadcastMode = false
            sharing = false
            ScreenBroadcast.shared.stop()
            videoSource?.adaptOutputFormat(toWidth: 1280, height: 720, fps: 30)
            if restoreCamera { startCamera(front: usingFront) }
            return
        }
        guard sharing else { return }
        sharing = false
        RPScreenRecorder.shared().stopCapture { _ in }
        videoSource?.adaptOutputFormat(toWidth: 1280, height: 720, fps: 30)
        if restoreCamera { startCamera(front: usingFront) }
    }

    func setVideoEnabled(_ on: Bool) {
        if on {
            if videoSource == nil { startCamera(front: usingFront) } else { localVideo?.isEnabled = true }
        } else {
            localVideo?.isEnabled = false
        }
    }

    func setMuted(_ muted: Bool) { audioTrack?.isEnabled = !muted }

    func setSpeaker(_ on: Bool) {
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        try? s.overrideOutputAudioPort(on ? .speaker : .none)
        s.unlockForConfiguration()
    }

    // MARK: SDP

    private let sdpConstraints = RTCMediaConstraints(
        mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"], optionalConstraints: nil)

    func makeOffer() async throws -> String {
        guard let pc else { throw RTCEngineError.failed }
        let sdp: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
            pc.offer(for: sdpConstraints) { sdp, error in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: error ?? RTCEngineError.failed) }
            }
        }
        try await setLocal(sdp)
        return sdp.sdp
    }

    func makeAnswer(offer: String) async throws -> String {
        guard let pc else { throw RTCEngineError.failed }
        try await setRemote(RTCSessionDescription(type: .offer, sdp: offer))
        let sdp: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
            pc.answer(for: sdpConstraints) { sdp, error in
                if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: error ?? RTCEngineError.failed) }
            }
        }
        try await setLocal(sdp)
        return sdp.sdp
    }

    func acceptAnswer(_ sdp: String) async throws {
        try await setRemote(RTCSessionDescription(type: .answer, sdp: sdp))
    }

    private func setLocal(_ sdp: RTCSessionDescription) async throws {
        guard let pc else { throw RTCEngineError.failed }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in if let error { c.resume(throwing: error) } else { c.resume() } }
        }
    }

    private func setRemote(_ sdp: RTCSessionDescription) async throws {
        guard let pc else { throw RTCEngineError.failed }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in if let error { c.resume(throwing: error) } else { c.resume() } }
        }
        haveRemote = true
        refreshRemote()
        for candidate in pendingIce { pc.add(candidate) { _ in } }
        pendingIce = []
    }

    func addRemoteIce(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sdp = obj["candidate"] as? String else { return }
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(obj["sdpMLineIndex"] as? Int ?? 0),
                                        sdpMid: obj["sdpMid"] as? String)
        if haveRemote, let pc { pc.add(candidate) { _ in } } else { pendingIce.append(candidate) }
    }

    /// Берёт входящую видеодорожку прямо из соединения — надёжнее, чем ждать колбэк
    func refreshRemote() {
        guard let pc else { return }
        if let track = pc.transceivers.compactMap({ $0.receiver.track as? RTCVideoTrack }).first, remoteVideo !== track {
            track.isEnabled = true
            remoteVideo = track
            remoteNote = "видео собеседника ✓"
            refreshDebug()
        }
    }

    func close() {
        if broadcastMode { broadcastMode = false; ScreenBroadcast.shared.stop() }
        if sharing { sharing = false; RPScreenRecorder.shared().stopCapture { _ in } }
        let oldCapturer = capturer
        Task { await oldCapturer?.stopCapture() }
        capturer = nil
        videoSource = nil
        localVideo = nil
        remoteVideo = nil
        camNote = ""; iceNote = ""; remoteNote = ""; debug = ""
        audioTrack = nil
        pc?.close()
        pc = nil
        haveRemote = false
        pendingIce = []
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        try? s.setActive(false)
        s.unlockForConfiguration()
    }
}

extension RTCEngine: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        Task { @MainActor in self.refreshRemote() }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        if let track = transceiver.receiver.track as? RTCVideoTrack {
            Task { @MainActor in track.isEnabled = true; self.remoteVideo = track; self.remoteNote = "видео собеседника ✓"; self.refreshDebug() }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let obj: [String: Any] = ["candidate": candidate.sdp, "sdpMLineIndex": Int(candidate.sdpMLineIndex),
                                  "sdpMid": candidate.sdpMid ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let text = String(data: data, encoding: .utf8) else { return }
        Task { @MainActor in self.onIce?(text) }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            switch newState {
            case .connected, .completed: self.iceNote = "связь ✓"; self.refreshRemote(); self.onConnected?()
            case .failed, .closed: self.iceNote = "связь: обрыв"; self.onDisconnected?()
            case .checking: self.iceNote = "связь…"
            case .disconnected: self.iceNote = "связь: нестабильна"
            default: break
            }
            self.refreshDebug()
        }
    }
}

/// Видео из WebRTC в SwiftUI. Кадры экрана (узкие, как у телефона) показываются целиком, без обрезки; камера — на весь экран
struct RTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack?
    var mirror = false
    var fill = true

    final class Coordinator: NSObject, RTCVideoViewDelegate {
        var current: RTCVideoTrack?
        var fill = true
        func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            let aspect = size.height > 0 ? size.width / size.height : 1
            let screenLike = aspect < 0.53 || aspect > 1.9          // камера: 9:16, 3:4, 4:3, 16:9 — экран телефона уже
            DispatchQueue.main.async { (videoView as? RTCMTLVideoView)?.videoContentMode = (self.fill && !screenLike) ? .scaleAspectFill : .scaleAspectFit }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView()
        v.videoContentMode = fill ? .scaleAspectFill : .scaleAspectFit
        v.backgroundColor = .black
        v.delegate = context.coordinator
        context.coordinator.fill = fill
        return v
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        if context.coordinator.current !== track {
            if let old = context.coordinator.current { old.remove(view) }
            track?.add(view)
            context.coordinator.current = track
        }
        view.transform = mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.current?.remove(view)
    }
}

#else

// MARK: - Заглушка, пока пакет WebRTC не добавлен

@MainActor
final class RTCEngine: NSObject, ObservableObject {
    static let isAvailable = false
    @Published private(set) var remoteVideo: Bool? = nil
    @Published private(set) var localVideo: Bool? = nil
    @Published private(set) var usingFront = true
    @Published private(set) var debug = ""
    @Published private(set) var sharing = false
    func startScreenShare() async -> Bool { false }
    func stopScreenShare(restoreCamera: Bool = true) {}
    var onIce: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    func prepare(servers: [IceServer], video: Bool) {}
    func startCamera(front: Bool) {}
    func flipCamera() {}
    func setVideoEnabled(_ on: Bool) {}
    func setMuted(_ muted: Bool) {}
    func setSpeaker(_ on: Bool) {}
    func makeOffer() async throws -> String { throw RTCEngineError.unavailable }
    func makeAnswer(offer: String) async throws -> String { throw RTCEngineError.unavailable }
    func acceptAnswer(_ sdp: String) async throws { throw RTCEngineError.unavailable }
    func addRemoteIce(_ json: String) {}
    func close() {}
}

struct RTCVideoView: View {
    let track: Bool?
    var mirror = false
    var fill = true
    var body: some View { Color.black }
}
#endif
