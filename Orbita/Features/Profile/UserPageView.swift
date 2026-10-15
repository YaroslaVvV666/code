import SwiftUI
import Combine

// MARK: - Модель страницы пользователя (своей или чужой)

@MainActor
final class UserPageModel: ObservableObject {
    enum Source: Equatable {
        case me, id(String), username(String)
    }

    @Published private(set) var profile: UserProfile?
    @Published private(set) var posts: [Post] = []
    @Published private(set) var wallLoaded = false
    @Published private(set) var ownReels: [Post] = []
    @Published private(set) var repostedReels: [Post] = []
    @Published private(set) var savedReels: [Post] = []
    @Published private(set) var reelsLoaded = false
    @Published private(set) var savedLoaded = false
    @Published var tracks: [Track] = []
    @Published var uploadingTracks = false
    @Published private(set) var friends: [FriendUser] = []
    @Published private(set) var incoming: [FriendUser] = []
    @Published private(set) var outgoing: [FriendUser] = []
    @Published private(set) var friendsLoaded = false
    @Published var error: APIError?
    @Published var failed: APIError?

    let source: Source
    private let myID: String
    private let profileRepo: ProfileRepository
    private let feedRepo: FeedRepository
    private let social: SocialRepository
    private weak var ownStore: ProfileStore?
    private weak var feed: FeedViewModel?

    init(source: Source, session: AppSession) {
        self.source = source
        myID = session.serverID
        profileRepo = session.profileRepo
        feedRepo = session.feedRepo
        social = session.socialRepo
        ownStore = session.profile
        feed = session.feed
    }

    var isMe: Bool { profile?.id.lowercased() == myID || source == .me }

    private static func map(_ error: Error) -> APIError { (error as? APIError) ?? .offline }

    func load() async {
        do {
            switch source {
            case .me:                profile = try await profileRepo.profile(id: myID)
            case .id(let id):        profile = try await profileRepo.profile(id: id)
            case .username(let name): profile = try await profileRepo.lookup(username: name)
            }
            failed = nil
        } catch {
            failed = Self.map(error)
            return
        }
        await reloadWall()
        if let id = profile?.id, (profile?.tracksCount ?? 0) > 0 || isMe {
            tracks = (try? await social.playlist(userID: id)) ?? []
        }
    }

    func loadReels() async {
        guard let id = profile?.id, !reelsLoaded else { return }
        async let own = social.reels(userID: id, reposts: false)
        async let rep = social.reels(userID: id, reposts: true)
        ownReels = (try? await own) ?? []
        repostedReels = (try? await rep) ?? []
        reelsLoaded = true
    }

    /// Избранное — только своё: закладки лежат на устройстве, берём из них шортсы
    func loadSaved() async {
        guard isMe else { return }
        var out: [Post] = []
        for id in BookmarkStore.shared.ids {
            if let p = try? await feedRepo.post(id: id), p.media.contains(where: { $0.kind == .video }) { out.append(p) }
        }
        savedReels = out
        savedLoaded = true
    }

    func reloadWall() async {
        guard let id = profile?.id else { return }
        if let wall = try? await social.wall(userID: id) {
            posts = wall.posts
            wallLoaded = true
        }
    }

    // MARK: Записи на стене

    func toggleLike(_ post: Post) {
        guard let i = posts.firstIndex(where: { $0.id == post.id }) else { return }
        posts[i].likedByMe.toggle()
        posts[i].likes += posts[i].likedByMe ? 1 : -1
        let liked = posts[i].likedByMe
        let id = post.id
        Task { @MainActor in
            do { try await feedRepo.setLike(postID: id, liked: liked) } catch {
                if let j = posts.firstIndex(where: { $0.id == id }) {
                    posts[j].likedByMe = !liked
                    posts[j].likes += liked ? -1 : 1
                }
                self.error = Self.map(error)
            }
        }
    }

    func delete(_ post: Post) {
        let backup = posts
        posts.removeAll { $0.id == post.id }
        feed?.forget(post.id)
        let id = post.id
        Task { @MainActor in
            do { try await feedRepo.deletePost(id: id) } catch {
                posts = backup
                self.error = Self.map(error)
            }
        }
    }

