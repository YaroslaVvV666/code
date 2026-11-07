import Combine
import SwiftUI
import AVFoundation
import CoreMedia

// MARK: - Групповые звонки и видеочаты
//
// Mesh: каждый участник соединён с каждым (до 8 человек). Новичок сам отправляет предложения тем, кто уже
// в звонке, — встречных предложений не бывает. Сигналы идут через сервер (/v1/groups/<id>/call/...).

struct GroupCallParticipant: Identifiable, Equatable, Decodable {
    let id: String
    let name: String
    let username: String?
    let avatar: String?
    let muted: Bool
    let video: Bool
    let me: Bool
}

struct GroupCallSignal: Decodable, Equatable {
    let from: String
    let kind: String            // offer | answer | ice
    let data: String
}

struct GroupCallState: Decodable {
    let active: Bool
    let callId: String?
    let startedAt: Double?
    let video: Bool?
    let participants: [GroupCallParticipant]?
    let joined: Bool?
    let max: Int?
    let ice: [IceServer]?
    let signals: [GroupCallSignal]?
}

/// Плашка «Идёт видеочат» в группе (из сведений о группе)
struct GroupCallBrief: Equatable, Decodable {
    let id: String
    let count: Int
    let video: Bool
}

struct GroupCallAPI: Sendable {
    let api: ServerAPI

    private func path(_ gid: String, _ tail: String = "") -> String { "/v1/groups/\(gid)/call" + tail }

    func status(_ gid: String) async throws -> GroupCallState {
        try decodeAPI(GroupCallState.self, from: try await api.request("GET", path(gid)))
    }
    func join(_ gid: String, video: Bool, muted: Bool) async throws -> GroupCallState {
        try decodeAPI(GroupCallState.self, from: try await api.request("POST", path(gid, "/join"),
                                                                        body: ServerAPI.json(["video": video, "muted": muted])))
    }
    func leave(_ gid: String) async {
        _ = try? await api.request("POST", path(gid, "/leave"), body: ServerAPI.json([:] as [String: Any]))
    }
    func state(_ gid: String, muted: Bool, video: Bool) async {
        _ = try? await api.request("POST", path(gid, "/state"), body: ServerAPI.json(["muted": muted, "video": video]))
    }
    func signal(_ gid: String, to: String, kind: String, data: String) async {
        _ = try? await api.request("POST", path(gid, "/signal"), body: ServerAPI.json(["to": to, "kind": kind, "data": data]))
    }
    func poll(_ gid: String) async throws -> GroupCallState {
        try decodeAPI(GroupCallState.self, from: try await api.request("GET", path(gid, "/poll"), query: ["timeout": "20"]))
    }
}

// MARK: - Сетка соединений (WebRTC)

#if canImport(WebRTC)
import WebRTC

typealias MeshVideoTrack = RTCVideoTrack

@MainActor
final class GroupRTCMesh: NSObject, ObservableObject {
    static let isAvailable = true

    @Published private(set) var remoteVideos: [String: RTCVideoTrack] = [:]
    @Published private(set) var localVideo: RTCVideoTrack?
    @Published private(set) var usingFront = true
    @Published private(set) var connected: Set<String> = []

    /// (кому, ICE-кандидат в JSON)
    var onIce: ((String, String) -> Void)?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private var servers: [IceServer] = []
    private var peers: [String: RTCPeerConnection] = [:]
    private var owners: [ObjectIdentifier: String] = [:]
    private var haveRemote: Set<String> = []
    private var pendingIce: [String: [RTCIceCandidate]] = [:]
    private var audioTrack: RTCAudioTrack?
    private var videoSource: RTCVideoSource?
    private var capturer: RTCCameraVideoCapturer?

