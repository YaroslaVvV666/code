import SwiftUI
import Combine
import UIKit
import AVFoundation

// MARK: - Данные эмодзи

enum EmojiData {
    struct Category: Identifiable {
        let id: String
        let icon: String            // SF Symbol
        let items: [String]
    }

    private static func list(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

    static let categories: [Category] = [
        Category(id: "smileys", icon: "face.smiling", items: list("""
        😀 😃 😄 😁 😆 😅 😂 🤣 🥲 ☺️ 😊 😇 🙂 🙃 😉 😌 😍 🥰 😘 😗 😙 😚 😋 😛 😝 😜 🤪 🤨 🧐 🤓 😎 🥸 🤩 🥳 😏 😒 😞 😔 😟 😕 🙁 ☹️ 😣 😖 😫 😩 🥺 😢 😭 😤 😠 😡 🤬 🤯 😳 🥵 🥶 😱 😨 😰 😥 😓 🤗 🤔 🫣 🤭 🫢 🫡 🤫 🫠 🤥 😶 😐 😑 😬 🙄 😯 😦 😧 😮 😲 🥱 😴 🤤 😪 😵 🤐 🥴 🤢 🤮 🤧 😷 🤒 🤕 🤑 🤠 😈 👿 👹 👺 🤡 💩 👻 💀 ☠️ 👽 👾 🤖 🎃
        """)),
        Category(id: "people", icon: "hand.wave", items: list("""
        👋 🤚 🖐 ✋ 🖖 👌 🤌 🤏 ✌️ 🤞 🫰 🤟 🤘 🤙 👈 👉 👆 🖕 👇 ☝️ 👍 👎 ✊ 👊 🤛 🤜 👏 🙌 🫶 👐 🤲 🤝 🙏 ✍️ 💅 🤳 💪 🦾 🧠 👀 👁 👅 👄 👶 🧒 👦 👧 🧑 👱 👨 👩 🧔 👴 👵 🙍 🙎 🙅 🙆 💁 🙋 🧏 🙇 🤦 🤷
        """)),
        Category(id: "animals", icon: "pawprint", items: list("""
        🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🙈 🙉 🙊 🐔 🐧 🐦 🐤 🦆 🦅 🦉 🦇 🐺 🐗 🐴 🦄 🐝 🐛 🦋 🐌 🐞 🐜 🐢 🐍 🦎 🐙 🦑 🦀 🐠 🐟 🐬 🐳 🦈 🐊 🦓 🦍 🐘 🦒 🐪 🌵 🌲 🌳 🌴 🌱 🌿 ☘️ 🍀 🌺 🌻 🌹 🌷 🌼 🌸
        """)),
        Category(id: "food", icon: "fork.knife", items: list("""
        🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🫐 🍈 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🥑 🍆 🥦 🥕 🌽 🌶 🥔 🍞 🥐 🧀 🥚 🍳 🥞 🧇 🥓 🍔 🍟 🍕 🌭 🥪 🌮 🌯 🥗 🍝 🍜 🍣 🍱 🍦 🍩 🍪 🎂 🍰 🧁 🍫 🍬 🍭 ☕ 🍵 🥤 🍺 🍻 🥂 🍷 🍸 🍹 🍾
        """)),
        Category(id: "activity", icon: "sportscourt", items: list("""
        ⚽ 🏀 🏈 ⚾ 🎾 🏐 🏉 🎱 🏓 🥊 🎯 ⛳ 🎮 🕹 🎲 🧩 🎸 🎹 🥁 🎤 🎧 🎬 🎨 🏆 🥇 🥈 🥉 🏅 🎪 🎭
        """)),
        Category(id: "travel", icon: "airplane", items: list("""
        🚗 🚕 🚙 🚌 🏎 🚓 🚑 🚒 🛴 🚲 🏍 ✈️ 🚀 🛸 🚁 ⛵ 🚢 🏠 🏢 🏰 🗽 🌍 🌙 ⭐ 🌟 ✨ ⚡ 🔥 🌈 ☀️ ⛅ ☁️ ❄️ 💧 🌊
        """)),
        Category(id: "objects", icon: "lightbulb", items: list("""
        ⌚ 📱 💻 ⌨️ 🖥 📷 📹 🎥 📞 ☎️ 📺 📻 ⏰ 💡 🔋 🔌 💰 💳 💎 🔧 🔨 ⚙️ 🔒 🔑 ✉️ 📦 📌 📎 ✂️ 📝 📚 🎁 🎈 🎉 🎊
        """)),
        Category(id: "symbols", icon: "heart", items: list("""
        ❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝 💯 ✅ ❌ ❓ ❗ ‼️ ⭕ 🔴 🟠 🟡 🟢 🔵 🟣 ⚫ ⚪ 🔺 🔻 ➕ ➖ ➗ ✔️ 💬 💭 ♻️ 🚫 ⚠️
        """))
    ]

    private static let recentKey = "orbita.emoji.recent"

    static var recent: [String] {
        UserDefaults.standard.stringArray(forKey: recentKey) ?? []
    }

    static func remember(_ emoji: String) {
        var list = recent.filter { $0 != emoji }
        list.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(list.prefix(24)), forKey: recentKey)
    }
}

