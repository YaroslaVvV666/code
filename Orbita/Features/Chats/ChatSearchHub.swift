import SwiftUI
import Combine
import AVFoundation

// MARK: - Поиск в мессенджере (нажали на поле поиска, ещё ничего не ввели)
// Сверху — 20 человек, с кем больше всего переписывался за месяц (листается лента).
// Ниже — разделы, которые листаются свайпом: «Чаты» (20 недавно открытых, как история), «Каналы», «Боты»,
// «Медиа», «Файлы», «Ссылки», «Музыка», «Голосовые» — всё присланное из всех чатов в одном месте.

/// История открытых чатов: последние 20, свежие сверху. Хранится на телефоне
@MainActor
final class RecentChatsStore: ObservableObject {
    static let shared = RecentChatsStore()

    struct Item: Codable, Equatable, Identifiable {
        let id: String
        var name: String
        var username: String?
        var avatarID: String?
        var isGroup: Bool
        var type: String?
        var memberCount: Int
        var peer: ChatPeer {
            ChatPeer(id: id, name: name, username: username, avatarID: avatarID, isGroup: isGroup, memberCount: memberCount, type: type)
        }
    }

    @Published private(set) var items: [Item] = []
    private let key = "chats.recentOpened"

    init() {
        if let data = UserDefaults.standard.data(forKey: key), let list = try? JSONDecoder().decode([Item].self, from: data) { items = list }
    }

    func record(_ p: ChatPeer) {
        var list = items.filter { $0.id != p.id }
        list.insert(Item(id: p.id, name: p.name, username: p.username, avatarID: p.avatarID, isGroup: p.isGroup,
                         type: p.type, memberCount: p.memberCount), at: 0)
        items = Array(list.prefix(20))
        save()
    }

    func remove(_ id: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { items.removeAll { $0.id == id } }
        save()
    }

    func clear() {
        withAnimation(.easeOut(duration: 0.25)) { items = [] }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }
}

enum HubSection: Int, CaseIterable, Identifiable {
    case chats, channels, bots, media, files, links, music, voice
    var id: Int { rawValue }
    func title(_ s: Strings) -> String {
        switch self {
        case .chats: return s.t("Чаты", "Chats")
        case .channels: return s.t("Каналы", "Channels")
        case .bots: return s.t("Боты", "Bots")
        case .media: return s.t("Медиа", "Media")
        case .files: return s.t("Файлы", "Files")
        case .links: return s.t("Ссылки", "Links")
        case .music: return s.t("Музыка", "Music")
        case .voice: return s.t("Голосовые", "Voice")
        }
    }
    var api: String? {
        switch self {
        case .media: return "media"
        case .files: return "files"
        case .links: return "links"
        case .music: return "music"
        case .voice: return "voice"
        default: return nil
        }
    }
}

