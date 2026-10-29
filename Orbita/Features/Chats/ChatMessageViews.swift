import SwiftUI
import AVFoundation
import QuickLook
import UIKit
import Combine

// MARK: - Палитра переписки

struct ChatColors {
    let theme: Theme

    var incoming: Color { theme.dark ? Color(red: 0.14, green: 0.155, blue: 0.21) : Color.white }
    var incomingText: Color { theme.text }
    var incomingSecondary: Color { theme.textTertiary }
    var outgoingText: Color { Color.white }
    var outgoingSecondary: Color { Color.white.opacity(0.72) }
}

// MARK: - Время и галочки внутри сообщения

struct MessageMeta: View {
    let message: ChatMessage
    let color: Color
    var onMedia = false

    @Environment(\.lang) private var lang

    var body: some View {
        HStack(spacing: 3) {
            if let views = message.views {
                Image(systemName: "eye").font(.system(size: 10))
                Text(views >= 1000 ? String(format: "%.1fK", Double(views) / 1000) : "\(views)").font(.system(size: 11))
                Text("·").font(.system(size: 11))
            }
            if let note = message.note {
                MessageNoteChip(messageID: message.id, note: note, color: color)
            }
            if message.editedAt != nil {
                Text(Strings(lang: lang).edited).font(.system(size: 11))
            }
            Text(ChatTime.clock(message.createdAt)).font(.system(size: 11))
            if message.mine {
                if message.isPending {
                    if message.failed {
                        Text(Strings(lang: lang).t("Отправляется…", "Sending…")).font(.system(size: 11))
                    }
                    SendingIndicator(color: color)
                    if message.failed {
                        // нет связи: сообщение уйдёт само, когда она появится
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 14))
                            .symbolRenderingMode(.palette).foregroundStyle(.white, Color(red: 1, green: 0.23, blue: 0.19))
                    }
                } else {
                    Ticks(read: message.read, color: color)
                }
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, onMedia ? 7 : 0)
        .padding(.vertical, onMedia ? 3 : 0)
        .background(onMedia ? Color.black.opacity(0.42) : Color.clear, in: Capsule())
    }
}

// MARK: - Своя заметка к сообщению

/// Экран чата открывает редактор заметки по id сообщения (из раскрытой заметки — «Изменить»)
private struct EditMessageNoteKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var editMessageNote: ((String) -> Void)? {
        get { self[EditMessageNoteKey.self] }
        set { self[EditMessageNoteKey.self] = newValue }
    }
}

/// Заметка мелким текстом слева от времени. Длинная обрезается; нажатие — полная версия во всплывающем окне
struct MessageNoteChip: View {
    let messageID: String
    let note: String
    let color: Color

    static let maxChars = 16

