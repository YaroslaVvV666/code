import SwiftUI
import Combine

// MARK: - Скелетоны: серые заглушки с бегущим бликом вместо крутилки

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, Color.white.opacity(theme.dark ? 0.14 : 0.55), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6)
                        .offset(x: phase * g.size.width * 1.6)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(ShimmerModifier()) }
}

struct SkeletonBlock: View {
    var height: CGFloat = 14
    var width: CGFloat? = nil
    var radius: CGFloat = 7
    @Environment(\.theme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(theme.text.opacity(theme.dark ? 0.09 : 0.07))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// Заглушка карточки поста, пока лента грузится
struct FeedSkeleton: View {
    var count = 3

    var body: some View {
        VStack(spacing: 22) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Circle().fill(Color.gray.opacity(0.18)).frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 7) {
                            SkeletonBlock(height: 12, width: 120)
                            SkeletonBlock(height: 10, width: 70)
                        }
                    }
                    SkeletonBlock(height: 12)
                    SkeletonBlock(height: 12, width: 220)
                    SkeletonBlock(height: 200, radius: 16)
                }
                .padding(.horizontal, 16)
            }
        }
        .shimmer()
        .padding(.top, 20)
    }
}


/// Заглушка списка чатов, пока он грузится
struct ChatListSkeleton: View {
    var count = 9

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: 12) {
                    Circle().fill(Color.gray.opacity(0.18)).frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 9) {
                        SkeletonBlock(height: 13, width: CGFloat(110 + (i * 37) % 80))
                        SkeletonBlock(height: 11, width: CGFloat(170 + (i * 53) % 110))
                    }
                    Spacer(minLength: 0)
                    SkeletonBlock(height: 10, width: 34)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .opacity(1 - Double(i) * 0.07)
            }
        }
        .shimmer()
        .padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .transition(.opacity)
    }
}

/// Заглушка сетки медиа (профиль: фото, видео), пока грузится
struct GridSkeleton: View {
    var columns = 3
    var rows = 4
    var spacing: CGFloat = 2

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns), spacing: spacing) {
            ForEach(0..<(columns * rows), id: \.self) { i in
                SkeletonBlock(height: 120, radius: 4)
                    .opacity(1 - Double(i / columns) * 0.15)
            }
        }
        .shimmer()
        .transition(.opacity)
    }
}

/// Пустой экран: значок в мягком круге, заголовок, подсказка и (необязательно) кнопка — один вид для всего приложения
struct EmptyStateView: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    /// На тёмном видео (шортсы) — белые надписи
    var onDark = false
    @Environment(\.theme) private var theme
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(onDark ? Color.white : theme.accentColor)
                .frame(width: 76, height: 76)
                .background(Circle().fill((onDark ? Color.white : theme.accentColor).opacity(0.12)))
                .scaleEffect(appeared ? 1 : 0.85)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(onDark ? Color.white : theme.text)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(onDark ? Color.white.opacity(0.75) : theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 20).frame(height: 40)
                        .background(theme.accent, in: Capsule())
                }
                .buttonStyle(PressStyle())
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 36)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { appeared = true } }
    }
}
