import Foundation

struct QRLoginSession: Equatable {
    let id: String
    let secret: String
    let expiresIn: TimeInterval
    var link: String { "orbita://login?id=\(id)" }
}

enum QRLoginStatus: Equatable {
    case pending, expired
    /// QR подтверждён с основного устройства, но в аккаунте есть облачный пароль
    case needsPassword(hint: String)
    case approved(QRLoginResult)
}

/// Вход по QR без токена: новое устройство показывает код и ждёт подтверждения с уже вошедшего.
enum QRLoginClient {
    private static func url(_ path: String, query: [String: String] = [:]) throws -> URL {
        guard let base = ServerConfig.baseURL else { throw APIError.notConfigured }
        var components = URLComponents(string: base.absoluteString + path)
        if !query.isEmpty { components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components?.url else { throw APIError.notConfigured }
        return url
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.server(status: http.statusCode, code: (object["error"] as? String) ?? "error")
            }
            return object
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.offline
        }
    }

    static func start() async throws -> QRLoginSession {
        var request = URLRequest(url: try url("/v1/qr"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = ServerAPI.json(DeviceInfo.fields)
        let object = try await send(request)
        guard let id = object["id"] as? String, let secret = object["secret"] as? String else {
            throw APIError.invalidResponse
        }
        return QRLoginSession(id: id, secret: secret, expiresIn: (object["expires_in"] as? Double) ?? 120)
    }

    /// Пароль после сканирования: только с ним сервер выдаёт сеанс
    static func submitPassword(_ session: QRLoginSession, password: String) async throws -> QRLoginResult {
        var request = URLRequest(url: try url("/v1/qr/\(session.id)/2fa"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = ServerAPI.json(["secret": session.secret, "password": password])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { throw AuthError.deliveryFailed }
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if http.statusCode == 200, let token = object["token"] as? String, let userID = object["user_id"] as? String {
            return QRLoginResult(token: token, userID: userID, name: (object["name"] as? String) ?? "",
                                 phone: (object["phone"] as? String) ?? "")
        }
        if http.statusCode == 404 { throw AuthError.codeExpired }
        throw OTPClient.passwordError(status: http.statusCode, object: object)
    }

    static func poll(_ session: QRLoginSession) async throws -> QRLoginStatus {
        var request = URLRequest(url: try url("/v1/qr/\(session.id)", query: ["secret": session.secret]), timeoutInterval: 15)
        request.httpMethod = "GET"
        let object: [String: Any]
        do {
            object = try await send(request)
        } catch APIError.server(let status, _) where status == 404 {
            return .expired
        }
        switch object["status"] as? String {
        case "pending":  return .pending
        case "expired":  return .expired
        case "twofa":    return .needsPassword(hint: (object["hint"] as? String) ?? "")
        case "approved":
            guard let token = object["token"] as? String, let userID = object["user_id"] as? String else {
                throw APIError.invalidResponse
            }
            return .approved(QRLoginResult(token: token, userID: userID,
                                           name: (object["name"] as? String) ?? "",
                                           phone: (object["phone"] as? String) ?? ""))
        default:
            throw APIError.invalidResponse
        }
    }
}
