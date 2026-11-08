import SwiftUI
import Combine
import AVFoundation
import MapKit

// MARK: - Результаты поиска шортсов: вкладки «Лучшее, Видео, Люди, Фото, Музыка, Места, Хэштеги»
// Вкладки листаются свайпом как страницы (видно соседнюю), в «Лучшем» — подфильтры. В результатах ролики играют сами
// по очереди (как в TikTok): закончилось — следующий. Просмотром это не считается — только открытие на весь экран.

enum SearchTab: Int, CaseIterable, Identifiable {
    case best, video, people, photo, music, places, tags
    var id: Int { rawValue }
    func title(_ s: Strings) -> String {
        switch self {
        case .best: return s.t("Лучшее", "Top")
        case .video: return s.t("Видео", "Videos")
        case .people: return s.t("Люди", "Users")
        case .photo: return s.t("Фото", "Photos")
        case .music: return s.t("Музыка", "Sounds")
        case .places: return s.t("Места", "Places")
        case .tags: return s.t("Хэштеги", "Hashtags")
        }
    }
    var api: String { self == .video ? "video" : (self == .photo ? "photo" : "best") }
}

enum SearchFilter: String, CaseIterable, Identifiable {
    case all, unseen, seen, recent
    var id: String { rawValue }
    func title(_ s: Strings) -> String {
        switch self {
        case .all: return s.t("Все", "All")
        case .unseen: return s.t("Не просмотрено", "Unwatched")
        case .seen: return s.t("Просмотрено", "Watched")
        case .recent: return s.t("Недавно загружено", "Recently uploaded")
        }
    }
}

struct SearchPerson: Identifiable, Decodable, Equatable {
    let id: String
    let name: String
    let username: String?
    let avatar: String?
    let followers: Int
    var following: Bool
    let reels: Int
}

struct SearchSound: Identifiable, Decodable, Equatable {
    var id: String { mediaId }
    let mediaId: String
    let title: String
    let artist: String
    let reels: Int
}

struct SearchTag: Identifiable, Decodable, Equatable {
    var id: String { tag }
    let tag: String
    let reels: Int
}

/// Ролик в результатах: сам ролик и пометка «Топовое в поиске»
struct SearchReel: Identifiable, Equatable {
    let reel: Reel
    let top: Bool
    var id: String { reel.id }
    var post: Post { reel.post }
}

private struct TabPageDTO: Decodable {
    struct Item: Decodable {
        let post: PostDTO
        let authorState: String
        let top: Bool
        init(from decoder: Decoder) throws {
            post = try PostDTO(from: decoder)
            let c = try decoder.container(keyedBy: Keys.self)
            authorState = try c.decodeIfPresent(String.self, forKey: .authorState) ?? "none"
            top = try c.decodeIfPresent(Bool.self, forKey: .top) ?? false
        }
        enum Keys: String, CodingKey { case authorState, top }
    }
    let reels: [Item]
    let more: Bool?
}

extension ExtrasAPI {
    func reelSearchTab(_ query: String, tab: SearchTab, filter: SearchFilter, offset: Int) async throws -> (items: [SearchReel], more: Bool) {
        let data: Data
        do {
            data = try await api.request("GET", "/v1/reels/search", query: ["q": query, "offset": "\(offset)", "limit": "20",
                                                                          "tab": tab.api, "filter": filter.rawValue])
        } catch APIError.server(_, let code) where code == "query_blocked" {
            throw ReelSearchError.blocked
        }
        let page = try decodeAPI(TabPageDTO.self, from: data)
        return (page.reels.map { SearchReel(reel: Reel(post: $0.post.model, state: $0.authorState), top: $0.top) }, page.more ?? false)
    }

    func reelSearchPeople(_ query: String) async -> [SearchPerson] {
        struct Box: Decodable { let people: [SearchPerson] }
        guard let d = try? await api.request("GET", "/v1/reels/search/extra", query: ["q": query, "kind": "people"]) else { return [] }
        return (try? decodeAPI(Box.self, from: d))?.people ?? []
    }

