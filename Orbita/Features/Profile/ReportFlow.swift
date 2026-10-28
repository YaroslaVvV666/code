import SwiftUI

/// Причины жалобы — совпадают с набором на сервере (REPORT_REASONS).
enum ReportReasons {
    static func list(_ s: Strings) -> [(code: String, title: String, icon: String)] {
        [("spam", s.t("Спам", "Spam"), "envelope.badge"),
         ("fraud", s.t("Мошенничество", "Fraud / scam"), "exclamationmark.shield"),
         ("violence", s.t("Насилие или угрозы", "Violence or threats"), "flame"),
         ("adult", s.t("Контент для взрослых", "Adult content"), "eye.slash"),
         ("child_abuse", s.t("Вред детям", "Child safety"), "figure.child"),
         ("extremism", s.t("Экстремизм / терроризм", "Extremism / terrorism"), "burst"),
         ("illegal", s.t("Незаконный контент", "Illegal content"), "xmark.octagon"),
         ("copyright", s.t("Нарушение авторских прав", "Copyright"), "c.circle"),
         ("other", s.t("Другое", "Other"), "ellipsis.circle")]
    }

    static func title(_ code: String, _ s: Strings) -> String {
        list(s).first { $0.code == code }?.title ?? s.t("Другое", "Other")
    }
}

/// Выбор причины + необязательный комментарий. Отправляет жалобу через колбэк.
struct ReportSheet: View {
    let title: String
    let onSubmit: (_ reason: String, _ note: String) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss
    @State private var reason: String?
    @State private var note = ""
    @State private var sent = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(theme.text)
                Spacer()
                Button(s.t("Отмена", "Cancel")) { dismiss() }.foregroundStyle(theme.accentColor)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(ReportReasons.list(s), id: \.code) { r in
                        Button { Haptics.select(); withAnimation(.easeOut(duration: 0.15)) { reason = r.code } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: r.icon).font(.system(size: 16)).frame(width: 24)
                                    .foregroundStyle(reason == r.code ? Color.white : theme.textSecondary)
                                Text(r.title).font(.system(size: 16))
                                    .foregroundStyle(reason == r.code ? Color.white : theme.text)
                                Spacer()
                                if reason == r.code { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white) }
                            }
                            .padding(.horizontal, 14).frame(height: 48)
                            .background(reason == r.code ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.surface),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    TextField(s.t("Комментарий (необязательно)", "Comment (optional)"), text: $note, axis: .vertical)
                        .lineLimit(1...3)
                        .font(.system(size: 15)).padding(14)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
            }

            Button {
                guard let reason else { return }
                onSubmit(reason, note.trimmingCharacters(in: .whitespacesAndNewlines))
                Haptics.notify(.success)
                sent = true
                dismiss()
            } label: {
                Text(s.t("Отправить жалобу", "Send report"))
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(reason == nil ? AnyShapeStyle(theme.textTertiary) : AnyShapeStyle(theme.accent),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(reason == nil)
            .padding(16)

            Text(s.t("Жалоба уходит модераторам. Распознавание и решение — на нашей стороне.",
                     "Your report goes to our moderators for review."))
                .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center).padding(.horizontal, 24).padding(.bottom, 12)
        }
    }
}

/// Экран «Мои жалобы» — список поданных жалоб со статусом рассмотрения.
struct MyReportsView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var reports: [MyReport] = []
    @State private var loaded = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        ScrollView {
            if !loaded {
                ProgressView().padding(.top, 60)
            } else if reports.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.shield").font(.system(size: 34, weight: .light)).foregroundStyle(theme.accentColor)
                    Text(s.t("Жалоб нет", "No reports")).font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.text)
                    Text(s.t("Здесь появятся ваши жалобы и их статус.", "Your reports and their status will appear here."))
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center).padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(reports) { r in reportCard(r) }
                }
                .padding(16)
            }
        }
        .background(theme.sheet.ignoresSafeArea())
        .navigationTitle(s.t("Мои жалобы", "My reports"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func reportCard(_ r: MyReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: kindIcon(r.kind)).font(.system(size: 14)).foregroundStyle(theme.accentColor)
                Text(kindTitle(r.kind)).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
                Spacer()
                statusBadge(r)
            }
            Text(ReportReasons.title(r.reason, s)).font(.system(size: 14)).foregroundStyle(theme.textSecondary)
            if !r.note.isEmpty {
                Text(r.note).font(.system(size: 13)).foregroundStyle(theme.textTertiary).lineLimit(2)
            }
            Text(ChatTime.short(Date(timeIntervalSince1970: r.createdAt), lang: lang))
                .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card(theme, radius: 16)
    }

    private func statusBadge(_ r: MyReport) -> some View {
        let (text, color): (String, Color) = {
            switch r.status {
            case "resolved": return (s.t("Рассмотрена", "Resolved"), .green)
            case "dismissed": return (s.t("Отклонена", "Dismissed"), theme.textTertiary)
            default: return (s.t("На рассмотрении", "In review"), .orange)
            }
        }()
        return Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 10).frame(height: 22)
            .background(color, in: Capsule())
    }

    private func kindIcon(_ kind: String) -> String {
        switch kind {
        case "message": return "bubble.left"
        case "user": return "person.crop.circle.badge.exclamationmark"
        case "post": return "photo"
        default: return "flag"
        }
    }

    private func kindTitle(_ kind: String) -> String {
        switch kind {
        case "message": return s.t("Сообщение", "Message")
        case "user": return s.t("Профиль", "Profile")
        case "post": return s.t("Публикация", "Post")
        case "chat": return s.t("Чат", "Chat")
        default: return s.t("Жалоба", "Report")
        }
    }

    private func load() async {
        reports = (try? await session.extras.myReports()) ?? []
        loaded = true
    }
}
