import SwiftUI
import Combine

// MARK: - Продвижение шортса (как в Instagram / VK / Avito)
// Три способа: пакет просмотров, бюджет по дням, «в топ» на 1/3/7 дней. Цель и аудитория — по желанию.
// Зрители пометку не видят: ролик чаще попадается в «Рекомендациях» и выше в поиске.
// Результаты — в статистике ролика. Сейчас тестовый период: бесплатно, цена показывается.

struct PromoOptions: Decodable {
    struct Country: Decodable, Hashable { let code: String; let name: String }
    let free: Bool
    let cpm: Int
    let topDay: Int
    let packs: [Int]
    let countries: [Country]
    let interests: [String]
}

struct PromoTargeting: Codable, Equatable {
    var ageMin: Int?
    var ageMax: Int?
    var gender: String?
    var countries: [String]?
    var cities: [String]?
    var interests: [String]?

    var json: [String: Any] {
        var d: [String: Any] = [:]
        if let ageMin, let ageMax { d["age_min"] = ageMin; d["age_max"] = ageMax }
        if let gender { d["gender"] = gender }
        if let countries, !countries.isEmpty { d["countries"] = countries }
        if let cities, !cities.isEmpty { d["cities"] = cities }
        if let interests, !interests.isEmpty { d["interests"] = interests }
        return d
    }
    var isAuto: Bool { json.isEmpty }
}

struct Promotion: Decodable, Identifiable, Equatable {
    let id: String
    let postId: String
    let kind: String
    let goal: String
    let status: String
    let target: Int?
    let days: Int
    let daily: Int
    let targeting: PromoTargeting
    let price: Int
    let spent: Int
    let free: Bool
    let createdAt: Double
    let endsAt: Double
    let impressions: Int
    let views: Int
    let likes: Int
    let follows: Int
    let dailyShows: [Int]
}

extension ExtrasAPI {
    func promoOptions() async -> PromoOptions? {
        guard let d = try? await api.request("GET", "/v1/promo/options") else { return nil }
        return try? decodeAPI(PromoOptions.self, from: d)
    }

    func promote(postID: String, body: [String: Any]) async throws -> Promotion {
        struct Box: Decodable { let promotion: Promotion }
        let d = try await api.request("POST", "/v1/posts/\(postID)/promote", body: ServerAPI.json(body))
        return try decodeAPI(Box.self, from: d).promotion
    }

    func promotions(postID: String) async -> [Promotion] {
        struct Box: Decodable { let promotions: [Promotion] }
        guard let d = try? await api.request("GET", "/v1/posts/\(postID)/promotions") else { return [] }
        return (try? decodeAPI(Box.self, from: d))?.promotions ?? []
    }

    func promotionAction(_ id: String, _ action: String) async -> Promotion? {
        struct Box: Decodable { let promotion: Promotion }
        guard let d = try? await api.request("POST", "/v1/promotions/\(id)/\(action)") else { return nil }
        return (try? decodeAPI(Box.self, from: d))?.promotion
    }
}

enum PromoText {
    static func interest(_ key: String, _ s: Strings) -> String {
        let ru: [String: (String, String)] = [
            "music": ("Музыка", "Music"), "movies": ("Кино", "Movies"), "games": ("Игры", "Games"), "sport": ("Спорт", "Sport"),
            "tech": ("Технологии", "Tech"), "travel": ("Путешествия", "Travel"), "food": ("Еда", "Food"), "art": ("Искусство", "Art"),
            "science": ("Наука", "Science"), "books": ("Книги", "Books"), "fashion": ("Мода", "Fashion"), "cars": ("Авто", "Cars"),
            "animals": ("Животные", "Animals"), "humor": ("Юмор", "Humor"), "photo": ("Фото", "Photo"), "business": ("Бизнес", "Business"),
            "education": ("Учёба", "Education"), "health": ("Здоровье", "Health"), "nature": ("Природа", "Nature"),
            "diy": ("Своими руками", "DIY"), "news": ("Новости", "News"), "history": ("История", "History"),
            "crypto": ("Крипта", "Crypto"), "dance": ("Танцы", "Dance")]
        guard let v = ru[key] else { return key }
        return s.t(v.0, v.1)
    }

