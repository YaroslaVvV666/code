import SwiftUI

struct CommentsRoute: Identifiable {
    let id = UUID()
    let channelID: String
    let post: ChatMessage
}

/// «9 комментариев», «1 комментарий», «Прокомментировать»
enum CommentWord {
    static func count(_ n: Int, lang: AppLanguage) -> String {
        guard lang == .ru else { return n == 1 ? "1 comment" : "\(n) comments" }
        let m100 = n % 100, m10 = n % 10
        let w = (11...14).contains(m100) ? "комментариев" : (m10 == 1 ? "комментарий" : ((2...4).contains(m10) ? "комментария" : "комментариев"))
        return "\(n) \(w)"
    }
}

/// Комментарии к посту канала — как чат в Telegram: сверху сам пост, под ним «Начало обсуждения»
/// и комментарии пузырями (чужие слева с аватаркой и именем, свои справа). На комментарий можно ответить свайпом.
/// Это ветка в привязанном чате обсуждения: все комментарии — ответы на копию поста там
struct ChannelCommentsSheet: View {
    let route: CommentsRoute

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss

    @State private var comments: [ChatMessage] = []
    @State private var mirrorID: String?
    @State private var canComment = true
    @State private var loaded = false
    @State private var text = ""
    @State private var sending = false
    @State private var errorText: String?
    @State private var replyTo: ChatMessage?
    @State private var actionFor: ChatMessage?
    @State private var jumpTo: String?
    @State private var highlightID: String?
    @State private var profileID: String?
    @FocusState private var focused: Bool

    private var s: Strings { Strings(lang: lang) }

    /// Подряд идущие комментарии одного человека — одна группа: имя у первого, аватарка у последнего
    private var entries: [(message: ChatMessage, isFirst: Bool, isLast: Bool)] {
        comments.enumerated().map { i, m in
            let prev = i > 0 ? comments[i - 1] : nil
            let next = i + 1 < comments.count ? comments[i + 1] : nil
            func same(_ o: ChatMessage?) -> Bool {
                guard let o else { return false }
                return o.sender?.id == m.sender?.id && abs(o.createdAt.timeIntervalSince(m.createdAt)) < 300
            }
            return (m, !same(prev), !same(next))
        }
    }

    var body: some View {
        ZStack {
            SpaceBackground(isDark: theme.dark, showStars: false).ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        MessageRow(message: route.post, isFirst: true, isLast: true,
                                   onReply: {}, onEdit: {}, onDelete: {}, onOpenMedia: { _, _ in }, onOpenFile: { _ in },
                                   interactive: false)
                            .padding(.bottom, 6)
                        discussionPill
                        if !loaded {
                            ProgressView().tint(.white).padding(.top, 30)
                        } else if comments.isEmpty {
                            emptyState
                        }
                        ForEach(entries, id: \.message.id) { e in
                            commentRow(e.message, isFirst: e.isFirst, isLast: e.isLast)
                                .id(e.message.id)
                                .background(highlightID == e.message.id ? theme.accentColor.opacity(0.18) : Color.clear)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        Color.clear.frame(height: 6).id("bottom")
                    }
                    .padding(.horizontal, 8).padding(.top, 6)
                    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: comments.count)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: comments.last?.id) { old, new in
                    // новый комментарий внизу (свой или чужой, пока читаешь конец) — доезжаем до него
                    guard old != nil || loaded, new != nil else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: jumpTo) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
                    withAnimation(.easeInOut(duration: 0.25)) { highlightID = id }
                    jumpTo = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                        withAnimation(.easeInOut(duration: 0.5)) { if highlightID == id { highlightID = nil } }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { inputArea }
        .preferredColorScheme(theme.dark ? .dark : .light)
        .edgeSwipeBack { dismiss() }
        .task {
            // пока экран открыт, комментарии обновляются сами
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .confirmationDialog("", isPresented: Binding(get: { actionFor != nil }, set: { if !$0 { actionFor = nil } }),
                            presenting: actionFor) { m in
            if canComment { Button(s.reply) { reply(to: m) } }
            if !m.text.isEmpty { Button(s.copy) { UIPasteboard.general.string = m.text } }
            Button(s.cancel, role: .cancel) {}
        }
        .profileSheet(id: $profileID)
    }

