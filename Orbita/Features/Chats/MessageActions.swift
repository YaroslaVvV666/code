import SwiftUI

/// Открыто ли меню зажатого сообщения. Обычный флаг без подписки: строки чата проверяют его только в обработчиках
/// касаний, поэтому открытие меню не перерисовывает список
enum MessageMenu {
    static var isOpen = false
}

/// Пока открыто меню, список под размытием не листается: палец, которым зажали сообщение, иначе продолжал
/// прокручивать чат. Подписан на выбранное сообщение сам — меняется только флаг прокрутки, строки не перерисовываются
struct ActionScrollLock<Content: View>: View {
    @ObservedObject var state: ActionTargetState
    @ViewBuilder var content: Content
    var body: some View {
        content.scrollDisabled(state.target != nil)
    }
}

/// Зажатое сообщение: сверху ряд реакций, посередине само сообщение, снизу меню действий (стекло)
struct MessageActionOverlay: View {
    let message: ChatMessage
    /// Без подписки (@ObservedObject): чат опрашивает сервер раз в секунду, и каждая публикация модели перерисовывала бы
    /// всё меню вместе с копией сообщения прямо во время анимации появления. Всё, что меню читает из модели, нужно один раз
    let model: ChatModel
    var noForward: Bool
    var showSender: Bool
    var onClose: () -> Void
    var onReply: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void = {}
    /// Подтверждённое удаление: true — у всех. Меню превращается в кнопку подтверждения, как в Telegram
    var onConfirmDelete: (Bool) -> Void = { _ in }
    var isSaved = false
    var onForward: () -> Void = {}
    var onSelect: () -> Void = {}
    var onInfo: () -> Void = {}

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var appear = false
    @State private var confirming = false
    @State private var closing = false           // меню уходит плавно, а не исчезает в один кадр

    private var s: Strings { Strings(lang: lang) }
    /// В реакциях — только эмодзи с анимацией
    static let emojis = AnimatedEmoji.all
    private var current: String? { model.messages.first { $0.id == message.id }?.reactions.first(where: \.mine)?.emoji }
    private var canEdit: Bool {
        message.mine && (!message.text.isEmpty || !message.attachments.isEmpty)
            && message.attachments.allSatisfy { $0.kind != .sticker }
    }

    /// Меню на экране: появилось и ещё не закрывается
    private var shown: Bool { appear && !closing }
    private var lead: UnitPoint { message.mine ? .trailing : .leading }

    /// Появление — мягкая пружина с небольшой очередью (сначала сообщение, потом реакции, потом действия), как в Telegram;
    /// закрытие — быстрое и без очереди. Анимируются только масштаб и прозрачность небольших элементов — это дёшево
    private func motion(_ delay: Double) -> Animation {
        closing ? .easeOut(duration: Self.closeDuration) : .spring(response: 0.34, dampingFraction: 0.78).delay(delay)
    }
    private static let closeDuration: Double = 0.17

