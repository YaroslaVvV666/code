import SwiftUI

// MARK: - Каталог: каналы и группы (вкладка «Сообщества» и «Открытые» в новом чате)

struct CommunityDirectory: View {
    let session: AppSession
    var mine: [ChatSummary] = []
    var onOpen: (ChatPeer) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var query = ""
    @State private var filter = 0                 // 0 — всё, 1 — каналы, 2 — группы
    @State private var found: [GroupPreview] = []
    @State private var messageHits: [MessageHit] = []
    @State private var loaded = false
    @State private var busy: String?
    @State private var notice: String?
    private var s: Strings { Strings(lang: lang) }

    private var typeParam: String? { filter == 1 ? "channel" : (filter == 2 ? "group" : nil) }

    private var myList: [ChatSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return mine.filter { c in
            guard c.peer.isGroup else { return false }
            if filter == 1 && !c.peer.isChannel { return false }
            if filter == 2 && c.peer.isChannel { return false }
            return q.isEmpty || c.peer.name.lowercased().contains(q)
        }
    }

    private var discover: [GroupPreview] { found.filter { !$0.joined } }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.textTertiary)
                TextField(s.t("Поиск каналов и групп", "Search channels and groups"), text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(theme.textTertiary) }
                }
            }
            .font(.system(size: 16))
            .padding(.horizontal, 14).frame(height: 40).card(theme, radius: 14).padding(.horizontal, 16)

            Picker("", selection: $filter) {
                Text(s.t("Все", "All")).tag(0)
                Text(s.t("Каналы", "Channels")).tag(1)
                Text(s.t("Группы", "Groups")).tag(2)
            }
            .pickerStyle(.segmented).padding(.horizontal, 16)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !myList.isEmpty {
                        header(s.t("МОИ", "MINE"))
                        ForEach(myList) { chat in myRow(chat) }
                    }
                    header(s.t("КАТАЛОГ", "DIRECTORY"))
                    if discover.isEmpty && loaded {
                        Text(query.isEmpty ? s.t("Пока нет публичных каналов и групп. Создайте первый!", "No public channels or groups yet. Create the first one!")
                                           : s.t("Ничего не найдено", "Nothing found"))
                            .font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                            .frame(maxWidth: .infinity).padding(30)
                    }
                    ForEach(discover) { g in row(g) }
                    if !messageHits.isEmpty {
                        header(s.t("СООБЩЕНИЯ", "MESSAGES"))
                        ForEach(messageHits) { hit in
                            MessageHitRow(hit: hit, query: query) { onOpen(hit.peer) }
                        }
                    }
                }
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
        }
        .overlay(alignment: .bottom) {
            if let notice {
                ToastView(text: notice).padding(.bottom, 24)
                    .task(id: notice) { try? await Task.sleep(nanoseconds: 2_500_000_000); self.notice = nil }
            }
        }
        .task(id: "\(query)|\(filter)") {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            found = (try? await session.messengerRepo.publicGroups(query: query, type: typeParam)) ?? []
            loaded = true
            // ключевые слова в сообщениях каналов и групп
            let raw = query.trimmingCharacters(in: .whitespaces)
            if raw.count >= 2 {
                let hits = (try? await session.messengerRepo.searchMessages(query: raw)) ?? []
                if Task.isCancelled { return }
                messageHits = hits.filter { h in
                    h.peer.isGroup && (filter == 0 || (filter == 1) == h.peer.isChannel)
                }
            } else {
                messageHits = []
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
    }

    private func icon(channel: Bool) -> some View {
        Image(systemName: channel ? "megaphone.fill" : "person.2.fill")
            .font(.system(size: 11)).foregroundStyle(theme.textTertiary)
    }

    private func myRow(_ chat: ChatSummary) -> some View {
        Button { onOpen(chat.peer) } label: {
            HStack(spacing: 12) {
                AvatarView(name: chat.peer.name, size: 48, avatarID: chat.peer.avatarID).clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        icon(channel: chat.peer.isChannel)
                        Text(chat.peer.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                    }
                    Text("\(chat.peer.memberCount) \(s.memberWord(channel: chat.peer.isChannel))")
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                }
                Spacer()
                if chat.mentions > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "at").font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color(red: 0.90, green: 0.28, blue: 0.17))
                        if chat.unread > 0 {
                            Text(chat.unread > 99 ? "99+" : "\(chat.unread)")
                                .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                                .background(chat.muted ? AnyShapeStyle(theme.textTertiary) : AnyShapeStyle(Color(red: 0.90, green: 0.28, blue: 0.17)), in: Capsule())
                        }
                    }
                } else if chat.unread > 0 {
                    Text(chat.unread > 99 ? "99+" : "\(chat.unread)")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                        .background(chat.muted ? AnyShapeStyle(theme.textTertiary) : AnyShapeStyle(theme.accent), in: Capsule())
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ g: GroupPreview) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: g.name, size: 52).clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    icon(channel: g.isChannel)
                    Text(g.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                }
                Text("\(g.members) \(s.memberWord(channel: g.isChannel))" + (g.handle.map { " · @" + $0 } ?? ""))
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(1)
                if !g.about.isEmpty {
                    Text(g.about).font(.system(size: 13)).foregroundStyle(theme.textTertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            Button { join(g) } label: {
                Group {
                    if busy == g.id { ProgressView().tint(.white) } else { Text(buttonTitle(g)).lineLimit(1) }
                }
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 32)
                .background(g.pending ? AnyShapeStyle(theme.textTertiary) : AnyShapeStyle(theme.accent), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(g.pending || busy != nil)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { if g.kind == "open" { onOpen(ChatPeer(preview: g)) } }
    }

    private func buttonTitle(_ g: GroupPreview) -> String {
        if g.pending { return s.t("Заявка отправлена", "Request sent") }
        if g.approve { return s.t("Подать заявку", "Request") }
        return g.isChannel ? s.t("Подписаться", "Follow") : s.t("Вступить", "Join")
    }

    private func join(_ g: GroupPreview) {
        busy = g.id
        Task {
            defer { busy = nil }
            do {
                let info = try await session.messengerRepo.joinGroup(id: g.id)
                await session.chats.refresh()
                if info.pending {
                    if let i = found.firstIndex(where: { $0.id == g.id }) { found[i].pending = true }
                    notice = s.t("Заявка отправлена", "Request sent")
                } else {
                    onOpen(ChatPeer(group: info))
                }
            } catch { notice = s.api((error as? APIError) ?? .offline) }
        }
    }
}

// MARK: - Каталог окном (из «Нового чата»)

struct PublicGroupsSheet: View {
    let onJoined: (ChatPeer) -> Void

    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lang) private var lang

    var body: some View {
        NavigationStack {
            CommunityDirectory(session: session, onOpen: onJoined)
                .navigationTitle(Strings(lang: lang).tabCommunities)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(Strings(lang: lang).close) { dismiss() } } }
        }
    }
}

