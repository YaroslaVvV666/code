import SwiftUI
import Charts

// MARK: - Вспомогательное

extension ChatPeer {
    /// Собеседник-группа из полной информации о ней
    init(group info: GroupInfo) {
        self.init(id: info.id, name: info.name, username: info.handle, avatarID: nil, isGroup: true, kind: info.kind,
                  memberCount: info.count, type: info.type, handle: info.handle, noForward: info.noForward)
    }
}

extension Strings {
    func memberWord(channel: Bool) -> String {
        channel ? t("подписчиков", "subscribers") : t("участников", "members")
    }

    func slowLabel(_ seconds: Int) -> String {
        switch seconds {
        case 0: return t("Выкл", "Off")
        case 10: return t("10 с", "10 s")
        case 30: return t("30 с", "30 s")
        case 60: return t("1 мин", "1 min")
        case 300: return t("5 мин", "5 min")
        case 900: return t("15 мин", "15 min")
        default: return t("1 час", "1 h")
        }
    }
}

enum GroupLinks {
    static func url(ref: String) -> URL? {
        guard let base = ServerConfig.baseURL else { return nil }
        return URL(string: base.absoluteString + "/g/" + ref)
    }
}

// MARK: - Форма параметров (создание и изменение)

struct GroupSettingsForm: View {
    @Binding var draft: GroupDraft
    /// Тип доступа и ссылку меняет только владелец
    var ownerRights = true
    /// «Кто может писать» и медленный режим прямо в форме (при создании); в настройках — на экране «Разрешения»
    var writingInline = true

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }
    private var channel: Bool { draft.type == "channel" }
    private var linkBase: String { (ServerConfig.baseURL?.absoluteString ?? "") + "/g/" }
    private let slowSteps = [0, 10, 30, 60, 300, 900, 3600]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField(channel ? s.t("Название канала", "Channel name") : s.t("Название группы", "Group name"), text: $draft.title)
                .font(.system(size: 17)).padding(.horizontal, 14).frame(height: 48).card(theme, radius: 14)
            TextField(s.t("Описание (необязательно)", "Description (optional)"), text: $draft.about, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 16)).padding(.horizontal, 14).padding(.vertical, 12).card(theme, radius: 14)

            if ownerRights {
                caption(channel ? s.t("ТИП КАНАЛА", "CHANNEL TYPE") : s.t("ТИП ГРУППЫ", "GROUP TYPE"))
                Picker("", selection: $draft.kind) {
                    Text(s.t("Закрытый", "Private")).tag("closed")
                    Text(s.t("Публичный", "Public")).tag("open")
                }
                .pickerStyle(.segmented)
                hint(draft.kind == "open"
                     ? s.t("Виден в каталоге «Сообщества» и в поиске, вступить может любой. Можно задать красивую ссылку.",
                           "Shown in the Communities directory and search; anyone can join. You can set a short link.")
                     : s.t("Попасть можно только по приглашению или ссылке-приглашению.",
                           "Join by invitation or invite link only."))
                if draft.kind == "open" {
                    HStack(spacing: 2) {
                        Text(linkBase).font(.system(size: 14)).foregroundStyle(theme.textTertiary).lineLimit(1)
                        TextField("name", text: $draft.handle)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.system(size: 16))
                    }
                    .padding(.horizontal, 14).frame(height: 46).card(theme, radius: 14)
                    hint(s.t("Необязательно. Латиница, цифры и _, от 5 символов.", "Optional. Latin letters, digits and _, 5+ characters."))
                }
            }

            caption(s.t("ПАРАМЕТРЫ", "SETTINGS"))
            toggleRow(s.t("Заявки на вступление", "Join requests"), $draft.approve,
                      s.t("Администраторы подтверждают каждого, кто хочет вступить.", "Admins approve everyone who wants to join."))
            if !channel {
                if writingInline {
                    menuRow(s.t("Кто может писать", "Who can write")) {
                        Picker("", selection: $draft.whoWrites) {
                            Text(s.t("Все участники", "All members")).tag("all")
                            Text(s.t("Только админы", "Admins only")).tag("admins")
                        }
                    }
                    menuRow(s.t("Медленный режим", "Slow mode")) {
                        Picker("", selection: $draft.slow) {
                            ForEach(slowSteps, id: \.self) { Text(s.slowLabel($0)).tag($0) }
                        }
                    }
                }
                toggleRow(s.t("История для новых участников", "History for new members"), $draft.history,
                          s.t("Если выключить, новички увидят только сообщения после вступления.",
                              "If off, newcomers only see messages sent after they join."))
            }
            toggleRow(s.t("Запретить копирование", "Restrict copying"), $draft.noForward,
                      s.t("Скрывает «Копировать» в сообщениях. Скриншоты запретить нельзя.",
                          "Hides “Copy” on messages. Screenshots can't be blocked."))
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
    }

    private func toggleRow(_ title: String, _ value: Binding<Bool>, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: value) {
                Text(title).font(.system(size: 16)).foregroundStyle(theme.text)
            }
            .tint(theme.accentColor)
            Text(note).font(.system(size: 12)).foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10).card(theme, radius: 14)
    }

    private func menuRow<P: View>(_ title: String, @ViewBuilder picker: () -> P) -> some View {
        HStack {
            Text(title).font(.system(size: 16)).foregroundStyle(theme.text)
            Spacer()
            picker().pickerStyle(.menu).tint(theme.accentColor)
        }
        .padding(.horizontal, 14).frame(height: 48).card(theme, radius: 14)
    }
}

