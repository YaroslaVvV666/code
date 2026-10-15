import Combine
import SwiftUI
import AVFoundation
import AudioToolbox

/// Состояние и сценарий звонка: звонок → ответ → соединение → разговор → конец.
/// Сигналы (offer / answer / ICE) идут через сервер Orbita, звук и видео — напрямую между телефонами (WebRTC).
@MainActor
final class CallManager: ObservableObject {
    enum Phase: Equatable { case idle, outgoing, incoming, connecting, active, ended }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var peer: ChatPeer?
    @Published private(set) var video = false
    @Published private(set) var elapsed = 0
    /// Свёрнутый звонок: сверху висит плашка, остальное приложение работает
    @Published var minimized = false
    @Published private(set) var endText = ""
    @Published var muted = false { didSet { engine.setMuted(muted) } }
    @Published var speaker = false { didSet { engine.setSpeaker(speaker) } }
    @Published var cameraOn = true { didSet { engine.setVideoEnabled(cameraOn) } }
    @Published private(set) var errorText: String?

    let engine = RTCEngine()
    private let repo: CallRepository
    private var callID: String?
    private var isCaller = false
    private var buffered: [CallSignal] = []
    private var ice: [IceServer] = []
    private var timer: Timer?
    private var ringTimer: Timer?
    private var started: Date?
    private var pollTask: Task<Void, Never>?

    init(repo: CallRepository) {
        self.repo = repo
        engine.onIce = { [weak self] json in
            guard let self, let id = self.callID else { return }
            let repo = self.repo
            Task { await repo.signal(id, kind: "ice", data: json) }
        }
        engine.onConnected = { [weak self] in self?.connected() }
        engine.onDisconnected = { [weak self] in self?.finish(text: "Соединение потеряно", notify: true) }
    }

    var inCall: Bool { phase != .idle }

    // MARK: Опрос сервера

    /// Запускается один раз при входе в приложение
    func run() async {
        while !Task.isCancelled {
            await pollOnce()
            let busy = phase != .idle
            try? await Task.sleep(nanoseconds: busy ? 700_000_000 : 1_800_000_000)
        }
    }

    private func pollOnce() async {
        guard let poll = try? await repo.poll() else { return }
        if let incoming = poll.incoming, phase == .idle {
            callID = incoming.id
            isCaller = false
            peer = incoming.from.peer
            video = incoming.video
            ice = incoming.ice
            buffered = []
            cameraOn = true
            muted = false
            speaker = incoming.video
            setPhase(.incoming)
        }
        for signal in poll.signals where signal.call == callID { handle(signal) }
    }

    private func handle(_ s: CallSignal) {
        switch s.kind {
        case "offer":
            buffered.append(s)
        case "ice":
            if phase == .incoming { buffered.append(s) } else { engine.addRemoteIce(s.data) }
        case "accepted":
            if phase == .outgoing { setPhase(.connecting) }
        case "answer":
            Task { try? await engine.acceptAnswer(s.data) }
        case "end":
            let text: String
            switch s.data {
            case "declined": text = "Вызов отклонён"
            case "missed": text = isCaller ? "Нет ответа" : "Пропущенный звонок"
            case "cancelled": text = "Вызов отменён"
            default: text = "Звонок завершён"
            }
            finish(text: text, notify: false)
        default:
            break
        }
    }

    // MARK: Действия

    func start(peer: ChatPeer, video: Bool) {
        guard phase == .idle else { return }
        guard RTCEngine.isAvailable else {
            flashError("Звонки требуют пакет WebRTC — добавьте его в Xcode (см. README)")
            return
        }
        Task {
            guard await permissions(video: video) else { flashError("Разрешите микрофон" + (video ? " и камеру" : "") + " в настройках"); return }
            do {
                let r = try await repo.start(to: peer.id, video: video)
                callID = r.id
                isCaller = true
                self.peer = peer
                self.video = video
                self.cameraOn = true
                self.muted = false
                self.speaker = video
                setPhase(.outgoing)
                engine.prepare(servers: r.ice, video: video)
                engine.setSpeaker(video)
                let offer = try await engine.makeOffer()
                await repo.signal(r.id, kind: "offer", data: offer)
            } catch let e as APIError {
                flashError(Self.message(for: e))
                finish(text: "", notify: false, silent: true)
            } catch {
                flashError("Не удалось начать звонок")
                if let id = callID { await repo.end(id) }
                finish(text: "", notify: false, silent: true)
            }
        }
    }