// MARK: - Вкладка «Сообщества»

struct CommunitiesView: View {
    let session: AppSession
    @ObservedObject var chats: ChatsModel

    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var openChat: ChatRoute?
    @State private var create: CreateKind?
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text(s.tabCommunities).font(.system(size: 30, weight: .bold)).foregroundStyle(theme.text)
                    Spacer()
                    Menu {
                        Button { create = CreateKind(id: "channel") } label: { Label(s.t("Новый канал", "New channel"), systemImage: "megaphone") }
                        Button { create = CreateKind(id: "group") } label: { Label(s.t("Новая группа", "New group"), systemImage: "person.3") }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.accentColor)
                            .frame(width: 42, height: 42).card(theme, radius: 21)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)
                CommunityDirectory(session: session, mine: chats.chats) { peer in openChat = ChatRoute(peer: peer) }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $openChat) { route in
                ChatScreen(route: route, session: session)
                    .environmentObject(session)
                    .environmentObject(flow)
            }
        }
        .task { await chats.refresh() }
        .sheet(item: $create) { kind in
            GroupCreateSheet(type: kind.id) { info in
                create = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openChat = ChatRoute(peer: ChatPeer(group: info)) }
            }
            .environmentObject(session).environmentObject(flow)
            .environment(\.theme, theme).environment(\.lang, lang)
            .presentationBackground(theme.sheet)
        }
    }
}

extension ChatPeer {
    /// Открыть канал / группу из каталога, не вступая — можно посмотреть, что там постят
    init(preview g: GroupPreview) {
        self.init(id: g.id, name: g.name, username: g.handle, avatarID: nil, isGroup: true, kind: g.kind,
                  memberCount: g.members, type: g.type, handle: g.handle)
    }
}

struct CreateKind: Identifiable {
    let id: String
}

// MARK: - Ссылка-приглашение (orbita://group/… или http://сервер/g/…)

