import SwiftUI
import Combine
import AVFoundation

/// Голосовые и кружки играют в категории `.playback` — беззвучный режим (переключатель на боку) их не глушит,
/// звук пропадает только когда громкость выведена в ноль. Если человек включает голосовое/кружок при нулевой
/// громкости, он ничего не слышит и думает, что сообщение пустое — показываем подсказку «прибавьте громкость».
@MainActor
final class SoundHint: ObservableObject {
    static let shared = SoundHint()

    /// Пока не nil — сверху висит подсказка (RootView рисует её на выбранном языке)
    @Published private(set) var shown = false
    private var lastShown = Date.distantPast
    private var clearTask: Task<Void, Never>?

    private init() {}

    /// Нулевая громкость вывода: звук физически не будет слышно
    static var silenced: Bool {
        AVAudioSession.sharedInstance().outputVolume < 0.05
    }

    /// Вызывается в момент старта воспроизведения голосового/кружка. Сессия уже активна, громкость читается.
    func checkOnPlay() {
        guard Self.silenced else { return }
        // не чаще раза в 12 секунд, чтобы не мигало при перелистывании голосовых
        guard Date().timeIntervalSince(lastShown) > 12 else { return }
        lastShown = Date()
        clearTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { shown = true }
        Haptics.impact(.soft)
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { self?.shown = false }
        }
    }

    func dismiss() {
        clearTask?.cancel()
        withAnimation { shown = false }
    }
}

/// Подсказка «прибавьте громкость» — плашка сверху
struct SoundHintBanner: View {
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.slash.fill").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.t("Звук выключен", "Sound is off"))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(s.t("Прибавьте громкость, чтобы услышать", "Turn up the volume to hear it"))
                    .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(red: 0.20, green: 0.22, blue: 0.30).opacity(0.96), in: Capsule())
        .shadow(color: Color.black.opacity(0.22), radius: 10, y: 4)
        .padding(.horizontal, 24)
    }
}
