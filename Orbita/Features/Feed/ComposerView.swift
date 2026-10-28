import SwiftUI
import PhotosUI

// MARK: - Новая публикация: форматирование, несколько фото и видео

struct ComposerView: View {
    @ObservedObject var vm: FeedViewModel
    /// Если задана — это правка существующей публикации
    var editing: Post? = nil
    /// Запись на своей стене: в ленту публикаций не попадает, видна только в профиле
    var wallOnly = false
    var onSaved: ((Post) -> Void)? = nil

    @EnvironmentObject private var flow: AuthFlow
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @StateObject private var controller = RichComposerController()
    @State private var picked: [PreparedMedia] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var preparing = false
    @State private var mediaError: String?
    @State private var askLink = false
    @State private var linkDraft = ""
    @State private var kept: [MediaItem] = []
    @State private var didLoadEditing = false
    @State private var showStickers = false
    @State private var packs: [StickerPack] = []
    @State private var options = PostOptions()

    private let maxMedia = 10
    private var s: Strings { Strings(lang: lang) }
    private var profile: UserProfile? { session.profile.profile }
    private var uploading: Bool { vm.uploadProgress != nil }
    private var canPost: Bool {
        (!controller.isBlank || !picked.isEmpty || !kept.isEmpty) && !uploading && !preparing
    }
    private var mediaCount: Int { picked.count + kept.count }

    /// Что именно будет опубликовано: тип записи и состав медиа
    private var detailText: String {
        let videos = picked.filter(\.isVideo).count + kept.filter { $0.kind == .video }.count
        let photos = mediaCount - videos
        var parts: [String] = []
        if photos > 0 { parts.append(s.t("фото: \(photos)", "photos: \(photos)")) }
        if videos > 0 { parts.append(s.t("видео: \(videos)", "videos: \(videos)")) }
        let media = parts.isEmpty ? s.t("только текст", "text only") : parts.joined(separator: ", ")
        return s.t("Появится в ленте и на вашей странице · ", "Shown in the feed and on your page · ") + media
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let progress = vm.uploadProgress {
                        ProgressView(value: progress).tint(theme.accentColor)
                    }

                    HStack(spacing: 12) {
                        AvatarView(name: profile?.name ?? flow.userName, size: 42, avatarID: profile?.avatarID)
                        Text(profile?.name ?? flow.userName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.text)
                    }

                    ZStack(alignment: .topLeading) {
                        FormattingTextView(controller: controller,
                                           textColor: UIColor(theme.text), tint: UIColor(theme.accentColor))
                            .frame(height: 190)
                        if controller.length == 0 {
                            Text(s.whatsNew)
                                .font(.system(size: 17))
                                .foregroundStyle(theme.textTertiary)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                    }

                    if mediaCount > 0 { mediaStrip }

                    if editing == nil {
                        PostOptionsCard(options: $options, hashtags: PostOptionsCard.hashtags(in: controller.plainText),
                                        detail: detailText)
                    }

                    if wallOnly && editing == nil {
                        Label(s.t("Запись появится только на вашей стене, в ленту публикаций она не попадёт",
                                  "This post will appear only on your wall, not in the feed"), systemImage: "person.crop.square")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let message = mediaError ?? vm.actionError.map({ s.api($0) }) {
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.danger)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .navigationTitle(editing == nil ? s.newPost : s.editPost)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(s.cancel) { dismiss() }.disabled(uploading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? s.publish : s.save, action: publish)
                        .fontWeight(.semibold)
                        .disabled(!canPost)
                }
            }
        }
        .tint(theme.accentColor)
        .alert(s.linkTitle, isPresented: $askLink) {
            TextField("https://", text: $linkDraft)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button(s.add) {
                controller.applyLink(linkDraft)
                linkDraft = ""
            }
            Button(s.cancel, role: .cancel) { linkDraft = "" }
        }
        .holdsMedia(stopsMusic: false)                  // музыка играет дальше, пока пишешь пост
        .onAppear {
            controller.onLinkRequest = { askLink = true }
            guard let post = editing, !didLoadEditing else { return }
            didLoadEditing = true
            kept = post.media
            controller.load(text: post.text, entities: post.entities, color: UIColor(theme.text))
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { @MainActor in
                await process(items)
                pickerItems = []
            }
        }
        .sheet(isPresented: $showStickers) {
            EmojiStickerPanel(packs: packs,
                              onEmoji: { controller.insert($0) },
                              onBackspace: { controller.backspace() },
                              onSticker: { addSticker($0) })
                .environment(\.theme, theme)
                .environment(\.lang, lang)
                .presentationDetents([.height(320)])
                .presentationBackground(theme.sheet)
        }
        .interactiveDismissDisabled(uploading)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Нижняя панель: форматирование и медиа

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack {
                PhotosPicker(selection: $pickerItems,
                             maxSelectionCount: max(1, maxMedia - mediaCount),
                             matching: .any(of: [.images, .videos])) {
                    Label(s.addMedia, systemImage: "photo.on.rectangle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.accentColor)
                }
                .disabled(mediaCount >= maxMedia || preparing || uploading)

                Button {
                    showStickers = true
                    Task { if packs.isEmpty { packs = (try? await session.messengerRepo.stickers()) ?? [] } }
                } label: {
                    Label(s.t("Стикеры", "Stickers"), systemImage: "face.smiling")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.accentColor)
                        .padding(.leading, 10)
                }
                .disabled(mediaCount >= maxMedia || uploading)

                if preparing { ProgressView().padding(.leading, 6) }

                Spacer()

                Text("\(controller.length)/\(controller.maxLength)")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
        .background(theme.sheet)
        .overlay(alignment: .top) { Rectangle().fill(theme.stroke).frame(height: 1) }
    }

