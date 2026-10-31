import Foundation

// MARK: - Вкус: что человек смотрит и сохраняет (лайки, комментарии и пересылки сервер видит сам)

struct TasteTopic: Decodable, Identifiable {
    let topic: String
    let score: Double
    var id: String { topic }
}

struct TasteStats: Decodable {
    let views: Int
    let likes: Int
    let comments: Int
    let shares: Int
    let saves: Int
    let watchMs: Int
}

struct TasteInfo: Decodable {
    let enabled: Bool
    let long: [TasteTopic]
    let recent: [TasteTopic]
    let rising: [String]
    let fading: [String]
    let stats: TasteStats
}

/// Считает, сколько каждый пост был на экране, и пачками отправляет серверу
@MainActor
final class TasteTracker {
    private let extras: ExtrasAPI
    private var shownSince: [String: Date] = [:]
    private var buffer: [[String: Any]] = []

    init(extras: ExtrasAPI) { self.extras = extras }

    func appeared(_ postID: String) {
        if shownSince[postID] == nil { shownSince[postID] = Date() }
    }

    func disappeared(_ postID: String) {
        guard let since = shownSince.removeValue(forKey: postID) else { return }
        let ms = Int(Date().timeIntervalSince(since) * 1000)
        guard ms >= 150 else { return }
        buffer.append(["post_id": postID, "type": "view", "ms": min(ms, 120_000)])
        if buffer.count >= 15 { flush() }
    }

    /// Короткое видео: сколько секунд смотрели и какую долю ролика (с пересмотрами больше 1)
    func reelEnded(_ postID: String, seconds: Double, ratio: Double) {
        let ms = Int(seconds * 1000)
        guard ms >= 100 else { return }
        buffer.append(["post_id": postID, "type": "view", "ms": min(ms, 120_000), "ratio": min(ratio, 5)])
        if buffer.count >= 6 { flush() }
    }

    /// «Не интересует»: сильный минус теме и автору, отправляется сразу
    func notInterested(_ postID: String) {
        buffer.append(["post_id": postID, "type": "dislike", "ms": 0])
        flush()
    }

    func saved(_ postID: String) {
        buffer.append(["post_id": postID, "type": "save", "ms": 0])
    }

    /// Поделился ссылкой на пост (скопировал, отправил наружу) — такой же сильный плюс, как пересылка в чат
    func shared(_ postID: String) {
        buffer.append(["post_id": postID, "type": "share", "ms": 0])
        flush()
    }

    /// Приложение уходит в фон — всё, что сейчас на экране, засчитываем и отправляем
    func endAll() {
        for id in Array(shownSince.keys) { disappeared(id) }
        flush()
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer = []
        let extras = extras
        Task { await extras.sendEvents(batch) }
    }
}

extension ExtrasAPI {
    func sendEvents(_ events: [[String: Any]]) async {
        _ = try? await api.request("POST", "/v1/events", body: ServerAPI.json(["events": events] as [String: Any]))
    }

    func taste() async -> TasteInfo? {
        guard let data = try? await api.request("GET", "/v1/me/taste") else { return nil }
        return try? decodeAPI(TasteInfo.self, from: data)
    }

    func setTaste(enabled: Bool) async -> TasteInfo? {
        guard let data = try? await api.request("PUT", "/v1/me/taste", body: ServerAPI.json(["enabled": enabled] as [String: Any])) else { return nil }
        return try? decodeAPI(TasteInfo.self, from: data)
    }

    func resetTaste() async -> TasteInfo? {
        guard let data = try? await api.request("DELETE", "/v1/me/taste") else { return nil }
        return try? decodeAPI(TasteInfo.self, from: data)
    }
}


// MARK: - Короткие видео

struct Reel: Identifiable, Equatable {
    var post: Post
    var state: String           // me | none | following
    var id: String { post.id }
}

private struct ReelDTO: Decodable {
    let post: PostDTO
    let authorState: String

    init(from decoder: Decoder) throws {
        post = try PostDTO(from: decoder)
        authorState = try decoder.container(keyedBy: Keys.self).decodeIfPresent(String.self, forKey: .authorState) ?? "none"
    }
    enum Keys: String, CodingKey { case authorState }
}

private struct ReelListDTO: Decodable { let reels: [ReelDTO] }

extension ExtrasAPI {
    func reels(friendsOnly: Bool, exclude: [String]) async throws -> [Reel] {
        var query = ["limit": "12"]
        if friendsOnly { query["feed"] = "friends" }
        if !exclude.isEmpty { query["exclude"] = exclude.suffix(120).joined(separator: ",") }
        let data = try await api.request("GET", "/v1/reels", query: query)
        return try decodeAPI(ReelListDTO.self, from: data).reels.map { Reel(post: $0.post.model, state: $0.authorState) }
    }

