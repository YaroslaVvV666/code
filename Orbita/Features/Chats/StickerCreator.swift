import SwiftUI
import PhotosUI

/// Создание своих стикеров прямо в приложении: набор + картинки/короткие видео (анимированные), без бота.
struct StickerCreatorSheet: View {
    var onChanged: () -> Void = {}

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss

    @State private var packs: [StickerPack] = []
    @State private var loading = true
    @State private var busyNote: String?
    @State private var errorText: String?

    @State private var creatingPack = false
    @State private var newName = ""

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var targetPack: String?
    @State private var pending: PendingSticker?

    private var s: Strings { Strings(lang: lang) }
    private var repo: MessengerRepository { session.messengerRepo }

    struct PendingSticker: Identifiable { let id = UUID(); let packID: String; let mediaID: String; let animated: Bool }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
            .background(theme.sheet.ignoresSafeArea())
            .navigationTitle(s.t("Мои стикеры", "My stickers"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(s.close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { newName = ""; creatingPack = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .task { await load() }
        .alert(s.t("Новый набор", "New pack"), isPresented: $creatingPack) {
            TextField(s.t("Название", "Name"), text: $newName)
            Button(s.t("Создать", "Create")) { createPack() }
            Button(s.cancel, role: .cancel) {}
        }
        .onChange(of: pickerItems) { _, items in if !items.isEmpty { handlePicked(items) } }
        .sheet(item: $pending) { p in
            StickerEmojiSheet(animated: p.animated) { emoji in
                Task { await addSticker(p, emoji: emoji) }
            }
            .environment(\.theme, theme).environment(\.lang, lang)
            .presentationDetents([.height(300)])
            .presentationBackground(theme.sheet)
        }
        .overlay(alignment: .top) {
            if let note = busyNote {
                Text(note).font(.system(size: 14, weight: .medium)).foregroundStyle(theme.text)
                    .padding(.horizontal, 16).frame(height: 40).glassCapsule().padding(.top, 8)
            } else if let errorText {
                Text(errorText).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 40).background(theme.danger, in: Capsule()).padding(.top, 8)
                    .task(id: errorText) { try? await Task.sleep(nanoseconds: 2_500_000_000); self.errorText = nil }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            if packs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "face.smiling").font(.system(size: 36, weight: .light)).foregroundStyle(theme.accentColor)
                    Text(s.t("Создайте свой первый набор стикеров", "Create your first sticker pack"))
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).multilineTextAlignment(.center)
                    Text(s.t("Картинка (лучше PNG с прозрачным фоном) или короткое видео — станет анимированным стикером.",
                             "An image (PNG with transparency is best) or a short video for an animated sticker."))
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center).padding(.horizontal, 30)
                    Button { newName = ""; creatingPack = true } label: {
                        Text(s.t("Создать набор", "Create pack")).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 24).frame(height: 48).background(theme.accent, in: Capsule())
                    }
                    .buttonStyle(PressStyle())
                }
                .frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                VStack(spacing: 20) {
                    ForEach(packs) { pack in packCard(pack) }
                }
                .padding(16)
            }
        }
    }

    private func packCard(_ pack: StickerPack) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(pack.title).font(.system(size: 16, weight: .bold)).foregroundStyle(theme.text)
                Spacer()
                Text("\(pack.stickers.count)").font(.system(size: 13)).foregroundStyle(theme.textTertiary)
                Menu {
                    Button(role: .destructive) { deletePack(pack) } label: { Label(s.t("Удалить набор", "Delete pack"), systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.textSecondary)
                        .frame(width: 32, height: 32)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(pack.stickers) { sticker in
                    StickerImage(sticker: sticker, size: 68)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .topTrailing) {
                            Button { deleteSticker(pack, sticker) } label: {
                                Image(systemName: "minus.circle.fill").font(.system(size: 18))
                                    .symbolRenderingMode(.palette).foregroundStyle(.white, theme.danger)
                            }
                            .buttonStyle(.plain).offset(x: 4, y: -4)
                        }
                }
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 1, matching: .any(of: [.images, .videos])) {
                    Image(systemName: "plus").font(.system(size: 24, weight: .semibold)).foregroundStyle(theme.accentColor)
                        .frame(maxWidth: .infinity).frame(height: 68)
                        .background(theme.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .simultaneousGesture(TapGesture().onEnded { targetPack = pack.id })
            }
        }
        .padding(14)
        .card(theme, radius: 18)
    }

    // MARK: Действия

    private func load() async {
        loading = true
        let all = (try? await repo.stickers()) ?? []
        packs = all.filter { $0.mine }
        loading = false
    }

    private func createPack() {
        let title = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        Task {
            do { _ = try await repo.createStickerPack(title: title); await load(); onChanged() }
            catch { errorText = s.t("Не удалось создать набор", "Couldn't create pack") }
        }
    }

    private func handlePicked(_ items: [PhotosPickerItem]) {
        pickerItems = []
        guard let item = items.first, let packID = targetPack else { return }
        Task {
            busyNote = s.t("Загружаю…", "Uploading…")
            defer { busyNote = nil }
            do {
                let media = try await MediaPreparer.prepare(item)
                let att = try await repo.upload(.prepared(media))
                pending = PendingSticker(packID: packID, mediaID: att.mediaID ?? "", animated: media.isVideo)
            } catch MediaError.tooLong {
                errorText = s.t("Видео слишком длинное", "Video is too long")
            } catch {
                errorText = s.t("Не удалось загрузить", "Upload failed")
            }
        }
    }

    private func addSticker(_ p: PendingSticker, emoji: String) async {
        guard !p.mediaID.isEmpty else { return }
        do { try await repo.addSticker(packID: p.packID, mediaID: p.mediaID, emoji: emoji); await load(); onChanged() }
        catch { errorText = s.t("Не удалось добавить стикер", "Couldn't add sticker") }
    }

    private func deleteSticker(_ pack: StickerPack, _ sticker: Sticker) {
        Haptics.impact(.light)
        Task { try? await repo.deleteSticker(packID: pack.id, stickerID: sticker.id); await load(); onChanged() }
    }

    private func deletePack(_ pack: StickerPack) {
        Haptics.impact(.light)
        Task { try? await repo.deleteStickerPack(id: pack.id); await load(); onChanged() }
    }
}

