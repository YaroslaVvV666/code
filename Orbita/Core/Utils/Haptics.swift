import UIKit

/// Вибрации приложения. Один общий выключатель: Профиль → «Вибрация».
enum Haptics {
    static let key = "haptics.enabled"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// Генераторы переиспользуются: новый на каждое нажатие сначала «будит» Taptic Engine, и отклик запаздывает
    private static var generators: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]

    private static func generator(_ style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        if let g = generators[style] { return g }
        let g = UIImpactFeedbackGenerator(style: style)
        generators[style] = g
        return g
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard enabled else { return }
        // общий кэш генераторов — только с главного потока
        guard Thread.isMainThread else { DispatchQueue.main.async { impact(style) }; return }
        generator(style).impactOccurred()
    }

    /// Заранее подготовить отклик, который вот-вот понадобится (палец лёг на сообщение — скоро сработает зажатие)
    static func prepare(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard enabled, Thread.isMainThread else { return }
        generator(style).prepare()
    }

    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    static func select() {
        guard enabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
