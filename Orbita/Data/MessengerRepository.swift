import Foundation
import Combine

// MARK: - Модели

struct ChatPeer: Equatable, Hashable {
    let id: String
    var name: String
    var username: String?
    var avatarID: String?
    var isGroup = false
    var kind: String? = nil             // группа: "open" | "closed"
    var memberCount = 0
    var type: String? = nil             // "group" | "channel"
    var handle: String? = nil           // публичная ссылка @имя
    var noForward = false               // запрет копирования
    var activity: UserActivity? = nil   // личный чат: «чем занят» собеседник (вместо «был(а) в сети»)
    var isChannel: Bool { type == "channel" }
}

struct GroupMember: Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var username: String?
    var avatarID: String?
    var role: String
}

struct GroupInfo: Equatable {
    let id: String
    var name: String
    var about: String
    var kind: String
    var members: [GroupMember]
    var myRole: String?
    var code: String?
    var type = "group"
    var handle: String? = nil
    var approve = false                 // вступление по заявкам
    var noForward = false               // запретить копирование
    var slow = 0                        // медленный режим, секунд
    var whoWrites = "all"               // "all" | "admins" | "selected"
    var history = true                  // новые участники видят историю
    var count = 0
    var muted = false
    var canWrite = true
    var requests = 0
    var pending = false
    var perms = GroupPerms()            // что участники могут без админки
    var writers: [String] = []          // «писать могут выбранные» (видят только админы)
    var restrictedUntil: Date? = nil    // вам запретили писать: до этого времени (distantFuture — навсегда)
    var discussion: DiscussionRef? = nil    // чат для комментариев канала
    var forum = false                   // группа разделена на темы
    var call: GroupCallBrief? = nil     // идёт групповой звонок / видеочат
    var isOwner: Bool { myRole == "owner" }
    var isAdmin: Bool { myRole == "owner" || myRole == "admin" }
    var isOpen: Bool { kind == "open" }
    var isChannel: Bool { type == "channel" }
    /// Публичная ссылка: @имя, иначе код приглашения
    var linkRef: String? { handle ?? code }
}

/// Каналы, открытые по ссылке: просмотры их постов попадают в статистику как «URL»
enum ChannelViewSource {
    static var openedByLink: Set<String> = []
}

/// Что участники группы могут без админки (как «Разрешения» в Telegram)
struct GroupPerms: Equatable {
    var media = true            // фото, видео, файлы, музыка
    var voice = true            // голосовые и кружки
    var stickers = true         // стикеры и GIF
    var links = true
    var polls = true
    var invite = true           // добавлять участников
    var pin = true              // закреплять сообщения

    var json: [String: Bool] {
        ["media": media, "voice": voice, "stickers": stickers, "links": links, "polls": polls, "invite": invite, "pin": pin]
    }
}

/// Кому в группе запретили писать
struct RestrictedMember: Identifiable, Equatable {
    var id: String { member.id }
    let member: GroupMember
    let until: Date?            // nil — навсегда
}

/// Админ удаляет чужое сообщение: что сделать заодно
struct ModerationOptions {
    var deleteAll = false
    var restrict: Int? = nil    // запретить писать: секунд, 0 — навсегда, nil — нет
    var ban = false
}

/// Статистика канала или группы (как в Telegram)
struct GroupStats {
    struct DayViews { let day: Date; let sources: [String: Int] }
    struct GrowthPoint { let day: Date; let count: Int }
    struct FollowerPoint { let day: Date; let joined: Int; let left: Int }
    struct LangShare { let index: Int; let code: String; let count: Int }
    struct Post: Identifiable { let id: String; let text: String; let createdAt: Date; let views: Int; let reactions: Int; let shares: Int }
    let count: Int
    let countWeekAgo: Int
    let notifyPercent: Double
    let viewsPerPost: Double
    let sharesPerPost: Double
    let reactionsPerPost: Double
    let periodStart: Date
    let periodEnd: Date
    let growth: [GrowthPoint]
    let followers: [FollowerPoint]
    let views: [DayViews]
    let hours: [Int]
    let languages: [LangShare]
    let posts: [Post]
}

/// Чат, привязанный к каналу для комментариев
struct DiscussionRef: Equatable {
    let id: String
    let name: String
}

/// Комментарии к посту канала
struct CommentThread {
    var messages: [ChatMessage]
    var canComment: Bool
    var mirrorID: String? = nil      // копия поста в чате обсуждения: ответы «на пост» — это ответы на неё
}

/// Параметры новой группы или канала
struct GroupDraft: Equatable {
    var type = "group"
    var title = ""
    var about = ""
    var kind = "closed"
    var handle = ""
    var approve = false
    var noForward = false
    var slow = 0
    var whoWrites = "all"
    var history = true
    var perms = GroupPerms()
    var writers: [String] = []
    var forum = false                   // разделить группу на темы
}

/// Что изменить в группе (nil — не трогать)
struct GroupPatch {
    var title: String?
    var about: String?
    var kind: String?
    var handle: String?
    var approve: Bool?
    var noForward: Bool?
    var slow: Int?
    var whoWrites: String?
    var history: Bool?
    var discussion: String?         // id чата для комментариев; "" — отвязать
    var perms: GroupPerms?
    var writers: [String]?
}

/// Заявка на вступление
struct JoinRequest: Identifiable, Equatable {
    var id: String { member.id }
    let member: GroupMember
    let createdAt: Date
}

/// Открытая группа в поиске или по ссылке-приглашению
struct GroupPreview: Identifiable, Equatable {
    let id: String
    var name: String
    var about: String
    var kind: String
    var members: Int
    var joined: Bool
    var type = "group"
    var handle: String? = nil
    var approve = false
    var code: String? = nil
    var pending = false
    var isChannel: Bool { type == "channel" }
}

/// Запись из записной книги телефона
struct BookEntry: Equatable {
    let name: String
    let phone: String
}

/// Человек из записной книги, который уже в Orbita
struct ImportMatch: Identifiable, Equatable {
    let id: String
    var name: String
    var username: String?
    var avatarID: String?
    var bookName: String
    var inContacts: Bool
}

/// «Ваш знакомый теперь в Orbita»
struct JoinNotice: Identifiable, Equatable {
    let id: String
    let userID: String
    var name: String
    var username: String?
    var avatarID: String?
    let createdAt: Date
}

/// Человек, сохранённый в контактах под своим именем
struct Contact: Identifiable, Equatable {
    let id: String
    var name: String
    var realName: String
    var username: String?
    var avatarID: String?
    var phone: String? = nil        // номер, если человек его показывает
    var lastSeen: Date? = nil       // когда был в сети (если показывает)
}

struct ChatSummary: Identifiable, Equatable {
    var id: String { peer.id }
    let peer: ChatPeer
    let unread: Int
    let updatedAt: Date
    let lastText: String
    let lastMine: Bool
    let lastRead: Bool
    let typing: String?             // "typing", "voice", "video", … или nil
    var lastSender: String? = nil   // кто написал последнее (имя), если не вы: «Андрей: привет»
    var muted = false
    var mentions = 0                // непрочитанные «тэги» (@username) — вместо числа ставится значок @
    var lastThumb: LastThumb? = nil // миниатюра фото/видео из последнего сообщения
}

struct LastThumb: Equatable {
    let kind: String                // photo, video, circle
    let mediaID: String
}

struct ReplyRef: Equatable {
    let id: String
    let name: String
    let text: String
    let fromMe: Bool
}

/// Вложение сообщения: фото, видео, кружок, голосовое, файл или стикер
struct ChatAttachment: Identifiable, Equatable {
    enum Kind: String { case photo, video, circle, voice, file, sticker, audio, location, contact }

    let kind: Kind
    var mediaID: String? = nil
    var thumbID: String? = nil
    var width = 0
    var height = 0
    var duration = 0.0
    var size = 0
    var name: String? = nil
    var mime: String? = nil
    var waveform: [Int] = []
    var sticker: String? = nil
    var title: String? = nil                // музыка: название и исполнитель из тегов
    var artist: String? = nil
    var localPreview: Data? = nil           // миниатюра, пока вложение загружается
    var stickerPack: String? = nil          // свой стикер: из какого набора (нажатие — «Добавить набор»)
    var gif = false                         // видео без звука, отправленное как GIF: крутится по кругу
    var geo: GeoPoint? = nil                // геопозиция: точка или трансляция
    var userID: String? = nil               // контакт: чей аккаунт
    var phone: String? = nil
    var username: String? = nil
    var avatarID: String? = nil
    var once = false                        // сгорающее голосовое: получатель слушает один раз
    var consumed = false                    // уже прослушано (у получателя — сгорело; у отправителя — «прослушано»)
    var listened = 0                        // в группе: сколько участников прослушали

    var id: String { kind.rawValue + ":" + (mediaID ?? sticker ?? userID ?? name ?? (once ? "once" : "local")) }
    var aspect: Double { (width > 0 && height > 0) ? Double(width) / Double(height) : 1 }

    /// Для просмотрщика фото и видео
    var mediaItem: MediaItem? {
        guard let mediaID, kind == .photo || kind == .video else { return nil }
        return MediaItem(id: mediaID, kind: kind == .photo ? .image : .video, width: width, height: height,
                         duration: duration > 0 ? duration : nil, thumbID: thumbID)
    }
}

struct MessageReaction: Equatable, Hashable {
    let emoji: String
    var count: Int
    var mine: Bool
}

struct StoryReplyRef: Equatable {
    var id: String
    var mediaID: String
    var isVideo: Bool
}

struct ForwardRef: Equatable {
    var id: String?
    var name: String
    var postID: String?
}

struct PollVoter: Equatable, Identifiable {
    var id: String
    var name: String
    var avatarID: String?
    var at: Date
}

struct PollOption: Equatable, Identifiable {
    var id: Int
    var text: String
    var votes: Int
    var mine: Bool
    var voters: [PollVoter]
}

struct PollInfo: Equatable {
    var multiple: Bool
    var anonymous: Bool
    var closed: Bool
    var total: Int
    var options: [PollOption]
    var mine: Bool          // я создатель
    var quiz = false        // викторина: один правильный ответ
    var correct: Int? = nil // правильный вариант (сервер присылает после ответа)
    var explanation: String? = nil
}

struct MessageInfo: Equatable {
    struct Entry: Equatable, Identifiable {
        var id: String { user.id + (emoji ?? "") }
        var user: ChatPeer
        var emoji: String?
        var at: Date
    }
    var readers: [Entry]
    var total: Int
    var reactions: [Entry]
    var sentAt: Date
}

/// Фото-цепочка: тема дня, фото по кругу, проверка владельцем
struct PhotoChain: Equatable {
    struct Item: Identifiable, Equatable {
        let id: String
        let mediaID: String
        let pending: Bool
        let mine: Bool
        let userID: String
        let name: String
        let avatarID: String?
    }
    var theme: String
    var owner: Bool
    var moderated: Bool
    var closed: Bool
    var items: [Item]
    var pending: [Item]
    var people: Int
}

