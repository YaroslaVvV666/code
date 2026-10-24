import SwiftUI

// MARK: - Главная лента

private struct FeedPullKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct FeedView: View {
    @ObservedObject var vm: FeedViewModel
    let onCompose: () -> Void
    let onServerSettings: () -> Void
    var onOpenAuthor: ((Author) -> Void)? = nil

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @AppStorage("autoplay") private var autoplay = true

    @State private var searching = false
    @State private var query = ""
    @State private var commentsPost: Post?
    @State private var showBookmarks = false
    @State private var editingPost: Post?
    @FocusState private var searchFocused: Bool
    @StateObject private var stories = StoryStore()
    @StateObject private var activity = ActivityStore()
    @State private var showActivity = false
    @State private var pendingAuthor: Author?
    @Environment(\.scenePhase) private var scenePhase
    @State private var pull: CGFloat = 0
    @State private var pullArmed = false

    private var s: Strings { Strings(lang: lang) }

    /// Фильтр по автору + поиск (не зависит от раскладки)
    private var visiblePosts: [Post] {
        var list = vm.posts
        if let author = vm.authorFilter { list = list.filter { $0.author.id == author } }
        guard !query.isEmpty else { return list }
        let variants = LayoutFix.variants(of: query)
        return list.filter { post in
            variants.contains {
                post.text.localizedCaseInsensitiveContains($0)
                || post.author.name.localizedCaseInsensitiveContains($0)
                || (post.author.username ?? "").localizedCaseInsensitiveContains($0)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: FeedPullKey.self, value: g.frame(in: .named("feedScroll")).minY)
                        })
                    if !searching {
                        // истории: только друзья и те, кто добавил вас в контакты; нет историй — нет и кружков
                        StoryTray(store: stories, pull: pull)
                        feedModeSwitch
                        Divider().overlay(theme.stroke)
                    }

                    stateView

