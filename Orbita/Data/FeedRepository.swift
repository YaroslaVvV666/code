import Foundation

protocol FeedRepository: Sendable {
    func loadFeed(forYou: Bool) async throws -> [Post]
    func uploadMedia(_ media: PreparedMedia) async throws -> MediaItem
    func createPost(text: String, entities: [TextEntity], media: [MediaItem]) async throws -> Post
    func setLike(postID: String, liked: Bool) async throws
    func likers(postID: String) async throws -> [FriendUser]
    func deletePost(id: String) async throws
    func editPost(id: String, text: String, entities: [TextEntity], media: [MediaItem]) async throws -> Post
    func post(id: String) async throws -> Post
    func comments(postID: String) async throws -> [Comment]
    func addComment(postID: String, text: String, parentID: String?) async throws -> Comment
    func setCommentLike(id: String, liked: Bool) async throws
    func setCommentPin(id: String, pinned: Bool) async throws
}

// MARK: - DTO (формат сервера)

struct AuthorDTO: Decodable {
    let id: String
    let name: String
    let username: String?
    let avatar: String?
    var model: Author { Author(id: id, name: name, username: username, avatarID: avatar) }
}

struct MediaDTO: Decodable {
    let id: String
    let kind: String
    let width: Int?
    let height: Int?
    let duration: Double?
    let thumb: String?

    var model: MediaItem {
        MediaItem(id: id, kind: MediaKind(rawValue: kind) ?? .image,
                  width: width ?? 0, height: height ?? 0,
                  duration: (duration ?? 0) > 0 ? duration : nil, thumbID: thumb)
    }
}

struct PostDTO: Decodable {
    let id: String
    let author: AuthorDTO
    let text: String
    let entities: [TextEntity]
    let media: [MediaDTO]
    let createdAt: Double
    let likes: Int
    let comments: Int
    let likedByMe: Bool
    let mine: Bool
    let commentsEnabled: Bool
    let editedAt: Double?
    let saves: Int?
    let savedByMe: Bool?
    let reposts: Int?
    let repostedByMe: Bool?
    let music: MusicDTO?

    struct MusicDTO: Decodable { let title: String; let artist: String; let media: String }

    var model: Post {
        Post(id: id, author: author.model, text: text, entities: entities, media: media.map(\.model),
             createdAt: Date(timeIntervalSince1970: createdAt), likes: likes, comments: comments,
             likedByMe: likedByMe, isMine: mine, commentsEnabled: commentsEnabled,
             editedAt: editedAt.map { Date(timeIntervalSince1970: $0) },
             saves: saves ?? 0, savedByMe: savedByMe ?? false,
             reposts: reposts ?? 0, repostedByMe: repostedByMe ?? false,
             music: music.map { PostMusic(title: $0.title, artist: $0.artist, mediaID: $0.media) })
    }
}

struct CommentDTO: Decodable {
    let id: String
    let author: AuthorDTO
    let text: String
    let createdAt: Double
    let likes: Int?
    let likedByMe: Bool?
    let likedByAuthor: Bool?
    let parentId: String?
    let replyToName: String?
    let pinned: Bool?
    var model: Comment {
        Comment(id: id, author: author.model, text: text, createdAt: Date(timeIntervalSince1970: createdAt),
                likes: likes ?? 0, likedByMe: likedByMe ?? false, likedByAuthor: likedByAuthor ?? false,
                parentID: parentId, replyToName: replyToName, pinned: pinned ?? false)
    }
}

struct PostListDTO: Decodable { let posts: [PostDTO] }
private struct CommentListDTO: Decodable { let comments: [CommentDTO] }

func decodeAPI<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do { return try JSONDecoder.orbita.decode(type, from: data) } catch { throw APIError.invalidResponse }
}

// MARK: - Реализация поверх сервера Orbita

struct RemoteFeedRepository: FeedRepository {
    let api: ServerAPI

    func loadFeed(forYou: Bool) async throws -> [Post] {
        var query = ["limit": "60"]
        if forYou { query["sort"] = "for_you" }
        let data = try await api.request("GET", "/v1/posts", query: query)
        return try decodeAPI(PostListDTO.self, from: data).posts.map(\.model)
    }

