import SwiftUI
import UIKit

/// Большая плашка поверх всего приложения: «Этот файл нарушает правила». Закрывается кнопкой «Я понял».
/// Показывается, когда сервер отклонил загрузку после проверки нейросетью (ошибка content_blocked).
@MainActor
enum ContentNotice {
    private static var window: UIWindow?

    static func show() {
        if window != nil { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        hideKeyboard()
        Haptics.notify(.warning)
        let lang = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "lang") ?? "") ?? .ru
        let dark = UserDefaults.standard.object(forKey: "isDark") as? Bool ?? true
        let host = UIHostingController(rootView: ContentNoticeCard(lang: lang, dark: dark) { hide() })
        host.view.backgroundColor = .clear
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 3                    // выше экрана звонка, шторок и камеры
        w.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        window = w
    }

    static func hide() {
        window?.isHidden = true
        window = nil
    }
}

private struct ContentNoticeCard: View {
    let lang: AppLanguage
    let dark: Bool
    let onClose: () -> Void
    @State private var shown = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.62 : 0).ignoresSafeArea()
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.orange.opacity(0.18)).frame(width: 76, height: 76)
                    Image(systemName: "hand.raised.fill").font(.system(size: 32, weight: .semibold)).foregroundStyle(.orange)
                }
                Text(s.t("Этот файл нарушает наши правила", "This file breaks our rules"))
                    .font(.system(size: 21, weight: .bold)).multilineTextAlignment(.center)
                Text(s.t("Мы не публикуем изображения и видео с обнажённым телом и другим запрещённым содержимым. Файл не загружен.",
                         "We don't allow nudity or other prohibited content. The file was not uploaded."))
                    .font(.system(size: 15)).multilineTextAlignment(.center)
                    .foregroundStyle(dark ? Color.white.opacity(0.7) : Color.black.opacity(0.6))
                Button(action: onClose) {
                    Text(s.t("Я понял", "Got it"))
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(Theme(dark: dark, accentIndex: UserDefaults.standard.integer(forKey: "accent")).accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .foregroundStyle(dark ? Color.white : Color.black)
            .padding(24)
            .frame(maxWidth: 340)
            .background(dark ? Color(white: 0.13) : Color.white, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
            .padding(.horizontal, 28)
            .scaleEffect(shown ? 1 : 0.88)
            .opacity(shown ? 1 : 0)
        }
        .onAppear { withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { shown = true } }
    }
}