struct PhotoChainDTO: Decodable {
    struct ItemDTO: Decodable {
        struct U: Decodable { let id: String; let name: String; let avatar: String? }
        let id: String; let mediaId: String; let status: String; let mine: Bool; let user: U
        var model: PhotoChain.Item {
            PhotoChain.Item(id: id, mediaID: mediaId, pending: status == "pending", mine: mine, userID: user.id,
                            name: user.name, avatarID: user.avatar)
        }
    }
    let theme: String; let owner: Bool; let moderated: Bool; let closed: Bool
    let items: [ItemDTO]; let pending: [ItemDTO]; let people: Int?
    var model: PhotoChain {
        PhotoChain(theme: theme, owner: owner, moderated: moderated, closed: closed,
                   items: items.map(\.model), pending: pending.map(\.model), people: people ?? 0)
    }
}

/// Список с галочками: пункты отмечают все участники чата
struct Checklist: Equatable {
    struct Item: Identifiable, Equatable {
        let id: String
        var text: String
        var done: Bool
        var doneByID: String?
        var doneByName: String?
        var doneByAvatar: String?
        var doneByMe: Bool
        var doneAt: Date?
    }
    var owner: Bool
    var othersAdd: Bool
    var items: [Item]
    var doneCount: Int { items.filter(\.done).count }
}

struct ChecklistDTO: Decodable {
    struct ItemDTO: Decodable {
        struct By: Decodable { let id: String; let name: String; let avatar: String?; let me: Bool? }
        let id: String; let text: String; let done: Bool; let doneBy: By?; let doneAt: Double?
        var model: Checklist.Item {
            Checklist.Item(id: id, text: text, done: done, doneByID: doneBy?.id, doneByName: doneBy?.name,
                           doneByAvatar: doneBy?.avatar, doneByMe: doneBy?.me ?? false,
                           doneAt: doneAt.map { Date(timeIntervalSince1970: $0) })
        }
    }
    let owner: Bool; let othersAdd: Bool; let items: [ItemDTO]
    var model: Checklist { Checklist(owner: owner, othersAdd: othersAdd, items: items.map(\.model)) }
}

/// Трек, который человек видел в переписках — для вкладки «Звук»
struct RecentAudio: Identifiable, Equatable, Decodable {
    var id: String { mediaId }
    let messageId: String
    let mediaId: String
    let title: String
    let artist: String
    let duration: Double
    let thumb: String?
    let at: Double
}

/// Своя копия трека из чужого сообщения
struct AudioCopy: Decodable {
    let mediaId: String
    let thumb: String?
    let title: String
    let artist: String
    let name: String
    let duration: Double
}

/// Сообщение перенесено из другого мессенджера
struct ImportedInfo: Equatable {
    var source: String              // Telegram / WhatsApp
    var name: String                // как звали отправителя там
}

/// Замок на сообщении: капсула времени (openAt) и/или секрет на расстоянии (place + radius)
struct MessageLock: Equatable {
    var openAt: Date?
    var open: Bool
    var timeOK: Bool
    var placeOK: Bool
    var place: GeoPoint?
    var radius: Double
    var isCapsule: Bool { openAt != nil }
    var isPlace: Bool { place != nil }
}

/// Что запечатать при отправке
struct OutgoingLock {
    var openAt: Date? = nil
    var place: GeoPoint? = nil
    var radius: Double = 150
    var json: [String: Any] {
        var d: [String: Any] = [:]
        if let openAt { d["open_at"] = openAt.timeIntervalSince1970 }
        if let place {
            d["lat"] = place.lat; d["lon"] = place.lon; d["radius"] = radius
            if let t = place.title { d["title"] = t }
        }
        return d
    }
}

struct ChatMessage: Identifiable, Equatable {
    var key: String                 // устойчивый идентификатор для списка (не меняется при отправке)
    var id: String
    let mine: Bool
    var text: String
    var entities: [TextEntity]
    let createdAt: Date
    var editedAt: Date?
    var read: Bool
    var reply: ReplyRef?
    var attachments: [ChatAttachment] = []
    var isPending = false
    var failed = false              // отправка не прошла из-за сети: висит «Отправляется…» с красным значком, уйдёт сама
    var sender: ChatPeer? = nil     // в группах — кто написал
    var views: Int? = nil           // в каналах — просмотры
    var reactions: [MessageReaction] = []
    var forwarded: ForwardRef? = nil
    var system: String? = nil       // служебное сообщение в группе: left / joined / removed
    var poll: PollInfo? = nil
    var storyReply: StoryReplyRef? = nil
    var comments: Int? = nil        // в канале с обсуждением — число комментариев
    var note: String? = nil         // своя заметка к сообщению: видна только тебе
    var commenters: [ChatPeer] = [] // пост канала: последние комментаторы (аватарки под постом)
    var markup: [[BotButton]] = []  // кнопки под сообщением (бота или кнопки-ссылки человека)
    var blocks: [ArticleBlock] = [] // статья: заголовки, текст, цитаты, таблицы, медиа — по порядку
    var lock: MessageLock? = nil    // капсула времени / секрет на расстоянии
    var sealed = false              // замок ещё закрыт: содержимое сервер не прислал
    var imported: ImportedInfo? = nil   // перенесено из Telegram / WhatsApp
    var chain: PhotoChain? = nil        // фото-цепочка
    var checklist: Checklist? = nil     // список с галочками
    var contact: ChatAttachment? { attachments.first { $0.kind == .contact } }
    var isArticle: Bool { !blocks.isEmpty }

    var summary: String {
        if system != nil { return "" }
        if sealed, let lock { return lock.place != nil && lock.timeOK ? "📍 Секрет" : "⏳ Капсула времени" }
        if poll != nil { return "📊 " + text }
        if checklist != nil { return text }
        if text.hasPrefix("\u{200B}call:") { return "Звонок" }
        if !text.isEmpty { return text }
        guard let first = attachments.first else { return "" }
        switch first.kind {
        case .photo: return "Фото"
        case .video: return "Видео"
        case .circle: return "Видеосообщение"
        case .voice: return "Голосовое сообщение"
        case .sticker: return "Стикер"
        case .file: return first.name ?? "Файл"
        case .audio: return first.title ?? first.name ?? "Музыка"
        case .location: return first.geo?.isLive == true ? "📍 Трансляция геопозиции" : "📍 " + (first.geo?.title ?? "Геопозиция")
        case .contact: return "👤 " + (first.name ?? "Контакт")
        }
    }
}

struct ChatThread {
    var messages: [ChatMessage]
    var peer: ChatPeer
    var lastSeen: Date?
    var typing: String?
    var canWrite: Bool
    var group: GroupInfo? = nil
    var isContact = false
    var realName: String? = nil
    var pinned: [ChatMessage] = []
    var firstUnread: String? = nil  // первое непрочитанное при входе — для плашки «Новые сообщения»
    var unread: Int? = nil          // сколько всего непрочитанных (может быть больше, чем загружено сообщений)
    var isPreview = false           // открытый канал/группа просматривается без вступления
    var ttl: Int = 0                // таймер исчезающих сообщений (секунды), 0 — выключен
    var botCommands: [BotCommand] = []  // переписка с ботом: его команды (меню «/»)
    var bot: BotInfo? = nil             // переписка с ботом: приветствие, «Старт», пользователи
    var botKeyboard: BotKeyboard? = nil // клавиатура бота вместо обычной
}

struct Sticker: Identifiable, Equatable, Hashable {
    let id: String                  // "пак/имя" — встроенный, "u:<id>" — свой (созданный через бота @stickers)
    let emoji: String
    var mediaID: String? = nil      // свой стикер: файл на сервере (картинка или видео)
    var animated = false            // свой анимированный: видео без звука по кругу (или Lottie у эмодзи)
    var packID: String? = nil
    var lottie = false              // своё эмодзи: анимация Lottie (JSON, на сервере хранится сжатым)
    var url: URL? { ServerConfig.baseURL.flatMap { URL(string: $0.absoluteString + "/stickers/" + id + ".png") } }
}

/// Бот @stickers: создание своих стикерпаков (как в Telegram)
enum StickerBot {
    static let id = "5717c4e5-0000-4000-8000-00000000057c"
    static var peer: ChatPeer { ChatPeer(id: id, name: "Стикеры", username: "stickers", avatarID: nil) }
}

/// Свой набор стикеров: что в нём и добавлен ли он у меня
struct CustomStickerPack: Identifiable, Equatable {
    let pack: StickerPack
    var installed: Bool
    let mine: Bool
    var id: String { pack.id }
}

struct StickerPack: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    let stickers: [Sticker]
    var mine = false            // мой набор (можно редактировать/удалять)
    var kind = "sticker"        // "sticker" — стикеры, "emoji" — свои эмодзи (вставляются прямо в текст)
    var isEmoji: Bool { kind == "emoji" }
}

/// Что загрузить на сервер перед отправкой
/// Геопозиция во вложении. Для трансляции — последняя присланная точка и до какого времени идёт
struct GeoPoint: Equatable {
    var lat: Double
    var lon: Double
    var accuracy: Double? = nil
    var heading: Double? = nil
    var title: String? = nil
    var liveUntil: Date? = nil
    var updatedAt: Date? = nil
    var stopped = false

    var isLive: Bool { liveUntil != nil }
    /// Трансляция идёт прямо сейчас
    func active(at now: Date = Date()) -> Bool { !stopped && (liveUntil.map { $0 > now } ?? false) }
}

enum OutgoingMedia {
    case prepared(PreparedMedia)                                  // фото или видео
    case circle(url: URL, thumb: Data, duration: Double)
    case voice(url: URL, duration: Double, waveform: [Int])
    case file(url: URL, name: String, mime: String)
    case audio(url: URL, name: String, title: String, artist: String, duration: Double, cover: Data?)
    case sticker(String)
    /// live — 0 (просто точка) или длительность трансляции в секундах (900 / 3600 / 28800)
    case location(GeoPoint, live: Int)
}

/// Загруженное вложение, готовое к отправке
struct OutgoingAttachment {
    let type: String
    var mediaID: String? = nil
    var name: String? = nil
    var sticker: String? = nil
    var waveform: [Int]? = nil
    var title: String? = nil
    var artist: String? = nil
    var thumb: String? = nil
    var gif = false
    var geo: GeoPoint? = nil
    var live = 0
    var userID: String? = nil           // контакт
    var phone: String? = nil
    var once = false                    // сгорающее голосовое

