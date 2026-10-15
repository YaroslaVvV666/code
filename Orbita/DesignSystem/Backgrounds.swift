import SwiftUI

// MARK: - Фон

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct StarField: View {
    private struct Star {
        let x, y, r, phase, speed, bright, driftX, driftY, driftSpeed: Double
        let glints: Bool
    }

    private let stars: [Star] = {
        var g = SeededGenerator(seed: 2024)
        return (0..<95).map { i in
            Star(x: Double.random(in: 0...1, using: &g),
                 y: Double.random(in: 0...1, using: &g),
                 r: Double.random(in: 0.3...1.15, using: &g),
                 phase: Double.random(in: 0...(2 * .pi), using: &g),
                 speed: Double.random(in: 0.35...1.5, using: &g),
                 bright: Double.random(in: 0.28...0.85, using: &g),
                 driftX: Double.random(in: 2...7, using: &g),
                 driftY: Double.random(in: 1.5...5, using: &g),
                 driftSpeed: Double.random(in: 0.03...0.09, using: &g),
                 glints: i % 11 == 0)
        }
    }()

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                for star in stars {
                    // неровное мерцание: две несинхронные волны + редкие вспышки
                    let wave = 0.6 + 0.4 * sin(t * star.speed + star.phase) * sin(t * star.speed * 0.37 + star.phase * 1.7)
                    let flash = pow(max(0, sin(t * 0.21 * star.speed + star.phase * 3)), 28)
                    let level = min(1, star.bright * (0.55 + 0.45 * wave) + flash * 0.5)

                    // медленный дрейф
                    let cx = star.x * size.width + sin(t * star.driftSpeed + star.phase) * star.driftX
                    let cy = star.y * size.height + cos(t * star.driftSpeed * 0.8 + star.phase) * star.driftY
                    let r = star.r * (1 + flash * 0.4)

                    context.opacity = level
                    context.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                                 with: .color(.white))

                    if star.glints && flash > 0.25 {
                        let l = 5 + 7 * flash
                        context.opacity = flash * 0.55
                        var cross = Path()
                        cross.move(to: CGPoint(x: cx - l, y: cy)); cross.addLine(to: CGPoint(x: cx + l, y: cy))
                        cross.move(to: CGPoint(x: cx, y: cy - l)); cross.addLine(to: CGPoint(x: cx, y: cy + l))
                        context.stroke(cross, with: .color(.white), lineWidth: 0.5)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Редкие кометы: тонкий угасающий след, без «мультяшной» головы
struct CometLayer: View {
    private let slot = 8.0

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let n = Int(floor(t / slot))
                for k in [n - 1, n] {
                    var g = SeededGenerator(seed: UInt64(bitPattern: Int64(k)) &* 7919 &+ 31)
                    guard Double.random(in: 0...1, using: &g) < 0.55 else { continue }
                    let delay = Double.random(in: 0...4, using: &g)
                    let dur = Double.random(in: 2.6...4.2, using: &g)
                    let p = (t - (Double(k) * slot + delay)) / dur
                    guard p >= 0, p <= 1 else { continue }

                    let angle = Double.random(in: 22...38, using: &g) * .pi / 180
                    let leftward = Bool.random(using: &g)
                    let dir = CGPoint(x: (leftward ? -1 : 1) * cos(angle), y: sin(angle))
                    let sx = Double.random(in: leftward ? 0.45...1.1 : -0.1...0.55, using: &g) * size.width
                    let sy = Double.random(in: -0.05...0.3, using: &g) * size.height
                    let travel = Double.random(in: 0.6...0.95, using: &g) * size.width
                    let tail = Double.random(in: 110...190, using: &g)

                    let env = min(1, p * 5) * min(1, (1 - p) * 3.5) * 0.75
                    let head = CGPoint(x: sx + dir.x * travel * p, y: sy + dir.y * travel * p)

                    let steps = 30
                    for i in 0..<steps {
                        let f0 = Double(i) / Double(steps), f1 = Double(i + 1) / Double(steps)
                        var seg = Path()
                        seg.move(to: CGPoint(x: head.x - dir.x * tail * f0, y: head.y - dir.y * tail * f0))
                        seg.addLine(to: CGPoint(x: head.x - dir.x * tail * f1, y: head.y - dir.y * tail * f1))
                        let fade = pow(1 - f0, 2.2)
                        ctx.stroke(seg,
                                   with: .color(Color(red: 0.80, green: 0.87, blue: 1.0).opacity(fade * env)),
                                   style: StrokeStyle(lineWidth: 1.5 * (1 - f0) + 0.3, lineCap: .round))
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: head.x - 7, y: head.y - 7, width: 14, height: 14)),
                             with: .radialGradient(Gradient(colors: [Color.white.opacity(0.4 * env), .clear]),
                                                   center: head, startRadius: 0, endRadius: 7))
                    ctx.fill(Path(ellipseIn: CGRect(x: head.x - 1.1, y: head.y - 1.1, width: 2.2, height: 2.2)),
                             with: .color(Color.white.opacity(env)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct SpaceBackground: View {
    let isDark: Bool
    var showStars = true

    var body: some View {
        ZStack {
            // тёмная: графит с лёгкой синевой
            LinearGradient(colors: [Color(red: 0.03, green: 0.035, blue: 0.06),
                                    Color(red: 0.055, green: 0.065, blue: 0.10)],
                           startPoint: .top, endPoint: .bottom)
                .opacity(isDark ? 1 : 0)

            RadialGradient(colors: [Color(red: 0.25, green: 0.35, blue: 0.60).opacity(0.14), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 380)
                .opacity(isDark ? 1 : 0)
            RadialGradient(colors: [Color(red: 0.30, green: 0.25, blue: 0.50).opacity(0.10), .clear],
                           center: .bottomLeading, startRadius: 0, endRadius: 440)
                .opacity(isDark ? 1 : 0)

            StarField().opacity(isDark && showStars ? 1 : 0)
            if isDark && showStars { CometLayer().transition(.opacity) }

            // светлая: холодный off-white с еле заметным свечением
            LinearGradient(colors: [Color(red: 0.965, green: 0.972, blue: 0.988),
                                    Color(red: 0.925, green: 0.935, blue: 0.965)],
                           startPoint: .top, endPoint: .bottom)
                .opacity(isDark ? 0 : 1)

            RadialGradient(colors: [Color(red: 0.45, green: 0.55, blue: 0.95).opacity(0.16), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 420)
                .opacity(isDark ? 0 : 1)
            RadialGradient(colors: [Color(red: 0.70, green: 0.62, blue: 0.95).opacity(0.10), .clear],
                           center: .bottomLeading, startRadius: 0, endRadius: 460)
                .opacity(isDark ? 0 : 1)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: isDark)
        .animation(.easeInOut(duration: 0.5), value: showStars)
    }
}

// MARK: - Логотип «Orbita»

struct OrbitLogo: View {
    var size: CGFloat = 150
    /// Белый шарик независимо от темы (для тёмных картинок)
    var forceDarkTheme = false

    @Environment(\.theme) private var theme

    private let ringA = Color(red: 0.62, green: 0.72, blue: 0.92)
    private let ringB = Color(red: 0.72, green: 0.66, blue: 0.90)

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let theta = (t / 7).truncatingRemainder(dividingBy: 1) * 2 * .pi
            let a = size * 0.5
            let b = size * 0.17
            let k = size / 150
            let x = a * cos(theta)
            let y = b * sin(theta)
            let isFront = sin(theta) > 0
            let darkBall = forceDarkTheme || theme.dark
            // шарик прячется, только когда он на дальней стороне И перекрыт самой планетой
            let behindPlanet = !isFront && hypot(x, y) < size * 0.25 + size * 0.05

            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 0.40, green: 0.50, blue: 0.85).opacity(0.22), .clear],
                                         center: .center, startRadius: 0, endRadius: size * 0.65))
                    .frame(width: size * 1.3, height: size * 1.3)

                ZStack {
                    ringView(a: a, b: b, lineWidth: 4 * k, front: false)
                    ringView(a: a * 0.82, b: b * 0.82, lineWidth: max(0.6, 1.2 * k), front: false)

                    if behindPlanet { satellite(x: x, y: y, dark: darkBall) }

                    planet

                    ringView(a: a, b: b, lineWidth: 4 * k, front: true)
                    ringView(a: a * 0.82, b: b * 0.82, lineWidth: max(0.6, 1.2 * k), front: true)

                    // во всех остальных случаях шарик летит поверх колец
                    if !behindPlanet { satellite(x: x, y: y, dark: darkBall) }
                }
                .rotationEffect(.degrees(-22))
            }
            .frame(width: size * 1.3, height: size * 1.3)
        }
    }

    private var planet: some View {
        let d = size * 0.5
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(red: 0.58, green: 0.62, blue: 0.88),
                                              Color(red: 0.32, green: 0.36, blue: 0.70),
                                              Color(red: 0.10, green: 0.12, blue: 0.30)],
                                     center: UnitPoint(x: 0.3, y: 0.25),
                                     startRadius: 0, endRadius: d * 0.95))

            VStack(spacing: 0) {
                Spacer()
                Rectangle().fill(Color.white.opacity(0.10)).frame(height: d * 0.07)
                Spacer().frame(height: d * 0.10)
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: d * 0.12)
                Spacer().frame(height: d * 0.08)
                Rectangle().fill(Color.black.opacity(0.12)).frame(height: d * 0.07)
                Spacer()
            }
            .frame(width: d, height: d)
            .mask(Circle())

            Circle()
                .fill(LinearGradient(colors: [.clear, Color.black.opacity(0.5)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))

            Circle()
                .stroke(LinearGradient(colors: [Color.white.opacity(0.45), .clear],
                                       startPoint: .topLeading, endPoint: .center),
                        lineWidth: max(0.6, size / 100))
        }
        .frame(width: d, height: d)
        .shadow(color: Color(red: 0.4, green: 0.5, blue: 0.9).opacity(0.3), radius: size / 15)
    }

    @ViewBuilder
    private func ringView(a: CGFloat, b: CGFloat, lineWidth: CGFloat, front: Bool) -> some View {
        let gradient = LinearGradient(colors: [ringA, ringB], startPoint: .leading, endPoint: .trailing)
        if front {
            Ellipse()
                .trim(from: 0, to: 0.5)
                .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .frame(width: a * 2, height: b * 2)
        } else {
            Ellipse()
                .stroke(gradient, lineWidth: lineWidth)
                .opacity(0.3)
                .frame(width: a * 2, height: b * 2)
        }
    }

    /// Тёмная тема — жемчужно-белый шарик, светлая — чёрный глянцевый (оникс) с бликом
    private func satellite(x: CGFloat, y: CGFloat, dark: Bool) -> some View {
        let d: CGFloat = size * 0.1
        let pearl: [Color] = [Color.white, Color(red: 0.84, green: 0.87, blue: 0.96)]
        let onyx: [Color] = [Color(red: 0.42, green: 0.44, blue: 0.52),
                             Color(red: 0.08, green: 0.08, blue: 0.11),
                             Color.black]
        let fill = RadialGradient(colors: dark ? pearl : onyx,
                                  center: dark ? UnitPoint(x: 0.35, y: 0.3) : UnitPoint(x: 0.32, y: 0.28),
                                  startRadius: 0,
                                  endRadius: dark ? d * 0.8 : d * 0.85)
        let glintOpacity: Double = dark ? 0 : 0.85
        let glintSize: CGFloat = d * 0.2
        let shadowColor: Color = dark ? Color.white.opacity(0.6) : Color.black.opacity(0.35)
        let shadowRadius: CGFloat = size / 40
        let shadowY: CGFloat = dark ? 0 : size / 150

        let glint = Circle()
            .fill(Color.white.opacity(glintOpacity))
            .frame(width: glintSize, height: glintSize)
            .offset(x: -d * 0.18, y: -d * 0.2)

        let ball = Circle()
            .fill(fill)
            .frame(width: d, height: d)
            .overlay(glint)
            .shadow(color: shadowColor, radius: shadowRadius, y: shadowY)

        return ball.offset(x: x, y: y)
    }
}

