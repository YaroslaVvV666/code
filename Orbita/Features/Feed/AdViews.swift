import SwiftUI

// MARK: - Модели рекламы

/// Страница ленты: органические посты + рекламные вставки с позициями (slot — после какого поста показать).
struct FeedPage {
    let posts: [Post]
    let ads: [FeedAd]
}

/// Рекламная карточка в ленте (то, что видит зритель).
struct FeedAd: Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
    let media: MediaItem?
    let link: String
    let cta: String
    let advertiser: Author
    let slot: Int
}

/// Кампания в кабинете рекламодателя.
struct AdCampaign: Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
    let status: String          // pending|active|paused|rejected|depleted
    let pricing: String         // cpm|cpc
    let rateCents: Int
    let budgetCents: Int
    let spentCents: Int
    let impressions: Int
    let clicks: Int
}

/// Черновик новой кампании.
struct AdDraft {
    var title = ""
    var body = ""
    var mediaID: String?
    var link = ""
    var cta = ""
    var pricing = "cpm"
    var rateCents = 5000        // 50 ₽ за 1000 показов / за клик
    var budgetCents = 100000    // 1000 ₽
    var dailyCapCents = 0
    var interests: [String] = []
}

// MARK: - DTO

struct AdDTO: Decodable {
    let adId: String
    let title: String
    let body: String
    let media: MediaDTO?
    let link: String
    let cta: String
    let advertiser: AuthorDTO
    let slot: Int
    var model: FeedAd {
        FeedAd(id: adId, title: title, body: body, media: media?.model,
               link: link, cta: cta, advertiser: advertiser.model, slot: slot)
    }
}

struct AdCampaignDTO: Decodable {
    let adId: String
    let title: String
    let body: String
    let status: String
    let pricing: String
    let rateCents: Int
    let budgetCents: Int
    let spentCents: Int
    let impressions: Int
    let clicks: Int
    var model: AdCampaign {
        AdCampaign(id: adId, title: title, body: body, status: status, pricing: pricing,
                   rateCents: rateCents, budgetCents: budgetCents, spentCents: spentCents,
                   impressions: impressions, clicks: clicks)
    }
}

private struct MyAdsDTO: Decodable { let ads: [AdCampaignDTO]; let balanceCents: Int }
private struct LinkDTO: Decodable { let link: String }
private struct BalanceDTO: Decodable { let balanceCents: Int }

// MARK: - Сетевые вызовы рекламы

extension RemoteFeedRepository {
    func adImpression(id: String) async {
        _ = try? await api.request("POST", "/v1/ads/\(id)/impression")
    }

    func adClick(id: String) async -> String {
        guard let d = try? await api.request("POST", "/v1/ads/\(id)/click") else { return "" }
        return (try? decodeAPI(LinkDTO.self, from: d))?.link ?? ""
    }

    func myAds() async throws -> (ads: [AdCampaign], balanceCents: Int) {
        let d = try await api.request("GET", "/v1/ads/mine")
        let dto = try decodeAPI(MyAdsDTO.self, from: d)
        return (dto.ads.map(\.model), dto.balanceCents)
    }

    func createAd(_ draft: AdDraft) async throws -> AdCampaign {
        var body: [String: Any] = [
            "title": draft.title, "body": draft.body, "pricing": draft.pricing,
            "rate_cents": draft.rateCents, "budget_cents": draft.budgetCents,
            "daily_cap_cents": draft.dailyCapCents, "cta": draft.cta, "link": draft.link,
            "target_interests": draft.interests]
        if let m = draft.mediaID { body["media_id"] = m }
        let d = try await api.request("POST", "/v1/ads", body: ServerAPI.json(body))
        return try decodeAPI(AdCampaignDTO.self, from: d).model
    }

    func setAdPaused(id: String, paused: Bool) async throws {
        _ = try await api.request("POST", "/v1/ads/\(id)/\(paused ? "pause" : "resume")")
    }

    func deleteAd(id: String) async throws {
        _ = try await api.request("DELETE", "/v1/ads/\(id)")
    }

    func topUpAds(amountCents: Int) async throws -> Int {
        let d = try await api.request("POST", "/v1/ads/wallet/topup", body: ServerAPI.json(["amount_cents": amountCents]))
        return try decodeAPI(BalanceDTO.self, from: d).balanceCents
    }
}

// MARK: - Карточка рекламы в ленте

