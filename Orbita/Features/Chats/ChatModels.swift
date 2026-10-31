import SwiftUI
import Combine

/// Предзагрузка переписок: последние сообщения чатов из списка подтягиваются заранее (без пометки «прочитано»),
/// и чат открывается уже с готовыми сообщениями, а не с пустым экраном и загрузкой
@MainActor
final class ThreadPrefetcher {
    static let shared = ThreadPrefetcher()
    private struct Entry { var thread: ChatThread; var stamp: Date }
    private var store: [String: Entry] = [:]
    private var inflight = Set<String>()
    private var queue: [(summary: ChatSummary, limit: Int)] = []
    private var running = 0
    private let maxParallel = 3
    private var repo: MessengerRepository?

    func get(_ id: String) -> ChatThread? { store[id]?.thread }

    /// При входе в «Чаты»: сначала самые свежие (список уже отсортирован). Сохраняются и на телефон —
    /// поэтому переписки открываются сразу и без интернета
    func warm(_ chats: [ChatSummary], repo: MessengerRepository, count: Int = 30, limit: Int = 30) {
        self.repo = repo
        for c in chats.prefix(count) { enqueue(c, limit: limit) }
    }

    /// Без сети: переписки из сохранённых на телефоне копий — сразу в память, чтобы открывались мгновенно
    func warmFromDisk(_ chats: [ChatSummary], repo: MessengerRepository, count: Int = 30) {
        self.repo = repo
        for c in chats.prefix(count) where store[c.id] == nil {
            if let t = repo.cachedThread(peerID: c.id) { store[c.id] = Entry(thread: t, stamp: .distantPast) }
        }
    }

    /// Когда строка чата показалась на экране при прокрутке: по 5 сообщений
    func visible(_ chat: ChatSummary, repo: MessengerRepository) {
        self.repo = repo
        enqueue(chat, limit: 5)
    }

    private func enqueue(_ c: ChatSummary, limit: Int) {
        if let e = store[c.id], e.stamp >= c.updatedAt { return }            // уже есть и ничего нового
        guard !inflight.contains(c.id) else { return }
        inflight.insert(c.id)
        queue.append((c, limit))
        pump()
    }

    private func pump() {
        while running < maxParallel, !queue.isEmpty, let repo {
            let job = queue.removeFirst()
            running += 1
            Task { [weak self] in
                let t = try? await repo.thread(peerID: job.summary.id, limit: job.limit, peek: true)
                guard let self else { return }
                self.running -= 1
                self.inflight.remove(job.summary.id)
                if let t { self.store[job.summary.id] = Entry(thread: t, stamp: job.summary.updatedAt) }
                self.pump()
            }
        }
    }
}

/// Список переписок (и счётчик непрочитанных для нижней панели)
@MainActor
final class ChatsModel: ObservableObject {
    @Published private(set) var chats: [ChatSummary] = []
    @Published private(set) var unread = 0
    @Published private(set) var loaded = false
    /// Уже был ответ сервера (а не только сохранённая на телефоне копия)
    private var gotFresh = false
    @Published var error: APIError?
    /// Открыта переписка — нижняя панель вкладок прячется (как в Telegram)
    @Published private(set) var chatOpen = false
    /// Сколько экранов переписки сейчас на экране. Считаем, а не ставим флаг: при быстром выходе и входе iOS может прислать
    /// «появился» нового чата раньше, чем «исчез» старого, — флаг тогда застревал, и панель вкладок пропадала или мешала
    private var openScreens = 0
    /// Нажали на чат, и он выезжает: панель прячется сразу, ещё до появления экрана переписки
    private var opening = false
    /// На каких вкладках сейчас открыта переписка. «Чаты» живут в памяти и при переходе на другую вкладку
    /// (например, открыли присланный шортс) переписка остаётся открытой — панель прячем только на её вкладке
    @Published private(set) var chatOpenTabs: Set<MainTab> = []
    private var screensByTab: [MainTab: Int] = [:]

    /// tab — вкладка, внутри которой открыта переписка; nil — поверх всего (полноэкранно), панель её и так не видно
    func chatScreenAppeared(_ peerID: String, tab: MainTab?) {
        openScreens += 1
        if let tab { screensByTab[tab, default: 0] += 1 }
        openPeerID = peerID
        syncChatOpen()
    }

