import SwiftUI
import UIKit

private struct InfoViewerItem: Identifiable {
    let id = UUID()
    let media: [MediaItem]
    let start: Int
    var hero: HeroSource.Snapshot?
}

private struct InfoAvatarTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Профиль переписки (как в Telegram: нажали на имя сверху)

struct ChatInfoView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject private var prefs = ChatListPrefs.shared
    var onPlayMusic: (Track, [Track]) -> Void
    var onLeftGroup: () -> Void

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var profile: UserProfile?
    @State private var history: [ChatMessage] = []
    @State private var tab = 0
    @State private var showContact = false
    @State private var showInvite = false
    @State private var showEdit = false
    @State private var showRequests = false
    @State private var showProfile = false
    @State private var openedMember: String?
    @State private var confirmBlock = false
    @State private var confirmLeave = false
    @State private var showStats = false
    @State private var showQR = false
    @State private var membersList: MembersListKind?
    @State private var aboutExpanded = false
    @State private var viewer: InfoViewerItem?
    @State private var frames = FrameBoxes()
    @State private var previewFile: PreviewFile?
    @State private var notice: String?
    @State private var avatarRoute: AvatarViewerRoute?
    @State private var pagerIndex = 0
    // три положения аватарки, как на странице человека: 0 — кружок, 1 — фото на всю ширину, 2 — на весь экран
    @State private var stage = 0
    @State private var stageForward = true
    @State private var stageStarted = false            // при первом открытии сразу встаём в среднее положение
    @State private var avatarTop: CGFloat = 0
    @State private var pullArmed = true
    @State private var tracker = PageScrollTracker()
    private var pageTop: CGFloat { TopInset.value }
    private static let avatarPad: CGFloat = 40
    private var headerHeight: CGFloat { UIScreen.main.bounds.width * 0.96 }
    private var hasStagePhotos: Bool { !isGroup && profile?.blockedMe != true && !(profile?.avatars.isEmpty ?? true) }
    private var st: Int { hasStagePhotos ? stage : 0 }

    private var s: Strings { Strings(lang: lang) }
    private var isGroup: Bool { model.peer.isGroup }
    private var group: GroupInfo? { model.group }

    private var media: [ChatAttachment] {
        history.flatMap(\.attachments).filter { ($0.kind == .photo || $0.kind == .video) && $0.mediaID != nil }
    }
    private var files: [(message: ChatMessage, file: ChatAttachment)] {
        history.flatMap { m in m.attachments.filter { $0.kind == .file && !$0.isMusic }.map { (m, $0) } }
    }
    private var music: [ChatMusicItem] { chatMusicItems(history) }
    private var voices: [(message: ChatMessage, voice: ChatAttachment)] {
        history.flatMap { m in m.attachments.filter { $0.kind == .voice }.map { (m, $0) } }
    }

    /// Вкладки показываются, только если такое было в переписке
    private var tabs: [(id: String, title: String)] {
        var list: [(String, String)] = []
        if !media.isEmpty { list.append(("media", s.t("Медиа", "Media"))) }
        if !files.isEmpty { list.append(("files", s.t("Файлы", "Files"))) }
        if !music.isEmpty { list.append(("music", s.t("Музыка", "Music"))) }
        if !voices.isEmpty { list.append(("voice", s.t("Голосовые", "Voice"))) }
        return list
    }

    var body: some View {
        ZStack(alignment: .top) {
            SpaceBackground(isDark: theme.dark, showStars: false).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    headerBlock
                    actionRow
                    dmRows
                    infoCard
                    if !isGroup { CommonChatsCard(userID: model.peer.id) }
                    if isGroup, let group, group.isAdmin { adminCard(group) }
                    // в канале подписчики — в отдельном списке, как в Telegram; в группе участники видны сразу
                    if isGroup, let group, !group.members.isEmpty, !group.isChannel { membersCard(group) }
                    sharedSection
                }
                .coordinateSpace(name: "infoBody")
                .environmentObject(tracker)
                .overlay(alignment: .topLeading) { stageOverlay }
                .onPreferenceChange(InfoAvatarTopKey.self) { v in if st == 0 { avatarTop = v } }
                .onAppear {
                    tracker.onChange = { offset in handleScroll(offset) }
                }
                .padding(.top, pageTop)                         // отступ снаружи: фото рисуется от верха страницы без сдвига, пустоты под ним нет
                .padding(.bottom, 40)
            }
            .coordinateSpace(name: "pageScroll")
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .environment(\.pageTopInset, pageTop)
            topBar
        }
        .overlay {
            // фото увеличивается плавно — «вырастает» из аватарки
            if let route = avatarRoute, let photos = profile?.avatars, !photos.isEmpty {
                AvatarViewer(name: model.peer.name, photos: photos, start: route.index,
                             onClose: { avatarRoute = nil })
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.12, anchor: UnitPoint(x: 0.5, y: 0.2)).combined(with: .opacity),
                        removal: .scale(scale: 0.4, anchor: UnitPoint(x: 0.5, y: 0.2)).combined(with: .opacity)))
                    .zIndex(20)
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.86), value: avatarRoute?.id)
        .edgeSwipeBack { if avatarRoute == nil { dismiss() } }
        .preferredColorScheme(theme.dark ? .dark : .light)
        .task {
            history = await model.loadFullHistory()
            await loadProfile()
        }
        .overlay(alignment: .bottom) {
            if let notice {
                ToastView(text: notice).padding(.bottom, 30)
                    .task(id: notice) { try? await Task.sleep(nanoseconds: 2_500_000_000); self.notice = nil }
            }
        }
        .sheet(isPresented: $showContact) {
            ContactNameSheet(peerID: model.peer.id, currentName: model.isContact ? model.peer.name : (model.realName ?? model.peer.name),
                             isContact: model.isContact) {
                await model.refresh()
                await session.chats.refresh()
                await loadProfile()
            }
            .environmentObject(session)
            .environment(\.theme, theme)
            .presentationDetents([.height(300)])
            .presentationBackground(theme.sheet)
        }
        .sheet(isPresented: $showInvite) {
            if let group {
                GroupInviteSheet(group: group) { await model.refresh() }
                    .environmentObject(session).environmentObject(flow)
                    .environment(\.theme, theme)
                    .presentationBackground(theme.sheet)
            }
        }
        .sheet(isPresented: $showEdit) {
            if let group {
                GroupEditSheet(group: group, onDone: { await model.refresh(); await session.chats.refresh() },
                               onDeleted: { onLeftGroup() })
                    .environmentObject(session)
                    .environment(\.theme, theme).environment(\.lang, lang)
                    .presentationBackground(theme.sheet)
            }
        }
        .sheet(isPresented: $showStats) {
            NavigationStack {
                GroupStatsView(groupID: model.peer.id, title: model.peer.name, channel: group?.isChannel ?? model.peer.isChannel)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(s.close) { showStats = false } } }
            }
            .environmentObject(session)
            .environment(\.theme, theme).environment(\.lang, lang)
            .presentationBackground(theme.sheet)
        }
        .sheet(isPresented: $showQR) {
            if let link = groupLink {
                GroupQRSheet(link: link, title: model.peer.name)
                    .environment(\.theme, theme).environment(\.lang, lang)
                    .presentationDetents([.medium])
                    .presentationBackground(theme.sheet)
            }
        }
        .sheet(item: $membersList) { kind in
            if let group {
                GroupMembersListSheet(group: group, adminsOnly: kind == .admins, me: session.serverID,
                                      onOpen: { id in
                                          membersList = nil
                                          DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openedMember = id }
                                      },
                                      onSetRole: { setRole($0, $1) },
                                      onRemove: { remove($0) },
                                      canRemove: { canRemove($0, in: group) })
                    .environment(\.theme, theme).environment(\.lang, lang)
                    .presentationBackground(theme.sheet)
            }
        }
        .sheet(isPresented: $showRequests) {
            GroupRequestsSheet(groupID: model.peer.id) { await model.refresh() }
                .environmentObject(session).environmentObject(flow)
                .environment(\.theme, theme).environment(\.lang, lang)
        }
        .fullScreenCover(isPresented: $showProfile) {
            PublicProfileSheet(source: .id(model.peer.id))
                .environmentObject(session).environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
        .profileSheet(id: $openedMember)
        .overlay {
            // из профиля — то же «вылетающее» фото, что и в переписке; счётчик «3 из 12» остаётся здесь
            if let item = viewer {
                HeroViewerHost(media: item.media, start: item.start, hero: item.hero) { viewer = nil }
                    .id(item.id)
                    .ignoresSafeArea()
                    .zIndex(10)
            }
        }
        .sheet(item: $previewFile) { file in FileViewerSheet(url: file.url).environment(\.theme, theme).environment(\.lang, lang) }
        .confirmationDialog(s.blockQuestion(model.peer.name), isPresented: $confirmBlock, titleVisibility: .visible) {
            Button(s.blockUser, role: .destructive) { setBlocked(true) }
            Button(s.cancel, role: .cancel) {}
        } message: { Text(s.blockHint) }
        .confirmationDialog((group?.isChannel ?? model.peer.isChannel) ? s.t("Покинуть канал?", "Leave channel?") : s.t("Покинуть группу?", "Leave group?"),
                            isPresented: $confirmLeave, titleVisibility: .visible) {
            Button(s.t("Покинуть", "Leave"), role: .destructive) { leave() }
            Button(s.cancel, role: .cancel) {}
        }
    }

    // MARK: Верхняя полоса

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
                    .frame(width: 42, height: 42).glassCircle()
                    .frame(width: 48, height: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .zIndex(10)
            Spacer()
            // «Изм.» — только в своей группе (админу); на профиле человека кнопки нет
            if isGroup, group?.isAdmin == true {
                Button { showEdit = true } label: { pillLabel(s.t("Изм.", "Edit")) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.top, 6)
    }

    private func pillLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
            .padding(.horizontal, 16).frame(height: 42).glassCapsule()
    }

    // MARK: Шапка

    private var headerBlock: some View {
        VStack(spacing: 6) {
            // фото профиля сразу здесь: нажали — раскрывается на весь экран и листается
            if hasStagePhotos, let photos = profile?.avatars {
                AvatarPager(name: model.peer.name, photos: photos, size: 112, index: $pagerIndex) {
                    setStage(1)
                }
                .opacity(st >= 1 ? 0 : 1)                              // вместо кружка рисует AvatarStage
                .frame(height: st >= 1 ? max(112, headerHeight - (Self.avatarPad + pageTop) - 4) : 112, alignment: .top)
                .background(GeometryReader { g in
                    Color.clear.preference(key: InfoAvatarTopKey.self, value: g.frame(in: .named("infoBody")).minY)
                })
                .padding(.top, Self.avatarPad)
            } else {
                AvatarView(name: model.peer.name, size: 112, avatarID: model.peer.avatarID).clipShape(Circle())
                    .padding(.top, Self.avatarPad)
            }
            if st == 0 {
                Text(model.peer.name)
                    .font(.system(size: 26, weight: .bold)).foregroundStyle(theme.text)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                if let real = model.realName, model.isContact, real != model.peer.name, !isGroup {
                    Text(real).font(.system(size: 14)).foregroundStyle(theme.textTertiary)
                }
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
            }
            requestsBanner.padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .background(alignment: .top) { PageScrollMarker(lockTop: true, reportPull: hasStagePhotos) }
    }

    // MARK: Три положения аватарки

    @ViewBuilder
    private var stageOverlay: some View {
        if hasStagePhotos, let p = profile {
            let count = p.avatars.count
            AvatarStage(expand: CGFloat(st), circleTop: avatarTop + pageTop, screen: UIScreen.main.bounds.size,
                        headerHeight: headerHeight, topInset: pageTop,
                        photos: p.avatars, page: pagerIndex, forward: stageForward,
                        name: model.peer.name, status: subtitle,
                        onStep: { stepPhoto($0, count: count) },
                        onCenter: { setStage(stage == 1 ? 2 : 1) },
                        onVertical: { stageDrag($0) },
                        onClose: { setStage(0) })
                .offset(y: -pageTop)
                .allowsHitTesting(st >= 1)
            if st == 2 {
                AvatarViewer(name: p.name, photos: p.avatars, start: pagerIndex, onClose: { setStage(0) })
                    .padding(.top, pageTop)
                    .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                    .background(Color.black)
                    .offset(y: -pageTop)
                    .transition(.opacity)
            }
        }
    }

    private func handleScroll(_ offset: CGFloat) {
        if offset > -8, !pullArmed { pullArmed = true }
        guard hasStagePhotos else { return }
        let pull = -offset
        if pull > 62, stage == 0, pullArmed { pullArmed = false; Haptics.impact(.medium); setStage(1) }
        if pull > 150, stage == 1, pullArmed { pullArmed = false; Haptics.impact(.heavy); setStage(2) }
        if offset > 40, stage == 1 { setStage(0) }
    }

    private func setStage(_ n: Int) {
        guard stage != n else { return }
        Haptics.impact(.light)
        if n == 0 || stage == 0 { stageForward = false }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.84)) {
            stage = n
            if n == 0 { pagerIndex = 0 }
        }
    }

    private func stepPhoto(_ delta: Int, count: Int) {
        guard count > 1 else { return }
        let next = max(0, min(count - 1, pagerIndex + delta))
        guard next != pagerIndex else { return }
        Haptics.select()
        stageForward = delta > 0
        withAnimation(.easeInOut(duration: 0.28)) { pagerIndex = next }
    }

    private func stageDrag(_ dy: CGFloat) {
        if stage == 1 {
            if dy > 50 { Haptics.impact(.medium); setStage(2) } else if dy < -50 { setStage(0) }
        } else if stage == 2, abs(dy) > 60 {
            setStage(1)
        }
    }

    private var subtitle: String {
        if isGroup {
            let count = group?.count ?? model.peer.memberCount
            let channel = group?.isChannel ?? model.peer.isChannel
            // «661 подписчик», как в Telegram
            return "\(count) " + Self.countWord(count, channel: channel, lang: lang)
        }
        return s.lastSeenText(model.lastSeen)
    }

    static func countWord(_ n: Int, channel: Bool, lang: AppLanguage) -> String {
        guard lang == .ru else { return channel ? (n == 1 ? "subscriber" : "subscribers") : (n == 1 ? "member" : "members") }
        let m100 = n % 100, m10 = n % 10
        let form = (11...14).contains(m100) ? 2 : (m10 == 1 ? 0 : ((2...4).contains(m10) ? 1 : 2))
        return (channel ? ["подписчик", "подписчика", "подписчиков"] : ["участник", "участника", "участников"])[form]
    }

    // MARK: Кнопки

    private var actionRow: some View {
        HStack(spacing: 10) {
            if isGroup {
                // как в Telegram: звук, чат обсуждения (или «пригласить»), ещё
                tile(group?.muted == true ? "bell.slash.fill" : "bell.fill",
                     group?.muted == true ? s.t("без звука", "muted") : s.t("звук", "sound")) { toggleMute() }
                if let d = group?.discussion {
                    tile("bubble.left.fill", s.t("чат", "chat")) { openDiscussion(d) }
                } else if canInvite {
                    tile("person.badge.plus", s.t("пригласить", "invite")) { showInvite = true }
                }
                Menu {
                    if canInvite && group?.discussion != nil {
                        Button { showInvite = true } label: { Label(s.t("Пригласить", "Invite"), systemImage: "person.badge.plus") }
                    }
                    if let link = groupLink {
                        ShareLink(item: link, message: Text(s.t("Заходи в Orbita", "Join on Orbita"))) {
                            Label(s.t("Поделиться ссылкой", "Share link"), systemImage: "square.and.arrow.up")
                        }
                        Button { showQR = true } label: { Label(s.t("QR-код", "QR code"), systemImage: "qrcode") }
                    }
                    if group?.isAdmin == true {
                        Button { showStats = true } label: { Label(s.t("Статистика", "Statistics"), systemImage: "chart.bar.fill") }
                        Button { showEdit = true } label: { Label(s.t("Настройки", "Settings"), systemImage: "gearshape") }
                    }
                    Divider()
                    Button(role: .destructive) { confirmLeave = true } label: {
                        Label((group?.isChannel ?? model.peer.isChannel) ? s.t("Отписаться", "Unfollow") : s.t("Покинуть группу", "Leave group"),
                              systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    tileLabel("ellipsis", s.t("ещё", "more"))
                }
            } else {
                tile("phone.fill", s.t("Звонок", "Call")) { callPeer(video: false) }
                tile("video.fill", s.t("Видео", "Video")) { callPeer(video: true) }
                tile("person.crop.circle", s.t("Профиль", "Profile")) { showProfile = true }
                let dmMuted = { _ = prefs.muteTick; return prefs.isDMMuted(model.peer.id) }()
                tile(dmMuted ? "bell.slash.fill" : "bell.fill",
                     dmMuted ? s.t("Без звука", "Muted") : s.t("Звук", "Sound")) {
                    prefs.setDMMuted(model.peer.id, !prefs.isDMMuted(model.peer.id))
                    Haptics.impact(.light)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// «В контакты» и «Заблокировать» — отдельными строками под кнопками
    @ViewBuilder
    private var dmRows: some View {
        if !isGroup {
            VStack(spacing: 10) {
                dmRow(model.isContact ? "person.fill.checkmark" : "person.badge.plus",
                      model.isContact ? s.t("Изменить контакт", "Edit contact") : s.t("Добавить в контакты", "Add to contacts")) {
                    showContact = true
                }
                ttlMenu
                dmRow(profile?.blockedByMe == true ? "hand.raised.slash" : "hand.raised.fill",
                      profile?.blockedByMe == true ? s.unblockUser : s.blockUser, danger: profile?.blockedByMe != true) {
                    if profile?.blockedByMe == true { setBlocked(false) } else { confirmBlock = true }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// Варианты таймера исчезающих сообщений (секунды) и подписи
    private static let ttlOptions: [Int] = [0, 5, 60, 3600, 86400, 7 * 86400, 30 * 86400]

    private func ttlLabel(_ sec: Int) -> String {
        switch sec {
        case 0: return s.t("Выключено", "Off")
        case 5: return s.t("5 секунд", "5 seconds")
        case 60: return s.t("1 минута", "1 minute")
        case 3600: return s.t("1 час", "1 hour")
        case 86400: return s.t("24 часа", "24 hours")
        case 7 * 86400: return s.t("7 дней", "7 days")
        case 30 * 86400: return s.t("30 дней", "30 days")
        default: return "\(sec)"
        }
    }

    private var ttlMenu: some View {
        Menu {
            ForEach(Self.ttlOptions, id: \.self) { sec in
                Button {
                    Task { await model.setTTL(sec) }
                } label: {
                    if model.ttl == sec { Label(ttlLabel(sec), systemImage: "checkmark") } else { Text(ttlLabel(sec)) }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "timer").font(.system(size: 17)).frame(width: 24)
                Text(s.t("Исчезающие сообщения", "Disappearing messages")).font(.system(size: 17))
                Spacer()
                Text(model.ttl == 0 ? s.t("Выкл", "Off") : ttlLabel(model.ttl))
                    .font(.system(size: 15)).foregroundStyle(theme.textSecondary)
            }
            .foregroundStyle(theme.accentColor)
            .padding(.horizontal, 16).frame(height: 52)
            .glass(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
        }
    }

    private func dmRow(_ icon: String, _ title: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 17)).frame(width: 24)
                Text(title).font(.system(size: 17))
                Spacer()
            }
            .foregroundStyle(danger ? theme.danger : theme.accentColor)
            .padding(.horizontal, 16).frame(height: 52)
            .glass(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
    }

    private var canInvite: Bool {
        guard let g = group else { return false }
        return g.isAdmin || (!g.isChannel && (g.isOpen || g.perms.invite))
    }

    private func openDiscussion(_ d: DiscussionRef) {
        let peer = ChatPeer(id: d.id, name: d.name, username: nil, avatarID: nil, isGroup: true, type: "group")
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { PushManager.shared.openChat = ChatRoute(peer: peer) }
    }

    private var groupLink: URL? {
        guard let ref = group?.linkRef else { return nil }
        return GroupLinks.url(ref: ref)
    }

    @ViewBuilder
    private var requestsBanner: some View {
        if let g = group, g.isAdmin, g.requests > 0 {
            Button { showRequests = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.clock").foregroundStyle(theme.accentColor)
                    Text(s.t("Заявки на вступление", "Join requests")).font(.system(size: 15, weight: .medium)).foregroundStyle(theme.text)
                    Text("\(g.requests)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                        .background(theme.accent, in: Capsule())
                }
                .padding(.horizontal, 16).frame(height: 40)
                .glassCapsule(interactive: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func callPeer(video: Bool) {
        session.calls.start(peer: model.peer, video: video)
    }

    private func tile(_ icon: String, _ title: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(icon, title, danger: danger) }.buttonStyle(PressStyle())
    }

    private func tileLabel(_ icon: String, _ title: String, danger: Bool = false) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 20))
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(danger ? theme.danger : theme.accentColor)
        .frame(maxWidth: .infinity).frame(height: 62)
        .card(theme, radius: 14)
    }

    // MARK: Данные

    @ViewBuilder
    private var infoCard: some View {
        if isGroup {
            groupAboutCard
        } else {
            let rows = infoRows
            if !rows.isEmpty { ProfileInfoCard(rows: rows).padding(.horizontal, 16) }
        }
    }

    private var infoRows: [ProfileInfoRow] {
        var rows: [ProfileInfoRow] = []
        if isGroup {
            let channel = group?.isChannel ?? model.peer.isChannel
            if let about = group?.about, !about.isEmpty {
                rows.append(ProfileInfoRow(label: channel ? s.t("О канале", "About") : s.t("О группе", "About"), value: about))
            }
            if let g = group, g.isOpen, let ref = g.linkRef, let link = GroupLinks.url(ref: ref) {
                rows.append(ProfileInfoRow(label: s.t("Ссылка", "Link"), value: link.absoluteString, accent: true, kind: .link))
            }
            if let g = group, g.noForward {
                rows.append(ProfileInfoRow(label: s.t("Защита", "Protection"), value: s.t("Копирование запрещено", "Copying is restricted")))
            }
            if let g = group, !g.isChannel, g.slow > 0 {
                rows.append(ProfileInfoRow(label: s.t("Медленный режим", "Slow mode"), value: s.slowLabel(g.slow)))
            }
        } else if let p = profile {
            if let phone = p.phone, !phone.isEmpty { rows.append(ProfileInfoRow(label: s.phoneLabel, value: phone, accent: true, kind: .phone)) }
            if let u = p.username, !u.isEmpty { rows.append(ProfileInfoRow(label: s.t("Имя пользователя", "Username"), value: "@" + u, accent: true,
                                           kind: .username(link: DeepLink.profileLink(username: u, userID: p.id)))) }
            if let b = s.birthdayText(p.birthday), !b.isEmpty { rows.append(ProfileInfoRow(label: s.birthday, value: b)) }
            if !p.bio.isEmpty { rows.append(ProfileInfoRow(label: s.bioLabel, value: p.bio)) }
        }
        return rows
    }

    /// Ссылка (с QR-кодом) и описание, длинное сворачивается в «ещё» — как в Telegram
    @ViewBuilder
    private var groupAboutCard: some View {
        let g = group
        let about = g?.about ?? ""
        let link = (g?.isOpen == true || g?.isAdmin == true) ? groupLink : nil
        let slow = g.map { !$0.isChannel && $0.slow > 0 } ?? false
        if link != nil || !about.isEmpty || g?.noForward == true || slow {
            VStack(alignment: .leading, spacing: 0) {
                if let link {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.t("ссылка", "link")).font(.system(size: 14)).foregroundStyle(theme.text)
                            Text(link.absoluteString).font(.system(size: 17)).foregroundStyle(theme.accentColor).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIPasteboard.general.string = link.absoluteString
                            Haptics.notify(.success)
                            notice = s.t("Ссылка скопирована", "Link copied")
                        }
                        Spacer(minLength: 8)
                        Button { showQR = true } label: {
                            Image(systemName: "qrcode").font(.system(size: 24)).foregroundStyle(theme.accentColor)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle())
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    if !about.isEmpty { aboutDivider }
                }
                if !about.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.t("описание", "description")).font(.system(size: 14)).foregroundStyle(theme.text)
                        RichInlineText(text: about, entities: [], size: 17, color: theme.text, linkColor: theme.accentColor, detect: true)
                            .lineLimit(aboutExpanded ? nil : 3)
                            .environment(\.openURL, OpenURLAction { url in ChatEntity(url: url) != nil ? .handled : .systemAction })
                        if !aboutExpanded && (about.count > 110 || about.filter { $0 == "\n" }.count > 2) {
                            HStack {
                                Spacer()
                                Button {
                                    Haptics.select()
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { aboutExpanded = true }
                                } label: {
                                    Text(s.t("ещё", "more")).font(.system(size: 16, weight: .medium)).foregroundStyle(theme.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                }
                if g?.noForward == true {
                    aboutDivider
                    smallRow(s.t("Копирование запрещено", "Copying is restricted"), icon: "lock.fill")
                }
                if slow, let g {
                    aboutDivider
                    smallRow(s.t("Медленный режим: ", "Slow mode: ") + s.slowLabel(g.slow), icon: "timer")
                }
            }
            .card(theme, radius: 18)
            .padding(.horizontal, 16)
        }
    }

    private var aboutDivider: some View { Rectangle().fill(theme.stroke).frame(height: 0.5).padding(.leading, 16) }

    private func smallRow(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 14)).foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// Для админов: «Администраторы», «Подписчики», «Статистика», «Настройки канала» — как в Telegram
    private func adminCard(_ group: GroupInfo) -> some View {
        let admins = group.members.filter { $0.role == "owner" || $0.role == "admin" }.count
        return VStack(spacing: 0) {
            adminRow("checkmark.shield.fill", Color(red: 0.2, green: 0.78, blue: 0.35), s.t("Администраторы", "Administrators"),
                     value: admins > 0 ? "\(admins)" : nil) { membersList = .admins }
            aboutDivider.padding(.leading, 46)
            adminRow("person.2.fill", Color(red: 0.2, green: 0.55, blue: 1.0),
                     group.isChannel ? s.t("Подписчики", "Subscribers") : s.t("Участники", "Members"),
                     value: "\(group.count)") { membersList = .all }
            aboutDivider.padding(.leading, 46)
            adminRow("chart.bar.fill", Color(red: 0.69, green: 0.32, blue: 0.87), s.t("Статистика", "Statistics"), value: nil) {
                showStats = true
            }
            aboutDivider.padding(.leading, 46)
            adminRow("slider.horizontal.3", Color(red: 1.0, green: 0.62, blue: 0.04),
                     group.isChannel ? s.t("Настройки канала", "Channel settings") : s.t("Настройки группы", "Group settings"),
                     value: group.requests > 0 ? "\(group.requests)" : nil) { showEdit = true }
        }
        .card(theme, radius: 18)
        .padding(.horizontal, 16)
    }

    private func adminRow(_ icon: String, _ color: Color, _ title: String, value: String?, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title).font(.system(size: 17)).foregroundStyle(theme.text)
                Spacer()
                if let value { Text(value).font(.system(size: 17)).foregroundStyle(theme.textSecondary) }
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 12).frame(height: 54).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func canRemove(_ member: GroupMember, in group: GroupInfo) -> Bool {
        group.isAdmin && member.id.lowercased() != session.serverID && member.role != "owner"
            && (member.role != "admin" || group.isOwner)
    }

    private func membersCard(_ group: GroupInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(group.count) \(s.memberWord(channel: group.isChannel))".uppercased())
                .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
            ForEach(group.members) { member in
                Button { if member.id.lowercased() != session.serverID { openedMember = member.id } } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: member.name, size: 42, avatarID: member.avatarID).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(member.name).font(.system(size: 16, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                            if let u = member.username { Text("@" + u).font(.system(size: 13)).foregroundStyle(theme.textTertiary) }
                        }
                        Spacer()
                        if member.role == "owner" {
                            Text(s.t("владелец", "owner")).font(.system(size: 12)).foregroundStyle(theme.accentColor)
                        } else if member.role == "admin" {
                            Text(s.t("админ", "admin")).font(.system(size: 12)).foregroundStyle(theme.accentColor)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if group.isOwner, member.id.lowercased() != session.serverID, member.role != "owner" {
                        Button { setRole(member, member.role == "admin" ? "member" : "admin") } label: {
                            Label(member.role == "admin" ? s.t("Снять админа", "Remove admin") : s.t("Сделать админом", "Make admin"),
                                  systemImage: member.role == "admin" ? "person.fill.xmark" : "person.badge.shield.checkmark")
                        }
                    }
                    if canRemove(member, in: group) {
                        Button(role: .destructive) { remove(member) } label: {
                            Label(s.t("Удалить", "Remove"), systemImage: "person.badge.minus")
                        }
                    }
                }
            }
            .padding(.bottom, 2)
            Color.clear.frame(height: 6)
        }
        .card(theme, radius: 18)
        .padding(.horizontal, 16)
    }

    // MARK: Медиа, файлы, музыка

    @ViewBuilder
    private var sharedSection: some View {
        let list = tabs
        if !list.isEmpty {
            VStack(spacing: 12) {
                ProfileTabs(titles: list.map(\.title), selection: $tab).padding(.horizontal, 16)
                let current = list[min(tab, list.count - 1)].id
                switch current {
                case "media": mediaGrid
                case "files": filesList
                case "music": musicList
                default: voiceList
                }
            }
        }
    }

    private var mediaGrid: some View {
        let items = media.compactMap(\.mediaItem)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Color.clear.aspectRatio(1, contentMode: .fit)
                    .overlay { RemoteImage(id: item.thumbID ?? item.id) }
                    .overlay {
                        if item.kind == .video {
                            Image(systemName: "play.fill").font(.system(size: 18)).foregroundStyle(.white).shadow(radius: 3)
                        }
                    }
                    .clipped()
                    .background(FrameProbe(box: frames.box(index)))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        var image: UIImage?
                        if let url = ServerConfig.mediaURL(item.thumbID ?? item.id) { image = ImageCache.shared.cached(url, maxPixel: 1280) }
                        HeroSource.shared.set(id: item.id, rect: frames.box(index).rect, image: image)
                        hideKeyboard()
                        viewer = InfoViewerItem(media: items, start: index, hero: HeroSource.shared.take())
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var filesList: some View {
        VStack(spacing: 0) {
            ForEach(Array(files.enumerated()), id: \.offset) { index, item in
                Button { open(item.file) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.fill").font(.system(size: 18)).foregroundStyle(.white)
                            .frame(width: 42, height: 42).background(theme.accentColor, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.file.name ?? s.fileLabel).font(.system(size: 15, weight: .medium))
                                .foregroundStyle(theme.text).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.file.size), countStyle: .file)
                                 + " · " + s.photoDateShort(item.message.createdAt))
                                .font(.system(size: 13)).foregroundStyle(theme.textTertiary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < files.count - 1 { Divider().overlay(theme.stroke).padding(.leading, 70) }
            }
        }
        .card(theme, radius: 18).padding(.horizontal, 16)
    }

    private var musicList: some View {
        let items = music
        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { onPlayMusic(item.track, items.map(\.track)); dismiss() } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            if let c = item.track.cover { RemoteImage(id: c) } else { theme.accentColor }
                            Image(systemName: "play.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        }
                        .frame(width: 46, height: 46).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.track.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                            Text([item.track.duration > 0 ? mmss(Int(item.track.duration)) : "", item.track.artist]
                                    .filter { !$0.isEmpty }.joined(separator: " • "))
                                .font(.system(size: 14)).foregroundStyle(theme.textSecondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { addToProfile(item) } label: { Label(s.t("Добавить в профиль", "Add to profile"), systemImage: "person.crop.circle.badge.plus") }
                }
                if index < items.count - 1 { Divider().overlay(theme.stroke).padding(.leading, 72) }
            }
        }
        .card(theme, radius: 18).padding(.horizontal, 16)
    }

    private var voiceList: some View {
        VStack(spacing: 0) {
            ForEach(Array(voices.enumerated()), id: \.offset) { index, item in
                HStack {
                    VoiceBlock(attachment: item.voice, mine: false)
                    Spacer()
                    Text(s.photoDateShort(item.message.createdAt)).font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                if index < voices.count - 1 { Divider().overlay(theme.stroke) }
            }
        }
        .card(theme, radius: 18).padding(.horizontal, 16)
    }

    // MARK: Действия

    private func loadProfile() async {
        guard !isGroup else { return }
        profile = try? await session.profileRepo.profile(id: model.peer.id)
        if !stageStarted, hasStagePhotos {                     // по умолчанию человек открывается в среднем положении
            stageStarted = true
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { stage = 1 }
        }
    }

    private func setBlocked(_ blocked: Bool) {
        Task {
            do {
                try await session.socialRepo.setBlocked(userID: model.peer.id, blocked: blocked)
                await loadProfile()
                await model.refresh()
                notice = blocked ? s.t("Пользователь заблокирован", "User blocked") : s.t("Пользователь разблокирован", "User unblocked")
            } catch { notice = s.api((error as? APIError) ?? .offline) }
        }
    }

    private func leave() {
        Task {
            do {
                try await session.messengerRepo.removeMember(groupID: model.peer.id, userID: session.serverID)
                await session.chats.refresh()
                onLeftGroup()
            } catch { notice = s.api((error as? APIError) ?? .offline) }
        }
    }

    private func toggleMute() {
        let next = !(group?.muted ?? false)
        Task {
            await model.setMuted(next)
            await session.chats.refresh()
            notice = next ? s.t("Уведомления выключены", "Muted") : s.t("Уведомления включены", "Unmuted")
        }
    }

    private func setRole(_ member: GroupMember, _ role: String) {
        Task {
            do {
                _ = try await session.messengerRepo.setRole(groupID: model.peer.id, userID: member.id, role: role)
                await model.refresh()
            } catch { notice = s.api((error as? APIError) ?? .offline) }
        }
    }

    private func remove(_ member: GroupMember) {
        Task {
            try? await session.messengerRepo.removeMember(groupID: model.peer.id, userID: member.id)
            await model.refresh()
        }
    }

    private func addToProfile(_ item: ChatMusicItem) {
        Task {
            do {
                _ = try await session.messengerRepo.addToProfile(messageID: item.messageID, mediaID: item.attachment.mediaID ?? "",
                                                                 title: item.track.title, artist: item.track.artist)
                await session.profile.load()
                notice = s.t("Добавлено в профиль", "Added to profile")
            } catch { notice = s.api((error as? APIError) ?? .offline) }
        }
    }

    private func open(_ file: ChatAttachment) {
        guard let id = file.mediaID else { return }
        Task {
            if let url = await FileDownloader.download(mediaID: id, name: file.name ?? "file") { previewFile = PreviewFile(url: url) }
        }
    }
}

// MARK: - Имя в контактах (как в Telegram)

struct ContactNameSheet: View {
    let peerID: String
    let currentName: String
    let isContact: Bool
    let onDone: () async -> Void

    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var name = ""
    @State private var busy = false
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isContact ? s.t("Имя в контактах", "Contact name") : s.t("Добавить в контакты", "Add to contacts"))
                .font(.system(size: 20, weight: .bold)).foregroundStyle(theme.text)
            Text(s.t("Это имя видите только вы — в переписках и списках.", "Only you see this name — in chats and lists."))
                .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
            TextField(s.t("Имя", "Name"), text: $name)
                .font(.system(size: 17)).padding(.horizontal, 14).frame(height: 48).card(theme, radius: 14)
            PrimaryButton(title: s.save, enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty, loading: busy) { save() }
            if isContact {
                Button(role: .destructive) { remove() } label: {
                    Text(s.t("Удалить из контактов", "Remove from contacts")).font(.system(size: 16))
                        .foregroundStyle(theme.danger).frame(maxWidth: .infinity)
                }
            }
        }
        .padding(20)
        .onAppear { name = currentName }
    }

    private func save() {
        busy = true
        Task {
            _ = try? await session.messengerRepo.saveContact(id: peerID, name: name)
            await onDone()
            busy = false
            dismiss()
        }
    }

    private func remove() {
        busy = true
        Task {
            try? await session.messengerRepo.deleteContact(id: peerID)
            await onDone()
            busy = false
            dismiss()
        }
    }
}

// MARK: - Выбор людей: контакты Orbita и поиск по @нику

struct PeoplePicker: View {
    @Binding var selected: [Contact]
    var exclude: Set<String> = []

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var contacts: [Contact] = []
    @State private var query = ""
    @State private var found: Contact?
    @State private var looking = false
    private var s: Strings { Strings(lang: lang) }

    private var filtered: [Contact] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "@", with: "")
        return contacts.filter { !exclude.contains($0.id.lowercased()) }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || ($0.username ?? "").lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.textTertiary)
                TextField(s.t("Контакты или @ник", "Contacts or @username"), text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit(lookup)
            }
            .font(.system(size: 16)).padding(.horizontal, 14).frame(height: 40).card(theme, radius: 14)

            if contacts.isEmpty && query.isEmpty {
                Text(s.t("Контактов пока нет. Найдите человека по @нику — или добавьте его в контакты из переписки.",
                         "No contacts yet. Find someone by @username, or add them from a chat."))
                    .font(.system(size: 14)).foregroundStyle(theme.textSecondary).padding(.vertical, 10)
            }

            ForEach(filtered) { row($0) }

            if filtered.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                if let found, !exclude.contains(found.id.lowercased()) {
                    row(found)
                } else {
                    Button(action: lookup) {
                        HStack {
                            if looking { ProgressView() } else { Image(systemName: "person.crop.circle.badge.questionmark") }
                            Text(s.t("Найти @\(query.replacingOccurrences(of: "@", with: ""))", "Find @\(query.replacingOccurrences(of: "@", with: ""))"))
                        }
                        .font(.system(size: 15)).foregroundStyle(theme.accentColor).padding(.vertical, 8)
                    }
                }
            }
        }
        .task {
            contacts = (try? await session.messengerRepo.contacts()) ?? []
        }
        .onChange(of: query) { _, _ in found = nil }
    }

    private func row(_ c: Contact) -> some View {
        let on = selected.contains { $0.id == c.id }
        return Button {
            if on { selected.removeAll { $0.id == c.id } } else { selected.append(c) }
        } label: {
            HStack(spacing: 12) {
                AvatarView(name: c.name, size: 40, avatarID: c.avatarID).clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name).font(.system(size: 16, weight: .medium)).foregroundStyle(theme.text)
                    if let u = c.username { Text("@" + u).font(.system(size: 13)).foregroundStyle(theme.textTertiary) }
                }
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(on ? theme.accentColor : theme.textTertiary)
            }
            .padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func lookup() {
        let name = query.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: "")
        guard !name.isEmpty, !looking else { return }
        looking = true
        Task {
            defer { looking = false }
            if let p = try? await session.profileRepo.lookup(username: name), p.id.lowercased() != session.serverID {
                found = Contact(id: p.id, name: p.name, realName: p.name, username: p.username, avatarID: p.avatarID)
            }
        }
    }
}