    var json: [String: Any] {
        var d: [String: Any] = ["type": type]
        if once { d["once"] = true }
        if let userID { d["user_id"] = userID }
        if let phone { d["phone"] = phone }
        if let geo {
            d["lat"] = geo.lat
            d["lon"] = geo.lon
            if let a = geo.accuracy { d["acc"] = a }
            if let h = geo.heading { d["heading"] = h }
            if let t = geo.title { d["title"] = t }
            if live > 0 { d["live"] = live }
        }
        if let mediaID { d["media_id"] = mediaID }
        if let name { d["name"] = name }
        if let sticker { d["sticker"] = sticker }
        if let waveform { d["waveform"] = waveform }
        if let title { d["title"] = title }
        if let artist { d["artist"] = artist }
        if let thumb { d["thumb"] = thumb }
        if gif { d["gif"] = true }
        return d
    }
}

/// Пересказ пропущенного: текст пунктами, написан ли ИИ, сколько сообщений охвачено
struct UnreadDigest: Decodable, Equatable {
    let summary: String
    let ai: Bool
    let count: Int
    let truncated: Bool?
}

protocol MessengerRepository: Sendable {
    func chats() async throws -> (chats: [ChatSummary], unread: Int)
    /// topic — тема группы-форума ("general" — общая); nil — вся переписка
    func thread(peerID: String, limit: Int, peek: Bool, topic: String?) async throws -> ChatThread
    /// Прочитано до сообщения (включительно) или всё; ответ — сколько осталось непрочитанных
    func markRead(peerID: String, upTo: String?) async -> Int?
    /// Сохранённые на телефоне копии — без сети и без ожидания (nil — ещё ни разу не загружали)
    func cachedChats() -> (chats: [ChatSummary], unread: Int)?
    func cachedThread(peerID: String) -> ChatThread?
    func cachedThread(peerID: String, topic: String) -> ChatThread?
    func react(messageID: String, emoji: String?) async throws -> ChatMessage
    func pin(messageID: String, pinned: Bool) async throws -> [ChatMessage]
    func setNote(messageID: String, text: String) async throws -> ChatMessage
    func setChatTTL(peerID: String, seconds: Int) async throws -> Int
    /// Личная переписка: запретить копирование и пересылку (включить/выключить)
    func setChatProtected(peerID: String, on: Bool) async throws -> Bool
    /// Нажали кнопку под сообщением бота: ответ бота (подсказка, окно или ссылка)
    func botCallback(messageID: String, data: String) async throws -> BotCallbackAnswer
    /// Статья: блоки (медиа уже загружены) и кнопки-ссылки под сообщением — рядами (до двух в ряду)
    func sendArticle(peerID: String, blocks: [[String: Any]], buttons: [[[String: Any]]], replyTo: String?,
                     topic: String?) async throws -> ChatMessage
    /// «Кратко»: пересказ сообщений начиная с `from` (первое непрочитанное)
    func unreadDigest(peerID: String, from messageID: String) async throws -> UnreadDigest
    func send(peerID: String, text: String, entities: [TextEntity], attachments: [OutgoingAttachment],
              replyTo: String?, silent: Bool, topic: String?) async throws -> ChatMessage
    func upload(_ media: OutgoingMedia) async throws -> OutgoingAttachment
    /// Капсула времени / секрет на расстоянии (текст)
    func sendLocked(peerID: String, text: String, entities: [TextEntity], lock: OutgoingLock) async throws -> ChatMessage
    /// Получатель на месте — открыть секрет. Далеко — ошибка с расстоянием
    func unlock(messageID: String, point: GeoPoint) async throws -> ChatMessage
    /// Экспорт: страница истории до момента `before` (старые → новые), есть ли ещё и откуда продолжать
    func exportPage(peerID: String, before: Double?) async throws -> (messages: [ChatMessage], more: Bool, before: Double?)
    /// Импорт: пачка сообщений из Telegram / WhatsApp, возвращает сколько добавлено
    func importBatch(peerID: String, source: String, messages: [[String: Any]]) async throws -> Int
    // фото-цепочка
    func sendChain(peerID: String, theme: String, moderated: Bool) async throws -> ChatMessage
    func chainAdd(messageID: String, mediaID: String) async throws -> PhotoChain
    func chainApprove(messageID: String, itemID: String) async throws -> PhotoChain
    func chainRemove(messageID: String, itemID: String) async throws -> PhotoChain
    func chainSettings(messageID: String, moderated: Bool?, closed: Bool?) async throws -> PhotoChain
    func chainReel(messageID: String) async throws
    // список с галочками
    func sendChecklist(peerID: String, title: String, items: [String], othersAdd: Bool) async throws -> ChatMessage
    func checklistToggle(messageID: String, itemID: String) async throws -> Checklist
    func checklistAdd(messageID: String, text: String) async throws -> Checklist
    // «Звук»: недавняя музыка из переписок и своя копия трека
    func recentAudio() async throws -> [RecentAudio]
    func audioCopy(messageID: String, mediaID: String) async throws -> AudioCopy
    func playlistCopy(trackID: String) async throws -> AudioCopy
    /// Сгорающее голосовое: открыть один раз (файл выдаётся только сейчас) и «сжечь» после прослушивания
    func onceOpen(messageID: String) async throws -> String
    func onceDone(messageID: String) async
    // темы в группах
    func topics(groupID: String) async throws -> ForumTopicList
    func createTopic(groupID: String, title: String, icon: String?, color: Int) async throws -> ForumTopic
    func updateTopic(groupID: String, topicID: String, fields: [String: Any]) async throws -> ForumTopic
    func deleteTopic(groupID: String, topicID: String) async throws
    func setForum(groupID: String, on: Bool) async throws -> Bool
    /// Трансляция геопозиции: новая точка / остановить
    func updateLiveLocation(messageID: String, point: GeoPoint) async throws
    func stopLiveLocation(messageID: String) async throws
    func edit(messageID: String, text: String, entities: [TextEntity]) async throws -> ChatMessage
    func delete(messageID: String, forEveryone: Bool) async throws
    func typing(peerID: String, action: String) async
    /// Только «печатает…» собеседника — без загрузки всей переписки
    func typingStatus(peerID: String) async throws -> String?
    /// forEveryone — переписка пропадает и у собеседника (только личные чаты)
    func clear(peerID: String, forEveryone: Bool) async throws
    func stickers() async throws -> [StickerPack]
    /// Наборы, сохранённые на телефоне (сразу, без сети); nil — ещё не сохраняли
    func savedStickers() -> [StickerPack]?
    func stickerPack(id: String) async throws -> CustomStickerPack
    func setStickerPack(id: String, installed: Bool) async throws -> CustomStickerPack
    func createStickerPack(title: String) async throws -> CustomStickerPack
    func addSticker(packID: String, mediaID: String, emoji: String) async throws
    func deleteSticker(packID: String, stickerID: String) async throws
    func deleteStickerPack(id: String) async throws

    // контакты
    func contacts() async throws -> [Contact]
    /// Поиск в мессенджере: частые собеседники за месяц и боты
    func searchHub() async throws -> SearchHub
    /// Всё присланное во всех чатах: media | files | links | music | voice
    func shared(kind: String, before: Double?) async throws -> (items: [SharedEntry], before: Double?, more: Bool)
    /// Фильтр списка чатов («фокус»): пока выбран, сервер не шлёт уведомления из неподходящих чатов (nil — все)
    func setChatFocus(_ folder: String?) async
    /// У кого из контактов сегодня день рождения (today — «MM-dd» по часам телефона)
    func birthdays(today: String) async throws -> [BirthdayPerson]
    func saveContact(id: String, name: String) async throws -> Contact
    func deleteContact(id: String) async throws

    // группы
    func createGroup(_ draft: GroupDraft, members: [String]) async throws -> GroupInfo
    func group(id: String) async throws -> GroupInfo
    func editGroup(id: String, patch: GroupPatch) async throws -> GroupInfo
    func invite(groupID: String, userIDs: [String]) async throws -> GroupInfo
    func removeMember(groupID: String, userID: String) async throws
    func setRole(groupID: String, userID: String, role: String) async throws -> GroupInfo
    func joinRequests(groupID: String) async throws -> [JoinRequest]
    func answerRequest(groupID: String, userID: String, approve: Bool) async throws -> GroupInfo
    func bannedUsers(groupID: String) async throws -> [GroupMember]
    func unban(groupID: String, userID: String) async throws
    func moderate(groupID: String, userID: String, messageID: String?, options: ModerationOptions) async throws
    func restricted(groupID: String) async throws -> [RestrictedMember]
    func unrestrict(groupID: String, userID: String) async throws
    func stats(groupID: String, days: Int) async throws -> GroupStats
    func setMuted(groupID: String, muted: Bool) async throws
    func deleteGroup(id: String) async throws
    func comments(channelID: String, messageID: String) async throws -> CommentThread
    func postComment(channelID: String, messageID: String, text: String, replyTo: String?) async throws -> ChatMessage

    // импорт записной книги и уведомления «теперь в Orbita»
    func importContacts(_ entries: [BookEntry]) async throws -> [ImportMatch]
    func forgetImportedContacts() async throws
    func notices() async throws -> [JoinNotice]
    func dismissNotices(ids: [String]) async throws
    func publicGroups(query: String, type: String?) async throws -> [GroupPreview]
    func searchMessages(query: String) async throws -> [MessageHit]
    /// scope: all | personal | groups | channels
    func searchMessages(query: String, scope: String) async throws -> [MessageHit]
    func groupPreview(code: String) async throws -> GroupPreview
    func joinGroup(code: String) async throws -> GroupInfo
    func joinGroup(id: String) async throws -> GroupInfo

    // музыка из переписки — в профиль
    func addToProfile(messageID: String, mediaID: String, title: String, artist: String) async throws -> Track
}

extension MessengerRepository {
    func savedStickers() -> [StickerPack]? { nil }
    func searchMessages(query: String) async throws -> [MessageHit] { [] }
    func searchMessages(query: String, scope: String) async throws -> [MessageHit] { try await searchMessages(query: query) }

    func thread(peerID: String) async throws -> ChatThread { try await thread(peerID: peerID, limit: 100, peek: false) }
    func thread(peerID: String, limit: Int) async throws -> ChatThread { try await thread(peerID: peerID, limit: limit, peek: false) }
    func thread(peerID: String, limit: Int, peek: Bool) async throws -> ChatThread {
        try await thread(peerID: peerID, limit: limit, peek: peek, topic: nil)
    }
    func send(peerID: String, text: String, entities: [TextEntity], attachments: [OutgoingAttachment],
              replyTo: String?, silent: Bool) async throws -> ChatMessage {
        try await send(peerID: peerID, text: text, entities: entities, attachments: attachments, replyTo: replyTo,
                       silent: silent, topic: nil)
    }

    /// Обычное текстовое сообщение
    func send(peerID: String, text: String, replyTo: String?) async throws -> ChatMessage {
        try await send(peerID: peerID, text: text, entities: [], attachments: [], replyTo: replyTo, silent: false)
    }
}