struct AdCardView: View {
    let ad: FeedAd
    var onHide: () -> Void = {}
    var onReport: () -> Void = {}

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.openURL) private var openURL
    @State private var reported = false

    private var s: Strings { Strings(lang: lang) }
    private var repo: RemoteFeedRepository? { session.feedRepo as? RemoteFeedRepository }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AvatarView(name: ad.advertiser.name, size: 38, avatarID: ad.advertiser.avatarID).clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(ad.advertiser.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                    Text(s.t("Реклама", "Sponsored")).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Menu {
                    Button { onHide() } label: { Label(s.t("Скрыть", "Hide"), systemImage: "eye.slash") }
                    Button(role: .destructive) { onReport() } label: { Label(s.t("Пожаловаться", "Report"), systemImage: "exclamationmark.bubble") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.textSecondary).frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, 14)

            if !ad.title.isEmpty {
                Text(ad.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                    .padding(.horizontal, 14)
            }
            if !ad.body.isEmpty {
                Text(ad.body).font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 14)
            }

            if let m = ad.media {
                RemoteImage(id: m.thumbID ?? m.id, fill: true, backdrop: theme.surface)
                    .aspectRatio(max(0.6, min(1.2, CGFloat(m.width) / CGFloat(max(1, m.height)))), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(alignment: .bottomTrailing) {
                        Text(s.t("Реклама", "Ad")).font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.5), in: Capsule()).padding(8)
                    }
            }

            Button(action: openLink) {
                Text(ad.cta.isEmpty ? s.t("Подробнее", "Learn more") : ad.cta)
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(theme.accent, in: Capsule())
            }
            .buttonStyle(PressStyle())
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .padding(.top, 12)
        .contentShape(Rectangle())
        .onTapGesture { openLink() }
        .onAppear {
            // показ засчитывается, когда карточка появилась на экране
            guard !reported, let repo else { return }
            reported = true
            Task { await repo.adImpression(id: ad.id) }
        }
    }

    private func openLink() {
        Haptics.impact(.light)
        guard let repo else { return }
        Task {
            let link = await repo.adClick(id: ad.id)
            let target = link.isEmpty ? ad.link : link
            if let url = URL(string: target) { await MainActor.run { openURL(url) } }
        }
    }
}

// MARK: - Кабинет рекламодателя

struct AdvertiserCabinetView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss

    @State private var ads: [AdCampaign] = []
    @State private var balanceCents = 0
    @State private var loading = true
    @State private var showCreate = false
    @State private var showTopUp = false
    @State private var error: String?

    private var s: Strings { Strings(lang: lang) }
    private var repo: RemoteFeedRepository? { session.feedRepo as? RemoteFeedRepository }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    balanceCard
                    Button { showCreate = true } label: {
                        Label(s.t("Создать рекламу", "Create ad"), systemImage: "plus")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 50).background(theme.accent, in: Capsule())
                    }
                    .buttonStyle(PressStyle())

                    if loading {
                        ProgressView().padding(.top, 30)
                    } else if ads.isEmpty {
                        Text(s.t("Пока нет кампаний", "No campaigns yet"))
                            .font(.system(size: 15)).foregroundStyle(theme.textSecondary).padding(.top, 30)
                    } else {
                        ForEach(ads) { campaignCard($0) }
                    }
                }
                .padding(16)
            }
            .background(theme.sheet.ignoresSafeArea())
            .navigationTitle(s.t("Реклама", "Ads"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(s.t("Закрыть", "Close")) { dismiss() } } }
            .task { await reload() }
            .sheet(isPresented: $showCreate) {
                AdCreateSheet { draft in
                    guard let repo else { return }
                    do { _ = try await repo.createAd(draft); await reload() }
                    catch { self.error = s.t("Не удалось создать", "Couldn't create") }
                }
                .environmentObject(session).environment(\.theme, theme).environment(\.lang, lang)
            }
            .alert(s.t("Пополнить баланс", "Top up"), isPresented: $showTopUp) {
                Button(s.t("1000 ₽", "$10")) { topUp(100000) }
                Button(s.t("5000 ₽", "$50")) { topUp(500000) }
                Button(s.cancel, role: .cancel) {}
            } message: {
                Text(s.t("Демо-пополнение. На проде здесь будет оплата через провайдера.",
                         "Demo top-up. In production this goes through a payment provider."))
            }
        }
    }

    private var balanceCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.t("Баланс", "Balance")).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                Text(rub(balanceCents)).font(.system(size: 24, weight: .bold)).foregroundStyle(theme.text)
            }
            Spacer()
            Button { showTopUp = true } label: {
                Text(s.t("Пополнить", "Top up")).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accentColor)
                    .padding(.horizontal, 16).frame(height: 40).glassCapsule()
            }
            .buttonStyle(.plain)
        }
        .padding(16).card(theme, radius: 18)
    }

    private func campaignCard(_ ad: AdCampaign) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ad.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Spacer()
                Text(statusLabel(ad.status)).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor(ad.status))
                    .padding(.horizontal, 8).frame(height: 22).background(statusColor(ad.status).opacity(0.15), in: Capsule())
            }
            HStack(spacing: 16) {
                stat(s.t("Показы", "Impressions"), "\(ad.impressions)")
                stat(s.t("Клики", "Clicks"), "\(ad.clicks)")
                stat(s.t("Потрачено", "Spent"), rub(ad.spentCents))
                stat(s.t("Бюджет", "Budget"), rub(ad.budgetCents))
            }
            HStack(spacing: 10) {
                if ad.status == "active" {
                    actionButton(s.t("Пауза", "Pause")) { setPaused(ad, true) }
                } else if ad.status == "paused" {
                    actionButton(s.t("Продолжить", "Resume")) { setPaused(ad, false) }
                }
                Spacer()
                Button(role: .destructive) { delete(ad) } label: {
                    Image(systemName: "trash").font(.system(size: 15)).foregroundStyle(theme.danger)
                        .frame(width: 36, height: 32)
                }
            }
        }
        .padding(14).card(theme, radius: 18)
    }

    private func stat(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(theme.text)
            Text(t).font(.system(size: 11)).foregroundStyle(theme.textSecondary)
        }
    }

    private func actionButton(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accentColor)
                .padding(.horizontal, 14).frame(height: 32).glassCapsule()
        }
        .buttonStyle(.plain)
    }

    private func statusLabel(_ st: String) -> String {
        switch st {
        case "active": return s.t("Активна", "Active")
        case "pending": return s.t("На модерации", "In review")
        case "paused": return s.t("Пауза", "Paused")
        case "rejected": return s.t("Отклонена", "Rejected")
        case "depleted": return s.t("Бюджет исчерпан", "Depleted")
        default: return st
        }
    }

    private func statusColor(_ st: String) -> Color {
        switch st {
        case "active": return .green
        case "pending", "paused": return .orange
        case "rejected": return theme.danger
        default: return theme.textSecondary
        }
    }

    private func rub(_ cents: Int) -> String { String(format: "%.2f ₽", Double(cents) / 100) }

    private func reload() async {
        guard let repo else { return }
        loading = true
        if let r = try? await repo.myAds() { ads = r.ads; balanceCents = r.balanceCents }
        loading = false
    }

    private func setPaused(_ ad: AdCampaign, _ paused: Bool) {
        guard let repo else { return }
        Task { try? await repo.setAdPaused(id: ad.id, paused: paused); await reload() }
    }

    private func delete(_ ad: AdCampaign) {
        guard let repo else { return }
        Task { try? await repo.deleteAd(id: ad.id); await reload() }
    }

    private func topUp(_ amount: Int) {
        guard let repo else { return }
        Task { if let b = try? await repo.topUpAds(amountCents: amount) { balanceCents = b } }
    }
}

