import SwiftUI
import PhotosUI
import AVFoundation
import Combine

// MARK: - Хранилище историй (общее для ленты, шапки и «потянуть вниз»)

struct StoryOpen: Identifiable {
    let id = UUID()
    let group: Int
    var item: Int = -1          // -1 — с первой непросмотренной
}

@MainActor
final class StoryStore: ObservableObject {
    @Published var groups: [StoryGroup] = []
    @Published var open: StoryOpen?
    @Published var composing: PreparedMedia?
    @Published var preparing = false
    @Published var toast: String?
    var myID = ""

    var mine: StoryGroup? { groups.first { $0.user.id == myID } }
    /// Сначала те, чьи истории ещё не смотрели; просмотренные уходят в конец списка
    var others: [StoryGroup] {
        let list = groups.filter { $0.user.id != myID }
        return list.filter { !$0.allViewed } + list.filter { $0.allViewed }
    }
    /// Порядок в просмотрщике: моя, затем остальные
    var display: [StoryGroup] { (mine.map { [$0] } ?? []) + others }
    var hasTray: Bool { !groups.isEmpty }
    /// Первый человек с непросмотренными историями — его аватарка «вырастает» при протягивании
    var firstUnseen: Int? { display.firstIndex { $0.user.id != myID && !$0.allViewed } }

    func reload(_ extras: ExtrasAPI) async {
        if let g = await extras.stories() { groups = g }
    }

    func openFirstUnseen() -> Bool {
        guard let i = firstUnseen else { return false }
        open = StoryOpen(group: i)
        return true
    }

    func flash(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toast == text { toast = nil }
        }
    }
}

// MARK: - Кольцо вокруг аватарки

/// Непросмотренное — бегущая цветная линия, просмотренное — серое; на каждую историю свой сегмент
struct StoryRing: View {
    let viewed: [Bool]
    var size: CGFloat = 70
    var lineWidth: CGFloat = 3
    var animated = true
    var staticColor: Color? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        let n = min(max(1, viewed.count), 24)
        let gap = n > 1 ? 0.04 : 0.0
        let seg = 1.0 / Double(n)
        let spinning = animated && staticColor == nil && viewed.contains(false)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !spinning)) { ctx in
            let angle = spinning ? (ctx.date.timeIntervalSinceReferenceDate * 150).truncatingRemainder(dividingBy: 360) : 0
            ZStack {
                ForEach(0..<n, id: \.self) { i in
                    let seen = viewed.indices.contains(i) ? viewed[i] : true
                    Circle()
                        .trim(from: Double(i) * seg + gap / 2, to: Double(i + 1) * seg - gap / 2)
                        .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .foregroundStyle(style(seen: seen, angle: angle))
                        .rotationEffect(.degrees(-90))
                }
            }
        }
        .frame(width: size, height: size)
    }

    private func style(seen: Bool, angle: Double) -> AnyShapeStyle {
        if let staticColor { return AnyShapeStyle(staticColor) }
        if seen { return AnyShapeStyle(Color.gray.opacity(0.55)) }
        return AnyShapeStyle(AngularGradient(colors: [theme.accentColor, .pink, .orange, theme.accentColor],
                                             center: .center, angle: .degrees(angle)))
    }
}

// MARK: - Лента историй на главной

struct StoryTray: View {
    @ObservedObject var store: StoryStore
    var pull: CGFloat = 0           // насколько потянули вниз

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    private var s: Strings { Strings(lang: lang) }
    private var grow: CGFloat { 1 + min(max(pull, 0), 110) / 110 * 0.75 }

