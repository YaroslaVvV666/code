import SwiftUI
import Combine
import UIKit

// MARK: - Форматирование времени

enum ChatTime {
    static func clock(_ date: Date) -> String { FormatterCache.format(date, "HH:mm") }

    /// Для списка чатов: время / день недели / дата
    static func short(_ date: Date, lang: AppLanguage) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return clock(date) }
        let locale = Locale(identifier: lang == .ru ? "ru_RU" : "en_US")
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day, days < 7 {
            return FormatterCache.format(date, "EEE", locale: locale)
        }
        return FormatterCache.format(date, "dd.MM.yy", locale: locale)
    }

    static func day(_ date: Date, s: Strings, lang: AppLanguage) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return s.today }
        if cal.isDateInYesterday(date) { return s.yesterday }
        return FormatterCache.format(date, cal.isDate(date, equalTo: Date(), toGranularity: .year) ? "d MMMM" : "d MMMM yyyy",
                                     locale: Locale(identifier: lang == .ru ? "ru_RU" : "en_US"))
    }
}

struct Ticks: View {
    let read: Bool
    let color: Color

    var body: some View {
        HStack(spacing: -6) {
            Image(systemName: "checkmark")
            if read { Image(systemName: "checkmark") }
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(color)
    }
}

// MARK: - Список чатов

struct ChatsListView: View {
    @ObservedObject var model: ChatsModel
    let session: AppSession

    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var query = ""
    @State private var folder: ChatFolder = .all
    @ObservedObject private var prefs = ChatListPrefs.shared
    @ObservedObject private var net = NetworkState.shared
    @State private var openChat: ChatRoute?
    @ObservedObject private var push = PushManager.shared
    @State private var showNew = false
    @State private var showImport = false
    @State private var deleting: ChatSummary?
    @State private var peek: ChatSummary?
    @State private var swipedOpen: String?
    @State private var userHits: [ChatPeer] = []
    @State private var groupHits: [GroupPreview] = []
    @State private var messageHits: [MessageHit] = []
    @AppStorage("contacts.prompted") private var promptedImport = false

    private var s: Strings { Strings(lang: lang) }

    private var searchingNow: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var filtered: [ChatSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let base = model.chats.filter { folder.contains($0) }
        let found = q.isEmpty ? base : base.filter {
            $0.peer.name.lowercased().contains(q) || ($0.peer.username ?? "").lowercased().contains(q)
                || $0.lastText.lowercased().contains(q)
        }
        // закреплённые — сверху, остальные в прежнем порядке
        return found.filter { prefs.isPinned($0.id) }.sorted {
            (prefs.pinned.firstIndex(of: $0.id) ?? 0) < (prefs.pinned.firstIndex(of: $1.id) ?? 0)
        } + found.filter { !prefs.isPinned($0.id) }
    }