/// Позвать в Orbita тех, кого здесь ещё нет: системное окно «Поделиться» (сообщения, почта, мессенджеры)
struct InviteOutsidersLink: View {
    var groupCode: String? = nil
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    private var link: URL? {
        guard let base = ServerConfig.baseURL else { return nil }
        return URL(string: groupCode.map { base.absoluteString + "/g/" + $0 } ?? base.absoluteString)
    }

    var body: some View {
        if let link {
            ShareLink(item: link, message: Text(groupCode == nil
                        ? s.t("Присоединяйся ко мне в Orbita", "Join me on Orbita")
                        : s.t("Заходи в нашу группу в Orbita", "Join our group on Orbita"))) {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.up")
                    Text(s.t("Позвать тех, кого нет в Orbita", "Invite people who aren't on Orbita"))
                        .font(.system(size: 15, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(theme.accentColor)
                .padding(.horizontal, 14).frame(height: 48).card(theme, radius: 14)
            }
        }
    }
}

// MARK: - Пригласить в группу

struct GroupInviteSheet: View {
    let group: GroupInfo
    let onDone: () async -> Void

    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var selected: [Contact] = []
    @State private var busy = false
    @State private var errorText: String?
    private var s: Strings { Strings(lang: lang) }
    private var canInvite: Bool { group.isAdmin || (group.isOpen && !group.isChannel) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if canInvite {
                        PeoplePicker(selected: $selected, exclude: Set(group.members.map { $0.id.lowercased() }))
                    } else {
                        Text(s.t("Приглашать могут только администраторы. Но можно отправить ссылку.",
                                 "Only admins can invite here, but you can share the link."))
                            .font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                    }
                    InviteOutsidersLink(groupCode: group.linkRef)
                    if let errorText { Text(errorText).font(.system(size: 13)).foregroundStyle(theme.danger) }
                    if canInvite {
                        PrimaryButton(title: s.t("Пригласить", "Invite") + (selected.isEmpty ? "" : " (\(selected.count))"),
                                      enabled: !selected.isEmpty, loading: busy) { invite() }
                    }
                }
                .padding(16)
            }
            .navigationTitle(s.t("Пригласить", "Invite"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(s.close) { dismiss() } } }
        }
    }

    private func invite() {
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await session.messengerRepo.invite(groupID: group.id, userIDs: selected.map(\.id))
                await onDone()
                dismiss()
            } catch { errorText = s.api((error as? APIError) ?? .offline) }
        }
    }
}