// MARK: - Создать группу или канал

struct GroupCreateSheet: View {
    var type = "group"
    let onCreated: (GroupInfo) -> Void

    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var draft = GroupDraft()
    @State private var selected: [Contact] = []
    @State private var busy = false
    @State private var errorText: String?
    private var s: Strings { Strings(lang: lang) }
    private var channel: Bool { type == "channel" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupSettingsForm(draft: $draft)

                    Text(channel ? s.t("ПОДПИСЧИКИ", "SUBSCRIBERS") : s.t("УЧАСТНИКИ", "MEMBERS"))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                    PeoplePicker(selected: $selected)
                    InviteOutsidersLink()

                    if let errorText { Text(errorText).font(.system(size: 13)).foregroundStyle(theme.danger) }
                    PrimaryButton(title: s.t("Создать", "Create"), enabled: !draft.title.trimmingCharacters(in: .whitespaces).isEmpty,
                                  loading: busy) { create() }
                }
                .padding(16)
            }
            .navigationTitle(channel ? s.t("Новый канал", "New channel") : s.t("Новая группа", "New group"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(s.cancel) { dismiss() } } }
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { draft.type = type; if channel { draft.whoWrites = "admins" } }
    }

    private func create() {
        busy = true
        errorText = nil
        Task {
            defer { busy = false }
            do {
                var d = draft
                d.title = d.title.trimmingCharacters(in: .whitespaces)
                d.handle = d.kind == "open" ? d.handle.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")) : ""
                let info = try await session.messengerRepo.createGroup(d, members: selected.map(\.id))
                await session.chats.refresh()
                onCreated(info)
            } catch { errorText = s.api((error as? APIError) ?? .offline) }
        }
    }
}

// MARK: - Изменить группу или канал

struct GroupEditSheet: View {
    let group: GroupInfo
    let onDone: () async -> Void
    var onDeleted: () -> Void = {}

    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var draft = GroupDraft()
    @State private var requests = 0
    @State private var busy = false
    @State private var errorText: String?
    @State private var confirmDelete = false
    @State private var discussion: DiscussionRef?
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupSettingsForm(draft: $draft, ownerRights: group.isOwner, writingInline: false)

                    if group.isChannel && group.isOwner { DiscussionPicker(selected: $discussion) }

                    if !group.isChannel {
                        NavigationLink {
                            GroupPermissionsView(draft: $draft, members: group.members)
                        } label: {
                            navRow("key.fill", s.t("Разрешения", "Permissions"), badge: 0, value: permissionsSummary)
                        }
                        NavigationLink {
                            GroupRestrictedView(groupID: group.id)
                        } label: {
                            navRow("speaker.slash.fill", s.t("Запрещено писать", "Restricted"), badge: 0)
                        }
                    }
                    NavigationLink {
                        GroupStatsView(groupID: group.id, title: group.name, channel: group.isChannel)
                    } label: {
                        navRow("chart.bar.fill", s.t("Статистика", "Statistics"), badge: 0)
                    }

                    NavigationLink {
                        GroupRequestsView(groupID: group.id) { await onDone() }
                    } label: {
                        navRow("person.crop.circle.badge.clock", s.t("Заявки на вступление", "Join requests"), badge: group.requests)
                    }
                    NavigationLink {
                        GroupBansView(groupID: group.id)
                    } label: {
                        navRow("person.fill.xmark", s.t("Удалённые участники", "Removed members"), badge: 0)
                    }

                    if let errorText { Text(errorText).font(.system(size: 13)).foregroundStyle(theme.danger) }
                    PrimaryButton(title: s.save, enabled: !draft.title.trimmingCharacters(in: .whitespaces).isEmpty,
                                  loading: busy) { save() }