/// Избранные стикеры (локально на устройстве) — как «⭐ Избранное» в Telegram.
enum FavoriteStickers {
    private static let key = "orbita.stickers.favorites"
    private struct Stored: Codable { let id: String; let emoji: String; let mediaID: String?; let animated: Bool; let packID: String? }

    static var all: [Sticker] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return list.map { Sticker(id: $0.id, emoji: $0.emoji, mediaID: $0.mediaID, animated: $0.animated, packID: $0.packID) }
    }

    static func contains(_ s: Sticker) -> Bool { all.contains { $0.id == s.id } }

    /// Переключает избранное; возвращает, в избранном ли стикер теперь.
    @discardableResult
    static func toggle(_ s: Sticker) -> Bool {
        var list = all
        let was = list.contains { $0.id == s.id }
        list.removeAll { $0.id == s.id }
        if !was { list.insert(s, at: 0) }
        let stored = list.prefix(60).map { Stored(id: $0.id, emoji: $0.emoji, mediaID: $0.mediaID, animated: $0.animated, packID: $0.packID) }
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(stored)), forKey: key)
        return !was
    }
}

/// Недавно отправленные стикеры (локально на устройстве) — раздел «Недавние», как в Telegram
enum RecentStickers {
    private static let key = "orbita.stickers.recent"
    private struct Stored: Codable { let id: String; let emoji: String; let mediaID: String?; let animated: Bool; let packID: String? }

    static var all: [Sticker] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return list.map { Sticker(id: $0.id, emoji: $0.emoji, mediaID: $0.mediaID, animated: $0.animated, packID: $0.packID) }
    }

    /// Отправили стикер — он первым в «Недавних» (до 25 штук)
    static func add(_ s: Sticker) {
        var list = all
        list.removeAll { $0.id == s.id }
        list.insert(s, at: 0)
        let stored = list.prefix(25).map { Stored(id: $0.id, emoji: $0.emoji, mediaID: $0.mediaID, animated: $0.animated, packID: $0.packID) }
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(stored)), forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

extension String {
    /// Только эмодзи (до трёх штук) — такие сообщения показываются крупно, без «пузыря»
    var isEmojiOnly: Bool {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 3 else { return false }
        return value.allSatisfy { ch in
            guard let first = ch.unicodeScalars.first else { return false }
            return first.properties.isEmojiPresentation || (first.properties.isEmoji && ch.unicodeScalars.count > 1)
                || (first.properties.isEmoji && first.value > 0x2000)
        }
    }
}

// MARK: - Картинка стикера

struct StickerImage: View {
    let sticker: Sticker
    var size: CGFloat = 80

    /// Стикер из установленного набора лежит на телефоне постоянно (StickerVault) — показываем его оттуда, и без сети тоже
    @State private var local: UIImage?
    private var maxPixel: CGFloat { max(256, size * 3) }

    var body: some View {
        if sticker.animated, let media = sticker.mediaID {
            // анимированный — беззвучное видео по кругу, файл с телефона, если он уже сохранён
            StickerVideo(mediaID: media, local: StickerVault.shared.localFile(sticker)).frame(width: size, height: size)
        } else if let img = local ?? StickerVault.shared.cachedImage(sticker, maxPixel: maxPixel) {
            Image(uiImage: img).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            Group {
                if let media = sticker.mediaID {
                    // свой стикер (через бота @stickers)
                    RemoteImage(id: media, fill: false, maxPixel: maxPixel, backdrop: .clear).frame(width: size, height: size)
                } else {
                    builtIn
                }
            }
            .task(id: sticker.id) {
                // файл на телефоне есть — разжимаем в фоне и подменяем сетевую картинку
                if let img = await StickerVault.shared.image(sticker, maxPixel: maxPixel) { local = img }
            }
        }
    }

