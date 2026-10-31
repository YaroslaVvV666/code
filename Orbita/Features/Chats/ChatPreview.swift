import SwiftUI

/// Предпросмотр переписки без «прочитано»: последние сообщения + лоскуток «Новые сообщения».
/// Используется и в баннере нового сообщения, и в меню по зажатию чата в списке.
struct ChatPreviewBody: View {
    let peer: ChatPeer
    let repo: MessengerRepository
    var limit = 14
    var maxHeight: CGFloat? = nil
    var onThread: ((ChatThread) -> Void)? = nil

    @Environment(\.theme) private var baseTheme
    @ObservedObject private var appearance = ChatAppearanceStore.shared
    private var theme: Theme { appearance.theme(baseTheme, for: peer.id) }
    @Environment(\.lang) private var lang
    @State private var messages: [ChatMessage] = []
    @State private var firstUnread: String?
    @State private var loading = true
    // Предпросмотр не проигрывает звук, но пузырь с аудио требует AudioPlayer в окружении.
    // Даём собственный «пустой» плеер, чтобы превью работало и в баннере, и в списке — без краша.
    @StateObject private var previewPlayer = AudioPlayer()

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 4) {
                    if loading { ProgressView().padding(.vertical, 30) }
                    if !loading && messages.isEmpty {
                        Text(s.chatStart).font(.system(size: 14)).foregroundStyle(theme.textTertiary).padding(.vertical, 30)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.key) { index, m in
                        if m.id == firstUnread {
                            Text(s.t("Новые сообщения", "New messages"))
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accentColor)
                                .frame(maxWidth: .infinity).padding(.vertical, 5)
                                .background(theme.accentColor.opacity(0.14))
                                .padding(.horizontal, -12).padding(.vertical, 4)
                                .id("strip")
                        }
                        bubble(m, index: index).id(m.key)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(maxHeight: maxHeight)
            .onChange(of: messages.count) { _, _ in jump(proxy) }
        }
        .background {
            // свои обои чата — и в предпросмотре
            if appearance.appearance(peer.id).wallpaper != "default" { ChatWallpaperView(chatID: peer.id) }
        }
        .environment(\.theme, theme)
        .environmentObject(previewPlayer)
        .task(id: peer.id) {
            let thread = try? await repo.thread(peerID: peer.id, limit: limit, peek: true)
            firstUnread = thread?.firstUnread
            if let thread { onThread?(thread) }
            messages = thread?.messages ?? []
            loading = false
        }
    }

    /// Сразу (без анимации) ставим карточку на ПЕРВОЕ непрочитанное — не на последнее и не внизу.
    /// Пара повторов с задержкой — чтобы точно сработало после первой компоновки списка.
    private func jump(_ proxy: ScrollViewProxy) {
        guard !messages.isEmpty else { return }
        let hasStrip = firstUnread != nil && messages.contains { $0.id == firstUnread }
        let target: String
        let anchor: UnitPoint
        if hasStrip { target = "strip"; anchor = .top }
        else if firstUnread != nil, let top = messages.first?.key { target = top; anchor = .top }   // непрочитанных больше, чем в окне — показываем с самого верха
        else if let last = messages.last { target = last.key; anchor = .bottom }                    // непрочитанного нет — вниз
        else { return }
        proxy.scrollTo(target, anchor: anchor)
        for delay in [0.05, 0.16] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo(target, anchor: anchor) }
        }
    }

    /// Настоящий пузырь из переписки (без нажатий): видно фото, кружки, стикеры и крупные анимированные эмодзи,
    /// а не надписи «Фото», «Видеосообщение»
    private func bubble(_ m: ChatMessage, index: Int) -> some View {
        let prev = index > 0 ? messages[index - 1] : nil
        let next = index + 1 < messages.count ? messages[index + 1] : nil
        let isFirst = prev.map { $0.mine != m.mine || $0.sender?.id != m.sender?.id } ?? true
        let isLast = next.map { $0.mine != m.mine || $0.sender?.id != m.sender?.id } ?? true
        return MessageRow(message: m, isFirst: isFirst, isLast: isLast,
                          onReply: {}, onEdit: {}, onDelete: {}, onOpenMedia: { _, _ in }, onOpenFile: { _ in },
                          showSender: peer.isGroup && !peer.isChannel, noForward: peer.noForward, interactive: false)
            .allowsHitTesting(false)
    }
}

