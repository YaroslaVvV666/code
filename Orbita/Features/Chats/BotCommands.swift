import SwiftUI
import UIKit

// MARK: - Команды ботов (как в Telegram)

/// Команда бота: «/newpack — Создать новый набор»
struct BotCommand: Equatable, Hashable, Decodable {
    let command: String
    let description: String

    var slash: String { "/" + command }

    /// Команды бота @stickers — на случай, если сервер ещё старый и сам их не прислал
    static let stickerBotDefaults: [BotCommand] = [
        BotCommand(command: "start", description: "Главное меню"),
        BotCommand(command: "newpack", description: "Создать новый набор"),
        BotCommand(command: "addsticker", description: "Добавить стикер в набор"),
        BotCommand(command: "delsticker", description: "Удалить стикер из набора"),
        BotCommand(command: "mypacks", description: "Мои наборы"),
        BotCommand(command: "delpack", description: "Удалить набор"),
        BotCommand(command: "done", description: "Закончить набор"),
        BotCommand(command: "cancel", description: "Отменить действие"),
        BotCommand(command: "help", description: "Помощь"),
    ]

    /// Команды для переписки: что прислал сервер, а для @stickers — хотя бы встроенный список
    static func resolve(_ fromServer: [BotCommand], peerID: String) -> [BotCommand] {
        if !fromServer.isEmpty { return fromServer }
        return peerID.lowercased() == StickerBot.id.lowercased() ? stickerBotDefaults : []
    }
}

/// Переписка с ботом: «Что умеет этот бот?» (описание + баннер), нажат ли «Старт», сколько пользователей
struct BotInfo: Equatable, Decodable {
    let description: String
    let banner: String?
    let bannerKind: String?
    let commands: [BotCommand]
    var started: Bool
    let users: Int
    /// «N пользователей в месяц»: сервер присылает, только если владелец разрешил и их 10 000+
    let monthlyUsers: Int?
    let owner: Bool?

    var bannerIsVideo: Bool { bannerKind == "video" }
    var hasIntro: Bool { !description.isEmpty || banner != nil }
}

/// Подпись под именем бота: «12 345 пользователей в месяц» (у ботов не пишем «был(а) в сети»)
enum BotUsers {
    static func text(_ n: Int, lang: AppLanguage) -> String {
        let num = n.formatted(.number.grouping(.automatic))
        if lang == .ru {
            let m100 = n % 100, m10 = n % 10
            let w = (m100 >= 11 && m100 <= 14) ? "пользователей" : (m10 == 1 ? "пользователь" : (m10 >= 2 && m10 <= 4 ? "пользователя" : "пользователей"))
            return "\(num) \(w) в месяц"
        }
        return "\(num) monthly user\(n == 1 ? "" : "s")"
    }
}

// MARK: Окружение: нажимаемые /команды в тексте сообщений

private struct BotCommandLinksKey: EnvironmentKey { static let defaultValue = false }
private struct OnBotCommandKey: EnvironmentKey { static let defaultValue: ((String) -> Void)? = nil }

extension EnvironmentValues {
    /// В переписке с ботом «/команды» в тексте подсвечиваются и нажимаются
    var botCommandLinks: Bool {
        get { self[BotCommandLinksKey.self] }
        set { self[BotCommandLinksKey.self] = newValue }
    }
    /// Что делать при нажатии на /команду (обычно — отправить её боту)
    var onBotCommand: ((String) -> Void)? {
        get { self[OnBotCommandKey.self] }
        set { self[OnBotCommandKey.self] = newValue }
    }
}

enum BotCommandLinks {
    static let scheme = "orbita-cmd"

    private static let regex = try? NSRegularExpression(pattern: "(?<![\\w/@])/[A-Za-z][A-Za-z0-9_]{0,31}(?![\\w/])")

    /// Подсвечивает /команды как ссылки «orbita-cmd:/команда»
    static func annotate(_ base: NSAttributedString, linkColor: UIColor) -> NSAttributedString {
        guard let regex else { return base }
        let text = base.string
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        guard !matches.isEmpty else { return base }
        let out = NSMutableAttributedString(attributedString: base)
        for m in matches {
            let cmd = (text as NSString).substring(with: m.range)
            guard let url = URL(string: scheme + ":" + cmd) else { continue }
            // уже ссылка (например, адрес сайта) — не трогаем
            if out.attribute(.link, at: m.range.location, effectiveRange: nil) != nil { continue }
            out.addAttributes([.link: url, .foregroundColor: linkColor], range: m.range)
        }
        return out
    }

