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

    /// Мгновенно, без ожидания: есть ли уже готовая картинка
    func cached(_ url: URL, maxPixel: CGFloat) -> UIImage? { memory.object(forKey: key(url, maxPixel)) }

    func load(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        let k = key(url, maxPixel)
        if let hit = memory.object(forKey: k) { return hit }
        let image = await task(for: k as String, url: url, maxPixel: maxPixel).value
        finish(k as String)
        if let image {
            let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
            memory.setObject(image, forKey: k, cost: cost)
        }
        return image
    }

    // Синхронные помощники: замок не держится через await
    private func task(for k: String, url: URL, maxPixel: CGFloat) -> Task<UIImage?, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let running = inflight[k] { return running }
        let created = Task.detached(priority: .userInitiated) { () -> UIImage? in
            // файлы на сервере неизменяемые (id = содержимое), поэтому берём из дискового кэша без повторных запросов
            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
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
    @ViewBuilder let content: (_ image: UIImage?, _ failed: Bool) -> Content

    @State private var image: UIImage?
    @State private var failed = false

    init(url: URL?, maxPixel: CGFloat = 1280, @ViewBuilder content: @escaping (_ image: UIImage?, _ failed: Bool) -> Content) {
        self.url = url
        self.maxPixel = maxPixel
        self.content = content
        _image = State(initialValue: url.flatMap { ImageCache.shared.cached($0, maxPixel: maxPixel) })
    }

    var body: some View {
        content(image, failed)
            .task(id: url) {
                guard let url else { image = nil; return }
                if let hit = ImageCache.shared.cached(url, maxPixel: maxPixel) { image = hit; failed = false; return }
                image = nil
                failed = false
                let loaded = await ImageCache.shared.load(url, maxPixel: maxPixel)
                guard !Task.isCancelled else { return }
                image = loaded
                failed = loaded == nil
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
