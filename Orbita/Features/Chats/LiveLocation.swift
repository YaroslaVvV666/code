import SwiftUI
import Combine
import MapKit
import CoreLocation
import UIKit

// MARK: - Аватарки на карте трансляции

struct LiveAvatars {
    var mine: String? = nil
    var myName = ""
    var peer: String? = nil
    var peerName = ""
}

private struct LiveAvatarsKey: EnvironmentKey { static let defaultValue = LiveAvatars() }

extension EnvironmentValues {
    var liveAvatars: LiveAvatars {
        get { self[LiveAvatarsKey.self] }
        set { self[LiveAvatarsKey.self] = newValue }
    }
}

/// Пин трансляции: аватарка в кружочке с цветным ободком, снизу — хвостик, сбоку — стрелка направления
struct LiveAvatarPin: View {
    let avatarID: String?
    let name: String
    let active: Bool
    var heading: Double? = nil
    var size: CGFloat = 40
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: -3) {
                AvatarView(name: name, size: size, avatarID: avatarID)
                    .clipShape(Circle())
                    .grayscale(active ? 0 : 1)                       // трансляция закончилась — застывает серой и темнее
                    .brightness(active ? 0 : -0.22)
                    .padding(3)
                    .background(Circle().fill(active ? theme.accentColor : Color.gray))
                    .background { if active { PulseRing(color: theme.accentColor) } }     // «живая» — расходятся волны
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                Triangle().fill(active ? theme.accentColor : Color.gray).frame(width: 12, height: 8)
            }
            .overlay(alignment: .bottomTrailing) {
                if let heading, active {
                    Image(systemName: "location.north.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .rotationEffect(.degrees(heading))
                        .frame(width: 18, height: 18).background(theme.accentColor, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .offset(x: 4, y: -6)
                }
        }
    }

    /// Высота пина: чтобы кончик хвостика стоял ровно в точке, сдвигаем вверх на половину
    static func tipOffset(_ size: CGFloat) -> CGFloat { -(size + 6 + 5) / 2 }

    private struct Triangle: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.closeSubpath()
            return p
        }
    }
}

// MARK: - Трансляция своей геопозиции: шлёт точки на сервер, пока трансляция идёт

@MainActor
final class LiveLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LiveLocationManager()

    struct Session: Codable, Equatable {
        let messageID: String
        let chatID: String
        let until: Date
        var userID: String
    }

    @Published private(set) var sessions: [Session] = []
    /// Где я сейчас (пока идёт трансляция) — для «Вы рядом!»
    @Published private(set) var lastLocation: CLLocation?
    /// Чаты в режиме «Встретиться»: трансляция выключится сама, когда вы окажетесь рядом
    @Published private(set) var meetChats: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "orbita.live.meet") ?? [])

    func setMeet(_ chatID: String, _ on: Bool) {
        if on { meetChats.insert(chatID) } else { meetChats.remove(chatID) }
        UserDefaults.standard.set(Array(meetChats), forKey: "orbita.live.meet")
    }

    /// «До встречи»: трансляция до 8 часов, но выключится раньше — как только будете рядом
    static let untilMeet = 8 * 3600
    private let manager = CLLocationManager()
    private var repo: MessengerRepository?
    private var userID = ""
    private var lastSent: [String: (date: Date, location: CLLocation)] = [:]
    private var timer: Timer?
    private let key = "orbita.live.sessions"

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 15
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Session].self, from: data) {
            sessions = saved.filter { $0.until > Date() }
        }
    }

    /// Вызывается при входе: продолжает трансляции, начатые до перезапуска приложения
    func attach(repo: MessengerRepository, userID: String) {
        self.repo = repo
        self.userID = userID
        sessions.removeAll { $0.userID != userID || $0.until <= Date() }
        save()
        updateRunning()
    }

    func isActive(_ messageID: String) -> Bool { sessions.contains { $0.messageID == messageID && $0.until > Date() } }
    func active(in chatID: String) -> [Session] { sessions.filter { $0.chatID == chatID && $0.until > Date() } }

    func start(messageID: String, chatID: String, until: Date, repo: MessengerRepository) {
        self.repo = repo
        sessions.removeAll { $0.messageID == messageID }
        sessions.append(Session(messageID: messageID, chatID: chatID, until: until, userID: userID))
        save()
        updateRunning()
    }

    func stop(_ messageID: String) {
        guard sessions.contains(where: { $0.messageID == messageID }) else { return }
        sessions.removeAll { $0.messageID == messageID }
        lastSent[messageID] = nil
        save()
        updateRunning()
        if let repo { Task { try? await repo.stopLiveLocation(messageID: messageID) } }
    }

    /// Сообщение с трансляцией удалено — трансляция прекращается сама (сервер её уже не примет)
    func forget(_ messageIDs: [String]) {
        let ids = Set(messageIDs)
        guard sessions.contains(where: { ids.contains($0.messageID) }) else { return }
        sessions.removeAll { ids.contains($0.messageID) }
        for id in ids { lastSent[id] = nil }
        save()
        updateRunning()
    }

    /// Переписка удалена — все трансляции в ней прекращаются
    func forgetChat(_ chatID: String) { forget(sessions.filter { $0.chatID == chatID }.map(\.messageID)) }

    /// «Навсегда»: до остановки вручную или удаления сообщения
    static let forever = 10 * 365 * 86400

    func stopAll(in chatID: String) {
        setMeet(chatID, false)
        for s in active(in: chatID) { stop(s.messageID) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sessions) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Фоновая трансляция возможна, только если в Info.plist включён фоновый режим «location» (иначе iOS падает)
    private static let backgroundAllowed: Bool = {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") ?? false
    }()

    private func updateRunning() {
        let expired = sessions.filter { $0.until <= Date() }
        if !expired.isEmpty {
            sessions.removeAll { $0.until <= Date() }
            save()
        }
        if sessions.isEmpty {
            manager.stopUpdatingLocation()
            timer?.invalidate()
            timer = nil
            return
        }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        if Self.backgroundAllowed {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
        if timer == nil {
            // стоим на месте — точки не приходят; раз в 30 с всё равно подтверждаем, что трансляция жива, и закрываем истёкшие
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.updateRunning()
                    if let loc = self.manager.location { self.push(loc, force: true) }
                }
            }
        }
    }

    private func push(_ location: CLLocation, force: Bool = false) {
        guard let repo, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 1500 else { return }
        let now = Date()
        for s in sessions where s.until > now {
            if let last = lastSent[s.messageID] {
                let dt = now.timeIntervalSince(last.date)
                let moved = location.distance(from: last.location)
                // не чаще раза в 5 с; раз в 10 с, если сдвинулись заметно; иначе — по таймеру
                let due = force ? dt >= 25 : ((dt >= 10 && moved > 10) || moved > 60)
                guard dt >= 5, due else { continue }
            }
            lastSent[s.messageID] = (now, location)
            let point = GeoPoint(lat: location.coordinate.latitude, lon: location.coordinate.longitude,
                                 accuracy: location.horizontalAccuracy,
                                 heading: location.course >= 0 ? location.course : nil)
            let id = s.messageID
            Task { [weak self] in
                do { try await repo.updateLiveLocation(messageID: id, point: point) }
                catch APIError.server(let status, _) where status == 410 || status == 404 {
                    await MainActor.run {
                        self?.sessions.removeAll { $0.messageID == id }
                        self?.save()
                        self?.updateRunning()
                    }
                } catch {}
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.lastLocation = loc
            self.push(loc)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in if !self.sessions.isEmpty { self.updateRunning() } }
    }
}

