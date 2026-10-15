import SwiftUI
import Combine

enum FlowStep: Equatable {
    case launch
    case phone, phoneCode, passwordLogin, name
    case emailOffer, emailInput, emailCode
    case twoFAOffer, twoFASetup
    case interests
    case done, home
}

/// Настройки аккаунта, восстановленные из базы после входа
struct SettingsRestore: Equatable {
    let id = UUID()
    let settings: UserSettings
}

/// Состояние и логика регистрации / входа. Экранов не знает — только шаги.
@MainActor
final class AuthFlow: ObservableObject {
    let backend: AuthBackend = LocalAuthBackend()
    private let sessionAccount = "orbita.session"

    @Published var step: FlowStep = .launch { didSet { error = nil } }
    @Published var isLoading = false
    @Published var error: AuthError?
    @Published var inbox: DeliveredMessage?
    @Published var keyboardVisible = false

    // языки из базы и настройки аккаунта
    @Published var languages: [LanguageInfo] = []
    @Published var restore: SettingsRestore?
    var deviceSettings = UserSettings(language: "ru", isDark: true)
    private var signedInPhone: String?

    // телефон
    @Published var country: Country? = countries[0]
    @Published var code = "+7"
    @Published var phone = ""
    @Published var isExistingUser = false
    @Published var twoFAChallenge: TwoFAChallenge?
    @Published var phoneTicket: CodeTicket?

    // почта
    @Published var email = ""
    @Published var emailTicket: CodeTicket?
    @Published var changeTicket: CodeTicket?        // смена номера из профиля (SMS на новый номер)
    @Published var changeEmailTicket: CodeTicket?   // и письмо на привязанную почту
    @Published var loginEmailTicket: CodeTicket?    // смена почты из профиля

    // аккаунт
    @Published var userID: String?
    @Published var userName = ""
    @Published var linkedEmail: String?
    @Published var twoFAEnabled = false
    @Published var twoFAHint: String?

