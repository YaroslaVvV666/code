import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Реакция: обычный эмодзи или своё («u:<id>»)

struct ReactionGlyph: View {
    let emoji: String
    var size: CGFloat = 24
    var animate = false

    var body: some View {
        if emoji.hasPrefix("u:") {
            CustomEmojiView(id: emoji, fallback: CustomEmojiStore.shared.info(emoji)?.emoji ?? "", size: size, animate: animate)
        } else {
            Text(emoji).font(.system(size: size * 0.82))
        }
    }
}

// MARK: - Нажали на чужое эмодзи — его набор: «Добавить N эмодзи»

@MainActor
final class EmojiPackPresenter: ObservableObject {
    static let shared = EmojiPackPresenter()
    struct Route: Identifiable, Equatable { let id: String }        // id набора "u:<id>"
    @Published var route: Route?

    /// Открыть набор, в котором лежит это эмодзи
    func open(emojiID: String) {
        Haptics.impact(.light)
        if let pack = CustomEmojiStore.shared.info(emojiID)?.pack {
            route = Route(id: pack)
            return
        }
        CustomEmojiStore.shared.request([emojiID])                  // сведений ещё нет — подтянем и откроем
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let pack = CustomEmojiStore.shared.info(emojiID)?.pack { route = Route(id: pack); return }
            }
        }
    }
}

