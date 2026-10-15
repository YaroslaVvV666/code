import Foundation

/// Тексты: стена, приватность, чёрный список, плейлист
extension Strings {
    // Публикации
    var editPost: String { t("Редактировать", "Edit") }
    var editedMark: String { t("изм.", "edited") }
    var deletePostQuestion: String { t("Удалить публикацию?", "Delete this post?") }
    var deletePostHint: String { t("Это действие нельзя отменить.", "This can't be undone.") }

    // Страница профиля
    var myPage: String { t("Моя страница", "My page") }
    var wallTitle: String { t("Стена", "Wall") }
    var wallWhatsNew: String { t("Что у вас нового?", "What's on your mind?") }
    var wallEmptyMine: String { t("На стене пока пусто. Расскажите, что у вас нового.", "Your wall is empty. Share what's new.") }
    var wallEmpty: String { t("Записей пока нет", "No posts yet") }
    var wallClosed: String { t("Стена закрыта", "The wall is private") }
    var wallClosedHint: String { t("Владелец скрыл публикации на своей стене.", "The owner has hidden the posts on their wall.") }
    var restrictedYou: String { t("Страница недоступна", "Page unavailable") }
    var restrictedYouHint: String { t("Пользователь ограничил вам доступ к своей странице.", "This user has restricted your access to their page.") }
    var infoTitle: String { t("Информация", "Information") }
    var postsStat: String { t("Публикации", "Posts") }
    var photosStat: String { t("Фото", "Photos") }
    var musicStat: String { t("Музыка", "Music") }
    var lastSeenRecently: String { t("был(а) недавно", "last seen recently") }
    /// Только такие формулировки: «в сети», «был(а) только что», «был(а) 5 минут назад», «был(а) день назад», «был(а) давно», «был(а) недавно»
    func lastSeenText(_ date: Date?) -> String {
        guard let date else { return lastSeenRecently }
        let sec = max(0, Date().timeIntervalSince(date))
        if sec < 60 { return online }
        if sec < 180 { return t("был(а) только что", "last seen just now") }
        let minutes = Int(sec / 60), hours = Int(sec / 3600), days = Int(sec / 86400)
        if sec < 3600 { return t("был(а) \(minutes) \(plural(minutes, "минуту", "минуты", "минут")) назад", "last seen \(minutes) min ago") }
        if sec < 86400 { return t("был(а) \(hours) \(plural(hours, "час", "часа", "часов")) назад", "last seen \(hours) h ago") }
        if days < 2 { return t("был(а) день назад", "last seen a day ago") }
        if days < 7 { return t("был(а) \(days) \(plural(days, "день", "дня", "дней")) назад", "last seen \(days) days ago") }
        return t("был(а) давно", "last seen a long time ago")
    }

