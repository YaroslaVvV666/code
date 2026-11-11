import SwiftUI
import Combine

// MARK: - Комментарии: дерево ответов, как в TikTok

struct CommentsSheet: View {
    let post: Post
    @ObservedObject var vm: FeedViewModel
    var onClose: (() -> Void)? = nil              // задано — панель показана не системной шторкой, а поверх экрана
    /// Задано — вместо поля ввода кнопка «Добавить комментарий…», которая открывает обычную панель
    /// (комментарии сбоку повёрнутого видео: системная клавиатура не поворачивается вместе с ним)
    var onWriteElsewhere: (() -> Void)? = nil
    /// Панель поверх экрана: тянут за шапку (заголовок + фильтры) — двигаем панель; ended — отпустили
    var onHeaderDrag: ((DragGesture.Value, Bool) -> Void)? = nil

    enum Sort: String, CaseIterable { case popular, new, old }
    @AppStorage("comments.sort") private var sortRaw = Sort.popular.rawValue
    private var sort: Sort { Sort(rawValue: sortRaw) ?? .popular }

    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var comments: [Comment] = []
    @State private var loaded = false
    @State private var draft = ""
    @State private var replyTarget: Comment?
    @State private var expanded: Set<String> = []
    @FocusState private var inputFocused: Bool

    private var s: Strings { Strings(lang: lang) }
    private var canComment: Bool { post.commentsEnabled || post.isMine }

    // MARK: Дерево

    private enum Entry: Identifiable {
        case comment(Comment, depth: Int)
        case more(Comment, count: Int, depth: Int)       // «Показать ответы»
        case less(Comment, depth: Int)                   // «Скрыть ответы»

        var id: String {
            switch self {
            case .comment(let c, _):  return "c-" + c.id
            case .more(let c, _, _):  return "m-" + c.id
            case .less(let c, _):     return "l-" + c.id
            }
        }
    }

