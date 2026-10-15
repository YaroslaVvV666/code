import SwiftUI
import Combine

/// Выбор времени для «Отправить позже»
struct ScheduleSheet: View {
    let onPick: (Date) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date().addingTimeInterval(3600)

    var body: some View {
        let s = Strings(lang: lang)
        VStack(spacing: 14) {
            HStack {
                Text(s.t("Отправить позже", "Send later")).font(.system(size: 20, weight: .bold)).foregroundStyle(theme.text)
                Spacer()
                Button(s.cancel) { dismiss() }.foregroundStyle(theme.accentColor)
            }
            .padding(.horizontal, 20).padding(.top, 20)
            DatePicker("", selection: $date, in: Date().addingTimeInterval(60)..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.wheel).labelsHidden().tint(theme.accentColor)
            Button { onPick(date) } label: {
                Text(s.t("Запланировать", "Schedule"))
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 50).background(theme.accent, in: Capsule())
            }
            .buttonStyle(PressStyle()).padding(.horizontal, 20)
        }
    }
}

/// Список запланированных сообщений чата
struct ScheduledListSheet: View {
    let peerID: String
    @State var items: [ScheduledItem]
    let onChange: () -> Void
    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        let s = Strings(lang: lang)
        VStack(spacing: 0) {
            Text(s.t("Запланировано", "Scheduled")).font(.system(size: 20, weight: .bold)).foregroundStyle(theme.text)
                .padding(.top, 20).padding(.bottom, 10)
            if items.isEmpty {
                Text(s.t("Нет запланированных сообщений", "Nothing scheduled")).foregroundStyle(theme.textSecondary).padding(.top, 30)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accentColor)
                                Text(item.text.isEmpty ? s.t("Вложение", "Attachment") : item.text)
                                    .font(.system(size: 15)).foregroundStyle(theme.text).lineLimit(2)
                            }
                            Spacer()
                            Button {
                                Task {
                                    await session.extras.cancelScheduled(id: item.id)
                                    withAnimation { items.removeAll { $0.id == item.id } }
                                    onChange()
                                }
                            } label: {
                                Image(systemName: "trash").foregroundStyle(theme.danger).frame(width: 40, height: 40)
                            }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        Divider().opacity(0.3).padding(.leading, 20)
                    }
                }
            }
        }
    }
}
