import SwiftUI
import AVFoundation
import Combine

// MARK: - Модель ленты коротких видео

@MainActor
final class ReelsModel: ObservableObject {
    enum Kind { case friends, forYou }

    @Published var kind: Kind = .forYou
    @Published private(set) var reels: [Reel] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published var failed: String?

    private var exhausted = false
    private var generation = 0

    func switchTo(_ new: Kind, session: AppSession) {
        guard new != kind else { return }
        kind = new
        reels = []
        loaded = false
        exhausted = false
        generation += 1
        Task { await loadMore(session: session) }
    }

    func loadMore(session: AppSession) async {
        guard !loading, !exhausted else { return }
        loading = true
        let gen = generation
        defer { if gen == generation { loading = false } }
        do {
            let batch = try await session.extras.reels(friendsOnly: kind == .friends, exclude: reels.map(\.id))
            guard gen == generation else { return }
            let known = Set(reels.map(\.id))
            let fresh = batch.filter { !known.contains($0.id) }
            if fresh.isEmpty { exhausted = true } else { reels += fresh }
            failed = nil
        } catch {
            guard gen == generation else { return }
            failed = Strings(lang: .ru).api((error as? APIError) ?? .offline)
        }
        loaded = true
    }

    func refresh(session: AppSession) async {
        generation += 1
        loading = false
        exhausted = false
        reels = []
        loaded = false
        await loadMore(session: session)
    }

    func toggleLike(_ id: String, session: AppSession) {
        guard let i = reels.firstIndex(where: { $0.id == id }) else { return }
        reels[i].post.likedByMe.toggle()
        reels[i].post.likes += reels[i].post.likedByMe ? 1 : -1
        let liked = reels[i].post.likedByMe
        Task {
            do { try await session.feedRepo.setLike(postID: id, liked: liked) } catch {
                if let j = reels.firstIndex(where: { $0.id == id }) {
                    reels[j].post.likedByMe = !liked
                    reels[j].post.likes += liked ? -1 : 1
                }
            }
        }
    }

    func remove(_ id: String) { reels.removeAll { $0.id == id } }

    /// Готовый список (шортсы под один звук): без подгрузки
    func seed(_ list: [Reel]) {
        reels = list
        loaded = true
        exhausted = true
    }

    func toggleRepost(_ id: String, session: AppSession) {
        guard let i = reels.firstIndex(where: { $0.id == id }), !reels[i].post.isMine else { return }
        reels[i].post.repostedByMe.toggle()
        reels[i].post.reposts += reels[i].post.repostedByMe ? 1 : -1
        let on = reels[i].post.repostedByMe
        Task {
            do { try await session.extras.setReposted(id: id, on: on) } catch {
                if let j = reels.firstIndex(where: { $0.id == id }) {
                    reels[j].post.repostedByMe = !on
                    reels[j].post.reposts += on ? -1 : 1
                }
            }
        }
    }

    func like(_ id: String, session: AppSession) {
        guard let r = reels.first(where: { $0.id == id }), !r.post.likedByMe else { return }
        toggleLike(id, session: session)
    }

    /// Новый шортс только что опубликован — показываем его первым во вкладке «Друзья» (там видны и свои)
    func showMine(session: AppSession) async {
        kind = .friends
        await refresh(session: session)
    }

    func setState(_ id: String, _ state: String) {
        for i in reels.indices where reels[i].post.author.id == reels.first(where: { $0.id == id })?.post.author.id {
            reels[i].state = state
        }
    }

    func refreshPost(_ id: String, session: AppSession) async {
        guard let fresh = try? await session.feedRepo.post(id: id), let i = reels.firstIndex(where: { $0.id == id }) else { return }
        reels[i].post.comments = fresh.comments
        reels[i].post.likes = fresh.likes
        reels[i].post.saves = fresh.saves
        reels[i].post.savedByMe = fresh.savedByMe
        reels[i].post.reposts = fresh.reposts
        reels[i].post.repostedByMe = fresh.repostedByMe
    }
}

// MARK: - Экран «Шортс»

