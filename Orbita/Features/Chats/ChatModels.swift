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

    /// При входе в «Чаты»: сначала самые свежие (список уже отсортирован), по 10 сообщений
    func warm(_ chats: [ChatSummary], repo: MessengerRepository, count: Int = 8, limit: Int = 10) {
        self.repo = repo
        for c in chats.prefix(count) { enqueue(c, limit: limit) }
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
    @Published var error: APIError?
    /// Открыта переписка — нижняя панель вкладок прячется (как в Telegram)
    @Published var chatOpen = false
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
        if ticks % 3 == 1 { await refreshNotices() }
        do {
            let result = try await repo.chats()
            if loaded {
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
                                  duration: m.duration ?? 0, localPreview: m.thumbnail)
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
        // предзагруженные сообщения показываем сразу; свежие приходят следом обычным обновлением
        if let t = ThreadPrefetcher.shared.get(peer.id) {
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
                if abs(fresh.count - messages.count) > 3 {
                    // длинная история разом (10 предзагруженных → 100): без анимации появления — иначе строки «въезжали» с нулевой прозрачностью
                    // и экран на миг оставался пустым, пока не пролистаешь
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { messages = fresh }
                } else {
                    messages = fresh
                }
            }
            peer = thread.peer
            typing = thread.typing
            lastSeen = thread.lastSeen
            canWrite = thread.canWrite
            group = thread.group
            isContact = thread.isContact
            realName = thread.realName
            if thread.pinned != pinned { pinned = thread.pinned }
            isPreview = thread.isPreview
            if !loaded { firstUnreadID = thread.firstUnread }
            loaded = true
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

    // MARK: Реакции и закреп

    /// Одна реакция на человека: новая заменяет старую, такая же — снимает
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
                if case .sticker = m {} else { ping(Self.action(for: m)) }
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
        case .sticker: return "typing"
        }
    }

    func sendSticker(_ sticker: Sticker) {
        Task {
            await deliver(text: "", entities: [], media: [.sticker(sticker.id)],
                          placeholders: [ChatAttachment(kind: .sticker, sticker: sticker.id)])
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

    func delete(_ message: ChatMessage, forEveryone: Bool, animated: Bool = true) async {
        if animated {
            dissolving.insert(message.id)
            Haptics.impact(.soft)
            try? await Task.sleep(nanoseconds: 950_000_000)
        }
        withAnimation(.easeOut(duration: 0.25)) {
            messages.removeAll { $0.id == message.id }
            dissolving.remove(message.id)
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
