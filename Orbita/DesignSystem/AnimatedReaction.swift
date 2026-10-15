import SwiftUI

/// Эмодзи реакции с «живой» анимацией: при появлении подпрыгивает с покачиванием,
/// а когда ставите свою реакцию — из неё вылетает стайка таких же эмодзи (как в Telegram)
struct AnimatedReactionEmoji: View {
    let emoji: String
    let mine: Bool
    let count: Int

    @State private var scale: CGFloat = 0.2
    @State private var tilt: Double = -25
    @State private var particles: [Particle] = []
    @State private var big = false

    struct Particle: Identifiable {
        let id = UUID()
        let dx: CGFloat
        let rise: CGFloat
        let size: CGFloat
        let spin: Double
    }

    var body: some View {
        LottieEmojiView(emoji: emoji, size: 20)
            .scaleEffect(scale)
            .rotationEffect(.degrees(tilt))
            .overlay {
                ZStack {
                    ForEach(particles) { p in
                        FloatingEmoji(emoji: emoji, particle: p)
                    }
                    // крупная анимация над сообщением, как в Telegram
                    if big {
                        LottieEmojiView(emoji: emoji, size: 96) { withAnimation(.easeOut(duration: 0.3)) { big = false } }
                            .offset(y: -64)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .allowsHitTesting(false)
            }
            .onAppear { pop(big: false) }
            .onChange(of: mine) { _, now in if now { pop(big: true) } }
            .onChange(of: count) { old, new in if new > old { pop(big: false) } }
    }

    private func pop(big: Bool) {
        scale = 0.3
        tilt = Bool.random() ? -22 : 22
        withAnimation(.spring(response: 0.36, dampingFraction: 0.42)) {
            scale = big ? 1.35 : 1
            tilt = 0
        }
        if big {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.22)) { scale = 1 }
        }
    }

    private func burst() {
        let batch = (0..<7).map { _ in
            Particle(dx: CGFloat.random(in: -34...34), rise: CGFloat.random(in: 44...90),
                     size: CGFloat.random(in: 11...20), spin: Double.random(in: -50...50))
        }
        particles = batch
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { big = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            withAnimation { big = false }
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            particles = []
        }
    }
}

private struct FloatingEmoji: View {
    let emoji: String
    let particle: AnimatedReactionEmoji.Particle
    @State private var go = false

    var body: some View {
        Text(emoji)
            .font(.system(size: particle.size))
            .offset(x: go ? particle.dx : 0, y: go ? -particle.rise : 0)
            .scaleEffect(go ? 0.6 : 1)
            .rotationEffect(.degrees(go ? particle.spin : 0))
            .opacity(go ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 0.95)) { go = true } }
    }
}
