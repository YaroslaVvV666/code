import SwiftUI

// MARK: - Опрос внутри пузыря

struct PollBlock: View {
    let messageID: String
    let question: String
    let poll: PollInfo
    let mine: Bool
    let pending: Bool
    var onChanged: (PollInfo) -> Void

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var info: PollInfo
    @State private var busy = false
    @State private var showVoters = false
    @State private var errorText: String?

    init(messageID: String, question: String, poll: PollInfo, mine: Bool, pending: Bool,
         onChanged: @escaping (PollInfo) -> Void) {
        self.messageID = messageID
        self.question = question
        self.poll = poll
        self.mine = mine
        self.pending = pending
        self.onChanged = onChanged
        _info = State(initialValue: poll)
    }

    private var s: Strings { Strings(lang: lang) }
    private var fg: Color { mine ? .white : theme.text }
    private var fg2: Color { mine ? Color.white.opacity(0.78) : theme.textSecondary }
    private var tint: Color { mine ? .white : theme.accentColor }
    private var voted: Bool { info.options.contains { $0.mine } }
    private var showResults: Bool { voted || info.closed || info.mine }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(fg)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(fg2)

            ForEach(info.options) { option in
                optionRow(option)
            }

            HStack {
                Text(votesText).font(.system(size: 12)).foregroundStyle(fg2)
                Spacer(minLength: 0)
                if !info.anonymous && info.total > 0 {
                    Button { showVoters = true } label: {
                        Text(s.t("Кто голосовал", "Voters")).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                    }
                    .buttonStyle(.plain)
                }
            }
            if info.mine && !info.closed {
                Button { close() } label: {
                    Text(s.t("Завершить опрос", "Stop poll"))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                        .frame(maxWidth: .infinity).frame(height: 32)
                        .background(tint.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if let errorText {
                Text(errorText).font(.system(size: 12)).foregroundStyle(mine ? Color.white : theme.danger)
            }
        }
        .frame(width: 244, alignment: .leading)
        .onChange(of: poll) { _, new in info = new }
        .sheet(isPresented: $showVoters) {
            PollVotersSheet(question: question, poll: info)
                .environment(\.theme, theme).environment(\.lang, lang)
                .presentationDetents([.medium, .large])
                .presentationBackground(theme.sheet)
        }
    }

    private var subtitle: String {
        if info.closed { return s.t("Опрос завершён", "Poll closed") }
        let kind = info.anonymous ? s.t("Анонимный опрос", "Anonymous poll") : s.t("Публичный опрос", "Public poll")
        return info.multiple ? kind + " · " + s.t("несколько ответов", "multiple answers") : kind
    }

    private var votesText: String {
        if info.total == 0 { return s.t("Пока нет голосов", "No votes yet") }
        return lang == .ru ? "Проголосовало: \(info.total)" : "\(info.total) voted"
    }

    private func optionRow(_ o: PollOption) -> some View {
        let total = max(1, info.options.reduce(0) { $0 + $1.votes })
        let share = Double(o.votes) / Double(total)
        return Button { vote(o) } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(fg2, lineWidth: 1.5).frame(width: 20, height: 20)
                    if o.mine {
                        Circle().fill(tint).frame(width: 20, height: 20)
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(mine ? theme.accentColor : Color.white)
                    }
                }
                Text(o.text).font(.system(size: 15)).foregroundStyle(fg).lineLimit(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if showResults {
                    Text("\(Int((share * 100).rounded()))%").font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(fg2)
                }
            }
            .padding(.vertical, 5)
            .background(alignment: .bottomLeading) {
                if showResults {
                    GeometryReader { g in
                        Capsule().fill(tint.opacity(0.35))
                            .frame(width: max(4, g.size.width * share), height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy || info.closed || pending)
    }

    private func vote(_ o: PollOption) {
        var set = Set(info.options.filter(\.mine).map(\.id))
        if info.multiple {
            if set.contains(o.id) { set.remove(o.id) } else { set.insert(o.id) }
        } else {
            set = set.contains(o.id) ? [] : [o.id]
        }
        busy = true
        Haptics.select()
        Task {
            defer { busy = false }
            do {
                let new = try await session.extras.vote(messageID: messageID, options: Array(set).sorted())
                info = new
                onChanged(new)
                errorText = nil
            } catch {
                errorText = s.api((error as? APIError) ?? .offline)
            }
        }
    }

    private func close() {
        busy = true
        Task {
            defer { busy = false }
            if let new = try? await session.extras.closePoll(messageID: messageID) {
                info = new
                onChanged(new)
            }
        }
    }
}

// MARK: - Кто проголосовал

struct PollVotersSheet: View {
    let question: String
    let poll: PollInfo

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(question).font(.system(size: 18, weight: .bold)).foregroundStyle(theme.text).lineLimit(2)
                Spacer()
                Button(s.close) { dismiss() }.foregroundStyle(theme.accentColor)
            }
            .padding(20)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(poll.options) { o in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(o.text).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
                                Spacer()
                                Text("\(o.votes)").font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                            }
                            if o.voters.isEmpty {
                                Text(s.t("Нет голосов", "No votes")).font(.system(size: 13)).foregroundStyle(theme.textTertiary)
                            }
                            ForEach(o.voters) { v in
                                HStack(spacing: 10) {
                                    AvatarView(name: v.name, size: 32, avatarID: v.avatarID).clipShape(Circle())
                                    Text(v.name).font(.system(size: 15)).foregroundStyle(theme.text)
                                    Spacer()
                                    Text(ChatTime.clock(v.at)).font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(theme, radius: 16)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 20)
            }
        }
    }
}

