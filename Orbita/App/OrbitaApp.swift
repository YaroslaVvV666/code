import SwiftUI
import Combine
import UIKit

@main
struct OrbitaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // фото и аватарки с сервера кэшируются на диск
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 400 * 1024 * 1024)
        // «Данные и память»: срок хранения медиа и предел кэша; сеть (мобильная / Wi-Fi) начинаем слушать сразу
        _ = NetPath.shared
        CacheJanitor.enforce()
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            CacheJanitor.enforce()
        }
        // анимированные эмодзи разбираются заранее, в фоне
        #if canImport(Lottie)
        Task.detached(priority: .utility) { await LottieEmojiStore.shared.preloadAll() }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