    /// «orbita-cmd:/newpack» → «/newpack»
    static func command(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let raw = url.absoluteString.dropFirst(scheme.count + 1)
        return raw.isEmpty ? nil : String(raw)
    }
}

// MARK: Кнопка меню слева от скрепки

struct BotMenuButton: View {
    let open: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                if open {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .bold))
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("/").font(.system(size: 22, weight: .bold, design: .rounded))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Color(red: 0.91, green: 0.29, blue: 0.17), in: Circle())
            .shadow(color: Color(red: 0.91, green: 0.29, blue: 0.17).opacity(0.35), radius: 6, y: 2)
            .padding(6).contentShape(Rectangle()).padding(-6)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: open)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("Меню команд")
    }
}

// MARK: Список команд над полем ввода

struct BotCommandsPanel: View {
    let commands: [BotCommand]
    let onPick: (BotCommand) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(commands.enumerated()), id: \.element) { i, c in
                    Button {
                        Haptics.select()
                        onPick(c)
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            Text(c.description)
                                .font(.system(size: 17)).foregroundStyle(theme.text)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(c.slash)
                                .font(.system(size: 16)).foregroundStyle(theme.textSecondary)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < commands.count - 1 {
                        Divider().overlay(theme.stroke).padding(.leading, 18)
                    }
                }
            }
        }
        .frame(maxHeight: min(CGFloat(commands.count) * 50, UIScreen.main.bounds.height * 0.45))
        .scrollBounceBehavior(.basedOnSize)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 14, y: -2)
        .padding(.horizontal, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Приветствие бота: баннер + «Что умеет этот бот?» (в самом начале переписки)

struct BotIntroCard: View {
    let info: BotInfo
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let banner = info.banner {
                Group {
                    if info.bannerIsVideo {
                        BotBannerVideo(mediaID: banner)
                    } else {
                        RemoteImage(id: banner)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 210)
                .clipped()
            }
            if !info.description.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Strings(lang: lang).t("Что умеет этот бот?", "What can this bot do?"))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(theme.text)
                    // /команды в описании нажимаются — как в сообщениях бота
                    RichInlineText(text: info.description, entities: [], size: 16, color: theme.text,
                                   linkColor: theme.accentColor, detect: true)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.dark ? Color(white: 0.1).opacity(0.92) : Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(theme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(theme.dark ? 0.35 : 0.08), radius: 14, y: 4)
        .frame(maxWidth: 440)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }
}

/// Видео-баннер: без звука, по кругу, только пока на экране
struct BotBannerVideo: View {
    let mediaID: String
    @StateObject private var box = LoopPlayerBox()
    @State private var onScreen = false

    var body: some View {
        ZStack {
            Color.black
            PlayerLayerView(player: box.player, gravity: .resizeAspectFill)
                .allowsHitTesting(false)
        }
        .background(GeometryReader { g in
            let f = g.frame(in: .global)
            let on = f.height > 0 && f.maxY > -40 && f.minY < UIScreen.main.bounds.height + 40
            Color.clear
                .onAppear { setOnScreen(on) }
                .onChange(of: on) { _, now in setOnScreen(now) }
        })
        .onDisappear { setOnScreen(false) }
    }

    private func setOnScreen(_ now: Bool) {
        guard now != onScreen else { return }
        onScreen = now
        if now { box.start(mediaID) } else { box.stop() }
    }
}

// MARK: - «Старт» вместо поля ввода, пока бота не запускали

struct BotStartBar: View {
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var hint = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 10) {
            // подсказка над кнопкой, как в Telegram
            HStack(spacing: 10) {
                Image(systemName: "chevron.down.2").font(.system(size: 15, weight: .semibold))
                    .offset(y: hint ? 2 : -2)
                Text(s.t("Чтобы использовать бота, нажмите здесь", "Tap here to use this bot"))
                    .font(.system(size: 16, weight: .medium))
            }
            .foregroundStyle(theme.text)
            .padding(.horizontal, 16).frame(height: 46)
            .background(theme.dark ? Color(white: 0.12) : Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .bottom) {
                BotHintTail().fill(theme.dark ? Color(white: 0.12) : Color.white)
                    .frame(width: 16, height: 8).offset(y: 8)
            }
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { hint = true }
            }

            Button {
                Haptics.impact(.medium)
                action()
            } label: {
                Text(s.t("Старт", "Start"))
                    .font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(theme.accent, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: theme.accentColor.opacity(0.45), radius: 12, y: 4)
            }
            .buttonStyle(PressStyle())
        }
        .padding(.horizontal, 16)
        .padding(.top, 8).padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct BotHintTail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Кнопки бота: под сообщением (inline) и клавиатура вместо обычной (как в Telegram)

