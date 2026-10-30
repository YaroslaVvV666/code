import Foundation
import CallKit
import AVFoundation

/// Входящий звонок через системный CallKit: iPhone сам играет рингтон, который человек выбрал у себя в настройках,
/// и показывает привычную плашку «Ответить / Отклонить». Сам разговор по-прежнему идёт через наш экран и WebRTC.
@MainActor
final class CallRinger: NSObject, CXProviderDelegate {
    static let shared = CallRinger()

    var onAnswer: (() -> Void)?
    var onDecline: (() -> Void)?
    /// Ответили в системном экране до того, как появился обработчик звонка (холодный старт по VoIP-пушу)
    private var pendingAnswer = false
    func consumePendingAnswer() -> Bool { let p = pendingAnswer; pendingAnswer = false; return p }

    private let provider: CXProvider
    private let controller = CXCallController()
    private var current: UUID?
    private var suppressEnd = false

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    var isRinging: Bool { current != nil }

    /// Показать системный входящий звонок. completion(false) — система не дала (например, режим «Не беспокоить» запрещает)
    func reportIncoming(name: String, video: Bool, completion: @escaping (Bool) -> Void) {
        end()
        let id = UUID()
        current = id
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = video
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            Task { @MainActor in
                if error != nil, self?.current == id { self?.current = nil }
                completion(error == nil)
            }
        }
    }

    /// Убрать системный звонок (ответили, отклонили или звонящий положил трубку). true — что-то было
    @discardableResult
    func end() -> Bool {
        guard let id = current else { return false }
        current = nil
        suppressEnd = true
        provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.suppressEnd = false }
        return true
    }

    // MARK: CXProviderDelegate

    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in self.current = nil }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            self.current = nil
            if let onAnswer = self.onAnswer { onAnswer() } else { self.pendingAnswer = true }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            if !self.suppressEnd, self.current != nil {
                self.current = nil
                self.onDecline?()
            }
            action.fulfill()
        }
    }
}
