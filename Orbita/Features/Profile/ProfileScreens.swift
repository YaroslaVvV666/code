import SwiftUI

// MARK: - Контейнер подэкрана (своя шапка со стрелкой «назад»)

struct ProfileSubScreen: View {
    let route: ProfileRoute
    @ObservedObject var store: ProfileStore
    let back: () -> Void

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    private var s: Strings { Strings(lang: lang) }

    private var title: String {
        switch route {
        case .name:       return s.myName
        case .username:   return s.usernameLabel
        case .bio:        return s.bioLabel
        case .privacy:    return s.privacy
        case .appearance: return s.appearance
        case .language:   return s.languageTitle
        case .data:       return s.dataAndStorage
        case .server:     return s.serverLabel
        case .twoFA:      return s.twoFATitle
        case .devices:    return s.devices
        case .wall:       return s.myPage
        case .blacklist:  return s.blacklist
        case .loginEmail: return s.loginEmail
        case .style:      return s.t("Цвет профиля", "Profile color")
        case .interests:  return s.t("Интересы", "Interests")
        case .visibility(let key): return s.visibilityTitle(key)
        }
    }

    /// Экран, на который вернёт стрелка «назад» (nil — в профиль)
    private var parent: ProfileRoute? {
        switch route {
        case .blacklist, .visibility: return .privacy
        case .twoFA, .loginEmail: return session.privacyOrigin ? .privacy : nil
        default: return nil
        }
    }

    private var isWall: Bool { if case .wall = route { return true } else { return false } }

    /// «Моя страница»: цветная шапка уходит под самый верх экрана (как во вкладке «Профиль»),
    /// а стрелка «назад» просто лежит поверх — без отдельной тёмной плашки
    private var wallBody: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                content.padding(.top, TopInset.value).padding(.bottom, 24)
            }
            .coordinateSpace(name: "pageScroll")
            .scrollBounceBehavior(.basedOnSize)
            .ignoresSafeArea(edges: .top)                 // цвет профиля доходит до самого верха, без тёмной полосы
            .environment(\.pageTopInset, TopInset.value)

            Button {
                if let parent { session.profileRoute = parent } else { back() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .frame(width: 36, height: 36)
                    .glassCircle(interactive: false)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .padding(.leading, 10).padding(.top, 2)
        }
        .edgeSwipeBack { if let parent { session.profileRoute = parent } else { back() } }
    }

    var body: some View {
        if isWall { wallBody } else { regularBody }
    }

    private var regularBody: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    if let parent { session.profileRoute = parent } else { back() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .frame(width: 36, height: 36)
                        .card(theme, radius: 18)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())

                Spacer()
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer()
                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)

            ScrollView {
                content
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
            .coordinateSpace(name: "pageScroll")
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .edgeSwipeBack { if let parent { session.profileRoute = parent } else { back() } }
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .name:       EditFieldScreen(kind: .name, store: store, back: back)
        case .username:   EditFieldScreen(kind: .username, store: store, back: back)
        case .bio:        EditFieldScreen(kind: .bio, store: store, back: back)
        case .privacy:    PrivacyScreen(store: store)
        case .appearance: AppearanceScreen()
        case .language:   LanguageScreen()
        case .data:       DataScreen()
        case .server:     ServerScreen(back: back)
        case .twoFA:      TwoFAScreen()
        case .devices:    DevicesScreen(store: session.devices)
        case .wall:       UserPageView(source: .me, session: session)
        case .blacklist:  BlacklistScreen()
        case .loginEmail: LoginEmailScreen()
        case .style:      ProfileStyleScreen(store: store, back: back)
        case .interests:  InterestsScreen()
        case .visibility(let key): VisibilityScreen(key: key, store: store)
        }
    }
}

// MARK: - Имя, @username, «О себе»

struct EditFieldScreen: View {
    enum Kind { case name, username, bio }

    let kind: Kind
    @ObservedObject var store: ProfileStore
    let back: () -> Void

    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var text = ""
    @State private var status: UsernameStatus = .unknown
    @State private var saving = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private var s: Strings { Strings(lang: lang) }