struct GroupLinkSheet: View {
    let code: String

    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var preview: GroupPreview?
    @State private var failed = false
    @State private var busy = false
    @State private var errorText: String?
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 12) {
            if let preview {
                AvatarView(name: preview.name, size: 84).clipShape(Circle()).padding(.top, 28)
                Text(preview.name).font(.system(size: 22, weight: .bold)).foregroundStyle(theme.text)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                Text(subtitle(preview)).font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                if !preview.about.isEmpty {
                    Text(preview.about).font(.system(size: 15)).foregroundStyle(theme.text)
                        .multilineTextAlignment(.center).padding(.horizontal, 30)
                }
                if let errorText { Text(errorText).font(.system(size: 13)).foregroundStyle(theme.danger) }
                PrimaryButton(title: buttonTitle(preview), enabled: !preview.pending, loading: busy) { join() }
                    .padding(.horizontal, 24).padding(.top, 8)
                if preview.kind == "open" && !preview.joined {
                    Button {
                        ChannelViewSource.openedByLink.insert(preview.id)
                        PushManager.shared.openChat = ChatRoute(peer: ChatPeer(preview: preview))
                        dismiss()
                    } label: {
                        Text(s.t("Посмотреть, что внутри", "Take a look first"))
                            .font(.system(size: 16, weight: .medium)).foregroundStyle(theme.accentColor)
                            .frame(maxWidth: .infinity).frame(height: 44)
                    }
                    .buttonStyle(.plain)
                }
            } else if failed {
                Text(s.t("Приглашение недействительно", "This invite is no longer valid"))
                    .font(.system(size: 16)).foregroundStyle(theme.textSecondary).padding(.top, 60)
            } else {
                ProgressView().padding(.top, 60)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(detentHeight)])
        .animation(.easeOut(duration: 0.2), value: preview?.pending)
        .task {
            do { preview = try await session.messengerRepo.groupPreview(code: code) } catch { failed = true }
        }
    }

    /// Без описания окно ниже — «приземлённое»; с кнопкой «посмотреть» чуть выше
    private var detentHeight: CGFloat {
        guard let p = preview else { return 260 }
        var h: CGFloat = 330
        if !p.about.isEmpty { h += 60 }
        if p.kind == "open" && !p.joined { h += 50 }
        return h
    }

    private func subtitle(_ p: GroupPreview) -> String {
        let kind = p.isChannel ? (p.kind == "open" ? s.t("Публичный канал", "Public channel") : s.t("Закрытый канал", "Private channel"))
                               : (p.kind == "open" ? s.t("Открытая группа", "Open group") : s.t("Закрытая группа", "Private group"))
        return "\(kind) · \(p.members) \(s.memberWord(channel: p.isChannel))"
    }

    private func buttonTitle(_ p: GroupPreview) -> String {
        if p.joined { return s.t("Открыть чат", "Open chat") }
        if p.pending { return s.t("Заявка отправлена", "Request sent") }
        if p.approve { return s.t("Подать заявку", "Request to join") }
        return p.isChannel ? s.t("Подписаться", "Follow") : s.t("Вступить", "Join")
    }

    private func join() {
        busy = true
        errorText = nil
        Task {
            defer { busy = false }
            do {
                let info = try await session.messengerRepo.joinGroup(code: code)
                await session.chats.refresh()
                if info.pending {
                    preview?.pending = true
                    // заявка подана — окно уходит вниз само
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    dismiss()
                } else {
                    PushManager.shared.openChat = ChatRoute(peer: ChatPeer(group: info))
                    dismiss()
                }
            } catch { errorText = s.api((error as? APIError) ?? .offline) }
        }
    }
}


/// Строка найденного сообщения (общая для «Чатов» и «Сообществ»)
struct MessageHitRow: View {
    let hit: MessageHit
    let query: String
    let onOpen: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                AvatarView(name: hit.peer.name, size: 48, avatarID: hit.peer.avatarID).clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(hit.peer.name).font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.text).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(hit.date, format: .dateTime.day().month(.abbreviated))
                            .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    }
                    Text((hit.mine ? Strings(lang: lang).t("Вы: ", "You: ") : "") + snippet)
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary).lineLimit(2)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Обрезаем длинный текст вокруг найденного слова
    private var snippet: String {
        let q = query.trimmingCharacters(in: .whitespaces)
        let text = hit.text
        guard text.count > 90, let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return text }
        let start = text.index(r.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
        return (start == text.startIndex ? "" : "…") + String(text[start...].prefix(120))
    }
}
