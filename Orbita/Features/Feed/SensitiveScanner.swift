import Foundation
import UIKit
#if canImport(SensitiveContentAnalysis)
import SensitiveContentAnalysis
#endif

/// Авто-распознавание «взрослого» (чувствительного) контента перед публикацией.
///
/// Использует системный анализатор Apple (SensitiveContentAnalysis, iOS 17+): проверка идёт
/// НА УСТРОЙСТВЕ, картинки/кадры никуда не отправляются. Если система распознаёт наготу —
/// пост/шортс помечается «чувствительным» сам, и зрителям он показывается под размытием
/// с подтверждением (SensitiveGate).
///
/// Важно: анализатор включается, только если у пользователя в Настройках iOS включено
/// «Конфиденциальность и безопасность → Предупреждения о чувствительном контенте».
/// Если выключено — авто-проверка молча пропускается (остаётся ручной переключатель 18+).
enum SensitiveScanner {

    /// true — хотя бы один из переданных кадров распознан как чувствительный (нагота).
    static func isSensitive(imageDatas: [Data]) async -> Bool {
        #if canImport(SensitiveContentAnalysis)
        guard #available(iOS 17.0, *) else { return false }
        let analyzer = SCSensitivityAnalyzer()
        guard analyzer.analysisPolicy != .disabled else { return false }   // системная настройка выключена
        for data in imageDatas {
            guard let cg = UIImage(data: data)?.cgImage else { continue }
            if let result = try? await analyzer.analyzeImage(cg), result.isSensitive {
                return true
            }
        }
        #endif
        return false
    }

    /// Доступна ли авто-проверка прямо сейчас (система включена). Для подсказок в интерфейсе.
    static var available: Bool {
        #if canImport(SensitiveContentAnalysis)
        if #available(iOS 17.0, *) {
            return SCSensitivityAnalyzer().analysisPolicy != .disabled
        }
        #endif
        return false
    }
}
