import SwiftUI
import Combine
import AVFoundation
import UIKit

/// Живая камера в меню скрепки: первая плитка показывает, что видит камера; нажатие — полный экран с зумом и затвором.
final class AttachCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    /// Одна сессия на всё приложение: настраивается заранее (при открытии чата), поэтому камера в скрепке включается мгновенно
    static let shared = AttachCamera()

    let session = AVCaptureSession()
    @Published var ready = false
    @Published var denied = false
    @Published var zoom: CGFloat = 1
    @Published var position: AVCaptureDevice.Position = .back

    private let output = AVCapturePhotoOutput()
    private let movie = AVCaptureMovieFileOutput()
    @Published var recording = false
    private var onVideo: ((URL) -> Void)?
    private let queue = DispatchQueue(label: "orbita.attachcamera")
    private var device: AVCaptureDevice?
    private var configured = false
    private var onPhoto: ((Data) -> Void)?

    /// Подготовить камеру заранее (без запуска): подключение устройства — самая долгая часть
    func prewarm() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        queue.async {
            if !self.configured { self.configure(self.position) }
        }
    }

    private var stopWork: DispatchWorkItem?

    /// Освободить камеру сразу: перед системной камерой сессия плитки не должна её занимать
    func stopNow() {
        stopWork?.cancel(); stopWork = nil
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
        ready = false
    }

    /// Запустить камеру заранее — если доступ уже выдан (на нажатие скрепки: к моменту, когда меню выехало, картинка уже идёт)
    func warmStart() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        start()
    }

    func start() {
        stopWork?.cancel()
        stopWork = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? self.run() : (self.denied = true) }
            }
        default: denied = true
        }
    }

    private func run() {
        if configured, session.isRunning { ready = true }          // уже идёт — плитка сразу живая
        queue.async {
            if !self.configured { self.configure(self.position) }
            if self.configured, !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.ready = self.configured }
        }
    }

    /// Не гасим сразу: закрыли меню и открыли снова — камера уже работает, без задержки запуска (останавливается через 30 секунд)
    func stop() {
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.queue.async { if let s = self?.session, s.isRunning { s.stopRunning() } }
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func configure(_ pos: AVCaptureDevice.Position) {
        session.beginConfiguration()
        session.sessionPreset = .high
        session.inputs.forEach { session.removeInput($0) }
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos),
              let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) else {
            session.commitConfiguration(); return
        }
        session.addInput(input)
        if !session.outputs.contains(output), session.canAddOutput(output) {
            session.addOutput(output)
            output.maxPhotoQualityPrioritization = .speed
        }
        if !session.outputs.contains(movie), session.canAddOutput(movie) { session.addOutput(movie) }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let mic = AVCaptureDevice.default(for: .audio), let mi = try? AVCaptureDeviceInput(device: mic), session.canAddInput(mi) {
            session.addInput(mi)
        }
        session.commitConfiguration()
        device = cam
        configured = true
    }

    func flip() {
        let next: AVCaptureDevice.Position = position == .back ? .front : .back
        position = next
        zoom = 1
        queue.async {
            self.configure(next)
        }
    }

    var maxZoom: CGFloat { min(device?.activeFormat.videoMaxZoomFactor ?? 1, 10) }

    func setZoom(_ z: CGFloat) {
        let value = Swift.max(1, Swift.min(z, maxZoom))
        zoom = value
        queue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            d.videoZoomFactor = value
            d.unlockForConfiguration()
        }
    }

    func capture(_ done: @escaping (Data) -> Void) {
        onPhoto = done
        queue.async {
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .speed
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    /// Запись видео своей камерой: тот же сеанс, что показывает плитку, поэтому старт мгновенный
    func startRecording(_ done: @escaping (URL) -> Void) {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.queue.async { self.configure(self.position) }
            }
        }
        onVideo = done
        queue.async {
            guard !self.movie.isRecording else { return }
            if let c = self.movie.connection(with: .video) {
                if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
                if c.isVideoMirroringSupported { c.isVideoMirrored = self.position == .front }
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cam-\(UUID().uuidString).mov")
            self.movie.startRecording(to: url, recordingDelegate: self)
            DispatchQueue.main.async { self.recording = true }
        }
    }

    func stopRecording() {
        queue.async { if self.movie.isRecording { self.movie.stopRecording() } }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.recording = false
            let ok = (error == nil) || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
            if ok { self.onVideo?(url) }
            self.onVideo = nil
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        DispatchQueue.main.async { self.onPhoto?(data); self.onPhoto = nil }
    }
}

