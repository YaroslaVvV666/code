import Foundation

/// Изменение профиля: заполняются только те поля, которые нужно поменять
struct ProfilePatch {
    var name: String?               // имя (без фамилии)
    var lastName: String?           // "" — убрать фамилию
    var birthday: String?           // "" — убрать дату
    var username: String?           // "" — убрать имя пользователя
    var bio: String?
    var phoneVisibility: String?
    var phone: String?
    var commentsPolicy: String?
    var privacy: [String: String]?
    var styleColor: Int?
    var styleEmoji: String?
    var resetStyle = false
    var statusEmoji: String?        // "" — убрать

    var body: Data {
        var object: [String: Any] = [:]
        if let name { object["name"] = name }
        if let username { object["username"] = username }
        if let bio { object["bio"] = bio }
        if let lastName { object["last_name"] = lastName }
        if let birthday { object["birthday"] = birthday }
        if let phoneVisibility { object["phone_visibility"] = phoneVisibility }
        if let phone { object["phone"] = phone }
        if let statusEmoji { object["status_emoji"] = statusEmoji }
        if let commentsPolicy { object["comments_policy"] = commentsPolicy }
        if let privacy { object["privacy"] = privacy }
        if resetStyle {
            object["style"] = ["color": NSNull(), "emoji": NSNull()] as [String: Any]
        } else if styleColor != nil || styleEmoji != nil {
            object["style"] = ["color": styleColor.map { $0 as Any } ?? NSNull(),
                               "emoji": styleEmoji.map { $0 as Any } ?? NSNull()] as [String: Any]
        }
        return ServerAPI.json(object)
    }
}

enum UsernameStatus: Equatable {
    case unknown, invalid, taken, available
}

protocol ProfileRepository: Sendable {
    func load() async throws -> UserProfile
    func update(_ patch: ProfilePatch) async throws -> UserProfile
    func uploadAvatar(_ jpeg: Data) async throws -> String
    func addAvatar(mediaID: String) async throws -> UserProfile
    func deleteAvatar(id: String) async throws -> UserProfile
    func reorderAvatars(_ ids: [String]) async throws -> UserProfile
    func profile(id: String) async throws -> UserProfile
    func lookup(username: String) async throws -> UserProfile
    func lookup(phone: String) async throws -> UserProfile
    func searchUsers(prefix: String) async throws -> [UserProfile]
    func friends(userID: String) async throws -> [FriendUser]
    func friendRequests() async throws -> (incoming: [FriendUser], outgoing: [FriendUser])
    func setFriend(userID: String, add: Bool) async throws -> String
    func sessions() async throws -> [DeviceSession]
    func terminateSession(id: String) async throws
    func terminateOtherSessions() async throws
    func loginRequest(qrID: String) async throws -> LoginRequestInfo
    func approveLogin(qrID: String, phone: String) async throws
    func usernameStatus(_ username: String) async throws -> UsernameStatus
    func deleteAccount() async throws
}

private struct OrbitDTO: Decodable {
    let id: String
    let name: String
    let avatar: String?
}

private struct AvatarDTO: Decodable {
    let id: String
    let media: String
    let createdAt: Double
    var model: AvatarPhoto { AvatarPhoto(id: id, mediaID: media, createdAt: Date(timeIntervalSince1970: createdAt)) }
}

private struct StyleDTO: Decodable {
    let color: Int?
    let emoji: String?
}

private struct ProfileDTO: Decodable {
    let id: String
    let name: String
    let firstName: String?
    let lastName: String?
    let birthday: String?
    let username: String?
    let bio: String
    let avatar: String?
    let avatars: [AvatarDTO]?
    let phone: String?
    let phoneVisibility: String?
    let commentsPolicy: String?
    let lastSeen: Double?
    let wallPrivate: Bool?
    let postsCount: Int?
    let track: TrackDTO?
    let tracksCount: Int?
    let privacy: [String: String]?
    let blockedByMe: Bool?
    let blockedMe: Bool?
    let contactName: String?
    let isContact: Bool?
    let style: StyleDTO?
    let statusEmoji: String?
    let friendState: String?
    let friendsCount: Int?
    let followersCount: Int?
    let following: Bool?
    let requestsCount: Int?
    let listening: Bool?
    let orbit: [OrbitDTO]?