    var body: some View {
        if store.hasTray {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    myBubble
                    ForEach(Array(store.others.enumerated()), id: \.element.id) { index, g in
                        bubble(g, scale: index == 0 ? grow : 1) {
                            if let i = store.display.firstIndex(where: { $0.id == g.id }) { store.open = StoryOpen(group: i) }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.others.map(\.id))
        }
    }

    private var myBubble: some View {
        let group = store.mine
        return ZStack(alignment: .bottomTrailing) {
            Button {
                if let i = store.display.firstIndex(where: { $0.user.id == store.myID }) { store.open = StoryOpen(group: i, item: 0) }
            } label: {
                VStack(spacing: 5) {
                    ZStack {
                        if let group {
                            StoryRing(viewed: group.items.map { _ in false }, size: 70, staticColor: theme.accentColor)
                        }
                        AvatarView(name: session.profile.profile?.name ?? "", size: 58, avatarID: session.profile.profile?.avatarID)
                            .clipShape(Circle())
                    }
                    .frame(width: 70, height: 70)
                    Text(s.t("Моя история", "My story")).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        .lineLimit(1).frame(width: 74)
                }
            }
            .buttonStyle(.plain)
            .disabled(group == nil)

            StoryAddPicker(store: store) {
                Image(systemName: store.preparing ? "hourglass" : "plus")
                    .font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(theme.accent, in: Circle())
                    .overlay(Circle().stroke(theme.sheet, lineWidth: 2))
            }
            .offset(x: 0, y: -22)
        }
    }

    private func bubble(_ g: StoryGroup, scale: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    StoryRing(viewed: g.items.map(\.viewed), size: 70)
                    AvatarView(name: g.user.name, size: 58, avatarID: g.user.avatar).clipShape(Circle())
                }
                .frame(width: 70, height: 70)
                .scaleEffect(scale, anchor: .top)
                .shadow(color: theme.accentColor.opacity(scale > 1.05 ? 0.35 : 0), radius: 14)
                Text(g.user.name).font(.system(size: 12))
                    .foregroundStyle(g.allViewed ? theme.textTertiary : theme.textSecondary)
                    .lineLimit(1).frame(width: 74)
                    .padding(.top, (scale - 1) * 52)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Выбор фото/видео для истории

struct StoryAddPicker<Label: View>: View {
    @ObservedObject var store: StoryStore
    @ViewBuilder var label: () -> Label

    @Environment(\.lang) private var lang
    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .any(of: [.images, .videos])) { label() }
            .onChange(of: item) { _, picked in
                guard let picked else { return }
                store.preparing = true
                let s = Strings(lang: lang)
                Task {
                    do {
                        store.composing = try await MediaPreparer.prepare(picked)
                    } catch MediaError.tooLong {
                        store.flash(s.t("Видео слишком длинное", "The video is too long"))
                    } catch MediaError.tooLarge {
                        store.flash(s.t("Видео слишком большое", "The video is too large"))
                    } catch {
                        store.flash(s.t("Не удалось подготовить файл. Попробуйте другое фото или видео.",
                                        "Couldn't prepare the file. Try another photo or video."))
                    }
                    store.preparing = false
                    item = nil
                }
            }
    }
}

/// Окна историй: публикация и просмотр — подключаются одним модификатором
struct StoryPresenters: ViewModifier {
    @ObservedObject var store: StoryStore
    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast = store.toast { ToastView(text: toast).padding(.top, 62).transition(.opacity) }
            }
            .animation(.easeOut(duration: 0.2), value: store.toast)
            .sheet(item: $store.composing) { media in
                StoryComposeSheet(media: media) {
                    store.composing = nil
                    Task { await store.reload(session.extras) }
                }
                .environmentObject(session)
                .environment(\.theme, theme).environment(\.lang, lang)
                .presentationBackground(theme.sheet)
            }
            .fullScreenCover(item: $store.open, onDismiss: {
                Task { await store.reload(session.extras) }
            }) { o in
                StoryViewerScreen(groups: store.display, startGroup: o.group, startIndex: o.item)
                    .environmentObject(session)
                    .environment(\.theme, theme).environment(\.lang, lang)
            }
    }
}

// MARK: - Публикация

struct StoryComposeSheet: View {
    let media: PreparedMedia
    let onDone: () -> Void
    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var caption = ""
    @State private var busy = false
    @State private var failed = false
    @State private var errorText = ""
    @State private var forever = false

