import SwiftUI
import Combine
import AVFoundation

// MARK: - Скрепка: «Список», «Звук», «Контакт»
// Список — чек-лист с галочками: отмечают все в чате, видно кто и когда.
// Звук — как в Telegram: недавняя музыка из переписок, свой плейлист и загрузка с телефона.
// Контакт — карточка человека из Orbita (аватарка, имя, номер, «НАПИСАТЬ»), как цитата. Изменить нельзя — только удалить.

extension ChatModel {
    /// Уже загруженные вложения (трек из «Недавних», контакт) — сразу сообщением
    func sendReady(_ attachments: [OutgoingAttachment]) async -> Bool {
        guard !attachments.isEmpty else { return false }
        do {
            var sent = try await repo.send(peerID: peerID, text: "", entities: [], attachments: attachments,
                                           replyTo: replyTo?.id, silent: false, topic: topic?.id)
            replyTo = nil
            sent.key = sent.id
            if let i = messages.firstIndex(where: { $0.id == sent.id }) { messages[i] = sent } else { messages.append(sent) }
            Haptics.notify(.success)
            return true
        } catch {
            self.error = (error as? APIError) ?? .offline
            return false
        }
    }

    func sendChecklist(title: String, items: [String], othersAdd: Bool) async -> Bool {
        do {
            var sent = try await repo.sendChecklist(peerID: peerID, title: title, items: items, othersAdd: othersAdd)
            sent.key = sent.id
            if !messages.contains(where: { $0.id == sent.id }) { messages.append(sent) }
            Haptics.notify(.success)
            return true
        } catch {
            self.error = (error as? APIError) ?? .offline
            return false
        }
    }

    /// Отметить пункт / добавить пункт → свежий список сразу в сообщении
    func updateChecklist(_ messageID: String, _ action: (MessengerRepository) async throws -> Checklist) async -> Bool {
        do {
            let list = try await action(repo)
            if let i = messages.firstIndex(where: { $0.id == messageID }) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { messages[i].checklist = list }
            }
            return true
        } catch {
            self.error = (error as? APIError) ?? .offline
            return false
        }
    }
}

// MARK: - Список с галочками в пузыре

