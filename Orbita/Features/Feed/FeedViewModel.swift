import SwiftUI
import Combine

@MainActor
final class FeedViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle, loading, loaded
        case failed(APIError)
    }

    @Published private(set) var posts: [Post] = []
    @Published private(set) var state: LoadState = .idle
    @Published var uploadProgress: Double?          // nil — ничего не загружается
    @Published var actionError: APIError?
    /// «Для вас» (по интересам) или «Свежее» (по времени); выбор запоминается
    @Published var forYou: Bool = UserDefaults.standard.object(forKey: "feed.forYou") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(forYou, forKey: "feed.forYou")
            if oldValue != forYou { Task { await load() } }
        }
    }
    @Published var authorFilter: String?            // показывать публикации одного автора

    private let repo: FeedRepository

    init(repo: FeedRepository) {
        self.repo = repo
    }

    /// Верхний ряд: авторы из ленты (нажатие — только их публикации)
    var stories: [Story] {
        var seen = Set<String>()
        var result: [Story] = []
        for post in posts where !post.isMine {
            guard seen.insert(post.author.id).inserted else { continue }
            let first = post.author.name.split(separator: " ").first.map(String.init) ?? post.author.name
            result.append(Story(id: post.author.id, name: first, avatarID: post.author.avatarID))
        }
        return Array(result.prefix(10))
    }

    private static func map(_ error: Error) -> APIError { (error as? APIError) ?? .offline }

    func load() async {
        if posts.isEmpty { state = .loading }
        do {
            posts = try await repo.loadFeed(forYou: forYou)
            state = .loaded
        } catch {
            state = .failed(Self.map(error))
        }
    }

    func toggleLike(_ post: Post) {
        guard let i = posts.firstIndex(where: { $0.id == post.id }) else { return }
        posts[i].likedByMe.toggle()
        posts[i].likes += posts[i].likedByMe ? 1 : -1
        let liked = posts[i].likedByMe
        let id = post.id
        Task { @MainActor in
            do {
                try await repo.setLike(postID: id, liked: liked)
            } catch {
                // сервер не принял — возвращаем как было
                if let j = posts.firstIndex(where: { $0.id == id }) {
                    posts[j].likedByMe = !liked
                    posts[j].likes += liked ? -1 : 1
                }
                actionError = Self.map(error)
            }
        }
    }

    /// Последняя опубликованная запись (в том числе «только на стене», которой нет в ленте)
    private(set) var lastPublished: Post?

    func publish(text: String, entities: [TextEntity], media: [PreparedMedia], options: PostOptions = PostOptions()) async -> Bool {
        actionError = nil
        uploadProgress = 0
        defer { uploadProgress = nil }
        do {
            var uploaded: [MediaItem] = []
            for (index, item) in media.enumerated() {
                uploaded.append(try await repo.uploadMedia(item))
                uploadProgress = Double(index + 1) / Double(media.count + 1)
            }
            let post = try await repo.createPost(text: text, entities: entities, media: uploaded, options: options)
            lastPublished = post
            if !options.wallOnly {                 // запись «только на стене» в ленту не добавляем
                posts.insert(post, at: 0)
                state = .loaded
            }
            return true
        } catch {
            actionError = Self.map(error)
            return false
        }
    }

    /// Сохранение правки: новые файлы загружаются, оставленные старые сохраняются
    func saveEdit(_ post: Post, text: String, entities: [TextEntity],
                  kept: [MediaItem], added: [PreparedMedia]) async -> Post? {
        actionError = nil
        uploadProgress = 0
        defer { uploadProgress = nil }
        do {
            var media = kept
            for (index, item) in added.enumerated() {
                media.append(try await repo.uploadMedia(item))
                uploadProgress = Double(index + 1) / Double(added.count + 1)
            }
            let saved = try await repo.editPost(id: post.id, text: text, entities: entities, media: media)
            if let i = posts.firstIndex(where: { $0.id == post.id }) { posts[i] = saved }
            return saved
        } catch {
            actionError = Self.map(error)
            return nil
        }
    }

    /// Публикация, которую удалили или изменили на стене
    func forget(_ id: String) { posts.removeAll { $0.id == id } }

    func delete(_ post: Post) {
        let backup = posts
        posts.removeAll { $0.id == post.id }
        let id = post.id
        Task { @MainActor in
            do { try await repo.deletePost(id: id) } catch {
                posts = backup
                actionError = Self.map(error)
            }
        }
    }

    func comments(for post: Post) async -> [Comment] {
        (try? await repo.comments(postID: post.id)) ?? []
    }

    func setCommentLike(_ id: String, liked: Bool) async -> Bool {
        do { try await repo.setCommentLike(id: id, liked: liked); return true } catch {
            actionError = Self.map(error)
            return false
        }
    }

    func setCommentPin(_ id: String, pinned: Bool) async -> Bool {
        do { try await repo.setCommentPin(id: id, pinned: pinned); return true } catch {
            actionError = Self.map(error)
            return false
        }
    }

    func addComment(to post: Post, text: String, parentID: String? = nil) async -> Comment? {
        do {
            let comment = try await repo.addComment(postID: post.id, text: text, parentID: parentID)
            if let i = posts.firstIndex(where: { $0.id == post.id }) { posts[i].comments += 1 }
            return comment
        } catch {
            actionError = Self.map(error)
            return nil
        }
    }
}
