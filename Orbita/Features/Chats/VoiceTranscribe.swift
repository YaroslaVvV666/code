import Foundation
import Speech
import Combine

/// Расшифровка голосовых сообщений в текст. Распознавание идёт на устройстве, если для языка есть офлайн-модель,
/// иначе средствами системы (Apple Speech). Результат хранится, пока приложение открыто.
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
        // без этого ключа в Info.plist iOS закрывает приложение при первом запросе доступа — проверяем заранее
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            return .failed(s.t("Добавьте NSSpeechRecognitionUsageDescription в Info.plist проекта",
                               "Add NSSpeechRecognitionUsageDescription to the project's Info.plist"))
        }
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else {
            return .failed(s.t("Разрешите распознавание речи в Настройках", "Allow speech recognition in Settings"))
        }
        guard let url = await FileDownloader.download(mediaID: mediaID, name: "voice.m4a") else {
            return .failed(s.t("Не удалось загрузить запись", "Couldn't load the recording"))
        }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let locale = Locale(identifier: lang == .ru ? "ru-RU" : "en-US")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            return .failed(s.t("Распознавание сейчас недоступно", "Speech recognition is unavailable"))
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        return await withCheckedContinuation { (c: CheckedContinuation<State, Never>) in
            var finished = false
            _ = recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    c.resume(returning: text.isEmpty ? .failed(s.t("Речь не распознана", "No speech recognized")) : .done(text))
                } else if error != nil {
                    finished = true
                    c.resume(returning: .failed(s.t("Не удалось расшифровать", "Couldn't transcribe")))
                }
            }
        }
    }
}
