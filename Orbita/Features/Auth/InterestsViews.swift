import SwiftUI

// MARK: - Каталог интересов (id совпадают с темами на сервере)

struct Interest: Identifiable, Hashable {
    let id: String
    let emoji: String
    let ru: String
    let en: String
}

enum InterestCatalog {
    static let maxCount = 10

    static let all: [Interest] = [
        Interest(id: "music", emoji: "🎧", ru: "Музыка", en: "Music"),
        Interest(id: "movies", emoji: "🎬", ru: "Кино и сериалы", en: "Movies & series"),
        Interest(id: "games", emoji: "🎮", ru: "Игры", en: "Games"),
        Interest(id: "sport", emoji: "⚽️", ru: "Спорт", en: "Sports"),
        Interest(id: "tech", emoji: "💻", ru: "Технологии", en: "Tech"),
        Interest(id: "travel", emoji: "✈️", ru: "Путешествия", en: "Travel"),
        Interest(id: "food", emoji: "🍕", ru: "Еда и рецепты", en: "Food"),
        Interest(id: "art", emoji: "🎨", ru: "Искусство и дизайн", en: "Art & design"),
        Interest(id: "science", emoji: "🔭", ru: "Наука и космос", en: "Science & space"),
        Interest(id: "books", emoji: "📚", ru: "Книги", en: "Books"),
        Interest(id: "fashion", emoji: "👗", ru: "Мода и стиль", en: "Fashion"),
        Interest(id: "cars", emoji: "🏎", ru: "Авто и мото", en: "Cars & bikes"),
        Interest(id: "animals", emoji: "🐾", ru: "Животные", en: "Animals"),
        Interest(id: "humor", emoji: "😂", ru: "Юмор и мемы", en: "Humor & memes"),
        Interest(id: "photo", emoji: "📷", ru: "Фотография", en: "Photography"),
        Interest(id: "business", emoji: "💼", ru: "Бизнес и финансы", en: "Business"),
        Interest(id: "education", emoji: "🎓", ru: "Учёба и языки", en: "Learning"),
        Interest(id: "health", emoji: "🧘", ru: "Здоровье и йога", en: "Health & yoga"),
        Interest(id: "nature", emoji: "🏔", ru: "Природа", en: "Nature"),
        Interest(id: "diy", emoji: "🛠", ru: "Своими руками", en: "DIY"),
        Interest(id: "news", emoji: "📰", ru: "Новости", en: "News"),
        Interest(id: "history", emoji: "🏛", ru: "История", en: "History"),
        Interest(id: "crypto", emoji: "🪙", ru: "Крипто", en: "Crypto"),
        Interest(id: "dance", emoji: "💃", ru: "Танцы", en: "Dance"),
    ]
}

/// Выбранные интересы лежат на телефоне и отправляются на сервер (для ленты «Для вас»)
enum InterestsStore {
    private static func key(_ user: String) -> String { "interests.\(user.lowercased())" }
    private static func askedKey(_ user: String) -> String { "interests.asked.\(user.lowercased())" }

    static func load(_ user: String) -> [String] {
        (UserDefaults.standard.array(forKey: key(user)) as? [String]) ?? []
    }

    static func hasAnswered(_ user: String) -> Bool {
        UserDefaults.standard.bool(forKey: askedKey(user))
    }

    static func save(_ topics: [String], user: String) {
        UserDefaults.standard.set(topics, forKey: key(user))
        UserDefaults.standard.set(true, forKey: askedKey(user))
    }
}

// MARK: - Раскладка «чипсами» с переносом строк

struct ChipFlow: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

// MARK: - Сетка выбора

struct InterestsPicker: View {
    @Binding var selection: Set<String>
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        ChipFlow(spacing: 10) {
            ForEach(InterestCatalog.all) { item in
                let on = selection.contains(item.id)
                Button { toggle(item.id) } label: {
                    HStack(spacing: 7) {
                        Text(item.emoji).font(.system(size: 17))
                        Text(lang == .ru ? item.ru : item.en)
                            .font(.system(size: 16, weight: .medium))
                    }
                    .foregroundStyle(on ? Color.white : theme.text)
                    .padding(.horizontal, 15).frame(height: 44)
                    .background {
                        Capsule().fill(on ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.surface))
                    }
                    .overlay(Capsule().stroke(on ? Color.clear : theme.stroke, lineWidth: 1))
                    .shadow(color: on ? theme.accentColor.opacity(0.4) : .clear, radius: 8, y: 3)
                    .scaleEffect(on ? 1.03 : 1)
                }
                .buttonStyle(.plain)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
            }
        }
        .padding(.horizontal, 20)
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
            Haptics.select()
        } else if selection.count < InterestCatalog.maxCount {
            selection.insert(id)
            Haptics.impact(.light)
        } else {
            Haptics.notify(.warning)
        }
    }
}

// MARK: - Шаг регистрации

struct InterestsStepView: View {
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var selection: Set<String> = []

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(s.t("Что вам интересно?", "What are you into?"))
                    .font(.system(size: 28, weight: .bold)).foregroundStyle(theme.text)
                Text(s.t("Выберите темы — соберём вашу ленту. До \(InterestCatalog.maxCount), можно хоть одну или пропустить.",
                         "Pick topics to shape your feed. Up to \(InterestCatalog.maxCount) — even just one, or skip."))
                    .font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 28)
            }
            .padding(.top, 64).padding(.bottom, 18)

            ScrollView {
                InterestsPicker(selection: $selection).padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 4) {
                PrimaryButton(title: selection.isEmpty ? s.t("Выберите хотя бы одну", "Pick at least one")
                                                       : s.t("Продолжить · \(selection.count)", "Continue · \(selection.count)"),
                              enabled: !selection.isEmpty) {
                    flow.finishInterests(Array(selection))
                }
                TextActionButton(title: s.skip) { flow.finishInterests([]) }
            }
            .padding(.bottom, 10)
        }
    }
}

