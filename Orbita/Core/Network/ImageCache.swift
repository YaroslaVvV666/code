import SwiftUI
import UIKit
import ImageIO

/// Кэш картинок: готовые уменьшенные UIImage в памяти + общая загрузка одной и той же картинки.
/// Раньше AsyncImage каждый раз заново декодировал полноразмерный файл — при прокрутке ленты и чата это давало подтормаживания.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        memory.totalCostLimit = 140 * 1024 * 1024
        memory.countLimit = 500
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.memory.removeAllObjects()
        }
    }

    private func key(_ url: URL, _ maxPixel: CGFloat) -> NSString { "\(url.absoluteString)@\(Int(maxPixel))" as NSString }

    /// Только память — без диска и декодирования. Безопасно звать из init вью и на главном потоке хоть каждый кадр.
    func memory(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        memory.object(forKey: key(url, maxPixel))
    }

    /// Аватарки с диска уже обновляли с сети в этом запуске — повторно не качаем
    private var refreshed = Set<String>()

    /// Мгновенно, без ожидания: есть ли уже готовая картинка (persistKey — аватарка из постоянного дискового кэша).
    /// ВНИМАНИЕ: при промахе памяти читает и декодирует файл — не вызывать на главном потоке в горячих местах.
    func cached(_ url: URL, maxPixel: CGFloat, persistKey: String? = nil) -> UIImage? {
        let k = key(url, maxPixel)
        if let hit = memory.object(forKey: k) { return hit }
        if let persistKey, let disk = AvatarStore.image(persistKey, maxPixel: maxPixel) {
            memory.setObject(disk, forKey: k)                 // с диска — сразу в память, дальше без чтения файла
            return disk
        }
        return nil
    }

    func load(_ url: URL, maxPixel: CGFloat, persistKey: String? = nil) async -> UIImage? {
        let k = key(url, maxPixel)
        if let hit = memory.object(forKey: k) { return hit }
        // чтение файла и декодирование — явно в фоне (не зависим от того, на каком акторе нас вызвали)
        var disk: UIImage?
        if let persistKey {
            disk = await Task.detached(priority: .userInitiated) { AvatarStore.image(persistKey, maxPixel: maxPixel) }.value
        }
        if let persistKey, let disk {
            memory.setObject(disk, forKey: k)
            // обновим с сети в фоне (вдруг аватарку сменили) — но один раз за запуск, а не при каждом показе
            lock.lock()
            let fresh = refreshed.insert(k as String).inserted
            lock.unlock()
            if fresh {
                Task.detached(priority: .utility) { _ = await self.task(for: k as String, url: url, maxPixel: maxPixel, persistKey: persistKey).value; self.finish(k as String) }
            }
            return disk
        }
        let image = await task(for: k as String, url: url, maxPixel: maxPixel, persistKey: persistKey).value
        finish(k as String)
        if let image {
            let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
            memory.setObject(image, forKey: k, cost: cost)
        }
        return image
    }

    // Синхронные помощники: замок не держится через await
    private func task(for k: String, url: URL, maxPixel: CGFloat, persistKey: String? = nil) -> Task<UIImage?, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let running = inflight[k] { return running }
        let created = Task.detached(priority: .userInitiated) { () -> UIImage? in
            // файлы на сервере неизменяемые (id = содержимое), поэтому берём из дискового кэша без повторных запросов
            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            if let persistKey { AvatarStore.save(data, id: persistKey) }        // аватарку — в постоянный кэш для работы без сети
            return ImageCache.downsample(data, maxPixel: maxPixel)
        }
        inflight[k] = created
        return created
    }

    private func finish(_ k: String) {
        lock.lock()
        inflight[k] = nil
        lock.unlock()
    }

    /// Декодирует сразу в нужный размер (в фоне), а не полный кадр
    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Загружает картинку из кэша и отдаёт её во вью; готовая из памяти показывается без мигания
struct CachedImage<Content: View>: View {
    let url: URL?
    let maxPixel: CGFloat
    /// Аватарки сохраняются в постоянный кэш (показываются без сети) — сюда передаётся их mediaID
    let persistKey: String?
    @ViewBuilder let content: (_ image: UIImage?, _ failed: Bool) -> Content