    func chatScreenDisappeared(tab: MainTab?) {
        openScreens = max(0, openScreens - 1)
        if let tab { screensByTab[tab] = max(0, (screensByTab[tab] ?? 0) - 1) }
        if openScreens == 0 { openPeerID = nil }
        syncChatOpen()
    }

    /// Список чатов: какой чат сейчас открывается (nil — вернулись в список)
    func setOpening(_ peerID: String?) {
        opening = peerID != nil
        if let peerID { openPeerID = peerID }
        syncChatOpen()
    }

    private func syncChatOpen() {
        let now = openScreens > 0 || opening
        if chatOpen != now { chatOpen = now }
        var tabs = Set(screensByTab.filter { $0.value > 0 }.keys)
        if opening { tabs.insert(.chats) }                  // нажали на чат в списке «Чатов»
        if chatOpenTabs != tabs { chatOpenTabs = tabs }
    }
    /// Какая переписка открыта прямо сейчас (для неё баннер не нужен)
    var openPeerID: String?
    /// Всплывающее сообщение о новом сообщении в другом чате
    @Published var banner: ChatBanner?
    /// «Знакомый теперь в Orbita»
    @Published private(set) var notices: [JoinNotice] = []

    let repo: MessengerRepository
    private var ticks = 0
    init(repo: MessengerRepository) { self.repo = repo }

    func dismissNotice(_ notice: JoinNotice) {
        notices.removeAll { $0.id == notice.id }
        let repo = repo, id = notice.id
        Task { try? await repo.dismissNotices(ids: [id]) }
    }

    private func refreshNotices() async {
        guard let fresh = try? await repo.notices() else { return }
        if fresh != notices {
            if fresh.contains(where: { n in !notices.contains(where: { $0.id == n.id }) }) && loaded { Haptics.notify(.success) }
            notices = fresh
        }
    }

    func refresh() async {
        ticks += 1
        // первый раз — сразу сохранённый список (без сети и без ожидания ответа), свежий приходит следом
        if !loaded, chats.isEmpty, let cached = repo.cachedChats() {
            chats = cached.chats
            unread = cached.unread
            loaded = true
            ThreadPrefetcher.shared.warmFromDisk(cached.chats, repo: repo)
        }
        if ticks % 3 == 1 { await refreshNotices() }
        do {
            let result = try await repo.chats()
            if gotFresh {                    // баннер — только на новое после первого ответа сервера, а не на разницу с сохранённой копией
                let old = Dictionary(chats.map { ($0.id, $0.unread) }, uniquingKeysWith: { a, _ in a })
                let oldTags = Dictionary(chats.map { ($0.id, $0.mentions) }, uniquingKeysWith: { a, _ in a })
                // если тегнули — баннер показывается, даже когда чат отключён
                if let c = result.chats.first(where: { $0.id != openPeerID && (($0.unread > (old[$0.id] ?? 0) && !$0.muted && !UserDefaults.standard.bool(forKey: "dm_muted_" + $0.id))
                                                                              || $0.mentions > (oldTags[$0.id] ?? 0)) }) {
                    banner = ChatBanner(peer: c.peer, text: (c.mentions > (oldTags[c.id] ?? 0) ? "@ " : "") + c.lastText)
                    Haptics.impact(.medium)
                }
            }
            if result.chats != chats { chats = result.chats }
            gotFresh = true
            ThreadPrefetcher.shared.warm(result.chats, repo: repo)
            if result.unread != unread {
                unread = result.unread
                PushManager.shared.setBadge(result.unread)
            }
            loaded = true
        } catch let e as APIError {
            if !loaded { error = e }
        } catch {}
    }

    func clear(_ peerID: String) async {
        chats.removeAll { $0.id == peerID }
        do { try await repo.clear(peerID: peerID) } catch let e as APIError { error = e } catch {}
        await refresh()
    }
}

/// Баннер «новое сообщение», пока вы в другом месте приложения
struct ChatBanner: Identifiable, Equatable {
    let id = UUID()
    let peer: ChatPeer
    let text: String
}

/// Вложение, выбранное, но ещё не отправленное (лежит над полем ввода)
struct DraftAttachment: Identifiable {
    enum Source {
        case media(PreparedMedia)
        case file(url: URL, name: String, mime: String, size: Int)
        case audio(url: URL, name: String, title: String, artist: String, duration: Double, cover: Data?, size: Int)
    }
    let id = UUID()
    let source: Source