/// Зажатие чата в списке: карточка с живой (листаемой) перепиской и меню действий — как в Telegram.
/// Переписка загружается в режиме «peek»: сообщения не помечаются прочитанными.
struct ChatPeekOverlay: View {
    let chat: ChatSummary
    let repo: MessengerRepository
    let pinned: Bool
    let muted: Bool
    let markedUnread: Bool
    let onOpen: () -> Void
    let onPin: () -> Void
    let onMute: () -> Void
    let onMark: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var shown = false
    @State private var thread: ChatThread?

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(theme.dark ? 0.45 : 0.25))
                    .ignoresSafeArea()
                    .onTapGesture { dismiss(onClose) }

                VStack(spacing: 12) {
                    card
                        .frame(height: min(geo.size.height * 0.52, 460))
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                    actions
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: 420)
                .scaleEffect(shown ? 1 : 0.92, anchor: .center)
                .opacity(shown ? 1 : 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { shown = true } }
    }

    private func dismiss(_ then: @escaping () -> Void) {
        withAnimation(.easeOut(duration: 0.16)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { then() }
    }

    // MARK: Карточка с перепиской

    private var card: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text(chat.peer.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(theme.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10).padding(.horizontal, 14)
            .background(theme.sheet)

            if let pin = thread?.pinned.last {
                HStack(spacing: 8) {
                    Capsule().fill(theme.accentColor).frame(width: 2.5, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.t("Закреплённое сообщение", "Pinned message")).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accentColor)
                        Text(pin.summary).font(.system(size: 13)).foregroundStyle(theme.text).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "pin.fill").font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(theme.sheet)
            }
            Divider().opacity(0.4)
            ChatPreviewBody(peer: chat.peer, repo: repo, limit: 40, onThread: { thread = $0 })
                .frame(maxHeight: .infinity)
                .background(theme.dark ? Color.black.opacity(0.25) : Color.black.opacity(0.03))
        }
        .background(theme.sheet)
    }

    private var subtitle: String {
        if chat.peer.isGroup {
            if let g = thread?.group { return "\(g.members.count) " + s.memberWord(channel: chat.peer.isChannel) }
            return chat.peer.isChannel ? s.t("Канал", "Channel") : s.t("Группа", "Group")
        }
        if let seen = thread?.lastSeen { return s.lastSeenText(seen) }
        return thread == nil ? "" : s.lastSeenRecently
    }

    // MARK: Меню

    private var actions: some View {
        VStack(spacing: 0) {
            row("arrow.up.right.square", s.t("Открыть", "Open")) { dismiss(onOpen) }
            sep
            if chat.unread == 0 {
                row(markedUnread ? "checkmark.bubble" : "bubble.left.and.exclamationmark.bubble.right",
                    markedUnread ? s.t("Снять отметку", "Remove mark") : s.t("Пометить как новое", "Mark as new")) { dismiss(onMark) }
            }
            row(pinned ? "pin.slash" : "pin", pinned ? s.t("Открепить", "Unpin") : s.t("Закрепить", "Pin")) { dismiss(onPin) }
            row(muted ? "bell" : "bell.slash", muted ? s.t("Включить уведомления", "Unmute") : s.t("Выключить уведомления", "Mute")) { dismiss(onMute) }
            sep
            row("trash", s.clearHistory, destructive: true) { dismiss(onDelete) }
        }
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var sep: some View { Divider().opacity(0.5).padding(.leading, 52) }

    private func row(_ icon: String, _ title: String, destructive: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.impact(.light); action() }) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 17)).frame(width: 24)
                Text(title).font(.system(size: 17))
                Spacer()
            }
            .foregroundStyle(destructive ? theme.danger : theme.text)
            .padding(.horizontal, 16).frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ChatPeer: Identifiable {}