struct ReelsView: View {
    var onOpenAuthor: (Author) -> Void
    var suspended = false          // поверх открыт профиль — звук и видео стоят
    /// Режим «один звук»: показываем заданный список, начиная с startID, и кнопку «назад» вместо вкладок
    var fixed: [Reel]? = nil
    var startID: String? = nil
    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @StateObject private var model = ReelsModel()
    @State private var current: String?
    @State private var commentsFor: Post?
    @State private var shareFor: Post?
    @State private var showComposer = false
    @State private var musicFor: PostMusic?

    private var s: Strings { Strings(lang: lang) }
    private var onCompose: () -> Void { { showComposer = true } }
    private func closeComments() {
        commentsFor = nil
        if let id = current { Task { await model.refreshPost(id, session: session) } }
    }
    /// «Не интересует»: учитываем в рекомендациях и сразу листаем к соседнему ролику
    private func hide(_ reel: Reel) {
        session.taste.notInterested(reel.id)
        let i = currentIndex
        let next = model.reels.indices.contains(i + 1) ? model.reels[i + 1].id : (i > 0 ? model.reels[i - 1].id : nil)
        Haptics.impact(.medium)
        withAnimation(.easeInOut(duration: 0.3)) {
            current = next
            model.remove(reel.id)
        }
    }
    private var currentIndex: Int { model.reels.firstIndex { $0.id == current } ?? 0 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                ZStack {
                    if model.reels.isEmpty {
                        emptyState
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(model.reels.enumerated()), id: \.element.id) { index, reel in
                                    ReelPage(reel: reel,
                                             active: reel.id == current,
                                             near: abs(index - currentIndex) <= 1,
                                             suspended: suspended || showComposer || musicFor != nil,       // пока открыто «выложить видео», текущий ролик стоит
                                             topInset: topInset,
                                             bottomClear: bottomClear,
                                             onLike: { model.toggleLike(reel.id, session: session) },
                                             onDoubleLike: { model.like(reel.id, session: session) },
                                             onComments: { commentsFor = reel.post },
                                             onShare: { shareFor = reel.post },
                                             onRepost: { model.toggleRepost(reel.id, session: session) },
                                             onMusic: { if fixed != nil { onClose?() } else if let m = reel.post.music { musicFor = m } },
                                             onAuthor: { onOpenAuthor(reel.post.author) },
                                             onFollow: { follow(reel) },
                                             onHide: { hide(reel) })
                                        .frame(width: geo.size.width, height: geo.size.height)
                                        .id(reel.id)
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.paging)
                        .scrollPosition(id: $current)
                        .ignoresSafeArea()
                    }
                    topBar
                }
            }
            .ignoresSafeArea()                                   // видео на весь экран, до самых краёв (как в TikTok)
        }
        .preferredColorScheme(.dark)
        .task {
            configureAudio()
            session.player.stop()
            if let fixed {
                if model.reels.isEmpty { model.seed(fixed) }
                if current == nil { current = startID ?? fixed.first?.id }
                return
            }
            if model.reels.isEmpty { await model.loadMore(session: session) }
            if current == nil { current = model.reels.first?.id }
        }
        .onChange(of: model.reels.first?.id) { _, id in if current == nil || !model.reels.contains(where: { $0.id == current }) { current = id } }
        .onChange(of: current) { _, _ in
            if fixed == nil, currentIndex >= model.reels.count - 3 { Task { await model.loadMore(session: session) } }
        }
        .overlay {
            // комментарии — панель на всю ширину экрана, без зазоров по бокам (системная шторка на iOS 26 «плавает»)
            if let post = commentsFor {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.45).ignoresSafeArea()
                        .onTapGesture { closeComments() }
                    CommentsSheet(post: post, vm: session.feed, onClose: { closeComments() })
                        .environmentObject(session).environmentObject(flow)
                        .environment(\.theme, theme).environment(\.lang, lang)
                        .frame(maxWidth: .infinity)
                        .frame(height: UIScreen.main.bounds.height * 0.7)
                        .background(theme.sheet)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous))
                        .ignoresSafeArea(.container, edges: .bottom)
                        .transition(.move(edge: .bottom))
                }
                .zIndex(30)
            }
        }
        .animation(.easeOut(duration: 0.25), value: commentsFor?.id)
        .fullScreenCover(item: $musicFor) { music in
            ReelMusicPage(music: music)
                .environmentObject(session).environmentObject(flow)
                .environment(\.theme, theme).environment(\.lang, lang)
        }
        .fullScreenCover(isPresented: $showComposer) {
            ReelComposerView { await model.showMine(session: session); current = model.reels.first?.id }
                .environmentObject(session).environmentObject(flow)
                .environment(\.theme, theme).environment(\.lang, lang)
        }
        .sheet(item: $shareFor) { post in
            SendToChatSheet(postID: post.id)
                .environmentObject(session)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
    }

    /// Сколько снизу занимает плавающая панель вкладок: подпись и полоса прогресса стоят над ней
    private var bottomClear: CGFloat {
        let bottom = (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.bottom) ?? 34
        return fixed != nil ? bottom + 28 : bottom + 76          // в режиме «один звук» нижней панели нет
    }

    private var topInset: CGFloat {
        (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.top) ?? 47
    }

    private func configureAudio() {
        let av = AVAudioSession.sharedInstance()
        try? av.setCategory(.playback, mode: .moviePlayback)
        AudioSessionGate.willActivate()
        try? av.setActive(true)
    }

    private func follow(_ reel: Reel) {
        Haptics.impact(.light)
        let author = reel.post.author.id
        model.setState(reel.id, "outgoing")
        Task {
            if let state = await session.extras.addFriend(id: author) { model.setState(reel.id, state) }
        }
    }

    // MARK: Верх: «Друзья | Рекомендации»

    private var topBar: some View {
        VStack {
            if let onClose {
                HStack {
                    Button { onClose() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(.white.opacity(0.16), in: Circle())
                            .frame(width: 48, height: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, topInset)
            } else {
            HStack(spacing: 18) {
                Color.clear.frame(width: 28, height: 28)
                Spacer(minLength: 0)
                tab(s.t("Друзья", "Friends"), .friends)
                tab(s.t("Рекомендации", "For you"), .forYou)
                Spacer(minLength: 0)
                Button { onCompose() } label: {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, topInset + 4)
            }
            Spacer()
        }
        .allowsHitTesting(true)
    }

    private func tab(_ title: String, _ kind: ReelsModel.Kind) -> some View {
        let on = model.kind == kind
        return Button {
            Haptics.select()
            current = nil
            model.switchTo(kind, session: session)
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                if current == nil { current = model.reels.first?.id }
            }
        } label: {
            VStack(spacing: 5) {
                Text(title)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)       // «Рекомендации» всегда в одну строку
                    .font(.system(size: 18, weight: on ? .bold : .semibold))
                    .foregroundStyle(on ? Color.white : Color.white.opacity(0.62))
                    .shadow(color: .black.opacity(0.55), radius: 3)
                Capsule().fill(Color.white).frame(width: 26, height: 3).opacity(on ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 14) {
            if model.loading || !model.loaded {
                ProgressView().tint(.white).scaleEffect(1.3)
            } else {
                Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 44, weight: .light)).foregroundStyle(.white.opacity(0.7))
                Text(model.failed ?? (model.kind == .friends
                                       ? s.t("У друзей пока нет коротких видео", "Your friends have no short videos yet")
                                       : s.t("Пока нет коротких видео", "No short videos yet")))
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
                Button { onCompose() } label: {
                    Text(s.t("Опубликовать видео", "Post a video"))
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 22).frame(height: 44)
                        .background(Color(red: 1, green: 0.17, blue: 0.33), in: Capsule())
                }
                .buttonStyle(.plain)
                Button { Task { await model.refresh(session: session) } } label: {
                    Text(s.t("Обновить", "Refresh")).font(.system(size: 15)).foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Одна страница: видео + правая колонка + подпись

struct ReelPage: View {
    let reel: Reel
    let active: Bool
    let near: Bool
    var suspended = false
    let topInset: CGFloat
    let bottomClear: CGFloat
    var onLike: () -> Void
    var onDoubleLike: () -> Void
    var onComments: () -> Void
    var onShare: () -> Void
    var onRepost: () -> Void
    var onMusic: () -> Void = {}
    var onAuthor: () -> Void
    var onFollow: () -> Void
    var onHide: () -> Void = {}

    @EnvironmentObject private var session: AppSession
    @Environment(\.lang) private var lang
    @ObservedObject private var bookmarks = BookmarkStore.shared

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var progress: Double = 0
    @State private var playing = false
    @State private var userPaused = false
    @State private var fast = false
    @State private var ready = false
    @State private var burst = 0
    @State private var hearts: [FloatingHeart] = []
    @State private var expanded = false
    @State private var scrubbing = false
    // учёт просмотра
    @State private var watched: Double = 0
    @State private var playingSince: Date?

    private var s: Strings { Strings(lang: lang) }
    private var post: Post { reel.post }
    private var video: MediaItem? { post.media.first { $0.kind == .video } ?? post.media.first }
    private var duration: Double { video?.duration ?? 0 }
    /// Вертикальное видео (9:16 и близкие) растягивается на весь экран, горизонтальное — по центру с чёрными полосами
    private var fill: Bool { (video?.aspect ?? 1) < 0.7 }
    private let red = Color(red: 1, green: 0.17, blue: 0.33)

    struct FloatingHeart: Identifiable { let id = UUID(); let point: CGPoint; let tilt: Double }

    var body: some View {
        ZStack {
            Color.black
            videoLayer
            LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .init(x: 0.5, y: 0.5), endPoint: .bottom)
                .allowsHitTesting(false)
            LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.18))
                .allowsHitTesting(false)

            // касания: один — пауза, два — сердечко
            GeometryReader { geo in
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2, coordinateSpace: .local) { point in
                        onDoubleLike()
                        let h = FloatingHeart(point: point, tilt: Double.random(in: -18...18))
                        hearts.append(h)
                        Haptics.impact(.medium)
                        Task {
                            try? await Task.sleep(nanoseconds: 900_000_000)
                            hearts.removeAll { $0.id == h.id }
                        }
                    }
                    .onTapGesture { togglePause() }
                    // удержание — ускорение ×2, отпустили — обычная скорость
                    .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 40, perform: {
                        guard active, !userPaused else { return }
                        fast = true
                        player?.rate = 2
                        Haptics.impact(.light)
                    }, onPressingChanged: { pressing in
                        if !pressing, fast {
                            fast = false
                            if !userPaused { player?.rate = 1 }
                        }
                    })
                ForEach(hearts) { h in
                    TapHeart(tilt: h.tilt).position(h.point).allowsHitTesting(false)
                }
            }

            if fast {
                Text("2×  ▸▸")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, topInset + 56)
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
            }

            if userPaused && active {
                Image(systemName: "play.fill")
                    .font(.system(size: 64)).foregroundStyle(.white.opacity(0.75))
                    .shadow(color: .black.opacity(0.4), radius: 8)
                    .allowsHitTesting(false)
                    .transition(.scale(scale: 1.3).combined(with: .opacity))
            }

            VStack(spacing: 0) {
                Spacer()
                HStack(alignment: .bottom, spacing: 0) {
                    caption
                    Spacer(minLength: 12)
                    rail
                }
                .padding(.leading, 14).padding(.trailing, 8).padding(.bottom, 10)
                progressBar
                    .padding(.horizontal, 14)
                Color.clear.frame(height: bottomClear)         // место под плавающую панель вкладок
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: userPaused)
        .onChange(of: near) { _, now in now ? makePlayer() : destroyPlayer() }
        .onChange(of: active) { _, now in now ? activate() : deactivate() }
        .onChange(of: suspended) { _, now in
            guard active else { return }
            if now { pauseClock(); player?.pause() }
            else if !userPaused { player?.play(); startClock() }
        }
        .onAppear {
            if near { makePlayer() }
            if active { activate() }
        }
        .onDisappear { deactivate(); destroyPlayer() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            if active { pauseClock() ; player?.pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if active, !userPaused { player?.play(); startClock() }
        }
    }

    // MARK: Видео

    @ViewBuilder
    private var videoLayer: some View {
        ZStack {
            if let v = video {
                if !ready {
                    RemoteImage(id: v.thumbID ?? v.id, fill: fill)
                }
                if let player {
                    PlayerLayerView(player: player, gravity: fill ? .resizeAspectFill : .resizeAspect)
                        .opacity(ready ? 1 : 0)
                }
            }
        }
    }

    private func makePlayer() {
        guard player == nil, let v = video, let url = ServerConfig.mediaURL(v.id) else { return }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .none
        p.automaticallyWaitsToMinimizeStalling = true
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { t in
            let d = p.currentItem?.duration.seconds ?? 0
            if d.isFinite, d > 0, !scrubbing { progress = min(1, t.seconds / d) }
            if !ready, t.seconds > 0.05 { ready = true }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            p.seek(to: .zero)
            if active, !userPaused { p.play() }
        }
        player = p
        if active, !userPaused { p.play(); startClock() }
    }

    private func destroyPlayer() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        ready = false
        progress = 0
    }

    private func activate() {
        watched = 0
        playingSince = nil
        userPaused = false
        player?.seek(to: .zero)
        player?.play()
        startClock()
    }

    private func deactivate() {
        pauseClock()
        let seconds = watched
        watched = 0
        player?.pause()
        if seconds > 0.1 {
            let ratio = duration > 0 ? seconds / duration : 0
            session.taste.reelEnded(post.id, seconds: seconds, ratio: ratio)
        }
    }

    private func startClock() { if playingSince == nil { playingSince = Date(); playing = true } }

    private func pauseClock() {
        if let since = playingSince { watched += Date().timeIntervalSince(since) }
        playingSince = nil
        playing = false
    }

    private func togglePause() {
        guard let player else { return }
        if userPaused {
            userPaused = false
            player.play()
            startClock()
        } else {
            userPaused = true
            player.pause()
            pauseClock()
        }
        Haptics.impact(.light)
    }

    // MARK: Подпись

    private let collapsedLimit = 62

    /// Текст подписи: хэштеги жирным, в свёрнутом виде — обрезка и «ещё», как в TikTok
    private var captionText: Text {
        captionAttributed
    }

    private var captionAttributed: Text {
        let full = post.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = !expanded && full.count > collapsedLimit
        let shown = cut ? String(full.prefix(collapsedLimit)).trimmingCharacters(in: .whitespaces) + "… " : full
        var result = AttributedString()
        for (i, word) in shown.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            var piece = AttributedString((i == 0 ? "" : " ") + String(word))
            if word.hasPrefix("#") || word.hasPrefix("@") {
                piece.font = .system(size: 16, weight: .bold)
            } else if let url = Linkify.url(in: String(word)) {
                piece.link = url
                piece.underlineStyle = .single
            }
            result.append(piece)
        }
        if cut {
            var more = AttributedString(s.t("ещё", "more"))
            more.font = .system(size: 16, weight: .bold)
            more.foregroundColor = .white.opacity(0.85)
            result.append(more)
        }
        return Text(result)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(action: onAuthor) {
                Text(post.author.username.map { "@" + $0 } ?? post.author.name)
                    .font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            if let music = post.music {
                Button(action: onMusic) {
                    HStack(spacing: 5) {
                        Image(systemName: "music.note").font(.system(size: 12, weight: .bold))
                        Text(music.display).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            if !post.text.isEmpty {
                captionText
                    .font(.system(size: 16)).foregroundColor(.white)
                    .tint(.white)
                    .lineSpacing(2)
                    .lineLimit(expanded ? 14 : 3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } }
            }
        }
        .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    // MARK: Правая колонка

    private var saved: Bool { bookmarks.has(post.id) }

    private var rail: some View {
        VStack(spacing: 13) {
            avatarButton
            railButton(count: short(post.likes), action: { if !post.likedByMe { burst += 1; Haptics.impact(.medium) }; onLike() }) {
                StoryHeart(liked: post.likedByMe, burst: burst, size: 40, solidWhenIdle: true)
            }
            railButton(count: short(post.comments), action: onComments) {
                ReelCommentIcon().frame(width: 32, height: 30)
            }
            .opacity(post.commentsEnabled ? 1 : 0.4)
            .disabled(!post.commentsEnabled)
            railButton(count: short(bookmarks.count(for: post)), action: {
                bookmarks.toggle(post.id); Haptics.impact(.light)
            }) {
                ReelBookmarkShape()
                    .fill(saved ? Color(red: 1, green: 0.8, blue: 0.2) : Color(white: 0.93))
                    .overlay(ReelBookmarkShape().stroke(saved ? Color(red: 1, green: 0.8, blue: 0.2) : Color(white: 0.93),
                                                        style: StrokeStyle(lineWidth: 2, lineJoin: .round)))
                    .frame(width: 25, height: 31)
                    .scaleEffect(saved ? 1.08 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: saved)
            }
            if !post.isMine {
                railButton(count: short(post.reposts), action: { Haptics.impact(.light); onRepost() }) {
                    Image(systemName: "arrow.2.squarepath").font(.system(size: 29, weight: .bold))
                        .foregroundStyle(post.repostedByMe ? Color(red: 0.25, green: 0.88, blue: 0.62) : Color(white: 0.93))
                        .scaleEffect(post.repostedByMe ? 1.08 : 1)
                        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: post.repostedByMe)
                }
            }
            railButton(count: s.t("Отправить", "Share"), action: onShare) {
                ReelShareShape().fill(Color(white: 0.93))
                    .overlay(ReelShareShape().stroke(Color(white: 0.93), style: StrokeStyle(lineWidth: 2, lineJoin: .round)))
                    .frame(width: 32, height: 28)
            }
            if !post.isMine {
                Menu {
                    Button(role: .destructive, action: onHide) {
                        Label(s.t("Не интересует", "Not interested"), systemImage: "hand.thumbsdown")
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 22, weight: .bold)).foregroundStyle(Color(white: 0.93))
                        .frame(width: 44, height: 30).contentShape(Rectangle())
                }
            }
            Button(action: onMusic) { musicDisc.frame(width: 48, height: 52).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .disabled(post.music == nil)
        }
        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
        .padding(.bottom, 2)
    }

    /// Вращающийся диск в углу: обложка/значок музыки, если она есть, иначе аватарка автора
    private var musicDisc: some View {
        TimelineView(.animation(paused: !(active && playing && !userPaused))) { ctx in
            let angle = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) / 6 * 360
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().stroke(Color(white: 0.3), lineWidth: 1).padding(4)
                if post.music != nil {
                    Circle().fill(LinearGradient(colors: [Color(red: 0.55, green: 0.35, blue: 1), Color(red: 1, green: 0.35, blue: 0.6)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 26, height: 26)
                        .overlay(Image(systemName: "music.note").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
                } else {
                    AvatarView(name: post.author.name, size: 26, avatarID: post.author.avatarID).clipShape(Circle())
                }
            }
            .rotationEffect(.degrees(angle))
        }
        .frame(width: 42, height: 42)
        .padding(.top, 4)
    }

    private var avatarButton: some View {
        ZStack(alignment: .bottom) {
            Button(action: onAuthor) {
                AvatarView(name: post.author.name, size: 52, avatarID: post.author.avatarID).clipShape(Circle())
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            if reel.state == "none" || reel.state == "incoming" {
                Button(action: onFollow) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .heavy)).foregroundStyle(.white)
                        .frame(width: 23, height: 23).background(red, in: Circle())
                }
                .buttonStyle(.plain)
                .offset(y: 11)
                .transition(.scale.combined(with: .opacity))
            } else if reel.state == "outgoing" {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(red)
                    .frame(width: 23, height: 23).background(Color.white, in: Circle())
                    .offset(y: 11)
            }
        }
        .padding(.bottom, 10)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: reel.state)
    }

    private func railButton<Icon: View>(count: String, action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                icon().frame(height: 40)
                Text(count).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(RailPress())
    }

    /// 1 234 → «1,2 тыс.», как в TikTok
    private func short(_ n: Int) -> String {
        func one(_ v: Double) -> String {
            let r = (v * 10).rounded() / 10
            return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r).replacingOccurrences(of: ".", with: ",")
        }
        if n >= 1_000_000 { return one(Double(n) / 1_000_000) + (lang == .ru ? " млн" : "M") }
        if n >= 1000 { return one(Double(n) / 1000) + (lang == .ru ? " тыс." : "K") }
        return "\(n)"
    }

    // MARK: Полоса прогресса: тонкая линия с точкой, при касании толстеет

    private var progressBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = max(0, min(w, w * progress))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28)).frame(height: scrubbing ? 5 : 2.5)
                Capsule().fill(.white).frame(width: max(5, x), height: scrubbing ? 5 : 2.5)
                Circle().fill(.white).frame(width: scrubbing ? 13 : 7, height: scrubbing ? 13 : 7)
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .offset(x: max(0, x - (scrubbing ? 6.5 : 3.5)))
            }
            .frame(height: 26)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    scrubbing = true
                    let f = max(0, min(1, v.location.x / max(1, w)))
                    progress = f
                    if let item = player?.currentItem, item.duration.seconds.isFinite {
                        player?.seek(to: CMTime(seconds: item.duration.seconds * f, preferredTimescale: 600),
                                     toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
                .onEnded { _ in scrubbing = false })
        }
        .frame(height: 26)
        .animation(.easeOut(duration: 0.15), value: scrubbing)
    }
}