/// Плитка в сетке: живое изображение
struct CameraTile: View {
    @ObservedObject var camera: AttachCamera
    let onOpen: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Color.black
            .aspectRatio(0.78, contentMode: .fit)
            .overlay {
                if camera.ready {
                    CameraPreview(session: camera.session)
                } else {
                    Image(systemName: "camera.fill").font(.system(size: 26)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .overlay(alignment: .bottom) {
                Image(systemName: "camera.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .shadow(radius: 3).padding(.bottom, 8)
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { Haptics.impact(.light); onOpen() }
    }
}

/// Полный экран: зум щипком, затвор, смена камеры
struct CameraCaptureView: View {
    @ObservedObject var camera: AttachCamera
    let onPhoto: (Data) -> Void
    var onVideo: (URL) -> Void = { _ in }
    let onClose: () -> Void
    @State private var base: CGFloat = 1
    @State private var flash = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session)
                .ignoresSafeArea()
                .gesture(MagnificationGesture()
                    .onChanged { camera.setZoom(base * $0) }
                    .onEnded { _ in base = camera.zoom })
            Color.white.opacity(flash ? 0.6 : 0).ignoresSafeArea().allowsHitTesting(false)

            VStack {
                HStack {
                    Button { onClose() } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).background(.black.opacity(0.4), in: Circle())
                            .frame(width: 56, height: 56).contentShape(Rectangle())
                    }
                    Spacer()
                    if camera.zoom > 1.05 {
                        Text(String(format: "%.1f×", Double(camera.zoom)))
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.yellow)
                            .padding(.horizontal, 10).frame(height: 28).background(.black.opacity(0.45), in: Capsule())
                    }
                    Spacer()
                    Color.clear.frame(width: 56, height: 56)
                }
                .padding(.horizontal, 10)
                Spacer()
                zoomPills
                    .padding(.bottom, 14)
                HStack {
                    Color.clear.frame(width: 70, height: 70)
                    Spacer()
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                        Circle().fill(camera.recording ? Color.red : .white)
                            .frame(width: camera.recording ? 40 : 64, height: camera.recording ? 40 : 64)
                            .animation(.easeOut(duration: 0.15), value: camera.recording)
                    }
                    .frame(width: 90, height: 90).contentShape(Circle())
                    // нажатие — фото, удержание — видео (как в Telegram)
                    .onTapGesture {
                        Haptics.impact(.medium)
                        withAnimation(.easeOut(duration: 0.08)) { flash = true }
                        withAnimation(.easeIn(duration: 0.25).delay(0.08)) { flash = false }
                        camera.capture { onPhoto($0) }
                    }
                    .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 80, perform: {
                        Haptics.impact(.medium)
                        camera.startRecording { onVideo($0) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { camera.stopRecording() }
                    }, onPressingChanged: { pressing in
                        if !pressing, camera.recording { camera.stopRecording() }
                    })
                    Spacer()
                    Button { base = 1; camera.flip() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                            .font(.system(size: 22)).foregroundStyle(.white)
                            .frame(width: 52, height: 52).background(.black.opacity(0.4), in: Circle())
                            .frame(width: 70, height: 70).contentShape(Rectangle())
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }

    /// Пилюли зума как в системной камере: 1×, 2×, 3× (в пределах возможностей объектива)
    private var zoomLevels: [CGFloat] { [1, 2, 3].filter { $0 <= camera.maxZoom + 0.01 } }

    private var zoomPills: some View {
        HStack(spacing: 8) {
            ForEach(zoomLevels, id: \.self) { level in
                let active = abs(camera.zoom - level) < 0.15
                Button {
                    Haptics.select()
                    camera.setZoom(level)
                    base = level
                } label: {
                    Text(active ? String(format: "%g×", Double(level)) : String(format: "%g", Double(level)))
                        .font(.system(size: active ? 15 : 13, weight: .semibold))
                        .foregroundStyle(active ? .yellow : .white)
                        .frame(width: active ? 42 : 36, height: active ? 42 : 36)
                        .background(.black.opacity(0.4), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.black.opacity(0.25), in: Capsule())
        .opacity(zoomLevels.count > 1 ? 1 : 0)
    }
}

/// Системная камера — один в один как приложение «Камера» (фото / видео, вспышка, зум, фронталка), только без галереи.
/// Работает быстрее собственного экрана: её готовит сама система.
struct SystemCameraView: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    let onVideo: (URL) -> Void
    let onCancel: () -> Void

    static var available: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image", "public.movie"]
        picker.cameraCaptureMode = .photo
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 120
        picker.allowsEditing = false
        picker.modalPresentationStyle = .fullScreen
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: SystemCameraView
        init(_ parent: SystemCameraView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                parent.onVideo(url)
            } else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.92) {
                parent.onImage(data)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onCancel() }
    }
}
