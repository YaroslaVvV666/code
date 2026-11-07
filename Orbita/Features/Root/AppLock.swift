import SwiftUI
import Combine
import LocalAuthentication
import Security
import CryptoKit
import AVFoundation
import UIKit

/// Код-пароль на вход в приложение + Face ID / Touch ID (как в Telegram).
///
/// Всё хранится только на этом устройстве: код — в связке ключей (`ThisDeviceOnly`: не уходит в iCloud и на другие
/// телефоны), настройки — в UserDefaults. Обновление приложения ничего не стирает. Переустановка — стирает: iOS
/// сохраняет связку ключей и после удаления приложения, поэтому при первом запуске «с нуля» старый код сбрасывается,
/// иначе человек, забывший код, не смог бы даже войти заново.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()

    @Published var locked: Bool {
        // заблокировались — все посторонние звуки (видео, голосовые, кружки) стихают; музыка играет дальше
        didSet { if locked && !oldValue { MediaSilence.pauseAll() } }
    }
    @Published private(set) var enabled: Bool
    @Published private(set) var codeLength: Int
    @Published var useBiometrics: Bool {
        didSet { UserDefaults.standard.set(useBiometrics, forKey: Keys.bio) }
    }
    /// Автоблокировка: через сколько секунд в фоне (или без касаний в открытом приложении) снова просить код.
    /// 0 — сразу при выходе; без касаний тогда — через 5 минут
    @Published var autoLock: Int {
        didSet { UserDefaults.standard.set(autoLock, forKey: Keys.auto) }
    }
    /// Слишком много неверных попыток — ввод закрыт до этого времени
    @Published private(set) var blockedUntil: Date?

    static let autoLockOptions = [0, 60, 300, 3600, 18000]

    private enum Keys {
        static let bio = "applock.bio"
        static let auto = "applock.auto"
        static let installed = "applock.installed"
        static let fails = "applock.fails"
        static let blocked = "applock.blockedUntil"
        static let wentBackground = "applock.bgAt"
        static let autoV2 = "applock.auto.v2"
    }
    private static let account = "orbita.passcode"

    /// Что лежит в связке ключей: соль, хэш (тысячи раундов HMAC) и длина кода
    private struct Stored: Codable {
        let salt: Data
        let hash: Data
        let length: Int
    }

    init() {
        let d = UserDefaults.standard
        // Первый запуск после установки (а не обновления): старый код из прошлой установки не действует.
        // Признак «уже стояло» — любая наша настройка в UserDefaults (их стирает только удаление приложения)
        if !d.bool(forKey: Keys.installed) {
            let hadData = d.object(forKey: "lang") != nil || d.object(forKey: Keys.bio) != nil
                || d.object(forKey: "isDark") != nil || d.object(forKey: "storySeen") != nil
            if !hadData { Self.write(nil) }
            d.set(true, forKey: Keys.installed)
        }
        let stored = Self.load()
        enabled = stored != nil
        locked = stored != nil
        codeLength = stored?.length ?? 4
        useBiometrics = d.object(forKey: Keys.bio) as? Bool ?? true
        // по умолчанию — через 5 минут: вышел и сразу вернулся — код не спрашивается.
        // Прежнее «сразу» (старое значение по умолчанию) один раз переводим на 5 минут
        if !d.bool(forKey: Keys.autoV2) {
            if (d.object(forKey: Keys.auto) as? Int ?? 0) == 0 { d.set(300, forKey: Keys.auto) }
            d.set(true, forKey: Keys.autoV2)
        }
        autoLock = d.object(forKey: Keys.auto) as? Int ?? 300
        let until = d.double(forKey: Keys.blocked)
        blockedUntil = until > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: until) : nil
    }

    // MARK: Связка ключей

    private static func derive(_ code: String, salt: Data) -> Data {
        // растянутый хэш: перебор 10⁴–10⁶ кодов по украденной копии связки ключей становится долгим
        var block = Data(HMAC<SHA256>.authenticationCode(for: Data(code.utf8), using: SymmetricKey(data: salt)))
        for _ in 0..<20_000 {
            block = Data(HMAC<SHA256>.authenticationCode(for: block, using: SymmetricKey(data: salt)))
        }
        return block
    }

    /// Старый формат (до этого обновления): просто SHA256 — продолжает работать, при следующей смене кода обновится
    private static func legacyHash(_ code: String) -> Data {
        Data(SHA256.hash(data: Data(("orbita.salt." + code).utf8)))
    }

    private static func readRaw() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func load() -> Stored? {
        guard let raw = readRaw() else { return nil }
        if let s = try? JSONDecoder().decode(Stored.self, from: raw) { return s }
        return Stored(salt: Data(), hash: raw, length: 4)               // старый 4-значный код
    }

    private static func write(_ data: Data?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let data else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    // MARK: Действия

    func setCode(_ code: String) {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let stored = Stored(salt: salt, hash: Self.derive(code, salt: salt), length: code.count)
        if let data = try? JSONEncoder().encode(stored) { Self.write(data) }
        enabled = true
        codeLength = code.count
        resetFails()
    }

    func disable() {
        Self.write(nil)
        enabled = false
        locked = false
        resetFails()
    }

    func check(_ code: String) -> Bool {
        guard let s = Self.load() else { return false }
        let ok = s.salt.isEmpty ? s.hash == Self.legacyHash(code) : s.hash == Self.derive(code, salt: s.salt)
        if ok { resetFails() } else { registerFail() }
        return ok
    }

    func unlock(with code: String) -> Bool {
        guard !isBlocked, check(code) else { return false }
        locked = false
        return true
    }

    // MARK: Неверные попытки

    var isBlocked: Bool { (blockedUntil ?? .distantPast) > Date() }

    private func registerFail() {
        let d = UserDefaults.standard
        let fails = d.integer(forKey: Keys.fails) + 1
        d.set(fails, forKey: Keys.fails)
        // 5 ошибок — минута паузы, дальше каждая ошибка удваивает паузу (до часа)
        guard fails >= 5 else { return }
        let wait = min(3600, 60 * pow(2, Double(fails - 5)))
        let until = Date().addingTimeInterval(wait)
        blockedUntil = until
        d.set(until.timeIntervalSince1970, forKey: Keys.blocked)
    }

    private func resetFails() {
        UserDefaults.standard.removeObject(forKey: Keys.fails)
        UserDefaults.standard.removeObject(forKey: Keys.blocked)
        blockedUntil = nil
    }

    // MARK: Face ID / Touch ID

    var biometryName: String {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return c.biometryType == .touchID ? "Touch ID" : (c.biometryType == .opticID ? "Optic ID" : "Face ID")
    }

    var biometryIcon: String { biometryName == "Touch ID" ? "touchid" : (biometryName == "Optic ID" ? "opticid" : "faceid") }

    var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    private var biometryRunning = false

    func unlockWithBiometrics() {
        guard enabled, locked, useBiometrics, biometryAvailable, !biometryRunning else { return }
        biometryRunning = true
        let context = LAContext()
        context.localizedFallbackTitle = Strings(lang: Self.lang).t("Ввести код", "Enter passcode")
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                               localizedReason: Strings(lang: Self.lang).t("Вход в Orbita", "Unlock Orbita")) { ok, _ in
            Task { @MainActor in
                self.biometryRunning = false
                if ok {
                    Haptics.notify(.success)
                    self.resetFails()
                    self.locked = false
                }
            }
        }
    }

    private static var lang: AppLanguage { AppLanguage(rawValue: UserDefaults.standard.string(forKey: "lang") ?? "") ?? .ru }

    // MARK: Автоблокировка

    /// Ушли в фон — запоминаем время (и при «сразу» блокируем)
    func didEnterBackground() {
        guard enabled, !locked else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.wentBackground)
        if autoLock == 0 { locked = true }
    }

    /// Вернулись — блокируем, если в фоне пробыли дольше выбранного
    func didBecomeActive() {
        guard enabled else { return }
        let at = UserDefaults.standard.double(forKey: Keys.wentBackground)
        if !locked, at > 0, Date().timeIntervalSince1970 - at >= Double(autoLock) { locked = true }
        UserDefaults.standard.removeObject(forKey: Keys.wentBackground)
        if locked { unlockWithBiometrics() }
    }

    func lockNow() {
        guard enabled, !locked else { return }
        locked = true
    }

    // MARK: Блокировка без действий

    /// Последнее касание экрана или ввод текста
    private var lastActivity = Date()
    private var idleTask: Task<Void, Never>?
    /// Сколько можно ничего не делать в открытом приложении: как автоблокировка, но не меньше 5 минут
    var idleLimit: TimeInterval { TimeInterval(max(300, autoLock)) }

    func touched() { lastActivity = Date() }

    /// Следим за бездействием, пока приложение на экране (раз в 10 секунд — почти бесплатно)
    func startIdleWatch() {
        lastActivity = Date()
        guard idleTask == nil else { return }
        idleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                // во время звонка экран не блокируем
                if self.enabled, !self.locked, !CallActivity.shared.active,
                   Date().timeIntervalSince(self.lastActivity) >= self.idleLimit {
                    self.locked = true
                }
            }
        }
    }

    func stopIdleWatch() {
        idleTask?.cancel()
        idleTask = nil
    }

    static func autoLockTitle(_ seconds: Int, _ s: Strings) -> String {
        switch seconds {
        case 0: return s.t("Сразу", "Immediately")
        case 60: return s.t("Через 1 мин", "After 1 min")
        case 300: return s.t("Через 5 мин", "After 5 min")
        case 3600: return s.t("Через 1 час", "After 1 hour")
        default: return s.t("Через 5 часов", "After 5 hours")
        }
    }
}

