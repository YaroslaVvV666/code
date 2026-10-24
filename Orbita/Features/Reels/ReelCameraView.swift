import SwiftUI
import AVFoundation
import Photos

/// Съёмка шортса: кружок внизу — нажал, пошла запись (он краснеет и уменьшается, вокруг бежит обод), нажал ещё раз — стоп.
/// Максимум 60 секунд: дальше запись останавливается сама и показывается результат. Снятое можно пересмотреть, переснять или отправить дальше.
/// Слева внизу — вкладка «Галерея»: выбрать готовое видео и отредактировать.
struct ReelCameraView: View {
    var error: String? = nil
    var onClose: () -> Void
    var onGallery: () -> Void
    /// Получает снятый файл, возвращает, удалось ли его подготовить
    var onRecorded: (URL) async -> Bool

    @Environment(\.lang) private var lang
    @StateObject private var recorder = CircleRecorder()

    private enum Phase { case idle, countdown, recording, review }
    @State private var phase: Phase = .idle
    @State private var limit: Double = 60
    @State private var timerSetting = 0              // 0 — сразу, 3 или 10 секунд до старта
    @State private var countdown = 0
    @State private var torch = false
    @State private var denied = false
    @State private var cameraFailed = false
    @State private var recordedURL: URL?
    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?
    @State private var sending = false
    @State private var notice: String?
    @State private var work: Task<Void, Never>?
    @State private var galleryThumb: UIImage?

    private var s: Strings { Strings(lang: lang) }
    private let red = Color(red: 1, green: 0.17, blue: 0.33)

    var body: some View {
        GeometryReader { geo in
            let top = TopInset.value
            let bottomSpace: CGFloat = 104 + max(0, BottomInset.value - 20)
            let areaH = geo.size.height - top - bottomSpace + 0
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                ZStack {
                    if phase == .review, let player {
                        PlayerLayerView(player: player, gravity: .resizeAspectFill)
                    } else if denied {
                        permissionDenied
                    } else {
                        CameraPreview(session: recorder.session)
                            .opacity(recorder.ready ? 1 : 0.0)
                        if !recorder.ready && !cameraFailed { ProgressView().tint(.white) }
                        if cameraFailed && !denied {
                            Text(s.t("Не удалось включить камеру", "Couldn't start the camera"))
                                .font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    overlays(areaH: areaH)
                }
                .frame(width: geo.size.width, height: max(200, areaH))
                .background(Color(white: 0.08))
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.top, top)

                VStack {
                    Spacer()
                    bottomArea
                        .frame(height: bottomSpace)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let text = notice ?? error { ToastView(text: text).padding(.top, TopInset.value + 12).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.2), value: notice)
        .task { await loadGalleryThumb() }
        .task {
            let ok = await recorder.prepare()
            if !ok { denied = recorder.failure == "denied"; cameraFailed = true }
        }
        .onDisappear {
            work?.cancel()
            recorder.shutdown()
            stopPlayback()
            if !sending, let url = recordedURL { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Поверх кадра

    @ViewBuilder
    private func overlays(areaH: CGFloat) -> some View {
        // закрыть / сбросить снятое
        VStack {
            HStack(alignment: .top) {
                if phase != .recording && phase != .countdown {
                    roundTool(phase == .review ? "chevron.left" : "xmark", size: 40) {
                        if phase == .review { redo() } else { onClose() }
                    }
                } else if phase == .recording {
                    timePill
                }
                Spacer()
                if phase == .idle {
                    VStack(spacing: 14) {
                        tool("arrow.triangle.2.circlepath.camera", label: nil) {
                            Haptics.impact(.light)
                            torch = false
                            recorder.flipCamera()
                        }
                        if !recorder.isFront {
                            tool(torch ? "bolt.fill" : "bolt.slash", label: nil) {
                                torch.toggle()
                                recorder.setTorch(torch)
                            }
                        }
                        tool("timer", label: timerSetting == 0 ? nil : "\(timerSetting)") {
                            Haptics.select()
                            timerSetting = timerSetting == 0 ? 3 : (timerSetting == 3 ? 10 : 0)
                        }
                    }
                } else if phase == .recording {
                    roundTool("arrow.triangle.2.circlepath.camera", size: 40) { recorder.flipCamera() }
                }
            }
            .padding(.horizontal, 14).padding(.top, 14)
            Spacer()
        }

        if phase == .countdown {
            Text("\(countdown)")
                .font(.system(size: 120, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 10)
                .contentTransition(.numericText())
                .allowsHitTesting(false)
        }

        if phase == .idle || phase == .recording || phase == .countdown {
            VStack(spacing: 18) {
                Spacer()
                if phase == .idle { modeRow }
                recordButton
                    .padding(.bottom, 20)
            }
        }

        if phase == .review {
            VStack {
                Spacer()
                Text(clock(recordedDuration))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(.bottom, 16)
            }
        }
    }

    private var permissionDenied: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash").font(.system(size: 38, weight: .light)).foregroundStyle(.white.opacity(0.8))
            Text(s.t("Нет доступа к камере или микрофону", "No access to the camera or microphone"))
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).multilineTextAlignment(.center)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text(s.t("Открыть настройки", "Open Settings")).font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 20).frame(height: 42).background(.white, in: Capsule())
            }
            .buttonStyle(PressStyle())
        }
        .padding(30)
    }

    private var timePill: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            HStack(spacing: 7) {
                Circle().fill(red).frame(width: 9, height: 9)
                Text(clock(elapsed)).font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                Text("/ " + clock(limit)).font(.system(size: 13).monospacedDigit()).foregroundStyle(.white.opacity(0.65))
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(.black.opacity(0.45), in: Capsule())
        }
    }

