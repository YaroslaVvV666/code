import SwiftUI

@main
struct OrbitaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // фото и аватарки с сервера кэшируются на диск
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 400 * 1024 * 1024)
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