                    ForEach(visiblePosts) { post in
                        PostCard(post: post, autoplay: autoplay,
                                 onLike: { vm.toggleLike(post) },
                                 onComments: { commentsPost = post },
                                 onDelete: { vm.delete(post) },
                                 onEdit: { editingPost = post },
                                 onOpenAuthor: onOpenAuthor)
                            .onAppear { session.taste.appeared(post.id) }
                            .onDisappear { session.taste.disappeared(post.id) }
                        Divider().overlay(theme.stroke)
                    }
                }
            }
            .coordinateSpace(name: "feedScroll")
            .onPreferenceChange(FeedPullKey.self) { handlePull($0) }
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                // потянули вниз — лента и истории обновляются
                async let feed: Void = vm.load()
                async let tray: Void = stories.reload(session.extras)
                _ = await (feed, tray)
                Haptics.impact(.light)
            }
        }
        .task { await vm.load() }
        .task {
            stories.myID = session.serverID
            while !Task.isCancelled {
                await stories.reload(session.extras)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .modifier(StoryPresenters(store: stories))
        .task {
            // счётчик на колокольчике: раз в минуту, тихо, без баннеров
            while !Task.isCancelled {
                await activity.refresh(session.extras)
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        .sheet(isPresented: $showActivity, onDismiss: {
            if let a = pendingAuthor { pendingAuthor = nil; onOpenAuthor?(a) }
        }) {
            ActivityView(store: activity) { pendingAuthor = $0 }
                .environmentObject(session).environment(\.theme, theme).environment(\.lang, lang)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.taste.endAll() }
        }
        .onDisappear { session.taste.endAll() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                session.taste.flush()
            }
        }
        .overlay(alignment: .top) {
            if let error = vm.actionError {
                ToastView(text: s.api(error))
                    .padding(.top, 62)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: error) {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        vm.actionError = nil
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: vm.actionError)
        .sheet(isPresented: $showBookmarks) {
            BookmarksSheet(vm: vm)
                .environmentObject(session).environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
        .sheet(item: $editingPost) { post in
            ComposerView(vm: vm, editing: post)
                .environmentObject(session)
                .environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
        .sheet(item: $commentsPost) { post in
            CommentsSheet(post: post, vm: vm)
                .environmentObject(session)
                .environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
    }

    /// Потянули ленту вниз: аватарка первого человека с историей растёт; отпустили — открываются истории (иначе обновление ленты)
    private func handlePull(_ y: CGFloat) {
        let v = max(0, y)
        if abs(v - pull) > 1 { pull = v }
        if v >= 95, !pullArmed {
            pullArmed = true
            Haptics.impact(.medium)
        } else if pullArmed, v < 40 {
            pullArmed = false
            let opened = stories.openFirstUnseen()
            if opened { Haptics.impact(.light) }
        }
    }

    /// Переключатель «Для вас / Свежее»
    private var feedModeSwitch: some View {
        HStack(spacing: 4) {
            ForEach([true, false], id: \.self) { mode in
                Button {
                    Haptics.select()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { vm.forYou = mode }
                } label: {
                    Text(mode ? s.t("Для вас", "For you") : s.t("Свежее", "Latest"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(vm.forYou == mode ? Color.white : theme.textSecondary)
                        .padding(.horizontal, 16).frame(height: 32)
                        .background {
                            if vm.forYou == mode { Capsule().fill(theme.accent) }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button { session.profileRoute = .interests; session.tabRequest = .profile } label: {
                Label(s.t("Интересы", "Interests"), systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: Состояния

    @ViewBuilder
    private var stateView: some View {
        switch vm.state {
        case .loading where vm.posts.isEmpty:
            FeedSkeleton()
        case .failed(let error) where vm.posts.isEmpty:
            VStack(spacing: 14) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(theme.accentColor)
                Text(s.api(error))
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                HStack(spacing: 18) {
                    TextActionButton(title: s.retry) { Task { await vm.load() } }
                    TextActionButton(title: s.setupServer, action: onServerSettings)
                }
            }
            .padding(.top, 50)
        default:
            if visiblePosts.isEmpty && vm.state == .loaded {
                Text(s.noPosts)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.top, 60)
            }
        }
    }

    // MARK: Шапка

    private var header: some View {
        HStack(spacing: 12) {
            if searching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.textSecondary)
                    TextField(s.searchFeed, text: $query)
                        .focused($searchFocused)
                        .foregroundStyle(theme.text)
                        .tint(theme.accentColor)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .card(theme, radius: 12)

                Button(s.cancel) {
                    searchFocused = false
                    withAnimation(.easeInOut(duration: 0.2)) { searching = false }
                    query = ""
                }
                .font(.system(size: 15))
                .foregroundStyle(theme.accentColor)
            } else {
                OrbitLogo(size: 30)
                    .frame(width: 40, height: 40)

                Text("Orbita")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(theme.text)
                    .tracking(0.4)
                    .padding(.leading, -6)

                Spacer()

                if !stories.hasTray {
                    StoryAddPicker(store: stories) {
                        Image(systemName: stories.preparing ? "hourglass" : "camera")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(theme.text)
                            .frame(width: 40, height: 40)
                    }
                }

                BellButton(store: activity) { showActivity = true }

                Button { showBookmarks = true } label: {
                    Image(systemName: "bookmark")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(theme.text)
                        .frame(width: 40, height: 40)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { searching = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { searchFocused = true }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(theme.text)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.stroke).frame(height: 1) }
    }
}

// MARK: - Авторы (быстрый фильтр)

struct StoriesRow: View {
    let stories: [Story]
    let selected: String?
    let onYourStory: () -> Void
    let onSelect: (Story) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Button(action: onYourStory) {
                    VStack(spacing: 7) {
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(theme.text)
                            .frame(width: 64, height: 64)
                            .card(theme, radius: 32)
                        Text(Strings(lang: lang).yourStory)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(width: 76)
                }
                .buttonStyle(PressStyle())

                ForEach(stories) { story in
                    let isSelected = selected == story.id
                    Button { onSelect(story) } label: {
                        VStack(spacing: 7) {
                            AvatarView(name: story.name, size: 58, avatarID: story.avatarID)
                                .padding(3)
                                .background(theme.sheet, in: Circle())
                                .padding(2.5)
                                .overlay(Circle().stroke(theme.accent, lineWidth: isSelected ? 3 : 1.5))
                            Text(story.name)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? theme.text : theme.textSecondary)
                                .lineLimit(1)
                        }
                        .frame(width: 70)
                    }
                    .buttonStyle(PressStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }
}

// MARK: - Публикация

struct PostCard: View {
    let post: Post
    let autoplay: Bool
    let onLike: () -> Void
    let onComments: () -> Void
    let onDelete: () -> Void
    var onEdit: (() -> Void)? = nil
    var onOpenAuthor: ((Author) -> Void)? = nil

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var viewer: ViewerRoute?
    @State private var confirmDelete = false
    @State private var sendSheet = false
    @State private var showLikers = false
    @State private var hiddenNote: String?
    @State private var reportAsk = false
    @ObservedObject private var bookmarks = BookmarkStore.shared
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var flow: AuthFlow

    private var s: Strings { Strings(lang: lang) }

    /// Ссылка на пост: обычный адрес сервера, кликабельный в любом мессенджере; в приложении открывается внутри него
    private var link: String { DeepLink.postShareLink(id: post.id) }

    private var shareText: String {
        let preview = post.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = preview.count > 90 ? String(preview.prefix(90)) + "…" : preview
        let name = post.author.name
        return (head.isEmpty ? name : "\(name): \(head)") + "\n" + link
    }

    @ViewBuilder
    private var shareItems: some View {
        ShareLink(item: shareText) { Label(s.share, systemImage: "square.and.arrow.up") }
        Button { sendSheet = true } label: { Label(s.sendToChat, systemImage: "paperplane") }
        Button {
            UIPasteboard.general.string = link
            Haptics.notify(.success)
        } label: { Label(s.copyLink, systemImage: "link") }
    }

    private func actionPill(_ icon: String, _ count: String?, tint: Color?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            if let count { Text(count).monospacedDigit() }
        }
        .foregroundStyle(tint ?? theme.textSecondary)
        .padding(.horizontal, 13).frame(height: 34)
        .background((tint ?? theme.textSecondary).opacity(tint == nil ? 0.10 : 0.14), in: Capsule())
    }

    private var timeText: String {
        let base = agoText(post.createdAt, lang: lang)
        return post.editedAt == nil ? base : base + " · " + s.editedMark
    }

    /// Короткий пост без медиа — крупным шрифтом
    private var textSize: CGFloat {
        post.media.isEmpty && post.text.count <= 60 && post.entities.isEmpty ? 24 : 16
    }

    var body: some View {
        if let note = hiddenNote {
            HStack(spacing: 10) {
                Image(systemName: "eye.slash").foregroundStyle(theme.textSecondary)
                Text(note).font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                Spacer()
                Button(s.t("Вернуть", "Undo")) {
                    withAnimation { hiddenNote = nil }
                }
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accentColor)
            }
            .padding(16)
            .transition(.opacity)
        } else {
            cardBody
        }
    }

    private var reportReasons: [(String, String)] {
        [("spam", s.t("Спам", "Spam")), ("violence", s.t("Насилие", "Violence")),
         ("adult", s.t("Контент для взрослых", "Adult content")), ("illegal", s.t("Незаконный контент", "Illegal content")),
         ("copyright", s.t("Нарушение авторских прав", "Copyright")), ("other", s.t("Другое", "Other"))]
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { onOpenAuthor?(post.author) } label: {
                    AvatarView(name: post.author.name, size: 46, avatarID: post.author.avatarID)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(onOpenAuthor == nil)

                VStack(alignment: .leading, spacing: 2) {
                    Text(post.author.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.text)
                    HStack(spacing: 5) {
                        if let username = post.author.username {
                            Text("@\(username)")
                            Text("·")
                        }
                        Text(timeText)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                }

                Spacer()

                Menu {
                    shareItems
                    if post.isMine {
                        if let onEdit {
                            Button(action: onEdit) {
                                Label(s.editPost, systemImage: "pencil")
                            }
                        }
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label(s.deletePost, systemImage: "trash")
                        }
                    } else {
                        Button {
                            Haptics.impact(.medium)
                            session.taste.notInterested(post.id)
                            withAnimation { hiddenNote = s.t("Скрыто. Похожее будем показывать реже", "Hidden. We'll show less like this") }
                        } label: { Label(s.t("Не интересует", "Not interested"), systemImage: "hand.thumbsdown") }
                        Button(role: .destructive) { reportAsk = true } label: {
                            Label(s.t("Пожаловаться", "Report"), systemImage: "exclamationmark.bubble")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 36, height: 36)
                }
            }

            if !post.text.isEmpty {
                FormattedText(text: post.text, entities: post.entities, size: textSize)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !post.media.isEmpty {
                MediaGrid(media: post.media, autoplay: autoplay) { viewer = ViewerRoute(index: $0) }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(theme.stroke, lineWidth: 1))
            }

            HStack(spacing: 8) {
                Button(action: onLike) {
                    actionPill(post.likedByMe ? "heart.fill" : "heart", "\(post.likes)",
                               tint: post.likedByMe ? theme.like : nil)
                        .symbolEffect(.bounce, value: post.likedByMe)
                }

                if post.isMine && post.likes > 0 {
                    Button { showLikers = true } label: {
                        actionPill("person.2.fill", nil, tint: nil)
                    }
                    .accessibilityLabel(s.t("Кто лайкнул", "Who liked"))
                }

                Button(action: onComments) {
                    actionPill(post.commentsEnabled || post.isMine ? "bubble.right" : "bubble.right.fill", "\(post.comments)", tint: nil)
                }

                Spacer()

                Button {
                    bookmarks.toggle(post.id); Haptics.impact(.light)
                } label: {
                    actionPill(bookmarks.has(post.id) ? "bookmark.fill" : "bookmark",
                               bookmarks.count(for: post) > 0 ? "\(bookmarks.count(for: post))" : nil,
                               tint: bookmarks.has(post.id) ? theme.accentColor : nil)
                }

                Menu { shareItems } label: {
                    actionPill("arrowshape.turn.up.right", nil, tint: nil)
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .sheet(isPresented: $showLikers) {
            PostLikersSheet(postID: post.id, count: post.likes)
                .environmentObject(session)
                .environmentObject(flow)
                .environment(\.theme, theme)
                .presentationDetents([.medium, .large])
                .presentationBackground(theme.sheet)
        }
        .padding(16)
        .confirmationDialog(s.t("На что жалуетесь?", "What's wrong?"), isPresented: $reportAsk, titleVisibility: .visible) {
            ForEach(reportReasons, id: \.0) { item in
                Button(item.1) {
                    let id = post.id
                    Task { try? await session.extras.reportPost(id: id, reason: item.0) }
                    Haptics.notify(.success)
                    withAnimation { hiddenNote = s.t("Жалоба отправлена. Спасибо!", "Report sent. Thank you!") }
                }
            }
            Button(s.cancel, role: .cancel) {}
        }
        .confirmationDialog(s.deletePostQuestion, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(s.delete, role: .destructive, action: onDelete)
            Button(s.cancel, role: .cancel) {}
        } message: {
            Text(s.deletePostHint)
        }
        .fullScreenCover(item: $viewer) { route in
            MediaViewer(media: post.media, start: route.index)
        }
        .sheet(isPresented: $sendSheet) {
            SendToChatSheet(postID: post.id)
                .environmentObject(session)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
    }
}
