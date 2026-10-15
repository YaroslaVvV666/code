import SwiftUI

/// Эффект реакции на весь экран: крупная анимированная эмодзи по центру,
/// вокруг неё искры, а снизу вверх вылетает стайка таких же эмодзи (как в Telegram и Max)
struct ReactionFX: Identifiable, Equatable {
    let id = UUID()
    let emoji: String
    var messageID: String = ""
}

/// Положение сообщений на экране (экранные координаты): эффект реакции вылетает прямо из нужного сообщения
struct MessageFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

final class MessageFrameStore {
    var frames: [String: CGRect] = [:]
}

struct ReactionEffectLayer: View {
    let fx: ReactionFX
    var origin: () -> CGPoint? = { nil }   // откуда вылетает: значок реакции; нет — по центру экрана
    let onDone: () -> Void

    private struct Item {
        let dx: CGFloat
        let sway: CGFloat
        let rise: CGFloat
        let size: CGFloat
        let delay: Double
        let life: Double
        let phase: Double
        let angle: Double
        let spark: Bool
    }

    private let items: [Item]
    @State private var start = Date().addingTimeInterval(0.12)     // чуть ждём, пока значок реакции встанет на место

    init(fx: ReactionFX, origin: @escaping () -> CGPoint? = { nil }, onDone: @escaping () -> Void) {
        self.fx = fx
        self.origin = origin
        self.onDone = onDone
        var list: [Item] = []
        for _ in 0..<14 {
            list.append(Item(dx: .random(in: -48...48), sway: .random(in: 3...9), rise: .random(in: 50...120),
                             size: .random(in: 11...21), delay: .random(in: 0...0.25), life: .random(in: 0.8...1.3),
                             phase: .random(in: 0...6.28), angle: 0, spark: false))
        }
        for i in 0..<7 {
            list.append(Item(dx: .random(in: 26...48), sway: 0, rise: 0, size: .random(in: 9...14),
                             delay: .random(in: 0...0.12), life: .random(in: 0.5...0.8), phase: 0,
                             angle: Double(i) / 7 * 6.283 + .random(in: -0.25...0.25), spark: true))
        }
        items = list
    }

    /// Точка вылета, прижатая к экрану, чтобы эффект не уезжал за край
    private func anchor(_ size: CGSize) -> CGPoint {
        guard let o = origin() else { return CGPoint(x: size.width / 2, y: size.height * 0.55) }
        return CGPoint(x: min(max(o.x, 30), size.width - 30), y: min(max(o.y, 130), size.height - 90))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                TimelineView(.animation) { tl in
                    let t = tl.date.timeIntervalSince(start)
                    ZStack {
                        ForEach(items.indices, id: \.self) { i in
                            particle(items[i], t: t, size: geo.size)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            onDone()
        }
    }

    @ViewBuilder
    private func particle(_ item: Item, t: Double, size: CGSize) -> some View {
        let age = t - item.delay
        let p = CGFloat(age / item.life)
        if age > 0, p < 1 {
            let fadeIn = min(1, p / 0.12)
            let fadeOut = p > 0.7 ? (1 - p) / 0.3 : 1
            let alpha = Double(fadeIn * fadeOut)
            if item.spark {
                let eased = 1 - (1 - p) * (1 - p)
                let a = anchor(size)
                let cx = a.x + CGFloat(cos(item.angle)) * item.dx * eased
                let cy = a.y + CGFloat(sin(item.angle)) * item.dx * eased
                Text("✨").font(.system(size: item.size))
                    .scaleEffect(0.5 + 0.8 * (1 - abs(p - 0.4)))
                    .opacity(alpha)
                    .position(x: cx, y: cy)
            } else {
                let eased = 1 - (1 - p) * (1 - p)
                let a = anchor(size)
                let x = a.x + item.dx * (0.3 + 0.7 * eased) + item.sway * CGFloat(sin(item.phase + Double(p) * 7))
                let y = a.y - item.rise * eased
                Text(fx.emoji).font(.system(size: item.size))
                    .scaleEffect(0.5 + 0.6 * min(1, p * 4))
                    .rotationEffect(.degrees(Double(item.dx) * 0.12 * Double(p)))
                    .opacity(alpha)
                    .position(x: x, y: y)
            }
        }
    }
}
