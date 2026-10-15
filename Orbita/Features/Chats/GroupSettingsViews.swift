import SwiftUI

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
                    GroupSettingsForm(draft: $draft, ownerRights: group.isOwner)

                    if group.isChannel && group.isOwner { DiscussionPicker(selected: $discussion) }

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
                               slow: group.slow, whoWrites: group.whoWrites, history: group.history)
            discussion = group.discussion
        }
        .confirmationDialog(s.t("Удалить для всех? Все сообщения будут стёрты.", "Delete for everyone? All messages will be erased."),
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(s.delete, role: .destructive) { delete() }
            Button(s.cancel, role: .cancel) {}
        }
    }

    private func navRow(_ icon: String, _ title: String, badge: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(theme.accentColor).frame(width: 24)
            Text(title).font(.system(size: 16)).foregroundStyle(theme.text)
            Spacer()
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
