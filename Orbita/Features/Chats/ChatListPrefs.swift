import SwiftUI
import Combine

/// Закреплённые чаты (хранятся на устройстве)
@MainActor
final class ChatListPrefs: ObservableObject {
    static let shared = ChatListPrefs()
    @Published private(set) var pinned: [String]
    /// Чаты, помеченные вручную как «новое» (кружок без числа)
    @Published private(set) var marked: Set<String>
    /// Архивированные чаты (прячутся из списка на отдельную полку сверху)
    @Published private(set) var archived: Set<String>
    /// Меняется при смене «без звука» у личных переписок — чтобы список перерисовался
    @Published private(set) var muteTick = 0

    init() {
        pinned = UserDefaults.standard.stringArray(forKey: "chats.pinned") ?? []
        marked = Set(UserDefaults.standard.stringArray(forKey: "chats.marked") ?? [])
        archived = Set(UserDefaults.standard.stringArray(forKey: "chats.archived") ?? [])
    }

    func isMarked(_ id: String) -> Bool { marked.contains(id) }

    func toggleMarked(_ id: String) {
        if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
        UserDefaults.standard.set(Array(marked), forKey: "chats.marked")
    }

    func clearMarked(_ id: String) {
        guard marked.remove(id) != nil else { return }
        UserDefaults.standard.set(Array(marked), forKey: "chats.marked")
    }

    func isDMMuted(_ id: String) -> Bool { UserDefaults.standard.bool(forKey: "dm_muted_" + id) }

    func setDMMuted(_ id: String, _ muted: Bool) {
        UserDefaults.standard.set(muted, forKey: "dm_muted_" + id)
        muteTick += 1
    }

    func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    func toggle(_ id: String) {
        if let i = pinned.firstIndex(of: id) { pinned.remove(at: i) }
        else if pinned.count < 5 { pinned.insert(id, at: 0) }
        UserDefaults.standard.set(pinned, forKey: "chats.pinned")
    }

    func isArchived(_ id: String) -> Bool { archived.contains(id) }

    func toggleArchive(_ id: String) {
        if archived.contains(id) {
            archived.remove(id)
        } else {
            archived.insert(id)
            // архивированный не может быть одновременно закреплён сверху
            if let i = pinned.firstIndex(of: id) {
                pinned.remove(at: i)
                UserDefaults.standard.set(pinned, forKey: "chats.pinned")
            }
        }
        UserDefaults.standard.set(Array(archived), forKey: "chats.archived")
    }
}

enum ChatFolder: String, CaseIterable {
    case all, unread, personal, groups, channels

    func title(_ s: Strings) -> String {
        switch self {
        case .all: return s.t("Все", "All")
        case .unread: return s.t("Новые", "Unread")
        case .personal: return s.t("Личные", "Personal")
        case .groups: return s.t("Группы", "Groups")
        case .channels: return s.t("Каналы", "Channels")
        }
    }

    func contains(_ chat: ChatSummary) -> Bool {
        switch self {
        case .all: return true
        case .unread: return chat.unread > 0 || chat.mentions > 0
        case .personal: return !chat.peer.isGroup
        case .groups: return chat.peer.isGroup && !chat.peer.isChannel
        case .channels: return chat.peer.isChannel
        }
    }
}

struct FolderBar: View {
    @Binding var folder: ChatFolder
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ChatFolder.allCases, id: \.self) { f in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { folder = f }; Haptics.impact(.light) } label: {
                        Text(f.title(Strings(lang: lang)))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(folder == f ? Color.white : theme.textSecondary)
                            .padding(.horizontal, 14).frame(height: 32)
                            .background(folder == f ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.surface), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 6)
    }
}

// MARK: - Поиск внутри чата

struct ChatSearchSheet: View {
    let load: () async -> [ChatMessage]
    let onPick: (String) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var all: [ChatMessage] = []
    @State private var loaded = false
    @FocusState private var focused: Bool

    private var results: [ChatMessage] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 1 else { return [] }
        return all.filter { !$0.text.hasPrefix("\u{200B}call:") && $0.summary.lowercased().contains(q) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        let s = Strings(lang: lang)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.textTertiary)
                TextField(s.t("Поиск по переписке", "Search messages"), text: $query)
                    .focused($focused).submitLabel(.search)
                    .autocorrectionDisabled()
                Button(s.t("Отмена", "Cancel")) { dismiss() }.foregroundStyle(theme.accentColor)
            }
            .padding(.horizontal, 14).frame(height: 44)
            .card(theme, radius: 14)
            .padding(16)

            if !loaded {
                ProgressView().padding(.top, 40)
            } else if results.isEmpty {
                Text(query.isEmpty ? s.t("Введите слово для поиска", "Type to search") : s.t("Ничего не найдено", "Nothing found"))
                    .font(.system(size: 15)).foregroundStyle(theme.textSecondary).padding(.top, 40)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { m in
                        Button { Haptics.impact(.light); dismiss(); onPick(m.id) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(m.mine ? s.t("Вы", "You") : (m.sender?.name ?? ""))
                                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accentColor)
                                    Spacer()
                                    Text(ChatTime.short(m.createdAt, lang: lang))
                                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                                }
                                Text(m.summary).font(.system(size: 15)).foregroundStyle(theme.text)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().opacity(0.3).padding(.leading, 76)
                    }
                }
            }
        }
        .task {
            all = await load(); loaded = true
            focused = true
        }
    }
}


// MARK: - Список найденных сообщений (как в Telegram: открыть список и выбрать)

struct SearchResultsSheet: View {
    let hits: [ChatMessage]
    let query: String
    let current: String?
    var peer: ChatPeer? = nil
    var myName: String = ""
    var myAvatar: String? = nil
    let onPick: (Int) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss

    private func highlighted(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return out }
        var from = out.startIndex
        while from < out.endIndex, let r = out[from...].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            out[r].foregroundColor = theme.accentColor
            out[r].font = .system(size: 15, weight: .bold)
            from = r.upperBound
        }
        return out
    }

    var body: some View {
        let s = Strings(lang: lang)
        VStack(spacing: 0) {
            HStack {
                Text(s.t("Найдено: \(hits.count)", "Found: \(hits.count)")).font(.system(size: 18, weight: .bold)).foregroundStyle(theme.text)
                Spacer()
                Button(s.close) { dismiss() }.foregroundStyle(theme.accentColor)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { i, m in
                        Button { Haptics.impact(.light); dismiss(); onPick(i) } label: {
                            let who: ChatPeer? = m.mine ? nil : (m.sender ?? peer)
                            let name = m.mine ? s.t("Вы", "You") : (who?.name ?? "")
                            HStack(alignment: .top, spacing: 12) {
                                AvatarView(name: m.mine ? myName : name, size: 48,
                                           avatarID: m.mine ? myAvatar : who?.avatarID).clipShape(Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text(name).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(ChatTime.short(m.createdAt, lang: lang))
                                            .font(.system(size: 13)).foregroundStyle(theme.textTertiary)
                                    }
                                    Text(highlighted(m.summary)).font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(m.id == current ? theme.accentColor.opacity(0.12) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().opacity(0.3).padding(.leading, 76)
                    }
                }
            }
        }
    }
}
