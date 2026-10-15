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

protocol SocialRepository: Sendable {
    func wall(userID: String) async throws -> Wall
    func reels(userID: String, reposts: Bool) async throws -> [Post]
    func musicPage(mediaID: String) async throws -> MusicPage
    func blocks() async throws -> [BlockedUser]
    func setBlocked(userID: String, blocked: Bool) async throws
    func playlist(userID: String) async throws -> [Track]
    func addTrack(fileURL: URL) async throws -> Track
    func reorderTracks(_ ids: [String]) async throws -> [Track]
    func renameTrack(id: String, title: String, artist: String) async throws -> Track
    func deleteTrack(id: String) async throws -> [Track]
}

private struct WallDTO: Decodable {
    let posts: [PostDTO]
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
        let body = ServerAPI.json(["media_id": media.id, "title": title, "artist": artist, "duration": duration] as [String: Any])
        let data = try await api.request("POST", "/v1/me/playlist", body: body)
        return try decodeAPI(TrackDTO.self, from: data).model
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
