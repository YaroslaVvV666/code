import SwiftUI

/// Красивый вылет эмодзи по жесту: крупный «герой» в центре подпрыгивает и тает, а вокруг разлетается
/// россыпь таких же эмодзи — с разбросом, вращением, гравитацией и затуханием. Рисуется через Canvas,
/// поэтому десятки частиц идут плавно. Накладывается поверх кружка во время записи.
struct GestureBurstOverlay: View {
    @ObservedObject var detector: HandGestureDetector
    @State private var bursts: [Burst] = []

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                let now = timeline.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    for burst in bursts {
                        draw(burst, now: now, size: size, ctx: &ctx)
                    }
                }
                .allowsHitTesting(false)
                .onChange(of: timeline.date) { _, _ in
                    // убираем отжившие вспышки
                    if bursts.contains(where: { now - $0.born > Burst.life }) {
                        bursts.removeAll { now - $0.born > Burst.life }
                    }
                }
            }
            .onChange(of: detector.hit?.id) { _, _ in
                guard let hit = detector.hit else { return }
                bursts.append(Burst(effect: hit.effect, center: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2),
                                    radius: min(geo.size.width, geo.size.height)))
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ burst: Burst, now: TimeInterval, size: CGSize, ctx: inout GraphicsContext) {
        let t = now - burst.born
        guard t >= 0, t <= Burst.life else { return }

        // «Герой» — крупный эмодзи: быстрый упругий поп, лёгкое покачивание, затем уплывает вверх и тает
        let heroIn = min(1, t / 0.22)
        let heroScale = heroPop(heroIn) * (1.0 + 0.04 * sin(t * 9))
        let heroRise = -CGFloat(t * t) * 60
        let heroAlpha = t < Burst.life * 0.6 ? 1 : 1 - (t - Burst.life * 0.6) / (Burst.life * 0.4)
        drawEmoji(burst.effect, at: CGPoint(x: burst.center.x, y: burst.center.y + heroRise),
                  size: 64 * heroScale, angle: 0, alpha: heroAlpha, glow: true, ctx: &ctx)

        // Россыпь: разлёт с гравитацией, вращением и затуханием
        for p in burst.particles {
            let pt = CGPoint(x: burst.center.x + p.vx * CGFloat(t) * 60,
                             y: burst.center.y + p.vy * CGFloat(t) * 60 + 0.5 * 320 * CGFloat(t * t))
            let appear = min(1, t / 0.12)
            let alpha = appear * max(0, 1 - t / Burst.life)
            drawEmoji(burst.effect, at: pt, size: p.size, angle: p.spin * t, alpha: alpha, glow: false, ctx: &ctx)
        }
    }

    private func drawEmoji(_ emoji: String, at point: CGPoint, size: CGFloat, angle: Double, alpha: Double,
                           glow: Bool, ctx: inout GraphicsContext) {
        guard alpha > 0.01, size > 1 else { return }
        let resolved = ctx.resolve(Text(emoji).font(.system(size: size)))
        ctx.drawLayer { layer in
            layer.opacity = alpha
            layer.translateBy(x: point.x, y: point.y)
            if angle != 0 { layer.rotate(by: .radians(angle)) }
            if glow { layer.addFilter(.shadow(color: .white.opacity(0.5), radius: 8)) }
            layer.draw(resolved, at: .zero, anchor: .center)
        }
    }

    /// Упругая кривая появления: перелёт и возврат к 1
    private func heroPop(_ x: Double) -> Double {
        let c = 1.70158 + 1
        let p = x - 1
        return 1 + c * p * p * p + 1.70158 * p * p
    }
}

private struct Burst: Identifiable {
    let id = UUID()
    let effect: String
    let center: CGPoint
    let born = Date().timeIntervalSinceReferenceDate
    let particles: [Particle]
    static let life: TimeInterval = 1.7

    init(effect: String, center: CGPoint, radius: CGFloat) {
        self.effect = effect
        self.center = center
        var ps: [Particle] = []
        for _ in 0..<16 {
            let angle = Double.random(in: 0..<(2 * .pi))
            let speed = CGFloat.random(in: 1.6...3.6)
            // чуть вверх охотнее, чем вниз — смотрится живее
            let vy = CGFloat(sin(angle)) * speed - CGFloat.random(in: 0.4...1.4)
            ps.append(Particle(vx: CGFloat(cos(angle)) * speed, vy: vy,
                               size: CGFloat.random(in: 18...34), spin: Double.random(in: -5...5)))
        }
        self.particles = ps
    }
}

private struct Particle {
    let vx: CGFloat
    let vy: CGFloat
    let size: CGFloat
    let spin: Double
}
