import SwiftUI
import Combine

// MARK: - Колокольчик: уведомления (лайки, комментарии, подписки…) без всплывающих баннеров

struct ActivityItem: Identifiable, Decodable {
    let id: String
    let kind: String
    let at: Double
    let unread: Bool
    let user: ActivityUser
    let postId: String?
    let storyId: String?
    let text: String?
}

struct ActivityUser: Decodable {
    let id: String
    let name: String
    let username: String?
    let avatar: String?
}

private struct ActivityList: Decodable { let items: [ActivityItem] }
private struct ActivityCount: Decodable { let unread: Int; let kinds: [String: Int]? }

extension ExtrasAPI {
    func activityCount() async -> (unread: Int, kinds: [String: Int])? {
        guard let data = try? await api.request("GET", "/v1/me/activity/count"),
              let c = try? decodeAPI(ActivityCount.self, from: data) else { return nil }
        return (c.unread, c.kinds ?? [:])
    }

    func activity(before: Double? = nil) async -> [ActivityItem]? {
        var path = "/v1/me/activity?limit=40"
        if let before { path += "&before=\(before)" }
        guard let data = try? await api.request("GET", path),
              let list = try? decodeAPI(ActivityList.self, from: data) else { return nil }
        return list.items
    }

    func markActivitySeen() async {
        _ = try? await api.request("POST", "/v1/me/activity/seen")
    }
}

/// Счётчик на колокольчике: опрашивается редко и без шума, баннеров нет
@MainActor
final class ActivityStore: ObservableObject {
    @Published var unread = 0
    /// Плашка у колокольчика «что было»: ♥ 3  💬 1  👤 2 (пусто — не показывается)
    @Published var toast: [ActivityToastItem] = []
    /// Сколько новых уже показали плашкой (на весь запуск): та же пачка второй раз не выскакивает
    private static var toasted = 0

    func refresh(_ extras: ExtrasAPI) async {
        guard let c = await extras.activityCount() else { return }
        unread = c.unread
        // зашли на главную и есть новое (или с прошлого раза прибавилось) — показываем, что именно
        if c.unread > Self.toasted {
            let items = ActivityToastItem.group(c.kinds)
            Self.toasted = c.unread
            if !items.isEmpty { toast = items }
        }
    }

    /// Открыли уведомления — всё прочитано, следующая плашка будет только о новом
    func markSeen() {
        unread = 0
        toast = []
        Self.toasted = 0
    }

    var badgeText: String { unread > 999 ? "999+" : "\(unread)" }
}

/// Одна группа в плашке: значок и сколько
struct ActivityToastItem: Identifiable, Equatable {
    let icon: String
    let count: Int
    var id: String { icon }

    /// Лайки (публикаций, комментариев, историй), комментарии и ответы, подписки и заявки в друзья, репосты
    static func group(_ kinds: [String: Int]) -> [ActivityToastItem] {
        let groups: [(String, [String])] = [
            ("heart.fill", ["like", "comment_like", "story_like"]),
            ("bubble.left.fill", ["comment", "reply"]),
            ("person.fill", ["follow", "friend_request"]),
            ("arrow.2.squarepath", ["repost"]),
        ]
        return groups.compactMap { icon, keys in
            let n = keys.reduce(0) { $0 + (kinds[$1] ?? 0) }
            return n > 0 ? ActivityToastItem(icon: icon, count: n) : nil
        }
    }
}

/// Красная плашка под колокольчиком (как в TikTok): что нового — лайки, комментарии, подписки — и сколько.
/// Сама прячется через несколько секунд, нажатие открывает уведомления
private struct ActivityToast: View {
    let items: [ActivityToastItem]
    static let red = Color(red: 1, green: 0.17, blue: 0.33)

    var body: some View {
        VStack(spacing: 0) {
            Triangle().fill(Self.red).frame(width: 14, height: 7)
            HStack(spacing: 12) {
                ForEach(items) { item in
                    HStack(spacing: 4) {
                        Image(systemName: item.icon).font(.system(size: 15, weight: .bold))
                        Text(item.count > 99 ? "99+" : "\(item.count)").font(.system(size: 16, weight: .bold).monospacedDigit())
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 38)
            .background(Self.red, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Self.red.opacity(0.35), radius: 8, y: 3)
        }
        .fixedSize()
    }

    private struct Triangle: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: r.midX, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                p.closeSubpath()
            }
        }
    }
}

struct BellButton: View {
    @ObservedObject var store: ActivityStore
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var shown: [ActivityToastItem] = []

