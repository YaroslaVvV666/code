import Foundation

// MARK: - Язык

enum AppLanguage: String, CaseIterable, Identifiable {
    case ru, en
    var id: String { rawValue }
    var title: String { self == .ru ? "Русский" : "English" }
}

// MARK: - Аккаунт

struct UserRecord: Equatable, Identifiable {
    let id: String
    let phone: String               // формат E.164, например +79817990269
    var name: String?
    var email: String?
    var hasTwoFactor: Bool
    let createdAt: Date
}

struct LanguageInfo: Identifiable, Equatable {
    let code: String                // "ru", "en"
    let name: String
    let nativeName: String
    var id: String { code }
}

struct UserSettings: Equatable {
    var language: String
    var isDark: Bool
    var accent: Int = 0
    var autoplay: Bool = true
}

enum CodeChannel: String {
    case sms, email
}

/// Выданный код подтверждения (сам код хранится только на «сервере»)
struct CodeTicket: Equatable, Identifiable {
    let id: UUID
    let channel: CodeChannel
    let target: String
    let codeLength: Int
    let expiresAt: Date
    let resendAvailableAt: Date
}

/// То, что «доставлено» пользователю. Показывается баннером.
/// Настоящий сервер возвращает nil — код уходит по SMS/почте.
struct DeliveredMessage: Identifiable, Equatable {
    let id = UUID()
    let channel: CodeChannel
    let target: String
    let code: String
}

enum PhoneIssue: Equatable {
    case incomplete, tooLong, notMobile, looksFake
}

enum AuthError: Error, Equatable {
    case invalidPhone(PhoneIssue)
    case invalidEmail
    case invalidName
    case emailTaken
    case phoneTaken
    case tooManyRequests(retryAfter: Int)
    case wrongCode(attemptsLeft: Int)
    case codeExpired
    case tooManyAttempts
    case weakPassword
    case passwordMismatch
    case hintGivesAway
    case passwordRequired
    case wrongPassword(attemptsLeft: Int)
    case locked(retryAfter: Int)
    case deliveryFailed
    case otpNotConfigured          // сервер отвечает, но запущен без SMS и без ORBITA_OTP_DEV=1
    case unknown
}

// MARK: - Соцсеть

struct Author: Equatable {
    let id: String
    let name: String
    let username: String?
    let avatarID: String?
}

enum MediaKind: String {
    case image, video, art
}

struct MediaItem: Identifiable, Equatable {
    let id: String                  // id файла на сервере или "art:N"
    let kind: MediaKind
    let width: Int
    let height: Int
    let duration: Double?
    let thumbID: String?            // обложка видео

    var aspect: Double { (width > 0 && height > 0) ? Double(width) / Double(height) : 1 }
    var artIndex: Int { Int(id.dropFirst(4)) ?? 0 }
}

/// Форматирование текста (как в Telegram): диапазон в UTF-16 единицах
struct TextEntity: Codable, Equatable {
    var type: String                // bold, italic, underline, strike, mono, quote, link
    var offset: Int
    var length: Int
    var url: String? = nil
}

struct Post: Identifiable, Equatable {
    let id: String
    let author: Author
    var text: String
    var entities: [TextEntity]
    var media: [MediaItem]
    let createdAt: Date
    var likes: Int
    var comments: Int
    var likedByMe: Bool
    let isMine: Bool
    let commentsEnabled: Bool
    var views = 0                    // просмотры (в сетке шортсов, как в TikTok)
    var editedAt: Date? = nil
    var saves = 0                    // сколько человек сохранили в избранное
    var savedByMe = false            // сохранено ли мной (по данным сервера)
    var reposts = 0                  // сколько человек сделали репост
    var repostedByMe = false
    var music: PostMusic? = nil      // музыка шортса (из плейлиста автора)
    var isRepost = false             // это репост-копия чужого шортса на странице репостнувшего
    var allowRepost = true           // автор разрешил репосты
    var repostFriends: [Author] = [] // кто из друзей сделал репост (до 8)
    var origin: Author? = nil        // у репост-копии — автор оригинала
    /// Создатель ролика: у репоста — автор оригинала, иначе автор
    var creator: Author { origin ?? author }
}

/// Параметры публикации, которые выбирает автор
struct PostOptions: Equatable {
    var commentsOff = false          // выключить комментарии
    var noRepost = false             // запретить репосты (для шортсов)
    var wallOnly = false             // запись на своей стене: видна в профиле, в ленту публикаций не попадает
}

struct PostMusic: Equatable, Identifiable {
    var id: String { mediaID }
    var title: String
    var artist: String
    var mediaID: String
    var display: String { artist.isEmpty ? title : "\(artist) — \(title)" }
}