    private var children: [String?: [Comment]] {
        Dictionary(grouping: comments, by: { $0.parentID }).mapValues { list in
            list.sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                // верхний уровень — по выбранному фильтру; ответы всегда по порядку, как шла переписка
                if a.parentID == nil && b.parentID == nil {
                    switch sort {
                    case .popular: if a.likes != b.likes { return a.likes > b.likes }; return a.createdAt > b.createdAt
                    case .new: return a.createdAt > b.createdAt
                    case .old: return a.createdAt < b.createdAt
                    }
                }
                return a.createdAt < b.createdAt
            }
        }
    }

    private func descendantCount(of id: String, in tree: [String?: [Comment]]) -> Int {
        (tree[id] ?? []).reduce(0) { $0 + 1 + descendantCount(of: $1.id, in: tree) }
    }

    private var entries: [Entry] {
        let tree = children
        var result: [Entry] = []
        func walk(_ parent: String?, depth: Int) {
            for comment in tree[parent] ?? [] {
                result.append(.comment(comment, depth: depth))
                let count = descendantCount(of: comment.id, in: tree)
                guard count > 0 else { continue }
                if expanded.contains(comment.id) {
                    walk(comment.id, depth: depth + 1)
                    result.append(.less(comment, depth: depth + 1))
                } else {
                    result.append(.more(comment, count: count, depth: depth + 1))
                }
            }
        }
        walk(nil, depth: 0)
        return result
    }

    // MARK: Экран

    var body: some View {
        VStack(spacing: 0) {
            // шапка с фильтрами — большая область, за которую панель тянется вниз (закрыть) и вверх
            VStack(spacing: 0) {
                header
                if comments.count > 1 { sortBar }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { v in onHeaderDrag?(v, false) }
                .onEnded { v in onHeaderDrag?(v, true) })
            if comments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(theme.textTertiary)
                    Text(loaded ? s.noComments : "")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            switch entry {
                            case .comment(let comment, let depth):
                                row(comment, depth: depth)
                            case .more(let comment, let count, let depth):
                                toggleRow(s.showReplies(count), systemImage: "chevron.down", depth: depth) {
                                    withAnimation(.easeOut(duration: 0.2)) { _ = expanded.insert(comment.id) }
                                }
                            case .less(let comment, let depth):
                                toggleRow(s.hideReplies, systemImage: "chevron.up", depth: depth) {
                                    withAnimation(.easeOut(duration: 0.2)) { _ = expanded.remove(comment.id) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                // список в самом верху: потянул вниз за любое место — панель закрывается
                .modifier(PullDownToClose(enabled: onClose != nil) { onClose?() })
                .animation(.spring(response: 0.36, dampingFraction: 0.86), value: sortRaw)
            }
            inputBar
        }
        .background(theme.sheet)
        .task {
            comments = await vm.comments(for: post)
            loaded = true
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack {
            Color.clear.frame(width: 34, height: 34)
            Spacer()
            Text(s.commentsCount(comments.count))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.text)
            Spacer()
            Button { if let onClose { onClose() } else { dismiss() } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 34, height: 34)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    /// Новые / Популярные / Старые — как в TikTok и Telegram
    private var sortBar: some View {
        HStack(spacing: 8) {
            ForEach(Sort.allCases, id: \.self) { k in
                let on = sort == k
                Button {
                    Haptics.select()
                    sortRaw = k.rawValue
                } label: {
                    Text(k == .popular ? s.t("Популярные", "Top") : (k == .new ? s.t("Новые", "Newest") : s.t("Старые", "Oldest")))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(on ? Color.white : theme.textSecondary)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(on ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.surface), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.18), value: sortRaw)
    }

    // MARK: Строка

    private func indent(_ depth: Int) -> CGFloat { CGFloat(min(depth, 3)) * 44 }

    private func row(_ comment: Comment, depth: Int) -> some View {
        let isAuthor = comment.author.id == post.author.id
        return HStack(alignment: .top, spacing: 10) {
            AvatarView(name: comment.author.name, size: depth == 0 ? 40 : 30, avatarID: comment.author.avatarID)

            VStack(alignment: .leading, spacing: 4) {
                if comment.pinned {
                    Label(s.pinnedLabel, systemImage: "pin.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.accentColor)
                }
                HStack(spacing: 6) {
                    Text(comment.author.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    if isAuthor {
                        Text(s.authorTag)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.accentColor, in: Capsule())
                    }
                }

                commentText(comment)

                HStack(spacing: 16) {
                    Text(timeText(comment.createdAt))
                        .foregroundStyle(theme.textTertiary)
                    if canComment {
                        Button(s.replyAction) { startReply(to: comment) }
                            .fontWeight(.semibold)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .font(.system(size: 13))
                .padding(.top, 1)
            }

            Spacer(minLength: 4)

            likeButton(comment)
        }
        .padding(.leading, indent(depth))
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            if canComment {
                Button { startReply(to: comment) } label: { Label(s.replyAction, systemImage: "arrowshape.turn.up.left") }
            }
            if post.isMine && comment.parentID == nil {
                Button { togglePin(comment) } label: {
                    Label(comment.pinned ? s.unpinComment : s.pinComment, systemImage: comment.pinned ? "pin.slash" : "pin")
                }
            }
            Button { UIPasteboard.general.string = comment.text } label: {
                Label(s.copyText, systemImage: "doc.on.doc")
            }
        }
    }

    private func toggleRow(_ title: String, systemImage: String, depth: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Rectangle().fill(theme.stroke).frame(width: 22, height: 1)
                Text(title).font(.system(size: 12, weight: .semibold))
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.leading, indent(depth) + 44)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Длинный комментарий — свёрнут до 6 строк, «Ещё» / «Свернуть»
    private func commentText(_ comment: Comment) -> some View {
        ExpandableBlock(collapsedHeight: 118) { commentBody(comment) }
    }

    @ViewBuilder
    private func commentBody(_ comment: Comment) -> some View {
        if let name = comment.replyToName, comment.parentID != nil {
            (Text(name + " ").foregroundStyle(theme.accentColor).fontWeight(.semibold)
             + Text(Linkify.attributed(comment.text)).foregroundStyle(theme.text))
                .font(.system(size: 15))
                .tint(theme.accentColor)
        } else {
            LinkText(text: comment.text, tint: theme.accentColor)
                .font(.system(size: 15))
                .foregroundStyle(theme.text)
        }
    }

    private func timeText(_ date: Date) -> String { agoText(date, lang: lang) }

    /// Сердечко и число под ним, как в TikTok
    private func likeButton(_ comment: Comment) -> some View {
        Button { toggleLike(comment) } label: {
            VStack(spacing: 2) {
                Image(systemName: comment.likedByMe ? "heart.fill" : "heart")
                    .font(.system(size: 28))
                    .foregroundStyle(comment.likedByMe ? theme.like : theme.textTertiary)
                    .symbolEffect(.bounce, value: comment.likedByMe)
                Text(comment.likes > 0 ? "\(comment.likes)" : " ")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
            .frame(width: 48)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if comment.likedByAuthor {
                Image(systemName: "heart.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.like)
                    .background(theme.sheet, in: Circle())
                    .offset(x: 4, y: -4)
                    .accessibilityLabel(s.likedByAuthorLabel)
            }
        }
    }

    // MARK: Действия

    private func update(_ id: String, _ change: (inout Comment) -> Void) {
        if let i = comments.firstIndex(where: { $0.id == id }) { change(&comments[i]) }
    }

    private func toggleLike(_ comment: Comment) {
        let liked = !comment.likedByMe
        let isMineAsAuthor = post.isMine
        update(comment.id) {
            $0.likedByMe = liked
            $0.likes = max(0, $0.likes + (liked ? 1 : -1))
            if isMineAsAuthor { $0.likedByAuthor = liked }
        }
        Haptics.impact(.light)
        Task { @MainActor in
            if await !vm.setCommentLike(comment.id, liked: liked) {
                update(comment.id) {
                    $0.likedByMe = !liked
                    $0.likes = max(0, $0.likes + (liked ? -1 : 1))
                    if isMineAsAuthor { $0.likedByAuthor = !liked }
                }
            }
        }
    }

    private func togglePin(_ comment: Comment) {
        let pin = !comment.pinned
        let before = comments
        for i in comments.indices { comments[i].pinned = false }
        update(comment.id) { $0.pinned = pin }
        Task { @MainActor in
            if await !vm.setCommentPin(comment.id, pinned: pin) { comments = before }
        }
    }

    private func startReply(to comment: Comment) {
        if let onWriteElsewhere { onWriteElsewhere(); return }      // сбоку повёрнутого видео — отвечаем в обычной панели
        replyTarget = comment
        inputFocused = true
    }

    // MARK: Ввод

    @ViewBuilder
    private var inputBar: some View {
        if canComment {
            VStack(spacing: 0) {
                if let target = replyTarget {
                    HStack(spacing: 8) {
                        Text("\(s.replyingTo) \(target.author.name)")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        Button { replyTarget = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(theme.textTertiary)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                }

                HStack(spacing: 10) {
                    AvatarView(name: session.profile.profile?.name ?? "", size: 34,
                               avatarID: session.profile.profile?.avatarID)

                    if let onWriteElsewhere {
                        Button(action: onWriteElsewhere) {
                            Text(s.writeComment)
                                .foregroundStyle(theme.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .frame(height: 42)
                                .background(theme.surface, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
                    TextField(s.writeComment, text: $draft)
                        .focused($inputFocused)
                        .foregroundStyle(theme.text)
                        .tint(theme.accentColor)
                        .padding(.horizontal, 16)
                        .frame(height: 42)
                        .background(theme.surface, in: Capsule())

                    let empty = draft.trimmingCharacters(in: .whitespaces).isEmpty
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 40, height: 40)
                            .background(empty ? AnyShapeStyle(Color.gray.opacity(0.4)) : AnyShapeStyle(theme.accent),
                                        in: Circle())
                    }
                    .disabled(empty)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(theme.sheet)
            .overlay(alignment: .top) { Rectangle().fill(theme.stroke).frame(height: 1) }
        } else {
            Text(s.commentsOff)
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(theme.sheet)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let target = replyTarget
        draft = ""
        replyTarget = nil
        inputFocused = false
        Task { @MainActor in
            // ответ крепится прямо к тому комментарию, на который отвечают
            if let comment = await vm.addComment(to: post, text: text, parentID: target?.id) {
                comments.append(comment)
                // раскрываем всю цепочку, чтобы новый ответ был виден
                var id = comment.parentID
                while let current = id {
                    expanded.insert(current)
                    id = comments.first { $0.id == current }?.parentID
                }
            }
        }
    }
}

/// Список в самом верху, потянули вниз и отпустили — закрыть панель (iOS 18+; раньше закрывается за шапку)
struct PullDownToClose: ViewModifier {
    let enabled: Bool
    let onClose: () -> Void
    @State private var over: CGFloat = 0

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), enabled {
            content
                .onScrollGeometryChange(for: Int.self) { g in
                    let o = -(g.contentOffset.y + g.contentInsets.top)
                    return o > 2 ? Int(o / 8) : 0
                } action: { _, step in over = CGFloat(step) * 8 }
                .onScrollPhaseChange { old, new in
                    if old == .interacting, new != .interacting, over > 70 {
                        Haptics.impact(.light)
                        onClose()
                    }
                }
        } else {
            content
        }
    }
}
