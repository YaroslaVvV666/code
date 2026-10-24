import Foundation
import AVFoundation

/// Чужие и свои стены, чёрный список, плейлист
struct BlockedUser: Identifiable, Equatable {
    let id: String
    let name: String
    let username: String?
    let avatarID: String?
}

/// Страница трека: шортсы, снятые под эту музыку
struct MusicPage: Equatable {
    var title: String
    var artist: String
    var mediaID: String
    var posts: [Post]
}

struct Wall: Equatable {
    var posts: [Post]
    var isPrivate: Bool
}

/// Запись гостя на чужой стене: текст, фото или рисунок от руки
struct WallEntry: Identifiable, Equatable {
    let id: String
    let author: Author
    let kind: String                // text | photo | drawing
    let text: String
    let mediaID: String?
    let width: Int
    let height: Int
    let createdAt: Date
    let canDelete: Bool
}

struct WallEntries: Equatable {
    var entries: [WallEntry]
    var canWrite: Bool
    var isPrivate: Bool
}

protocol SocialRepository: Sendable {
    func wallEntries(userID: String) async throws -> WallEntries
    func addWallEntry(userID: String, kind: String, text: String, mediaID: String?) async throws -> WallEntry
    func uploadWallImage(_ data: Data, mime: String, width: Int, height: Int) async throws -> String
    func deleteWallEntry(id: String) async throws
    func wall(userID: String) async throws -> Wall
    func reels(userID: String, reposts: Bool) async throws -> [Post]
    func musicPage(mediaID: String) async throws -> MusicPage
    func addSoundToProfile(mediaID: String, title: String, artist: String) async throws -> Track
    func blocks() async throws -> [BlockedUser]
    func setBlocked(userID: String, blocked: Bool) async throws
    func playlist(userID: String) async throws -> [Track]
    func addTrack(fileURL: URL) async throws -> Track
    func reorderTracks(_ ids: [String]) async throws -> [Track]
    func setListening(_ on: Bool) async
    func renameTrack(id: String, title: String, artist: String) async throws -> Track
    func deleteTrack(id: String) async throws -> [Track]
}

private struct WallDTO: Decodable {
    let posts: [PostDTO]
    let `private`: Bool?
}

private struct WallEntryDTO: Decodable {
    let id: String
    let author: AuthorDTO
    let kind: String
    let text: String
    let media: String?
    let width: Int?
    let height: Int?
    let createdAt: Double
    let canDelete: Bool?
    var model: WallEntry {
        WallEntry(id: id, author: author.model, kind: kind, text: text, mediaID: media, width: width ?? 0, height: height ?? 0,
                  createdAt: Date(timeIntervalSince1970: createdAt), canDelete: canDelete ?? false)
    }
}

private struct WallEntriesDTO: Decodable {
    let entries: [WallEntryDTO]
    let canWrite: Bool?
    let `private`: Bool?
}

private struct BlockedDTO: Decodable {
    let id: String
    let name: String
    let username: String?
    let avatar: String?
}

private struct BlockListDTO: Decodable { let users: [BlockedDTO] }
private struct TrackListDTO: Decodable { let tracks: [TrackDTO] }
private struct MusicPageDTO: Decodable { let title: String; let artist: String; let media: String; let posts: [PostDTO] }

struct RemoteSocialRepository: SocialRepository {
    let api: ServerAPI

    func musicPage(mediaID: String) async throws -> MusicPage {
        let data = try await api.request("GET", "/v1/music/\(mediaID)/reels")
        let dto = try decodeAPI(MusicPageDTO.self, from: data)
        return MusicPage(title: dto.title, artist: dto.artist, mediaID: dto.media, posts: dto.posts.map(\.model))
    }

    func reels(userID: String, reposts: Bool) async throws -> [Post] {
        let data = try await api.request("GET", "/v1/users/\(userID)/reels", query: ["kind": reposts ? "reposts" : "own"])
        return try decodeAPI(WallDTO.self, from: data).posts.map(\.model)
    }

    func wall(userID: String) async throws -> Wall {
        let data = try await api.request("GET", "/v1/users/\(userID)/posts", query: ["limit": "60"])
        let dto = try decodeAPI(WallDTO.self, from: data)
        return Wall(posts: dto.posts.map(\.model), isPrivate: dto.private ?? false)
    }

    func wallEntries(userID: String) async throws -> WallEntries {
        let data = try await api.request("GET", "/v1/users/\(userID)/wall", query: ["limit": "60"])
        let dto = try decodeAPI(WallEntriesDTO.self, from: data)
        return WallEntries(entries: dto.entries.map(\.model), canWrite: dto.canWrite ?? false, isPrivate: dto.private ?? false)
    }

