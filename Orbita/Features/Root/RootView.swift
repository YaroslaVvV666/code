import SwiftUI
import Combine

/// Корень приложения: фон, переключение шагов регистрации и главного экрана
struct RootView: View {
    @AppStorage("isDark") private var isDark = true
    @AppStorage("lang") private var langRaw = AppLanguage.ru.rawValue
    @AppStorage("accent") private var accentRaw = 0
    @AppStorage("autoplay") private var autoplay = true
    @StateObject private var flow = AuthFlow()
    @StateObject private var router = LinkRouter()
    @ObservedObject private var appLock = AppLock.shared
    @Environment(\.scenePhase) private var scenePhase

    private var lang: AppLanguage { AppLanguage(rawValue: langRaw) ?? .ru }
    private var theme: Theme { Theme(dark: isDark, accentIndex: accentRaw) }
    private var currentSettings: UserSettings {
        UserSettings(language: langRaw, isDark: isDark, accent: accentRaw, autoplay: autoplay)
    }
    private var stepTransition: AnyTransition { .opacity.combined(with: .scale(scale: 0.98)) }

    private var showsTopBar: Bool {
        flow.step != .launch && flow.step != .home
    }

    var body: some View {
        ZStack(alignment: .top) {
            SpaceBackground(isDark: isDark, showStars: flow.step != .home)

            content

            if showsTopBar { topBar }

            if let address = router.serverApplied {
                Label(Strings(lang: lang).serverConnected(address), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(Color.green.opacity(0.92), in: Capsule())
                    .padding(.top, 54)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let message = flow.inbox {
                InboxBanner(message: message)
                    .padding(.top, 54)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { flow.inbox = nil }
            }
        }
        .overlay {
            if appLock.locked && appLock.enabled {
                AppLockView(lock: appLock).transition(.opacity)
            } else if appLock.enabled && scenePhase != .active {
                // в переключателе приложений содержимое не видно
                SpaceBackground(isDark: isDark, showStars: true).ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appLock.locked)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { appLock.lockNow() }
        }
        .edgeSwipeBack(enabled: showsTopBar && flow.canGoBack) { flow.back() }
        .animation(.easeInOut(duration: 0.3), value: flow.step)
        .animation(.easeInOut(duration: 0.25), value: flow.keyboardVisible)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: flow.inbox)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: router.serverApplied)
        .animation(.easeOut(duration: 0.2), value: flow.error)
        .environmentObject(flow)
        .environmentObject(router)
        .environment(\.theme, theme)
        .environment(\.lang, lang)
        .preferredColorScheme(isDark ? .dark : .light)
        .onAppear { flow.deviceSettings = currentSettings }
        .onChange(of: langRaw) { _, _ in flow.updateDeviceSettings(currentSettings) }
        .onChange(of: isDark) { _, _ in flow.updateDeviceSettings(currentSettings) }
        .onChange(of: accentRaw) { _, _ in flow.updateDeviceSettings(currentSettings) }
        .onChange(of: autoplay) { _, _ in flow.updateDeviceSettings(currentSettings) }
        .onChange(of: flow.restore) { _, new in
            guard let new else { return }
            langRaw = new.settings.language
            accentRaw = new.settings.accent
            autoplay = new.settings.autoplay
            withAnimation(.easeInOut(duration: 0.4)) { isDark = new.settings.isDark }
        }
        .onOpenURL { router.handle($0) }
        // ссылки внутри текста (посты, чаты): свои открываем внутри приложения, остальные — как обычно
        .environment(\.openURL, OpenURLAction { url in
            if DeepLink(url: url) != nil { router.handle(url); return .handled }
            return .systemAction
        })
        .onReceive(NotificationCenter.default.publisher(for: .orbitaSessionRevoked)
            .receive(on: DispatchQueue.main)) { _ in
            if flow.step == .home { flow.logout() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            flow.keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            flow.keyboardVisible = false
        }
    }

    @ViewBuilder
    private var content: some View {
        let s = Strings(lang: lang)
        switch flow.step {
        case .launch:
            LaunchView().transition(.opacity)
        case .phone:
            PhoneStepView().transition(stepTransition)
        case .phoneCode:
            CodeStepView(channel: .sms).transition(stepTransition)
        case .passwordLogin:
            PasswordLoginView().transition(stepTransition)
        case .name:
            NameStepView().transition(stepTransition)
        case .emailOffer:
            OfferStepView(
                icon: "envelope",
                title: s.emailOfferTitle,
                subtitle: s.emailOfferSub,
                bullets: [("lock.rotation", s.bulletRecovery), ("bell", s.bulletAlerts)],
                primary: s.linkEmail,
                secondary: s.skip,
                onPrimary: { flow.startEmail() },
                onSecondary: { flow.skipEmail() }
            ).transition(stepTransition)
        case .emailInput:
            EmailInputView().transition(stepTransition)
        case .emailCode:
            CodeStepView(channel: .email).transition(stepTransition)
        case .twoFAOffer:
            OfferStepView(
                icon: "lock.shield",
                title: s.twoFATitle,
                subtitle: s.twoFASub,
                bullets: [("key", s.bulletPassword), ("message.badge", s.bulletSMS)],
                primary: s.enable,
                secondary: s.skip,
                onPrimary: { flow.startTwoFA() },
                onSecondary: { flow.skipTwoFA() }
            ).transition(stepTransition)
        case .twoFASetup:
            TwoFASetupView().transition(stepTransition)
        case .interests:
            InterestsStepView().transition(stepTransition)
        case .done:
            DoneStepView().transition(stepTransition)
        case .home:
            MainTabView(userID: flow.userID ?? "", userName: flow.userName)
                .transition(.opacity)
        }
    }

    private var topBar: some View {
        HStack {
            if flow.canGoBack {
                Button {
                    Haptics.impact(.light)
                    flow.back()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .frame(width: 36, height: 36)
                        .card(theme, radius: 18)
                }
                .buttonStyle(PressStyle())
                .transition(.opacity)
            }
            Spacer()
            ThemeToggle(isDark: $isDark)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .animation(.easeOut(duration: 0.2), value: flow.canGoBack)
    }
}
