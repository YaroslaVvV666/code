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
                    SendingIndicator(color: color)
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
    var onReact: ((String) -> Void)? = nil          // двойной тап и нажатие на «чип» реакции
    var onLongPress: (() -> Void)? = nil            // зажатие — реакции и меню
    var interactive = true
    var pinnedMark = false
    var onOpenProfile: ((String) -> Void)? = nil     // тап по «Переслано от …» / имени
    var onOpenPost: ((String) -> Void)? = nil
    var onOpenStory: ((String) -> Void)? = nil
    var onPollChanged: ((PollInfo) -> Void)? = nil
    var onOpenComments: (() -> Void)? = nil          // канал с обсуждением: «Комментарии»

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var dragX: CGFloat = 0

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
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.32).onEnded { _ in
            if interactive, !message.isPending, let onLongPress { Haptics.impact(.medium); onLongPress() }
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

    private var bubble: some View {
        let textColor = mine ? colors.outgoingText : colors.incomingText
        let secondary = mine ? colors.outgoingSecondary : colors.incomingSecondary
        // место под время/галочки/просмотры: оценка ширины в «узких пробелах» (по 8 пт), чтобы не оставалось лишнего отступа
        let metaWidth: CGFloat = 32 + (mine ? 16 : 0) + (message.editedAt != nil ? 44 : 0)
            + (message.views.map { 6 + CGFloat($0 >= 1000 ? 4 : String($0).count) * 5 } ?? 0) + 10
        let filler = String(repeating: "\u{2002}", count: Int((metaWidth / 8).rounded(.up)))

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
            if let fwd = message.forwarded {
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
                    case .audio: AudioBlock(attachment: a, mine: mine, pending: message.isPending) { onPlayAudio(a) }
                    case .file:
                        if a.isMusic {
                            AudioBlock(attachment: a, mine: mine) { onPlayAudio(a) }
                        } else {
                            FileBlock(attachment: a, mine: mine, pending: message.isPending) { onOpenFile(a) }
                        }
                    case .circle: CircleVideoBubble(attachment: a, message: message, size: 180)
                    default: StickerImage(sticker: Sticker(id: a.sticker ?? "", emoji: ""), size: 120)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, hasText ? 0 : 6)
                .overlay(alignment: .bottomTrailing) {
                    if voiceOnly && a.kind == .voice {
                        MessageMeta(message: message, color: secondary).padding(.trailing, 10).padding(.bottom, 6)
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
            } else if !onlyMedia && message.poll == nil && !voiceOnly {
                HStack { Spacer(minLength: 0); MessageMeta(message: message, color: secondary) }
                    .padding(.horizontal, 11)
                    .padding(.bottom, 5)
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

    private let width: CGFloat = 262
    private let gap: CGFloat = 2
    @AppStorage("autoplay") private var autoplay = true
    @State private var frames = FrameBoxes()

    var body: some View {
        Group {
            switch items.count {
            case 1:
                let a = items[0]
                let aspect = min(1.5, max(0.65, a.aspect))
                cell(a, index: 0).frame(width: width, height: width / aspect)
            case 2:
                HStack(spacing: gap) {
                    cell(items[0], index: 0).frame(width: (width - gap) / 2, height: 190)
                    cell(items[1], index: 1).frame(width: (width - gap) / 2, height: 190)
                }
            case 3:
                VStack(spacing: gap) {
                    cell(items[0], index: 0).frame(width: width, height: 170)
                    HStack(spacing: gap) {
                        cell(items[1], index: 1).frame(width: (width - gap) / 2, height: 126)
                        cell(items[2], index: 2).frame(width: (width - gap) / 2, height: 126)
                    }
                }
            default:
                let side = (width - gap) / 2
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        cell(items[0], index: 0).frame(width: side, height: side)
                        cell(items[1], index: 1).frame(width: side, height: side)
                    }
                    HStack(spacing: gap) {
                        cell(items[2], index: 2).frame(width: side, height: side)
                        cell(items[3], index: 3).frame(width: side, height: side)
                            .overlay {
                                if items.count > 4 {
                                    Color.black.opacity(0.5)
                                    Text("+\(items.count - 4)").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                                }
                            }
                    }
                }
            }
        }
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

    private var sizeText: String {
        attachment.size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file) : ""
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(mine ? Color.white : theme.accentColor)
                    if pending {
                        TransferRing(progress: nil, icon: "arrow.up", size: 42, tint: mine ? theme.accentColor : .white,
                                     track: (mine ? theme.accentColor : Color.white).opacity(0.25))
                    } else if let p = dl {
                        TransferRing(progress: p, icon: "xmark", size: 42, tint: mine ? theme.accentColor : .white,
                                     track: (mine ? theme.accentColor : Color.white).opacity(0.25))
                    } else {
                        Image(systemName: "doc.fill").font(.system(size: 19))
                            .foregroundStyle(mine ? theme.accentColor : Color.white)
                    }
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name ?? "Файл")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(mine ? Color.white : theme.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let p = dl {
                        Text("\(Int(p * 100))% · \(sizeText)").font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(mine ? Color.white.opacity(0.75) : theme.textTertiary)
                    } else if pending {
                        Text("\(sizeText)").font(.system(size: 12))
                            .foregroundStyle(mine ? Color.white.opacity(0.75) : theme.textTertiary)
                    } else if !sizeText.isEmpty {
                        Text(sizeText).font(.system(size: 12))
                            .foregroundStyle(mine ? Color.white.opacity(0.75) : theme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 210)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - «Кружок»: круглое видеосообщение

@MainActor
final class CirclePlayback: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var started = false
    @Published private(set) var progress = 0.0
    private(set) var player: AVPlayer?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    func toggle(mediaID: String, duration: Double) {
        if player == nil {
            guard let url = ServerConfig.mediaURL(mediaID) else { return }
            VoicePlayer.shared.stop()
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
                    guard let self else { return }
                    self.player?.seek(to: .zero)
                    self.isPlaying = false
                    self.started = false
                    self.progress = 0
                }
            }
        }
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
            started = true
        }
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
        .frame(width: size, height: size)
        .clipShape(Circle())
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
