import SwiftUI
import Combine
import UIKit

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
    /// Открыто из «Недавних» в поиске — первой строкой «Убрать из недавних»
    var onRemoveRecent: (() -> Void)? = nil

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
            if let onRemoveRecent {
                row("xmark.circle", s.t("Убрать из недавних", "Remove from recents"), destructive: true) { dismiss(onRemoveRecent) }
                sep
            }
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

/// Строка списка чатов (как в Telegram на iOS 26): тянешь влево — строка становится скруглённой карточкой,
/// справа по одной «выпрыгивают» капсулы: сначала «В архив», потом «Удалить», потом звук.
/// Протянул дальше — серая капсула архива растягивается на всю строку; отпустил — чат уходит в архив.
/// Тянешь вправо — слева капсула «Закрепить».
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
    /// Капсулы слева (свайп вправо)
    var leading: [Action] = []
    /// Капсулы справа (свайп влево) — первая стоит у самого края и появляется первой
    let trailing: [Action]
    /// Полный свайп влево запускает первую капсулу справа (архив)
    var fullSwipe = true
    @ViewBuilder var content: () -> Content

    @Environment(\.theme) private var theme
    @State private var drag: CGFloat = 0
    @State private var side: Int = 0            // -1 открыто справа, +1 открыто слева, 0 закрыто
    @State private var width: CGFloat = 390
    @State private var armed = false            // протянули до конца: отпустишь — сработает первая капсула
    @State private var leaving = false          // строка уезжает влево (в архив)

    private let pill: CGFloat = 62              // ширина капсулы
    private let gap: CGFloat = 8
    private func span(_ n: Int) -> CGFloat { n == 0 ? 0 : CGFloat(n) * pill + CGFloat(n - 1) * gap + 22 }     // все капсулы полного размера + поля
    private var trailingFull: CGFloat { span(trailing.count) }
    private var leadingFull: CGFloat { span(leading.count) }
    private var fullAt: CGFloat { max(trailingFull + 50, width * 0.62) }

    private var base: CGFloat {
        guard openID == id else { return 0 }
        return side < 0 ? -trailingFull : (side > 0 ? leadingFull : 0)
    }
    private var offset: CGFloat {
        if leaving { return -width }
        let raw = base + drag
        if raw > leadingFull {                  // вправо дальше капсул — туго
            return leadingFull + (raw - leadingFull) * 0.25
        }
        if !fullSwipe, raw < -trailingFull {
            return -trailingFull - (-trailingFull - raw) * 0.25
        }
        return max(-width, raw)
    }
    /// Насколько строка «оторвалась» — от этого скругление карточки
    private var lift: CGFloat { min(1, abs(offset) / 40) }

    private func close() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { openID = nil; side = 0; drag = 0 }
    }

    /// Капсула размером `size` (0…pill): маленькая, пока места мало, и растёт вместе с открывшимся местом
    private func capsule(_ a: Action, size: CGFloat, stretched: CGFloat? = nil) -> some View {
        let k = stretched != nil ? 1 : max(0, min(1, size / pill))
        return Button {
            Haptics.impact(.light)
            close()
            a.run()
        } label: {
            VStack(spacing: 3 * k) {
                ZStack(alignment: stretched != nil ? .leading : .center) {
                    Capsule().fill(a.tint)
                    Image(systemName: a.icon).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                        .scaleEffect(max(0.3, k))
                        .padding(.leading, stretched != nil ? 22 : 0)
                }
                .frame(width: stretched ?? size, height: 46 * max(k, 0.0001))
                if !a.label.isEmpty {
                    Text(a.label).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.7).frame(width: pill + 6)
                        .frame(height: 13 * k)
                        .opacity(stretched == nil ? Double(max(0, (k - 0.75) * 4)) : 0)
                }
            }
            .opacity(Double(min(1, k * 2.5)))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(k > 0.6)
    }

    /// Размеры капсул по порядку появления: каждая занимает только то место, что уже открылось, —
    /// сначала маленькая у самого края карточки, растёт до полного размера и дальше не увеличивается;
    /// закрываешь — уменьшается вместе с местом, ничего не мешает
    private func sizes(_ count: Int, shown: CGFloat) -> [CGFloat] {
        var left = max(0, shown - 10 - 4)
        var out: [CGFloat] = []
        for _ in 0..<count {
            let w = max(0, min(pill, left))
            out.append(w)
            left -= w + gap
        }
        return out
    }

    /// Свайп вбок (только горизонтальный — вертикальный сразу уходит в прокрутку списка)
    private func pan(_ state: UIGestureRecognizer.State, tx: CGFloat, ty: CGFloat, startX: CGFloat) {
        switch state {
        case .began, .changed:
            if tx > 0 && leading.isEmpty && base == 0 { return }
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { drag = tx }
            let now = fullSwipe && !trailing.isEmpty && -(base + tx) > fullAt
            if now != armed {
                armed = now
                Haptics.impact(now ? .medium : .light)
            }
        default:
            let ok = state == .ended
            let final = base + (ok ? tx : 0)
            if ok, armed, let first = trailing.first {
                // протянули до конца — строка уезжает, срабатывает первая капсула (архив)
                armed = false
                withAnimation(.easeIn(duration: 0.2)) { leaving = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    first.run()
                    leaving = false; drag = 0; side = 0
                    if openID == id { openID = nil }
                }
                return
            }
            armed = false
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                if ok, !trailing.isEmpty, final < -trailingFull * 0.4 {
                    if openID != id || side != -1 { Haptics.select() }
                    openID = id; side = -1
                } else if ok, !leading.isEmpty, final > leadingFull * 0.5 {
                    if openID != id || side != 1 { Haptics.select() }
                    openID = id; side = 1
                } else {
                    openID = nil; side = 0
                }
                drag = 0
            }
        }
    }

    var body: some View {
        let shownRight = max(0, -offset)
        let shownLeft = max(0, offset)
        let rightSizes = sizes(trailing.count, shown: shownRight)
        let leftSizes = sizes(leading.count, shown: shownLeft)
        ZStack {
            // справа: капсулы прилегают к краю карточки, первая — у края экрана; на полном свайпе первая тянется на всё место
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ForEach(Array(trailing.enumerated().reversed()), id: \.element.id) { i, a in
                    if armed && i == 0 {
                        capsule(a, size: pill, stretched: max(pill, shownRight - 20))
                    } else if !armed && rightSizes[i] > 0.5 {
                        capsule(a, size: rightSizes[i])
                            .padding(.trailing, i == 0 ? 0 : gap * min(1, rightSizes[i] / pill))
                    }
                }
            }
            .padding(.trailing, 10)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: armed)

            // слева: закрепить
            HStack(spacing: 0) {
                ForEach(Array(leading.enumerated()), id: \.element.id) { i, a in
                    if leftSizes[i] > 0.5 {
                        capsule(a, size: leftSizes[i]).padding(.leading, i == 0 ? 0 : gap * min(1, leftSizes[i] / pill))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)

            content()
                .background {
                    // отъезжая, строка превращается в скруглённую карточку
                    RoundedRectangle(cornerRadius: 26 * lift, style: .continuous)
                        .fill(theme.dark ? Color(white: 0.11) : Color(white: 0.95))
                        .opacity(Double(lift))
                }
                .clipShape(RoundedRectangle(cornerRadius: 26 * lift, style: .continuous))
                .offset(x: offset)
                // касания строки ловит её системный слой (ChatRowTouch): свайп вбок — сюда, тап по открытой — закрыть
                .environment(\.rowSwipe, RowSwipeHooks(
                    pan: { state, tx, ty, startX in pan(state, tx: tx, ty: ty, startX: startX) },
                    interceptTap: { if openID == id { close(); return true }; return false }))
        }
        .clipped()
        .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } })
        .onChange(of: openID) { _, new in if new != id { withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { drag = 0; side = 0 } } }
    }
}