// MARK: - Экран в настройках

struct InterestsScreen: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var selection: Set<String> = []
    @State private var loaded = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 16) {
            Text(s.t("Эти темы влияют на ленту «Для вас». Выбрано \(selection.count) из \(InterestCatalog.maxCount).",
                     "These topics shape your For You feed. \(selection.count) of \(InterestCatalog.maxCount) selected."))
                .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 28)
            InterestsPicker(selection: $selection)
            TasteSection()
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            selection = Set(InterestsStore.load(session.userID))
        }
        .onChange(of: selection) { _, new in
            guard loaded else { return }
            InterestsStore.save(Array(new), user: session.userID)
            Task { await session.pushInterests(Array(new)) }
        }
    }
}


// MARK: - «Мой вкус»: что нравилось раньше и что нравится сейчас

/// Обобщение по действиям: сколько смотрел, лайкал, комментировал и пересылал.
/// Не зависит от выбранных интересов — смена интересов вкус не стирает.
struct TasteSection: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var info: TasteInfo?
    @State private var confirmReset = false

    private var s: Strings { Strings(lang: lang) }

    private func title(_ id: String) -> String {
        guard let i = InterestCatalog.all.first(where: { $0.id == id }) else { return id }
        return i.emoji + " " + (lang == .ru ? i.ru : i.en)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(s.t("Мой вкус", "My taste").uppercased())
                .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                .padding(.leading, 4)

            if let info {
                Toggle(isOn: Binding(get: { info.enabled }, set: { on in
                    Task { self.info = await session.extras.setTaste(enabled: on) ?? self.info; await session.feed.load() }
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.t("Учитывать мои действия", "Learn from my activity")).font(.system(size: 16, weight: .medium)).foregroundStyle(theme.text)
                        Text(s.t("Просмотры, лайки, комментарии и пересылки улучшают ленту «Для вас».",
                                 "Views, likes, comments and shares improve your For You feed."))
                            .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    }
                }
                .tint(theme.accentColor)
                .padding(14).card(theme, radius: 16)

                if info.enabled {
                    statsRow(info.stats)
                    if info.long.isEmpty && info.recent.isEmpty {
                        Text(s.t("Пока мало данных — смотрите и лайкайте, и лента подстроится.",
                                 "Not enough data yet — watch and like posts and the feed will adapt."))
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary).padding(.horizontal, 4)
                    } else {
                        bars(s.t("Сейчас", "Now"), info.recent)
                        bars(s.t("Раньше", "Before"), info.long)
                        trend(info)
                    }
                    Button(role: .destructive) { confirmReset = true } label: {
                        Text(s.t("Сбросить мой вкус", "Reset my taste"))
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(theme.danger)
                            .frame(maxWidth: .infinity).frame(height: 44).card(theme, radius: 14)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 20)
        .task { info = await session.extras.taste() }
        .confirmationDialog(s.t("Сбросить накопленный вкус?", "Reset learned taste?"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button(s.t("Сбросить", "Reset"), role: .destructive) {
                Task { info = await session.extras.resetTaste() ?? info; await session.feed.load() }
            }
            Button(s.cancel, role: .cancel) {}
        } message: {
            Text(s.t("Выбранные интересы останутся.", "Your selected interests stay."))
        }
    }

    private func statsRow(_ st: TasteStats) -> some View {
        let minutes = st.watchMs / 60000
        return HStack(spacing: 0) {
            stat("eye", "\(st.views)", s.t("просмотров", "views"))
            stat("heart", "\(st.likes)", s.t("лайков", "likes"))
            stat("bubble.left", "\(st.comments)", s.t("коммент.", "comments"))
            stat("arrowshape.turn.up.right", "\(st.shares)", s.t("пересылок", "shares"))
            stat("clock", "\(minutes)", s.t("мин", "min"))
        }
        .padding(.vertical, 12).card(theme, radius: 16)
    }

    private func stat(_ icon: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(theme.accentColor)
            Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit()).foregroundStyle(theme.text)
            Text(label).font(.system(size: 10)).foregroundStyle(theme.textSecondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private func bars(_ heading: String, _ list: [TasteTopic]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
            if list.isEmpty {
                Text("—").foregroundStyle(theme.textTertiary)
            }
            ForEach(list.prefix(5)) { t in
                HStack(spacing: 10) {
                    Text(title(t.topic)).font(.system(size: 14)).foregroundStyle(theme.text)
                        .frame(width: 150, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        Capsule().fill(theme.accentColor.opacity(0.18))
                            .overlay(alignment: .leading) {
                                Capsule().fill(theme.accent).frame(width: max(6, g.size.width * min(1, t.score)))
                            }
                    }
                    .frame(height: 8)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).card(theme, radius: 16)
    }

    @ViewBuilder
    private func trend(_ info: TasteInfo) -> some View {
        if !info.rising.isEmpty || !info.fading.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !info.rising.isEmpty {
                    Label(s.t("Всё больше: ", "Rising: ") + info.rising.map(title).joined(separator: ", "), systemImage: "arrow.up.right")
                        .foregroundStyle(Color.green)
                }
                if !info.fading.isEmpty {
                    Label(s.t("Реже, чем раньше: ", "Fading: ") + info.fading.map(title).joined(separator: ", "), systemImage: "arrow.down.right")
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .font(.system(size: 13))
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).card(theme, radius: 16)
        }
    }
}
