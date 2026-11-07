import Foundation
import Combine

/// Очередь сообщений, написанных без связи. Лежит на диске (Application Support/outbox), поэтому переживает
/// выход из чата и перезапуск приложения: когда связь вернётся, сообщения уйдут сами — из открытого чата
/// или фоном, если чат закрыт. Файлы (голосовые, кружки, документы) копируются в папку очереди.
@MainActor
final class PersistentOutbox {
    static let shared = PersistentOutbox()

    struct Entry: Codable, Equatable {
        enum Media: Codable, Equatable {
            case sticker(String)
            case voice(file: String, duration: Double, waveform: [Int])
            case circle(file: String, thumb: Data, duration: Double)
            case document(file: String, name: String, mime: String)
        }
        let key: String
        let peerID: String
        let text: String
        let entities: [TextEntity]
        let replyID: String?
        let silent: Bool
        let createdAt: Date
        var media: [Media]
    }

    private(set) var entries: [Entry] = []
    private var bag: AnyCancellable?
    private var repo: MessengerRepository?
    private var account = ""
    private var flushing = false
    /// Переписки, открытые сейчас: их очередь отправляет сам экран чата (с «Отправляется…» в списке)
    private var openChats: [String: Int] = [:]

    private static let dir: URL = {
        var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? base.setResourceValues(values)
        return base
    }()
    /// У каждого аккаунта своя очередь: после смены аккаунта чужие сообщения не уйдут от его имени
    private var file: URL {
        let safe = String(account.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.prefix(64))
        return Self.dir.appendingPathComponent("queue-\(safe).json")
    }

    private init() {}

    /// Приложение вошло в аккаунт: очередь отправляется, как только появляется связь
    func attach(repo: MessengerRepository, account: String) {
        self.repo = repo
        self.account = account
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = list
        } else {
            entries = []
        }
        bag = NetworkState.shared.$offline.removeDuplicates().sink { [weak self] offline in
            if !offline { Task { await self?.flush() } }
        }
        Task { await flush() }
    }

    func detach() {
        bag = nil
        repo = nil
        entries = []
        account = ""
    }

    // MARK: Очередь

    /// Сохранить сообщение в очередь. false — вложение нельзя сохранить (фото/видео ещё в памяти) — останется только в памяти чата
    @discardableResult
    func add(key: String, peerID: String, text: String, entities: [TextEntity], replyID: String?, silent: Bool,
             media: [OutgoingMedia]) -> Bool {
        guard !entries.contains(where: { $0.key == key }) else { return true }
        var stored: [Entry.Media] = []
        for m in media {
            switch m {
            case .sticker(let id): stored.append(.sticker(id))
            case .voice(let url, let duration, let waveform):
                guard let name = copy(url, key: key) else { return false }
                stored.append(.voice(file: name, duration: duration, waveform: waveform))
            case .circle(let url, let thumb, let duration):
                guard let name = copy(url, key: key) else { return false }
                stored.append(.circle(file: name, thumb: thumb, duration: duration))
            case .file(let url, let fileName, let mime):
                guard let name = copy(url, key: key) else { return false }
                stored.append(.document(file: name, name: fileName, mime: mime))
            default:
                return false
            }
        }
        entries.append(Entry(key: key, peerID: peerID, text: text, entities: entities, replyID: replyID,
                             silent: silent, createdAt: Date(), media: stored))
        save()
        return true
    }

    func remove(_ key: String) {
        guard let i = entries.firstIndex(where: { $0.key == key }) else { return }
        entries.remove(at: i)
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(key, isDirectory: true))
        save()
    }

    func entries(for peerID: String) -> [Entry] { entries.filter { $0.peerID == peerID } }

    func chatOpened(_ peerID: String) { openChats[peerID, default: 0] += 1 }
    func chatClosed(_ peerID: String) {
        openChats[peerID, default: 1] -= 1
        if openChats[peerID] ?? 0 <= 0 { openChats[peerID] = nil }
    }

    /// Сообщение из очереди → то, что умеет отправлять чат
    func outgoing(_ m: Entry.Media) -> OutgoingMedia {
        switch m {
        case .sticker(let id): return .sticker(id)
        case .voice(let file, let duration, let waveform): return .voice(url: url(file), duration: duration, waveform: waveform)
        case .circle(let file, let thumb, let duration): return .circle(url: url(file), thumb: thumb, duration: duration)
        case .document(let file, let name, let mime): return .file(url: url(file), name: name, mime: mime)
        }
    }

    /// Заглушка для списка сообщений, пока сообщение ждёт отправки
    func placeholder(_ m: Entry.Media) -> ChatAttachment {
        switch m {
        case .sticker(let id): return ChatAttachment(kind: .sticker, sticker: id)
        case .voice(_, let duration, let waveform): return ChatAttachment(kind: .voice, duration: duration, waveform: waveform)
        case .circle(_, _, let duration): return ChatAttachment(kind: .circle, duration: duration)
        case .document(_, let name, let mime): return ChatAttachment(kind: .file, name: name, mime: mime)
        }
    }

    // MARK: Фоновая отправка (чат закрыт)

    func flush() async {
        guard !flushing, let repo, !NetworkState.shared.offline else { return }
        flushing = true
        defer { flushing = false }
        for entry in entries where openChats[entry.peerID] == nil {
            do {
                var uploaded: [OutgoingAttachment] = []
                for m in entry.media { uploaded.append(try await repo.upload(outgoing(m))) }
                _ = try await repo.send(peerID: entry.peerID, text: entry.text, entities: entry.entities,
                                        attachments: uploaded, replyTo: entry.replyID, silent: entry.silent)
                remove(entry.key)
            } catch let e as APIError where e == .offline {
                return                                  // связь опять пропала — продолжим, когда вернётся
            } catch {
                remove(entry.key)                       // сервер отказал (чат удалён, нас заблокировали) — не крутим вечно
            }
        }
    }

    // MARK: Диск

    private func url(_ name: String) -> URL { Self.dir.appendingPathComponent(name) }

    private func copy(_ src: URL, key: String) -> String? {
        let folder = Self.dir.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = key + "/" + UUID().uuidString + "-" + SafeFileName.clean(src.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: src, to: url(name))
            return name
        } catch {
            return nil
        }
    }

    private func save() {
        guard !account.isEmpty, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