// MARK: - Создание кампании

struct AdCreateSheet: View {
    var onSave: (AdDraft) async -> Void

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss

    @State private var draft = AdDraft()
    @State private var budgetRub = "1000"
    @State private var rateRub = "50"
    @State private var saving = false

    private var s: Strings { Strings(lang: lang) }
    private var valid: Bool { !draft.title.trimmingCharacters(in: .whitespaces).isEmpty && (Double(budgetRub) ?? 0) > 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section(s.t("Объявление", "Ad")) {
                    TextField(s.t("Заголовок", "Title"), text: $draft.title)
                    TextField(s.t("Текст", "Body"), text: $draft.body, axis: .vertical).lineLimit(1...4)
                    TextField(s.t("Ссылка (https://…)", "Link (https://…)"), text: $draft.link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(s.t("Кнопка (напр. «Купить»)", "Button (e.g. Buy)"), text: $draft.cta)
                }
                Section(s.t("Оплата", "Pricing")) {
                    Picker(s.t("Модель", "Model"), selection: $draft.pricing) {
                        Text(s.t("За показы (CPM)", "Per 1000 views")).tag("cpm")
                        Text(s.t("За клики (CPC)", "Per click")).tag("cpc")
                    }
                    HStack {
                        Text(draft.pricing == "cpm" ? s.t("Ставка за 1000 показов, ₽", "Rate per 1000, $") : s.t("Ставка за клик, ₽", "Rate per click, $"))
                        Spacer()
                        TextField("50", text: $rateRub).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                    }
                    HStack {
                        Text(s.t("Бюджет, ₽", "Budget, $"))
                        Spacer()
                        TextField("1000", text: $budgetRub).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                    }
                }
                Section {
                    Text(s.t("После создания объявление уходит на модерацию. Показывается в ленте между постами с пометкой «Реклама».",
                             "After creating, the ad goes to moderation. It shows in the feed between posts, labeled Sponsored."))
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                }
            }
            .navigationTitle(s.t("Новая реклама", "New ad"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(s.cancel) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(s.t("Создать", "Create")) { submit() }.disabled(!valid || saving)
                }
            }
        }
    }

    private func submit() {
        saving = true
        draft.budgetCents = Int((Double(budgetRub) ?? 0) * 100)
        draft.rateCents = max(1, Int((Double(rateRub) ?? 0) * 100))
        let d = draft
        Task { await onSave(d); await MainActor.run { dismiss() } }
    }
}