    func reelSearchSounds(_ query: String) async -> [SearchSound] {
        struct Box: Decodable { let music: [SearchSound] }
        guard let d = try? await api.request("GET", "/v1/reels/search/extra", query: ["q": query, "kind": "music"]) else { return [] }
        return (try? decodeAPI(Box.self, from: d))?.music ?? []
    }

    func reelSearchTags(_ query: String) async -> [SearchTag] {
        struct Box: Decodable { let tags: [SearchTag] }
        guard let d = try? await api.request("GET", "/v1/reels/search/extra", query: ["q": query, "kind": "tags"]) else { return [] }
        return (try? decodeAPI(Box.self, from: d))?.tags ?? []
    }

    /// Для статистики автора: показали в поиске / проигралось само / открыли
    func reelSearchTrack(_ query: String, events: [(String, String)]) async {
        guard !events.isEmpty else { return }
        let body: [String: Any] = ["q": query, "events": events.map { ["post_id": $0.0, "kind": $0.1] }]
        _ = try? await api.request("POST", "/v1/reels/search/track", body: ServerAPI.json(body))
    }
}

// MARK: - Автопроигрывание в результатах

/// Играет один ролик за раз: видео — до конца, фото и коллаж — листаются сами, пока звучит их музыка (или несколько секунд).
/// Закончилось — следующий по списку. Открыли что-то на весь экран — всё стоит
@MainActor
final class SearchAutoplay: ObservableObject {
    @Published private(set) var currentID: String?
    @Published var muted = false {
        didSet { player?.isMuted = muted; music?.isMuted = muted }
    }
    @Published private(set) var slide = 0                  // какое фото коллажа сейчас видно
    @Published private(set) var player: AVPlayer?

    private var order: [Post] = []
    private var music: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var slideTimer: Timer?
    private var finishTask: Task<Void, Never>?
    var suspended = false {
        didSet {
            if suspended { player?.pause(); music?.pause(); slideTimer?.invalidate() } else if oldValue { resumeCurrent() }
        }
    }
    var onAutoplay: ((String) -> Void)?

    func setOrder(_ posts: [Post]) {
        order = posts
        if currentID == nil || !posts.contains(where: { $0.id == currentID }), let first = posts.first { start(first) }
    }

    func stop() {
        cleanup()
        currentID = nil
    }

    private func cleanup() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause(); player = nil
        music?.pause(); music = nil
        slideTimer?.invalidate(); slideTimer = nil
        finishTask?.cancel(); finishTask = nil
    }

    private func start(_ post: Post) {
        cleanup()
        currentID = post.id
        slide = 0
        guard !suspended else { return }
        onAutoplay?(post.id)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        if let m = post.media.first, m.kind == .video, post.media.count == 1, let url = ServerConfig.mediaURL(m.id) {
            let item = AVPlayerItem(url: url)
            let p = AVPlayer(playerItem: item)
            p.isMuted = muted
            MediaSilence.register(p)
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.next() }
            }
            player = p
            p.play()
        } else {
            // фото / коллаж: кадры сменяются сами; играет музыка ролика, если она есть
            let frames = max(1, post.media.count)
            var total = Double(frames) * 2.4
            if let mus = post.music, let url = ServerConfig.mediaURL(mus.mediaID) {
                let p = AVPlayer(url: url)
                p.isMuted = muted
                MediaSilence.register(p)
                music = p
                p.play()
                total = max(total, 12)                     // под звук — дольше (сам звук обрывается на смене ролика)
            } else {
                total = max(total, 5)
            }
            if frames > 1 {
                slideTimer = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        withAnimation(.easeInOut(duration: 0.35)) { self.slide = (self.slide + 1) % frames }
                    }
                }
            }
            let id = post.id
            finishTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(total * 1_000_000_000))
                guard let self, !Task.isCancelled, self.currentID == id else { return }
                self.next()
            }
        }
    }

    private func resumeCurrent() {
        guard let id = currentID, let post = order.first(where: { $0.id == id }) else { return }
        if let player { player.play() } else { start(post) }
        music?.play()
    }

    func next() {
        guard let id = currentID, let i = order.firstIndex(where: { $0.id == id }) else { return }
        let n = order.indices.contains(i + 1) ? order[i + 1] : order.first
        if let n { start(n) }
    }

    /// Нажали на карточку, которая сейчас не играет — она и начинает (без открытия)
    func play(_ post: Post) { start(post) }

    /// Открывают ролик, который сейчас играет в результатах: полноэкранный просмотр продолжит с этой же секунды, а не с начала
    func handOff(_ id: String) {
        guard currentID == id, let p = player else { return }
        let t = p.currentTime().seconds
        let d = p.currentItem?.duration.seconds ?? 0
        guard t.isFinite else { return }
        ReelResume.shared.save(id, seconds: t, duration: d.isFinite ? d : 0)
    }
}

