import SwiftUI
#if canImport(Lottie)
import Lottie
#endif

#if canImport(Lottie)
/// Разобранные анимации лежат в памяти: JSON на 300–400 КБ разбирается один раз, а не при каждом показе эмодзи
final class LottieSyncCache {
    static let shared = LottieSyncCache()
    private let lock = NSLock()
    private var items: [String: LottieAnimation] = [:]
    func get(_ key: String) -> LottieAnimation? { lock.lock(); defer { lock.unlock() }; return items[key] }
    func set(_ key: String, _ value: LottieAnimation) { lock.lock(); items[key] = value; lock.unlock() }
}

/// Готовые картинки покоя: эмодзи в панели, в сообщениях и в списке стоят как обычные картинки, а настоящая Lottie-анимация
/// создаётся только на время проигрывания. Сложная векторная сцена (512×512, десятки слоёв) для неподвижного эмодзи не строится вообще —
/// именно её построение давало лаги при открытии чата и панели
@MainActor
final class LottieSnapshots {
    static let shared = LottieSnapshots()
    private var images: [String: UIImage] = [:]

    func cached(_ emoji: String, atEnd: Bool) -> UIImage? { images[emoji + (atEnd ? "#1" : "#0")] }

    /// Картинки покоя лежат ещё и на диске (PNG): после первого запуска Lottie для неподвижных эмодзи не нужен вообще —
    /// ни разбор JSON на 300–500 КБ, ни построение векторной сцены. Версия в имени папки сбрасывает кэш, если поменять вид снимка
    private static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("emoji-snap-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func file(_ emoji: String, atEnd: Bool) -> URL {
        dir.appendingPathComponent(LottieEmojiStore.code(emoji) + (atEnd ? "_end" : "_start") + ".png")
    }

    /// Читаем и разжимаем картинки с диска вне главного потока, на экран они попадают уже готовыми
    func loadFromDisk() async {
        for emoji in AnimatedEmoji.all {
            for atEnd in [true, false] where cached(emoji, atEnd: atEnd) == nil {
                let url = Self.file(emoji, atEnd: atEnd)
                let image = await Task.detached(priority: .utility) { () -> UIImage? in
                    guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
                    return img.preparingForDisplay() ?? img
                }.value
                if let image { images[emoji + (atEnd ? "#1" : "#0")] = image }
            }
        }
    }

    @discardableResult
    func prepare(_ emoji: String, _ animation: LottieAnimation, atEnd: Bool = true) -> UIImage? {
        let key = emoji + (atEnd ? "#1" : "#0")
        if let hit = images[key] { return hit }
        let view = LottieAnimationView(animation: animation, configuration: LottieConfiguration(renderingEngine: .mainThread))
        view.frame = CGRect(x: 0, y: 0, width: 160, height: 160)
        view.contentMode = .scaleAspectFit
        view.currentProgress = atEnd ? 1 : 0
        view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: view.bounds.size).image { ctx in view.layer.render(in: ctx.cgContext) }
        guard Self.hasContent(image) else { return nil }          // пустой снимок не запоминаем — тогда покажется обычная Lottie
        images[key] = image
        let url = Self.file(emoji, atEnd: atEnd)
        Task.detached(priority: .utility) { try? image.pngData()?.write(to: url, options: .atomic) }
        return image
    }

    private static func hasContent(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let n = 16
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        return stride(from: 3, to: px.count, by: 4).contains { px[$0] > 8 }
    }
}
#endif

