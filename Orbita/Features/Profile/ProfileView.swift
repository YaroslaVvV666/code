import SwiftUI
import PhotosUI

// MARK: - Раздел-заглушка (Чаты, Сообщества)

struct ComingSoonView: View {
    let icon: String
    let title: String
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.accentColor)
                .frame(width: 84, height: 84)
                .card(theme, radius: 42)
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.text)
            Text(Strings(lang: lang).soonSub)
                .font(.system(size: 15))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Профиль (как в Telegram)

struct ProfileView: View {
    @ObservedObject var store: ProfileStore
    @Binding var route: ProfileRoute?

    @EnvironmentObject private var flow: AuthFlow
    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @AppStorage("lang") private var langRaw = AppLanguage.ru.rawValue

    @State private var confirmDelete = false
    @State private var scrollY: CGFloat = 0
    @State private var probeY: CGFloat = 0
    // положение аватарки и имени (экранные y) и место, куда имя «пристыковывается» в панели
    @State private var avatarTopLive: CGFloat = 0
    @State private var avatarTopRest: CGFloat = 0
    @State private var nameMidLive: CGFloat = 0
    @State private var nameMidRest: CGFloat = 0
    @State private var dockMid: CGFloat = 0
    @State private var pullArmed = true
    @State private var pullAmount: CGFloat = 0
    @State private var rawOffset: CGFloat = 0          // насколько прокручено: вверх — плюс, потянули вниз — минус
    /// Ступень шапки: 0 — кружок, 1 — фото на всю ширину, 2 — фото на весь экран
    @State private var pullStage = 0
    @State private var showEdit = false
    @State private var showStatus = false
    @State private var showQR = false
    @State private var showImport = false
    @State private var showPlaylist = false
    @State private var musicModel: UserPageModel?
    @AppStorage(Haptics.key) private var haptics = true
    @State private var pageIndex = 0
    @State private var stageForward = true
    @State private var viewer: AvatarViewerRoute?

    private var s: Strings { Strings(lang: lang) }
    private var name: String { store.profile?.name ?? flow.userName }
    private var shownName: String { store.profile?.displayName ?? flow.userName }
    private var photos: [AvatarPhoto] { store.profile?.avatars ?? [] }

    private var usernameText: String {
        if let username = store.profile?.username, !username.isEmpty { return "@" + username }
        return s.notSet
    }

    private var bioText: String {
        if let bio = store.profile?.bio, !bio.isEmpty { return bio }
        return s.notSet
    }

    private var languageName: String {
        flow.availableLanguages.first { $0.code == langRaw }?.nativeName ?? langRaw
    }

    private var serverHost: String {
        ServerConfig.baseURL?.host ?? s.notSet
    }

    private var subtitle: String {
        if let username = store.profile?.username, !username.isEmpty {
            return flow.displayPhone + "  •  @" + username
        }
        return flow.displayPhone
    }

    var body: some View {
        ZStack {
            if let route {
                ProfileSubScreen(route: route, store: store) { self.route = nil }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                main.transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.28), value: route)
    }

    private func openPlaylist() {
        let m = UserPageModel(source: .me, session: session)
        musicModel = m
        showPlaylist = true
        Task { await m.load() }
    }

