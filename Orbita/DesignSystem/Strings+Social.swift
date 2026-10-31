import Foundation

/// Тексты ленты, редактора, профиля и ошибок сервера
extension Strings {
    // Лента
    var retry: String { t("Повторить", "Retry") }
    var setupServer: String { t("Настроить сервер", "Server settings") }
    var commentsOff: String { t("Автор отключил комментарии", "The author turned comments off") }

    // Редактор
    var addMedia: String { t("Фото и видео", "Photos & videos") }
    var linkTitle: String { t("Ссылка", "Link") }
    var add: String { t("Добавить", "Add") }
    var videoTooLong: String { t("Видео длиннее 5 минут", "The video is longer than 5 minutes") }
    var videoTooBig: String { t("Видео слишком большое даже после сжатия", "The video is too large even after compression") }
    var mediaFailed: String { t("Не удалось обработать файл", "Couldn't process the file") }

    // Профиль
    var phoneLabel: String { t("Телефон", "Phone") }
    var usernameLabel: String { t("Имя пользователя", "Username") }
    var bioLabel: String { t("О себе", "Bio") }
    var notSet: String { t("Не задано", "Not set") }
    var privacy: String { t("Конфиденциальность", "Privacy") }
    var appearance: String { t("Оформление", "Appearance") }
    var dataAndStorage: String { t("Данные и память", "Data and storage") }
    var serverLabel: String { t("Сервер", "Server") }
    var removePhoto: String { t("Удалить фото", "Remove photo") }

    var nameHint: String { t("Любые символы, до 40. Можно ник вроде ✦ Orbit_77 ✦.",
                             "Any characters, up to 40. A nickname like ✦ Orbit_77 ✦ works.") }
    var usernameHint: String { t("Можно a–z, 0–9 и _. От 5 до 32 символов, начинается с буквы. По нему вас смогут найти.",
                                 "a–z, 0–9 and _. 5 to 32 characters, starts with a letter. People can find you by it.") }
    var usernameFree: String { t("Имя свободно", "Username is available") }
    var usernameTaken: String { t("Это имя уже занято", "This username is taken") }
    var usernameBad: String { t("Недопустимое имя пользователя", "Invalid username") }
    var bioHint: String { t("Несколько слов о себе. До 70 символов.", "A few words about you. Up to 70 characters.") }

    var privacyPhone: String { t("Кто видит мой номер", "Who can see my number") }
    var privacyPhoneHint: String { t("Если выбрано «Никто», номер не покажется в вашем профиле.",
                                     "If set to Nobody, your number won't appear in your profile.") }
    var privacyComments: String { t("Кто может комментировать", "Who can comment") }
    var privacyCommentsHint: String { t("Это касается ваших публикаций. Сами вы всегда можете комментировать.",
                                        "Applies to your posts. You can always comment yourself.") }
    var everyone: String { t("Все", "Everyone") }
    var nobody: String { t("Никто", "Nobody") }

    var accentColor: String { t("Цвет акцента", "Accent color") }
    var autoplayVideo: String { t("Автовоспроизведение видео", "Autoplay videos") }
    var autoplayHint: String { t("Видео в ленте играет без звука. Нажмите на него, чтобы открыть с управлением.",
                                 "Videos in the feed play muted. Tap one to open it with controls.") }
    var cacheSize: String { t("Кэш медиа", "Media cache") }
    var clearCache: String { t("Очистить кэш", "Clear cache") }

    var serverAddress: String { t("Адрес сервера", "Server address") }
    var serverHint: String { t("Укажите адрес сервера Orbita, например http://192.168.1.20:8080.",
                               "Enter the Orbita server address, e.g. http://192.168.1.20:8080.") }
    var checking: String { t("Проверяем…", "Checking…") }
    var connectionOK: String { t("Сервер Orbita отвечает", "Orbita server is reachable") }
    var connectionFail: String { t("Не удалось подключиться", "Couldn't connect") }
    var checkConnection: String { t("Проверить подключение", "Check connection") }

    var twoFACurrent: String { t("Текущий пароль", "Current password") }
    var twoFANew: String { t("Новый пароль", "New password") }
    var twoFAOnHint: String { t("Двухфакторная защита включена. Пароль спрашивают при входе с нового устройства.",
                                "Two-step verification is on. The password is asked on every new device.") }
    var twoFADisableHint: String { t("Введите текущий пароль, чтобы отключить защиту.",
                                     "Enter your current password to turn protection off.") }
    var changePassword: String { t("Изменить пароль", "Change password") }
    var disable: String { t("Отключить", "Turn off") }