// MARK: - DTO

private struct PeerDTO: Decodable {
    let id: String
    let name: String
    let username: String?
    let avatar: String?
    let group: Bool?
    let kind: String?
    let members: Int?
    let type: String?
    let handle: String?
    let noForward: Bool?
    let activity: ActivityDTO?
    var model: ChatPeer {
        ChatPeer(id: id, name: name, username: username, avatarID: avatar,
                 isGroup: group ?? false, kind: kind, memberCount: members ?? 0,
                 type: type, handle: handle, noForward: noForward ?? false, activity: activity?.model)
    }
}

private struct LastDTO: Decodable {
    struct Thumb: Decodable { let type: String; let media: String }
    let text: String
    let mine: Bool
    let read: Bool
    let createdAt: Double
    let thumb: Thumb?
    let who: String?
}

private struct ChatDTO: Decodable {
    let peer: PeerDTO
    let unread: Int
    let updatedAt: Double
    let last: LastDTO
    let typing: String?
    let muted: Bool?
    let mentions: Int?
}

private struct MessageHitDTO: Decodable {
    let id: String
    let peer: PeerDTO
    let text: String
    let mine: Bool
    let createdAt: Double
    let sender: String?
}

private struct MessageHitListDTO: Decodable { let hits: [MessageHitDTO] }

private struct ChatListDTO: Decodable {
    let chats: [ChatDTO]
    let unread: Int
}

private struct ReplyDTO: Decodable {
    let id: String
    let fromMe: Bool
    let name: String
    let text: String
}

/// Поиск в мессенджере: с кем больше всего переписывался за месяц и с какими ботами общался
struct SearchHub: Decodable, Equatable {
    struct Person: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
        let username: String?
        let avatar: String?
        let count: Int?
        let monthly: Int?
        var peer: ChatPeer { ChatPeer(id: id, name: name, username: username, avatarID: avatar) }
    }
    let top: [Person]
    let bots: [Person]
}

/// Одно присланное (медиа, файл, ссылка, трек, голосовое) с чатом, откуда оно
struct SharedEntry: Identifiable, Equatable {
    let messageID: String
    let chat: ChatPeer
    let at: Date
    let mine: Bool
    let sender: String
    var attachment: ChatAttachment?
    var url: String?
    var text: String?
    var id: String { messageID + ":" + (attachment?.mediaID ?? url ?? "") }
}

private struct SharedEntryDTO: Decodable {
    struct Chat: Decodable { let id: String; let name: String; let avatar: String?; let group: Bool; let channel: Bool }
    let messageId: String
    let chat: Chat
    let at: Double
    let mine: Bool
    let sender: String
    let attachment: AttachmentDTO?
    let url: String?
    let text: String?
    var model: SharedEntry {
        SharedEntry(messageID: messageId,
                    chat: ChatPeer(id: chat.id, name: chat.name, avatarID: chat.avatar, isGroup: chat.group,
                                   type: chat.group ? (chat.channel ? "channel" : "group") : nil),
                    at: Date(timeIntervalSince1970: at), mine: mine, sender: sender,
                    attachment: attachment?.model, url: url, text: text)
    }
}

private struct AttachmentDTO: Decodable {
    let type: String
    let mediaId: String?
    let thumb: String?
    let width: Int?
    let height: Int?
    let duration: Double?
    let size: Int?
    let name: String?
    let mime: String?
    let waveform: [Int]?
    let sticker: String?
    let title: String?
    let artist: String?
    let pack: String?
    let gif: Bool?
    let lat: Double?
    let lon: Double?
    let acc: Double?
    let heading: Double?
    let liveUntil: Double?
    let updatedAt: Double?
    let stopped: Bool?
    let userId: String?
    let phone: String?
    let username: String?
    let avatar: String?
    let once: Bool?
    let consumed: Bool?
    let listened: Int?

    var model: ChatAttachment? {
        guard let kind = ChatAttachment.Kind(rawValue: type) else { return nil }
        var geo: GeoPoint?
        if kind == .location {
            guard let lat, let lon else { return nil }
            geo = GeoPoint(lat: lat, lon: lon, accuracy: acc, heading: heading, title: title,
                           liveUntil: liveUntil.map { Date(timeIntervalSince1970: $0) },
                           updatedAt: updatedAt.map { Date(timeIntervalSince1970: $0) }, stopped: stopped ?? false)
        }
        return ChatAttachment(kind: kind, mediaID: mediaId, thumbID: thumb, width: width ?? 0, height: height ?? 0,
                              duration: duration ?? 0, size: size ?? 0, name: name, mime: mime,
                              waveform: waveform ?? [], sticker: sticker, title: kind == .location ? nil : title, artist: artist,
                              stickerPack: pack, gif: gif ?? false, geo: geo,
                              userID: userId, phone: phone, username: username, avatarID: avatar,
                              once: once ?? false, consumed: consumed ?? false, listened: listened ?? 0)
    }
}

private struct ReactionDTO: Decodable { let emoji: String; let count: Int; let mine: Bool }

struct StoryReplyDTO: Decodable { let id: String; let mediaId: String; let kind: String }
struct ForwardDTO: Decodable { let id: String?; let name: String; let post: String? }

struct PollVoterDTO: Decodable {
    let id: String; let name: String; let avatar: String?; let at: Double
}
struct PollOptionDTO: Decodable {
    let idx: Int; let text: String; let votes: Int; let mine: Bool; let voters: [PollVoterDTO]?
}
struct PollDTO: Decodable {
    let multiple: Bool; let anonymous: Bool; let closed: Bool; let total: Int
    let options: [PollOptionDTO]; let mineCreated: Bool
    let quiz: Bool?; let correct: Int?; let explanation: String?
    var model: PollInfo {
        PollInfo(multiple: multiple, anonymous: anonymous, closed: closed, total: total,
                 options: options.map { o in
                     PollOption(id: o.idx, text: o.text, votes: o.votes, mine: o.mine,
                                voters: (o.voters ?? []).map { PollVoter(id: $0.id, name: $0.name, avatarID: $0.avatar, at: Date(timeIntervalSince1970: $0.at)) })
                 }, mine: mineCreated, quiz: quiz ?? false, correct: correct, explanation: explanation)
    }
}

struct InfoEntryDTO: Decodable {
    let id: String; let name: String; let username: String?; let avatar: String?
    let emoji: String?; let at: Double
}
struct MessageInfoDTO: Decodable {
    let readers: [InfoEntryDTO]; let total: Int; let reactions: [InfoEntryDTO]; let sentAt: Double
    var model: MessageInfo {
        func map(_ e: InfoEntryDTO) -> MessageInfo.Entry {
            MessageInfo.Entry(user: ChatPeer(id: e.id, name: e.name, username: e.username, avatarID: e.avatar),
                              emoji: e.emoji, at: Date(timeIntervalSince1970: e.at))
        }
        return MessageInfo(readers: readers.map(map), total: total, reactions: reactions.map(map),
                           sentAt: Date(timeIntervalSince1970: sentAt))
    }
}

private struct MessageDTO: Decodable {
    let id: String
    let mine: Bool
    let text: String
    let entities: [TextEntity]
    let createdAt: Double
    let editedAt: Double?
    let read: Bool
    let reply: ReplyDTO?
    let attachments: [AttachmentDTO]?
    let sender: PeerDTO?
    let views: Int?
    let reactions: [ReactionDTO]?
    let forwarded: ForwardDTO?
    let system: String?
    let poll: PollDTO?
    let storyReply: StoryReplyDTO?
    let comments: Int?
    let note: String?
    let commenters: [PeerDTO]?
    let markup: [[BotButton]]?
    let blocks: [ArticleBlockDTO]?
    let lock: LockDTO?
    let sealed: Bool?
    let imported: ImportedDTO?
    struct ImportedDTO: Decodable { let source: String; let name: String? }
    let chain: PhotoChainDTO?
    let checklist: ChecklistDTO?

    struct LockDTO: Decodable {
        struct Place: Decodable { let lat: Double; let lon: Double; let title: String? }
        let openAt: Double?
        let open: Bool
        let timeOk: Bool?
        let placeOk: Bool?
        let place: Place?
        let radius: Double?
        var model: MessageLock {
            MessageLock(openAt: openAt.map { Date(timeIntervalSince1970: $0) }, open: open, timeOK: timeOk ?? true,
                        placeOK: placeOk ?? true, place: place.map { GeoPoint(lat: $0.lat, lon: $0.lon, title: $0.title) },
                        radius: radius ?? 150)
        }
    }

    var model: ChatMessage {
        ChatMessage(key: id, id: id, mine: mine, text: text, entities: entities,
                    createdAt: Date(timeIntervalSince1970: createdAt),
                    editedAt: editedAt.map { Date(timeIntervalSince1970: $0) }, read: read,
                    reply: reply.map { ReplyRef(id: $0.id, name: $0.name, text: $0.text, fromMe: $0.fromMe) },
                    attachments: (attachments ?? []).compactMap(\.model), sender: sender?.model, views: views,
                    reactions: (reactions ?? []).map { MessageReaction(emoji: $0.emoji, count: $0.count, mine: $0.mine) },
                    forwarded: forwarded.map { ForwardRef(id: $0.id, name: $0.name, postID: $0.post) },
                    system: system, poll: poll?.model,
                    storyReply: storyReply.map { StoryReplyRef(id: $0.id, mediaID: $0.mediaId, isVideo: $0.kind == "video") },
                    comments: comments, note: note, commenters: (commenters ?? []).map(\.model),
                    markup: markup ?? [], blocks: (blocks ?? []).compactMap(\.model),
                    lock: lock?.model, sealed: sealed ?? false,
                    imported: imported.map { ImportedInfo(source: $0.source, name: $0.name ?? "") },
                    chain: chain?.model, checklist: checklist?.model)
    }
}

private struct ArticleBlockDTO: Decodable {
    struct Item: Decodable { let text: String; let checked: Bool? }
    let kind: String
    let text: String?
    let level: Int?
    let author: String?
    let lang: String?
    let url: String?
    let color: String?
    let style: String?
    let items: [Item]?
    let body: String?
    let rows: [[String]]?
    let header: Bool?
    let caption: String?
    let media: AttachmentDTO?

    var model: ArticleBlock? {
        guard let k = ArticleBlock.Kind(rawValue: kind) else { return nil }
        var b = ArticleBlock(kind: k)
        b.text = text ?? ""
        b.level = level ?? 1
        b.author = author ?? ""
        b.lang = lang ?? ""
        b.url = url ?? ""
        b.color = color ?? "default"
        b.style = style ?? "bullet"
        b.items = (items ?? []).map { ArticleListItem(text: $0.text, checked: $0.checked ?? false) }
        b.body = body ?? ""
        b.rows = rows ?? []
        b.header = header ?? true
        b.caption = caption ?? ""
        b.media = media?.model
        if k == .media && b.media == nil { return nil }
        return b
    }
}

