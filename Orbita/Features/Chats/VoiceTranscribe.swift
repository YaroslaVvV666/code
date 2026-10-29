import Foundation
import Speech
import SoundAnalysis
import Combine
#if canImport(WhisperKit)
import WhisperKit
#endif

/// Расшифровка голосовых в текст — максимально качественно и на устройстве (приватно):
///  • если в проект добавлен пакет WhisperKit — текст распознаёт Whisper (сильно точнее Apple Speech,
///    особенно по-русски и в шуме); модель скачивается один раз и дальше работает офлайн.
///  • иначе — запасной движок Apple Speech (встроенный, без зависимостей).
/// Плюс отдельным проходом Apple Sound Analysis помечает музыку/аплодисменты/смех и т.п.
/// Результат хранится, пока приложение открыто.
@MainActor
final class VoiceTranscriber: ObservableObject {
    static let shared = VoiceTranscriber()

    enum State: Equatable {
        case working
        case done(String)
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:]

    func state(_ id: String) -> State? { states[id] }

    /// Нажатие на кнопку: запустить расшифровку или скрыть уже готовую
    func toggle(mediaID: String, lang: AppLanguage) {
        switch states[mediaID] {
        case .working: return
        case .done: states[mediaID] = nil
        default:
            states[mediaID] = .working
            Task {
                let result = await Self.run(mediaID: mediaID, lang: lang)
                states[mediaID] = result
            }
        }
    }

    private static func run(mediaID: String, lang: AppLanguage) async -> State {
        let s = Strings(lang: lang)
        guard let url = await FileDownloader.download(mediaID: mediaID, name: "voice.m4a") else {
            return .failed(s.t("Не удалось загрузить запись", "Couldn't load the recording"))
        }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // 1) Звуковые метки (музыка/аплодисменты/смех…) — независимо от распознавания речи.
        let tags = await SoundTagger.tags(url: url, lang: lang)

        // 2) Текст: Whisper, если доступен; иначе Apple Speech.
        let text = await transcribeText(url: url, lang: lang, s: s)

        switch text {
        case .success(let body):
            let prefix = tags.isEmpty ? "" : tags.joined(separator: " · ") + "\n"
            return .done(prefix + body)
        case .failure(let message):
            // речи нет, но что-то звучало (музыка/аплодисменты) — покажем хотя бы это
            if !tags.isEmpty { return .done(tags.joined(separator: " · ")) }
            return .failed(message)
        }
    }

    /// Возвращает распознанный текст либо сообщение об ошибке
    private static func transcribeText(url: URL, lang: AppLanguage, s: Strings) async -> Result<String, String> {
        #if canImport(WhisperKit)
        if let whisperText = await whisper(url: url, lang: lang) {
            return .success(whisperText)
        }
        #endif
        return await appleSpeech(url: url, lang: lang, s: s)
    }

    // MARK: - Whisper (на устройстве, подключается пакетом WhisperKit)

    #if canImport(WhisperKit)
    private static var whisperKit: WhisperKit?

    /// Модель: "base" — компактная (~150 МБ) и уже заметно точнее Apple Speech.
    /// Для максимального качества можно поставить "small" или "medium" (крупнее, точнее).
    private static let whisperModel = "base"

    private static func whisper(url: URL, lang: AppLanguage) async -> String? {
        do {
            if whisperKit == nil {
                whisperKit = try await WhisperKit(model: whisperModel)
            }
            guard let wk = whisperKit else { return nil }
            let options = DecodingOptions(language: lang == .ru ? "ru" : "en")
            let results = try await wk.transcribe(audioPath: url.path, decodeOptions: options)
            let text = results.map { $0.text }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil            // не вышло — тихо откатываемся на Apple Speech
        }
    }
    #endif

    // MARK: - Apple Speech (запасной движок)

    private static func appleSpeech(url: URL, lang: AppLanguage, s: Strings) async -> Result<String, String> {
        // без этого ключа в Info.plist iOS закрывает приложение при первом запросе доступа — проверяем заранее
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            return .failure(s.t("Добавьте NSSpeechRecognitionUsageDescription в Info.plist проекта",
                                "Add NSSpeechRecognitionUsageDescription to the project's Info.plist"))
        }
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else {
            return .failure(s.t("Разрешите распознавание речи в Настройках", "Allow speech recognition in Settings"))
        }
        let locale = Locale(identifier: lang == .ru ? "ru-RU" : "en-US")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            return .failure(s.t("Распознавание сейчас недоступно", "Speech recognition is unavailable"))
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        return await withCheckedContinuation { (c: CheckedContinuation<Result<String, String>, Never>) in
            var finished = false
            _ = recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    c.resume(returning: text.isEmpty
                             ? .failure(s.t("Речь не распознана", "No speech recognized"))
                             : .success(text))
                } else if error != nil {
                    finished = true
                    c.resume(returning: .failure(s.t("Не удалось расшифровать", "Couldn't transcribe")))
                }
            }
        }
    }
}

// MARK: - Метки звуков (музыка, аплодисменты, смех…)

/// Классификатор звуков Apple (на устройстве, бесплатно). Прогоняет запись и возвращает метки
/// неречевых звуков — чтобы в расшифровке было видно «🎵 Музыка», «👏 Аплодисменты» и т.п.
private enum SoundTagger {
    static func tags(url: URL, lang: AppLanguage) async -> [String] {
        await withCheckedContinuation { (c: CheckedContinuation<[String], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(returning: analyze(url: url, lang: lang))
            }
        }
    }

    private static func analyze(url: URL, lang: AppLanguage) -> [String] {
        guard let analyzer = try? SNAudioFileAnalyzer(url: url),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return [] }
        let collector = Collector()
        guard (try? analyzer.add(request, withObserver: collector)) != nil else { return [] }
        analyzer.analyze()                      // синхронно: к возврату у collector уже все результаты
        return collector.labels(lang: lang)
    }

    /// Идентификатор классификатора Apple → эмодзи-метка. Берём только явные неречевые звуки.
    private static let known: [(id: String, ru: String, en: String)] = [
        ("music", "🎵 Музыка", "🎵 Music"),
        ("singing", "🎤 Пение", "🎤 Singing"),
        ("applause", "👏 Аплодисменты", "👏 Applause"),
        ("laughter", "😂 Смех", "😂 Laughter"),
        ("cheering", "🎉 Ликование", "🎉 Cheering"),
        ("crowd", "👥 Шум толпы", "👥 Crowd noise"),
        ("crying_sobbing", "😢 Плач", "😢 Crying"),
        ("whistling", "😗 Свист", "😗 Whistling"),
    ]

    final class Collector: NSObject, SNResultsObserving {
        private var best: [String: Double] = [:]

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let classification = result as? SNClassificationResult else { return }
            for c in classification.classifications where c.confidence > 0.7 {
                best[c.identifier] = max(best[c.identifier] ?? 0, c.confidence)
            }
        }

        func labels(lang: AppLanguage) -> [String] {
            known.compactMap { best[$0.id] != nil ? (lang == .ru ? $0.ru : $0.en) : nil }
        }
    }
}
