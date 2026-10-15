import Foundation

/// Адрес сервера Orbita. По умолчанию — сервер на этом же Mac (для симулятора).
/// На реальном iPhone укажите адрес Mac в Wi-Fi сети, например http://192.168.1.20:8080
enum ServerConfig {
    private static let key = "orbita.serverURL"
    static let defaultURL = "http://localhost:8080"

    static var urlString: String {
        get { UserDefaults.standard.string(forKey: key) ?? defaultURL }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key) }
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