    private var builtIn: some View {
        CachedImage(url: sticker.url, maxPixel: max(256, size * 3)) { image, failed in
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                Text(sticker.emoji).font(.system(size: size * 0.5))
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
    }
}

/// Анимированный стикер: короткое видео без звука, крутится по кругу, пока на экране.
/// В переписке все строки построены сразу (список не ленивый) и onDisappear не приходит при прокрутке —
/// раньше каждый анимированный стикер в истории декодировал видео без остановки. Теперь играет только видимый
struct StickerVideo: View {
    let mediaID: String
    var local: URL? = nil                       // файл с телефона (сохранённый набор)
    @StateObject private var box = LoopPlayerBox()
    @State private var onScreen = false

    var body: some View {
        PlayerLayerView(player: box.player, gravity: .resizeAspect)
            .allowsHitTesting(false)
            .background(GeometryReader { g in
                let f = g.frame(in: .global)
                let on = f.height > 0 && f.maxY > -40 && f.minY < UIScreen.main.bounds.height + 40
                Color.clear
                    .onAppear { setOnScreen(on) }
                    .onChange(of: on) { _, now in setOnScreen(now) }
            })
            .onDisappear { setOnScreen(false) }
    }

    private func setOnScreen(_ now: Bool) {
        guard now != onScreen else { return }
        onScreen = now
        if now { box.start(mediaID, local: local) } else { box.stop() }
    }
}

/// Плеер «по кругу» без звука — для анимированных стикеров и GIF
@MainActor
final class LoopPlayerBox: ObservableObject {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var current: String?

    init() {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    func start(_ mediaID: String, local: URL? = nil) {
        if current != mediaID, let url = local ?? MediaFileCache.shared.playableURL(mediaID) {
            current = mediaID
            player.removeAllItems()
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        }
        player.play()
    }

    func stop() { player.pause() }
}

// MARK: - Панель вместо клавиатуры: эмодзи и стикеры

struct EmojiStickerPanel: View {
    let packs: [StickerPack]
    let onEmoji: (String) -> Void
    let onBackspace: () -> Void
    let onSticker: (Sticker) -> Void
    /// «Создать стикер»; nil — открыть переписку с ботом @stickers
    var onCreateStickers: (() -> Void)? = nil
    /// Свои эмодзи из эмодзи-паков: вставляются прямо в текст
    var onCustomEmoji: ((CustomEmojiRef) -> Void)? = nil
    /// Набор, который только что сделали или пополнили: панель открывается сразу на нём
    var focusPackID: String? = nil

    private enum Tab: Hashable { case emoji, stickers }

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var tab: Tab = .emoji
    @State private var focusApplied = false
    @State private var category = "smileys"
    @State private var packID: String?
    @State private var recent = EmojiData.recent
    @State private var favs: [Sticker] = FavoriteStickers.all
    @State private var recents: [Sticker] = RecentStickers.all
    private let favID = "__fav__"
    private let recentID = "__recent__"
    @State private var peek: Sticker?           // зажали стикер — крупный предпросмотр с действиями

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if tab == .emoji { emojiTab } else { stickerTab }
            }
            .onAppear { if focusPackID != nil, !focusApplied { focusApplied = true; tab = .stickers } }
            .onChange(of: focusPackID) { _, f in if f != nil { tab = .stickers } }
            .frame(maxHeight: .infinity)