/// Строка списка чатов: короткое нажатие открывает, долгое — показывает карточку с перепиской.
/// Свайп влево — быстрые кнопки справа (закрепить, без звука, удалить) с подписями, как в Telegram.
/// Свайп вправо — одна кнопка слева (архив).
struct SwipeActionsRow<Content: View>: View {
    struct Action: Identifiable {
        let id = UUID()
        let icon: String
        var label: String = ""
        let tint: Color
        let run: () -> Void
    }

    let id: String
    @Binding var openID: String?
    var leading: Action? = nil
    let actions: [Action]                       // кнопки справа (свайп влево)
    @ViewBuilder var content: () -> Content

    @State private var drag: CGFloat = 0
    @State private var side: Int = 0            // -1 открыто справа, +1 открыто слева, 0 закрыто
    private let unit: CGFloat = 80
    private var trailingFull: CGFloat { unit * CGFloat(actions.count) }
    private var leadingFull: CGFloat { leading != nil ? unit : 0 }

    private var base: CGFloat {
        guard openID == id else { return 0 }
        return side < 0 ? -trailingFull : (side > 0 ? leadingFull : 0)
    }
    private var offset: CGFloat { max(-trailingFull - 24, min(leadingFull + 24, base + drag)) }

    private func button(_ a: Action) -> some View {
        Button {
            Haptics.impact(.light)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { openID = nil; side = 0 }
            a.run()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: a.icon).font(.system(size: 20, weight: .semibold))
                if !a.label.isEmpty {
                    Text(a.label).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(.white)
            .frame(width: unit).frame(maxHeight: .infinity).background(a.tint)
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        ZStack {
            // кнопка слева (свайп вправо) — архив
            if let leading {
                HStack(spacing: 0) { button(leading); Spacer(minLength: 0) }
                    .mask(alignment: .leading) { Rectangle().frame(width: max(0, offset)) }
            }
            // кнопки справа (свайп влево)
            HStack(spacing: 0) { Spacer(minLength: 0); ForEach(actions) { button($0) } }
                .mask(alignment: .trailing) { Rectangle().frame(width: max(0, -offset)) }

            content()
                .background(Color.clear)
                .offset(x: offset)
                .allowsHitTesting(openID != id)
                .overlay {
                    if openID == id {
                        Color.clear.contentShape(Rectangle()).offset(x: offset)
                            .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { openID = nil; side = 0 } }
                    }
                }
        }
        .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 18, coordinateSpace: .local)
                .onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height) * 1.6, v.startLocation.x > 30 else { return }
                    // вправо тянем только если есть кнопка слева
                    if v.translation.width > 0 && leading == nil && base == 0 { return }
                    drag = v.translation.width
                }
                .onEnded { v in
                    let horizontal = abs(v.translation.width) > abs(v.translation.height) * 1.6 && v.startLocation.x > 30
                    let final = base + (horizontal ? v.translation.width : 0)
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                        if horizontal, final < -trailingFull * 0.45 {
                            if openID != id || side != -1 { Haptics.select() }
                            openID = id; side = -1
                        } else if horizontal, leading != nil, final > leadingFull * 0.5 {
                            if openID != id || side != 1 { Haptics.select() }
                            openID = id; side = 1
                        } else {
                            openID = nil; side = 0
                        }
                        drag = 0
                    }
                }
        )
        .onChange(of: openID) { _, new in if new != id { drag = 0; side = 0 } }
    }
}

struct ChatRowTouch<Content: View>: View {
    let onTap: () -> Void
    let onLong: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.theme) private var theme
    @State private var pressed = false

    var body: some View {
        content()
            .background(pressed ? theme.surface : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 12, perform: onLong, onPressingChanged: { p in
                withAnimation(.easeOut(duration: 0.12)) { pressed = p }
            })
    }
}
