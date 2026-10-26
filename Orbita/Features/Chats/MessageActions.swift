import SwiftUI
#if canImport(Translation)
import Translation
import NaturalLanguage
#endif

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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .scrollDisabled(state.target != nil)
            // страховка: если меню так и не появилось или исчезло само (свернули приложение, окно не создалось),
            // выбор сбрасывается — иначе переписка оставалась «замороженной» и не листалась
            .onChange(of: state.target?.id) { _, id in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard state.target?.id == id, !MessageMenuWindow.isShowing else { return }
                    state.target = nil
                    MessageMenu.isOpen = false
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase != .active, state.target != nil else { return }
                state.target = nil
                MessageMenu.isOpen = false
            }
            .onDisappear {
                state.target = nil
                MessageMenu.isOpen = false
            }
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
    /// Админ группы удаляет чужое сообщение: галочки «удалить все его сообщения», «запретить писать», «заблокировать»
    var onModerate: ((ModerationOptions) -> Void)? = nil
    var isSaved = false
    var onForward: () -> Void = {}
    var onSelect: () -> Void = {}
    var onInfo: () -> Void = {}
    /// «Перевести» — системный переводчик iOS (17.4+), прямо на телефоне
    var onTranslate: (() -> Void)? = nil
    /// Своя заметка к сообщению — видна только тебе
    var onNote: (() -> Void)? = nil
    /// Где сообщение стоит на экране (экранные координаты): копия встаёт ровно туда же, как в Telegram
    var sourceFrame: CGRect? = nil

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var appear = false
    @State private var confirming = false
    @State private var modDeleteAll = false
    @State private var modRestrict = false
    @State private var modBan = false
    @State private var expanded = false           // ряд реакций раскрыт в панель со всеми эмодзи (кнопка справа, как в Telegram)
    @State private var reminding = false          // список «Напомнить: через час / вечером / завтра»
    @State private var closing = false           // меню уходит плавно, а не исчезает в один кадр

    private var s: Strings { Strings(lang: lang) }
    /// В реакциях — только эмодзи с анимацией
    static let emojis = AnimatedEmoji.all
    private var current: String? { model.messages.first { $0.id == message.id }?.reactions.first(where: \.mine)?.emoji }
    /// Перевод есть для текста, если система умеет (iOS 17.4+)
    private var canTranslate: Bool {
        guard onTranslate != nil, TranslationSheet.available, !message.text.hasPrefix("\u{200B}call:") else { return false }
        return Self.needsTranslation(message.text)
    }

    /// Есть что переводить: в тексте есть слова (не только эмодзи, числа, ссылки и @упоминания)
    /// и он не на языке телефона — как в Telegram
    static func needsTranslation(_ text: String) -> Bool {
        let words = text.replacingOccurrences(of: "(https?://|www\\.)\\S+|@\\w+", with: " ", options: .regularExpression)
        guard words.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 2 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(words.prefix(400)))        // для определения языка хватает начала
        guard let found = recognizer.dominantLanguage, found != .undetermined else { return true }
        let mine = Locale.preferredLanguages.first.map { String($0.prefix(2)).lowercased() } ?? "ru"
        return found.rawValue.prefix(2).lowercased() != mine
    }

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

    // Раскладка: сверху ряд реакций, посередине сообщение на своём месте, снизу кнопки
    private static let barHeight: CGFloat = 52
    private static let gap: CGFloat = 10
    private static let rowHeight: CGFloat = 46

    /// Высота списка действий — считается заранее, чтобы сразу знать, сколько места нужно под сообщением
    private var canNote: Bool { onNote != nil && !message.isPending && message.system == nil }

    private var actionCount: Int {
        var n = 4                                                                   // ответить, напомнить, выбрать, удалить
        if !noForward && message.system == nil && !message.text.hasPrefix("\u{200B}call:") { n += 1 }
        if !message.text.isEmpty && !noForward && message.poll == nil { n += 1 }
        if model.canPin { n += 1 }
        if showSender { n += 1 }
        if canEdit && message.poll == nil { n += 1 }
        if canTranslate { n += 1 }
        if canNote { n += 1 }
        return n
    }
    private var listHeight: CGFloat {
        Self.headerHeight + 0.5 + CGFloat(actionCount) * Self.rowHeight + CGFloat(actionCount - 1) * 0.5
    }
    private static let headerHeight: CGFloat = 34

    var body: some View {
        GeometryReader { g in
            let screen = g.size
            let top = TopInset.value + 8
            let bottom = screen.height - max(BottomInset.value, 12) - 8
            let f = sourceFrame ?? CGRect(x: 0, y: screen.height * 0.35, width: screen.width, height: 80)
            // сообщение слишком высокое — показываем его в прокрутке нужной высоты
            let maxMessage = max(60, bottom - top - (Self.barHeight + Self.gap) - (Self.gap + listHeight))
            let messageH = min(f.height, maxMessage)
            // стоит на своём месте; сдвигается, только если сверху не хватает места для реакций или снизу — для кнопок
            let target = min(max(f.minY, top + Self.barHeight + Self.gap), bottom - listHeight - Self.gap - messageH)
            let y = shown ? target : f.minY                      // при закрытии сообщение возвращается на место
            let side: Alignment = message.mine ? .trailing : .leading

            ZStack(alignment: .topLeading) {
                // размытие ставится сразу и без анимации прозрачности (анимированный blur пересчитывается каждый кадр и тормозит);
                // плавно проявляется и уходит только затемнение. Размыто всё, включая клавиатуру под меню
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(shown ? (theme.dark ? 0.35 : 0.12) : 0)
                        .animation(closing ? .easeOut(duration: Self.closeDuration) : .easeOut(duration: 0.25), value: shown))
                    .frame(width: screen.width, height: screen.height)
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }

                Group {
                    reactionBar
                        .opacity(confirming || reminding || expanded ? 0 : 1)
                        .scaleEffect(confirming || reminding ? 0.9 : 1, anchor: message.mine ? .bottomTrailing : .bottomLeading)
                        .allowsHitTesting(!confirming && !reminding && !expanded)
                        // ряд реакций «вырастает» из угла над сообщением
                        .scaleEffect(shown ? 1 : 0.4, anchor: message.mine ? .bottomTrailing : .bottomLeading)
                        .opacity(shown ? 1 : 0)
                        .animation(motion(0.03), value: shown)
                        .frame(width: screen.width - 24, alignment: side)
                        .offset(x: 12, y: y - Self.gap - Self.barHeight)

                    ScrollView {
                        MessageRow(message: message, isFirst: true, isLast: true,
                                   onReply: {}, onEdit: {}, onDelete: {}, onOpenMedia: { _, _ in }, onOpenFile: { _ in },
                                   showSender: showSender, noForward: noForward, interactive: false)
                            .allowsHitTesting(false)
                    }
                    .scrollDisabled(f.height <= messageH + 1)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(width: f.width, height: messageH)
                    .offset(x: f.minX, y: y)

                    Group {
                        if confirming {
                            confirmList
                                .transition(.scale(scale: 0.6, anchor: message.mine ? .topTrailing : .topLeading).combined(with: .opacity))
                        } else if reminding {
                            reminderList
                                .transition(.scale(scale: 0.6, anchor: message.mine ? .topTrailing : .topLeading).combined(with: .opacity))
                        } else {
                            actionList
                                .transition(.scale(scale: 0.85, anchor: message.mine ? .topTrailing : .topLeading).combined(with: .opacity))
                        }
                    }
                    // список действий раскрывается из угла под сообщением
                    .scaleEffect(shown ? 1 : 0.5, anchor: message.mine ? .topTrailing : .topLeading)
                    .opacity(shown && !expanded ? 1 : 0)
                    .allowsHitTesting(!expanded)
                    .animation(motion(0.05), value: shown)
                    .frame(width: screen.width - 24, alignment: side)
                    .offset(x: 12, y: y + messageH + Self.gap)

                    // все реакции: панель раскрывается из ряда вниз, поверх сообщения и кнопок
                    if expanded {
                        let panelW = screen.width - 24
                        let panelH = Self.panelHeight(width: panelW, limit: min(380, bottom - top))
                        let panelTop = max(top, min(y - Self.gap - Self.barHeight, bottom - panelH))
                        expandedPanel(width: panelW, height: panelH)
                            .opacity(shown ? 1 : 0)
                            .offset(x: 12, y: panelTop)
                            .transition(.scale(scale: 0.3, anchor: message.mine ? .topTrailing : .topLeading).combined(with: .opacity))
                            .zIndex(5)
                    }
                }
                // сообщение (и всё вокруг) плавно встаёт на место, если пришлось сдвинуть
                .animation(closing ? .easeOut(duration: Self.closeDuration) : .spring(response: 0.36, dampingFraction: 0.86), value: shown)
                .allowsHitTesting(!closing)               // пункты меню — только пока не закрывается
            }
        }
        .ignoresSafeArea()
        // размытый фон ловит все касания, в том числе пока меню плавно уходит: под ним ничего не нажимается
        .onAppear {
            MessageMenu.isOpen = true
            // меню живёт в своём окне: команда «появиться» приходит ещё до первого кадра, и без задержки
            // SwiftUI сразу рисовал конечное состояние — анимация появления пропадала. Запускаем со следующего кадра
            DispatchQueue.main.async { appear = true }
        }
        .onDisappear { MessageMenu.isOpen = false }
    }

    /// Сколько эмодзи помещается в ряд вместе с кнопкой «раскрыть» справа
    private static var visibleCount: Int { max(4, Int((UIScreen.main.bounds.width - 32 - 20 - 40) / 40)) }
    private static var hasMore: Bool { emojis.count > visibleCount }

    private func emojiButton(_ e: String, index: Int, size: CGFloat = 38) -> some View {
        Button {
            model.react(message, emoji: e)
            dismiss()
        } label: {
            ReactionBarEmoji(emoji: e, index: index)
                .frame(width: size, height: size + 2)
                .background(current == e ? theme.accentColor.opacity(0.25) : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var reactionBar: some View {
        if Self.hasMore { compactBar } else { scrollingBar }
    }

    /// Как в Telegram: первые эмодзи и кнопка-стрелка, по ней — панель со всеми
    private var compactBar: some View {
        HStack(spacing: 2) {
            ForEach(Array(Self.emojis.prefix(Self.visibleCount).enumerated()), id: \.element) { index, e in
                emojiButton(e, index: index)
            }
            Button {
                Haptics.impact(.light)
                withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) { expanded = true }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(theme.textTertiary.opacity(0.2), in: Circle())
                    .frame(width: 38, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(height: 52)
        .menuSurface(Capsule())
    }

    private static func panelColumns(_ width: CGFloat) -> Int { max(6, Int((width - 16) / 46)) }

    static func panelHeight(width: CGFloat, limit: CGFloat) -> CGFloat {
        let rows = (emojis.count + panelColumns(width) - 1) / panelColumns(width)
        return min(limit, CGFloat(rows) * 52 + 20)
    }

    /// Все реакции сеткой; если их много — листается
    private func expandedPanel(width: CGFloat, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: Self.panelColumns(width)), spacing: 6) {
                ForEach(Array(Self.emojis.enumerated()), id: \.element) { index, e in
                    emojiButton(e, index: index, size: 44)
                }
            }
            .padding(10)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: width, height: height)
        .clipShape(shape)
        .menuSurface(shape)
    }

    private var scrollingBar: some View {
        // эмодзи больше, чем влезает в ширину экрана, — полоска листается вбок
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 2) {
                ForEach(Array(Self.emojis.enumerated()), id: \.element) { index, e in
                    emojiButton(e, index: index)
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
            sentHeader
            divider
            row("arrowshape.turn.up.left", s.reply) { dismiss(onReply) }
            if !noForward && message.system == nil && !message.text.hasPrefix("\u{200B}call:") {
                divider
                row("arrowshape.turn.up.right", s.t("Переслать", "Forward")) { dismiss(onForward) }
            }
            if !message.text.isEmpty && !noForward && message.poll == nil {
                divider
                row("doc.on.doc", s.copy) { UIPasteboard.general.string = message.text; dismiss() }
            }
            if canTranslate {
                divider
                row("character.bubble", s.t("Перевести", "Translate")) { dismiss { onTranslate?() } }
            }
            if model.canPin {
                divider
                let pinned = model.isPinned(message)
                row(pinned ? "pin.slash" : "pin", pinned ? s.t("Открепить", "Unpin") : s.t("Закрепить", "Pin")) {
                    model.togglePin(message); dismiss()
                }
            }
            if showSender {
                // в группе — кто прочитал и кто как отреагировал; в личке время и «прочитано» и так видны сверху меню
                divider
                row("eye", s.t("Кто прочитал и отреагировал", "Seen & reactions")) { dismiss(onInfo) }
            }
            if canEdit && message.poll == nil {
                divider
                row("pencil", s.editMessage) { dismiss(onEdit) }
            }
            if canNote {
                divider
                row(message.note == nil ? "note.text.badge.plus" : "note.text",
                    message.note == nil ? s.t("Добавить заметку", "Add note") : s.t("Изменить заметку", "Edit note")) {
                    dismiss { onNote?() }
                }
            }
            divider
            row("bell", s.t("Напомнить", "Remind me")) {
                Haptics.select()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { reminding = true }
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

    /// Когда отправлено (точная дата и время), изменено ли, прочитано ли — вместо отдельного свайпа «показать время»
    private var sentHeader: some View {
        var parts = [ChatTime.day(message.createdAt, s: s, lang: lang) + ", " + ChatTime.clock(message.createdAt)]
        if message.editedAt != nil { parts.append(s.t("изменено", "edited")) }
        if message.mine && !message.isPending { parts.append(message.read ? s.t("прочитано", "read") : s.t("доставлено", "delivered")) }
        return HStack(spacing: 6) {
            Image(systemName: message.mine && message.read ? "checkmark.circle.fill" : "clock")
                .font(.system(size: 12, weight: .semibold))
            Text(parts.joined(separator: " · ")).font(.system(size: 13)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 16)
        .frame(height: Self.headerHeight)
    }

    /// «Напомнить»: когда прислать уведомление об этом сообщении
    private var reminderList: some View {
        VStack(spacing: 0) {
            ForEach(Array(MessageReminder.options(lang).enumerated()), id: \.offset) { index, option in
                if index > 0 { divider }
                row("clock", option.title) {
                    let peer = model.peer, text = message.summary, id = message.id, date = option.date, language = self.lang
                    Task {
                        let ok = await MessageReminder.schedule(peer: peer, text: text, messageID: id, at: date, lang: language)
                        Haptics.notify(ok ? .success : .error)
                    }
                    dismiss()
                }
            }
        }
        .frame(width: 250)
        .menuSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: .infinity, alignment: message.mine ? .trailing : .leading)
    }

    /// Вместо списка действий — только кнопка(и) удаления
    /// Чужое сообщение в группе, а ты админ — удаление с галочками, как в Telegram
    private var moderating: Bool {
        guard onModerate != nil, let g = model.group, g.isAdmin, !g.isChannel, !message.mine,
              message.system == nil, let sender = message.sender else { return false }
        // админа может наказать только владелец, владельца — никто
        let role = g.members.first { $0.id == sender.id }?.role
        return role != "owner" && (role != "admin" || g.isOwner)
    }

    @ViewBuilder
    private var confirmList: some View {
        if moderating { moderationList } else { plainConfirmList }
    }

    private var moderationList: some View {
        let name = message.sender?.name ?? ""
        return VStack(spacing: 0) {
            Text(s.t("Удалить сообщение от \(name)?", "Delete message from \(name)?"))
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 16).padding(.vertical, 12)
            divider
            checkRow(s.t("Удалить все его сообщения", "Delete all their messages"), isOn: $modDeleteAll)
            divider
            checkRow(s.t("Запретить писать", "Restrict from writing"), isOn: $modRestrict)
                .disabled(modBan).opacity(modBan ? 0.4 : 1)
            divider
            checkRow(s.t("Заблокировать", "Ban from the group"), isOn: $modBan)
            divider
            Button {
                var o = ModerationOptions()
                o.deleteAll = modDeleteAll
                o.ban = modBan
                o.restrict = modRestrict && !modBan ? 0 : nil
                dismiss { onModerate?(o) }
            } label: {
                Text(s.delete).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.danger)
                    .frame(maxWidth: .infinity).frame(height: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 290)
        .menuSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(maxWidth: .infinity, alignment: message.mine ? .trailing : .leading)
        .animation(.easeOut(duration: 0.15), value: modBan)
    }

    private func checkRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            Haptics.select()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21)).foregroundStyle(isOn.wrappedValue ? theme.danger : theme.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
                Text(title).font(.system(size: 16)).foregroundStyle(theme.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).frame(height: 46).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var plainConfirmList: some View {
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

    private var delay: Double { Self.start + Double(min(index, 16)) * Self.step }      // в большой панели волна не затягивается

    var body: some View {
        LottieEmojiView(emoji: emoji, size: 34, playing: live, idleAtStart: true)      // один круг при появлении и стоп
            .scaleEffect(popped ? 1 : 0.3)
            .opacity(popped ? 1 : 0)
            .onAppear {
                // со следующего кадра — иначе в отдельном окне меню «прыжок» не виден (см. MessageActionOverlay)
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.62).delay(delay)) { popped = true }
                }
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

// MARK: - Меню поверх клавиатуры

/// Меню зажатого сообщения показывается в отдельном окне выше клавиатуры: клавиатура не прячется,
/// а размывается вместе со всем экраном (как в Telegram). Окно не становится главным — поле ввода не теряет фокус
@MainActor
enum MessageMenuWindow {
    private static var window: UIWindow?
    static var isShowing: Bool { window != nil }

    static func show<V: View>(_ view: V) {
        hide()
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = .clear
        let w = UIWindow(windowScene: scene)
        // выше всех окон, включая клавиатуру (её уровень зависит от версии iOS): размыто всё, и клавиатура тоже
        let top = scene.windows.map(\.windowLevel.rawValue).max() ?? 0
        w.windowLevel = UIWindow.Level(rawValue: max(10_000_001, top + 1))
        w.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        window = w
    }

    static func hide() {
        window?.isHidden = true
        window = nil
    }
}

/// Пока выбрано сообщение, держит его меню в окне поверх клавиатуры; сообщение сбросили — окно убирается
struct MessageMenuPresenter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onAppear { MessageMenuWindow.show(content) }
            .onDisappear { MessageMenuWindow.hide() }
    }
}

// MARK: - Перевод сообщения

/// Системная шторка перевода (Translation, iOS 17.4+): перевод делается на телефоне, без сервера
struct TranslationSheet: ViewModifier {
    @Binding var text: String?

    static var available: Bool {
        #if canImport(Translation)
        if #available(iOS 17.4, *) { return true }
        #endif
        return false
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 17.4, *) {
            content.translationPresentation(isPresented: Binding(get: { text != nil }, set: { if !$0 { text = nil } }),
                                            text: text ?? "")
        } else {
            content
        }
        #else
        content
        #endif
    }
}
