import SwiftUI
import Combine

enum MainTab: Hashable {
    case home, reels, chats, communities, profile

    var order: Int {
        switch self {
        case .home: return 0
        case .reels: return 1
        case .chats: return 2
        case .communities: return 3
        case .profile: return 4
        }
    }
}

struct TabBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct AuthorRoute: Identifiable {
    let id: String
}

/// Главный экран соцсети: вкладки + нижняя панель с кнопкой «+»
struct MainTabView: View {
    @EnvironmentObject private var flow: AuthFlow
    @EnvironmentObject private var router: LinkRouter
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var session: AppSession
    @ObservedObject private var push = PushManager.shared
    @State private var tab: MainTab = .home
    @State private var showComposer = false
    @State private var openedAuthor: AuthorRoute?
    @State private var barHeight: CGFloat = 70
    @State private var newLogin: DeviceSession?
    @State private var chatsMounted = false

    init(userID: String, userName: String) {
        _session = StateObject(wrappedValue: AppSession(userID: userID, userName: userName))
    }

    private var s: Strings { Strings(lang: lang) }

    /// Запоминаем известные сеансы; появившийся новый — показываем уведомлением
    private func checkNewLogins() {
        guard session.devices.loaded, session.devices.error == nil else { return }
        let key = "sec.knownSessions." + session.userID
        let known = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let all = session.devices.sessions
        if !known.isEmpty, newLogin == nil,
           let fresh = all.filter({ !$0.isCurrent && !known.contains($0.id) }).max(by: { $0.createdAt < $1.createdAt }) {
            newLogin = fresh
            Haptics.notify(.warning)
        }
        UserDefaults.standard.set(all.map(\.id), forKey: key)
    }

    private static func isProfileLink(_ link: DeepLink) -> Bool {
        switch link { case .username, .userID: return true; default: return false }
    }

