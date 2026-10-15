import SwiftUI
import UIKit
import UserNotifications
import Combine

/// Настоящие push-уведомления (APNs): разрешение, регистрация устройства, нажатие на уведомление
@MainActor
final class PushManager: ObservableObject {
    static let shared = PushManager()

    @Published private(set) var token: String?          // токен устройства (hex)
    @Published private(set) var denied = false
    /// Нажали на уведомление о сообщении — открыть этот чат
    @Published var openChat: ChatRoute?

    #if DEBUG
    static let environment = "sandbox"                  // сборка из Xcode на устройство
    #else
    static let environment = "production"               // TestFlight / App Store
    #endif

    /// Спрашивает разрешение (один раз) и регистрирует устройство в APNs
    func requestAndRegister() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            denied = !granted
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        case .denied:
            denied = true
        default:
            denied = false
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func didRegister(_ data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
    }

    func handleTap(_ userInfo: [AnyHashable: Any]) {
        guard let id = userInfo["chat"] as? String else { return }
        let name = (userInfo["name"] as? String) ?? ""
        let avatar = userInfo["avatar"] as? String
        openChat = ChatRoute(peer: ChatPeer(id: id, name: name, username: nil, avatarID: avatar))
    }

    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.didRegister(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Push: не удалось зарегистрироваться: \(error.localizedDescription)")
    }

    /// Пока приложение открыто — баннер не показываем (сообщение и так видно в чате)
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [] }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        await MainActor.run { PushManager.shared.handleTap(info) }
    }
}