    private var modeRow: some View {
        HStack(spacing: 8) {
            ForEach([15.0, 60.0], id: \.self) { value in
                Button {
                    Haptics.select()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { limit = value }
                } label: {
                    Text(s.t("\(Int(value)) с", "\(Int(value)) s"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(limit == value ? Color.black : Color.white)
                        .padding(.horizontal, 15).frame(height: 32)
                        .background(limit == value ? Color.white : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .transition(.opacity)
    }

    // MARK: Кнопка записи

    private var recordButton: some View {
        Button { recordTapped() } label: {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: phase != .recording)) { _ in
                let recording = phase == .recording
                let progress = recording ? min(1, elapsed / limit) : 0
                ZStack {
                    Circle().stroke(Color.white.opacity(recording ? 0.3 : 1), lineWidth: 5).frame(width: 88, height: 88)
                    if recording {
                        Circle().trim(from: 0, to: progress)
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90)).frame(width: 88, height: 88)
                    }
                    Circle().fill(recording ? red : Color.white)
                        .frame(width: recording ? 40 : 68, height: recording ? 40 : 68)
                }
                .frame(width: 96, height: 96)
                .animation(.spring(response: 0.3, dampingFraction: 0.72), value: recording)
            }
        }
        .buttonStyle(.plain)
        .disabled(!recorder.ready || sending)
    }

    // MARK: Низ экрана

    @ViewBuilder
    private var bottomArea: some View {
        switch phase {
        case .review:
            HStack(spacing: 12) {
                Button { redo() } label: {
                    Label(s.t("Переснять", "Retake"), systemImage: "trash")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(PressStyle())
                .disabled(sending)
                Button { next() } label: {
                    Group {
                        if sending { ProgressView().tint(.white) } else {
                            Label(s.t("Далее", "Next"), systemImage: "arrow.right").labelStyle(.titleAndIcon)
                        }
                    }
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(red, in: Capsule())
                }
                .buttonStyle(PressStyle())
                .disabled(sending)
            }
            .padding(.horizontal, 16).padding(.bottom, max(8, BottomInset.value - 8))

        case .recording, .countdown:
            // во время съёмки: отменить всё, не сохраняя
            HStack {
                Button { cancelRecording() } label: {
                    Label(s.t("Отменить съёмку", "Discard"), systemImage: "trash")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).frame(height: 44)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(PressStyle())
            }
            .frame(maxWidth: .infinity).padding(.bottom, max(8, BottomInset.value - 8))

        case .idle:
            ZStack {
                Text(s.t("КАМЕРА", "CAMERA")).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                HStack {
                    Button { onGallery() } label: {
                        VStack(spacing: 3) {
                            ZStack {
                                if let galleryThumb {
                                    Image(uiImage: galleryThumb).resizable().scaledToFill()
                                } else {
                                    Color.white.opacity(0.14)
                                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 20, weight: .medium))
                                }
                            }
                            .frame(width: 46, height: 46)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.7), lineWidth: 1.5))
                            Text(s.t("Галерея", "Gallery")).font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 22)
            }
            .padding(.bottom, max(4, BottomInset.value - 12))
        }
    }