// MARK: - Цифровая клавиатура (как экран блокировки iPhone)

struct PasscodePad: View {
    let title: String
    var subtitle: String? = nil
    var length = 4
    var showsLock = false
    var showsBiometrics = false
    var biometryIcon = "faceid"
    var onBiometrics: () -> Void = {}
    /// Слева внизу вместо Face ID (например, «Отмена»)
    var leftTitle: String? = nil
    var onLeft: () -> Void = {}
    var disabledText: String? = nil
    /// Возвращает false — код не подошёл (точки трясутся)
    let onComplete: (String) -> Bool

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var code = ""
    @State private var shake: CGFloat = 0
    @State private var wrong = false

    private static let letters = ["", "A B C", "D E F", "G H I", "J K L", "M N O", "P Q R S", "T U V", "W X Y Z"]

    var body: some View {
        VStack(spacing: 0) {
            if showsLock {
                Image(systemName: wrong ? "lock.trianglebadge.exclamationmark.fill" : "lock.fill")
                    .font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .padding(.bottom, 26)
            }
            Text(title).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if let line = disabledText ?? subtitle {
                Text(line).font(.system(size: 14)).foregroundStyle(disabledText != nil ? Color.red.opacity(0.9) : Color.white.opacity(0.65))
                    .multilineTextAlignment(.center).padding(.top, 6)
            }
            HStack(spacing: length > 4 ? 22 : 26) {
                ForEach(0..<length, id: \.self) { i in
                    Circle().fill(i < code.count ? Color.white : Color.clear)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.4))
                        .frame(width: 13, height: 13)
                        .scaleEffect(i == code.count - 1 ? 1.15 : 1)
                        .animation(.spring(response: 0.2, dampingFraction: 0.5), value: code.count)
                }
            }
            .offset(x: shake)
            .padding(.top, 26)
            .padding(.bottom, 46)