    func replace(_ post: Post) {
        if let i = posts.firstIndex(where: { $0.id == post.id }) { posts[i] = post }
    }

    func added(_ post: Post) { posts.insert(post, at: 0) }

    // MARK: Друзья

    func loadFriends() async {
        guard let id = profile?.id else { return }
        if let list = try? await profileRepo.friends(userID: id) { friends = list }
        if isMe, let r = try? await profileRepo.friendRequests() {
            incoming = r.incoming
            outgoing = r.outgoing
        }
        friendsLoaded = true
    }

    /// Добавить / принять / отменить заявку / удалить из друзей — для человека на этой странице
    func toggleFriend() async {
        guard let p = profile else { return }
        await setFriend(id: p.id, add: p.friendState == "none" || p.friendState == "incoming")
    }

    func setFriend(id: String, add: Bool) async {
        do {
            let state = try await profileRepo.setFriend(userID: id, add: add)
            if profile?.id == id {
                profile?.friendState = state
                profile?.friendsCount += state == "friends" ? 1 : 0
            }
            if isMe {
                await loadFriends()
                if let r = try? await profileRepo.profile(id: myID) { profile = r }
            } else if let p = profile {
                profile = (try? await profileRepo.profile(id: p.id)) ?? profile
            }
            Haptics.notify(.success)
        } catch {
            self.error = Self.map(error)
        }
    }

    // MARK: Блокировка

    func setBlocked(_ blocked: Bool) async {
        guard let id = profile?.id else { return }
        do {
            try await social.setBlocked(userID: id, blocked: blocked)
            await load()
            await feed?.load()
        } catch {
            self.error = Self.map(error)
        }
    }

    // MARK: Плейлист

    private func tracksChanged() async { await ownStore?.load() }

    func addTracks(_ urls: [URL]) async {
        uploadingTracks = true
        defer { uploadingTracks = false }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 40 * 1024 * 1024 {
                error = .server(status: 413, code: "too_large")
                continue
            }
            do {
                tracks.append(try await social.addTrack(fileURL: url))
            } catch {
                self.error = Self.map(error)
            }
        }
        await tracksChanged()
    }

    func deleteTrack(_ track: Track) async {
        do {
            tracks = try await social.deleteTrack(id: track.id)
            await tracksChanged()
        } catch { self.error = Self.map(error) }
    }

    func moveTrack(from: IndexSet, to: Int) async {
        let backup = tracks
        tracks.move(fromOffsets: from, toOffset: to)
        do {
            tracks = try await social.reorderTracks(tracks.map(\.id))
            await tracksChanged()
        } catch {
            tracks = backup
            self.error = Self.map(error)
        }
    }

    func rename(_ track: Track, title: String, artist: String) async {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        do {
            let updated = try await social.renameTrack(id: track.id, title: clean, artist: artist)
            if let i = tracks.firstIndex(where: { $0.id == track.id }) { tracks[i] = updated }
            await tracksChanged()
        } catch { self.error = Self.map(error) }
    }
}

// MARK: - Страница пользователя (стена как во ВКонтакте / Facebook)

struct UserPageView: View {
    @StateObject private var model: UserPageModel
    @ObservedObject private var player: AudioPlayer
    @ObservedObject private var feed: FeedViewModel
    @ObservedObject private var ownStore: ProfileStore

    @EnvironmentObject private var session: AppSession
    @Environment(\.pageTopInset) private var pageTop
    @EnvironmentObject private var flow: AuthFlow
    @State private var chatRoute: ChatRoute?
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @AppStorage("autoplay") private var autoplay = true

    @State private var page = 0
    @State private var avatarViewer: AvatarViewerRoute?
    @State private var showPlaylist = false
    @State private var showComposer = false
    @State private var editingPost: Post?
    @State private var commentsPost: Post?
    @State private var confirmBlock = false
    @State private var showContact = false
    /// Ступень шапки: 0 — кружок, 1 — фото на всю ширину, 2 — на весь экран (как в Telegram)
    @State private var stage = 0
    @State private var stageForward = true
    @State private var avatarTop: CGFloat = 0          // верх аватарки в координатах страницы
    @State private var pullArmed = true
    @State private var tracker = PageScrollTracker()
    @State private var tab = 0
    @State private var reelOpen: Post?