    private func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m100 = n % 100, m10 = n % 10
        if m100 >= 11 && m100 <= 14 { return many }
        if m10 == 1 { return one }
        if m10 >= 2 && m10 <= 4 { return few }
        return many
    }
    var blockUser: String { t("Заблокировать", "Block") }
    var unblockUser: String { t("Разблокировать", "Unblock") }
    func blockQuestion(_ name: String) -> String {
        t("Заблокировать \(name)?", "Block \(name)?")
    }
    var blockHint: String {
        t("Вы перестанете видеть публикации друг друга, а человек не сможет комментировать ваши записи.",
          "You'll stop seeing each other's posts, and they won't be able to comment on yours.")
    }
    var youBlockedHint: String { t("Вы заблокировали этого пользователя.", "You blocked this user.") }

    // Плейлист
    var playlistTitle: String { t("Плейлист", "Playlist") }
    var addMusic: String { t("Добавить музыку", "Add music") }
    var addTracks: String { t("Добавить треки", "Add tracks") }
    var playlistEmpty: String { t("В плейлисте пока пусто", "The playlist is empty") }
    var playlistHintMine: String { t("Первый трек показывается под вашим именем бегущей строкой. Порядок можно менять.",
                                     "The first track runs under your name. You can reorder the list.") }
    var renameTrack: String { t("Изменить название", "Edit title") }
    var trackTitleField: String { t("Название", "Title") }
    var trackArtistField: String { t("Исполнитель", "Artist") }
    var uploadingTracks: String { t("Загружаем…", "Uploading…") }
    var trackTooBig: String { t("Файл больше 40 МБ", "The file is over 40 MB") }
    var removeTrack: String { t("Удалить из плейлиста", "Remove from playlist") }

    // Конфиденциальность (как в Telegram)
    var securitySection: String { t("Безопасность", "Security") }
    var blacklist: String { t("Чёрный список", "Blocked users") }
    func blockedCount(_ n: Int) -> String { n == 0 ? t("Нет", "None") : "\(n)" }
    var blacklistEmpty: String { t("Список пуст", "No blocked users") }
    var blacklistHint: String {
        t("Заблокированные пользователи не видят вашу страницу и публикации и не могут комментировать. Заблокировать можно на странице человека.",
          "Blocked users can't see your page or posts and can't comment. You can block someone from their page.")
    }
    var loginEmail: String { t("Почта для входа", "Login email") }
    var loginEmailHint: String {
        t("Почта нужна для восстановления доступа и уведомлений о новых входах. Мы отправим на неё код подтверждения.",
          "Your email is used for account recovery and sign-in alerts. We'll send a confirmation code to it.")
    }
    var loginEmailChange: String { t("Сменить почту", "Change email") }
    var codeFromEmail: String { t("Код из письма", "Code from the email") }
    var emailLinked: String { t("Почта подтверждена", "Email confirmed") }

    var closedWall: String { t("Закрытая стена", "Private wall") }
    var closedWallHint: String {
        t("Скрывает только стену: публикации увидите лишь вы. Сам профиль остаётся виден — он настраивается ниже.",
          "Hides only the wall: just you see the posts. The profile itself stays visible, as configured below.")
    }
    var whoCanSeeSection: String { t("Кто видит", "Who can see") }
    var rowPhone: String { t("Номер телефона", "Phone number") }
    var rowLastSeen: String { t("Время захода", "Last seen") }
    var rowPhotos: String { t("Фотографии профиля", "Profile photos") }
    var rowBio: String { t("Раздел «О себе»", "About") }
    var rowBirthday: String { t("День рождения", "Birthday") }
    var rowMusic: String { t("Музыка в профиле", "Profile music") }
    var rowCalls: String { t("Звонки", "Calls") }
    var rowForwards: String { t("Пересылка сообщений", "Forwarded messages") }
    var rowInvites: String { t("Приглашения", "Invitations") }
    var rowComments: String { t("Комментарии", "Comments") }
    var onlyMe: String { t("Только я", "Only me") }
    var visibleAll: String { t("Все", "Everybody") }
    var visibleNone: String { t("Никто", "Nobody") }
    var visibleContacts: String { t("Мои контакты", "My contacts") }
    func visibilityTitle(_ key: String) -> String {
        switch key {
        case "phone": return rowPhone
        case "last_seen": return rowLastSeen
        case "photos": return rowPhotos
        case "bio": return rowBio
        case "birthday": return rowBirthday
        case "music": return rowMusic
        case "calls": return rowCalls
        case "forwards": return rowForwards
        case "invites": return rowInvites
        case "find": return t("Найти меня по номеру", "Find me by number")
        default: return rowComments
        }
    }
    func visibilityHint(_ key: String) -> String {
        switch key {
        case "phone": return t("Если выбрано «Никто», номер не покажется на вашей странице.", "If set to Nobody, your number won't appear on your page.")
        case "last_seen": return t("Если скрыть, другие увидят «был(а) недавно». Вы тоже не увидите чужое время захода.", "If hidden, others will see “last seen recently”.")
        case "photos": return t("Если скрыть, фотографий профиля не будет видно нигде — и в ленте тоже.", "If hidden, your profile photos won't show anywhere, including the feed.")
        case "bio": return t("Описание профиля увидят только те, кому вы разрешили.", "Only people you allow will see your bio.")
        case "birthday": return t("Дата рождения показывается на вашей странице.", "Your birthday is shown on your page.")
        case "music": return t("Скрывает плейлист и бегущую строку под именем.", "Hides the playlist and the running line under your name.")
        case "find": return t("Если выбрано «Никто», знакомые не найдут вас по номеру и не получат уведомление, что вы в Orbita.", "If set to Nobody, people can't find you by number and won't be told you joined Orbita.")
        case "comments": return t("Касается ваших публикаций. Сами вы всегда можете комментировать.", "Applies to your posts. You can always comment yourself.")
        case "invites": return t("Кто может добавлять вас в группы и каналы.", "Who can add you to groups and channels.")
        default: return t("Настройка сохранится и заработает вместе с чатами.", "Saved now; it will take effect once chats arrive.")
        }
    }
    var soonTag: String { t("скоро", "soon") }
    func privacyValue(_ v: String) -> String { v == "all" ? visibleAll : (v == "contacts" ? visibleContacts : visibleNone) }
}

// MARK: - Комментарии (дерево, как в TikTok)
extension Strings {
    func showReplies(_ n: Int) -> String { t("Показать ответы (\(n))", "View replies (\(n))") }
    var hideReplies: String { t("Скрыть ответы", "Hide replies") }
    var authorTag: String { t("Автор", "Author") }
    func commentsCount(_ n: Int) -> String {
        if lang == .en { return n == 1 ? "1 comment" : "\(n) comments" }
        let d = n % 10, h = n % 100
        let word = (h >= 11 && h <= 14) ? "комментариев" : (d == 1 ? "комментарий" : (2...4).contains(d) ? "комментария" : "комментариев")
        return "\(n) \(word)"
    }
    var copyText: String { t("Копировать", "Copy") }
}

extension Strings {
    var connectServer: String { t("Подключить сервер", "Connect to server") }
    func serverConnected(_ address: String) -> String { t("Сервер подключён: \(address)", "Server connected: \(address)") }
}
