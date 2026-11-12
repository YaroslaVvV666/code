import SwiftUI
import Combine
import UIKit

// MARK: - «Помощь»: окно, как в Telegram, → «ОК» открывает официальный бот поддержки @support

enum SupportBot {
    /// Официальный бот поддержки Orbita (на сервере — SUPPORT_ID); отвечают волонтёры
    static let id = "5c0ff0e0-0000-4000-8000-00000005c0ff"
    static var peer: ChatPeer { ChatPeer(id: id, name: "Orbita Support", username: "support", avatarID: nil) }

    @MainActor
    static func open() {
        PushManager.shared.openChat = ChatRoute(peer: peer)       // главный экран сам переключится на «Чаты»
    }
}

/// Окно «Помощь»: про волонтёров и «Вопросы об Orbita»; «Ответы» — частые вопросы, «ОК» — написать в поддержку
struct HelpAlert: View {
    let onAnswers: () -> Void
    let onOK: () -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var shown = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).opacity(shown ? 1 : 0)
                .overlay(Color.black.opacity(shown ? 0.28 : 0))
                .ignoresSafeArea()
                .onTapGesture { close(onDismiss) }

            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 22) {
                    Text(s.t("Пожалуйста, обратите внимание, что в поддержке Orbita отвечают волонтёры. Мы постараемся помочь как можно быстрее, но ожидание может занять время.",
                             "Please note that Orbita support is run by volunteers. We'll try to help as quickly as possible, but it may take a while."))
                    Text(s.t("Пожалуйста, ознакомьтесь с частыми вопросами об Orbita: там вы найдёте ответы на большинство вопросов и важные советы по устранению неполадок.",
                             "Please check the Orbita FAQ: it has answers to most questions and important troubleshooting tips."))
                }
                .font(.system(size: 17))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)

                HStack(spacing: 10) {
                    Button { close(onAnswers) } label: {
                        Text(s.t("Ответы", "Answers"))
                            .font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.text)
                            .frame(maxWidth: .infinity).frame(height: 56)
                            .background(theme.text.opacity(theme.dark ? 0.1 : 0.07), in: Capsule())
                    }
                    .buttonStyle(PressStyle())
                    Button { close(onOK) } label: {
                        Text("OK")
                            .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 56)
                            .background(theme.accentColor, in: Capsule())
                    }
                    .buttonStyle(PressStyle())
                }
            }
            .padding(.horizontal, 18).padding(.top, 26).padding(.bottom, 18)
            .background {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(theme.dark ? Color(white: 0.13).opacity(0.94) : Color.white.opacity(0.96))
                    .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).stroke(theme.stroke, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
            }
            .padding(.horizontal, 28)
            .scaleEffect(shown ? 1 : 0.86)
            .opacity(shown ? 1 : 0)
        }
        .onAppear {
            Haptics.impact(.light)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { shown = true }
        }
    }

    private func close(_ then: @escaping () -> Void) {
        withAnimation(.easeOut(duration: 0.18)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { then() }
    }
}

// MARK: - Вопросы об Orbita

struct FAQSheet: View {
    var onAskSupport: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var open: Set<Int> = []
    @State private var query = ""

    private var s: Strings { Strings(lang: lang) }

