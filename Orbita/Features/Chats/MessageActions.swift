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
    var onDelete: () -> Void
    var onForward: () -> Void = {}
    var onSelect: () -> Void = {}
    var onInfo: () -> Void = {}

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var appear = false

    private var s: Strings { Strings(lang: lang) }
    static let emojis = ["\u{2764}\u{FE0F}", "\u{1F44D}", "\u{1F44E}", "\u{1F525}", "\u{1F602}", "\u{1F62E}", "\u{1F622}", "\u{1F389}"]
    private var current: String? { model.messages.first { $0.id == message.id }?.reactions.first(where: \.mine)?.emoji }
    private var canEdit: Bool {
        message.mine && (!message.text.isEmpty || !message.attachments.isEmpty)
            && message.attachments.allSatisfy { $0.kind != .sticker }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).opacity(appear ? 1 : 0)
                .overlay(Color.black.opacity(appear ? (theme.dark ? 0.35 : 0.12) : 0))
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(alignment: message.mine ? .trailing : .leading, spacing: 10) {
                reactionBar
                ScrollView {
                    MessageRow(message: message, isFirst: true, isLast: true,
                               onReply: {}, onEdit: {}, onDelete: {}, onOpenMedia: { _, _ in }, onOpenFile: { _ in },
                               showSender: showSender, noForward: noForward, interactive: false)
                        .allowsHitTesting(false)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
                actionList
            }
            .padding(.horizontal, 12)
            .scaleEffect(appear ? 1 : 0.92)
            .opacity(appear ? 1 : 0)
        }
        .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { appear = true } }
    }

    private var reactionBar: some View {
        HStack(spacing: 2) {
            ForEach(Self.emojis, id: \.self) { e in
                Button {
                    model.react(message, emoji: e)
                    onClose()
                } label: {
                    LottieEmojiView(emoji: e, size: 34, loop: true)
                        .frame(width: 38, height: 40)
                        .background(current == e ? theme.accentColor.opacity(0.25) : Color.clear, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
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
            row("trash", s.delete, danger: true) { onClose(); onDelete() }
        }
        .frame(width: 250)
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: .infinity, alignment: message.mine ? .trailing : .leading)
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