    var body: some View {
        let s = Strings(lang: lang)
        VStack(spacing: 14) {
            Text(s.t("Новая история", "New story")).font(.system(size: 20, weight: .bold)).foregroundStyle(theme.text)
                .padding(.top, 20)
            if let image = UIImage(data: media.thumbnail) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 180, height: 300).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            TextField(s.t("Подпись", "Caption"), text: $caption)
                .padding(.horizontal, 14).frame(height: 44).card(theme, radius: 14).padding(.horizontal, 20)
            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: $forever) {
                    Label(s.t("Оставить навсегда", "Keep forever"), systemImage: "infinity")
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(theme.text)
                }
                .tint(theme.accentColor)
                Text(s.t("Такие истории видны в вашем профиле. Не больше 50 на аккаунт.",
                         "These stories stay on your profile. Up to 50 per account."))
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10).card(theme, radius: 14).padding(.horizontal, 20)
            if failed {
                Text(errorText).font(.system(size: 13)).foregroundStyle(theme.danger)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }
            Button {
                busy = true; failed = false
                Task {
                    do { try await session.extras.publishStory(media, caption: caption, forever: forever); onDone() }
                    catch {
                        errorText = s.api((error as? APIError) ?? .offline)
                        failed = true; busy = false
                    }
                }
            } label: {
                Group { if busy { ProgressView().tint(.white) } else {
                    Text(forever ? s.t("Опубликовать навсегда", "Publish forever") : s.t("Опубликовать на 24 часа", "Publish for 24 hours")) } }
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(theme.accent, in: Capsule())
            }
            .buttonStyle(PressStyle()).disabled(busy).padding(.horizontal, 20)
            Spacer()
        }
    }
}

// MARK: - Просмотр