struct ChatSearchHub: View {
    let session: AppSession
    let chats: [ChatSummary]
    var onOpen: (ChatPeer) -> Void
    var onDelete: (ChatSummary) -> Void = { _ in }

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @ObservedObject private var recents = RecentChatsStore.shared
    @ObservedObject private var prefs = ChatListPrefs.shared
    @State private var hub: SearchHub?
    @State private var section: HubSection = .chats
    @State private var peek: ChatSummary?
    @Namespace private var tabNS

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 0) {
            topPeople
            TabView(selection: $section) {
                ForEach(HubSection.allCases) { sec in
                    page(sec).tag(sec)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .overlay(alignment: .bottom) { sectionBar }
        .overlay {
            if let chat = peek {
                ChatPeekOverlay(
                    chat: chat, repo: session.messengerRepo,
                    pinned: prefs.isPinned(chat.id), muted: chat.muted || prefs.isDMMuted(chat.id), markedUnread: prefs.isMarked(chat.id),
                    onOpen: { peek = nil; onOpen(chat.peer) },
                    onPin: { peek = nil; prefs.toggle(chat.id) },
                    onMute: {
                        peek = nil
                        if chat.peer.isGroup {
                            let repo = session.messengerRepo, id = chat.id, want = !chat.muted
                            Task { try? await repo.setMuted(groupID: id, muted: want) }
                        } else {
                            prefs.setDMMuted(chat.id, !prefs.isDMMuted(chat.id))
                        }
                    },
                    onMark: { peek = nil; prefs.toggleMarked(chat.id) },
                    onDelete: { peek = nil; onDelete(chat) },
                    onClose: { peek = nil },
                    onRemoveRecent: { peek = nil; recents.remove(chat.id) })
                .environment(\.theme, theme).environment(\.lang, lang)
                .transition(.opacity)
                .zIndex(50)
            }
        }
        .task { hub = try? await session.messengerRepo.searchHub() }
    }

    // MARK: Частые собеседники

    @ViewBuilder
    private var topPeople: some View {
        if let top = hub?.top, !top.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(top) { p in
                        Button {
                            Haptics.impact(.light)
                            onOpen(p.peer)
                        } label: {
                            VStack(spacing: 7) {
                                AvatarView(name: p.name, size: 70, avatarID: p.avatar).clipShape(Circle())
                                    .overlay(Circle().stroke(theme.stroke, lineWidth: 0.5))
                                Text(p.name).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.text)
                                    .lineLimit(1).frame(width: 82)
                            }
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .transition(.opacity)
        } else if hub == nil {
            HStack(spacing: 14) {
                ForEach(0..<5, id: \.self) { _ in
                    VStack(spacing: 7) {
                        Circle().fill(theme.text.opacity(0.08)).frame(width: 70, height: 70)
                        SkeletonBlock(height: 10, width: 56)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .shimmer()
        }
    }

    // MARK: Нижняя строка разделов (листается, выбранный — в капсуле)

    private var sectionBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(HubSection.allCases) { sec in
                        Button {
                            Haptics.select()
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { section = sec }
                        } label: {
                            Text(sec.title(s))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(section == sec ? theme.text : theme.textSecondary)
                                .padding(.horizontal, 16).frame(height: 40)
                                .background {
                                    if section == sec {
                                        Capsule().fill(theme.text.opacity(theme.dark ? 0.12 : 0.08))
                                            .matchedGeometryEffect(id: "hubTab", in: tabNS)
                                    }
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(sec)
                    }
                }
                .padding(5)
            }
            .glass(Capsule())
            .padding(.horizontal, 24).padding(.bottom, 8)
            .onChange(of: section) { _, sec in withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(sec, anchor: .center) } }
        }
    }

    // MARK: Страницы

    @ViewBuilder
    private func page(_ sec: HubSection) -> some View {
        switch sec {
        case .chats: recentPage
        case .channels: channelsPage
        case .bots: botsPage
        default:
            SharedPage(kind: sec, repo: session.messengerRepo, player: session.player, onOpenChat: onOpen)
        }
    }

    private var recentPage: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if recents.items.isEmpty {
                    EmptyStateView(icon: "clock.arrow.circlepath", title: s.t("Здесь появятся недавние", "Recent chats appear here"),
                                   subtitle: s.t("Открывайте переписки, каналы и ботов — последние 20 будут под рукой.",
                                                 "Open chats, channels and bots — the last 20 stay at hand."))
                        .padding(.top, 50)
                } else {
                    HStack {
                        Text(s.t("НЕДАВНИЕ", "RECENT")).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.textSecondary)
                        Spacer()
                        Button(s.t("Очистить", "Clear")) { Haptics.impact(.light); recents.clear() }
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(theme.accentColor)
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)
                    ForEach(recents.items) { item in
                        let summary = chats.first { $0.id == item.id }
                        let peer = summary?.peer ?? item.peer
                        let isBot = hub?.bots.contains { $0.id == item.id } ?? false
                        hubRow(peer: peer, subtitle: subtitle(peer, isBot: isBot), unread: summary?.unread ?? 0,
                               muted: summary?.muted ?? false, openButton: isBot)
                            .onLongPressGesture(minimumDuration: 0.35) {
                                Haptics.impact(.medium)
                                withAnimation(.easeOut(duration: 0.18)) {
                                    peek = summary ?? ChatSummary(peer: peer, unread: 0, updatedAt: Date(), lastText: "", lastMine: false,
                                                                  lastRead: true, typing: nil)
                                }
                            }
                    }
                }
                Color.clear.frame(height: 80)
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var channelsPage: some View {
        let list = chats.filter { $0.peer.isChannel }.sorted { $0.updatedAt > $1.updatedAt }
        return ScrollView {
            LazyVStack(spacing: 0) {
                if list.isEmpty {
                    EmptyStateView(icon: "megaphone", title: s.t("Каналов пока нет", "No channels yet")).padding(.top, 50)
                }
                ForEach(list) { c in
                    hubRow(peer: c.peer, subtitle: "\(c.peer.memberCount) " + s.memberWord(channel: true),
                           unread: c.unread, muted: c.muted, openButton: false)
                }
                Color.clear.frame(height: 80)
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var botsPage: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let bots = hub?.bots, !bots.isEmpty {
                    ForEach(bots) { b in
                        hubRow(peer: b.peer, subtitle: BotUsers.text(b.monthly ?? 0, lang: lang), unread: chats.first { $0.id == b.id }?.unread ?? 0,
                               muted: false, openButton: true)
                    }
                } else if hub != nil {
                    EmptyStateView(icon: "cpu", title: s.t("Ботов пока нет", "No bots yet"),
                                   subtitle: s.t("Здесь будут боты, с которыми вы общались.", "Bots you've chatted with show up here."))
                        .padding(.top, 50)
                } else {
                    ProgressView().padding(.top, 50)
                }
                Color.clear.frame(height: 80)
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func subtitle(_ p: ChatPeer, isBot: Bool) -> String {
        if isBot, let b = hub?.bots.first(where: { $0.id == p.id }) { return BotUsers.text(b.monthly ?? 0, lang: lang) }
        if p.isGroup { return "\(p.memberCount) " + s.memberWord(channel: p.isChannel) }
        return p.username.map { "@" + $0 } ?? s.t("личная переписка", "personal chat")
    }

    private func hubRow(peer: ChatPeer, subtitle: String, unread: Int, muted: Bool, openButton: Bool) -> some View {
        Button {
            onOpen(peer)
        } label: {
            HStack(spacing: 12) {
                AvatarView(name: peer.name, size: 50, avatarID: peer.avatarID).clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if peer.isChannel { Image(systemName: "megaphone.fill").font(.system(size: 11)).foregroundStyle(theme.textTertiary) }
                        Text(peer.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                    }
                    Text(subtitle).font(.system(size: 14)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if openButton {
                    Text(s.t("ОТКРЫТЬ", "OPEN")).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 32)
                        .background(Color(red: 0.93, green: 0.3, blue: 0.2), in: Capsule())
                } else if unread > 0 {
                    Text(unread > 99 ? "99+" : "\(unread)")
                        .font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 8).frame(minWidth: 26, minHeight: 26)
                        .background(muted ? AnyShapeStyle(theme.textTertiary) : AnyShapeStyle(theme.accent), in: Capsule())
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(theme.stroke).frame(height: 0.5).padding(.leading, 78) }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Присланное из всех чатов: медиа, файлы, ссылки, музыка, голосовые

private struct SharedPage: View {
    let kind: HubSection
    let repo: MessengerRepository
    @ObservedObject var player: AudioPlayer
    var onOpenChat: (ChatPeer) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.openURL) private var openURL
    @ObservedObject private var voice = VoicePlayer.shared
    @State private var items: [SharedEntry] = []
    @State private var before: Double?
    @State private var more = false
    @State private var loaded = false
    @State private var loading = false
    @State private var viewer: ViewerRoute?
    @State private var fileURL: FileRoute?
    @State private var downloading: Set<String> = []

    private struct ViewerRoute: Identifiable { let id = UUID(); let media: [MediaItem]; let start: Int; let meta: [MediaMeta] }
    private struct FileRoute: Identifiable { let id = UUID(); let url: URL }

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        ScrollView {
            Group {
                if !loaded {
                    if kind == .media { GridSkeleton(rows: 4).padding(.top, 4) } else { ChatListSkeleton(count: 7) }
                } else if items.isEmpty {
                    EmptyStateView(icon: emptyIcon, title: emptyTitle,
                                   subtitle: s.t("Здесь собирается присланное из всех ваших чатов.", "Everything shared in all your chats gathers here."))
                        .padding(.top, 50)
                } else if kind == .media {
                    mediaGrid
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            row(item).onAppear { if item.id == items.last?.id { Task { await load(reset: false) } } }
                        }
                    }
                }
            }
            if loading && loaded { ProgressView().padding(16) }
            Color.clear.frame(height: 80)
        }
        .scrollDismissesKeyboard(.immediately)
        .task { if !loaded { await load(reset: true) } }
        .onAppear { if kind == .voice { installNext() } }
        .fullScreenCover(item: $viewer) { v in
            MediaViewer(media: v.media, start: v.start, meta: v.meta, onClose: { viewer = nil })
        }
        .sheet(item: $fileURL) { f in FileViewerSheet(url: f.url).environment(\.theme, theme).environment(\.lang, lang) }
    }

    private var emptyIcon: String {
        switch kind {
        case .media: return "photo.on.rectangle"
        case .files: return "doc"
        case .links: return "link"
        case .music: return "music.note"
        default: return "waveform"
        }
    }

    private var emptyTitle: String {
        switch kind {
        case .media: return s.t("Фото и видео пока нет", "No photos or videos yet")
        case .files: return s.t("Файлов пока нет", "No files yet")
        case .links: return s.t("Ссылок пока нет", "No links yet")
        case .music: return s.t("Музыки пока нет", "No music yet")
        default: return s.t("Голосовых пока нет", "No voice messages yet")
        }
    }

    private func load(reset: Bool) async {
        guard let api = kind.api, !loading, reset || more else { return }
        loading = true
        defer { loading = false }
        if let page = try? await repo.shared(kind: api, before: reset ? nil : before) {
            let known = Set(items.map(\.id))
            items = (reset ? [] : items) + page.items.filter { reset || !known.contains($0.id) }
            before = page.before
            more = page.more
        }
        loaded = true
    }

    private func date(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? FormatterCache.format(d, "HH:mm") : FormatterCache.format(d, "d MMM")
    }

    // MARK: Медиа: сетка 3 в ряд — фото картинкой, видео обложкой с длительностью и «скачать»

    private var mediaGrid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
        let media = items.compactMap { $0.attachment?.mediaItem }
        return LazyVGrid(columns: cols, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if let a = item.attachment, let mid = a.mediaID {
                    Color(white: 0.12)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay { RemoteImage(id: a.thumbID ?? mid, maxPixel: 360) }
                        .clipped()
                        .overlay(alignment: .bottomLeading) {
                            if a.kind == .video {
                                HStack(spacing: 3) {
                                    Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                                    Text(mmss(Int(safe: a.duration))).font(.system(size: 11, weight: .semibold).monospacedDigit())
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.black.opacity(0.5), in: Capsule())
                                .padding(5)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if a.kind == .video, MediaFileCache.shared.cached(mid) == nil {
                                // видео ещё не на телефоне — можно скачать
                                Button {
                                    Haptics.impact(.light)
                                    downloading.insert(mid)
                                    Task { _ = await MediaFileCache.shared.download(mid); downloading.remove(mid) }
                                } label: {
                                    Group {
                                        if downloading.contains(mid) { ProgressView().tint(.white).scaleEffect(0.7) }
                                        else { Image(systemName: "arrow.down").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                                    }
                                    .frame(width: 26, height: 26)
                                    .background(Color.black.opacity(0.5), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .padding(5)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let idx = media.firstIndex { $0.id == mid } ?? 0
                            let meta = items.compactMap { e -> MediaMeta? in
                                guard e.attachment?.mediaItem != nil else { return nil }
                                return MediaMeta(title: e.chat.name, subtitle: e.sender + " · " + date(e.at))
                            }
                            viewer = ViewerRoute(media: media, start: idx, meta: meta)
                        }
                        .onAppear { if i == items.count - 1 { Task { await load(reset: false) } } }
                }
            }
        }
    }

    // MARK: Строки: файл, ссылка, трек, голосовое

    @ViewBuilder
    private func row(_ item: SharedEntry) -> some View {
        switch kind {
        case .links: linkRow(item)
        case .music: musicRow(item)
        case .voice: voiceRow(item)
        default: fileRow(item)
        }
    }

    private func source(_ item: SharedEntry) -> some View {
        Button { onOpenChat(item.chat) } label: {
            Text((item.chat.isGroup ? item.sender + " · " : "") + item.chat.name + " · " + date(item.at))
                .font(.system(size: 12)).foregroundStyle(theme.textTertiary).lineLimit(1)
        }
        .buttonStyle(.plain)
    }

    private func fileRow(_ item: SharedEntry) -> some View {
        let a = item.attachment
        let ext = ((a?.name ?? "") as NSString).pathExtension.uppercased()
        return Button {
            guard let mid = a?.mediaID else { return }
            downloading.insert(mid)
            Task {
                if let url = await MediaFileCache.shared.download(mid, fallback: ext.isEmpty ? "bin" : ext.lowercased()) { fileURL = FileRoute(url: url) }
                downloading.remove(mid)
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.accent)
                    if let mid = a?.mediaID, downloading.contains(mid) {
                        ProgressView().tint(.white)
                    } else {
                        Text(ext.isEmpty ? "FILE" : String(ext.prefix(4))).font(.system(size: 12, weight: .heavy)).foregroundStyle(.white)
                    }
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(a?.name ?? s.t("Файл", "File")).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                        .lineLimit(1).truncationMode(.middle)
                    Text((a?.size ?? 0) > 0 ? ByteCountFormatter.string(fromByteCount: Int64(a?.size ?? 0), countStyle: .file) : " ")
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    source(item)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func linkRow(_ item: SharedEntry) -> some View {
        let url = item.url.flatMap(URL.init(string:))
        let host = url?.host?.replacingOccurrences(of: "www.", with: "") ?? item.url ?? ""
        return Button {
            if let url, let safe = SafeLink.url(url.absoluteString) { openURL(safe) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(String(host.prefix(1)).uppercased())
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(LinearGradient(colors: [theme.accentColor, theme.accentColor.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(host).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                    Text(item.url ?? "").font(.system(size: 13)).foregroundStyle(theme.accentColor).lineLimit(1)
                    if let t = item.text, !t.isEmpty, t != item.url {
                        Text(t).font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(2)
                    }
                    source(item)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var tracks: [Track] { items.compactMap { $0.attachment?.track } }

    private func musicRow(_ item: SharedEntry) -> some View {
        let track = item.attachment?.track
        let current = track.map { player.isCurrent($0) } ?? false
        return Button {
            guard let track else { return }
            Haptics.impact(.light)
            player.toggle(track, queue: tracks)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    if let cover = item.attachment?.thumbID { RemoteImage(id: cover, maxPixel: 160) } else { theme.accent }
                    Circle().fill(Color.black.opacity(item.attachment?.thumbID == nil ? 0 : 0.3))
                    Image(systemName: current && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 48, height: 48).clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.attachment?.displayTitle ?? "").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(current ? theme.accentColor : theme.text).lineLimit(1).truncationMode(.middle)
                    if let artist = item.attachment?.artist, !artist.isEmpty {
                        Text(artist).font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(1)
                    }
                    source(item)
                }
                Spacer(minLength: 0)
                Text(mmss(Int(safe: item.attachment?.duration ?? 0))).font(.system(size: 13).monospacedDigit()).foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func voiceRow(_ item: SharedEntry) -> some View {
        if let a = item.attachment, let mid = a.mediaID {
            if a.kind == .circle {
                HubCircleRow(item: item, attachment: a, playback: CircleFocus.shared.playback(for: mid), source: AnyView(source(item)))
            } else {
                HubVoiceRow(item: item, attachment: a, mediaID: mid, clock: voice.isCurrent(mid) ? voice.clock : PlaybackClock.idle,
                            source: AnyView(source(item)))
            }
        }
    }

    /// Дослушали голосовое или досмотрели кружок в поиске — сразу следующее из этого же списка (как в чате)
    private func installNext() {
        VoicePlayer.shared.nextProvider = { id in
            let list: [ChatMediaNext] = items.compactMap { e in
                guard let a = e.attachment, let m = a.mediaID, a.kind == .voice || a.kind == .circle else { return nil }
                return ChatMediaNext(id: m, mediaID: m, duration: a.duration, circle: a.kind == .circle, messageID: e.messageID)
            }
            guard let i = list.firstIndex(where: { $0.id == id }), i + 1 < list.count else { return nil }
            return list[i + 1]
        }
        VoicePlayer.shared.onAdvance = nil
    }
}

// MARK: - Голосовое в поиске: живая волна, перемотка пальцем по волне, скорость, время

private struct HubVoiceRow: View {
    let item: SharedEntry
    let attachment: ChatAttachment
    let mediaID: String
    @ObservedObject var clock: PlaybackClock
    let source: AnyView

    @ObservedObject private var voice = VoicePlayer.shared
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var scrub: Double?

    private var current: Bool { voice.isCurrent(mediaID) }
    private var playing: Bool { current && voice.isPlaying }
    private var progress: Double { scrub ?? (current ? clock.value : 0) }

    var body: some View {
        let s = Strings(lang: lang)
        let total = max(attachment.duration, 0)
        HStack(spacing: 12) {
            Button {
                Haptics.impact(.light)
                voice.toggle(id: mediaID, mediaID: mediaID, duration: total)
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(theme.accentColor, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressStyle())
            VStack(alignment: .leading, spacing: 4) {
                Text(item.mine ? s.t("Вы", "You") : item.sender)
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                GeometryReader { g in
                    Waveform(samples: attachment.waveform, progress: progress,
                             active: theme.accentColor, inactive: theme.textTertiary.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in scrub = max(0, min(1, v.location.x / max(g.size.width, 1))) }
                                .onEnded { v in
                                    let f = max(0, min(1, v.location.x / max(g.size.width, 1)))
                                    if !current { voice.toggle(id: mediaID, mediaID: mediaID, duration: total) }
                                    voice.seek(toFraction: f)
                                    if !voice.isPlaying { voice.resume() }
                                    Haptics.select()
                                    scrub = nil
                                }
                        )
                }
                .frame(height: 20).frame(maxWidth: 200)
                source
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                Text(mmss(Int(safe: current || scrub != nil ? total * progress : total)))
                    .font(.system(size: 13).monospacedDigit()).foregroundStyle(theme.textTertiary)
                if current {
                    Button { voice.cycleRate(); Haptics.select() } label: {
                        Text(voice.rate == 1 ? "1×" : (voice.rate == 1.5 ? "1,5×" : "2×"))
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(theme.accentColor)
                            .padding(.horizontal, 7).frame(height: 22)
                            .background(theme.accentColor.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale))
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .animation(.easeOut(duration: 0.18), value: current)
    }
}

// MARK: - Кружок в поиске: играет прямо в строке, кольцо прогресса

private struct HubCircleRow: View {
    let item: SharedEntry
    let attachment: ChatAttachment
    @ObservedObject var playback: CirclePlayback
    let source: AnyView

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        let s = Strings(lang: lang)
        let size: CGFloat = playback.started ? 120 : 64
        HStack(spacing: 12) {
            Button {
                guard let mid = attachment.mediaID else { return }
                Haptics.impact(.light)
                playback.toggle(mediaID: mid, duration: attachment.duration)
            } label: {
                ZStack {
                    if let id = attachment.thumbID { RemoteImage(id: id) } else { theme.surface }
                    if playback.started, let player = playback.player { PlayerLayerView(player: player) }
                    if !playback.isPlaying {
                        Image(systemName: "play.fill")
                            .font(.system(size: playback.started ? 20 : 15, weight: .bold)).foregroundStyle(.white)
                            .frame(width: playback.started ? 44 : 30, height: playback.started ? 44 : 30)
                            .background(Color.black.opacity(0.4), in: Circle())
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().trim(from: 0, to: playback.progress)
                    .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(1.5))
            }
            .buttonStyle(.plain)
            .onAppear { if let id = attachment.mediaID { MediaFileCache.shared.prefetch(id) } }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.mine ? s.t("Вы", "You") : item.sender)
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Label(s.t("Видеосообщение", "Video message"), systemImage: "video.circle")
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                source
            }
            Spacer(minLength: 0)
            Text(mmss(Int(safe: playback.started ? attachment.duration * playback.progress : attachment.duration)))
                .font(.system(size: 13).monospacedDigit()).foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: playback.started)
    }
}
