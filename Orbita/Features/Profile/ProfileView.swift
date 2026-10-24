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
    private var isInterests: Bool { if case .interests = route { return true } else { return false } }

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
    @State private var nameSlotLive: CGFloat = 0      // центр места под ник (экранные координаты)
    @State private var nameSlotRest: CGFloat = 0
    @State private var stackTop: CGFloat = 0
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
        // Переход как в iOS: новый экран наезжает справа поверх профиля, а профиль немного уходит влево и притемняется.
        // Экраны целиком не гаснут (проявление на весь экран тяжёлое и давало рывки), анимация без «отскока»
        ZStack {
            if let route {
                ProfileSubScreen(route: route, store: store) { self.route = nil }
                    .background(SpaceBackground(isDark: theme.dark, showStars: false).ignoresSafeArea())   // непрозрачный: профиль под ним не просвечивает
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            } else {
                main
                    .transition(.modifier(active: PushedBack(amount: 1), identity: PushedBack(amount: 0)))
                    .zIndex(0)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 1), value: route)
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
            if pullStage == 2, !photos.isEmpty {
                // последнее положение — просмотр как в Telegram: назад / ник и дата / «Изм.», миниатюры, «поделиться» и корзина
                AvatarViewer(name: shownName, photos: photos, start: pageIndex,
                             onReorder: { ids in Task { _ = await store.reorderPhotos(ids) } },
                             onDelete: { id in Task { _ = await store.removePhoto(id) } },
                             onClose: { setStage(0) })
                    .padding(.top, TopInset.value)          // кнопки — под статус-баром, а не вровень с ним
                    .background(Color.black.ignoresSafeArea())
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(50)
            }
            // тёмная «капля» островка: аватарка в неё втекает, пока шапка сворачивается
            // плашка поверх содержимого: прокручиваемое уходит «под потолок»
            Color.clear
            .frame(height: bar)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.72), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .offset(y: -inset)
            .opacity(Double(min(1, max(0, (collapse - 0.55) / 0.3))))
            .overlay {
                // плашка «съедает» нажатия: кнопки, которые сейчас под размытием, не срабатывают
                Color.clear.contentShape(Rectangle()).onTapGesture {}
                    .allowsHitTesting(collapse > 0.6)
            }
            pinnedBar
            floatingName
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: StackTopKey.self, value: g.frame(in: .global).minY)
        })
        .onPreferenceChange(StackTopKey.self) { stackTop = $0 }
        .onChange(of: pullStage) { _, n in session.tabBarHidden = n == 2 || isInterests }
        .onChange(of: route) { _, _ in session.tabBarHidden = pullStage == 2 || isInterests }
        .onDisappear { session.tabBarHidden = false }
        .onPreferenceChange(NameSlotKey.self) { v in
            nameSlotLive = v
            if pullStage == 0 { nameSlotRest = v + max(0, rawOffset) }      // место под ник в покое, независимо от текущей прокрутки

        }
        .onPreferenceChange(ScrollTopKey.self) { scrollY = $0 }
        .onPreferenceChange(AvatarTopKey.self) { v in
            avatarTopLive = v
            if scrollOffset <= 0.5, pullStage == 0 { avatarTopRest = v }
        }
    }

    private func setStage(_ n: Int) {
        guard pullStage != n else { return }
        Haptics.impact(.light)
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
            AvatarStage(expand: CGFloat(pullStage), circleTop: origin.y + 60 - raw, screen: screen,
                        headerHeight: screen.width * 0.96, topInset: inset,
                        photos: photos, page: pageIndex, forward: stageForward,
                        name: shownName.isEmpty ? s.you : shownName, status: subtitle,
                        onStep: { stepPhoto($0) },
                        onCenter: { setStage(pullStage == 1 ? 2 : 1) },
                        onVertical: { stageDrag($0) },
                        onClose: { setStage(0) },
                        track: store.profile?.track, queue: store.profile?.track.map { [$0] } ?? [], player: session.player,
                        onMusic: { openPlaylist() })
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
        let grow: CGFloat = 1                                                 // при натяжении кружок не растёт: в нужный момент сразу переходит в средний режим
        return grow * (1 - 0.62 * c * c)
    }

    private var avatarBlur: CGFloat {
        return 14 * smooth(collapse / 0.8)                 // размывается постепенно, пока едет
    }

    /// Чернеет со стороны острова (сверху) и понемногу вся
    private var darkSweep: some View {
        let q: CGFloat = smooth((collapse - 0.12) / 0.6)
        let front: CGFloat = q * 1.7
        return Circle().fill(Color.black)
            .mask(LinearGradient(colors: [.black, .clear],
                                 startPoint: UnitPoint(x: 0.5, y: front - 0.7),
                                 endPoint: UnitPoint(x: 0.5, y: front)))
            .allowsHitTesting(false)
    }

    private var avatarOpacity: Double {
        return Double(1 - smooth((collapse - 0.45) / 0.5))   // фото уступает место тёмной капле, когда уже маленькое
    }

    /// Аватарка темнеет в каплю, та стекает к островку, сливается с ним и исчезает (как «жидкость»)
    private func islandBlob(inset: CGFloat) -> some View {
        let c: CGFloat = collapse
        let off: CGFloat = scrollOffset
        let raw: CGFloat = rawOffset
        let ready = inset >= 51                                             // острова нет — просто растворяемся
        let alpha: Double = Double(smooth((c - 0.1) / 0.05) * (1 - smooth((c - 0.96) / 0.04)))
        return ScreenSpace { screen, origin in
            Canvas { ctx, size in
            guard ready else { return }
            let top: CGFloat = origin.y + 60 - raw - 34 * c * c       // верх аватарки на экране
            let scale: CGFloat = 1 - 0.75 * c * c
            let aD: CGFloat = 112 * scale                              // её диаметр
            let dock: CGFloat = smooth((c - 0.7) / 0.3)
            // маленькая капля у верха аватарки, соединена с островком; растёт до размера аватарки, потом втекает и уменьшается
            let grow: CGFloat = smooth((c - 0.12) / 0.58)
            let free: CGFloat = 16 + (aD - 16) * grow
            let diameter: CGFloat = max(6, free * (1 - 0.78 * dock))
            let islandCY: CGFloat = 29.5
            let follow: CGFloat = top + free * (0.5 - 0.22 * (1 - grow))      // сначала капля чуть «вдавлена» в верх аватарки — они срастаются
            let hold: CGFloat = islandCY + 18 + diameter / 2 - 16 - 10 * dock
            let cy: CGFloat = max(follow, hold)
            let island = CGRect(x: size.width / 2 - 59, y: islandCY - 15, width: 118, height: 30)
            let drop = CGRect(x: size.width / 2 - diameter / 2, y: cy - diameter / 2, width: diameter, height: diameter)
            ctx.addFilter(.alphaThreshold(min: 0.5, color: .black))
            ctx.addFilter(.blur(radius: 9))
            ctx.drawLayer { layer in
                layer.fill(Path(roundedRect: island, cornerRadius: 15), with: .color(.black))
                layer.fill(Path(ellipseIn: drop), with: .color(.black))
                // перемычка: от островка тянется к капле, они соединяются
                let neckW: CGFloat = max(14, diameter * 0.6)
                let neck = CGRect(x: size.width / 2 - neckW / 2, y: islandCY, width: neckW, height: max(0, cy - islandCY))
                layer.fill(Path(roundedRect: neck, cornerRadius: neckW / 2), with: .color(.black))
            }
            }
            .frame(width: screen.width, height: screen.height)
        }
        .opacity(alpha)
        .allowsHitTesting(false)
    }

    /// 0 — шапка раскрыта, 1 — свёрнута (после ~150 pt прокрутки)
    private var collapse: CGFloat { max(0, min(1, max(rawOffset, max(-scrollY, probeY)) / 150)) }

    /// «Изм.», QR и ник остаются наверху при прокрутке; ник появляется, когда крупный уходит
    private var pinnedBar: some View {
        topBar
            .padding(.top, 8)
    }

    /// Ник: едет вверх вместе со страницей, постепенно уменьшается и останавливается в панели.
    /// Считается только от прокрутки (без замеров), тень появляется лишь когда ник уже встал на место.
    private var floatingName: some View {
        let dockY: CGFloat = 29                                    // центр панели с кнопками «Изм.» и QR
        // крупный ник живёт в самой странице (всегда на своём месте); сюда он «переходит» уже маленьким, когда страница уехала вверх
        let r0: CGFloat = max(0, rawOffset)
        let appear: Double = Double(smooth((r0 - 80) / 40))
        let ink = ProfilePalette.ink(store.profile?.styleColor, fallback: theme.text)
        let label = shownName.isEmpty ? s.you : shownName
        return Text(label)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(ink)
            .lineLimit(1)
            .frame(maxWidth: 220)
            .frame(height: 32)
            .padding(.top, dockY - 16)
            .opacity(pullStage == 0 ? appear : 0)
            .allowsHitTesting(false)
    }

    private var mainScroll: some View {
        ScrollViewReader { proxy in
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                Color.clear.frame(height: 0).id("profileTop")
                Color.clear.frame(height: 20)                      // место под закреплённую панель (аватарка ближе к верху)
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
                ScrollOffsetProbe(lockTop: true, reportPull: !photos.isEmpty) { offset in
                    probeY = max(0, offset)
                    if abs(offset - rawOffset) > 0.3 { rawOffset = offset }
                    if offset > -8 { if !pullArmed { pullArmed = true } }
                    guard !photos.isEmpty else { return }
                    let pull = -offset
                    let amount: CGFloat = pullStage == 0 ? max(0, min(80, pull)) : 0
                    if abs(amount - pullAmount) > 0.5 { pullAmount = amount }
                    // ступень 1: аватарка плавно вырастает в шапку на всю ширину (и остаётся, пока не пролистать вверх)
                    if pull > 62, pullStage == 0, pullArmed {
                        pullArmed = false                // в третье — только новым жестом, после отпускания
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
                store.setStatusEmoji(emoji)                       // рядом с ником — сразу, не дожидаясь сервера
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
                    // нажимается вся капсула и ещё ~12 pt вокруг, а не только буквы: стеклянный фон на iOS 26
                    // не считается областью нажатия, и раньше срабатывал лишь точный тап по «Изм.»
                    .contentShape(Rectangle().inset(by: -12))
            }
            .buttonStyle(.plain)

            Spacer()

            Button { showQR = true } label: {
                Image(systemName: "qrcode")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(theme.text)
                    .frame(width: 42, height: 42)
                    .glassCircle()
                    .contentShape(Rectangle().inset(by: -12))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    // MARK: Шапка с фотографиями

    private var header: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                if let orbit = store.profile?.orbit, !orbit.isEmpty {
                    OrbitRing(friends: orbit, avatarSize: 112, front: false, mine: true)              // пузыри, залетевшие за аватарку
                        .scaleEffect(avatarScale, anchor: .top)
                        .offset(y: -34 * collapse * collapse)
                        .opacity(pullStage >= 1 ? 0 : avatarOpacity)
                }
                AvatarPager(name: name, photos: photos, size: 112, index: $pageIndex, addStore: store, isMine: true) {
                    if !photos.isEmpty { setStage(1) }
                }
                // листаем вверх: аватарка уменьшается, размывается и «втягивается» в островок
                .scaleEffect(avatarScale, anchor: .top)
                .offset(y: -34 * collapse * collapse)
                .background(GeometryReader { g in
                    Color.clear.preference(key: AvatarTopKey.self, value: g.frame(in: .global).minY)
                })
                .blur(radius: avatarBlur)
                .opacity(pullStage >= 1 ? 0 : avatarOpacity)        // вместо кружка рисует AvatarStage
                if let orbit = store.profile?.orbit, !orbit.isEmpty {
                    OrbitRing(friends: orbit, avatarSize: 112, front: true, mine: true)
                        .scaleEffect(avatarScale, anchor: .top)
                        .offset(y: -34 * collapse * collapse)
                        .opacity(pullStage >= 1 ? 0 : avatarOpacity)
                }
            }
            // при раскрытой шапке под фото освобождается место, а содержимое плавно съезжает вниз
            .frame(height: pullStage >= 1 ? max(112, UIScreen.main.bounds.width * 0.96 - (TopInset.value + 60) - 10) : 112,
                   alignment: .top)
            .zIndex(1)                                                  // орбита пролетает поверх никнейма

            if pullStage == 0 {
                // само имя рисует floatingName (поверх плашки); здесь — место под него
                NameWithStatus(name: name.isEmpty ? s.you : name, emoji: store.profile?.statusEmoji, fontSize: 26,
                               onEmojiTap: { showStatus = true })                // свой профиль: нажатие — смена статуса
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(ProfilePalette.ink(store.profile?.styleColor, fallback: theme.text))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, 24)
                    .frame(height: 32)
                    .opacity(1 - Double(smooth((rawOffset - 50) / 50)))     // уходит вместе со страницей, пока в панели появляется маленький

                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(ProfilePalette.inkSecondary(store.profile?.styleColor, fallback: theme.textSecondary))
                    .opacity(Double(1 - max(0, collapse - 0.35) * 2.5))
            }

            if pullStage == 0 {
            MusicStrip(track: store.profile?.track, queue: store.profile?.track.map { [$0] } ?? [],
                       canAdd: true, player: session.player) { openPlaylist() }
                .padding(.top, 4)
            }

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

private struct NameSlotKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct StackTopKey: PreferenceKey {
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

/// Экран под наезжающим сверху: сдвинут влево на четверть ширины и притемнён (как в навигации iOS)
private struct PushedBack: ViewModifier {
    let amount: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(x: -UIScreen.main.bounds.width * 0.28 * amount)
            .overlay(Color.black.opacity(0.22 * Double(amount)).ignoresSafeArea().allowsHitTesting(false))
    }
}