    var preview: Data? {
        if case .media(let m) = source { return m.thumbnail }
        if case .audio(_, _, _, _, _, let cover, _) = source { return cover }
        return nil
    }
    var isVideo: Bool { if case .media(let m) = source { return m.isVideo }; return false }
    var fileName: String? {
        switch source {
        case .file(_, let name, _, _): return name
        case .audio(_, _, let title, _, _, _, _): return title
        default: return nil
        }
    }

    var placeholder: ChatAttachment {
        switch source {
        case .media(let m):
            return ChatAttachment(kind: m.isVideo ? .video : .photo, width: m.width, height: m.height,
                                  duration: m.duration ?? 0, localPreview: m.thumbnail, gif: m.gif)
        case .file(_, let name, let mime, let size):
            return ChatAttachment(kind: .file, size: size, name: name, mime: mime)
        case .audio(_, let name, let title, let artist, let duration, let cover, let size):
            return ChatAttachment(kind: .audio, duration: duration, size: size, name: name, title: title, artist: artist,
                                  localPreview: cover)
        }
    }

    var outgoing: OutgoingMedia {
        switch source {
        case .media(let m): return .prepared(m)
        case .file(let url, let name, let mime, _): return .file(url: url, name: name, mime: mime)
        case .audio(let url, let name, let title, let artist, let duration, let cover, _):
            return .audio(url: url, name: name, title: title, artist: artist, duration: duration, cover: cover)
        }
    }
}