    private enum TabKind { case posts, shorts, reposts, saved, photos, friends }
    private var tabKinds: [TabKind] { model.isMe ? [.posts, .shorts, .reposts, .saved, .photos, .friends]
                                                 : [.posts, .shorts, .reposts, .photos, .friends] }
    private func tabTitle(_ k: TabKind) -> String {
        switch k {
        case .posts:   return s.postsStat
        case .shorts:  return s.t("Шортсы", "Shorts")
        case .reposts: return s.t("Репосты", "Reposts")
        case .saved:   return s.t("Избранное", "Saved")
        case .photos:  return s.photosStat
        case .friends: return model.profile.map(friendsTabTitle) ?? ""
        }
    }
    /// Две строки вкладок: «Шортсы · Репосты · Избранное» и «Публикации · Фото · Друзья»
    private var tabRows: some View {
        let titles = tabKinds.map(tabTitle)
        let reelRow = tabKinds.indices.filter { [.shorts, .reposts, .saved].contains(tabKinds[$0]) }
        let restRow = tabKinds.indices.filter { ![.shorts, .reposts, .saved].contains(tabKinds[$0]) }
        return VStack(spacing: 8) {
            ProfileTabs(titles: titles, selection: $tab, only: reelRow)
            ProfileTabs(titles: titles, selection: $tab, only: restRow)
        }
        .padding(.horizontal, 16)
    }
    @State private var muted = false
    @State private var soonText: String?
    @State private var friendSheet: FriendRoute?

