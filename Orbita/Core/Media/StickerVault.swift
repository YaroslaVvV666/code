import Foundation
import Combine
import UIKit

/// Стикеры установленных наборов — постоянно на телефоне.
///
/// Лежат в Application Support (не в Caches): iOS не вычищает их при нехватке места, а «Очистить кэш» в настройках
/// их не трогает. Набор пропадает с телефона ТОЛЬКО когда человек сам зашёл в него и нажал «Удалить» / «Убрать».
/// Список наборов тоже хранится здесь — панель стикеров открывается и без сети.
final class StickerVault: @unchecked Sendable {
    static let shared = StickerVault()

    private let lock = NSLock()
    private let root: URL
    private let files: URL
    private var inflight: Set<String> = []
    private var known: [String: URL] = [:]              // уже найденные на диске файлы
    private let images = NSCache<NSString, UIImage>()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("StickerVault", isDirectory: true)
        files = root.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        // в резервную копию iCloud не кладём: при восстановлении всё скачается заново само
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var r = root
        try? r.setResourceValues(values)
        images.countLimit = 300
    }

    // MARK: - Список наборов (по аккаунту)

    private struct StickerRecord: Codable {
        let id: String
        let emoji: String
        let mediaID: String?
        let animated: Bool
        var lottie: Bool? = nil
    }

    private struct PackRecord: Codable {
        let id: String
        let title: String
        let icon: String
        let mine: Bool
        let stickers: [StickerRecord]
        var kind: String? = nil
    }

    private func listURL(_ account: String) -> URL {
        let safe = String(account.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return root.appendingPathComponent("packs-\(safe).json")
    }

    private static func record(_ p: StickerPack) -> PackRecord {
        PackRecord(id: p.id, title: p.title, icon: p.icon, mine: p.mine,
                   stickers: p.stickers.map { StickerRecord(id: $0.id, emoji: $0.emoji, mediaID: $0.mediaID, animated: $0.animated,
                                                            lottie: $0.lottie) },
                   kind: p.kind)
    }

    private static func model(_ r: PackRecord) -> StickerPack {
        StickerPack(id: r.id, title: r.title, icon: r.icon,
                    stickers: r.stickers.map { Sticker(id: $0.id, emoji: $0.emoji, mediaID: $0.mediaID, animated: $0.animated,
                                                       packID: r.id, lottie: $0.lottie ?? false) },
                    mine: r.mine, kind: r.kind ?? "sticker")
    }

    private func readRecords(_ account: String) -> [PackRecord] {
        guard let data = try? Data(contentsOf: listURL(account)) else { return [] }
        return (try? JSONDecoder().decode([PackRecord].self, from: data)) ?? []
    }

    private func writeRecords(_ list: [PackRecord], _ account: String) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: listURL(account), options: .atomic)
    }

    /// Сохранённые наборы (nil — ни разу не сохраняли)
    func packs(account: String) -> [StickerPack]? {
        guard FileManager.default.fileExists(atPath: listURL(account).path) else { return nil }
        return lock.withLock { readRecords(account) }.map(Self.model)
    }

    /// Свежий список с сервера. Наборы, которых в ответе нет, с телефона НЕ удаляем —
    /// только если человек сам удалил набор (forget). Новое докачивается в фоне
    func store(_ fresh: [StickerPack], account: String) {
        lock.withLock {
            let freshIDs = Set(fresh.map(\.id))
            var list = fresh.map(Self.record)
            // наборы, удалённые не через приложение (например, с другого устройства), остаются, пока их не уберут здесь
            list += readRecords(account).filter { !freshIDs.contains($0.id) }
            writeRecords(list, account)
        }
        download(fresh.filter { !$0.isEmoji }.flatMap(\.stickers))      // свои эмодзи хранит CustomEmojiStore
    }

    /// Человек добавил набор — сразу на телефон
    func keep(_ pack: StickerPack, account: String) {
        lock.withLock {
            var list = readRecords(account).filter { $0.id != pack.id }
            list.append(Self.record(pack))
            writeRecords(list, account)
        }
        download(pack.stickers)
    }

    /// Человек сам удалил набор — убираем его из списка и стираем файлы, которые больше ни одному набору не нужны
    func forget(packID: String, account: String) {
        let orphans: [String] = lock.withLock {
            var list = readRecords(account)
            guard let gone = list.first(where: { $0.id == packID }) else { return [] }
            list.removeAll { $0.id == packID }
            writeRecords(list, account)
            let stillUsed = Set(list.flatMap { $0.stickers.map { Self.fileName(id: $0.id, mediaID: $0.mediaID, animated: $0.animated) } })
            return gone.stickers.map { Self.fileName(id: $0.id, mediaID: $0.mediaID, animated: $0.animated) }
                .filter { !stillUsed.contains($0) }
        }
        for name in orphans {
            let url = files.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            lock.withLock { known[name] = nil }
            images.removeObject(forKey: name as NSString)
        }
    }

    // MARK: - Файлы

    private static func fileName(id: String, mediaID: String?, animated: Bool) -> String {
        let raw = mediaID.map { "m_" + $0 } ?? ("b_" + id)
        let safe = String(raw.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        return safe + (animated ? ".mp4" : (mediaID == nil ? ".png" : ".img"))
    }

    private static func fileName(_ s: Sticker) -> String { fileName(id: s.id, mediaID: s.mediaID, animated: s.animated) }

    private static func remote(_ s: Sticker) -> URL? {
        if let media = s.mediaID { return ServerConfig.mediaURL(media) }
        return s.url
    }

    /// Файл стикера на телефоне, если уже скачан
    func localFile(_ s: Sticker) -> URL? {
        let name = Self.fileName(s)
        if let hit = lock.withLock({ known[name] }) { return hit }
        let url = files.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        lock.withLock { known[name] = url }
        return url
    }

    /// Уже разжатая картинка из памяти (без обращения к диску)
    func cachedImage(_ s: Sticker, maxPixel: CGFloat) -> UIImage? {
        images.object(forKey: "\(Self.fileName(s))@\(Int(maxPixel))" as NSString)
    }

    /// Картинка стикера с телефона, разжатая под нужный размер — в фоне
    func image(_ s: Sticker, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(Self.fileName(s))@\(Int(maxPixel))" as NSString
        if let img = images.object(forKey: key) { return img }
        guard let url = localFile(s) else { return nil }
        let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ImageCache.downsample(data, maxPixel: maxPixel)
        }.value
        if let img { images.setObject(img, forKey: key) }
        return img
    }

    /// Скачать недостающие (по 3 одновременно, в фоне)
    func download(_ stickers: [Sticker]) {
        let todo: [Sticker] = lock.withLock {
            var seen = Set<String>()
            return stickers.filter { s in
                let name = Self.fileName(s)
                guard seen.insert(name).inserted, !inflight.contains(name),
                      !FileManager.default.fileExists(atPath: files.appendingPathComponent(name).path) else { return false }
                inflight.insert(name)
                return true
            }
        }
        guard !todo.isEmpty else { return }
        Task.detached(priority: .utility) { [self] in
            await withTaskGroup(of: Void.self) { group in
                var it = todo.makeIterator()
                for _ in 0..<3 { if let s = it.next() { group.addTask { await self.fetch(s) } } }
                while await group.next() != nil {
                    if let s = it.next() { group.addTask { await self.fetch(s) } }
                }
            }
        }
    }

    private func fetch(_ s: Sticker) async {
        let name = Self.fileName(s)
        defer { _ = lock.withLock { inflight.remove(name) } }
        guard let remote = Self.remote(s) else { return }
        do {
            let (temp, response) = try await URLSession.shared.download(from: remote)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: temp)
                return
            }
            let target = files.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temp, to: target)
            lock.withLock { known[name] = target }
        } catch {}
    }

    /// Сколько места занимают стикеры (для «Данные и память»)
    func diskUsage() -> Int {
        let list = (try? FileManager.default.contentsOfDirectory(at: files, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return list.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
