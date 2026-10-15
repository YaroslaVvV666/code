import UIKit

/// Вибрации приложения. Один общий выключатель: Профиль → «Вибрация».
enum Haptics {
    static let key = "haptics.enabled"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
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
