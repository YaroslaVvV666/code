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
                    if isGroup, let group, !group.members.isEmpty { membersCard(group) }
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
            if isGroup, group?.isAdmin == true {
                Button { showEdit = true } label: { pillLabel(s.t("Изм.", "Edit")) }.buttonStyle(.plain)
            } else if !isGroup {
                Button { showContact = true } label: { pillLabel(s.t("Изм.", "Edit")) }.buttonStyle(.plain)
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
            let open = group?.isOpen ?? (model.peer.kind == "open")
            let kind = channel ? (open ? s.t("Публичный канал", "Public channel") : s.t("Закрытый канал", "Private channel"))
                               : (open ? s.t("Открытая группа", "Open group") : s.t("Закрытая группа", "Private group"))
            return "\(kind) · \(count) \(s.memberWord(channel: channel))"
        }
        return s.lastSeenText(model.lastSeen)
    }

    // MARK: Кнопки

    private var actionRow: some View {
        HStack(spacing: 10) {
            if isGroup {
                if let g = group, g.isAdmin || (g.isOpen && !g.isChannel) {
                    tile("person.badge.plus", s.t("Пригласить", "Invite")) { showInvite = true }
                }
                if let link = groupLink {
                    ShareLink(item: link, message: Text(s.t("Заходи в Orbita", "Join on Orbita"))) {
                        tileLabel("link", s.t("Ссылка", "Link"))
                    }
                    .buttonStyle(PressStyle())
                }
                tile(group?.muted == true ? "bell.slash.fill" : "bell.fill",
                     group?.muted == true ? s.t("Включить", "Unmute") : s.t("Без звука", "Mute")) { toggleMute() }
                tile("rectangle.portrait.and.arrow.right",
                     (group?.isChannel ?? model.peer.isChannel) ? s.t("Отписаться", "Unfollow") : s.t("Выйти", "Leave"),
                     danger: true) { confirmLeave = true }
            } else {
                tile("phone.fill", s.t("Звонок", "Call")) { callPeer(video: false) }
                tile("video.fill", s.t("Видео", "Video")) { callPeer(video: true) }
                tile("person.crop.circle", s.t("Профиль", "Profile")) { showProfile = true }
                tile("bell.fill", s.t("Звук", "Sound")) { notice = s.t("Звук личных чатов настраивается в профиле", "Set sound in the profile") }
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
                dmRow(profile?.blockedByMe == true ? "hand.raised.slash" : "hand.raised.fill",
                      profile?.blockedByMe == true ? s.unblockUser : s.blockUser, danger: profile?.blockedByMe != true) {
                    if profile?.blockedByMe == true { setBlocked(false) } else { confirmBlock = true }
                }
            }
            .padding(.horizontal, 16)
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
        let rows = infoRows
        if !rows.isEmpty { ProfileInfoCard(rows: rows).padding(.horizontal, 16) }
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
