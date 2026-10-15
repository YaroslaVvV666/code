import SwiftUI
import Contacts

// MARK: - Записная книга телефона

enum AddressBook {
    /// nil — нет доступа к контактам
    static func load() async -> [BookEntry]? {
        let granted = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        guard granted else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> [BookEntry] in
            let store = CNContactStore()
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var out: [BookEntry] = []
            try? store.enumerateContacts(with: request) { contact, _ in
                let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                for number in contact.phoneNumbers {
                    out.append(BookEntry(name: name, phone: number.value.stringValue))
                }
            }
            return out
        }.value
    }
}

// MARK: - Найти друзей из контактов

struct ContactsImportSheet: View {
    var onOpenChat: ((ChatPeer) -> Void)? = nil

    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    private enum Stage { case intro, working, result, denied }
    @State private var stage: Stage = .intro
    @State private var matches: [ImportMatch] = []
    @State private var chosen: Set<String> = []
    @State private var total = 0
    @State private var busy = false
    @State private var errorText: String?
    @State private var done: String?
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    switch stage {
                    case .intro: intro
                    case .working: working
                    case .result: result
                    case .denied: denied
                    }
                    if let errorText { Text(errorText).font(.system(size: 13)).foregroundStyle(theme.danger) }
                }
                .padding(20)
            }
            .navigationTitle(s.t("Найти друзей", "Find friends"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(s.close) { dismiss() } } }
        }
    }

    private func hero(_ icon: String) -> some View {
        Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(theme.accentColor)
            .frame(width: 84, height: 84).card(theme, radius: 42).padding(.top, 10)
    }

    private var intro: some View {
        VStack(spacing: 14) {
            hero("person.2.wave.2.fill")
            Text(s.t("Друзья из записной книги", "Friends from your address book"))
                .font(.system(size: 22, weight: .bold)).foregroundStyle(theme.text).multilineTextAlignment(.center)
            Text(s.t("Orbita сравнит номера из ваших контактов с номерами пользователей и покажет, кто уже здесь. Когда кто-то из знакомых зарегистрируется, вам придёт уведомление. Номера нигде не показываются, а загруженное можно удалить в любой момент.",
                     "Orbita compares numbers in your contacts with Orbita users and shows who's already here. You'll be notified when someone you know joins. Numbers are never shown to anyone and you can delete the uploaded list at any time."))
                .font(.system(size: 15)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
            PrimaryButton(title: s.t("Разрешить и найти", "Allow and find"), enabled: true, loading: false) { run() }
                .padding(.top, 6)
        }
    }

    private var working: some View {
        VStack(spacing: 14) {
            ProgressView().padding(.top, 60)
            Text(s.t("Ищем друзей…", "Looking for friends…")).font(.system(size: 15)).foregroundStyle(theme.textSecondary)
        }
    }

    private var denied: some View {
        VStack(spacing: 14) {
            hero("lock.fill")
            Text(s.t("Нет доступа к контактам", "No access to contacts"))
                .font(.system(size: 20, weight: .bold)).foregroundStyle(theme.text)
            Text(s.t("Разрешите доступ в Настройках iPhone → Orbita → Контакты.", "Allow access in iPhone Settings → Orbita → Contacts."))
                .font(.system(size: 15)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
            PrimaryButton(title: s.t("Открыть настройки", "Open Settings"), enabled: true, loading: false) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 14) {
            if matches.isEmpty {
                hero("person.crop.circle.badge.questionmark").frame(maxWidth: .infinity)
                Text(s.t("Пока никого из ваших контактов нет в Orbita", "None of your contacts are on Orbita yet"))
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.text)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                Text(s.t("Мы сообщим, когда кто-то из них появится. А пока можно пригласить их.", "We'll tell you when someone joins. Meanwhile you can invite them."))
                    .font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center)
            } else {
                Text(s.t("УЖЕ В ORBITA", "ALREADY ON ORBITA") + " · \(matches.count)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                VStack(spacing: 0) {
                    ForEach(matches) { m in matchRow(m) }
                }
                .card(theme, radius: 16)
                let addable = chosen.count
                PrimaryButton(title: s.t("Добавить в контакты", "Add to contacts") + (addable > 0 ? " (\(addable))" : ""),
                              enabled: addable > 0, loading: busy) { addChosen() }
            }
            if let done { Text(done).font(.system(size: 14)).foregroundStyle(theme.accentColor).frame(maxWidth: .infinity) }
            InviteOutsidersLink()
            Button { forget() } label: {
                Text(s.t("Удалить загруженные контакты", "Delete uploaded contacts"))
                    .font(.system(size: 14)).foregroundStyle(theme.danger).frame(maxWidth: .infinity).padding(.top, 8)
            }
            .buttonStyle(.plain)
        }
    }

    private func matchRow(_ m: ImportMatch) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: m.name, size: 44, avatarID: m.avatarID).clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(m.bookName.isEmpty ? m.name : m.bookName).font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.text).lineLimit(1)
                Text(m.username.map { "@" + $0 } ?? m.name).font(.system(size: 13)).foregroundStyle(theme.textTertiary).lineLimit(1)
            }
            Spacer()
            if m.inContacts {
                Text(s.t("в контактах", "saved")).font(.system(size: 12)).foregroundStyle(theme.textTertiary)
            } else {
                Image(systemName: chosen.contains(m.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(chosen.contains(m.id) ? theme.accentColor : theme.textTertiary)
            }
            Button {
                dismiss()
                onOpenChat?(ChatPeer(id: m.id, name: m.bookName.isEmpty ? m.name : m.bookName, username: m.username, avatarID: m.avatarID))
            } label: {
                Image(systemName: "paperplane.fill").font(.system(size: 14)).foregroundStyle(theme.accentColor)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .opacity(onOpenChat == nil ? 0 : 1)
            .disabled(onOpenChat == nil)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !m.inContacts else { return }
            Haptics.select()
            if chosen.contains(m.id) { chosen.remove(m.id) } else { chosen.insert(m.id) }
        }
    }

    // MARK: Действия

    private func run() {
        errorText = nil
        stage = .working
        Task {
            guard let book = await AddressBook.load() else { stage = .denied; return }
            // Один и тот же номер у нескольких записей не нужен
            var seen = Set<String>()
            let entries = book.filter { seen.insert($0.phone.filter(\.isNumber)).inserted }
            total = entries.count
            do {
                var found: [ImportMatch] = []
                var index = 0
                while index < max(entries.count, 1) {
                    let chunk = Array(entries[index..<min(index + 500, entries.count)])
                    if !chunk.isEmpty { found += try await session.messengerRepo.importContacts(chunk) }
                    index += 500
                }
                var unique: [String: ImportMatch] = [:]
                for m in found { unique[m.id] = m }
                matches = unique.values.sorted { $0.bookName.lowercased() < $1.bookName.lowercased() }
                chosen = Set(matches.filter { !$0.inContacts }.map(\.id))
                stage = .result
                Haptics.notify(.success)
            } catch {
                errorText = s.api((error as? APIError) ?? .offline)
                stage = .intro
            }
        }
    }

    private func addChosen() {
        busy = true
        Task {
            defer { busy = false }
            var added = 0
            for m in matches where chosen.contains(m.id) {
                let name = m.bookName.isEmpty ? m.name : m.bookName
                if (try? await session.messengerRepo.saveContact(id: m.id, name: name)) != nil {
                    added += 1
                    if let i = matches.firstIndex(where: { $0.id == m.id }) { matches[i].inContacts = true }
                }
            }
            chosen = []
            done = s.t("Добавлено в контакты: \(added)", "Added to contacts: \(added)")
            Haptics.notify(.success)
            await session.chats.refresh()
        }
    }

    private func forget() {
        Task {
            try? await session.messengerRepo.forgetImportedContacts()
            matches = []
            chosen = []
            done = s.t("Загруженные контакты удалены", "Uploaded contacts deleted")
            UserDefaults.standard.set(true, forKey: "contacts.prompted")
        }
    }
}

// MARK: - Карточки в начале списка чатов

struct JoinNoticeCard: View {
    let notice: JoinNotice
    let onWrite: () -> Void
    let onClose: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: notice.name, size: 44, avatarID: notice.avatarID).clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Text(s.t("теперь в Orbita", "joined Orbita")).font(.system(size: 14)).foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Button(action: onWrite) {
                Text(s.t("Написать", "Message")).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 32).background(theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.textTertiary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 10).card(theme, radius: 16)
    }
}

struct ImportPromptCard: View {
    let onOpen: () -> Void
    let onClose: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.wave.2.fill").font(.system(size: 20)).foregroundStyle(theme.accentColor)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.t("Найдите друзей", "Find your friends")).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                Text(s.t("Кто из контактов уже в Orbita", "See who from your contacts is here"))
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Button(action: onOpen) {
                Text(s.t("Открыть", "Open")).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 32).background(theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.textTertiary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 10).card(theme, radius: 16)
    }
}