/// Лёгкое «вдавливание» кнопки в правой колонке
private struct RailPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Сердечко от двойного тапа

struct TapHeart: View {
    let tilt: Double
    @State private var go = false

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 86))
            .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.4, blue: 0.55), Color(red: 1, green: 0.1, blue: 0.3)],
                                            startPoint: .top, endPoint: .bottom))
            .shadow(color: .red.opacity(0.5), radius: 14)
            .rotationEffect(.degrees(tilt))
            .scaleEffect(go ? 1.0 : 0.3)
            .offset(y: go ? -50 : 0)
            .opacity(go ? 0 : 1)
            .onAppear {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { go = false }
                withAnimation(.easeOut(duration: 0.8).delay(0.12)) { go = true }
            }
    }
}


/// Значок комментариев как в TikTok: округлое облачко с хвостиком и тремя точками
struct ReelCommentBubble: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.minY + y * h) }
        var p = Path()
        p.addEllipse(in: CGRect(x: r.minX, y: r.minY, width: w, height: h * 0.84))
        var tail = Path()
        tail.move(to: pt(0.50, 0.76))
        tail.addCurve(to: pt(0.80, 0.99), control1: pt(0.56, 0.90), control2: pt(0.68, 0.99))
        tail.addCurve(to: pt(0.82, 0.68), control1: pt(0.78, 0.90), control2: pt(0.80, 0.80))
        tail.closeSubpath()
        p.addPath(tail)
        return p
    }
}