    var body: some View {
        ZStack {
            ZStack {
                switch tab {
                case .home:
                    FeedView(vm: session.feed,
                             onCompose: { showComposer = true },
                             onServerSettings: {
                                 session.profileRoute = .server
                                 tab = .profile
                             },
                             onOpenAuthor: { openedAuthor = AuthorRoute(id: $0.id) })
                case .reels:
                    ReelsView(onOpenAuthor: { openedAuthor = AuthorRoute(id: $0.id) }, suspended: openedAuthor != nil, shared: session.mainReels)
                case .chats:
                    Color.clear                      // сам список чатов живёт ниже и не пересоздаётся при каждом заходе
                case .communities:
                    CommunitiesView(session: session, chats: session.chats)
                case .profile:
                    ProfileView(store: session.profile, route: $session.profileRoute)
                }
            }
            .id(tab)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
            // «Чаты» один раз построены и остаются в памяти: заход во вкладку — это просто показ, без пересборки списка, скелетона и состояния
            if chatsMounted || tab == .chats {
                ChatsListView(model: session.chats, session: session)
                    .opacity(tab == .chats ? 1 : 0)
                    .allowsHitTesting(tab == .chats)
                    .accessibilityHidden(tab != .chats)
                    .animation(.easeOut(duration: 0.18), value: tab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.34, dampingFraction: 0.92), value: tab)
        .environmentObject(session)
        // Панель всегда лежит поверх; обычным экранам оставляем под неё место, а «Шортс» идёт на весь экран под панелью
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: tab == .reels ? 0 : barHeight)
        }
        .overlay(alignment: .bottom) {
            TabBarHost(chats: session.chats, selection: Binding(
                get: { tab },
                set: { new in tab = new })) { showComposer = true }
                .background(GeometryReader { g in
                    Color.clear.preference(key: TabBarHeightKey.self, value: g.size.height)
                })
                .offset(y: session.tabBarHidden ? barHeight + 40 : 0)
                .opacity(session.tabBarHidden ? 0 : 1)
                .allowsHitTesting(!session.tabBarHidden)
                .animation(.easeOut(duration: 0.22), value: session.tabBarHidden)
        }
        .onPreferenceChange(TabBarHeightKey.self) { barHeight = $0 }
        .onChange(of: session.reelRequest?.id) { _, id in
            if id != nil, tab != .reels { tab = .reels }
        }
        .sheet(isPresented: $showComposer) {
            ComposerView(vm: session.feed)
                .environmentObject(session)
                .environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
        .fullScreenCover(item: $openedAuthor) { route in
            PublicProfileSheet(source: .id(route.id))
                .environmentObject(session)
                .environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
        .sheet(item: Binding(get: { router.pending.flatMap { Self.isProfileLink($0) ? nil : $0 } },
                              set: { if $0 == nil { router.pending = nil } })) { link in
            LinkSheet(link: link)
                .environmentObject(session)
                .environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
        }
        // профиль по ссылке @имя — на весь экран, как и из остальных мест
        .fullScreenCover(item: Binding(get: { router.pending.flatMap { Self.isProfileLink($0) ? $0 : nil } },
                                       set: { if $0 == nil { router.pending = nil } })) { link in
            LinkSheet(link: link)
                .environmentObject(session)
                .environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
        .task { await session.profile.load() }
        .task { await session.syncInterests() }
        .task { await session.syncSaves() }
        .task { await session.calls.run() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await session.chats.refresh() }
        }
        .task { await PushManager.shared.requestAndRegister() }
        .onReceive(PushManager.shared.$token.compactMap { $0 }) { token in
            Task { await session.uploadPush(token: token) }          // и при каждом входе в аккаунт
        }
        .onChange(of: push.openChat) { _, route in
            if route != nil { tab = .chats }
        }
        .task(id: scenePhase) {
            // новый вход в аккаунт с другого устройства: «Это вы?»
            guard scenePhase == .active else { return }
            await session.devices.load()
            checkNewLogins()
        }
        .alert(s.t("Новый вход в аккаунт", "New sign-in"), isPresented: Binding(get: { newLogin != nil }, set: { if !$0 { newLogin = nil } })) {
            Button(s.t("Это я", "It's me"), role: .cancel) {}
            Button(s.t("Завершить сеанс", "End session"), role: .destructive) {
                if let n = newLogin { Task { await session.devices.terminate(n) } }
            }
        } message: {
            if let n = newLogin {
                Text(s.t("\(n.device) · \(n.system)\nIP \(n.ip)\nЕсли это были не вы, завершите сеанс и включите облачный пароль.",
                         "\(n.device) · \(n.system)\nIP \(n.ip)\nIf this wasn't you, end the session and turn on a cloud password."))
            }
        }
        .task(id: scenePhase) {
            // счётчик непрочитанных и список чатов — пока приложение открыто. Обновляемся по событию long-poll,
            // а таймер (30 с) остаётся лишь страховкой на случай пропущенной побудки.
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await session.chats.refresh()
                await session.live.waitForTopics(["dm", "group", "call"], timeout: 30)
            }
        }
        .task { await session.live.run() }
        .onReceive(session.live.events) { topics in
            if topics.contains("call") { session.calls.wake() }      // звонок приходит мгновенно, без частого опроса
        }
        .background {
            BannerWindowInstaller(chats: session.chats, session: session, flow: flow, theme: theme, lang: lang) { peer in
                push.openChat = ChatRoute(peer: peer)
                tab = .chats
            }
            .frame(width: 0, height: 0)
        }
        .task {
            // Телефон нужен серверу, чтобы знакомые могли найти вас (видимость номера остаётся по вашей настройке)
            let phone = flow.e164
            if phone.count > 6 { _ = await session.profile.update(ProfilePatch(phone: phone)) }
        }
        .onReceive(session.$tabRequest.compactMap { $0 }) { target in
            session.tabRequest = nil
            tab = target
        }
        .overlay { ChatsBackgroundMedia(chats: session.chats, tab: tab, barHeight: barHeight) }
        .onChange(of: tab) { _, new in
            if new == .chats { chatsMounted = true }
            // голосовые и кружки играют в фоне только на вкладке «Чаты»
            if new != .chats { VoicePlayer.shared.stop(); CircleFocus.shared.stop() }
            if new != .profile { session.profileRoute = nil }
        }
    }
}

// MARK: - Нижняя панель

/// Следит за счётчиком непрочитанных (вложенный ObservableObject сам MainTabView не обновляет)
/// В какой вкладке открыта переписка (по умолчанию — «Чаты»)
private struct ChatHostTabKey: EnvironmentKey {
    static let defaultValue: MainTab = .chats
}

extension EnvironmentValues {
    var chatHostTab: MainTab {
        get { self[ChatHostTabKey.self] }
        set { self[ChatHostTabKey.self] = newValue }
    }
}

struct TabBarHost: View {
    @ObservedObject var chats: ChatsModel
    @Binding var selection: MainTab
    let onCompose: () -> Void

    /// Панель на экране. Отстаёт от chatOpen при выходе из чата: вышли и сразу зашли обратно — панель не успевает
    /// выехать и не мелькает. При входе в чат прячется сразу
    @State private var shown = true
    @State private var showTask: Task<Void, Never>?
    /// Сколько ждать после выхода из чата, прежде чем показать панель
    private static let showDelay: UInt64 = 300_000_000
    /// Переписка открыта на той вкладке, где мы сейчас. Ушли из чата в шортсы (присланное видео) — панель видна
    private var chatHere: Bool { chats.chatOpenTabs.contains(selection) }

