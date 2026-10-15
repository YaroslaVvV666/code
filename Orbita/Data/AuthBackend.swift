import Foundation

/// Всё, что в боевом приложении делает сервер авторизации.
/// LocalAuthBackend работает на устройстве; для реального сервера
/// напишите вторую реализацию этого протокола (URLSession + ваш API).
protocol AuthBackend: Sendable {
    func supportedLanguages() async -> [LanguageInfo]

    func phoneExists(_ phone: String) async -> Bool
    func requestCode(channel: CodeChannel, target: String, resendOf: CodeTicket?) async throws -> (CodeTicket, DeliveredMessage?)
    func verify(_ ticket: CodeTicket, code: String) async throws
    /// Сеанс существующего серверного аккаунта, полученный при проверке кода (один раз)
    func takeLogin(phone: String) async -> QRLoginResult?

    /// Аккаунт на сервере защищён облачным паролем: сеанс выдаётся только после него
    func twoFAChallenge(phone: String) async -> TwoFAChallenge?
    func completeTwoFA(phone: String, password: String) async throws -> QRLoginResult
    func discardTwoFA(phone: String) async
    /// Подтягивает с сервера пароль-маркер, почту и настройки (после входа на любом устройстве)
    func pullAccount(phone: String) async

    func signIn(phone: String) async -> UserRecord
    func user(id: String) async -> UserRecord?
    func setName(_ name: String, for phone: String) async
    func changePhone(from old: String, to new: String) async throws
    /// Вход по QR: аккаунт уже существует на сервере, здесь заводим для него локальную запись
    func adoptAccount(id: String, phone: String, name: String?) async -> UserRecord

    func isEmailTaken(_ email: String, excluding phone: String) async -> Bool
    func attachEmail(_ email: String, to phone: String) async throws

    func setPassword(_ password: String, hint: String, for phone: String) async throws
    func passwordHint(for phone: String) async -> String?
    func checkPassword(_ password: String, for phone: String) async throws
    func removePassword(for phone: String) async throws

    func loadSettings(phone: String) async -> UserSettings?
    func saveSettings(_ settings: UserSettings, phone: String) async

    func deleteAccount(phone: String) async
    func resetDatabase() async
}
