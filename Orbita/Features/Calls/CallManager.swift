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
        CallRinger.shared.onAnswer = { [weak self] in self?.accept() }
        CallRinger.shared.onDecline = { [weak self] in self?.decline() }
        // VoIP-пуш разбудил приложение на входящий звонок — подтягиваем его из сервера и соединяемся
        VoIPPush.shared.onIncomingCall = { [weak self] _, _, _ in self?.wake() }
        engine.onConnected = { [weak self] in self?.connected() }
        engine.onDisconnected = { [weak self] in self?.finish(text: "Соединение потеряно", notify: true) }
        if CallRinger.shared.consumePendingAnswer() { accept() }     // ответили ещё до запуска приложения
    }

    var inCall: Bool { phase != .idle }

    // MARK: Опрос сервера

    /// Запускается один раз при входе в приложение
    func run() async {
        while !Task.isCancelled {
            await pollOnce()
            // пока звонок соединяется, ICE-кандидаты нужно забирать часто, иначе путь между разными сетями не успевает найтись
            let delay: UInt64
            switch phase {
            // в покое звонок приходит событием long-poll (wake()), поэтому опрос тут редкий — лишь страховка
            case .idle:                         delay = 30_000_000_000
            case .outgoing, .incoming, .connecting: delay = 250_000_000
            case .active:                       delay = 600_000_000
            case .ended:                        delay = 5_000_000_000
            }
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    /// Внешний сигнал «пришло событие звонка» (из long-poll): опросить сервер немедленно, не дожидаясь таймера.
    func wake() { Task { await pollOnce() } }

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
            if pendingAccept { accept() }               // в системном экране уже нажали «Ответить»
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

    /// Ответили в системном экране (CallKit) раньше, чем сервер успел сообщить о звонке — примем, как только он придёт
    private var pendingAccept = false

    func accept() {
        guard phase == .incoming, let id = callID else {
            // звонок ещё не подтянулся из poll (например, разбудил VoIP-пуш) — опросим и примем следом
            pendingAccept = true
            Task { await pollOnce() }
            return
        }
        pendingAccept = false
        Task {
            guard await permissions(video: video) else {
                flashError("Разрешите микрофон" + (video ? " и камеру" : "") + " в настройках")
                decline()
                return
            }
            do {
                let servers = try await repo.answer(id)
                setPhase(.connecting)
                try? await Task.sleep(nanoseconds: 450_000_000)        // CallKit отпускает аудио, потом его берёт разговор
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

    /// Короткий отбой — только если звонок уже был (не после отклонённого входящего без ответа)
    private func playEndTone(after was: Phase) {
        guard was == .active || was == .connecting || was == .outgoing else { return }
        CallTones.shared.play(.end, takeOverSession: true)
    }

    private func finish(text: String, notify: Bool, silent: Bool = false) {
        let was = phase
        if notify, let id = callID { Task { await repo.end(id) } }
        timer?.invalidate(); timer = nil
        engine.close()
        callID = nil
        buffered = []
        endText = text
        defer { playEndTone(after: was) }                   // после смены фазы, иначе мелодия звонка «глушит» отбой
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
        CallActivity.shared.set(CallGate.busy)
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

    /// Мелодия и мягкая вибрация, пока звонит: у аудио- и видеозвонка звук разный
    private func updateRinging() {
        ringTimer?.invalidate(); ringTimer = nil
        CallTones.shared.stop()
        if phase != .incoming { CallRinger.shared.end() }
        guard phase == .incoming || phase == .outgoing else { return }
        let incoming = phase == .incoming
        if incoming {
            // рингтон, который человек выбрал у себя в настройках iPhone, играет сам CallKit;
            // наша мелодия — только если система не дала показать звонок
            let isVideo = video
            CallRinger.shared.reportIncoming(name: peer?.name ?? "Focus", video: isVideo) { [weak self] ok in
                guard !ok, let self, self.phase == .incoming else { return }
                CallTones.shared.play(isVideo ? .incomingVideo : .incomingVoice, takeOverSession: true)
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        } else {
            // у исходящего звонка сессия уже настроена под разговор — её не трогаем
            CallTones.shared.play(video ? .outgoingVideo : .outgoingVoice, takeOverSession: false)
            Haptics.impact(.soft)
        }
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
/// Во время звонка нельзя смотреть видео и шортсы, включать музыку и записывать голосовые и кружки:
/// действие не выполняется, сверху на пару секунд всплывает подсказка
enum CallGate {
    static var busy = false

    enum Action { case video, shorts, music, voice, circle }

    static func message(_ lang: AppLanguage, _ action: Action = .video) -> String {
        let s = Strings(lang: lang)
        switch action {
        case .video:  return s.t("Сначала завершите разговор, чтобы посмотреть видео", "End the call first to watch videos")
        case .shorts: return s.t("Сначала завершите разговор, чтобы смотреть шортсы", "End the call first to watch shorts")
        case .music:  return s.t("Сначала завершите разговор, чтобы включить музыку", "End the call first to play music")
        case .voice:  return s.t("Сначала завершите разговор, чтобы записать голосовое", "End the call first to record a voice message")
        case .circle: return s.t("Сначала завершите разговор, чтобы записать кружок", "End the call first to record a video message")
        }
    }

    /// true — идёт звонок: действие не выполняем и показываем подсказку
    @discardableResult
    static func blocks(_ action: Action) -> Bool {
        guard busy else { return false }
        Task { @MainActor in CallGateToast.show(action) }
        return true
    }
}

/// Идёт ли звонок — для экранов, которым нужно перерисоваться, когда звонок начался или закончился (шортсы)
@MainActor
final class CallActivity: ObservableObject {
    static let shared = CallActivity()
    @Published private(set) var active = false
    func set(_ value: Bool) { if active != value { active = value } }
}

/// Подсказка «Сначала завершите разговор…» поверх всего приложения; касания проходят сквозь неё
@MainActor
enum CallGateToast {
    private static var window: UIWindow?
    private static var hideTask: Task<Void, Never>?

    static func show(_ action: CallGate.Action) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        Haptics.notify(.warning)
        let lang = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "lang") ?? "") ?? .ru
        let host = UIHostingController(rootView: CallGateToastView(text: CallGate.message(lang, action)))
        host.view.backgroundColor = .clear
        let w = window ?? UIWindow(windowScene: scene)
        w.windowLevel = .alert + 2
        w.backgroundColor = .clear
        w.isUserInteractionEnabled = false
        w.rootViewController = host
        w.isHidden = false
        window = w
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            window?.isHidden = true
            window = nil
        }
    }
}

private struct CallGateToastView: View {
    let text: String
    @State private var shown = false

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "phone.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.green)
                Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.black.opacity(0.82), in: Capsule())
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .offset(y: shown ? 0 : -90)
            .opacity(shown ? 1 : 0)
            Spacer()
        }
        .onAppear { withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { shown = true } }
    }
}