private struct ThreadPeerDTO: Decodable {
    let id: String
    let name: String
    let username: String?
    let avatar: String?
    let lastSeen: Double?
    let group: Bool?
    let kind: String?
    let members: Int?
    let type: String?
    let handle: String?
    let noForward: Bool?
    let isContact: Bool?
    let firstName: String?
    let lastName: String?
}

private struct MemberDTO: Decodable {
    let id: String
    let name: String
    let username: String?
    let avatar: String?
    let role: String
    var model: GroupMember { GroupMember(id: id, name: name, username: username, avatarID: avatar, role: role) }
}

private struct DiscussionDTO: Decodable { let id: String; let name: String }
private struct CommentThreadDTO: Decodable { let messages: [MessageDTO]; let canComment: Bool; let mirror: String? }

private struct GroupDTO: Decodable {
    let id: String
    let name: String
    let about: String
    let kind: String
    let members: [MemberDTO]
    let myRole: String?
    let code: String?
    let type: String?
    let handle: String?
    let approve: Bool?
    let noForward: Bool?
    let slow: Int?
    let whoWrites: String?
    let history: Bool?
    let count: Int?
    let muted: Bool?
    let canWrite: Bool?
    let requests: Int?
    let pending: Bool?
    let discussion: DiscussionDTO?
    let perms: [String: Bool]?
    let writers: [String]?
    let restrictedUntil: Double?
    let forum: Bool?
    let call: GroupCallBrief?
    var model: GroupInfo {
        GroupInfo(id: id, name: name, about: about, kind: kind, members: members.map(\.model), myRole: myRole, code: code,
                  type: type ?? "group", handle: handle, approve: approve ?? false, noForward: noForward ?? false,
                  slow: slow ?? 0, whoWrites: whoWrites ?? "all", history: history ?? true, count: count ?? members.count,
                  muted: muted ?? false, canWrite: canWrite ?? true, requests: requests ?? 0, pending: pending ?? false,
                  perms: perms.map { p in GroupPerms(media: p["media"] ?? true, voice: p["voice"] ?? true, stickers: p["stickers"] ?? true,
                                                     links: p["links"] ?? true, polls: p["polls"] ?? true, invite: p["invite"] ?? true,
                                                     pin: p["pin"] ?? true) } ?? GroupPerms(),
                  writers: writers ?? [],
                  restrictedUntil: restrictedUntil.map { $0 > 0 ? Date(timeIntervalSince1970: $0) : .distantFuture },
                  discussion: discussion.map { DiscussionRef(id: $0.id, name: $0.name) }, forum: forum ?? false, call: call)
    }
}

private struct RestrictedListDTO: Decodable {
    struct Item: Decodable { let user: MemberDTOLite; let until: Double }
    let restricted: [Item]
}

private struct GroupStatsDTO: Decodable {
    struct PostDTO: Decodable { let id: String; let text: String; let createdAt: Double; let views: Int; let reactions: Int; let shares: Int }
    struct DayViewsDTO: Decodable {
        let day: Double
        let sources: [String: Int]
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            day = try c.decode(Double.self)
            sources = try c.decode([String: Int].self)
        }
    }
    let period: [Double]
    let count: Int
    let countWeekAgo: Int
    let notifyPct: Double
    let viewsPerPost: Double
    let sharesPerPost: Double
    let reactionsPerPost: Double
    let growth: [[Double]]
    let followers: [[Double]]
    let views: [DayViewsDTO]
    let hours: [Int]
    let languagesRaw: [LangDTO]?
    let posts: [PostDTO]

    struct LangDTO: Decodable {
        let code: String
        let count: Int
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            code = try c.decode(String.self)
            count = try c.decode(Int.self)
        }
    }

    enum CodingKeys: String, CodingKey {
        case period, count, countWeekAgo, notifyPct, viewsPerPost, sharesPerPost, reactionsPerPost, growth, followers, views, hours, posts
        case languagesRaw = "languages"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        period = try c.decode([Double].self, forKey: .period)
        count = try c.decode(Int.self, forKey: .count)
        countWeekAgo = try c.decode(Int.self, forKey: .countWeekAgo)
        notifyPct = try c.decode(Double.self, forKey: .notifyPct)
        viewsPerPost = try c.decode(Double.self, forKey: .viewsPerPost)
        sharesPerPost = try c.decode(Double.self, forKey: .sharesPerPost)
        reactionsPerPost = try c.decode(Double.self, forKey: .reactionsPerPost)
        growth = try c.decode([[Double]].self, forKey: .growth)
        followers = try c.decode([[Double]].self, forKey: .followers)
        views = try c.decode([DayViewsDTO].self, forKey: .views)
        hours = try c.decode([Int].self, forKey: .hours)
        languagesRaw = try c.decodeIfPresent([LangDTO].self, forKey: .languagesRaw)
        posts = try c.decode([PostDTO].self, forKey: .posts)
    }

    var model: GroupStats {
        let date = { (t: Double) in Date(timeIntervalSince1970: t) }
        return GroupStats(count: count, countWeekAgo: countWeekAgo, notifyPercent: notifyPct, viewsPerPost: viewsPerPost,
                          sharesPerPost: sharesPerPost, reactionsPerPost: reactionsPerPost,
                          periodStart: date(period.first ?? 0), periodEnd: date(period.last ?? 0),
                          growth: growth.compactMap { $0.count >= 2 ? GroupStats.GrowthPoint(day: date($0[0]), count: Int($0[1])) : nil },
                          followers: followers.compactMap {
                              $0.count >= 3 ? GroupStats.FollowerPoint(day: date($0[0]), joined: Int($0[1]), left: Int($0[2])) : nil
                          },
                          views: views.map { GroupStats.DayViews(day: date($0.day), sources: $0.sources) },
                          hours: hours.count == 24 ? hours : Array(repeating: 0, count: 24),
                          languages: (languagesRaw ?? []).enumerated().map { GroupStats.LangShare(index: $0.offset, code: $0.element.code,
                                                                                                count: $0.element.count) },
                          posts: posts.map { GroupStats.Post(id: $0.id, text: $0.text, createdAt: date($0.createdAt), views: $0.views,
                                                             reactions: $0.reactions, shares: $0.shares) })
    }
}

private struct JoinRequestDTO: Decodable {
    let user: MemberDTOLite
    let createdAt: Double
}
private struct MemberDTOLite: Decodable {
    let id: String
    let name: String
    let username: String?
    let avatar: String?
    var model: GroupMember { GroupMember(id: id, name: name, username: username, avatarID: avatar, role: "member") }
}
private struct ImportMatchDTO: Decodable {
    let user: MemberDTOLite
    let bookName: String?
    let inContacts: Bool?
}
private struct ImportDTO: Decodable { let matches: [ImportMatchDTO] }
private struct NoticeDTO: Decodable {
    let id: String
    let name: String?
    let createdAt: Double
    let user: MemberDTOLite
}
private struct NoticeListDTO: Decodable { let notices: [NoticeDTO] }
private struct JoinRequestListDTO: Decodable { let requests: [JoinRequestDTO] }
private struct BanListDTO: Decodable { let users: [MemberDTOLite] }

private struct GroupPreviewDTO: Decodable {
    let id: String
    let name: String
    let about: String?
    let kind: String?
    let members: Int?
    let joined: Bool?
    let type: String?
    let handle: String?
    let approve: Bool?
    let code: String?
    let pending: Bool?
    var model: GroupPreview {
        GroupPreview(id: id, name: name, about: about ?? "", kind: kind ?? "closed", members: members ?? 0,
                     joined: joined ?? false, type: type ?? "group", handle: handle, approve: approve ?? false,
                     code: code, pending: pending ?? false)
    }
}

private struct GroupPreviewListDTO: Decodable { let groups: [GroupPreviewDTO] }

private struct ContactDTO: Decodable {
    let id: String
    let name: String
    let realName: String
    let username: String?
    let avatar: String?
    let phone: String?
    let lastSeen: Double?
    var model: Contact {
        Contact(id: id, name: name, realName: realName, username: username, avatarID: avatar, phone: phone,
                lastSeen: lastSeen.map { Date(timeIntervalSince1970: $0) })
    }
}

private struct ContactListDTO: Decodable { let contacts: [ContactDTO] }

private struct ThreadDTO: Decodable {
    let messages: [MessageDTO]
    let peer: ThreadPeerDTO
    let typing: String?
    let canWrite: Bool
    let group: GroupDTO?
    let pinned: [MessageDTO]?
    let preview: Bool?
    let firstUnread: String?
    let unread: Int?
    let ttl: Int?
    let botCommands: [BotCommand]?
    let bot: BotInfo?
    let botKeyboard: BotKeyboard?
    let `protected`: Bool?                  // личная переписка: запрещено копирование и пересылка
}

private struct PinnedDTO: Decodable { let pinned: [MessageDTO] }

private struct StickerDTO: Decodable {
    let id: String; let emoji: String; let mediaId: String?; let animated: Bool?; let lottie: Bool?
}
private struct PackDTO: Decodable {
    let id: String; let title: String; let icon: String; let stickers: [StickerDTO]
    let mine: Bool?; let installed: Bool?; let kind: String?
    var model: StickerPack {
        StickerPack(id: id, title: title, icon: icon,
                    stickers: stickers.map { Sticker(id: $0.id, emoji: $0.emoji, mediaID: $0.mediaId, animated: $0.animated ?? false,
                                                     packID: id, lottie: $0.lottie ?? false) },
                    mine: mine ?? false, kind: kind ?? "sticker")
    }
}
private struct PackListDTO: Decodable { let packs: [PackDTO] }
private struct UploadedDTO: Decodable { let id: String }

// MARK: - Реализация

struct RemoteMessengerRepository: MessengerRepository {
    let api: ServerAPI

    func chats() async throws -> (chats: [ChatSummary], unread: Int) {
        try decodeChats(try await api.requestCached("/v1/chats"))
    }

    func cachedChats() -> (chats: [ChatSummary], unread: Int)? {
        api.cachedResponse("/v1/chats").flatMap { try? decodeChats($0) }
    }

    func cachedThread(peerID: String) -> ChatThread? {
        api.cachedResponse("/v1/chats/\(peerID)/messages", slot: "", fallback: ["p"]).flatMap { try? decodeThread($0) }
    }