struct Comment: Identifiable, Equatable {
    let id: String
    let author: Author
    let text: String
    let createdAt: Date
    var likes: Int = 0
    var likedByMe: Bool = false
    var likedByAuthor: Bool = false
    var parentID: String? = nil
    var replyToName: String? = nil
    var pinned: Bool = false
}

/// «История» в ленте: автор, по которому можно отфильтровать публикации
struct Story: Identifiable, Equatable {
    let id: String
    let name: String
    let avatarID: String?
}

/// Одна фотография профиля. Подпись — дата, когда её добавили.
struct AvatarPhoto: Identifiable, Equatable, Hashable {
    let id: String
    let mediaID: String
    let createdAt: Date
}

struct OrbitFriend: Equatable, Identifiable {
    let id: String
    let name: String
    let avatarID: String?
}

struct UserProfile: Equatable {
    let id: String
    var name: String                // имя и фамилия через пробел
    var username: String?
    var bio: String
    var avatarID: String?
    var phone: String?
    var phoneVisibility: String     // "all" | "nobody"
    var commentsPolicy: String      // "all" | "nobody"
    var firstName: String = ""
    var lastName: String = ""
    var birthday: String? = nil     // "1999-05-17" или "--05-17" (без года)
    var avatars: [AvatarPhoto] = []
    var lastSeen: Date? = nil       // nil — скрыто настройками приватности
    var wallPrivate: Bool = false   // стена скрыта от вас
    var postsCount: Int? = nil
    var track: Track? = nil         // первый трек плейлиста
    var tracksCount: Int = 0
    var privacy: PrivacySettings? = nil     // только у своего профиля
    var blockedByMe: Bool = false
    var blockedMe: Bool = false
    var contactName: String? = nil      // как я сохранил этого человека в контактах
    var isContact: Bool = false
    var styleColor: Int? = nil          // цвет профиля 0–15
    var styleEmoji: String? = nil       // фоновый эмодзи
    var friendState: String = "none"    // none | friends | outgoing | incoming
    var friendsCount: Int = 0
    var followersCount: Int? = nil      // nil — скрыто настройками приватности
    var following: Bool = false
    var requestsCount: Int? = nil       // входящие заявки (только у своего профиля)
    var statusEmoji: String? = nil      // эмодзи-статус рядом с именем
    var listening: Bool = false         // человек прямо сейчас слушает музыку
    var orbit: [OrbitFriend] = []       // лучшие друзья (если человек это включил)
    /// Имя с эмодзи-статусом (для шапок профиля)
    var displayName: String { statusEmoji.flatMap { $0.isEmpty ? nil : name + " " + $0 } ?? name }
}

/// Человек в списке друзей или заявок
struct FriendUser: Identifiable, Equatable {
    let id: String
    let name: String
    let username: String?
    let avatarID: String?
    var state: String
}

/// Трек плейлиста профиля
struct Track: Identifiable, Equatable, Hashable {
    let id: String
    let mediaID: String
    var title: String
    var artist: String
    let duration: Double
    var cover: String? = nil            // обложка (из тегов файла), если есть

    var display: String { artist.isEmpty ? title : "\(artist) — \(title)" }
}

/// Кто что видит. Значения: "all" — все, "nobody" — только я.
struct PrivacySettings: Equatable {
    var phone = "nobody"
    var lastSeen = "all"
    var photos = "all"
    var bio = "all"
    var birthday = "nobody"
    var music = "all"
    var wall = "all"
    var calls = "all"
    var forwards = "all"
    var invites = "all"
    var comments = "all"
    var find = "all"
    var followers = "all"
    var orbit = "nobody"          // «all» — лучшие друзья кружат вокруг аватарки

    /// Поле сервера → значение
    subscript(key: String) -> String {
        get {
            switch key {
            case "phone": return phone
            case "last_seen": return lastSeen
            case "photos": return photos
            case "bio": return bio
            case "birthday": return birthday
            case "music": return music
            case "wall": return wall
            case "calls": return calls
            case "forwards": return forwards
            case "invites": return invites
            case "find": return find
            case "followers": return followers
            case "orbit": return orbit
            default: return comments
            }
        }
        set {
            switch key {
            case "phone": phone = newValue
            case "last_seen": lastSeen = newValue
            case "photos": photos = newValue
            case "bio": bio = newValue
            case "birthday": birthday = newValue
            case "music": music = newValue
            case "wall": wall = newValue
            case "calls": calls = newValue
            case "forwards": forwards = newValue
            case "invites": invites = newValue
            case "find": find = newValue
            case "followers": followers = newValue
            case "orbit": orbit = newValue
            default: comments = newValue
            }
        }
    }
}

/// Сеанс — вход аккаунта на одном устройстве
struct DeviceSession: Identifiable, Equatable {
    let id: String
    let device: String
    let system: String
    let app: String
    let ip: String
    let createdAt: Date
    let lastActive: Date
    let isCurrent: Bool
}