struct StoryViewerScreen: View {
    @State var groups: [StoryGroup]
    @State var gi: Int
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lang) private var lang
    @Environment(\.theme) private var theme

    @State private var ii = 0
    @State private var progress: Double = 0
    @State private var pressed = false
    @State private var pressStart: Date?
    @State private var player: AVPlayer?
    @State private var reply = ""
    @State private var toast: String?
    @State private var showViewers = false
    @State private var confirmDelete = false
    @State private var profileID: String?
    @State private var dragY: CGFloat = 0
    @State private var dragX: CGFloat = 0
    @State private var burst = 0
    @State private var bigHeart = false
    @FocusState private var typing: Bool

    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    init(groups: [StoryGroup], startGroup: Int, startIndex: Int = -1) {
        _groups = State(initialValue: groups)
        _gi = State(initialValue: startGroup)
        let items = groups.indices.contains(startGroup) ? groups[startGroup].items : []
        let first = startIndex >= 0 ? startIndex : (items.firstIndex { !$0.viewed } ?? 0)
        _ii = State(initialValue: min(first, max(0, items.count - 1)))
    }

    private var group: StoryGroup? { groups.indices.contains(gi) ? groups[gi] : nil }
    private var item: StoryItem? {
        guard let g = group, g.items.indices.contains(ii) else { return nil }
        return g.items[ii]
    }
    private var isMine: Bool { group?.user.id == session.serverID }
    private var paused: Bool { pressed || typing || showViewers || confirmDelete || profileID != nil }

    var body: some View {
        let s = Strings(lang: lang)
        ZStack {
            Color.black.ignoresSafeArea()
            if let item {
                // видео держим в одном и том же слое с одним плеером: пересоздание слоя с анимацией давало чёрный кадр при звуке
                media(item).ignoresSafeArea()
                    .id(item.isVideo ? "video" : item.id)
                    .transition(item.isVideo ? .identity : .opacity)
            }
            LinearGradient(colors: [.black.opacity(0.5), .clear, .clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)

            // зоны нажатия: тап — следующая/предыдущая, удержание — пауза, свайп в стороны — другой человек, вниз — закрыть
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if pressStart == nil { pressStart = Date() }
                        pressed = true
                        if abs(v.translation.height) > abs(v.translation.width) {
                            dragY = max(0, v.translation.height)
                        } else {
                            dragX = v.translation.width / 3
                        }
                    }
                    .onEnded { v in
                        let held = Date().timeIntervalSince(pressStart ?? Date())
                        pressed = false; pressStart = nil
                        let w = v.translation.width, h = v.translation.height
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragX = 0; dragY = 0 }
                        if h > 120 && abs(h) > abs(w) { dismiss(); return }
                        if abs(w) > 60 && abs(w) > abs(h) {
                            w < 0 ? nextGroup() : previousGroup()
                            return
                        }
                        if held < 0.25, abs(w) < 12, abs(h) < 12 {
                            if typing { typing = false; return }
                            v.location.x < UIScreen.main.bounds.width / 3 ? previous() : next()
                        }
                    })

            VStack(spacing: 8) {
                if let g = group {
                    HStack(spacing: 4) {
                        ForEach(g.items.indices, id: \.self) { i in
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.3))
                                    Capsule().fill(.white).frame(width: geo.size.width * (i < ii ? 1 : (i == ii ? progress : 0)))
                                }
                            }
                            .frame(height: 3)
                        }
                    }
                    .padding(.horizontal, 10)
                    HStack(spacing: 10) {
                        Button { profileID = g.user.id } label: {
                            HStack(spacing: 10) {
                                AvatarView(name: g.user.name, size: 38, avatarID: g.user.avatar).clipShape(Circle())
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(g.user.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                    if g.suggested == true {
                                        Text(s.t("Рекомендуем", "Suggested")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if isMine, let item, item.permanent != true {
                            glassButton("infinity") { keepForever() }
                        }
                        if isMine { glassButton("trash") { confirmDelete = true } }
                        glassButton("xmark") { dismiss() }
                    }
                    .padding(.horizontal, 12)
                }
                Spacer()
                if let item, !item.caption.isEmpty {
                    LinkText(text: item.caption, tint: .white).font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                        .shadow(radius: 4)
                }
                if let item {
                    Text(ago(item.createdAt, s))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12).frame(height: 26)
                        .glassCapsule()
                }
                bottomBar(s)
            }
            .padding(.top, 8)

            if bigHeart {
                Image(systemName: "heart.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.5), .red], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .red.opacity(0.5), radius: 20)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
            if let toast {
                Text(toast).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 36).glassCapsule()
            }
        }
        .offset(x: dragX, y: dragY)
        .scaleEffect(1 - min(dragY, 300) / 1500)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear { startItem() }
        .onDisappear { player?.pause(); player = nil }
        .onReceive(tick) { _ in advance() }
        .profileSheet(id: $profileID)
        .confirmationDialog(s.t("Удалить историю?", "Delete story?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(s.t("Удалить", "Delete"), role: .destructive) { deleteCurrent() }
            Button(s.cancel, role: .cancel) {}
        }
        .sheet(isPresented: $showViewers) {
            if let item { StoryViewersSheet(storyID: item.id).environmentObject(session).environment(\.theme, theme).environment(\.lang, lang) }
        }
    }

    private func glassButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 38, height: 38).glassCircle()
        }
        .buttonStyle(.plain)
    }

    // MARK: Содержимое

    @ViewBuilder
    private func media(_ item: StoryItem) -> some View {
        if item.isVideo, let player {
            PlayerLayerView(player: player)
        } else if item.isVideo {
            Color.black
        } else {
            RemoteImage(id: item.mediaId, fill: false)
        }
    }

    @ViewBuilder
    private func bottomBar(_ s: Strings) -> some View {
        if isMine {
            Button { showViewers = true } label: {
                HStack(spacing: 14) {
                    Label("\(item?.views ?? 0)", systemImage: "eye.fill")
                    Label("\(item?.likes ?? 0)", systemImage: "heart.fill")
                        .foregroundStyle(Color(red: 1, green: 0.4, blue: 0.5))
                }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 18).frame(height: 44).glassCapsule(interactive: true)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)
        } else {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    TextField(s.t("Ответить…", "Reply…"), text: $reply)
                        .focused($typing).submitLabel(.send).onSubmit(sendReply)
                        .foregroundStyle(.white).tint(.white)
                    if !reply.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button(action: sendReply) {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 28)).foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.leading, 16).padding(.trailing, 8).frame(height: 46)
                .glassCapsule()
                likeButton
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: reply.isEmpty)
            .padding(.horizontal, 14).padding(.bottom, 14)
        }
    }

    private var likeButton: some View {
        let liked = item?.liked ?? false
        let count = item?.likes ?? 0
        return Button(action: toggleLike) {
            HStack(spacing: 6) {
                StoryHeart(liked: liked, burst: burst, size: 22)
                if count > 0 {
                    Text("\(count)").font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 14).frame(height: 46)
            .glassCapsule(interactive: true)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: count)
        }
        .buttonStyle(.plain)
    }

    // MARK: Логика

    private func startItem() {
        progress = 0
        guard let item, let g = group else { player?.pause(); return }
        if g.user.id != session.serverID && !item.viewed {
            groups[gi].items[ii].viewed = true
            groups[gi].allViewed = groups[gi].items.allSatisfy(\.viewed)
            Task { await session.extras.markViewed(storyID: item.id) }
        }
        if item.isVideo, let url = ServerConfig.mediaURL(item.mediaId) {
            let p = player ?? AVPlayer()
            p.pause()
            p.replaceCurrentItem(with: AVPlayerItem(url: url))
            p.seek(to: .zero)
            p.play()
            if player == nil { player = p }
        } else {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
        }
    }

    private func advance() {
        guard !paused, item != nil else { player?.pause(); return }
        if let item, item.isVideo, let p = player {
            p.play()
            let d = p.currentItem?.duration.seconds ?? 0
            if d.isFinite, d > 0 { progress = min(1, p.currentTime().seconds / d) }
            if progress >= 0.995 { next() }
            return
        }
        progress += 0.05 / 5.0
        if progress >= 1 { next() }
    }

    private func firstUnseen(_ index: Int) -> Int {
        guard groups.indices.contains(index) else { return 0 }
        return groups[index].items.firstIndex { !$0.viewed } ?? 0
    }

    private func next() {
        guard let g = group else { dismiss(); return }
        if ii + 1 < g.items.count { withAnimation(.easeInOut(duration: 0.18)) { ii += 1 }; startItem() }
        else { nextGroup() }
    }

    private func nextGroup() {
        if gi + 1 < groups.count {
            Haptics.impact(.light)
            withAnimation(.easeInOut(duration: 0.22)) { gi += 1; ii = firstUnseen(gi) }
            startItem()
        } else { dismiss() }
    }

    private func previous() {
        if ii > 0 { withAnimation(.easeInOut(duration: 0.18)) { ii -= 1 }; startItem() }
        else { previousGroup() }
    }

    private func previousGroup() {
        if gi > 0 {
            Haptics.impact(.light)
            withAnimation(.easeInOut(duration: 0.22)) { gi -= 1; ii = 0 }
        }
        startItem()
    }

    private func say(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if toast == text { toast = nil }
        }
    }

    private func sendReply() {
        let text = reply.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let g = group, let item else { return }
        reply = ""; typing = false
        let s = Strings(lang: lang)
        Task {
            do {
                try await session.extras.replyToStory(peerID: g.user.id, storyID: item.id, text: text)
                Haptics.notify(.success)
                say(s.t("Отправлено", "Sent"))
            } catch {
                say(s.api((error as? APIError) ?? .offline))
            }
        }
    }

    private func toggleLike() {
        guard let item, groups.indices.contains(gi) else { return }
        let was = item.liked ?? false
        let now = !was
        let gIndex = gi, iIndex = ii, id = item.id
        groups[gIndex].items[iIndex].liked = now
        groups[gIndex].items[iIndex].likes = max(0, (item.likes ?? 0) + (now ? 1 : -1))
        if now {
            burst += 1
            Haptics.impact(.medium)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { bigHeart = true }
            Task {
                try? await Task.sleep(nanoseconds: 650_000_000)
                withAnimation(.easeOut(duration: 0.25)) { bigHeart = false }
            }
        } else {
            Haptics.select()
        }
        Task {
            do {
                let fresh = try await session.extras.likeStory(id: id, liked: now)
                if groups.indices.contains(gIndex), groups[gIndex].items.indices.contains(iIndex),
                   groups[gIndex].items[iIndex].id == id {
                    groups[gIndex].items[iIndex].likes = fresh.likes
                    groups[gIndex].items[iIndex].liked = fresh.liked
                }
            } catch {
                if groups.indices.contains(gIndex), groups[gIndex].items.indices.contains(iIndex) {
                    groups[gIndex].items[iIndex].liked = was
                    groups[gIndex].items[iIndex].likes = item.likes
                }
                say(Strings(lang: lang).api((error as? APIError) ?? .offline))
            }
        }
    }

    private func keepForever() {
        guard let item else { return }
        Task {
            do {
                try await session.extras.makeForever(storyID: item.id)
                groups[gi].items[ii].permanent = true
                Haptics.notify(.success)
                say(Strings(lang: lang).t("Останется в профиле", "Kept on your profile"))
            } catch {
                say(Strings(lang: lang).api((error as? APIError) ?? .offline))
            }
        }
    }

    private func deleteCurrent() {
        guard let item else { return }
        Task { await session.extras.deleteStory(id: item.id) }
        groups[gi].items.remove(at: ii)
        if groups[gi].items.isEmpty { dismiss(); return }
        if ii >= groups[gi].items.count { ii = groups[gi].items.count - 1 }
        startItem()
    }

    /// «5 мин назад», «3 ч назад», а у старых историй из профиля — дата
    private func ago(_ t: Double, _ s: Strings) -> String {
        let secs = Int(Date().timeIntervalSince1970 - t)
        let m = secs / 60
        if m < 1 { return s.t("только что", "just now") }
        if m < 60 { return s.t("\(m) мин назад", "\(m) min ago") }
        if m < 60 * 24 { return s.t("\(m / 60) ч назад", "\(m / 60) h ago") }
        return FormatterCache.format(Date(timeIntervalSince1970: t), "d MMM yyyy",
                                     locale: Locale(identifier: lang == .ru ? "ru_RU" : "en_US"))
    }
}

