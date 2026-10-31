import SwiftUI
import MapKit
import CoreLocation
import UIKit

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

    func stopAll(in chatID: String) {
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
        Task { @MainActor in self.push(loc) }
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
                    if fetcher.denied {
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
                        subtitle: s.t("Собеседник видит, где вы, в реальном времени", "Updates in real time while you move")) {
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
                ForEach([(900, s.t("15 минут", "15 minutes")), (3600, s.t("1 час", "1 hour")), (8 * 3600, s.t("8 часов", "8 hours"))], id: \.0) { sec, label in
                    Button(label) { sendLive(sec) }
                }
                Button(s.t("Отмена", "Cancel"), role: .cancel) {}
            } message: {
                Text(s.t("Пока идёт трансляция, собеседник видит ваше местоположение на карте. Её можно остановить в любой момент.",
                         "While sharing, they see where you are on a map. You can stop at any time."))
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
            placeName = marks?.first.map(Self.describe)
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
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

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
        .contentShape(Rectangle())
        .onTapGesture { if !pending { showMap = true } }
        .task(id: MapSnapshotCache.key(geo.lat, geo.lon, dark: theme.dark, span: span)) {
            let k = MapSnapshotCache.key(geo.lat, geo.lon, dark: theme.dark, span: span)
            if let img = MapSnapshotCache.cached(k) { snapshot = img; return }
            let img = await MapSnapshotCache.image(lat: geo.lat, lon: geo.lon, size: size, dark: theme.dark, span: span)
            withAnimation(.easeOut(duration: 0.2)) { snapshot = img ?? snapshot }
        }
        .fullScreenCover(isPresented: $showMap) {
            LocationMapView(geo: geo, messageID: messageID, mine: mine)
                .environment(\.theme, theme).environment(\.lang, lang)
        }
    }

    @ViewBuilder
    private func pin(active: Bool) -> some View {
        if geo.isLive {
            ZStack {
                if active {
                    PulseRing(color: theme.accentColor)
                }
                Circle().fill(.white).frame(width: 30, height: 30).shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                Circle().fill(active ? theme.accentColor : Color.gray).frame(width: 22, height: 22)
                Image(systemName: "location.north.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .rotationEffect(.degrees(geo.heading ?? 0))
            }
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
                Annotation(geo.title ?? "", coordinate: coordinate) {
                    ZStack {
                        if geo.active() { PulseRing(color: theme.accentColor) }
                        if geo.isLive {
                            Circle().fill(.white).frame(width: 34, height: 34).shadow(radius: 3)
                            Circle().fill(geo.active() ? theme.accentColor : .gray).frame(width: 26, height: 26)
                            Image(systemName: "location.north.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                .rotationEffect(.degrees(geo.heading ?? 0))
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

// MARK: - Плашка в чате: «Вы транслируете геопозицию»

struct LiveLocationBar: View {
    let chatID: String

    @ObservedObject private var live = LiveLocationManager.shared
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        let mineHere = live.active(in: chatID)
        if let last = mineHere.max(by: { $0.until < $1.until }) {
            TimelineView(.periodic(from: .now, by: 30)) { tl in
                let left = max(1, Int(last.until.timeIntervalSince(tl.date) / 60))
                HStack(spacing: 10) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.22, green: 0.66, blue: 0.45))
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.t("Вы транслируете геопозицию", "You're sharing live location"))
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                        Text(left >= 60 ? s.t("ещё \(left / 60) ч \(left % 60) мин", "\(left / 60) h \(left % 60) min left")
                                        : s.t("ещё \(left) мин", "\(left) min left"))
                            .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        live.stopAll(in: chatID)
                        Haptics.impact(.medium)
                    } label: {
                        Text(s.t("Остановить", "Stop")).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.danger)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(theme.danger.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14).frame(height: 46)
                .glass(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 10)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