    /// Сохранить / убрать из избранного — нужно для счётчика «сколько сохранили»
    func setSaved(id: String, saved: Bool) async {
        _ = try? await api.request(saved ? "PUT" : "DELETE", "/v1/posts/\(id)/save")
    }

    /// Пожаловаться на публикацию (spam | violence | adult | illegal | copyright | other)
    func reportPost(id: String, reason: String) async throws {
        _ = try await api.request("POST", "/v1/posts/\(id)/report", body: ServerAPI.json(["reason": reason]))
    }

    /// Пожаловаться на сообщение (личное или в группе)
    func reportMessage(id: String, reason: String, note: String = "") async throws {
        _ = try await api.request("POST", "/v1/messages/\(id)/report",
                                  body: ServerAPI.json(["reason": reason, "note": note]))
    }

    /// Пожаловаться на профиль пользователя
    func reportUser(id: String, reason: String, note: String = "") async throws {
        _ = try await api.request("POST", "/v1/users/\(id)/report",
                                  body: ServerAPI.json(["reason": reason, "note": note]))
    }

    /// Мои жалобы со статусом рассмотрения
    func myReports() async throws -> [MyReport] {
        let data = try await api.request("GET", "/v1/reports/mine")
        return try decodeAPI(MyReportListDTO.self, from: data).reports
    }

    // MARK: Техподдержка

    /// Новое обращение в поддержку. link — необязательная привязка к объекту (жалоба).
    @discardableResult
    func openSupportTicket(topic: String, text: String, subject: String = "",
                           linkKind: String? = nil, linkID: String? = nil) async throws -> SupportTicket {
        var body: [String: Any] = ["topic": topic, "text": text]
        if !subject.isEmpty { body["subject"] = subject }
        if let linkKind { body["link_kind"] = linkKind }
        if let linkID { body["link_id"] = linkID }
        let data = try await api.request("POST", "/v1/support/tickets", body: ServerAPI.json(body))
        return try decodeAPI(SupportTicketDTO.self, from: data).ticket
    }

    /// Мои обращения в поддержку
    func supportTickets() async throws -> [SupportTicket] {
        let data = try await api.request("GET", "/v1/support/tickets")
        return try decodeAPI(SupportTicketListDTO.self, from: data).tickets
    }

    /// Переписка по обращению (открытие снимает отметку непрочитанного)
    func supportThread(id: String) async throws -> SupportTicket {
        let data = try await api.request("GET", "/v1/support/tickets/\(id)")
        return try decodeAPI(SupportTicketDTO.self, from: data).ticket
    }

    /// Ответ пользователя в своём обращении
    @discardableResult
    func replySupport(id: String, text: String) async throws -> SupportTicket {
        let data = try await api.request("POST", "/v1/support/tickets/\(id)/messages",
                                         body: ServerAPI.json(["text": text]))
        return try decodeAPI(SupportTicketDTO.self, from: data).ticket
    }

