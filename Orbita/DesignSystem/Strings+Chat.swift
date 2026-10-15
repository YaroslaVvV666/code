import Foundation

/// Тексты мессенджера
extension Strings {
    var chatsTitle: String { t("Чаты", "Chats") }
    var chatsSearch: String { t("Поиск", "Search") }
    var chatsEmpty: String { t("Пока нет переписок", "No chats yet") }
    var chatsEmptyHint: String { t("Нажмите на карандаш и найдите человека по @нику — или откройте чей-то профиль и нажмите «Написать».", "Tap the pencil and find someone by @username — or open a profile and tap “Message”.") }
    var newChat: String { t("Новый чат", "New chat") }
    var newChatHint: String { t("Введите ник человека", "Enter a username") }
    var userNotFound: String { t("Пользователь не найден", "User not found") }
    var findUser: String { t("Найти", "Find") }
    var writeMessage: String { t("Написать", "Message") }
    var messagePlaceholder: String { t("Сообщение", "Message") }
    var typingNow: String { t("печатает…", "typing…") }
    var youPrefix: String { t("Вы: ", "You: ") }
    var reply: String { t("Ответить", "Reply") }
    var copy: String { t("Копировать", "Copy") }
    var editMessage: String { t("Изменить", "Edit") }
    var editing: String { t("Редактирование", "Editing") }
    var deleteMessage: String { t("Удалить сообщение?", "Delete message?") }
    var deleteForMe: String { t("Удалить у меня", "Delete for me") }
    var deleteForAll: String { t("Удалить у всех", "Delete for everyone") }
    var clearHistory: String { t("Удалить переписку", "Delete chat") }
    var chatWriteBlocked: String { t("Вы не можете писать этому пользователю", "You can't message this user") }
    var chatStart: String { t("Напишите первое сообщение", "Write the first message") }
    var today: String { t("Сегодня", "Today") }
    var yesterday: String { t("Вчера", "Yesterday") }
    var edited: String { t("изм.", "edited") }
}

/// Тексты: ссылки на посты и «поделиться»
extension Strings {
    var copyLink: String { t("Скопировать ссылку", "Copy link") }
    var linkCopied: String { t("Ссылка скопирована", "Link copied") }
    var sendToChat: String { t("Отправить в чат", "Send in chat") }
    var sendToChatTitle: String { t("Кому отправить", "Send to") }
    var sentToChat: String { t("Отправлено", "Sent") }
    var postUnavailable: String { t("Публикация недоступна", "Post unavailable") }
    var postUnavailableHint: String { t("Её удалили, или автор ограничил вам доступ.", "It was deleted, or the author restricted your access.") }
    var noChatsToSend: String { t("Пока нет переписок. Откройте профиль человека и нажмите «Написать».", "No chats yet. Open a profile and tap “Message”.") }
}

/// Тексты: ввод, вложения, статусы собеседника
extension Strings {
    var noStickers: String { t("Стикеров пока нет", "No stickers yet") }
    var attachPhotoVideo: String { t("Фото или видео", "Photo or video") }
    var attachFile: String { t("Файл", "File") }
    var slideToCancel: String { t("Влево — отмена", "Slide to cancel") }
    var releaseToSend: String { t("Отпустите, чтобы отправить", "Release to send") }
    var micDenied: String { t("Разрешите доступ к микрофону в Настройках", "Allow microphone access in Settings") }
    var cameraDenied: String { t("Разрешите доступ к камере и микрофону в Настройках", "Allow camera and microphone access in Settings") }
    var tooShort: String { t("Слишком короткая запись", "Recording is too short") }
    var photoLabel: String { t("Фото", "Photo") }
    var videoLabel: String { t("Видео", "Video") }
    var fileLabel: String { t("Файл", "File") }
    var voiceLabel: String { t("Голосовое сообщение", "Voice message") }
    var circleLabel: String { t("Видеосообщение", "Video message") }
    var stickerLabel: String { t("Стикер", "Sticker") }
    var messageSent: String { t("Сообщение", "Message") }
    var scrollDown: String { t("Вниз", "Down") }

    /// Текст без многоточия: точки рисует анимированный `ActionLabel`
    func actionWord(_ action: String) -> String {
        actionText(action).replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// «печатает…», «записывает голосовое…» и т.д.
    func actionText(_ action: String) -> String {
        switch action {
        case "voice": return t("записывает голосовое…", "recording voice…")
        case "video": return t("записывает видео…", "recording video…")
        case "photo": return t("отправляет фото…", "sending a photo…")
        case "file":  return t("отправляет файл…", "sending a file…")
        default:      return typingNow
        }
    }
}
