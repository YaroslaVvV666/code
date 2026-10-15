import SwiftUI

/// Предпросмотр переписки без «прочитано»: последние сообщения + лоскуток «Новые сообщения».
/// Используется и в баннере нового сообщения, и в меню по зажатию чата в списке.
struct ChatPreviewBody: View {
    let peer: ChatPeer
    let repo: MessengerRepository
    var limit = 14
    var maxHeight: CGFloat? = nil
    var onThread: ((ChatThread) -> Void)? = nil

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var messages: [ChatMessage] = []
    @State private var firstUnread: String?
    @State private var loading = true

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 4) {
                    if loading { ProgressView().padding(.vertical, 30) }
                    if !loading && messages.isEmpty {
                        Text(s.chatStart).font(.system(size: 14)).foregroundStyle(theme.textTertiary).padding(.vertical, 30)
                    }
                    ForEach(messages) { m in
                        if m.id == firstUnread {
                            Text(s.t("Новые сообщения", "New messages"))
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accentColor)
                                .frame(maxWidth: .infinity).padding(.vertical, 5)
                                .background(theme.accentColor.opacity(0.14))
                                .padding(.horizontal, -12).padding(.vertical, 4)
                                .id("strip")
                        }
                        bubble(m).id(m.key)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(maxHeight: maxHeight)
            .onChange(of: messages.count) { _, _ in
                if firstUnread != nil { proxy.scrollTo("strip", anchor: .top) }
                else if let last = messages.last { proxy.scrollTo(last.key, anchor: .bottom) }
            }
        }
        .task(id: peer.id) {
            let thread = try? await repo.thread(peerID: peer.id, limit: limit, peek: true)
            firstUnread = thread?.firstUnread
            if let thread { onThread?(thread) }
            messages = thread?.messages ?? []
            loading = false
        }
    }

    private func bubble(_ m: ChatMessage) -> some View {
        HStack {
            if m.mine { Spacer(minLength: 40) }
            VStack(alignment: .trailing, spacing: 1) {
                Text(m.summary.isEmpty ? "…" : m.summary)
                    .font(.system(size: 15))
                    .foregroundStyle(m.mine ? Color.white : theme.text)
                    .multilineTextAlignment(.leading)
                Text(ChatTime.clock(m.createdAt))
                    .font(.system(size: 10)).foregroundStyle(m.mine ? Color.white.opacity(0.7) : theme.textTertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(m.mine ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.surface),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !m.mine { Spacer(minLength: 40) }
        }
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

/// Строка списка чатов: короткое нажатие открывает, долгое — показывает карточку с перепиской
/// Свайп строки влево открывает быстрые кнопки (закрепить, без звука, удалить), как в Telegram
struct SwipeActionsRow<Content: View>: View {
    struct Action: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let run: () -> Void
    }

    let id: String
    @Binding var openID: String?
    let actions: [Action]
    @ViewBuilder var content: () -> Content

    @State private var drag: CGFloat = 0
    private let unit: CGFloat = 72
    private var full: CGFloat { unit * CGFloat(actions.count) }
    private var base: CGFloat { openID == id ? -full : 0 }
    private var offset: CGFloat { max(-full - 24, min(0, base + drag)) }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                ForEach(actions) { a in
                    Button {
                        Haptics.impact(.light)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { openID = nil }
                        a.run()
                    } label: {
                        Image(systemName: a.icon).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: unit).frame(maxHeight: .infinity).background(a.tint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: full)
            .mask(alignment: .trailing) { Rectangle().frame(width: max(0, -offset)) }      // видна только открытая часть

            content()
                .background(Color.clear)
                .offset(x: offset)
                .allowsHitTesting(openID != id)
                .overlay {
                    // открытая строка: нажатие по ней закрывает кнопки
                    if openID == id {
                        Color.clear.contentShape(Rectangle()).offset(x: offset)
                            .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { openID = nil } }
                    }
                }
        }
        .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 18, coordinateSpace: .local)
                .onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height) * 1.6, v.startLocation.x > 30 else { return }
                    drag = v.translation.width
                }
                .onEnded { v in
                    let horizontal = abs(v.translation.width) > abs(v.translation.height) * 1.6 && v.startLocation.x > 30
                    let final = base + (horizontal ? v.translation.width : 0)
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                        if horizontal, final < -full * 0.45 {
                            if openID != id { Haptics.select() }
                            openID = id
                        } else if horizontal {
                            openID = nil
                        }
                        drag = 0
                    }
                }
        )
        .onChange(of: openID) { _, new in if new != id { drag = 0 } }
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