    private func decodeChats(_ data: Data) throws -> (chats: [ChatSummary], unread: Int) {
        let dto = try decodeAPI(ChatListDTO.self, from: data)
        let list = dto.chats.map {
            ChatSummary(peer: $0.peer.model, unread: $0.unread, updatedAt: Date(timeIntervalSince1970: $0.updatedAt),
                        lastText: $0.last.text, lastMine: $0.last.mine, lastRead: $0.last.read, typing: $0.typing,
                        lastSender: $0.last.who, muted: $0.muted ?? false,
                        mentions: $0.mentions ?? 0, lastThumb: $0.last.thumb.map { LastThumb(kind: $0.type, mediaID: $0.media) })
        }
        return (list, dto.unread)
    }

    func react(messageID: String, emoji: String?) async throws -> ChatMessage {
        let body = ServerAPI.json(["emoji": emoji ?? ""] as [String: Any])
        let data = try await api.request("PUT", "/v1/messages/\(messageID)/reaction", body: body)
        return try decodeAPI(MessageDTO.self, from: data).model
    }

    func setNote(messageID: String, text: String) async throws -> ChatMessage {
        let body = ServerAPI.json(["text": text] as [String: Any])
        let data = try await api.request("PUT", "/v1/messages/\(messageID)/note", body: body)
        return try decodeAPI(MessageDTO.self, from: data).model
    }

    func pin(messageID: String, pinned: Bool) async throws -> [ChatMessage] {
        let body = ServerAPI.json(["pinned": pinned] as [String: Any])
        let data = try await api.request("PUT", "/v1/messages/\(messageID)/pin", body: body)
        return try decodeAPI(PinnedDTO.self, from: data).pinned.map(\.model)
    }

    func thread(peerID: String, limit: Int, peek: Bool, topic: String?) async throws -> ChatThread {
        var query = ["limit": String(limit)]
        if peek { query["peek"] = "1" }
        // прочитанным сервер ничего не отмечает сам — телефон отмечает то, что человек увидел на экране (markRead)
        if !peek && topic == nil { query["read"] = "manual" }
        if ChannelViewSource.openedByLink.contains(peerID) { query["src"] = "link" }      // статистика: «URL»
        if let topic {
            query["topic"] = topic
            let slot = "t-" + topic + (peek ? "-p" : "")                  // у каждой темы своя копия на телефоне
            return try decodeThread(try await api.requestCached("/v1/chats/\(peerID)/messages", query: query, slot: slot))
        }
        // быстрый просмотр (предзагрузка) и полная загрузка хранятся отдельно: короткая копия не затирает длинную
        let data = try await api.requestCached("/v1/chats/\(peerID)/messages", query: query,
                                               slot: peek ? "p" : "", fallback: peek ? [""] : ["p"])
        return try decodeThread(data)
    }

    func markRead(peerID: String, upTo: String?) async -> Int? {
        struct Left: Decodable { let unread: Int }
        let body: [String: Any] = upTo.map { ["up_to": $0] } ?? ["all": true]
        guard let data = try? await api.request("POST", "/v1/chats/\(peerID)/read", body: ServerAPI.json(body)) else { return nil }
        return (try? decodeAPI(Left.self, from: data))?.unread
    }

    func cachedThread(peerID: String, topic: String) -> ChatThread? {
        api.cachedResponse("/v1/chats/\(peerID)/messages", slot: "t-" + topic, fallback: []).flatMap { try? decodeThread($0) }
    }

    func topics(groupID: String) async throws -> ForumTopicList {
        try decodeAPI(ForumTopicList.self, from: try await api.requestCached("/v1/groups/\(groupID)/topics"))
    }

    func createTopic(groupID: String, title: String, icon: String?, color: Int) async throws -> ForumTopic {
        var body: [String: Any] = ["title": title, "color": color]
        if let icon { body["icon"] = icon }
        return try decodeAPI(ForumTopic.self, from: try await api.request("POST", "/v1/groups/\(groupID)/topics", body: ServerAPI.json(body)))
    }

    func updateTopic(groupID: String, topicID: String, fields: [String: Any]) async throws -> ForumTopic {
        try decodeAPI(ForumTopic.self, from: try await api.request("PUT", "/v1/groups/\(groupID)/topics/\(topicID)", body: ServerAPI.json(fields)))
    }

    func deleteTopic(groupID: String, topicID: String) async throws {
        _ = try await api.request("DELETE", "/v1/groups/\(groupID)/topics/\(topicID)")
    }

    func setForum(groupID: String, on: Bool) async throws -> Bool {
        struct R: Decodable { let forum: Bool }
        let data = try await api.request("PUT", "/v1/groups/\(groupID)/forum", body: ServerAPI.json(["on": on]))
        return (try? decodeAPI(R.self, from: data))?.forum ?? on
    }

    private func decodeThread(_ data: Data) throws -> ChatThread {
        let dto = try decodeAPI(ThreadDTO.self, from: data)
        let peer = ChatPeer(id: dto.peer.id, name: dto.peer.name, username: dto.peer.username, avatarID: dto.peer.avatar,
                            isGroup: dto.peer.group ?? false, kind: dto.peer.kind, memberCount: dto.peer.members ?? 0,
                            type: dto.peer.type, handle: dto.peer.handle,
                            noForward: (dto.peer.noForward ?? false) || (dto.protected ?? false))
        let real = [dto.peer.firstName, dto.peer.lastName].compactMap { $0 }.joined(separator: " ")
        return ChatThread(messages: dto.messages.map(\.model), peer: peer,
                          lastSeen: dto.peer.lastSeen.map { Date(timeIntervalSince1970: $0) },
                          typing: dto.typing, canWrite: dto.canWrite, group: dto.group?.model,
                          isContact: dto.peer.isContact ?? false, realName: real.isEmpty ? nil : real,
                          pinned: (dto.pinned ?? []).map(\.model), firstUnread: dto.firstUnread, unread: dto.unread,
                          isPreview: dto.preview ?? false, ttl: dto.ttl ?? 0, botCommands: dto.botCommands ?? dto.bot?.commands ?? [], bot: dto.bot,
                          botKeyboard: dto.botKeyboard)
    }

    func sendArticle(peerID: String, blocks: [[String: Any]], buttons: [[[String: Any]]], replyTo: String?,
                     topic: String?) async throws -> ChatMessage {
        var body: [String: Any] = ["text": "", "blocks": blocks]
        if !buttons.isEmpty { body["buttons"] = buttons }
        if let replyTo { body["reply_to"] = replyTo }
        if let topic, topic != "general" { body["topic_id"] = topic }
        let data = try await api.request("POST", "/v1/chats/\(peerID)/messages", body: ServerAPI.json(body))
        return try decodeAPI(MessageDTO.self, from: data).model
    }

    func botCallback(messageID: String, data: String) async throws -> BotCallbackAnswer {
        let body = ServerAPI.json(["data": data] as [String: Any])
        return try decodeAPI(BotCallbackAnswer.self, from: try await api.request("POST", "/v1/messages/\(messageID)/callback", body: body))
    }

    func setChatProtected(peerID: String, on: Bool) async throws -> Bool {
        let data = try await api.request("PUT", "/v1/chats/\(peerID)/protect", body: ServerAPI.json(["on": on]))
        struct R: Decodable { let `protected`: Bool }
        return (try? decodeAPI(R.self, from: data))?.protected ?? on
    }

    func setChatTTL(peerID: String, seconds: Int) async throws -> Int {
        let data = try await api.request("PUT", "/v1/chats/\(peerID)/ttl",
                                         body: ServerAPI.json(["ttl": seconds]))
        struct R: Decodable { let ttl: Int }
        return (try? decodeAPI(R.self, from: data))?.ttl ?? seconds
    }

    func unreadDigest(peerID: String, from messageID: String) async throws -> UnreadDigest {
        let data = try await api.request("GET", "/v1/chats/\(peerID)/summary", query: ["from": messageID])
        return try decodeAPI(UnreadDigest.self, from: data)
    }

    static func entityJSON(_ entities: [TextEntity]) -> [[String: Any]] {
        entities.map { e in
            var item: [String: Any] = ["type": e.type, "offset": e.offset, "length": e.length]
            if let url = e.url { item["url"] = url }
            return item
        }
    }

    func send(peerID: String, text: String, entities: [TextEntity], attachments: [OutgoingAttachment],
              replyTo: String?, silent: Bool, topic: String?) async throws -> ChatMessage {
        var body: [String: Any] = ["text": text, "entities": Self.entityJSON(entities)]
        if silent { body["silent"] = true }
        if let topic, topic != "general" { body["topic_id"] = topic }
        if !attachments.isEmpty { body["attachments"] = attachments.map(\.json) }
        if let replyTo { body["reply_to"] = replyTo }
        let data = try await api.request("POST", "/v1/chats/\(peerID)/messages", body: ServerAPI.json(body))
        return try decodeAPI(MessageDTO.self, from: data).model
    }

    func sendLocked(peerID: String, text: String, entities: [TextEntity], lock: OutgoingLock) async throws -> ChatMessage {
        let body: [String: Any] = ["text": text, "entities": Self.entityJSON(entities), "lock": lock.json]
        let data = try await api.request("POST", "/v1/chats/\(peerID)/messages", body: ServerAPI.json(body))
        return try decodeAPI(MessageDTO.self, from: data).model
    }

    func exportPage(peerID: String, before: Double?) async throws -> (messages: [ChatMessage], more: Bool, before: Double?) {
        struct Page: Decodable { let messages: [MessageDTO]; let more: Bool; let before: Double? }
        var path = "/v1/chats/\(peerID)/export?limit=500"
        if let before { path += "&before=\(before)" }
        let page = try decodeAPI(Page.self, from: try await api.request("GET", path))
        return (page.messages.map(\.model), page.more, page.before)
    }

    func sendChain(peerID: String, theme: String, moderated: Bool) async throws -> ChatMessage {
        let data = try await api.request("POST", "/v1/chats/\(peerID)/messages",
                                         body: ServerAPI.json(["chain": ["theme": theme, "moderated": moderated]]))
        return try decodeAPI(MessageDTO.self, from: data).model
    }

    private struct ChainBox: Decodable { let chain: PhotoChainDTO }

    func chainAdd(messageID: String, mediaID: String) async throws -> PhotoChain {
        try decodeAPI(ChainBox.self, from: try await api.request("POST", "/v1/chains/\(messageID)/items",
                                                                 body: ServerAPI.json(["media_id": mediaID]))).chain.model
    }

    func chainApprove(messageID: String, itemID: String) async throws -> PhotoChain {
        try decodeAPI(ChainBox.self, from: try await api.request("POST", "/v1/chains/\(messageID)/items/\(itemID)/approve")).chain.model
    }

    func chainRemove(messageID: String, itemID: String) async throws -> PhotoChain {
        try decodeAPI(ChainBox.self, from: try await api.request("DELETE", "/v1/chains/\(messageID)/items/\(itemID)")).chain.model
    }