/// Свои анимированные эмодзи (Lottie JSON). Чужие скачанные анимации убраны: пока своих нет, везде показывается обычный эмодзи.
/// Когда появятся свои — кладём файлы `<код>.json` в папку CustomEmoji внутри приложения (код — юникод эмодзи, как «1f525»),
/// и они начнут играть сами, без правок экранов.
/// Сейчас есть: 👍 (1f44d.json), ❤️ (2764_fe0f.json), 🔥 (1f525.json), 🖕 (1f595.json), 🤣 (1f923.json), 🤡 (1f921.json), 🍾 (1f37e.json), 🏆 (1f3c6.json), 🚀 (1f680.json), 🌹 (1f339.json), 💐 (1f490.json), 💩 (1f4a9.json), 🧑‍💻 (1f9d1_200d_1f4bb.json). Файл должен входить в Copy Bundle Resources цели Focus/Orbita.
actor LottieEmojiStore {
    static let shared = LottieEmojiStore()

    private var memory: [String: Data] = [:]
    private var missing: Set<String> = []

    init() {
        // чистим то, что раньше скачалось из сети
        let old = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("lottie-emoji", isDirectory: true)
        try? FileManager.default.removeItem(at: old)
    }

    /// 🔥 → "1f525", ❤️ → "2764_fe0f"
    static func code(_ emoji: String, keepVariation: Bool = true) -> String {
        emoji.unicodeScalars
            .filter { keepVariation || $0.value != 0xFE0F }
            .map { String($0.value, radix: 16) }
            .joined(separator: "_")
    }

    private var inflight: [String: Task<Data?, Never>] = [:]

    #if canImport(Lottie)
    /// Готовая анимация: разбор JSON — один раз и вне главного потока, дальше из памяти
    func animation(for emoji: String) async -> LottieAnimation? {
        if let hit = LottieSyncCache.shared.get(emoji) { return hit }
        guard let data = await data(for: emoji), let parsed = try? LottieAnimation.from(data: data) else { return nil }
        LottieSyncCache.shared.set(emoji, parsed)
        return parsed
    }

    /// При запуске приложения разбираем все свои анимации заранее: в чате и панели они появляются мгновенно
    func preloadAll() async {
        // порядок как в списке: сначала самые частые (❤️ 👍 🔥 🤣 — реакции), редкие потом; между файлами уступаем очередь, чтобы не мешать запуску
        await LottieSnapshots.shared.loadFromDisk()
        for emoji in AnimatedEmoji.all {
            // картинка покоя уже есть с прошлого запуска — JSON даже не разбираем, он понадобится только при нажатии
            if await MainActor.run(body: { LottieSnapshots.shared.cached(emoji, atEnd: true) != nil }) { continue }
            if let anim = await animation(for: emoji) {
                await MainActor.run { _ = LottieSnapshots.shared.prepare(emoji, anim) }      // картинка покоя — заранее
            }
            await Task.yield()
        }
    }
    #endif

    /// Одно и то же эмодзи в панели и в чате скачивается один раз, даже если его просят одновременно
    func data(for emoji: String) async -> Data? {
        if let task = inflight[emoji] { return await task.value }
        let task = Task { await self.load(emoji) }
        inflight[emoji] = task
        let result = await task.value
        inflight[emoji] = nil
        return result
    }

    /// Файлы анимаций лежат сжатыми (gzip, как .tgs в Telegram): в приложении они в ~8 раз меньше и читаются с диска быстрее.
    /// Обычный несжатый JSON тоже принимается — так можно класть и новые файлы без упаковки
    private static func inflate(_ raw: Data) -> Data? {
        guard raw.count > 18, raw[raw.startIndex] == 0x1f, raw[raw.startIndex + 1] == 0x8b else { return raw }
        guard raw[raw.startIndex + 3] == 0 else { return nil }                      // без имени и доп. полей — как их пакует скрипт
        let body = raw.dropFirst(10).dropLast(8)
        return try? (Data(body) as NSData).decompressed(using: .zlib) as Data
    }

    private func load(_ emoji: String) async -> Data? {
        // 👍🏽 (с оттенком кожи) → 👍: оттенки 1f3fb…1f3ff отбрасываем
        let plain = String(String.UnicodeScalarView(emoji.unicodeScalars.filter { !(0x1F3FB...0x1F3FF).contains($0.value) }))
        for variant in [emoji, plain] {
            for keep in [true, false] {
                let code = Self.code(variant, keepVariation: keep)
                if let d = memory[code] { return d }
                if missing.contains(code) { continue }
                // в Xcode-группе файл лежит в корне пакета, в папке-ссылке CustomEmoji — внутри неё
                let url = Bundle.main.url(forResource: code, withExtension: "json", subdirectory: "CustomEmoji")
                    ?? Bundle.main.url(forResource: code, withExtension: "json")
                if let url, let raw = try? Data(contentsOf: url), let d = Self.inflate(raw) {
                    memory[code] = d
                    return d
                }
                missing.insert(code)
            }
        }
        return nil
    }
}

struct LottieEmojiView: View {
    let emoji: String
    var size: CGFloat = 28
    var loop = false
    /// false — замереть на последнем кадре
    var playing = true
    /// Сколько раз проиграть до конца и замереть на последнем кадре; для крупного эффекта
    var onFinish: (() -> Void)? = nil