    private var mediaStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(kept) { item in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if item.kind == .art {
                                PostArt(kind: item.artIndex)
                            } else {
                                RemoteImage(id: item.thumbID ?? item.id)
                            }
                        }
                        .frame(width: 104, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            if item.kind == .video {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Color.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color.black.opacity(0.5), in: Circle())
                            }
                        }
                        Button {
                            kept.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.white)
                                .frame(width: 24, height: 24)
                                .background(Color.black.opacity(0.6), in: Circle())
                        }
                        .padding(6)
                        .disabled(uploading)
                    }
                }
                ForEach(picked) { media in
                    ZStack(alignment: .topTrailing) {
                        if let image = UIImage(data: media.thumbnail) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 104, height: 104)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay {
                                    if media.isVideo {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(Color.white)
                                            .frame(width: 36, height: 36)
                                            .background(Color.black.opacity(0.5), in: Circle())
                                    }
                                }
                        }
                        Button {
                            picked.removeAll { $0.id == media.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.white)
                                .frame(width: 24, height: 24)
                                .background(Color.black.opacity(0.6), in: Circle())
                        }
                        .padding(6)
                        .disabled(uploading)
                    }
                }
            }
        }
    }

    // MARK: Действия

    private func process(_ items: [PhotosPickerItem]) async {
        preparing = true
        mediaError = nil
        for item in items where mediaCount < maxMedia {
            do {
                picked.append(try await MediaPreparer.prepare(item))
            } catch MediaError.tooLong {
                mediaError = s.videoTooLong
            } catch MediaError.tooLarge {
                mediaError = s.videoTooBig
            } catch {
                mediaError = s.mediaFailed
            }
        }
        preparing = false
    }

    /// Стикер уходит как обычная картинка (PNG с прозрачностью)
    private func addSticker(_ sticker: Sticker) {
        guard mediaCount < maxMedia, let url = sticker.url else { return }
        showStickers = false
        Task { @MainActor in
            preparing = true
            defer { preparing = false }
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else {
                mediaError = s.mediaFailed
                return
            }
            picked.append(PreparedMedia(source: .png(data), width: Int(image.size.width), height: Int(image.size.height),
                                        duration: nil, thumbnail: data))
        }
    }

    private func cleanup() {
        for media in picked {
            if case .video(let url) = media.source { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func publish() {
        Task { @MainActor in
            if let post = editing {
                guard let saved = await vm.saveEdit(post, text: controller.plainText, entities: controller.entities,
                                                    kept: kept, added: picked) else {
                    Haptics.notify(.error)
                    return
                }
                cleanup()
                onSaved?(saved)
                Haptics.notify(.success)
                dismiss()
                return
            }
            var opts = options
            opts.wallOnly = wallOnly
            let ok = await vm.publish(text: controller.plainText, entities: controller.entities, media: picked, options: opts)
            if ok {
                if let post = vm.lastPublished { onSaved?(post) }
                for media in picked {
                    if case .video(let url) = media.source { try? FileManager.default.removeItem(at: url) }
                }
                Haptics.notify(.success)
                dismiss()
            } else {
                Haptics.notify(.error)
            }
        }
    }
}


// MARK: - Параметры публикации (общие для поста и шортса)

struct PostOptionsCard: View {
    @Binding var options: PostOptions
    var showsRepost = false
    var hashtags: [String]
    var detail: String

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(s.t("ПАРАМЕТРЫ", "OPTIONS"))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 4).padding(.bottom, 6)
            VStack(spacing: 0) {
                row(icon: "bubble.left.and.bubble.right.fill", tint: .blue,
                    title: s.t("Комментарии", "Comments"),
                    subtitle: options.commentsOff ? s.t("Выключены — никто не сможет комментировать", "Off — nobody can comment")
                                                  : s.t("Можно комментировать по настройкам приватности", "Allowed by your privacy settings"),
                    isOn: Binding(get: { !options.commentsOff }, set: { options.commentsOff = !$0 }))
                if showsRepost {
                    Divider().padding(.leading, 52)
                    row(icon: "arrow.2.squarepath", tint: .green,
                        title: s.t("Репосты", "Reposts"),
                        subtitle: options.noRepost ? s.t("Запрещены — репостнуть нельзя", "Off — nobody can repost")
                                                   : s.t("Друзья смогут репостнуть к себе на страницу", "People can repost it to their page"),
                        isOn: Binding(get: { !options.noRepost }, set: { options.noRepost = !$0 }))
                }
                Divider().padding(.leading, 52)
                row(icon: "eye.trianglebadge.exclamationmark.fill", tint: .orange,
                    title: s.t("Чувствительный контент (18+)", "Sensitive content (18+)"),
                    subtitle: options.sensitive ? s.t("Будет скрыт под размытием, пока не нажмут «Показать»", "Shown blurred until viewers tap to reveal")
                                                : s.t("Отметьте, если контент для взрослых", "Mark it if the content is for adults"),
                    isOn: Binding(get: { options.sensitive }, set: { options.sensitive = $0 }))
                if !hashtags.isEmpty {
                    Divider().padding(.leading, 16)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(s.t("Хэштеги: \(hashtags.count)", "Hashtags: \(hashtags.count)"))
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textSecondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(hashtags, id: \.self) { tag in
                                    Text(tag).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accentColor)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(theme.accentColor.opacity(0.12), in: Capsule())
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !detail.isEmpty {
                    Divider().padding(.leading, 16)
                    Text(detail)
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .card(theme, radius: 16)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: options)
        }
    }

    private func row(icon: String, tint: Color, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16)).foregroundStyle(theme.text)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).labelsHidden().tint(theme.accentColor)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// #хэштеги из текста, без повторов
    static func hashtags(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "#[\\p{L}\\p{N}_]+") else { return [] }
        let ns = text as NSString
        var seen = Set<String>(), out: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let t = ns.substring(with: m.range)
            if seen.insert(t.lowercased()).inserted { out.append(t) }
        }
        return out
    }
}
