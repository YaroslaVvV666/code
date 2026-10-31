import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Анимация отправки / скачивания

/// Вращающаяся дуга — «отправляется». Без таймеров: одна бесконечная анимация на слой.
struct SpinnerRing: View {
    var size: CGFloat = 12
    var lineWidth: CGFloat = 1.6
    var color: Color = .white
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.85).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
            .drawingGroup()
    }
}

/// Кольцо прогресса с крестиком/стрелкой внутри. progress == nil — неопределённая загрузка.
struct TransferRing: View {
    var progress: Double?
    var icon: String = "arrow.down"
    var size: CGFloat = 42
    var tint: Color = .white
    var track: Color = Color.white.opacity(0.28)

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: 2.4)
            if let p = progress {
                Circle().trim(from: 0, to: max(0.04, min(1, p)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: p)
            } else {
                SpinnerRing(size: size, lineWidth: 2.4, color: tint)
            }
            Image(systemName: icon).font(.system(size: size * 0.34, weight: .bold)).foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

/// Живая «отправка» вместо часиков в метке времени сообщения
struct SendingIndicator: View {
    var color: Color
    var body: some View { SpinnerRing(size: 10, lineWidth: 1.4, color: color) }
}

/// Прогресс скачиваний по mediaID (общий для всех блоков)
@MainActor
final class DownloadCenter: ObservableObject {
    static let shared = DownloadCenter()
    @Published private(set) var progress: [String: Double] = [:]

    func set(_ id: String, _ value: Double?) {
        if let value {
            // не чаще ~50 обновлений на файл
            if let old = progress[id], abs(old - value) < 0.02, value < 1 { return }
            progress[id] = value
        } else {
            progress[id] = nil
        }
    }
}

final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    let id: String
    init(id: String) { self.id = id }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let id = id
        Task { @MainActor in DownloadCenter.shared.set(id, p) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

// MARK: - Медиа из переписок на телефоне (как в Telegram)

/// Видео, голосовые и кружки из переписок один раз скачиваются и дальше лежат на телефоне: открываются сразу и без сети.
/// Пропадают, только если очистить кэш («Данные и память») — тогда при просмотре снова скачиваются, с прогрессом
final class MediaFileCache: @unchecked Sendable {
    static let shared = MediaFileCache()

    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-media-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Расширения, под которыми файл может лежать: по нему AVPlayer понимает, что это за файл
    private static let extensions = ["mp4", "mov", "m4v", "m4a", "mp3", "aac", "wav", "caf"]

    private let lock = NSLock()
    private var hits: [String: URL] = [:]                       // уже найденные на диске — без лишних обращений к файлам
    private var inflight: [String: Task<URL?, Never>] = [:]     // одно и то же видео качается один раз

    private static func base(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    /// Файл на телефоне, если уже скачан
    func cached(_ id: String) -> URL? {
        if let hit = lock.withLock({ hits[id] }) {
            if FileManager.default.fileExists(atPath: hit.path) { return hit }
            lock.withLock { hits[id] = nil }
        }
        let b = Self.base(id)
        for ext in Self.extensions {
            let url = Self.dir.appendingPathComponent(b + "." + ext)
            if FileManager.default.fileExists(atPath: url.path) {
                lock.withLock { hits[id] = url }
                return url
            }
        }
        return nil
    }

    /// Что проигрывать: файл с телефона, а если его нет — с сервера
    func playableURL(_ id: String) -> URL? { cached(id) ?? ServerConfig.mediaURL(id) }

    /// Скачать на телефон (с прогрессом в DownloadCenter). fallback — расширение, если сервер не сказал тип файла
    @discardableResult
    func download(_ id: String, fallback: String = "mp4") async -> URL? {
        if let hit = cached(id) { return hit }
        let task: Task<URL?, Never> = lock.withLock {
            if let running = inflight[id] { return running }
            let t = Task<URL?, Never>(priority: .utility) { await Self.fetch(id, fallback: fallback) }
            inflight[id] = t
            return t
        }
        let result = await task.value
        lock.withLock {
            inflight[id] = nil
            if let result { hits[id] = result }
        }
        return result
    }

    /// Очередь фоновых загрузок: не больше двух одновременно, чтобы открытый чат с кучей видео не забирал весь канал
    private var pending: [(id: String, fallback: String)] = []
    private var workers = 0
    private static let maxWorkers = 2

    /// Начать скачивание в фоне, если файла ещё нет. Последнее попросившее качается первым (самые свежие сообщения внизу чата)
    func prefetch(_ id: String, fallback: String = "mp4") {
        guard cached(id) == nil else { return }
        let spawn: Bool = lock.withLock {
            if inflight[id] != nil || pending.contains(where: { $0.id == id }) { return false }
            pending.append((id: id, fallback: fallback))
            guard workers < Self.maxWorkers else { return false }
            workers += 1
            return true
        }
        if spawn { Task.detached(priority: .utility) { [self] in await drain() } }
    }

    private func drain() async {
        while true {
            let next: (id: String, fallback: String)? = lock.withLock {
                if pending.isEmpty { workers -= 1; return nil }
                return pending.removeLast()
            }
            guard let next else { return }
            _ = await download(next.id, fallback: next.fallback)
        }
    }

    private static func fetch(_ id: String, fallback: String) async -> URL? {
        guard let remote = ServerConfig.mediaURL(id) else { return nil }
        await MainActor.run { DownloadCenter.shared.set(id, 0) }
        defer { Task { @MainActor in DownloadCenter.shared.set(id, nil) } }
        do {
            let (temp, response) = try await URLSession.shared.download(from: remote, delegate: DownloadProgressDelegate(id: id))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: temp)
                return nil
            }
            var ext = response.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? fallback
            if !extensions.contains(ext) { ext = fallback }
            let target = dir.appendingPathComponent(base(id) + "." + ext)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temp, to: target)
            return target
        } catch {
            return nil
        }
    }

    /// Сколько занимают скачанные медиа
    func diskUsage() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Очистка кэша: всё скачанное удаляется, при следующем просмотре скачается заново
    func clear() {
        lock.withLock { hits.removeAll() }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil)) ?? []
        for f in files { try? FileManager.default.removeItem(at: f) }
    }
}