    static func goal(_ g: String, _ s: Strings) -> String {
        switch g {
        case "followers": return s.t("Подписчики", "Followers")
        case "profile": return s.t("Переходы в профиль", "Profile visits")
        default: return s.t("Просмотры", "Views")
        }
    }

    static func num(_ n: Int) -> String {
        n >= 1000 ? String(format: n >= 10000 ? "%.0f" : "%.1f", Double(n) / 1000).replacingOccurrences(of: ".", with: ",") + " тыс." : "\(n)"
    }
}

// MARK: - Запуск продвижения

struct PromoteSheet: View {
    let postID: String
    var onLaunched: (Promotion) -> Void = { _ in }

    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    private enum Mode: String, CaseIterable { case views, budget, top }

    @State private var options: PromoOptions?
    @State private var post: Post?
    @State private var mode: Mode = .views
    @State private var goal = "views"
    @State private var pack = 5000
    @State private var daily: Double = 300
    @State private var days: Double = 5
    @State private var topDays = 3
    @State private var customAudience = false
    @State private var ageMin = 18
    @State private var ageMax = 45
    @State private var gender = ""
    @State private var countries: Set<String> = []
    @State private var cities: [String] = []
    @State private var cityDraft = ""
    @State private var interests: Set<String> = []
    @State private var launching = false
    @State private var errorText: String?
    @State private var launched: Promotion?

    private var s: Strings { Strings(lang: lang) }
    private var cpm: Int { options?.cpm ?? 150 }

    private var price: Int {
        switch mode {
        case .views: return Int((Double(pack) * Double(cpm) / 1000).rounded())
        case .budget: return Int(daily) * Int(days)
        case .top: return (options?.topDay ?? 199) * topDays
        }
    }