    var body: some View {
        bell
            .overlay(alignment: .top) {
                if !shown.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { shown = [] }
                        action()
                    } label: { ActivityToast(items: shown) }
                    .buttonStyle(PressStyle())
                    .offset(y: 42)
                    .transition(.scale(scale: 0.5, anchor: .top).combined(with: .opacity))
                }
            }
            .zIndex(shown.isEmpty ? 0 : 20)
            .onChange(of: store.toast) { _, items in present(items) }
            .onAppear { present(store.toast) }
    }

    private func present(_ items: [ActivityToastItem]) {
        guard !items.isEmpty else { return }
        store.toast = []
        Haptics.impact(.light)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.7)) { shown = items }
        let current = items
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            guard shown == current else { return }
            withAnimation(.easeOut(duration: 0.25)) { shown = [] }
        }
    }

    private var bell: some View {
        Button(action: action) {
            Image(systemName: "bell")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(theme.text)
                .frame(width: 40, height: 40)
                .overlay(alignment: .topTrailing) {
                    if store.unread > 0 {
                        Text(store.unread >= 999 ? "999+" : "\(store.unread)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 5).frame(minWidth: 17, minHeight: 17)
                            .background(Color.red, in: Capsule())
                            .overlay(Capsule().stroke(theme.sheet, lineWidth: 1.5))
                            .offset(x: 6, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

struct ActivityView: View {
    @ObservedObject var store: ActivityStore
    let onOpenUser: (Author) -> Void

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss

    @State private var items: [ActivityItem] = []
    @State private var loaded = false
    @State private var loadingMore = false
    @State private var reachedEnd = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(s.t("Уведомления", "Notifications"))
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(theme.text)
                Spacer()
                Button(s.t("Готово", "Done")) { dismiss() }
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.accentColor)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 16).padding(.top, 8)

            if loaded && items.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "bell.slash").font(.system(size: 34)).foregroundStyle(theme.textSecondary)
                    Text(s.t("Пока тихо", "Nothing yet")).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                    Text(s.t("Лайки, комментарии и подписки появятся здесь", "Likes, comments and follows will show up here"))
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 30)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            row(item)
                                .onAppear { if item.id == items.last?.id { Task { await more() } } }
                        }
                        if loadingMore { ProgressView().padding(16) }
                    }
                }
            }
        }
        .background(theme.sheet.ignoresSafeArea())
        .task {
            await load()
            await session.extras.markActivitySeen()
            store.markSeen()
        }
    }

    private func load() async {
        if let list = await session.extras.activity() {
            items = list
            reachedEnd = list.count < 40
        }
        loaded = true
    }

    private func more() async {
        guard !loadingMore, !reachedEnd, let last = items.last else { return }
        loadingMore = true
        if let list = await session.extras.activity(before: last.at) {
            let known = Set(items.map(\.id))
            items += list.filter { !known.contains($0.id) }
            reachedEnd = list.count < 40
        }
        loadingMore = false
    }

    private func title(_ i: ActivityItem) -> String {
        switch i.kind {
        case "like": return s.t("оценил(а) вашу публикацию", "liked your post")
        case "comment": return s.t("прокомментировал(а) вашу публикацию", "commented on your post")
        case "reply": return s.t("ответил(а) на ваш комментарий", "replied to your comment")
        case "comment_like": return s.t("оценил(а) ваш комментарий", "liked your comment")
        case "follow": return s.t("подписался(-ась) на вас", "started following you")
        case "friend_request": return s.t("хочет добавить вас в друзья", "sent you a friend request")
        case "story_like": return s.t("оценил(а) вашу историю", "liked your story")
        case "repost": return s.t("сделал(а) репост", "reposted your post")
        default: return ""
        }
    }

    private func icon(_ kind: String) -> (String, Color) {
        switch kind {
        case "like", "comment_like", "story_like": return ("heart.fill", Color(red: 1, green: 0.3, blue: 0.4))
        case "comment", "reply": return ("bubble.left.fill", Color(red: 0.3, green: 0.6, blue: 1))
        case "repost": return ("arrow.2.squarepath", Color(red: 0.3, green: 0.8, blue: 0.5))
        default: return ("person.fill.badge.plus", Color(red: 0.6, green: 0.45, blue: 1))
        }
    }

    private func ago(_ t: Double) -> String {
        let m = Int(Date().timeIntervalSince1970 - t) / 60
        if m < 1 { return s.t("сейчас", "now") }
        if m < 60 { return s.t("\(m) мин", "\(m)m") }
        if m < 60 * 24 { return s.t("\(m / 60) ч", "\(m / 60)h") }
        if m < 60 * 24 * 7 { return s.t("\(m / 1440) дн", "\(m / 1440)d") }
        return FormatterCache.format(Date(timeIntervalSince1970: t), "d MMM",
                                     locale: Locale(identifier: lang == .ru ? "ru_RU" : "en_US"))
    }

    private func row(_ i: ActivityItem) -> some View {
        let (sym, tint) = icon(i.kind)
        return Button {
            dismiss()
            onOpenUser(Author(id: i.user.id, name: i.user.name, username: i.user.username, avatarID: i.user.avatar))
        } label: {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(name: i.user.name, size: 46, avatarID: i.user.avatar)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: sym).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 19, height: 19).background(tint, in: Circle())
                            .overlay(Circle().stroke(theme.sheet, lineWidth: 1.5)).offset(x: 3, y: 3)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    (Text(i.user.name).fontWeight(.semibold) + Text(" " + title(i)))
                        .font(.system(size: 15)).foregroundStyle(theme.text)
                        .multilineTextAlignment(.leading)
                    if let t = i.text, !t.isEmpty {
                        Text(t).font(.system(size: 14)).foregroundStyle(theme.textSecondary).lineLimit(2)
                    }
                    Text(ago(i.at)).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: 0)
                if i.unread { Circle().fill(Color.red).frame(width: 8, height: 8).padding(.top, 8) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(i.unread ? theme.accentColor.opacity(0.07) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