// MARK: - Текущая геопозиция для экрана выбора

@MainActor
final class LocationFetcher: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var location: CLLocation?
    @Published var status: CLAuthorizationStatus
    private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var denied: Bool { status == .denied || status == .restricted }
    /// В Info.plist приложения нет текста разрешения — iOS тогда молча не даёт геопозицию (кнопки стоят серыми)
    static var missingUsageKey: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") == nil
    }

    func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    func stop() { manager.stopUpdatingLocation() }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.location = loc }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            self.status = s
            if s == .authorizedWhenInUse || s == .authorizedAlways { self.manager.startUpdatingLocation() }
        }
    }
}

// MARK: - Шторка «Геопозиция»: моя точка, выбранное место, трансляция

struct LocationShareSheet: View {
    var onSend: (GeoPoint, Int) -> Void

    @StateObject private var fetcher = LocationFetcher()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var center: CLLocationCoordinate2D?
    @State private var movedAway = false
    @State private var placeName: String?
    @State private var askLive = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Map(position: $camera) {
                        UserAnnotation()
                    }
                    .mapControls {
                        MapUserLocationButton()
                        MapCompass()
                    }
                    .onMapCameraChange(frequency: .onEnd) { ctx in
                        center = ctx.region.center
                        if let me = fetcher.location {
                            let d = CLLocation(latitude: ctx.region.center.latitude, longitude: ctx.region.center.longitude).distance(from: me)
                            movedAway = d > max(40, me.horizontalAccuracy)
                        } else {
                            movedAway = true
                        }
                    }
                    if movedAway {
                        // выбранное место — по центру карты
                        Image(systemName: "mappin")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(Color(red: 0.92, green: 0.26, blue: 0.24))
                            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                            .offset(y: -17)
                            .allowsHitTesting(false)
                            .transition(.scale.combined(with: .opacity))
                    }
                    if LocationFetcher.missingUsageKey {
                        missingKeyCard
                    } else if fetcher.denied {
                        deniedCard
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: movedAway)

