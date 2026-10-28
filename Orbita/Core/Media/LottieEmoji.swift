import SwiftUI
import ImageIO
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
/// Готовые кадры анимаций, как у Telegram: каждое эмодзи один раз рисуется в последовательность картинок (30 кадров/с),
/// кадры навсегда лежат на диске, а при показе просто сменяют друг друга — без Lottie, без построения векторной сцены
/// и без пересчёта на главном потоке. Так играют мелкие эмодзи (ряд реакций, реакции под сообщением, панель);
/// крупные (эмодзи-сообщение, большой эффект) по-прежнему через Lottie
final class EmojiFrames {
    static let shared = EmojiFrames()
    static let fps: Double = 30
    /// Кадры рисуются под этот размер в точках (ряд реакций); для эмодзи меньше — уменьшаются
    static let pointSize: CGFloat = 34
    /// Эмодзи больше этого размера играют через Lottie: кадры под них были бы размытыми
    static let maxSize: CGFloat = 48
    /// Разжатие кадров — в фоне, на главный поток попадает готовая картинка
    static let decodeQueue = DispatchQueue(label: "orbita.emoji-frames", qos: .userInitiated, attributes: .concurrent)

    /// Кадры одного эмодзи: файл с диска отображён в память (mmap) и не занимает её «по-настоящему»;
    /// кадр — сжатый PNG, разжимается по одному перед показом
    final class Clip {
        let blob: Data
        let ranges: [Range<Int>]
        var count: Int { ranges.count }
        var duration: Double { Double(ranges.count) / EmojiFrames.fps }
        init(blob: Data, ranges: [Range<Int>]) { self.blob = blob; self.ranges = ranges }

        func image(at index: Int) -> CGImage? {
            guard !ranges.isEmpty else { return nil }
            return EmojiFrames.decode(Data(blob[ranges[min(max(index, 0), ranges.count - 1)]]))
        }
    }

    private let lock = NSLock()
    private var clips: [String: Clip] = [:]

    func clip(_ emoji: String) -> Clip? { lock.lock(); defer { lock.unlock() }; return clips[emoji] }
    private func set(_ emoji: String, _ clip: Clip) { lock.lock(); clips[emoji] = clip; lock.unlock() }

    /// Application Support, а не Caches: кэш система может вычистить, а кадры должны лежать «навсегда».
    /// В резервную копию iCloud не попадают — их всегда можно нарисовать заново
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var d = base.appendingPathComponent("emoji-frames-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? d.setResourceValues(values)
        return d
    }()