/// Свайп строки: SwipeActionsRow передаёт сюда, что делать со сдвигом вбок и с тапом по открытой строке
struct RowSwipeHooks {
    var pan: (UIGestureRecognizer.State, CGFloat, CGFloat, CGFloat) -> Void
    var interceptTap: () -> Bool
}

private struct RowSwipeKey: EnvironmentKey { static let defaultValue: RowSwipeHooks? = nil }
extension EnvironmentValues {
    var rowSwipe: RowSwipeHooks? {
        get { self[RowSwipeKey.self] }
        set { self[RowSwipeKey.self] = newValue }
    }
}

/// Строка списка чатов: тап — открыть, долгое нажатие — предпросмотр, свайп вбок — капсулы.
/// Всё на системных распознавателях (UIKit): они не спорят с прокруткой — повёл пальцем вверх/вниз,
/// и список сразу листается, а не думает, что строку «зажимают»
struct ChatRowTouch<Content: View>: View {
    let onTap: () -> Void
    var onLong: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @Environment(\.theme) private var theme
    @Environment(\.rowSwipe) private var swipe
    @State private var pressed = false

    var body: some View {
        content()
            .background(pressed ? theme.surface : Color.clear)
            .overlay {
                RowTouchLayer(
                    onTap: {
                        if swipe?.interceptTap() == true { return }
                        withAnimation(.easeOut(duration: 0.08)) { pressed = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            withAnimation(.easeOut(duration: 0.2)) { pressed = false }
                        }
                        onTap()
                    },
                    onLong: onLong.map { long in {
                        if swipe?.interceptTap() == true { return }
                        withAnimation(.easeOut(duration: 0.1)) { pressed = true }
                        long()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(.easeOut(duration: 0.2)) { pressed = false }
                        }
                    } },
                    onPan: swipe?.pan)
            }
    }
}

