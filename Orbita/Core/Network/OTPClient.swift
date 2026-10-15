import Foundation

/// Настоящие коды подтверждения: сервер сам отправляет SMS / письмо через провайдера.
/// Ключи провайдеров лежат только на сервере (см. Server/README.md).
enum OTPClient {
    enum SendResult {
        case sent(debugCode: String?, expiresIn: Int, resendIn: Int)
        /// Сервер недоступен или провайдеры не настроены — работаем локально, как раньше
        case unavailable
    }

    private static var lang: String { UserDefaults.standard.string(forKey: "lang") == "en" ? "en" : "ru" }

    static func send(channel: CodeChannel, to target: String) async throws -> SendResult {
        guard let (status, object) = await post("/v1/otp/send",
                                                ["channel": channel.rawValue, "to": target, "lang": lang]) else {
            return .unavailable
        }
        let code = object["error"] as? String
        switch status {
        case 200:
            return .sent(debugCode: object["debug_code"] as? String,
                         expiresIn: object["expires_in"] as? Int ?? 300,
                         resendIn: object["resend_in"] as? Int ?? 45)
        case 429:
            throw AuthError.tooManyRequests(retryAfter: object["retry_after"] as? Int ?? 60)
        case 503 where code == "otp_not_configured":
            return .unavailable
        case 502:
            throw AuthError.deliveryFailed
        case 400 where code == "bad_target":
            throw channel == .email ? AuthError.invalidEmail : AuthError.invalidPhone(.incomplete)
        default:
            return .unavailable
        }
    }

    enum VerifyResult {
        case none                               // кода достаточно, аккаунта на сервере ещё нет
        case login(QRLoginResult)               // аккаунт есть — сеанс выдан
        case twofa(TwoFAChallenge)              // аккаунт есть, но нужен облачный пароль
    }

    /// Проверяет код. Если на номер уже есть аккаунт на сервере, возвращает вход в него
    static func verify(channel: CodeChannel, to target: String, code: String) async throws -> VerifyResult {
        var body = DeviceInfo.fields
        body["channel"] = channel.rawValue
        body["to"] = target
        body["code"] = code
        if channel == .sms { body["login"] = "1" }
        guard let (status, object) = await post("/v1/otp/verify", body) else {
            throw AuthError.deliveryFailed
        }
        if status == 200 {
            if let login = object["login"] as? [String: Any],
               let token = login["token"] as? String, let id = login["user_id"] as? String {
                return .login(QRLoginResult(token: token, userID: id, name: (login["name"] as? String) ?? "", phone: target))
            }
            if let t = object["twofa"] as? [String: Any], let ticket = t["ticket"] as? String {
                return .twofa(TwoFAChallenge(ticket: ticket, hint: (t["hint"] as? String) ?? "",
                                             userID: (t["user_id"] as? String) ?? "",
                                             name: (t["name"] as? String) ?? "", phone: target))
            }
            return .none
        }
        switch object["error"] as? String {
        case "wrong_code":        throw AuthError.wrongCode(attemptsLeft: object["attempts_left"] as? Int ?? 0)
        case "code_expired":      throw AuthError.codeExpired
        case "too_many_attempts": throw AuthError.tooManyAttempts
        default:                  throw AuthError.unknown
        }
    }

    /// Второй шаг входа: пароль к билету, выданному после кода
    static func completeTwoFA(_ challenge: TwoFAChallenge, password: String) async throws -> QRLoginResult {
        guard let (status, object) = await post("/v1/auth/2fa", ["ticket": challenge.ticket, "password": password]) else {
            throw AuthError.deliveryFailed
        }
        if status == 200, let login = object["login"] as? [String: Any],
           let token = login["token"] as? String, let id = login["user_id"] as? String {
            return QRLoginResult(token: token, userID: id, name: (login["name"] as? String) ?? challenge.name,
                                 phone: challenge.phone)
        }
        throw passwordError(status: status, object: object)
    }

    static func passwordError(status: Int, object: [String: Any]) -> AuthError {
        switch object["error"] as? String {
        case "wrong_password": return .wrongPassword(attemptsLeft: object["attempts_left"] as? Int ?? 0)
        case "locked":         return .locked(retryAfter: object["retry_after"] as? Int ?? 300)
        case "code_expired":   return .codeExpired
        default:               return .unknown
        }
    }

    /// nil — сервер не отвечает
    private static func post(_ path: String, _ body: [String: String]) async -> (Int, [String: Any])? {
        guard let base = ServerConfig.baseURL, let url = URL(string: base.absoluteString + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = ServerAPI.json(body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (http.statusCode, object)
    }
}