    init(source: UserPageModel.Source, session: AppSession) {
        _model = StateObject(wrappedValue: UserPageModel(source: source, session: session))
        _player = ObservedObject(wrappedValue: session.player)
        _feed = ObservedObject(wrappedValue: session.feed)
        _ownStore = ObservedObject(wrappedValue: session.profile)
    }

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 0) {
            if let profile = model.profile {
                PageScrollMarker(lockTop: profile.avatars.isEmpty || profile.blockedMe)
                header(profile)
                if profile.blockedMe {
                    notice(icon: "hand.raised.slash", title: s.restrictedYou, text: s.restrictedYouHint)
                } else {
                    VStack(spacing: 14) {
                        actions(profile)
                        info(profile)
                        PermanentStoriesStrip(userID: profile.id, name: profile.name, avatarID: profile.avatarID)
                        tabRows
                        switch tabKinds[min(tab, tabKinds.count - 1)] {
                        case .posts:   wall(profile)
                        case .shorts:  reelGrid(model.ownReels, loaded: model.reelsLoaded,
                                                empty: s.t("Шортсов пока нет", "No shorts yet"))
                        case .reposts: reelGrid(model.repostedReels, loaded: model.reelsLoaded,
                                                empty: s.t("Репостов пока нет", "No reposts yet"))
                        case .saved:   reelGrid(model.savedReels, loaded: model.savedLoaded,
                                                empty: s.t("Сохранённых шортсов нет", "No saved shorts"))
                        case .photos:  photoGrid(profile)
                        case .friends: FriendsTab(model: model, profile: profile) { friendSheet = $0 }
                        }
                    }
                    .padding(.top, 14)
                }
            } else if let failed = model.failed {
                Text(s.api(failed))
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 80)
                    .padding(.horizontal, 30)
            } else {
                ProgressView().padding(.top, 80)
            }
        }
        .coordinateSpace(name: "userPageBody")
        .environmentObject(tracker)
        .overlay(alignment: .topLeading) {
            if let profile = model.profile, !profile.avatars.isEmpty, !profile.blockedMe { avatarStage(profile) }
        }
        .onPreferenceChange(PageAvatarTopKey.self) { v in if stage == 0 { avatarTop = v } }
        .onAppear {
            tracker.onChange = { offset in
                if let profile = model.profile { handleScroll(offset, profile: profile) }
            }
        }
        .overlay(alignment: .top) {
            if let profile = model.profile, !profile.blockedMe, stage == 0 {
                StickyProfileBar(name: profile.displayName, subtitle: statusLine(profile), color: profile.styleColor, tracker: tracker)
            }
        }
        .task { await model.load() }
        .onChange(of: ownStore.profile?.avatars) { _, _ in
            if model.isMe { Task { await model.load() } }
        }
        .overlay(alignment: .top) {
            if let error = model.error {
                ToastView(text: s.api(error))
                    .padding(.top, 8)
                    .task(id: error) {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        model.error = nil
                    }
            }
        }
        .fullScreenCover(item: $avatarViewer) { route in
            if let profile = model.profile {
                if model.isMe {
                    AvatarViewer(name: profile.name, photos: profile.avatars, start: route.index,
                                 onReorder: { ids in Task { _ = await session.profile.reorderPhotos(ids) } },
                                 onDelete: { id in Task { _ = await session.profile.removePhoto(id) } })
                } else {
                    AvatarViewer(name: profile.name, photos: profile.avatars, start: route.index)
                }
            }
        }
        .fullScreenCover(item: $chatRoute) { route in
            ChatScreen(route: route, session: session, standalone: true)
                .environmentObject(session)
                .environmentObject(flow)
        }
        .sheet(isPresented: $showPlaylist) {
            PlaylistSheet(model: model, player: player, isMine: model.isMe)
                .preferredColorScheme(theme.dark ? .dark : .light)
        }
        .sheet(isPresented: $showComposer) {
            ComposerView(vm: feed, onSaved: { model.added($0) })
                .environmentObject(session)
                .environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
        .sheet(item: $editingPost) { post in
            ComposerView(vm: feed, editing: post, onSaved: { model.replace($0) })
                .environmentObject(session)
                .environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
        .sheet(item: $commentsPost, onDismiss: { Task { await model.reloadWall() } }) { post in
            CommentsSheet(post: post, vm: feed)
                .environmentObject(session)
                .environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
        .fullScreenCover(item: $friendSheet) { route in
            PublicProfileSheet(source: .id(route.id))
                .environmentObject(session)
                .environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
        .onChange(of: tab) { _, new in
            let kind = tabKinds[min(new, tabKinds.count - 1)]
            if kind == .friends, !model.friendsLoaded { Task { await model.loadFriends() } }
            if kind == .shorts || kind == .reposts { Task { await model.loadReels() } }
            if kind == .saved, !model.savedLoaded { Task { await model.loadSaved() } }
        }
        .fullScreenCover(item: $reelOpen) { post in
            PostLinkSheet(postID: post.id)
                .environmentObject(session).environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
        .sheet(isPresented: $showContact) {
            if let profile = model.profile {
                ContactNameSheet(peerID: profile.id, currentName: profile.contactName ?? profile.name,
                                 isContact: profile.isContact) {
                    await model.load()
                    await session.chats.refresh()
                }
                .environmentObject(session)
                .environment(\.theme, theme)
                .presentationDetents([.height(300)])
                .presentationBackground(theme.sheet)
            }
        }
        .confirmationDialog(s.blockQuestion(model.profile?.name ?? ""), isPresented: $confirmBlock,
                            titleVisibility: .visible) {
            Button(s.blockUser, role: .destructive) { Task { await model.setBlocked(true) } }
            Button(s.cancel, role: .cancel) {}
        } message: {
            Text(s.blockHint)
        }
    }

    // MARK: Шапка

    /// Потянули вниз — аватарка вырастает в шапку на всю ширину, потянули ещё — на весь экран; прокрутили вверх — сворачивается
    private func handleScroll(_ offset: CGFloat, profile: UserProfile) {
        if offset > -8, !pullArmed { pullArmed = true }
        guard !profile.avatars.isEmpty, !profile.blockedMe else { return }
        let pull = -offset
        if pull > 62, stage == 0, pullArmed {
            Haptics.impact(.medium)
            setStage(1)
        }
        if pull > 150, stage == 1, pullArmed {
            pullArmed = false
            Haptics.impact(.heavy)
            setStage(2)
        }
        if offset > 40, stage == 1 { setStage(0) }
    }

    private func setStage(_ n: Int) {
        guard stage != n else { return }
        if n == 0 || stage == 0 { stageForward = false }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.84)) {
            stage = n
            if n == 0 { page = 0 }
        }
    }

    private func stepPhoto(_ delta: Int, count: Int) {
        guard count > 1 else { return }
        let next = max(0, min(count - 1, page + delta))
        guard next != page else { return }
        Haptics.select()
        stageForward = delta > 0
        withAnimation(.easeInOut(duration: 0.28)) { page = next }
    }

    private func stageDrag(_ dy: CGFloat) {
        if stage == 1 {
            if dy > 50 { Haptics.impact(.medium); setStage(2) } else if dy < -50 { setStage(0) }
        } else if stage == 2, abs(dy) > 60 {
            setStage(1)
        }
    }

    private var headerHeight: CGFloat { UIScreen.main.bounds.width * 0.96 }

    private func avatarStage(_ profile: UserProfile) -> some View {
        let screen: CGSize = UIScreen.main.bounds.size
        let count = profile.avatars.count
        return AvatarStage(expand: CGFloat(stage), circleTop: avatarTop + pageTop, screen: screen,
                           headerHeight: headerHeight, topInset: pageTop,
                           photos: profile.avatars, page: page, forward: stageForward,
                           name: profile.displayName, status: statusLine(profile),
                           onStep: { stepPhoto($0, count: count) },
                           onCenter: { setStage(stage == 1 ? 2 : 1) },
                           onVertical: { stageDrag($0) })
            .offset(y: -pageTop)
            .allowsHitTesting(stage >= 1)
    }

    @ViewBuilder
    private func header(_ profile: UserProfile) -> some View {
        compactHeader(profile)
    }

    private func compactHeader(_ profile: UserProfile) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .top) {
                AvatarPager(name: profile.name, photos: profile.avatars, size: 118, index: $page,
                            addStore: model.isMe ? session.profile : nil) {
                    if !profile.avatars.isEmpty { setStage(1) }
                }
                .collapsing(endScale: 0.5, fadeFrom: 0, fadeTo: 0.62)      // аватарка сжимается и «вплавляется» в потолок
                .opacity(stage >= 1 ? 0 : 1)                               // вместо кружка рисует AvatarStage
            }
            // при раскрытой шапке под фото освобождается место, а содержимое плавно съезжает вниз
            .frame(height: stage >= 1 ? max(118, headerHeight - (avatarTop + pageTop) + 4) : 118, alignment: .top)
            .background(GeometryReader { g in
                Color.clear.preference(key: PageAvatarTopKey.self, value: g.frame(in: .named("userPageBody")).minY)
            })
            .padding(.top, 34)
            .padding(.bottom, 6)

            if stage == 0 {
                Text(profile.displayName)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(ProfilePalette.ink(profile.styleColor, fallback: theme.text))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                    .collapsing(fadeFrom: 0.45, fadeTo: 0.65)               // крупный ник уходит, ник в плашке остаётся
                Text(statusLine(profile))
                    .font(.system(size: 15))
                    .foregroundStyle(statusIsOnline(profile) ? (profile.styleColor == nil ? theme.accentColor : Color.white)
                                                             : ProfilePalette.inkSecondary(profile.styleColor, fallback: theme.textSecondary))
                    .lineLimit(1)
                    .collapsing(fadeFrom: 0.3, fadeTo: 0.55)
            }

            if !profile.blockedMe { musicRow(profile).padding(.top, 8) }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
        .background(alignment: .top) {
            // страница заходит под статус-бар на pageTopInset: цвет профиля продолжаем вверх на ту же высоту,
            // иначе над шапкой остаётся полоса другого цвета
            ProfileBackdrop(color: profile.styleColor, emoji: profile.styleEmoji, height: 400 + pageTop)
                .offset(y: -pageTop)
                .ignoresSafeArea(edges: .top)
        }
    }

    private func musicRow(_ profile: UserProfile) -> some View {
        MusicStrip(track: model.tracks.first ?? profile.track,
                   queue: model.tracks, canAdd: model.isMe, player: player) { showPlaylist = true }
    }

    private func statusIsOnline(_ profile: UserProfile) -> Bool {
        !model.isMe && s.lastSeenText(profile.lastSeen) == s.online
    }

    /// «в сети» / «был(а) …»; ник вынесен в карточку с данными
    private func statusLine(_ profile: UserProfile) -> String {
        if model.isMe { return profile.username.map { "@" + $0 } ?? "" }
        return s.lastSeenText(profile.lastSeen)
    }

    private func friendsTabTitle(_ profile: UserProfile) -> String {
        let n = profile.friendsCount + (model.isMe ? (profile.requestsCount ?? 0) : 0)
        return n > 0 ? s.t("Друзья", "Friends") + " \(n)" : s.t("Друзья", "Friends")
    }

    // MARK: Действия

    @ViewBuilder
    private func actions(_ profile: UserProfile) -> some View {
        if model.isMe {
            HStack(spacing: 10) {
                pill(icon: "square.and.pencil", title: s.newPost) { showComposer = true }
                pill(icon: "music.note.list", title: s.playlistTitle) { showPlaylist = true }
            }
            .padding(.horizontal, 16)
        } else if profile.blockedByMe {
            pill(icon: "hand.raised.slash", title: s.unblockUser) { Task { await model.setBlocked(false) } }
                .padding(.horizontal, 16)
        } else {
            VStack(spacing: 12) {
                if !profile.blockedMe {
                    HStack(spacing: 8) {
                        tile(icon: "bubble.left.fill", title: s.t("Чат", "Chat")) {
                            chatRoute = ChatRoute(peer: ChatPeer(id: profile.id, name: profile.name,
                                                                 username: profile.username, avatarID: profile.avatarID))
                        }
                        tile(icon: "phone.fill", title: s.t("Звонок", "Call")) { call(profile, video: false) }
                        tile(icon: "video.fill", title: s.t("Видео", "Video")) { call(profile, video: true) }
                        tile(icon: muted ? "bell.slash.fill" : "bell.fill",
                             title: muted ? s.t("Без звука", "Muted") : s.t("Звук", "Sound")) {
                            muted.toggle()
                            UserDefaults.standard.set(muted, forKey: "dm_muted_" + profile.id)
                            Haptics.impact(.light)
                            soonText = muted ? s.t("Уведомления выключены", "Muted") : s.t("Уведомления включены", "Unmuted")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { soonText = nil }
                        }
                    }
                }
                if !profile.blockedMe { friendButton(profile) }
                // «в контакты» и «заблокировать» — каждая отдельной строкой
                rowButton(icon: profile.isContact ? "person.fill.checkmark" : "person.badge.plus",
                          title: profile.isContact ? s.t("Изменить контакт", "Edit contact") : s.t("Добавить в контакты", "Add to contacts")) {
                    showContact = true
                }
                .glass(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
                rowButton(icon: "hand.raised.fill", title: s.blockUser, danger: true) { confirmBlock = true }
                    .glass(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
            }
            .padding(.horizontal, 16)
            .onAppear { muted = UserDefaults.standard.bool(forKey: "dm_muted_" + profile.id) }
            .overlay(alignment: .top) {
                if let soonText {
                    ToastView(text: soonText).offset(y: -50).transition(.opacity)
                }
            }
        }
    }

    private func friendButton(_ profile: UserProfile) -> some View {
        let (icon, title): (String, String) = {
            switch profile.friendState {
            case "friends":  return ("person.crop.circle.badge.checkmark", s.t("У вас в друзьях · удалить", "Friends · remove"))
            case "outgoing": return ("clock", s.t("Заявка отправлена · отменить", "Request sent · cancel"))
            case "incoming": return ("person.crop.circle.badge.plus", s.t("Принять заявку в друзья", "Accept friend request"))
            default:         return ("person.crop.circle.badge.plus", s.t("Добавить в друзья", "Add friend"))
            }
        }()
        return rowButton(icon: icon, title: title) { Task { await model.toggleFriend() } }
            .glass(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
    }

    private func call(_ profile: UserProfile, video: Bool) {
        session.calls.start(peer: ChatPeer(id: profile.id, name: profile.contactName ?? profile.name,
                                           username: profile.username, avatarID: profile.avatarID), video: video)
    }

    private func soon() {
        withAnimation { soonText = s.t("Скоро будет доступно", "Coming soon") }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { soonText = nil }
        }
    }

    private func tile(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 21, weight: .regular)).foregroundStyle(theme.accentColor)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.accentColor).lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: 66)
            .glass(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
        }
        .buttonStyle(PressStyle())
    }

    private func rowButton(icon: String, title: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 17)).frame(width: 24)
                Text(title).font(.system(size: 17))
                Spacer()
            }
            .foregroundStyle(danger ? theme.danger : theme.accentColor)
            .padding(.horizontal, 16).frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pill(icon: String, title: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 15, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(danger ? theme.danger : theme.text)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .card(theme, radius: 14)
        }
        .buttonStyle(PressStyle())
    }

    // MARK: Информация

    @ViewBuilder
    private func info(_ profile: UserProfile) -> some View {
        let rows: [ProfileInfoRow] = [
            ProfileInfoRow(label: s.phoneLabel, value: profile.phone ?? "", accent: true, kind: .phone),
            ProfileInfoRow(label: s.t("Имя пользователя", "Username"),
                           value: profile.username.map { "@" + $0 } ?? "", accent: true,
                           kind: .username(link: DeepLink.profileLink(username: profile.username, userID: profile.id))),
            ProfileInfoRow(label: s.birthday, value: s.birthdayText(profile.birthday) ?? ""),
            ProfileInfoRow(label: s.bioLabel, value: profile.bio),
        ].filter { !$0.value.isEmpty }

        if !rows.isEmpty {
            ProfileInfoCard(rows: rows).padding(.horizontal, 16)
        }
    }

    // MARK: Фото

    /// Сетка шортсов как в TikTok: вертикальные обложки и сердечки с числом
    @ViewBuilder
    private func reelGrid(_ posts: [Post], loaded: Bool, empty: String) -> some View {
        if posts.isEmpty {
            Text(loaded ? empty : " ")
                .font(.system(size: 15)).foregroundStyle(theme.textSecondary).padding(.vertical, 40)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                ForEach(posts) { post in
                    Color.black.aspectRatio(9.0 / 16.0, contentMode: .fit)
                        .overlay {
                            if let m = post.media.first {
                                if let thumb = m.thumbID { RemoteImage(id: thumb) } else { RemoteImage(id: m.id) }
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            HStack(spacing: 4) {
                                Image(systemName: "heart.fill").font(.system(size: 10))
                                Text("\(post.likes)").font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 3)
                            .padding(6)
                        }
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture { reelOpen = post }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
    }

    @ViewBuilder
    private func photoGrid(_ profile: UserProfile) -> some View {
        if profile.avatars.isEmpty {
            Text(s.t("Фото пока нет", "No photos yet"))
                .font(.system(size: 15)).foregroundStyle(theme.textSecondary).padding(.vertical, 40)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                ForEach(Array(profile.avatars.enumerated()), id: \.element.id) { index, photo in
                    Color.clear.aspectRatio(1, contentMode: .fit)
                        .overlay { RemoteImage(id: photo.mediaID) }
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture { avatarViewer = AvatarViewerRoute(index: index) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
    }

    // MARK: Стена

    @ViewBuilder
    private func wall(_ profile: UserProfile) -> some View {
        VStack(spacing: 12) {
            if model.isMe {
                Button { showComposer = true } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: profile.name, size: 38, avatarID: profile.avatarID)
                        Text(s.wallWhatsNew)
                            .font(.system(size: 15))
                            .foregroundStyle(theme.textTertiary)
                        Spacer()
                        Image(systemName: "photo.on.rectangle").foregroundStyle(theme.accentColor)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 58)
                    .card(theme, radius: 16)
                    .padding(.horizontal, 16)
                }
                .buttonStyle(PressStyle())
            }

            if profile.wallPrivate {
                notice(icon: "lock.fill", title: s.wallClosed, text: s.wallClosedHint)
            } else if model.posts.isEmpty {
                Text(model.wallLoaded ? (model.isMe ? s.wallEmptyMine : s.wallEmpty) : "")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 30)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(model.posts) { post in
                        PostCard(post: post, autoplay: autoplay,
                                 onLike: { model.toggleLike(post) },
                                 onComments: { commentsPost = post },
                                 onDelete: { model.delete(post) },
                                 onEdit: { editingPost = post })
                            .card(theme, radius: 18)
                            .padding(.horizontal, 12)
                    }
                }
            }
        }
        .padding(.bottom, 30)
    }

    private func notice(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(theme.textSecondary)
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 30)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
    }
}

private struct PageAvatarTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
