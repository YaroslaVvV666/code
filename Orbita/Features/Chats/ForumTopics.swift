import SwiftUI
import Combine

// MARK: - Темы в группах (форум, как в Telegram)

struct ForumTopic: Identifiable, Equatable, Hashable, Decodable {
    struct Last: Equatable, Hashable, Decodable {
        let text: String
        let who: String
        let mine: Bool
        let at: Double
    }
    let id: String
    let title: String
    let icon: String?
    let color: Int
    let closed: Bool
    let pinned: Bool
    let general: Bool
    let unread: Int
    let createdByMe: Bool?
    let last: Last?

    var ref: ForumTopicRef { ForumTopicRef(id: id, title: title, icon: icon, color: color, general: general) }
}

struct ForumTopicList: Decodable {
    let forum: Bool
    let topics: [ForumTopic]
    let canCreate: Bool
    let canManage: Bool
}

/// Тема, открытая в переписке
struct ForumTopicRef: Hashable {
    let id: String
    let title: String
    var icon: String? = nil
    var color = 0
    var general = false
}

enum TopicPalette {
    static let colors: [Color] = [
        Color(red: 0.42, green: 0.62, blue: 0.98), Color(red: 1.0, green: 0.78, blue: 0.24),
        Color(red: 0.75, green: 0.48, blue: 0.98), Color(red: 0.42, green: 0.83, blue: 0.47),
        Color(red: 1.0, green: 0.51, blue: 0.72), Color(red: 1.0, green: 0.42, blue: 0.36),
        Color(red: 0.36, green: 0.80, blue: 0.86)
    ]
    static func color(_ i: Int) -> Color { colors[min(max(i, 0), colors.count - 1)] }
    static let emojis = ["💬", "📰", "📢", "🎮", "🎵", "📚", "💡", "🔥", "❤️", "⭐️", "🎉", "🛠", "💼", "📷", "🍕", "⚽️", "✈️", "🏠", "💰", "❓"]
}

/// Значок темы: эмодзи или цветная «капля» с первой буквой
struct TopicIcon: View {
    let icon: String?
    let color: Int
    let title: String
    var general = false
    var size: CGFloat = 36