// MARK: - Сердечко как в TikTok

/// Гладкое сердце: при лайке «выпрыгивает» и разлетается маленькими сердечками
struct StoryHeart: View {
    let liked: Bool
    let burst: Int
    var size: CGFloat = 22
    var solidWhenIdle = false           // в шортсах не лайкнутое сердце — залитое белое, как в TikTok

    private let pink = Color(red: 1, green: 0.32, blue: 0.5)

    var body: some View {
        ZStack {
            heartIcon
                .shadow(color: liked ? .red.opacity(0.5) : .clear, radius: 6)
                .keyframeAnimator(initialValue: 1.0, trigger: burst) { content, k in
                    content.scaleEffect(k)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(0.7, duration: 0.08)
                        SpringKeyframe(1.35, duration: 0.2, spring: .bouncy)
                        SpringKeyframe(1.0, duration: 0.3, spring: .smooth)
                    }
                }
            particles
        }
        .animation(.easeOut(duration: 0.15), value: liked)
        .frame(width: size + 4, height: size + 4)
    }

    /// В шортсах — широкое округлое сердце, как в TikTok; в остальных местах — системное
    @ViewBuilder
    private var heartIcon: some View {
        if solidWhenIdle {
            ReelHeartShape()
                .fill(liked ? AnyShapeStyle(LinearGradient(colors: [pink, .red], startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(Color(white: 0.93)))
                .overlay(ReelHeartShape().stroke(liked ? Color.red : Color(white: 0.93), style: StrokeStyle(lineWidth: 2, lineJoin: .round)))
                .frame(width: size * 0.8, height: size * 0.72)
        } else {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(liked
                                 ? AnyShapeStyle(LinearGradient(colors: [pink, .red], startPoint: .top, endPoint: .bottom))
                                 : AnyShapeStyle(Color.white))
        }
    }

    private var particles: some View {
        ZStack {
            ForEach(0..<7, id: \.self) { i in
                let angle = Double(i) / 7.0 * 2 * .pi
                Image(systemName: "heart.fill")
                    .font(.system(size: size * 0.32))
                    .foregroundStyle(i % 2 == 0 ? pink : Color.orange)
                    .modifier(BurstOffset(dx: cos(angle), dy: sin(angle), distance: size * 1.1, trigger: burst))
            }
        }
        .allowsHitTesting(false)
    }
}

private struct BurstOffset: ViewModifier {
    let dx: Double
    let dy: Double
    let distance: CGFloat
    let trigger: Int

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, p in
            view
                .offset(x: CGFloat(dx) * distance * CGFloat(p), y: CGFloat(dy) * distance * CGFloat(p))
                .scaleEffect(0.5 + 0.5 * (1 - p))
                .opacity(p <= 0.001 || p >= 0.999 ? 0 : 1 - p)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(1.0, duration: 0.55)
            }
        }
    }
}

