import SwiftUI
import Combine
import AVFoundation

// MARK: - Пометки шортса и страница поста целиком
// Пометки («Создано ИИ», место, «Реклама»…) — над ником автора. Длинная подпись сворачивается с «ещё»;
// нажатие открывает страницу поста, как в TikTok: медиа сверху, полное описание, хэштеги, звук, дата, комментарии.

/// Пометки строкой: значок + текст на тёмной подложке
struct PostLabelsRow: View {
    let labels: [PostLabel]
    var onDark = true
    @Environment(\.lang) private var lang
    @Environment(\.theme) private var theme

    var body: some View {
        let s = Strings(lang: lang)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(labels, id: \.self) { l in
                    HStack(spacing: 4) {
                        Image(systemName: l.icon).font(.system(size: 11, weight: .bold))
                        Text(l.title(s)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundStyle(onDark ? Color.white : theme.text)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(onDark ? Color.black.opacity(0.4) : theme.text.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
        .scrollDisabled(labels.count < 3)
    }
}

/// Пометки при публикации шортса
struct ReelLabelsCard: View {
    @Binding var labels: [PostLabel]
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var place = ""
    @State private var custom = ""

    private var s: Strings { Strings(lang: lang) }

    private func has(_ k: PostLabel.Kind) -> Bool { labels.contains { $0.kind == k } }

    private func toggle(_ k: PostLabel.Kind) {
        Haptics.select()
        if has(k) { labels.removeAll { $0.kind == k } } else if labels.count < 3 { labels.append(PostLabel(kind: k)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s.t("ПОМЕТКИ", "LABELS")).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
            VStack(spacing: 0) {
                toggleRow(.ai, s.t("Создано ИИ", "AI-generated"), s.t("Видео или фото сделаны нейросетью", "Made with AI tools"))
                Rectangle().fill(theme.stroke).frame(height: 0.5).padding(.leading, 52)
                toggleRow(.ad, s.t("Реклама", "Ad"), s.t("Платное размещение или реклама бренда", "Paid or branded content"))
                Rectangle().fill(theme.stroke).frame(height: 0.5).padding(.leading, 52)
                fieldRow(icon: "mappin.and.ellipse", placeholder: s.t("Место, например «Улица Пушкина»", "Place, e.g. “Abbey Road”"),
                         text: $place, kind: .place, limit: 60)
                Rectangle().fill(theme.stroke).frame(height: 0.5).padding(.leading, 52)
                fieldRow(icon: "tag.fill", placeholder: s.t("Своя пометка", "Custom label"), text: $custom, kind: .custom, limit: 30)
            }
            .card(theme, radius: 16)
            if !labels.isEmpty {
                PostLabelsRow(labels: labels, onDark: false)
                Text(s.t("Так пометки будут над вашим ником. Не больше трёх.", "Shown above your name. Up to three."))
                    .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
            }
        }
        .onAppear {
            place = labels.first { $0.kind == .place }?.text ?? ""
            custom = labels.first { $0.kind == .custom }?.text ?? ""
        }
    }

    private func toggleRow(_ k: PostLabel.Kind, _ title: String, _ sub: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: PostLabel(kind: k).icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 16)).foregroundStyle(theme.text)
                Text(sub).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { has(k) }, set: { _ in toggle(k) })).labelsHidden().tint(theme.accentColor)
        }
        .padding(.horizontal, 12).frame(minHeight: 58)
    }

    private func fieldRow(icon: String, placeholder: String, text: Binding<String>, kind: PostLabel.Kind, limit: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accentColor).frame(width: 28)
            TextField(placeholder, text: text)
                .font(.system(size: 16)).foregroundStyle(theme.text)
                .submitLabel(.done)
                .onChange(of: text.wrappedValue) { _, v in
                    let t = String(v.prefix(limit))
                    if t != v { text.wrappedValue = t; return }
                    let clean = t.trimmingCharacters(in: .whitespaces)
                    if let i = labels.firstIndex(where: { $0.kind == kind }) {
                        if clean.isEmpty { labels.remove(at: i) } else { labels[i].text = clean }
                    } else if !clean.isEmpty, labels.count < 3 {
                        labels.append(PostLabel(kind: kind, text: clean))
                    }
                }
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 52)
    }
}

// MARK: - Страница поста

struct ReelDetailPage: View {
    let start: Reel
    let onClose: () -> Void
    var onOpenTag: (String) -> Void = { _ in }

