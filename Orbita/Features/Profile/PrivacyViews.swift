import SwiftUI

// MARK: - Конфиденциальность (по образцу Telegram)

struct PrivacyScreen: View {
    @ObservedObject var store: ProfileStore
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var blockedCount = 0
    @State private var errorText: String?

    private var s: Strings { Strings(lang: lang) }
    private var privacy: PrivacySettings { store.profile?.privacy ?? PrivacySettings() }

    /// Строка, как в Telegram: название + значение + шеврон
    private func row(_ key: String, icon: String, tint: Color, pending: Bool = false) -> some View {
        SettingsRow(icon: icon, tint: tint, title: s.visibilityTitle(key),
                    value: s.privacyValue(privacy[key]), showsChevron: true) {
            session.profileRoute = .visibility(key)
        }
    }

    var body: some View {
        VStack(spacing: 22) {
            // Безопасность
            SettingsGroup {
                SettingsRow(icon: "hand.raised.slash.fill", tint: .red, title: s.blacklist,
                            value: s.blockedCount(blockedCount), showsChevron: true) {
                    session.profileRoute = .blacklist
                }
                SettingsDivider()
                SettingsRow(icon: "lock.shield.fill", tint: .teal, title: s.twoFATitle,
                            value: flow.twoFAEnabled ? s.on : s.off, showsChevron: true) {
                    session.privacyOrigin = true
                    session.profileRoute = .twoFA
                }
                SettingsDivider()
                SettingsRow(icon: "envelope.fill", tint: .blue, title: s.loginEmail,
                            value: flow.linkedEmail ?? s.notSet, showsChevron: true) {
                    session.privacyOrigin = true
                    session.profileRoute = .loginEmail
                }
            }

            AppLockSettings()

            // Закрытая стена
            VStack(alignment: .leading, spacing: 8) {
                SettingsGroup {
                    HStack(spacing: 14) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.indigo, in: RoundedRectangle(cornerRadius: 8))
                        Text(s.closedWall).font(.system(size: 16)).foregroundStyle(theme.text)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { privacy.wall == "nobody" },
                            set: { apply("wall", $0 ? "nobody" : "all") }
                        ))
                        .labelsHidden()
                        .tint(theme.accentColor)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                }
                Text(s.closedWallHint)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 30)
            }

            // Лучшие друзья вокруг аватарки
            VStack(alignment: .leading, spacing: 8) {
                SettingsGroup {
                    HStack(spacing: 14) {
                        Image(systemName: "circle.hexagongrid.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 8))
                        Text(s.t("Отображение лучших друзей", "Show best friends")).font(.system(size: 16)).foregroundStyle(theme.text)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { privacy.orbit == "all" },
                            set: { apply("orbit", $0 ? "all" : "nobody") }
                        ))
                        .labelsHidden()
                        .tint(theme.accentColor)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                }
                Text(s.t("Вокруг вашей аватарки будут медленно кружиться аватарки тех, с кем вы общаетесь больше всего. Это видят все, кто открывает ваш профиль.",
                         "The avatars of people you chat with the most will slowly orbit your profile picture. Everyone who opens your profile sees it."))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 30)
            }

            // Кто видит
            VStack(alignment: .leading, spacing: 8) {
                Text(s.whoCanSeeSection.uppercased())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 30)
                SettingsGroup {
                    row("phone", icon: "phone.fill", tint: .green)
                    SettingsDivider()
                    row("find", icon: "magnifyingglass", tint: .teal)
                    SettingsDivider()
                    row("followers", icon: "person.2.fill", tint: .mint)
                    SettingsDivider()
                    row("last_seen", icon: "clock.fill", tint: .orange)
                    SettingsDivider()
                    row("photos", icon: "photo.fill", tint: .pink)
                    SettingsDivider()
                    row("bio", icon: "text.alignleft", tint: .indigo)
                    SettingsDivider()
                    row("birthday", icon: "gift.fill", tint: .purple)
                    SettingsDivider()
                    row("music", icon: "music.note", tint: .red)
                    SettingsDivider()
                    row("comments", icon: "bubble.right.fill", tint: .blue)
                    SettingsDivider()
                    row("calls", icon: "phone.arrow.up.right.fill", tint: .gray)
                    SettingsDivider()
                    row("forwards", icon: "arrowshape.turn.up.right.fill", tint: .gray)
                    SettingsDivider()
                    row("invites", icon: "person.badge.plus", tint: .gray)
                }
            }

            if let errorText {
                Text(errorText).font(.system(size: 13)).foregroundStyle(theme.danger)
            }
        }
        .task {
            blockedCount = (try? await session.socialRepo.blocks().count) ?? 0
        }
    }

    private func apply(_ key: String, _ value: String) {
        errorText = nil
        var patch = ProfilePatch(privacy: [key: value])
        if key == "phone", value != "nobody" { patch.phone = flow.e164 }
        Task { @MainActor in
            if let error = await store.update(patch) { errorText = s.api(error) }
        }
    }
}