// MARK: - Экран результатов

struct ReelSearchResults: View {
    let query: String
    var initialBest: [SearchReel] = []
    var initialMore = false
    let suspended: Bool
    var onOpen: ([Reel], String) -> Void
    var onSearch: (String) -> Void
    /// «Фото»: пост открывается страницей (медиа, полное описание, комментарии), а не лентой
    var onOpenDetail: (Reel) -> Void = { _ in }

    @EnvironmentObject private var session: AppSession
    @Environment(\.lang) private var lang
    @State private var tab: SearchTab = .best
    @StateObject private var autoplay = SearchAutoplay()
    @State private var pending: [(String, String)] = []
    @State private var shownIDs: Set<String> = []
    @Namespace private var underline

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            TabView(selection: $tab) {
                ForEach(SearchTab.allCases) { t in
                    page(t).tag(t)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.25), value: tab)
        }
        .onChange(of: suspended) { _, v in autoplay.suspended = v }
        .onChange(of: tab) { _, t in
            // ушли на вкладку без роликов — звук не играет фоном
            if t == .people || t == .music || t == .places || t == .tags { autoplay.stop() }
        }
        .onAppear {
            autoplay.suspended = suspended
            autoplay.onAutoplay = { id in track(id, "autoplay") }
        }
        .onDisappear { autoplay.stop(); flush() }
        .task(id: query) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                flush()
            }
        }
    }

    // MARK: Вкладки сверху

    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(SearchTab.allCases) { t in
                        Button {
                            Haptics.select()
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { tab = t }
                        } label: {
                            VStack(spacing: 8) {
                                Text(t.title(s))
                                    .font(.system(size: 17, weight: tab == t ? .bold : .semibold))
                                    .foregroundStyle(tab == t ? Color.white : Color.white.opacity(0.55))
                                ZStack {
                                    Capsule().fill(Color.clear).frame(height: 3)
                                    if tab == t {
                                        Capsule().fill(Color.white).frame(height: 3)
                                            .matchedGeometryEffect(id: "searchTab", in: underline)
                                    }
                                }
                            }
                            .fixedSize()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(t)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
            .onChange(of: tab) { _, t in withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(t, anchor: .center) } }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5) }
    }

    @ViewBuilder
    private func page(_ t: SearchTab) -> some View {
        switch t {
        case .best, .video, .photo:
            ReelGridPage(query: query, tab: t, initial: t == .best ? initialBest : [], initialMore: t == .best ? initialMore : false,
                         active: tab == t, autoplay: autoplay,
                         onOpen: { items, id in
                             track(id, "open")
                             autoplay.suspended = true
                             if t == .photo, let r = items.first(where: { $0.id == id }) { onOpenDetail(r) } else { onOpen(items, id) }
                         },
                         onShown: { id in track(id, "shown") })
        case .people: PeoplePage(query: query)
        case .music: SoundsPage(query: query, player: session.player)
        case .places: PlacesPage(query: query, onSearch: onSearch)
        case .tags: TagsPage(query: query, onSearch: onSearch)
        }
    }

    private func track(_ id: String, _ kind: String) {
        let key = id + kind
        guard !shownIDs.contains(key) else { return }
        shownIDs.insert(key)
        pending.append((id, kind))
    }

    private func flush() {
        let batch = pending
        pending = []
        let q = query, extras = session.extras
        Task { await extras.reelSearchTrack(q, events: batch) }
    }
}