            VStack(spacing: 18) {
                ForEach(0..<3, id: \.self) { r in
                    HStack(spacing: 26) {
                        ForEach(1...3, id: \.self) { c in key(String(r * 3 + c), letters: Self.letters[r * 3 + c - 1]) }
                    }
                }
                HStack(spacing: 26) {
                    Group {
                        if let leftTitle {
                            Button(leftTitle, action: onLeft).font(.system(size: 17)).foregroundStyle(.white)
                        } else if showsBiometrics {
                            Button(action: onBiometrics) {
                                Image(systemName: biometryIcon).font(.system(size: 30)).foregroundStyle(.white)
                            }
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 80, height: 80)
                    key("0", letters: "")
                    Button {
                        guard !code.isEmpty else { return }
                        Haptics.impact(.light)
                        code.removeLast()
                    } label: {
                        Text(Strings(lang: lang).t("Удалить", "Delete")).font(.system(size: 17)).foregroundStyle(.white)
                            .frame(width: 80, height: 80)
                    }
                    .buttonStyle(.plain)
                    .opacity(code.isEmpty ? 0 : 1)
                }
            }
            .disabled(disabledText != nil)
            .opacity(disabledText != nil ? 0.4 : 1)
        }
        .buttonStyle(.plain)
    }

    private func key(_ d: String, letters: String) -> some View {
        Button { tap(d) } label: {
            VStack(spacing: -2) {
                Text(d).font(.system(size: 36, weight: .regular)).foregroundStyle(.white)
                if !letters.isEmpty {
                    Text(letters).font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(.white)
                }
            }
            .frame(width: 80, height: 80)
            .background(Circle().fill(Color.white.opacity(0.12)))
            .overlay(Circle().stroke(theme.accentColor.opacity(0.35), lineWidth: 1))
            .contentShape(Circle())
        }
        .buttonStyle(PasscodeKeyStyle())
    }

    private func tap(_ d: String) {
        guard code.count < length else { return }
        Haptics.impact(.light)
        wrong = false
        code += d
        guard code.count == length else { return }
        let entered = code
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if onComplete(entered) { code = "" } else {
                Haptics.notify(.error)
                wrong = true
                withAnimation(.default) { shake = 14 }
                withAnimation(.interpolatingSpring(stiffness: 600, damping: 6).delay(0.05)) { shake = 0 }
                code = ""
            }
        }
    }
}