// MARK: - Один параметр: «Все / Никто»

struct VisibilityScreen: View {
    let key: String
    @ObservedObject var store: ProfileStore
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var errorText: String?

    private var s: Strings { Strings(lang: lang) }
    private var isStub: Bool { ["calls", "forwards", "invites"].contains(key) }
    /// «Только контактам» — везде, кроме поиска по номеру
    private var choices: [(String, String)] {
        (key == "find" || key == "followers") ? [("all", s.visibleAll), ("nobody", s.visibleNone)]
                      : [("all", s.visibleAll), ("contacts", s.visibleContacts), ("nobody", s.visibleNone)]
    }

    var body: some View {
        VStack(spacing: 14) {
            ChoiceGroup(title: s.visibilityTitle(key), footer: s.visibilityHint(key) + (key == "find" ? "" : "\n" + s.t("«Мои контакты» — только люди, которых вы сохранили в контактах.", "“My contacts” — only people you saved as contacts.")),
                        options: choices,
                        current: (store.profile?.privacy ?? PrivacySettings())[key]) { value in
                errorText = nil
                var patch = ProfilePatch(privacy: [key: value])
                if key == "phone", value != "nobody" { patch.phone = flow.e164 }
                Task { @MainActor in
                    if let error = await store.update(patch) { errorText = s.api(error) }
                }
            }
            if let errorText {
                Text(errorText).font(.system(size: 13)).foregroundStyle(theme.danger)
            }
        }
    }
}

// MARK: - Чёрный список

struct BlacklistScreen: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var users: [BlockedUser] = []
    @State private var loaded = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if users.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "hand.raised.slash")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(theme.textSecondary)
                    Text(loaded ? s.blacklistEmpty : "")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(theme.text)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 50)
            } else {
                SettingsGroup {
                    ForEach(Array(users.enumerated()), id: \.element.id) { index, user in
                        HStack(spacing: 12) {
                            AvatarView(name: user.name, size: 40, avatarID: user.avatarID)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(user.name).font(.system(size: 16)).foregroundStyle(theme.text)
                                if let username = user.username {
                                    Text("@" + username).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                                }
                            }
                            Spacer()
                            Button(s.unblockUser) { Task { await unblock(user) } }
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(theme.accentColor)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 60)
                        if index < users.count - 1 { SettingsDivider().padding(.leading, 66) }
                    }
                }
            }
            Text(s.blacklistHint)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 30)
        }
        .task {
            users = (try? await session.socialRepo.blocks()) ?? []
            loaded = true
        }
    }

    private func unblock(_ user: BlockedUser) async {
        try? await session.socialRepo.setBlocked(userID: user.id, blocked: false)
        users.removeAll { $0.id == user.id }
        await session.feed.load()
    }
}

// MARK: - Почта для входа

struct LoginEmailScreen: View {
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var draft = ""
    @State private var code = ""
    @State private var sent = false
    @State private var doneMessage = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 16) {
            SettingsGroup {
                SettingsRow(icon: "envelope.fill", tint: .blue, title: s.emailLabel,
                            value: flow.linkedEmail ?? s.notSet)
            }

            if sent {
                InputField(placeholder: s.codeFromEmail, text: $code, icon: "number", keyboard: .numberPad)
                    .padding(.horizontal, 16)
                PrimaryButton(title: s.confirm, enabled: code.filter(\.isNumber).count >= 6, loading: flow.isLoading) {
                    Task { @MainActor in
                        if await flow.confirmLoginEmail(String(code.filter(\.isNumber))) {
                            sent = false; code = ""; draft = ""; doneMessage = true
                        }
                    }
                }
                TextActionButton(title: s.cancel) {
                    flow.cancelLoginEmail()
                    sent = false; code = ""
                }
            } else {
                InputField(placeholder: s.emailPlaceholder, text: $draft, icon: "envelope", email: true)
                    .padding(.horizontal, 16)
                PrimaryButton(title: flow.linkedEmail == nil ? s.linkEmail : s.loginEmailChange,
                              enabled: Validator.isValidEmail(Validator.normalizeEmail(draft)), loading: flow.isLoading) {
                    doneMessage = false
                    Task { @MainActor in
                        if await flow.requestLoginEmail(draft) { sent = true }
                    }
                }
            }

            ErrorText(error: flow.error)

            if doneMessage {
                Label(s.emailLinked, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.green)
            }

            Text(s.loginEmailHint)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