struct EmojiPackSheet: View {
    let packID: String
    var onChanged: () -> Void = {}

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss
    @State private var pack: CustomStickerPack?
    @State private var failed = false
    @State private var busy = false

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(pack?.pack.title ?? s.t("Набор эмодзи", "Emoji pack"))
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(theme.text).lineLimit(1)
                Spacer()
                Button(s.close) { dismiss() }.foregroundStyle(theme.accentColor)
            }
            .padding(20)

            if let pack {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(pack.pack.stickers) { e in
                            CustomEmojiView(id: e.id, fallback: e.emoji, size: 46, animate: true)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                Button { toggle(pack) } label: {
                    Group {
                        if busy { ProgressView().tint(.white) }
                        else if pack.mine { Text(s.t("Это ваш набор", "This is your pack")) }
                        else if pack.installed { Text(s.t("Убрать набор", "Remove pack")) }
                        else { Text(lang == .ru ? "Добавить \(pack.pack.stickers.count) эмодзи" : "Add \(pack.pack.stickers.count) emoji") }
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(pack.installed && !pack.mine ? theme.danger : .white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background {
                        if pack.installed && !pack.mine { Capsule().fill(theme.danger.opacity(0.14)) }
                        else { Capsule().fill(theme.accent) }
                    }
                }
                .buttonStyle(PressStyle())
                .disabled(busy || pack.mine)
                .padding(16)
            } else if failed {
                Spacer()
                Text(s.api(.offline)).foregroundStyle(theme.textSecondary)
                Spacer()
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
        .background(theme.sheet.ignoresSafeArea())
        .task {
            do {
                let p = try await session.messengerRepo.stickerPack(id: packID)
                pack = p
                CustomEmojiStore.shared.register([p.pack])
            } catch { failed = true }
        }
    }

    private func toggle(_ p: CustomStickerPack) {
        busy = true
        Task {
            defer { busy = false }
            if let fresh = try? await session.messengerRepo.setStickerPack(id: p.id, installed: !p.installed) {
                Haptics.notify(.success)
                pack = fresh
                onChanged()
            }
        }
    }
}

// MARK: - Свои эмодзи прямо в приложении (без бота)

struct EmojiCreatorSheet: View {
    var onChanged: () -> Void = {}

    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss

    @State private var packs: [StickerPack] = []
    @State private var selected: String?
    @State private var loading = true
    @State private var busy = false
    @State private var errorText: String?
    @State private var newName = ""
    @State private var askName = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var pendingSource: (data: Data, lottie: Bool)?
    @State private var askEmoji = false
    @State private var fallback = ""

    private var s: Strings { Strings(lang: lang) }
    private var repo: MessengerRepository { session.messengerRepo }
    private var current: StickerPack? { packs.first { $0.id == (selected ?? packs.first?.id) } }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if packs.isEmpty {
                    empty
                } else {
                    content
                }
            }
            .background(theme.sheet.ignoresSafeArea())
            .navigationTitle(s.t("Мои эмодзи", "My emoji"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(s.close) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { newName = ""; askName = true } label: { Image(systemName: "folder.badge.plus") }
                }
            }
        }
        .task { await load() }
        .photosPicker(isPresented: $showPhotos, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task { await takeImage(item) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.json, .data, .item]) { result in
            if case .success(let url) = result { takeLottie(url) }
        }
        .alert(s.t("Новый набор эмодзи", "New emoji pack"), isPresented: $askName) {
            TextField(s.t("Название", "Title"), text: $newName)
            Button(s.t("Создать", "Create")) { createPack() }
            Button(s.cancel, role: .cancel) {}
        }
        .alert(s.t("Какой эмодзи подходит?", "Which emoji fits?"), isPresented: $askEmoji) {
            TextField("😀", text: $fallback)
            Button(s.t("Добавить", "Add")) { addPending() }
            Button(s.cancel, role: .cancel) { pendingSource = nil }
        } message: {
            Text(s.t("Обычный эмодзи-заменитель: он виден там, где свои эмодзи не поддерживаются.",
                     "A regular emoji shown where custom emoji aren't supported."))
        }
        .alert(errorText ?? "", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            Image(systemName: "face.smiling.inverse").font(.system(size: 54)).foregroundStyle(theme.accentColor)
            Text(s.t("Свои эмодзи — прямо в тексте сообщений", "Your own emoji — right in your messages"))
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.text).multilineTextAlignment(.center)
            Text(s.t("Анимированные — из файла Lottie (.tgs или .json, до 3 секунд), статичные — из любой картинки: "
                     + "она станет PNG 100×100.",
                     "Animated — from a Lottie file (.tgs or .json, up to 3 s), static — from any picture: it becomes a 100×100 PNG."))
                .font(.system(size: 14)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
            Button { newName = ""; askName = true } label: {
                Text(s.t("Создать набор эмодзи", "Create an emoji pack")).font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 52).background(theme.accent, in: Capsule())
            }
            .buttonStyle(PressStyle())
        }
        .padding(28)
        .frame(maxHeight: .infinity)
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(packs) { p in
                        let on = p.id == current?.id
                        Button { selected = p.id } label: {
                            Text("\(p.title) · \(p.stickers.count)").font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(on ? .white : theme.text)
                                .padding(.horizontal, 14).frame(height: 34)
                                .background(on ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.surface), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            if let pack = current {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                        Menu {
                            Button { showPhotos = true } label: {
                                Label(s.t("Картинка (станет PNG 100×100)", "Picture (becomes 100×100 PNG)"), systemImage: "photo")
                            }
                            Button { showFiles = true } label: {
                                Label(s.t("Анимация Lottie (.tgs, .json)", "Lottie animation (.tgs, .json)"), systemImage: "sparkles")
                            }
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(theme.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                if busy { ProgressView() } else {
                                    Image(systemName: "plus").font(.system(size: 22, weight: .semibold)).foregroundStyle(theme.accentColor)
                                }
                            }
                            .frame(width: 58, height: 58)
                        }
                        .disabled(busy)
                        ForEach(pack.stickers) { e in
                            CustomEmojiView(id: e.id, fallback: e.emoji, size: 52, animate: true)
                                .frame(width: 58, height: 58)
                                .contextMenu {
                                    Button(role: .destructive) { delete(e, from: pack) } label: {
                                        Label(s.t("Удалить эмодзи", "Delete emoji"), systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding(16)
                    Text(s.t("Зажмите эмодзи, чтобы удалить. Наборы можно делать и в боте @stickers.",
                             "Long-press an emoji to delete it. You can also make packs with the @stickers bot."))
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary).padding(.horizontal, 20)
                    Button(role: .destructive) { deletePack(pack) } label: {
                        Text(s.t("Удалить набор", "Delete pack")).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.danger)
                    }
                    .padding(.vertical, 20)
                }
            }
        }
    }

    // MARK: Действия

    private func load() async {
        let all = (try? await repo.stickers()) ?? []
        packs = all.filter { $0.mine && $0.isEmoji }
        CustomEmojiStore.shared.register(packs)
        loading = false
    }

    private func createPack() {
        let title = newName.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        Task {
            do {
                let p = try await repo.createEmojiPack(title: title)
                packs.append(p.pack)
                selected = p.id
                onChanged()
            } catch { errorText = s.api((error as? APIError) ?? .offline) }
        }
    }

    private func takeImage(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = ImageCache.downsample(data, maxPixel: 512), let png = image.pngData() else {
            errorText = s.t("Не получилось открыть картинку", "Couldn't open the picture")
            return
        }
        pendingSource = (png, false)
        fallback = ""
        askEmoji = true
    }

    private func takeLottie(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count <= 1024 * 1024 else {
            errorText = s.t("Файл больше 1 МБ", "The file is over 1 MB")
            return
        }
        // .tgs (сжатый Lottie) или .json — проверит сервер
        pendingSource = (data, true)
        fallback = ""
        askEmoji = true
    }

    private func addPending() {
        guard let src = pendingSource, let pack = current else { return }
        pendingSource = nil
        let emoji = fallback.trimmingCharacters(in: .whitespaces).first.map(String.init) ?? "🙂"
        busy = true
        Task {
            defer { busy = false }
            do {
                let media = try await repo.uploadEmojiSource(src.data, lottie: src.lottie)
                let info = try await repo.addEmoji(packID: pack.id, mediaID: media, emoji: emoji)
                if let i = packs.firstIndex(where: { $0.id == pack.id }) {
                    let added = Sticker(id: info.id, emoji: info.emoji, mediaID: info.mediaID, animated: info.lottie,
                                        packID: pack.id, lottie: info.lottie)
                    let old = packs[i]
                    packs[i] = StickerPack(id: old.id, title: old.title, icon: old.icon, stickers: old.stickers + [added],
                                           mine: old.mine, kind: old.kind)
                    CustomEmojiStore.shared.register([packs[i]])
                }
                Haptics.notify(.success)
                onChanged()
            } catch let e as APIError {
                if case .server(_, let code) = e, code == "bad_emoji" {
                    errorText = src.lottie
                        ? s.t("Анимация не подошла: нужен Lottie (.tgs или .json) — квадратный холст, до 3 секунд, до 60 кадров/с, "
                              + "без картинок, шрифтов и выражений внутри, до 64 КБ после сжатия.",
                              "The animation doesn't fit: Lottie (.tgs or .json), square canvas, up to 3 s and 60 fps, no images, "
                              + "fonts or expressions, up to 64 KB compressed.")
                        : s.t("Картинка не подошла — попробуйте PNG с прозрачным фоном.", "The picture doesn't fit — try a PNG with transparency.")
                } else {
                    errorText = s.api(e)
                }
            } catch { errorText = s.api(.offline) }
        }
    }

    private func delete(_ e: Sticker, from pack: StickerPack) {
        Task {
            try? await repo.deleteSticker(packID: pack.id, stickerID: String(e.id.dropFirst(2)))
            if let i = packs.firstIndex(where: { $0.id == pack.id }) {
                let old = packs[i]
                packs[i] = StickerPack(id: old.id, title: old.title, icon: old.icon, stickers: old.stickers.filter { $0.id != e.id },
                                       mine: old.mine, kind: old.kind)
            }
            onChanged()
        }
    }

    private func deletePack(_ pack: StickerPack) {
        Task {
            try? await repo.deleteStickerPack(id: pack.id)
            packs.removeAll { $0.id == pack.id }
            selected = nil
            onChanged()
        }
    }
}