    /// Плавно убрать меню, потом закрыть его и выполнить действие
    private func dismiss(_ then: @escaping () -> Void = {}) {
        guard !closing else { return }
        closing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDuration) {
            onClose()
            then()
        }
    }

    var body: some View {
        ZStack {
            // размытие ставится сразу и без анимации прозрачности (анимированный blur пересчитывается каждый кадр и тормозит);
            // плавно проявляется и уходит только затемнение
            Rectangle().fill(.ultraThinMaterial)
                .contentShape(Rectangle())
                .overlay(Color.black.opacity(shown ? (theme.dark ? 0.35 : 0.12) : 0)
                    .animation(closing ? .easeOut(duration: Self.closeDuration) : .easeOut(duration: 0.25), value: shown))
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(alignment: message.mine ? .trailing : .leading, spacing: 10) {
                reactionBar
                    .opacity(confirming ? 0 : 1).scaleEffect(confirming ? 0.9 : 1, anchor: message.mine ? .bottomTrailing : .bottomLeading)
                    .allowsHitTesting(!confirming)
                    // ряд реакций «вырастает» из угла над сообщением
                    .scaleEffect(shown ? 1 : 0.4, anchor: message.mine ? .bottomTrailing : .bottomLeading)
                    .opacity(shown ? 1 : 0)
                    .animation(motion(0.03), value: shown)
                ScrollView {
                    MessageRow(message: message, isFirst: true, isLast: true,
                               onReply: {}, onEdit: {}, onDelete: {}, onOpenMedia: { _, _ in }, onOpenFile: { _ in },
                               showSender: showSender, noForward: noForward, interactive: false)
                        .allowsHitTesting(false)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
                // сообщение видно сразу (оно — опора меню), только мягко «приподнимается»
                .scaleEffect(shown ? 1 : 0.96, anchor: lead)
                .opacity(closing ? 0 : 1)
                .animation(motion(0), value: shown)
                Group {
                    if confirming {
                        confirmList
                            .transition(.scale(scale: 0.6, anchor: message.mine ? .topTrailing : .topLeading).combined(with: .opacity))
                    } else {
                        actionList
                            .transition(.scale(scale: 0.85, anchor: message.mine ? .topTrailing : .topLeading).combined(with: .opacity))
                    }
                }
                // список действий раскрывается из угла под сообщением
                .scaleEffect(shown ? 1 : 0.5, anchor: message.mine ? .topTrailing : .topLeading)
                .opacity(shown ? 1 : 0)
                .animation(motion(0.05), value: shown)
            }
            .padding(.horizontal, 12)
            .allowsHitTesting(!closing)               // пункты меню — только пока не закрывается
        }
        // размытый фон ловит все касания, в том числе пока меню плавно уходит: под ним ничего не нажимается
        .onAppear { appear = true; MessageMenu.isOpen = true }
        .onDisappear { MessageMenu.isOpen = false }
    }

    private var reactionBar: some View {
        // эмодзи больше, чем влезает в ширину экрана, — полоска листается вбок
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 2) {
                let selected = current
                ForEach(Array(Self.emojis.enumerated()), id: \.element) { index, e in
                    Button {
                        model.react(message, emoji: e)
                        dismiss()
                    } label: {
                        ReactionBarEmoji(emoji: e, index: index)
                            .frame(width: 38, height: 40)
                            .background(selected == e ? theme.accentColor.opacity(0.25) : Color.clear, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .frame(width: min(CGFloat(Self.emojis.count) * 40 + 20, UIScreen.main.bounds.width - 32), height: 52)
        // при прокрутке эмодзи мягко гаснут у краёв, а не обрезаются резко
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 10)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 10)
            }
        }
        // эмодзи не выходят за скруглённые края: прокрутка сама режет только по прямоугольнику
        .clipShape(Capsule())
        .menuSurface(Capsule())
    }

    private var actionList: some View {
        VStack(spacing: 0) {
            row("arrowshape.turn.up.left", s.reply) { dismiss(onReply) }
            if !noForward && message.system == nil && !message.text.hasPrefix("\u{200B}call:") {
                divider
                row("arrowshape.turn.up.right", s.t("Переслать", "Forward")) { dismiss(onForward) }
            }
            if !message.text.isEmpty && !noForward && message.poll == nil {
                divider
                row("doc.on.doc", s.copy) { UIPasteboard.general.string = message.text; dismiss() }
            }
            if model.canPin {
                divider
                let pinned = model.isPinned(message)
                row(pinned ? "pin.slash" : "pin", pinned ? s.t("Открепить", "Unpin") : s.t("Закрепить", "Pin")) {
                    model.togglePin(message); dismiss()
                }
            }
            if showSender || message.mine {
                divider
                row("eye", showSender ? s.t("Кто прочитал и отреагировал", "Seen & reactions") : s.t("Информация", "Info")) {
                    dismiss(onInfo)
                }
            }
            if canEdit && message.poll == nil {
                divider
                row("pencil", s.editMessage) { dismiss(onEdit) }
            }
            divider
            row("checkmark.circle", s.t("Выбрать", "Select")) { dismiss(onSelect) }
            divider
            row("trash", s.delete, danger: true) {
                Haptics.impact(.light)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { confirming = true }
            }
        }
        .frame(width: 250)
        .menuSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: .infinity, alignment: message.mine ? .trailing : .leading)
    }

    /// Вместо списка действий — только кнопка(и) удаления
    private var confirmList: some View {
        let everyone = message.mine || model.group?.isAdmin == true
        return VStack(spacing: 0) {
            if isSaved {
                confirmRow(s.t("Удалить из Избранного", "Delete from Saved"), forAll: false)
            } else {
                confirmRow(s.deleteForMe, forAll: false)
                if everyone { divider; confirmRow(s.deleteForAll, forAll: true) }
            }
        }
        .frame(minWidth: 250)
        .fixedSize()
        .menuSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(maxWidth: .infinity, alignment: message.mine ? .trailing : .leading)
    }

    private func confirmRow(_ title: String, forAll: Bool) -> some View {
        Button { dismiss { onConfirmDelete(forAll) } } label: {
            Text(title).font(.system(size: 17)).foregroundStyle(theme.danger)
                .frame(maxWidth: .infinity).padding(.horizontal, 20).frame(height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View { Rectangle().fill(theme.stroke).frame(height: 0.5) }

    private func row(_ icon: String, _ title: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 17))
                Spacer()
                Image(systemName: icon).font(.system(size: 16))
            }
            .foregroundStyle(danger ? theme.danger : theme.text)
            .padding(.horizontal, 16).frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Эмодзи в ряду реакций: «выпрыгивают» по очереди слева направо (лёгкая пружина) и сразу начинают играть.
/// Анимации — готовые кадры с диска (EmojiFrames), поэтому их запуск ничего не стоит и не тормозит появление меню.
/// Вью не пересоздаётся — тот же LottieEmojiView переключается playing false → true
private struct ReactionBarEmoji: View {
    let emoji: String
    let index: Int
    @State private var live = false
    @State private var popped = false

    /// Ряд начинает раскрываться чуть позже сообщения; эмодзи — волной с этим шагом
    private static let start: Double = 0.05
    private static let step: Double = 0.025

    private var delay: Double { Self.start + Double(index) * Self.step }

    var body: some View {
        LottieEmojiView(emoji: emoji, size: 34, playing: live, idleAtStart: true)      // один круг при появлении и стоп
            .scaleEffect(popped ? 1 : 0.3)
            .opacity(popped ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.62).delay(delay)) { popped = true }
            }
            .task {
                // играть начинает вместе с «прыжком» — анимация плавно разгоняется вместе с появлением
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                live = true
            }
    }
}

/// Подложка ряда реакций и списка действий. На iOS 26 — системное стекло. На старых системах — не материал,
/// а почти непрозрачная заливка: под меню и так уже размытый экран, второе размытие поверх первого не видно,
/// а стоит дорого; тень считается по форме, а не по содержимому
private struct MenuSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.theme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background {
                shape.fill(theme.dark ? Color(white: 0.16).opacity(0.94) : Color.white.opacity(0.96))
                    .shadow(color: Color.black.opacity(theme.dark ? 0.28 : 0.08), radius: 14, y: 5)
            }
            .overlay(shape.stroke(Color.white.opacity(theme.dark ? 0.12 : 0.6), lineWidth: 0.5))
    }
}

private extension View {
    func menuSurface<S: Shape>(_ shape: S) -> some View { modifier(MenuSurface(shape: shape)) }
}