/// Нажатие клавиши: кружок светлеет, как на экране блокировки iPhone
private struct PasscodeKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.35 : 0)))
            .animation(.easeOut(duration: configuration.isPressed ? 0.02 : 0.35), value: configuration.isPressed)
    }
}

/// Тёмный фон с отсветом акцентного цвета — как на экране блокировки
struct PasscodeBackground: View {
    @Environment(\.theme) private var theme
    var body: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [theme.accentColor.opacity(0.35), .clear], center: .bottomLeading, startRadius: 20, endRadius: 600)
            RadialGradient(colors: [theme.accentColor.opacity(0.18), .clear], center: .topLeading, startRadius: 10, endRadius: 500)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Экран блокировки

struct AppLockView: View {
    @ObservedObject var lock: AppLock
    var onForgot: () -> Void = {}
    @Environment(\.lang) private var lang
    @State private var now = Date()
    @State private var askForgot = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var s: Strings { Strings(lang: lang) }

    private var waitText: String? {
        guard let until = lock.blockedUntil, until > now else { return nil }
        let sec = Int(until.timeIntervalSince(now).rounded(.up))
        return sec >= 60 ? s.t("Слишком много попыток. Повторите через \(sec / 60) мин \(sec % 60) с",
                               "Too many attempts. Try again in \(sec / 60) min \(sec % 60) s")
                         : s.t("Слишком много попыток. Повторите через \(sec) с", "Too many attempts. Try again in \(sec) s")
    }