// MARK: - Переключатель темы

struct ThemeToggle: View {
    @Binding var isDark: Bool

    var body: some View {
        Button {
            Haptics.impact(.soft)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.68)) { isDark.toggle() }
        } label: {
            ZStack {
                Capsule()
                    .fill(isDark
                          ? LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.18),
                                                    Color(red: 0.14, green: 0.13, blue: 0.24)],
                                           startPoint: .leading, endPoint: .trailing)
                          : LinearGradient(colors: [Color(red: 0.60, green: 0.78, blue: 1.0),
                                                    Color(red: 0.84, green: 0.92, blue: 1.0)],
                                           startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().stroke(Color.white.opacity(isDark ? 0.14 : 0.7), lineWidth: 1))

                HStack {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(isDark ? 0.4 : 0))
                    Spacer()
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(isDark ? 0 : 0.9))
                }
                .padding(.horizontal, 9)

                Circle()
                    .fill(isDark ? Color(red: 0.85, green: 0.88, blue: 0.96) : Color.white)
                    .frame(width: 26, height: 26)
                    .overlay(
                        Image(systemName: isDark ? "moon.fill" : "sun.max.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(isDark ? Color(red: 0.25, green: 0.28, blue: 0.60) : Color.orange)
                            .contentTransition(.symbolEffect(.replace))
                    )
                    .shadow(color: Color.black.opacity(0.22), radius: 3, y: 1)
                    .offset(x: isDark ? 15 : -15)
            }
            .frame(width: 62, height: 32)
        }
        .buttonStyle(.plain)
    }
}