// MARK: - Кто смотрел

/// Сверху — те, кто поставил сердечко (как в Telegram), дальше остальные зрители
struct StoryViewersSheet: View {
    let storyID: String
    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var viewers: [StoryViewer] = []
    @State private var likes = 0
    @State private var loaded = false

    var body: some View {
        let s = Strings(lang: lang)
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(s.t("Просмотры", "Views")).font(.system(size: 18, weight: .bold)).foregroundStyle(theme.text)
                Spacer()
                Label("\(viewers.count)", systemImage: "eye.fill").foregroundStyle(theme.textSecondary)
                Label("\(likes)", systemImage: "heart.fill").foregroundStyle(Color(red: 1, green: 0.35, blue: 0.5))
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 10)
            if loaded && viewers.isEmpty {
                Text(s.t("Пока никто не смотрел", "No views yet")).foregroundStyle(theme.textSecondary).padding(.top, 30)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewers) { v in
                        HStack(spacing: 12) {
                            AvatarView(name: v.name, size: 42, avatarID: v.avatar).clipShape(Circle())
                            VStack(alignment: .leading, spacing: 1) {
                                Text(v.name).font(.system(size: 16, weight: .medium)).foregroundStyle(theme.text)
                                if let u = v.username { Text("@" + u).font(.system(size: 13)).foregroundStyle(theme.textSecondary) }
                            }
                            Spacer()
                            if v.liked == true {
                                Image(systemName: "heart.fill")
                                    .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.5), .red],
                                                                    startPoint: .top, endPoint: .bottom))
                            }
                            Text(ChatTime.clock(Date(timeIntervalSince1970: v.at)))
                                .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                        }
                        .padding(.horizontal, 20).padding(.vertical, 8)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.ultraThinMaterial)
        .task {
            let result = await session.extras.viewersWithLikes(storyID: storyID)
            viewers = result.viewers
            likes = result.likes
            loaded = true
        }
    }
}

