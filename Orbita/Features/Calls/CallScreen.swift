import Combine
import SwiftUI

// MARK: - Окно звонка поверх всего приложения

@MainActor
final class CallWindowController {
    static let shared = CallWindowController()
    private var window: PassthroughWindow?
    private var bag = Set<AnyCancellable>()

    func show(_ manager: CallManager) {
        hideKeyboard()
        if window != nil { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let host = UIHostingController(rootView: CallScreen(manager: manager))
        host.view.backgroundColor = .clear
        let w = PassthroughWindow(windowScene: scene)
        w.windowLevel = .alert + 2
        w.backgroundColor = .clear
        w.rootViewController = host
        w.capturesAll = true
        bag.removeAll()
        // Свёрнутый звонок: окно сжимается до плашки сверху по центру и целиком ловит нажатия — плашка всегда поверх всего,
        // а всё остальное экрана (кнопки «назад», «Изм.» и т.д.) остаётся доступным
        w.capturesAll = true
        manager.$minimized.receive(on: DispatchQueue.main).sink { [weak w] m in
            guard let w else { return }
            let b = UIScreen.main.bounds
            if m {
                let top = w.safeAreaInsets.top > 0 ? w.safeAreaInsets.top : 54
                let width: CGFloat = 220
                w.frame = CGRect(x: (b.width - width) / 2, y: 0, width: width, height: top + 56)
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
    }
}

// MARK: - Экран звонка (как в Telegram)

struct CallScreen: View {
    @ObservedObject var manager: CallManager
    @ObservedObject private var engine: RTCEngine
    @Environment(\.lang) private var lang
    @State private var swapped = false
    @State private var tileOffset: CGSize = .zero
    @State private var tileDrag: CGSize = .zero

    init(manager: CallManager) {
        self.manager = manager
        _engine = ObservedObject(wrappedValue: manager.engine)
    }

    private var peer: ChatPeer { manager.peer ?? ChatPeer(id: "", name: "") }
    private var showsVideo: Bool { manager.video && (manager.phase == .active || (manager.phase == .connecting && engine.remoteVideo != nil)) }
    private var incoming: Bool { manager.phase == .incoming }
    /// Пока звоним по видео — на весь экран показываем своё изображение, как в Telegram
    private var selfPreview: Bool { manager.video && manager.cameraOn && (manager.phase == .outgoing || manager.phase == .connecting) }

    private var canMinimize: Bool { manager.phase == .active || manager.phase == .connecting || manager.phase == .outgoing }
    /// Большое изображение — собеседник; по нажатию на плитку можно поменять местами
    private var localBig: Bool { swapped && manager.cameraOn }

    var body: some View {
        if manager.minimized && canMinimize {
            miniBar
        } else {
            full
        }
    }

    private var miniBar: some View {
        VStack {
            Button { Haptics.impact(.light); withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { manager.minimized = false } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "phone.fill").font(.system(size: 13, weight: .bold))
                    Text(peer.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(manager.phase == .active ? mmss(manager.elapsed) : status)
                        .font(.system(size: 14, weight: .medium)).monospacedDigit().opacity(0.9)
                    if manager.video {
                        Image(systemName: "video.slash.fill").font(.system(size: 12)).opacity(0.8)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16).frame(height: 36).frame(maxWidth: 212)
                .background(Color.green.opacity(0.92), in: Capsule())
                .contentShape(Capsule())
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var full: some View {
        ZStack {
            background
            if showsVideo {
                RTCVideoView(track: localBig ? engine.localVideo : engine.remoteVideo,
                             mirror: localBig && engine.usingFront && !engine.sharing).ignoresSafeArea()
                LinearGradient(colors: [.black.opacity(0.45), .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea().allowsHitTesting(false)
            }
            if selfPreview {
                RTCVideoView(track: engine.localVideo, mirror: engine.usingFront).ignoresSafeArea()
                LinearGradient(colors: [.black.opacity(0.5), .clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea().allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                header.padding(.top, 70)
                if !showsVideo && !selfPreview {
                    AvatarView(name: peer.name, size: 150, avatarID: peer.avatarID).clipShape(Circle())
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
                        .padding(.top, 54)
                        .scaleEffect(manager.phase == .active ? 1 : 1.0)
                }
                Spacer()
                controls.padding(.bottom, 54)
            }
            if showsVideo && manager.cameraOn {
                GeometryReader { geo in
                    RTCVideoView(track: localBig ? engine.remoteVideo : engine.localVideo,
                                 mirror: !localBig && engine.usingFront && !engine.sharing)
                        .frame(width: 104, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
                        .shadow(radius: 10)
                        .offset(x: tileOffset.width + tileDrag.width, y: tileOffset.height + tileDrag.height)
                        .onTapGesture { Haptics.impact(.light); withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { swapped.toggle() } }
                        .gesture(DragGesture()
                            .onChanged { tileDrag = $0.translation }
                            .onEnded { v in
                                let w = geo.size.width, h = geo.size.height
                                // базовая позиция — правый верхний угол (x: w-120, y: 60)
                                let x = (w - 120) + tileOffset.width + v.translation.width + 52
                                let y = 60 + tileOffset.height + v.translation.height + 75
                                let right = x > w / 2, bottom = y > h / 2
                                let target = CGSize(width: right ? 0 : -(w - 120 - 16),
                                                    height: bottom ? h - 150 - 190 - 60 : 0)
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                                    tileOffset = target; tileDrag = .zero
                                }
                            })
                        .position(x: geo.size.width - 120 + 52, y: 60 + 75)
                }
            }
            if canMinimize {
                VStack {
                    HStack {
                        Button { Haptics.impact(.light); withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { manager.minimized = true } } label: {
                            Image(systemName: "chevron.down").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 40, height: 40).background(Color.white.opacity(0.16), in: Circle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.leading, 16).padding(.top, 60)
                    Spacer()
                }
            }
            if engine.sharing {
                VStack {
                    Label(Strings(lang: lang).t("Вы показываете экран", "You are sharing your screen"), systemImage: "rectangle.on.rectangle")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Color.red.opacity(0.85), in: Capsule())
                        .padding(.top, 8)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            if manager.video, !engine.debug.isEmpty, manager.phase != .incoming {
                VStack { Spacer(); Text(engine.debug).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 20).allowsHitTesting(false) }
            }
            if let error = manager.errorText {
                VStack { ToastView(text: error).padding(.top, 60); Spacer() }
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.3), value: manager.phase)
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.16, blue: 0.34), Color(red: 0.22, green: 0.10, blue: 0.36),
                                    Color(red: 0.07, green: 0.07, blue: 0.14)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let id = peer.avatarID, !showsVideo {
                RemoteImage(id: id).blur(radius: 70).opacity(0.35).scaleEffect(1.5)
            }
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(peer.name).font(.system(size: 32, weight: .bold)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 30)
            Text(status).font(.system(size: 18)).foregroundStyle(.white.opacity(0.75)).monospacedDigit()
            if manager.phase == .active || manager.phase == .connecting {
                Label(Strings(lang: lang).t("Сквозное шифрование", "End-to-end encrypted"), systemImage: "lock.fill")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).padding(.top, 2)
            }
        }
    }

    private var status: String {
        let s = Strings(lang: lang)
        switch manager.phase {
        case .outgoing: return s.t("Вызов…", "Calling…")
        case .incoming: return manager.video ? s.t("Входящий видеозвонок", "Incoming video call") : s.t("Входящий звонок", "Incoming call")
        case .connecting: return s.t("Соединение…", "Connecting…")
        case .active: return mmss(manager.elapsed)
        case .ended: return manager.endText
        case .idle: return ""
        }
    }

    @ViewBuilder
    private var controls: some View {
        if incoming {
            HStack(spacing: 70) {
                bigButton("phone.down.fill", title: Strings(lang: lang).t("Отклонить", "Decline"), color: .red) { manager.decline() }
                bigButton(manager.video ? "video.fill" : "phone.fill", title: Strings(lang: lang).t("Принять", "Accept"), color: .green) { manager.accept() }
            }
        } else if manager.phase == .ended {
            EmptyView()
        } else {
            VStack(spacing: 28) {
                HStack(spacing: 12) {
                    round(manager.video ? (manager.cameraOn ? "video.fill" : "video.slash.fill") : "video.fill",
                          title: Strings(lang: lang).t("Видео", "Video"), on: manager.video && manager.cameraOn,
                          enabled: manager.video) { manager.cameraOn.toggle() }
                    round(manager.speaker ? "speaker.wave.3.fill" : "speaker.fill",
                          title: Strings(lang: lang).t("Динамик", "Speaker"), on: manager.speaker) { manager.speaker.toggle() }
                    round(manager.muted ? "mic.slash.fill" : "mic.fill",
                          title: Strings(lang: lang).t("Микрофон", "Mute"), on: manager.muted) { manager.muted.toggle() }
                    if manager.video && manager.phase == .active {
                        round(engine.sharing ? "rectangle.inset.filled.on.rectangle" : "rectangle.on.rectangle",
                              title: Strings(lang: lang).t("Экран", "Screen"), on: engine.sharing) { manager.toggleShare() }
                    }
                    if manager.video && !engine.sharing {
                        round("camera.rotate.fill", title: Strings(lang: lang).t("Камера", "Flip"), on: false) { engine.flipCamera() }
                    }
                }
                bigButton("phone.down.fill", title: nil, color: .red) { manager.hangUp() }
            }
        }
    }

    private func round(_ icon: String, title: String, on: Bool, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.impact(.light); action() }) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(on ? Color.black : Color.white)
                    .frame(width: 58, height: 58)
                    .background(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.16)), in: Circle())
                Text(title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
            }
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func bigButton(_ icon: String, title: String?, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.impact(.medium); action() }) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 28, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 74, height: 74).background(color, in: Circle())
                    .shadow(color: color.opacity(0.5), radius: 14, y: 4)
                if let title { Text(title).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85)) }
            }
        }
        .buttonStyle(PressStyle())
    }
}
