import Foundation

/// Данные аккаунта на сервере: облачный пароль (2FA), почта и настройки.
/// Благодаря этому после выхода или на новом устройстве аккаунт открывается как был — без повторного имени и интересов.
/// Работает по токену сеанса из Keychain, поэтому может вызываться ещё до создания AppSession.
enum AccountClient {
    struct Remote {
        var twofa: Bool
        var hint: String?
        var email: String?
        var settings: [String: Any]?
    }

    enum CheckResult {
        case ok
        case wrong(attemptsLeft: Int)
        case locked(retryAfter: Int)
        case notEnabled                 // на сервере пароля нет (старый аккаунт, пароль только на этом телефоне)
        case unavailable                // нет сети или токена
    }

    private static func request(_ method: String, _ path: String, userID: String, body: [String: Any]? = nil) async -> (Int, [String: Any])? {
        guard let base = ServerConfig.baseURL,
              let token = Keychain.string(ServerAPI.tokenAccount(for: userID)),
              let url = URL(string: base.absoluteString + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = ServerAPI.json(body)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    static func fetch(userID: String) async -> Remote? {
        guard let (status, o) = await request("GET", "/v1/me/account", userID: userID), status == 200 else { return nil }
        let hint = o["hint"] as? String
        return Remote(twofa: o["twofa"] as? Bool ?? false, hint: (hint?.isEmpty ?? true) ? nil : hint,
                      email: o["email"] as? String, settings: o["settings"] as? [String: Any])
    }

    static func check(userID: String, password: String) async -> CheckResult {
        guard let (status, o) = await request("POST", "/v1/me/2fa/check", userID: userID, body: ["password": password]) else {
            return .unavailable
        }
        switch status {
        case 200: return .ok
        case 409: return .notEnabled
        case 429: return .locked(retryAfter: o["retry_after"] as? Int ?? 300)
        case 400: return .wrong(attemptsLeft: o["attempts_left"] as? Int ?? 0)
        default:  return .unavailable
        }
    }

    @discardableResult
    static func setPassword(userID: String, password: String, hint: String, current: String?) async -> Bool {
        var body: [String: Any] = ["password": password, "hint": hint]
        if let current { body["current"] = current }
        return (await request("PUT", "/v1/me/2fa", userID: userID, body: body))?.0 == 200
    }

    static func removePassword(userID: String, password: String) async {
        _ = await request("POST", "/v1/me/2fa/remove", userID: userID, body: ["password": password])
    }

    static func pushEmail(userID: String, email: String) async {
        _ = await request("PUT", "/v1/me/account", userID: userID, body: ["email": email])
    }

    static func pushSettings(userID: String, _ s: UserSettings) async {
        let object: [String: Any] = ["language": s.language, "dark": s.isDark, "accent": s.accent, "autoplay": s.autoplay]
        _ = await request("PUT", "/v1/me/account", userID: userID, body: ["settings": object])
    }

    static func settings(from object: [String: Any]) -> UserSettings? {
        guard let language = object["language"] as? String else { return nil }
        return UserSettings(language: language, isDark: object["dark"] as? Bool ?? true,
                            accent: object["accent"] as? Int ?? 0, autoplay: object["autoplay"] as? Bool ?? true)
    }
}