    private var original: String {
        switch kind {
        case .name:     return store.profile?.name ?? flow.userName
        case .username: return store.profile?.username ?? ""
        case .bio:      return store.profile?.bio ?? ""
        }
    }

    private var current: String {
        kind == .name ? Validator.normalizeName(text) : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        guard current != original, !saving else { return false }
        switch kind {
        case .name:     return Validator.isValidName(current)
        case .username: return current.isEmpty || status == .available
        case .bio:      return current.count <= 70
        }
    }

    private static func usernameLooksValid(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z][A-Za-z0-9_]{4,31}$", options: .regularExpression) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if kind == .username {
                    Text("@").font(.system(size: 17, weight: .medium)).foregroundStyle(theme.textSecondary)
                }
                if kind == .bio {
                    TextField(s.bioLabel, text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focused)
                } else {
                    TextField(kind == .name ? s.namePlaceholder : "username", text: $text)
                        .focused($focused)
                        .textInputAutocapitalization(kind == .username ? .never : .words)
                        .autocorrectionDisabled()
                }
            }
            .font(.system(size: 17))
            .foregroundStyle(theme.text)
            .tint(theme.accentColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .card(theme, radius: 14)
            .padding(.horizontal, 16)

            Group {
                switch kind {
                case .name:
                    Text(s.nameHint)
                case .username:
                    switch status {
                    case .available: Text(s.usernameFree).foregroundStyle(Color.green)
                    case .taken:     Text(s.usernameTaken).foregroundStyle(theme.danger)
                    case .invalid:   Text(s.usernameBad).foregroundStyle(theme.danger)
                    case .unknown:   Text(s.usernameHint)
                    }
                case .bio:
                    HStack { Text(s.bioHint); Spacer(); Text("\(text.count)/70").monospacedDigit() }
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 28)

            if let errorText {
                Text(errorText).font(.system(size: 13)).foregroundStyle(theme.danger).padding(.horizontal, 28)
            }

            PrimaryButton(title: s.save, enabled: canSave, loading: saving, action: save)
                .padding(.top, 10)
        }
        .onAppear {
            text = original
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true }
        }
        .onChange(of: text) { _, new in
            errorText = nil
            if kind == .username {
                let filtered = String(new.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }.prefix(32))
                if filtered != new { text = filtered }
                status = .unknown
            }
        }
        .task(id: text) {
            guard kind == .username, !text.isEmpty, text != original else { return }
            if !Self.usernameLooksValid(text) { status = .invalid; return }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            status = await store.usernameStatus(text)
        }
    }

    private func save() {
        saving = true
        errorText = nil
        Task { @MainActor in
            defer { saving = false }
            let value = current
            let error: APIError?
            switch kind {
            case .name:
                error = await store.update(ProfilePatch(name: value))
                if error == nil { _ = await flow.saveName(value) }      // и в локальной базе
            case .username:
                error = await store.update(ProfilePatch(username: value))
            case .bio:
                error = await store.update(ProfilePatch(bio: value))
            }
            if let error { errorText = s.api(error) } else { back() }
        }
    }
}

// MARK: - Выбор из вариантов (с галочкой)

struct ChoiceGroup: View {
    let title: String
    var footer: String? = nil
    let options: [(value: String, label: String)]
    let current: String
    let onSelect: (String) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 30)

            SettingsGroup {
                ForEach(Array(options.enumerated()), id: \.offset) { item in
                    Button { onSelect(item.element.value) } label: {
                        HStack {
                            Text(item.element.label).font(.system(size: 16)).foregroundStyle(theme.text)
                            Spacer()
                            if item.element.value == current {
                                Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(theme.accentColor)
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    if item.offset < options.count - 1 { SettingsDivider().padding(.leading, 16) }
                }
            }

            if let footer {
                Text(footer)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 30)
            }
        }
    }
}

// MARK: - Конфиденциальность

// MARK: - Оформление