            bottomBar
        }
        .frame(height: 300)
        .background(theme.sheet)
        .overlay { if let st = peek { peekView(st) } }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: peek)
    }

    /// Предпросмотр по долгому нажатию (как в Telegram): крупно, «Отправить» и «В избранное»
    private func peekView(_ st: Sticker) -> some View {
        let fav = favs.contains { $0.id == st.id }
        return ZStack {
            Rectangle().fill(.ultraThinMaterial)
                .contentShape(Rectangle())
                .onTapGesture { peek = nil }
            VStack(spacing: 14) {
                StickerImage(sticker: st, size: 170)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                HStack(spacing: 10) {
                    Button {
                        Haptics.impact(.light)
                        peek = nil
                        send(st)
                    } label: {
                        Label(s.t("Отправить", "Send"), systemImage: "arrow.up")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).frame(height: 40)
                            .background(theme.accent, in: Capsule())
                    }
                    .buttonStyle(PressStyle())
                    Button {
                        Haptics.select()
                        FavoriteStickers.toggle(st)
                        favs = FavoriteStickers.all
                        peek = nil
                    } label: {
                        Label(fav ? s.t("Из избранных", "Unfavorite") : s.t("В избранные", "Favorite"),
                              systemImage: fav ? "star.slash" : "star")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
                            .padding(.horizontal, 16).frame(height: 40)
                            .background(theme.surface, in: Capsule())
                    }
                    .buttonStyle(PressStyle())
                }
            }
        }
        .transition(.opacity)
    }

    // MARK: Эмодзи

    /// Наборы своих эмодзи (сделанные в @stickers и добавленные)
    private var emojiPacks: [StickerPack] { packs.filter { $0.isEmoji && !$0.stickers.isEmpty } }
    private var stickerPacks: [StickerPack] { packs.filter { !$0.isEmoji } }

    private var emojiTab: some View {
        // для отправки доступны только эмодзи с анимацией
        ScrollView {
            if let onCustomEmoji {
                ForEach(emojiPacks) { pack in
                    sectionHeader(pack.title)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 8), spacing: 6) {
                        ForEach(pack.stickers) { e in
                            Button {
                                Haptics.impact(.light)
                                onCustomEmoji(CustomEmojiRef(id: e.id, fallback: e.emoji))
                            } label: {
                                CustomEmojiView(id: e.id, fallback: e.emoji, size: 34, animate: true)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                if !emojiPacks.isEmpty {
                    sectionHeader(s.t("Эмодзи", "Emoji"))
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 8), spacing: 6) {      // плотная сетка в 8 колонок, как в системной клавиатуре эмодзи
                ForEach(AnimatedEmoji.all, id: \.self) { emoji in
                    Button {
                        Haptics.impact(.light)
                        EmojiData.remember(emoji)
                        onEmoji(emoji)
                    } label: {
                        LottieEmojiView(emoji: emoji, size: 34)         // один круг при открытии панели
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.top, 12)
            .padding(.bottom, 8)
        }
    }

    private func chip(id: String, icon: String) -> some View {
        Button { category = id } label: {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(category == id ? theme.accentColor : theme.textSecondary)
                .frame(width: 38, height: 34)
                .background(category == id ? theme.accentColor.opacity(0.14) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Стикеры

    /// Название раздела по центру, заглавными (как в Telegram): «ИЗБРАННЫЕ СТИКЕРЫ», «НЕДАВНИЕ», «КОСМОС».
    /// onClear — крестик справа (очистить «Недавние»)
    private func sectionHeader(_ title: String, onClear: (() -> Void)? = nil) -> some View {
        Text(title.uppercased())
            .font(.system(size: 13, weight: .bold)).tracking(0.6)
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 44)
            .overlay(alignment: .trailing) {
                if let onClear {
                    Button {
                        Haptics.select()
                        onClear()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 36, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                }
            }
            .padding(.top, 14).padding(.bottom, 8)
    }

    /// Единственная кнопка создания: плитка «+ Создать стикер» в начале «Недавних» (нет их — в самом начале)
    private var createTile: some View {
        Button {
            Haptics.impact(.light)
            if let onCreateStickers { onCreateStickers() }
            else if let url = URL(string: "orbita://u/stickers?start=stickers") { UIApplication.shared.open(url) }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "plus").font(.system(size: 22, weight: .medium))
                Text(s.t("Создать\nстикер", "Create\nsticker"))
                    .font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.8)
            }
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity).frame(height: 74)
            .background(theme.text.opacity(theme.dark ? 0.08 : 0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(s.t("Создать стикер", "Create sticker"))
    }

    private func send(_ sticker: Sticker) {
        RecentStickers.add(sticker)
        onSticker(sticker)
        recents = RecentStickers.all
    }

    /// Сетка стикеров; withCreate — первой клеткой плитка «Создать стикер»
    private func stickerGrid(_ stickers: [Sticker], withCreate: Bool = false) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            if withCreate { createTile }
            ForEach(stickers) { sticker in
                Button {
                    guard peek == nil else { return }            // отпустили палец после предпросмотра — не отправляем
                    Haptics.impact(.light)
                    send(sticker)
                } label: {
                    StickerImage(sticker: sticker, size: 74).frame(maxWidth: .infinity)
                }
                .buttonStyle(PressStyle())                       // нажатие — лёгкое «вдавливание», как у кнопок
                // зажали — крупный предпросмотр (отправить / в избранное)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                    Haptics.impact(.medium)
                    peek = sticker
                })
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    /// Разделы ленты стикеров по порядку: избранные, недавние, наборы
    private struct StickerSection: Identifiable { let id: String; let title: String; let stickers: [Sticker] }

    private var sections: [StickerSection] {
        var out: [StickerSection] = []
        if !favs.isEmpty { out.append(StickerSection(id: favID, title: s.t("Избранные стикеры", "Favorite stickers"), stickers: favs)) }
        if !recents.isEmpty { out.append(StickerSection(id: recentID, title: s.t("Недавние", "Recent"), stickers: recents)) }
        out += stickerPacks.filter { !$0.stickers.isEmpty }.map { StickerSection(id: $0.id, title: $0.title, stickers: $0.stickers) }
        return out
    }

    /// Где стоит плитка «Создать стикер»: в «Недавних», а если их нет — в первом разделе
    private var createSectionID: String? { recents.isEmpty ? sections.first?.id : recentID }

    private func stripButton<L: View>(_ id: String, selected: Bool, proxy: ScrollViewProxy, @ViewBuilder label: () -> L) -> some View {
        Button {
            Haptics.select()
            packID = id
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .top) }
        } label: {
            label()
                .frame(width: 42, height: 38)
                .background(selected ? theme.accentColor.opacity(0.14) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var stickerTab: some View {
        let list = sections
        let current = packID ?? list.first?.id
        return ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if !list.isEmpty {
                    // полоска сверху: избранное, недавние и наборы — нажатие листает к разделу
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(list) { sec in
                                stripButton(sec.id, selected: current == sec.id, proxy: proxy) {
                                    if sec.id == favID {
                                        Image(systemName: "bookmark").font(.system(size: 17, weight: .medium))
                                            .foregroundStyle(current == sec.id ? theme.accentColor : theme.textSecondary)
                                    } else if sec.id == recentID {
                                        Image(systemName: "clock").font(.system(size: 17, weight: .medium))
                                            .foregroundStyle(current == sec.id ? theme.accentColor : theme.textSecondary)
                                    } else if let pack = stickerPacks.first(where: { $0.id == sec.id }),
                                              let icon = pack.stickers.first(where: { $0.id == pack.icon }) ?? pack.stickers.first {
                                        StickerImage(sticker: icon, size: 30)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                    .frame(height: 42)
                }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        if list.isEmpty {
                            // нет ни одного стикера — плитка в самом начале и подсказка
                            stickerGrid([], withCreate: true).padding(.top, 12)
                            Text(s.noStickers).font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                                .padding(.top, 18)
                        }
                        ForEach(list) { sec in
                            sectionHeader(sec.title, onClear: sec.id == recentID ? {
                                RecentStickers.clear()
                                withAnimation(.easeOut(duration: 0.2)) { recents = [] }
                            } : nil)
                            .id(sec.id)
                            stickerGrid(sec.stickers, withCreate: sec.id == createSectionID)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        .onAppear {
            recents = RecentStickers.all; favs = FavoriteStickers.all
            if let f = focusPackID, list.contains(where: { $0.id == f }) {
                packID = f
                DispatchQueue.main.async { proxy.scrollTo(f, anchor: .top) }
            }
        }
        .onChange(of: focusPackID) { _, f in
            guard let f, sections.contains(where: { $0.id == f }) else { return }
            packID = f
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(f, anchor: .top) }
        }
        }
    }

    // MARK: Нижняя панель

    private var bottomBar: some View {
        HStack {
            HStack(spacing: 2) {
                tabButton(.emoji, icon: "face.smiling")
                tabButton(.stickers, icon: "seal")
            }
            .padding(3)
            .background(theme.surface, in: Capsule())
            Spacer()
            if tab == .emoji {
                Button {
                    Haptics.impact(.light)
                    onBackspace()
                } label: {
                    Image(systemName: "delete.left")
                        .font(.system(size: 20))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 48, height: 36)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(theme.stroke).frame(height: 1) }
    }

    private func tabButton(_ value: Tab, icon: String) -> some View {
        Button { tab = value; recent = EmojiData.recent } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tab == value ? Color.white : theme.textSecondary)
                .frame(width: 52, height: 30)
                .background(tab == value ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.clear), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
