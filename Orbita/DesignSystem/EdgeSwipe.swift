import SwiftUI
import Combine

/// Свайп от левого края вправо — «назад» (как в iOS и Telegram) для экранов с собственной стрелкой назад
struct EdgeSwipeBack: ViewModifier {
    var enabled = true
    var fullWidth = false
    var skipEdge = false          // у края уже работает системный жест — не дублируем
    let action: () -> Void

    func body(content: Content) -> some View {
        // Жест висит на самом экране и срабатывает, только если палец начал у левого края.
        // Раньше поверх экрана лежала невидимая полоска и перехватывала нажатия на стрелку «назад».
        content.simultaneousGesture(
            DragGesture(minimumDistance: 14, coordinateSpace: .global)
                .onEnded { value in
                    guard enabled, fullWidth || value.startLocation.x < 32 else { return }
                    if skipEdge, value.startLocation.x < 30 { return }
                    let dx = value.translation.width, dy = abs(value.translation.height)
                    guard dx > 60, dy < dx * 0.7 else { return }
                    Haptics.impact(.light)
                    action()
                }
        )
    }
}

extension View {
    func edgeSwipeBack(enabled: Bool = true, fullWidth: Bool = false, skipEdge: Bool = false, _ action: @escaping () -> Void) -> some View {
        modifier(EdgeSwipeBack(enabled: enabled, fullWidth: fullWidth, skipEdge: skipEdge, action: action))
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

    /// Свайп вправо с любого места экрана: второй распознаватель управляет тем же системным переходом «назад»
    final class FullPanDelegate: NSObject, UIGestureRecognizerDelegate {
        static let shared = FullPanDelegate()
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view,
                  let nav = view.next as? UINavigationController, nav.viewControllers.count > 1 else { return false }
            let v = pan.velocity(in: view)
            return v.x > 0 && abs(v.x) > abs(v.y) * 1.3
        }
    }

    static let pans = NSMapTable<UINavigationController, UIPanGestureRecognizer>.weakToStrongObjects()

    static func fullPan(for nav: UINavigationController) -> UIPanGestureRecognizer? {
        if let p = pans.object(forKey: nav) { return p }
        guard let edge = nav.interactivePopGestureRecognizer, let host = edge.view,
              let targets = edge.value(forKey: "targets") as? [AnyObject], let first = targets.first,
              let target = first.value(forKey: "target") else { return nil }
        let pan = UIPanGestureRecognizer(target: target, action: NSSelectorFromString("handleNavigationTransition:"))
        pan.maximumNumberOfTouches = 1
        pan.delegate = FullPanDelegate.shared
        host.addGestureRecognizer(pan)
        pans.setObject(pan, forKey: nav)
        return pan
    }

    var fullScreen = false

    final class Controller: UIViewController {
        var fullScreen = false
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attach()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard fullScreen, let nav = navigationController ?? view.parentNavigation else { return }
            PopGestureEnabler.pans.object(forKey: nav)?.isEnabled = false
            nav.interactivePopGestureRecognizer?.isEnabled = true
        }
        private func attach() {
            guard let nav = navigationController ?? view.parentNavigation else { return }
            nav.interactivePopGestureRecognizer?.isEnabled = true
            nav.interactivePopGestureRecognizer?.delegate = Delegate.shared
            if fullScreen, nav.viewControllers.count > 1, let pan = PopGestureEnabler.fullPan(for: nav) {
                pan.isEnabled = true
                nav.interactivePopGestureRecognizer?.isEnabled = false       // чтобы два жеста не вели один переход
            }
        }
    }

    func makeUIViewController(context: Context) -> Controller {
        let c = Controller(); c.fullScreen = fullScreen; return c
    }
    func updateUIViewController(_ vc: Controller, context: Context) { vc.fullScreen = fullScreen }
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
    func swipeBackEnabled(fullScreen: Bool = false) -> some View {
        background(PopGestureEnabler(fullScreen: fullScreen).frame(width: 0, height: 0))
    }
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
        let had = UserDefaults.standard.data(forKey: key(chat)) != nil
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(chat))
            if had { ChatDraftSignal.bump() }
        } else if let data = try? JSONEncoder().encode(Draft(text: text, entities: entities)) {
            UserDefaults.standard.set(data, forKey: key(chat))
            // сигнал — только когда черновик появился: на каждую букву список чатов под открытым чатом не перерисовываем
            // (сам текст обновится в строке при выходе из чата — там тоже сигнал)
            if !had { ChatDraftSignal.bump() }
        }
    }

    static func load(chat: String) -> (text: String, entities: [TextEntity])? {
        guard let data = UserDefaults.standard.data(forKey: key(chat)),
              let d = try? JSONDecoder().decode(Draft.self, from: data) else { return nil }
        return (d.text, d.entities)
    }

    static func text(chat: String) -> String? { load(chat: chat)?.text }
}

/// Черновик появился, изменился или пропал — список чатов сразу перерисовывает строку «Черновик: …»
/// (сами черновики лежат в UserDefaults, и без сигнала список узнавал о них только при следующем обновлении с сервера)
final class ChatDraftSignal: ObservableObject {
    static let shared = ChatDraftSignal()
    @Published private(set) var version = 0

    static func bump() {
        if Thread.isMainThread { shared.version += 1 } else { DispatchQueue.main.async { shared.version += 1 } }
    }
}
