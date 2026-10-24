import Foundation

// MARK: - Модели

struct ScheduledItem: Identifiable, Decodable, Equatable {
    let id: String
    let text: String
    let sendAt: Double
    let attachments: Int
    var date: Date { Date(timeIntervalSince1970: sendAt) }
}

struct StoryUser: Decodable, Equatable, Hashable {
    let id: String
    let name: String
    let username: String?
    let avatar: String?
}

struct StoryItem: Identifiable, Decodable, Equatable {
    let id: String
    let mediaId: String
    let kind: String
    let caption: String
    let createdAt: Double
    let expiresAt: Double
    var permanent: Bool? = nil
    var thumb: String? = nil            // обложка видео-истории (для сетки в профиле)
    var viewed: Bool
    let views: Int
    var likes: Int? = nil
    var liked: Bool? = nil
    var isVideo: Bool { kind == "video" }
}

struct StoryGroup: Identifiable, Decodable, Equatable {
    let user: StoryUser
    var items: [StoryItem]
    var allViewed: Bool
    var suggested: Bool? = nil
    var id: String { user.id }
}

struct StoryViewer: Identifiable, Decodable {
    let id: String
    let name: String
    let username: String?
    let avatar: String?
    let at: Double
    let liked: Bool?
}

private struct ScheduledList: Decodable { let items: [ScheduledItem] }
private struct StoryList: Decodable { let stories: [StoryGroup] }
private struct ViewerList: Decodable { let viewers: [StoryViewer]; let likes: Int? }

// MARK: - Запросы: отложенные сообщения и истории

struct ExtrasAPI {
    let api: ServerAPI

    // Отложенные
    func schedule(peerID: String, text: String, entities: [TextEntity], attachments: [OutgoingAttachment], at date: Date) async throws {
        var body: [String: Any] = ["text": text, "entities": RemoteMessengerRepository.entityJSON(entities),
                                   "send_at": date.timeIntervalSince1970]
        if !attachments.isEmpty { body["attachments"] = attachments.map(\.json) }
        _ = try await api.request("POST", "/v1/chats/\(peerID)/messages", body: ServerAPI.json(body))
    }

    func scheduled(peerID: String) async -> [ScheduledItem] {
        guard let data = try? await api.request("GET", "/v1/chats/\(peerID)/scheduled"),
              let list = try? decodeAPI(ScheduledList.self, from: data) else { return [] }
        return list.items
    }

    func cancelScheduled(id: String) async {
        _ = try? await api.request("DELETE", "/v1/scheduled/\(id)")
    }

    // Предпросмотр ссылки
    func linkPreview(url: String) async -> LinkPreviewData? {
        let query = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let data = try? await api.request("GET", "/v1/link_preview?url=\(query)") else { return nil }
        return try? decodeAPI(LinkPreviewData.self, from: data)
    }

    // Истории
    func stories() async -> [StoryGroup]? {
        guard let data = try? await api.request("GET", "/v1/stories"),
              let list = try? decodeAPI(StoryList.self, from: data) else { return nil }
        return list.stories
    }

    /// Одна история по id (для «ответа на историю» в переписке); nil — истории уже нет
    func story(id: String) async -> StoryGroup? {
        guard let data = try? await api.request("GET", "/v1/stories/\(id)") else { return nil }
        return try? decodeAPI(StoryGroup.self, from: data)
    }

    func publishStory(_ media: PreparedMedia, caption: String, forever: Bool = false) async throws {
        let item = try await RemoteFeedRepository(api: api).uploadMedia(media)
        let isVideo: Bool
        if case .video = media.source { isVideo = true } else { isVideo = false }
        var body: [String: Any] = ["media_id": item.id, "kind": isVideo ? "video" : "image", "caption": caption]
        if forever { body["forever"] = true }
        _ = try await api.request("POST", "/v1/stories", body: ServerAPI.json(body))
    }

    func markViewed(storyID: String) async {
        _ = try? await api.request("POST", "/v1/stories/\(storyID)/view")
    }

