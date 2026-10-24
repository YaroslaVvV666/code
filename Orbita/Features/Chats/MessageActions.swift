import SwiftUI

/// Зажатое сообщение: сверху ряд реакций, посередине само сообщение, снизу меню действий (стекло)
struct MessageActionOverlay: View {
    let message: ChatMessage
    @ObservedObject var model: ChatModel
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
    @State private var settled = false          // анимация эмодзи стартует после появления меню, а не вместе с ним

    private var s: Strings { Strings(lang: lang) }
    /// В реакциях — только эмодзи с анимацией
    static let emojis = AnimatedEmoji.all
    private var current: String? { model.messages.first { $0.id == message.id }?.reactions.first(where: \.mine)?.emoji }
    private var canEdit: Bool {
        message.mine && (!message.text.isEmpty || !message.attachments.isEmpty)
            && message.attachments.allSatisfy { $0.kind != .sticker }
    }

    var body: some View {
        ZStack {
            // размытие ставится сразу и без анимации прозрачности (анимированный blur пересчитывается каждый кадр и тормозит);
            // плавно проявляется только затемнение
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(appear ? (theme.dark ? 0.35 : 0.12) : 0))
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(alignment: message.mine ? .trailing : .leading, spacing: 10) {
                reactionBar
                    .opacity(confirming ? 0 : 1).scaleEffect(confirming ? 0.9 : 1, anchor: message.mine ? .bottomTrailing : .bottomLeading)
                    .allowsHitTesting(!confirming)
                ScrollView {
                    MessageRow(message: message, isFirst: true, isLast: true,
                               onReply: {}, onEdit: {}, onDelete: {}, onOpenMedia: { _, _ in }, onOpenFile: { _ in },
                               showSender: showSender, noForward: noForward, interactive: false)
                        .allowsHitTesting(false)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
                if confirming {
                    confirmList
                        .transition(.scale(scale: 0.6, anchor: message.mine ? .topTrailing : .topLeading).combined(with: .opacity))
                } else {
                    actionList
                        .transition(.scale(scale: 0.85, anchor: message.mine ? .topTrailing : .topLeading).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .scaleEffect(appear ? 1 : 0.9, anchor: message.mine ? .bottomTrailing : .bottomLeading)
            .opacity(appear ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { appear = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { settled = true }
        }
    }

    private var reactionBar: some View {
        // эмодзи больше, чем влезает в ширину экрана, — полоска листается вбок
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 2) {
                ForEach(Self.emojis, id: \.self) { e in
                    Button {
                        model.react(message, emoji: e)
                        onClose()
                    } label: {
                        LottieEmojiView(emoji: e, size: 34, playing: settled).id(settled)      // один круг при появлении и стоп
                            .frame(width: 38, height: 40)
                            .background(current == e ? theme.accentColor.opacity(0.25) : Color.clear, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .frame(width: min(CGFloat(Self.emojis.count) * 40 + 16, UIScreen.main.bounds.width - 32), height: 52)
        .glass(Capsule())
    }

    private var actionList: some View {
        VStack(spacing: 0) {
            row("arrowshape.turn.up.left", s.reply) { onClose(); onReply() }
            if !noForward && message.system == nil && !message.text.hasPrefix("\u{200B}call:") {
                divider
                row("arrowshape.turn.up.right", s.t("Переслать", "Forward")) { onClose(); onForward() }
            }
            if !message.text.isEmpty && !noForward && message.poll == nil {
                divider
                row("doc.on.doc", s.copy) { UIPasteboard.general.string = message.text; onClose() }
            }
            if model.canPin {
                divider
                let pinned = model.isPinned(message)
                row(pinned ? "pin.slash" : "pin", pinned ? s.t("Открепить", "Unpin") : s.t("Закрепить", "Pin")) {
                    model.togglePin(message); onClose()
                }
            }
            if showSender || message.mine {
                divider
                row("eye", showSender ? s.t("Кто прочитал и отреагировал", "Seen & reactions") : s.t("Информация", "Info")) {
                    onClose(); onInfo()
                }
            }
            if canEdit && message.poll == nil {
                divider
                row("pencil", s.editMessage) { onClose(); onEdit() }
            }
            divider
            row("checkmark.circle", s.t("Выбрать", "Select")) { onClose(); onSelect() }
            divider
            row("trash", s.delete, danger: true) {
                Haptics.impact(.light)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { confirming = true }
            }
        }
        .frame(width: 250)
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(maxWidth: .infinity, alignment: message.mine ? .trailing : .leading)
    }

    private func confirmRow(_ title: String, forAll: Bool) -> some View {
        Button { onConfirmDelete(forAll) } label: {
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
