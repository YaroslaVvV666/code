import SwiftUI
import Combine

/// Канал перемотки шортса «из панели вкладок»: как в TikTok, можно зажать палец даже на кнопке
/// «Главная»/«Шортс» и, двигая вправо/влево, перематывать видео. Панель вкладок пишет сюда цель
/// перемотки, активная ячейка шортса её слушает и перематывает свой плеер.
final class ReelScrubBus: ObservableObject {
    static let shared = ReelScrubBus()

    /// Текущее положение активного ролика (0…1) — активная ячейка обновляет его без перерисовок,
    /// чтобы панель вкладок знала, откуда начинать перемотку.
    var currentFrac: Double = 0

    /// Если недавно была перемотка с панели — не переключаем вкладку по этому касанию (касание «ушло в перемотку»).
    var suppressTapUntil: Date = .distantPast

    @Published var target: Double? = nil      // куда перемотать (ставит панель вкладок)
    @Published var active = false             // идёт ли перемотка с панели
    @Published var tick = 0                   // одинаковая цель подряд тоже должна срабатывать

    func scrub(to frac: Double) {
        target = min(1, max(0, frac))
        active = true
        tick &+= 1
        suppressTapUntil = Date().addingTimeInterval(0.35)
    }

    func end() {
        active = false
    }
}