struct ReelCommentIcon: View {
    var body: some View {
        GeometryReader { g in
            let d = g.size.width * 0.13
            ZStack {
                ReelCommentBubble().fill(Color(white: 0.93))
                    .overlay(ReelCommentBubble().stroke(Color(white: 0.93), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)))
                HStack(spacing: d * 0.8) {
                    ForEach(0..<3, id: \.self) { _ in Circle().frame(width: d, height: d) }
                }
                .blendMode(.destinationOut)
                .offset(y: -g.size.height * 0.08)
            }
            .compositingGroup()
        }
    }
}


// MARK: - Значки правой колонки (как в TikTok)

struct ReelBookmarkShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.minY + y * h) }
        var p = Path()
        p.move(to: pt(0, 0.10))
        p.addQuadCurve(to: pt(0.12, 0), control: pt(0, 0))
        p.addLine(to: pt(0.88, 0))
        p.addQuadCurve(to: pt(1, 0.10), control: pt(1, 0))
        p.addLine(to: pt(1, 1))
        p.addLine(to: pt(0.5, 0.72))
        p.addLine(to: pt(0, 1))
        p.closeSubpath()
        return p
    }
}

struct ReelShareShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.minY + y * h) }
        var p = Path()
        p.move(to: pt(0.62, 0.03))
        p.addLine(to: pt(0.98, 0.38))
        p.addLine(to: pt(0.62, 0.74))
        p.addLine(to: pt(0.62, 0.55))
        p.addCurve(to: pt(0.04, 0.97), control1: pt(0.30, 0.55), control2: pt(0.10, 0.74))
        p.addCurve(to: pt(0.62, 0.23), control1: pt(0.06, 0.46), control2: pt(0.30, 0.24))
        p.closeSubpath()
        return p
    }
}