    func chainSettings(messageID: String, moderated: Bool?, closed: Bool?) async throws -> PhotoChain {
        var body: [String: Any] = [:]
        if let moderated { body["moderated"] = moderated }
        if let closed { body["closed"] = closed }
        return try decodeAPI(ChainBox.self, from: try await api.request("POST", "/v1/chains/\(messageID)/settings",
                                                                        body: ServerAPI.json(body))).chain.model
    }

    func chainReel(messageID: String) async throws {
        _ = try await api.request("POST", "/v1/chains/\(messageID)/reel")
    }

    func sendChecklist(peerID: String, title: String, items: [String], othersAdd: Bool) async throws -> ChatMessage {
        let body: [String: Any] = ["checklist": ["title": title, "items": items, "others_add": othersAdd]]
        let data = try await api.request("POST", "/v1/chats/\(peerID)/messages", body: ServerAPI.json(body))
        return try decodeAPI(MessageDTO.self, from: data).model
    }

    private struct ChecklistBox: Decodable { let checklist: ChecklistDTO }

    func checklistToggle(messageID: String, itemID: String) async throws -> Checklist {
        try decodeAPI(ChecklistBox.self, from: try await api.request("POST", "/v1/checklists/\(messageID)/items/\(itemID)/toggle")).checklist.model
    }

    func checklistAdd(messageID: String, text: String) async throws -> Checklist {
        try decodeAPI(ChecklistBox.self, from: try await api.request("POST", "/v1/checklists/\(messageID)/items",
                                                                     body: ServerAPI.json(["text": text]))).checklist.model
    }

    func recentAudio() async throws -> [RecentAudio] {
        struct Box: Decodable { let audio: [RecentAudio] }
        return try decodeAPI(Box.self, from: try await api.request("GET", "/v1/me/recent-audio")).audio
    }

    func audioCopy(messageID: String, mediaID: String) async throws -> AudioCopy {
        try decodeAPI(AudioCopy.self, from: try await api.request("POST", "/v1/messages/\(messageID)/audio-copy",
                                                                  body: ServerAPI.json(["media_id": mediaID])))
    }

    func onceOpen(messageID: String) async throws -> String {
        struct Box: Decodable { let mediaId: String }
        return try decodeAPI(Box.self, from: try await api.request("POST", "/v1/messages/\(messageID)/once-open")).mediaId
    }

    func onceDone(messageID: String) async {
        _ = try? await api.request("POST", "/v1/messages/\(messageID)/once-done")
    }

    func playlistCopy(trackID: String) async throws -> AudioCopy {
        try decodeAPI(AudioCopy.self, from: try await api.request("POST", "/v1/me/playlist/\(trackID)/copy"))
    }

    func importBatch(peerID: String, source: String, messages: [[String: Any]]) async throws -> Int {
        struct R: Decodable { let added: Int }
        let data = try await api.request("POST", "/v1/chats/\(peerID)/import",
                                         body: ServerAPI.json(["source": source, "messages": messages]))
        return try decodeAPI(R.self, from: data).added
    }

    func unlock(messageID: String, point: GeoPoint) async throws -> ChatMessage {
        var body: [String: Any] = ["lat": point.lat, "lon": point.lon]
        if let acc = point.accuracy { body["acc"] = acc }
        let data = try await api.request("POST", "/v1/messages/\(messageID)/unlock", body: ServerAPI.json(body))
        return try decodeAPI(MessageDTO.self, from: data).model
    }

    func upload(_ media: OutgoingMedia) async throws -> OutgoingAttachment {
        switch media {
        case .prepared(let prepared):
            let item = try await RemoteFeedRepository(api: api).uploadMedia(prepared)
            return OutgoingAttachment(type: prepared.isVideo ? "video" : "photo", mediaID: item.id, gif: prepared.gif && prepared.isVideo)

        case .circle(let url, let thumb, let duration):
            let thumbData = try await api.upload("/v1/media", query: ["kind": "image", "w": "480", "h": "480"],
                                                 payload: .data(thumb), contentType: "image/jpeg")
            let thumbID = try decodeAPI(UploadedDTO.self, from: thumbData).id
            let mime = url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
            let data = try await api.upload("/v1/media", query: ["kind": "video", "w": "480", "h": "480",
                                                                 "dur": String(duration), "thumb": thumbID],
                                            payload: .file(url), contentType: mime)
            return OutgoingAttachment(type: "circle", mediaID: try decodeAPI(UploadedDTO.self, from: data).id)

        case .voice(let url, let duration, let waveform):
            let data = try await api.upload("/v1/media", query: ["kind": "audio", "dur": String(duration)],
                                            payload: .file(url), contentType: "audio/mp4")
            return OutgoingAttachment(type: "voice", mediaID: try decodeAPI(UploadedDTO.self, from: data).id,
                                      waveform: waveform)

        case .file(let url, let name, let mime):
            let data = try await api.upload("/v1/media", query: ["kind": "file"], payload: .file(url), contentType: mime)
            return OutgoingAttachment(type: "file", mediaID: try decodeAPI(UploadedDTO.self, from: data).id, name: name)

        case .audio(let url, let name, let title, let artist, let duration, let cover):
            var coverID: String? = nil
            if let cover {
                let data = try await api.upload("/v1/media", query: ["kind": "image", "w": "600", "h": "600"],
                                                payload: .data(cover), contentType: "image/jpeg")
                coverID = try decodeAPI(UploadedDTO.self, from: data).id
            }
            let ext = url.pathExtension.lowercased()
            let mime = ["m4a": "audio/mp4", "mp4": "audio/mp4", "aac": "audio/aac"][ext] ?? "audio/mpeg"
            let data = try await api.upload("/v1/media", query: ["kind": "audio", "dur": String(duration)],
                                            payload: .file(url), contentType: mime)
            return OutgoingAttachment(type: "audio", mediaID: try decodeAPI(UploadedDTO.self, from: data).id, name: name,
                                      title: title, artist: artist, thumb: coverID)

        case .sticker(let id):
            return OutgoingAttachment(type: "sticker", sticker: id)

        case .location(let geo, let live):
            return OutgoingAttachment(type: "location", geo: geo, live: live)
        }
    }

    func updateLiveLocation(messageID: String, point: GeoPoint) async throws {
        var body: [String: Any] = ["lat": point.lat, "lon": point.lon]
        if let a = point.accuracy { body["acc"] = a }
        if let h = point.heading { body["heading"] = h }
        _ = try await api.request("PUT", "/v1/live-location/\(messageID)", body: ServerAPI.json(body))
    }

    func stopLiveLocation(messageID: String) async throws {
        _ = try await api.request("POST", "/v1/live-location/\(messageID)/stop")
    }

    func edit(messageID: String, text: String, entities: [TextEntity]) async throws -> ChatMessage {
        let body = ServerAPI.json(["text": text, "entities": Self.entityJSON(entities)] as [String: Any])
        let data = try await api.request("PUT", "/v1/messages/\(messageID)", body: body)
        return try decodeAPI(MessageDTO.self, from: data).model
    }

    func delete(messageID: String, forEveryone: Bool) async throws {
        _ = try await api.request("DELETE", "/v1/messages/\(messageID)", query: forEveryone ? ["all": "1"] : [:])
    }

    func typingStatus(peerID: String) async throws -> String? {
        struct R: Decodable { let typing: String? }
        return try decodeAPI(R.self, from: try await api.request("GET", "/v1/chats/\(peerID)/typing")).typing
    }

    func typing(peerID: String, action: String) async {
        _ = try? await api.request("POST", "/v1/chats/\(peerID)/typing", body: ServerAPI.json(["action": action]))
    }

    func clear(peerID: String, forEveryone: Bool) async throws {
        _ = try await api.request("DELETE", "/v1/chats/\(peerID)" + (forEveryone ? "?all=1" : ""))
    }

    /// Наборы стикеров. Ответ сервера сохраняется на телефон вместе с самими стикерами (StickerVault);
    /// без сети — отдаём сохранённое, панель стикеров работает как обычно
    func stickers() async throws -> [StickerPack] {
        do {
            let data = try await api.request("GET", "/v1/stickers")
            let packs = try decodeAPI(PackListDTO.self, from: data).packs.map(\.model)
            StickerVault.shared.store(packs, account: api.accountID)
            return packs
        } catch {
            if let saved = StickerVault.shared.packs(account: api.accountID) { return saved }
            throw error
        }
    }

    func savedStickers() -> [StickerPack]? { StickerVault.shared.packs(account: api.accountID) }

    func stickerPack(id: String) async throws -> CustomStickerPack {
        do {
            let dto = try decodeAPI(PackDTO.self, from: try await api.request("GET", "/v1/stickers/packs/\(id)"))
            return CustomStickerPack(pack: dto.model, installed: dto.installed ?? false, mine: dto.mine ?? false)
        } catch {
            // без сети — сохранённый на телефоне набор
            if let saved = StickerVault.shared.packs(account: api.accountID)?.first(where: { $0.id == id }) {
                return CustomStickerPack(pack: saved, installed: true, mine: saved.mine)
            }
            throw error
        }
    }

    func setStickerPack(id: String, installed: Bool) async throws -> CustomStickerPack {
        let dto = try decodeAPI(PackDTO.self, from: try await api.request(installed ? "PUT" : "DELETE", "/v1/stickers/packs/\(id)/install"))
        let result = CustomStickerPack(pack: dto.model, installed: dto.installed ?? installed, mine: dto.mine ?? false)
        // добавили — сразу на телефон; убрали из набора своими руками — только тогда стираем с телефона
        if result.installed { StickerVault.shared.keep(result.pack, account: api.accountID) }
        else { StickerVault.shared.forget(packID: id, account: api.accountID) }
        return result
    }

    func createStickerPack(title: String) async throws -> CustomStickerPack {
        let dto = try decodeAPI(PackDTO.self, from: try await api.request("POST", "/v1/stickers/packs",
                                                                           body: ServerAPI.json(["title": title])))
        let result = CustomStickerPack(pack: dto.model, installed: dto.installed ?? true, mine: dto.mine ?? true)
        StickerVault.shared.keep(result.pack, account: api.accountID)
        return result
    }

    func addSticker(packID: String, mediaID: String, emoji: String) async throws {
        _ = try await api.request("POST", "/v1/stickers/packs/\(packID)/stickers",
                                  body: ServerAPI.json(["media_id": mediaID, "emoji": emoji]))
    }

    func deleteSticker(packID: String, stickerID: String) async throws {
        let bare = stickerID.hasPrefix("u:") ? String(stickerID.dropFirst(2)) : stickerID
        _ = try await api.request("DELETE", "/v1/stickers/packs/\(packID)/stickers/\(bare)")
    }

    func deleteStickerPack(id: String) async throws {
        _ = try await api.request("DELETE", "/v1/stickers/packs/\(id)")
        StickerVault.shared.forget(packID: id, account: api.accountID)          // удалили набор — и с телефона
    }

