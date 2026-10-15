import SwiftUI

struct CommentsRoute: Identifiable {
    let id = UUID()
    let channelID: String
    let post: ChatMessage
}

/// Комментарии к посту канала: ветка в привязанном чате обсуждения (как в Telegram)
struct ChannelCommentsSheet: View {
    let route: CommentsRoute

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss

    @State private var comments: [ChatMessage] = []
    @State private var canComment = true
    @State private var loaded = false
    @State private var text = ""
    @State private var sending = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        postCard
                        if !loaded {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
                        } else if comments.isEmpty {
                            Text(s.t("Комментариев пока нет. Напишите первым.", "No comments yet. Be the first."))
                                .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                                .frame(maxWidth: .infinity).padding(.top, 24)
                        }
                        ForEach(comments) { c in commentRow(c).id(c.id) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: comments.count) { old, new in
                    if new > old, let last = comments.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if let errorText {
                Text(errorText).font(.system(size: 13)).foregroundStyle(theme.danger).padding(.horizontal, 16).padding(.bottom, 4)
            }
            inputBar
        }
        .background(theme.sheet)
        .task {
            // пока окно открыто, комментарии обновляются сами
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private var header: some View {
        HStack {
            Color.clear.frame(width: 60, height: 1)
            Spacer()
            VStack(spacing: 1) {
                Text(s.t("Комментарии", "Comments")).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
                if loaded {
                    Text(comments.isEmpty ? s.t("пока нет", "none yet") : "\(comments.count)")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
            }
            Spacer()
            Button(s.close) { dismiss() }.foregroundStyle(theme.accentColor).frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var postCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.t("Пост канала", "Channel post")).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accentColor)
            Text(route.post.summary).font(.system(size: 15)).foregroundStyle(theme.text).lineLimit(4)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .card(theme, radius: 14)
    }

    private func commentRow(_ c: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(name: c.sender?.name ?? "", size: 34, avatarID: c.sender?.avatarID).clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(c.mine ? s.t("Вы", "You") : (c.sender?.name ?? "")).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accentColor).lineLimit(1)
                    Text(ChatTime.clock(c.createdAt)).font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                }
                LinkText(text: c.text, tint: theme.accentColor)
                    .font(.system(size: 16)).foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer(minLength: 20)
        }
    }

    @ViewBuilder
    private var inputBar: some View {
        if canComment {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(s.t("Комментарий", "Comment"), text: $text, axis: .vertical)
                    .lineLimit(1...5).focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(canSend ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.textTertiary.opacity(0.5)), in: Circle())
                }
                .buttonStyle(PressStyle())
                .disabled(!canSend)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        } else {
            Text(s.t("Подпишитесь на канал, чтобы комментировать", "Join the channel to comment"))
                .font(.system(size: 14)).foregroundStyle(theme.textSecondary).padding(16)
        }
    }

    private var canSend: Bool { !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func load() async {
        guard let thread = try? await session.messengerRepo.comments(channelID: route.channelID, messageID: route.post.id) else {
            loaded = true
            return
        }
        if thread.messages != comments { comments = thread.messages }
        canComment = thread.canComment
        loaded = true
    }

    private func send() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        sending = true
        errorText = nil
        Task {
            defer { sending = false }
            do {
                let sent = try await session.messengerRepo.postComment(channelID: route.channelID, messageID: route.post.id, text: value)
                text = ""
                Haptics.impact(.light)
                if !comments.contains(where: { $0.id == sent.id }) { comments.append(sent) }
            } catch {
                errorText = s.api((error as? APIError) ?? .offline)
            }
        }
    }
}

/// Выбор чата для комментариев в настройках канала
struct DiscussionPicker: View {
    @Binding var selected: DiscussionRef?
    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    private var groups: [ChatSummary] {
        session.chats.chats.filter { $0.peer.isGroup && !$0.peer.isChannel }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                Button { selected = nil } label: {
                    Label(s.t("Без обсуждения", "No discussion"), systemImage: selected == nil ? "checkmark" : "nosign")
                }
                ForEach(groups) { g in
                    Button { selected = DiscussionRef(id: g.peer.id, name: g.peer.name) } label: {
                        Label(g.peer.name, systemImage: selected?.id == g.peer.id ? "checkmark" : "person.3")
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(theme.accentColor).frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.t("Обсуждение", "Discussion")).font(.system(size: 16)).foregroundStyle(theme.text)
                        Text(selected?.name ?? s.t("Не выбрано", "Not set")).font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, 14).frame(height: 56).card(theme, radius: 14)
            }
            .buttonStyle(.plain)
            Text(s.t("Выберите свою группу — под каждым постом появятся комментарии, а сами посты продублируются в группе. Подписчики канала смогут комментировать.",
                     "Pick one of your groups — every post gets comments, and posts are mirrored in that group. Channel subscribers can comment."))
                .font(.system(size: 12)).foregroundStyle(theme.textTertiary).padding(.horizontal, 4)
        }
    }
}