    private let sdpConstraints = RTCMediaConstraints(
        mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"], optionalConstraints: nil)

    func prepare(servers: [IceServer], video: Bool) {
        close()
        self.servers = servers
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        try? s.setCategory(.playAndRecord, with: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
        try? s.setMode(video ? .videoChat : .voiceChat)
        try? s.setActive(true)
        s.unlockForConfiguration()
        let source = Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        audioTrack = Self.factory.audioTrack(with: source, trackId: "a0")
        if video { startCamera(front: true) }
    }

    /// Соединение с участником: наши дорожки (звук и, если есть, камера) уходят ему
    private func connection(_ peerID: String) -> RTCPeerConnection? {
        if let pc = peers[peerID] { return pc }
        let config = RTCConfiguration()
        config.iceServers = servers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        let made: RTCPeerConnection? = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)
        guard let pc = made else { return nil }
        if let audioTrack { pc.add(audioTrack, streamIds: ["s0"]) }
        if let localVideo { pc.add(localVideo, streamIds: ["s0"]) }
        peers[peerID] = pc
        owners[ObjectIdentifier(pc)] = peerID
        return pc
    }

    func offer(to peerID: String) async throws -> String {
        guard let pc = connection(peerID) else { throw RTCEngineError.failed }
        let sdp: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
            pc.offer(for: sdpConstraints) { sdp, e in if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: e ?? RTCEngineError.failed) } }
        }
        try await setLocal(pc, sdp)
        return sdp.sdp
    }

    func answer(to peerID: String, offer: String) async throws -> String {
        // повторное предложение (участник переподключился) — начинаем соединение заново
        if peers[peerID] != nil, haveRemote.contains(peerID) { drop(peerID) }
        guard let pc = connection(peerID) else { throw RTCEngineError.failed }
        try await setRemote(peerID, pc, RTCSessionDescription(type: .offer, sdp: offer))
        let sdp: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
            pc.answer(for: sdpConstraints) { sdp, e in if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: e ?? RTCEngineError.failed) } }
        }
        try await setLocal(pc, sdp)
        return sdp.sdp
    }

    func accept(from peerID: String, answer: String) async {
        guard let pc = peers[peerID] else { return }
        try? await setRemote(peerID, pc, RTCSessionDescription(type: .answer, sdp: answer))
    }

    func addIce(from peerID: String, _ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sdp = obj["candidate"] as? String else { return }
        let c = RTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(obj["sdpMLineIndex"] as? Int ?? 0), sdpMid: obj["sdpMid"] as? String)
        if haveRemote.contains(peerID), let pc = peers[peerID] { pc.add(c) { _ in } } else { pendingIce[peerID, default: []].append(c) }
    }

    func drop(_ peerID: String) {
        if let pc = peers.removeValue(forKey: peerID) {
            owners[ObjectIdentifier(pc)] = nil
            pc.close()
        }
        haveRemote.remove(peerID)
        pendingIce[peerID] = nil
        remoteVideos[peerID] = nil
        connected.remove(peerID)
    }

    private func setLocal(_ pc: RTCPeerConnection, _ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { e in if let e { c.resume(throwing: e) } else { c.resume() } }
        }
    }

    private func setRemote(_ peerID: String, _ pc: RTCPeerConnection, _ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { e in if let e { c.resume(throwing: e) } else { c.resume() } }
        }
        haveRemote.insert(peerID)
        for cand in pendingIce[peerID] ?? [] { pc.add(cand) { _ in } }
        pendingIce[peerID] = nil
        refreshRemote(peerID)
    }

    fileprivate func refreshRemote(_ peerID: String) {
        guard let pc = peers[peerID],
              let track = pc.transceivers.compactMap({ $0.receiver.track as? RTCVideoTrack }).first else { return }
        track.isEnabled = true
        if remoteVideos[peerID] !== track { remoteVideos[peerID] = track }
    }

    fileprivate func owner(_ pc: RTCPeerConnection) -> String? { owners[ObjectIdentifier(pc)] }
    fileprivate func setConnected(_ peerID: String, _ on: Bool) {
        if on { connected.insert(peerID) } else { connected.remove(peerID) }
    }

    // MARK: Камера, звук

    func startCamera(front: Bool) {
        if videoSource == nil {
            let source = Self.factory.videoSource()
            videoSource = source
            let track = Self.factory.videoTrack(with: source, trackId: "v0")
            localVideo = track
            capturer = RTCCameraVideoCapturer(delegate: source)
            // камеру включили посреди звонка — дорожку получают все (соединения пересогласуются при следующем предложении)
            for pc in peers.values { pc.add(track, streamIds: ["s0"]) }
            // mesh: на каждого получателя своя копия видео, поэтому качество ниже, чем в личном звонке
            source.adaptOutputFormat(toWidth: 640, height: 480, fps: 24)
        }
        let position: AVCaptureDevice.Position = front ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position })
                ?? RTCCameraVideoCapturer.captureDevices().first else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        func width(_ f: AVCaptureDevice.Format) -> Int32 { CMVideoFormatDescriptionGetDimensions(f.formatDescription).width }
        guard let format = formats.min(by: { abs(Int(width($0)) - 640) < abs(Int(width($1)) - 640) }) else { return }
        capturer?.startCapture(with: device, format: format, fps: 24)
        usingFront = front
        localVideo?.isEnabled = true
    }

    func flipCamera() { startCamera(front: !usingFront) }

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

    func close() {
        let old = capturer
        Task { await old?.stopCapture() }
        capturer = nil
        videoSource = nil
        localVideo = nil
        for pc in peers.values { pc.close() }
        peers = [:]
        owners = [:]
        haveRemote = []
        pendingIce = [:]
        remoteVideos = [:]
        connected = []
        audioTrack = nil
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        try? s.setActive(false)
        s.unlockForConfiguration()
    }
}

