import SwiftUI

/// Кто лайкнул пост — видит только автор
struct PostLikersSheet: View {
    let postID: String
    let count: Int

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var users: [FriendUser] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var profile: FriendRoute?

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 0) {
            Text(s.t("Лайкнули", "Liked by") + (loaded ? " · \(users.count)" : ""))
                .font(.system(size: 17, weight: .bold)).foregroundStyle(theme.text)
                .padding(.vertical, 18)
            if !loaded {
                ProgressView().padding(.top, 40)
                Spacer()
            } else if failed {
                Text(s.t("Не удалось загрузить", "Couldn't load"))
                    .font(.system(size: 15)).foregroundStyle(theme.textSecondary).padding(.top, 40)
                Spacer()
            } else if users.isEmpty {
                Text(s.t("Пока никто не лайкнул", "No likes yet"))
                    .font(.system(size: 15)).foregroundStyle(theme.textSecondary).padding(.top, 40)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(users) { u in
                            Button { profile = FriendRoute(id: u.id) } label: {
                                HStack(spacing: 12) {
                                    AvatarView(name: u.name, size: 46, avatarID: u.avatarID).clipShape(Circle())
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(u.name).font(.system(size: 16, weight: .semibold))
                                            .foregroundStyle(theme.text).lineLimit(1)
                                        if let n = u.username {
                                            Text("@" + n).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "heart.fill").font(.system(size: 14)).foregroundStyle(theme.like)
                                }
                                .padding(.horizontal, 20).padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .task {
            do { users = try await session.feedRepo.likers(postID: postID) } catch { failed = true }
            loaded = true
        }
        .fullScreenCover(item: $profile) { route in
            PublicProfileSheet(source: .id(route.id))
                .environmentObject(session)
                .environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
    }
}