enum MembersListKind: String, Identifiable {
    case admins, all
    var id: String { rawValue }
}

/// Список администраторов или всех участников / подписчиков; владельцу — смахнуть влево: админ, удалить
struct GroupMembersListSheet: View {
    let group: GroupInfo
    let adminsOnly: Bool
    let me: String
    var onOpen: (String) -> Void
    var onSetRole: (GroupMember, String) -> Void
    var onRemove: (GroupMember) -> Void
    var canRemove: (GroupMember) -> Bool

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var s: Strings { Strings(lang: lang) }

    private var list: [GroupMember] {
        let base = adminsOnly ? group.members.filter { $0.role == "owner" || $0.role == "admin" } : group.members
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? base : base.filter { $0.name.lowercased().contains(q) || ($0.username ?? "").lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(list) { m in
                    Button { if m.id.lowercased() != me { onOpen(m.id) } } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: m.name, size: 40, avatarID: m.avatarID).clipShape(Circle())
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.name).font(.system(size: 16, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                                if let u = m.username { Text("@" + u).font(.system(size: 13)).foregroundStyle(theme.textTertiary) }
                            }
                            Spacer()
                            if m.role != "member" {
                                Text(m.role == "owner" ? s.t("владелец", "owner") : s.t("админ", "admin"))
                                    .font(.system(size: 12)).foregroundStyle(theme.accentColor)
                            }
                        }
                    }
                    .listRowBackground(theme.surface)
                    .swipeActions(edge: .trailing) {
                        if canRemove(m) {
                            Button(role: .destructive) { onRemove(m) } label: { Label(s.t("Удалить", "Remove"), systemImage: "person.badge.minus") }
                        }
                        if group.isOwner, m.id.lowercased() != me, m.role != "owner" {
                            Button { onSetRole(m, m.role == "admin" ? "member" : "admin") } label: {
                                Label(m.role == "admin" ? s.t("Снять админа", "Remove admin") : s.t("Сделать админом", "Make admin"),
                                      systemImage: "person.badge.shield.checkmark")
                            }
                            .tint(theme.accentColor)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .searchable(text: $query, prompt: s.t("Поиск", "Search"))
            .navigationTitle(adminsOnly ? s.t("Администраторы", "Administrators")
                             : (group.isChannel ? s.t("Подписчики", "Subscribers") : s.t("Участники", "Members")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(s.close) { dismiss() } } }
        }
    }
}