    /// Сколько обращений с непрочитанным ответом поддержки — для значка
    func supportUnread() async -> Int {
        guard let data = try? await api.request("GET", "/v1/support/unread"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return obj["count"] as? Int ?? 0
    }

    /// Репост шортса к себе на страницу / отмена репоста
    @discardableResult
    func setReposted(id: String, on: Bool) async throws -> (count: Int, mine: Bool)? {
        let data = try await api.request(on ? "PUT" : "DELETE", "/v1/posts/\(id)/repost")
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let n = j["reposts"] as? Int else { return nil }
        return (n, j["reposted_by_me"] as? Bool ?? on)
    }

    /// Закладки раньше жили только на устройстве — один раз отправляем их серверу
    func syncSaves(ids: [String]) async {
        guard !ids.isEmpty else { return }
        _ = try? await api.request("POST", "/v1/me/saves/sync", body: ServerAPI.json(["ids": Array(ids.prefix(500))] as [String: Any]))
    }

    /// Новый шортс: одно вертикальное видео до 3 минут (публикуется отдельно от постов)
    func createReel(text: String, media: MediaItem, musicTrack: String? = nil, options: PostOptions = PostOptions()) async throws -> Post {
        var body: [String: Any] = ["text": text, "entities": [[String: Any]](),
                                   "media": [["id": media.id, "width": media.width, "height": media.height]],
                                   "reel": true]
        if let musicTrack { body["music_track"] = musicTrack }
        if options.commentsOff { body["comments_off"] = true }
        if options.noRepost { body["no_repost"] = true }
        if options.sensitive { body["sensitive"] = true }
        let data = try await api.request("POST", "/v1/posts", body: ServerAPI.json(body))
        return try decodeAPI(PostDTO.self, from: data).model
    }

    /// Подписаться / отписаться. Возвращает (подписан ли, число подписчиков)
    /// source — шортс, с которого подписались (идёт в статистику видео автора)
    func setFollow(id: String, on: Bool, source: String? = nil) async -> (Bool, Int)? {
        let body: Data? = (on && source != nil) ? ServerAPI.json(["post": source!]) : nil
        guard let data = try? await api.request(on ? "POST" : "DELETE", "/v1/follow/\(id)", body: body),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ((obj["following"] as? Bool) ?? on, (obj["followers"] as? Int) ?? 0)
    }

    func addFriend(id: String) async -> String? {
        guard let data = try? await api.request("PUT", "/v1/friends/\(id)"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["state"] as? String
    }
}

/// Жалоба, поданная мной, со статусом рассмотрения
struct MyReport: Identifiable, Decodable, Equatable {
    let id: String
    let kind: String            // message | user | post | chat
    let reason: String
    let note: String
    let status: String          // open | resolved | dismissed
    let resolution: String
    let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, kind, reason, note, status, resolution
        case createdAt = "created_at"
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "other"
        reason = (try? c.decode(String.self, forKey: .reason)) ?? "other"
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? "open"
        resolution = (try? c.decode(String.self, forKey: .resolution)) ?? ""
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
    }
}

struct MyReportListDTO: Decodable { let reports: [MyReport] }

// MARK: - Техподдержка

/// Одно сообщение в обращении: автор — я (`user`) или поддержка (`staff`).
struct SupportMessage: Identifiable, Decodable, Equatable, Hashable {
    let id: String
    let author: String
    let body: String
    let createdAt: Double

    var fromStaff: Bool { author == "staff" }

    enum CodingKeys: String, CodingKey { case id, author, body; case createdAt = "created_at" }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        author = (try? c.decode(String.self, forKey: .author)) ?? "user"
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
    }
}

/// Обращение в поддержку со статусом и перепиской.
struct SupportTicket: Identifiable, Decodable, Equatable, Hashable {
    let id: String
    let topic: String
    let subject: String
    let status: String          // open | answered | closed
    let unread: Bool
    let createdAt: Double
    let updatedAt: Double
    let lastBody: String
    let lastFromStaff: Bool
    let messages: [SupportMessage]

    enum CodingKeys: String, CodingKey {
        case id, topic, subject, status, unread, messages, last
        case createdAt = "created_at", updatedAt = "updated_at"
    }
    private struct Last: Decodable { let body: String?; let author: String? }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        topic = (try? c.decode(String.self, forKey: .topic)) ?? "other"
        subject = (try? c.decode(String.self, forKey: .subject)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? "open"
        unread = (try? c.decode(Bool.self, forKey: .unread)) ?? false
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
        updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
        messages = (try? c.decode([SupportMessage].self, forKey: .messages)) ?? []
        let last = try? c.decode(Last.self, forKey: .last)
        lastBody = last?.body ?? messages.last?.body ?? ""
        lastFromStaff = (last?.author ?? messages.last?.author) == "staff"
    }
}

struct SupportTicketDTO: Decodable { let ticket: SupportTicket }
struct SupportTicketListDTO: Decodable { let tickets: [SupportTicket] }

/// Темы обращений — совпадают с набором на сервере (SUPPORT_TOPICS).
enum SupportTopics {
    static func list(_ s: Strings) -> [(code: String, title: String, icon: String)] {
        [("bug", s.t("Ошибка в приложении", "App bug"), "ladybug"),
         ("account", s.t("Аккаунт и вход", "Account & login"), "person.crop.circle"),
         ("payment", s.t("Оплата и подписка", "Payments"), "creditcard"),
         ("safety", s.t("Безопасность", "Safety"), "lock.shield"),
         ("complaint", s.t("Жалоба", "Complaint"), "exclamationmark.bubble"),
         ("idea", s.t("Идея или пожелание", "Idea / feedback"), "lightbulb"),
         ("other", s.t("Другое", "Other"), "ellipsis.circle")]
    }
    static func title(_ code: String, _ s: Strings) -> String {
        list(s).first { $0.code == code }?.title ?? s.t("Другое", "Other")
    }
    static func icon(_ code: String) -> String {
        ["bug": "ladybug", "account": "person.crop.circle", "payment": "creditcard",
         "safety": "lock.shield", "complaint": "exclamationmark.bubble", "idea": "lightbulb"][code] ?? "ellipsis.circle"
    }
}