struct ChecklistBlock: View {
    let message: ChatMessage
    let list: Checklist
    let mine: Bool

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.chainModel) private var model
    @State private var busy: Set<String> = []
    @State private var adding = false
    @State private var newItem = ""
    @FocusState private var addFocus: Bool

    private var s: Strings { Strings(lang: lang) }
    private var ink: Color { mine ? .white : theme.text }
    private var sub: Color { mine ? Color.white.opacity(0.75) : theme.textSecondary }
    private var tint: Color { mine ? .white : theme.accentColor }
    private var title: String {
        message.text.hasPrefix("☑️ ") ? String(message.text.dropFirst(3)) : message.text
    }
    private var canAdd: Bool { (list.owner || list.othersAdd) && list.items.count < 50 && !message.isPending }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "checklist").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(LinearGradient(colors: [Color(red: 0.2, green: 0.74, blue: 0.4), Color(red: 0.1, green: 0.55, blue: 0.45)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(ink).lineLimit(3)
                    Text(s.t("Выполнено \(list.doneCount) из \(list.items.count)", "\(list.doneCount) of \(list.items.count) done"))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(sub)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
            }
            // полоска прогресса
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.opacity(0.14))
                    Capsule().fill(tint)
                        .frame(width: list.items.isEmpty ? 0 : g.size.width * CGFloat(list.doneCount) / CGFloat(list.items.count))
                }
            }
            .frame(height: 4)
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: list.doneCount)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(list.items) { item in row(item) }
            }
            if canAdd { addRow }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
        .frame(minWidth: 240, maxWidth: 290, alignment: .leading)
    }

    private func row(_ item: Checklist.Item) -> some View {
        Button { toggle(item) } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().stroke(item.done ? tint : sub.opacity(0.7), lineWidth: 1.8)
                    if item.done {
                        Circle().fill(tint)
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(mine ? theme.accentColor : .white)
                            .transition(.scale.combined(with: .opacity))
                    }
                    if busy.contains(item.id) { ProgressView().scaleEffect(0.6).tint(item.done ? .white : tint) }
                }
                .frame(width: 22, height: 22)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: item.done)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text).font(.system(size: 15)).foregroundStyle(item.done ? sub : ink)
                        .strikethrough(item.done, color: sub)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.done, let name = item.doneByName {
                        Text((item.doneByMe ? s.t("Вы", "You") : name) + (item.doneAt.map { " · " + FormatterCache.format($0, "d MMM, HH:mm") } ?? ""))
                            .font(.system(size: 11)).foregroundStyle(sub).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if item.done, let id = item.doneByID, !item.doneByMe {
                    AvatarView(name: item.doneByName ?? "", size: 20, avatarID: item.doneByAvatar).clipShape(Circle())
                        .id(id)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(message.isPending)
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill").font(.system(size: 21)).foregroundStyle(tint)
            if adding {
                TextField(s.t("Новый пункт", "New item"), text: $newItem)
                    .font(.system(size: 15)).foregroundStyle(ink).tint(tint)
                    .focused($addFocus)
                    .submitLabel(.done)
                    .onSubmit { add() }
                    .onChange(of: newItem) { _, v in if v.count > 200 { newItem = String(v.prefix(200)) } }
            } else {
                Text(s.t("Добавить пункт", "Add item")).font(.system(size: 15, weight: .medium)).foregroundStyle(tint)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !adding else { return }
            adding = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { addFocus = true }
        }
        .onChange(of: addFocus) { _, f in if !f && newItem.trimmingCharacters(in: .whitespaces).isEmpty { adding = false } }
    }

    private func toggle(_ item: Checklist.Item) {
        guard let model, !busy.contains(item.id) else { return }
        Haptics.impact(.light)
        busy.insert(item.id)
        Task {
            if await model.updateChecklist(message.id, { try await $0.checklistToggle(messageID: message.id, itemID: item.id) }),
               !item.done {
                Haptics.notify(.success)
            }
            busy.remove(item.id)
        }
    }

    private func add() {
        let t = newItem.trimmingCharacters(in: .whitespaces)
        guard let model, !t.isEmpty else { adding = false; return }
        newItem = ""
        Task {
            _ = await model.updateChecklist(message.id) { try await $0.checklistAdd(messageID: message.id, text: t) }
            addFocus = true
        }
    }
}

// MARK: - Создание списка

struct ChecklistCreateSheet: View {
    let onCreate: (String, [String], Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var title = ""
    @State private var items: [Entry] = [Entry(), Entry()]
    @State private var othersAdd = true
    @FocusState private var focus: String?

    struct Entry: Identifiable, Equatable { var id = UUID().uuidString; var text = "" }

    private var s: Strings { Strings(lang: lang) }
    private var filled: [String] {
        items.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private var ready: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && !filled.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section(s.t("Название", "Title")) {
                    TextField(s.t("Например: покупки на выходные", "E.g. weekend shopping"), text: $title)
                        .focused($focus, equals: "title")
                        .onChange(of: title) { _, v in if v.count > 120 { title = String(v.prefix(120)) } }
                }
                Section {
                    ForEach($items) { $e in
                        HStack(spacing: 10) {
                            Image(systemName: "circle").font(.system(size: 18)).foregroundStyle(theme.textTertiary)
                            TextField(s.t("Пункт", "Item"), text: $e.text)
                                .focused($focus, equals: e.id)
                                .submitLabel(.next)
                                .onSubmit { next(after: e.id) }
                                .onChange(of: e.text) { _, v in if v.count > 200 { e.text = String(v.prefix(200)) } }
                        }
                    }
                    .onDelete { idx in
                        items.remove(atOffsets: idx)
                        if items.isEmpty { items = [Entry()] }
                    }
                    .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                    if items.count < 50 {
                        Button {
                            let e = Entry()
                            items.append(e)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focus = e.id }
                        } label: {
                            Label(s.t("Добавить пункт", "Add item"), systemImage: "plus.circle.fill")
                                .foregroundStyle(theme.accentColor)
                        }
                    }
                } header: {
                    Text(s.t("Пункты", "Items"))
                } footer: {
                    Text(s.t("Смахните пункт влево, чтобы удалить.", "Swipe an item left to delete it."))
                }
                Section {
                    Toggle(s.t("Другие могут добавлять пункты", "Others can add items"), isOn: $othersAdd)
                        .tint(theme.accentColor)
                } footer: {
                    Text(s.t("Отмечать пункты могут все в чате — видно, кто и когда отметил.",
                             "Everyone in the chat can tick items — you'll see who did it and when."))
                }
            }
            .navigationTitle(s.t("Список", "Checklist"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(s.cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(s.t("Отправить", "Send")) {
                        onCreate(title.trimmingCharacters(in: .whitespaces), filled, othersAdd)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!ready)
                }
            }
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focus = "title" } }
        }
    }

    private func next(after id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if i + 1 < items.count {
            focus = items[i + 1].id
        } else if items.count < 50, !items[i].text.trimmingCharacters(in: .whitespaces).isEmpty {
            let e = Entry()
            items.append(e)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = e.id }
        }
    }
}