    var model: UserProfile {
        UserProfile(id: id, name: name, username: username, bio: bio, avatarID: avatar, phone: phone,
                    phoneVisibility: phoneVisibility ?? "nobody", commentsPolicy: commentsPolicy ?? "all",
                    firstName: firstName ?? name, lastName: lastName ?? "", birthday: birthday,
                    avatars: (avatars ?? []).map(\.model),
                    lastSeen: lastSeen.map { Date(timeIntervalSince1970: $0) },
                    wallPrivate: wallPrivate ?? false, postsCount: postsCount, track: track?.model,
                    tracksCount: tracksCount ?? 0, privacy: privacy.map(PrivacySettings.init(server:)),
                    blockedByMe: blockedByMe ?? false, blockedMe: blockedMe ?? false,
                    contactName: contactName, isContact: isContact ?? false,
                    styleColor: style?.color, styleEmoji: style?.emoji,
                    friendState: friendState ?? "none", friendsCount: friendsCount ?? 0, followersCount: followersCount, following: following ?? false,
                    requestsCount: requestsCount, statusEmoji: statusEmoji, listening: listening ?? false,
                    orbit: (orbit ?? []).map { OrbitFriend(id: $0.id, name: $0.name, avatarID: $0.avatar) })
    }
}

private struct SessionDTO: Decodable {
    let id: String
    let device: String
    let system: String
    let app: String
    let ip: String
    let createdAt: Double
    let lastActive: Double
    let current: Bool

    var model: DeviceSession {
        DeviceSession(id: id, device: device, system: system, app: app, ip: ip,
                      createdAt: Date(timeIntervalSince1970: createdAt),
                      lastActive: Date(timeIntervalSince1970: lastActive), isCurrent: current)
    }
}

private struct FriendDTO: Decodable {
    let id: String
    let name: String
    let username: String?
    let avatar: String?
    let friendState: String?
    var model: FriendUser { FriendUser(id: id, name: name, username: username, avatarID: avatar, state: friendState ?? "none") }
}

private struct FriendListDTO: Decodable { let users: [FriendDTO] }
private struct FriendRequestsDTO: Decodable { let incoming: [FriendDTO]; let outgoing: [FriendDTO] }
private struct FriendStateDTO: Decodable { let state: String }

private struct UserListDTO: Decodable { let users: [ProfileDTO] }

private struct SessionListDTO: Decodable { let sessions: [SessionDTO] }

private struct LoginRequestDTO: Decodable {
    let device: String
    let system: String
    let app: String
    let ip: String
}

private struct UsernameCheckDTO: Decodable {
    let valid: Bool
    let available: Bool
}

struct RemoteProfileRepository: ProfileRepository {
    let api: ServerAPI

    func load() async throws -> UserProfile {
        try decodeAPI(ProfileDTO.self, from: try await api.request("GET", "/v1/me")).model
    }

    func update(_ patch: ProfilePatch) async throws -> UserProfile {
        try decodeAPI(ProfileDTO.self, from: try await api.request("PUT", "/v1/me", body: patch.body)).model
    }

    func uploadAvatar(_ jpeg: Data) async throws -> String {
        let data = try await api.upload("/v1/media", query: ["kind": "image", "w": "512", "h": "512"],
                                        payload: .data(jpeg), contentType: "image/jpeg")
        return try decodeAPI(MediaDTO.self, from: data).id
    }

    func usernameStatus(_ username: String) async throws -> UsernameStatus {
        let data = try await api.request("GET", "/v1/username/check", query: ["u": username])
        let result = try decodeAPI(UsernameCheckDTO.self, from: data)
        if !result.valid { return .invalid }
        return result.available ? .available : .taken
    }

    func deleteAccount() async throws {
        _ = try await api.request("DELETE", "/v1/me")
    }