                    if group.isOwner {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Text(group.isChannel ? s.t("Удалить канал", "Delete channel") : s.t("Удалить группу", "Delete group"))
                                .font(.system(size: 16, weight: .medium)).foregroundStyle(theme.danger)
                                .frame(maxWidth: .infinity).frame(height: 48).card(theme, radius: 14)
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                .padding(16)
            }
            .navigationTitle(group.isChannel ? s.t("Изменить канал", "Edit channel") : s.t("Изменить группу", "Edit group"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(s.close) { dismiss() } } }
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            draft = GroupDraft(type: group.type, title: group.name, about: group.about, kind: group.kind,
                               handle: group.handle ?? "", approve: group.approve, noForward: group.noForward,
                               slow: group.slow, whoWrites: group.whoWrites, history: group.history,
                               perms: group.perms, writers: group.writers)
            discussion = group.discussion
        }
        .confirmationDialog(s.t("Удалить для всех? Все сообщения будут стёрты.", "Delete for everyone? All messages will be erased."),
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(s.delete, role: .destructive) { delete() }
            Button(s.cancel, role: .cancel) {}
        }
    }

    /// «Все участники · медленный режим 30 с» — что сейчас настроено
    private var permissionsSummary: String {
        var parts = [draft.whoWrites == "admins" ? s.t("Только админы", "Admins only")
                     : draft.whoWrites == "selected" ? s.t("Выбранные", "Selected") : s.t("Все", "Everyone")]
        if draft.slow > 0 { parts.append(s.slowLabel(draft.slow)) }
        return parts.joined(separator: " · ")
    }

    private func navRow(_ icon: String, _ title: String, badge: Int, value: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(theme.accentColor).frame(width: 24)
            Text(title).font(.system(size: 16)).foregroundStyle(theme.text)
            Spacer()
            if let value { Text(value).font(.system(size: 14)).foregroundStyle(theme.textSecondary).lineLimit(1) }
            if badge > 0 {
                Text("\(badge)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                    .background(theme.accent, in: Capsule())
            }
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, 14).frame(height: 50).card(theme, radius: 14)
    }

    private func save() {
        busy = true
        errorText = nil
        Task {
            defer { busy = false }
            var p = GroupPatch(title: draft.title.trimmingCharacters(in: .whitespaces), about: draft.about,
                               approve: draft.approve, noForward: draft.noForward, history: draft.history)
            if group.isOwner {
                p.kind = draft.kind
                p.handle = draft.kind == "open" ? draft.handle.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")) : ""
                if group.isChannel, discussion?.id != group.discussion?.id { p.discussion = discussion?.id ?? "" }
            }
            if !group.isChannel {
                p.slow = draft.slow
                p.whoWrites = draft.whoWrites
                p.perms = draft.perms
                if draft.whoWrites == "selected" { p.writers = draft.writers }
            }
            do {
                _ = try await session.messengerRepo.editGroup(id: group.id, patch: p)
                await onDone()
                dismiss()
            } catch { errorText = s.api((error as? APIError) ?? .offline) }
        }
    }

    private func delete() {
        Task {
            do {
                try await session.messengerRepo.deleteGroup(id: group.id)
                await session.chats.refresh()
                dismiss()
                onDeleted()
            } catch { errorText = s.api((error as? APIError) ?? .offline) }
        }
    }
}

// MARK: - Заявки на вступление