// MARK: - «Лучшее», «Видео», «Фото»: подфильтры и сетка в две колонки

private struct ReelGridPage: View {
    let query: String
    let tab: SearchTab
    let initial: [SearchReel]
    let initialMore: Bool
    let active: Bool
    @ObservedObject var autoplay: SearchAutoplay
    var onOpen: ([Reel], String) -> Void
    var onShown: (String) -> Void

    @EnvironmentObject private var session: AppSession
    @Environment(\.lang) private var lang
    @State private var filter: SearchFilter = .all
    @State private var items: [SearchReel] = []
    @State private var more = false
    @State private var loading = false
    @State private var loaded = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if tab == .best { filters }
                if !loaded {
                    skeleton
                } else if items.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: s.t("Ничего не найдено", "Nothing found"),
                                   subtitle: s.t("Попробуйте другой фильтр или запрос.", "Try another filter or search."), onDark: true)
                        .padding(.top, 80)
                } else {
                    masonry
                    if loading { ProgressView().tint(.white).padding(18) }
                }
                Color.clear.frame(height: 40)
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .task {
            guard !loaded else { return }
            if !initial.isEmpty {
                items = initial; more = initialMore; loaded = true
                if active { autoplay.setOrder(items.map(\.post)) }
            } else {
                await load(reset: true)
            }
        }
        .onChange(of: active) { _, on in if on, !items.isEmpty { autoplay.setOrder(items.map(\.post)) } }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(SearchFilter.allCases) { f in
                    Button {
                        guard f != filter else { return }
                        Haptics.select()
                        filter = f
                        Task { await load(reset: true) }
                    } label: {
                        Text(f.title(s))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(filter == f ? Color.white : Color.white.opacity(0.7))
                            .padding(.horizontal, 16).frame(height: 36)
                            .background(Color.white.opacity(filter == f ? 0.2 : 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
        }
    }

    /// Две колонки разной высоты (как в TikTok): каждая карточка уходит в ту колонку, что сейчас короче
    private var masonry: some View {
        let cols = split(items)
        return HStack(alignment: .top, spacing: 6) {
            ForEach(0..<2, id: \.self) { c in
                LazyVStack(spacing: 6) {
                    ForEach(cols[c]) { item in
                        SearchCard(item: item, autoplay: autoplay, active: active)
                            .onTapGesture { autoplay.handOff(item.id); onOpen(items.map(\.reel), item.id) }
                            .onAppear {
                                onShown(item.id)
                                if item.id == items.last?.id { Task { await load(reset: false) } }
                            }
                    }
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private func split(_ list: [SearchReel]) -> [[SearchReel]] {
        var out: [[SearchReel]] = [[], []]
        var h: [CGFloat] = [0, 0]
        for item in list {
            let c = h[0] <= h[1] ? 0 : 1
            out[c].append(item)
            h[c] += SearchCard.mediaHeightRatio(item.post) + 0.42
        }
        return out
    }

    private var skeleton: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(0..<2, id: \.self) { c in
                VStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07))
                            .frame(height: (c + i) % 2 == 0 ? 300 : 240)
                    }
                }
            }
        }
        .padding(.horizontal, 6).padding(.top, 6)
        .shimmer()
    }

    private func load(reset: Bool) async {
        if reset {
            loaded = false; items = []; more = false
        } else {
            guard more, !loading else { return }
        }
        loading = true
        defer { loading = false }
        let r = try? await session.extras.reelSearchTab(query, tab: tab, filter: filter, offset: reset ? 0 : items.count)
        if let r {
            let known = Set(items.map(\.id))
            items += r.items.filter { !known.contains($0.id) }
            more = r.more
        }
        loaded = true
        if active { autoplay.setOrder(items.map(\.post)) }
    }
}