                VStack(spacing: 10) {
                    if movedAway, let c = center {
                        row(icon: "mappin.and.ellipse", tint: Color(red: 0.92, green: 0.26, blue: 0.24),
                            title: s.t("Отправить выбранное место", "Send this place"),
                            subtitle: placeName ?? String(format: "%.5f, %.5f", c.latitude, c.longitude)) {
                            onSend(GeoPoint(lat: c.latitude, lon: c.longitude, title: placeName), 0)
                            dismiss()
                        }
                    }
                    row(icon: "location.fill", tint: theme.accentColor,
                        title: s.t("Отправить мою геопозицию", "Send my current location"),
                        subtitle: fetcher.location.map { s.t("Точность \(Int($0.horizontalAccuracy)) м", "Accurate to \(Int($0.horizontalAccuracy)) m") }
                            ?? s.t("Определяем…", "Locating…")) {
                        guard let loc = fetcher.location else { return }
                        onSend(GeoPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, accuracy: loc.horizontalAccuracy), 0)
                        dismiss()
                    }
                    .disabled(fetcher.location == nil)
                    row(icon: "dot.radiowaves.left.and.right", tint: Color(red: 0.22, green: 0.66, blue: 0.45),
                        title: s.t("Транслировать геопозицию", "Share live location"),
                        subtitle: fetcher.location == nil
                            ? (fetcher.denied || LocationFetcher.missingUsageKey ? s.t("Нет доступа к геопозиции", "No location access") : s.t("Определяем, где вы…", "Locating…"))
                            : s.t("Собеседник видит, где вы, в реальном времени", "Updates in real time while you move")) {
                        askLive = true
                    }
                    .disabled(fetcher.location == nil)
                }
                .padding(16)
            }
            .background(theme.sheet.ignoresSafeArea())
            .navigationTitle(s.t("Геопозиция", "Location"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(s.t("Отмена", "Cancel")) { dismiss() }.foregroundStyle(theme.accentColor)
                }
            }
            .confirmationDialog(s.t("Транслировать геопозицию", "Share live location"), isPresented: $askLive, titleVisibility: .visible) {
                ForEach([(900, s.t("15 минут", "15 minutes")), (3600, s.t("1 час", "1 hour")),
                         (LiveLocationManager.forever, s.t("Навсегда", "Until I stop"))], id: \.0) { sec, label in
                    Button(label) { sendLive(sec) }
                }
                // «Мы рядом»: выключится сама, когда вы окажетесь рядом
                Button(s.t("До встречи 🤝", "Until we meet 🤝")) { sendLive(LiveLocationManager.untilMeet) }
                Button(s.t("Отмена", "Cancel"), role: .cancel) {}
            } message: {
                Text(s.t("Собеседник видит вас на карте — с вашей аватаркой. Остановить можно в любой момент: в сообщении или на карте. Удалите сообщение — трансляция тоже прекратится.",
                         "They see you on a map with your avatar. Stop anytime from the message or the map. Deleting the message stops it too."))
            }
        }
        .onAppear { fetcher.start() }
        .onDisappear { fetcher.stop() }
        .task(id: movedAway ? center.map { "\(($0.latitude * 10000).rounded()),\(($0.longitude * 10000).rounded())" } : nil) {
            // название места по центру карты (после остановки карты, с паузой — геокодер не любит частые запросы)
            guard movedAway, let c = center else { placeName = nil; return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            let marks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude))
            if Task.isCancelled { return }
            if let place = marks?.first {
                placeName = Self.describe(place)
            } else {
                placeName = nil
            }
        }
    }

    private func sendLive(_ seconds: Int) {
        guard let loc = fetcher.location else { return }
        onSend(GeoPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, accuracy: loc.horizontalAccuracy,
                        heading: loc.course >= 0 ? loc.course : nil), seconds)
        dismiss()
    }

    static func describe(_ p: CLPlacemark) -> String? {
        if let name = p.name, !name.isEmpty { return name }
        let parts = [p.thoroughfare, p.subThoroughfare, p.locality].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Сборка без ключа геопозиции в Info.plist — объясняем, что добавить (иначе непонятно, почему всё серое)
    private var missingKeyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 26)).foregroundStyle(.orange)
            Text(s.t("Геопозиция не настроена в сборке", "Location isn't set up in this build"))
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).multilineTextAlignment(.center)
            Text(s.t("В Xcode: таргет → Info → добавьте «Privacy - Location When In Use Usage Description» с любым текстом. Для трансляции в фоне: Signing & Capabilities → Background Modes → Location updates.",
                     "In Xcode: target → Info → add “Privacy - Location When In Use Usage Description”. For background sharing: Signing & Capabilities → Background Modes → Location updates."))
                .font(.system(size: 13)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
        }
        .padding(18)
        .glass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(24)
    }

    private var deniedCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "location.slash.fill").font(.system(size: 26)).foregroundStyle(theme.textSecondary)
            Text(s.t("Нет доступа к геопозиции", "No access to location")).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
            Text(s.t("Разрешите доступ в Настройках, чтобы отправлять своё местоположение. Место на карте можно выбрать и без него.",
                     "Allow access in Settings to send where you are. You can still pick a place on the map."))
                .font(.system(size: 13)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
            Button(s.t("Открыть Настройки", "Open Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accentColor)
        }
        .padding(18)
        .glass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(24)
    }

    private func row(icon: String, tint: Color, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38).background(tint, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).frame(height: 60)
            .glass(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Снимок карты для пузыря (рисуется один раз и кэшируется, а не живая карта в каждой ячейке)

enum MapSnapshotCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 60
        return c
    }()

    static func key(_ lat: Double, _ lon: Double, dark: Bool, span: Double) -> String {
        String(format: "%.4f,%.4f,%d,%.4f", lat, lon, dark ? 1 : 0, span)
    }

    static func cached(_ key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    static func image(lat: Double, lon: Double, size: CGSize, dark: Bool, span: Double) async -> UIImage? {
        let k = key(lat, lon, dark: dark, span: span)
        if let img = cached(k) { return img }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
        options.size = size
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        options.pointOfInterestFilter = .excludingAll
        guard let snap = try? await MKMapSnapshotter(options: options).start() else { return nil }
        cache.setObject(snap.image, forKey: k as NSString)
        return snap.image
    }
}

// MARK: - Геопозиция в сообщении

struct LocationBlock: View {
    let geo: GeoPoint
    let messageID: String
    let mine: Bool
    let pending: Bool
    var avatarID: String? = nil
    /// Просто точка: карта во весь пузырь, без подписей и скруглений (их даёт сам пузырь) — как в Telegram
    var bare = false

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @ObservedObject private var live = LiveLocationManager.shared
    @State private var snapshot: UIImage?
    @State private var showMap = false

    private var s: Strings { Strings(lang: lang) }
    private let size = CGSize(width: 240, height: 150)
    private let span = 0.006

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { tl in
            let active = geo.active(at: tl.date)
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Rectangle().fill(theme.dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))
                    if let img = snapshot {
                        Image(uiImage: img).resizable().scaledToFill().transition(.opacity)
                    }
                    pin(active: active)
                }
                .frame(width: bare ? 260 : size.width, height: bare ? 170 : size.height)
                .clipShape(RoundedRectangle(cornerRadius: bare ? 0 : 14, style: .continuous))

                if !bare {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(active: active)).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(mine ? Color.white : theme.text).lineLimit(1)
                        Text(subtitle(active: active, now: tl.date)).font(.system(size: 12))
                            .foregroundStyle(mine ? Color.white.opacity(0.75) : theme.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if mine, active, live.isActive(messageID) {
                        Button {
                            live.stop(messageID)
                            Haptics.impact(.medium)
                        } label: {
                            Text(s.t("Стоп", "Stop")).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(mine ? Color.white : theme.danger)
                                .padding(.horizontal, 10).frame(height: 26)
                                .background((mine ? Color.white : theme.danger).opacity(0.2), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4).padding(.top, 7).padding(.bottom, 2)
                .frame(width: size.width, alignment: .leading)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !pending { showMap = true } }
        .task(id: MapSnapshotCache.key(geo.lat, geo.lon, dark: theme.dark, span: span)) {
            let k = MapSnapshotCache.key(geo.lat, geo.lon, dark: theme.dark, span: span)
            if let img = MapSnapshotCache.cached(k) { snapshot = img; return }
            let img = await MapSnapshotCache.image(lat: geo.lat, lon: geo.lon, size: size, dark: theme.dark, span: span)
            withAnimation(.easeOut(duration: 0.2)) { snapshot = img ?? snapshot }
        }
        .fullScreenCover(isPresented: $showMap) {
            if geo.isLive, !chatLive.people.isEmpty {
                // трансляция: общая карта — и моя, и его аватарки, закончившиеся — серые на последней точке
                LiveMapScreen(context: chatLive, focus: messageID)
                    .environment(\.theme, theme).environment(\.lang, lang)
            } else {
            LocationMapView(geo: geo, messageID: messageID, mine: mine, avatarID: pinAvatar, name: pinName)
                .environment(\.theme, theme).environment(\.lang, lang)
            }
        }
    }

    @Environment(\.liveAvatars) private var avatars
    @Environment(\.chatLive) private var chatLive
    private var pinAvatar: String? { avatarID ?? (mine ? avatars.mine : avatars.peer) }
    private var pinName: String { mine ? avatars.myName : avatars.peerName }

    @ViewBuilder
    private func pin(active: Bool) -> some View {
        if geo.isLive {
            // трансляция: аватарка того, кто транслирует, в кружочке
            LiveAvatarPin(avatarID: pinAvatar, name: pinName, active: active, heading: geo.heading, size: 34)
                .offset(y: LiveAvatarPin.tipOffset(34))
        } else {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 30))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color(red: 0.92, green: 0.26, blue: 0.24))
                .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
        }
    }

    private func title(active: Bool) -> String {
        if geo.isLive { return active ? s.t("Трансляция геопозиции", "Live location") : s.t("Трансляция завершена", "Live location ended") }
        return geo.title ?? s.t("Геопозиция", "Location")
    }

    private func subtitle(active: Bool, now: Date) -> String {
        if geo.isLive {
            if active, let until = geo.liveUntil, until.timeIntervalSince(now) > 300 * 86400 {
                return s.t("без ограничения", "until stopped") + " · " + updated(now: now)
            }
            if active, let until = geo.liveUntil {
                let left = max(1, Int(until.timeIntervalSince(now) / 60))
                let leftText = left >= 60 ? s.t("осталось \(left / 60) ч \(left % 60) мин", "\(left / 60) h \(left % 60) min left")
                                          : s.t("осталось \(left) мин", "\(left) min left")
                return leftText + " · " + updated(now: now)
            }
            return updated(now: now)
        }
        return String(format: "%.5f, %.5f", geo.lat, geo.lon)
    }

    private func updated(now: Date) -> String {
        guard let u = geo.updatedAt else { return s.t("обновлено только что", "updated just now") }
        let min = Int(now.timeIntervalSince(u) / 60)
        if min < 1 { return s.t("обновлено только что", "updated just now") }
        if min < 60 { return s.t("обновлено \(min) мин назад", "updated \(min) min ago") }
        return s.t("обновлено \(min / 60) ч назад", "updated \(min / 60) h ago")
    }
}