    func accept() {
        guard phase == .incoming, let id = callID else { return }
        Task {
            guard await permissions(video: video) else {
                flashError("Разрешите микрофон" + (video ? " и камеру" : "") + " в настройках")
                decline()
                return
            }
            do {
                let servers = try await repo.answer(id)
                setPhase(.connecting)
                engine.prepare(servers: servers.isEmpty ? ice : servers, video: video)
                engine.setSpeaker(video)
                // оффер мог ещё не дойти: ждём до 6 секунд
                var waited = 0
                while !buffered.contains(where: { $0.kind == "offer" }) && waited < 30 {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    waited += 1
                }
                guard let offer = buffered.first(where: { $0.kind == "offer" }) else { throw RTCEngineError.failed }
                let answer = try await engine.makeAnswer(offer: offer.data)
                await repo.signal(id, kind: "answer", data: answer)
                for s in buffered where s.kind == "ice" { engine.addRemoteIce(s.data) }
                buffered = []
            } catch {
                await repo.end(id)
                finish(text: "Не удалось соединиться", notify: false)
            }
        }
    }

    func toggleShare() {
        Task {
            if engine.sharing {
                engine.stopScreenShare()
            } else if !(await engine.startScreenShare()) {
                flashError("Не удалось включить показ экрана")
            }
        }
    }

    func decline() { hangUp() }

    func hangUp() {
        guard let id = callID else { return finish(text: "", notify: false, silent: true) }
        let was = phase
        Task { await repo.end(id) }
        finish(text: was == .active ? "Звонок завершён" : (was == .incoming ? "" : "Вызов отменён"), notify: false,
               silent: was == .incoming)
    }

    private func connected() {
        guard phase == .connecting || phase == .outgoing else { return }
        started = Date()
        elapsed = 0
        setPhase(.active)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.started else { return }
                self.elapsed = Int(Date().timeIntervalSince(s))
            }
        }
    }

    private func finish(text: String, notify: Bool, silent: Bool = false) {
        if notify, let id = callID { Task { await repo.end(id) } }
        timer?.invalidate(); timer = nil
        engine.close()
        callID = nil
        buffered = []
        endText = text
        if silent || text.isEmpty {
            setPhase(.idle)
        } else {
            setPhase(.ended)
            Task {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                if phase == .ended { setPhase(.idle) }
            }
        }
    }

    // MARK: Служебное

    private func setPhase(_ new: Phase) {
        phase = new
        CallGate.busy = (new != .idle && new != .ended)
        if new == .idle || new == .incoming || new == .ended { minimized = false }
        updateRinging()
        if new == .idle {
            peer = nil
            started = nil
            elapsed = 0
            CallWindowController.shared.hide()
        } else {
            CallWindowController.shared.show(self)
        }
    }

    /// Звук и вибрация, пока звонит
    private func updateRinging() {
        ringTimer?.invalidate(); ringTimer = nil
        guard phase == .incoming || phase == .outgoing else { return }
        let incoming = phase == .incoming
        func tick() {
            if incoming {
                AudioServicesPlaySystemSound(1005)
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            } else {
                Haptics.impact(.soft)
            }
        }
        tick()
        ringTimer = Timer.scheduledTimer(withTimeInterval: incoming ? 2.2 : 3, repeats: true) { _ in tick() }
    }

    private func permissions(video: Bool) async -> Bool {
        let mic = await withCheckedContinuation { c in AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) } }
        guard mic else { return false }
        if video { return await AVCaptureDevice.requestAccess(for: .video) }
        return true
    }

    private func flashError(_ text: String) {
        errorText = text
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if errorText == text { errorText = nil }
        }
    }

    private static func message(for e: APIError) -> String {
        if case .server(_, let code) = e {
            switch code {
            case "busy": return "Вы уже разговариваете"
            case "callee_busy": return "Абонент занят"
            case "forbidden": return "Человек запретил вам звонить"
            case "blocked": return "Звонок невозможен"
            default: break
            }
        }
        return "Не удалось позвонить"
    }
}

/// Пока идёт разговор, видео в приложении не воспроизводится
enum CallGate {
    static var busy = false
    static func message(_ lang: AppLanguage) -> String {
        Strings(lang: lang).t("Сначала завершите разговор, чтобы посмотреть видео", "End the call first to watch videos")
    }
}