/// QR-код ссылки на канал или группу
struct GroupQRSheet: View {
    let link: URL
    let title: String

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(theme.text).padding(.top, 24)
            QRCodeView(text: link.absoluteString)
                .frame(width: 210, height: 210)
                .padding(16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text(link.absoluteString).font(.system(size: 14)).foregroundStyle(theme.textSecondary).lineLimit(1).padding(.horizontal, 24)
            ShareLink(item: link) {
                Label(s.t("Поделиться", "Share"), systemImage: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 50).background(theme.accent, in: Capsule())
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
    }
}


/// «Общие чаты» в профиле человека — группы, где вы оба (как в Telegram и MAX). Нет общих — блока нет.
/// Нажатие открывает группу
struct CommonChatsCard: View {
    let userID: String

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss
    @State private var chats: [ChatPeer] = []

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        Group {
            if !chats.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(s.t("ОБЩИЕ ЧАТЫ", "GROUPS IN COMMON"))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textSecondary)
                        .padding(.leading, 16)
                    VStack(spacing: 0) {
                        ForEach(chats, id: \.id) { peer in
                            Button { open(peer) } label: {
                                HStack(spacing: 14) {
                                    AvatarView(name: peer.name, size: 48, avatarID: peer.avatarID).clipShape(Circle())
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(peer.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                                        Text("\(peer.memberCount) " + ChatInfoView.countWord(peer.memberCount, channel: false, lang: lang))
                                            .font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textTertiary)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if peer.id != chats.last?.id {
                                Rectangle().fill(theme.stroke).frame(height: 0.5).padding(.leading, 76)
                            }
                        }
                    }
                    .card(theme, radius: 18)
                }
                .padding(.horizontal, 16)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: chats.count)
        .task(id: userID) {
            guard userID.lowercased() != session.serverID else { return }
            chats = await session.extras.commonChats(userID: userID)
        }
    }

    private func open(_ peer: ChatPeer) {
        Haptics.impact(.light)
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { PushManager.shared.openChat = ChatRoute(peer: peer) }
    }
}
