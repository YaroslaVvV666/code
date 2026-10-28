import SwiftUI

/// Глобальная настройка устройства: показывать ли чувствительный контент без размытия.
enum SensitiveContent {
    private static let key = "orbita.sensitive.alwaysShow"
    static var alwaysShow: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Накладывает размытие и плашку «Показать» на 18+/чувствительный контент.
/// Снимается на один конкретный пост (локально) или глобально в настройках.
struct SensitiveGate<Content: View>: View {
    let sensitive: Bool
    var compact = false                       // мелкая плашка (для сетки/превью)
    @ViewBuilder var content: () -> Content

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var revealed = false

    private var s: Strings { Strings(lang: lang) }
    private var hidden: Bool { sensitive && !revealed && !SensitiveContent.alwaysShow }

    var body: some View {
        content()
            .overlay {
                if hidden {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        Rectangle().fill(Color.black.opacity(0.28))
                        VStack(spacing: compact ? 4 : 10) {
                            Image(systemName: "eye.trianglebadge.exclamationmark.fill")
                                .font(.system(size: compact ? 20 : 30, weight: .medium))
                                .foregroundStyle(.white)
                            if !compact {
                                Text(s.t("Чувствительный контент", "Sensitive content"))
                                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                Text(s.t("Может быть не для всех", "May not be suitable for everyone"))
                                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                            }
                            Button {
                                Haptics.impact(.light)
                                withAnimation(.easeOut(duration: 0.2)) { revealed = true }
                            } label: {
                                Text(s.t("Показать", "Show"))
                                    .font(.system(size: compact ? 12 : 14, weight: .semibold)).foregroundStyle(.black)
                                    .padding(.horizontal, compact ? 12 : 18).frame(height: compact ? 28 : 36)
                                    .background(Color.white, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(8)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 16, style: .continuous))
                    .transition(.opacity)
                }
            }
            // пока скрыто — не даём нажимать/проигрывать то, что под размытием
            .allowsHitTesting(true)
            .disabled(false)
    }
}