    /// В имени файла — отпечаток самой анимации и размер в пикселях: поменяли JSON или экран другой — кадры рисуются заново
    private static func file(_ emoji: String, source: Data, pixels: Int) -> URL {
        var h: UInt64 = 0xcbf29ce484222325                    // FNV-1a
        for b in source { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return dir.appendingPathComponent(LottieEmojiStore.code(emoji) + "_\(pixels)_" + String(h, radix: 16) + ".frames")
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    // Формат файла: "EMF1", число кадров (UInt32), длины кадров (UInt32 каждая), затем сами PNG подряд
    private static let magic = Data("EMF1".utf8)

    private static func pack(_ frames: [Data]) -> Data {
        var out = magic
        func put(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        put(UInt32(frames.count))
        for f in frames { put(UInt32(f.count)) }
        for f in frames { out.append(f) }
        return out
    }

    private static func unpack(_ blob: Data) -> Clip? {
        guard blob.count > 8, blob.prefix(4) == magic else { return nil }
        func get(_ offset: Int) -> Int {
            Int(UInt32(littleEndian: blob.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }))
        }
        let count = get(4)
        guard count > 0, blob.count >= 8 + count * 4 else { return nil }
        var ranges: [Range<Int>] = []
        var offset = 8 + count * 4
        for i in 0..<count {
            let len = get(8 + i * 4)
            guard len > 0, offset + len <= blob.count else { return nil }
            ranges.append(offset..<(offset + len))
            offset += len
        }
        return Clip(blob: blob, ranges: ranges)
    }

    /// Подхватить нарисованные раньше кадры с диска (вне главного потока)
    func load(_ emoji: String, source: Data, pixels: Int) -> Bool {
        if clip(emoji) != nil { return true }
        let url = Self.file(emoji, source: source, pixels: pixels)
        guard let blob = try? Data(contentsOf: url, options: .alwaysMapped), let clip = Self.unpack(blob) else { return false }
        set(emoji, clip)
        return true
    }

    /// Нарисовать кадры один раз (первый запуск или новая анимация). LottieAnimationView живёт только на главном потоке,
    /// поэтому рисуем по кадру и отпускаем главный поток между кадрами — интерфейс в это время не подтормаживает
    @MainActor
    func render(_ emoji: String, _ animation: LottieAnimation, source: Data, pixels: Int) async {
        guard clip(emoji) == nil else { return }
        let side = CGFloat(pixels)
        let view = LottieAnimationView(animation: animation, configuration: LottieConfiguration(renderingEngine: .mainThread))
        view.frame = CGRect(x: 0, y: 0, width: side, height: side)
        view.contentMode = .scaleAspectFit
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let count = max(1, Int((animation.duration * Self.fps).rounded()))
        var frames: [Data] = []
        frames.reserveCapacity(count)
        for i in 0..<count {
            view.currentProgress = count == 1 ? 1 : CGFloat(i) / CGFloat(count - 1)
            view.forceDisplayUpdate()
            view.layoutIfNeeded()
            let image = renderer.image { ctx in view.layer.render(in: ctx.cgContext) }
            guard let png = image.pngData() else { return }
            frames.append(png)
            try? await Task.sleep(nanoseconds: 6_000_000)
        }
        // пустые кадры (Lottie не нарисовал сцену вне окна) не запоминаем — тогда эмодзи продолжит играть через Lottie
        guard let middle = Self.decode(frames[frames.count / 2]), Self.hasContent(middle) else { return }
        let blob = Self.pack(frames)
        guard let clip = Self.unpack(blob) else { return }
        set(emoji, clip)
        let url = Self.file(emoji, source: source, pixels: pixels)
        Task.detached(priority: .utility) { try? blob.write(to: url, options: .atomic) }
    }

    private static func hasContent(_ cg: CGImage) -> Bool {
        let n = 16
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        return stride(from: 3, to: px.count, by: 4).contains { px[$0] > 8 }
    }

    /// Старые версии папки с кадрами (после смены формата) и устаревшие файлы одного эмодзи
    static func prune(keep: Set<URL>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let keepNames = Set(keep.map(\.lastPathComponent))
        for f in files where !keepNames.contains(f.lastPathComponent) { try? FileManager.default.removeItem(at: f) }
    }

    static func url(_ emoji: String, source: Data, pixels: Int) -> URL { file(emoji, source: source, pixels: pixels) }
}

/// Проигрыватель готовых кадров: CADisplayLink на 30 кадров/с меняет картинку слоя, следующий кадр разжимается в фоне.
/// SwiftUI при этом ничего не пересчитывает
final class EmojiFramePlayerView: UIView {
    private var clip: EmojiFrames.Clip?
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var shown = -1
    private var decoding = false
    private var loop = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { link?.invalidate() }

    func play(_ clip: EmojiFrames.Clip, loop: Bool = false) {
        stop()
        self.clip = clip
        self.loop = loop
        layer.contents = clip.image(at: 0)                 // первый кадр — сразу, совпадает с картинкой покоя
        shown = 0
        start = CACurrentMediaTime()
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: Float(EmojiFrames.fps), preferred: Float(EmojiFrames.fps))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// Вью переиспользуется с другими кадрами (сменилось эмодзи) — сразу играем новые, а не старые
    func update(_ clip: EmojiFrames.Clip, loop: Bool) {
        guard clip !== self.clip || loop != self.loop else { return }
        play(clip, loop: loop)
    }

    fileprivate func tick() {
        guard let clip else { stop(); return }
        let raw = Int((CACurrentMediaTime() - start) * EmojiFrames.fps)
        let index = loop ? raw % max(clip.count, 1) : raw              // по кругу — снова с первого кадра
        if !loop && index >= clip.count - 1 {
            // последний кадр и стоп
            if shown != clip.count - 1 { layer.contents = clip.image(at: clip.count - 1); shown = clip.count - 1 }
            stop()
            return
        }
        guard index != shown, !decoding else { return }
        decoding = true
        EmojiFrames.decodeQueue.async { [weak self] in
            let image = clip.image(at: index)
            DispatchQueue.main.async {
                guard let self else { return }
                self.decoding = false
                guard self.link != nil, let image else { return }
                self.layer.contents = image
                self.shown = index
            }
        }
    }
}

/// CADisplayLink держит цель сильной ссылкой — через прокси вью освобождается как обычно
private final class DisplayLinkProxy: NSObject {
    weak var owner: EmojiFramePlayerView?
    init(_ owner: EmojiFramePlayerView) { self.owner = owner }
    @objc func tick() { owner?.tick() }
}

private struct EmojiFramePlayer: UIViewRepresentable {
    let clip: EmojiFrames.Clip
    var loop = false

    func makeUIView(context: Context) -> EmojiFramePlayerView {
        let view = EmojiFramePlayerView(frame: .zero)
        view.play(clip, loop: loop)
        return view
    }

    func updateUIView(_ uiView: EmojiFramePlayerView, context: Context) { uiView.update(clip, loop: loop) }

    static func dismantleUIView(_ uiView: EmojiFramePlayerView, coordinator: ()) { uiView.stop() }
}
#endif

/// Свои анимированные эмодзи (Lottie JSON). Чужие скачанные анимации убраны: пока своих нет, везде показывается обычный эмодзи.
/// Когда появятся свои — кладём файлы `<код>.json` в папку CustomEmoji внутри приложения (код — юникод эмодзи, как «1f525»),
/// и они начнут играть сами, без правок экранов.
/// Сейчас есть: 👍 (1f44d.json), ❤️ (2764_fe0f.json), 🔥 (1f525.json), 🖕 (1f595.json), 🤣 (1f923.json), 🤡 (1f921.json), 🍾 (1f37e.json), 🏆 (1f3c6.json), 🚀 (1f680.json), 🌹 (1f339.json), 💐 (1f490.json), 💩 (1f4a9.json), 🧑‍💻 (1f9d1_200d_1f4bb.json), 😔 (1f614.json), 😀 (1f600.json), 😃 (1f603.json), 😄 (1f604.json), 😁 (1f601.json), 😆 (1f606.json), 🥹 (1f979.json), 😅 (1f605.json), 😂 (1f602.json), 🥲 (1f972.json), ☺️ (263a_fe0f.json), 😇 (1f607.json), 😊 (1f60a.json), 😉 (1f609.json), 🙂 (1f642.json), 🙃 (1f643.json), 😍 (1f60d.json), 😌 (1f60c.json), 😘 (1f618.json), 🥰 (1f970.json), 😙 (1f619.json), 😗 (1f617.json), 😚 (1f61a.json), 😋 (1f60b.json), 😛 (1f61b.json), 😝 (1f61d.json), 😜 (1f61c.json), 🤪 (1f92a.json), 👄 (1f444.json), 👅 (1f445.json), 👀 (1f440.json), 🤰 (1f930.json), 🤦‍♀️ (1f926_200d_2640_fe0f.json), 🤷‍♀️ (1f937_200d_2640_fe0f.json), 🤦 (1f926.json), 🤦‍♂️ (1f926_200d_2642_fe0f.json), 🤷 (1f937.json), 🤷‍♂️ (1f937_200d_2642_fe0f.json), 🎩 (1f3a9.json), 👑 (1f451.json), 🏠 (1f3e0.json), 🍀 (1f340.json), 🌈 (1f308.json), ☘️ (2618_fe0f.json), 🏖️ (1f3d6.json), 🏝️ (1f3dd.json), 📝 (1f4dd.json), ✂️ (2702_fe0f.json), ❤️‍🩹 (2764_fe0f_200d_1fa79.json), 🌲 (1f332.json), 🎄 (1f384.json). Файл должен входить в Copy Bundle Resources цели Focus/Orbita.
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

    /// При запуске приложения всё готовится заранее и дальше лежит в памяти и на диске:
    /// 1) картинки покоя и готовые кадры подхватываются с диска; 2) все анимации разбираются (вне главного потока);
    /// 3) чего нет на диске (первый запуск, новая анимация) — рисуется один раз и сохраняется навсегда.
    /// Порядок как в списке: сначала самые частые (❤️ 👍 🔥 🤣 — реакции), редкие потом
    func preloadAll() async {
        await LottieSnapshots.shared.loadFromDisk()
        let pixels = await MainActor.run { Int((EmojiFrames.pointSize * UIScreen.main.scale).rounded(.up)) }
        var keep: Set<URL> = []
        var toRender: [(emoji: String, source: Data)] = []
        for emoji in AnimatedEmoji.all {
            guard let source = await data(for: emoji) else { continue }
            keep.insert(EmojiFrames.url(emoji, source: source, pixels: pixels))
            if !EmojiFrames.shared.load(emoji, source: source, pixels: pixels) { toRender.append((emoji: emoji, source: source)) }
            if let anim = await animation(for: emoji) {
                await MainActor.run {
                    _ = LottieSnapshots.shared.prepare(emoji, anim, atEnd: true)       // уже есть — вернётся сразу
                    _ = LottieSnapshots.shared.prepare(emoji, anim, atEnd: false)
                }
            }
            await Task.yield()
        }
        EmojiFrames.prune(keep: keep)                           // кадры старых версий анимаций
        for item in toRender {
            guard let anim = await animation(for: item.emoji) else { continue }
            await EmojiFrames.shared.render(item.emoji, anim, source: item.source, pixels: pixels)
        }
    }

    /// Разобрать анимации в память заранее (вне главного потока): ряд реакций в меню сообщения начинает играть сразу,
    /// а не после разбора 13 JSON по 300–500 КБ в момент открытия меню
    func warm(_ emojis: [String]) async {
        for emoji in emojis where LottieSyncCache.shared.get(emoji) == nil {
            _ = await animation(for: emoji)
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
    /// В покое (до запуска) показывать первый кадр, а не последний: ряд реакций сначала стоит статично,
    /// а потом плавно, без скачка картинки, начинает играть с того же кадра
    var idleAtStart = false
    /// Сколько раз проиграть до конца и замереть на последнем кадре; для крупного эффекта
    var onFinish: (() -> Void)? = nil

    #if canImport(Lottie)
    @State private var animation: LottieAnimation?
    private var shown: LottieAnimation? { animation ?? LottieSyncCache.shared.get(emoji) }
    /// Готовые кадры с диска — для мелких эмодзи (один круг или по кругу, как эмодзи-статус)
    private var frameClip: EmojiFrames.Clip? {
        size > EmojiFrames.maxSize ? nil : EmojiFrames.shared.clip(emoji)
    }
    #endif
    @State private var loaded = false
    @State private var visible = false              // играет только то, что сейчас на экране
    @State private var granted = false              // и не больше нескольких анимаций одновременно
    @State private var gateID = UUID()
    @State private var startDate = Date()
    @State private var finished = false
    @State private var snapTick = 0
    @Environment(\.scenePhase) private var scenePhase
    /// Кадры меняются 30 раз в секунду вместо 60: для эмодзи разницы не видно, а нагрузка вдвое меньше
    private static let frameInterval = 1.0 / 30
    private var isLoaded: Bool {
        #if canImport(Lottie)
        return shown != nil || frameClip != nil
        #else
        return false
        #endif
    }

    /// Хочет играть прямо сейчас (если пустит PlaybackGate)
    private var wants: Bool { playing && visible && scenePhase == .active }
    /// Кадр покоя: до первого запуска — первый (если просили), после проигрывания — последний
    private var restAtEnd: Bool { loop ? false : (finished || !idleAtStart) }

    /// Место в PlaybackGate берём в момент старта, а не при появлении: эмодзи, которое появилось неподвижным
    /// и запускается позже (playing false → true), тоже честно получает слот
    private func updateGate() {
        if wants && !finished {
            granted = PlaybackGate.shared.request(gateID)
        } else {
            PlaybackGate.shared.release(gateID)
        }
    }

    var body: some View {
        let run = wants && granted
        ZStack {
            #if canImport(Lottie)
            if run && !finished, let clip = frameClip {
                EmojiFramePlayer(clip: clip, loop: loop)                 // готовые кадры, без Lottie
            } else if run && !finished, let animation = shown {
                let duration = max(0.1, animation.duration)
                TimelineView(.animation(minimumInterval: Self.frameInterval)) { ctx in
                    let p = ctx.date.timeIntervalSince(startDate) / duration
                    LottieView(animation: animation)
                        .currentProgress(loop ? p.truncatingRemainder(dividingBy: 1) : min(1, max(0, p)))
                        .resizable()
                }
            } else if let image = LottieSnapshots.shared.cached(emoji, atEnd: restAtEnd) {
                Image(uiImage: image).resizable().scaledToFit()          // в покое — обычная картинка, без Lottie
            } else if let animation = shown {
                LottieView(animation: animation)
                    .currentProgress(restAtEnd ? 1 : 0)
                    .resizable()
            } else {
                Text(emoji).font(.system(size: size * 0.78))
            }
            #else
            Text(emoji).font(.system(size: size * 0.78))
            #endif
        }
        .frame(width: size, height: size)
        .onAppear { visible = true; updateGate() }
        .onDisappear { visible = false; updateGate() }
        .onChange(of: playing) { _, now in
            // снова запустили после остановки — играем заново с первого кадра, без пересоздания вью через .id
            if now { finished = false }
            updateGate()
        }
        .onChange(of: scenePhase) { _, _ in updateGate() }
        .onChange(of: run) { _, now in if now { startDate = Date() } }
        .task(id: "\(run)-\(isLoaded)") {
            // один круг: по окончании замираем на последнем кадре и сообщаем наверх
            #if canImport(Lottie)
            guard run, !loop else { return }
            let duration: Double
            if let clip = frameClip { duration = clip.duration }
            else if let animation = shown { duration = max(0.1, animation.duration) }
            else { return }
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            finished = true
            PlaybackGate.shared.release(gateID)
            onFinish?()
            #endif
        }
        .task(id: "\(emoji)-\(run)") {
            #if canImport(Lottie)
            // неподвижному эмодзи с готовой картинкой анимация не нужна — грузим её только когда надо играть
            let rest = restAtEnd
            let hasSnap = LottieSnapshots.shared.cached(emoji, atEnd: rest) != nil
            guard run || !hasSnap else { loaded = true; return }
            if frameClip != nil && hasSnap { loaded = true; return }        // играет готовыми кадрами — Lottie не нужен
            let ready = shown != nil                         // уже в памяти (прогрето заранее) — играет с момента старта
            animation = await LottieEmojiStore.shared.animation(for: emoji)
            if let anim = animation, !hasSnap {
                LottieSnapshots.shared.prepare(emoji, anim, atEnd: rest)
                snapTick += 1
            }
            if run && !ready { startDate = Date() }
            #endif
            loaded = true
        }
    }
}

/// Не даёт играть слишком многим анимациям сразу: остальные стоят на последнем кадре (ровно столько, сколько выдерживает экран без лагов).
/// Ряд реакций — до ~10 видимых эмодзи плюс несколько в чате; слот освобождается сразу по окончании круга
final class PlaybackGate {
    static let shared = PlaybackGate()
    private let limit = 16
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
    /// Только что отправленное или пришедшее сообщение: один круг анимации сам. nil — старое, играет только по нажатию
    var playOnceKey: String? = nil

    @State private var token = 0
    @State private var playing = false              // при входе в переписку не играет — только по нажатию
    /// Уже сыгравшие сами: после подтверждения отправки (и в копии сообщения в меню) повторно не играют
    private static var played = Set<String>()

    var body: some View {
        LottieEmojiView(emoji: emoji, size: size, playing: playing, onFinish: { playing = false })
            .id(token)
            .onAppear {
                guard let key = playOnceKey, !Self.played.contains(key) else { return }
                Self.played.insert(key)
                playing = true
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // зажали сообщение ради реакций — отпускание пальца не должно ни вибрировать, ни запускать анимацию
                guard !MessageMenu.isOpen else { return }
                Haptics.impact(.light)
                token += 1
                playing = true
            }
    }
}

/// Неподвижное крупное эмодзи — последний кадр анимации готовой картинкой (или обычный символ, пока картинки нет).
/// Без Lottie: для копий сообщения, где анимация не играет
struct StillEmoji: View {
    let emoji: String
    var size: CGFloat = 64

    var body: some View {
        Group {
            #if canImport(Lottie)
            if let image = LottieSnapshots.shared.cached(emoji, atEnd: true) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Text(emoji).font(.system(size: size * 0.78))
            }
            #else
            Text(emoji).font(.system(size: size * 0.78))
            #endif
        }
        .frame(width: size, height: size)
    }
}

/// Анимированные эмодзи: только они доступны для отправки и в реакциях
enum AnimatedEmoji {
    static let all = ["\u{2764}\u{FE0F}", "\u{1F44D}", "\u{1F525}", "\u{1F923}", "\u{1F4A9}", "\u{1F921}", "\u{1F37E}",
                      "\u{1F3C6}", "\u{1F680}", "\u{1F339}", "\u{1F490}", "\u{1F595}", "\u{1F9D1}\u{200D}\u{1F4BB}",
                      "\u{1F614}", "\u{1F600}", "\u{1F603}", "\u{1F604}", "\u{1F601}", "\u{1F606}",
                      "\u{1F979}", "\u{1F605}", "\u{1F602}", "\u{1F972}",
                      "\u{263A}\u{FE0F}", "\u{1F607}", "\u{1F60A}", "\u{1F609}",
                      "\u{1F642}", "\u{1F643}", "\u{1F60D}", "\u{1F60C}",
                      "\u{1F618}", "\u{1F970}", "\u{1F619}", "\u{1F617}",
                      "\u{1F61A}", "\u{1F60B}", "\u{1F61B}", "\u{1F61D}",
                      "\u{1F61C}", "\u{1F92A}", "\u{1F444}", "\u{1F445}",
                      "\u{1F440}", "\u{1F930}", "\u{1F926}\u{200D}\u{2640}\u{FE0F}",
                      "\u{1F937}\u{200D}\u{2640}\u{FE0F}", "\u{1F926}",
                      "\u{1F926}\u{200D}\u{2642}\u{FE0F}", "\u{1F937}",
                      "\u{1F937}\u{200D}\u{2642}\u{FE0F}", "\u{1F3A9}", "\u{1F451}",
                      "\u{1F3E0}", "\u{1F340}", "\u{1F308}", "\u{2618}\u{FE0F}",
                      "\u{1F3D6}\u{FE0F}", "\u{1F3DD}\u{FE0F}", "\u{1F4DD}",
                      "\u{2702}\u{FE0F}", "\u{2764}\u{FE0F}\u{200D}\u{1FA79}", "\u{1F332}", "\u{1F384}"]
}