/// Выбор эмодзи для нового стикера
private struct StickerEmojiSheet: View {
    let animated: Bool
    let onPick: (String) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss
    @State private var emoji = ""

    private var s: Strings { Strings(lang: lang) }
    private let quick = ["😀", "😂", "❤️", "🔥", "👍", "😎", "🥰", "😭", "🎉", "💀", "✨", "🙏"]

    var body: some View {
        VStack(spacing: 16) {
            Text(animated ? s.t("Эмодзи для анимированного стикера", "Emoji for the animated sticker")
                          : s.t("Какой эмодзи у стикера?", "Pick an emoji for the sticker"))
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                .multilineTextAlignment(.center).padding(.top, 20).padding(.horizontal, 20)

            TextField("😀", text: $emoji)
                .multilineTextAlignment(.center).font(.system(size: 44))
                .frame(height: 64)
                .onChange(of: emoji) { _, v in emoji = String(v.suffix(1)) }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                ForEach(quick, id: \.self) { e in
                    Button { emoji = e } label: { Text(e).font(.system(size: 30)) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)

            Button {
                let pick = emoji.isEmpty ? "😀" : emoji
                dismiss(); onPick(pick)
            } label: {
                Text(s.t("Добавить", "Add")).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 50).background(theme.accent, in: Capsule())
            }
            .buttonStyle(PressStyle()).padding(.horizontal, 20)
            Spacer(minLength: 0)
        }
    }
}
