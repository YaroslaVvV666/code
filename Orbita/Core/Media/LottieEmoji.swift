import SwiftUI
#if canImport(Lottie)
import Lottie
#endif

/// Анимированные эмодзи (Lottie) — как в Telegram: огонь горит, палец показывается, сердце бьётся.
/// Анимации берутся из набора Noto Animated Emoji (Google, CC BY 4.0) при первом показе и кешируются на телефоне.
/// Без пакета Lottie или без сети показывается обычный эмодзи — приложение работает и так.
actor LottieEmojiStore {
    static let shared = LottieEmojiStore()

    private var memory: [String: Data] = [:]
    private var missing: Set<String> = []
    private let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("lottie-emoji", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// 🔥 → "1f525", ❤️ → "2764_fe0f"
    static func code(_ emoji: String, keepVariation: Bool = true) -> String {
        emoji.unicodeScalars
            .filter { keepVariation || $0.value != 0xFE0F }
            .map { String($0.value, radix: 16) }
            .joined(separator: "_")
    }

    private var inflight: [String: Task<Data?, Never>] = [:]

    /// Одно и то же эмодзи в панели и в чате скачивается один раз, даже если его просят одновременно
    func data(for emoji: String) async -> Data? {
        if let task = inflight[emoji] { return await task.value }
        let task = Task { await self.load(emoji) }
        inflight[emoji] = task
        let result = await task.value
        inflight[emoji] = nil
        return result
    }

    private func load(_ emoji: String) async -> Data? {
        for keep in [true, false] {
            let code = Self.code(emoji, keepVariation: keep)
            if let d = memory[code] { return d }
            if missing.contains(code) { continue }
            let file = dir.appendingPathComponent(code + ".json")
            if let d = try? Data(contentsOf: file) { memory[code] = d; return d }
            guard let url = URL(string: "https://fonts.gstatic.com/s/e/notoemoji/latest/\(code)/lottie.json") else { continue }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let (d, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200, d.count > 100 {
                try? d.write(to: file)
                memory[code] = d
                return d
            }
            missing.insert(code)
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
    #endif
    @State private var loaded = false

    var body: some View {
        ZStack {
            #if canImport(Lottie)
            if let animation {
                if playing {
                    LottieView(animation: animation)
                        .playing(loopMode: loop ? .loop : .playOnce)
                        .animationDidFinish { _ in onFinish?() }
                        .resizable()
                } else {
                    LottieView(animation: animation)
                        .currentProgress(1)
                        .resizable()
                }
            } else {
                Text(emoji).font(.system(size: size * 0.78))
            }
            #else
            Text(emoji).font(.system(size: size * 0.78))
            #endif
        }
        .frame(width: size, height: size)
        .task(id: emoji) {
            #if canImport(Lottie)
            if let data = await LottieEmojiStore.shared.data(for: emoji) {
                animation = try? LottieAnimation.from(data: data)
            }
            #endif
            loaded = true
        }
    }
}

/// Эмодзи в сообщении: крутится около 5 секунд и замирает; нажатие запускает ещё на 5 секунд
struct TimedLottieEmoji: View {
    let emoji: String
    var size: CGFloat = 64
    var seconds: Double = 5

    @State private var playing = true
    @State private var token = 0

    var body: some View {
        LottieEmojiView(emoji: emoji, size: size, loop: true, playing: playing)
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.impact(.light)
                token += 1
            }
            .task(id: token) {
                playing = true
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if !Task.isCancelled { playing = false }
            }
    }
}