    func addAvatar(mediaID: String) async throws -> UserProfile {
        let body = ServerAPI.json(["media_id": mediaID])
        return try decodeAPI(ProfileDTO.self, from: try await api.request("POST", "/v1/me/avatars", body: body)).model
    }

    func deleteAvatar(id: String) async throws -> UserProfile {
        try decodeAPI(ProfileDTO.self, from: try await api.request("DELETE", "/v1/me/avatars/\(id)")).model
    }

    func reorderAvatars(_ ids: [String]) async throws -> UserProfile {
        let body = ServerAPI.json(["ids": ids])
        return try decodeAPI(ProfileDTO.self, from: try await api.request("PUT", "/v1/me/avatars/order", body: body)).model
    }

    func profile(id: String) async throws -> UserProfile {
        try decodeAPI(ProfileDTO.self, from: try await api.request("GET", "/v1/users/\(id)")).model
    }

    func lookup(username: String) async throws -> UserProfile {
        try decodeAPI(ProfileDTO.self, from: try await api.request("GET", "/v1/lookup", query: ["u": username])).model
    }

    func lookup(phone: String) async throws -> UserProfile {
        try decodeAPI(ProfileDTO.self, from: try await api.request("GET", "/v1/lookup_phone", query: ["p": phone])).model
    }

    func searchUsers(prefix: String) async throws -> [UserProfile] {
        try decodeAPI(UserListDTO.self, from: try await api.request("GET", "/v1/search/users", query: ["q": prefix])).users.map(\.model)
    }

    func friends(userID: String) async throws -> [FriendUser] {
        try decodeAPI(FriendListDTO.self, from: try await api.request("GET", "/v1/users/\(userID)/friends")).users.map(\.model)
    }

    func friendRequests() async throws -> (incoming: [FriendUser], outgoing: [FriendUser]) {
        let dto = try decodeAPI(FriendRequestsDTO.self, from: try await api.request("GET", "/v1/me/friend-requests"))
        return (dto.incoming.map(\.model), dto.outgoing.map(\.model))
    }

    func setFriend(userID: String, add: Bool) async throws -> String {
        try decodeAPI(FriendStateDTO.self, from: try await api.request(add ? "PUT" : "DELETE", "/v1/friends/\(userID)")).state
    }

    func sessions() async throws -> [DeviceSession] {
        try decodeAPI(SessionListDTO.self, from: try await api.request("GET", "/v1/sessions")).sessions.map(\.model)
    }

    func terminateSession(id: String) async throws {
        _ = try await api.request("DELETE", "/v1/sessions/\(id)")
    }

    func terminateOtherSessions() async throws {
        _ = try await api.request("DELETE", "/v1/sessions")
    }

    func loginRequest(qrID: String) async throws -> LoginRequestInfo {
        let dto = try decodeAPI(LoginRequestDTO.self, from: try await api.request("GET", "/v1/qr/\(qrID)/info"))
        return LoginRequestInfo(device: dto.device, system: dto.system, app: dto.app, ip: dto.ip)
    }

    func approveLogin(qrID: String, phone: String) async throws {
        _ = try await api.request("POST", "/v1/qr/\(qrID)/approve", body: ServerAPI.json(["phone": phone]))
    }
}

struct TrackDTO: Decodable {
    let id: String
    let media: String
    let title: String
    let artist: String
    let duration: Double
    let cover: String?
    var model: Track { Track(id: id, mediaID: media, title: title, artist: artist, duration: duration, cover: cover) }
}

extension PrivacySettings {
    init(server dict: [String: String]) {
        self.init()
        for (key, value) in dict {
            // JSONDecoder с convertFromSnakeCase переименовывает и ключи словарей
            self[key == "lastSeen" ? "last_seen" : key] = value
        }
    }

    var serverDict: [String: String] {
        ["phone", "last_seen", "photos", "bio", "birthday", "music", "wall", "calls", "forwards", "invites", "comments", "find", "followers", "orbit"]
            .reduce(into: [:]) { $0[$1] = self[$1] }
    }
}