extension GroupRTCMesh: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        Task { @MainActor in if let id = self.owner(peerConnection) { self.refreshRemote(id) } }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        Task { @MainActor in if let id = self.owner(peerConnection) { self.refreshRemote(id) } }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let obj: [String: Any] = ["candidate": candidate.sdp, "sdpMLineIndex": Int(candidate.sdpMLineIndex), "sdpMid": candidate.sdpMid ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let text = String(data: data, encoding: .utf8) else { return }
        Task { @MainActor in if let id = self.owner(peerConnection) { self.onIce?(id, text) } }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            guard let id = self.owner(peerConnection) else { return }
            switch newState {
            case .connected, .completed: self.setConnected(id, true); self.refreshRemote(id)
            case .failed, .closed, .disconnected: self.setConnected(id, false)
            default: break
            }
        }
    }
}

#else

typealias MeshVideoTrack = Bool

@MainActor
final class GroupRTCMesh: NSObject, ObservableObject {
    static let isAvailable = false
    @Published private(set) var remoteVideos: [String: Bool] = [:]
    @Published private(set) var localVideo: Bool?
    @Published private(set) var usingFront = true
    @Published private(set) var connected: Set<String> = []
    var onIce: ((String, String) -> Void)?
    func prepare(servers: [IceServer], video: Bool) {}
    func offer(to peerID: String) async throws -> String { throw RTCEngineError.unavailable }
    func answer(to peerID: String, offer: String) async throws -> String { throw RTCEngineError.unavailable }
    func accept(from peerID: String, answer: String) async {}
    func addIce(from peerID: String, _ json: String) {}
    func drop(_ peerID: String) {}
    func startCamera(front: Bool) {}
    func flipCamera() {}
    func setVideoEnabled(_ on: Bool) {}
    func setMuted(_ muted: Bool) {}
    func setSpeaker(_ on: Bool) {}
    func close() {}
}

#endif

// MARK: - Звонок: состояние, сигналы, участники

@MainActor
final class GroupCallManager: ObservableObject {
    static let shared = GroupCallManager()
    enum Phase: Equatable { case idle, joining, active }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var group: ChatPeer?
    @Published private(set) var participants: [GroupCallParticipant] = []
    @Published private(set) var errorText: String?
    @Published var minimized = false
    @Published var muted = false { didSet { mesh.setMuted(muted); pushState() } }
    @Published var cameraOn = false { didSet { mesh.setVideoEnabled(cameraOn); pushState() } }
    @Published var speaker = true { didSet { mesh.setSpeaker(speaker) } }
    @Published private(set) var startedAt: Date?

