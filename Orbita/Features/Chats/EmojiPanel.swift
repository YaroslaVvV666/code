import SwiftUI
import UIKit

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

    var body: some View {
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

// MARK: - Панель вместо клавиатуры: эмодзи и стикеры

struct EmojiStickerPanel: View {
    let packs: [StickerPack]
    let onEmoji: (String) -> Void
    let onBackspace: () -> Void
    let onSticker: (Sticker) -> Void

    private enum Tab: Hashable { case emoji, stickers }

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var tab: Tab = .emoji
    @State private var category = "smileys"
    @State private var packID: String?
    @State private var recent = EmojiData.recent

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if tab == .emoji { emojiTab } else { stickerTab }
            }
            .frame(maxHeight: .infinity)

            bottomBar
        }
        .frame(height: 300)
        .background(theme.sheet)
    }

    // MARK: Эмодзи

    private var emojiTab: some View {
        // для отправки доступны только эмодзи с анимацией
        ScrollView {
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

    private var stickerTab: some View {
        VStack(spacing: 0) {
            if packs.isEmpty {
                Text(s.noStickers).font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(packs) { pack in
                            let selected = (packID ?? packs.first?.id) == pack.id
                            Button { packID = pack.id } label: {
                                Group {
                                    if let icon = pack.stickers.first(where: { $0.id == pack.icon }) ?? pack.stickers.first {
                                        StickerImage(sticker: icon, size: 30)
                                    }
                                }
                                .frame(width: 42, height: 38)
                                .background(selected ? theme.accentColor.opacity(0.14) : Color.clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(height: 42)

                ScrollView {
                    let pack = packs.first { $0.id == (packID ?? packs.first?.id) } ?? packs[0]
                    Text(pack.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.top, 4)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(pack.stickers) { sticker in
                            Button {
                                Haptics.impact(.light)
                                onSticker(sticker)
                            } label: {
                                StickerImage(sticker: sticker, size: 74).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
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
