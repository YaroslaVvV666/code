import SwiftUI

// MARK: - Liquid Glass
// На iOS 26 и Xcode 26 используется системное стекло (glassEffect).
// На более старых системах — материал с тонкой световой каймой, выглядит похоже.

private struct GlassModifier<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?
    var interactive: Bool
    @Environment(\.theme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(effect, in: shape)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private var effect: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
    #endif

    private func fallback(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .background((tint ?? .clear).opacity(0.25), in: shape)
            .overlay(
                shape.stroke(LinearGradient(colors: [Color.white.opacity(theme.dark ? 0.26 : 0.95),
                                                     Color.white.opacity(theme.dark ? 0.04 : 0.30)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing),
                             lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(theme.dark ? 0.28 : 0.08), radius: 14, y: 5)
    }
}

/// Карточка по умолчанию: стекло на iOS 26, прежний вид на старых системах
struct CardModifier: ViewModifier {
    let theme: Theme
    let radius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .shadow(color: theme.shadow, radius: 10, y: 3)
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    private func legacy(_ content: Content) -> some View {
        content
            .background(theme.dark ? Color.white.opacity(0.07) : Color.white, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(LinearGradient(colors: [Color.white.opacity(theme.dark ? 0.16 : 0.9), theme.stroke],
                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: theme.shadow, radius: 12, y: 4)
    }
}

extension View {
    /// Явное стекло для кнопок, плашек и подписей
    func glass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassModifier(shape: shape, tint: tint, interactive: interactive))
    }

    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        glass(Capsule(), tint: tint, interactive: interactive)
    }

    func glassCircle(tint: Color? = nil, interactive: Bool = true) -> some View {
        glass(Circle(), tint: tint, interactive: interactive)
    }
}