    let mesh = GroupRTCMesh()
    private var api: GroupCallAPI?
    private var myID = ""
    private var pollTask: Task<Void, Never>?
    private var known: Set<String> = []

    private init() {
        mesh.onIce = { [weak self] peerID, json in
            guard let self, let gid = self.group?.id, let api = self.api else { return }
            Task { await api.signal(gid, to: peerID, kind: "ice", data: json) }
        }
    }

    func attach(api: ServerAPI, userID: String) {
        self.api = GroupCallAPI(api: api)
        self.myID = userID.lowercased()
    }

    var others: [GroupCallParticipant] { participants.filter { !$0.me } }

    /// Войти в звонок группы (если его нет — начать)
    func join(_ peer: ChatPeer, video: Bool) {
        guard let api, phase == .idle else {
            if group?.id == peer.id { minimized = false }
            return
        }
        guard GroupRTCMesh.isAvailable else {
            errorText = "Звонки недоступны: в сборке нет WebRTC"
            AppToast.show("Звонки недоступны: в сборке нет WebRTC", icon: "phone.down.fill")
            return
        }
        group = peer
        phase = .joining
        minimized = false
        errorText = nil
        GroupCallWindow.shared.show(self)
        Task {
            await CallPermissions.request(video: video)
            do {
                let st = try await api.join(peer.id, video: video, muted: false)
                mesh.prepare(servers: st.ice ?? [], video: video)
                cameraOn = video
                muted = false
                speaker = true
                apply(st)
                phase = .active
                startedAt = Date()
                // мы новенькие: сами предлагаем соединение каждому, кто уже здесь
                for p in others {
                    known.insert(p.id)
                    await sendOffer(to: p.id)
                }
                startPolling()
            } catch {
                errorText = (error as? APIError).map { e -> String in
                    if case .server(_, let code) = e, code == "call_full" { return "В звонке уже максимум участников" }
                    if case .server(_, let code) = e, code == "busy" { return "Сначала завершите текущий звонок" }
                    return "Не удалось подключиться"
                } ?? "Не удалось подключиться"
                if let errorText { AppToast.show(errorText, icon: "phone.down.fill") }
                finishLocally()
            }
        }
    }

    func leave() {
        guard let gid = group?.id, let api else { return finishLocally() }
        Task { await api.leave(gid) }
        finishLocally()
    }

    private func finishLocally() {
        pollTask?.cancel()
        pollTask = nil
        mesh.close()
        participants = []
        known = []
        phase = .idle
        group = nil
        startedAt = nil
        minimized = false
        GroupCallWindow.shared.hide()
    }

    private func sendOffer(to peerID: String) async {
        guard let gid = group?.id, let api else { return }
        if let sdp = try? await mesh.offer(to: peerID) { await api.signal(gid, to: peerID, kind: "offer", data: sdp) }
    }

    private func pushState() {
        guard phase == .active, let gid = group?.id, let api else { return }
        let m = muted, v = cameraOn
        Task { await api.state(gid, muted: m, video: v) }
    }

    private func apply(_ st: GroupCallState) {
        let list = st.participants ?? []
        if list != participants { participants = list }
        // ушедшие — закрываем их соединения
        let ids = Set(list.filter { !$0.me }.map(\.id))
        for gone in known.subtracting(ids) { mesh.drop(gone) }
        known = known.intersection(ids).union(ids)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, let gid = self.group?.id, let api = self.api else { return }
                do {
                    let st = try await api.poll(gid)
                    failures = 0
                    if st.joined == false {                  // звонок завершился или нас убрали
                        self.finishLocally()
                        return
                    }
                    self.apply(st)
                    for s in st.signals ?? [] { await self.handle(s) }
                } catch {
                    failures += 1
                    if failures > 6 { self.errorText = "Связь потеряна"; self.leave(); return }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
    }

    private func handle(_ s: GroupCallSignal) async {
        guard let gid = group?.id, let api else { return }
        switch s.kind {
        case "offer":
            if let sdp = try? await mesh.answer(to: s.from, offer: s.data) {
                await api.signal(gid, to: s.from, kind: "answer", data: sdp)
            }
        case "answer": await mesh.accept(from: s.from, answer: s.data)
        case "ice": mesh.addIce(from: s.from, s.data)
        default: break
        }
    }
}

/// Доступ к микрофону и камере перед звонком
enum CallPermissions {
    static func request(video: Bool) async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        if video { _ = await AVCaptureDevice.requestAccess(for: .video) }
    }
}

