import SwiftUI
import Combine
import UIKit

// MARK: - Дни рождения
// В списке чатов — строка «🎂 Сегодня день рождения у …» (в общей карточке с играющей песней и голосовым).
// Нажатие — профиль именинника: хлопушки с конфетти каждый раз, когда его открываешь, и 🎂 у даты рождения.

/// Именинник из контактов
struct BirthdayPerson: Identifiable, Equatable, Decodable {
    let id: String
    let name: String
    let username: String?
    let avatar: String?
    let age: Int?
}

enum BirthdayCalc {
    /// «MM-dd» сегодняшнего дня по часам телефона
    static var todayKey: String { FormatterCache.format(Date(), "MM-dd", locale: Locale(identifier: "en_US_POSIX")) }

    /// День рождения сегодня? Дата — «1999-05-17» или «--05-17»
    static func isToday(_ value: String?) -> Bool {
        guard let value, value.count >= 5 else { return false }
        return String(value.suffix(5)) == todayKey
    }

    /// Сколько исполняется (если год указан)
    static func age(_ value: String?) -> Int? {
        guard let value, value.count == 10, !value.hasPrefix("--"), let y = Int(value.prefix(4)) else { return nil }
        return Calendar.current.component(.year, from: Date()) - y
    }
}

@MainActor
final class BirthdayStore: ObservableObject {
    static let shared = BirthdayStore()

    @Published private(set) var people: [BirthdayPerson] = []
    /// Строку закрыли крестиком — до завтра не показываем
    @Published private(set) var dismissedDay: String = UserDefaults.standard.string(forKey: "birthdays.dismissed") ?? ""
    private var loadedDay = ""
    private var loadedAt = Date.distantPast

    var visible: [BirthdayPerson] { dismissedDay == BirthdayCalc.todayKey ? [] : people }

    func refresh(repo: MessengerRepository) async {
        let day = BirthdayCalc.todayKey
        // раз в полчаса хватает; новый день — сразу
        guard day != loadedDay || Date().timeIntervalSince(loadedAt) > 1800 else { return }
        guard let list = try? await repo.birthdays(today: day) else { return }
        loadedDay = day
        loadedAt = Date()
        if list != people { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { people = list } }
    }

    func dismiss() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dismissedDay = BirthdayCalc.todayKey }
        UserDefaults.standard.set(dismissedDay, forKey: "birthdays.dismissed")
    }
}

/// Строка в верхней карточке списка чатов
struct BirthdayIslandRow: View {
    let people: [BirthdayPerson]
    var onOpen: (BirthdayPerson) -> Void
    var onClose: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var wiggle = false
    private var s: Strings { Strings(lang: lang) }

    private var title: String {
        guard let first = people.first else { return "" }
        if people.count == 1 { return first.name }
        if people.count == 2 { return first.name + s.t(" и ", " and ") + people[1].name }
        return first.name + s.t(" и ещё \(people.count - 1)", " and \(people.count - 1) more")
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if let first = people.first { Haptics.impact(.light); onOpen(first) }
            } label: {
                HStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        // до трёх аватарок внахлёст
                        HStack(spacing: -12) {
                            ForEach(people.prefix(3)) { p in
                                AvatarView(name: p.name, size: 34, avatarID: p.avatar).clipShape(Circle())
                                    .overlay(Circle().stroke(theme.sheet, lineWidth: 2))
                            }
                        }
                        Text("🎂").font(.system(size: 15))
                            .rotationEffect(.degrees(wiggle ? 10 : -10))
                            .offset(x: 6, y: 4)
                    }
                    .padding(.leading, 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.t("Сегодня день рождения", "Birthday today"))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.accentColor)
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if people.count > 1 {
                // несколько именинников — меню со всеми
                Menu {
                    ForEach(people) { p in
                        Button { onOpen(p) } label: {
                            Text(p.name + (p.age.map { s.t(" — \($0)", " — \($0)") } ?? ""))
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textSecondary).frame(width: 36, height: 52).contentShape(Rectangle())
                }
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textSecondary).frame(width: 44, height: 52).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .frame(height: 56)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { wiggle = true }
        }
    }
}

/// Значок у даты рождения в профиле (как в Telegram): 🎂, в сам день — покачивается
struct BirthdayBadge: View {
    let today: Bool
    @State private var bob = false

    var body: some View {
        Text(today ? "🎂" : "🎁")
            .font(.system(size: 24))
            .rotationEffect(.degrees(today && bob ? 12 : (today ? -12 : 0)))
            .scaleEffect(today && bob ? 1.12 : 1)
            .frame(width: 44, height: 44)
            .onAppear {
                guard today else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { bob = true }
            }
    }
}

// MARK: - Хлопушки

