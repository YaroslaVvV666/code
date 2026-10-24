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

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var dragX: CGFloat = 0
    @State private var longFired = false         // после зажатия (меню открылось) отпускание пальца не должно открывать фото/файл
    /// Палец лежит на сообщении: пузырь чуть сжимается ещё до срабатывания зажатия — отклик сразу, а не через 0.25 с.
    /// Только визуально: порог и допуск жеста те же, прокрутку это не перехватывает
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.3, dampingFraction: 0.7)))
    private var pressing = false

    private var s: Strings { Strings(lang: lang) }
    private var colors: ChatColors { ChatColors(theme: theme) }
    private var mine: Bool { message.mine }

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
                .scaleEffect(pressing && interactive && !message.isPending ? 0.96 : 1, anchor: mine ? .trailing : .leading)
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
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if interactive, !message.isPending { onReact?("\u{2764}\u{FE0F}") }
        })
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.25, maximumDistance: 8)
            .updating($pressing) { value, state, tx in
                state = value
                if value && interactive { Haptics.prepare(.medium) }
                // короткое касание в начале прокрутки почти не успевает сжать пузырь — небольшая задержка и плавный вход
                tx.animation = .easeOut(duration: 0.22).delay(0.05)
            }
            .onEnded { _ in
                if interactive, !message.isPending, let onLongPress {
                    longFired = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { longFired = false }
                    Haptics.impact(.medium); onLongPress()
                }
            })
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.6 else { return }
                    dragX = max(-80, min(0, value.translation.width))
                }
                .onEnded { value in
                    if dragX <= -56 {
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
            guard interactive, let onCallBack else { return }
            Haptics.impact(.medium)
            onCallBack(info.video)
        }
    }

    private var reactionChips: some View {
        HStack(spacing: 4) {
            ForEach(message.reactions, id: \.emoji) { r in
                Button { if interactive { onReact?(r.emoji) } } label: {
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
                    if interactive { Haptics.impact(.medium); onReactionInfo?() }
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
                StickerImage(sticker: Sticker(id: sticker.sticker ?? "", emoji: ""), size: 168)
                MessageMeta(message: message, color: .white, onMedia: true).padding(6)
            }
        } else if let circle = circleOnly {
            CircleVideoBubble(attachment: circle, message: message)
            } else if emojiOnly {
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                let value = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.count == 1 {
                    // одно эмодзи — анимированное: 5 секунд крутится, по нажатию снова
                    TimedLottieEmoji(emoji: value, size: emojiSize * 1.25)
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
        // место под время/галочки/просмотры: оценка ширины в «узких пробелах» (по 8 пт), чтобы не оставалось лишнего отступа
        let metaWidth: CGFloat = 32 + (mine ? 16 : 0) + (message.editedAt != nil ? 44 : 0)
            + (message.views.map { v -> CGFloat in
                // глаз + число + «·» + три зазора; число считаем так же, как рисует MessageMeta
                let text = v >= 1000 ? String(format: "%.1fK", Double(v) / 1000) : "\(v)"
                return 30 + CGFloat(text.count) * 6.8
            } ?? 0) + 12
        let filler = String(repeating: "\u{2007}", count: Int((metaWidth / 8.5).rounded(.up)))  // неразрывные: хвост не «висит» и время не наезжает на последнюю строку

        return VStack(alignment: .leading, spacing: 0) {
            if showSender, !mine, isFirst, let sender = message.sender {
                Text(sender.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(senderColor(sender.id))
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .padding(.top, 6)
                    .onTapGesture { onOpenProfile?(sender.id) }
            }
            if let fwd = message.forwarded, !fwd.name.isEmpty {
                Button {
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
                Button { Haptics.impact(.light); onOpenStory?(story.id) } label: {
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
                    .onTapGesture { Haptics.impact(.light); onJumpToReply?(reply.id) }
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
                    if longFired { return }
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
                    case .audio: AudioBlock(attachment: a, mine: mine, pending: message.isPending) { if !longFired { onPlayAudio(a) } }
                    case .file:
                        if a.isMusic {
                            AudioBlock(attachment: a, mine: mine) { if !longFired { onPlayAudio(a) } }
                        } else {
                            FileBlock(attachment: a, mine: mine, pending: message.isPending) { if !longFired { onOpenFile(a) } }
                        }
                    case .circle: CircleVideoBubble(attachment: a, message: message, size: 180)
                    default: StickerImage(sticker: Sticker(id: a.sticker ?? "", emoji: ""), size: 120)
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
                               color: textColor, linkColor: mine ? .white : theme.accentColor, filler: filler)
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
                Button(action: open) {
                    HStack(spacing: 8) {
                        Image(systemName: "bubble.left").font(.system(size: 14, weight: .semibold))
                        Text(n == 0 ? s.t("Оставить комментарий", "Leave a comment")
                                    : s.t("Комментарии: \(n)", "\(n) comments"))
                            .font(.system(size: 15, weight: .semibold))
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(theme.accentColor)
                    .padding(.horizontal, 12).frame(height: 38)
                    .frame(minWidth: 210, alignment: .leading)
                    .background(theme.accentColor.opacity(0.10))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 56, alignment: .leading)
        .background(mine ? AnyShapeStyle(theme.accent) : AnyShapeStyle(colors.incoming), in: shape)
        .clipShape(shape)
        .overlay(shape.stroke(mine ? Color.clear : (theme.dark ? Color.white.opacity(0.04) : Color.black.opacity(0.06)), lineWidth: 1))
        .shadow(color: mine ? theme.accentColor.opacity(theme.dark ? 0.25 : 0.22) : Color.black.opacity(theme.dark ? 0 : 0.06),
                radius: mine ? 6 : 2, y: mine ? 2 : 1)
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
            // автовоспроизведение без звука, как в Telegram (настройка «Автовоспроизведение видео»)
            if a.kind == .video, autoplay, !pending, a.size <= 40 * 1024 * 1024, let video = a.mediaItem {
                InlineVideo(item: video).allowsHitTesting(false)
            }
            if a.kind == .video {
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
        }
        .clipped()
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
                guard let mediaID = attachment.mediaID else { return }
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
                    if isCurrent && player.rate != 1 {
                        Text(player.rate == 1.5 ? "1.5×" : "2×")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(mine ? theme.accentColor : Color.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(mine ? Color.white : theme.accentColor, in: Capsule())
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

    func toggle(mediaID: String, duration: Double) {
        if player == nil {
            guard let url = ServerConfig.mediaURL(mediaID) else { return }
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
                Task { @MainActor in self?.stop() }
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

    @StateObject private var playback = CirclePlayback()
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

            if playback.started, let player = playback.player {
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
            guard !message.isPending, let id = attachment.mediaID else { return }
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
    func dustDissolve(active: Bool, color: Color) -> some View { modifier(DustDissolve(active: active, color: color)) }
}

private struct DustDissolve: ViewModifier {
    let active: Bool
    let color: Color
    @State private var start: Date?
    private let duration: Double = 1.15
    private let pad: CGFloat = 70
    /// Ступени прозрачности улетающих песчинок
    private static let levels = 8

    private static func rand(_ x: Int, _ y: Int, _ k: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: x &* 73856093 ^ y &* 19349663 ^ k &* 83492791)
        h = (h ^ (h >> 13)) &* 1274126177
        h ^= h >> 16
        return Double(h % 10000) / 10000
    }

    /// Размер «песчинки»: мелкая, но для больших вложений крупнее, чтобы число клеток не росло
    private static func cell(for size: CGSize) -> CGFloat {
        max(2, (size.width * size.height / 9000).squareRoot())
    }

    /// Когда клетка отрывается: волна идёт от нижнего левого края вправо и вверх, с шумом — как в Telegram
    private static func threshold(_ ix: Int, _ iy: Int, cols: Int, rows: Int) -> Double {
        let nx = Double(ix) / Double(max(cols, 1)), ny = Double(iy) / Double(max(rows, 1))
        return 0.50 * (0.65 * nx + 0.35 * (1 - ny)) + 0.30 * rand(ix, iy, 1)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation) { ctx in
                let s = start ?? ctx.date
                let p = min(1, max(0, ctx.date.timeIntervalSince(s) / duration))
                content
                    .mask {
                        Canvas { g, size in
                            let cell = Self.cell(for: size)
                            let cols = Int(size.width / cell) + 1, rows = Int(size.height / cell) + 1
                            // все клетки — в один путь и одну заливку: тысячи отдельных fill на кадр и были основной ценой
                            var path = Path()
                            for ix in 0..<cols {
                                for iy in 0..<rows {
                                    let th = Self.threshold(ix, iy, cols: cols, rows: rows)
                                    let k = min(1, max(0, (th - p) * 9))              // песчинка сжимается и пропадает
                                    guard k > 0 else { continue }
                                    let d = cell * CGFloat(k)
                                    path.addRect(CGRect(x: CGFloat(ix) * cell + (cell - d) / 2, y: CGFloat(iy) * cell + (cell - d) / 2, width: d, height: d))
                                }
                            }
                            g.fill(path, with: .color(.white))
                        }
                    }
                    .overlay {
                        Canvas { g, full in
                            let size = CGSize(width: full.width - pad * 2, height: full.height - pad * 2)
                            let cell = Self.cell(for: size)
                            let cols = Int(size.width / cell) + 1, rows = Int(size.height / cell) + 1
                            let light = Color.white.opacity(0.9)
                            // песчинки раскладываются по 2 цветам × 8 ступеням прозрачности: 16 заливок на кадр вместо тысяч
                            var paths = [Path](repeating: Path(), count: Self.levels * 2)
                            for ix in 0..<cols {
                                for iy in 0..<rows {
                                    guard Self.rand(ix, iy, 2) < 0.8 else { continue }
                                    let th = Self.threshold(ix, iy, cols: cols, rows: rows)
                                    let age = (p - th) / 0.5                          // 0 — только что оторвалась, 1 — растаяла
                                    guard age > 0, age < 1 else { continue }
                                    let r1 = Self.rand(ix, iy, 3), r2 = Self.rand(ix, iy, 4), r3 = Self.rand(ix, iy, 5)
                                    let ease = CGFloat(age * (0.4 + 0.6 * age))      // разгоняются, как по ветру
                                    // ветер вправо и чуть вверх; часть песчинок улетает далеко
                                    let x = pad + CGFloat(ix) * cell + ease * CGFloat(30 + 110 * r1 * r1)
                                    let y = pad + CGFloat(iy) * cell - ease * CGFloat(10 + 55 * r2) + CGFloat(sin(age * 9 + r1 * 6)) * 3
                                    let d = cell * CGFloat(0.85 - 0.45 * age)
                                    let level = min(Self.levels - 1, Int((1 - age) * Double(Self.levels)))
                                    paths[(r3 < 0.28 ? Self.levels : 0) + level].addEllipse(in: CGRect(x: x, y: y, width: d, height: d))
                                }
                            }
                            for i in paths.indices where !paths[i].isEmpty {
                                let alpha = 0.95 * (Double(i % Self.levels) + 0.5) / Double(Self.levels)
                                g.fill(paths[i], with: .color((i >= Self.levels ? light : color).opacity(alpha)))
                            }
                        }
                        .padding(-pad)
                        .allowsHitTesting(false)
                    }
                    .onAppear { if start == nil { start = ctx.date } }
            }
        } else {
            content
        }
    }
}
