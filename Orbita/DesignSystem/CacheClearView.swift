import SwiftUI

/// Очистка кэша: мусор по орбите втягивается в планету, счётчик идёт до 100%
struct CacheClearView: View {
    let freedBytes: Int
    let onFinish: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var start = Date()
    @State private var finished = false

    private let duration = 2.8
    private let count = 44
    private var s: Strings { Strings(lang: lang) }

    private func progress(_ t: Date) -> Double {
        let x = min(1, max(0, t.timeIntervalSince(start) / duration))
        return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2   // easeInOut
    }

    var body: some View {
        ZStack {
            theme.sheet.ignoresSafeArea()
            if theme.dark { StarField().ignoresSafeArea().opacity(0.8) }

            VStack(spacing: 30) {
                TimelineView(.animation) { timeline in
                    let p = progress(timeline.date)
                    VStack(spacing: 26) {
                        scene(p: p, time: timeline.date.timeIntervalSinceReferenceDate)
                            .frame(width: 280, height: 220)

                        VStack(spacing: 6) {
                            Text(p >= 1 ? s.cacheCleared : s.cacheClearing)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(theme.text)
                            if p >= 1 {
                                Text("\(s.cacheFreed): \(ByteCountFormatter.string(fromByteCount: Int64(freedBytes), countStyle: .file))")
                                    .font(.system(size: 15))
                                    .foregroundStyle(theme.textSecondary)
                                    .transition(.opacity)
                            } else {
                                Text("\(Int((p * 100).rounded()))%")
                                    .font(.system(size: 34, weight: .light).monospacedDigit())
                                    .foregroundStyle(theme.accentColor)
                            }
                        }
                        .frame(height: 70)
                    }
                    .onChange(of: p >= 1) { _, done in
                        guard done, !finished else { return }
                        finished = true
                        Haptics.notify(.success)
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            onFinish()
                        }
                    }
                }
            }
        }
        .onAppear { start = Date() }
    }

    private func scene(p: Double, time t: Double) -> some View {
        Canvas { ctx, size in
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: .degrees(-22))

            let ringColor = Color(red: 0.62, green: 0.72, blue: 0.92)
            // орбиты
            for (i, rx) in [118.0, 94.0].enumerated() {
                let rect = CGRect(x: -rx, y: -rx * 0.34, width: rx * 2, height: rx * 0.68)
                ctx.stroke(Path(ellipseIn: rect), with: .color(ringColor.opacity(i == 0 ? 0.28 : 0.14)), lineWidth: 1)
            }

            // мусор, втягиваемый в планету
            var g = SeededGenerator(seed: 77)
            for i in 0..<count {
                let baseR = Double.random(in: 62...122, using: &g)
                let speed = Double.random(in: 0.5...1.1, using: &g) * (i % 2 == 0 ? 1 : -1)
                let phase = Double.random(in: 0...(2 * .pi), using: &g)
                let dotSize = Double.random(in: 1.2...3.2, using: &g)
                let begin = 0.06 + 0.78 * Double(i) / Double(count)
                let q = min(1, max(0, (p - begin) / 0.16))
                if q >= 1 { continue }

                let r = baseR * (1 - q * q)
                let theta = phase + t * speed * (1 + q * 2.5)
                let pos = CGPoint(x: r * cos(theta), y: r * 0.34 * sin(theta))
                let d = dotSize * (1 - q * 0.7)
                ctx.opacity = 0.95 - q * 0.4
                ctx.fill(Path(ellipseIn: CGRect(x: pos.x - d / 2, y: pos.y - d / 2, width: d, height: d)),
                         with: .color(i % 5 == 0 ? Color(red: 0.75, green: 0.70, blue: 0.95) : ringColor))
                ctx.opacity = 1
            }

            // планета
            let absorbed = p
            let pulse = p >= 1 ? 1.0 + 0.05 * sin((t * 6).truncatingRemainder(dividingBy: .pi * 2)) : 1.0
            let radius = (24 + 4 * absorbed) * pulse
            let glow = CGRect(x: -radius * 2.2, y: -radius * 2.2, width: radius * 4.4, height: radius * 4.4)
            ctx.fill(Path(ellipseIn: glow),
                     with: .radialGradient(Gradient(colors: [Color(red: 0.40, green: 0.50, blue: 0.85).opacity(0.18 + 0.2 * absorbed), .clear]),
                                           center: .zero, startRadius: 0, endRadius: radius * 2.2))
            ctx.fill(Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)),
                     with: .radialGradient(Gradient(colors: [Color(red: 0.58, green: 0.62, blue: 0.88),
                                                             Color(red: 0.32, green: 0.36, blue: 0.70),
                                                             Color(red: 0.10, green: 0.12, blue: 0.30)]),
                                           center: CGPoint(x: -radius * 0.4, y: -radius * 0.5),
                                           startRadius: 0, endRadius: radius * 1.9))

            // прогресс: дуга вокруг планеты
            ctx.rotate(by: .degrees(22))
            var arc = Path()
            arc.addArc(center: .zero, radius: radius + 9, startAngle: .degrees(-90),
                       endAngle: .degrees(-90 + 360 * p), clockwise: false)
            ctx.stroke(arc, with: .color(Color.white.opacity(0.75)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

            // финальная волна
            if p >= 1 {
                let w = min(1, (t - floor(t)) )   // лёгкое дыхание кольца
                let wr = radius + 14 + 10 * w
                ctx.stroke(Path(ellipseIn: CGRect(x: -wr, y: -wr, width: wr * 2, height: wr * 2)),
                           with: .color(ringColor.opacity(0.4 * (1 - w))), lineWidth: 1)
            }
        }
    }
}
