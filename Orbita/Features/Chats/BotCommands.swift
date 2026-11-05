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