struct GroupRequestsView: View {
    let groupID: String
    var onChanged: () async -> Void = {}

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var list: [JoinRequest] = []
    @State private var loaded = false
    @State private var errorText: String?
    @State private var busyAll = false
    @State private var profile: GroupMember?
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if list.count > 1 {
                    Button { acceptAll() } label: {
                        HStack(spacing: 8) {
                            if busyAll { ProgressView().tint(.white) } else { Image(systemName: "checkmark.circle.fill") }
                            Text(s.t("Принять всех (\(list.count))", "Accept all (\(list.count))")).font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(theme.accent, in: Capsule())
                    }
                    .buttonStyle(PressStyle())
                    .disabled(busyAll)
                    .padding(.bottom, 4)
                }
                if list.isEmpty && loaded {
                    Text(s.t("Новых заявок нет", "No pending requests"))
                        .font(.system(size: 15)).foregroundStyle(theme.textSecondary).padding(40)
                }
                ForEach(list) { r in
                    HStack(spacing: 12) {
                        Button { profile = r.member } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: r.member.name, size: 46, avatarID: r.member.avatarID).clipShape(Circle())
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.member.name).font(.system(size: 16, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                                    Text(r.member.username.map { "@" + $0 } ?? s.t("Открыть профиль", "View profile"))
                                        .font(.system(size: 13)).foregroundStyle(theme.textTertiary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { answer(r, false) } label: {
                            Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(theme.danger)
                                .frame(width: 38, height: 38).glassCircle()
                        }
                        .buttonStyle(.plain)
                        Button { answer(r, true) } label: {
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 38, height: 38).background(theme.accent, in: Circle())
                        }
                        .buttonStyle(PressStyle())
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                if let errorText { Text(errorText).font(.system(size: 13)).foregroundStyle(theme.danger).padding() }
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 20)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: list.map(\.id))
        }
        .navigationTitle(s.t("Заявки", "Requests"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fullScreenCover(item: $profile) { member in
            PublicProfileSheet(source: .id(member.id))
                .environmentObject(session).environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
    }

    private func load() async {
        list = (try? await session.messengerRepo.joinRequests(groupID: groupID)) ?? []
        loaded = true
    }

    private func answer(_ r: JoinRequest, _ approve: Bool) {
        Task {
            do {
                _ = try await session.messengerRepo.answerRequest(groupID: groupID, userID: r.member.id, approve: approve)
                withAnimation { list.removeAll { $0.id == r.id } }
                Haptics.impact(.light)
                await onChanged()
            } catch { errorText = s.api((error as? APIError) ?? .offline) }
        }
    }

    private func acceptAll() {
        busyAll = true
        let pending = list
        Task {
            for r in pending {
                if (try? await session.messengerRepo.answerRequest(groupID: groupID, userID: r.member.id, approve: true)) != nil {
                    withAnimation { list.removeAll { $0.id == r.id } }
                }
            }
            Haptics.notify(.success)
            busyAll = false
            await onChanged()
        }
    }
}

/// Заявки отдельным окном (из профиля чата и из шапки переписки)
struct GroupRequestsSheet: View {
    let groupID: String
    let onChanged: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lang) private var lang

    var body: some View {
        NavigationStack {
            GroupRequestsView(groupID: groupID, onChanged: onChanged)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(Strings(lang: lang).close) { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
    }
}

// MARK: - Удалённые участники

struct GroupBansView: View {
    let groupID: String

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var list: [GroupMember] = []
    @State private var loaded = false
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if list.isEmpty && loaded {
                    Text(s.t("Список пуст", "The list is empty"))
                        .font(.system(size: 15)).foregroundStyle(theme.textSecondary).padding(40)
                }
                ForEach(list) { m in
                    HStack(spacing: 12) {
                        AvatarView(name: m.name, size: 46, avatarID: m.avatarID).clipShape(Circle())
                        Text(m.name).font(.system(size: 16, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                        Spacer()
                        Button {
                            Task {
                                try? await session.messengerRepo.unban(groupID: groupID, userID: m.id)
                                list.removeAll { $0.id == m.id }
                            }
                        } label: {
                            Text(s.t("Разрешить", "Allow")).font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.accentColor)
                                .padding(.horizontal, 14).frame(height: 32).card(theme, radius: 16)
                        }
                        .buttonStyle(PressStyle())
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
        }
        .navigationTitle(s.t("Удалённые", "Removed"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            list = (try? await session.messengerRepo.bannedUsers(groupID: groupID)) ?? []
            loaded = true
        }
    }
}


// MARK: - Разрешения группы (как в Telegram)

struct GroupPermissionsView: View {
    @Binding var draft: GroupDraft
    let members: [GroupMember]

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }
    private let slowSteps = [0, 10, 30, 60, 300, 900, 3600]
    private var regular: [GroupMember] { members.filter { $0.role == "member" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                caption(s.t("КТО МОЖЕТ ПИСАТЬ", "WHO CAN SEND MESSAGES"))
                VStack(spacing: 0) {
                    choice(s.t("Все участники", "All members"), "all")
                    line
                    choice(s.t("Только администраторы", "Admins only"), "admins")
                    line
                    choice(s.t("Выбранные участники", "Selected members"), "selected")
                }
                .card(theme, radius: 14)
                if draft.whoWrites == "selected" {
                    hint(s.t("Отметьте, кто может писать. Администраторы пишут всегда.",
                             "Pick who can write. Admins can always write."))
                    VStack(spacing: 0) {
                        if regular.isEmpty {
                            Text(s.t("В группе пока только администраторы", "Only admins in the group so far"))
                                .font(.system(size: 14)).foregroundStyle(theme.textSecondary).padding(16)
                        }
                        ForEach(regular) { m in
                            memberRow(m)
                            if m.id != regular.last?.id { line }
                        }
                    }
                    .card(theme, radius: 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                caption(s.t("ЧТО МОГУТ УЧАСТНИКИ", "WHAT MEMBERS CAN DO")).padding(.top, 8)
                VStack(spacing: 0) {
                    perm(s.t("Фото, видео и файлы", "Photos, videos & files"), "photo.on.rectangle", \.media)
                    line
                    perm(s.t("Голосовые и кружки", "Voice & video messages"), "mic.fill", \.voice)
                    line
                    perm(s.t("Стикеры и GIF", "Stickers & GIFs"), "face.smiling", \.stickers)
                    line
                    perm(s.t("Ссылки", "Links"), "link", \.links)
                    line
                    perm(s.t("Опросы", "Polls"), "chart.bar.xaxis", \.polls)
                    line
                    perm(s.t("Добавлять участников", "Add members"), "person.badge.plus", \.invite)
                    line
                    perm(s.t("Закреплять сообщения", "Pin messages"), "pin.fill", \.pin)
                }
                .card(theme, radius: 14)
                hint(s.t("Администраторов это не касается.", "Admins aren't affected."))

                caption(s.t("МЕДЛЕННЫЙ РЕЖИМ", "SLOW MODE")).padding(.top, 8)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(slowSteps, id: \.self) { v in
                            Button {
                                Haptics.select()
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { draft.slow = v }
                            } label: {
                                Text(s.slowLabel(v)).font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(draft.slow == v ? Color.white : theme.text)
                                    .padding(.horizontal, 14).frame(height: 34)
                                    .background(draft.slow == v ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.surface), in: Capsule())
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                }
                hint(s.t("Как часто участник может отправлять сообщение.", "How often a member can send a message."))
                hint(s.t("Изменения сохранятся кнопкой «Сохранить».", "Tap “Save” to apply the changes.")).padding(.top, 6)
            }
            .padding(16)
        }
        .navigationTitle(s.t("Разрешения", "Permissions"))
        .navigationBarTitleDisplayMode(.inline)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: draft.whoWrites)
    }

    private var line: some View { Rectangle().fill(theme.stroke).frame(height: 0.5).padding(.leading, 16) }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary).padding(.leading, 4)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(theme.textTertiary).padding(.horizontal, 4)
    }

    private func choice(_ title: String, _ value: String) -> some View {
        Button {
            Haptics.select()
            draft.whoWrites = value
        } label: {
            HStack {
                Text(title).font(.system(size: 16)).foregroundStyle(theme.text)
                Spacer()
                if draft.whoWrites == value {
                    Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accentColor)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16).frame(height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func memberRow(_ m: GroupMember) -> some View {
        let on = draft.writers.contains(m.id)
        return Button {
            Haptics.select()
            if on { draft.writers.removeAll { $0 == m.id } } else { draft.writers.append(m.id) }
        } label: {
            HStack(spacing: 12) {
                AvatarView(name: m.name, size: 36, avatarID: m.avatarID).clipShape(Circle())
                Text(m.name).font(.system(size: 16)).foregroundStyle(theme.text).lineLimit(1)
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(on ? theme.accentColor : theme.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 16).padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func perm(_ title: String, _ icon: String, _ key: WritableKeyPath<GroupPerms, Bool>) -> some View {
        Toggle(isOn: Binding(get: { draft.perms[keyPath: key] }, set: { draft.perms[keyPath: key] = $0 })) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(theme.accentColor).frame(width: 22)
                Text(title).font(.system(size: 16)).foregroundStyle(theme.text)
            }
        }
        .tint(theme.accentColor)
        .padding(.horizontal, 16).frame(height: 48)
    }
}

// MARK: - Кому запретили писать

struct GroupRestrictedView: View {
    let groupID: String

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var list: [RestrictedMember] = []
    @State private var loaded = false
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if list.isEmpty && loaded {
                    VStack(spacing: 8) {
                        Image(systemName: "speaker.slash").font(.system(size: 30)).foregroundStyle(theme.textTertiary)
                        Text(s.t("Никому не запрещено писать", "Nobody is restricted"))
                            .font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                        Text(s.t("Запретить можно при удалении сообщения участника.",
                                 "You can restrict someone when deleting their message."))
                            .font(.system(size: 13)).foregroundStyle(theme.textTertiary).multilineTextAlignment(.center)
                    }
                    .padding(40)
                }
                ForEach(list) { r in
                    HStack(spacing: 12) {
                        AvatarView(name: r.member.name, size: 46, avatarID: r.member.avatarID).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.member.name).font(.system(size: 16, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                            Text(r.until.map { s.t("до ", "until ") + $0.formatted(date: .abbreviated, time: .shortened) }
                                 ?? s.t("навсегда", "forever"))
                                .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        Button {
                            Haptics.impact(.light)
                            Task {
                                try? await session.messengerRepo.unrestrict(groupID: groupID, userID: r.id)
                                withAnimation(.easeOut(duration: 0.2)) { list.removeAll { $0.id == r.id } }
                            }
                        } label: {
                            Text(s.t("Разрешить", "Allow")).font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.accentColor)
                                .padding(.horizontal, 14).frame(height: 32).card(theme, radius: 16)
                        }
                        .buttonStyle(PressStyle())
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .transition(.opacity)
                }
            }
        }
        .navigationTitle(s.t("Запрещено писать", "Restricted"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            list = (try? await session.messengerRepo.restricted(groupID: groupID)) ?? []
            loaded = true
        }
    }
}


// MARK: - Статистика канала или группы (как в Telegram)

struct GroupStatsView: View {
    let groupID: String
    let title: String
    let channel: Bool

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var stats: GroupStats?
    @State private var failed = false
    @State private var showJoined = true
    @State private var showLeft = true
    @State private var hiddenSources: Set<String> = []
    @State private var hiddenLangs: Set<String> = []
    private var s: Strings { Strings(lang: lang) }

    static let sourceOrder = ["subscribers", "other", "dm", "groups", "url"]
    static let sourceColors: [String: Color] = [
        "subscribers": Color(red: 0.0, green: 0.48, blue: 1.0), "other": Color(red: 0.35, green: 0.78, blue: 0.98),
        "dm": Color(red: 0.55, green: 0.85, blue: 0.2), "groups": Color(red: 1.0, green: 0.58, blue: 0.0),
        "url": Color(red: 0.2, green: 0.78, blue: 0.35),
    ]
    static let langColors: [Color] = [Color(red: 0.0, green: 0.48, blue: 1.0), Color(red: 0.35, green: 0.78, blue: 0.98),
                                      Color(red: 1.0, green: 0.58, blue: 0.0), Color(red: 0.2, green: 0.78, blue: 0.35),
                                      Color(red: 0.69, green: 0.32, blue: 0.87), Color(red: 1.0, green: 0.27, blue: 0.23)]

    private func sourceName(_ key: String) -> String {
        switch key {
        case "subscribers": return channel ? s.t("Подписчики", "Followers") : s.t("Участники", "Members")
        case "dm": return s.t("Личные чаты", "Private chats")
        case "groups": return s.t("Группы", "Groups")
        case "url": return "URL"
        default: return s.t("Другое", "Other")
        }
    }

    private func langName(_ code: String) -> String {
        if code == "other" { return s.t("Неизвестно", "Unknown") }
        let name = Locale(identifier: lang == .ru ? "ru" : "en").localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    var body: some View {
        ScrollView {
            if let stats {
                VStack(alignment: .leading, spacing: 10) {
                    overview(stats)
                    section(s.t("РОСТ", "GROWTH")) {
                        RangeChartCard(dates: stats.growth.map(\.day)) { range in
                            growthChart(stats, range: range, mini: false)
                        } mini: {
                            growthChart(stats, range: nil, mini: true)
                        }
                    }
                    section(channel ? s.t("ПОДПИСЧИКИ", "FOLLOWERS") : s.t("УЧАСТНИКИ", "MEMBERS")) {
                        RangeChartCard(dates: stats.followers.map(\.day)) { range in
                            followersChart(stats, range: range, mini: false)
                        } mini: {
                            followersChart(stats, range: nil, mini: true)
                        } legend: {
                            ChipsFlow {
                                SeriesChip(title: s.t("Подписались", "Joined"), color: .green, on: showJoined) { toggle(&showJoined, other: showLeft) }
                                SeriesChip(title: s.t("Отписались", "Left"), color: .red, on: showLeft) { toggle(&showLeft, other: showJoined) }
                            }
                        }
                    }
                    if channel {
                        section(s.t("ИСТОЧНИКИ ПРОСМОТРОВ", "VIEW SOURCES")) {
                            RangeChartCard(dates: stats.views.map(\.day)) { range in
                                sourcesChart(stats, range: range, mini: false)
                            } mini: {
                                sourcesChart(stats, range: nil, mini: true)
                            } legend: {
                                ChipsFlow {
                                    ForEach(Self.sourceOrder, id: \.self) { key in
                                        SeriesChip(title: sourceName(key), color: Self.sourceColors[key] ?? .gray,
                                                   on: !hiddenSources.contains(key)) { toggleSet(&hiddenSources, key, total: Self.sourceOrder.count) }
                                    }
                                }
                            }
                        }
                    }
                    if !stats.languages.isEmpty {
                        section(s.t("ЯЗЫКИ", "LANGUAGES")) { languagesCard(stats) }
                    }
                    section(s.t("АКТИВНОСТЬ ПО ЧАСАМ", "ACTIVITY BY HOUR")) { hoursCard(stats) }
                    if !stats.posts.isEmpty {
                        section(s.t("ПОСЛЕДНИЕ ПУБЛИКАЦИИ", "RECENT POSTS")) { postsCard(stats) }
                    }
                }
                .padding(16)
                .transition(.opacity)
            } else if failed {
                Text(s.t("Не удалось загрузить статистику", "Couldn't load statistics"))
                    .font(.system(size: 15)).foregroundStyle(theme.textSecondary).padding(.top, 120)
            } else {
                ProgressView().padding(.top, 120)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .animation(.easeOut(duration: 0.25), value: stats == nil)
        .task {
            do { stats = try await session.messengerRepo.stats(groupID: groupID, days: 90) } catch { failed = true }
        }
    }

    /// Хотя бы одна линия на графике остаётся включённой
    private func toggle(_ value: inout Bool, other: Bool) {
        guard !value || other else { Haptics.notify(.warning); return }
        Haptics.select()
        withAnimation(.easeInOut(duration: 0.25)) { value.toggle() }
    }

    private func toggleSet(_ set: inout Set<String>, _ key: String, total: Int) {
        if set.contains(key) { set.remove(key) }
        else if set.count + 1 < total { set.insert(key) }
        else { Haptics.notify(.warning); return }
        Haptics.select()
    }

    // MARK: Общая

    private func overview(_ st: GroupStats) -> some View {
        let delta = st.count - st.countWeekAgo
        let pct = st.countWeekAgo > 0 ? abs(Double(delta)) / Double(st.countWeekAgo) * 100 : 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(s.t("ОБЩАЯ", "OVERVIEW")).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                Spacer()
                Text(Self.rangeText(st.periodStart...st.periodEnd)).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 4)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 14) {
                metric("\(st.count)", channel ? s.t("Подписчики", "Followers") : s.t("Участники", "Members"),
                       delta: delta == 0 ? nil : (delta > 0 ? "+" : "") + "\(delta) (" + String(format: "%.2f%%", pct) + ")", up: delta > 0)
                metric(String(format: "%.2f%%", st.notifyPercent), s.t("Уведомления включены", "Notifications enabled"))
                if channel {
                    metric(Self.short(st.viewsPerPost), s.t("Просмотров на пост", "Views per post"))
                    metric(Self.short(st.sharesPerPost), s.t("Пересылок на пост", "Shares per post"))
                }
                metric(Self.short(st.reactionsPerPost), s.t("Реакций на пост", "Reactions per post"))
            }
            .padding(16)
            .card(theme, radius: 22)
        }
    }

    private func metric(_ value: String, _ label: String, delta: String? = nil, up: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 20, weight: .bold)).foregroundStyle(theme.text)
                if let delta {
                    Text(delta).font(.system(size: 14, weight: .medium)).foregroundStyle(up ? Color.green : Color.red)
                }
            }
            Text(label).font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(2)
        }
    }

    static func short(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.1fK", v / 1000) : (v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v))
    }

    static func rangeText(_ r: ClosedRange<Date>) -> String {
        let f = Date.FormatStyle(date: .abbreviated, time: .omitted)
        return r.lowerBound.formatted(f) + " – " + r.upperBound.formatted(f)
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary).padding(.horizontal, 4)
            content()
        }
        .padding(.top, 14)
    }

    // MARK: Графики

    private func growthChart(_ st: GroupStats, range: ClosedRange<Date>?, mini: Bool) -> some View {
        let points = st.growth.filter { range?.contains($0.day) ?? true }
        let values = points.map(\.count)
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let pad = max(1, (hi - lo) / 8)
        return Chart(points, id: \.day) { p in
            LineMark(x: .value("day", p.day), y: .value("count", p.count))
                .foregroundStyle(Color(red: 0.2, green: 0.5, blue: 1.0))
                .lineStyle(StrokeStyle(lineWidth: mini ? 1.2 : 2.2))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: max(0, lo - pad)...(hi + pad))
        .modifier(StatsAxes(mini: mini))
    }

    private func followersChart(_ st: GroupStats, range: ClosedRange<Date>?, mini: Bool) -> some View {
        let points = st.followers.filter { range?.contains($0.day) ?? true }
        return Chart {
            if showJoined {
                ForEach(points, id: \.day) { p in
                    LineMark(x: .value("day", p.day), y: .value("n", p.joined), series: .value("s", "joined"))
                        .foregroundStyle(Color.green).lineStyle(StrokeStyle(lineWidth: mini ? 1 : 2))
                }
            }
            if showLeft {
                ForEach(points, id: \.day) { p in
                    LineMark(x: .value("day", p.day), y: .value("n", p.left), series: .value("s", "left"))
                        .foregroundStyle(Color.red).lineStyle(StrokeStyle(lineWidth: mini ? 1 : 2))
                }
            }
        }
        .modifier(StatsAxes(mini: mini))
    }

    private func sourcesChart(_ st: GroupStats, range: ClosedRange<Date>?, mini: Bool) -> some View {
        let days = st.views.filter { range?.contains($0.day) ?? true }
        let keys = Self.sourceOrder.filter { !hiddenSources.contains($0) }
        return Chart {
            ForEach(days, id: \.day) { d in
                ForEach(keys, id: \.self) { key in
                    BarMark(x: .value("day", d.day, unit: .day), y: .value("views", d.sources[key] ?? 0))
                        .foregroundStyle(Self.sourceColors[key] ?? .gray)
                }
            }
        }
        .modifier(StatsAxes(mini: mini))
    }

    private func languagesCard(_ st: GroupStats) -> some View {
        let shown = st.languages.filter { !hiddenLangs.contains($0.code) }
        let total = max(1, shown.reduce(0) { $0 + $1.count })
        func label(_ l: GroupStats.LangShare) -> String {
            let pct = Int((Double(l.count) / Double(total) * 100).rounded())
            return pct >= 6 ? "\(pct)%" : ""
        }
        return VStack(spacing: 14) {
            Chart(shown, id: \.code) { item in
                SectorMark(angle: .value("n", item.count), angularInset: 1.5)
                    .foregroundStyle(Self.langColors[item.index % Self.langColors.count])
                    .annotation(position: .overlay) {
                        Text(label(item)).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    }
            }
            .frame(height: 230)
            .animation(.easeInOut(duration: 0.3), value: hiddenLangs)
            ChipsFlow {
                ForEach(st.languages, id: \.code) { l in
                    SeriesChip(title: langName(l.code), color: Self.langColors[l.index % Self.langColors.count],
                               on: !hiddenLangs.contains(l.code)) { toggleSet(&hiddenLangs, l.code, total: st.languages.count) }
                }
            }
        }
        .padding(16)
        .card(theme, radius: 22)
    }

    private func hoursCard(_ st: GroupStats) -> some View {
        // сервер считает часы по UTC — сдвигаем в часовой пояс телефона
        let shift = TimeZone.current.secondsFromGMT() / 3600
        let local = (0..<24).map { h in GroupStats.GrowthPoint(day: Date(timeIntervalSince1970: Double(h)),
                                                               count: st.hours[((h - shift) % 24 + 24) % 24]) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(s.t("Просмотры за 7 дней, по часам", "Views in the last 7 days, by hour")).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            Chart(local, id: \.day) { p in
                BarMark(x: .value("hour", Int(p.day.timeIntervalSince1970)), y: .value("views", p.count))
                    .foregroundStyle(Color(red: 0.2, green: 0.5, blue: 1.0).gradient)
                    .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { _ in AxisValueLabel() }
            }
            .frame(height: 170)
        }
        .padding(16)
        .card(theme, radius: 22)
    }

    private func postsCard(_ st: GroupStats) -> some View {
        VStack(spacing: 0) {
            ForEach(st.posts) { p in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.text.isEmpty ? s.t("Публикация", "Post") : p.text)
                            .font(.system(size: 15)).foregroundStyle(theme.text).lineLimit(1)
                        Text(p.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Label("\(p.views)", systemImage: "eye").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.text)
                        HStack(spacing: 8) {
                            if p.shares > 0 { Label("\(p.shares)", systemImage: "arrowshape.turn.up.right") }
                            if p.reactions > 0 { Label("\(p.reactions)", systemImage: "heart") }
                        }
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                if p.id != st.posts.last?.id { Rectangle().fill(theme.stroke).frame(height: 0.5).padding(.leading, 16) }
            }
        }
        .card(theme, radius: 22)
    }
}