    /// Примерный охват — вилкой, как в Instagram
    private var reach: (Int, Int) {
        var base: Int
        switch mode {
        case .views: base = pack
        case .budget: base = Int(daily * 1000 / Double(cpm) * days)
        case .top: base = 2500 * topDays
        }
        if customAudience { base = Int(Double(base) * 0.85) }      // узкая аудитория — немного меньше
        return (Int(Double(base) * 0.9), Int(Double(base) * 1.3))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.sheet.ignoresSafeArea()
                if let launched {
                    successView(launched)
                } else {
                    form
                }
            }
            .navigationTitle(s.t("Продвижение", "Promote"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(launched == nil ? s.cancel : s.close) { dismiss() } } }
        }
        .task {
            options = await session.extras.promoOptions()
            post = try? await session.feedRepo.post(id: postID)
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                section(s.t("ЦЕЛЬ", "GOAL")) {
                    HStack(spacing: 8) {
                        goalCard("views", "eye.fill", s.t("Просмотры", "Views"), s.t("Больше людей увидят", "More people see it"))
                        goalCard("followers", "person.badge.plus", s.t("Подписчики", "Followers"), s.t("Тем, кто ещё не подписан", "Only non-followers"))
                        goalCard("profile", "person.crop.square", s.t("Профиль", "Profile"), s.t("Переходы к вам", "Visits to you"))
                    }
                }
                section(s.t("ФОРМАТ", "FORMAT")) {
                    Picker("", selection: $mode.animation(.spring(response: 0.35, dampingFraction: 0.85))) {
                        Text(s.t("Просмотры", "Views")).tag(Mode.views)
                        Text(s.t("Бюджет", "Budget")).tag(Mode.budget)
                        Text(s.t("В топ", "Top")).tag(Mode.top)
                    }
                    .pickerStyle(.segmented)
                    modeBody.padding(.top, 6)
                }
                audience
                summary
                if let errorText {
                    Text(errorText).font(.system(size: 14)).foregroundStyle(theme.danger)
                }
                launchButton
            }
            .padding(16)
            .padding(.bottom, 20)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                if let m = post?.media.first { RemoteImage(id: m.thumbID ?? m.id, maxPixel: 300) } else { theme.surface }
            }
            .frame(width: 64, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(s.t("Покажем ваш ролик тем, кому он понравится", "We'll show your video to people who'll like it"))
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                Text(s.t("Чаще в «Рекомендациях» и выше в поиске. Зрители не видят, что ролик продвигается.",
                         "More often in “For you” and higher in search. Viewers don't see it's promoted."))
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textSecondary)
            content()
        }
    }

    private func goalCard(_ id: String, _ icon: String, _ title: String, _ sub: String) -> some View {
        let on = goal == id
        return Button {
            Haptics.select()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { goal = id }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(on ? .white : theme.accentColor)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(on ? .white : theme.text)
                Text(sub).font(.system(size: 11)).foregroundStyle(on ? Color.white.opacity(0.8) : theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(on ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.surface),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }

    @ViewBuilder
    private var modeBody: some View {
        switch mode {
        case .views:
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(options?.packs ?? [1000, 5000, 20000, 50000], id: \.self) { p in
                    let on = pack == p
                    Button {
                        Haptics.select()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pack = p }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("+" + PromoText.num(p)).font(.system(size: 20, weight: .bold)).foregroundStyle(on ? .white : theme.text)
                            Text(s.t("просмотров", "views")).font(.system(size: 12)).foregroundStyle(on ? Color.white.opacity(0.85) : theme.textSecondary)
                            Text("\(Int((Double(p) * Double(cpm) / 1000).rounded())) ₽").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(on ? .white : theme.accentColor)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(on ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.surface),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressStyle())
                }
            }
        case .budget:
            VStack(alignment: .leading, spacing: 14) {
                sliderRow(s.t("В день", "Per day"), "\(Int(daily)) ₽", value: $daily, range: 100...3000, step: 50)
                sliderRow(s.t("Дней", "Days"), "\(Int(days))", value: $days, range: 1...30, step: 1)
            }
        case .top:
            VStack(alignment: .leading, spacing: 8) {
                Text(s.t("Ролик первым в «Рекомендациях» у подходящих людей и выше в поиске", "First in “For you” for matching people and higher in search"))
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                HStack(spacing: 8) {
                    ForEach([1, 3, 7], id: \.self) { d in
                        let on = topDays == d
                        Button {
                            Haptics.select()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { topDays = d }
                        } label: {
                            VStack(spacing: 2) {
                                Text(d == 1 ? s.t("1 день", "1 day") : s.t("\(d) дней", "\(d) days")).font(.system(size: 15, weight: .bold))
                                Text("\((options?.topDay ?? 199) * d) ₽").font(.system(size: 12))
                            }
                            .foregroundStyle(on ? .white : theme.text)
                            .frame(maxWidth: .infinity).frame(height: 56)
                            .background(on ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.surface),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(PressStyle())
                    }
                }
            }
        }
    }

    private func sliderRow(_ title: String, _ value: String, value v: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 15)).foregroundStyle(theme.text)
                Spacer()
                Text(value).font(.system(size: 17, weight: .bold).monospacedDigit()).foregroundStyle(theme.text)
                    .contentTransition(.numericText())
            }
            Slider(value: v, in: range, step: step).tint(theme.accentColor)
                .onChange(of: v.wrappedValue) { _, _ in Haptics.select() }
        }
    }

    // MARK: Аудитория

    private var audience: some View {
        section(s.t("АУДИТОРИЯ", "AUDIENCE")) {
            Picker("", selection: $customAudience.animation(.spring(response: 0.35, dampingFraction: 0.85))) {
                Text(s.t("Автоматически", "Automatic")).tag(false)
                Text(s.t("Своя", "Custom")).tag(true)
            }
            .pickerStyle(.segmented)
            if !customAudience {
                Label(s.t("Покажем людям, похожим на ваших зрителей и подписчиков", "We'll show it to people similar to your viewers"),
                      systemImage: "sparkles")
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.t("Возраст: \(ageMin)–\(ageMax == 65 ? "65+" : String(ageMax))", "Age: \(ageMin)–\(ageMax == 65 ? "65+" : String(ageMax))"))
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(theme.text)
                        HStack {
                            Stepper("", value: $ageMin, in: 13...max(13, ageMax - 1)).labelsHidden()
                            Spacer()
                            Stepper("", value: $ageMax, in: min(65, ageMin + 1)...65).labelsHidden()
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.t("Пол", "Gender")).font(.system(size: 15, weight: .medium)).foregroundStyle(theme.text)
                        Picker("", selection: $gender) {
                            Text(s.t("Все", "All")).tag("")
                            Text(s.t("Мужчины", "Men")).tag("m")
                            Text(s.t("Женщины", "Women")).tag("f")
                        }
                        .pickerStyle(.segmented)
                    }
                    chipsBlock(s.t("Страны", "Countries"), items: (options?.countries ?? []).map { ($0.code, $0.name) }, selected: $countries)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.t("Города", "Cities")).font(.system(size: 15, weight: .medium)).foregroundStyle(theme.text)
                        HStack(spacing: 8) {
                            TextField(s.t("Например, Москва", "E.g. London"), text: $cityDraft)
                                .padding(.horizontal, 12).frame(height: 40)
                                .background(theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .submitLabel(.done)
                                .onSubmit { addCity() }
                            Button(action: addCity) {
                                Image(systemName: "plus").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 40, height: 40).background(theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(PressStyle())
                        }
                        FlowChips(items: cities, tint: theme.accentColor) { c in cities.removeAll { $0 == c } }
                    }
                    chipsBlock(s.t("Интересы", "Interests"),
                               items: (options?.interests ?? []).map { ($0, PromoText.interest($0, s)) }, selected: $interests)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func addCity() {
        let c = cityDraft.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty, !cities.contains(c), cities.count < 10 else { return }
        Haptics.select()
        cities.append(c)
        cityDraft = ""
    }

    private func chipsBlock(_ title: String, items: [(String, String)], selected: Binding<Set<String>>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(theme.text)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items, id: \.0) { key, name in
                        let on = selected.wrappedValue.contains(key)
                        Button {
                            Haptics.select()
                            if on { selected.wrappedValue.remove(key) } else { selected.wrappedValue.insert(key) }
                        } label: {
                            Text(name).font(.system(size: 14, weight: .medium))
                                .foregroundStyle(on ? .white : theme.text)
                                .padding(.horizontal, 12).frame(height: 32)
                                .background(on ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.surface), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Итог и запуск

    private var summary: some View {
        let r = reach
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(s.t("Примерный охват", "Estimated reach")).font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                Spacer()
                Text(PromoText.num(r.0) + " – " + PromoText.num(r.1)).font(.system(size: 17, weight: .bold)).foregroundStyle(theme.text)
                    .contentTransition(.numericText())
            }
            HStack {
                Text(s.t("Стоимость", "Cost")).font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                Spacer()
                if options?.free ?? true {
                    Text("\(price) ₽").font(.system(size: 15)).strikethrough().foregroundStyle(theme.textTertiary)
                    Text(s.t("Бесплатно", "Free")).font(.system(size: 17, weight: .bold)).foregroundStyle(Color(red: 0.2, green: 0.75, blue: 0.45))
                } else {
                    Text("\(price) ₽").font(.system(size: 17, weight: .bold)).foregroundStyle(theme.text)
                }
            }
            if options?.free ?? true {
                Text(s.t("Тестовый период: продвижение пока бесплатное.", "Test period: promotion is free for now."))
                    .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
            }
        }
        .padding(14)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: price)
    }

    private var launchButton: some View {
        Button { launch() } label: {
            HStack(spacing: 8) {
                if launching { ProgressView().tint(.white) } else { Image(systemName: "flame.fill") }
                Text(s.t("Запустить продвижение", "Start promotion")).font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 54)
            .background(LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.3), Color(red: 1, green: 0.17, blue: 0.45)],
                                       startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color(red: 1, green: 0.2, blue: 0.4).opacity(0.35), radius: 12, y: 5)
        }
        .buttonStyle(PressStyle())
        .disabled(launching)
    }

    private func launch() {
        var body: [String: Any] = ["kind": mode.rawValue, "goal": goal]
        switch mode {
        case .views: body["views"] = pack
        case .budget: body["daily"] = Int(daily); body["days"] = Int(days)
        case .top: body["days"] = topDays
        }
        if customAudience {
            let t = PromoTargeting(ageMin: ageMin, ageMax: ageMax, gender: gender.isEmpty ? nil : gender,
                                   countries: Array(countries), cities: cities, interests: Array(interests))
            body["targeting"] = t.json
        }
        launching = true
        errorText = nil
        Task {
            defer { launching = false }
            do {
                let p = try await session.extras.promote(postID: postID, body: body)
                if p.status == "rejected" {
                    errorText = s.t("Этот ролик нельзя продвигать: он нарушает правила (18+, жалобы или запрещённые слова).",
                                    "This video can't be promoted: it breaks the rules.")
                    Haptics.notify(.error)
                    return
                }
                Haptics.notify(.success)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { launched = p }
                onLaunched(p)
            } catch {
                errorText = s.t("Не удалось запустить. Попробуйте ещё раз.", "Couldn't start. Try again.")
            }
        }
    }

    private func successView(_ p: Promotion) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "flame.fill").font(.system(size: 44)).foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(LinearGradient(colors: [Color(red: 1, green: 0.4, blue: 0.3), Color(red: 1, green: 0.15, blue: 0.45)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                .shadow(color: Color(red: 1, green: 0.25, blue: 0.4).opacity(0.45), radius: 20, y: 8)
                .symbolEffect(.bounce, value: launched != nil)
            Text(s.t("Продвижение запущено", "Promotion started")).font(.system(size: 22, weight: .bold)).foregroundStyle(theme.text)
            Text(s.t("Результаты — в статистике ролика: показы, просмотры, лайки и новые подписчики.",
                     "Results are in the video's statistics: impressions, views, likes and new followers."))
                .font(.system(size: 15)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center).padding(.horizontal, 30)
            Spacer()
            Button { dismiss() } label: {
                Text(s.t("Готово", "Done")).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52).background(theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressStyle())
            .padding(.horizontal, 16).padding(.bottom, 20)
        }
    }
}