// MARK: - Истории «навсегда» в профиле

struct PermanentStoriesStrip: View {
    let userID: String
    let name: String
    let avatarID: String?

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var items: [StoryItem] = []
    @State private var open: StoryStart?

    private struct StoryStart: Identifiable { let id = UUID(); let index: Int }

    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Strings(lang: lang).t("Истории", "Stories").uppercased())
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                        .padding(.leading, 20)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                Button { open = StoryStart(index: index) } label: {
                                    ZStack {
                                        if item.isVideo {
                                            Color.black.opacity(0.85)
                                            Image(systemName: "play.fill").foregroundStyle(.white.opacity(0.9))
                                        } else {
                                            RemoteImage(id: item.mediaId)
                                        }
                                    }
                                    .frame(width: 64, height: 92)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(theme.accentColor, lineWidth: 2))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
        .task(id: userID) { items = await session.extras.profileStories(userID: userID) }
        .fullScreenCover(item: $open, onDismiss: {
            Task { items = await session.extras.profileStories(userID: userID) }
        }) { start in
            StoryViewerScreen(groups: [StoryGroup(user: StoryUser(id: userID, name: name, username: nil, avatar: avatarID),
                                                  items: items, allViewed: true)], startGroup: 0, startIndex: start.index)
                .environmentObject(session)
                .environment(\.theme, theme).environment(\.lang, lang)
        }
    }
}



/// Широкое сердце с мягкими боками и слегка скруглённым низом
struct ReelHeartShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.minY + y * h) }
        var p = Path()
        p.move(to: pt(0.5, 0.92))
        p.addCurve(to: pt(0.03, 0.38), control1: pt(0.28, 0.78), control2: pt(0.03, 0.60))
        p.addCurve(to: pt(0.26, 0.06), control1: pt(0.03, 0.18), control2: pt(0.12, 0.06))
        p.addCurve(to: pt(0.5, 0.22), control1: pt(0.38, 0.06), control2: pt(0.46, 0.13))
        p.addCurve(to: pt(0.74, 0.06), control1: pt(0.54, 0.13), control2: pt(0.62, 0.06))
        p.addCurve(to: pt(0.97, 0.38), control1: pt(0.88, 0.06), control2: pt(0.97, 0.18))
        p.addCurve(to: pt(0.5, 0.92), control1: pt(0.97, 0.60), control2: pt(0.72, 0.78))
        p.closeSubpath()
        return p
    }
}
