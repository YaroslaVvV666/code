import SwiftUI
import Combine
import LocalAuthentication
import Security
import CryptoKit

/// Код-пароль на вход в приложение (+ Face ID / Touch ID). Хранится в связке ключей.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()

    @Published var locked: Bool
    @Published private(set) var enabled: Bool
    @Published var useBiometrics: Bool {
        didSet { UserDefaults.standard.set(useBiometrics, forKey: "applock.bio") }
    }

    private static let account = "orbita.passcode"

    init() {
        let on = Self.read() != nil
        enabled = on
        locked = on
        useBiometrics = UserDefaults.standard.object(forKey: "applock.bio") as? Bool ?? true
    }

    // MARK: Связка ключей

    private static func hash(_ code: String) -> Data {
        Data(SHA256.hash(data: Data(("orbita.salt." + code).utf8)))
    }

    private static func read() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
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
        Self.write(Self.hash(code))
        enabled = true
    }

    func disable() {
        Self.write(nil)
        enabled = false
        locked = false
    }

    func check(_ code: String) -> Bool { Self.read() == Self.hash(code) }

    func unlock(with code: String) -> Bool {
        guard check(code) else { return false }
        locked = false
        return true
    }

    var biometryName: String {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return c.biometryType == .touchID ? "Touch ID" : "Face ID"
    }

    var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    func unlockWithBiometrics() {
        guard enabled, useBiometrics, biometryAvailable else { return }
        LAContext().evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                   localizedReason: "Orbita") { ok, _ in
            if ok { Task { @MainActor in self.locked = false } }
        }
    }

    func lockNow() {
        guard enabled, !locked else { return }
        locked = true
    }
}

// MARK: - Цифровая клавиатура

struct PasscodePad: View {
    let title: String
    var subtitle: String? = nil
    var showsBiometrics = false
    var biometryIcon = "faceid"
    var onBiometrics: () -> Void = {}
    /// Возвращает false — код не подошёл (точки трясутся)
    let onComplete: (String) -> Bool

    @Environment(\.theme) private var theme
    @State private var code = ""
    @State private var shake: CGFloat = 0

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 8) {
                Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(theme.text)
                if let subtitle {
                    Text(subtitle).font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                }
            }
            HStack(spacing: 18) {
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(i < code.count ? theme.accentColor : Color.clear)
                        .overlay(Circle().stroke(theme.accentColor, lineWidth: 1.5))
                        .frame(width: 14, height: 14)
                }
            }
            .offset(x: shake)

            VStack(spacing: 14) {
                ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]], id: \.self) { row in
                    HStack(spacing: 22) { ForEach(row, id: \.self) { key($0) } }
                }
                HStack(spacing: 22) {
                    Button { onBiometrics() } label: {
                        Image(systemName: biometryIcon).font(.system(size: 26)).foregroundStyle(theme.accentColor)
                            .frame(width: 74, height: 74)
                    }
                    .buttonStyle(.plain).opacity(showsBiometrics ? 1 : 0).disabled(!showsBiometrics)
                    key("0")
                    Button { if !code.isEmpty { code.removeLast() } } label: {
                        Image(systemName: "delete.left").font(.system(size: 22)).foregroundStyle(theme.text)
                            .frame(width: 74, height: 74)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func key(_ d: String) -> some View {
        Button { tap(d) } label: {
            Text(d).font(.system(size: 30, weight: .medium)).foregroundStyle(theme.text)
                .frame(width: 74, height: 74)
                .background(theme.surface.opacity(0.9), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func tap(_ d: String) {
        guard code.count < 4 else { return }
        Haptics.impact(.light)
        code += d
        guard code.count == 4 else { return }
        let entered = code
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if onComplete(entered) { code = "" } else {
                Haptics.impact(.heavy)
                withAnimation(.default) { shake = 12 }
                withAnimation(.interpolatingSpring(stiffness: 600, damping: 6).delay(0.05)) { shake = 0 }
                code = ""
            }
        }
    }
}

// MARK: - Экран блокировки

struct AppLockView: View {
    @ObservedObject var lock: AppLock
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        ZStack {
            SpaceBackground(isDark: theme.dark, showStars: true).ignoresSafeArea()
            Color.black.opacity(0.25).ignoresSafeArea()
            PasscodePad(title: Strings(lang: lang).t("Введите код-пароль", "Enter passcode"),
                        showsBiometrics: lock.useBiometrics && lock.biometryAvailable,
                        biometryIcon: lock.biometryName == "Touch ID" ? "touchid" : "faceid",
                        onBiometrics: { lock.unlockWithBiometrics() }) { lock.unlock(with: $0) }
        }
        .onAppear {
            hideKeyboard()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { lock.unlockWithBiometrics() }
        }
    }
}

// MARK: - Настройка в «Конфиденциальности»

struct AppLockSettings: View {
    @ObservedObject private var lock = AppLock.shared
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var setup = false
    @State private var confirmOff = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        SettingsGroup {
            HStack(spacing: 14) {
                Image(systemName: "lock.rotation").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(Color.green, in: RoundedRectangle(cornerRadius: 8))
                Text(s.t("Код-пароль", "Passcode")).font(.system(size: 16)).foregroundStyle(theme.text)
                Spacer()
                Toggle("", isOn: Binding(get: { lock.enabled }, set: { on in
                    if on { setup = true } else { confirmOff = true }
                })).labelsHidden().tint(theme.accentColor)
            }
            .padding(.horizontal, 14).frame(height: 52)
            if lock.enabled && lock.biometryAvailable {
                SettingsDivider()
                HStack(spacing: 14) {
                    Image(systemName: lock.biometryName == "Touch ID" ? "touchid" : "faceid")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30).background(Color.blue, in: RoundedRectangle(cornerRadius: 8))
                    Text(lock.biometryName).font(.system(size: 16)).foregroundStyle(theme.text)
                    Spacer()
                    Toggle("", isOn: $lock.useBiometrics).labelsHidden().tint(theme.accentColor)
                }
                .padding(.horizontal, 14).frame(height: 52)
            }
        }
        .sheet(isPresented: $setup) {
            PasscodeSetupSheet { setup = false }
                .environment(\.theme, theme).environment(\.lang, lang)
                .presentationBackground(theme.sheet)
        }
        .sheet(isPresented: $confirmOff) {
            VStack {
                Spacer()
                PasscodePad(title: s.t("Введите код, чтобы выключить", "Enter passcode to turn off")) { code in
                    guard lock.check(code) else { return false }
                    lock.disable(); confirmOff = false
                    return true
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .environment(\.theme, theme).environment(\.lang, lang)
            .presentationBackground(theme.sheet)
        }
    }
}

struct PasscodeSetupSheet: View {
    let onDone: () -> Void
    @ObservedObject private var lock = AppLock.shared
    @Environment(\.lang) private var lang
    @State private var first: String?

    var body: some View {
        let s = Strings(lang: lang)
        VStack {
            Spacer()
            if let firstCode = first {
                PasscodePad(title: s.t("Повторите код", "Repeat the code")) { code in
                    guard code == firstCode else { return false }
                    lock.setCode(code); onDone()
                    return true
                }
                .id("second")
            } else {
                PasscodePad(title: s.t("Придумайте код", "Create a passcode"),
                            subtitle: s.t("4 цифры", "4 digits")) { code in
                    first = code
                    return true
                }
                .id("first")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