struct AppearanceScreen: View {
    @AppStorage("isDark") private var isDark = true
    @AppStorage("accent") private var accent = 0
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup {
                HStack(spacing: 14) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 30, height: 30)
                        .background(Color.indigo, in: RoundedRectangle(cornerRadius: 8))
                    Text(s.themeLabel).font(.system(size: 16)).foregroundStyle(theme.text)
                    Spacer()
                    ThemeToggle(isDark: $isDark)
                }
                .padding(.horizontal, 14)
                .frame(height: 56)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(s.accentColor.uppercased())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 30)

                HStack(spacing: 14) {
                    ForEach(0..<Theme.accents.count, id: \.self) { index in
                        Button {
                            Haptics.select()
                            withAnimation(.easeInOut(duration: 0.25)) { accent = index }
                        } label: {
                            Circle()
                                .fill(Theme.swatch(index))
                                .frame(width: 42, height: 42)
                                .overlay {
                                    if accent == index {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundStyle(Color.white)
                                    }
                                }
                                .overlay(Circle().stroke(theme.stroke, lineWidth: 1))
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }
}

// MARK: - Язык

struct LanguageScreen: View {
    @EnvironmentObject private var flow: AuthFlow
    @AppStorage("lang") private var langRaw = AppLanguage.ru.rawValue
    @Environment(\.lang) private var lang

    var body: some View {
        ChoiceGroup(title: Strings(lang: lang).languageTitle,
                    options: flow.availableLanguages.map { ($0.code, $0.nativeName) },
                    current: langRaw) { langRaw = $0 }
    }
}

// MARK: - Данные и память

struct DataScreen: View {
    @AppStorage("autoplay") private var autoplay = true
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var cacheBytes = URLCache.shared.currentDiskUsage
    @State private var clearing = false
    @State private var freedBytes = 0

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsGroup {
                    HStack(spacing: 14) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 30, height: 30)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 8))
                        Text(s.autoplayVideo).font(.system(size: 16)).foregroundStyle(theme.text)
                        Spacer()
                        Toggle("", isOn: $autoplay).labelsHidden().tint(theme.accentColor)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 56)
                }
                Text(s.autoplayHint)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 30)
            }

            SettingsGroup {
                SettingsRow(icon: "photo.stack.fill", tint: .teal, title: s.cacheSize,
                            value: ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file))
                SettingsDivider()
                Button {
                    freedBytes = URLCache.shared.currentDiskUsage
                    URLCache.shared.removeAllCachedResponses()
                    cacheBytes = URLCache.shared.currentDiskUsage
                    Haptics.impact(.soft)
                    clearing = true
                } label: {
                    Text(s.clearCache)
                        .font(.system(size: 16))
                        .foregroundStyle(theme.danger)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
        }
        .fullScreenCover(isPresented: $clearing) {
            CacheClearView(freedBytes: freedBytes) { clearing = false }
                .preferredColorScheme(theme.dark ? .dark : .light)
        }
    }
}

// MARK: - Сервер

struct ServerScreen: View {
    let back: () -> Void

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    enum Check: Equatable { case idle, checking, ok, failed }

    @State private var address = ServerConfig.urlString
    @State private var check: Check = .idle

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(s.serverAddress.uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 30)

            TextField("http://192.168.1.20:8080", text: $address)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 17))
                .foregroundStyle(theme.text)
                .tint(theme.accentColor)
                .padding(.horizontal, 16)
                .frame(height: 54)
                .card(theme, radius: 14)
                .padding(.horizontal, 16)

            Group {
                switch check {
                case .idle:     Text(s.serverHint)
                case .checking: Text(s.checking)
                case .ok:       Text(s.connectionOK).foregroundStyle(Color.green)
                case .failed:   Text(s.connectionFail).foregroundStyle(theme.danger)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 28)

            TextActionButton(title: s.checkConnection, action: test)
                .padding(.horizontal, 24)

            PrimaryButton(title: s.save, enabled: ServerConfig.url(from: address) != nil, action: save)
                .padding(.top, 6)
        }
        .onChange(of: address) { _, _ in check = .idle }
    }

    private func test() {
        guard let url = ServerConfig.url(from: address) else { check = .failed; return }
        check = .checking
        Task { @MainActor in check = await ServerAPI.ping(url) ? .ok : .failed }
    }

    private func save() {
        ServerConfig.urlString = address
        Task { @MainActor in
            await session.reloadAll()
            back()
        }
    }
}

