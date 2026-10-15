import SwiftUI
import PhotosUI

// MARK: - Новая публикация: форматирование, несколько фото и видео

struct ComposerView: View {
    @ObservedObject var vm: FeedViewModel
    /// Если задана — это правка существующей публикации
    var editing: Post? = nil
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

    private let maxMedia = 10
    private var s: Strings { Strings(lang: lang) }
    private var profile: UserProfile? { session.profile.profile }
    private var uploading: Bool { vm.uploadProgress != nil }
    private var canPost: Bool {
        (!controller.isBlank || !picked.isEmpty || !kept.isEmpty) && !uploading && !preparing
    }
    private var mediaCount: Int { picked.count + kept.count }

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
            let ok = await vm.publish(text: controller.plainText, entities: controller.entities, media: picked)
            if ok {
                if let first = vm.posts.first { onSaved?(first) }
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