// MARK: - Создание опроса

struct PollCreateSheet: View {
    let peerID: String
    var onSent: () -> Void

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss

    @State private var question = ""
    @State private var options = ["", ""]
    @State private var anonymous = true
    @State private var multiple = false
    @State private var sending = false
    @State private var errorText: String?

    private var s: Strings { Strings(lang: lang) }
    private var cleaned: [String] {
        options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && cleaned.count >= 2 && !sending
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(s.cancel) { dismiss() }.foregroundStyle(theme.accentColor)
                Spacer()
                Text(s.t("Новый опрос", "New poll")).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
                Spacer()
                Button { send() } label: {
                    if sending { ProgressView() } else {
                        Text(s.t("Отправить", "Send")).fontWeight(.semibold)
                    }
                }
                .foregroundStyle(canSend ? theme.accentColor : theme.textTertiary)
                .disabled(!canSend)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    label(s.t("Вопрос", "Question"))
                    TextField(s.t("Задайте вопрос", "Ask a question"), text: $question, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(14).card(theme, radius: 16)

                    label(s.t("Варианты ответа", "Options"))
                    VStack(spacing: 8) {
                        ForEach(options.indices, id: \.self) { i in
                            HStack(spacing: 8) {
                                TextField(s.t("Вариант \(i + 1)", "Option \(i + 1)"), text: $options[i])
                                    .padding(14).card(theme, radius: 16)
                                if options.count > 2 {
                                    Button { options.remove(at: i) } label: {
                                        Image(systemName: "minus.circle.fill").font(.system(size: 22))
                                            .foregroundStyle(theme.danger)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if options.count < 10 {
                            Button { options.append("") } label: {
                                Label(s.t("Добавить вариант", "Add option"), systemImage: "plus.circle.fill")
                                    .font(.system(size: 15, weight: .medium)).foregroundStyle(theme.accentColor)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(spacing: 0) {
                        Toggle(s.t("Анонимное голосование", "Anonymous voting"), isOn: $anonymous)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                        Divider()
                        Toggle(s.t("Несколько ответов", "Multiple answers"), isOn: $multiple)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    .tint(theme.accentColor)
                    .card(theme, radius: 16)

                    if let errorText {
                        Text(errorText).font(.system(size: 13)).foregroundStyle(theme.danger)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 30)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
            .padding(.leading, 4)
    }

    private func send() {
        sending = true
        Task {
            defer { sending = false }
            do {
                try await session.extras.sendPoll(peerID: peerID,
                                                  question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  options: cleaned, multiple: multiple, anonymous: anonymous)
                Haptics.notify(.success)
                onSent()
                dismiss()
            } catch {
                errorText = s.api((error as? APIError) ?? .offline)
            }
        }
    }
}