    func uploadMedia(_ media: PreparedMedia) async throws -> MediaItem {
        var query = ["w": "\(media.width)", "h": "\(media.height)"]
        switch media.source {
        case .image(let data):
            query["kind"] = "image"
            let result = try await api.upload("/v1/media", query: query, payload: .data(data), contentType: "image/jpeg")
            return try decodeAPI(MediaDTO.self, from: result).model

        case .png(let data):
            query["kind"] = "image"
            let result = try await api.upload("/v1/media", query: query, payload: .data(data), contentType: "image/png")
            return try decodeAPI(MediaDTO.self, from: result).model

        case .video(let url):
            // сначала обложка, потом само видео
            let thumbResult = try await api.upload("/v1/media", query: ["kind": "image", "w": "\(media.width)", "h": "\(media.height)"],
                                                   payload: .data(media.thumbnail), contentType: "image/jpeg")
            let thumb = try decodeAPI(MediaDTO.self, from: thumbResult)
            query["kind"] = "video"
            query["dur"] = String(media.duration ?? 0)
            query["thumb"] = thumb.id
            let result = try await api.upload("/v1/media", query: query, payload: .file(url),
                                          contentType: url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4")
            return try decodeAPI(MediaDTO.self, from: result).model
        }
    }

    private func postBody(text: String, entities: [TextEntity], media: [MediaItem]) -> Data {
        let entityList: [[String: Any]] = entities.map { e in
            var item: [String: Any] = ["type": e.type, "offset": e.offset, "length": e.length]
            if let url = e.url { item["url"] = url }
            return item
        }
        let mediaList: [[String: Any]] = media.map { m in
            ["id": m.id, "width": m.width, "height": m.height]
        }
        return ServerAPI.json(["text": text, "entities": entityList, "media": mediaList] as [String: Any])
    }

    func createPost(text: String, entities: [TextEntity], media: [MediaItem]) async throws -> Post {
        let data = try await api.request("POST", "/v1/posts", body: postBody(text: text, entities: entities, media: media))
        return try decodeAPI(PostDTO.self, from: data).model
    }

    func editPost(id: String, text: String, entities: [TextEntity], media: [MediaItem]) async throws -> Post {
        let data = try await api.request("PUT", "/v1/posts/\(id)", body: postBody(text: text, entities: entities, media: media))
        return try decodeAPI(PostDTO.self, from: data).model
    }

    func post(id: String) async throws -> Post {
        try decodeAPI(PostDTO.self, from: try await api.request("GET", "/v1/posts/\(id)")).model
    }

    func likers(postID: String) async throws -> [FriendUser] {
        struct Row: Decodable { let id: String; let name: String; let username: String?; let avatar: String? }
        struct List: Decodable { let users: [Row] }
        let data = try await api.request("GET", "/v1/posts/\(postID)/likes")
        return try decodeAPI(List.self, from: data).users.map {
            FriendUser(id: $0.id, name: $0.name, username: $0.username, avatarID: $0.avatar, state: "none")
        }
    }

    func setLike(postID: String, liked: Bool) async throws {
        _ = try await api.request(liked ? "PUT" : "DELETE", "/v1/posts/\(postID)/like")
    }

    func deletePost(id: String) async throws {
        _ = try await api.request("DELETE", "/v1/posts/\(id)")
    }

    func comments(postID: String) async throws -> [Comment] {
        let data = try await api.request("GET", "/v1/posts/\(postID)/comments")
        return try decodeAPI(CommentListDTO.self, from: data).comments.map(\.model)
    }

    func addComment(postID: String, text: String, parentID: String?) async throws -> Comment {
        var body: [String: Any] = ["text": text]
        if let parentID { body["parent_id"] = parentID }
        let data = try await api.request("POST", "/v1/posts/\(postID)/comments", body: ServerAPI.json(body))
        return try decodeAPI(CommentDTO.self, from: data).model
    }

    func setCommentLike(id: String, liked: Bool) async throws {
        _ = try await api.request(liked ? "PUT" : "DELETE", "/v1/comments/\(id)/like")
    }

    func setCommentPin(id: String, pinned: Bool) async throws {
        _ = try await api.request(pinned ? "PUT" : "DELETE", "/v1/comments/\(id)/pin")
    }
}