/// Одна переписка
@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var peer: ChatPeer
    /// Сообщения, которые прямо сейчас «рассыпаются» (эффект удаления); из списка уходят после анимации
    @Published var dissolving: Set<String> = []
    /// Видео в этих сообщениях на миг показывает превью-кадр — чтобы рассыпалась картинка, а не чёрный видеослой
    @Published var freezing: Set<String> = []
    /// Экран чата подсказывает, где сообщение стоит на экране: оттуда оно и рассыпается
    var frameOf: ((String) -> CGRect?)?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var pending: [ChatMessage] = []
    @Published private(set) var typing: String?
    @Published private(set) var lastSeen: Date?
    @Published private(set) var canWrite = true
    @Published private(set) var loaded = false
    @Published var error: APIError?
    @Published var replyTo: ChatMessage?
    /// Только что поставленная реакция: по экрану вылетают эмодзи
    @Published var reactionFX: ReactionFX?
    @Published var editing: ChatMessage?
    @Published private(set) var packs: [StickerPack] = []
    @Published private(set) var group: GroupInfo?
    @Published private(set) var isContact = false
    @Published private(set) var realName: String?
    @Published private(set) var pinned: [ChatMessage] = []
    @Published private(set) var isPreview = false
    @Published private(set) var ttl = 0            // таймер исчезающих сообщений (секунды), 0 — выкл
    @Published private(set) var joining = false
    /// Сообщение, с которого начинались непрочитанные при входе в чат (запоминается один раз)
    @Published private(set) var firstUnreadID: String?
    /// Растёт, когда поверх предзагруженных сообщений разом приходит длинная история: экран переписки создаётся заново
    /// и сразу открывается внизу — вместо кадров, где список стоял на месте, а контент под ним вырос
    @Published private(set) var generation = 0
    private var refreshedOnce = false

    let peerID: String
    let repo: MessengerRepository
    private var lastTypingPing = Date.distantPast

    init(peer: ChatPeer, repo: MessengerRepository) {
        self.peer = peer
        self.peerID = peer.id
        self.repo = repo
        // предзагруженные (или сохранённые на телефоне) сообщения показываем сразу — и без интернета;
        // свежие приходят следом обычным обновлением
        if let t = ThreadPrefetcher.shared.get(peer.id) ?? repo.cachedThread(peerID: peer.id) {
            messages = t.messages
            self.peer = t.peer
            lastSeen = t.lastSeen
            canWrite = t.canWrite
            group = t.group
            isContact = t.isContact
            realName = t.realName
            pinned = t.pinned
            isPreview = t.isPreview
            firstUnreadID = t.firstUnread
            loaded = true
        }
    }

    /// Сколько последних сообщений держим в списке; при поиске по чату увеличивается, чтобы можно было перейти к любому найденному
    var historyLimit = 100

    var items: [ChatMessage] { messages + pending }

    func refresh() async {
        do {
            let thread = try await repo.thread(peerID: peerID, limit: historyLimit)
            // Тот же ключ у тех же сообщений: список не перерисовывается и не «прыгает»
            let keys = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0.key) })
            let fresh = thread.messages.map { m -> ChatMessage in
                var m = m
                if let key = keys[m.id] { m.key = key }
                return m
            }
            if refreshedOnce, fresh.filter({ !$0.mine }).count > messages.filter({ !$0.mine }).count, fresh.count - messages.count <= 3 { Haptics.impact(.soft) }       // только на настоящее новое сообщение, не на подгрузку истории при входе
            if fresh != messages {
                announceIncomingReaction(in: fresh)
                if abs(fresh.count - messages.count) > 3 {
                    // длинная история разом (10 предзагруженных → 100): без анимации появления — иначе строки «въезжали» с нулевой прозрачностью
                    // и экран на миг оставался пустым, пока не пролистаешь
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { messages = fresh }
                } else {
                    messages = fresh
                }
            }
            // опрос идёт раз в секунду: присваиваем только изменившееся — каждое присваивание @Published перерисовывает
            // весь экран чата (и открытое меню сообщения), даже если значение то же самое
            if peer != thread.peer { peer = thread.peer }
            if typing != thread.typing { typing = thread.typing }
            if lastSeen != thread.lastSeen { lastSeen = thread.lastSeen }
            if canWrite != thread.canWrite { canWrite = thread.canWrite }
            if group != thread.group { group = thread.group }
            if isContact != thread.isContact { isContact = thread.isContact }
            if realName != thread.realName { realName = thread.realName }
            if thread.pinned != pinned { pinned = thread.pinned }
            if isPreview != thread.isPreview { isPreview = thread.isPreview }
            if ttl != thread.ttl { ttl = thread.ttl }
            if !loaded { firstUnreadID = thread.firstUnread }
            if !loaded { loaded = true }
            refreshedOnce = true
            if !outbox.isEmpty, !NetworkState.shared.offline { Task { await retryQueued() } }
        } catch let e as APIError {
            if !loaded { error = e }
        } catch {}
    }

    /// Вступление из режима просмотра (подписка на канал / заявка)
    func join() async {
        joining = true
        defer { joining = false }
        do { group = try await repo.joinGroup(id: peerID) } catch let e as APIError { error = e } catch {}
        await refresh()
    }

    /// Таймер исчезающих сообщений для этого чата (секунды; 0 — выключить)
    func setTTL(_ seconds: Int) async {
        let before = ttl
        ttl = seconds                               // сразу в UI, без ожидания сети
        do { ttl = try await repo.setChatTTL(peerID: peerID, seconds: seconds) }
        catch let e as APIError { error = e; ttl = before }
        catch { ttl = before }
    }

    // MARK: Реакции и закреп

    /// Собеседник поставил реакцию — над сообщением проигрывается тот же крупный эффект, что и у своей (как в Telegram).
    /// Сравниваем с тем, что было: реакций «не моих» на сообщении стало больше
    private func announceIncomingReaction(in fresh: [ChatMessage]) {
        guard refreshedOnce, reactionFX == nil else { return }
        let before = Dictionary(messages.map { ($0.id, $0.reactions) }, uniquingKeysWith: { a, _ in a })
        for m in fresh.reversed() {
            guard let old = before[m.id] else { continue }
            for r in m.reactions {
                let prev = old.first { $0.emoji == r.emoji }
                let othersNow = r.count - (r.mine ? 1 : 0)
                let othersBefore = (prev?.count ?? 0) - ((prev?.mine ?? false) ? 1 : 0)
                if othersNow > othersBefore {
                    reactionFX = ReactionFX(emoji: r.emoji, messageID: m.id, incoming: true)
                    Haptics.impact(.light)
                    return
                }
            }
        }
    }

    /// Одна реакция на человека: новая заменяет старую, такая же — снимает
    /// Своя заметка к сообщению (пустая — удалить). Видна только тебе, хранится на сервере зашифрованной
    func setNote(_ message: ChatMessage, text: String) {
        guard !message.isPending, let i = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = messages[i].note
        messages[i].note = clean.isEmpty ? nil : clean
        let repo = repo, id = message.id
        Task {
            do {
                let updated = try await repo.setNote(messageID: id, text: clean)
                if let k = messages.firstIndex(where: { $0.id == id }) { messages[k].note = updated.note }
            } catch {
                if let k = messages.firstIndex(where: { $0.id == id }) { messages[k].note = old }
                Haptics.notify(.error)
            }
        }
    }

    func react(_ message: ChatMessage, emoji: String) {
        guard !message.isPending, let i = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let current = messages[i].reactions.first(where: \.mine)?.emoji
        let newEmoji: String? = current == emoji ? nil : emoji
        var list = messages[i].reactions
        if let c = current, let j = list.firstIndex(where: { $0.emoji == c }) {
            list[j].count -= 1; list[j].mine = false
            if list[j].count <= 0 { list.remove(at: j) }
        }
        if let e = newEmoji {
            if let j = list.firstIndex(where: { $0.emoji == e }) { list[j].count += 1; list[j].mine = true }
            else { list.append(MessageReaction(emoji: e, count: 1, mine: true)) }
        }
        messages[i].reactions = list
        newEmoji == nil ? Haptics.impact(.light) : Haptics.impact(.soft)
        if let e = newEmoji { reactionFX = ReactionFX(emoji: e, messageID: message.id) }
        let repo = repo, id = message.id
        Task {
            if let updated = try? await repo.react(messageID: id, emoji: newEmoji),
               let k = messages.firstIndex(where: { $0.id == id }) {
                var u = updated
                u.key = messages[k].key
                messages[k] = u
            }
        }
    }

    func isPinned(_ message: ChatMessage) -> Bool { pinned.contains { $0.id == message.id } }

    var canPin: Bool { !peer.isGroup || group?.isAdmin == true }

    func togglePin(_ message: ChatMessage) {
        let want = !isPinned(message)
        let repo = repo, id = message.id
        Task {
            do { pinned = try await repo.pin(messageID: id, pinned: want) }
            catch let e as APIError { error = e } catch {}
        }
    }

    func setMuted(_ muted: Bool) async {
        try? await repo.setMuted(groupID: peerID, muted: muted)
        await refresh()
    }

    /// Больше сообщений — для вкладок «Медиа», «Файлы», «Музыка» в профиле чата
    func loadFullHistory() async -> [ChatMessage] {
        (try? await repo.thread(peerID: peerID, limit: 300).messages) ?? messages
    }

    func rename(to name: String) { peer.name = name }

    func loadStickers() async {
        guard packs.isEmpty else { return }
        packs = (try? await repo.stickers()) ?? []
    }

    /// Добавили или убрали набор — панель стикеров обновляется
    func reloadStickers() async {
        if let fresh = try? await repo.stickers() { packs = fresh }
    }

    /// Сообщаем собеседнику, что мы печатаем / записываем (раз в 3 секунды)
    func ping(_ action: String = "typing") {
        guard Date().timeIntervalSince(lastTypingPing) > 3 else { return }
        lastTypingPing = Date()
        let repo = repo, id = peerID
        Task { await repo.typing(peerID: id, action: action) }
    }

    // MARK: Отправка

    /// То, что нужно, чтобы повторить отправку, когда появится сеть
    private struct Outgoing {
        var text: String
        var entities: [TextEntity]
        var media: [OutgoingMedia]
        var replyID: String?
        var silent: Bool
        var cleanup: URL?
    }
    private var outbox: [(key: String, item: Outgoing)] = []
    private var retrying = false

    /// Загружает вложения и отправляет сообщение. Сначала в списке появляется «ожидающее» сообщение.
    /// Нет сети — сообщение остаётся «Отправляется…» с красным значком и уходит само, как только связь вернётся.
    @discardableResult
    func deliver(text: String, entities: [TextEntity], media: [OutgoingMedia] = [],
                 placeholders: [ChatAttachment] = [], silent: Bool = false, cleanup: URL? = nil) async -> Bool {
        guard !text.isEmpty || !media.isEmpty else { return false }
        let reply = replyTo
        replyTo = nil
        let local = ChatMessage(key: "local-" + UUID().uuidString, id: "local-" + UUID().uuidString, mine: true,
                                text: text, entities: entities, createdAt: Date(), editedAt: nil, read: false,
                                reply: reply.map { ReplyRef(id: $0.id, name: "", text: String($0.summary.prefix(140)), fromMe: $0.mine) },
                                attachments: placeholders, isPending: true)
        pending.append(local)
        let item = Outgoing(text: text, entities: entities, media: media, replyID: reply?.id, silent: silent, cleanup: cleanup)
        return await attempt(local.key, item, restoreReply: reply)
    }

    private func setFailed(_ key: String, _ value: Bool) {
        if let i = pending.firstIndex(where: { $0.key == key }), pending[i].failed != value { pending[i].failed = value }
    }

    /// true — сообщение принято (отправлено или ждёт сеть), false — отклонено сервером
    private func attempt(_ key: String, _ item: Outgoing, restoreReply: ChatMessage?) async -> Bool {
        do {
            var uploaded: [OutgoingAttachment] = []
            for m in item.media {
                switch m {
                case .sticker, .location: break
                default: ping(Self.action(for: m))
                }
                uploaded.append(try await repo.upload(m))
            }
            var sent = try await repo.send(peerID: peerID, text: item.text, entities: item.entities,
                                           attachments: uploaded, replyTo: item.replyID, silent: item.silent)
            sent.key = key
            pending.removeAll { $0.key == key }
            outbox.removeAll { $0.key == key }
            if let i = messages.firstIndex(where: { $0.id == sent.id }) { messages[i] = sent } else { messages.append(sent) }
            if let url = item.cleanup { try? FileManager.default.removeItem(at: url) }
            return true
        } catch {
            if let e = error as? APIError, e == .offline {
                if !outbox.contains(where: { $0.key == key }) { outbox.append((key, item)) }
                setFailed(key, true)
                return true
            }
            pending.removeAll { $0.key == key }
            outbox.removeAll { $0.key == key }
            if let url = item.cleanup { try? FileManager.default.removeItem(at: url) }
            if let e = error as? APIError { self.error = e }
            replyTo = restoreReply
            return false
        }
    }

    /// Связь вернулась — отправляем накопившееся по порядку
    func retryQueued() async {
        guard !retrying, !outbox.isEmpty else { return }
        retrying = true
        defer { retrying = false }
        for entry in outbox {
            guard pending.contains(where: { $0.key == entry.key }) else { outbox.removeAll { $0.key == entry.key }; continue }
            setFailed(entry.key, false)
            _ = await attempt(entry.key, entry.item, restoreReply: nil)
            if outbox.contains(where: { $0.key == entry.key }) { break }          // опять нет сети — остальное позже
        }
    }

    private static func action(for media: OutgoingMedia) -> String {
        switch media {
        case .prepared(let m): return m.isVideo ? "video" : "photo"
        case .circle: return "video"
        case .voice: return "voice"
        case .file, .audio: return "file"
        case .sticker, .location: return "typing"
        }
    }

    func sendSticker(_ sticker: Sticker) {
        Task {
            await deliver(text: "", entities: [], media: [.sticker(sticker.id)],
                          placeholders: [ChatAttachment(kind: .sticker, mediaID: sticker.mediaID,
                                                        mime: sticker.animated ? "video/mp4" : nil, sticker: sticker.id,
                                                        stickerPack: sticker.packID)])
        }
    }

    /// Геопозиция: точка (live = 0) или трансляция на live секунд. Трансляцию после отправки ведёт LiveLocationManager
    func sendLocation(_ point: GeoPoint, live: Int) {
        Task {
            var shown = point
            if live > 0 { shown.liveUntil = Date().addingTimeInterval(TimeInterval(live)) }
            let before = Set(messages.map(\.id))
            let ok = await deliver(text: "", entities: [], media: [.location(point, live: live)],
                                   placeholders: [ChatAttachment(kind: .location, geo: shown)])
            guard ok, live > 0,
                  let sent = messages.last(where: { $0.mine && !before.contains($0.id) && $0.attachments.contains { $0.kind == .location } }),
                  let until = sent.attachments.first(where: { $0.kind == .location })?.geo?.liveUntil else { return }
            LiveLocationManager.shared.start(messageID: sent.id, chatID: peerID, until: until, repo: repo)
        }
    }

    func sendVoice(url: URL, duration: Double, waveform: [Int]) {
        Task {
            await deliver(text: "", entities: [], media: [.voice(url: url, duration: duration, waveform: waveform)],
                          placeholders: [ChatAttachment(kind: .voice, duration: duration, waveform: waveform)], cleanup: url)
        }
    }

    func sendCircle(url: URL, thumb: Data, duration: Double) {
        Task {
            await deliver(text: "", entities: [], media: [.circle(url: url, thumb: thumb, duration: duration)],
                          placeholders: [ChatAttachment(kind: .circle, width: 480, height: 480, duration: duration,
                                                        localPreview: thumb)], cleanup: url)
        }
    }

    /// Правка текста (вложения остаются)
    func saveEdit(_ target: ChatMessage, text: String, entities: [TextEntity]) async -> Bool {
        editing = nil
        guard text != target.text || entities != target.entities else { return true }
        do {
            let updated = try await repo.edit(messageID: target.id, text: text, entities: entities)
            if let i = messages.firstIndex(where: { $0.id == target.id }) {
                var u = updated
                u.key = messages[i].key
                messages[i] = u
            }
            return true
        } catch {
            if let e = error as? APIError { self.error = e }
            return false
        }
    }

    /// Админ удаляет чужое сообщение и заодно: все сообщения автора, запрет писать, блокировка
    func moderate(_ message: ChatMessage, options: ModerationOptions) async {
        guard let author = message.sender?.id else { return await delete(message, forEveryone: true) }
        let gone = Set(messages.filter { $0.id == message.id || (options.deleteAll && $0.sender?.id == author && $0.system == nil) }.map(\.id))
        await dissolve(Array(gone))
        withAnimation(Self.closeGap) {
            messages.removeAll { gone.contains($0.id) }
            dissolving.subtract(gone)
            freezing.subtract(gone)
        }
        do { try await repo.moderate(groupID: peerID, userID: author, messageID: message.id, options: options) }
        catch let e as APIError { error = e } catch {}
        await refresh()
    }

    /// Сообщения рассыпаются на частицы (как в Telegram); строки сразу можно убирать из списка — пыль летит поверх
    func dissolve(_ ids: [String]) async {
        Haptics.impact(.soft)
        let frames = ids.compactMap { frameOf?($0) }
        freezing.formUnion(ids)
        try? await Task.sleep(nanoseconds: 40_000_000)            // превью вместо видео успевает отрисоваться
        await MessageDust.burst(frames) { dissolving.formUnion(ids) }
        try? await Task.sleep(nanoseconds: 90_000_000)            // пыль уже отрывается — теперь соседи плавно съезжают
    }

    /// Как соседние сообщения съезжают на место удалённого
    static let closeGap = Animation.spring(response: 0.45, dampingFraction: 0.9)

    /// Несколько выбранных: рассыпаются и уходят из списка разом, запросы на сервер — уже после
    func deleteMany(_ list: [ChatMessage]) async {
        let ids = Set(list.map(\.id))
        await dissolve(Array(ids))
        withAnimation(Self.closeGap) {
            messages.removeAll { ids.contains($0.id) }
            dissolving.subtract(ids)
            freezing.subtract(ids)
        }
        for m in list {
            do { try await repo.delete(messageID: m.id, forEveryone: false) }
            catch let e as APIError { error = e } catch {}
        }
        await refresh()
    }

    func delete(_ message: ChatMessage, forEveryone: Bool, animated: Bool = true) async {
        if animated { await dissolve([message.id]) }
        withAnimation(Self.closeGap) {
            messages.removeAll { $0.id == message.id }
            dissolving.remove(message.id)
            freezing.remove(message.id)
        }
        do { try await repo.delete(messageID: message.id, forEveryone: forEveryone) }
        catch let e as APIError { error = e } catch {}
        await refresh()
    }
}

struct ChatRoute: Identifiable, Hashable {
    let peer: ChatPeer
    var id: String { peer.id }
}


/// Найденное сообщение в глобальном поиске по чатам
struct MessageHit: Identifiable, Hashable {
    let id: String
    let peer: ChatPeer
    let text: String
    let mine: Bool
    let date: Date
}