/// Расходящееся кольцо вокруг точки трансляции
private struct PulseRing: View {
    let color: Color
    @State private var on = false

    var body: some View {
        Circle().fill(color.opacity(0.35))
            .frame(width: 30, height: 30)
            .scaleEffect(on ? 2.4 : 1)
            .opacity(on ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { on = true }
            }
    }
}

// MARK: - Карта на весь экран

struct LocationMapView: View {
    let geo: GeoPoint
    let messageID: String
    let mine: Bool
    var avatarID: String? = nil
    var name = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @ObservedObject private var live = LiveLocationManager.shared
    @State private var camera: MapCameraPosition = .automatic

    private var s: Strings { Strings(lang: lang) }
    private var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: geo.lat, longitude: geo.lon) }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $camera) {
                UserAnnotation()
                Annotation(geo.title ?? "", coordinate: coordinate, anchor: geo.isLive ? .bottom : .center) {
                    ZStack {
                        if geo.isLive {
                            // аватарка в кружочке — того, кто транслирует
                            LiveAvatarPin(avatarID: avatarID, name: name, active: geo.active(), heading: geo.heading, size: 44)
                        } else {
                            Image(systemName: "mappin.circle.fill").font(.system(size: 36))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white, Color(red: 0.92, green: 0.26, blue: 0.24))
                                .shadow(radius: 3)
                        }
                    }
                }
                if let acc = geo.accuracy, acc > 20 {
                    MapCircle(center: coordinate, radius: acc)
                        .foregroundStyle(theme.accentColor.opacity(0.12))
                        .stroke(theme.accentColor.opacity(0.4), lineWidth: 1)
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .ignoresSafeArea()

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
                        .frame(width: 42, height: 42).glassCircle()
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 8)

            VStack {
                Spacer()
                VStack(spacing: 10) {
                    if mine, geo.active(), live.isActive(messageID) {
                        Button {
                            live.stop(messageID)
                            Haptics.impact(.medium)
                        } label: {
                            Text(s.t("Остановить трансляцию", "Stop sharing"))
                                .font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.danger)
                                .frame(maxWidth: .infinity).frame(height: 50)
                                .glass(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
                        }
                        .buttonStyle(.plain)
                    }
                    Button { openInMaps() } label: {
                        Label(s.t("Маршрут", "Directions"), systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background(theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
        }
        .preferredColorScheme(theme.dark ? .dark : .light)
        .onAppear { recenter() }
        .onChange(of: geo) { _, _ in withAnimation(.easeInOut(duration: 0.6)) { recenter() } }
    }

    private func recenter() {
        camera = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 700, longitudinalMeters: 700))
    }

    private func openInMaps() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = geo.title ?? (geo.isLive ? s.t("Трансляция геопозиции", "Live location") : s.t("Геопозиция", "Location"))
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
    }
}

