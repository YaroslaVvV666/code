import SwiftUI
import Combine

struct FriendRoute: Identifiable, Hashable {
    let id: String
}

/// Вкладка «Друзья» на странице (как во ВКонтакте): заявки, список, поиск по друзьям
struct FriendsTab: View {
    @ObservedObject var model: UserPageModel
    let profile: UserProfile
    let open: (FriendRoute) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var query = ""
    @State private var busy: Set<String> = []

    private var s: Strings { Strings(lang: lang) }

    private var shown: [FriendUser] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.friends }
        return model.friends.filter { $0.name.lowercased().contains(q) || ($0.username ?? "").lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 14) {
            if model.isMe {
                if !model.incoming.isEmpty {
                    section(s.t("Заявки в друзья", "Friend requests"), count: model.incoming.count) {
                        ForEach(model.incoming) { u in
                            row(u) {
                                HStack(spacing: 8) {
                                    smallButton(s.t("Принять", "Accept"), filled: true, id: u.id) {
                                        await model.setFriend(id: u.id, add: true)
                                    }
                                    smallButton(s.t("Отклонить", "Decline"), filled: false, id: u.id) {
                                        await model.setFriend(id: u.id, add: false)
                                    }
                                }
                            }
                        }
                    }
                }
                if !model.outgoing.isEmpty {
                    section(s.t("Исходящие заявки", "Sent requests"), count: model.outgoing.count) {
                        ForEach(model.outgoing) { u in
                            row(u) {
                                smallButton(s.t("Отменить", "Cancel"), filled: false, id: u.id) {
                                    await model.setFriend(id: u.id, add: false)
                                }
                            }
                        }
                    }
                }
            }

            if model.friends.count > 6 {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.textTertiary)
                    TextField(s.t("Поиск по друзьям", "Search friends"), text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .foregroundStyle(theme.text)
                }
                .padding(.horizontal, 14).frame(height: 40)
                .background(theme.surface, in: Capsule())
                .padding(.horizontal, 16)
            }

            if !model.friendsLoaded {
                ProgressView().padding(.vertical, 40)
            } else if model.friends.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2").font(.system(size: 28, weight: .light)).foregroundStyle(theme.textSecondary)
                    Text(model.isMe ? s.t("Пока нет друзей", "No friends yet") : s.t("Друзей пока нет", "No friends yet"))
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                    if model.isMe {
                        Text(s.t("Найдите людей через поиск по @нику и отправьте заявку — когда её примут, вы станете друзьями.",
                                 "Find people by @username and send a request — once accepted, you're friends."))
                            .font(.system(size: 14)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
                    }
                }
                .padding(.vertical, 30).padding(.horizontal, 36)
            } else {
                section(s.t("Все друзья", "All friends"), count: shown.count) {
                    ForEach(shown) { u in
                        row(u) {
                            if model.isMe {
                                Menu {
                                    Button(role: .destructive) {
                                        Task { await model.setFriend(id: u.id, add: false) }
                                    } label: {
                                        Label(s.t("Удалить из друзей", "Remove friend"), systemImage: "person.fill.xmark")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(theme.textSecondary).frame(width: 36, height: 36)
                                        .contentShape(Rectangle())
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.bottom, 30)
        .task { if !model.friendsLoaded { await model.loadFriends() } }
    }

    private func section<C: View>(_ title: String, count: Int, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased() + "  \(count)")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 28).padding(.bottom, 6)
            VStack(spacing: 0) { content() }
                .card(theme, radius: 16)
                .padding(.horizontal, 16)
        }
    }

    private func row<T: View>(_ u: FriendUser, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 12) {
            Button { open(FriendRoute(id: u.id)) } label: {
                HStack(spacing: 12) {
                    AvatarView(name: u.name, size: 46, avatarID: u.avatarID).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(u.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                        if let n = u.username {
                            Text("@" + n).font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func smallButton(_ title: String, filled: Bool, id: String, action: @escaping () async -> Void) -> some View {
        Button {
            guard !busy.contains(id) else { return }
            busy.insert(id)
            Task {
                await action()
                busy.remove(id)
            }
        } label: {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(filled ? Color.white : theme.accentColor)
                .padding(.horizontal, 12).frame(height: 32)
                .background {
                    if filled { Capsule().fill(theme.accent) } else { Capsule().fill(theme.surface) }
                }
        }
        .buttonStyle(.plain)
        .opacity(busy.contains(id) ? 0.5 : 1)
    }
}
