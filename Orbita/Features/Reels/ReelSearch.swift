import SwiftUI

// MARK: - Поиск по шортсам: история и популярное, результаты по два в ряд, как в TikTok

private struct ReelSearchPage: Decodable {
    let reels: [ReelSearchDTO]
    let more: Bool?
}

private struct ReelSearchDTO: Decodable {
    let post: PostDTO
    let authorState: String
    init(from decoder: Decoder) throws {
        post = try PostDTO(from: decoder)
        authorState = try decoder.container(keyedBy: Keys.self).decodeIfPresent(String.self, forKey: .authorState) ?? "none"
    }
    enum Keys: String, CodingKey { case authorState }
}

private struct PopularDTO: Decodable { let queries: [String] }

enum ReelSearchError: Error { case blocked }

extension ExtrasAPI {
    func reelSearch(_ query: String, offset: Int) async throws -> (reels: [Reel], more: Bool) {
        do {
            let data = try await api.request("GET", "/v1/reels/search", query: ["q": query, "offset": "\(offset)", "limit": "20"])
            let page = try decodeAPI(ReelSearchPage.self, from: data)
            return (page.reels.map { Reel(post: $0.post.model, state: $0.authorState) }, page.more ?? false)
        } catch APIError.server(_, let code) where code == "query_blocked" {
            throw ReelSearchError.blocked
        }
    }

    func reelPopular() async -> [String] {
        guard let data = try? await api.request("GET", "/v1/reels/search/popular"),
              let r = try? decodeAPI(PopularDTO.self, from: data) else { return [] }
        return r.queries
    }
}

struct ReelSearchView: View {
    let onClose: () -> Void

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    private enum Phase { case idle, loading, results, empty, blocked, failed }

    @State private var text = ""
    @State private var submitted = ""
    @State private var phase: Phase = .idle
    @State private var results: [Reel] = []
    @State private var more = false
    @State private var loadingMore = false
    @State private var popular: [String] = []
    @State private var history: [String] = ReelSearchView.loadHistory()
    @State private var opened: Reel?
    @FocusState private var focused: Bool

    private var s: Strings { Strings(lang: lang) }
    private static let historyKey = "reelSearchHistory"

