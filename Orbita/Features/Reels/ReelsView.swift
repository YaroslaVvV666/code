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
    /// Какой ролик смотрели последним: вернулись во вкладку — продолжаем с него
    var resumeID: String?

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

    @Published var refreshing = false

    func refresh(session: AppSession) async {
        refreshing = true
        defer { refreshing = false }
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
    /// Ролик, на который пришли по ссылке (из чата): он первый, дальше идут рекомендации
    func pin(_ post: Post) {
        reels = [Reel(post: post, state: post.isMine ? "me" : "none")]
        loaded = true
    }

    /// Ролик, присланный в чат: ставим первым в ленте
    func insertFirst(_ post: Post) {
        reels.removeAll { $0.id == post.id }
        reels.insert(Reel(post: post, state: post.isMine ? "me" : "none"), at: 0)
        loaded = true
    }

    func seed(_ list: [Reel]) {
        reels = list
        loaded = true
        exhausted = true
    }

    func toggleRepost(_ id: String, session: AppSession) {
        guard let i = reels.firstIndex(where: { $0.id == id }),
              reels[i].post.allowRepost || reels[i].post.isMine || reels[i].post.repostedByMe else { return }
        reels[i].post.repostedByMe.toggle()
        reels[i].post.reposts = max(0, reels[i].post.reposts + (reels[i].post.repostedByMe ? 1 : -1))
        let on = reels[i].post.repostedByMe
        Task {
            do {
                // число и состояние берём у сервера — так счётчик всегда настоящий
                if let r = try await session.extras.setReposted(id: id, on: on), let j = reels.firstIndex(where: { $0.id == id }) {
                    reels[j].post.reposts = r.count
                    reels[j].post.repostedByMe = r.mine
                }
            } catch {
                if let j = reels.firstIndex(where: { $0.id == id }) {
                    reels[j].post.repostedByMe = !on
                    reels[j].post.reposts = max(0, reels[j].post.reposts + (on ? -1 : 1))
                }
                // репост не удался — говорим почему, а не молча откатываем
                notice = Strings(lang: .ru).api((error as? APIError) ?? .offline)
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                notice = nil
            }
        }
    }

    @Published var notice: String?

    func like(_ id: String, session: AppSession) {
        guard let r = reels.first(where: { $0.id == id }), !r.post.likedByMe else { return }
        toggleLike(id, session: session)
    }

    /// Новый шортс только что опубликован — показываем его первым во вкладке «Друзья» (там видны и свои)
    func showMine(session: AppSession) async {
        kind = .friends
        await refresh(session: session)
    }

    /// Авторы, у которых сейчас показана галочка (5 секунд после подписки)
    @Published var checkAuthors: Set<String> = []

    func flashCheck(_ author: String) {
        checkAuthors.insert(author)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            checkAuthors.remove(author)
        }
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
    var pinned: Post? = nil        // открыто по ссылке: этот шортс первым, затем обычная лента
    var onClose: (() -> Void)? = nil

    @ObservedObject private var callActivity = CallActivity.shared      // во время звонка шортсы не играют
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @StateObject private var model: ReelsModel
    @State private var current: String?

    init(onOpenAuthor: @escaping (Author) -> Void, suspended: Bool = false, fixed: [Reel]? = nil, startID: String? = nil,
         pinned: Post? = nil, onClose: (() -> Void)? = nil, shared: ReelsModel? = nil) {
        self.onOpenAuthor = onOpenAuthor
        self.suspended = suspended
        self.fixed = fixed
        self.startID = startID
        self.pinned = pinned
        self.onClose = onClose
        _model = StateObject(wrappedValue: shared ?? ReelsModel())
        // вернулись во вкладку «Шортс» — сразу встаём на тот же ролик
        if fixed == nil, pinned == nil, let shared, let id = shared.resumeID, shared.reels.contains(where: { $0.id == id }) {
            _current = State(initialValue: id)
        }
    }
    @State private var commentsFor: Post?
    @State private var holdFast = false             // палец зажат (ускорение ×2): листать нельзя, пока не отпустишь
    @State private var sheetTall = false            // шторка комментариев раскрыта выше
    @State private var sheetDrag: CGFloat = 0
    @State private var shareFor: Post?
    @State private var showComposer = false
    @State private var showSearch = false          // поиск по шортсам: текущее видео стоит
    @State private var searchQuery = ""            // предзаполненный запрос (нажали на #хэштег)
    @State private var musicFor: PostMusic?
    @State private var soundTrackID = ""

    private var s: Strings { Strings(lang: lang) }
    private var onCompose: () -> Void { { showComposer = true } }
    private func closeComments() {
        commentsFor = nil
        if let id = current { Task { await model.refreshPost(id, session: session) } }
    }
    /// Скачать шортс в галерею с водяным знаком и ником автора
    private func download(_ post: Post) {
        let ru = lang == .ru
        model.notice = ru ? "Скачиваю…" : "Downloading…"
        Task {
            do {
                try await ReelDownload.run(post)
                Haptics.notify(.success)
                model.notice = ru ? "Сохранено в галерею" : "Saved to Photos"
            } catch ReelDownload.Failure.noAccess {
                model.notice = ru ? "Разрешите доступ к фото в Настройках" : "Allow Photos access in Settings"
            } catch {
                model.notice = ru ? "Не удалось скачать" : "Couldn't download"
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            model.notice = nil
        }
    }
    /// Жалоба: отправляем на сервер и, как «не интересует», убираем ролик из ленты
    private func report(_ post: Post, reason: String) {
        Task {
            try? await session.extras.reportPost(id: post.id, reason: reason)
            model.notice = Strings(lang: lang).t("Жалоба отправлена. Спасибо!", "Report sent. Thank you!")
            if let r = model.reels.first(where: { $0.id == post.id }) { hide(r) }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            model.notice = nil
        }
    }

    /// Автор удаляет своё видео: уходит с сервера, из ленты и со стены
    private func deleteReel(_ post: Post) {
        let ru = Strings(lang: lang)
        Task {
            do {
                try await session.feedRepo.deletePost(id: post.id)
                session.feed.forget(post.id)
                let i = currentIndex
                let next = model.reels.indices.contains(i + 1) ? model.reels[i + 1].id : (i > 0 ? model.reels[i - 1].id : nil)
                Haptics.notify(.success)
                withAnimation(.easeInOut(duration: 0.3)) {
                    if current == post.id { current = next }
                    model.remove(post.id)
                }
                model.notice = ru.t("Видео удалено", "Video deleted")
            } catch {
                model.notice = ru.t("Не удалось удалить", "Couldn't delete")
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            model.notice = nil
        }
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
    /// Нажали на присланный в чат шортс: он становится первым в ленте и сразу открывается
    private func openRequested() {
        guard fixed == nil, pinned == nil, let post = session.reelRequest else { return }
        session.reelRequest = nil
        model.insertFirst(post)
        current = post.id
    }
    private var currentIndex: Int { model.reels.firstIndex { $0.id == current } ?? 0 }
    @ObservedObject private var landscapeMode = LandscapeMode.shared
    /// Повёрнутый режим для текущего ролика: верхние вкладки и «+» скрыты
    private var rotatedNow: Bool {
        guard landscapeMode.on, model.reels.indices.contains(currentIndex) else { return false }
        let v = model.reels[currentIndex].post.media.first { $0.kind == .video }
        return (v?.aspect ?? 1) >= 0.7
    }

    private func isLandscape(_ r: Reel) -> Bool {
        let v = r.post.media.first { $0.kind == .video }
        return (v?.aspect ?? 1) >= 0.7
    }

    @State private var kb: CGFloat = 0
    @State private var slideX: CGFloat = 0
    @State private var sliding = false

    /// В повёрнутом режиме «вверх» повёрнутого видео — это вправо на экране: свайп туда — следующее, обратно — предыдущее.
    /// Вертикальный свайп отключён, а лента едет по той же оси, что и палец. Ролики, которые так не показать, пропускаются сразу
    /// Обычное положение: свайп вправо — назад к профилю (если шортсы открыты оттуда), свайп влево — профиль создателя
    private enum SwipeKind { case none, peek, back, vertical }
    @State private var swipeKind: SwipeKind = .none
    @State private var peekID: String?
    @State private var peekX: CGFloat = UIScreen.main.bounds.width
    @State private var peekOpen = false
    @State private var backX: CGFloat = 0
    private var screenW: CGFloat { UIScreen.main.bounds.width }

    private func edgeChanged(_ v: DragGesture.Value) {
        if swipeKind == .vertical { return }
        if swipeKind == .none {
            guard !rotatedNow, commentsFor == nil, !holdFast, peekID == nil,
                  v.startLocation.y < UIScreen.main.bounds.height - bottomClear - 56,        // не мешаем перемотке по полосе внизу
                  model.reels.indices.contains(currentIndex) else { return }
            // ось выбирается один раз в начале жеста: диагональ — это листание, профиль не открывается
            guard abs(v.translation.width) > abs(v.translation.height) * 2.4 else { swipeKind = .vertical; return }
            if v.translation.width < 0 {
                peekID = model.reels[currentIndex].post.creator.id
                swipeKind = .peek
            } else if onClose != nil {
                swipeKind = .back
            } else { return }
        }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            if swipeKind == .peek { peekX = min(screenW, max(0, screenW + v.translation.width)) }
            else if swipeKind == .back { backX = max(0, v.translation.width) }
        }
    }

    private func edgeEnded(_ v: DragGesture.Value) {
        let kind = swipeKind
        swipeKind = .none
        let spring = Animation.spring(response: 0.36, dampingFraction: 0.88)
        switch kind {
        case .peek:
            if v.translation.width < -screenW * 0.28 || v.predictedEndTranslation.width < -screenW * 0.6 {
                Haptics.impact(.light)
                withAnimation(spring) { peekX = 0 }
                peekOpen = true
            } else { closePeek() }
        case .back:
            if v.translation.width > screenW * 0.3 || v.predictedEndTranslation.width > screenW * 0.6 {
                Haptics.impact(.light)
                onClose?()
            } else { withAnimation(spring) { backX = 0 } }
        case .none, .vertical: break
        }
    }

    /// Закрыть выехавший профиль: он уезжает за край, шортс возвращается
    private func closePeek() {
        peekOpen = false
        withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) { peekX = screenW }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 380_000_000)
            if !peekOpen, swipeKind != .peek { peekID = nil }
        }
    }

    private func profilePanel(_ id: String) -> some View {
        PublicProfileSheet(source: .id(id), onClose: { closePeek() })
            .environmentObject(session).environmentObject(flow)
            .environment(\.theme, theme).environment(\.lang, lang)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.sheet.ignoresSafeArea())
            .shadow(color: .black.opacity(0.35), radius: 14, x: -4)
            .offset(x: peekX)
            .simultaneousGesture(DragGesture(minimumDistance: 24)
                .onChanged { v in
                    guard peekOpen, v.translation.width > 0, abs(v.translation.width) > abs(v.translation.height) * 1.4 else { return }
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { peekX = min(screenW, v.translation.width) }
                }
                .onEnded { v in
                    guard peekOpen else { return }
                    if v.translation.width > screenW * 0.3 || v.predictedEndTranslation.width > screenW * 0.6,
                       abs(v.translation.width) > abs(v.translation.height) {
                        Haptics.impact(.light); closePeek()
                    } else {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) { peekX = 0 }
                    }
                })
    }

    private func rotatedSwipe(_ v: DragGesture.Value) {
        guard rotatedNow, !sliding, abs(v.translation.width) > 50, abs(v.translation.width) > abs(v.translation.height) * 1.2 else { return }
        let step = v.translation.width > 0 ? 1 : -1
        var i = currentIndex + step
        while model.reels.indices.contains(i), !isLandscape(model.reels[i]) { i += step }
        guard model.reels.indices.contains(i) else {
            if step > 0, fixed == nil { Task { await model.loadMore(session: session) } }
            return
        }
        let target = model.reels[i].id
        let w = UIScreen.main.bounds.width
        sliding = true
        Haptics.impact(.light)
        withAnimation(.easeIn(duration: 0.16)) { slideX = CGFloat(step) * w }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 170_000_000)
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { current = target; slideX = CGFloat(-step) * w }
            try? await Task.sleep(nanoseconds: 40_000_000)
            withAnimation(.easeOut(duration: 0.24)) { slideX = 0 }
            try? await Task.sleep(nanoseconds: 240_000_000)
            sliding = false
        }
    }

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
                                             suspended: suspended || showComposer || showSearch || session.mediaHeld || musicFor != nil || peekOpen || callActivity.active,       // пока открыто «выложить видео», текущий ролик стоит
                                             topInset: topInset,
                                             bottomClear: bottomClear,
                                             onLike: { model.toggleLike(reel.id, session: session) },
                                             onDoubleLike: { model.like(reel.id, session: session) },
                                             onComments: { commentsFor = reel.post },
                                             onShare: { shareFor = reel.post },
                                             onRepost: { model.toggleRepost(reel.id, session: session) },
                                             onMusic: { if fixed != nil { onClose?() } else if let m = reel.post.music { musicFor = m } },
                                             onAuthor: { onOpenAuthor(reel.post.author) },
                                             onOpenUser: { onOpenAuthor($0) },
                                             onOpenTag: { tag in searchQuery = "#" + tag; showSearch = true },
                                             onHold: { holdFast = $0 },
                                             onFollow: { follow(reel) },
                                             onUnfollow: { unfollow(reel) },
                                             showCheck: model.checkAuthors.contains(reel.post.author.id),
                                             onHide: { hide(reel) })
                                        .containerRelativeFrame([.horizontal, .vertical])      // страница ровно по окну ленты: соседний ролик не заезжает и страница не сдвигается
                                        .clipped()                                             // и ничего не рисуется за пределами своей страницы
                                        .id(reel.id)
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.paging)
                        .scrollClipDisabled(false)
                        .scrollDisabled(holdFast || rotatedNow || swipeKind == .peek || swipeKind == .back)
                        .offset(x: slideX)
                        .scrollPosition(id: $current)
                        .ignoresSafeArea()
                    }
                    if !rotatedNow { topBar }
                }
                .frame(width: geo.size.width, height: geo.size.height)      // что бы ни случилось внутри, лента не шире экрана и не съезжает
            }
            .simultaneousGesture(DragGesture(minimumDistance: 30)
                .onChanged { if !rotatedNow { edgeChanged($0) } }
                .onEnded { rotatedNow ? rotatedSwipe($0) : edgeEnded($0) })
            .offset(x: peekID != nil ? -(screenW - peekX) * 0.28 : backX)
            .overlay { Color.black.opacity(peekID != nil ? 0.45 * Double(1 - peekX / screenW) : 0.35 * Double(backX / screenW)).allowsHitTesting(false) }
            .ignoresSafeArea()                                   // видео на весь экран, до самых краёв (как в TikTok)
        }
        .overlay { if let id = peekID { profilePanel(id) } }
        .overlay {
            // идёт звонок — ролики стоят, по центру подсказка; кнопки шортсов (закрыть, профиль) по-прежнему нажимаются
            if callActivity.active {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 12) {
                        Image(systemName: "phone.fill").font(.system(size: 28, weight: .semibold)).foregroundStyle(.green)
                        Text(CallGate.message(lang, .shorts))
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .multilineTextAlignment(.center).padding(.horizontal, 40)
                    }
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: callActivity.active)
        .onChange(of: peekID) { _, id in session.tabBarHidden = id != nil || commentsFor != nil }
        .preferredColorScheme(.dark)
        .task {
            configureAudio()
            session.player.stop()
            if let fixed {
                // сначала выбираем стартовый ролик, потом показываем ленту: тогда она сразу стоит на нём и листается и с первого
                if current == nil { current = startID ?? fixed.first?.id }
                if model.reels.isEmpty { model.seed(fixed) }
                return
            }
            if let pinned, model.reels.isEmpty { model.pin(pinned); current = pinned.id }
            openRequested()
            if model.reels.count < 2 { await model.loadMore(session: session) }
            if current == nil { current = model.reels.first?.id }
        }
        .onChange(of: session.reelRequest?.id) { _, id in if id != nil { openRequested() } }
        .onChange(of: rotatedNow) { _, on in if commentsFor == nil { session.tabBarHidden = on } }
        .overlay(alignment: .top) {
            if let text = model.notice { ToastView(text: text).padding(.top, topInset + 8).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.2), value: model.notice)
        .onChange(of: model.reels.first?.id) { _, id in if current == nil || !model.reels.contains(where: { $0.id == current }) { current = id } }
        .onChange(of: current) { _, new in
            if fixed == nil, let new { model.resumeID = new }
            if fixed == nil, currentIndex >= model.reels.count - 3 { Task { await model.loadMore(session: session) } }
        }
        .overlay {
            // комментарии — панель на всю ширину экрана, без зазоров по бокам (системная шторка на iOS 26 «плавает»)
            if let post = commentsFor {
                let H = UIScreen.main.bounds.height
                let base = (sheetTall ? 0.93 : 0.7) * H
                let h = min(0.95 * H, max(0.12 * H, base - sheetDrag), max(0.3 * H, H - kb - topInset - 8))
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.45).ignoresSafeArea()
                        .onTapGesture { closeComments() }
                    CommentsSheet(post: post, vm: session.feed, onClose: { closeComments() })
                        .environmentObject(session).environmentObject(flow)
                        .environment(\.theme, theme).environment(\.lang, lang)
                        .frame(maxWidth: .infinity)
                        .frame(height: h)
                        .background(theme.sheet)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous))
                        .overlay(alignment: .top) {
                            // за верхнюю кромку шторку можно тянуть вверх и вниз.
                            // тянем только центральную часть — углы (в т.ч. крестик) остаются нажимаемыми
                            ZStack(alignment: .top) {
                                Capsule().fill(theme.textTertiary.opacity(0.6)).frame(width: 38, height: 5).padding(.top, 8)
                                Color.clear.frame(width: 200, height: 56).contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                                    .onChanged { v in var t = Transaction(); t.disablesAnimations = true
                                        withTransaction(t) { sheetDrag = v.translation.height } }
                                    .onEnded { v in
                                        let final = base - v.translation.height
                                        let predicted = base - v.predictedEndTranslation.height
                                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                            if predicted < 0.45 * H || (!sheetTall && v.translation.height > 140) {
                                                commentsFor = nil
                                                if let id = current { Task { await model.refreshPost(id, session: session) } }
                                            } else {
                                                sheetTall = final > 0.82 * H || predicted > 0.88 * H
                                            }
                                            sheetDrag = 0
                                        }
                                    })
                            }
                            .frame(maxWidth: .infinity)             // полоса во всю ширину, но тянется только центр
                        }
                        .padding(.bottom, kb)                       // клавиатуру учитываем сами: ввод всегда над ней
                        .ignoresSafeArea(.container, edges: .bottom)
                        .transition(.move(edge: .bottom))
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .zIndex(30)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            guard let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let h = max(0, UIScreen.main.bounds.height - f.minY)
            withAnimation(.easeOut(duration: 0.25)) { kb = h }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.88), value: commentsFor?.id)
        .onChange(of: commentsFor?.id) { _, id in
            session.tabBarHidden = id != nil
            if id == nil { sheetTall = false; sheetDrag = 0 }
        }
        .onDisappear { session.tabBarHidden = false; landscapeMode.on = false }       // ушли из шортсов — повёрнутый режим сбрасывается
        .sheet(item: $musicFor, onDismiss: {
            if session.player.current?.id == soundTrackID { session.player.stop() }
        }) { music in
            SoundSheet(music: music)
                .environmentObject(session).environmentObject(flow)
                .environment(\.theme, theme).environment(\.lang, lang)
                .presentationDragIndicator(.hidden)
                .onAppear { soundTrackID = music.mediaID }
        }
        .fullScreenCover(isPresented: $showSearch) {
            ReelSearchView(onClose: { showSearch = false }, initialQuery: searchQuery)
                .environmentObject(session).environmentObject(flow)
                .environment(\.theme, theme).environment(\.lang, lang)
        }
        .fullScreenCover(isPresented: $showComposer) {
            ReelComposerView { await model.showMine(session: session); current = model.reels.first?.id }
                .environmentObject(session).environmentObject(flow)
                .environment(\.theme, theme).environment(\.lang, lang)
        }
        .sheet(item: $shareFor) { post in
            SendToChatSheet(postID: post.id,
                            onDownload: { download(post) },
                            onNotInterested: { if let r = model.reels.first(where: { $0.id == post.id }) { hide(r) } },
                            onReport: { reason in report(post, reason: reason) },
                            onDelete: post.isMine && !post.isRepost ? { deleteReel(post) } : nil)
                .environmentObject(session)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
    }

    /// Сколько снизу занимает плавающая панель вкладок: подпись и полоса прогресса стоят над ней
    private var bottomClear: CGFloat {
        let bottom = (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.bottom) ?? 34
        // кнопки/подпись/полоса прижаты к низу: полоса течения видео почти прилегает к панели вкладок (как в TikTok)
        return fixed != nil ? bottom + 20 : bottom + 40          // в режиме «один звук» нижней панели нет
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
        model.setState(reel.id, "following")
        model.flashCheck(author)
        Task {
            if await session.extras.setFollow(id: author, on: true, source: reel.id) == nil {
                model.setState(reel.id, "none")
                model.checkAuthors.remove(author)
            }
        }
    }

    private func unfollow(_ reel: Reel) {
        Haptics.impact(.light)
        model.setState(reel.id, "none")
        Task { _ = await session.extras.setFollow(id: reel.post.author.id, on: false) }
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
            // вкладки по центру, значки справа поверх: ширина строки никогда не больше экрана (иначе вся лента съезжает вбок)
            ZStack {
                HStack(spacing: 14) {
                    tab(s.t("Друзья", "Friends"), .friends)
                    tab(s.t("Рекомендации", "For you"), .forYou)
                }
                .offset(x: -26)                      // чуть левее, чтобы не липло к поиску
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button { Haptics.impact(.light); searchQuery = ""; showSearch = true } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 19, weight: .medium)).foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .shadow(color: .black.opacity(0.5), radius: 3)
                            .padding(4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(-4)
                    Button { onCompose() } label: {
                        Image(systemName: "video.badge.plus")
                            .font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .shadow(color: .black.opacity(0.5), radius: 3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
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
            if model.kind == kind {
                // уже на этой вкладке — нажатие обновляет ленту
                guard !model.refreshing else { return }
                Haptics.impact(.light)
                Task {
                    await model.refresh(session: session)
                    current = model.reels.first?.id
                }
                return
            }
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
                ZStack {
                    Capsule().fill(Color.white).frame(width: 26, height: 3).opacity(on && !(model.refreshing) ? 1 : 0)
                    if on && model.refreshing {
                        ProgressView().controlSize(.mini).tint(.white).frame(height: 3)
                    }
                }
                .frame(height: 3)
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
    var onOpenUser: (Author) -> Void = { _ in }
    var onOpenTag: (String) -> Void = { _ in }       // нажали на #хэштег в подписи
    var onHold: (Bool) -> Void = { _ in }
    var onFollow: () -> Void
    var onUnfollow: () -> Void = {}
    var showCheck: Bool = false
    var onHide: () -> Void = {}

    @EnvironmentObject private var session: AppSession
    @Environment(\.lang) private var lang
    @Environment(\.openURL) private var systemOpenURL
    @ObservedObject private var bookmarks = BookmarkStore.shared
    @ObservedObject private var scrubBus = ReelScrubBus.shared

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
    @ObservedObject private var mode = LandscapeMode.shared
    @State private var lsControls = false         // кнопки в повёрнутом режиме: показываются по одному нажатию
    @State private var lsHideTask: Task<Void, Never>?
    /// «На весь экран» для горизонтального видео: режим общий — следующее горизонтальное видео тоже откроется повёрнутым
    private var forceFill: Bool { mode.on && landscape }
    @State private var repostSpin = 0
    @State private var repostsOpen = false
    // учёт просмотра
    @State private var watched: Double = 0
    @State private var playingSince: Date?

    static var safeBottom: CGFloat {
        (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.bottom) ?? 34
    }

    private var s: Strings { Strings(lang: lang) }
    private var post: Post { reel.post }
    private var video: MediaItem? { post.media.first { $0.kind == .video } ?? post.media.first }
    private var duration: Double { video?.duration ?? 0 }
    /// Вертикальное видео (9:16 и близкие) растягивается на весь экран, горизонтальное — по центру с чёрными полосами
    private var fill: Bool { (video?.aspect ?? 1) < 0.7 }
    private var landscape: Bool { (video?.aspect ?? 1) >= 0.7 }
    private let red = Color(red: 1, green: 0.17, blue: 0.33)

    struct FloatingHeart: Identifiable { let id = UUID(); let point: CGPoint; let tilt: Double }

    var body: some View {
        ZStack {
            Color.black
            if forceFill {
                // «На весь экран»: видео не растягивается, а поворачивается — 16:9 занимает весь экран в горизонтальном положении
                GeometryReader { geo in
                    videoLayer
                        .frame(width: geo.size.height, height: geo.size.width)
                        .rotationEffect(.degrees(90))
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            } else {
                // Видео и его обложка — только наложение: их собственный размер (картинка «на всю высоту» шире экрана) не должен
                // раздвигать страницу. Иначе пока обложка не сменилась кадром, колонка кнопок стояла за правым краем и потом «телепортировалась»
                Color.black.overlay { videoLayer }.clipped()
            }
            LinearGradient(colors: [.clear, .black.opacity(0.46)], startPoint: .init(x: 0.5, y: 0.62), endPoint: .bottom)
                .allowsHitTesting(false)
            LinearGradient(colors: [.black.opacity(0.22), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.12))
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
                    .onTapGesture { if forceFill { toggleControls() } else { togglePause() } }
                    // удержание — ускорение ×2, отпустили — обычная скорость
                    .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 4000, perform: {
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
                    TapHeart(tilt: h.tilt).rotationEffect(.degrees(forceFill ? 90 : 0)).position(h.point).allowsHitTesting(false)
                }
            }

            // как в TikTok: у горизонтального видео под кадром кнопка «На весь экран»
            if landscape && ready && !forceFill {
                GeometryReader { geo in
                    let h = geo.size.width / CGFloat(max(0.2, video?.aspect ?? 1.78))
                    Button {
                        Haptics.impact(.light)
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { mode.on = true }
                        showControlsBriefly()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 12, weight: .semibold))
                            Text(s.t("На весь экран", "Full screen"))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13).frame(height: 30)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                        .padding(8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .position(x: geo.size.width / 2,
                              y: min(geo.size.height * 0.66, geo.size.height / 2 + h / 2 + 42))
                }
            }

            if forceFill { landscapeUI }

            Color.clear.frame(width: 0, height: 0)
                .onChange(of: fast) { _, v in onHold(v) }
                .onDisappear { if fast { fast = false; onHold(false) } }
            if fast {
                let badge = Text("2×  ▸▸")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(.ultraThinMaterial, in: Capsule())
                if forceFill {
                    // повёрнутый режим: надпись сверху по центру повёрнутого видео
                    GeometryReader { geo in
                        badge
                            .frame(width: geo.size.height, height: geo.size.width, alignment: .top)
                            .padding(.top, 28)
                            .rotationEffect(.degrees(90))
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                } else {
                    badge
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, topInset + 56)
                        .allowsHitTesting(false)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            if userPaused && active {
                Image(systemName: "play.fill")
                    .font(.system(size: 64)).foregroundStyle(.white.opacity(0.38))
                    .shadow(color: .black.opacity(0.4), radius: 8)
                    .rotationEffect(.degrees(forceFill ? 90 : 0))
                    .allowsHitTesting(false)
                    .transition(.scale(scale: 1.3).combined(with: .opacity))
            }

            if !forceFill {
            VStack(spacing: 0) {
                Spacer()
                HStack(alignment: .bottom, spacing: 0) {
                    caption
                    Spacer(minLength: 30)
                    rail
                }
                .padding(.leading, 14).padding(.trailing, 8).padding(.bottom, 6)
                progressBar(hitHeight: 48)                       // широкая зона перемотки: промазать по полоске трудно
                    .padding(.horizontal, 14)
                // кнопки/подпись/полоса прижаты ближе к панели вкладок (как в TikTok): оставляем место ровно под панель, без лишнего зазора
                Color.clear.frame(height: max(0, bottomClear + Self.safeBottom - 24))
            }
            // Слой считается от полного размера страницы, а не от безопасной области: она доходит до страницы не сразу, и кнопки
            // сначала стояли ниже (под панелью вкладок), а потом «телепортировались» на место
            .ignoresSafeArea()
            // панель с аватаркой/лайком/комментом сразу стоит на месте: внешние неявные анимации (пауза, смена страницы) её не двигают
            .transaction { $0.animation = nil }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: userPaused)
        .onChange(of: forceFill && active) { _, on in
            if !on { lsControls = false }
        }
        .onChange(of: near) { _, now in now ? makePlayer() : destroyPlayer() }
        .onChange(of: active) { _, now in now ? activate() : deactivate() }
        // перемотка жестом по панели вкладок (как в TikTok) — применяем только к активному ролику
        .onChange(of: scrubBus.tick) { _, _ in
            guard active, let f = scrubBus.target else { return }
            scrubbing = true
            progress = f
            if let item = player?.currentItem, item.duration.seconds.isFinite {
                player?.seek(to: CMTime(seconds: item.duration.seconds * f, preferredTimescale: 600),
                             toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        .onChange(of: scrubBus.active) { _, on in if active, !on { scrubbing = false } }
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
            // вернулись в приложение: если сверху съёмка, публикация, профиль и т.п. — ролик остаётся на паузе
            if active, !userPaused, !suspended { player?.play(); startClock() }
        }
    }

    // MARK: Видео

    @ViewBuilder
    private var videoLayer: some View {
        SensitiveGate(sensitive: post.sensitive) {
            ZStack {
                if let v = video {
                    if !ready {
                        RemoteImage(id: v.thumbID ?? v.id, fill: fill, backdrop: .black)
                    }
                    if let player {
                        PlayerLayerView(player: player, gravity: fill ? .resizeAspectFill : .resizeAspect)
                            .opacity(ready ? 1 : 0)
                    }
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
            if active { ReelScrubBus.shared.currentFrac = progress }     // чтобы панель вкладок знала, откуда перематывать
            if !ready, t.seconds > 0.05 { ready = true }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            p.seek(to: .zero)
            if active, !userPaused { p.play() }
        }
        player = p
        if active {
            // новый плеер после возврата во вкладку — сразу ставим на запомненную секунду
            let resume = ReelResume.shared.time(post.id)
            if resume > 0 { p.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
            if !userPaused { p.play(); startClock() }
        }
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
        // продолжаем с той секунды, на которой остановились (ушли в поиск/на «Главную»/снимать видео)
        let resume = ReelResume.shared.time(post.id)
        player?.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
        startClock()
    }

    private func deactivate() {
        pauseClock()
        saveResume()
        let seconds = watched
        watched = 0
        player?.pause()
        if seconds > 0.1 {
            let ratio = duration > 0 ? seconds / duration : 0
            session.taste.reelEnded(post.id, seconds: seconds, ratio: ratio)
        }
    }

    /// Запомнить текущий момент ролика — чтобы продолжить с него при возвращении
    private func saveResume() {
        guard let t = player?.currentTime().seconds, t.isFinite else { return }
        ReelResume.shared.save(post.id, seconds: t, duration: duration)
    }

    private func startClock() { if playingSince == nil { playingSince = Date(); playing = true } }

    private func pauseClock() {
        if let since = playingSince { watched += Date().timeIntervalSince(since) }
        playingSince = nil
        playing = false
    }

    // MARK: Повёрнутый режим (как в TikTok): без кнопок, пока не нажмёшь один раз

    private func toggleControls() {
        withAnimation(.easeOut(duration: 0.2)) { lsControls.toggle() }
        if lsControls { scheduleHide() } else { lsHideTask?.cancel() }
    }

    private func showControlsBriefly() {
        withAnimation(.easeOut(duration: 0.2)) { lsControls = true }
        scheduleHide()
    }

    private func scheduleHide() {
        lsHideTask?.cancel()
        lsHideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { if !scrubbing && !userPaused { withAnimation(.easeOut(duration: 0.25)) { lsControls = false } } }
        }
    }

    private func clock(_ t: Double) -> String {
        let n = max(0, Int(t.rounded()))
        return String(format: "%02d:%02d", n / 60, n % 60)
    }

    private var landscapeUI: some View {
        GeometryReader { geo in
            let w = geo.size.height, h = geo.size.width          // размеры в повёрнутой системе
            ZStack {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 8) {
                        Button {
                            Haptics.impact(.light)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { mode.on = false }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 48, height: 48).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 8) {
                            let title = post.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? ""
                            if !title.isEmpty {
                                Text(title)
                                    .font(.system(size: 17, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                                    .shadow(color: .black.opacity(0.5), radius: 3)
                            }
                            HStack(spacing: 10) {
                            Button(action: { exitThen(onAuthor) }) {
                                HStack(spacing: 8) {
                                    AvatarView(name: post.author.name, size: 28, avatarID: post.author.avatarID).clipShape(Circle())
                                    Text(post.author.username ?? post.author.name)
                                        .font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                                }
                                .padding(.leading, 4).padding(.trailing, 12).frame(height: 36)
                                .background(Color.black.opacity(0.35), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            if reel.state == "none" {
                                Button(action: onFollow) {
                                    Text(s.t("Подписаться", "Follow"))
                                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                        .padding(.horizontal, 14).frame(height: 36)
                                        .background(red, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                            }
                        }
                        .padding(.top, 6)
                        Spacer()
                    }
                    Spacer()
                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            Text(clock(progress * duration)).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                            Text("/ " + clock(duration)).font(.system(size: 14).monospacedDigit()).foregroundStyle(.white.opacity(0.65))
                            Spacer()
                        }
                        progressBar()
                        HStack(spacing: 26) {
                            lsAction(count: short(post.likes), action: { if !post.likedByMe { burst += 1; Haptics.impact(.medium) }; onLike() }) {
                                StoryHeart(liked: post.likedByMe, burst: burst, size: 24, solidWhenIdle: true)
                            }
                            lsAction(count: short(post.comments), action: { exitThen(onComments) }) { ReelCommentIcon().frame(width: 19, height: 18) }
                                .opacity(post.commentsEnabled ? 1 : 0.4)
                                .disabled(!post.commentsEnabled)
                            lsAction(count: short(bookmarks.count(for: post)), action: { bookmarks.toggle(post.id); Haptics.impact(.light) }) {
                                ReelBookmarkShape().fill(saved ? Color(red: 1, green: 0.8, blue: 0.2) : Color(white: 0.93))
                                    .frame(width: 14, height: 18)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.leading, topInset + 4).padding(.trailing, 28)       // слева — сторона с вырезом
                .padding(.vertical, 24)

                Button { togglePause() } label: {
                    Image(systemName: userPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 26)).foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Color.black.opacity(0.35), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: w, height: h)
            .opacity(lsControls ? 1 : 0)
            .allowsHitTesting(lsControls)
            .rotationEffect(.degrees(90))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    /// Комментарии, профиль и т.п. открываются в обычном положении: сначала возвращаем экран, потом открываем нужное
    private func exitThen(_ action: @escaping () -> Void) {
        Haptics.impact(.light)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { mode.on = false }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 380_000_000)
            action()
        }
    }

    private func lsAction<Icon: View>(count: String, action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon()
                Text(count).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(minHeight: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    /// Ссылка-жест для #хэштега: слово без решётки и хвостовой пунктуации, схема orbita-tag:
    static func tagLink(_ word: String) -> URL? {
        let tag = String(word.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        guard tag.count >= 1, let enc = tag.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "orbita-tag:" + enc)
    }

    private var captionAttributed: Text {
        let full = post.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = !expanded && full.count > collapsedLimit
        let shown = cut ? String(full.prefix(collapsedLimit)).trimmingCharacters(in: .whitespaces) + "… " : full
        var result = AttributedString()
        for (i, word) in shown.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            var piece = AttributedString((i == 0 ? "" : " ") + String(word))
            if word.hasPrefix("#"), let tag = Self.tagLink(String(word)) {
                piece.font = .system(size: 16, weight: .bold)
                piece.link = tag
            } else if word.hasPrefix("@") {
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

    // MARK: Кто сделал репост

    private struct Reposter: Identifiable { let id: String; let name: String; let avatarID: String?; let isMe: Bool; let author: Author? }

    /// Я (если репостнул), автор репост-копии и друзья, которые репостнули оригинал — без повторов
    private var reposters: [Reposter] {
        var list: [Reposter] = []
        if post.repostedByMe || (post.isRepost && post.isMine) {
            let me = session.profile.profile
            list.append(Reposter(id: "me", name: me?.name ?? "", avatarID: me?.avatarID, isMe: true, author: nil))
        }
        if post.isRepost, !post.isMine {
            list.append(Reposter(id: post.author.id, name: post.author.name, avatarID: post.author.avatarID, isMe: false, author: post.author))
        }
        for f in post.repostFriends where !list.contains(where: { $0.id == f.id }) {
            list.append(Reposter(id: f.id, name: f.name, avatarID: f.avatarID, isMe: false, author: f))
        }
        return list
    }

    @ViewBuilder
    private var repostBadge: some View {
        let list = reposters
        if let first = list.first {
            let firstName = first.name.components(separatedBy: " ").first ?? first.name
            let others = list.count - 1
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    guard others > 0 else { return }
                    Haptics.select()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { repostsOpen.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        HStack(spacing: -7) {
                            ForEach(Array(list.prefix(3).enumerated()), id: \.element.id) { i, r in
                                AvatarView(name: r.name, size: 20, avatarID: r.avatarID).clipShape(Circle())
                                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                                    .zIndex(Double(3 - i))
                            }
                        }
                        Text(badgeTitle(first: first, firstName: firstName, others: others))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black).lineLimit(1)
                        if others > 0 {
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.black.opacity(0.6))
                                .rotationEffect(.degrees(repostsOpen ? 180 : 0))
                        }
                    }
                    .padding(.leading, 5).padding(.trailing, 10).frame(height: 28)
                    .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)

                if repostsOpen, others > 0 {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(list) { r in
                            Button { if let a = r.author { onOpenUser(a) } } label: {
                                HStack(spacing: 10) {
                                    AvatarView(name: r.name, size: 28, avatarID: r.avatarID).clipShape(Circle())
                                    Text(r.isMe ? s.t("Вы", "You") : r.name)
                                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12).frame(height: 40).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(r.author == nil)
                        }
                    }
                    .frame(width: 230)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .transition(.scale(scale: 0.9, anchor: .topLeading).combined(with: .opacity))
                }
            }
            .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
            .animation(.spring(response: 0.34, dampingFraction: 0.8), value: list.count)
        }
    }

    private func badgeTitle(first: Reposter, firstName: String, others: Int) -> String {
        if others == 0 {
            return first.isMe ? s.t("Вы сделали репост", "You reposted") : s.t("\(firstName) сделал(а) репост", "\(firstName) reposted")
        }
        let who = first.isMe ? s.t("Вы", "You") : firstName
        return s.t("\(who) и ещё \(others) сделали репост", "\(who) and \(others) more reposted")
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 7) {
            repostBadge
            Button(action: onAuthor) {
                Text(post.author.username.map { "@" + $0 } ?? post.author.name)
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            if let music = post.music {
                Button(action: onMusic) {
                    HStack(spacing: 5) {
                        Image(systemName: "music.note").font(.system(size: 12, weight: .bold))
                        Text(music.display).font(.system(size: 13, weight: .medium)).lineLimit(1).opacity(0.9)
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            if !post.text.isEmpty {
                captionText
                    .font(.system(size: 15)).foregroundColor(.white.opacity(0.95))
                    .tint(.white)
                    .lineSpacing(2)
                    .lineLimit(expanded ? 14 : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in
                        if url.scheme == "orbita-tag" {
                            let enc = String(url.absoluteString.dropFirst("orbita-tag:".count))
                            onOpenTag(enc.removingPercentEncoding ?? enc)
                            return .handled
                        }
                        systemOpenURL(url)
                        return .handled
                    })
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
        VStack(spacing: 5) {
            avatarButton
            railButton(count: short(post.likes), action: { if !post.likedByMe { burst += 1; Haptics.impact(.medium) }; onLike() }) {
                StoryHeart(liked: post.likedByMe, burst: burst, size: 26, solidWhenIdle: true)
            }
            railButton(count: short(post.comments), action: onComments) {
                ReelCommentIcon().frame(width: 19, height: 18)
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
                    .frame(width: 14, height: 18)
                    .scaleEffect(saved ? 1.08 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: saved)
            }
            do {
                railButton(count: short(post.reposts), tint: post.repostedByMe ? Color(red: 0.25, green: 0.88, blue: 0.62) : .white, action: {
                    if !post.allowRepost && !post.isMine && !post.repostedByMe { Haptics.impact(.rigid); return }
                    if post.repostedByMe { Haptics.impact(.light) } else { repostSpin += 1; Haptics.impact(.medium) }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { onRepost() }
                }) {
                    Image(systemName: "arrow.2.squarepath").font(.system(size: 17, weight: .bold))
                        .opacity(post.allowRepost || post.isMine ? 1 : 0.35)
                        .foregroundStyle(post.repostedByMe ? Color(red: 0.25, green: 0.88, blue: 0.62) : Color(white: 0.93))
                        .scaleEffect(post.repostedByMe ? 1.08 : 1)
                        .rotationEffect(.degrees(Double(repostSpin) * 360))
                        .animation(.spring(response: 0.6, dampingFraction: 0.6), value: repostSpin)
                        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: post.repostedByMe)
                        .overlay { RepostRipple(trigger: repostSpin) }
                }
            }
            railButton(count: s.t("Отправить", "Share"), action: onShare) {
                ReelShareShape().fill(Color(white: 0.93))
                    .overlay(ReelShareShape().stroke(Color(white: 0.93), style: StrokeStyle(lineWidth: 2, lineJoin: .round)))
                    .frame(width: 20, height: 17)
            }
            if !post.isMine {
                Menu {
                    Button(role: .destructive, action: onHide) {
                        Label(s.t("Не интересует", "Not interested"), systemImage: "hand.thumbsdown")
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold)).foregroundStyle(Color(white: 0.93))
                        .frame(width: 44, height: 30).contentShape(Rectangle())
                }
            }
            Button(action: onMusic) { musicDisc.scaleEffect(0.7).frame(width: 34, height: 36).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .disabled(post.music == nil)
        }
        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
        .padding(.bottom, 2)
        .scaleEffect(1.36, anchor: .bottomTrailing)      // колонка крупнее обычной в 1,36 раза (1,5 / 1,1)
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
                AvatarView(name: post.author.name, size: 38, avatarID: post.author.avatarID).clipShape(Circle())
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.2))
            }
            .buttonStyle(.plain)
            .contextMenu {
                if reel.state == "following" {
                    Button(role: .destructive, action: onUnfollow) {
                        Label(lang == .ru ? "Отписаться" : "Unfollow", systemImage: "person.badge.minus")
                    }
                }
            }
            if reel.state == "none" {
                Button(action: onFollow) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                        .frame(width: 17, height: 17).background(red, in: Circle())
                }
                .buttonStyle(.plain)
                .offset(y: 8)
                .transition(.scale.combined(with: .opacity))
            } else if reel.state == "following" && showCheck {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(red)
                    .frame(width: 17, height: 17).background(Color.white, in: Circle())
                    .offset(y: 8)
            }
        }
        .padding(.bottom, 10)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: reel.state)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showCheck)
    }

    private func railButton<Icon: View>(count: String, tint: Color = .white, action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                icon().frame(height: 21)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                Text(count).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
                    .contentTransition(.numericText())
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 42)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RailPress())
        .padding(.horizontal, -8).padding(.vertical, -6)
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

    /// hitHeight — высота зоны перемотки: в портрете делаем её большой, чтобы «промазать» по тонкой полоске
    /// было почти невозможно (как в TikTok). Сама полоса остаётся тонкой и стоит внизу зоны, у панели вкладок.
    private func progressBar(hitHeight: CGFloat = 26) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = max(0, min(w, w * progress))
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.28)).frame(height: scrubbing ? 5 : 2.5)
                    Capsule().fill(.white).frame(width: max(5, x), height: scrubbing ? 5 : 2.5)
                    Circle().fill(.white).frame(width: scrubbing ? 13 : 7, height: scrubbing ? 13 : 7)
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .offset(x: max(0, x - (scrubbing ? 6.5 : 3.5)))
                }
                .frame(height: 13)
            }
            .frame(height: hitHeight)
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
        .frame(height: hitHeight)
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


/// Анимация репоста: расходящееся кольцо и стайка стрелок вокруг кнопки
struct RepostRipple: View {
    let trigger: Int
    @State private var t: CGFloat = 1
    private let green = Color(red: 0.25, green: 0.88, blue: 0.62)

    var body: some View {
        ZStack {
            Circle().stroke(green, lineWidth: 1 + 3 * (1 - t))
                .frame(width: 28, height: 28)
                .scaleEffect(0.5 + 1.5 * t)
                .opacity(Double(1 - t))
            ForEach(0..<7, id: \.self) { i in
                let angle = Double(i) / 7 * 2 * Double.pi
                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(green)
                    .rotationEffect(.degrees(Double(i) * 51 + Double(t) * 200))
                    .offset(x: CGFloat(cos(angle)) * 48 * t, y: CGFloat(sin(angle)) * 48 * t)
                    .scaleEffect(1 - 0.4 * t)
                    .opacity(Double(1 - t))
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            t = 0
            withAnimation(.easeOut(duration: 0.75)) { t = 1 }
        }
    }
}


/// Общий режим «на весь экран» для горизонтальных шортсов
final class LandscapeMode: ObservableObject {
    static let shared = LandscapeMode()
    @Published var on = false
}