    var body: some View {
        ZStack {
            PasscodeBackground()
            VStack {
                Spacer(minLength: 40)
                PasscodePad(title: s.t("Приложение заблокировано", "Orbita is locked"),
                            length: lock.codeLength,
                            showsLock: true,
                            showsBiometrics: lock.useBiometrics && lock.biometryAvailable,
                            biometryIcon: lock.biometryIcon,
                            onBiometrics: { lock.unlockWithBiometrics() },
                            disabledText: waitText) { lock.unlock(with: $0) }
                Spacer()
                Button(s.t("Забыли код?", "Forgot passcode?")) { askForgot = true }
                    .font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
        .onReceive(timer) { now = $0 }
        .onAppear {
            hideKeyboard()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { lock.unlockWithBiometrics() }
        }
        .confirmationDialog(s.t("Забыли код-пароль?", "Forgot your passcode?"), isPresented: $askForgot, titleVisibility: .visible) {
            Button(s.t("Выйти из аккаунта", "Log out"), role: .destructive) {
                lock.disable()
                onForgot()
            }
            Button(s.cancel, role: .cancel) {}
        } message: {
            Text(s.t("Код хранится только на этом телефоне, восстановить его нельзя. Можно выйти из аккаунта и войти заново "
                     + "по номеру — переписки останутся на сервере, а код-пароль сбросится.",
                     "The passcode is stored only on this phone and can't be recovered. You can log out and sign in again "
                     + "with your number — your chats stay on the server and the passcode is reset."))
        }
    }
}

// MARK: - Настройка в «Конфиденциальности»

struct AppLockSettings: View {
    @ObservedObject private var lock = AppLock.shared
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var setup = false
    @State private var change = false
    @State private var confirmOff = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        SettingsGroup {
            HStack(spacing: 14) {
                Image(systemName: "lock.rotation").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(Color.green, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.t("Код-пароль", "Passcode")).font(.system(size: 16)).foregroundStyle(theme.text)
                    Text(s.t("Только на этом устройстве", "Only on this device")).font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { lock.enabled }, set: { on in
                    if on { setup = true } else { confirmOff = true }
                })).labelsHidden().tint(theme.accentColor)
            }
            .padding(.horizontal, 14).frame(height: 56)
            if lock.enabled {
                SettingsDivider()
                Button { change = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "key.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30).background(Color.orange, in: RoundedRectangle(cornerRadius: 8))
                        Text(s.t("Сменить код-пароль", "Change passcode")).font(.system(size: 16)).foregroundStyle(theme.text)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textTertiary)
                    }
                    .padding(.horizontal, 14).frame(height: 52).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                SettingsDivider()
                HStack(spacing: 14) {
                    Image(systemName: "timer").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30).background(Color.purple, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.t("Автоблокировка", "Auto-lock")).font(.system(size: 16)).foregroundStyle(theme.text)
                        // и после выхода, и если в открытом приложении ничего не трогать (не меньше 5 минут)
                        Text(s.t("И без действий в приложении", "Also when idle in the app")).font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Picker("", selection: $lock.autoLock) {
                        ForEach(AppLock.autoLockOptions, id: \.self) { Text(AppLock.autoLockTitle($0, s)).tag($0) }
                    }
                    .pickerStyle(.menu).tint(theme.textSecondary)
                }
                .padding(.horizontal, 14).frame(height: 52)
                if lock.biometryAvailable {
                    SettingsDivider()
                    HStack(spacing: 14) {
                        Image(systemName: lock.biometryIcon)
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30).background(Color.blue, in: RoundedRectangle(cornerRadius: 8))
                        Text(s.t("Вход по \(lock.biometryName)", "Unlock with \(lock.biometryName)")).font(.system(size: 16))
                            .foregroundStyle(theme.text)
                        Spacer()
                        Toggle("", isOn: $lock.useBiometrics).labelsHidden().tint(theme.accentColor)
                    }
                    .padding(.horizontal, 14).frame(height: 52)
                }
            }
        }
        .fullScreenCover(isPresented: $setup) {
            PasscodeSetupView { setup = false }
                .environment(\.theme, theme).environment(\.lang, lang)
        }
        .fullScreenCover(isPresented: $change) {
            PasscodeSetupView(verifyOld: true) { change = false }
                .environment(\.theme, theme).environment(\.lang, lang)
        }
        .fullScreenCover(isPresented: $confirmOff) {
            ZStack {
                PasscodeBackground()
                PasscodePad(title: s.t("Введите код, чтобы выключить", "Enter passcode to turn off"),
                            length: lock.codeLength, leftTitle: s.cancel, onLeft: { confirmOff = false }) { code in
                    guard lock.check(code) else { return false }
                    lock.disable(); confirmOff = false
                    return true
                }
            }
            .preferredColorScheme(.dark)
            .environment(\.theme, theme).environment(\.lang, lang)
        }
    }
}