// MARK: - Кто транслирует в этом чате

/// Трансляция одного человека в чате (последняя его трансляция)
struct LivePerson: Identifiable, Equatable {
    let messageID: String
    let userID: String
    let name: String
    let avatarID: String?
    let mine: Bool
    let geo: GeoPoint
    var id: String { userID }
    var active: Bool { geo.active() }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: geo.lat, longitude: geo.lon) }
}

/// Всё про трансляции чата — для плашки сверху, общей карты и карт в сообщениях
struct ChatLiveContext {
    var chatID = ""
    var people: [LivePerson] = []
    /// Поделиться своей трансляцией прямо с карты (точка, секунды)
    var onShare: ((GeoPoint, Int) -> Void)? = nil
    /// Предложить место встречи — обычной точкой в чат
    var onSendPlace: ((GeoPoint) -> Void)? = nil
    var active: [LivePerson] { people.filter(\.active) }

    /// Из сообщений чата: у каждого — его последняя трансляция (идущая или закончившаяся — тогда застывшая серая)
    static func build(chatID: String, messages: [ChatMessage], me: (id: String, name: String, avatar: String?),
                      peer: ChatPeer, onShare: ((GeoPoint, Int) -> Void)?,
                      onSendPlace: ((GeoPoint) -> Void)? = nil) -> ChatLiveContext {
        var byUser: [String: LivePerson] = [:]
        for m in messages {
            guard let geo = m.attachments.first(where: { $0.kind == .location })?.geo, geo.isLive else { continue }
            let uid = m.mine ? me.id : (m.sender?.id ?? peer.id)
            let person = LivePerson(messageID: m.id, userID: uid,
                                    name: m.mine ? me.name : (m.sender?.name ?? peer.name),
                                    avatarID: m.mine ? me.avatar : (m.sender?.avatarID ?? peer.avatarID),
                                    mine: m.mine, geo: geo)
            if let old = byUser[uid], old.active && !person.active { continue }     // идущая важнее закончившейся
            byUser[uid] = person
        }
        let list = byUser.values.sorted { a, b in a.mine != b.mine ? a.mine : (a.active != b.active ? a.active : a.name < b.name) }
        return ChatLiveContext(chatID: chatID, people: list, onShare: onShare, onSendPlace: onSendPlace)
    }
}

private struct ChatLiveKey: EnvironmentKey { static let defaultValue = ChatLiveContext() }

extension EnvironmentValues {
    var chatLive: ChatLiveContext {
        get { self[ChatLiveKey.self] }
        set { self[ChatLiveKey.self] = newValue }
    }
}

/// Значок трансляции: булавка и расходящиеся с двух сторон волны
struct LiveBeaconIcon: View {
    var size: CGFloat = 18
    var color: Color = Color(red: 0.22, green: 0.66, blue: 0.45)
    @State private var on = false

    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: "wave.3.left").font(.system(size: size * 0.7, weight: .semibold))
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating)
            Image(systemName: "mappin").font(.system(size: size, weight: .bold))
                .offset(y: on ? -1.5 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            Image(systemName: "wave.3.right").font(.system(size: size * 0.7, weight: .semibold))
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating)
        }
        .foregroundStyle(color)
        .onAppear { on = true }
    }
}

