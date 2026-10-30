import Foundation
import PushKit
import CallKit

/// VoIP-пуш (PushKit) — отдельный канал только для звонков. Apple будит приложение таким пушем,
/// даже если оно полностью закрыто, и ТРЕБУЕТ, чтобы мы тут же показали системный входящий звонок
/// (CallKit). Благодаря этому звонок приходит на весь экран, как в Telegram, при закрытом приложении.
///
/// Нужно в Xcode: Signing & Capabilities → Background Modes → «Voice over IP»; и Push Notifications.
/// VoIP-токен уходит на сервер отдельно от обычного (kind: "voip"). Реестр доставляет колбэки на .main,
/// поэтому обращения к @MainActor-объектам здесь безопасны.
final class VoIPPush: NSObject, ObservableObject, PKPushRegistryDelegate {
    @MainActor static let shared = VoIPPush()

    private let registry = PKPushRegistry(queue: .main)
    @Published private(set) var token: String?
    /// Пришёл звонок — приложение должно подхватить его и соединиться (ставит CallManager)
    @MainActor var onIncomingCall: ((_ callID: String, _ name: String, _ video: Bool) -> Void)?

    @MainActor func activate() {
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }

    // MARK: PKPushRegistryDelegate (реестр создан с queue: .main → мы на главном потоке)

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        MainActor.assumeIsolated { self.token = hex }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        if type == .voIP { MainActor.assumeIsolated { self.token = nil } }
    }

    /// Пришёл VoIP-пуш. Apple убьёт приложение, если мы НЕ покажем входящий звонок здесь же (синхронно).
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                                  for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        MainActor.assumeIsolated {
            let info = payload.dictionaryPayload
            let callID = (info["call"] as? String) ?? UUID().uuidString
            let name = (info["name"] as? String) ?? "Входящий звонок"
            let video = (info["video"] as? Bool) ?? ((info["video"] as? Int) == 1)
            // 1) немедленно — системный экран входящего звонка (обязательное требование Apple для VoIP-пуша)
            CallRinger.shared.reportIncoming(name: name, video: video) { _ in }
            // 2) приложение подхватывает звонок и соединяется по WebRTC (через обычный сценарий)
            onIncomingCall?(callID, name, video)
            completion()
        }
    }
}