/// Создание или смена кода: (старый код →) новый код (4 или 6 цифр) → повтор
struct PasscodeSetupView: View {
    var verifyOld = false
    let onDone: () -> Void
    @ObservedObject private var lock = AppLock.shared
    @Environment(\.lang) private var lang
    @State private var oldOK = false
    @State private var first: String?
    @State private var length = 4

    var body: some View {
        let s = Strings(lang: lang)
        ZStack {
            PasscodeBackground()
            VStack {
                Spacer()
                if verifyOld && !oldOK {
                    PasscodePad(title: s.t("Введите текущий код", "Enter your current passcode"), length: lock.codeLength,
                                leftTitle: s.cancel, onLeft: onDone) { code in
                        guard lock.check(code) else { return false }
                        oldOK = true
                        return true
                    }
                    .id("old")
                } else if let firstCode = first {
                    PasscodePad(title: s.t("Повторите код", "Repeat the passcode"), length: length,
                                leftTitle: s.cancel, onLeft: onDone) { code in
                        guard code == firstCode else {
                            first = nil
                            return false
                        }
                        lock.setCode(code)
                        Haptics.notify(.success)
                        onDone()
                        return true
                    }
                    .id("second")
                } else {
                    PasscodePad(title: s.t("Придумайте код-пароль", "Create a passcode"),
                                subtitle: s.t("Будет спрашиваться при входе в приложение на этом телефоне",
                                              "Asked when you open the app on this phone"),
                                length: length, leftTitle: s.cancel, onLeft: onDone) { code in
                        first = code
                        return true
                    }
                    .id("first-\(length)")
                    Button {
                        Haptics.select()
                        length = length == 4 ? 6 : 4
                    } label: {
                        Text(length == 4 ? s.t("Код из 6 цифр", "6-digit passcode") : s.t("Код из 4 цифр", "4-digit passcode"))
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).frame(height: 36)
                            .background(Color.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 22)
                }
                Spacer()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Тишина при блокировке

/// Плееры видео, голосовых и кружков регистрируются здесь; при блокировке все они встают на паузу.
/// Музыка (плеер плейлистов) сюда не входит — её блокировка не трогает, в том числе в фоне
@MainActor
enum MediaSilence {
    private static let players = NSHashTable<AVPlayer>.weakObjects()

    static func register(_ p: AVPlayer) { players.add(p) }

    static func pauseAll() {
        for p in players.allObjects { p.pause() }
        VoicePlayer.shared.stop()
        CircleFocus.shared.stop()
    }
}

// MARK: - Касания для блокировки без действий

/// Ловит любое касание в окне (не мешая самим касаниям) и сообщает AppLock, что человек что-то делает
final class ActivityTouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        Task { @MainActor in AppLock.shared.touched() }
        state = .failed
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Ставит распознаватель касаний на окно приложения; ввод текста тоже считается действием
struct ActivityTracker: UIViewRepresentable {
    final class Probe: UIView {
        private var installed: UIWindow?
        private var observers: [NSObjectProtocol] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, installed !== window else { return }
            installed = window
            window.addGestureRecognizer(ActivityTouchRecognizer())
            if observers.isEmpty {
                for name in [UITextView.textDidChangeNotification, UITextField.textDidChangeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                        Task { @MainActor in AppLock.shared.touched() }
                    })
                }
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: Probe, context: Context) {}
}