/// Хлопушки поверх всего экрана: из нижних углов вылетает конфетти и мягко падает. Нажатия проходят насквозь
@MainActor
enum ConfettiWindow {
    private static var window: UIWindow?
    private static var hideTask: Task<Void, Never>?

    static func fire() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        hideTask?.cancel()
        window?.isHidden = true
        let host = UIHostingController(rootView: ConfettiBurst(seed: UInt64.random(in: 1...UInt64.max)))
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.backgroundColor = .clear
        w.isUserInteractionEnabled = false
        w.rootViewController = host
        w.isHidden = false
        window = w
        Haptics.notify(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Haptics.impact(.medium) }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            guard !Task.isCancelled else { return }
            window?.isHidden = true
            window = nil
        }
    }
}

private struct ConfettiPiece {
    var x: CGFloat; var y: CGFloat          // старт в долях экрана
    var vx: CGFloat; var vy: CGFloat        // точек в секунду
    var spin: Double; var phase: Double
    var size: CGFloat; var color: Color; var round: Bool
    var delay: Double
}

struct ConfettiBurst: View {
    let seed: UInt64
    @State private var start = Date()
    @State private var pop = false

    private static let colors: [Color] = [
        Color(red: 1, green: 0.27, blue: 0.38), Color(red: 1, green: 0.75, blue: 0.1), Color(red: 0.25, green: 0.78, blue: 0.45),
        Color(red: 0.27, green: 0.55, blue: 1), Color(red: 0.7, green: 0.4, blue: 1), Color(red: 1, green: 0.5, blue: 0.2), .white
    ]

    private var pieces: [ConfettiPiece] {
        var rng = SplitMix(seed: seed)
        return (0..<150).map { i in
            let left = i % 2 == 0                                      // две хлопушки: слева и справа снизу
            let angle = Double.pi / 2 + (left ? -1 : 1) * rng.next(0.15, 0.75)   // вверх и к центру
            let speed = rng.next(900, 1500)
            return ConfettiPiece(x: left ? 0.04 : 0.96, y: 0.98,
                                 vx: CGFloat(cos(angle) * speed) * (left ? 1 : 1), vy: CGFloat(-sin(angle) * speed),
                                 spin: rng.next(-9, 9), phase: rng.next(0, 6.28),
                                 size: CGFloat(rng.next(6, 12)), color: Self.colors[Int(rng.next(0, Double(Self.colors.count) - 0.01))],
                                 round: rng.next(0, 1) < 0.3, delay: rng.next(0, 0.18))
        }
    }

    var body: some View {
        let list = pieces
        GeometryReader { g in
            ZStack {
                TimelineView(.animation) { tl in
                    let t = tl.date.timeIntervalSince(start)
                    Canvas { ctx, size in
                        for p in list {
                            let tt = t - p.delay
                            guard tt > 0 else { continue }
                            // полёт с сопротивлением воздуха и гравитацией, потом лёгкое покачивание при падении
                            let drag = 1.6
                            let k = (1 - exp(-drag * tt)) / drag
                            let x = p.x * size.width + p.vx * CGFloat(k) + CGFloat(sin(tt * 3 + p.phase) * 14 * min(1, tt))
                            let y = p.y * size.height + p.vy * CGFloat(k) + CGFloat(0.5 * 520 * tt * tt * 0.55)
                            guard y < size.height + 30 else { continue }
                            let fade = max(0, min(1, (3.6 - tt) / 0.8))
                            var c = ctx
                            c.opacity = fade
                            c.translateBy(x: x, y: y)
                            c.rotate(by: .radians(p.spin * tt))
                            // плоская бумажка «переворачивается» — меняется видимая ширина
                            let w = p.size * CGFloat(abs(cos(tt * 5 + p.phase))) + 1
                            let rect = CGRect(x: -w / 2, y: -p.size / 2, width: w, height: p.size * (p.round ? 1 : 0.55))
                            c.fill(p.round ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 1.5), with: .color(p.color))
                        }
                    }
                }
                // сами хлопушки в углах: «бах» и исчезают
                Text("🎉").font(.system(size: 54))
                    .scaleEffect(x: -1, y: 1)
                    .scaleEffect(pop ? 1 : 0.2)
                    .opacity(pop ? 0 : 1)
                    .position(x: 44, y: g.size.height - 70)
                Text("🎉").font(.system(size: 54))
                    .scaleEffect(pop ? 1 : 0.2)
                    .opacity(pop ? 0 : 1)
                    .position(x: g.size.width - 44, y: g.size.height - 70)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            start = Date()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { pop = false }
            withAnimation(.easeOut(duration: 1.1).delay(0.25)) { pop = true }
        }
    }
}

/// Детерминированный генератор: у одного залпа — одна раскладка конфетти на все кадры
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextRaw() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * Double(nextRaw() >> 11) / Double(1 << 53)
    }
}