    private var items: [(String, String)] {
        [
            (s.t("Что такое мой ID?", "What is my ID?"),
             s.t("Постоянный номер вашего аккаунта — он виден в профиле, в строке «ID». По нему поддержка находит ваш аккаунт. Номер нельзя изменить, и по нему нельзя войти в аккаунт.",
                 "A permanent number of your account shown in your profile. Support uses it to find your account. It can't be changed and can't be used to log in.")),
            (s.t("Не приходят уведомления", "I don't get notifications"),
             s.t("Проверьте «Настройки iPhone → Уведомления → Orbita»: уведомления должны быть разрешены. Также проверьте, не отключён ли звук у самого чата (значок колокольчика) и не включён ли режим «Фокусирование».",
                 "Check iPhone Settings → Notifications → Orbita. Also check that the chat isn't muted and Focus mode is off.")),
            (s.t("Как войти на другом устройстве?", "How do I log in on another device?"),
             s.t("Профиль → «Устройства» → «Подключить устройство» и отсканируйте QR-код на экране входа другого устройства.",
                 "Profile → Devices → Link device, then scan the QR code on the other device's login screen.")),
            (s.t("Кто-то зашёл в мой аккаунт", "Someone logged into my account"),
             s.t("Откройте «Устройства» и завершите незнакомые сеансы, затем включите облачный пароль в «Конфиденциальности». Мы никогда не просим ваш код входа.",
                 "Open Devices and end unknown sessions, then turn on the cloud password in Privacy. We never ask for your login code.")),
            (s.t("Телефон заполнен — что удалить?", "My phone is full — what can I delete?"),
             s.t("«Данные и память» → «Использование памяти»: выберите, что очистить. Всё удалённое скачается заново, когда понадобится. Там же можно задать срок хранения медиа и предел кэша.",
                 "Data and storage → Storage usage: choose what to clear. It re-downloads when needed. You can also set a keep-media period and a cache limit.")),
            (s.t("Как сэкономить мобильный трафик?", "How do I save cellular data?"),
             s.t("«Данные и память» → «Автозагрузка медиа» → «Через мобильную сеть»: выключите видео и файлы. Там же «Использование трафика» покажет, что сколько тратит.",
                 "Data and storage → Auto-download → Using cellular: turn off videos and files. Data usage shows what uses the most.")),
            (s.t("Как удалить аккаунт?", "How do I delete my account?"),
             s.t("Профиль → в самом низу «Удалить аккаунт». Это нельзя отменить: сообщения, посты и шортсы удалятся.",
                 "Profile → Delete account at the very bottom. It can't be undone.")),
            (s.t("Как создать своего бота?", "How do I create a bot?"),
             s.t("Напишите @botgod и отправьте /newbot — он проведёт по шагам и выдаст токен для Bot API.",
                 "Message @botgod and send /newbot — it guides you and gives you a Bot API token.")),
            (s.t("Как пожаловаться на человека или пост?", "How do I report someone?"),
             s.t("Нажмите «…» у поста, в профиле или в чате и выберите «Пожаловаться». Ваши жалобы и решения по ним — в «Конфиденциальность → Мои жалобы».",
                 "Tap “…” on a post, profile or chat and choose Report. Your reports are in Privacy → My reports.")),
        ]
    }

    private var filtered: [(Int, (String, String))] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return Array(items.enumerated()).filter { q.isEmpty || $0.element.0.lowercased().contains(q) || $0.element.1.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(s.t("Вопросы об Orbita", "Orbita FAQ")).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 6)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.textTertiary)
                TextField(s.t("Поиск по вопросам", "Search questions"), text: $query)
                    .foregroundStyle(theme.text).tint(theme.accentColor)
            }
            .padding(.horizontal, 14).frame(height: 42)
            .background(theme.surface, in: Capsule())
            .padding(.horizontal, 16).padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 0) {
                    SettingsGroup {
                        ForEach(Array(filtered.enumerated()), id: \.element.0) { pos, entry in
                            let (i, qa) = entry
                            Button {
                                Haptics.select()
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                    if open.contains(i) { open.remove(i) } else { open.insert(i) }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(qa.0).font(.system(size: 16, weight: .medium)).foregroundStyle(theme.text)
                                            .multilineTextAlignment(.leading)
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(theme.textTertiary)
                                            .rotationEffect(.degrees(open.contains(i) ? 180 : 0))
                                    }
                                    if open.contains(i) {
                                        Text(qa.1).font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .transition(.opacity.combined(with: .move(edge: .top)))
                                    }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if pos < filtered.count - 1 { SettingsDivider() }
                        }
                    }
                    if let onAskSupport {
                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onAskSupport() }
                        } label: {
                            Label(s.t("Не нашли ответ? Написать в поддержку", "No answer? Contact support"), systemImage: "bubble.left.and.bubble.right.fill")
                                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).frame(height: 52)
                                .background(theme.accentColor, in: Capsule())
                                .padding(.horizontal, 16)
                        }
                        .buttonStyle(PressStyle())
                        .padding(.top, 18)
                    }
                }
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(theme.sheet.ignoresSafeArea())
    }
}