    // MARK: Контакты

    func contacts() async throws -> [Contact] {
        let data = try await api.request("GET", "/v1/contacts")
        return try decodeAPI(ContactListDTO.self, from: data).contacts.map(\.model)
    }

    func searchHub() async throws -> SearchHub {
        try decodeAPI(SearchHub.self, from: try await api.request("GET", "/v1/me/search-hub"))
    }

    func shared(kind: String, before: Double?) async throws -> (items: [SharedEntry], before: Double?, more: Bool) {
        struct Page: Decodable { let items: [SharedEntryDTO]; let before: Double?; let more: Bool }
        var query = ["kind": kind]
        if let before { query["before"] = String(before) }
        let page = try decodeAPI(Page.self, from: try await api.request("GET", "/v1/me/shared", query: query))
        return (page.items.map(\.model), page.before, page.more)
    }

    func setChatFocus(_ folder: String?) async {
        let body: [String: Any] = ["folder": folder.map { $0 as Any } ?? NSNull()]
        _ = try? await api.request("PUT", "/v1/me/chat-focus", body: ServerAPI.json(body))
    }

    func birthdays(today: String) async throws -> [BirthdayPerson] {
        struct Box: Decodable { let birthdays: [BirthdayPerson] }
        return try decodeAPI(Box.self, from: try await api.request("GET", "/v1/me/birthdays", query: ["today": today])).birthdays
    }

    func saveContact(id: String, name: String) async throws -> Contact {
        let data = try await api.request("PUT", "/v1/contacts/\(id)", body: ServerAPI.json(["name": name]))
        return try decodeAPI(ContactDTO.self, from: data).model
    }

    func deleteContact(id: String) async throws {
        _ = try await api.request("DELETE", "/v1/contacts/\(id)")
    }

    // MARK: Группы

    private static func draftBody(_ d: GroupDraft) -> [String: Any] {
        ["title": d.title, "about": d.about, "type": d.type, "kind": d.kind, "handle": d.handle, "approve": d.approve,
         "no_forward": d.noForward, "slow": d.slow, "who_writes": d.whoWrites, "history": d.history, "perms": d.perms.json]
    }

    func createGroup(_ draft: GroupDraft, members: [String]) async throws -> GroupInfo {
        var body = Self.draftBody(draft)
        body["members"] = members
        return try decodeAPI(GroupDTO.self, from: try await api.request("POST", "/v1/groups", body: ServerAPI.json(body))).model
    }

    func group(id: String) async throws -> GroupInfo {
        try decodeAPI(GroupDTO.self, from: try await api.request("GET", "/v1/groups/\(id)")).model
    }

    func editGroup(id: String, patch: GroupPatch) async throws -> GroupInfo {
        var body: [String: Any] = [:]
        if let v = patch.title { body["title"] = v }
        if let v = patch.about { body["about"] = v }
        if let v = patch.kind { body["kind"] = v }
        if let v = patch.handle { body["handle"] = v }
        if let v = patch.approve { body["approve"] = v }
        if let v = patch.noForward { body["no_forward"] = v }
        if let v = patch.slow { body["slow"] = v }
        if let v = patch.whoWrites { body["who_writes"] = v }
        if let v = patch.history { body["history"] = v }
        if let v = patch.discussion { body["discussion"] = v }
        if let v = patch.perms { body["perms"] = v.json }
        if let v = patch.writers { body["writers"] = v }
        return try decodeAPI(GroupDTO.self, from: try await api.request("PUT", "/v1/groups/\(id)", body: ServerAPI.json(body))).model
    }

    func comments(channelID: String, messageID: String) async throws -> CommentThread {
        let data = try await api.request("GET", "/v1/groups/\(channelID)/comments/\(messageID)")
        let dto = try decodeAPI(CommentThreadDTO.self, from: data)
        return CommentThread(messages: dto.messages.map(\.model), canComment: dto.canComment, mirrorID: dto.mirror)
    }

    func postComment(channelID: String, messageID: String, text: String, replyTo: String?) async throws -> ChatMessage {
        var fields: [String: Any] = ["text": text, "entities": [Any]()]
        if let replyTo { fields["reply_to"] = replyTo }
        let body = ServerAPI.json(fields)
        let data = try await api.request("POST", "/v1/groups/\(channelID)/comments/\(messageID)", body: body)
        return try decodeAPI(MessageDTO.self, from: data).model
    }

    func invite(groupID: String, userIDs: [String]) async throws -> GroupInfo {
        let data = try await api.request("POST", "/v1/groups/\(groupID)/members", body: ServerAPI.json(["user_ids": userIDs]))
        return try decodeAPI(GroupDTO.self, from: data).model
    }

    func removeMember(groupID: String, userID: String) async throws {
        _ = try await api.request("DELETE", "/v1/groups/\(groupID)/members/\(userID)")
    }

    func setRole(groupID: String, userID: String, role: String) async throws -> GroupInfo {
        let data = try await api.request("PUT", "/v1/groups/\(groupID)/members/\(userID)", body: ServerAPI.json(["role": role]))
        return try decodeAPI(GroupDTO.self, from: data).model
    }

    func joinRequests(groupID: String) async throws -> [JoinRequest] {
        let data = try await api.request("GET", "/v1/groups/\(groupID)/requests")
        return try decodeAPI(JoinRequestListDTO.self, from: data).requests.map {
            JoinRequest(member: $0.user.model, createdAt: Date(timeIntervalSince1970: $0.createdAt))
        }
    }

    func answerRequest(groupID: String, userID: String, approve: Bool) async throws -> GroupInfo {
        let data = try await api.request("POST", "/v1/groups/\(groupID)/requests/\(userID)", body: ServerAPI.json(["approve": approve]))
        return try decodeAPI(GroupDTO.self, from: data).model
    }

    func bannedUsers(groupID: String) async throws -> [GroupMember] {
        try decodeAPI(BanListDTO.self, from: try await api.request("GET", "/v1/groups/\(groupID)/bans")).users.map(\.model)
    }

    func unban(groupID: String, userID: String) async throws {
        _ = try await api.request("DELETE", "/v1/groups/\(groupID)/bans/\(userID)")
    }

    func moderate(groupID: String, userID: String, messageID: String?, options: ModerationOptions) async throws {
        var body: [String: Any] = ["delete_all": options.deleteAll, "ban": options.ban]
        if let messageID { body["message_id"] = messageID }
        if let r = options.restrict { body["restrict"] = r }
        _ = try await api.request("POST", "/v1/groups/\(groupID)/moderate/\(userID)", body: ServerAPI.json(body))
    }

    func restricted(groupID: String) async throws -> [RestrictedMember] {
        try decodeAPI(RestrictedListDTO.self, from: try await api.request("GET", "/v1/groups/\(groupID)/restricted")).restricted.map {
            RestrictedMember(member: $0.user.model, until: $0.until > 0 ? Date(timeIntervalSince1970: $0.until) : nil)
        }
    }

    func unrestrict(groupID: String, userID: String) async throws {
        _ = try await api.request("DELETE", "/v1/groups/\(groupID)/restricted/\(userID)")
    }

    func stats(groupID: String, days: Int) async throws -> GroupStats {
        let data = try await api.request("GET", "/v1/groups/\(groupID)/stats", query: ["days": String(days)])
        return try decodeAPI(GroupStatsDTO.self, from: data).model
    }

    func setMuted(groupID: String, muted: Bool) async throws {
        _ = try await api.request("POST", "/v1/groups/\(groupID)/mute", body: ServerAPI.json(["muted": muted]))
    }

    func deleteGroup(id: String) async throws {
        _ = try await api.request("DELETE", "/v1/groups/\(id)")
    }

    func importContacts(_ entries: [BookEntry]) async throws -> [ImportMatch] {
        let items = entries.map { ["name": $0.name, "phone": $0.phone] }
        let data = try await api.request("POST", "/v1/import/contacts", body: ServerAPI.json(["contacts": items]))
        return try decodeAPI(ImportDTO.self, from: data).matches.map {
            ImportMatch(id: $0.user.id, name: $0.user.name, username: $0.user.username, avatarID: $0.user.avatar,
                        bookName: $0.bookName ?? "", inContacts: $0.inContacts ?? false)
        }
    }

    func forgetImportedContacts() async throws {
        _ = try await api.request("DELETE", "/v1/import/contacts")
    }

    func notices() async throws -> [JoinNotice] {
        let data = try await api.request("GET", "/v1/notices")
        return try decodeAPI(NoticeListDTO.self, from: data).notices.map {
            JoinNotice(id: $0.id, userID: $0.user.id, name: $0.name ?? $0.user.name, username: $0.user.username,
                       avatarID: $0.user.avatar, createdAt: Date(timeIntervalSince1970: $0.createdAt))
        }
    }

    func dismissNotices(ids: [String]) async throws {
        _ = try await api.request("POST", "/v1/notices/dismiss", body: ServerAPI.json(["ids": ids]))
    }

    func publicGroups(query: String, type: String?) async throws -> [GroupPreview] {
        var params: [String: String] = [:]
        if !query.isEmpty { params["q"] = query }
        if let type { params["type"] = type }
        let data = try await api.request("GET", "/v1/groups/public", query: params)
        return try decodeAPI(GroupPreviewListDTO.self, from: data).groups.map(\.model)
    }

    func searchMessages(query: String) async throws -> [MessageHit] {
        try await searchMessages(query: query, scope: "all")
    }

    func searchMessages(query: String, scope: String) async throws -> [MessageHit] {
        let data = try await api.request("GET", "/v1/search/messages", query: ["q": query, "scope": scope])
        return try decodeAPI(MessageHitListDTO.self, from: data).hits.map {
            MessageHit(id: $0.id, peer: $0.peer.model, text: $0.text, mine: $0.mine,
                       date: Date(timeIntervalSince1970: $0.createdAt), sender: $0.sender)
        }
    }

    func groupPreview(code: String) async throws -> GroupPreview {
        try decodeAPI(GroupPreviewDTO.self, from: try await api.request("GET", "/v1/groups/code/\(code)")).model
    }

    func joinGroup(code: String) async throws -> GroupInfo {
        try decodeAPI(GroupDTO.self, from: try await api.request("POST", "/v1/groups/code/\(code)/join")).model
    }

    func joinGroup(id: String) async throws -> GroupInfo {
        try decodeAPI(GroupDTO.self, from: try await api.request("POST", "/v1/groups/\(id)/join")).model
    }

    // MARK: Музыка из переписки

    func addToProfile(messageID: String, mediaID: String, title: String, artist: String) async throws -> Track {
        let body = ServerAPI.json(["message_id": messageID, "media_id": mediaID, "title": title, "artist": artist])
        return try decodeAPI(TrackDTO.self, from: try await api.request("POST", "/v1/me/playlist/from-chat", body: body)).model
    }
}
