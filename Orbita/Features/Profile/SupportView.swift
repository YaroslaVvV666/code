import SwiftUI

/// Экран «Техподдержка»: список обращений + кнопка нового. Открывает переписку с поддержкой.
struct SupportView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var tickets: [SupportTicket] = []
    @State private var loaded = false
    @State private var composing = false
    @State private var open: SupportTicket?

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        ScrollView {
            if !loaded {
                ProgressView().padding(.top, 60)
            } else if tickets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "headphones").font(.system(size: 36, weight: .light)).foregroundStyle(theme.accentColor)
                    Text(s.t("Чем помочь?", "How can we help?")).font(.system(size: 19, weight: .semibold)).foregroundStyle(theme.text)
                    Text(s.t("Напишите нам — ответим в этом же окне.", "Write to us — we'll reply right here."))
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center).padding(.horizontal, 40)
                    Button { composing = true } label: {
                        Text(s.t("Новое обращение", "New request"))
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 24).frame(height: 48)
                            .background(theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain).padding(.top, 6)
                }
                .frame(maxWidth: .infinity).padding(.top, 54)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(tickets) { t in
                        Button { open = t } label: { ticketCard(t) }.buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
        .background(theme.sheet.ignoresSafeArea())
        .navigationTitle(s.t("Техподдержка", "Support"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !tickets.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $composing) {
            NavigationStack { SupportComposeView(onDone: { t in open = t; Task { await load() } }) }
                .wrapSupport(session: session, theme: theme, lang: lang)
        }
        .navigationDestination(item: $open) { t in
            SupportThreadView(ticket: t).onDisappear { Task { await load() } }
        }
    }

    private func ticketCard(_ t: SupportTicket) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: SupportTopics.icon(t.topic)).font(.system(size: 14)).foregroundStyle(theme.accentColor).frame(width: 20)
                Text(t.subject.isEmpty ? SupportTopics.title(t.topic, s) : t.subject)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Spacer()
                if t.unread { Circle().fill(theme.accentColor).frame(width: 9, height: 9) }
                statusBadge(t)
            }
            if !t.lastBody.isEmpty {
                Text((t.lastFromStaff ? s.t("Поддержка: ", "Support: ") : "") + t.lastBody)
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(2)
            }
            Text(ChatTime.short(Date(timeIntervalSince1970: t.updatedAt), lang: lang))
                .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card(theme, radius: 16)
    }

    private func statusBadge(_ t: SupportTicket) -> some View {
        let (text, color): (String, Color) = {
            switch t.status {
            case "answered": return (s.t("Ответили", "Answered"), .green)
            case "closed": return (s.t("Закрыто", "Closed"), theme.textTertiary)
            default: return (s.t("Ждёт ответа", "Pending"), .orange)
            }
        }()
        return Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 9).frame(height: 20)
            .background(color, in: Capsule())
    }

    private func load() async {
        tickets = (try? await session.extras.supportTickets()) ?? []
        loaded = true
    }
}

/// Создание обращения: выбор темы + текст.
struct SupportComposeView: View {
    var presetTopic = "other"
    var linkKind: String? = nil
    var linkID: String? = nil
    let onDone: (SupportTicket) -> Void

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss
    @State private var topic = "other"
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(s.t("Тема", "Topic")).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 4)
                FlowTopics(selected: $topic)

                Text(s.t("Сообщение", "Message")).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 4).padding(.top, 4)
                TextField(s.t("Опишите вопрос или проблему", "Describe your question or issue"), text: $text, axis: .vertical)
                    .lineLimit(5...12).font(.system(size: 16)).padding(14).focused($focused)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if let error { Text(error).font(.system(size: 13)).foregroundStyle(theme.danger).padding(.horizontal, 4) }
            }
            .padding(16)
        }
        .background(theme.sheet.ignoresSafeArea())
        .navigationTitle(s.t("Новое обращение", "New request"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button(s.t("Отмена", "Cancel")) { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button(s.t("Отправить", "Send")) { send() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                    .fontWeight(.semibold)
            }
        }
        .onAppear { topic = presetTopic; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true } }
    }

    private func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        sending = true; error = nil
        Task {
            do {
                let t = try await session.extras.openSupportTicket(topic: topic, text: body, linkKind: linkKind, linkID: linkID)
                Haptics.notify(.success)
                dismiss(); onDone(t)
            } catch {
                self.error = s.t("Не удалось отправить. Попробуйте ещё раз.", "Couldn't send. Please try again.")
                sending = false
            }
        }
    }
}