    var body: some View {
        NavigationStack {
            listContent
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $openChat) { route in
                    ChatScreen(route: route, session: session)
                        .environmentObject(session)
                        .environmentObject(flow)
                }
        }
        // Нижняя панель прячется в момент нажатия, а не когда переписка уже выехала: иначе область под сообщениями менялась
        // посреди открытия, список пересчитывался и на пару кадров пустел
        .onChange(of: openChat?.peer.id) { _, id in
            if let id { session.chats.chatOpen = true; session.chats.openPeerID = id }
        }
        .task { await model.refresh() }                   // дальше список обновляет общий опрос в MainTabView
        .onAppear { takePushRoute() }
        .onChange(of: push.openChat) { _, _ in takePushRoute() }
        .task(id: query) { await globalSearch() }
        .sheet(isPresented: $showNew) {
            NewChatSheet(session: session) { route in
                showNew = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openChat = route }
            }
            .environmentObject(session)
            .environmentObject(flow)
            .preferredColorScheme(theme.dark ? .dark : .light)
            .presentationBackground(theme.sheet)
            .presentationDetents([.height(250)])
        }
        .sheet(isPresented: $showImport) {
            ContactsImportSheet { peer in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openChat = ChatRoute(peer: peer) }
            }
            .environmentObject(session)
            .environmentObject(flow)
            .environment(\.theme, theme).environment(\.lang, lang)
            .presentationBackground(theme.sheet)
        }
        .overlay {
            if let chat = peek {
                ChatPeekOverlay(
                    chat: chat, repo: session.messengerRepo,
                    pinned: prefs.isPinned(chat.id), muted: isMuted(chat), markedUnread: prefs.isMarked(chat.id),
                    onOpen: { peek = nil; open(chat) },
                    onPin: { peek = nil; prefs.toggle(chat.id) },
                    onMute: { peek = nil; toggleMute(chat) },
                    onMark: { peek = nil; prefs.toggleMarked(chat.id) },
                    onDelete: { peek = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { deleting = chat } },
                    onClose: { peek = nil })
                .environment(\.theme, theme).environment(\.lang, lang)
                .transition(.opacity)
                .zIndex(50)
            }
        }
        .confirmationDialog(s.clearHistory, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button(s.clearHistory, role: .destructive) {
                if let chat = deleting { Task { await model.clear(chat.id) } }
            }
            Button(s.cancel, role: .cancel) {}
        } message: {
            Text(s.t("Все сообщения в этой переписке будут удалены. Это действие нельзя отменить.",
                     "All messages in this chat will be deleted. This can't be undone."))
        }
    }

    private func isMuted(_ chat: ChatSummary) -> Bool {
        _ = prefs.muteTick
        return chat.muted || (!chat.peer.isGroup && prefs.isDMMuted(chat.id))
    }

    private func toggleMute(_ chat: ChatSummary) {
        if chat.peer.isGroup {
            let repo = session.messengerRepo, id = chat.id, want = !chat.muted
            Task { try? await repo.setMuted(groupID: id, muted: want); await model.refresh() }
        } else {
            prefs.setDMMuted(chat.id, !prefs.isDMMuted(chat.id))
        }
    }

    private func open(_ chat: ChatSummary) {
        prefs.clearMarked(chat.id)
        openChat = ChatRoute(peer: chat.peer)
    }

    private var listContent: some View {
        VStack(spacing: 0) {
            HStack {
                if net.offline {
                    // нет связи: как в Telegram — «Соединение…» и крутится значок
                    HStack(spacing: 10) {
                        ProgressView().tint(theme.text)
                        Text(s.t("Соединение…", "Connecting…"))
                            .font(.system(size: 26, weight: .bold)).foregroundStyle(theme.text)
                    }
                    .transition(.opacity)
                } else {
                    Text(s.chatsTitle)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(theme.text)
                        .transition(.opacity)
                }
                Spacer()
                Button { showNew = true } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                        .frame(width: 44, height: 44)
                        .glassCircle()
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.textTertiary)
                TextField(s.chatsSearch, text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(theme.textTertiary) }
                }
            }
            .font(.system(size: 16))
            .padding(.horizontal, 14)
            .frame(height: 40)
            .card(theme, radius: 14)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ChatsTopIsland(session: session)

            FolderBar(folder: $folder)

            cards

            if model.chats.isEmpty && model.loaded && query.trimmingCharacters(in: .whitespaces).isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(theme.accentColor)
                        .frame(width: 84, height: 84)
                        .card(theme, radius: 42)
                    Text(s.chatsEmpty).font(.system(size: 20, weight: .semibold)).foregroundStyle(theme.text)
                    Text(s.chatsEmptyHint)
                        .font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.loaded {
                ChatListSkeleton()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if folder == .all && query.trimmingCharacters(in: .whitespaces).isEmpty { savedRow }
                        if searchingNow && !filtered.filter({ $0.id != session.serverID }).isEmpty {
                            sectionTitle(s.t("ЧАТЫ И КОНТАКТЫ", "CHATS AND CONTACTS"))
                        }
                        ForEach(filtered.filter { $0.id != session.serverID }) { chat in
                            row(chat)
                        }
                        globalResults
                        messageResults
                    }
                    .padding(.bottom, 90)
                }
                .scrollIndicators(.hidden)
            }
        }
        .overlay(alignment: .top) {
            if let error = model.error {
                ToastView(text: s.api(error)).padding(.top, 8)
                    .task(id: error) {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        model.error = nil
                    }
            }
        }
    }

    @ViewBuilder
    private var cards: some View {
        if !model.notices.isEmpty || !promptedImport {
            VStack(spacing: 8) {
                ForEach(model.notices) { notice in
                    JoinNoticeCard(notice: notice, onWrite: {
                        model.dismissNotice(notice)
                        openChat = ChatRoute(peer: ChatPeer(id: notice.userID, name: notice.name, username: notice.username,
                                                            avatarID: notice.avatarID))
                    }, onClose: { model.dismissNotice(notice) })
                }
                if !promptedImport {
                    ImportPromptCard(onOpen: { promptedImport = true; showImport = true }, onClose: { promptedImport = true })
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    // MARK: Поиск слов по всем перепискам

    @ViewBuilder
    private var messageResults: some View {
        if !messageHits.isEmpty {
            sectionTitle(s.t("СООБЩЕНИЯ", "MESSAGES"))
            ForEach(messageHits) { hit in
                MessageHitRow(hit: hit, query: query) { openChat = ChatRoute(peer: hit.peer) }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
    }

    // MARK: Поиск по Orbita (юзернейм, каналы)

    @ViewBuilder
    private var globalResults: some View {
        if !userHits.isEmpty || !groupHits.isEmpty {
            Text(s.t("АККАУНТЫ И КАНАЛЫ", "ACCOUNTS AND CHANNELS"))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
            ForEach(userHits, id: \.id) { peer in
                Button { openChat = ChatRoute(peer: peer) } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: peer.name, size: 48, avatarID: peer.avatarID).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                            if let u = peer.username { Text("@" + u).font(.system(size: 13)).foregroundStyle(theme.textSecondary) }
                        }
                        Spacer()
                        Image(systemName: "paperplane").foregroundStyle(theme.textTertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(groupHits) { g in
                Button { openChat = ChatRoute(peer: ChatPeer(preview: g)) } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: g.name, size: 48).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Image(systemName: g.isChannel ? "megaphone.fill" : "person.2.fill")
                                    .font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                                Text(g.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                            }
                            Text("\(g.members) \(s.memberWord(channel: g.isChannel))" + (g.handle.map { " · @" + $0 } ?? ""))
                                .font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func globalSearch() async {
        let raw = query.trimmingCharacters(in: .whitespaces)
        // текст сообщений во всех переписках
        if raw.count >= 2, !raw.hasPrefix("@") {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let hits = (try? await session.messengerRepo.searchMessages(query: raw)) ?? []
            if Task.isCancelled { return }
            messageHits = hits
        } else {
            messageHits = []
        }
        let name = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
        guard name.count >= (raw.hasPrefix("@") ? 2 : 3) else { userHits = []; groupHits = []; return }
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        async let groups = try? await session.messengerRepo.publicGroups(query: name, type: nil)
        var found: [ChatPeer] = []
        if name.range(of: "^[A-Za-z0-9_]{2,32}$", options: .regularExpression) != nil,
           let list = try? await session.profileRepo.searchUsers(prefix: name) {
            found = list.filter { $0.id.lowercased() != session.serverID }
                .map { ChatPeer(id: $0.id, name: $0.name, username: $0.username, avatarID: $0.avatarID) }
        }
        let g = await groups ?? []
        if Task.isCancelled { return }
        userHits = found
        groupHits = Array(g.filter { !$0.joined }.prefix(5))
    }

    /// Нажали на уведомление — открываем чат
    private func takePushRoute() {
        guard let route = push.openChat else { return }
        push.openChat = nil
        openChat = route
    }

    private var savedRow: some View {
        let last = model.chats.first { $0.id == session.serverID }
        return Button { openChat = ChatRoute(peer: ChatPeer(id: session.serverID, name: s.t("Избранное", "Saved messages"))) } label: {
            HStack(spacing: 12) {
                Image(systemName: "bookmark.fill").font(.system(size: 22)).foregroundStyle(.white)
                    .frame(width: 54, height: 54).background(theme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.t("Избранное", "Saved messages")).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
                    Text(last?.lastText ?? s.t("Заметки, файлы и ссылки для себя", "Notes, files and links for yourself"))
                        .font(.system(size: 15)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.stroke.opacity(0.7)).frame(height: 0.5).padding(.leading, 82) }
        }
        .buttonStyle(.plain)
    }

    private func row(_ chat: ChatSummary) -> some View {
        SwipeActionsRow(id: chat.id, openID: $swipedOpen, actions: [
            .init(icon: prefs.isPinned(chat.id) ? "pin.slash.fill" : "pin.fill", tint: .orange) {
                prefs.toggle(chat.id)
            },
            .init(icon: isMuted(chat) ? "bell.fill" : "bell.slash.fill", tint: .indigo) { toggleMute(chat) },
            .init(icon: "trash.fill", tint: .red) { deleting = chat },
        ]) { rowBody(chat) }
        .onAppear { ThreadPrefetcher.shared.visible(chat, repo: session.messengerRepo) }
    }

    /// Последнее сообщение в списке: миниатюра фото/видео и анимированный эмодзи вместо голого текста
    @ViewBuilder
    private func lastLine(_ chat: ChatSummary, _ s: Strings) -> some View {
        let color = chat.lastMine ? theme.textSecondary : (chat.unread > 0 ? theme.text : theme.textSecondary)
        let bare = chat.lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        let animated = AnimatedEmoji.all.first { $0 == bare || LottieEmojiStore.code($0, keepVariation: false) == LottieEmojiStore.code(bare, keepVariation: false) }
        HStack(alignment: .center, spacing: 5) {
            if let thumb = chat.lastThumb {
                RemoteImage(id: thumb.mediaID, maxPixel: 120)
                    .frame(width: 22, height: 22)
                    .clipShape(thumb.kind == "circle" ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 5, style: .continuous)))
                    .overlay {
                        if thumb.kind != "photo" {
                            Image(systemName: "play.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.5), radius: 2)
                        }
                    }
            }
            if let animated {
                LottieEmojiView(emoji: animated, size: 24, playing: false)      // в списке чатов не играет, стоит на последнем кадре
            } else {
                Text(chat.lastText).foregroundStyle(color)
            }
        }
    }

    private func rowBody(_ chat: ChatSummary) -> some View {
        ChatRowTouch(onTap: { open(chat) }, onLong: { Haptics.impact(.medium); withAnimation(.easeOut(duration: 0.18)) { peek = chat } }) {
            HStack(spacing: 12) {
                AvatarView(name: chat.peer.name, size: 54, avatarID: chat.peer.avatarID)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        if chat.peer.isChannel {
                            Image(systemName: "megaphone.fill").font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                        }
                        Text(chat.peer.name)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        if isMuted(chat) {
                            Image(systemName: "bell.slash.fill").font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                        }
                        if prefs.isPinned(chat.id) {
                            Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                        }
                        Spacer(minLength: 6)
                        if chat.lastMine { Ticks(read: chat.lastRead, color: theme.accentColor) }
                        Text(ChatTime.short(chat.updatedAt, lang: lang))
                            .font(.system(size: 13))
                            .foregroundStyle(chat.unread > 0 ? theme.accentColor : theme.textTertiary)
                    }
                    HStack(alignment: .top) {
                        Group {
                            if let action = chat.typing {
                                ActionLabel(action: action)
                            } else if let draft = ChatDraftStore.text(chat: chat.peer.id) {
                                Text(s.t("Черновик: ", "Draft: ")).foregroundStyle(theme.danger) + Text(draft).foregroundStyle(theme.textSecondary)
                            } else {
                                lastLine(chat, s)
                            }
                        }
                        .font(.system(size: 15))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        Spacer(minLength: 6)
                        if chat.mentions > 0 {
                            // вас «тегнули»: красная «собака» всегда, рядом число — красное, если чат не отключён
                            HStack(spacing: 6) {
                                Image(systemName: "at")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(Color(red: 0.90, green: 0.28, blue: 0.17))
                                if chat.unread > 0 {
                                    Text(chat.unread > 99 ? "99+" : "\(chat.unread)")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 7)
                                        .frame(minWidth: 22, minHeight: 22)
                                        .background(chat.muted ? AnyShapeStyle(theme.textTertiary) : AnyShapeStyle(Color(red: 0.90, green: 0.28, blue: 0.17)), in: Capsule())
                                }
                            }
                        } else if chat.unread == 0 && prefs.isMarked(chat.id) {
                            Circle().fill(theme.accent).frame(width: 14, height: 14)
                        } else if chat.unread > 0 {
                            Text(chat.unread > 99 ? "99+" : "\(chat.unread)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .frame(minWidth: 22, minHeight: 22)
                                .background(chat.muted ? AnyShapeStyle(theme.textTertiary) : AnyShapeStyle(theme.accent), in: Capsule())
                                .shadow(color: chat.muted ? .clear : theme.accentColor.opacity(0.35), radius: 5, y: 2)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.stroke.opacity(0.7)).frame(height: 0.5).padding(.leading, 82)
            }
        }
    }
}

// MARK: - Новый чат: поиск по нику

struct NewChatSheet: View {
    let session: AppSession
    let onPick: (ChatRoute) -> Void

    @EnvironmentObject private var flow: AuthFlow
    @State private var create: CreateKind?

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(s.t("Создать", "Create")).font(.system(size: 22, weight: .bold)).foregroundStyle(theme.text)
            Text(s.t("Найти человека можно в поиске на экране чатов — по имени пользователя.",
                     "To find someone, use the search on the chats screen — by username."))
                .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
            // кнопки группы и канала — отдельной строкой, стекло
            HStack(spacing: 12) {
                bigAction("person.3.fill", s.t("Новая группа", "New group")) { create = CreateKind(id: "group") }
                bigAction("megaphone.fill", s.t("Новый канал", "New channel")) { create = CreateKind(id: "channel") }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .sheet(item: $create) { kind in
            GroupCreateSheet(type: kind.id) { info in
                create = nil
                onPick(ChatRoute(peer: ChatPeer(group: info)))
            }
            .environmentObject(session).environmentObject(flow)
            .environment(\.theme, theme).environment(\.lang, lang)
            .presentationBackground(theme.sheet)
        }
    }

    private func bigAction(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 24))
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(theme.accentColor)
            .frame(maxWidth: .infinity).frame(height: 96)
            .glass(RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - Экран переписки

private struct UnreadYKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct BottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ForwardRoute: Identifiable {
    let id = UUID()
    let ids: [String]
}

struct ChatStoryRoute: Identifiable {
    let id = UUID()
    let group: StoryGroup
}

private struct ViewerItem: Identifiable {
    let id = UUID()
    var media: [MediaItem]
    let start: Int
    var meta: [MediaMeta] = []
    var hero: HeroSource.Snapshot?
}

struct ChatScreen: View {
    let route: ChatRoute
    let session: AppSession
    var standalone = false          // открыт поверх (не в навигации): свайп от края закрывает сам экран

    @StateObject private var model: ChatModel
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.scenePhase) private var scenePhase

    @State private var showInfo = false
    @State private var searching = false
    @State private var searchQuery = ""
    @State private var searchHits: [ChatMessage] = []      // от новых к старым
    @State private var searchPos = 0
    @State private var searchCurrent: String?
    @State private var showSearchList = false
    @FocusState private var searchFocused: Bool
    @State private var scheduled: [ScheduledItem] = []
    @State private var showScheduled = false
    @State private var showPlayer = false
    @State private var deleting: ChatMessage?
    @State private var viewer: ViewerItem?
    @State private var previewFile: PreviewFile?
    @State private var topVisible = false
    @State private var topKey: String?              // с какого сообщения построен список: при входе фиксируется и дальше не растёт сам
    @State private var userDragged = false          // пока не листали сами — длинная история не должна уводить экран от низа
    @State private var atBottom = true
    @State private var peekSearch = false
    @State private var lastBottomY: CGFloat = 0
    @State private var unreadIDs: Set<String> = []      // входящие, которые ещё не показывались на экране
    @State private var viewH: CGFloat = 800
    @State private var downloading = false
    /// Зажатое сообщение хранится в отдельном объекте: его смена перерисовывает только меню, а не весь экран чата со списком
    @State private var actionState = ActionTargetState()
    private var actionTarget: ChatMessage? {
        get { actionState.target }
        nonmutating set { actionState.target = newValue }
    }
    @State private var messageFrames = MessageFrameStore()
    @State private var showRequests = false
    @State private var scrollTarget: String?
    @State private var highlightID: String?
    @State private var pinIndex = 0
    @State private var forwardIDs: ForwardRoute?
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var infoMessage: ChatMessage?
    @State private var profileID: String?
    @State private var showPollCreate = false
    @State private var postLinkID: String?
    @State private var storyRoute: ChatStoryRoute?
    @State private var commentsRoute: CommentsRoute?
    @State private var storyNotice: String?
    @ObservedObject private var voicePlayer = VoicePlayer.shared
    @ObservedObject private var circleFocus = CircleFocus.shared

    init(route: ChatRoute, session: AppSession, standalone: Bool = false) {
        self.route = route
        self.session = session
        self.standalone = standalone
        _model = StateObject(wrappedValue: ChatModel(peer: route.peer, repo: session.messengerRepo))
    }

    private var s: Strings { Strings(lang: lang) }
    private var isSaved: Bool { model.peer.id == session.serverID }

    var body: some View {
        ZStack {
            SpaceBackground(isDark: theme.dark, showStars: false).ignoresSafeArea()
            messagesList
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 6) {
                        if searching { searchBar } else { header }
                        requestsBar
                        scheduledBar
                        pinnedBar
                        PeekSearchRow(visible: peekSearch && !searching) { startSearch() }
                        NowPlayingBar { showPlayer = true }
                        VoiceNowBar()
                    }
                    .padding(.bottom, 4)
                    // всё, что в шапке, выше сообщений: тапы мимо кнопок не проваливаются в ленту
                    .background { Color.clear.contentShape(Rectangle()).onTapGesture { } }
                    .zIndex(10)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Group {
                        if searching {
                            searchNavBar
                        } else if selecting {
                            selectionBar
                        } else {
                            ChatInputBar(model: model, onSent: { scrollToBottom(animated: false, delay: 0.05) },
                                         onPoll: { showPollCreate = true })
                        }
                    }
                    // за полем ввода — лёгкое затемнение и размытие, сообщения видны сквозь него, но нажать на них нельзя
                    .background(alignment: .bottom) {
                        ZStack {
                            Rectangle().fill(.ultraThinMaterial).opacity(0.7)
                            Color.black.opacity(theme.dark ? 0.18 : 0.04)
                        }
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.28),
                                                     .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
                        .contentShape(Rectangle())
                        .onTapGesture { }
                        .ignoresSafeArea(edges: .bottom)
                    }
                    .zIndex(10)
                }
            ActionTargetHost(state: actionState) { target in
                MessageActionOverlay(
                    message: target, model: model, noForward: model.peer.noForward || model.group?.noForward == true,
                    showSender: model.peer.isGroup && !model.peer.isChannel,
                    onClose: { actionTarget = nil },
                    onReply: { model.editing = nil; model.replyTo = target },
                    onEdit: { model.replyTo = nil; model.editing = target },
                    onConfirmDelete: { everyone in
                        // меню закрывается, сообщение рассыпается пылью, список сдвигается
                        actionTarget = nil
                        Task { try? await Task.sleep(nanoseconds: 120_000_000); await model.delete(target, forEveryone: everyone) }
                    },
                    isSaved: isSaved,
                    onForward: { forwardIDs = ForwardRoute(ids: [target.id]) },
                    onSelect: { selecting = true; selected = [target.id] },
                    onInfo: { infoMessage = target })
            }
            .zIndex(20)
        }
        .overlay {
            if let fx = model.reactionFX {
                ReactionEffectLayer(fx: fx, origin: { reactionOrigin(fx) }) { if model.reactionFX?.id == fx.id { model.reactionFX = nil } }
                    .id(fx.id)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .onPreferenceChange(MessageFrameKey.self) { messageFrames.frames = $0 }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .preferredColorScheme(theme.dark ? .dark : .light)
        .environmentObject(session.player)
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: session.player.current?.id)
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: voicePlayer.currentID)
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: circleFocus.current != nil)
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: model.pinned.count)
        .onChange(of: model.messages.count) { _, _ in session.player.syncQueue(model.musicItems.map(\.track)) }
        .onAppear {
            session.chats.chatOpen = true; session.chats.openPeerID = route.peer.id
            VoicePlayer.shared.onStart = { [weak music = session.player] in music?.stop() }
        }
        .onDisappear { session.chats.chatOpen = false; session.chats.openPeerID = nil }
        .task {
            // анимации ряда реакций разбираем заранее (вне главного потока), пока чат открыт и читается:
            // меню по зажатию оживает сразу, а не после разбора JSON в момент открытия
            #if canImport(Lottie)
            try? await Task.sleep(nanoseconds: 800_000_000)
            await LottieEmojiStore.shared.warm(AnimatedEmoji.all)
            #endif
        }
        .task(id: scenePhase) {
            // опрос только пока приложение на экране; в фоне — ни запросов, ни батареи
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .overlay(alignment: .top) {
            if let error = model.error {
                ToastView(text: s.api(error)).padding(.top, 60)
                    .task(id: error) {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        model.error = nil
                    }
            }
        }
        .swipeBackEnabled(fullScreen: false)
        .edgeSwipeBack(enabled: true, fullWidth: true, skipEdge: !standalone) { dismiss() }
        .fullScreenCover(isPresented: $showInfo) {
            ChatInfoView(model: model, onPlayMusic: { track, queue in
                session.player.start(track, queue: queue)
                showPlayer = true
            }, onLeftGroup: {
                showInfo = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
            })
            .environmentObject(session)
            .environmentObject(flow)
            .environmentObject(session.player)
        }
        .sheet(isPresented: $showRequests) {
            GroupRequestsSheet(groupID: route.peer.id) { await model.refresh() }
                .environmentObject(session).environmentObject(flow)
                .environment(\.theme, theme).environment(\.lang, lang)
        }
        .sheet(isPresented: $showPlayer) {
            FullPlayerSheet(items: model.musicItems, addToProfile: { item in await addToProfile(item) })
                .environmentObject(session.player)
                .environment(\.theme, theme)
                .presentationDragIndicator(.hidden)
        }
        .overlay {
            if let item = viewer {
                HeroViewerHost(media: item.media, start: item.start, meta: item.meta, hero: item.hero) { viewer = nil }
                    .id(item.id)
                    .ignoresSafeArea()
                    .ignoresSafeArea(.keyboard)
                    .zIndex(10)
            }
        }
        .sheet(item: $previewFile) { file in
            FileViewerSheet(url: file.url).environment(\.theme, theme).environment(\.lang, lang)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, !model.peer.isGroup, !isSaved else { return }
            while !Task.isCancelled {
                let list = await session.extras.scheduled(peerID: model.peer.id)
                if list != scheduled { withAnimation { scheduled = list } }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .sheet(isPresented: $showScheduled) {
            ScheduledListSheet(peerID: model.peer.id, items: scheduled) {
                Task { scheduled = await session.extras.scheduled(peerID: model.peer.id) }
            }
            .environmentObject(session)
            .environment(\.theme, theme).environment(\.lang, lang)
            .presentationBackground(theme.sheet)
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $forwardIDs) { route in
            SendToChatSheet(messageIDs: route.ids)
                .environmentObject(session)
                .environment(\.theme, theme).environment(\.lang, lang)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
                .onDisappear { selecting = false; selected = [] }
        }
        .sheet(item: $infoMessage) { m in
            MessageInfoSheet(message: m, group: model.peer.isGroup)
                .environmentObject(session)
                .environment(\.theme, theme).environment(\.lang, lang)
                .presentationDetents([.medium, .large])
                .presentationBackground(theme.sheet)
        }
        .sheet(isPresented: $showPollCreate) {
            PollCreateSheet(peerID: model.peer.id) { Task { await model.refresh(); scrollToBottom(animated: true, delay: 0.1) } }
                .environmentObject(session)
                .environment(\.theme, theme).environment(\.lang, lang)
                .presentationBackground(theme.sheet)
        }
        .profileSheet(id: $profileID)
        .sheet(item: $commentsRoute) { r in
            ChannelCommentsSheet(route: r)
                .environmentObject(session)
                .environment(\.theme, theme).environment(\.lang, lang)
                .presentationBackground(theme.sheet)
        }
        .fullScreenCover(item: $storyRoute) { r in
            StoryViewerScreen(groups: [r.group], startGroup: 0, startIndex: 0)
                .environmentObject(session)
                .environment(\.theme, theme).environment(\.lang, lang)
        }
        .overlay(alignment: .top) {
            if let storyNotice { ToastView(text: storyNotice).padding(.top, 60).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.2), value: storyNotice)
        .fullScreenCover(item: Binding(get: { postLinkID.map { AuthorRoute(id: $0) } }, set: { postLinkID = $0?.id })) { route in
            PostLinkSheet(postID: route.id)
                .environmentObject(session).environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
        .sheet(isPresented: $showSearchList) {
            SearchResultsSheet(hits: searchHits, query: searchQuery, current: searchCurrent, peer: model.peer,
                               myName: session.profile.profile?.name ?? "", myAvatar: session.profile.profile?.avatarID) { i in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { goToHit(i) }
            }
            .environment(\.theme, theme).environment(\.lang, lang)
            .presentationBackground(theme.sheet)
            .presentationDetents([.medium, .large])
        }
        .onChange(of: searchQuery) { _, _ in searchCurrent = nil; recomputeSearch() }
        .onChange(of: model.messages.count) { _, _ in if searching { recomputeSearch() } }
        .confirmationDialog(s.deleteMessage, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { message in
            Button(s.deleteForMe, role: .destructive) { Task { await model.delete(message, forEveryone: false) } }
            if message.mine || model.group?.isAdmin == true {
                Button(s.deleteForAll, role: .destructive) { Task { await model.delete(message, forEveryone: true) } }
            }
            Button(s.cancel, role: .cancel) {}
        }
    }

    // MARK: Поиск по чату (строка сверху, счётчик и стрелки снизу — как в Telegram)

    private func startSearch() {
        Haptics.impact(.light)
        model.historyLimit = 300
        Task { await model.refresh() }
        withAnimation(.easeOut(duration: 0.2)) { searching = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { searchFocused = true }
    }

    private func endSearch() {
        searchFocused = false
        withAnimation(.easeOut(duration: 0.2)) { searching = false }
        searchQuery = ""
        searchHits = []
        searchCurrent = nil
        searchPos = 0
        model.historyLimit = 100
    }

    private func recomputeSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { searchHits = []; searchPos = 0; searchCurrent = nil; return }
        let hits = model.messages.filter { !$0.text.hasPrefix("\u{200B}call:") && $0.summary.lowercased().contains(q) }
            .sorted { $0.createdAt > $1.createdAt }
        searchHits = hits
        if let keep = searchCurrent, let i = hits.firstIndex(where: { $0.id == keep }) {
            searchPos = i
        } else if !hits.isEmpty {
            goToHit(0)
        } else {
            searchPos = 0; searchCurrent = nil
        }
    }

    private func goToHit(_ i: Int) {
        guard searchHits.indices.contains(i) else { return }
        searchPos = i
        searchCurrent = searchHits[i].id
        scrollTarget = searchHits[i].id
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.textTertiary)
                TextField(s.t("Поиск по переписке", "Search messages"), text: $searchQuery)
                    .focused($searchFocused).submitLabel(.search)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { if searchPos + 1 < searchHits.count { goToHit(searchPos + 1) } }
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).frame(height: 44)
            .glassCapsule()
            Button(s.t("Отмена", "Cancel")) { endSearch() }
                .foregroundStyle(theme.accentColor)
        }
        .padding(.horizontal, 12)
        .transition(.opacity)
    }

    private var searchNavBar: some View {
        let q = !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 10) {
            Button { searchFocused = false; showSearchList = true } label: {
                Image(systemName: "list.bullet").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                    .frame(width: 44, height: 44).glassCircle(interactive: true)
            }
            .buttonStyle(.plain).disabled(searchHits.isEmpty).opacity(searchHits.isEmpty ? 0.4 : 1)
            Spacer()
            Text(!q ? s.t("Введите слово для поиска", "Type to search")
                 : searchHits.isEmpty ? s.t("Ничего не найдено", "Nothing found")
                 : s.t("\(searchPos + 1) из \(searchHits.count)", "\(searchPos + 1) of \(searchHits.count)"))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
                .contentTransition(.numericText())
            Spacer()
            // вверх — к более старым совпадениям, вниз — к более новым
            Button { goToHit(searchPos + 1) } label: {
                Image(systemName: "chevron.up").font(.system(size: 16, weight: .bold)).foregroundStyle(theme.text)
                    .frame(width: 44, height: 44).glassCircle(interactive: true)
            }
            .buttonStyle(.plain).disabled(searchPos + 1 >= searchHits.count).opacity(searchPos + 1 >= searchHits.count ? 0.4 : 1)
            Button { goToHit(searchPos - 1) } label: {
                Image(systemName: "chevron.down").font(.system(size: 16, weight: .bold)).foregroundStyle(theme.text)
                    .frame(width: 44, height: 44).glassCircle(interactive: true)
            }
            .buttonStyle(.plain).disabled(searchPos <= 0).opacity(searchPos <= 0 ? 0.4 : 1)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .animation(.easeOut(duration: 0.15), value: searchPos)
    }

    // MARK: Шапка

    private var header: some View {
        ZStack {
            // ник и статус — строго по центру экрана, независимо от кнопок по краям
            Button { if !isSaved { showInfo = true } } label: {
                VStack(spacing: 1) {
                    Text(isSaved ? s.t("Избранное", "Saved messages") : model.peer.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Group {
                        if isSaved {
                            Text(s.t("Ваши заметки", "Your notes")).foregroundStyle(theme.textSecondary)
                        } else if let action = model.typing {
                            ActionLabel(action: action)
                        } else if model.peer.isGroup {
                            Text("\(model.group?.count ?? model.peer.memberCount) \(s.memberWord(channel: model.peer.isChannel))")
                                .foregroundStyle(theme.textSecondary)
                        } else {
                            // «в сети» или «был(а) …» — как разрешил человек в приватности
                            Text(s.lastSeenText(model.lastSeen)).foregroundStyle(theme.textSecondary)
                        }
                    }
                    .font(.system(size: 12))
                    .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .frame(minWidth: 156)                           // пузырь сразу такой, чтобы «был(а) 59 минут назад» помещалось
                .glassCapsule(interactive: true)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 116)                      // место под кнопки слева и справа поровну

            HStack(spacing: 8) {
                Button { dismiss() } label: {
                    BackWithUnread(model: session.chats, excluding: route.peer.id)
                }
                .buttonStyle(.plain)
                .zIndex(5)

                Spacer(minLength: 0)

                Button { startSearch() } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                        .frame(width: 44, height: 44).glassCircle()
                        .padding(.horizontal, 4).padding(.vertical, 12)      // зона нажатия шире кнопки (≈52×68)
                        .contentShape(Rectangle())
                        .padding(.horizontal, -4).padding(.vertical, -12)
                }
                .buttonStyle(.plain)

                Button { if !isSaved { showInfo = true } } label: {
                    if isSaved {
                        Image(systemName: "bookmark.fill").font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(theme.accentColor).frame(width: 44, height: 44).glassCircle()
                    } else {
                        AvatarView(name: model.peer.name, size: 44, avatarID: model.peer.avatarID)
                            .clipShape(Circle())
                            .glassCircle()
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
    }

    // MARK: Запланированные сообщения

    @ViewBuilder
    private var scheduledBar: some View {
        if !scheduled.isEmpty {
            Button { showScheduled = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "clock.fill").foregroundStyle(theme.accentColor)
                    Text(s.t("Запланировано: \(scheduled.count)", "Scheduled: \(scheduled.count)"))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, 16).frame(height: 36)
                .glassCapsule(interactive: true)
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Заявки (для администраторов) — под названием, как в Telegram

    @ViewBuilder
    private var requestsBar: some View {
        if let g = model.group, g.isAdmin, g.requests > 0 {
            Button { showRequests = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.clock").foregroundStyle(theme.accentColor)
                    Text(s.t("\(g.requests) заявок на вступление", "\(g.requests) join requests"))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, 16).frame(height: 36)
                .glassCapsule(interactive: true)
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Закреплённые

    @ViewBuilder
    private var pinnedBar: some View {
        if !model.pinned.isEmpty {
            let index = min(pinIndex, model.pinned.count - 1)
            let m = model.pinned[index]
            Button {
                scrollTarget = m.id
                if model.pinned.count > 1 { pinIndex = (index + 1) % model.pinned.count }
                Haptics.impact(.light)
            } label: {
                HStack(spacing: 10) {
                    Capsule().fill(theme.accentColor).frame(width: 3, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.pinned.count > 1
                             ? s.t("Закреплённое сообщение \(index + 1)/\(model.pinned.count)", "Pinned message \(index + 1)/\(model.pinned.count)")
                             : s.t("Закреплённое сообщение", "Pinned message"))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accentColor)
                        Text(m.summary.isEmpty ? "…" : m.summary)
                            .font(.system(size: 14)).foregroundStyle(theme.text).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "pin.fill").font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, 14).frame(height: 46)
                .glass(RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true)
                .padding(.horizontal, 10)
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Сообщения

    private struct Entry: Identifiable {
        let message: ChatMessage
        let isFirst: Bool
        let isLast: Bool
        let dayTitle: Date?
        var id: String { message.key }
    }

    private func entries(_ items: [ChatMessage]) -> [Entry] {
        let cal = Calendar.current
        func joins(_ a: ChatMessage, _ b: ChatMessage) -> Bool {
            a.mine == b.mine && a.sender?.id == b.sender?.id && a.system == nil && b.system == nil
                && cal.isDate(a.createdAt, inSameDayAs: b.createdAt)
                && abs(b.createdAt.timeIntervalSince(a.createdAt)) < 300
        }
        return items.enumerated().map { i, m in
            let prev = i > 0 ? items[i - 1] : nil
            let next = i + 1 < items.count ? items[i + 1] : nil
            let newDay = prev == nil || !cal.isDate(prev!.createdAt, inSameDayAs: m.createdAt)
            return Entry(message: m,
                         isFirst: prev == nil || !joins(prev!, m),
                         isLast: next == nil || !joins(m, next!),
                         dayTitle: newDay ? m.createdAt : nil)
        }
    }

    /// Непрочитанные входящие, где тегнули меня (@мой_ник). Удалённые сюда не попадают — их уже нет в items
    private var tagItems: [ChatMessage] {
        guard !unreadIDs.isEmpty, let me = session.profile.profile?.username?.lowercased(), !me.isEmpty else { return [] }
        let needle = "@" + me
        return model.items.filter { m in
            guard !m.mine, m.system == nil, unreadIDs.contains(m.id) else { return false }
            let t = m.text.lowercased()
            var from = t.startIndex
            while let r = t.range(of: needle, range: from..<t.endIndex) {
                let before = r.lowerBound == t.startIndex ? nil : t[t.index(before: r.lowerBound)]
                let after = r.upperBound == t.endIndex ? nil : t[r.upperBound]
                let okBefore = before.map { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "@") } ?? true
                let okAfter = after.map { !($0.isLetter || $0.isNumber || $0 == "_") } ?? true
                if okBefore && okAfter { return true }
                from = r.upperBound
            }
            return false
        }
    }

    private func tagButton(_ tags: [ChatMessage]) -> some View {
        Button {
            Haptics.impact(.light)
            if let first = tags.first { scrollTarget = first.id }
        } label: {
            Image(systemName: "at")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(red: 0.17, green: 0.55, blue: 0.95))
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(theme.stroke, lineWidth: 1))
                .overlay(alignment: .top) {
                    Text(tags.count > 99 ? "99+" : "\(tags.count)")
                        .font(.system(size: 12, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                        .background(Color(red: 0.17, green: 0.55, blue: 0.95), in: Capsule())
                        .offset(y: -12)
                }
        }
        .buttonStyle(PressStyle())
        .transition(.scale.combined(with: .opacity))
    }

    private var messagesList: some View {
        let all = entries(model.items)
        // Строим только хвост переписки: тысяча сообщений разом (с картинками и эмодзи) и давала лаг при входе в чат;
        // ранние подгружаются, когда долистал до верха
        let startIdx: Int = {
            if let k = topKey, let i = all.firstIndex(where: { $0.id == k }) { return i }
            return max(0, all.count - 40)
        }()
        let list = startIdx > 0 ? Array(all[startIdx...]) : all
        return ScrollViewReader { proxy in
            ScrollView {
                // Не Lazy: сотня сообщений — это дёшево, зато нет скачков и пустых экранов при отправке
                VStack(spacing: 0) {
                    if startIdx > 0, let firstKey = list.first?.id {
                        // Ранние сообщения добавляются сами, когда долистал до верха; при входе список не растёт —
                        // иначе большой чат строил десятки строк разом, пустел и перескакивал
                        Color.clear.frame(height: 1)
                            .onAppear { topVisible = true }
                            .onDisappear { topVisible = false }
                            .onChange(of: topVisible && userDragged) { _, go in
                                guard go else { return }
                                topKey = all[max(0, startIdx - 40)].id
                                DispatchQueue.main.async { proxy.scrollTo(firstKey, anchor: .top) }
                            }
                    }
                    if list.isEmpty && model.loaded {
                        Text(s.chatStart)
                            .font(.system(size: 15)).foregroundStyle(theme.textTertiary)
                            .padding(.top, 60)
                    }
                    ForEach(list) { entry in
                        if entry.message.id == model.firstUnreadID {
                            newMessagesStrip.id("unreadStrip")
                        }
                        if let day = entry.dayTitle {
                            Text(ChatTime.day(day, s: s, lang: lang))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(.top, 10).padding(.bottom, 6)
                        }
                        row(entry)
                            .background {
                                if unreadIDs.contains(entry.message.id) {
                                    GeometryReader { g in
                                        Color.clear.preference(key: UnreadYKey.self,
                                                               value: [entry.message.id: g.frame(in: .named("chatScroll")).minY])
                                    }
                                }
                            }
                            .padding(.top, entry.isFirst ? 7 : 2)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.88, anchor: entry.message.mine ? .bottomTrailing : .bottomLeading)
                                    .combined(with: .move(edge: .bottom)).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.9))))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .background(GeometryReader { g in
                            Color.clear.preference(key: BottomKey.self, value: g.frame(in: .named("chatScroll")).maxY)
                        })
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .animation(.spring(response: 0.38, dampingFraction: 0.86), value: list.map(\.id))
            }
            .coordinateSpace(name: "chatScroll")
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { viewH = g.size.height }
                    .onChange(of: g.size.height) { old, new in
                        viewH = new
                        if atBottom { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
                    }
            })
            .onPreferenceChange(UnreadYKey.self) { ys in
                // сообщение прочитано, когда его верх вошёл в видимую область
                let seen = ys.filter { $0.value < viewH - 16 }.keys
                if !seen.isEmpty { unreadIDs.subtract(seen) }
            }
            .onPreferenceChange(BottomKey.self) { y in
                let near = y < viewH + 140
                if near != atBottom { atBottom = near }
                // листаем вверх (низ контента уезжает вниз) — показываем строку поиска, вниз — прячем
                let dy = y - lastBottomY
                if abs(dy) > 14 {
                    let up = dy > 0 && !near
                    if up != peekSearch { withAnimation(.easeOut(duration: 0.2)) { peekSearch = up } }
                    lastBottomY = y
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in userDragged = true })
            .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { if $0.translation.height > 50 { hideKeyboard() } })
            .defaultScrollAnchor(.bottom)
            .onAppear {
                if model.loaded {
                    if topKey == nil, let first = list.first { topKey = first.id }       // предзагруженные сообщения: список на этом и стоит
                    seedUnread()
                    // чат открылся с предзагруженными сообщениями — к плашке «Новые сообщения», как и при обычной загрузке
                    if model.firstUnreadID != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { proxy.scrollTo("unreadStrip", anchor: .top) }
                    }
                }
            }
            .onChange(of: model.items.count) { old, new in
                // пришла более длинная история (предзагруженные 10 → 100): остаёмся внизу, а не у начала переписки
                if new > old, !userDragged {
                    let id = model.firstUnreadID != nil && unreadIDs.isEmpty == false ? "unreadStrip" : "bottom"
                    let anchor: UnitPoint = id == "bottom" ? .bottom : .top
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: anchor) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { if !userDragged { proxy.scrollTo(id, anchor: anchor) } }
                }
            }
            .onChange(of: model.items.last?.key) { _, _ in
                if let last = model.items.last, !last.mine, last.system == nil, !last.isPending { unreadIDs.insert(last.id) }
                if atBottom || model.items.last?.mine == true {
                    DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onChange(of: model.loaded) { _, ok in
                // как в Telegram: открываем чат на первом непрочитанном, а не в самом низу
                if topKey == nil, !all.isEmpty { topKey = all[max(0, all.count - 40)].id }
                if let uid = model.firstUnreadID, let i = all.firstIndex(where: { $0.message.id == uid }), i < startIdx {
                    topKey = all[max(0, i - 5)].id          // первое непрочитанное должно быть в построенной части
                }
                seedUnread()
                guard ok, model.firstUnreadID != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    proxy.scrollTo("unreadStrip", anchor: .top)
                }
            }
            .onReceive(scrollRequests) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: scrollTarget) { _, id in
                guard let id else { return }
                if let i = all.firstIndex(where: { $0.message.id == id }), i < startIdx {
                    topKey = all[max(0, i - 5)].id          // найденное сообщение лежит выше построенной части
                }
                if let key = all.first(where: { $0.message.id == id })?.id {
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(key, anchor: .center) }
                    // сообщение на секунду подсвечивается
                    withAnimation(.easeInOut(duration: 0.25)) { highlightID = id }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_300_000_000)
                        withAnimation(.easeInOut(duration: 0.5)) { if highlightID == id { highlightID = nil } }
                    }
                }
                scrollTarget = nil
            }
            .overlay(alignment: .bottomTrailing) {
                let tags = tagItems
                VStack(spacing: 0) {
                if !tags.isEmpty {
                    tagButton(tags).padding(.horizontal, 12).padding(.top, 18).padding(.bottom, atBottom ? 12 : 4)
                }
                if !atBottom {
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(theme.stroke, lineWidth: 1))
                            .overlay(alignment: .top) {
                                if !unreadIDs.isEmpty {
                                    Text(unreadIDs.count > 999 ? "999+" : "\(unreadIDs.count)")
                                        .font(.system(size: 12, weight: .bold)).monospacedDigit()
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                                        .background(theme.accentColor, in: Capsule())
                                        .offset(y: -12)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                    }
                    .buttonStyle(PressStyle())
                    .padding(12)
                    .transition(.scale.combined(with: .opacity))
                }
                }
            }
            .animation(.easeOut(duration: 0.2), value: atBottom)
        }
    }

    /// Какие входящие ещё не прочитаны: всё от первого непрочитанного и ниже
    private func seedUnread() {
        guard let first = model.firstUnreadID, let i = model.items.firstIndex(where: { $0.id == first }) else { return }
        unreadIDs = Set(model.items[i...].filter { !$0.mine && $0.system == nil }.map(\.id))
    }

    /// Лоскуток «Новые сообщения» над первым непрочитанным
    private var newMessagesStrip: some View {
        Text(s.t("Новые сообщения", "New messages"))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(theme.accentColor.opacity(0.14))
            .padding(.horizontal, -10)                  // на всю ширину экрана, как у Telegram
            .padding(.top, 10).padding(.bottom, 4)
    }

    // Запрос «прокрути вниз» из строки ввода
    private let scrollRequests = NotificationCenter.default.publisher(for: ChatScreen.scrollNote)
    private static let scrollNote = Notification.Name("orbita.chat.scrollBottom")

    private func scrollToBottom(animated: Bool, delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NotificationCenter.default.post(name: ChatScreen.scrollNote, object: nil)
        }
    }

    private func row(_ entry: Entry) -> some View {
        let m = entry.message
        let groupChat = model.peer.isGroup && !model.peer.isChannel
        return HStack(alignment: .bottom, spacing: 6) {
            if selecting && m.system == nil {
                Image(systemName: selected.contains(m.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected.contains(m.id) ? theme.accentColor : theme.textTertiary)
                    .transition(.scale.combined(with: .opacity))
            }
            if groupChat && !m.mine && m.system == nil {
                if entry.isLast, let sender = m.sender {
                    Button { profileID = sender.id } label: {
                        AvatarView(name: sender.name, size: 32, avatarID: sender.avatarID).clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 32, height: 32)
                }
            }
            MessageRow(
                message: m, isFirst: entry.isFirst, isLast: entry.isLast,
                onReply: { model.editing = nil; model.replyTo = m },
                onEdit: { model.replyTo = nil; model.editing = m },
                onDelete: { deleting = m },
                onOpenMedia: { items, index in openGallery(tapped: items, index: index) },
                onOpenFile: openFile,
                onPlayAudio: playAudio,
                showSender: groupChat,
                noForward: model.peer.noForward || model.group?.noForward == true,
                onReactionInfo: { infoMessage = m },
                onJumpToReply: { scrollTarget = $0 },
                onReact: { model.react(m, emoji: $0) },
                onLongPress: { if !selecting { actionTarget = m } },
                onOpenProfile: { id in if id.lowercased() != session.serverID { profileID = id } },
                onOpenPost: { openSharedPost($0) },
                onOpenStory: openStory,
                onOpenComments: model.peer.isChannel ? { commentsRoute = CommentsRoute(channelID: model.peer.id, post: m) } : nil,
                onCallBack: (model.peer.isGroup || isSaved) ? nil : { video in session.calls.start(peer: model.peer, video: video) })
            .allowsHitTesting(!selecting && !model.dissolving.contains(m.id))
            .dustDissolve(active: model.dissolving.contains(m.id), color: m.mine ? theme.accentColor : Color.white.opacity(0.85))
            .background(GeometryReader { g in
                Color.clear.preference(key: MessageFrameKey.self, value: [m.id: g.frame(in: .global)])
            })
        }
        .overlay {
            if selecting && m.system == nil {
                Color.clear.contentShape(Rectangle()).onTapGesture {
                    if selected.contains(m.id) { selected.remove(m.id) } else { selected.insert(m.id) }
                    Haptics.select()
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: selecting)
        .background {
            if highlightID == m.id || (searching && searchCurrent == m.id) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.accentColor.opacity(0.28))
                    .padding(.horizontal, -10).padding(.vertical, -3)
                    .transition(.opacity)
            }
        }
    }

    private var selectionBar: some View {
        let noForward = model.peer.noForward || model.group?.noForward == true
        return HStack(spacing: 10) {
            Button { selecting = false; selected = [] } label: {
                Text(s.cancel).font(.system(size: 16, weight: .medium)).foregroundStyle(theme.text)
                    .padding(.horizontal, 18).frame(height: 46).glassCapsule(interactive: true)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Text("\(selected.count)").font(.system(size: 16, weight: .semibold).monospacedDigit()).foregroundStyle(theme.textSecondary)
            Button {
                let ids = model.items.filter { selected.contains($0.id) }.map(\.id)
                if !ids.isEmpty { forwardIDs = ForwardRoute(ids: ids) }
            } label: {
                Label(s.t("Переслать", "Forward"), systemImage: "arrowshape.turn.up.right")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(height: 46).background(theme.accent, in: Capsule())
            }
            .buttonStyle(PressStyle())
            .disabled(selected.isEmpty || noForward)
            .opacity(selected.isEmpty || noForward ? 0.5 : 1)
            Button {
                if let first = model.items.first(where: { selected.contains($0.id) }), selected.count == 1 {
                    deleting = first
                } else {
                    let list = model.items.filter { selected.contains($0.id) }
                    Task {
                        model.dissolving.formUnion(list.map(\.id))           // все рассыпаются одновременно
                        Haptics.impact(.soft)
                        try? await Task.sleep(nanoseconds: 950_000_000)
                        for m in list { await model.delete(m, forEveryone: false, animated: false) }
                        selecting = false; selected = []
                    }
                }
            } label: {
                Image(systemName: "trash").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.danger)
                    .frame(width: 46, height: 46).glassCircle()
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    /// Где на экране сообщение, к которому поставили реакцию: эффект вылетает рядом с её значком (у нижнего края пузыря)
    private func reactionOrigin(_ fx: ReactionFX) -> CGPoint? {
        // сам значок реакции, если он уже нарисован; иначе нижний край сообщения
        if let chip = messageFrames.frames[fx.messageID + "|" + fx.emoji] {
            return CGPoint(x: chip.midX, y: chip.midY)
        }
        guard let f = messageFrames.frames[fx.messageID],
              let m = model.messages.first(where: { $0.id == fx.messageID }) else { return nil }
        return CGPoint(x: m.mine ? f.maxX - 70 : f.minX + 70, y: f.maxY - 6)
    }

    private func playAudio(_ a: ChatAttachment) {
        guard let track = a.track else { return }
        let queue = model.musicItems.map(\.track)
        session.player.toggle(track, queue: queue.isEmpty ? [track] : queue)
    }

    private func addToProfile(_ item: ChatMusicItem) async -> Bool {
        do {
            _ = try await session.messengerRepo.addToProfile(messageID: item.messageID, mediaID: item.attachment.mediaID ?? "",
                                                             title: item.track.title, artist: item.track.artist)
            await session.profile.load()
            return true
        } catch {
            model.error = (error as? APIError) ?? .offline
            return false
        }
    }

    /// «сегодня в 20:49», «вчера в 20:49», «12 окт. в 20:49»
    private func viewerStamp(_ date: Date) -> String {
        let cal = Calendar.current
        let time = FormatterCache.format(date, "HH:mm", locale: Locale(identifier: lang == .ru ? "ru_RU" : "en_US"))
        if cal.isDateInToday(date) { return s.t("сегодня в ", "today at ") + time }
        if cal.isDateInYesterday(date) { return s.t("вчера в ", "yesterday at ") + time }
        let day = FormatterCache.format(date, "d MMM", locale: Locale(identifier: lang == .ru ? "ru_RU" : "en_US"))
        return day + s.t(" в ", " at ") + time
    }

    /// Все фото и видео из списка сообщений — в порядке переписки, с подписями
    private func gallery(from messages: [ChatMessage]) -> (media: [MediaItem], meta: [MediaMeta]) {
        var all: [MediaItem] = []
        var meta: [MediaMeta] = []
        for m in messages where !m.isPending {
            let who = m.mine ? s.t("Вы", "You") : (m.sender?.name ?? model.peer.name)
            let text = m.text.hasPrefix("\u{200B}call:") ? "" : m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            for item in m.attachments.compactMap(\.mediaItem) {
                all.append(item)
                meta.append(MediaMeta(title: who, subtitle: viewerStamp(m.createdAt), text: text))
            }
        }
        return (all, meta)
    }

    /// Просмотр всех фото и видео переписки: листаем между сообщениями. Сначала открывается то, что загружено,
    /// а затем подтягивается вся история — и фото, и видео, в том числе старые
    private func openGallery(tapped: [MediaItem], index: Int) {
        let (all, meta) = gallery(from: model.messages)
        guard tapped.indices.contains(index), let at = all.firstIndex(where: { $0.id == tapped[index].id }) else {
            let owner = model.messages.first { msg in msg.attachments.contains { $0.mediaItem?.id == tapped[index].id } }
            let who = (owner?.mine ?? false) ? s.t("Вы", "You") : (owner?.sender?.name ?? model.peer.name)
            let cap = (owner?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let single = owner.map { [MediaMeta(title: who, subtitle: viewerStamp($0.createdAt), text: cap.hasPrefix("\u{200B}call:") ? "" : cap)] } ?? []
            hideKeyboard()
            viewer = ViewerItem(media: [tapped[index]], start: 0, meta: single, hero: HeroSource.shared.take())
            return
        }
        hideKeyboard()
        let item = ViewerItem(media: all, start: at, meta: meta, hero: HeroSource.shared.take())
        viewer = item
        Task {
            let history = await model.loadFullHistory()
            let full = gallery(from: history)
            guard full.media.count > all.count, viewer?.id == item.id else { return }
            viewer?.media = full.media
            viewer?.meta = full.meta
        }
    }

    /// Присланный шортс открывается во вкладке «Шортс» (как в TikTok), остальные посты — карточкой
    private func openSharedPost(_ id: String) {
        Task {
            guard let post = try? await session.feedRepo.post(id: id) else { postLinkID = id; return }
            if post.media.first?.kind == .video {
                session.reelRequest = post
                if standalone { dismiss() }
            } else {
                postLinkID = id
            }
        }
    }

    private func openStory(_ id: String) {
        Task {
            if let group = await session.extras.story(id: id) {
                storyRoute = ChatStoryRoute(group: group)
            } else {
                storyNotice = s.t("История уже недоступна", "This story is no longer available")
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                storyNotice = nil
            }
        }
    }

    private func openFile(_ a: ChatAttachment) {
        guard let id = a.mediaID, !downloading else { return }
        downloading = true
        Task {
            defer { downloading = false }
            if let url = await FileDownloader.download(mediaID: id, name: a.name ?? "file") {
                previewFile = PreviewFile(url: url)
            } else {
                model.error = .offline
            }
        }
    }
}

// MARK: - Отправить ссылку в чат (как «Переслать» в Telegram)

private struct StatsID: Identifiable { let id: String }

struct SendToChatSheet: View {
    enum Payload { case text(String), post(String), messages([String]) }
    let payload: Payload

    init(text: String) { payload = .text(text) }
    init(postID: String, onDownload: (() -> Void)? = nil, onNotInterested: (() -> Void)? = nil, onReport: ((String) -> Void)? = nil,
         onDelete: (() -> Void)? = nil) {
        payload = .post(postID)
        self.onDelete = onDelete
        self.onDownload = onDownload
        self.onNotInterested = onNotInterested
        self.onReport = onReport
    }
    init(messageIDs: [String]) { payload = .messages(messageIDs) }

    /// Только для шортсов: две отдельные кнопки над списком чатов
    var onNotInterested: (() -> Void)? = nil
    var onReport: ((String) -> Void)? = nil
    /// Только для шортсов: скачать ролик с водяным знаком
    var onDownload: (() -> Void)? = nil
    /// Только у автора шортса: «Удалить» (с подтверждением)
    var onDelete: (() -> Void)? = nil
    @State private var deleteAsk = false
    @State private var statsFor: String?
    @State private var reportAsk = false

    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var query = ""
    @State private var selected: [ChatPeer] = []          // порядок выбора сохраняется
    @State private var sending = false
    @State private var comment = ""
    @State private var hideSender = false
    @State private var hideCaption = false
    @State private var failed = false
    @State private var failText = ""

    private var s: Strings { Strings(lang: lang) }
    private var isText: Bool { if case .text = payload { return true } else { return false } }
    private var count: Int { if case .messages(let ids) = payload { return ids.count } else { return 1 } }

    private var savedPeer: ChatPeer { ChatPeer(id: session.serverID, name: s.t("Избранное", "Saved messages")) }

    private var chats: [ChatSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = session.chats.chats.filter { $0.id != session.serverID }
        guard !q.isEmpty else { return list }
        return list.filter { $0.peer.name.lowercased().contains(q) || ($0.peer.username ?? "").lowercased().contains(q) }
    }

    private var showSaved: Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || "избранное".contains(q) || "saved messages".contains(q)
    }

    private func isSelected(_ id: String) -> Bool { selected.contains { $0.id == id } }

    private func toggle(_ peer: ChatPeer) {
        Haptics.select()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if let i = selected.firstIndex(where: { $0.id == peer.id }) { selected.remove(at: i) } else { selected.append(peer) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(s.sendToChatTitle).font(.system(size: 20, weight: .bold)).foregroundStyle(theme.text)
                Spacer()
                Button(s.close) { dismiss() }.foregroundStyle(theme.accentColor)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 10)

            if onNotInterested != nil || onReport != nil || onDownload != nil || onDelete != nil {
                VStack(spacing: 8) {
                    if let onDownload {
                        feedbackButton(s.t("Скачать", "Save"), icon: "arrow.down.to.line", danger: false) {
                            Haptics.impact(.medium); dismiss(); onDownload()
                        }
                    }
                    if onDelete != nil {
                        HStack(spacing: 8) {
                            if case .post(let pid) = payload {
                                feedbackButton(s.t("Статистика", "Statistics"), icon: "chart.bar.fill", danger: false) { statsFor = pid }
                            }
                            feedbackButton(s.t("Удалить", "Delete"), icon: "trash", danger: true) { deleteAsk = true }
                        }
                    }
                    HStack(spacing: 8) {
                        if let onNotInterested {
                            feedbackButton(s.t("Не интересует", "Not interested"), icon: "hand.thumbsdown", danger: false) {
                                Haptics.impact(.medium); dismiss(); onNotInterested()
                            }
                        }
                        if onReport != nil {
                            feedbackButton(s.t("Пожаловаться", "Report"), icon: "exclamationmark.bubble", danger: true) { reportAsk = true }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.textTertiary)
                TextField(s.chatsSearch, text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .padding(.horizontal, 14).frame(height: 40).card(theme, radius: 14)
            .padding(.horizontal, 16).padding(.bottom, 8)

            if !selected.isEmpty { chips }

            ScrollView {
                LazyVStack(spacing: 0) {
                    if showSaved { pickRow(savedPeer, saved: true) }
                    ForEach(chats) { chat in pickRow(chat.peer, saved: false) }
                    if chats.isEmpty && !showSaved {
                        Text(s.noChatsToSend).font(.system(size: 15)).foregroundStyle(theme.textSecondary).padding(40)
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)

            bottomPanel
        }
        .overlay(alignment: .top) { if failed { ToastView(text: failText).padding(.top, 60) } }
        .task { await session.chats.refresh() }
        .sheet(item: Binding(get: { statsFor.map { StatsID(id: $0) } }, set: { statsFor = $0?.id })) { item in
            ReelStatsSheet(postID: item.id)
                .environmentObject(session).environment(\.theme, theme).environment(\.lang, lang)
                .presentationDetents([.large])
                .presentationBackground(theme.sheet)
        }
        .confirmationDialog(s.t("Удалить видео?", "Delete this video?"), isPresented: $deleteAsk, titleVisibility: .visible) {
            Button(s.t("Удалить", "Delete"), role: .destructive) { dismiss(); onDelete?() }
            Button(s.cancel, role: .cancel) {}
        } message: {
            Text(s.t("Оно пропадёт у всех, вернуть его будет нельзя.", "It will disappear for everyone and can't be restored."))
        }
        .confirmationDialog(s.t("На что жалуетесь?", "What's wrong?"), isPresented: $reportAsk, titleVisibility: .visible) {
            ForEach([("spam", s.t("Спам", "Spam")), ("violence", s.t("Насилие", "Violence")),
                     ("adult", s.t("Контент для взрослых", "Adult content")), ("illegal", s.t("Незаконный контент", "Illegal content")),
                     ("copyright", s.t("Нарушение авторских прав", "Copyright")), ("other", s.t("Другое", "Other"))], id: \.0) { item in
                Button(item.1) { dismiss(); onReport?(item.0) }
            }
            Button(s.cancel, role: .cancel) {}
        }
    }

    private func feedbackButton(_ title: String, icon: String, danger: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(danger ? theme.danger : theme.text)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background((danger ? theme.danger : theme.textTertiary).opacity(0.14), in: Capsule())
        }
        .buttonStyle(PressStyle())
    }

    // Выбранные получатели — аватарки с крестиком, как в Telegram
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(selected) { peer in
                    Button { toggle(peer) } label: {
                        VStack(spacing: 3) {
                            AvatarView(name: peer.name, size: 46, avatarID: peer.avatarID).clipShape(Circle())
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                                        .foregroundStyle(theme.textSecondary, theme.sheet).offset(x: 4, y: -4)
                                }
                            Text(peer.id == session.serverID ? s.t("Избранное", "Saved") : peer.name)
                                .font(.system(size: 11)).foregroundStyle(theme.textSecondary).lineLimit(1).frame(width: 56)
                        }
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }

    private func pickRow(_ peer: ChatPeer, saved: Bool) -> some View {
        Button { toggle(peer) } label: {
            HStack(spacing: 12) {
                if saved {
                    Image(systemName: "bookmark.fill").font(.system(size: 20)).foregroundStyle(.white)
                        .frame(width: 46, height: 46).background(theme.accent, in: Circle())
                } else {
                    AvatarView(name: peer.name, size: 46, avatarID: peer.avatarID).clipShape(Circle())
                }
                Text(peer.name).font(.system(size: 17, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                Spacer()
                Image(systemName: isSelected(peer.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundStyle(isSelected(peer.id) ? theme.accentColor : theme.textTertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sending)
    }

    // Комментарий, параметры пересылки и кнопка отправки
    private var bottomPanel: some View {
        VStack(spacing: 10) {
            if !selected.isEmpty {
                TextField(s.t("Добавить комментарий…", "Add a comment…"), text: $comment, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(.horizontal, 14).padding(.vertical, 10).card(theme, radius: 14)
                if !isText {
                    HStack(spacing: 8) {
                        optionChip(s.t("Скрыть имя отправителя", "Hide sender name"), on: $hideSender, icon: "person.fill.questionmark")
                        optionChip(s.t("Без подписей", "No captions"), on: $hideCaption, icon: "text.badge.minus")
                    }
                    Text(hideSender || hideCaption
                         ? (hideCaption ? s.t("Без текста под медиа и без пометки «Переслано от».",
                                              "No text under the media and no “Forwarded from” label.")
                                        : s.t("Сообщения придут как ваши собственные, без пометки «Переслано».",
                                              "Messages will arrive as your own, without the “Forwarded” label."))
                         : s.t("Будет видно, от кого пересланы сообщения.", "The original sender will be shown."))
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button { sendAll() } label: {
                Group {
                    if sending { ProgressView().tint(.white) } else {
                        Text(selected.isEmpty ? s.t("Выберите, кому отправить", "Choose recipients")
                             : s.t("Отправить (\(selected.count))", "Send (\(selected.count))"))
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(selected.isEmpty ? AnyShapeStyle(theme.textTertiary.opacity(0.5)) : AnyShapeStyle(theme.accent), in: Capsule())
            }
            .buttonStyle(PressStyle())
            .disabled(selected.isEmpty || sending)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selected.isEmpty)
    }

    private func optionChip(_ title: String, on: Binding<Bool>, icon: String) -> some View {
        Button { on.wrappedValue.toggle(); Haptics.select() } label: {
            HStack(spacing: 5) {
                Image(systemName: on.wrappedValue ? "checkmark" : icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(on.wrappedValue ? Color.white : theme.accentColor)
            .padding(.horizontal, 12).frame(height: 34).frame(maxWidth: .infinity)
            .background(on.wrappedValue ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.accentColor.opacity(0.14)), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Сразу после открытия чата или отправки сообщение/пост может быть ещё «не найден» на сервере (id меняется на настоящий).
    /// Поэтому при временной ошибке приложение немного подумает и повторит сам, а не покажет «профиль не найден».
    private static func attempt(_ op: () async throws -> Void) async throws {
        var delay: UInt64 = 500_000_000
        for n in 0..<4 {
            do { try await op(); return } catch {
                let e = (error as? APIError) ?? .offline
                let transient: Bool
                switch e {
                case .offline: transient = true
                case .server(let status, _): transient = status == 404 || status >= 500
                default: transient = false
                }
                if !transient || n == 3 { throw error }
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 2_000_000_000)
            }
        }
    }

    private func sendAll() {
        guard !selected.isEmpty, !sending else { return }
        sending = true
        let targets = selected
        let note = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            var failedPeers: [ChatPeer] = []
            var lastError: APIError = .offline
            for peer in targets {
                do {
                    if !note.isEmpty {
                        try await Self.attempt { _ = try await session.messengerRepo.send(peerID: peer.id, text: note, replyTo: nil) }
                    }
                    switch payload {
                    case .text(let text):
                        try await Self.attempt { _ = try await session.messengerRepo.send(peerID: peer.id, text: text, replyTo: nil) }
                    case .post(let id):
                        try await Self.attempt { try await session.extras.sharePost(id: id, to: peer.id, hideSender: hideSender, hideCaption: hideCaption) }
                    case .messages(let ids):
                        try await Self.attempt { try await session.extras.forward(ids: ids, to: peer.id, hideSender: hideSender, hideCaption: hideCaption) }
                    }
                } catch {
                    failedPeers.append(peer)
                    lastError = (error as? APIError) ?? .offline
                }
            }
            sending = false
            await session.chats.refresh()
            if failedPeers.isEmpty {
                Haptics.notify(.success)
                dismiss()
            } else {
                // неотправленные остаются выбранными — можно повторить
                withAnimation { selected = failedPeers }
                failText = s.api(lastError)
                failed = true
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                failed = false
            }
        }
    }
}


// MARK: - «печатает…» с бегущими точками, как в Telegram

struct ActionLabel: View {
    let action: String
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        HStack(spacing: 3) {
            Text(Strings(lang: lang).actionWord(action))
            ActionGlyph(action: action, color: theme.accentColor)
        }
        .foregroundStyle(theme.accentColor)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// Три прыгающие точки (печатает), «эквалайзер» (голосовое), пульс (видео), стрелка (файл/фото)
struct ActionGlyph: View {
    let action: String
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            switch action {
            case "voice":
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        let v = 0.5 + 0.5 * sin(t * 7 + Double(i) * 1.3)
                        Capsule().fill(color).frame(width: 2.5, height: 4 + 8 * v)
                    }
                }
                .frame(height: 12)
            case "video":
                Circle().fill(color)
                    .frame(width: 7, height: 7)
                    .scaleEffect(0.7 + 0.5 * (0.5 + 0.5 * sin(t * 5)))
                    .opacity(0.6 + 0.4 * (0.5 + 0.5 * sin(t * 5)))
            case "photo", "file":
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .offset(y: -2 * CGFloat(0.5 + 0.5 * sin(t * 6)))
            default:
                HStack(spacing: 2.5) {
                    ForEach(0..<3, id: \.self) { i in
                        // волна: каждая точка отстаёт по фазе — получается «перебирание»
                        let wave = max(0, sin(t * 6 - Double(i) * 0.9))
                        Circle().fill(color)
                            .frame(width: 4.5, height: 4.5)
                            .offset(y: -3.5 * CGFloat(wave))
                            .opacity(0.45 + 0.55 * wave)
                    }
                }
                .frame(height: 12)
                .padding(.top, 3)
            }
        }
        .foregroundStyle(color)
    }
}


/// Кнопка «назад» в шапке чата: рядом число непрочитанных сообщений в остальных чатах (без отключённых)
private struct BackWithUnread: View {
    @ObservedObject var model: ChatsModel
    let excluding: String
    @Environment(\.theme) private var theme

    private var unread: Int {
        model.chats.filter { $0.id != excluding && !$0.muted }.reduce(0) { $0 + $1.unread }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.text)
            if unread > 0 {
                Text(unread > 999 ? "999+" : "\(unread)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.dark ? Color.black : Color.white)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(theme.dark ? Color.white : Color.black.opacity(0.75), in: Capsule())
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, unread > 0 ? 12 : 0)
        .frame(minWidth: 44).frame(height: 44)
        .glassCapsule()
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.15), value: unread)
    }
}


/// Строка поиска над плеером в чате — появляется, когда листаешь вверх
struct PeekSearchRow: View {
    let visible: Bool
    let action: () -> Void
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        if visible && player.current != nil {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.textTertiary)
                    Text(Strings(lang: lang).t("Поиск по переписке", "Search messages"))
                        .font(.system(size: 15)).foregroundStyle(theme.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, 14).frame(height: 38)
                .glassCapsule().contentShape(Capsule())
            }
            .buttonStyle(.plain).padding(.horizontal, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}


final class ActionTargetState: ObservableObject {
    @Published var target: ChatMessage?
}

/// Подписан на выбранное сообщение сам — родитель (чат) при этом не перестраивается
struct ActionTargetHost<Content: View>: View {
    @ObservedObject var state: ActionTargetState
    @ViewBuilder var content: (ChatMessage) -> Content
    var body: some View {
        if let t = state.target { content(t) }
    }
}
