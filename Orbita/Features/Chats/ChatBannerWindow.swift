import SwiftUI
import UIKit

// MARK: - Окно поверх всего приложения (баннер «новое сообщение»)

/// Отдельное окно над всеми sheet / fullScreenCover: баннер виден, даже если открыт чей-то профиль.
/// Пропускает касания сквозь себя, пока не показан предпросмотр.
final class PassthroughWindow: UIWindow {
    var capturesAll = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let view = super.hitTest(point, with: event) else { return nil }
        if capturesAll { return view }
        return view === rootViewController?.view ? nil : view
    }
}

@MainActor
final class BannerWindowController {
    static let shared = BannerWindowController()
    private var window: PassthroughWindow?
    private var host: UIHostingController<AnyView>?

    func install(_ root: AnyView) {
        if let host { host.rootView = root; return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        let controller = UIHostingController(rootView: root)
        controller.view.backgroundColor = .clear
        let w = PassthroughWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.backgroundColor = .clear
        w.rootViewController = controller
        w.isHidden = false
        window = w
        host = controller
    }

    func capture(_ on: Bool) { window?.capturesAll = on }

    func remove() {
        window?.isHidden = true
        window = nil
        host = nil
    }

    /// Закрыть всё открытое поверх главного экрана (профиль, шторки) перед переходом в чат
    static func dismissPresented() {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for w in windows where !(w is PassthroughWindow) {
            w.rootViewController?.dismiss(animated: true)
        }
    }
}

/// Невидимая вставка в иерархию: держит окно баннера и обновляет его тему / язык
struct BannerWindowInstaller: UIViewRepresentable {
    let chats: ChatsModel
    let theme: Theme
    let lang: AppLanguage
    let onOpen: (ChatPeer) -> Void

    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ uiView: UIView, context: Context) {
        let root = AnyView(
            ChatBannerHost(chats: chats, onOpen: onOpen)
                .environment(\.theme, theme).environment(\.lang, lang)
                .preferredColorScheme(theme.dark ? .dark : .light)
        )
        DispatchQueue.main.async { BannerWindowController.shared.install(root) }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        DispatchQueue.main.async { BannerWindowController.shared.remove() }
    }
}

// MARK: - Сам баннер + предпросмотр по долгому нажатию

struct ChatBannerHost: View {
    @ObservedObject var chats: ChatsModel
    let onOpen: (ChatPeer) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var previewing: ChatBanner?
    @State private var pressed = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        ZStack(alignment: .top) {
            if previewing != nil {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { closePreview() }
                    .transition(.opacity)
            }
            VStack(spacing: 10) {
                if let banner = chats.banner {
                    bannerCard(banner)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: banner.id) {
                            try? await Task.sleep(nanoseconds: 4_500_000_000)
                            while pressed { try? await Task.sleep(nanoseconds: 300_000_000) }
                            if previewing == nil, chats.banner?.id == banner.id { chats.banner = nil }
                        }
                }
                if previewing != nil { previewCard.transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity)) }
                Spacer()
            }
            .padding(.top, 6)
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.84), value: chats.banner)
        .animation(.spring(response: 0.38, dampingFraction: 0.84), value: previewing)
        .onChange(of: previewing) { _, v in BannerWindowController.shared.capture(v != nil) }
    }

    private func bannerCard(_ banner: ChatBanner) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: banner.peer.name, size: 40, avatarID: banner.peer.avatarID).clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(banner.peer.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Text(banner.text).font(.system(size: 14)).foregroundStyle(theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .scaleEffect(pressed ? 0.97 : 1)
        .padding(.horizontal, 12)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            chats.banner = nil
            BannerWindowController.dismissPresented()
            onOpen(banner.peer)
        }
        // зажать — посмотреть, что написали, не отмечая прочитанным
        .onLongPressGesture(minimumDuration: 0.35, pressing: { pressed = $0 }) {
            Haptics.impact(.medium)
            openPreview(banner)
        }
        .simultaneousGesture(DragGesture(minimumDistance: 18).onEnded { v in
            if v.translation.height < -12 { chats.banner = nil }
        })
    }

    private func openPreview(_ banner: ChatBanner) { previewing = banner }

    private func closePreview() {
        previewing = nil
        chats.banner = nil
    }

    private var previewCard: some View {
        let banner = previewing
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                AvatarView(name: banner?.peer.name ?? "", size: 34, avatarID: banner?.peer.avatarID).clipShape(Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(banner?.peer.name ?? "").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                    Text(s.t("Предпросмотр · не прочитано", "Preview · stays unread"))
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Button { closePreview() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.textSecondary)
                        .frame(width: 30, height: 30).glassCircle()
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            if let peer = banner?.peer {
                ChatPreviewBody(peer: peer, repo: chats.repo, maxHeight: 360)
            }

            Button {
                if let peer = banner?.peer {
                    closePreview()
                    BannerWindowController.dismissPresented()
                    onOpen(peer)
                }
            } label: {
                Text(s.t("Открыть чат", "Open chat")).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(theme.accent, in: Capsule())
            }
            .buttonStyle(PressStyle())
            .padding(14)
        }
        .glass(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 12)
    }
}