    // MARK: Шапка — как у переписки

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
                    .frame(width: 44, height: 44).glassCircle()
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text(s.t("Комментарии", "Comments")).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                Text(loaded ? (comments.isEmpty ? s.t("пока нет", "none yet") : CommentWord.count(comments.count, lang: lang)) : " ")
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 22).frame(height: 46).glassCapsule()
            Spacer(minLength: 0)
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 6)
    }

    private var discussionPill: some View {
        Text(s.t("Начало обсуждения", "Discussion started"))
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Color.black.opacity(theme.dark ? 0.35 : 0.25), in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 34)).foregroundStyle(theme.accentColor)
            Text(s.t("Комментариев пока нет", "No comments yet")).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
            Text(s.t("Напишите первым", "Be the first to comment")).font(.system(size: 14)).foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 28).padding(.vertical, 20)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.top, 30)
    }

    // MARK: Комментарий

    private func commentRow(_ m: ChatMessage, isFirst: Bool, isLast: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            if !m.mine {
                if isLast, let sender = m.sender {
                    Button { profileID = sender.id } label: {
                        AvatarView(name: sender.name, size: 32, avatarID: sender.avatarID).clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 32, height: 32)
                }
            }
            MessageRow(message: m, isFirst: isFirst, isLast: isLast,
                       onReply: { reply(to: m) }, onEdit: {}, onDelete: {},
                       onOpenMedia: { _, _ in }, onOpenFile: { _ in },
                       showSender: true,
                       onJumpToReply: { jumpTo = $0 },
                       onLongPress: { actionFor = m },
                       onOpenProfile: { id in if id.lowercased() != session.serverID { profileID = id } })
        }
        .padding(.top, isFirst ? 6 : 0)
    }

    // MARK: Поле ввода — как в переписке

    private var inputArea: some View {
        VStack(spacing: 6) {
            if let r = replyTo {
                HStack(spacing: 10) {
                    Image(systemName: "arrowshape.turn.up.left").font(.system(size: 16)).foregroundStyle(theme.accentColor)
                    Capsule().fill(theme.accentColor).frame(width: 2, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.mine ? s.t("Вы", "You") : (r.sender?.name ?? "")).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.accentColor).lineLimit(1)
                        Text(r.summary).font(.system(size: 14)).foregroundStyle(theme.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Button { withAnimation(.easeOut(duration: 0.18)) { replyTo = nil } } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.textSecondary)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .glass(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let errorText {
                Text(errorText).font(.system(size: 13)).foregroundStyle(theme.danger)
            }
            if canComment {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(s.t("Комментарий", "Comment"), text: $text, axis: .vertical)
                        .font(.system(size: 17))
                        .lineLimit(1...6).focused($focused)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    Button(action: send) {
                        Group {
                            if sending { ProgressView().tint(.white) }
                            else { Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).foregroundStyle(.white) }
                        }
                        .frame(width: 44, height: 44)
                        .background(canSend ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.textTertiary.opacity(0.45)), in: Circle())
                    }
                    .buttonStyle(PressStyle())
                    .disabled(!canSend)
                    .animation(.easeOut(duration: 0.15), value: canSend)
                }
            } else if loaded {
                Text(s.t("Подпишитесь на канал, чтобы комментировать", "Join the channel to comment"))
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 18).frame(height: 44).glassCapsule()
            }
        }
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: replyTo?.id)
    }

    private var canSend: Bool { !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func reply(to m: ChatMessage) {
        guard canComment else { return }
        Haptics.impact(.light)
        withAnimation(.easeOut(duration: 0.18)) { replyTo = m }
        focused = true
    }

    /// Ответ «на пост» (копию поста в обсуждении) цитатой не показываем — это и есть обычный комментарий
    private func prepared(_ list: [ChatMessage]) -> [ChatMessage] {
        list.map { c in
            var m = c
            if let mirrorID, m.reply?.id == mirrorID { m.reply = nil }
            return m
        }
    }

    private func load() async {
        guard let thread = try? await session.messengerRepo.comments(channelID: route.channelID, messageID: route.post.id) else {
            loaded = true
            return
        }
        mirrorID = thread.mirrorID
        let fresh = prepared(thread.messages)
        if fresh != comments { comments = fresh }
        canComment = thread.canComment
        loaded = true
    }

    private func send() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        sending = true
        errorText = nil
        let target = replyTo?.id
        Task {
            defer { sending = false }
            do {
                let sent = try await session.messengerRepo.postComment(channelID: route.channelID, messageID: route.post.id,
                                                                     text: value, replyTo: target)
                text = ""
                replyTo = nil
                Haptics.impact(.light)
                if !comments.contains(where: { $0.id == sent.id }) { comments.append(contentsOf: prepared([sent])) }
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