/// Кнопка под сообщением бота: ссылка или «callback» — нажатие уходит коду бота
struct BotButton: Equatable, Hashable, Codable {
    let text: String
    var url: String? = nil
    var callbackData: String? = nil
}

/// Клавиатура бота вместо обычной: нажатие отправляет текст кнопки
struct BotKeyboard: Equatable, Decodable {
    struct Key: Equatable, Hashable, Decodable { let text: String }
    let keyboard: [[Key]]
    let resize: Bool?
    let oneTime: Bool?
    let placeholder: String?
}

struct BotCallbackAnswer: Decodable {
    let answered: Bool
    let text: String?
    let showAlert: Bool?
    let url: String?
}

private struct BotButtonActionKey: EnvironmentKey {
    static let defaultValue: ((ChatMessage, BotButton) -> Void)? = nil
}

extension EnvironmentValues {
    /// Нажали кнопку под сообщением бота
    var onBotButton: ((ChatMessage, BotButton) -> Void)? {
        get { self[BotButtonActionKey.self] }
        set { self[BotButtonActionKey.self] = newValue }
    }
}

/// Ряды кнопок под пузырём сообщения бота
struct BotInlineButtons: View {
    let message: ChatMessage
    @Environment(\.onBotButton) private var onBotButton
    @Environment(\.theme) private var theme
    @ObservedObject private var progress = BotButtonProgress.shared

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(message.markup.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, b in
                        Button {
                            Haptics.impact(.light)
                            onBotButton?(message, b)
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Group {
                                    if progress.loading == key(b) {
                                        ProgressView().tint(.white).controlSize(.small)
                                    } else {
                                        Text(b.text).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                                            .multilineTextAlignment(.center).minimumScaleFactor(0.8)
                                    }
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .padding(.horizontal, 8)
                                if b.url != nil {
                                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.85)).padding(5)
                                }
                            }
                            .background(.black.opacity(theme.dark ? 0.35 : 0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressStyle())
                    }
                }
            }
        }
        .frame(maxWidth: 340)
    }

    private func key(_ b: BotButton) -> String { message.id + "|" + (b.callbackData ?? "") }
}

/// Какая кнопка бота сейчас ждёт ответа (крутилка вместо подписи)
@MainActor
final class BotButtonProgress: ObservableObject {
    static let shared = BotButtonProgress()
    @Published var loading: String?
}

/// Клавиатура бота на месте системной: ряды крупных кнопок
struct BotReplyKeyboardPanel: View {
    let keyboard: BotKeyboard
    let onPress: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(Array(keyboard.keyboard.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 6) {
                        ForEach(row, id: \.self) { key in
                            Button {
                                Haptics.impact(.light)
                                onPress(key.text)
                            } label: {
                                Text(key.text).font(.system(size: 16, weight: .medium)).foregroundStyle(theme.text)
                                    .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity, minHeight: keyboard.resize == true ? 44 : 52)
                                    .padding(.horizontal, 6)
                                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .shadow(color: .black.opacity(theme.dark ? 0 : 0.12), radius: 0, y: 1)
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                }
            }
            .padding(8)
        }
        .frame(maxHeight: keyboard.resize == true ? min(CGFloat(keyboard.keyboard.count) * 50 + 16, 280) : 280)
        .background(theme.dark ? Color(white: 0.09) : Color(white: 0.86))
    }
}

/// Ссылка на бота с параметром запуска: orbita.app/<bot>?start=abc → «Старт» отправит «/start abc»
enum BotStartParam {
    static func clean(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= 64,
              raw.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }),
              raw.allSatisfy(\.isASCII) else { return nil }
        return raw
    }
}

/// Параметры запуска ботов из ссылок (?start=…), ждут, пока откроется переписка с ботом
@MainActor
enum BotStartLinks {
    private static var pending: [String: String] = [:]

    nonisolated static func set(username: String, param: String) {
        Task { @MainActor in pending[username.lowercased()] = param }
    }

    static func peek(username: String?) -> String? {
        guard let username else { return nil }
        return pending[username.lowercased()]
    }

    static func take(username: String?) -> String? {
        guard let username else { return nil }
        return pending.removeValue(forKey: username.lowercased())
    }
}