/// Что известно об устройстве, которое просит войти по QR-коду
struct LoginRequestInfo: Equatable {
    let device: String
    let system: String
    let app: String
    let ip: String
}

struct QRLoginResult: Equatable {
    let token: String
    let userID: String
    let name: String
    let phone: String
}

/// Вход в аккаунт с облачным паролем: сервер ещё не выдал сеанс, ждёт пароль
struct TwoFAChallenge: Equatable {
    let ticket: String
    let hint: String
    let userID: String
    let name: String
    let phone: String
}

/// Ссылка, открывшая приложение (камера, другое приложение, сканер внутри Orbita)
enum DeepLink: Identifiable, Equatable {
    case login(String)              // orbita://login?id=…
    case username(String)           // orbita://u/name
    case userID(String)             // orbita://id/uuid
    case server(String)             // orbita://server?url=http://192.168.1.20:8080
    case post(String)               // orbita://post/<id>  или  http://сервер/p/<id>
    case group(String)              // orbita://group/<code>  или  http://сервер/g/<code>
    case phone(String)              // orbita://phone/+7981…  — номер телефона из текста сообщения

    var id: String {
        switch self {
        case .login(let v):    return "login:" + v
        case .username(let v): return "u:" + v
        case .userID(let v):   return "id:" + v
        case .server(let v):   return "server:" + v
        case .post(let v):     return "post:" + v
        case .group(let v):    return "group:" + v
        case .phone(let v):    return "ph:" + v
        }
    }

    init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    init?(url: URL) {
        // http(s)://адрес-вашего-сервера/p/<id> — ссылка, которой делятся в мессенджерах
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count == 2, let host = ServerConfig.baseURL?.host, host == url.host else { return nil }
            if parts[0] == "p", parts[1].range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil {
                self = .post(parts[1])
                return
            }
            if parts[0] == "g", parts[1].range(of: "^[A-Za-z0-9_]{5,32}$", options: .regularExpression) != nil {
                self = .group(parts[1])
                return
            }
            if parts[0] == "u", parts[1].range(of: "^[A-Za-z][A-Za-z0-9_]{4,31}$", options: .regularExpression) != nil {
                self = .username(parts[1])
                return
            }
            if parts[0] == "id", parts[1].range(of: "^[A-Za-z0-9\\-]{8,64}$", options: .regularExpression) != nil {
                self = .userID(parts[1])
                return
            }
            return nil
        }
        guard url.scheme?.lowercased() == "orbita", let host = url.host?.lowercased() else { return nil }
        let tail = url.pathComponents.filter { $0 != "/" }.first ?? ""
        switch host {
        case "login":
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "id" }?.value ?? ""
            guard id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else { return nil }
            self = .login(id)
        case "u":
            guard tail.range(of: "^[A-Za-z][A-Za-z0-9_]{4,31}$", options: .regularExpression) != nil else { return nil }
            self = .username(tail)
        case "server":
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "url" }?.value ?? ""
            guard ServerConfig.url(from: value) != nil else { return nil }
            self = .server(value)
        case "post":
            guard tail.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else { return nil }
            self = .post(tail)
        case "group":
            guard tail.range(of: "^[A-Za-z0-9_]{5,32}$", options: .regularExpression) != nil else { return nil }
            self = .group(tail)
        case "phone":
            guard tail.range(of: "^\\+?\\d{7,15}$", options: .regularExpression) != nil else { return nil }
            self = .phone(tail)
        case "id":
            guard tail.range(of: "^[A-Za-z0-9\\-]{8,64}$", options: .regularExpression) != nil else { return nil }
            self = .userID(tail)
        default:
            return nil
        }
    }

    /// Ссылка на пост: обычный адрес сервера — кликабельна в любом мессенджере и открывает приложение
    static func postShareLink(id: String) -> String {
        let base = ServerConfig.baseURL?.absoluteString ?? ServerConfig.urlString
        return base + "/p/" + id
    }

    /// Ссылка на профиль для QR-кода
    static func profileLink(username: String?, userID: String) -> String {
        let base = ServerConfig.baseURL?.absoluteString ?? ServerConfig.urlString
        if let username, !username.isEmpty { return base + "/u/" + username }
        return base + "/id/" + userID
    }
}

/// Фото или видео, подготовленное к загрузке
struct PreparedMedia: Identifiable {
    enum Source {
        case image(Data)            // JPEG
        case video(URL)             // сжатый mp4
        case png(Data)              // стикер: PNG с прозрачностью
    }
    let id = UUID()
    let source: Source
    let width: Int
    let height: Int
    let duration: Double?
    let thumbnail: Data             // JPEG-миниатюра для предпросмотра и обложки

    var isVideo: Bool { if case .video = source { return true }; return false }
}