    var body: some View {
        // Внутри переписки панель прячется — как в Telegram
        Group {
        if shown {
            OrbitaTabBar(selection: $selection, chatsBadge: chats.unread, onCompose: onCompose)
                // вся полоса под панелью «съедает» касания: посты и фото позади не нажимаются
                .background(Color.black.opacity(0.001).ignoresSafeArea(edges: .bottom))
                .contentShape(Rectangle())
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        }
        .onAppear { shown = !chatHere }
        .onChange(of: chatHere) { _, open in
            showTask?.cancel()
            if open {
                // зашли в чат (в том числе сразу после выхода) — панель уезжает сразу и быстро, даже если только начала выезжать
                withAnimation(.easeOut(duration: 0.2)) { shown = false }
            } else {
                showTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: Self.showDelay)
                    guard !Task.isCancelled, !chatHere else { return }
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { shown = true }
                }
            }
        }
    }
}

struct OrbitaTabBar: View {
    @Binding var selection: MainTab
    var chatsBadge = 0
    let onCompose: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    /// Положение пузыря в «слотах» панели (0…5, кнопка «+» — слот 2)
    @State private var pillSlot: CGFloat

    init(selection: Binding<MainTab>, chatsBadge: Int = 0, onCompose: @escaping () -> Void) {
        _selection = selection
        self.chatsBadge = chatsBadge
        self.onCompose = onCompose
        _pillSlot = State(initialValue: Self.slot(selection.wrappedValue))
    }

    private static func slot(_ tab: MainTab) -> CGFloat {
        switch tab {
        case .home: return 0
        case .reels: return 1
        case .chats: return 3
        case .communities: return 4
        case .profile: return 5
        }
    }

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            item(.home, icon: "house.fill", label: s.tabHome)
            item(.reels, icon: "play.rectangle.on.rectangle.fill", label: s.t("Шортс", "Shorts"))
            Button {
                Haptics.impact(.light)
                onCompose()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 50, height: 46)
                    .glass(Capsule(), tint: theme.accentColor, interactive: true)
            }
            .buttonStyle(PressStyle())
            .frame(maxWidth: .infinity)

            item(.chats, icon: "bubble.left.and.bubble.right.fill", label: s.tabChats, badge: chatsBadge)

            item(.communities, icon: "person.3.fill", label: s.tabCommunities)
            item(.profile, icon: "person.crop.circle.fill", label: s.tabProfile)
        }
        .background { pillView }
        .onChange(of: selection) { old, new in
            // пузырь всегда едет; чем дальше — тем чуть быстрее
            let distance = abs(Self.slot(new) - Self.slot(old))
            let response = max(0.28, 0.5 - 0.055 * Double(distance))
            withAnimation(.spring(response: response, dampingFraction: 0.72)) { pillSlot = Self.slot(new) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .glass(Capsule())
        .shadow(color: .black.opacity(theme.dark ? 0.35 : 0.12), radius: 18, y: 8)
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    /// Один пузырь на всю панель: катится от слота к слоту, к середине пути «раздувается» и возвращается с мягким отскоком
    private var pillView: some View {
        GeometryReader { geo in
            let w = geo.size.width / 6
            Capsule().fill(theme.accentColor.opacity(0.16))
                .frame(width: w, height: geo.size.height)
                .keyframeAnimator(initialValue: 1.0, trigger: selection) { content, k in
                    content.scaleEffect(x: k, y: 1 + (k - 1) * 0.8)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(1.3, duration: 0.18)
                        SpringKeyframe(1.0, duration: 0.42, spring: .bouncy(duration: 0.42, extraBounce: 0.12))
                    }
                }
                .offset(x: pillSlot * w)
        }
    }

    private func item(_ tab: MainTab, icon: String, label: String, badge: Int = 0) -> some View {
        Button {
            if selection != tab {
                Haptics.select()
                selection = tab
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 20))
                    .symbolEffect(.bounce, value: selection == tab)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text(badge > 99 ? "99+" : "\(badge)")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                                .background(LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.4), Color.red], startPoint: .top, endPoint: .bottom), in: Capsule())
                                .offset(x: 10, y: -6)
                        }
                    }
                Text(label).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(selection == tab ? theme.accentColor : theme.textSecondary)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())

        }
        .buttonStyle(.plain)
    }
}
