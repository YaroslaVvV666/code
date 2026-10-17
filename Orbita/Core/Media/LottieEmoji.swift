import SwiftUI
#if canImport(Lottie)
import Lottie
#endif

/// Анимированные эмодзи (Lottie) — только наши собственные, нарисованные для Orbita.
/// Файлы лежат в приложении: DesignSystem/Emoji/emoji_<код>.json (🔥 → emoji_1f525.json).
/// Генераторы анимаций — в tools/emoji. Для эмодзи без своей анимации показывается обычный символ,
/// без пакета Lottie — тоже. Сеть не нужна.
actor LottieEmojiStore {
    static let shared = LottieEmojiStore()

    private var memory: [String: Data] = [:]
    private var missing: Set<String> = []

    init() {
        // Раньше анимации скачивались из чужого набора и кешировались — удаляем этот кеш
        let old = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lottie-emoji", isDirectory: true)
        try? FileManager.default.removeItem(at: old)
    }

    /// 🔥 → "1f525", ❤️ → "2764" (селектор варианта FE0F не учитывается)
    static func code(_ emoji: String) -> String {
        emoji.unicodeScalars
            .filter { $0.value != 0xFE0F }
            .map { String($0.value, radix: 16) }
            .joined(separator: "_")
    }

    /// Есть ли у эмодзи своя анимация в приложении
    nonisolated static func hasAnimation(_ emoji: String) -> Bool {
        Bundle.main.url(forResource: "emoji_" + code(emoji), withExtension: "json") != nil
    }

    func data(for emoji: String) async -> Data? {
        let code = Self.code(emoji)
        if let d = memory[code] { return d }
        if missing.contains(code) { return nil }
        guard let url = Bundle.main.url(forResource: "emoji_" + code, withExtension: "json"),
              let d = try? Data(contentsOf: url) else {
            missing.insert(code)
            return nil
        }
        memory[code] = d
        return d
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