// MARK: - Карточка ролика

private struct SearchCard: View {
    let item: SearchReel
    @ObservedObject var autoplay: SearchAutoplay
    let active: Bool
    @Environment(\.lang) private var lang

    private var post: Post { item.post }
    private var playing: Bool { active && autoplay.currentID == item.id }

    /// Высота медиа относительно ширины: вертикальное видео выше, квадратное — ниже (в разумных пределах)
    static func mediaHeightRatio(_ post: Post) -> CGFloat {
        guard let m = post.media.first, m.width > 0, m.height > 0 else { return 1.33 }
        return min(1.6, max(1.0, CGFloat(m.height) / CGFloat(m.width)))
    }

    var body: some View {
        let s = Strings(lang: lang)
        VStack(alignment: .leading, spacing: 0) {
            Color(white: 0.08)
                .aspectRatio(1 / Self.mediaHeightRatio(post), contentMode: .fit)
                .overlay { media }
                .overlay(alignment: .topTrailing) {
                    if post.media.count > 1 {
                        Image(systemName: "square.on.square.fill").font(.system(size: 15)).foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 3).padding(8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if playing && (autoplay.player != nil || post.music != nil) {
                        // звук: включить / выключить
                        Button {
                            Haptics.select()
                            autoplay.muted.toggle()
                        } label: {
                            Image(systemName: autoplay.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Color.black.opacity(0.35), in: Circle())
                                .padding(8)
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if item.top {
                        Text(s.t("Топовое в поиске", "Top in search"))
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .padding(6)
                    }
                }
                .clipped()

            VStack(alignment: .leading, spacing: 8) {
                if !post.text.isEmpty {
                    Text(post.text)
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                HStack(spacing: 8) {
                    AvatarView(name: post.creator.name, size: 24, avatarID: post.creator.avatarID).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 0) {
                        Text(post.creator.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        Text(Self.date(post.createdAt, s)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 3) {
                        Image(systemName: post.likedByMe ? "heart.fill" : "heart").font(.system(size: 13))
                            .foregroundStyle(post.likedByMe ? Color(red: 1, green: 0.2, blue: 0.35) : .white.opacity(0.75))
                        Text(Self.short(post.likes, lang)).font(.system(size: 13).monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                    }
                    .fixedSize()
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
        }
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.25), value: playing)
    }

    @ViewBuilder
    private var media: some View {
        if playing, let player = autoplay.player {
            ZStack {
                if let m = post.media.first { RemoteImage(id: m.thumbID ?? m.id, maxPixel: 600) }
                PlayerLayerView(player: player).transition(.opacity)
            }
        } else if post.media.count > 1 {
            // коллаж: у играющего кадры сменяются сами
            let i = playing ? min(autoplay.slide, post.media.count - 1) : 0
            let m = post.media[i]
            RemoteImage(id: m.thumbID ?? m.id, maxPixel: 600)
                .id(m.id)
                .transition(.opacity)
        } else if let m = post.media.first {
            RemoteImage(id: m.thumbID ?? m.id, maxPixel: 600)
        }
    }

    static func date(_ d: Date, _ s: Strings) -> String {
        let sec = Date().timeIntervalSince(d)
        if sec < 3600 { return s.t("\(max(1, Int(sec / 60))) мин. назад", "\(max(1, Int(sec / 60)))m ago") }
        if sec < 86400 { return s.t("\(Int(sec / 3600)) ч. назад", "\(Int(sec / 3600))h ago") }
        if sec < 7 * 86400 { return s.t("\(Int(sec / 86400)) д. назад", "\(Int(sec / 86400))d ago") }
        let sameYear = Calendar.current.component(.year, from: d) == Calendar.current.component(.year, from: Date())
        return FormatterCache.format(d, sameYear ? "d MMM" : "d MMM yyyy")
    }

    static func short(_ n: Int, _ lang: AppLanguage) -> String {
        func one(_ v: Double) -> String {
            let r = (v * 10).rounded() / 10
            return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r).replacingOccurrences(of: ".", with: ",")
        }
        if n >= 1_000_000 { return one(Double(n) / 1_000_000) + (lang == .ru ? " млн" : "M") }
        if n >= 1000 { return one(Double(n) / 1000) + (lang == .ru ? " тыс." : "K") }
        return "\(n)"
    }
}

// MARK: - «Люди»

private struct PeoplePage: View {
    let query: String
    @EnvironmentObject private var session: AppSession
    @Environment(\.lang) private var lang
    @State private var people: [SearchPerson] = []
    @State private var loaded = false
    @State private var profileID: String?

    var body: some View {
        let s = Strings(lang: lang)
        ScrollView {
            LazyVStack(spacing: 0) {
                if !loaded {
                    ForEach(0..<6, id: \.self) { _ in
                        HStack(spacing: 12) {
                            Circle().fill(Color.white.opacity(0.08)).frame(width: 54, height: 54)
                            VStack(alignment: .leading, spacing: 8) {
                                RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)).frame(width: 140, height: 13)
                                RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)).frame(width: 100, height: 11)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                    .shimmer()
                } else if people.isEmpty {
                    EmptyStateView(icon: "person.2", title: s.t("Никого не нашли", "No users found"), onDark: true).padding(.top, 80)
                } else {
                    ForEach($people) { $p in
                        HStack(spacing: 12) {
                            AvatarView(name: p.name, size: 54, avatarID: p.avatar).clipShape(Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                Text((p.username.map { "@" + $0 + " · " } ?? "")
                                     + SearchCard.short(p.followers, lang) + s.t(" подписчиков", " followers"))
                                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Button {
                                Haptics.impact(.light)
                                let on = !p.following
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { p.following = on }
                                let id = p.id
                                Task { _ = await session.extras.setFollow(id: id, on: on, source: "search") }
                            } label: {
                                Text(p.following ? s.t("Вы подписаны", "Following") : s.t("Подписаться", "Follow"))
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 14).frame(height: 34)
                                    .background(p.following ? Color.white.opacity(0.14) : Color(red: 1, green: 0.17, blue: 0.33),
                                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { profileID = p.id }
                    }
                }
            }
            .padding(.top, 6)
        }
        .task { guard !loaded else { return }; people = await session.extras.reelSearchPeople(query); loaded = true }
        .profileSheet(id: $profileID)
    }
}

// MARK: - «Музыка»

private struct SoundsPage: View {
    let query: String
    @ObservedObject var player: AudioPlayer
    @EnvironmentObject private var session: AppSession
    @Environment(\.lang) private var lang
    @State private var sounds: [SearchSound] = []
    @State private var loaded = false
    @State private var openSound: PostMusic?

    var body: some View {
        let s = Strings(lang: lang)
        ScrollView {
            LazyVStack(spacing: 0) {
                if !loaded {
                    ProgressView().tint(.white).padding(.top, 60)
                } else if sounds.isEmpty {
                    EmptyStateView(icon: "music.note", title: s.t("Звуков не нашли", "No sounds found"), onDark: true).padding(.top, 80)
                } else {
                    ForEach(sounds) { snd in
                        let track = Track(id: snd.mediaId, mediaID: snd.mediaId, title: snd.title.isEmpty ? s.t("Без названия", "Untitled") : snd.title,
                                          artist: snd.artist, duration: 0)
                        let current = player.isCurrent(track)
                        HStack(spacing: 12) {
                            Button {
                                Haptics.impact(.light)
                                player.toggle(track, queue: [track])
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(LinearGradient(colors: [Color(red: 0.5, green: 0.3, blue: 1), Color(red: 1, green: 0.3, blue: 0.55)],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                    Image(systemName: current && player.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                                }
                                .frame(width: 56, height: 56)
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(track.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                                    .lineLimit(1).truncationMode(.middle)
                                if !snd.artist.isEmpty {
                                    Text(snd.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                                }
                                Text(s.t("\(snd.reels) видео", "\(snd.reels) videos")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.35))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { openSound = PostMusic(title: snd.title, artist: snd.artist, mediaID: snd.mediaId) }
                    }
                }
            }
            .padding(.top, 6)
        }
        .task { guard !loaded else { return }; sounds = await session.extras.reelSearchSounds(query); loaded = true }
        .sheet(item: $openSound) { m in
            SoundSheet(music: m).environmentObject(session).environmentObject(player)
        }
    }
}

// MARK: - «Места» (Карты Apple: место по запросу → поиск роликов с его названием)

private struct PlacesPage: View {
    let query: String
    var onSearch: (String) -> Void
    @Environment(\.lang) private var lang
    @State private var places: [MKMapItem] = []
    @State private var loaded = false

    var body: some View {
        let s = Strings(lang: lang)
        ScrollView {
            LazyVStack(spacing: 0) {
                if !loaded {
                    ProgressView().tint(.white).padding(.top, 60)
                } else if places.isEmpty {
                    EmptyStateView(icon: "mappin.and.ellipse", title: s.t("Мест не нашли", "No places found"), onDark: true).padding(.top, 80)
                } else {
                    ForEach(Array(places.enumerated()), id: \.offset) { _, item in
                        Button { onSearch(item.name ?? query) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill").font(.system(size: 30))
                                    .foregroundStyle(Color(red: 1, green: 0.27, blue: 0.3))
                                    .frame(width: 56, height: 56)
                                    .background(Color.white.opacity(0.08), in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name ?? "").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                    Text(address(item)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                                }
                                Spacer(minLength: 6)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 6)
        }
        .task {
            guard !loaded else { return }
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = query.replacingOccurrences(of: "#", with: "")
            places = (try? await MKLocalSearch(request: req).start())?.mapItems.prefix(20).map { $0 } ?? []
            loaded = true
        }
    }

    private func address(_ item: MKMapItem) -> String {
        let p = item.placemark
        return [p.locality, p.thoroughfare, p.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

// MARK: - «Хэштеги»

private struct TagsPage: View {
    let query: String
    var onSearch: (String) -> Void
    @EnvironmentObject private var session: AppSession
    @Environment(\.lang) private var lang
    @State private var tags: [SearchTag] = []
    @State private var loaded = false

    var body: some View {
        let s = Strings(lang: lang)
        ScrollView {
            LazyVStack(spacing: 0) {
                if !loaded {
                    ProgressView().tint(.white).padding(.top, 60)
                } else if tags.isEmpty {
                    EmptyStateView(icon: "number", title: s.t("Хэштегов не нашли", "No hashtags found"), onDark: true).padding(.top, 80)
                } else {
                    ForEach(tags) { t in
                        Button { onSearch("#" + t.tag) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "number").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                                    .frame(width: 56, height: 56)
                                    .background(Color.white.opacity(0.1), in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("#" + t.tag).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                    Text(s.t("\(t.reels) видео", "\(t.reels) videos")).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                                }
                                Spacer(minLength: 6)
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.35))
                            }
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 6)
        }
        .task { guard !loaded else { return }; tags = await session.extras.reelSearchTags(query); loaded = true }
    }
}