/// Чипы, которые переносятся на новую строку (города), с крестиком
struct FlowChips: View {
    let items: [String]
    let tint: Color
    var onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { c in
                    Button { Haptics.select(); onRemove(c) } label: {
                        HStack(spacing: 5) {
                            Text(c).font(.system(size: 14, weight: .medium))
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(tint, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Результаты в статистике ролика

struct PromotionsBlock: View {
    let postID: String

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var list: [Promotion] = []
    @State private var loaded = false
    @State private var showPromote = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(red: 1, green: 0.3, blue: 0.35))
                Text(s.t("Продвижение", "Promotion")).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                Spacer()
            }
            if loaded && list.isEmpty {
                Text(s.t("Покажите ролик большему числу людей: чаще в «Рекомендациях» и выше в поиске.",
                         "Show your video to more people: more often in “For you” and higher in search."))
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            }
            ForEach(list) { p in promoCard(p) }
            Button { showPromote = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "flame.fill")
                    Text(list.isEmpty ? s.t("Продвинуть ролик", "Promote video") : s.t("Новое продвижение", "New promotion"))
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 48)
                .background(LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.3), Color(red: 1, green: 0.17, blue: 0.45)],
                                           startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PressStyle())
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.textTertiary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .task { await reload() }
        .sheet(isPresented: $showPromote, onDismiss: { Task { await reload() } }) {
            PromoteSheet(postID: postID)
                .environmentObject(session)
                .environment(\.theme, theme).environment(\.lang, lang)
                .presentationDetents([.large])
                .sheetStyle(theme)
        }
    }

    private func reload() async {
        list = await session.extras.promotions(postID: postID)
        loaded = true
    }

    private func statusInfo(_ st: String) -> (String, Color) {
        switch st {
        case "active": return (s.t("Идёт", "Running"), Color(red: 0.2, green: 0.75, blue: 0.45))
        case "paused": return (s.t("Пауза", "Paused"), .orange)
        case "rejected": return (s.t("Отклонено", "Rejected"), theme.danger)
        case "stopped": return (s.t("Остановлено", "Stopped"), theme.textTertiary)
        default: return (s.t("Завершено", "Finished"), theme.textTertiary)
        }
    }

    private func promoCard(_ p: Promotion) -> some View {
        let st = statusInfo(p.status)
        let progress = p.target.map { min(1, Double(p.impressions) / Double(max(1, $0))) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(st.0).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).frame(height: 22).background(st.1, in: Capsule())
                Text(kindTitle(p) + " · " + PromoText.goal(p.goal, s)).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.text)
                    .lineLimit(1)
                Spacer()
                Text(p.free ? s.t("бесплатно", "free") : "\(p.spent) / \(p.price) ₽").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            }
            if let progress {
                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.accentColor.opacity(0.15))
                            Capsule().fill(theme.accent).frame(width: g.size.width * progress)
                        }
                    }
                    .frame(height: 6)
                    Text(s.t("Показано \(PromoText.num(p.impressions)) из \(PromoText.num(p.target ?? 0))",
                             "\(PromoText.num(p.impressions)) of \(PromoText.num(p.target ?? 0)) shown"))
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
            }
            HStack(spacing: 0) {
                metric(PromoText.num(p.impressions), s.t("показы", "impressions"))
                metric(PromoText.num(p.views), s.t("просмотры", "views"))
                metric(PromoText.num(p.likes), s.t("лайки", "likes"))
                metric("+" + PromoText.num(p.follows), s.t("подписчики", "followers"))
            }
            miniChart(p.dailyShows)
            if p.status == "active" || p.status == "paused" {
                HStack(spacing: 8) {
                    actionButton(p.status == "active" ? s.t("Пауза", "Pause") : s.t("Продолжить", "Resume"),
                                 p.status == "active" ? "pause.fill" : "play.fill") {
                        await act(p, p.status == "active" ? "pause" : "resume")
                    }
                    actionButton(s.t("Остановить", "Stop"), "stop.fill", danger: true) { await act(p, "stop") }
                }
            }
        }
        .padding(12)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func kindTitle(_ p: Promotion) -> String {
        switch p.kind {
        case "budget": return s.t("Бюджет", "Budget")
        case "top": return s.t("В топе \(p.days) дн.", "Top \(p.days)d")
        default: return s.t("Просмотры", "Views")
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 17, weight: .bold).monospacedDigit()).foregroundStyle(theme.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 11)).foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func miniChart(_ days: [Int]) -> some View {
        let peak = max(1, days.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, v in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(i == days.count - 1 ? theme.accentColor : theme.accentColor.opacity(0.4))
                    .frame(height: max(3, CGFloat(v) / CGFloat(peak) * 34))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 36, alignment: .bottom)
    }

    private func actionButton(_ title: String, _ icon: String, danger: Bool = false, _ run: @escaping () async -> Void) -> some View {
        Button { Haptics.impact(.light); Task { await run() } } label: {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(danger ? theme.danger : theme.text)
                .frame(maxWidth: .infinity).frame(height: 38)
                .background(theme.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }

    private func act(_ p: Promotion, _ action: String) async {
        if let updated = await session.extras.promotionAction(p.id, action), let i = list.firstIndex(where: { $0.id == p.id }) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { list[i] = updated }
        }
    }
}
