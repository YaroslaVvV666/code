import SwiftUI
import Combine
import MapKit
import CoreLocation
import UIKit

// MARK: - Капсула времени и секрет на расстоянии
// Капсула: сообщение откроется у собеседника в выбранный момент — до этого он видит только запечатанную капсулу с таймером.
// Секрет: откроется, только когда собеседник придёт в нужное место (сервер проверяет расстояние).

/// Открыть секрет на месте: возвращает результат (открыт / далеко на N метров / ошибка)
enum UnlockOutcome: Equatable { case opened, tooFar(Int), failed(String) }

private struct UnlockSecretKey: EnvironmentKey {
    static let defaultValue: ((ChatMessage, GeoPoint) async -> UnlockOutcome)? = nil
}

extension EnvironmentValues {
    var unlockSecret: ((ChatMessage, GeoPoint) async -> UnlockOutcome)? {
        get { self[UnlockSecretKey.self] }
        set { self[UnlockSecretKey.self] = newValue }
    }
}

/// Какие замки этот телефон видел закрытыми — чтобы при открытии один раз проиграть «распечатывание»
@MainActor
final class SealedMemory: ObservableObject {
    static let shared = SealedMemory()
    private var seen: Set<String>
    private var revealed: Set<String>
    private let seenKey = "orbita.sealed.seen", revealedKey = "orbita.sealed.revealed"

    private init() {
        seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        revealed = Set(UserDefaults.standard.stringArray(forKey: revealedKey) ?? [])
    }

    func markSeen(_ id: String) {
        guard !seen.contains(id) else { return }
        seen.insert(id)
        UserDefaults.standard.set(Array(seen.suffix(500)), forKey: seenKey)
    }

    func shouldReveal(_ id: String) -> Bool { seen.contains(id) && !revealed.contains(id) }

    func markRevealed(_ id: String) {
        revealed.insert(id)
        UserDefaults.standard.set(Array(revealed.suffix(500)), forKey: revealedKey)
    }
}

// MARK: - Запечатанное сообщение у получателя