/// Оси графиков статистики: у большого — сетка и подписи, у мини-графика под ним — ничего
private struct StatsAxes: ViewModifier {
    let mini: Bool
    func body(content: Content) -> some View {
        if mini {
            content.chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        } else {
            content
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine(); AxisValueLabel() } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
                .chartLegend(.hidden)
        }
    }
}

/// Карточка графика как в Telegram: сверху период, большой график, под ним мини-график всего периода
/// с окном, которое двигают и растягивают за края
struct RangeChartCard<Main: View, Mini: View, Legend: View>: View {
    let dates: [Date]
    @ViewBuilder var main: (ClosedRange<Date>) -> Main
    @ViewBuilder var mini: () -> Mini
    @ViewBuilder var legend: () -> Legend

    @Environment(\.theme) private var theme
    @State private var lo: CGFloat = 0.6           // доли ширины: по умолчанию — последние ~5 недель
    @State private var hi: CGFloat = 1
    @State private var startLo: CGFloat?
    @State private var startHi: CGFloat?

    private static var minSpan: CGFloat { 0.08 }

    private var first: Date { dates.first ?? Date() }
    private var last: Date { dates.last ?? Date() }
    private func date(_ f: CGFloat) -> Date { first.addingTimeInterval(last.timeIntervalSince(first) * Double(f)) }
    private var range: ClosedRange<Date> { date(lo)...max(date(hi), date(lo).addingTimeInterval(86400)) }