    #if canImport(Lottie)
    @State private var animation: LottieAnimation?
    private var shown: LottieAnimation? { animation ?? LottieSyncCache.shared.get(emoji) }
    #endif
    @State private var loaded = false
    @State private var visible = false              // играет только то, что сейчас на экране
    @State private var granted = true               // и не больше нескольких анимаций одновременно
    @State private var gateID = UUID()
    @State private var startDate = Date()
    @State private var finished = false
    @State private var snapTick = 0
    @Environment(\.scenePhase) private var scenePhase
    /// Кадры меняются 30 раз в секунду вместо 60: для эмодзи разницы не видно, а нагрузка вдвое меньше
    private static let frameInterval = 1.0 / 30
    private var isLoaded: Bool {
        #if canImport(Lottie)
        return shown != nil
        #else
        return false
        #endif
    }

    var body: some View {
        let run = playing && visible && granted && scenePhase == .active
        ZStack {
            #if canImport(Lottie)
            if run && !finished, let animation = shown {
                let duration = max(0.1, animation.duration)
                TimelineView(.animation(minimumInterval: Self.frameInterval)) { ctx in
                    let p = ctx.date.timeIntervalSince(startDate) / duration
                    LottieView(animation: animation)
                        .currentProgress(loop ? p.truncatingRemainder(dividingBy: 1) : min(1, max(0, p)))
                        .resizable()
                }
            } else if let image = LottieSnapshots.shared.cached(emoji, atEnd: !loop) {
                Image(uiImage: image).resizable().scaledToFit()          // в покое — обычная картинка, без Lottie
            } else if let animation = shown {
                LottieView(animation: animation)
                    .currentProgress(loop ? 0 : 1)
                    .resizable()
            } else {
                Text(emoji).font(.system(size: size * 0.78))
            }
            #else
            Text(emoji).font(.system(size: size * 0.78))
            #endif
        }
        .frame(width: size, height: size)
        .onAppear { visible = true; granted = playing ? PlaybackGate.shared.request(gateID) : true }
        .onDisappear { visible = false; PlaybackGate.shared.release(gateID) }
        .onChange(of: run) { _, now in if now { startDate = Date(); finished = false } }
        .task(id: "\(run)-\(isLoaded)") {
            // один круг: по окончании замираем на последнем кадре и сообщаем наверх
            #if canImport(Lottie)
            guard run, !loop, let animation = shown else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, animation.duration) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            finished = true
            PlaybackGate.shared.release(gateID)
            onFinish?()
            #endif
        }
        .task(id: "\(emoji)-\(run)") {
            #if canImport(Lottie)
            // неподвижному эмодзи с готовой картинкой анимация не нужна — грузим её только когда надо играть
            let hasSnap = LottieSnapshots.shared.cached(emoji, atEnd: !loop) != nil
            guard run || !hasSnap else { loaded = true; return }
            animation = await LottieEmojiStore.shared.animation(for: emoji)
            if let anim = animation, !hasSnap {
                LottieSnapshots.shared.prepare(emoji, anim, atEnd: !loop)
                snapTick += 1
            }
            if run { startDate = Date() }
            #endif
            loaded = true
        }
    }
}

/// Не даёт играть слишком многим анимациям сразу: остальные стоят на последнем кадре (ровно столько, сколько выдерживает экран без лагов)
final class PlaybackGate {
    static let shared = PlaybackGate()
    private let limit = 12
    private var active = Set<UUID>()
    private let lock = NSLock()

    func request(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if active.contains(id) { return true }
        guard active.count < limit else { return false }
        active.insert(id)
        return true
    }

    func release(_ id: UUID) { lock.lock(); active.remove(id); lock.unlock() }
}

/// Эмодзи в сообщении: один круг анимации и стоп; нажатие проигрывает ещё раз
struct TimedLottieEmoji: View {
    let emoji: String
    var size: CGFloat = 64

    @State private var token = 0
    @State private var playing = false              // при входе в переписку не играет — только по нажатию

    var body: some View {
        LottieEmojiView(emoji: emoji, size: size, playing: playing, onFinish: { playing = false })
            .id(token)
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.impact(.light)
                token += 1
                playing = true
            }
    }
}

/// Анимированные эмодзи: только они доступны для отправки и в реакциях
enum AnimatedEmoji {
    static let all = ["\u{2764}\u{FE0F}", "\u{1F44D}", "\u{1F525}", "\u{1F923}", "\u{1F4A9}", "\u{1F921}", "\u{1F37E}",
                      "\u{1F3C6}", "\u{1F680}", "\u{1F339}", "\u{1F490}", "\u{1F595}", "\u{1F9D1}\u{200D}\u{1F4BB}"]
}