struct LockedBubble: View {
    let message: ChatMessage
    let lock: MessageLock
    let mine: Bool

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.unlockSecret) private var unlock
    @StateObject private var fetcher = LocationFetcher()
    @State private var checking = false
    @State private var note: String?
    @State private var wobble = false
    @State private var shake: CGFloat = 0

    private var s: Strings { Strings(lang: lang) }
    private var textColor: Color { mine ? .white : theme.text }
    private var secondary: Color { mine ? Color.white.opacity(0.75) : theme.textSecondary }
    /// Сейчас ждём время (капсула) или место (секрет)
    private var waitingTime: Bool { !lock.timeOK }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(LinearGradient(colors: waitingTime
                                                 ? [Color(red: 0.98, green: 0.72, blue: 0.25), Color(red: 0.93, green: 0.42, blue: 0.2)]
                                                 : [Color(red: 0.3, green: 0.75, blue: 0.5), Color(red: 0.12, green: 0.55, blue: 0.62)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: waitingTime ? "hourglass" : "mappin.and.ellipse")
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                        .rotationEffect(.degrees(waitingTime && wobble ? 180 : 0))
                        .offset(y: !waitingTime && wobble ? -2 : 1)
                }
                .frame(width: 50, height: 50)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                .onAppear {
                    withAnimation(.easeInOut(duration: waitingTime ? 2.4 : 0.9).repeatForever(autoreverses: !waitingTime)) { wobble = true }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(waitingTime ? s.t("Капсула времени", "Time capsule") : s.t("Секрет на месте", "Secret at a place"))
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(textColor)
                    Text(waitingTime ? s.t("Запечатано — откроется само", "Sealed — opens by itself")
                                     : s.t("Откроется, когда вы будете там", "Opens when you're there"))
                        .font(.system(size: 13)).foregroundStyle(secondary)
                }
            }

            if waitingTime, let at = lock.openAt {
                // обратный отсчёт до открытия
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Self.countdown(to: at, now: ctx.date, s))
                            .font(.system(size: 22, weight: .heavy).monospacedDigit()).foregroundStyle(textColor)
                            .contentTransition(.numericText())
                        Text(s.t("откроется ", "opens ") + FormatterCache.format(at, "d MMMM yyyy, HH:mm",
                                                                                    locale: Locale(identifier: lang == .ru ? "ru_RU" : "en_US")))
                            .font(.system(size: 12)).foregroundStyle(secondary)
                    }
                }
                if lock.isPlace {
                    Label(s.t("А потом — ещё и на месте", "Then also at a place"), systemImage: "mappin")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(secondary)
                }
            } else if let place = lock.place {
                VStack(alignment: .leading, spacing: 4) {
                    Label(place.title?.isEmpty == false ? place.title! : s.t("Точка на карте", "A spot on the map"), systemImage: "mappin.circle.fill")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(textColor)
                    Text(s.t("в радиусе \(Int(lock.radius)) м", "within \(Int(lock.radius)) m") + distanceText(place))
                        .font(.system(size: 12)).foregroundStyle(secondary)
                }
                if !mine {
                    HStack(spacing: 8) {
                        Button(action: tryUnlock) {
                            HStack(spacing: 6) {
                                if checking { ProgressView().tint(.white).scaleEffect(0.8) }
                                Text(s.t("Я на месте — открыть", "I'm here — open")).font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 36)
                            .background(Color(red: 0.2, green: 0.62, blue: 0.5), in: Capsule())
                        }
                        .buttonStyle(PressStyle())
                        .disabled(checking)
                        .modifier(ShakeEffect(amount: shake))
                        Button { route(place) } label: {
                            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill").font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(textColor).frame(width: 36, height: 36)
                                .background(textColor.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                if let note {
                    Text(note).font(.system(size: 12, weight: .medium)).foregroundStyle(mine ? .white : theme.danger)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
        .frame(width: 250, alignment: .leading)
        .onAppear {
            SealedMemory.shared.markSeen(message.id)
            if lock.isPlace && lock.timeOK && !mine { fetcher.start() }
        }
        .onDisappear { fetcher.stop() }
        .animation(.easeOut(duration: 0.2), value: note)
    }

    private func distanceText(_ place: GeoPoint) -> String {
        guard !mine, let me = fetcher.location else { return "" }
        let d = me.distance(from: CLLocation(latitude: place.lat, longitude: place.lon))
        return " · " + (d < 1000 ? s.t("вы в \(Int(d)) м", "you're \(Int(d)) m away")
                                 : s.t(String(format: "вы в %.1f км", d / 1000), String(format: "you're %.1f km away", d / 1000)))
    }

    static func countdown(to date: Date, now: Date, _ s: Strings) -> String {
        let left = max(0, Int(date.timeIntervalSince(now)))
        let d = left / 86400, h = (left % 86400) / 3600, m = (left % 3600) / 60, sec = left % 60
        if d > 0 { return s.t("\(d) д \(h) ч \(m) мин", "\(d)d \(h)h \(m)m") }
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }

    private func tryUnlock() {
        guard let unlock else { return }
        fetcher.start()
        checking = true
        note = nil
        Task { @MainActor in
            defer { checking = false }
            // ждём свежую точку до 6 секунд
            for _ in 0..<30 where fetcher.location == nil || (fetcher.location?.timestamp.timeIntervalSinceNow ?? -100) < -30 {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let loc = fetcher.location else {
                note = fetcher.denied ? s.t("Разрешите доступ к геопозиции в настройках", "Allow location access in Settings")
                                      : s.t("Не удалось определить, где вы", "Couldn't get your location")
                return
            }
            let outcome = await unlock(message, GeoPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                                                          accuracy: loc.horizontalAccuracy))
            switch outcome {
            case .opened:
                Haptics.notify(.success)
            case .tooFar(let meters):
                Haptics.notify(.error)
                withAnimation(.default) { shake += 1 }
                note = meters < 1000 ? s.t("Пока далеко: \(meters) м. Подойдите ближе", "Still \(meters) m away. Get closer")
                                     : s.t(String(format: "Пока далеко: %.1f км", Double(meters) / 1000), String(format: "Still %.1f km away", Double(meters) / 1000))
            case .failed(let text):
                Haptics.notify(.error)
                note = text
            }
        }
    }

    private func route(_ place: GeoPoint) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)))
        item.name = place.title
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}

private struct ShakeEffect: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(amount * .pi * 4), y: 0))
    }
}