    // MARK: Кнопки-инструменты

    private func roundTool(_ icon: String, size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                .frame(width: size, height: size).background(.black.opacity(0.35), in: Circle())
                .padding(4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tool(_ icon: String, label: String?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: icon).font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .frame(width: 44, height: 44)
                if let label {
                    Text(label).font(.system(size: 10, weight: .heavy)).foregroundStyle(.black)
                        .frame(width: 17, height: 17).background(.white, in: Circle())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Логика

    private var elapsed: Double { recorder.clockStart.map { Date().timeIntervalSince($0) } ?? 0 }
    private var recordedDuration: Double { player?.currentItem?.asset.duration.seconds.nonNaN ?? 0 }

    private func clock(_ t: Double) -> String {
        let n = Int(max(0, t).rounded(.down))
        return String(format: "%d:%02d", n / 60, n % 60)
    }

    private func recordTapped() {
        switch phase {
        case .idle:
            Haptics.impact(.medium)
            if timerSetting > 0 { startCountdown() } else { begin() }
        case .countdown:
            work?.cancel(); phase = .idle
        case .recording:
            Haptics.impact(.medium)
            finish()
        case .review:
            break
        }
    }

    private func startCountdown() {
        phase = .countdown
        countdown = timerSetting
        work?.cancel()
        work = Task { @MainActor in
            while countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                withAnimation { countdown -= 1 }
                Haptics.select()
            }
            if !Task.isCancelled { begin() }
        }
    }

    private func begin() {
        phase = .recording
        recorder.startRecording()
        work?.cancel()
        // следим за пределом: свой лимит (15 с) останавливаем сами, 60 с останавливает и сама камера
        work = Task { @MainActor in
            while !Task.isCancelled, phase == .recording {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
                if elapsed >= limit - 0.05 || !recorder.isRecording {
                    Haptics.notify(.warning)
                    finish()
                    return
                }
            }
        }
    }

    /// Остановить запись и показать, что получилось
    private func finish() {
        guard phase == .recording else { return }
        work?.cancel()
        torch = false
        recorder.setTorch(false)
        Task { @MainActor in
            let url = await recorder.stopRecording()
            guard let url else {
                phase = .idle
                flash(s.t("Запись не получилась. Попробуйте ещё раз", "Recording failed. Please try again"))
                return
            }
            recordedURL = url
            startPlayback(url)
            withAnimation(.easeOut(duration: 0.2)) { phase = .review }
        }
    }

    /// Отменить съёмку: запись останавливается, файл удаляется
    private func cancelRecording() {
        work?.cancel()
        if phase == .countdown { phase = .idle; return }
        phase = .idle
        Haptics.impact(.light)
        Task { @MainActor in
            if let url = await recorder.stopRecording() { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Переснять: снятое удаляется, снова камера
    private func redo() {
        Haptics.impact(.light)
        stopPlayback()
        if let url = recordedURL { try? FileManager.default.removeItem(at: url) }
        recordedURL = nil
        withAnimation(.easeOut(duration: 0.2)) { phase = .idle }
    }

    private func next() {
        guard let url = recordedURL, !sending else { return }
        sending = true
        Task { @MainActor in
            let ok = await onRecorded(url)
            sending = false
            if !ok { flash(s.t("Не удалось подготовить видео", "Couldn't prepare the video")) } else { recordedURL = nil }
        }
    }

    private func startPlayback(_ url: URL) {
        stopPlayback()
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .none
        loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            p.seek(to: .zero); p.play()
        }
        player = p
        p.play()
    }

    private func stopPlayback() {
        player?.pause()
        player = nil
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
    }

    /// На кнопке «Галерея» — самое свежее фото или видео из галереи (если доступ уже выдан)
    private func loadGalleryThumb() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        guard let asset = PHAsset.fetchAssets(with: options).firstObject else { return }
        let image: UIImage? = await withCheckedContinuation { c in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat
            o.resizeMode = .fast
            o.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 140, height: 140), contentMode: .aspectFill, options: o) { img, _ in
                c.resume(returning: img)
            }
        }
        galleryThumb = image
    }

    private func flash(_ text: String) {
        notice = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if notice == text { notice = nil }
        }
    }
}

private extension Double {
    var nonNaN: Double? { isFinite ? self : nil }
}