    // Ошибки сервера
    func api(_ error: APIError) -> String {
        switch error {
        case .notConfigured:
            return t("Укажите адрес сервера: Профиль → Сервер.", "Set the server address: Profile → Server.")
        case .offline:
            return t("Соединение…", "Connecting…")                // как в Telegram: без страшных слов про сервер
        case .unauthorized:
            return t("Сервер не принял вход. Попробуйте ещё раз.", "The server rejected the sign-in. Please try again.")
        case .invalidResponse:
            return t("Сервер ответил неожиданно.", "Unexpected server response.")
        case .server(_, let code):
            switch code {
            case "username_taken":    return usernameTaken
            case "username_invalid":  return usernameBad
            case "name_invalid":      return message(for: .invalidName)
            case "bio_too_long":      return t("«О себе» — не больше 70 символов.", "Bio is limited to 70 characters.")
            case "comments_disabled": return commentsOff
            case "too_large":         return t("Файл слишком большой.", "The file is too large.")
            case "wall_closed":       return t("Этот человек не принимает записи на стене.", "This person doesn't accept wall posts.")
            case "too_many":          return t("Слишком много записей. Попробуйте позже.", "Too many posts. Try again later.")
            case "bad_entry", "bad_text": return t("Напишите текст или добавьте фото.", "Write some text or add a photo.")
            case "content_blocked":   return t("Этот файл нарушает правила сообщества и не может быть загружен.", "This file breaks the community rules and can't be uploaded.")
            case "moderation_unavailable": return t("Проверка контента временно недоступна. Попробуйте позже.", "Content check is temporarily unavailable. Try again later.")
            case "unsupported_media": return t("Этот формат файла не поддерживается.", "This file format isn't supported.")
            case "too_many_media":    return t("В одной публикации — не больше 10 файлов.", "A post can have up to 10 files.")
            case "text_too_long":     return t("Текст слишком длинный.", "The text is too long.")
            case "empty":             return t("Добавьте текст или медиа.", "Add some text or media.")
            case "birthday_invalid":  return t("Проверьте дату рождения.", "Please check the birthday.")
            case "qr_expired":        return qrExpired
            case "too_many_avatars":  return t("Можно добавить до 50 фотографий.", "You can add up to 50 photos.")
            case "already_added":     return t("Это фото уже добавлено.", "This photo is already added.")
            case "too_many_requests": return t("Слишком часто. Попробуйте чуть позже.", "Too many requests. Try again shortly.")
            case "blocked":           return t("Недоступно: пользователь ограничил доступ.", "Unavailable: the user restricted access.")
            case "too_many_tracks":   return t("В плейлисте может быть до 100 треков.", "A playlist can hold up to 100 tracks.")
            case "forbidden":         return t("Это действие недоступно.", "This action isn't available.")
            case "slow_mode":         return t("Включён медленный режим — подождите немного перед следующим сообщением.",
                                               "Slow mode is on — wait a moment before the next message.")
            case "banned":            return t("Вас удалили из этого чата — вступить нельзя.", "You were removed from this chat and can't join.")
            case "handle_taken":      return t("Эта ссылка уже занята.", "This link is already taken.")
            case "bad_handle":        return t("Ссылка: 5–32 символа, латиница, цифры и _, начинается с буквы.",
                                               "Link: 5–32 characters, Latin letters, digits and _, starts with a letter.")
            case "group_full":        return t("Достигнут лимит участников.", "The member limit is reached.")
            case "media_not_found":   return t("Файл не найден на сервере. Попробуйте ещё раз.", "The file wasn't found on the server. Try again.")
            case "story_limit":       return t("Можно хранить не больше 50 историй навсегда.", "You can keep up to 50 stories forever.")
            case "too_long":          return t("Видео для истории — не длиннее минуты.", "A story video can be up to one minute.")
            case "bad_value":         return t("Сервер не понял запрос. Обновите server.py на сервере и перезапустите его.",
                                               "The server didn't understand the request. Update server.py and restart it.")
            case "bad_poll":          return t("Нужен вопрос и минимум два варианта ответа.", "A question and at least two options are required.")
            case "poll_closed":       return t("Опрос уже завершён.", "This poll is closed.")
            case "no_forward":        return t("Автор запретил пересылку из этого чата.", "Forwarding from this chat is disabled.")
            case "not_found":         return profileNotFound
            case "user_exists":       return t("Этот аккаунт уже зарегистрирован на сервере с другого устройства.",
                                               "This account is already registered on the server from another device.")
            default:                  return t("Ошибка сервера (\(code)).", "Server error (\(code)).")
            }
        }
    }
}

// MARK: - Комментарии

extension Strings {
    var replyAction: String { t("Ответить", "Reply") }
    var replyingTo: String { t("Ответ для", "Replying to") }
    var pinComment: String { t("Закрепить", "Pin") }
    var unpinComment: String { t("Открепить", "Unpin") }
    var pinnedLabel: String { t("Закреплено", "Pinned") }
    var likedByAuthorLabel: String { t("Нравится автору", "Liked by author") }
}

extension Strings {
    var cacheClearing: String { t("Очищаем кэш", "Clearing cache") }
    var cacheCleared: String { t("Кэш очищен", "Cache cleared") }
    var cacheFreed: String { t("Освобождено", "Freed") }
}