// MARK: - Двухфакторная защита

struct TwoFAScreen: View {
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    enum Mode { case menu, change, disable }

    @State private var mode: Mode = .menu
    @State private var current = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var hint = ""

    private var s: Strings { Strings(lang: lang) }
    private var level: Int { password.isEmpty ? 0 : max(1, Validator.passwordStrength(password)) }

    private func currentHintBlock() -> some View {
        VStack(spacing: 6) {
            Label(flow.twoFAHint.map { s.t("Подсказка: ", "Hint: ") + $0 }
                  ?? s.t("Подсказка не задавалась", "No hint was set"), systemImage: "lightbulb")
                .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            if !flow.twoFAEnabled {
                intro(s.twoFASub)
                newPasswordFields
                PrimaryButton(title: s.enable, enabled: !password.isEmpty && !confirm.isEmpty, loading: flow.isLoading) {
                    Task { @MainActor in
                        if await flow.savePassword(password, confirm: confirm, hint: hint) { reset() }
                    }
                }
            } else {
                switch mode {
                case .menu:
                    intro(s.twoFAOnHint)
                    SettingsGroup {
                        SettingsRow(icon: "key.fill", tint: .teal, title: s.changePassword, showsChevron: true) {
                            flow.error = nil; mode = .change
                        }
                        SettingsDivider()
                        SettingsRow(icon: "lock.open.fill", tint: .red, title: s.disable, showsChevron: true) {
                            flow.error = nil; mode = .disable
                        }
                    }
                case .change:
                    intro(s.t("Чтобы сменить пароль, введите прежний и новый.", "To change it, enter the old and the new password."))
                    currentHintBlock()
                    InputField(placeholder: s.twoFACurrent, text: $current, icon: "key", secure: true)
                    newPasswordFields
                    PrimaryButton(title: s.savePassword,
                                  enabled: !current.isEmpty && !password.isEmpty && !confirm.isEmpty,
                                  loading: flow.isLoading) {
                        Task { @MainActor in
                            if await flow.changeTwoFA(current: current, new: password, confirm: confirm, hint: hint) { reset() }
                        }
                    }
                case .disable:
                    intro(s.twoFADisableHint)
                    currentHintBlock()
                    InputField(placeholder: s.twoFACurrent, text: $current, icon: "key", secure: true)
                    PrimaryButton(title: s.disable, enabled: !current.isEmpty, loading: flow.isLoading) {
                        Task { @MainActor in
                            if await flow.disableTwoFA(current: current) { reset() }
                        }
                    }
                }
            }

            ErrorText(error: flow.error)
        }
        .task { await flow.refreshTwoFAHint() }
        .onChange(of: current) { _, _ in flow.error = nil }
        .onChange(of: password) { _, _ in flow.error = nil }
        .onChange(of: confirm) { _, _ in flow.error = nil }
    }

    private var newPasswordFields: some View {
        VStack(spacing: 12) {
            InputField(placeholder: s.twoFANew, text: $password, icon: "key", secure: true)
            InputField(placeholder: s.passRepeat, text: $confirm, icon: "checkmark.shield", secure: true)
            InputField(placeholder: s.t("Подсказка к паролю (необязательно)", "Password hint (optional)"),
                       text: $hint, icon: "lightbulb")
            if !password.isEmpty {
                VStack(spacing: 6) {
                    StrengthMeter(level: level)
                    Text(s.strength(level)).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private func intro(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(theme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
    }

    private func reset() {
        current = ""; password = ""; confirm = ""; hint = ""
        mode = .menu
    }
}
