import SwiftUI
import Combine
import UIKit

/// Короткая подсказка поверх всего приложения (ответ бота на нажатие кнопки, «Сохранено» и т.п.); касания проходят сквозь неё
@MainActor
enum AppToast {
    private static var window: UIWindow?
    private static var hideTask: Task<Void, Never>?

    static func show(_ text: String, icon: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let host = UIHostingController(rootView: AppToastView(text: text, icon: icon))
        host.view.backgroundColor = .clear
        let w = window ?? UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.backgroundColor = .clear
        w.isUserInteractionEnabled = false
        w.rootViewController = host
        w.isHidden = false
        window = w
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(min(5, 1.6 + Double(text.count) / 30) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            window?.isHidden = true
            window = nil
        }
    }
}

private struct AppToastView: View {
    let text: String
    let icon: String?
    @State private var shown = false

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white) }
                Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.leading).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : -16)
            Spacer()
        }
        .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { shown = true } }
    }
}

/// Системные окна поверх текущего экрана — без привязки к конкретному View
@MainActor
enum AppAlert {
    private static var top: UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }

    static func info(_ title: String?, _ message: String, ok: String = "OK") {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: ok, style: .default))
        top?.present(a, animated: true)
    }

    static func confirm(_ title: String, _ message: String, ok: String, cancel: String, action: @escaping () -> Void) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: cancel, style: .cancel))
        a.addAction(UIAlertAction(title: ok, style: .default) { _ in action() })
        a.preferredAction = a.actions.last
        top?.present(a, animated: true)
    }
}