// MARK: - Пометка на открытом / своём сообщении с замком

struct LockBadge: View {
    let lock: MessageLock
    let mine: Bool
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        let s = Strings(lang: lang)
        let color = mine ? Color.white.opacity(0.85) : theme.accentColor
        HStack(spacing: 5) {
            Image(systemName: lock.isPlace ? "mappin.and.ellipse" : "hourglass").font(.system(size: 11, weight: .bold))
            Text(text(s)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 11).padding(.top, 7)
    }

    private func text(_ s: Strings) -> String {
        let loc = Locale(identifier: lang == .ru ? "ru_RU" : "en_US")
        if lock.open {
            return lock.isPlace ? s.t("Секрет открыт на месте", "Secret opened at the place")
                                : s.t("Капсула времени · открыта", "Time capsule · opened")
        }
        if !lock.timeOK, let at = lock.openAt {
            return s.t("Капсула · откроется ", "Capsule · opens ") + FormatterCache.format(at, "d MMM, HH:mm", locale: loc)
        }
        return s.t("Секрет · откроется у «\(lock.place?.title ?? "точки")»", "Secret · opens at “\(lock.place?.title ?? "the spot")”")
    }
}

/// Только что открытая капсула / секрет: проявляется из размытия, с искрами — один раз
struct RevealOnOpen: ViewModifier {
    let id: String
    let active: Bool
    @State private var shown = true
    @State private var sparkle = false

    func body(content: Content) -> some View {
        content
            .blur(radius: shown ? 0 : 12)
            .scaleEffect(shown ? 1 : 0.92)
            .overlay {
                if sparkle {
                    ForEach(0..<10, id: \.self) { i in
                        Image(systemName: "sparkle").font(.system(size: CGFloat(10 + (i % 3) * 5)))
                            .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.3))
                            .offset(x: cos(Double(i) * 0.63) * 90, y: sin(Double(i) * 0.63) * 40)
                            .transition(.scale.combined(with: .opacity))
                    }
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard active, SealedMemory.shared.shouldReveal(id) else { return }
                SealedMemory.shared.markRevealed(id)
                shown = false
                Haptics.notify(.success)
                withAnimation(.spring(response: 0.7, dampingFraction: 0.7).delay(0.15)) { shown = true; sparkle = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(.easeOut(duration: 0.4)) { sparkle = false } }
            }
    }
}

// MARK: - Отправка: когда открыть капсулу

struct CapsuleSheet: View {
    let onPick: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var custom = Date().addingTimeInterval(86400)
    @State private var showPicker = false

