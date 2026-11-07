import SwiftUI

/// Кто поставил реакции на сообщение (как в Telegram):
/// • зажали реакцию под сообщением — крупная анимированная эмодзи, плашка с аватарками и список тех, кто её поставил;
/// • «N реакций» в меню сообщения — все реакции: человек, когда поставил и какую.
struct ReactionWhoRoute: Identifiable, Equatable {
    let id = UUID()
    let message: ChatMessage
    let emoji: String?                  // nil — все реакции

    static func == (a: ReactionWhoRoute, b: ReactionWhoRoute) -> Bool { a.id == b.id }
}

enum ReactionWords {
    /// «1 реакция», «3 реакции», «12 реакций»
    static func count(_ n: Int, lang: AppLanguage) -> String {
        guard lang == .ru else { return "\(n) reaction\(n == 1 ? "" : "s")" }
        let m100 = n % 100, m10 = n % 10
        let w = (11...14).contains(m100) ? "реакций" : (m10 == 1 ? "реакция" : ((2...4).contains(m10) ? "реакции" : "реакций"))
        return "\(n) \(w)"
    }

    /// «сегодня в 11:24», «вчера в 09:03», «5 нояб. в 18:40»
    static func stamp(_ d: Date, lang: AppLanguage) -> String {
        let cal = Calendar.current
        let time = FormatterCache.format(d, "HH:mm")
        let ru = lang == .ru
        if cal.isDateInToday(d) { return (ru ? "сегодня в " : "today at ") + time }
        if cal.isDateInYesterday(d) { return (ru ? "вчера в " : "yesterday at ") + time }
        let day = FormatterCache.format(d, "d MMM", locale: Locale(identifier: ru ? "ru_RU" : "en_US"))
        return day + (ru ? " в " : " at ") + time
    }
}

struct ReactionWhoOverlay: View {
    let route: ReactionWhoRoute
    let onClose: () -> Void
    var onOpenProfile: (String) -> Void = { _ in }

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var info: MessageInfo?
    @State private var failed = false
    @State private var appear = false
    @State private var bounce = false

    private var s: Strings { Strings(lang: lang) }
    private var mine: Bool { route.message.mine }
    private var cardWidth: CGFloat { min(UIScreen.main.bounds.width - 32, 360) }

    /// Отреагировавшие: по выбранной эмодзи или все, свежие сверху
    private var entries: [MessageInfo.Entry] {
        let all = (info?.reactions ?? []).filter { route.emoji == nil || $0.emoji == route.emoji }
        return all.sorted { $0.at > $1.at }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(theme.dark ? 0.5 : 0.25))
                .ignoresSafeArea()
                .opacity(appear ? 1 : 0)
                .onTapGesture { close() }

            VStack(alignment: mine ? .trailing : .leading, spacing: 12) {
                Spacer(minLength: 60)
                if let emoji = route.emoji {
                    LottieEmojiView(emoji: emoji, size: 120, loop: true)
                        .frame(width: 140, height: 140)
                        .scaleEffect(appear ? (bounce ? 1.0 : 1.08) : 0.3, anchor: .bottom)
                        .rotationEffect(.degrees(appear ? 0 : -18))
                        .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
                    chip(emoji)
                } else {
                    preview
                }
                card
                    .scaleEffect(appear ? 1 : 0.85, anchor: mine ? .topTrailing : .topLeading)
                    .opacity(appear ? 1 : 0)
                Spacer(minLength: 30)
            }
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
            .padding(.horizontal, 16)
        }
        .task {
            Haptics.impact(.medium)
            withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) { appear = true }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.45).delay(0.25)) { bounce = true }
            do { info = try await session.extras.info(messageID: route.message.id) } catch { failed = true }
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.18)) { appear = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onClose() }
    }

    /// Плашка как под сообщением: эмодзи и аватарки тех, кто её поставил
    private func chip(_ emoji: String) -> some View {
        HStack(spacing: 6) {
            Text(emoji).font(.system(size: 22))
            HStack(spacing: -10) {
                ForEach(Array(entries.prefix(3).enumerated()), id: \.element.id) { i, e in
                    AvatarView(name: e.user.name, size: 30, avatarID: e.user.avatarID)
                        .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 2))
                        .zIndex(Double(3 - i))
                }
            }
            if entries.count > 3 {
                Text("+\(entries.count - 3)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 12).frame(height: 44)
        .background(.black.opacity(0.45), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 1))
        .opacity(appear ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: entries.count)
    }

    /// «Все реакции»: над списком — само сообщение (коротко)
    private var preview: some View {
        let m = route.message
        return HStack(alignment: .bottom, spacing: 8) {
            if let thumb = m.attachments.first(where: { $0.kind == .photo || $0.kind == .video }), let id = thumb.thumbID ?? thumb.mediaID {
                RemoteImage(id: id).frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if !m.summary.isEmpty {
                Text(m.summary).font(.system(size: 16)).foregroundStyle(mine ? .white : theme.text).lineLimit(4)
            }
            Text(ChatTime.clock(m.createdAt)).font(.system(size: 12)).foregroundStyle(mine ? .white.opacity(0.75) : theme.textSecondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(mine ? AnyShapeStyle(theme.accent) : AnyShapeStyle(ChatColors(theme: theme).incoming),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: cardWidth, alignment: mine ? .trailing : .leading)
        .scaleEffect(appear ? 1 : 0.9)
        .opacity(appear ? 1 : 0)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if route.emoji == nil {
                Button { close() } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "arrow.left").font(.system(size: 18, weight: .semibold))
                        Text(s.t("Назад", "Back")).font(.system(size: 17, weight: .semibold))
                        Spacer()
                        if !entries.isEmpty {
                            Text(ReactionWords.count(entries.count, lang: lang)).font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(height: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5).padding(.horizontal, 16)
            }
            if info == nil && !failed {
                ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.vertical, 26)
            } else if entries.isEmpty {
                Text(failed ? s.api(.offline) : s.t("Реакций пока нет", "No reactions yet"))
                    .font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity).padding(.vertical, 22)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(entries) { e in row(e) }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: min(CGFloat(entries.count) * 66 + 16, 400))
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(width: cardWidth)
        .background(Color(white: 0.12).opacity(0.94), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
        .environment(\.colorScheme, .dark)
    }

    private func row(_ e: MessageInfo.Entry) -> some View {
        Button {
            Haptics.select()
            let id = e.user.id
            close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onOpenProfile(id) }
        } label: {
            HStack(spacing: 12) {
                AvatarView(name: e.user.name, size: 44, avatarID: e.user.avatarID)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.user.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: "heart").font(.system(size: 13, weight: .semibold))
                        Text(ReactionWords.stamp(e.at, lang: lang)).font(.system(size: 15))
                    }
                    .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 8)
                if route.emoji == nil, let emoji = e.emoji {
                    Text(emoji).font(.system(size: 28))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