    var body: some View {
        Group {
            if general {
                Image(systemName: "number").font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.secondary)
            } else if let icon, !icon.isEmpty {
                Text(icon).font(.system(size: size * 0.72))
            } else {
                ZStack {
                    Image(systemName: "bubble.left.fill").font(.system(size: size * 0.9))
                        .foregroundStyle(TopicPalette.color(color).gradient)
                    Text(String(title.prefix(1)).uppercased()).font(.system(size: size * 0.36, weight: .bold))
                        .foregroundStyle(.white).offset(y: -size * 0.04)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Список тем группы-форума: вместо общей ленты сообщений
struct ForumTopicsScreen: View {
    let route: ChatRoute
    let session: AppSession
    let group: GroupInfo
    var standalone = false
    let onInfo: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss
    @State private var list: ForumTopicList?
    @State private var openTopic: ChatRoute?
    @State private var creating = false
    @State private var editing: ForumTopic?
    @State private var failed = false

    private var s: Strings { Strings(lang: lang) }
    private var repo: MessengerRepository { session.messengerRepo }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let list {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(list.topics) { t in
                            Button { open(t) } label: { row(t) }
                                .buttonStyle(.plain)
                                .contextMenu { if list.canManage || t.createdByMe == true, !t.general { menu(t) } }
                            Divider().padding(.leading, 70)
                        }
                    }
                    .padding(.bottom, 30)
                }
                .refreshable { await load() }
            } else if failed {
                Spacer()
                Text(s.t("Не удалось загрузить темы", "Couldn't load topics")).foregroundStyle(theme.textSecondary)
                Button(s.t("Повторить", "Retry")) { Task { await load() } }.padding(.top, 8)
                Spacer()
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
        .background(theme.dark ? Color.black : Color(white: 0.97))
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .task {
            // темы живут: новые сообщения и непрочитанные обновляются, пока список открыт
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await load()
            }
        }
        .navigationDestination(item: standalone ? .constant(nil) : $openTopic) { r in
            ChatScreen(route: r, session: session).environmentObject(session)
        }
        .fullScreenCover(item: standalone ? $openTopic : .constant(nil)) { r in
            ChatScreen(route: r, session: session, standalone: true).environmentObject(session)
        }
        .sheet(isPresented: $creating) {
            TopicEditSheet(title: s.t("Новая тема", "New topic"), initial: nil) { title, icon, color in
                let t = try await repo.createTopic(groupID: group.id, title: title, icon: icon, color: color)
                await load()
                openTopic = ChatRoute(peer: route.peer, topic: t.ref)
            }
            .environment(\.theme, theme).environment(\.lang, lang)
            .presentationDetents([.medium, .large])
            .sheetStyle(theme)
        }
        .sheet(item: $editing) { t in
            TopicEditSheet(title: s.t("Изменить тему", "Edit topic"), initial: t) { title, icon, _ in
                _ = try await repo.updateTopic(groupID: group.id, topicID: t.id, fields: ["title": title, "icon": icon ?? ""])
                await load()
            }
            .environment(\.theme, theme).environment(\.lang, lang)
            .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.text)
                    .frame(width: 44, height: 44).glassCircle()
            }
            .buttonStyle(.plain)
            Button(action: onInfo) {
                HStack(spacing: 10) {
                    AvatarView(name: group.name, size: 38, avatarID: route.peer.avatarID).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                        Text("\(group.count) \(s.memberWord(channel: false))").font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            if list?.canCreate == true {
                Button { creating = true } label: {
                    Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.text)
                        .frame(width: 44, height: 44).glassCircle()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func row(_ t: ForumTopic) -> some View {
        HStack(spacing: 12) {
            TopicIcon(icon: t.icon, color: t.color, title: t.title, general: t.general, size: 40)
                .frame(width: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(t.general ? s.t("Общая", "General") : t.title)
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                    if t.closed {
                        Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: 4)
                    if let last = t.last {
                        Text(ChatTime.short(Date(timeIntervalSince1970: last.at), lang: lang))
                            .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    }
                }
                HStack(alignment: .top) {
                    if let last = t.last {
                        (Text(last.mine ? s.t("Вы: ", "You: ") : last.who + ": ").foregroundStyle(theme.text)
                         + Text(last.text).foregroundStyle(theme.textSecondary))
                            .font(.system(size: 14)).lineLimit(2)
                    } else {
                        Text(s.t("Пока нет сообщений", "No messages yet")).font(.system(size: 14)).foregroundStyle(theme.textTertiary)
                    }
                    Spacer(minLength: 4)
                    if t.unread > 0 {
                        Text("\(t.unread)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                            .background(theme.accentColor, in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func menu(_ t: ForumTopic) -> some View {
        Button { editing = t } label: { Label(s.t("Изменить", "Edit"), systemImage: "pencil") }
        if list?.canManage == true {
            Button {
                Task { _ = try? await repo.updateTopic(groupID: group.id, topicID: t.id, fields: ["pinned": !t.pinned]); await load() }
            } label: { Label(t.pinned ? s.t("Открепить", "Unpin") : s.t("Закрепить", "Pin"), systemImage: t.pinned ? "pin.slash" : "pin") }
            Button {
                Task { _ = try? await repo.updateTopic(groupID: group.id, topicID: t.id, fields: ["closed": !t.closed]); await load() }
            } label: { Label(t.closed ? s.t("Открыть тему", "Reopen") : s.t("Закрыть тему", "Close topic"),
                             systemImage: t.closed ? "lock.open" : "lock") }
            Button(role: .destructive) {
                AppAlert.confirm(s.t("Удалить тему «\(t.title)»?", "Delete topic «\(t.title)»?"),
                                 s.t("Все сообщения в ней будут удалены у всех.", "All its messages will be deleted for everyone."),
                                 ok: s.t("Удалить", "Delete"), cancel: s.cancel) {
                    Task { try? await repo.deleteTopic(groupID: group.id, topicID: t.id); await load() }
                }
            } label: { Label(s.t("Удалить", "Delete"), systemImage: "trash") }
        }
    }

    private func open(_ t: ForumTopic) {
        Haptics.select()
        openTopic = ChatRoute(peer: route.peer, topic: t.ref)
    }

    private func load() async {
        do {
            let fresh = try await repo.topics(groupID: group.id)
            if fresh.topics != list?.topics || list == nil { list = fresh }
            failed = false
        } catch {
            if list == nil { failed = true }
        }
    }
}

/// Создание / изменение темы: название, значок-эмодзи, цвет
struct TopicEditSheet: View {
    let title: String
    let initial: ForumTopic?
    let save: (_ title: String, _ icon: String?, _ color: Int) async throws -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon: String?
    @State private var color = 0
    @State private var busy = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private var s: Strings { Strings(lang: lang) }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(s.cancel) { dismiss() }.foregroundStyle(theme.accentColor)
                Spacer()
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
                Spacer()
                Button {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            try await save(String(trimmed.prefix(64)), icon, color)
                            dismiss()
                        } catch {
                            errorText = s.api((error as? APIError) ?? .offline)
                        }
                    }
                } label: {
                    if busy { ProgressView() } else { Text(s.t("Готово", "Done")).fontWeight(.semibold) }
                }
                .foregroundStyle(trimmed.isEmpty ? theme.textTertiary : theme.accentColor)
                .disabled(trimmed.isEmpty || busy)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)

            ScrollView {
                VStack(spacing: 18) {
                    TopicIcon(icon: icon, color: color, title: trimmed.isEmpty ? "?" : trimmed, size: 72)
                        .padding(.top, 6)
                    TextField(s.t("Название темы", "Topic name"), text: $name)
                        .focused($focused)
                        .padding(14).card(theme, radius: 16)
                    if icon == nil {
                        HStack(spacing: 12) {
                            ForEach(TopicPalette.colors.indices, id: \.self) { i in
                                Circle().fill(TopicPalette.colors[i]).frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(theme.text, lineWidth: color == i ? 2.5 : 0).padding(-4))
                                    .onTapGesture { Haptics.select(); color = i }
                            }
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        Button { icon = nil } label: {
                            Image(systemName: "textformat").font(.system(size: 18)).foregroundStyle(theme.text)
                                .frame(width: 44, height: 44)
                                .background(icon == nil ? theme.accentColor.opacity(0.25) : Color.clear, in: Circle())
                        }
                        .buttonStyle(.plain)
                        ForEach(TopicPalette.emojis, id: \.self) { e in
                            Button { Haptics.select(); icon = e } label: {
                                Text(e).font(.system(size: 26)).frame(width: 44, height: 44)
                                    .background(icon == e ? theme.accentColor.opacity(0.25) : Color.clear, in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let errorText {
                        Text(errorText).font(.system(size: 13)).foregroundStyle(theme.danger)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 30)
            }
        }
        .background(theme.sheet)
        .onAppear {
            name = initial?.title ?? ""
            icon = initial?.icon
            color = initial?.color ?? Int.random(in: 0..<TopicPalette.colors.count)
            focused = initial == nil
        }
    }
}