    var body: some View {
        VStack(spacing: 12) {
            Text(GroupStatsView.rangeText(range)).font(.system(size: 15, weight: .bold)).foregroundStyle(theme.text)
                .contentTransition(.numericText())
            main(range).frame(height: 220)
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    mini().frame(height: 44).padding(.vertical, 4)
                    // затемнение вне окна
                    Rectangle().fill(theme.dark ? Color.black.opacity(0.45) : Color.white.opacity(0.6))
                        .frame(width: max(0, lo * w))
                    Rectangle().fill(theme.dark ? Color.black.opacity(0.45) : Color.white.opacity(0.6))
                        .frame(width: max(0, (1 - hi) * w)).offset(x: hi * w)
                    // окно: тянуть за середину — сдвиг, за края — ширина
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.textTertiary, lineWidth: 2)
                        .frame(width: max(24, (hi - lo) * w))
                        .offset(x: lo * w)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                            if startLo == nil { startLo = lo; startHi = hi }
                            let span = (startHi ?? hi) - (startLo ?? lo)
                            let d = v.translation.width / w
                            let nl = min(max(0, (startLo ?? lo) + d), 1 - span)
                            lo = nl; hi = nl + span
                        }.onEnded { _ in startLo = nil; startHi = nil })
                    handle(left: true).offset(x: lo * w - 1)
                        .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                            if startLo == nil { startLo = lo }
                            lo = min(max(0, (startLo ?? lo) + v.translation.width / w), hi - Self.minSpan)
                        }.onEnded { _ in startLo = nil; Haptics.select() })
                    handle(left: false).offset(x: hi * w - 13)
                        .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                            if startHi == nil { startHi = hi }
                            hi = max(min(1, (startHi ?? hi) + v.translation.width / w), lo + Self.minSpan)
                        }.onEnded { _ in startHi = nil; Haptics.select() })
                }
            }
            .frame(height: 52)
            legend()
        }
        .padding(16)
        .card(theme, radius: 22)
    }

    private func handle(left: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(theme.textTertiary)
            .frame(width: 14, height: 52)
            .overlay(Image(systemName: left ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
            .frame(width: 30, height: 52).contentShape(Rectangle())
            .offset(x: left ? -8 : -2)
    }
}

extension RangeChartCard where Legend == EmptyView {
    init(dates: [Date], @ViewBuilder main: @escaping (ClosedRange<Date>) -> Main, @ViewBuilder mini: @escaping () -> Mini) {
        self.init(dates: dates, main: main, mini: mini, legend: { EmptyView() })
    }
}

/// Переключатель линии графика: «✓ Подписались» залит цветом линии, выключенный — только обводка
struct SeriesChip: View {
    let title: String
    let color: Color
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).opacity(on ? 1 : 0)
                    .frame(width: on ? nil : 0)
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(on ? Color.white : color)
            .padding(.horizontal, 14).frame(height: 34)
            .background(Capsule().fill(on ? color : Color.clear))
            .overlay(Capsule().strokeBorder(color, lineWidth: 1.5))
        }
        .buttonStyle(PressStyle())
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: on)
    }
}

/// Чипы переносятся на следующую строку, если не влезают
struct ChipsFlow<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        FlowRows(spacing: 8) { content() }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FlowRows: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