    private static func loadHistory() -> [String] { UserDefaults.standard.stringArray(forKey: historyKey) ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            bar
            content
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            popular = await session.extras.reelPopular()
            try? await Task.sleep(nanoseconds: 250_000_000)
            if phase == .idle { focused = true }
        }
        .fullScreenCover(item: $opened) { reel in
            MusicShortsCover(reels: results, startID: reel.id, onClose: { opened = nil })
                .environmentObject(session).environmentObject(flow)
                .environment(\.theme, theme).environment(\.lang, lang)
        }
    }

    // MARK: Верх

    private var bar: some View {
        HStack(spacing: 8) {
            Button { focused = false; onClose() } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 48, height: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.55))
                TextField("", text: $text, prompt: Text(s.t("Поиск видео", "Search videos")).foregroundColor(.white.opacity(0.4)))
                    .focused($focused)
                    .submitLabel(.search)
                    .foregroundStyle(.white).tint(.white)
                    .autocorrectionDisabled()
                    .onSubmit { search(text) }
                if !text.isEmpty {
                    Button { text = ""; phase = .idle; results = []; focused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5))
                            .frame(width: 32, height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).frame(height: 42)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button { search(text) } label: {
                Text(s.t("Найти", "Search")).font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(text.trimmingCharacters(in: .whitespaces).count >= 2 ? Color.red : .white.opacity(0.3))
                    .frame(minWidth: 52, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
        }
        .padding(.leading, 2).padding(.top, 4)
    }

    // MARK: Содержимое

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle: suggestions
        case .loading: VStack { ProgressView().tint(.white).padding(.top, 60); Spacer() }
        case .results: grid
        case .empty:
            message(icon: "magnifyingglass", title: s.t("Ничего не найдено", "Nothing found"),
                    text: s.t("По запросу «\(submitted)» видео нет. Попробуйте другие слова.", "No videos for “\(submitted)”. Try different words."))
        case .failed:
            message(icon: "wifi.exclamationmark", title: s.t("Не удалось загрузить", "Couldn't load"),
                    text: s.t("Проверьте соединение и попробуйте ещё раз.", "Check your connection and try again."),
                    button: (s.t("Повторить", "Retry"), { search(submitted) }))
        case .blocked:
            message(icon: "hand.raised.fill", title: s.t("Этот запрос нарушает наши правила", "This search breaks our rules"),
                    text: s.t("Мы не показываем результаты по запросам с запрещённым содержимым.", "We don't show results for searches with prohibited content."),
                    tint: .orange, button: (s.t("Я понял", "Got it"), { text = ""; submitted = ""; phase = .idle; focused = true }))
        }
    }

    private func message(icon: String, title: String, text: String, tint: Color = .white.opacity(0.55),
                         button: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 38, weight: .light)).foregroundStyle(tint)
            Text(title).font(.system(size: 19, weight: .bold)).foregroundStyle(.white).multilineTextAlignment(.center)
            Text(text).font(.system(size: 15)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
            if let button {
                Button(action: button.1) {
                    Text(button.0).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 28).frame(height: 46).background(Color.red, in: Capsule())
                }
                .buttonStyle(.plain).padding(.top, 6)
            }
            Spacer()
        }
        .padding(.horizontal, 32).padding(.top, 80)
    }

    private var suggestions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !history.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(s.t("Вы искали", "Recent")).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            Spacer()
                            Button { history = []; UserDefaults.standard.removeObject(forKey: Self.historyKey) } label: {
                                Text(s.t("Очистить", "Clear")).font(.system(size: 14)).foregroundStyle(.white.opacity(0.55))
                                    .frame(minHeight: 40).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(history, id: \.self) { q in row(q, icon: "clock") }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.t("Популярные запросы", "Popular searches")).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .padding(.bottom, 2)
                    ForEach(popular, id: \.self) { q in row(q, icon: "flame.fill") }
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func row(_ q: String, icon: String) -> some View {
        Button { text = q; search(q) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(icon == "flame.fill" ? Color.orange : .white.opacity(0.5))
                    .frame(width: 22)
                Text(q).font(.system(size: 16)).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Image(systemName: "arrow.up.left").font(.system(size: 12)).foregroundStyle(.white.opacity(0.3))
            }
            .frame(minHeight: 46).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 2), spacing: 4) {
                ForEach(results) { reel in
                    cell(reel.post)
                        .onTapGesture { focused = false; opened = reel }
                        .onAppear { if reel.id == results.last?.id { loadMore() } }
                }
            }
            .padding(.horizontal, 4).padding(.top, 6)
            if loadingMore { ProgressView().tint(.white).padding(16) }
            Color.clear.frame(height: 30)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func cell(_ post: Post) -> some View {
        Color(white: 0.1)
            .aspectRatio(3.0 / 4.2, contentMode: .fit)
            .overlay { if let m = post.media.first { RemoteImage(id: m.thumbID ?? m.id) } }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).frame(height: 90)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    if !post.text.isEmpty {
                        Text(post.text).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    HStack(spacing: 6) {
                        AvatarView(name: post.author.name, size: 18, avatarID: post.author.avatarID).clipShape(Circle())
                        Text(post.author.name).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "heart").font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                        Text("\(post.likes)").font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
    }

    // MARK: Логика

    private func remember(_ q: String) {
        history.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        history.insert(q, at: 0)
        history = Array(history.prefix(10))
        UserDefaults.standard.set(history, forKey: Self.historyKey)
    }

    private func search(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return }
        focused = false
        text = q
        submitted = q
        phase = .loading
        results = []
        Task {
            do {
                let r = try await session.extras.reelSearch(q, offset: 0)
                guard submitted == q else { return }
                results = r.reels
                more = r.more
                if r.reels.isEmpty { phase = .empty } else { phase = .results; remember(q) }
            } catch ReelSearchError.blocked {
                guard submitted == q else { return }
                Haptics.notify(.warning)
                phase = .blocked
            } catch {
                guard submitted == q else { return }
                phase = .failed
            }
        }
    }

    private func loadMore() {
        guard more, !loadingMore else { return }
        loadingMore = true
        let q = submitted
        Task {
            if let r = try? await session.extras.reelSearch(q, offset: results.count), submitted == q {
                let known = Set(results.map(\.id))
                results += r.reels.filter { !known.contains($0.id) }
                more = r.more
            } else { more = false }
            loadingMore = false
        }
    }
}