// MARK: - Карточка контакта в пузыре (как цитата)

struct ContactCard: View {
    let attachment: ChatAttachment
    let mine: Bool
    var onOpen: (String) -> Void = { _ in }

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }
    private var ink: Color { mine ? .white : theme.text }
    private var sub: Color { mine ? Color.white.opacity(0.78) : theme.textSecondary }
    private var bar: Color { mine ? .white : theme.accentColor }

    private var subtitle: String {
        if let p = attachment.phone, !p.isEmpty { return PhoneFormat.pretty(p) }
        if let u = attachment.username, !u.isEmpty { return "@" + u }
        return s.t("Контакт в Orbita", "Orbita contact")
    }

    var body: some View {
        VStack(spacing: 0) {
            Button { open() } label: {
                HStack(spacing: 11) {
                    AvatarView(name: attachment.name ?? "", size: 44, avatarID: attachment.avatarID).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.name ?? s.t("Контакт", "Contact")).font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(ink).lineLimit(1)
                        Text(subtitle).font(.system(size: 14).monospacedDigit()).foregroundStyle(sub).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle().fill(bar.opacity(0.22)).frame(height: 0.7).padding(.leading, 10)
            Button { open() } label: {
                Text(s.t("НАПИСАТЬ", "MESSAGE")).font(.system(size: 13, weight: .bold)).kerning(0.6)
                    .foregroundStyle(bar)
                    .frame(maxWidth: .infinity).frame(height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
        }
        .background(bar.opacity(mine ? 0.14 : 0.09))
        .overlay(alignment: .leading) { Rectangle().fill(bar).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(minWidth: 220, maxWidth: 260)
    }

    private func open() {
        guard let id = attachment.userID else { return }
        Haptics.impact(.light)
        onOpen(id)
    }
}

/// «+79991234567» → «+7 999 123-45-67» (остальные номера — как есть, с пробелами по три)
enum PhoneFormat {
    static func pretty(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        if digits.count == 11, digits.first == "7" || digits.first == "8" {
            let d = Array(digits)
            return "+7 \(String(d[1...3])) \(String(d[4...6]))-\(String(d[7...8]))-\(String(d[9...10]))"
        }
        return raw
    }
}

// MARK: - Выбор контакта

struct ContactPickerSheet: View {
    let repo: MessengerRepository
    let onPick: (Contact) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var contacts: [Contact] = []
    @State private var loading = true
    @State private var query = ""
    @State private var failed = false

    private var s: Strings { Strings(lang: lang) }
    private var shown: [Contact] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = contacts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !q.isEmpty else { return list }
        return list.filter {
            $0.name.lowercased().contains(q) || $0.realName.lowercased().contains(q)
                || ($0.username ?? "").lowercased().contains(q) || ($0.phone ?? "").contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if contacts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 44, weight: .light))
                            .foregroundStyle(theme.textTertiary)
                        Text(failed ? s.api(.offline) : s.t("В контактах пока никого", "No contacts yet"))
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
                        Text(s.t("Добавьте людей из Orbita в контакты — и ими можно будет поделиться.",
                                 "Add people from Orbita to your contacts to share them."))
                            .font(.system(size: 14)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
                    }
                    .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(shown) { c in
                        Button {
                            Haptics.select()
                            onPick(c)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: c.name, size: 42, avatarID: c.avatarID).clipShape(Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                                    Text(c.phone.map(PhoneFormat.pretty) ?? c.username.map { "@" + $0 } ?? c.realName)
                                        .font(.system(size: 13).monospacedDigit()).foregroundStyle(theme.textSecondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "paperplane.fill").font(.system(size: 14)).foregroundStyle(theme.accentColor)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                                prompt: s.t("Поиск контактов", "Search contacts"))
                }
            }
            .navigationTitle(s.t("Контакт", "Contact"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(s.cancel) { dismiss() } } }
        }
        .task {
            do { contacts = try await repo.contacts() } catch { failed = true }
            loading = false
        }
    }
}

