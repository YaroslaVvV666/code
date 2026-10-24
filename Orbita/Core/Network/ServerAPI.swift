import Combine
import Foundation
import CryptoKit

enum APIError: Error, Equatable {
    case notConfigured
    case offline
    case unauthorized
    case invalidResponse
    case server(status: Int, code: String)
}

extension JSONDecoder {
    static let orbita: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

/// Клиент сервера Orbita. Сам регистрирует устройство при первом обращении:
/// токен выдаётся один раз и хранится в Keychain.
actor ServerAPI {
    enum Payload {
        case data(Data)
        case file(URL)
    }

    private let userID: String
    private var displayName: String
    private var token: String?
    private var tokenBase: String?
    private var pendingRegistration: Task<String, Error>?

    init(userID: String, displayName: String) {
        self.userID = userID
        self.displayName = displayName
    }

    func updateDisplayName(_ name: String) { displayName = name }

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// Проверка адреса без регистрации
    static func ping(_ base: URL) async -> Bool {
        guard let url = URL(string: base.absoluteString + "/v1/ping") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.httpMethod = "GET"
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["ok"] as? Bool == true
    }

    // MARK: Запросы

    func request(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil) async throws -> Data {
        for attempt in 0..<2 {
            do {
                var req = try await authorized(method, path, query: query)
                if let body {
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = body
                }
                return try await perform(req, upload: nil)
            } catch APIError.unauthorized where attempt == 0 {
                forgetToken()
            }
        }
        throw APIError.unauthorized
    }

    func upload(_ path: String, query: [String: String], payload: Payload, contentType: String) async throws -> Data {
        for attempt in 0..<2 {
            do {
                var req = try await authorized("POST", path, query: query)
                req.setValue(contentType, forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 300
                return try await perform(req, upload: payload)
            } catch APIError.unauthorized where attempt == 0 {
                forgetToken()
            }
        }
        throw APIError.unauthorized
    }

    // MARK: Внутреннее

    private func makeURL(_ path: String, query: [String: String]) throws -> URL {
        guard let base = ServerConfig.baseURL else { throw APIError.notConfigured }
        var components = URLComponents(string: base.absoluteString + path)
        if !query.isEmpty { components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components?.url else { throw APIError.notConfigured }
        return url
    }

    private func authorized(_ method: String, _ path: String, query: [String: String]) async throws -> URLRequest {
        let url = try makeURL(path, query: query)
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        let token = try await ensureToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    static func tokenAccount(for userID: String) -> String { "orbita.token.\(userID)@\(ServerConfig.urlString)" }
    private var tokenAccount: String { Self.tokenAccount(for: userID) }

    /// GET с запасом на диске: пока сети нет, отдаём последний удачный ответ — чаты и переписки видны до момента пропадания связи.
    /// slot — отдельная ячейка для разных видов одного запроса (быстрый просмотр и полная загрузка), fallback — откуда брать, если своя пуста
    func requestCached(_ path: String, query: [String: String] = [:], slot: String = "", fallback: [String] = []) async throws -> Data {
        do {
            let data = try await request("GET", path, query: query)
            OfflineStore.save(data, user: userID, path: path, slot: slot)
            await NetworkState.shared.set(offline: false)
            return data
        } catch let error as APIError where error == .offline {
            await NetworkState.shared.set(offline: true)
            for s in [slot] + fallback {
                if let cached = OfflineStore.load(user: userID, path: path, slot: s) { return cached }
            }
            throw error
        }
    }

    /// Последний сохранённый ответ без обращения к сети: экран показывается сразу (и без интернета),
    /// а свежие данные приходят следом обычным запросом
    nonisolated func cachedResponse(_ path: String, slot: String = "", fallback: [String] = []) -> Data? {
        for s in [slot] + fallback {
            if let data = OfflineStore.load(user: userID, path: path, slot: s) { return data }
        }
        return nil
    }

    /// Выход: завершаем свой сеанс на сервере и забываем токен
    func signOut() async {
        OfflineStore.wipe(user: userID)
        if let data = try? await request("GET", "/v1/sessions"),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = object["sessions"] as? [[String: Any]],
           let current = list.first(where: { ($0["current"] as? Bool) == true }),
           let id = current["id"] as? String {
            _ = try? await request("DELETE", "/v1/sessions/\(id)")
        }
        forgetToken()
    }

    private func forgetToken() {
        Keychain.delete(tokenAccount)
        token = nil
    }

    private func ensureToken() async throws -> String {
        if tokenBase != ServerConfig.urlString { token = nil; tokenBase = ServerConfig.urlString }
        if let token { return token }
        if let saved = Keychain.string(tokenAccount) {
            token = saved
            return saved
        }
        // Несколько запросов стартуют одновременно (профиль, лента…): регистрируемся один раз,
        // остальные ждут тот же результат. Иначе второй запрос получил бы «user_exists» и выкинул из аккаунта.
        if let pendingRegistration { return try await pendingRegistration.value }
        let task = Task { try await self.register() }
        pendingRegistration = task
        defer { pendingRegistration = nil }
        return try await task.value
    }

    private func register() async throws -> String {
        // первая регистрация на этом сервере
        var req = URLRequest(url: try makeURL("/v1/session", query: [:]), timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var fields = DeviceInfo.fields
        fields["user_id"] = userID
        fields["name"] = displayName
        req.httpBody = Self.json(fields)
        let data: Data
        do {
            data = try await perform(req, upload: nil)
        } catch APIError.server(let status, let code) where status == 409 && code == "user_exists" {
            // аккаунт на сервере есть, а токена у нас больше нет: сеанс завершили с другого устройства
            NotificationCenter.default.post(name: .orbitaSessionRevoked, object: nil)
            throw APIError.unauthorized
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issued = object["token"] as? String else { throw APIError.invalidResponse }
        Keychain.setString(issued, account: tokenAccount)
        token = issued
        return issued
    }

    private func perform(_ req: URLRequest, upload: Payload?) async throws -> Data {
        do {
            let result: (Data, URLResponse)
            switch upload {
            case .data(let data)?: result = try await URLSession.shared.upload(for: req, from: data)
            case .file(let url)?:  result = try await URLSession.shared.upload(for: req, fromFile: url)
            case nil:              result = try await URLSession.shared.data(for: req)
            }
            let (data, response) = result
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            switch http.statusCode {
            case 200..<300: return data
            case 401:       throw APIError.unauthorized
            default:
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let code = (object?["error"] as? String) ?? "error"
                if code == "content_blocked" {                 // нейросеть отклонила файл — крупная плашка «Я понял»
                    await MainActor.run { ContentNotice.show() }
                }
                throw APIError.server(status: http.statusCode, code: code)
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.offline
        }
    }
}


/// Копия последних ответов сервера для работы без сети. Лежит в Application Support (не в iCloud-копии), под защитой данных iOS
enum OfflineStore {
    private static let dir: URL = {
        var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? base.setResourceValues(values)
        return base
    }()

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    private static func file(user: String, path: String, slot: String) -> URL {
        dir.appendingPathComponent(hash(user) + "_" + hash(path + "#" + slot) + ".json")
    }

    static func save(_ data: Data, user: String, path: String, slot: String) {
        try? data.write(to: file(user: user, path: path, slot: slot), options: [.atomic, .completeFileProtection])
    }

    static func load(user: String, path: String, slot: String) -> Data? {
        guard let data = try? Data(contentsOf: file(user: user, path: path, slot: slot)) else { return nil }
        return scrubTyping(data)
    }

    /// Выход из аккаунта: чужие переписки на диске не остаются
    static func wipe(user: String) {
        let prefix = hash(user) + "_"
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// «Печатает…» из старого ответа без сети показывалось бы вечно — убираем
    private static func scrubTyping(_ data: Data) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        if object["typing"] != nil { object["typing"] = NSNull() }
        if var chats = object["chats"] as? [[String: Any]] {
            for i in chats.indices where chats[i]["typing"] != nil { chats[i]["typing"] = NSNull() }
            object["chats"] = chats
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }
}


/// Есть ли связь с сервером: по результату опросов списка чатов и переписок. От него зависят «Соединение…» и повторная отправка
@MainActor
final class NetworkState: ObservableObject {
    static let shared = NetworkState()
    @Published private(set) var offline = false
    func set(offline value: Bool) { if offline != value { offline = value } }
}
