import SwiftUI

// MARK: - Статистика шортса (видна только автору)

struct ReelStatsDTO: Decodable {
    let views: Int
    let unique: Int
    let avgWatch: Double
    let retention: Double
    let completion: Double
    let skip: Double
    let duration: Double
    let likes: Int
    let comments: Int
    let saves: Int
    let reposts: Int
    let shares: Int
    let engagement: Double
    let followers: Int
    let followersWeek: Int
    let followersFromVideo: Int
    let daily: [Int]
}

extension ExtrasAPI {
    func reelStats(postID: String) async -> ReelStatsDTO? {
        guard let data = try? await api.request("GET", "/v1/posts/\(postID)/stats") else { return nil }
        return try? decodeAPI(ReelStatsDTO.self, from: data)
    }
}

struct ReelStatsSheet: View {
    let postID: String

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss

    @State private var stats: ReelStatsDTO?
    @State private var failed = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(s.t("Статистика", "Statistics")).font(.system(size: 20, weight: .bold)).foregroundStyle(theme.text)
                Spacer()
                Button(s.close) { dismiss() }.foregroundStyle(theme.accentColor).frame(minHeight: 44)
            }
            .padding(.horizontal, 20).padding(.top, 14)

            if let st = stats {
                ScrollView {
                    VStack(spacing: 14) {
                        VStack(spacing: 2) {
                            Text(num(st.views)).font(.system(size: 40, weight: .bold)).foregroundStyle(theme.text)
                            Text(s.t("просмотров", "views") + " · " + num(st.unique) + s.t(" человек", " people"))
                                .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                        }
                        .padding(.top, 6)

                        chart(st.daily)

                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            card("person.badge.plus", s.t("Подписались с этого видео", "Followed from this video"), "+" + num(st.followersFromVideo),
                                 s.t("за неделю на аккаунт: +", "account, 7d: +") + num(st.followersWeek) + s.t(" · всего ", " · total ") + num(st.followers))
                            card("clock", s.t("Среднее время просмотра", "Avg. watch time"), seconds(st.avgWatch),
                                 st.duration > 0 ? s.t("из ", "of ") + seconds(st.duration) : "")
                            card("gauge.medium", s.t("Удержание", "Retention"), percent(st.retention),
                                 s.t("в среднем смотрят", "avg. watched"))
                            card("checkmark.circle", s.t("Досмотрели до конца", "Watched to the end"), percent(st.completion), "")
                            card("forward.end", s.t("Пролистали сразу", "Swiped away"), percent(st.skip), s.t("за первые 2 сек", "in first 2s"))
                            card("sparkles", s.t("Вовлечённость", "Engagement"), percent(st.engagement),
                                 s.t("действий на просмотр", "actions per view"))
                            card("heart.fill", s.t("Лайки", "Likes"), num(st.likes), "")
                            card("bubble.left.fill", s.t("Комментарии", "Comments"), num(st.comments), "")
                            card("bookmark.fill", s.t("Сохранили", "Saves"), num(st.saves), "")
                            card("arrow.2.squarepath", s.t("Репосты", "Reposts"), num(st.reposts), "")
                            card("paperplane.fill", s.t("Отправили в чаты", "Sent in chats"), num(st.shares), "")
                        }
                        .padding(.horizontal, 16)

                        Text(s.t("Просмотры, удержание, время и подписки с видео считаются с момента выхода этого обновления. В «подписались с этого видео» входят подписки, сделанные в шортсах (кнопка «+» у аватарки); подписки с профиля сюда не попадают.",
                                 "Views, retention, watch time and follows are counted since this update. “Followed from this video” counts follows made in Shorts (the “+” by the avatar); follows from a profile aren't included."))
                            .font(.system(size: 12)).foregroundStyle(theme.textTertiary).multilineTextAlignment(.center)
                            .padding(.horizontal, 24).padding(.bottom, 30)
                    }
                }
            } else if failed {
                Spacer()
                Text(s.t("Не удалось загрузить", "Couldn't load")).foregroundStyle(theme.textSecondary)
                Spacer()
            } else {
                Spacer(); ProgressView(); Spacer()
            }
        }
        .background(theme.sheet.ignoresSafeArea())
        .task {
            if let st = await session.extras.reelStats(postID: postID) { stats = st } else { failed = true }
        }
    }

    private func chart(_ days: [Int]) -> some View {
        let peak = max(1, days.max() ?? 1)
        return VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, v in
                    VStack(spacing: 4) {
                        Text(v > 0 ? "\(v)" : "").font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(i == days.count - 1 ? theme.accentColor : theme.accentColor.opacity(0.45))
                            .frame(height: max(4, CGFloat(v) / CGFloat(peak) * 70))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 96, alignment: .bottom)
            Text(s.t("Просмотры за 7 дней", "Views, last 7 days")).font(.system(size: 12)).foregroundStyle(theme.textTertiary)
        }
        .padding(14).frame(maxWidth: .infinity)
        .background(theme.textTertiary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func card(_ icon: String, _ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accentColor)
                Text(title).font(.system(size: 12)).foregroundStyle(theme.textSecondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(value).font(.system(size: 24, weight: .bold)).foregroundStyle(theme.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(note.isEmpty ? " " : note).font(.system(size: 11)).foregroundStyle(theme.textTertiary).lineLimit(2)
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background(theme.textTertiary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func num(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1f", Double(n) / 1_000_000).replacingOccurrences(of: ".0", with: "") + "M" }
        if n >= 10_000 { return String(format: "%.1f", Double(n) / 1000).replacingOccurrences(of: ".0", with: "") + "K" }
        return "\(n)"
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func seconds(_ v: Double) -> String {
        let t = Int(v.rounded())
        return t >= 60 ? "\(t / 60):" + String(format: "%02d", t % 60) : s.t("\(t) сек", "\(t)s")
    }
}