    init() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.languages = await self.backend.supportedLanguages()
            await self.restoreSession()
        }
    }

    var phoneDigits: String { phone.hasPrefix("+") ? "" : String(phone.filter(\.isNumber)) }
    var e164: String { code + phoneDigits }
    var displayPhone: String { code + " " + formatDigits(phoneDigits, code: code, separator: " ") }

    /// Языки из таблицы languages (только те, что поддерживает интерфейс)
    var availableLanguages: [LanguageInfo] {
        let fromDB = languages.filter { AppLanguage(rawValue: $0.code) != nil }
        if !fromDB.isEmpty { return fromDB }
        return AppLanguage.allCases.map { LanguageInfo(code: $0.rawValue, name: $0.title, nativeName: $0.title) }
    }

    var canGoBack: Bool {
        switch step {
        case .phoneCode, .passwordLogin, .emailInput, .emailCode, .twoFASetup: return true
        default: return false
        }
    }

    // MARK: Сессия (id пользователя в Keychain)

    private func restoreSession() async {
        try? await Task.sleep(nanoseconds: 700_000_000)          // короткая заставка
        if let id = Keychain.string(sessionAccount), let record = await backend.user(id: id) {
            adopt(record)
            signedInPhone = record.phone
            if let saved = await backend.loadSettings(phone: record.phone) {
                deviceSettings = saved
                restore = SettingsRestore(settings: saved)
            }
            step = .home
        } else {
            Keychain.delete(sessionAccount)
            step = .phone
        }
    }

    private func adopt(_ record: UserRecord) {
        if let split = splitE164(record.phone) {
            country = split.country
            code = split.country.code
            phone = formatDigits(split.digits, code: split.country.code)
        }
        userID = record.id
        userName = record.name ?? ""
        linkedEmail = record.email
        twoFAEnabled = record.hasTwoFactor
    }

    // MARK: Настройки (язык и тема в базе)

    func updateDeviceSettings(_ settings: UserSettings) {
        deviceSettings = settings
        guard let phone = signedInPhone else { return }
        Task { @MainActor in await backend.saveSettings(settings, phone: phone) }
    }

    // MARK: Телефон

    func submitPhone() async {
        error = nil
        if let issue = Validator.validatePhone(code: code, digits: phoneDigits) {
            error = .invalidPhone(issue)
            return
        }
        // уже запрашивали код на этот номер и он ещё действует — не шлём второй
        if let t = phoneTicket, t.target == e164, t.expiresAt > Date() {
            step = .phoneCode
            return
        }
        isLoading = true
        isExistingUser = await backend.phoneExists(e164)      // проверка по базе
        isLoading = false
        if await issueCode(channel: .sms, target: e164, previous: nil) { step = .phoneCode }
    }

    func verifyPhoneCode(_ value: String) async -> Bool {
        guard let ticket = phoneTicket else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            try await backend.verify(ticket, code: value)
            // аккаунт защищён облачным паролем: сеанс выдадим только после него
            if let challenge = await backend.twoFAChallenge(phone: e164) {
                twoFAChallenge = challenge
                isExistingUser = true
                twoFAEnabled = true
                twoFAHint = challenge.hint.isEmpty ? nil : challenge.hint
                userName = challenge.name
                inbox = nil
                phoneTicket = nil
                step = .passwordLogin
                return true
            }
            let record: UserRecord
            if let login = await backend.takeLogin(phone: e164) {
                // на этот номер уже есть аккаунт на сервере: входим в него, а не создаём новый
                record = await completeLogin(login, phone: e164)
                isExistingUser = true
            } else {
                record = await backend.signIn(phone: e164)
                adopt(record)
                signedInPhone = e164
                await restoreSettings(phone: e164)
            }

            inbox = nil
            phoneTicket = nil
            if record.hasTwoFactor {
                twoFAHint = await backend.passwordHint(for: e164)
                step = .passwordLogin
            } else if record.name == nil {
                step = .name
            } else if isExistingUser {
                step = .done
            } else {
                step = .interests
            }
            return true
        } catch {
            handle(error)
            return false
        }
    }

    /// Вход в существующий серверный аккаунт: токен, локальная запись, и с сервера возвращаются имя, почта, пароль и настройки
    private func completeLogin(_ login: QRLoginResult, phone: String) async -> UserRecord {
        Keychain.setString(login.token, account: ServerAPI.tokenAccount(for: login.userID))
        var record = await backend.adoptAccount(id: login.userID, phone: phone, name: login.name)
        await backend.pullAccount(phone: record.phone)
        record = await backend.user(id: record.id) ?? record
        adopt(record)
        signedInPhone = record.phone
        await restoreSettings(phone: record.phone)
        return record
    }

    /// Язык и тема аккаунта: берём из базы или сохраняем текущие
    private func restoreSettings(phone: String) async {
        if let saved = await backend.loadSettings(phone: phone) {
            deviceSettings = saved
            restore = SettingsRestore(settings: saved)
        } else {
            await backend.saveSettings(deviceSettings, phone: phone)
        }
    }

    func resendPhoneCode() async {
        guard let old = phoneTicket else { return }
        _ = await issueCode(channel: .sms, target: e164, previous: old)
    }

    // MARK: Вход с паролем

    func checkPassword(_ password: String) async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            if twoFAChallenge != nil {
                // вход по коду на новом устройстве: пароль отдаём серверу, он выдаёт сеанс
                let login = try await backend.completeTwoFA(phone: e164, password: password)
                twoFAChallenge = nil
                let record = await completeLogin(login, phone: e164)
                if userName.isEmpty { userName = login.name }
                step = record.name == nil && userName.isEmpty ? .name : .done
                return true
            }
            try await backend.checkPassword(password, for: e164)
            step = userName.isEmpty ? .name : .done
            return true
        } catch {
            handle(error)
            return false
        }
    }

    // MARK: Имя

    /// Из регистрации (шаг .name) или из профиля
    func saveName(_ raw: String) async -> Bool {
        let name = Validator.normalizeName(raw)
        guard Validator.isValidName(name) else {
            if step == .name { error = .invalidName }
            return false
        }
        isLoading = true
        defer { isLoading = false }
        await backend.setName(name, for: e164)
        userName = name
        if step == .name { step = isExistingUser ? .done : .interests }
        return true
    }

    // MARK: Интересы (для ленты «Для вас»)

    func finishInterests(_ topics: [String]) {
        if let id = userID { InterestsStore.save(topics, user: id) }
        step = .done
    }

    // MARK: Почта (необязательна: добавляется в настройках)

    func startEmail() { step = .emailInput }
    func skipEmail() { step = .twoFAOffer }

    func submitEmail() async {
        error = nil
        let normalized = Validator.normalizeEmail(email)
        guard Validator.isValidEmail(normalized) else { error = .invalidEmail; return }

        isLoading = true
        let taken = await backend.isEmailTaken(normalized, excluding: e164)   // проверка по базе
        isLoading = false
        if taken { error = .emailTaken; return }

        email = normalized
        if let t = emailTicket, t.target == normalized, t.expiresAt > Date() {
            step = .emailCode
            return
        }
        if await issueCode(channel: .email, target: normalized, previous: nil) { step = .emailCode }
    }

    func verifyEmailCode(_ value: String) async -> Bool {
        guard let ticket = emailTicket else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            try await backend.verify(ticket, code: value)
            try await backend.attachEmail(ticket.target, to: e164)
            linkedEmail = ticket.target
            emailTicket = nil
            inbox = nil
            step = .twoFAOffer
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func resendEmailCode() async {
        guard let old = emailTicket else { return }
        _ = await issueCode(channel: .email, target: old.target, previous: old)
    }

    // MARK: Двухфакторная защита

    func startTwoFA() { step = .twoFASetup }
    func skipTwoFA() { step = .done }

    /// Подсказка не должна выдавать пароль
    private func cleanHint(_ raw: String, password: String) -> String? {
        let hint = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if hint.isEmpty { return "" }
        if hint.lowercased().contains(password.lowercased()) { return nil }
        return String(hint.prefix(80))
    }

    func refreshTwoFAHint() async {
        twoFAHint = twoFAEnabled ? await backend.passwordHint(for: e164) : nil
    }

    func savePassword(_ password: String, confirm: String, hint: String = "") async -> Bool {
        guard Validator.isAcceptablePassword(password, phoneDigits: phoneDigits) else {
            error = .weakPassword
            return false
        }
        guard password == confirm else {
            error = .passwordMismatch
            return false
        }
        guard let cleaned = cleanHint(hint, password: password) else { error = .hintGivesAway; return false }
        isLoading = true
        defer { isLoading = false }
        do {
            try await backend.setPassword(password, hint: cleaned, for: e164)
            twoFAEnabled = true
            twoFAHint = cleaned.isEmpty ? nil : cleaned
            if step == .twoFASetup { step = .done }
            return true
        } catch {
            handle(error)
            return false
        }
    }

    /// Из профиля: сменить пароль (нужен текущий)
    func changeTwoFA(current: String, new: String, confirm: String, hint: String = "") async -> Bool {
        guard Validator.isAcceptablePassword(new, phoneDigits: phoneDigits) else { error = .weakPassword; return false }
        guard new == confirm else { error = .passwordMismatch; return false }
        guard let cleaned = cleanHint(hint, password: new) else { error = .hintGivesAway; return false }
        isLoading = true
        defer { isLoading = false }
        do {
            try await backend.checkPassword(current, for: e164)
            try await backend.setPassword(new, hint: cleaned, for: e164)
            twoFAHint = cleaned.isEmpty ? nil : cleaned
            return true
        } catch {
            handle(error)
            return false
        }
    }

    /// Из профиля: отключить двухфакторную защиту (нужен текущий пароль)
    func disableTwoFA(current: String) async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            try await backend.checkPassword(current, for: e164)
            try await backend.removePassword(for: e164)
            twoFAEnabled = false
            twoFAHint = nil
            return true
        } catch {
            handle(error)
            return false
        }
    }

    // MARK: Смена номера (из профиля)

    /// "8 981 799-02-69", "+7 981…", "9817990269" → "+79817990269"
    private func normalizedE164(_ raw: String) -> String? {
        let hasPlus = raw.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        var digits = raw.filter(\.isNumber)
        if !hasPlus {
            let own = String(code.dropFirst())
            if code == "+7", digits.count == 11, digits.hasPrefix("8") { digits = "7" + digits.dropFirst() }
            else if digits.count <= 10 { digits = own + digits }
        }
        guard digits.count >= 8 else { return nil }
        return "+" + digits
    }

    /// Отправляет код на новый номер. true — код отправлен.
    func requestPhoneChange(_ raw: String, password: String = "") async -> Bool {
        error = nil
        // двухфакторная защита включена — без пароля номер не сменить
        if twoFAEnabled {
            guard !password.isEmpty else { error = .passwordRequired; return false }
            isLoading = true
            do { try await backend.checkPassword(password, for: e164) } catch { isLoading = false; handle(error); return false }
            isLoading = false
        }
        guard let number = normalizedE164(raw), let split = splitE164(number) else {
            error = .invalidPhone(.incomplete)
            return false
        }
        if let issue = Validator.validatePhone(code: split.country.code, digits: split.digits) {
            error = .invalidPhone(issue)
            return false
        }
        if number == e164 { error = .phoneTaken; return false }
        if let t = changeTicket, t.target == number, t.expiresAt > Date() { return true }

        isLoading = true
        let taken = await backend.phoneExists(number)
        isLoading = false
        if taken { error = .phoneTaken; return false }

        isLoading = true
        defer { isLoading = false }
        do {
            let (ticket, message) = try await backend.requestCode(channel: .sms, target: number, resendOf: changeTicket)
            changeTicket = ticket
            // есть почта — второй код уходит письмом
            if let mail = linkedEmail {
                let (mailTicket, mailMessage) = try await backend.requestCode(channel: .email, target: mail, resendOf: changeEmailTicket)
                changeEmailTicket = mailTicket
                inbox = mailMessage ?? message
            } else {
                inbox = message
            }
            return true
        } catch {
            handle(error)
            return false
        }
    }

    /// Проверяет код и меняет номер. Возвращает новый номер в формате E.164.
    func confirmPhoneChange(_ value: String, emailCode: String = "") async -> String? {
        guard let ticket = changeTicket else { return nil }
        isLoading = true
        defer { isLoading = false }
        do {
            if linkedEmail != nil {
                guard let mailTicket = changeEmailTicket else { return nil }
                try await backend.verify(mailTicket, code: emailCode)
            }
            try await backend.verify(ticket, code: value)
            try await backend.changePhone(from: e164, to: ticket.target)
            if let split = splitE164(ticket.target) {
                country = split.country
                code = split.country.code
                phone = formatDigits(split.digits, code: split.country.code)
            }
            signedInPhone = ticket.target
            changeTicket = nil
            changeEmailTicket = nil
            inbox = nil
            return ticket.target
        } catch {
            handle(error)
            return nil
        }
    }

    // MARK: Почта для входа (из профиля)

    func requestLoginEmail(_ raw: String) async -> Bool {
        error = nil
        let normalized = Validator.normalizeEmail(raw)
        guard Validator.isValidEmail(normalized) else { error = .invalidEmail; return false }
        isLoading = true
        let taken = await backend.isEmailTaken(normalized, excluding: e164)
        isLoading = false
        if taken && normalized != linkedEmail { error = .emailTaken; return false }
        if let t = loginEmailTicket, t.target == normalized, t.expiresAt > Date() { return true }

        isLoading = true
        defer { isLoading = false }
        do {
            let (ticket, message) = try await backend.requestCode(channel: .email, target: normalized,
                                                                  resendOf: loginEmailTicket)
            loginEmailTicket = ticket
            deliver(message)
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func confirmLoginEmail(_ value: String) async -> Bool {
        guard let ticket = loginEmailTicket else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            try await backend.verify(ticket, code: value)
            try await backend.attachEmail(ticket.target, to: e164)
            linkedEmail = ticket.target
            loginEmailTicket = nil
            inbox = nil
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func cancelLoginEmail() {
        loginEmailTicket = nil
        inbox = nil
        error = nil
    }

    func cancelPhoneChange() {
        changeTicket = nil
        changeEmailTicket = nil
        inbox = nil
        error = nil
    }

    // MARK: Вход по QR-коду (с другого устройства)

    func finishQRLogin(_ result: QRLoginResult) async {
        isLoading = true
        defer { isLoading = false }
        // токен сеанса кладём туда, где его ищет ServerAPI
        Keychain.setString(result.token, account: ServerAPI.tokenAccount(for: result.userID))

        let phone = result.phone.isEmpty ? "+0" + String(result.userID.filter(\.isHexDigit).prefix(11)) : result.phone
        let record = await completeLogin(result, phone: phone)
        isExistingUser = true
        Keychain.setString(record.id, account: sessionAccount)
        inbox = nil
        step = .home
    }

    // MARK: Навигация и служебное

    func enterApp() {
        if let id = userID { Keychain.setString(id, account: sessionAccount) }
        step = .home
    }

    func back() {
        inbox = nil
        switch step {
        case .phoneCode, .passwordLogin:
            if twoFAChallenge != nil {
                twoFAChallenge = nil
                Task { await backend.discardTwoFA(phone: e164) }
            }
            step = .phone
        case .emailInput:                step = .emailOffer
        case .emailCode:                 step = .emailInput
        case .twoFASetup:                step = .twoFAOffer
        default: break
        }
    }

    func logout() {
        Keychain.delete(sessionAccount)
        step = .phone
        phone = ""
        email = ""
        country = countries[0]
        code = "+7"
        phoneTicket = nil
        emailTicket = nil
        changeTicket = nil
        userID = nil
        userName = ""
        linkedEmail = nil
        twoFAEnabled = false
        twoFAHint = nil
        isExistingUser = false
        twoFAChallenge = nil
        signedInPhone = nil
        restore = nil
        inbox = nil
    }

    func deleteAccount() async {
        isLoading = true
        await backend.deleteAccount(phone: e164)
        isLoading = false
        logout()
    }

    func resetDatabase() async {
        await backend.resetDatabase()
        logout()
    }

    private func issueCode(channel: CodeChannel, target: String, previous: CodeTicket?) async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            let (ticket, message) = try await backend.requestCode(channel: channel, target: target, resendOf: previous)
            if channel == .sms { phoneTicket = ticket } else { emailTicket = ticket }
            deliver(message)
            return true
        } catch {
            handle(error)
            return false
        }
    }

    private func deliver(_ message: DeliveredMessage?) {
        guard let message else { return }
        inbox = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if inbox?.id == message.id { inbox = nil }
        }
    }

    private func handle(_ error: Error) {
        self.error = (error as? AuthError) ?? .unknown
    }
}