    @EnvironmentObject private var session: AppSession
    @Environment(\.lang) private var lang
    @ObservedObject private var bookmarks = BookmarkStore.shared

    @State private var post: Post
    @State private var following: Bool
    @State private var page = 0
    @State private var comments: [Comment] = []
    @State private var loadedComments = false
    @State private var draft = ""
    @State private var sending = false
    @State private var muted = false
    @State private var player: AVPlayer?
    @State private var showAllComments = false
    @State private var showShare = false
    @State private var profileID: String?
    @State private var soundOpen: PostMusic?
    @FocusState private var inputFocused: Bool

    init(reel: Reel, onClose: @escaping () -> Void, onOpenTag: @escaping (String) -> Void = { _ in }) {
        self.start = reel
        self.onClose = onClose
        self.onOpenTag = onOpenTag
        _post = State(initialValue: reel.post)
        _following = State(initialValue: reel.state == "following")
    }

    private var s: Strings { Strings(lang: lang) }
    private var isVideo: Bool { post.media.count == 1 && post.media.first?.kind == .video }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    media
                    if post.media.count > 1 { dots.padding(.top, 10) }
                    details.padding(.horizontal, 16).padding(.top, 14)
                    Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5).padding(.horizontal, 16).padding(.vertical, 16)
                    commentsBlock.padding(.horizontal, 16)
                    Color.clear.frame(height: 30)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            bottomBar
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { startMedia(); markViewed() }
        .onDisappear { player?.pause(); player = nil; stopMusic() }
        .task { await loadComments() }
        .sheet(isPresented: $showAllComments) {
            CommentsSheet(post: post, vm: session.feed)
                .environmentObject(session)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showShare) {
            SendToChatSheet(postID: post.id).environmentObject(session)
        }
        .sheet(item: $soundOpen) { m in SoundSheet(music: m).environmentObject(session).environmentObject(session.player) }
        .profileSheet(id: $profileID)
        .edgeSwipeBack(enabled: true) { onClose() }
    }

    // MARK: Шапка: назад, автор, «Подписаться»

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "chevron.left").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { profileID = post.creator.id } label: {
                HStack(spacing: 10) {
                    AvatarView(name: post.creator.name, size: 34, avatarID: post.creator.avatarID).clipShape(Circle())
                    Text(post.creator.name).font(.system(size: 17, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            if !post.isMine {
                Button {
                    Haptics.impact(.light)
                    let on = !following
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { following = on }
                    let id = post.creator.id, pid = post.id
                    Task { _ = await session.extras.setFollow(id: id, on: on, source: pid) }
                } label: {
                    Text(following ? s.t("Вы подписаны", "Following") : s.t("Подписаться", "Follow"))
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 36)
                        .background(following ? Color.white.opacity(0.15) : Color(red: 1, green: 0.17, blue: 0.33), in: Capsule())
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5) }
    }

    // MARK: Медиа: фото листаются, видео играет; кнопка звука

    private var media: some View {
        let first = post.media.first
        let ratio: CGFloat = first.map { m in m.width > 0 && m.height > 0 ? min(1.5, max(0.8, CGFloat(m.height) / CGFloat(m.width))) : 1.25 } ?? 1.25
        return Color(white: 0.06)
            .aspectRatio(1 / ratio, contentMode: .fit)
            .overlay {
                if isVideo, let player {
                    PlayerLayerView(player: player, gravity: .resizeAspect)
                } else {
                    TabView(selection: $page) {
                        ForEach(Array(post.media.enumerated()), id: \.offset) { i, m in
                            RemoteImage(id: m.thumbID ?? m.id, fill: false, maxPixel: 1600).tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isVideo || post.music != nil {
                    Button {
                        Haptics.select()
                        muted.toggle()
                        player?.isMuted = muted
                        musicPlayer?.isMuted = muted
                    } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                }
            }
            .onTapGesture {
                if let player { player.timeControlStatus == .playing ? player.pause() : player.play() }
            }
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<post.media.count, id: \.self) { i in
                Circle().fill(Color.white.opacity(i == page ? 1 : 0.35)).frame(width: 7, height: 7)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: page)
    }

    // MARK: Описание целиком

    /// Первая строка — заголовком (жирно), если подпись из нескольких строк
    private var titleAndBody: (String?, String) {
        let full = post.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = full.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        if lines.count == 2, lines[0].count <= 80, !lines[0].hasPrefix("#") {
            return (String(lines[0]), String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (nil, full)
    }

    private var details: some View {
        let (title, body) = titleAndBody
        return VStack(alignment: .leading, spacing: 12) {
            if !post.labels.isEmpty { PostLabelsRow(labels: post.labels) }
            if let title {
                Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
            }
            if !body.isEmpty {
                Text(styled(body))
                    .font(.system(size: 17)).foregroundColor(.white.opacity(0.95))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .tint(Color(red: 0.4, green: 0.7, blue: 1))
                    .environment(\.openURL, OpenURLAction { url in
                        if url.scheme == "orbita-tag" {
                            let enc = String(url.absoluteString.dropFirst("orbita-tag:".count))
                            onOpenTag(enc.removingPercentEncoding ?? enc)
                            return .handled
                        }
                        return .systemAction
                    })
            }
            if let m = post.music {
                Button { soundOpen = m } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Color(red: 1, green: 0.2, blue: 0.35), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text(m.display).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    }
                    .padding(.leading, 5).padding(.trailing, 12).frame(height: 36)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Text(dateLine).font(.system(size: 14)).foregroundStyle(.white.opacity(0.5))
        }
    }

    private var dateLine: String {
        let sec = Date().timeIntervalSince(post.createdAt)
        if sec < 3600 { return s.t("\(max(1, Int(sec / 60))) мин. назад", "\(max(1, Int(sec / 60)))m ago") }
        if sec < 86400 { return s.t("\(Int(sec / 3600)) ч. назад", "\(Int(sec / 3600))h ago") }
        if sec < 7 * 86400 { return s.t("\(Int(sec / 86400)) дн. назад", "\(Int(sec / 86400))d ago") }
        return FormatterCache.format(post.createdAt, "d MMMM yyyy")
    }

    /// Хэштеги — голубые и нажимаются, ссылки — подчёркнуты
    private func styled(_ text: String) -> AttributedString {
        var out = AttributedString()
        for (li, line) in text.components(separatedBy: "\n").enumerated() {
            if li > 0 { out.append(AttributedString("\n")) }
            for (i, word) in line.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
                var piece = AttributedString((i == 0 ? "" : " ") + String(word))
                if word.hasPrefix("#"), let tag = ReelPage.tagLink(String(word)) {
                    piece.link = tag
                    piece.foregroundColor = Color(red: 0.4, green: 0.7, blue: 1)
                } else if let url = Linkify.url(in: String(word)) {
                    piece.link = url
                    piece.underlineStyle = .single
                }
                out.append(piece)
            }
        }
        return out
    }

    // MARK: Комментарии

    private var commentsBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { showAllComments = true } label: {
                HStack(spacing: 8) {
                    Text(s.t("\(post.comments) комментариев", "\(post.comments) comments"))
                        .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            if post.commentsEnabled || post.isMine {
                HStack(spacing: 10) {
                    AvatarView(name: session.profile.profile?.name ?? "", size: 40, avatarID: session.profile.profile?.avatarID)
                        .clipShape(Circle())
                    Text(s.t("Поделитесь своим мнением", "Share your thoughts"))
                        .font(.system(size: 16)).foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(Color.white.opacity(0.1), in: Capsule())
                        .onTapGesture { inputFocused = true }
                }
            }
            if !loadedComments {
                ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                ForEach(comments.filter { $0.parentID == nil }.prefix(30)) { c in commentRow(c) }
                if post.comments > comments.filter({ $0.parentID == nil }).prefix(30).count {
                    Button { showAllComments = true } label: {
                        Text(s.t("Все комментарии", "All comments")).font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func commentRow(_ c: Comment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(name: c.author.name, size: 40, avatarID: c.author.avatarID).clipShape(Circle())
                .onTapGesture { profileID = c.author.id }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(c.author.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    if c.author.id == post.creator.id {
                        Text("· " + s.t("Автор", "Creator")).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(red: 0.3, green: 0.75, blue: 0.95))
                    }
                }
                Text(c.text).font(.system(size: 16)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                let replies = comments.filter { $0.parentID == c.id }.count
                if replies > 0 {
                    Button { showAllComments = true } label: {
                        Text(s.t("Ответы: \(replies)", "\(replies) replies")).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 6)
            VStack(spacing: 2) {
                Image(systemName: c.likedByMe ? "heart.fill" : "heart").font(.system(size: 15))
                    .foregroundStyle(c.likedByMe ? Color(red: 1, green: 0.2, blue: 0.35) : .white.opacity(0.5))
                if c.likes > 0 { Text("\(c.likes)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)) }
            }
        }
    }

    // MARK: Низ: поле комментария, лайк, комментарии, избранное, поделиться

    private var bottomBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                TextField("", text: $draft, prompt: Text(s.t("Добавить комментарий…", "Add comment…")).foregroundColor(.white.opacity(0.4)))
                    .focused($inputFocused)
                    .foregroundStyle(.white).tint(.white)
                    .submitLabel(.send)
                    .onSubmit { send() }
                    .disabled(!(post.commentsEnabled || post.isMine))
                if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button { send() } label: {
                        Image(systemName: sending ? "ellipsis" : "arrow.up.circle.fill").font(.system(size: 26))
                            .foregroundStyle(Color(red: 1, green: 0.17, blue: 0.33))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).frame(height: 46)
            .background(Color.white.opacity(0.1), in: Capsule())
            if !inputFocused {
                barButton(post.likedByMe ? "heart.fill" : "heart", short(post.likes),
                          tint: post.likedByMe ? Color(red: 1, green: 0.2, blue: 0.35) : .white) { toggleLike() }
                barButton("ellipsis.bubble", short(post.comments)) { showAllComments = true }
                barButton(bookmarks.has(post.id) ? "bookmark.fill" : "bookmark", short(bookmarks.count(for: post)),
                          tint: bookmarks.has(post.id) ? Color(red: 1, green: 0.8, blue: 0.2) : .white) {
                    Haptics.impact(.light); bookmarks.toggle(post.id)
                }
                barButton("arrowshape.turn.up.right", short(post.reposts)) { showShare = true }
            }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
        .background(Color(white: 0.09).ignoresSafeArea(edges: .bottom))
        .animation(.easeOut(duration: 0.2), value: inputFocused)
    }

    private func barButton(_ icon: String, _ count: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 21, weight: .medium)).foregroundStyle(tint).frame(height: 24)
                Text(count).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white).lineLimit(1)
            }
            .frame(minWidth: 40)
        }
        .buttonStyle(PressStyle())
    }

    private func short(_ n: Int) -> String {
        func one(_ v: Double) -> String {
            let r = (v * 10).rounded() / 10
            return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r).replacingOccurrences(of: ".", with: ",")
        }
        if n >= 1_000_000 { return one(Double(n) / 1_000_000) + (lang == .ru ? " млн" : "M") }
        if n >= 1000 { return one(Double(n) / 1000) + (lang == .ru ? " тыс." : "K") }
        return "\(n)"
    }

    // MARK: Логика

    @State private var musicPlayer: AVPlayer?

    private func startMedia() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        if isVideo, let m = post.media.first, let url = ServerConfig.mediaURL(m.id) {
            let p = AVPlayer(url: url)
            p.actionAtItemEnd = .none
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
                p.seek(to: .zero); p.play()
            }
            MediaSilence.register(p)
            player = p
            p.play()
        } else if let mus = post.music, let url = ServerConfig.mediaURL(mus.mediaID) {
            let p = AVPlayer(url: url)
            MediaSilence.register(p)
            musicPlayer = p
            p.play()
        }
    }

    private func stopMusic() { musicPlayer?.pause(); musicPlayer = nil }

    /// Пост открыт на весь экран — это настоящий просмотр (в отличие от автопроигрывания в поиске)
    private func markViewed() {
        let pid = post.id
        Task { await session.extras.sendEvents([["type": "view", "post_id": pid, "ms": 3000, "ratio": 1.0]]) }
    }

    private func loadComments() async {
        comments = (try? await session.feedRepo.comments(postID: post.id)) ?? []
        loadedComments = true
    }

    private func toggleLike() {
        let on = !post.likedByMe
        Haptics.impact(on ? .medium : .light)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            post.likedByMe = on
            post.likes += on ? 1 : -1
        }
        let id = post.id
        Task {
            do { try await session.feedRepo.setLike(postID: id, liked: on) } catch {
                post.likedByMe = !on
                post.likes += on ? -1 : 1
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        let id = post.id
        Task {
            defer { sending = false }
            if let c = try? await session.feedRepo.addComment(postID: id, text: text, parentID: nil) {
                Haptics.notify(.success)
                draft = ""
                inputFocused = false
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    comments.insert(c, at: 0)
                    post.comments += 1
                }
            }
        }
    }
}
