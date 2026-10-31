import SwiftUI

/// Цвета и стили Orbita. Тёмная тема — сдержанная графитово-синяя,
/// светлая — холодный off-white с белыми карточками и мягкими тенями.
/// Акцентный цвет выбирается пользователем (Профиль → Оформление).
struct Theme {
    let dark: Bool
    var accentIndex: Int = 0
    /// Свой цвет акцента (оформление отдельного чата: цвет моих сообщений); nil — из палитры по accentIndex
    var customAccent: ThemeRGB? = nil

    static let accents: [(r: Double, g: Double, b: Double)] = [
        (0.30, 0.46, 0.92),     // синий
        (0.50, 0.40, 0.90),     // фиолетовый
        (0.12, 0.60, 0.68),     // бирюзовый
        (0.22, 0.64, 0.45),     // зелёный
        (0.90, 0.54, 0.20),     // оранжевый
        (0.86, 0.36, 0.58)      // розовый
    ]

    static func swatch(_ index: Int) -> Color {
        let a = accents[min(max(index, 0), accents.count - 1)]
        return Color(red: a.r, green: a.g, blue: a.b)
    }

    private var base: (r: Double, g: Double, b: Double) {
        if let c = customAccent { return (c.r, c.g, c.b) }
        return Self.accents[min(max(accentIndex, 0), Self.accents.count - 1)]
    }

    private func shade(_ delta: Double) -> Color {
        func c(_ v: Double) -> Double { min(1, max(0, v + delta)) }
        return Color(red: c(base.r), green: c(base.g), blue: c(base.b))
    }

    // поверхности
    var surface: Color { dark ? Color.white.opacity(0.07) : Color.white }
    var stroke: Color {
        dark ? Color.white.opacity(0.09) : Color(red: 0.12, green: 0.15, blue: 0.25).opacity(0.08)
    }
    var shadow: Color {
        dark ? Color.clear : Color(red: 0.15, green: 0.20, blue: 0.40).opacity(0.08)
    }
    var bar: Color {
        dark ? Color(red: 0.05, green: 0.06, blue: 0.095).opacity(0.97) : Color.white.opacity(0.97)
    }
    var sheet: Color {
        dark ? Color(red: 0.07, green: 0.08, blue: 0.11) : Color(red: 0.97, green: 0.975, blue: 0.99)
    }

    // текст
    var text: Color {
        dark ? Color.white.opacity(0.94) : Color(red: 0.08, green: 0.10, blue: 0.17)
    }
    var textSecondary: Color {
        dark ? Color.white.opacity(0.58) : Color(red: 0.38, green: 0.42, blue: 0.52)
    }
    var textTertiary: Color {
        dark ? Color.white.opacity(0.36) : Color(red: 0.60, green: 0.64, blue: 0.72)
    }

    // акценты
    var accent: LinearGradient {
        LinearGradient(colors: [shade(dark ? 0.10 : 0.05), shade(dark ? -0.06 : -0.09)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var accentColor: Color { dark ? shade(0.14) : shade(-0.04) }
    var danger: Color { Color(red: 0.90, green: 0.36, blue: 0.38) }
    var like: Color { Color(red: 0.92, green: 0.30, blue: 0.40) }
    var glow: Double { dark ? 0.28 : 0.22 }
}

/// Цвет в долях 0…1 (хранится в настройках чата)
struct ThemeRGB: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var color: Color { Color(red: r, green: g, blue: b) }
}

extension Theme {
    /// Та же тема, но с другим акцентом
    func withAccent(_ rgb: ThemeRGB?) -> Theme {
        guard let rgb else { return self }
        var t = self
        t.customAccent = rgb
        return t
    }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme(dark: true) }
private struct LangKey: EnvironmentKey { static let defaultValue = AppLanguage.ru }

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
    var lang: AppLanguage {
        get { self[LangKey.self] }
        set { self[LangKey.self] = newValue }
    }
}

extension View {
    /// Карточка: стекло (Liquid Glass) на iOS 26, на более старых — полупрозрачная / белая с тенью
    func card(_ theme: Theme, radius: CGFloat = 16) -> some View {
        modifier(CardModifier(theme: theme, radius: radius))
    }
}