// MARK: - Плашка в чате: кто сейчас транслирует (я и другие)

struct LiveLocationBar: View {
    let context: ChatLiveContext
    let onOpen: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        let active = context.active
        if !active.isEmpty {
            Button(action: { Haptics.impact(.light); onOpen() }) {
                HStack(spacing: 12) {
                    LiveBeaconIcon()
                        .frame(width: 52, height: 36)
                        .background(Color(red: 0.22, green: 0.66, blue: 0.45).opacity(0.14), in: Capsule())
                    VStack(spacing: 2) {
                        Text(s.t("Трансляция геопозиции", "Live location")).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.text)
                        Text(active.map { $0.mine ? s.t("Я", "Me") : $0.name }.joined(separator: " • "))
                            .font(.system(size: 12)).foregroundStyle(theme.textSecondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    // аватарки тех, кто транслирует
                    HStack(spacing: -8) {
                        ForEach(active.prefix(3)) { p in
                            AvatarView(name: p.name, size: 26, avatarID: p.avatarID)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(theme.sheet, lineWidth: 2))
                        }
                    }
                    .frame(width: 52, alignment: .trailing)
                }
                .padding(.horizontal, 12).frame(height: 52)
                .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .padding(.horizontal, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Общая карта трансляций чата

struct LiveMapScreen: View {
    let context: ChatLiveContext
    var focus: String? = nil                    // id сообщения, с которого открыли

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @ObservedObject private var live = LiveLocationManager.shared
    @State private var camera: MapCameraPosition = .automatic
    @State private var askLive = false
    @State private var me: CLLocation?
    @State private var places: [MKMapItem] = []          // места посередине между вами
    @State private var picked: MKMapItem?
    @State private var searching = false
    private let locator = CLLocationManager()

    /// Я и собеседник оба на карте — можно встретиться посередине
    private var pair: (LivePerson, LivePerson)? {
        guard let mine = context.people.first(where: { $0.mine && $0.active }),
              let other = context.people.first(where: { !$0.mine && $0.active }) else { return nil }
        return (mine, other)
    }
    private var midpoint: CLLocationCoordinate2D? {
        guard let p = pair else { return nil }
        let a = p.0, b = p.1
        return CLLocationCoordinate2D(latitude: (a.geo.lat + b.geo.lat) / 2, longitude: (a.geo.lon + b.geo.lon) / 2)
    }

    private var s: Strings { Strings(lang: lang) }
    private var sharingHere: Bool { !live.active(in: context.chatID).isEmpty }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $camera) {
                UserAnnotation()
                ForEach(context.people) { p in
                    Annotation(p.mine ? s.t("Я", "Me") : p.name, coordinate: p.coordinate, anchor: .bottom) {
                        LiveAvatarPin(avatarID: p.avatarID, name: p.name, active: p.active, heading: p.geo.heading, size: 44)
                            .onTapGesture { zoom(to: p) }
                    }
                }
                if let p = pair {
                    // линия между вами и точка посередине
                    MapPolyline(coordinates: [p.0.coordinate, p.1.coordinate])
                        .stroke(Color(red: 0.22, green: 0.66, blue: 0.45).opacity(0.7), style: StrokeStyle(lineWidth: 3, dash: [6, 6]))
                    if let mid = midpoint {
                        Annotation(s.t("Посередине", "Halfway"), coordinate: mid) {
                            Image(systemName: "flag.checkered.circle.fill").font(.system(size: 30))
                                .symbolRenderingMode(.palette).foregroundStyle(.white, Color(red: 0.22, green: 0.66, blue: 0.45))
                                .shadow(radius: 3)
                        }
                    }
                }
                ForEach(places, id: \.self) { item in
                    Annotation(item.name ?? "", coordinate: item.placemark.coordinate) {
                        Image(systemName: picked == item ? "cup.and.saucer.fill" : "cup.and.saucer")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            .frame(width: picked == item ? 38 : 30, height: picked == item ? 38 : 30)
                            .background(Color.orange, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .shadow(radius: 3)
                            .onTapGesture { withAnimation(.spring(response: 0.3)) { picked = item } }
                    }
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapPitchToggle()
            }
            .ignoresSafeArea()

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
                        .frame(width: 44, height: 44).glassCircle()
                }
                .buttonStyle(.plain)
                Spacer()
                Text(s.t("Геопозиция", "Location")).font(.system(size: 17, weight: .bold)).foregroundStyle(theme.text)
                    .shadow(color: .black.opacity(0.25), radius: 3)
                Spacer()
                Button { Haptics.select(); showAll() } label: {
                    Text(s.t("Показать все", "Show all")).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
                        .padding(.horizontal, 14).frame(height: 44)
                        .glass(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.top, 8)

            VStack { Spacer(); panel }
        }
        .onAppear {
            me = locator.location
            if let f = focus, let p = context.people.first(where: { $0.messageID == f }) { zoom(to: p, animated: false) }
            else { showAll(animated: false) }
        }
        .confirmationDialog(s.t("Транслировать геопозицию", "Share live location"), isPresented: $askLive, titleVisibility: .visible) {
            ForEach([(900, s.t("15 минут", "15 minutes")), (3600, s.t("1 час", "1 hour")),
                     (LiveLocationManager.forever, s.t("Навсегда", "Until I stop"))], id: \.0) { sec, label in
                Button(label) { shareLive(sec) }
            }
            Button(s.t("Отмена", "Cancel"), role: .cancel) {}
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            if let p = pair {
                // встреча: расстояние между вами и места посередине
                let d = CLLocation(latitude: p.0.geo.lat, longitude: p.0.geo.lon).distance(from: CLLocation(latitude: p.1.geo.lat, longitude: p.1.geo.lon))
                HStack(spacing: 10) {
                    Image(systemName: "figure.walk").foregroundStyle(Color(red: 0.22, green: 0.66, blue: 0.45))
                    Text(s.t("Между вами ", "Between you: ") + (d < 1000 ? s.t("\(Int(d)) м", "\(Int(d)) m") : String(format: s.t("%.1f км", "%.1f km"), d / 1000)))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
                    Spacer()
                    Button { Task { await findPlaces() } } label: {
                        HStack(spacing: 5) {
                            if searching { ProgressView().scaleEffect(0.7) } else { Image(systemName: "cup.and.saucer.fill") }
                            Text(s.t("Места посередине", "Places halfway"))
                        }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 32).background(Color.orange, in: Capsule())
                    }
                    .buttonStyle(PressStyle())
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                if let item = picked {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name ?? "").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                            Text(item.placemark.thoroughfare ?? "").font(.system(size: 12)).foregroundStyle(theme.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        if let send = context.onSendPlace {
                            Button {
                                let c = item.placemark.coordinate
                                send(GeoPoint(lat: c.latitude, lon: c.longitude, title: item.name))
                                Haptics.notify(.success)
                                withAnimation { picked = nil }
                            } label: {
                                Text(s.t("Предложить", "Suggest")).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 12).frame(height: 32).background(theme.accent, in: Capsule())
                            }
                            .buttonStyle(PressStyle())
                        }
                        Button { item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]) } label: {
                            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill").foregroundStyle(theme.accentColor)
                                .frame(width: 32, height: 32).background(theme.accentColor.opacity(0.14), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Divider().padding(.leading, 16)
            }
            // поделиться в ответ — или остановить свою
            if sharingHere {
                Button {
                    live.stopAll(in: context.chatID)
                    Haptics.impact(.medium)
                } label: {
                    row(icon: AnyView(Image(systemName: "stop.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                                        .frame(width: 46, height: 46).background(theme.danger, in: Circle())),
                        title: s.t("Остановить трансляцию", "Stop sharing"), subtitle: nil, titleColor: theme.danger)
                }
                .buttonStyle(.plain)
            } else if context.onShare != nil {
                Button { askLive = true } label: {
                    row(icon: AnyView(LiveBeaconIcon(size: 15, color: .white).frame(width: 46, height: 46)
                                        .background(Color(red: 0.22, green: 0.66, blue: 0.45), in: Circle())),
                        title: s.t("Транслировать геопозицию", "Share live location"),
                        subtitle: s.t("Обновляется в реальном времени", "Updates in real time"), titleColor: theme.text)
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 74)
                // «Мы рядом»: трансляция до встречи — выключится сама, когда окажетесь рядом
                Button { shareLive(LiveLocationManager.untilMeet, meet: true) } label: {
                    row(icon: AnyView(Image(systemName: "figure.2.arms.open").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                                        .frame(width: 46, height: 46).background(Color.orange, in: Circle())),
                        title: s.t("Встретиться", "Meet up"),
                        subtitle: s.t("Покажем точку посередине, а рядом — «Вы рядом!»", "We'll show a halfway point and tell you when you're close"),
                        titleColor: theme.text)
                }
                .buttonStyle(.plain)
            }
            ForEach(context.people) { p in
                Divider().padding(.leading, 74)
                Button { zoom(to: p) } label: {
                    row(icon: AnyView(AvatarView(name: p.name, size: 46, avatarID: p.avatarID).clipShape(Circle())
                                        .grayscale(p.active ? 0 : 1).brightness(p.active ? 0 : -0.15)),
                        title: p.mine ? s.t("Я", "Me") : p.name, subtitle: subtitle(p), titleColor: theme.text,
                        live: p.active)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .glass(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    private func row(icon: AnyView, title: String, subtitle: String?, titleColor: Color, live: Bool = false) -> some View {
        HStack(spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(titleColor).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if live {
                Circle().fill(Color(red: 0.22, green: 0.66, blue: 0.45)).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color(red: 0.22, green: 0.66, blue: 0.45).opacity(0.4), lineWidth: 4).scaleEffect(1.6))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func subtitle(_ p: LivePerson) -> String {
        var parts: [String] = []
        if p.active {
            if let u = p.geo.updatedAt {
                let sec = Int(Date().timeIntervalSince(u))
                parts.append(sec < 60 ? s.t("обновлено только что", "updated just now") : s.t("обновлено \(sec / 60) мин назад", "updated \(sec / 60) min ago"))
            } else {
                parts.append(s.t("в реальном времени", "live"))
            }
        } else {
            parts.append(s.t("трансляция закончилась", "sharing ended"))
        }
        if !p.mine, let me {
            let d = me.distance(from: CLLocation(latitude: p.geo.lat, longitude: p.geo.lon))
            parts.append(d < 1000 ? s.t("\(Int(d)) м от вас", "\(Int(d)) m away") : s.t(String(format: "%.1f км от вас", d / 1000), String(format: "%.1f km away", d / 1000)))
        }
        return parts.joined(separator: " · ")
    }

    private func zoom(to p: LivePerson, animated: Bool = true) {
        let pos = MapCameraPosition.region(MKCoordinateRegion(center: p.coordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
        if animated { withAnimation(.easeInOut(duration: 0.5)) { camera = pos } } else { camera = pos }
    }

    /// Все трансляции (и я) в кадре
    private func showAll(animated: Bool = true) {
        var coords = context.people.map(\.coordinate)
        if let me { coords.append(me.coordinate) }
        guard let first = coords.first else { return }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let span = MKCoordinateSpan(latitudeDelta: max(0.01, (maxLat - minLat) * 1.6), longitudeDelta: max(0.01, (maxLon - minLon) * 1.6))
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let pos = MapCameraPosition.region(MKCoordinateRegion(center: center, span: span))
        if animated { withAnimation(.easeInOut(duration: 0.6)) { camera = pos } } else { camera = pos }
    }

    /// Места посередине: кафе и кофейни рядом с точкой между вами
    private func findPlaces() async {
        guard let mid = midpoint else { return }
        searching = true
        defer { searching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "кафе"
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.cafe, .restaurant, .bakery])
        request.region = MKCoordinateRegion(center: mid, latitudinalMeters: 1500, longitudinalMeters: 1500)
        let found = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
        let midLoc = CLLocation(latitude: mid.latitude, longitude: mid.longitude)
        let sorted = found.sorted { ($0.placemark.location?.distance(from: midLoc) ?? .infinity) < ($1.placemark.location?.distance(from: midLoc) ?? .infinity) }
        withAnimation(.spring(response: 0.4)) {
            places = Array(sorted.prefix(6))
            picked = places.first
        }
        if places.isEmpty { Haptics.notify(.warning) } else {
            Haptics.select()
            withAnimation(.easeInOut(duration: 0.6)) {
                camera = .region(MKCoordinateRegion(center: mid, latitudinalMeters: 2200, longitudinalMeters: 2200))
            }
        }
    }

    private func shareLive(_ seconds: Int, meet: Bool = false) {
        if meet { live.setMeet(context.chatID, true) }
        guard let onShare = context.onShare else { return }
        if locator.authorizationStatus == .notDetermined { locator.requestWhenInUseAuthorization() }
        guard let loc = locator.location ?? me else { return }
        onShare(GeoPoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, accuracy: loc.horizontalAccuracy,
                         heading: loc.course >= 0 ? loc.course : nil), seconds)
        Haptics.notify(.success)
        dismiss()
    }
}

// MARK: - «Вы рядом!»

/// Следит за режимом встречи: как только вы с собеседником ближе 60 м — праздник, вибрация и трансляция выключается
struct MeetWatcher: View {
    let context: ChatLiveContext
    @ObservedObject private var live = LiveLocationManager.shared
    @State private var celebrate = false
    @State private var fired = false

    private var near: Bool {
        guard live.meetChats.contains(context.chatID), !live.active(in: context.chatID).isEmpty,
              let me = live.lastLocation else { return false }
        return context.people.contains { p in
            !p.mine && p.active && me.distance(from: CLLocation(latitude: p.geo.lat, longitude: p.geo.lon)) < 60 + min(40, max(0, me.horizontalAccuracy))
        }
    }

    var body: some View {
        ZStack {
            if celebrate { NearbyCelebration().transition(.scale(scale: 0.6).combined(with: .opacity)) }
        }
        .allowsHitTesting(false)
        .onChange(of: near) { _, now in if now { fire() } }
        .onAppear { if near { fire() } }
    }

    private func fire() {
        guard !fired else { return }
        fired = true
        Haptics.notify(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Haptics.impact(.heavy) }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) { celebrate = true }
        live.stopAll(in: context.chatID)                  // встретились — геопозиция больше не нужна
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            withAnimation(.easeOut(duration: 0.4)) { celebrate = false }
        }
    }
}

private struct NearbyCelebration: View {
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var burst = false

    var body: some View {
        let s = Strings(lang: lang)
        ZStack {
            ForEach(0..<14, id: \.self) { i in
                Text(["🎉", "✨", "🤝", "💛"][i % 4]).font(.system(size: 26))
                    .offset(x: burst ? cos(Double(i) / 14 * 2 * .pi) * 150 : 0, y: burst ? sin(Double(i) / 14 * 2 * .pi) * 150 : 0)
                    .opacity(burst ? 0 : 1)
            }
            VStack(spacing: 8) {
                Text("🤝").font(.system(size: 56))
                Text(s.t("Вы рядом!", "You're close!")).font(.system(size: 26, weight: .heavy)).foregroundStyle(theme.text)
                Text(s.t("Трансляция геопозиции выключена", "Live location turned off")).font(.system(size: 14)).foregroundStyle(theme.textSecondary)
            }
            .padding(28)
            .glass(RoundedRectangle(cornerRadius: 30, style: .continuous))
        }
        .onAppear { withAnimation(.easeOut(duration: 1.4)) { burst = true } }
    }
}