/// Сетка-выбор темы обращения.
private struct FlowTopics: View {
    @Binding var selected: String
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    private let cols = [GridItem(.adaptive(minimum: 150), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: cols, spacing: 8) {
            ForEach(SupportTopics.list(s), id: \.code) { topic in
                Button { Haptics.select(); selected = topic.code } label: {
                    HStack(spacing: 8) {
                        Image(systemName: topic.icon).font(.system(size: 14)).frame(width: 18)
                        Text(topic.title).font(.system(size: 14)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selected == topic.code ? Color.white : theme.text)
                    .padding(.horizontal, 12).frame(height: 44)
                    .background(selected == topic.code ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.surface),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Переписка с поддержкой: пузыри + поле ответа.
struct SupportThreadView: View {
    let ticket: SupportTicket

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var current: SupportTicket
    @State private var draft = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    private var s: Strings { Strings(lang: lang) }

    init(ticket: SupportTicket) {
        self.ticket = ticket
        _current = State(initialValue: ticket)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        header
                        ForEach(current.messages) { m in bubble(m) }
                        if current.status == "closed" {
                            Text(s.t("Обращение закрыто. Новое сообщение откроет его снова.",
                                     "Request closed. A new message reopens it."))
                                .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                                .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 6)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: current.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }

            composer
        }
        .background(theme.sheet.ignoresSafeArea())
        .navigationTitle(current.subject.isEmpty ? SupportTopics.title(current.topic, s) : current.subject)
        .navigationBarTitleDisplayMode(.inline)
        .task { if let fresh = try? await session.extras.supportThread(id: current.id) { current = fresh } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: SupportTopics.icon(current.topic)).font(.system(size: 13)).foregroundStyle(theme.accentColor)
            Text(SupportTopics.title(current.topic, s)).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textSecondary)
            Spacer()
        }
    }

    private func bubble(_ m: SupportMessage) -> some View {
        HStack {
            if m.fromStaff {
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.t("Поддержка", "Support")).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.accentColor)
                    Text(m.body).font(.system(size: 16)).foregroundStyle(theme.text)
                    time(m)
                }
                .padding(12).background(theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.body).font(.system(size: 16)).foregroundStyle(.white)
                    time(m)
                }
                .padding(12).background(theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func time(_ m: SupportMessage) -> some View {
        Text(ChatTime.short(Date(timeIntervalSince1970: m.createdAt), lang: lang))
            .font(.system(size: 11))
            .foregroundStyle(m.fromStaff ? theme.textTertiary : Color.white.opacity(0.7))
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField(s.t("Сообщение…", "Message…"), text: $draft, axis: .vertical)
                .lineLimit(1...5).font(.system(size: 16)).padding(.horizontal, 14).padding(.vertical, 9)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .focused($focused)
            Button { send() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? theme.textTertiary : theme.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.sheet)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        Task {
            if let fresh = try? await session.extras.replySupport(id: current.id, text: text) {
                current = fresh; draft = ""
            }
            sending = false
        }
    }
}

private extension View {
    func wrapSupport(session: AppSession, theme: Theme, lang: AppLanguage) -> some View {
        self.environmentObject(session)
            .environment(\.theme, theme).environment(\.lang, lang)
            .preferredColorScheme(theme.dark ? .dark : .light)
            .presentationBackground(theme.sheet)
    }
}
