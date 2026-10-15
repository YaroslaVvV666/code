import SwiftUI

/// Свайп от левого края вправо — «назад» (как в iOS и Telegram) для экранов с собственной стрелкой назад
struct EdgeSwipeBack: ViewModifier {
    var enabled = true
    let action: () -> Void

    func body(content: Content) -> some View {
        // Жест висит на самом экране и срабатывает, только если палец начал у левого края.
        // Раньше поверх экрана лежала невидимая полоска и перехватывала нажатия на стрелку «назад».
        content.simultaneousGesture(
            DragGesture(minimumDistance: 14, coordinateSpace: .global)
                .onEnded { value in
                    guard enabled, value.startLocation.x < 32 else { return }
                    let dx = value.translation.width, dy = abs(value.translation.height)
                    guard dx > 60, dy < dx * 0.7 else { return }
                    Haptics.impact(.light)
                    action()
                }
        )
    }
}

extension View {
    func edgeSwipeBack(enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        modifier(EdgeSwipeBack(enabled: enabled, action: action))
    }
}

/// Системный свайп «назад» от левого края для экранов, где скрыта навигационная панель
/// (без этого iOS отключает жест, и из чата можно выйти только кнопкой)
struct PopGestureEnabler: UIViewControllerRepresentable {
    final class Delegate: NSObject, UIGestureRecognizerDelegate {
        static let shared = Delegate()
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let nav = (gestureRecognizer.view?.next as? UINavigationController)
                    ?? gestureRecognizer.view?.parentNavigation else { return true }
            return nav.viewControllers.count > 1
        }
    }

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attach()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        private func attach() {
            guard let nav = navigationController ?? view.parentNavigation else { return }
            nav.interactivePopGestureRecognizer?.isEnabled = true
            nav.interactivePopGestureRecognizer?.delegate = Delegate.shared
        }
    }

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ vc: Controller, context: Context) {}
}

private extension UIView {
    var parentNavigation: UINavigationController? {
        var r: UIResponder? = self
        while let n = r?.next {
            if let nav = n as? UINavigationController { return nav }
            r = n
        }
        return nil
    }
}

extension View {
    func swipeBackEnabled() -> some View { background(PopGestureEnabler().frame(width: 0, height: 0)) }
}

/// Спрятать клавиатуру
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

/// Черновики переписок: набранное, но не отправленное, хранится на телефоне и возвращается при следующем заходе
enum ChatDraftStore {
    private struct Draft: Codable { var text: String; var entities: [TextEntity] }
    private static func key(_ chat: String) -> String { "chat.draft." + chat }

    static func save(chat: String, text: String, entities: [TextEntity]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(chat))
        } else if let data = try? JSONEncoder().encode(Draft(text: text, entities: entities)) {
            UserDefaults.standard.set(data, forKey: key(chat))
        }
    }

    static func load(chat: String) -> (text: String, entities: [TextEntity])? {
        guard let data = UserDefaults.standard.data(forKey: key(chat)),
              let d = try? JSONDecoder().decode(Draft.self, from: data) else { return nil }
        return (d.text, d.entities)
    }

    static func text(chat: String) -> String? { load(chat: chat)?.text }
}