    private var main: some View {
        let inset = TopInset.value
        let bar = inset + 58                                      // высота свёрнутой шапки
        return ZStack(alignment: .top) {
            // цвет идёт от самого верха экрана (под статус-баром); при прокрутке сжимается в плашку
            ProfileBackdrop(color: store.profile?.styleColor, emoji: store.profile?.styleEmoji,
                            height: max(bar, 400 + inset - max(-scrollY, probeY)))
                .offset(y: -inset)
            mainScroll
            if !photos.isEmpty { avatarStage }
            // плашка поверх содержимого: прокручиваемое уходит «под потолок»
            Rectangle().fill(.thinMaterial)
            .frame(height: bar)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.45), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))   // без цвета, размытие сходит на нет книзу
            .offset(y: -inset)
            .opacity(Double(min(1, max(0, (collapse - 0.55) / 0.3))))
            .overlay {
                // плашка «съедает» нажатия: кнопки, которые сейчас под размытием, не срабатывают
                Color.clear.contentShape(Rectangle()).onTapGesture {}
                    .allowsHitTesting(collapse > 0.6)
            }
            // аватарка и капля островка: поверх страницы и плашки, в одном слое и по одной геометрии
            if !photos.isEmpty { collapsingAvatar(inset: inset) }
            pinnedBar
            floatingName
        }
        .onPreferenceChange(ScrollTopKey.self) { scrollY = $0 }
        .onPreferenceChange(AvatarTopKey.self) { v in
            avatarTopLive = v
            if scrollOffset <= 0.5, pullStage == 0 { avatarTopRest = v }
        }
    }

    private func setStage(_ n: Int) {
        guard pullStage != n else { return }
        if n == 0 || (pullStage == 0 && n >= 1) { stageForward = false }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.84)) {
            pullStage = n
            if n == 0 { pageIndex = 0 }
        }
    }

    private func stepPhoto(_ delta: Int) {
        guard photos.count > 1 else { return }
        let next = max(0, min(photos.count - 1, pageIndex + delta))
        guard next != pageIndex else { return }
        Haptics.select()
        stageForward = delta > 0
        withAnimation(.easeInOut(duration: 0.28)) { pageIndex = next }
    }

    private func stageDrag(_ dy: CGFloat) {
        if pullStage == 1 {
            if dy > 50 { Haptics.impact(.medium); setStage(2) } else if dy < -50 { setStage(0) }
        } else if pullStage == 2, abs(dy) > 60 {
            setStage(1)
        }
    }

    /// Фото, выросшее из кружка аватарки (как в Telegram)
    private var avatarStage: some View {
        let inset: CGFloat = TopInset.value
        let raw: CGFloat = rawOffset
        return ScreenSpace { screen, origin in
            AvatarStage(expand: CGFloat(pullStage), circleTop: origin.y + 82 - raw, screen: screen,
                        headerHeight: screen.width * 0.96, topInset: inset,
                        photos: photos, page: pageIndex, forward: stageForward,
                        name: shownName.isEmpty ? s.you : shownName, status: subtitle,
                        onStep: { stepPhoto($0) },
                        onCenter: { setStage(pullStage == 1 ? 2 : 1) },
                        onVertical: { stageDrag($0) })
        }
        .allowsHitTesting(pullStage >= 1)
    }

    private var scrollOffset: CGFloat { max(0, max(-scrollY, probeY)) }

    private func smooth(_ x: CGFloat) -> CGFloat {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    private var avatarScale: CGFloat {
        let c: CGFloat = collapse
        let grow: CGFloat = 1 + 0.32 * min(1, pullAmount / 62)               // тянем — кружок растёт вместе с пальцем
        return grow * (1 - 0.75 * c * c)
    }

    /// Аватарка сворачивается в островок (как в Telegram): уменьшается, повисает на капле островка,
    /// чернеет сверху от места срастания и втекает в островок. Фото и капля — по одной геометрии `AvatarCollapse`.
    private func collapsingAvatar(inset: CGFloat) -> some View {
        let island: Bool = inset >= 51                                   // острова нет — просто растворяемся
        let raw: CGFloat = rawOffset
        let pull: CGFloat = pullAmount
        let photoID: String? = photos.first?.mediaID
        let label: String = name
        let ring: Color = theme.stroke
        return ScreenSpace { screen, origin in
            CollapsingAvatarLayer(raw: raw, restTop: origin.y + 82, screen: screen, pull: pull,
                                  island: island, name: label, photoID: photoID, ring: ring)
        }
        .opacity(pullStage >= 1 ? 0 : 1)                                 // вместо кружка рисует AvatarStage
        .allowsHitTesting(false)
    }

    /// 0 — шапка раскрыта, 1 — свёрнута (после ~150 pt прокрутки)
    private var collapse: CGFloat { max(0, min(1, max(rawOffset, max(-scrollY, probeY)) / 150)) }

    /// «Изм.», QR и ник остаются наверху при прокрутке; ник появляется, когда крупный уходит
    private var pinnedBar: some View {
        topBar
            .padding(.top, 8)
    }

    /// Ник: едет со страницей, но не выше низа аватарки — пока она висит под островком, ник держится под ней;
    /// аватарка втянулась — ник встаёт в панель между «Изм.» и QR. Всё считается от прокрутки, без замеров и теней.
    private var floatingName: some View {
        let raw: CGFloat = rawOffset
        let pull: CGFloat = pullAmount
        let follow: Bool = !photos.isEmpty                          // аватарку с фото рисует collapsingAvatar
        let ink: Color = ProfilePalette.ink(store.profile?.styleColor, fallback: theme.text)
        let label: String = shownName.isEmpty ? s.you : shownName
        return ScreenSpace { screen, origin in
            Self.nameLabel(label, ink: ink, raw: raw, pull: pull, origin: origin, screen: screen, follow: follow)
        }
        .opacity(pullStage == 0 ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: pullStage)
        .allowsHitTesting(false)
    }

    private static let nameRestY: CGFloat = 218                     // центр ника в покое (в координатах этого экрана)
    private static let nameDockY: CGFloat = 29                      // центр панели с кнопками «Изм.» и QR

    private static func nameLabel(_ label: String, ink: Color, raw: CGFloat, pull: CGFloat,
                                  origin: CGPoint, screen: CGSize, follow: Bool) -> some View {
        let y: CGFloat = nameCenter(raw: raw, pull: pull, origin: origin, screen: screen, follow: follow)
        let travel: CGFloat = min(1, max(0, (nameRestY - y) / (nameRestY - nameDockY)))
        let eased: CGFloat = AvatarCollapse.smooth(travel)
        let scale: CGFloat = 1 + 0.53 * (1 - eased)                 // 26 pt в шапке → 17 pt в панели
        return Text(label)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(ink)
            .lineLimit(1)
            .frame(maxWidth: 220)
            .scaleEffect(scale)
            .frame(width: screen.width, height: 32)
            .position(x: screen.width / 2, y: origin.y + y)
    }

    /// Центр ника (в координатах экрана профиля)
    private static func nameCenter(raw: CGFloat, pull: CGFloat, origin: CGPoint, screen: CGSize, follow: Bool) -> CGFloat {
        // свободный путь: до `a` ровно со страницей (и вниз, когда тянут), потом плавно разгоняется к панели
        let a: CGFloat = 50
        let b: CGFloat = AvatarCollapse.travel * 0.96                // к этому моменту капля уже почти вся в островке
        let free: CGFloat
        if raw <= a {
            free = nameRestY - raw
        } else if raw >= b {
            free = nameDockY
        } else {
            free = nameGlide(t: (raw - a) / (b - a), from: nameRestY - a, to: nameDockY, length: b - a)
        }
        guard follow else { return free }
        // не выше низа аватарки: в покое ровно на своём месте, дальше — с запасом 24 pt до центра строки
        let g = AvatarCollapse(raw: raw, restTop: origin.y + 82, screenWidth: screen.width, pull: pull)
        let bottom: CGFloat = g.center.y + g.diameter / 2 - origin.y
        let ease: CGFloat = 12 * (1 - AvatarCollapse.smooth(g.c / 0.15))   // в покое ограничение не трогает ник
        let below: CGFloat = bottom + 24 - ease
        return max(nameDockY, AvatarCollapse.smoothMax(free, below, k: 10))
    }

    /// Кривая Эрмита: стартует со скоростью страницы, к панели подходит медленнее (без рывка при остановке)
    private static func nameGlide(t: CGFloat, from p0: CGFloat, to p1: CGFloat, length: CGFloat) -> CGFloat {
        let t2: CGFloat = t * t
        let t3: CGFloat = t2 * t
        let h00: CGFloat = 2 * t3 - 3 * t2 + 1
        let h10: CGFloat = t3 - 2 * t2 + t
        let h01: CGFloat = -2 * t3 + 3 * t2
        let h11: CGFloat = t3 - t2
        let startSpeed: CGFloat = -1                               // pt ника на pt прокрутки
        let endSpeed: CGFloat = -0.4
        return h00 * p0 + h10 * length * startSpeed + h01 * p1 + h11 * length * endSpeed
    }

    private var mainScroll: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 16) {
                Color.clear.frame(height: 0).id("profileTop")
                Color.clear.frame(height: 42)                      // место под закреплённую панель
                header

                SettingsGroup {
                    SettingsRow(icon: "person.text.rectangle.fill", tint: .blue, title: s.myPage,
                                value: store.profile?.postsCount.map(String.init), showsChevron: true) { route = .wall }
                    SettingsDivider()
                    SettingsRow(icon: "face.smiling.fill", tint: .yellow, title: s.t("Эмодзи-статус", "Emoji status"),
                                value: store.profile?.statusEmoji ?? s.t("Нет", "None"), showsChevron: true) { showStatus = true }
                }

                SettingsGroup {
                    SettingsRow(icon: "paintpalette.fill", tint: .pink, title: s.t("Изменить цвет профиля", "Profile color"),
                                showsChevron: true) { route = .style }
                    SettingsDivider()
                    SettingsRow(icon: "person.2.wave.2.fill", tint: .teal, title: s.t("Найти друзей из контактов", "Find friends from contacts"),
                                showsChevron: true) { showImport = true }
                }

                SettingsGroup {
                    SettingsRow(icon: "phone.fill", tint: .green, title: s.phoneLabel, value: flow.displayPhone)
                    SettingsDivider()
                    SettingsRow(icon: "at", tint: .blue, title: s.usernameLabel, value: usernameText,
                                showsChevron: true) { route = .username }
                    SettingsDivider()
                    SettingsRow(icon: "person.fill", tint: .indigo, title: s.myName, value: name,
                                showsChevron: true) { showEdit = true }
                    SettingsDivider()
                    SettingsRow(icon: "text.alignleft", tint: .orange, title: s.bioLabel, value: bioText,
                                showsChevron: true) { route = .bio }
                }

                SettingsGroup {
                    SettingsRow(icon: "sparkles", tint: .pink, title: s.t("Интересы", "Interests"),
                                value: InterestsStore.load(session.userID).isEmpty ? s.t("Не выбраны", "None")
                                    : "\(InterestsStore.load(session.userID).count)",
                                showsChevron: true) { route = .interests }
                    SettingsDivider()
                    SettingsRow(icon: "envelope.fill", tint: .blue, title: s.loginEmail,
                                value: flow.linkedEmail ?? s.t("Не привязана", "Not linked"),
                                showsChevron: true) {
                        session.privacyOrigin = false
                        route = .loginEmail
                    }
                    SettingsDivider()
                    SettingsRow(icon: "laptopcomputer.and.iphone", tint: .orange, title: s.devices,
                                showsChevron: true) { route = .devices }
                    SettingsDivider()
                    SettingsRow(icon: "hand.raised.fill", tint: .gray, title: s.privacy,
                                showsChevron: true) { route = .privacy }
                    SettingsDivider()
                    SettingsRow(icon: "lock.shield.fill", tint: .teal, title: s.twoFATitle,
                                value: flow.twoFAEnabled ? s.on : s.off, showsChevron: true) {
                        session.privacyOrigin = false
                        route = .twoFA
                    }
                    SettingsDivider()
                    SettingsRow(icon: "externaldrive.fill", tint: .green, title: s.dataAndStorage,
                                showsChevron: true) { route = .data }
                }

                SettingsGroup {
                    SettingsRow(icon: "paintbrush.fill", tint: .pink, title: s.appearance,
                                showsChevron: true) { route = .appearance }
                    SettingsDivider()
                    SettingsRow(icon: "globe", tint: .purple, title: s.languageTitle, value: languageName,
                                showsChevron: true) { route = .language }
                    SettingsDivider()
                    HStack(spacing: 14) {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30).background(Color.orange, in: RoundedRectangle(cornerRadius: 8))
                        Text(s.t("Вибрация", "Haptics")).font(.system(size: 16)).foregroundStyle(theme.text)
                        Spacer()
                        Toggle("", isOn: $haptics).labelsHidden().tint(theme.accentColor)
                            .onChange(of: haptics) { _, on in if on { Haptics.impact(.medium) } }
                    }
                    .padding(.horizontal, 14).frame(height: 52)
                    SettingsDivider()
                    SettingsRow(icon: "server.rack", tint: .blue, title: s.serverLabel, value: serverHost,
                                showsChevron: true) { route = .server }
                }

                TextActionButton(title: s.logout) {
                    Task { @MainActor in
                        await session.signOutRemote()
                        flow.logout()
                    }
                }
                .padding(.top, 4)

                Button(s.deleteAccount) { confirmDelete = true }
                    .font(.system(size: 13))
                    .foregroundStyle(theme.danger)
                    .padding(.bottom, 24)
            }
            .padding(.top, 8)
            .background(alignment: .top) {
                GeometryReader { g in
                    Color.clear.preference(key: ScrollTopKey.self, value: g.frame(in: .named("profileScroll")).minY)
                }
            }
            .background {
                ScrollOffsetProbe(lockTop: photos.isEmpty) { offset in
                    probeY = max(0, offset)
                    if abs(offset - rawOffset) > 0.3 { rawOffset = offset }
                    if offset > -8 { if !pullArmed { pullArmed = true } }
                    guard !photos.isEmpty else { return }
                    let pull = -offset
                    let amount: CGFloat = pullStage == 0 ? max(0, min(80, pull)) : 0
                    if abs(amount - pullAmount) > 0.5 { pullAmount = amount }
                    // ступень 1: аватарка плавно вырастает в шапку на всю ширину (и остаётся, пока не пролистать вверх)
                    if pull > 62, pullStage == 0, pullArmed {
                        Haptics.impact(.medium)
                        setStage(1)
                    }
                    // ступень 2: шапка растёт на весь экран; фото листаются свайпами и нажатиями
                    if pull > 150, pullStage == 1, pullArmed {
                        pullArmed = false
                        Haptics.impact(.heavy)
                        setStage(2)
                    }
                    // листаем страницу вверх — шапка сворачивается обратно в кружок
                    if offset > 24, pullStage == 1 { setStage(0) }
                }
                .frame(width: 0, height: 0)
            }
        }
        .coordinateSpace(name: "profileScroll")
        .scrollBounceBehavior(.basedOnSize)
        .onAppear {
            // каждый заход в «Профиль» — с самого начала: шапка раскрыта, аватарка на месте
            scrollY = 0; probeY = 0; pullArmed = true
            proxy.scrollTo("profileTop", anchor: .top)
        }
        }
        .task { await store.load() }
        .confirmationDialog(s.deleteAccount, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(s.delete, role: .destructive) {
                Task { @MainActor in
                    await session.deleteRemoteAccount()
                    await flow.deleteAccount()
                }
            }
            Button(s.cancel, role: .cancel) {}
        } message: {
            Text(s.deleteWarning)
        }
        .fullScreenCover(isPresented: $showEdit) {
            EditProfileView(store: store)
                .preferredColorScheme(theme.dark ? .dark : .light)
        }
        .sheet(isPresented: $showStatus) {
            EmojiStatusSheet(current: store.profile?.statusEmoji) { emoji in
                Task { _ = await store.update(ProfilePatch(statusEmoji: emoji)) }
            }
            .environment(\.theme, theme).environment(\.lang, lang)
            .presentationDetents([.medium])
            .presentationBackground(theme.sheet)
        }
        .sheet(isPresented: $showPlaylist) {
            if let musicModel {
                PlaylistSheet(model: musicModel, player: session.player, isMine: true)
                    .environmentObject(session)
                    .environment(\.theme, theme).environment(\.lang, lang)
                    .preferredColorScheme(theme.dark ? .dark : .light)
            }
        }
        .sheet(isPresented: $showImport) {
            ContactsImportSheet()
                .environmentObject(session).environmentObject(flow)
                .environment(\.theme, theme).environment(\.lang, lang)
                .presentationBackground(theme.sheet)
        }
        .fullScreenCover(isPresented: $showQR) {
            ProfileQRScreen(link: DeepLink.profileLink(username: store.profile?.username,
                                                       userID: store.profile?.id ?? flow.userID ?? ""),
                            name: name, username: store.profile?.username, avatarID: store.profile?.avatarID)
                .environment(\.theme, theme)
                .environment(\.lang, lang)
        }
        .fullScreenCover(item: $viewer) { route in
            AvatarViewer(name: name, photos: photos, start: route.index,
                         onReorder: { ids in Task { _ = await store.reorderPhotos(ids) } },
                         onDelete: { id in Task { _ = await store.removePhoto(id) } })
        }
    }

    // MARK: Верхняя панель: «Изм.» слева, QR справа

    private var topBar: some View {
        HStack {
            Button { showEdit = true } label: {
                Text(s.editShort)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 20)
                    .frame(height: 42)
                    .glassCapsule(interactive: true)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { showQR = true } label: {
                Image(systemName: "qrcode")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(theme.text)
                    .frame(width: 42, height: 42)
                    .glassCircle()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    // MARK: Шапка с фотографиями

    private var header: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                if photos.isEmpty {
                    // без фото: буква с «+», просто уменьшается и растворяется
                    AvatarPager(name: name, photos: photos, size: 112, index: $pageIndex, addStore: store)
                        .scaleEffect(avatarScale, anchor: .top)
                        .offset(y: -34 * collapse * collapse)
                        .opacity(Double(1 - smooth((collapse - 0.5) / 0.35)))
                        .background(GeometryReader { g in
                            Color.clear.preference(key: AvatarTopKey.self, value: g.frame(in: .global).minY)
                        })
                } else {
                    // саму аватарку рисует collapsingAvatar (поверх, в экранных координатах); здесь — место и нажатие
                    Color.clear
                        .frame(width: 112, height: 112)
                        .contentShape(Circle())
                        .onTapGesture { setStage(1) }
                        .background(GeometryReader { g in
                            Color.clear.preference(key: AvatarTopKey.self, value: g.frame(in: .global).minY)
                        })
                }
            }
            // при раскрытой шапке под фото освобождается место, а содержимое плавно съезжает вниз
            // (верх кружка в покое считаем из раскладки: замер внутри ScrollView приходит нулём — оставалась пустая полоса)
            .frame(height: pullStage >= 1 ? max(112, UIScreen.main.bounds.width * 0.96 - (TopInset.value + 82) + 4) : 112,
                   alignment: .top)

            if pullStage == 0 {
                // само имя рисует floatingName (поверх плашки); здесь — место под него
                Color.clear.frame(height: 32)

                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(ProfilePalette.inkSecondary(store.profile?.styleColor, fallback: theme.textSecondary))
                    .opacity(Double(1 - max(0, collapse - 0.35) * 2.5))
            }

            MusicStrip(track: store.profile?.track, queue: store.profile?.track.map { [$0] } ?? [],
                       canAdd: true, player: session.player) { openPlaylist() }
                .padding(.top, 4)

            if let bio = store.profile?.bio, !bio.isEmpty {
                LinkText(text: bio, tint: theme.accentColor)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            if let error = store.loadError.flatMap({ store.profile == nil ? s.api($0) : nil }) {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }
}

private struct AvatarTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct NameMidKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct DockMidKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