// MARK: - «Звук»: недавняя музыка, плейлист, загрузка — как в Telegram

struct MusicPickerSheet: View {
    /// Выбранные треки — уже своими копиями на сервере, можно сразу отправлять
    let onPick: ([AudioCopy]) -> Void
    /// «Загрузить с телефона»
    let onUpload: () -> Void

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var recent: [RecentAudio] = []
    @State private var playlist: [Track] = []
    @State private var loading = true
    @State private var query = ""
    @State private var selected: [String] = []          // порядок выбора: «1», «2»…
    @State private var sending = false
    @State private var failed = false

    private var s: Strings { Strings(lang: lang) }

    /// Один трек для списка — откуда бы он ни был
    private struct Row: Identifiable, Equatable {
        let id: String
        let track: Track
        let messageID: String?           // nil — из своего плейлиста
    }

    private func match(_ t: Track) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || t.title.lowercased().contains(q) || t.artist.lowercased().contains(q)
    }
    private var recentRows: [Row] {
        recent.map { r in
            Row(id: "r:" + r.mediaId, track: Track(id: r.mediaId, mediaID: r.mediaId, title: r.title.isEmpty ? s.t("Без названия", "Untitled") : r.title,
                                                   artist: r.artist, duration: r.duration, cover: r.thumb),
                messageID: r.messageId)
        }.filter { match($0.track) }
    }
    private var playlistRows: [Row] {
        playlist.map { Row(id: "p:" + $0.id, track: $0, messageID: nil) }.filter { match($0.track) }
    }
    private var allRows: [Row] { recentRows + playlistRows }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    uploadRow
                    if loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else if allRows.isEmpty {
                        empty
                    } else {
                        if !recentRows.isEmpty {
                            Section { ForEach(recentRows) { trackRow($0, queue: recentRows) } } header: { header(s.t("НЕДАВНИЕ", "RECENT")) }
                        }
                        if !playlistRows.isEmpty {
                            Section { ForEach(playlistRows) { trackRow($0, queue: playlistRows) } } header: { header(s.t("МОЙ ПЛЕЙЛИСТ", "MY PLAYLIST")) }
                        }
                    }
                }
                .padding(.bottom, selected.isEmpty ? 20 : 90)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: s.t("Поиск музыки", "Search music"))
            .navigationTitle(s.t("Музыка", "Music"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(s.cancel) { dismiss() } } }
            .overlay(alignment: .bottom) { sendBar }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selected)
        }
        .task {
            recent = (try? await session.messengerRepo.recentAudio()) ?? []
            playlist = (try? await session.socialRepo.playlist(userID: session.serverID)) ?? []
            // трек и в недавних, и в плейлисте — показываем один раз (в плейлисте)
            let mine = Set(playlist.map(\.mediaID))
            recent.removeAll { mine.contains($0.mediaId) }
            loading = false
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.sheet)
    }

    private var uploadRow: some View {
        Button {
            dismiss()
            onUpload()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill").font(.system(size: 19)).foregroundStyle(.white)
                    .frame(width: 46, height: 46).background(theme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.t("Загрузить с телефона", "Upload from phone")).font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                    Text("MP3, M4A, AAC").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list").font(.system(size: 42, weight: .light)).foregroundStyle(theme.textTertiary)
            Text(query.isEmpty ? s.t("Музыки пока нет", "No music yet") : s.t("Ничего не найдено", "Nothing found"))
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
            if query.isEmpty {
                Text(s.t("Здесь появятся треки из ваших переписок и плейлиста.", "Tracks from your chats and playlist show up here."))
                    .font(.system(size: 14)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
            }
        }
        .padding(32).frame(maxWidth: .infinity)
    }

    private func trackRow(_ row: Row, queue: [Row]) -> some View {
        let index = selected.firstIndex(of: row.id)
        let current = player.isCurrent(row.track)
        return HStack(spacing: 12) {
            // обложка: нажатие — послушать (как в Telegram), сам ряд — выбрать
            Button {
                Haptics.impact(.light)
                player.toggle(row.track, queue: queue.map(\.track))
            } label: {
                ZStack {
                    if let cover = row.track.cover {
                        RemoteImage(id: cover, maxPixel: 200)
                    } else {
                        LinearGradient(colors: [theme.accentColor, theme.accentColor.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    Circle().fill(.black.opacity(current || row.track.cover == nil ? 0.28 : 0.0))
                    Image(systemName: current && player.isPlaying ? "pause.fill" : (current || row.track.cover == nil ? "play.fill" : "music.note"))
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .opacity(row.track.cover == nil || current ? 1 : 0)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 46, height: 46).clipShape(Circle())
            }
            .buttonStyle(PressStyle())
            VStack(alignment: .leading, spacing: 2) {
                Text(row.track.title).font(.system(size: 16, weight: current ? .semibold : .regular))
                    .foregroundStyle(current ? theme.accentColor : theme.text).lineLimit(1)
                Text((row.track.artist.isEmpty ? "" : row.track.artist + " · ") + Self.time(row.track.duration))
                    .font(.system(size: 13).monospacedDigit()).foregroundStyle(theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            ZStack {
                Circle().stroke(index == nil ? theme.textTertiary : theme.accentColor, lineWidth: 1.6)
                if let index {
                    Circle().fill(theme.accentColor)
                    Text("\(index + 1)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(index == nil ? Color.clear : theme.accentColor.opacity(0.07))
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.select()
            if let index { selected.remove(at: index) } else if selected.count < 10 { selected.append(row.id) }
        }
    }

    @ViewBuilder
    private var sendBar: some View {
        if !selected.isEmpty {
            VStack(spacing: 6) {
                if failed {
                    Text(s.api(.offline)).font(.system(size: 13)).foregroundStyle(theme.danger)
                }
                Button { send() } label: {
                    HStack(spacing: 8) {
                        if sending { ProgressView().tint(.white) }
                        Text(s.t("Отправить", "Send") + " (\(selected.count))").font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 54)
                    .background(theme.accent, in: Capsule())
                    .shadow(color: theme.accentColor.opacity(0.4), radius: 10, y: 4)
                }
                .buttonStyle(PressStyle())
                .disabled(sending)
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func send() {
        let rows = selected.compactMap { id in allRows.first { $0.id == id } ?? (recentRowsAll + playlistRowsAll).first { $0.id == id } }
        guard !rows.isEmpty else { return }
        sending = true
        failed = false
        Task {
            var out: [AudioCopy] = []
            for r in rows {
                // своя копия на сервере: удалят сообщение — оригинал (в чужой переписке или в плейлисте) останется
                let repo = session.messengerRepo
                var copy: AudioCopy?
                if let mid = r.messageID {
                    copy = try? await repo.audioCopy(messageID: mid, mediaID: r.track.mediaID)
                } else {
                    copy = try? await repo.playlistCopy(trackID: r.track.id)
                }
                guard let copy else { failed = true; sending = false; return }
                out.append(copy)
            }
            sending = false
            Haptics.notify(.success)
            dismiss()
            onPick(out)
        }
    }

    // выбранное могло скрыться поиском — ищем и среди всех
    private var recentRowsAll: [Row] {
        recent.map { r in
            Row(id: "r:" + r.mediaId, track: Track(id: r.mediaId, mediaID: r.mediaId, title: r.title, artist: r.artist,
                                                   duration: r.duration, cover: r.thumb), messageID: r.messageId)
        }
    }
    private var playlistRowsAll: [Row] { playlist.map { Row(id: "p:" + $0.id, track: $0, messageID: nil) } }

    static func time(_ d: Double) -> String {
        let t = Int(d.isFinite ? max(0, d) : 0)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