// MARK: - Экран группового звонка

struct GroupCallScreen: View {
    @ObservedObject var manager: GroupCallManager
    @ObservedObject private var mesh: GroupRTCMesh
    @Environment(\.lang) private var lang
    @State private var now = Date()

    init(manager: GroupCallManager) {
        self.manager = manager
        self.mesh = manager.mesh
    }

    private var s: Strings { Strings(lang: lang) }
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.08, green: 0.09, blue: 0.16), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                top
                grid
                controls
            }
            .padding(.horizontal, 12)
        }
        .onReceive(timer) { now = $0 }
        .preferredColorScheme(.dark)
    }

    private var top: some View {
        HStack {
            Button { manager.minimized = true } label: {
                Image(systemName: "chevron.down").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(.white.opacity(0.12), in: Circle())
            }
            Spacer()
            VStack(spacing: 2) {
                Text(manager.group?.name ?? "").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(subtitle).font(.system(size: 13).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.top, 6)
    }

    private var subtitle: String {
        if manager.phase == .joining { return s.t("Подключение…", "Connecting…") }
        let n = manager.participants.count
        let people = lang == .ru ? "\(n) \(n == 1 ? "участник" : (2...4).contains(n % 10) && !(12...14).contains(n % 100) ? "участника" : "участников")"
                                 : "\(n) participant\(n == 1 ? "" : "s")"
        guard let start = manager.startedAt else { return people }
        let sec = Int(now.timeIntervalSince(start))
        return people + " · " + String(format: "%d:%02d", sec / 60, sec % 60)
    }

    private var grid: some View {
        let list = manager.participants
        let columns = list.count <= 1 ? 1 : (list.count <= 4 ? 2 : 3)
        return ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(list) { p in tile(p, tall: list.count <= 2) }
            }
        }
        .scrollDisabled(list.count <= 6)
    }

    private func tile(_ p: GroupCallParticipant, tall: Bool) -> some View {
        let track: MeshVideoTrack? = p.me ? (manager.cameraOn ? mesh.localVideo : nil) : (p.video ? mesh.remoteVideos[p.id] : nil)
        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.08))
            if let track {
                RTCVideoView(track: track, mirror: p.me && mesh.usingFront)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                AvatarView(name: p.name, size: tall ? 110 : 70, avatarID: p.avatar).clipShape(Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 5) {
                if p.muted { Image(systemName: "mic.slash.fill").font(.system(size: 11)).foregroundStyle(.red) }
                Text(p.me ? s.t("Вы", "You") : p.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if !p.me && !mesh.connected.contains(p.id) && manager.phase == .active {
                    ProgressView().controlSize(.mini).tint(.white)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(8)
        }
        .aspectRatio(tall ? 0.75 : 1, contentMode: .fit)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            control(manager.cameraOn ? "video.fill" : "video.slash.fill", s.t("Камера", "Camera"), on: manager.cameraOn) {
                manager.cameraOn.toggle()
            }
            if manager.cameraOn {
                control("arrow.triangle.2.circlepath.camera.fill", s.t("Повернуть", "Flip"), on: false) { mesh.flipCamera() }
            }
            control(manager.muted ? "mic.slash.fill" : "mic.fill", s.t("Микрофон", "Mic"), on: !manager.muted) {
                manager.muted.toggle()
            }
            control(manager.speaker ? "speaker.wave.3.fill" : "speaker.fill", s.t("Динамик", "Speaker"), on: manager.speaker) {
                manager.speaker.toggle()
            }
            Button { Haptics.impact(.medium); manager.leave() } label: {
                VStack(spacing: 6) {
                    Image(systemName: "phone.down.fill").font(.system(size: 22)).foregroundStyle(.white)
                        .frame(width: 60, height: 60).background(Color.red, in: Circle())
                    Text(s.t("Выйти", "Leave")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .padding(.bottom, 10)
    }

    private func control(_ icon: String, _ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.impact(.light); action() } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 21)).foregroundStyle(on ? .black : .white)
                    .frame(width: 60, height: 60).background(on ? Color.white : Color.white.opacity(0.16), in: Circle())
                Text(title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
            }
        }
    }
}

