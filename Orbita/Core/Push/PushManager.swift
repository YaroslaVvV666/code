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

    /// Пока приложение открыто — баннер не показываем (сообщение и так видно в чате). Кроме напоминаний «Напомнить позже»
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        notification.request.content.userInfo["reminder"] as? Bool == true ? [.banner, .list, .sound] : []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        await MainActor.run { PushManager.shared.handleTap(info) }
    }
}

// MARK: - «Напомнить позже» по сообщению

/// Локальное напоминание о сообщении: придёт уведомлением в нужное время, нажатие открывает этот чат
enum MessageReminder {
    struct Option { let title: String; let date: Date }

    /// Через час / сегодня вечером (если ещё не вечер) / завтра утром / завтра вечером
    static func options(_ lang: AppLanguage, now: Date = Date()) -> [Option] {
        let s = Strings(lang: lang)
        let cal = Calendar.current
        var list = [Option(title: s.t("Через час", "In an hour"), date: now.addingTimeInterval(3600))]
        if let evening = cal.date(bySettingHour: 20, minute: 0, second: 0, of: now), cal.component(.hour, from: now) < 19 {
            list.append(Option(title: s.t("Сегодня вечером, 20:00", "This evening, 8 PM"), date: evening))
        }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now) {
            if let morning = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
                list.append(Option(title: s.t("Завтра утром, 9:00", "Tomorrow morning, 9 AM"), date: morning))
            }
            if let evening = cal.date(bySettingHour: 20, minute: 0, second: 0, of: tomorrow) {
                list.append(Option(title: s.t("Завтра вечером, 20:00", "Tomorrow evening, 8 PM"), date: evening))
            }
        }
        return list
    }

    /// false — уведомления запрещены в настройках iOS
    @discardableResult
    static func schedule(peer: ChatPeer, text: String, messageID: String, at date: Date, lang: AppLanguage) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return false }
        } else if settings.authorizationStatus == .denied {
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = Strings(lang: lang).t("Напоминание · ", "Reminder · ") + peer.name
        content.body = text.isEmpty ? Strings(lang: lang).t("Сообщение", "Message") : String(text.prefix(180))
        content.sound = .default
        var info: [String: Any] = ["chat": peer.id, "name": peer.name, "reminder": true, "message": messageID]
        if let avatar = peer.avatarID { info["avatar"] = avatar }
        content.userInfo = info
        let interval = max(5, date.timeIntervalSinceNow)
        let request = UNNotificationRequest(identifier: "reminder." + messageID + "." + String(Int(date.timeIntervalSince1970)),
                                            content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
        do { try await center.add(request); return true } catch { return false }
    }
}
