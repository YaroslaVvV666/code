import Foundation

/// Адрес сервера Orbita. По умолчанию — сервер на этом же Mac (для симулятора).
/// На реальном iPhone укажите адрес Mac в Wi-Fi сети, например http://192.168.1.20:8080
enum ServerConfig {
    private static let key = "orbita.serverURL"
    static let defaultURL = "http://localhost:8080"

    static var urlString: String {
        // Keychain переживает удаление приложения, UserDefaults — нет. Поэтому адрес сервера храним в Keychain,
        // а старое значение из UserDefaults подхватываем один раз (миграция). Иначе после переустановки адрес
        // сбрасывался на localhost и приложение переставало подключаться к серверу
        get {
            if let saved = Keychain.string(key) { return saved }
            if let old = UserDefaults.standard.string(forKey: key) {
                Keychain.setString(old, account: key)
                return old
            }
            return defaultURL
        }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Keychain.setString(v, account: key)
            UserDefaults.standard.set(v, forKey: key)
        }
    }

    static func url(from string: String) -> URL? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    static var baseURL: URL? { url(from: urlString) }

    static func mediaURL(_ id: String) -> URL? {
        guard let base = baseURL else { return nil }
        return URL(string: base.absoluteString + "/media/" + id)
    }
}