/// Свёрнутый групповой звонок: плашка сверху, нажатие разворачивает
struct GroupCallMiniBar: View {
    @ObservedObject var manager: GroupCallManager
    @Environment(\.lang) private var lang

    var body: some View {
        Button { manager.minimized = false } label: {
            HStack(spacing: 10) {
                Image(systemName: manager.cameraOn ? "video.fill" : "phone.fill").foregroundStyle(.white)
                Text(manager.group?.name ?? "").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Text(Strings(lang: lang).t("Вернуться", "Return")).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 16).frame(height: 40)
            .background(Color.green.gradient, in: Capsule())
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
    }
}

/// Плашка в переписке группы: «Идёт видеочат · 3 участника — Присоединиться»
struct GroupCallJoinBanner: View {
    let brief: GroupCallBrief
    let onJoin: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        let s = Strings(lang: lang)
        HStack(spacing: 10) {
            Image(systemName: brief.video ? "video.fill" : "phone.fill").font(.system(size: 15))
                .foregroundStyle(.white).frame(width: 32, height: 32).background(Color.green, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(brief.video ? s.t("Идёт видеочат", "Video chat in progress") : s.t("Идёт групповой звонок", "Group call in progress"))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
                Text(lang == .ru ? "Участников: \(brief.count)" : "\(brief.count) participant\(brief.count == 1 ? "" : "s")")
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Button(action: onJoin) {
                Text(s.t("Войти", "Join")).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 32).background(Color.green, in: Capsule())
            }
            .buttonStyle(PressStyle())
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 10)
    }
}

// MARK: - Окно группового звонка поверх всего приложения

@MainActor
final class GroupCallWindow {
    static let shared = GroupCallWindow()
    private var window: PassthroughWindow?
    private var bag = Set<AnyCancellable>()

    func show(_ manager: GroupCallManager) {
        hideKeyboard()
        if window != nil { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let host = UIHostingController(rootView: GroupCallHost(manager: manager))
        host.view.backgroundColor = .clear
        let w = PassthroughWindow(windowScene: scene)
        w.windowLevel = .alert + 2
        w.backgroundColor = .clear
        w.rootViewController = host
        w.capturesAll = true
        bag.removeAll()
        // свёрнутый звонок — окно сжимается до плашки сверху, остальное приложение доступно
        manager.$minimized.receive(on: DispatchQueue.main).sink { [weak w] m in
            guard let w else { return }
            let b = UIScreen.main.bounds
            if m {
                let top = w.safeAreaInsets.top > 0 ? w.safeAreaInsets.top : 54
                w.frame = CGRect(x: 0, y: 0, width: b.width, height: top + 48)
            } else {
                w.frame = b
            }
        }.store(in: &bag)
        w.isHidden = false
        window = w
    }

    func hide() {
        window?.isHidden = true
        window = nil
        bag.removeAll()
    }
}

private struct GroupCallHost: View {
    @ObservedObject var manager: GroupCallManager

    var body: some View {
        if manager.minimized {
            VStack { GroupCallMiniBar(manager: manager); Spacer(minLength: 0) }
        } else {
            GroupCallScreen(manager: manager).transition(.move(edge: .bottom))
        }
    }
}
