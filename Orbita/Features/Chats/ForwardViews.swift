import SwiftUI

// MARK: - Открыть профиль по id (общий способ для чатов, групп, участников)

private struct ProfileSheetModifier: ViewModifier {
    @Binding var id: String?
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.fullScreenCover(item: Binding(get: { id.map { AuthorRoute(id: $0) } }, set: { id = $0?.id })) { route in
            PublicProfileSheet(source: .id(route.id))
                .environmentObject(session).environmentObject(flow)
                .preferredColorScheme(theme.dark ? .dark : .light)
                .presentationBackground(theme.sheet)
        }
    }
}

extension View {
    func profileSheet(id: Binding<String?>) -> some View { modifier(ProfileSheetModifier(id: id)) }
}

// MARK: - Кто прочитал и кто отреагировал

struct MessageInfoSheet: View {
    let message: ChatMessage
    let group: Bool

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss

    @State private var info: MessageInfo?
    @State private var failed = false
    private var s: Strings { Strings(lang: lang) }

    private func stamp(_ d: Date) -> String {
        FormatterCache.format(d, Calendar.current.isDateInToday(d) ? "HH:mm" : "d MMM, HH:mm",
                              locale: Locale(identifier: lang == .ru ? "ru_RU" : "en_US"))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(s.t("Информация о сообщении", "Message info")).font(.system(size: 18, weight: .bold)).foregroundStyle(theme.text)
                Spacer()
                Button(s.close) { dismiss() }.foregroundStyle(theme.accentColor)
            }
            .padding(20)

            if let info {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.summary).font(.system(size: 15)).foregroundStyle(theme.text).lineLimit(3)
                            Text(s.t("Отправлено ", "Sent ") + stamp(info.sentAt))
                                .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading).card(theme, radius: 16)

                        section(title: group
                                ? s.t("Прочитали", "Read by") + " (\(info.readers.count) \(s.t("из", "of")) \(info.total))"
                                : s.t("Прочитано", "Read"),
                                empty: s.t("Пока никто не прочитал", "Not read yet"),
                                entries: info.readers, showEmoji: false)
                        section(title: s.t("Реакции", "Reactions") + " (\(info.reactions.count))",
                                empty: s.t("Реакций нет", "No reactions"),
                                entries: info.reactions, showEmoji: true)
                        if group {
                            Text(s.t("Время прочтения в группах — когда человек открыл чат после этого сообщения.",
                                     "In groups the read time is when the person opened the chat after this message."))
                                .font(.system(size: 12)).foregroundStyle(theme.textTertiary).padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 24)
                }
            } else if failed {
                Text(s.api(.offline)).foregroundStyle(theme.textSecondary).padding(40)
                Spacer()
            } else {
                ProgressView().padding(40)
                Spacer()
            }
        }
        .task {
            do { info = try await session.extras.info(messageID: message.id) } catch { failed = true }
        }
    }

    private func section(title: String, empty: String, entries: [MessageInfo.Entry], showEmoji: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            if entries.isEmpty {
                Text(empty).font(.system(size: 14)).foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 14).padding(.bottom, 14)
            }
            ForEach(entries) { e in
                HStack(spacing: 12) {
                    AvatarView(name: e.user.name, size: 38, avatarID: e.user.avatarID).clipShape(Circle())
                    Text(e.user.name).font(.system(size: 16, weight: .medium)).foregroundStyle(theme.text).lineLimit(1)
                    Spacer()
                    if showEmoji, let emoji = e.emoji { Text(emoji).font(.system(size: 20)) }
                    Text(stamp(e.at)).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }
            Color.clear.frame(height: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(theme, radius: 16)
    }
}