    var body: some View {
        let s = Strings(lang: lang)
        let cal = Calendar.current
        let tomorrow9 = cal.date(bySettingHour: 9, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()) ?? Date()
        let options: [(String, String, Date)] = [
            ("clock", s.t("Через час", "In an hour"), Date().addingTimeInterval(3600)),
            ("sunrise", s.t("Завтра в 9:00", "Tomorrow at 9:00"), tomorrow9),
            ("calendar", s.t("Через неделю", "In a week"), cal.date(byAdding: .day, value: 7, to: Date()) ?? Date()),
            ("calendar.badge.clock", s.t("Через месяц", "In a month"), cal.date(byAdding: .month, value: 1, to: Date()) ?? Date()),
            ("gift", s.t("Через год", "In a year"), cal.date(byAdding: .year, value: 1, to: Date()) ?? Date()),
        ]
        NavigationStack {
            List {
                Section {
                    ForEach(options, id: \.1) { icon, title, date in
                        Button { pick(date) } label: { Label(title, systemImage: icon).foregroundStyle(theme.text) }
                    }
                    Button { withAnimation { showPicker.toggle() } } label: {
                        Label(s.t("Выбрать дату и время", "Pick date and time"), systemImage: "calendar.circle").foregroundStyle(theme.text)
                    }
                    if showPicker {
                        DatePicker("", selection: $custom, in: Date().addingTimeInterval(120)...Date().addingTimeInterval(10 * 365 * 86400))
                            .datePickerStyle(.graphical).tint(theme.accentColor)
                        Button(s.t("Запечатать до этой даты", "Seal until this date")) { pick(custom) }
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.accentColor)
                    }
                } footer: {
                    Text(s.t("Собеседник увидит запечатанную капсулу с таймером. Открыть раньше не получится — ни у него, ни на сервере.",
                             "They'll see a sealed capsule with a countdown. Nobody can open it earlier."))
                }
            }
            .navigationTitle(s.t("Капсула времени", "Time capsule"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(s.cancel) { dismiss() } } }
        }
    }

    private func pick(_ date: Date) {
        Haptics.impact(.medium)
        onPick(date)
        dismiss()
    }
}

// MARK: - Отправка: где откроется секрет

struct SecretPlaceSheet: View {
    let onPick: (GeoPoint, Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @StateObject private var fetcher = LocationFetcher()
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var center: CLLocationCoordinate2D?
    @State private var radius: Double = 150
    @State private var title = ""
    @State private var placeName: String?

    var body: some View {
        let s = Strings(lang: lang)
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Map(position: $camera) {
                        UserAnnotation()
                        if let center {
                            MapCircle(center: center, radius: radius)
                                .foregroundStyle(Color(red: 0.2, green: 0.62, blue: 0.5).opacity(0.18))
                                .stroke(Color(red: 0.2, green: 0.62, blue: 0.5), lineWidth: 2)
                        }
                    }
                    .onMapCameraChange(frequency: .continuous) { ctx in center = ctx.region.center }
                    .onMapCameraChange(frequency: .onEnd) { ctx in geocode(ctx.region.center) }
                    // булавка всегда по центру карты — двигайте карту
                    Image(systemName: "mappin")
                        .font(.system(size: 34, weight: .bold)).foregroundStyle(Color(red: 0.2, green: 0.62, blue: 0.5))
                        .shadow(radius: 3).offset(y: -17).allowsHitTesting(false)
                }
                .frame(maxHeight: .infinity)

                VStack(spacing: 12) {
                    Text(placeName ?? s.t("Двигайте карту — булавка в центре", "Move the map — the pin is in the center"))
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(1)
                    TextField(s.t("Подсказка: «у нашего кафе»", "Hint: “at our café”"), text: $title)
                        .padding(.horizontal, 14).frame(height: 44)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Picker("", selection: $radius) {
                        Text("50 м").tag(50.0)
                        Text("150 м").tag(150.0)
                        Text("500 м").tag(500.0)
                        Text(s.t("2 км", "2 km")).tag(2000.0)
                    }
                    .pickerStyle(.segmented)
                    Button {
                        guard let c = center else { return }
                        Haptics.impact(.medium)
                        let label = title.trimmingCharacters(in: .whitespaces).isEmpty ? placeName : title
                        onPick(GeoPoint(lat: c.latitude, lon: c.longitude, title: label), radius)
                        dismiss()
                    } label: {
                        Label(s.t("Запечатать здесь", "Seal here"), systemImage: "lock.fill")
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background(Color(red: 0.2, green: 0.62, blue: 0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressStyle())
                    .disabled(center == nil)
                }
                .padding(16)
                .background(theme.sheet)
            }
            .navigationTitle(s.t("Секрет на месте", "Secret at a place"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(s.cancel) { dismiss() } } }
        }
        .onAppear { fetcher.start() }
        .onDisappear { fetcher.stop() }
    }

    private func geocode(_ c: CLLocationCoordinate2D) {
        Task {
            let marks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude))
            if let p = marks?.first { placeName = LocationShareSheet.describe(p) }
        }
    }
}