    @State private var image: UIImage?
    @State private var failed = false

    init(url: URL?, maxPixel: CGFloat = 1280, persistKey: String? = nil,
         @ViewBuilder content: @escaping (_ image: UIImage?, _ failed: Bool) -> Content) {
        self.url = url
        self.maxPixel = maxPixel
        self.persistKey = persistKey
        self.content = content
        // в init — только память: init вызывается при каждом пересчёте тела родителя (а внутри анимаций — каждый кадр),
        // и чтение файла с декодированием здесь намертво вешало главный поток
        _image = State(initialValue: url.flatMap { ImageCache.shared.memory($0, maxPixel: maxPixel) })
    }

    var body: some View {
        content(image, failed)
            .task(id: url) {
                guard let url else { image = nil; return }
                if let hit = ImageCache.shared.memory(url, maxPixel: maxPixel) { image = hit; failed = false; return }
                image = nil
                failed = false
                let started = Date()
                // диск и сеть — в фоне (load не привязан к главному актору)
                let loaded = await ImageCache.shared.load(url, maxPixel: maxPixel, persistKey: persistKey)
                guard !Task.isCancelled else { return }
                if Date().timeIntervalSince(started) < 0.06 {
                    // нашлось почти сразу (с диска) — ставим без анимации, чтобы не мигала заглушка
                    image = loaded
                    failed = loaded == nil
                } else {
                    // картинка проявляется плавно, а не выскакивает на место заглушки
                    withAnimation(.easeOut(duration: 0.22)) {
                        image = loaded
                        failed = loaded == nil
                    }
                }
            }
    }
}

/// Один раз созданные форматтеры дат: создание DateFormatter дорогое, а раньше оно шло на каждую строку чата
enum FormatterCache {
    private static var store: [String: DateFormatter] = [:]
    private static let lock = NSLock()

    static func formatter(_ key: String, _ configure: (DateFormatter) -> Void) -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let f = store[key] { return f }
        let f = DateFormatter()
        configure(f)
        store[key] = f
        return f
    }

    static func format(_ date: Date, _ pattern: String, locale: Locale? = nil) -> String {
        formatter("\(locale?.identifier ?? "-")|\(pattern)") { f in
            if let locale { f.locale = locale }
            f.dateFormat = pattern
        }.string(from: date)
    }

    static func localized(_ date: Date, template: String, locale: Locale) -> String {
        formatter("\(locale.identifier)|t|\(template)") { f in
            f.locale = locale
            f.setLocalizedDateFormatFromTemplate(template)
        }.string(from: date)
    }
}

/// Постоянный кэш аватарок: маленькие картинки лежат на диске (Application Support, без вычистки системой и без бэкапа),
/// поэтому своя и уже виденные аватарки показываются без интернета даже после перезапуска.
enum AvatarStore {
    private static let dir: URL = {
        var d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("avatars-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? d.setResourceValues(values)
        return d
    }()

    private static func file(_ id: String) -> URL {
        let safe = String(id.prefix(120).map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        return dir.appendingPathComponent(safe)
    }

    static func has(_ id: String) -> Bool { FileManager.default.fileExists(atPath: file(id).path) }

    /// Декодированная с диска картинка нужного размера (nil — ещё не сохранена)
    static func image(_ id: String, maxPixel: CGFloat) -> UIImage? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return ImageCache.downsample(data, maxPixel: maxPixel)
    }

    /// Сохранить исходные байты аватарки на диск (под защитой данных iOS)
    static func save(_ data: Data, id: String) {
        guard !data.isEmpty, !has(id) else { return }
        try? data.write(to: file(id), options: [.atomic, .completeFileProtection])
        prune()
    }

    /// Закачать свою аватарку в кэш заранее — чтобы без сети она точно была
    static func pin(_ id: String) async {
        guard !id.isEmpty, !has(id), let url = ServerConfig.mediaURL(id) else { return }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        save(data, id: id)
    }

    /// Не разрастаться бесконечно: держим 400 самых свежих файлов
    private static func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > 400 else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for f in sorted.dropFirst(400) { try? FileManager.default.removeItem(at: f) }
    }
}