    func addWallEntry(userID: String, kind: String, text: String, mediaID: String?) async throws -> WallEntry {
        var body: [String: Any] = ["kind": kind, "text": text]
        if let mediaID { body["media"] = mediaID }
        let data = try await api.request("POST", "/v1/users/\(userID)/wall", body: ServerAPI.json(body))
        return try decodeAPI(WallEntryDTO.self, from: data).model
    }

    /// Фото и рисунки проходят ту же проверку нейросетью на 18+, что и все загрузки: запрещённое сервер отклоняет (content_blocked)
    func uploadWallImage(_ data: Data, mime: String, width: Int, height: Int) async throws -> String {
        let result = try await api.upload("/v1/media", query: ["kind": "image", "w": "\(width)", "h": "\(height)"],
                                          payload: .data(data), contentType: mime)
        return try decodeAPI(MediaDTO.self, from: result).id
    }

    func deleteWallEntry(id: String) async throws {
        _ = try await api.request("DELETE", "/v1/wall/\(id)")
    }

    func blocks() async throws -> [BlockedUser] {
        let data = try await api.request("GET", "/v1/me/blocks")
        return try decodeAPI(BlockListDTO.self, from: data).users.map {
            BlockedUser(id: $0.id, name: $0.name, username: $0.username, avatarID: $0.avatar)
        }
    }

    func setBlocked(userID: String, blocked: Bool) async throws {
        _ = try await api.request(blocked ? "PUT" : "DELETE", "/v1/me/blocks/\(userID)")
    }

    func playlist(userID: String) async throws -> [Track] {
        let data = try await api.request("GET", "/v1/users/\(userID)/playlist")
        return try decodeAPI(TrackListDTO.self, from: data).tracks.map(\.model)
    }

    /// Название и исполнитель берутся из тегов файла; нет тегов — имя файла
    func addSoundToProfile(mediaID: String, title: String, artist: String) async throws -> Track {
        let body = ServerAPI.json(["media_id": mediaID, "title": title, "artist": artist])
        return try decodeAPI(TrackDTO.self, from: try await api.request("POST", "/v1/me/playlist/from-sound", body: body)).model
    }

    func addTrack(fileURL: URL) async throws -> Track {
        let asset = AVURLAsset(url: fileURL)
        var title = "", artist = ""
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey?.rawValue else { continue }
                if key == "title", title.isEmpty { title = (try? await item.load(.stringValue)) ?? "" }
                if key == "artist", artist.isEmpty { artist = (try? await item.load(.stringValue)) ?? "" }
            }
        }
        if title.trimmingCharacters(in: .whitespaces).isEmpty {
            title = fileURL.deletingPathExtension().lastPathComponent
        }
        let seconds = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        let duration = seconds.isFinite ? max(0, seconds) : 0

        let ext = fileURL.pathExtension.lowercased()
        let mime = ["m4a": "audio/mp4", "mp4": "audio/mp4", "aac": "audio/aac"][ext] ?? "audio/mpeg"
        let uploaded = try await api.upload("/v1/media", query: ["kind": "audio", "dur": String(duration)],
                                            payload: .file(fileURL), contentType: mime)
        let media = try decodeAPI(MediaDTO.self, from: uploaded)
        var fields: [String: Any] = ["media_id": media.id, "title": title, "artist": artist, "duration": duration]
        // обложка из тегов файла (если есть) — загружаем картинкой и привязываем к треку
        if let cover = await AudioMeta.read(fileURL).cover,
           let up = try? await api.upload("/v1/media", query: ["kind": "image", "w": "600", "h": "600"],
                                          payload: .data(cover), contentType: "image/jpeg"),
           let id = try? decodeAPI(MediaDTO.self, from: up).id {
            fields["cover"] = id
        }
        let body = ServerAPI.json(fields)
        let data = try await api.request("POST", "/v1/me/playlist", body: body)
        return try decodeAPI(TrackDTO.self, from: data).model
    }

    func setListening(_ on: Bool) async {
        _ = try? await api.request("POST", "/v1/me/listening", body: ServerAPI.json(["on": on]))
    }

    func reorderTracks(_ ids: [String]) async throws -> [Track] {
        let data = try await api.request("PUT", "/v1/me/playlist/order", body: ServerAPI.json(["ids": ids]))
        return try decodeAPI(TrackListDTO.self, from: data).tracks.map(\.model)
    }

    func renameTrack(id: String, title: String, artist: String) async throws -> Track {
        let data = try await api.request("PUT", "/v1/me/playlist/\(id)",
                                         body: ServerAPI.json(["title": title, "artist": artist]))
        return try decodeAPI(TrackDTO.self, from: data).model
    }

    func deleteTrack(id: String) async throws -> [Track] {
        let data = try await api.request("DELETE", "/v1/me/playlist/\(id)")
        return try decodeAPI(TrackListDTO.self, from: data).tracks.map(\.model)
    }
}