    /// Длинная — первые символы и «…»; ширина предсказуема, под неё в пузыре оставляется место
    static func short(_ note: String) -> String {
        let line = note.replacingOccurrences(of: "\n", with: " ")
        return line.count > maxChars ? String(line.prefix(maxChars - 1)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.editMessageNote) private var editNote
    @State private var expanded = false

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "note.text").font(.system(size: 9, weight: .semibold))
            Text(Self.short(note)).font(.system(size: 11).italic()).lineLimit(1)
        }
        .fixedSize()
        .padding(.trailing, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            guard editNote != nil, !MessageMenu.isOpen else { return }
            Haptics.select()
            expanded = true
        }
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Label(Strings(lang: lang).t("Заметка · видна только вам", "Note · only you can see it"), systemImage: "lock.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                ScrollView {
                    Text(note).font(.system(size: 16)).foregroundStyle(theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
                Button {
                    expanded = false
                    let id = messageID
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { editNote?(id) }
                } label: {
                    Label(Strings(lang: lang).t("Изменить", "Edit"), systemImage: "pencil")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .frame(width: min(320, UIScreen.main.bounds.width - 48))
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// Редактор заметки: добавить, изменить, удалить
struct MessageNoteSheet: View {
    let message: ChatMessage
    var onSave: (String) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(s.t("Отмена", "Cancel")) { dismiss() }.foregroundStyle(theme.textSecondary)
                Spacer()
                Text(s.t("Заметка", "Note")).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
                Spacer()
                Button(s.t("Готово", "Done")) {
                    Haptics.notify(.success)
                    onSave(text); dismiss()
                }
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.accentColor)
            }
            .padding(.top, 16)
            Label(s.t("Видна только вам — собеседник её не увидит", "Only you can see it — the other person won't"),
                  systemImage: "lock.fill")
                .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            TextField(s.t("Текст заметки", "Note text"), text: $text, axis: .vertical)
                .font(.system(size: 16)).foregroundStyle(theme.text)
                .lineLimit(3...10)
                .focused($focused)
                .padding(12)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onChange(of: text) { _, v in if v.count > 2000 { text = String(v.prefix(2000)) } }
            if message.note != nil {
                Button(role: .destructive) {
                    Haptics.impact(.light)
                    onSave(""); dismiss()
                } label: {
                    Label(s.t("Удалить заметку", "Delete note"), systemImage: "trash")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(theme.danger)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .onAppear { text = message.note ?? ""; focused = true }
    }
}

// MARK: - Строка сообщения

struct MessageRow: View {
    let message: ChatMessage
    let isFirst: Bool
    let isLast: Bool
    var onReply: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onOpenMedia: ([MediaItem], Int) -> Void
    var onOpenFile: (ChatAttachment) -> Void
    var onPlayAudio: (ChatAttachment) -> Void = { _ in }
    var showSender = false
    var noForward = false
    var onReactionInfo: (() -> Void)? = nil
    var onJumpToReply: ((String) -> Void)? = nil     // нажали на цитату — перейти к исходному сообщению
    var onReact: ((String) -> Void)? = nil          // двойной тап и нажатие на «чип» реакции
    var onLongPress: (() -> Void)? = nil            // зажатие — реакции и меню
    var interactive = true
    var pinnedMark = false
    var onOpenProfile: ((String) -> Void)? = nil     // тап по «Переслано от …» / имени
    var onOpenPost: ((String) -> Void)? = nil
    var onOpenStory: ((String) -> Void)? = nil
    var onPollChanged: ((PollInfo) -> Void)? = nil
    var onOpenComments: (() -> Void)? = nil          // канал с обсуждением: «Комментарии»
    var onCallBack: ((Bool) -> Void)? = nil          // нажали на запись о звонке — перезвонить (true — видео)
    var onOpenStickerPack: ((String) -> Void)? = nil  // нажали на свой стикер — шторка набора «Добавить»
    var onOpenEntity: ((ChatEntity) -> Void)? = nil   // нажали на номер / карту / криптоадрес / @юзернейм в тексте

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.openURL) private var parentOpenURL
    @State private var dragX: CGFloat = 0
    @State private var longFired = false         // после зажатия (меню открылось) отпускание пальца не должно открывать фото/файл

    private var s: Strings { Strings(lang: lang) }
    private var colors: ChatColors { ChatColors(theme: theme) }
    private var mine: Bool { message.mine }
    /// Касания сообщения не срабатывают: только что было зажатие или открыто меню реакций.
    /// Палец, которым зажали, остаётся «привязан» к этой строке и после появления меню — его движения и отпускание
    /// не должны отвечать свайпом, ставить ❤️ или открывать фото/видео/файл под размытием
    private var blocked: Bool { longFired || MessageMenu.isOpen }

    private var stickerOnly: ChatAttachment? {
        guard message.attachments.count == 1, message.text.isEmpty, message.reply == nil,
              message.attachments[0].kind == .sticker else { return nil }
        return message.attachments[0]
    }
    private var circleOnly: ChatAttachment? {
        guard message.attachments.count == 1, message.text.isEmpty, message.reply == nil,
              message.attachments[0].kind == .circle else { return nil }
        return message.attachments[0]
    }
    private var emojiOnly: Bool {
        message.attachments.isEmpty && message.reply == nil && message.storyReply == nil && message.text.isEmojiOnly
    }
    /// Одно эмодзи — крупно, два-три — поменьше
    private var emojiSize: CGFloat {
        switch message.text.trimmingCharacters(in: .whitespacesAndNewlines).count {
        case 1: return 112
        case 2: return 80
        default: return 62
        }
    }
    private var mediaItems: [ChatAttachment] { message.attachments.filter { $0.kind == .photo || $0.kind == .video } }

    var body: some View {
        if let sys = message.system {
            systemPill(sys)
        } else {
            regularBody
        }
    }

    private func systemPill(_ kind: String) -> some View {
        let who = message.sender?.name ?? ""
        let what: String
        switch kind {
        case "left": what = s.t("вышел(а) из группы", "left the group")
        case "joined": what = s.t("вступил(а) в группу", "joined the group")
        case "removed": what = s.t("исключён(а) из группы", "was removed from the group")
        default: what = ""
        }
        return HStack {
            Spacer(minLength: 0)
            Text(who.isEmpty ? what : who + " " + what)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(theme.stroke, lineWidth: 0.5))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if let id = message.sender?.id { onOpenProfile?(id) } }
    }

    private var regularBody: some View {
        HStack(spacing: 0) {
            if mine { Spacer(minLength: 44) }
            content
                .offset(x: dragX)
                .overlay(alignment: mine ? .leading : .trailing) {
                    Image(systemName: "arrowshape.turn.up.left.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(theme.accentColor)
                        .opacity(Double(min(1, -dragX / 56)))
                        .offset(x: mine ? -34 : 34)
                        .scaleEffect(min(1, -dragX / 56))
                }
            if !mine { Spacer(minLength: 44) }
        }
        .contentShape(Rectangle())
        // ссылки в тексте: пока открыто меню реакций (зажали сообщение), отпускание пальца на ссылке её не открывает
        .environment(\.openURL, OpenURLAction { url in
            if blocked { return .handled }
            if let entity = ChatEntity(url: url) {
                if let onOpenEntity { Haptics.impact(.light); onOpenEntity(entity) }
                return .handled
            }
            parentOpenURL(url)
            return .handled
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if interactive, !message.isPending, !blocked { onReact?("\u{2764}\u{FE0F}") }
        })
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.25, maximumDistance: 8)
            .onEnded { _ in
                if interactive, !message.isPending, !MessageMenu.isOpen, let onLongPress {
                    longFired = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { longFired = false }
                    Haptics.impact(.medium); onLongPress()
                }
            })
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    guard !MessageMenu.isOpen else { if dragX != 0 { dragX = 0 }; return }      // меню открыто — свайп-ответа нет
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.6 else { return }
                    dragX = max(-80, min(0, value.translation.width))
                }
                .onEnded { value in
                    if dragX <= -56 && !MessageMenu.isOpen {
                        Haptics.impact(.medium)
                        onReply()
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragX = 0 }
                }
        )
    }

    private var callInfo: (status: String, video: Bool, seconds: Int)? {
        guard message.text.hasPrefix("\u{200B}call:") else { return nil }
        let parts = message.text.dropFirst(6).split(separator: ":").map(String.init)
        guard parts.count >= 3 else { return nil }
        return (parts[0], parts[1] == "1", Int(Double(parts[2]) ?? 0))
    }

    private var content: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if let info = callInfo { callBubble(info) } else { core }
            if !message.reactions.isEmpty { reactionChips }
        }
    }

    private func callBubble(_ info: (status: String, video: Bool, seconds: Int)) -> some View {
        let failed = info.status != "ended"
        let title: String = {
            switch info.status {
            case "ended": return mine ? s.t("Исходящий звонок", "Outgoing call") : s.t("Входящий звонок", "Incoming call")
            case "missed": return mine ? s.t("Нет ответа", "No answer") : s.t("Пропущенный звонок", "Missed call")
            case "declined": return mine ? s.t("Звонок отклонён", "Call declined") : s.t("Вы отклонили звонок", "You declined")
            default: return mine ? s.t("Звонок отменён", "Call cancelled") : s.t("Пропущенный звонок", "Missed call")
            }
        }()
        let detail = info.status == "ended"
            ? ChatTime.clock(message.createdAt) + " · " + mmss(info.seconds)
            : ChatTime.clock(message.createdAt)
        return HStack(spacing: 12) {
            Image(systemName: info.video ? "video.fill" : (failed ? "phone.down.fill" : (mine ? "phone.arrow.up.right.fill" : "phone.arrow.down.left.fill")))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(failed ? AnyShapeStyle(theme.danger) : AnyShapeStyle(Color.green), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(failed && !mine ? theme.danger : theme.text)
                Text(detail).font(.system(size: 13).monospacedDigit()).foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture {
            guard interactive, !blocked, let onCallBack else { return }
            Haptics.impact(.medium)
            onCallBack(info.video)
        }
    }

    private var reactionChips: some View {
        HStack(spacing: 4) {
            ForEach(message.reactions, id: \.emoji) { r in
                Button { if interactive && !blocked { onReact?(r.emoji) } } label: {
                    HStack(spacing: 4) {
                        AnimatedReactionEmoji(emoji: r.emoji, mine: r.mine, count: r.count)
                        if r.count > 1 || !r.mine {
                            Text("\(r.count)").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(r.mine ? Color.white : theme.text)
                        }
                    }
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(r.mine ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
                    .overlay(Capsule().stroke(theme.stroke, lineWidth: r.mine ? 0 : 1))
                    .background(GeometryReader { g in
                        Color.clear.preference(key: MessageFrameKey.self,
                                               value: [message.id + "|" + r.emoji: g.frame(in: .global)])
                    })
                }
                .buttonStyle(.plain)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    if interactive && !blocked { Haptics.impact(.medium); onReactionInfo?() }
                })
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: message.reactions)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var core: some View {
        if let sticker = stickerOnly {
            ZStack(alignment: .bottomTrailing) {
                StickerImage(sticker: sticker.asSticker, size: 168)
                MessageMeta(message: message, color: .white, onMedia: true).padding(6)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // свой стикер — показать набор и дать добавить его себе
                guard interactive, !blocked, let pack = sticker.stickerPack else { return }
                Haptics.impact(.light)
                onOpenStickerPack?(pack)
            }
        } else if let circle = circleOnly {
            CircleVideoBubble(attachment: circle, message: message)
            } else if emojiOnly {
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                let value = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.count == 1 && !interactive {
                    // копия сообщения (предпросмотр чата по зажатию, баннер, меню реакций): анимация тут не играет —
                    // готовая картинка, без живой Lottie-сцены внутри всплывающей карточки (из-за неё предпросмотр падал)
                    StillEmoji(emoji: value, size: emojiSize * 1.25)
                } else if value.count == 1 {
                    // одно эмодзи — анимированное. Только что отправили или пришло при открытом чате — один круг анимации; старые — по нажатию
                    let fresh = message.isPending || Date().timeIntervalSince(message.createdAt) < 20
                    TimedLottieEmoji(emoji: value, size: emojiSize * 1.25, playOnceKey: fresh ? message.key : nil)
                } else {
                    Text(value).font(.system(size: emojiSize))
                }
                MessageMeta(message: message, color: .white, onMedia: true)
            }
        } else {
            bubble
        }
    }

    // MARK: Пузырь

    private var shape: UnevenRoundedRectangle {
        let big: CGFloat = 21, small: CGFloat = 6, join: CGFloat = 7
        return UnevenRoundedRectangle(
            topLeadingRadius: mine ? big : (isFirst ? big : join),
            bottomLeadingRadius: mine ? big : (isLast ? small : join),
            bottomTrailingRadius: mine ? (isLast ? small : join) : big,
            topTrailingRadius: mine ? (isFirst ? big : join) : big,
            style: .continuous)
    }

    private var hasText: Bool { !message.text.isEmpty }
    private var onlyMedia: Bool { hasText == false && mediaItems.count == message.attachments.count && !mediaItems.isEmpty }

    /// Одно голосовое без текста: время кладётся в ту же строку, что и длительность, без отдельной пустой строки
    private var voiceOnly: Bool {
        !hasText && message.poll == nil && mediaItems.isEmpty && message.attachments.count == 1
            && message.attachments[0].kind == .voice
    }

    /// Один файл или трек без текста: время кладётся в угол блока, без отдельной строки снизу
    private var fileOnly: Bool {
        !hasText && message.poll == nil && mediaItems.isEmpty && message.attachments.count == 1
            && (message.attachments[0].kind == .file || message.attachments[0].kind == .audio)
    }

    private var bubble: some View {
        let textColor = mine ? colors.outgoingText : colors.incomingText
        let secondary = mine ? colors.outgoingSecondary : colors.incomingSecondary
        // место под время/галочки/просмотры: ширина самой метки + небольшой гарантированный зазор между текстом и временем.
        // Короткому сообщению не добавляем лишнего, длинному — время не наезжает на текст.
        let metaGap: CGFloat = 10                              // обязательный зазор «текст ↔ время»
        let metaWidth: CGFloat = 24 + (mine ? 14 : 0) + (message.editedAt != nil ? 44 : 0)
            + (message.note.map { n in 16 + CGFloat(MessageNoteChip.short(n).count) * 5.8 } ?? 0)
            + (message.views.map { v -> CGFloat in
                // глаз + число + «·» + три зазора; число считаем так же, как рисует MessageMeta
                let text = v >= 1000 ? String(format: "%.1fK", Double(v) / 1000) : "\(v)"
                return 30 + CGFloat(text.count) * 6.8
            } ?? 0) + metaGap
        // figure space (U+2007) неразрывный и шириной с цифру (~9.1 пт на 16): хвост не «висит» и время не наезжает
        let filler = String(repeating: "\u{2007}", count: Int((metaWidth / 9.1).rounded(.up)))

        return VStack(alignment: .leading, spacing: 0) {
            if showSender, !mine, isFirst, let sender = message.sender {
                Text(sender.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(senderColor(sender.id))
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .padding(.top, 6)
                    .onTapGesture { if !blocked { onOpenProfile?(sender.id) } }
            }
            if let fwd = message.forwarded, !fwd.name.isEmpty {
                Button {
                    if blocked { return }
                    if let post = fwd.postID { onOpenPost?(post) } else if let id = fwd.id { onOpenProfile?(id) }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(fwd.postID != nil ? s.t("Публикация от", "Post from") : s.t("Переслано от", "Forwarded from"))
                            .font(.system(size: 12))
                            .foregroundStyle(mine ? Color.white.opacity(0.8) : theme.textSecondary)
                        Text(fwd.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            .foregroundStyle(mine ? Color.white : theme.accentColor)
                    }
                    .padding(.horizontal, 11).padding(.top, showSender && !mine && isFirst ? 2 : 7).padding(.bottom, 1)
                    .frame(maxWidth: 230, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            if let story = message.storyReply {
                Button { if !blocked { Haptics.impact(.light); onOpenStory?(story.id) } } label: {
                HStack(spacing: 8) {
                    Capsule().fill(mine ? Color.white.opacity(0.85) : theme.accentColor).frame(width: 3)
                    ZStack {
                        if story.isVideo {
                            Color.black.opacity(0.7)
                            Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(.white)
                        } else {
                            RemoteImage(id: story.mediaID)
                        }
                    }
                    .frame(width: 30, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.t("Ответ на историю", "Reply to story"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(mine ? Color.white : theme.accentColor)
                        Text(s.t("История", "Story")).font(.system(size: 12))
                            .foregroundStyle(mine ? Color.white.opacity(0.8) : theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(mine ? Color.white.opacity(0.7) : theme.textTertiary)
                }
                .frame(maxWidth: 230, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 2)
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let reply = message.reply {
                ReplyQuote(reply: reply, mine: mine)
                    .contentShape(Rectangle())
                    .onTapGesture { if !blocked { Haptics.impact(.light); onJumpToReply?(reply.id) } }
                    .padding(.horizontal, 10)
                    .padding(.top, 7)
                    .padding(.bottom, 2)
            }
            if let poll = message.poll {
                PollBlock(messageID: message.id, question: message.text, poll: poll, mine: mine, pending: message.isPending,
                          onChanged: { onPollChanged?($0) })
                    .padding(.horizontal, 11).padding(.top, 8).padding(.bottom, 4)
                MessageMeta(message: message, color: secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 11).padding(.bottom, 5)
            }

            if !mediaItems.isEmpty {
                MediaBlock(items: mediaItems, pending: message.isPending) { index in
                    // присланный шортс: нажатие открывает ленту шортсов на этом видео (как в TikTok)
                    if blocked { return }
                    if let pid = message.forwarded?.postID, mediaItems.first?.mediaItem?.kind == .video, let open = onOpenPost {
                        open(pid); return
                    }
                    let items = mediaItems.compactMap(\.mediaItem)
                    if !items.isEmpty { onOpenMedia(items, min(index, items.count - 1)) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if onlyMedia { MessageMeta(message: message, color: .white, onMedia: true).padding(6) }
                }
                .padding(.top, message.reply == nil ? 0 : 6)
            }

            ForEach(message.attachments.filter { $0.kind == .voice || $0.kind == .file || $0.kind == .circle
                                                  || $0.kind == .sticker || $0.kind == .audio }) { a in
                Group {
                    switch a.kind {
                    case .voice: VoiceBlock(attachment: a, mine: mine, pending: message.isPending, metaSpace: voiceOnly)
                    case .audio: AudioBlock(attachment: a, mine: mine, pending: message.isPending) { if !blocked { onPlayAudio(a) } }
                    case .file:
                        if a.isMusic {
                            AudioBlock(attachment: a, mine: mine) { if !blocked { onPlayAudio(a) } }
                        } else {
                            FileBlock(attachment: a, mine: mine, pending: message.isPending) { if !blocked { onOpenFile(a) } }
                        }
                    case .circle: CircleVideoBubble(attachment: a, message: message, size: 180)
                    default: StickerImage(sticker: a.asSticker, size: 120)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, hasText ? 0 : (fileOnly ? 4 : 6))
                .overlay(alignment: .bottomTrailing) {
                    if voiceOnly && a.kind == .voice {
                        MessageMeta(message: message, color: secondary).padding(.trailing, 10).padding(.bottom, 6)
                    } else if fileOnly {
                        MessageMeta(message: message, color: secondary).padding(.trailing, 10).padding(.bottom, 8)
                    }
                }
            }

            if hasText && message.poll == nil {
                RichInlineText(text: message.text, entities: message.entities, size: 16,
                               color: textColor, linkColor: mine ? .white : theme.accentColor, filler: filler,
                               detect: interactive)
                    .padding(.horizontal, 11)
                    .padding(.top, mediaItems.isEmpty && message.attachments.isEmpty && message.reply == nil ? 7 : 6)
                    .padding(.bottom, 7)
                    .overlay(alignment: .bottomTrailing) {
                        MessageMeta(message: message, color: secondary).padding(.trailing, 10).padding(.bottom, 5)
                    }
            } else if !onlyMedia && message.poll == nil && !voiceOnly && !fileOnly {
                HStack { Spacer(minLength: 0); MessageMeta(message: message, color: secondary) }
                    .padding(.horizontal, 11)
                    .padding(.bottom, 5)
            }

            if hasText, message.poll == nil, mediaItems.isEmpty, let link = LinkPreviewCard.firstURL(in: message.text) {
                LinkPreviewCard(url: link, mine: mine)
            }

            if let n = message.comments, !message.isPending, let open = onOpenComments {
                commentsBar(n, open: open)
            }
        }
        .frame(minWidth: 56, alignment: .leading)
        .background(mine ? AnyShapeStyle(theme.accent) : AnyShapeStyle(colors.incoming), in: shape)
        .clipShape(shape)
        .overlay(shape.stroke(mine ? Color.clear : (theme.dark ? Color.white.opacity(0.04) : Color.black.opacity(0.06)), lineWidth: 1))
        .shadow(color: mine ? theme.accentColor.opacity(theme.dark ? 0.25 : 0.22) : Color.black.opacity(theme.dark ? 0 : 0.06),
                radius: mine ? 6 : 2, y: mine ? 2 : 1)
    }

    /// Низ поста канала, как в Telegram: аватарки последних комментаторов, «9 комментариев» и стрелка
    private func commentsBar(_ n: Int, open: @escaping () -> Void) -> some View {
        let tint: Color = mine ? .white : theme.accentColor
        let ring: Color = mine ? theme.accentColor : colors.incoming
        return Button {
            guard !blocked else { return }
            Haptics.select()
            open()
        } label: {
            HStack(spacing: 10) {
                if message.commenters.isEmpty {
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 17))
                        .frame(width: 30, height: 30)
                } else {
                    HStack(spacing: -10) {
                        ForEach(Array(message.commenters.prefix(3).enumerated()), id: \.element.id) { i, p in
                            AvatarView(name: p.name, size: 30, avatarID: p.avatarID)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(ring, lineWidth: 2))
                                .zIndex(Double(3 - i))
                        }
                    }
                }
                Text(n == 0 ? s.t("Прокомментировать", "Leave a comment") : CommentWord.count(n, lang: lang))
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12).frame(height: 48)
            .frame(minWidth: 240, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(mine ? Color.white.opacity(0.22) : (theme.dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)))
                    .frame(height: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func senderColor(_ id: String) -> Color {
        let palette: [Color] = [.orange, .pink, .purple, .teal, .green, .blue, .red, .indigo]
        let sum = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return palette[sum % palette.count]
    }

    @ViewBuilder
    private var menu: some View {
        if !message.isPending {
            Button(action: onReply) { Label(s.reply, systemImage: "arrowshape.turn.up.left") }
            if !message.text.isEmpty && !noForward {
                Button { UIPasteboard.general.string = message.text } label: { Label(s.copy, systemImage: "doc.on.doc") }
            }
            ForEach(message.attachments.filter { ($0.kind == .audio || $0.kind == .file || $0.kind == .voice) && $0.mediaID != nil }) { a in
                Button { Task { _ = await AttachmentExporter.export(a) } } label: {
                    Label(a.kind == .voice ? s.t("Скачать голосовое", "Save voice message")
                                           : s.t("Скачать файл", "Download file"), systemImage: "arrow.down.circle")
                }
            }
            if mine, !message.text.isEmpty || !message.attachments.isEmpty, message.attachments.allSatisfy({ $0.kind != .sticker }) {
                Button(action: onEdit) { Label(s.editMessage, systemImage: "pencil") }
            }
            Button(role: .destructive, action: onDelete) { Label(s.delete, systemImage: "trash") }
        }
    }
}

// MARK: - Цитата-ответ внутри пузыря

struct ReplyQuote: View {
    let reply: ReplyRef
    let mine: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 7) {
            Capsule().fill(mine ? Color.white.opacity(0.85) : theme.accentColor).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                if !reply.name.isEmpty {
                    Text(reply.name).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(mine ? Color.white : theme.accentColor)
                }
                // одна строка с «…»: длинное сообщение не раздувает пузырь ответа
                Text(reply.text.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 13)).lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(mine ? Color.white.opacity(0.88) : theme.textSecondary)
            }
            .frame(maxWidth: 210, alignment: .leading)
        }
        .frame(maxWidth: 230, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Фото и видео в сообщении

struct MediaBlock: View {
    let items: [ChatAttachment]
    var pending = false
    let onOpen: (Int) -> Void

    /// Ширина альбома — как у Telegram, около трёх четвертей экрана
    private var width: CGFloat { min(300, UIScreen.main.bounds.width * 0.76) }
    private let gap: CGFloat = 2
    @AppStorage("autoplay") private var autoplay = true
    @State private var frames = FrameBoxes()

    private func asp(_ i: Int) -> CGFloat {
        let a = CGFloat(items[i].aspect)
        return a > 0 ? min(1.8, max(0.55, a)) : 1
    }

    /// Разбивка на ряды после первых «больших» ячеек: по три в ряд, без одиноких хвостов
    private func rows(_ ids: [Int]) -> [[Int]] {
        var out: [[Int]] = []
        var rest = ids
        while !rest.isEmpty {
            if rest.count == 4 { out.append(Array(rest.prefix(2))); out.append(Array(rest.suffix(2))); break }
            let n = min(3, rest.count)
            out.append(Array(rest.prefix(n)))
            rest.removeFirst(n)
        }
        return out
    }

    private func more(_ i: Int, last: Bool) -> some View {
        cell(items[i], index: i)
            .overlay {
                if last, items.count > 10 {
                    Color.black.opacity(0.5)
                    Text("+\(items.count - 10)").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                }
            }
    }

    private func rowView(_ ids: [Int], height: CGFloat? = nil) -> some View {
        let w = (width - gap * CGFloat(ids.count - 1)) / CGFloat(ids.count)
        let h = height ?? w * (ids.count == 1 ? 0.7 : (ids.count == 2 ? 0.9 : 1))
        return HStack(spacing: gap) {
            ForEach(ids, id: \.self) { i in
                more(i, last: i == 9).frame(width: w, height: h)
            }
        }
    }

    var body: some View {
        Group {
            switch items.count {
            case 1:
                let aspect = min(1.5, max(0.65, CGFloat(items[0].aspect)))
                cell(items[0], index: 0).frame(width: width, height: width / aspect)
            case 2:
                if asp(0) > 1.25 && asp(1) > 1.25 {
                    // две горизонтальные — друг под другом
                    VStack(spacing: gap) {
                        cell(items[0], index: 0).frame(width: width, height: min(width * 0.72, width / asp(0)))
                        cell(items[1], index: 1).frame(width: width, height: min(width * 0.72, width / asp(1)))
                    }
                } else {
                    let w = (width - gap) / 2
                    let h = w / min(1.0, max(0.62, (asp(0) + asp(1)) / 2))
                    HStack(spacing: gap) {
                        cell(items[0], index: 0).frame(width: w, height: h)
                        cell(items[1], index: 1).frame(width: w, height: h)
                    }
                }
            case 3:
                if asp(0) >= 0.95 {
                    VStack(spacing: gap) {
                        cell(items[0], index: 0).frame(width: width, height: min(width * 0.78, width / min(1.6, asp(0))))
                        let w = (width - gap) / 2
                        let h = w / min(1.2, max(0.8, (asp(1) + asp(2)) / 2))
                        HStack(spacing: gap) {
                            cell(items[1], index: 1).frame(width: w, height: h)
                            cell(items[2], index: 2).frame(width: w, height: h)
                        }
                    }
                } else {
                    // вертикальное первое: слева большое, справа два друг под другом
                    let total = width * 1.15
                    let left = width * 0.64
                    let right = width - left - gap
                    HStack(spacing: gap) {
                        cell(items[0], index: 0).frame(width: left, height: total)
                        VStack(spacing: gap) {
                            cell(items[1], index: 1).frame(width: right, height: (total - gap) / 2)
                            cell(items[2], index: 2).frame(width: right, height: (total - gap) / 2)
                        }
                    }
                }
            default:
                let shown = Array(0..<min(items.count, 10))
                VStack(spacing: gap) {
                    if items.count == 4 {
                        // одна большая сверху, три маленьких под ней
                        cell(items[0], index: 0).frame(width: width, height: width / min(1.5, max(1.0, asp(0))))
                        rowView([1, 2, 3])
                    } else {
                        rowView([0, 1], height: (width - gap) / 2 * 1.05)
                        ForEach(Array(rows(Array(shown.dropFirst(2))).enumerated()), id: \.offset) { _, ids in
                            rowView(ids)
                        }
                    }
                }
            }
        }
        .clipped()          // картинка не должна вылезать за свой кадр и налезать на подпись под ней
    }

    private func cell(_ a: ChatAttachment, index: Int) -> some View {
        ZStack {
            if let data = a.localPreview, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let id = a.thumbID ?? a.mediaID {
                RemoteImage(id: id)
            } else {
                Color.gray.opacity(0.3)
            }
            // автовоспроизведение без звука, как в Telegram (настройка «Автовоспроизведение видео»); GIF крутится всегда
            if a.kind == .video, autoplay || a.gif, !pending, a.gif || a.size <= 40 * 1024 * 1024, let video = a.mediaItem {
                InlineVideo(item: video).allowsHitTesting(false)
            }
            if a.kind == .video && a.gif {
                Text("GIF")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.black.opacity(0.45), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(6)
            } else if a.kind == .video {
                if !(autoplay && !pending) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Color.black.opacity(0.45), in: Circle())
                }
                if a.duration > 0 {
                    Text(mmss(Int(a.duration)))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.45), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(6)
                }
            }
            if pending { Color.black.opacity(0.25); TransferRing(progress: nil, icon: "arrow.up", size: 40) }
            if a.kind == .video, !pending, let id = a.mediaID {
                MediaCacheBadge(mediaID: id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(6)
            }
        }
        .clipped()
        .onAppear {
            // видео сразу сохраняется на телефон — потом смотрится и без сети (как в Telegram)
            // очень большие (больше 100 МБ) сами не качаются — сохранятся, когда их откроют
            if a.kind == .video, !pending, let id = a.mediaID, a.size <= 100 * 1024 * 1024, !NetworkState.shared.offline {
                MediaFileCache.shared.prefetch(id)
            }
        }
        .background(FrameProbe(box: frames.box(index)))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !pending else { return }
            // запоминаем, откуда «вылетает» фото, и какая картинка там сейчас видна
            var image: UIImage?
            if let data = a.localPreview { image = UIImage(data: data) }
            else if let id = a.thumbID ?? a.mediaID, let url = ServerConfig.mediaURL(id) { image = ImageCache.shared.cached(url, maxPixel: 1280) }
            HeroSource.shared.set(id: a.mediaID, rect: frames.box(index).rect, image: image)
            onOpen(index)
        }
    }
}

// MARK: - Голосовое сообщение

struct VoiceBlock: View {
    let attachment: ChatAttachment
    let mine: Bool
    var pending = false
    var metaSpace = false           // время сообщения лежит поверх нижнего правого угла

    @ObservedObject private var player = VoicePlayer.shared
    @ObservedObject private var transcriber = VoiceTranscriber.shared
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    private var playerID: String { attachment.mediaID ?? attachment.id }
    private var isCurrent: Bool { player.isCurrent(playerID) }
    private var playing: Bool { isCurrent && player.isPlaying }
    private var progress: Double { isCurrent ? player.progress : 0 }

    var body: some View {
        let tint = mine ? Color.white : theme.accentColor
        VStack(alignment: .leading, spacing: 6) {
            playerRow(tint: tint)
            transcript(tint: tint)
        }
        .frame(width: 218, alignment: .leading)
        .onAppear {
            // голосовое сохраняется на телефон — слушается и без сети
            if let id = attachment.mediaID, !NetworkState.shared.offline { MediaFileCache.shared.prefetch(id, fallback: "m4a") }
        }
    }

    @ViewBuilder
    private func transcript(tint: Color) -> some View {
        if let id = attachment.mediaID, let state = transcriber.state(id) {
            Group {
                switch state {
                case .working:
                    HStack(spacing: 6) {
                        SpinnerRing(size: 12, lineWidth: 1.6, color: tint)
                        Text(Strings(lang: lang).t("Расшифровываю…", "Transcribing…")).font(.system(size: 13))
                    }
                case .done(let text):
                    Text(text).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .failed(let reason):
                    Text(reason).font(.system(size: 13)).opacity(0.85)
                }
            }
            .foregroundStyle(mine ? Color.white : theme.text)
            .padding(.bottom, metaSpace ? 14 : 0)
            .transition(.opacity)
        }
    }

    private func playerRow(tint: Color) -> some View {
        HStack(spacing: 10) {
            Button {
                // зажали голосовое ради реакций — отпускание пальца не должно его включать
                guard !MessageMenu.isOpen, let mediaID = attachment.mediaID else { return }
                player.toggle(id: playerID, mediaID: mediaID, duration: attachment.duration)
            } label: {
                ZStack {
                    Circle().fill(mine ? Color.white : theme.accentColor)
                    if pending {
                        SpinnerRing(size: 24, lineWidth: 2.2, color: mine ? theme.accentColor : .white)
                    } else {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(mine ? theme.accentColor : Color.white)
                    }
                }
                .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Waveform(samples: attachment.waveform, progress: progress, active: tint,
                         inactive: tint.opacity(mine ? 0.42 : 0.28))
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
                HStack(spacing: 6) {
                    let shown = isCurrent && progress > 0 ? attachment.duration * progress : attachment.duration
                    Text(mmss(Int(shown.rounded(.down))))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(mine ? Color.white.opacity(0.8) : theme.textTertiary)
                    if isCurrent {
                        // скорость прямо в пузыре: 1× → 1.5× → 2×, запоминается для всех голосовых
                        Button {
                            Haptics.select()
                            player.cycleRate()
                        } label: {
                            Text(player.rate == 1 ? "1×" : (player.rate == 1.5 ? "1.5×" : "2×"))
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(mine ? theme.accentColor : Color.white)
                                .padding(.horizontal, 6).frame(height: 16)
                                .background(mine ? Color.white : theme.accentColor, in: Capsule())
                                .padding(6).contentShape(Rectangle()).padding(-6)
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                    }
                    if !pending, let id = attachment.mediaID {
                        Button {
                            Haptics.impact(.light)
                            withAnimation(.easeOut(duration: 0.2)) { transcriber.toggle(mediaID: id, lang: lang) }
                        } label: {
                            Image(systemName: "text.alignleft").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(mine ? theme.accentColor : Color.white)
                                .frame(width: 24, height: 16)
                                .background(mine ? Color.white : theme.accentColor, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Невысокая «полоска громкости» на всю ширину: столбики подгоняются под доступную ширину
struct Waveform: View {
    let samples: [Int]
    let progress: Double
    let active: Color
    let inactive: Color

    var body: some View {
        Canvas { context, size in
            let barWidth: CGFloat = 2.5, gap: CGFloat = 2
            let count = max(8, Int((size.width + gap) / (barWidth + gap)))
            let source = samples.isEmpty ? Array(repeating: 6, count: 36) : samples
            for i in 0..<count {
                let lo = i * source.count / count
                let hi = max(lo + 1, (i + 1) * source.count / count)
                let slice = source[lo..<min(hi, source.count)]
                let value = CGFloat(slice.max() ?? 6)
                let h = max(3, min(size.height, 3 + value / 31 * (size.height - 3)))
                let x = CGFloat(i) * (barWidth + gap)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                let played = Double(i) / Double(count) < progress
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(played ? active : inactive))
            }
        }
    }
}

// MARK: - Файл

struct FileBlock: View {
    let attachment: ChatAttachment
    let mine: Bool
    var pending = false
    let onTap: () -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var downloads = DownloadCenter.shared
    private var dl: Double? { attachment.mediaID.flatMap { downloads.progress[$0] } }

    /// «7,2 Кб», «1,4 Мб» — как в Telegram
    private var sizeText: String {
        let n = Double(attachment.size)
        guard n > 0 else { return "" }
        func f(_ v: Double, _ unit: String) -> String {
            let r = (v * 10).rounded() / 10
            let t = r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r).replacingOccurrences(of: ".", with: ",")
            return t + " " + unit
        }
        if n < 1024 { return "\(Int(n)) Б" }
        if n < 1024 * 1024 { return f(n / 1024, "Кб") }
        if n < 1024 * 1024 * 1024 { return f(n / 1024 / 1024, "Мб") }
        return f(n / 1024 / 1024 / 1024, "Гб")
    }

    private var ext: String {
        let name = attachment.name ?? ""
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        let e = String(name[name.index(after: dot)...])
        return e.count <= 5 ? e.uppercased() : ""
    }

    private var fg: Color { mine ? Color.white : theme.text }
    private var sub: Color { mine ? Color.white.opacity(0.72) : theme.textTertiary }
    private var disc: Color { mine ? Color.white : theme.accentColor }
    private var onDisc: Color { mine ? theme.accentColor : Color.white }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(disc)
                    if pending {
                        TransferRing(progress: nil, icon: "arrow.up", size: 52, tint: onDisc, track: onDisc.opacity(0.25))
                    } else if let p = dl {
                        TransferRing(progress: p, icon: "xmark", size: 52, tint: onDisc, track: onDisc.opacity(0.25))
                    } else {
                        Image(systemName: "doc.fill").font(.system(size: 23, weight: .regular))
                            .foregroundStyle(onDisc)
                    }
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(attachment.name ?? "Файл")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(fg)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                    Group {
                        if let p = dl {
                            Text("\(Int(p * 100))% · \(sizeText)").monospacedDigit()
                        } else if pending {
                            Text(sizeText.isEmpty ? "Отправка…" : "Отправка · \(sizeText)")
                        } else {
                            Text([sizeText, ext].filter { !$0.isEmpty }.joined(separator: " · "))
                        }
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(sub)
                    .lineLimit(1)
                    .padding(.trailing, 44)       // под время сообщения
                }
                Spacer(minLength: 0)
            }
            .frame(width: 244)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - «Кружок»: круглое видеосообщение

/// Какой кружок играет сейчас: он один на всё приложение (голосовые, музыка и другие кружки при этом молчат)
@MainActor
final class CircleFocus: ObservableObject {
    static let shared = CircleFocus()
    @Published var current: CirclePlayback?
    func stop() { current?.stop() }

    /// Плеер кружка живёт здесь, а не во вью: следующий кружок может включиться сам, даже если он ещё не на экране
    private var pool: [String: CirclePlayback] = [:]
    func playback(for key: String) -> CirclePlayback {
        if let p = pool[key] { return p }
        if pool.count > 40 { pool = pool.filter { $0.value.player != nil } }
        let p = CirclePlayback()
        pool[key] = p
        return p
    }
}

@MainActor
final class CirclePlayback: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var started = false
    @Published private(set) var progress = 0.0
    private(set) var player: AVPlayer?
    private(set) var duration = 0.0
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    private var rate: Float { VoicePlayer.shared.rate }

    /// Включить с начала, если не играет (автопереход от предыдущего голосового или кружка)
    func start(mediaID: String, duration: Double) {
        if !isPlaying { toggle(mediaID: mediaID, duration: duration) }
    }

    func toggle(mediaID: String, duration: Double) {
        if player == nil {
            guard let url = MediaFileCache.shared.playableURL(mediaID) else { return }      // скачан — с телефона, без сети тоже
            // одновременно звучит что-то одно
            CircleFocus.shared.current?.stop()
            VoicePlayer.shared.stop()
            VoicePlayer.shared.onStart?()
            self.duration = duration
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            AudioSessionGate.willActivate()
            try? AVAudioSession.sharedInstance().setActive(true)
            let item = AVPlayerItem(url: url)
            let p = AVPlayer(playerItem: item)
            player = p
            observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
                Task { @MainActor in
                    guard let self, duration > 0 else { return }
                    self.progress = min(1, time.seconds / duration)
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                                 queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.stop()
                    VoicePlayer.shared.playNext(after: mediaID)          // досмотрели — следующее голосовое или кружок
                }
            }
            CircleFocus.shared.current = self
        }
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.rate = rate
            isPlaying = true
            started = true
        }
    }

    func resume() { guard let player else { return }; player.rate = rate; isPlaying = true; started = true }
    func pause() { player?.pause(); isPlaying = false }
    func applyRate() { if isPlaying { player?.rate = rate } }

    func seek(toFraction f: Double) {
        let fraction = max(0, min(1, f))
        progress = fraction
        player?.seek(to: CMTime(seconds: fraction * duration, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        if let observer, let player { player.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        observer = nil
        endObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        started = false
        progress = 0
        if CircleFocus.shared.current === self { CircleFocus.shared.current = nil }
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}

struct CircleVideoBubble: View {
    let attachment: ChatAttachment
    let message: ChatMessage
    var size: CGFloat = 214

    var body: some View {
        CircleVideoContent(attachment: attachment, message: message, size: size,
                           playback: CircleFocus.shared.playback(for: attachment.mediaID ?? attachment.id))
    }
}

private struct CircleVideoContent: View {
    let attachment: ChatAttachment
    let message: ChatMessage
    var size: CGFloat

    @ObservedObject var playback: CirclePlayback
    @Environment(\.mediaFrozen) private var frozen
    /// Пока кружок смотрят, он вырастает (как в Telegram)
    private var shown: CGFloat { playback.started ? max(size, min(300, UIScreen.main.bounds.width - 70)) : size }
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var callToast = false

    var body: some View {
        ZStack {
            if let data = attachment.localPreview, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let id = attachment.thumbID {
                RemoteImage(id: id)
            } else {
                theme.surface
            }
            Color.clear.onAppear {
                // кружок сохраняется на телефон — смотрится и без сети
                if let id = attachment.mediaID, !message.isPending, !NetworkState.shared.offline { MediaFileCache.shared.prefetch(id) }
            }

            if playback.started, let player = playback.player, !frozen {
                PlayerLayerView(player: player)
            }

            if message.isPending {
                Color.black.opacity(0.25)
                TransferRing(progress: nil, icon: "arrow.up", size: 52)
            } else if !playback.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.black.opacity(0.4), in: Circle())
            }
        }
        .frame(width: shown, height: shown)
        .clipShape(Circle())
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: playback.started)
        .overlay(Circle().trim(from: 0, to: playback.progress).stroke(theme.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .rotationEffect(.degrees(-90)).padding(2))
        .overlay(alignment: .bottomLeading) {
            Text(mmss(Int(attachment.duration)))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.black.opacity(0.45), in: Capsule())
                .padding(.leading, 10).padding(.bottom, 12)
        }
        .overlay(alignment: .bottomTrailing) {
            MessageMeta(message: message, color: .white, onMedia: true).padding(.trailing, 14).padding(.bottom, 12)
        }
        .overlay { if callToast { Text(CallGate.message(lang)).font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center).foregroundStyle(.white).padding(10).background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12)).padding(14) } }
        .contentShape(Circle())
        .onTapGesture {
            // зажали кружок ради реакций — отпускание пальца не должно его включать
            guard !MessageMenu.isOpen, !message.isPending, let id = attachment.mediaID else { return }
            if CallGate.busy {
                callToast = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { callToast = false }
                return
            }
            playback.toggle(mediaID: id, duration: attachment.duration)
        }
    }
}

// MARK: - Просмотр файла (QuickLook)

struct PreviewFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

enum FileDownloader {
    /// Скачивает файл из сообщения во временную папку под его настоящим именем
    static func download(mediaID: String, name: String) async -> URL? {
        guard let remote = ServerConfig.mediaURL(mediaID) else { return nil }
        do {
            await MainActor.run { DownloadCenter.shared.set(mediaID, 0) }
            defer { Task { @MainActor in DownloadCenter.shared.set(mediaID, nil) } }
            let (temp, _) = try await URLSession.shared.download(from: remote, delegate: DownloadProgressDelegate(id: mediaID))
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safe = name.replacingOccurrences(of: "/", with: "_")
            let target = folder.appendingPathComponent(safe.isEmpty ? "file" : safe)
            try FileManager.default.moveItem(at: temp, to: target)
            return target
        } catch {
            return nil
        }
    }
}


// MARK: - Удаление: сообщение рассыпается на частицы, как в Telegram

extension View {
    /// Пока сообщение рассыпается, сама строка скрыта: частицы рисует MessageDust в своём окне поверх чата
    func dustDissolve(active: Bool) -> some View { opacity(active ? 0 : 1) }
}

/// Сообщение рассыпается на частицы своих же цветов — как «материя» в Telegram.
/// Снимок экрана на месте сообщения → сообщение прячется → второй снимок: где пиксели отличаются, там и было
/// сообщение (обои и пустое место вокруг пузыря не рассыпаются). Частицы летят в отдельном прозрачном окне,
/// поэтому строку сразу убирают из списка и соседние сообщения съезжают, пока пыль ещё в воздухе
@MainActor
enum MessageDust {
    private static var window: UIWindow?

    private final class PassThroughWindow: UIWindow {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }

    private static var host: UIWindow? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first { $0.isKeyWindow && !($0 is PassThroughWindow) }
            ?? windows.first { $0.windowLevel == .normal && !($0 is PassThroughWindow) }
    }

    /// `frames` — где сообщения стоят на экране; `hide` прячет их (строки перестают рисоваться)
    static func burst(_ frames: [CGRect], hide: () -> Void) async {
        guard let host, let scene = host.windowScene else { hide(); return }
        let rects = frames.map { $0.intersection(host.bounds) }.filter { !$0.isNull && $0.width > 4 && $0.height > 4 }
        guard !rects.isEmpty else { hide(); return }
        let scale = min(host.screen.scale, 2)
        let before = rects.map { (sharp: snapshot(host, $0, scale: scale), small: snapshot(host, $0, scale: 1)) }
        let overlay = window ?? {
            let w = PassThroughWindow(windowScene: scene)
            w.windowLevel = host.windowLevel + 1
            w.backgroundColor = .clear
            w.isUserInteractionEnabled = false
            w.isHidden = false
            window = w
            return w
        }()
        // сначала поверх кладём неподвижный снимок — подмены не видно, пока строка прячется
        let views = zip(rects, before).map { rect, shot -> DustView in
            let v = DustView(rect: rect, image: shot.sharp)
            overlay.addSubview(v)
            return v
        }
        hide()
        try? await Task.sleep(nanoseconds: 60_000_000)          // SwiftUI успевает перерисовать список без строки
        for (i, rect) in rects.enumerated() {
            views[i].start(with: before[i].small, without: snapshot(host, rect, scale: 1)) { finished(views[i]) }
        }
    }

    private static func finished(_ view: UIView) {
        view.removeFromSuperview()
        if window?.subviews.isEmpty == true {
            window?.isHidden = true
            window = nil
        }
    }

    private static func snapshot(_ window: UIWindow, _ rect: CGRect, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(bounds: rect, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }
}

/// Частицы одного сообщения: рисуются раз в кадр (CADisplayLink), до ~4000 штук
private final class DustView: UIView {
    static let pad: CGFloat = 150                       // частицы разлетаются за края сообщения

    private struct Particle {
        let x: CGFloat, y: CGFloat                      // где была в сообщении (pt от его угла)
        let vx: CGFloat, vy: CGFloat
        let delay: Double, life: Double
        let size: CGFloat
        let color: CGColor
        let wave: Double                                // положение на «волне» разрушения, 0…1
        let phase: CGFloat                              // покачивание в полёте — у каждой своё
    }

    private var image: UIImage
    private let contentRect: CGRect
    private var particles: [Particle] = []
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var endTime: Double = 0
    private var onDone: (() -> Void)?
    /// За сколько волна проходит всё сообщение (слева сверху → вправо вниз)
    private let sweep: Double = 0.62

    init(rect: CGRect, image: UIImage) {
        self.image = image
        contentRect = CGRect(x: Self.pad, y: Self.pad, width: rect.width, height: rect.height)
        super.init(frame: rect.insetBy(dx: -Self.pad, dy: -Self.pad))
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        layer.contentsScale = min(UIScreen.main.scale, 2)
        setNeedsDisplay()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Волна: левый край отрывается первым, верх чуть раньше низа
    private static func wave(_ nx: CGFloat, _ ny: CGFloat) -> Double { Double(0.8 * nx + 0.2 * ny) }

    func start(with before: UIImage, without after: UIImage, done: @escaping () -> Void) {
        onDone = done
        guard let a = before.cgImage, let b = after.cgImage, let pa = Self.pixels(a), let pb = Self.pixels(b, width: a.width, height: a.height) else {
            done(); return
        }
        let w = a.width, h = a.height
        // где сообщение: пиксели, которые изменились, когда его спрятали
        var mask = [Bool](repeating: false, count: w * h)
        var count = 0
        for i in 0..<(w * h) {
            let o = i * 4
            let d = abs(Int(pa[o]) - Int(pb[o])) + abs(Int(pa[o + 1]) - Int(pb[o + 1])) + abs(Int(pa[o + 2]) - Int(pb[o + 2]))
            if d > 18 { mask[i] = true; count += 1 }
        }
        guard count > 0 else { done(); return }
        // частицы: клетки 2 pt и крупнее, если сообщение большое; цвет — средний цвет сообщения в клетке
        let cell = max(2, Int((Double(count) / 4000).squareRoot().rounded(.up)))
        let sx = contentRect.width / CGFloat(w), sy = contentRect.height / CGFloat(h)
        var list: [Particle] = []
        list.reserveCapacity(min(6000, count / (cell * cell) + 16))
        var y0 = 0
        while y0 < h {
            var x0 = 0
            while x0 < w {
                var n = 0, r = 0, g = 0, bl = 0, al = 0
                for y in y0..<min(h, y0 + cell) {
                    for x in x0..<min(w, x0 + cell) where mask[y * w + x] {
                        let o = (y * w + x) * 4
                        r += Int(pa[o]); g += Int(pa[o + 1]); bl += Int(pa[o + 2]); al += Int(pa[o + 3]); n += 1
                    }
                }
                if n * 3 >= cell * cell {
                    let alpha = CGFloat(al) / CGFloat(n * 255)
                    let k = alpha > 0 ? 1 / (CGFloat(n) * 255 * alpha) : 0      // пиксели снимка — с умноженной прозрачностью
                    let color = CGColor(srgbRed: CGFloat(r) * k, green: CGFloat(g) * k, blue: CGFloat(bl) * k, alpha: alpha)
                    let px = (CGFloat(x0) + CGFloat(cell) / 2) * sx, py = (CGFloat(y0) + CGFloat(cell) / 2) * sy
                    let wv = Self.wave(px / contentRect.width, py / contentRect.height)
                    let r1 = CGFloat.random(in: 0...1), r2 = CGFloat.random(in: 0...1)
                    list.append(Particle(x: px, y: py,
                                         vx: -20 + 115 * r1 * r1,              // в основном вправо, часть — влево
                                         vy: -(20 + 80 * r2),                  // и вверх
                                         delay: sweep * (0.85 * wv + 0.15 * Double.random(in: 0...1)),
                                         life: Double.random(in: 0.75...1.25),
                                         size: CGFloat(cell) * sx * CGFloat.random(in: 0.8...1.15),
                                         color: color, wave: wv, phase: CGFloat.random(in: 0...(2 * .pi))))
                }
                x0 += cell
            }
            y0 += cell
        }
        particles = list
        endTime = (list.map { $0.delay + $0.life }.max() ?? 0) + 0.05
        image = Self.masked(image, mask: mask, width: w, height: h)
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)     // на 120 Гц — плавнее
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        if CACurrentMediaTime() - startTime > endTime {
            link?.invalidate()
            link = nil
            onDone?()
            onDone = nil
            return
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        guard link != nil else { image.draw(in: contentRect); return }       // ещё не рассыпается — неподвижный снимок
        let t = CACurrentMediaTime() - startTime
        // нетронутая часть: всё, до чего волна точно не дошла, рисуется самим снимком (чётко, без «пикселей»)
        let front = t / (0.85 * sweep)
        if front < 1 {
            let w = contentRect.width
            let topX = CGFloat(front / 0.8) * w, bottomX = CGFloat((front - 0.2) / 0.8) * w
            ctx.saveGState()
            ctx.beginPath()
            ctx.move(to: CGPoint(x: contentRect.minX + max(0, topX), y: contentRect.minY - 1))
            ctx.addLine(to: CGPoint(x: contentRect.maxX + 1, y: contentRect.minY - 1))
            ctx.addLine(to: CGPoint(x: contentRect.maxX + 1, y: contentRect.maxY + 1))
            ctx.addLine(to: CGPoint(x: contentRect.minX + max(0, bottomX), y: contentRect.maxY + 1))
            ctx.closePath()
            ctx.clip()
            image.draw(in: contentRect)
            ctx.restoreGState()
        }
        for p in particles {
            if t < p.delay {
                // на волне, но ещё не оторвалась — стоит на месте
                guard p.wave < front else { continue }
                ctx.setAlpha(1)
                ctx.setFillColor(p.color)
                ctx.fill(CGRect(x: contentRect.minX + p.x - p.size / 2, y: contentRect.minY + p.y - p.size / 2, width: p.size, height: p.size))
                continue
            }
            let age = t - p.delay
            guard age < p.life else { continue }
            let k = age / p.life
            let a = CGFloat(age)
            // отрывается мягко: сначала почти на месте, потом разгоняется ветром вправо-вверх (без рывка на старте)
            let go = a * a / (a + 0.22)
            let sway = sin(a * 7 + p.phase) * 3 * min(1, a * 4)
            let x = contentRect.minX + p.x + p.vx * go + 50 * go * go + sway
            let y = contentRect.minY + p.y + p.vy * go - 32 * go * go
            // чуть «вспухает» в момент отрыва, потом плавно уменьшается и тает
            let d = p.size * CGFloat((1 + 0.18 * sin(min(1, k * 5) * .pi)) * (1 - 0.6 * k))
            let fade = max(0, min(1, (k - 0.3) / 0.7))
            ctx.setAlpha(CGFloat(1 - fade * fade * (3 - 2 * fade)))
            ctx.setFillColor(p.color)
            ctx.fill(CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d))
        }
    }

    /// RGBA, 8 бит на канал, с умноженной прозрачностью — в заданном размере
    private static func pixels(_ image: CGImage, width: Int? = nil, height: Int? = nil) -> [UInt8]? {
        let w = width ?? image.width, h = height ?? image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? data : nil
    }

    /// Чёткий снимок, в котором оставлено только сообщение (без обоев вокруг пузыря)
    private static func masked(_ image: UIImage, mask: [Bool], width: Int, height: Int) -> UIImage {
        var alpha = mask.map { $0 ? UInt8(255) : 0 }
        guard let provider = CGDataProvider(data: Data(bytes: &alpha, count: alpha.count) as CFData),
              let maskImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { r in
            let ctx = r.cgContext
            let rect = CGRect(origin: .zero, size: image.size)
            // маска в CGContext перевёрнута относительно UIKit
            ctx.saveGState()
            ctx.translateBy(x: 0, y: rect.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.clip(to: rect, mask: maskImage)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: 0, y: -rect.height)
            image.draw(in: rect)
            ctx.restoreGState()
        }
    }
}

/// Уголок превью видео: идёт скачивание на телефон — кольцо прогресса; нет сети и видео не скачано — значок «скачать»
struct MediaCacheBadge: View {
    let mediaID: String
    @ObservedObject private var downloads = DownloadCenter.shared
    @ObservedObject private var network = NetworkState.shared

    var body: some View {
        if let p = downloads.progress[mediaID] {
            TransferRing(progress: p, icon: "arrow.down", size: 26)
                .background(Circle().fill(Color.black.opacity(0.45)))
        } else if network.offline, MediaFileCache.shared.cached(mediaID) == nil {
            Image(systemName: "arrow.down")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.black.opacity(0.45)))
        }
    }
}

extension ChatAttachment {
    /// Стикер из вложения: встроенный — по id, свой — с файлом (картинка или анимированное видео)
    var asSticker: Sticker {
        Sticker(id: sticker ?? "", emoji: "", mediaID: mediaID, animated: (mime ?? "").hasPrefix("video"), packID: stickerPack)
    }
}

/// Свой стикерпак: что внутри, «Добавить набор» / «Убрать набор»
struct StickerPackSheet: View {
    let packID: String
    let repo: MessengerRepository
    var onChanged: () -> Void = {}
    var onSend: ((Sticker) -> Void)? = nil

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss
    @State private var pack: CustomStickerPack?
    @State private var failed = false
    @State private var busy = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 14) {
            if let pack {
                Text(pack.pack.title).font(.system(size: 18, weight: .bold)).foregroundStyle(theme.text).padding(.top, 20)
                Text(s.t("\(pack.pack.stickers.count) стикеров", "\(pack.pack.stickers.count) stickers"))
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(pack.pack.stickers) { st in
                            Button {
                                guard let onSend else { return }
                                Haptics.impact(.light); onSend(st); dismiss()
                            } label: {
                                StickerImage(sticker: st, size: 74).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                Button { toggle() } label: {
                    Group {
                        if busy { ProgressView().tint(.white) }
                        else {
                            Text(pack.installed ? s.t("Убрать набор", "Remove pack") : s.t("Добавить набор", "Add pack"))
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .foregroundStyle(pack.installed ? theme.danger : Color.white)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(pack.installed ? AnyShapeStyle(theme.danger.opacity(0.12)) : AnyShapeStyle(theme.accent), in: Capsule())
                }
                .buttonStyle(PressStyle()).disabled(busy)
                .padding(.horizontal, 16).padding(.bottom, 12)
                .animation(.easeOut(duration: 0.2), value: pack.installed)
            } else if failed {
                Text(s.t("Не удалось загрузить набор", "Couldn't load the pack"))
                    .font(.system(size: 15)).foregroundStyle(theme.textSecondary).frame(maxHeight: .infinity)
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .task {
            do { pack = try await repo.stickerPack(id: packID) } catch { failed = true }
        }
    }

    private func toggle() {
        guard let current = pack else { return }
        busy = true
        Task {
            if let updated = try? await repo.setStickerPack(id: packID, installed: !current.installed) {
                pack = updated
                Haptics.notify(.success)
                onChanged()
            } else {
                Haptics.notify(.error)
            }
            busy = false
        }
    }
}


/// Карточка того, что нажали в тексте: номер (страна и аккаунт, если человек разрешил находить себя по номеру),
/// карта (платёжная система и банк), криптоадрес (сеть) или @юзернейм
struct EntityInfoSheet: View {
    let entity: ChatEntity
    var onOpenProfile: (String) -> Void = { _ in }

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var account: UserProfile?
    @State private var searching = false
    @State private var copied = false

    private var s: Strings { Strings(lang: lang) }

    private var title: String {
        switch entity.kind {
        case .phone: return "+" + ChatEntityInfo.international(entity.value)
        case .card: return ChatEntityInfo.grouped(entity.value)
        case .crypto, .username: return entity.value
        }
    }

    private var subtitle: String {
        switch entity.kind {
        case .phone: return ChatEntityInfo.phone(entity.value, lang: lang)
        case .card: return ChatEntityInfo.card(entity.value, lang: lang)
        case .crypto: return s.t("Криптоадрес · ", "Crypto address · ") + ChatEntityInfo.crypto(entity.value).network
        case .username: return s.t("Имя пользователя", "Username")
        }
    }

    private var icon: String {
        switch entity.kind {
        case .phone: return "phone.fill"
        case .card: return "creditcard.fill"
        case .crypto: return "bitcoinsign.circle.fill"
        case .username: return "at"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 54, height: 54).background(theme.accent, in: Circle())
                .padding(.top, 22)
            VStack(spacing: 4) {
                Text(title).font(.system(size: entity.kind == .crypto ? 15 : 20, weight: .bold, design: entity.kind == .crypto ? .monospaced : .default))
                    .foregroundStyle(theme.text).multilineTextAlignment(.center).textSelection(.enabled)
                Text(subtitle).font(.system(size: 14)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)

            if entity.kind == .phone || entity.kind == .username { accountCard }

            VStack(spacing: 0) {
                switch entity.kind {
                case .phone:
                    if let tel = URL(string: "tel:+" + ChatEntityInfo.international(entity.value)) {
                        action("phone", s.t("Позвонить", "Call")) { dismiss(); openURL(tel) }
                    }
                    action("doc.on.doc", copied ? s.t("Скопировано", "Copied") : s.t("Скопировать номер", "Copy number")) { copy(title) }
                case .card:
                    action("doc.on.doc", copied ? s.t("Скопировано", "Copied") : s.t("Скопировать номер карты", "Copy card number")) { copy(entity.value) }
                case .crypto:
                    if let explorer = ChatEntityInfo.crypto(entity.value).explorer {
                        action("safari", s.t("Открыть в обозревателе", "Open in explorer")) { dismiss(); openURL(explorer) }
                    }
                    action("doc.on.doc", copied ? s.t("Скопировано", "Copied") : s.t("Скопировать адрес", "Copy address")) { copy(entity.value) }
                case .username:
                    action("doc.on.doc", copied ? s.t("Скопировано", "Copied") : s.t("Скопировать", "Copy")) { copy(entity.value) }
                }
            }
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 16)
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: account?.id)
        .task { await find() }
    }

    @ViewBuilder private var accountCard: some View {
        if let account {
            HStack(spacing: 12) {
                AvatarView(name: account.name, size: 46, avatarID: account.avatarID)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                    Text(account.username.map { "@" + $0 } ?? s.t("в Orbita", "on Orbita"))
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    Haptics.impact(.light)
                    let peer = ChatPeer(id: account.id, name: account.name, username: account.username, avatarID: account.avatarID)
                    dismiss()
                    PushManager.shared.openChat = ChatRoute(peer: peer)
                } label: {
                    Text(s.t("Написать", "Message")).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 34).background(theme.accent, in: Capsule())
                }
                .buttonStyle(PressStyle())
            }
            .padding(12)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { let id = account.id; dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onOpenProfile(id) } }
            .padding(.horizontal, 16)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else if searching {
            ProgressView().frame(height: 70)
        } else if entity.kind == .username {
            Text(s.t("Такого пользователя нет", "No such user")).font(.system(size: 13)).foregroundStyle(theme.textTertiary)
        }
    }

    private func action(_ systemImage: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.system(size: 17)).foregroundStyle(theme.accentColor).frame(width: 24)
                Text(title).font(.system(size: 16)).foregroundStyle(theme.text)
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        Haptics.notify(.success)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
    }

    /// Аккаунт по номеру ищется только у тех, кто не запретил находить себя по номеру (проверяет сервер)
    private func find() async {
        guard entity.kind == .phone || entity.kind == .username else { return }
        searching = true
        defer { searching = false }
        let found: UserProfile?
        if entity.kind == .phone {
            found = try? await session.profileRepo.lookup(phone: "+" + ChatEntityInfo.international(entity.value))
        } else {
            found = try? await session.profileRepo.lookup(username: String(entity.value.drop(while: { $0 == "@" })))
        }
        account = found
    }
}