private struct RowTouchLayer: UIViewRepresentable {
    var onTap: () -> Void
    var onLong: (() -> Void)?
    var onPan: ((UIGestureRecognizer.State, CGFloat, CGFloat, CGFloat) -> Void)?

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let c = context.coordinator
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.4
        hold.allowableMovement = 8                  // палец поехал — это прокрутка, не «зажатие»
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        c.panRecognizer = pan
        for g in [tap, hold, pan] as [UIGestureRecognizer] {
            g.cancelsTouchesInView = false
            g.delegate = c
            v.addGestureRecognizer(g)
        }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: RowTouchLayer
        weak var panRecognizer: UIPanGestureRecognizer?
        private var startX: CGFloat = 0
        init(parent: RowTouchLayer) { self.parent = parent }

        @objc func tap(_ g: UITapGestureRecognizer) { parent.onTap() }
        @objc func hold(_ g: UILongPressGestureRecognizer) { if g.state == .began { parent.onLong?() } }
        @objc func pan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            if g.state == .began { startX = g.location(in: g.view).x - t.x }
            parent.onPan?(g.state, t.x, t.y, startX)
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === panRecognizer, let pan = g as? UIPanGestureRecognizer else {
                return g is UILongPressGestureRecognizer ? parent.onLong != nil : true
            }
            // вбок — только явно горизонтальное движение и не от самого края (там «назад»)
            guard parent.onPan != nil else { return false }
            let v = pan.velocity(in: pan.view)
            let start = pan.location(in: pan.view).x - pan.translation(in: pan.view).x
            return abs(v.x) > abs(v.y) * 1.3 && start > 30
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // тап и долгое нажатие не мешают прокрутке; свайп вбок, начавшись, строку не делит со списком
            g !== panRecognizer
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            // прокрутка списка ждёт, пока станет ясно, что это не свайп вбок (решается на первом же сдвиге)
            g === panRecognizer && other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}