    func viewers(storyID: String) async -> [StoryViewer] {
        guard let data = try? await api.request("GET", "/v1/stories/\(storyID)/viewers"),
              let list = try? decodeAPI(ViewerList.self, from: data) else { return [] }
        return list.viewers
    }

    func likeStory(id: String, liked: Bool) async throws -> StoryItem {
        let data = try await api.request("PUT", "/v1/stories/\(id)/like", body: ServerAPI.json(["liked": liked] as [String: Any]))
        return try decodeAPI(StoryItem.self, from: data)
    }

    /// Ответ на историю: приходит человеку в личку как сообщение-ответ с превью истории
    func replyToStory(peerID: String, storyID: String, text: String) async throws {
        let body: [String: Any] = ["text": text, "story_id": storyID]
        _ = try await api.request("POST", "/v1/chats/\(peerID)/messages", body: ServerAPI.json(body))
    }

    func viewersWithLikes(storyID: String) async -> (viewers: [StoryViewer], likes: Int) {
        guard let data = try? await api.request("GET", "/v1/stories/\(storyID)/viewers"),
              let list = try? decodeAPI(ViewerList.self, from: data) else { return ([], 0) }
        return (list.viewers, list.likes ?? 0)
    }

    func deleteStory(id: String) async {
        _ = try? await api.request("DELETE", "/v1/stories/\(id)")
    }

    // Постоянные истории пользователя (в профиле)
    func profileStories(userID: String) async -> [StoryItem] {
        guard let data = try? await api.request("GET", "/v1/users/\(userID)/stories"),
              let list = try? decodeAPI(ProfileStoryList.self, from: data) else { return [] }
        return list.stories
    }

    func makeForever(storyID: String) async throws {
        _ = try await api.request("PUT", "/v1/stories/\(storyID)/forever")
    }

    // Пересылка, опросы, «кто прочитал»
    func forward(ids: [String], to peerID: String, hideSender: Bool = false, hideCaption: Bool = false) async throws {
        let body: [String: Any] = ["ids": ids, "hide_sender": hideSender, "hide_caption": hideCaption]
        _ = try await api.request("POST", "/v1/chats/\(peerID)/forward", body: ServerAPI.json(body))
    }

    func sharePost(id: String, to peerID: String, hideSender: Bool = false, hideCaption: Bool = false) async throws {
        let body: [String: Any] = ["post_id": id, "hide_sender": hideSender, "hide_caption": hideCaption]
        _ = try await api.request("POST", "/v1/chats/\(peerID)/share-post", body: ServerAPI.json(body))
    }

    func sendPoll(peerID: String, question: String, options: [String], multiple: Bool, anonymous: Bool) async throws {
        let poll: [String: Any] = ["question": question, "options": options, "multiple": multiple, "anonymous": anonymous]
        let body: [String: Any] = ["text": question, "poll": poll]
        _ = try await api.request("POST", "/v1/chats/\(peerID)/messages", body: ServerAPI.json(body))
    }

    func vote(messageID: String, options: [Int]) async throws -> PollInfo {
        let data = try await api.request("PUT", "/v1/messages/\(messageID)/vote", body: ServerAPI.json(["options": options] as [String: Any]))
        return try decodeAPI(PollDTO.self, from: data).model
    }

    func closePoll(messageID: String) async throws -> PollInfo {
        let data = try await api.request("PUT", "/v1/messages/\(messageID)/poll-close")
        return try decodeAPI(PollDTO.self, from: data).model
    }

    func info(messageID: String) async throws -> MessageInfo {
        let data = try await api.request("GET", "/v1/messages/\(messageID)/info")
        return try decodeAPI(MessageInfoDTO.self, from: data).model
    }
}

private struct ProfileStoryList: Decodable { let stories: [StoryItem] }


struct LinkPreviewData: Decodable, Equatable {
    let title: String
    let description: String
    let site: String
    let image: String
    let url: String
}
