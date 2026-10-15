import SwiftUI
import Combine

/// Закладки: id постов хранятся на устройстве
@MainActor
final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()
    @Published private(set) var ids: [String]
    /// Сообщает серверу о сохранении / снятии (ставится при входе в аккаунт) — из этого считаются счётчики
    static var onChange: ((String, Bool) -> Void)?

    init() { ids = UserDefaults.standard.stringArray(forKey: "bookmarks.posts") ?? [] }

    func has(_ id: String) -> Bool { ids.contains(id) }

    func toggle(_ id: String) {
        let nowSaved: Bool
        if let i = ids.firstIndex(of: id) { ids.remove(at: i); nowSaved = false } else { ids.insert(id, at: 0); nowSaved = true }
        UserDefaults.standard.set(ids, forKey: "bookmarks.posts")
        Self.onChange?(id, nowSaved)
    }

    /// Сколько всего сохранили пост: данные сервера с поправкой на моё локальное действие
    func count(for post: Post) -> Int {
        max(0, post.saves + (has(post.id) ? 1 : 0) - (post.savedByMe ? 1 : 0))
    }
}

struct BookmarksSheet: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var flow: AuthFlow
    @ObservedObject private var store = BookmarkStore.shared
    @ObservedObject var vm: FeedViewModel
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var posts: [Post] = []
    @State private var loading = true
    @State private var commentsPost: Post?

    var body: some View {
        let s = Strings(lang: lang)
        VStack(spacing: 0) {
            Text(s.t("Закладки", "Bookmarks")).font(.system(size: 20, weight: .bold)).foregroundStyle(theme.text)
                .padding(.top, 22).padding(.bottom, 10)
            if loading {
                ProgressView().padding(.top, 40)
            } else if posts.isEmpty {
                Text(s.t("Сохраняйте посты кнопкой-закладкой", "Save posts with the bookmark button"))
                    .font(.system(size: 15)).foregroundStyle(theme.textSecondary).padding(.top, 40)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(posts.filter { store.has($0.id) }) { post in
                        PostCard(post: post, autoplay: false, onLike: { vm.toggleLike(post) },
                                 onComments: { commentsPost = post }, onDelete: {})
                        Divider().overlay(theme.stroke)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .task {
            var out: [Post] = []
            for id in store.ids { if let p = try? await session.feedRepo.post(id: id) { out.append(p) } }
            posts = out; loading = false
        }
        .sheet(item: $commentsPost) { post in
            CommentsSheet(post: post, vm: vm)
                .environmentObject(session).environmentObject(flow)
                .presentationBackground(theme.sheet)
        }
    }
}
