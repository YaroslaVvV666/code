import SwiftUI
import Combine
import UIKit

// MARK: - Оформление (как в Telegram): превью чата, темы, обои, ночная тема, размер текста, углы, анимации, иконка

/// Готовые темы: цвет акцента + обои по умолчанию + значок карточки
private struct ThemePreset: Identifiable {
    let id: String
    let accent: Int
    let wallpaper: String
    let emoji: String
}

private let themePresets: [ThemePreset] = [
    .init(id: "space", accent: 0, wallpaper: "default", emoji: "🪐"),
    .init(id: "lavender", accent: 1, wallpaper: "p:stars", emoji: "💜"),
    .init(id: "sea", accent: 2, wallpaper: "g:ocean", emoji: "🌊"),
    .init(id: "forest", accent: 3, wallpaper: "p:leaves", emoji: "🌿"),
    .init(id: "sunset", accent: 4, wallpaper: "g:sunset", emoji: "🔥"),
    .init(id: "sakura", accent: 5, wallpaper: "p:hearts", emoji: "🌸"),
    .init(id: "night", accent: 1, wallpaper: "p:moons", emoji: "🌙"),
    .init(id: "music", accent: 0, wallpaper: "p:music", emoji: "🎧"),
]

/// Иконки приложения (имена — наборы в Assets.xcassets; nil — основная)
struct AppIconChoice: Identifiable {
    let id: String
    let iconName: String?
    let preview: String
    let ru: String
    let en: String

    static let all: [AppIconChoice] = [
        .init(id: "main", iconName: nil, preview: "IconPreviewMain", ru: "Основная", en: "Default"),
        .init(id: "ocean", iconName: "AppIconOcean", preview: "IconPreviewOcean", ru: "Океан", en: "Ocean"),
        .init(id: "sunset", iconName: "AppIconSunset", preview: "IconPreviewSunset", ru: "Закат", en: "Sunset"),
        .init(id: "mainx", iconName: "AppIconMainX", preview: "IconPreviewMainX", ru: "Основная X", en: "Default X"),
        .init(id: "fill", iconName: "AppIconFill", preview: "IconPreviewFill", ru: "Заливка", en: "Filled"),
        .init(id: "fillx", iconName: "AppIconFillX", preview: "IconPreviewFillX", ru: "Заливка X", en: "Filled X"),
        .init(id: "blue", iconName: "AppIconBlue", preview: "IconPreviewBlue", ru: "Синяя", en: "Blue"),
        .init(id: "star", iconName: "AppIconStar", preview: "IconPreviewStar", ru: "Звезда", en: "Star"),
        .init(id: "comet", iconName: "AppIconComet", preview: "IconPreviewComet", ru: "Комета", en: "Comet"),
        .init(id: "space", iconName: "AppIconSpace", preview: "IconPreviewSpace", ru: "Космос", en: "Space"),
        .init(id: "night", iconName: "AppIconNight", preview: "IconPreviewNight", ru: "Ночь", en: "Night"),
    ]
}

struct AppearanceScreen: View {
    @AppStorage("isDark") private var isDark = true
    @AppStorage("accent") private var accent = 0
    @AppStorage("theme.mode") private var themeMode = "manual"         // manual | system
    @AppStorage("chat.textSize") private var textSize = 0
    @AppStorage("chat.radius") private var radius = 21.0
    @AppStorage("media.tapPaging") private var tapPaging = true
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @ObservedObject private var wallpapers = ChatAppearanceStore.shared

    @State private var sheet: Sub?
    @State private var currentIcon: String? = UIApplication.shared.alternateIconName
    @State private var iconError = false

    enum Sub: String, Identifiable { case wallpaper, colors, corners, animations, stickers; var id: String { rawValue } }

    private var s: Strings { Strings(lang: lang) }
    private var globalWallpaper: String { wallpapers.appearance(ChatAppearanceStore.global).wallpaper }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(s.t("Цветовая тема — ", "Color theme — ") + (isDark ? s.t("ночной режим", "night mode") : s.t("дневной режим", "day mode")))
            VStack(spacing: 0) {
                ChatPreviewCard(textSize: textSize, radius: radius)
                    .frame(height: 200)
                    .clipped()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(themePresets) { p in themeCard(p) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 14)
                }
                SettingsDivider()
                navRow(s.t("Обои для чатов", "Chat wallpapers")) { sheet = .wallpaper }
                SettingsDivider()
                Button { sheet = .colors } label: {
                    HStack(spacing: 8) {
                        Text(s.t("Персональные цвета", "Personal colors")).font(.system(size: 16)).foregroundStyle(theme.text)
                        Spacer()
                        ZStack {
                            Circle().fill(Theme.swatch(accent)).frame(width: 26, height: 26).offset(x: -12)
                            Circle().fill(LinearGradient(colors: [Color(white: 0.45), Color(white: 0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().stroke(theme.surface, lineWidth: 2))
                        }
                        Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(theme.textTertiary)
                    }
                    .padding(.horizontal, 16).frame(height: 52).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
            .card(theme, radius: 22)
            .padding(.horizontal, 16)

            group {
                HStack {
                    Text(s.t("Ночной режим", "Night mode")).font(.system(size: 16))
                        .foregroundStyle(themeMode == "system" ? theme.textTertiary : theme.text)
                    Spacer()
                    Toggle("", isOn: Binding(get: { isDark }, set: { v in withAnimation(.easeInOut(duration: 0.3)) { isDark = v } }))
                        .labelsHidden().tint(theme.accentColor)
                        .disabled(themeMode == "system")
                }
                .padding(.horizontal, 16).frame(height: 52)
                SettingsDivider()
                menuRow(s.t("Ночная тема", "Auto-night mode"), value: themeMode == "system" ? s.t("Системная", "System") : s.t("Отключена", "Off"),
                        options: [("system", s.t("Системная — как на iPhone", "System — like iPhone")), ("manual", s.t("Отключена — вручную", "Off — manual"))]) { v in
                    themeMode = v
                    if v == "system" {
                        let dark = UIScreen.main.traitCollection.userInterfaceStyle == .dark
                        withAnimation(.easeInOut(duration: 0.3)) { isDark = dark }
                    }
                }
            }
            .padding(.top, 26)

            group {
                menuRow(s.t("Размер текста", "Text size"), value: textSize == 0 ? s.t("Системный", "System") : "\(textSize) pt",
                        options: [("0", s.t("Системный", "System"))] + [14, 15, 17, 18, 20, 22].map { ("\($0)", "\($0) pt") }) { v in
                    withAnimation(.easeOut(duration: 0.2)) { textSize = Int(v) ?? 0 }
                }
                SettingsDivider()
                navRow(s.t("Углы блоков с сообщениями", "Message corners")) { sheet = .corners }
                SettingsDivider()
                navRow(s.t("Анимации", "Animations")) { sheet = .animations }
                SettingsDivider()
                navRow(s.t("Стикеры и эмодзи", "Stickers and emoji")) { sheet = .stickers }
            }
            .padding(.top, 26)

            header(s.t("Иконка приложения", "App icon")).padding(.top, 14)
            iconGrid
            if iconError {
                Text(s.t("Не удалось сменить иконку — попробуйте ещё раз.", "Couldn't change the icon — try again."))
                    .font(.system(size: 13)).foregroundStyle(theme.danger).padding(.horizontal, 30).padding(.top, 6)
            }

            header(s.t("Другое", "Other")).padding(.top, 14)
            group {
                HStack {
                    Text(s.t("Листать медиа по нажатию", "Tap to switch media")).font(.system(size: 16)).foregroundStyle(theme.text)
                    Spacer()
                    Toggle("", isOn: $tapPaging).labelsHidden().tint(theme.accentColor)
                }
                .padding(.horizontal, 16).frame(height: 52)
            }
            Text(s.t("Листать нажатием у края экрана в режиме просмотра медиафайлов.", "Tap near the screen edge to switch photos in the media viewer."))
                .font(.system(size: 13)).foregroundStyle(theme.textSecondary).padding(.horizontal, 30).padding(.top, 8)
        }
        .padding(.bottom, 20)
        .sheet(item: $sheet) { sub in
            Group {
                switch sub {
                case .wallpaper: ChatAppearanceSheet(chatID: ChatAppearanceStore.global, chatName: s.t("Все чаты", "All chats"))
                case .colors: AccentSheet()
                case .corners: CornersSheet()
                case .animations: AnimationsSheet()
                case .stickers: StickersEmojiSheet()
                }
            }
            .environment(\.theme, theme).environment(\.lang, lang)
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: Темы

    private func themeCard(_ p: ThemePreset) -> some View {
        let selected = accent == p.accent && globalWallpaper == p.wallpaper
        return Button {
            Haptics.select()
            withAnimation(.easeInOut(duration: 0.3)) {
                accent = p.accent
                ChatAppearanceStore.shared.update(ChatAppearanceStore.global) { $0.wallpaper = p.wallpaper; $0.bubble = nil }
            }
        } label: {
            ZStack {
                if let preset = WallpaperPreset.find(p.wallpaper) {
                    WallpaperFill(preset: preset, dark: isDark, compact: true)
                } else {
                    SpaceBackground(isDark: isDark, showStars: true)
                }
                VStack(spacing: 8) {
                    Capsule().fill(Theme.swatch(p.accent)).frame(width: 52, height: 20)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Capsule().fill(Color.white.opacity(isDark ? 0.16 : 0.8)).frame(width: 52, height: 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                    Text(p.emoji).font(.system(size: 26))
                }
                .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 10)
            }
            .frame(width: 84, height: 116)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? theme.accentColor : theme.stroke, lineWidth: selected ? 3 : 1))
            .padding(selected ? 1.5 : 0)
        }
        .buttonStyle(PressStyle())
    }

    // MARK: Иконки

    private var iconGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 16) {
            ForEach(AppIconChoice.all) { c in
                let on = currentIcon == c.iconName
                Button { setIcon(c) } label: {
                    VStack(spacing: 6) {
                        Image(c.preview).resizable().scaledToFit()
                            .frame(width: 62, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.stroke, lineWidth: 0.5))
                            .padding(3)
                            .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .stroke(on ? theme.accentColor : .clear, lineWidth: 2.5))
                        Text(lang == .ru ? c.ru : c.en)
                            .font(.system(size: 12, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? theme.accentColor : theme.text)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 16)
        .card(theme, radius: 22)
        .padding(.horizontal, 16)
    }

    private func setIcon(_ c: AppIconChoice) {
        guard UIApplication.shared.supportsAlternateIcons, currentIcon != c.iconName else { return }
        Haptics.select()
        iconError = false
        UIApplication.shared.setAlternateIconName(c.iconName) { error in
            DispatchQueue.main.async {
                if error == nil {
                    withAnimation(.easeOut(duration: 0.2)) { currentIcon = c.iconName }
                } else {
                    iconError = true
                }
            }
        }
    }

    // MARK: Строки

    private func header(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 30).padding(.bottom, 8)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .card(theme, radius: 22)
            .padding(.horizontal, 16)
    }

    private func navRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 16)).foregroundStyle(theme.text)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 16).frame(height: 52).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private func menuRow(_ title: String, value: String, options: [(String, String)], pick: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.0) { o in
                Button { Haptics.select(); pick(o.0) } label: { Text(o.1) }
            }
        } label: {
            HStack {
                Text(title).font(.system(size: 16)).foregroundStyle(theme.text)
                Spacer()
                Text(value).font(.system(size: 16)).foregroundStyle(theme.textSecondary)
                Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 16).frame(height: 52).contentShape(Rectangle())
        }
    }
}

// MARK: - Превью чата с текущими настройками

private struct ChatPreviewCard: View {
    let textSize: Int
    let radius: Double
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        let s = Strings(lang: lang)
        let size = CGFloat(textSize > 0 ? textSize : 16)
        let r = CGFloat(radius)
        ZStack {
            ChatWallpaperView(chatID: ChatAppearanceStore.global, showStars: true)
            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(theme.accentColor).frame(width: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.t("Алиса", "Alice")).font(.system(size: size - 2, weight: .semibold)).foregroundStyle(theme.accentColor)
                            Text(s.t("Доброе утро! 👋", "Good morning! 👋")).font(.system(size: size - 2)).foregroundStyle(theme.text)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: min(8, r), style: .continuous))
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text(s.t("Знаешь, который час?", "Do you know what time it is?")).font(.system(size: size)).foregroundStyle(theme.text)
                        Text("21:20").font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                    }
                }
                .padding(8)
                .background(theme.dark ? Color(white: 0.16) : Color.white,
                            in: UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: min(6, r), bottomTrailingRadius: r,
                                                       topTrailingRadius: r, style: .continuous))
                .frame(maxWidth: 260, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(s.t("В Токио утро 😎", "It's morning in Tokyo 😎")).font(.system(size: size)).foregroundStyle(.white)
                    Text("21:20").font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(theme.accent, in: UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r,
                                                                     bottomTrailingRadius: min(6, r), topTrailingRadius: r, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .animation(.easeOut(duration: 0.2), value: textSize)
            .animation(.easeOut(duration: 0.2), value: radius)
        }
    }
}

// MARK: - Подэкраны

private struct SheetHeader: View {
    let title: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    var body: some View {
        ZStack {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(theme.textSecondary)
                        .frame(width: 34, height: 34).background(theme.surface, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 10)
    }
}

private struct AccentSheet: View {
    @AppStorage("accent") private var accent = 0
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    var body: some View {
        let s = Strings(lang: lang)
        VStack(spacing: 16) {
            SheetHeader(title: s.t("Персональные цвета", "Personal colors"))
            ChatPreviewCard(textSize: UserDefaults.standard.integer(forKey: "chat.textSize"),
                            radius: UserDefaults.standard.object(forKey: "chat.radius") as? Double ?? 21)
                .frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous)).padding(.horizontal, 16)
            HStack(spacing: 14) {
                ForEach(0..<Theme.accents.count, id: \.self) { i in
                    Button {
                        Haptics.select()
                        withAnimation(.easeInOut(duration: 0.25)) { accent = i }
                    } label: {
                        Circle().fill(Theme.swatch(i)).frame(width: 44, height: 44)
                            .overlay { if accent == i { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white) } }
                            .overlay(Circle().stroke(theme.stroke, lineWidth: 1))
                    }
                    .buttonStyle(PressStyle())
                }
            }
            Text(s.t("Цвет ваших сообщений, кнопок и выделения во всём приложении.", "Color of your messages, buttons and highlights across the app."))
                .font(.system(size: 13)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center).padding(.horizontal, 30)
            Spacer()
        }
        .background(theme.sheet.ignoresSafeArea())
        .presentationDetents([.medium, .large])
    }
}

private struct CornersSheet: View {
    @AppStorage("chat.radius") private var radius = 21.0
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    var body: some View {
        let s = Strings(lang: lang)
        VStack(spacing: 16) {
            SheetHeader(title: s.t("Углы блоков с сообщениями", "Message corners"))
            ChatPreviewCard(textSize: UserDefaults.standard.integer(forKey: "chat.textSize"), radius: radius)
                .frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous)).padding(.horizontal, 16)
            HStack(spacing: 12) {
                Image(systemName: "square").foregroundStyle(theme.textSecondary)
                Slider(value: $radius, in: 0...21, step: 1).tint(theme.accentColor)
                    .onChange(of: radius) { _, _ in Haptics.select() }
                Image(systemName: "capsule").foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 24)
            Button(s.t("Сбросить", "Reset")) { withAnimation { radius = 21 } }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accentColor)
            Spacer()
        }
        .background(theme.sheet.ignoresSafeArea())
        .presentationDetents([.medium])
    }
}

private struct ToggleLine: View {
    let title: String
    let hint: String
    @Binding var on: Bool
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 16)).foregroundStyle(theme.text)
                Spacer()
                Toggle("", isOn: $on).labelsHidden().tint(theme.accentColor)
            }
            .padding(.horizontal, 16).frame(height: 52)
            .card(theme, radius: 18).padding(.horizontal, 16)
            Text(hint).font(.system(size: 13)).foregroundStyle(theme.textSecondary).padding(.horizontal, 30)
        }
    }
}

private struct AnimationsSheet: View {
    @AppStorage("anim.messages") private var messages = true
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    var body: some View {
        let s = Strings(lang: lang)
        VStack(spacing: 18) {
            SheetHeader(title: s.t("Анимации", "Animations"))
            ToggleLine(title: s.t("Появление сообщений", "Message appearance"),
                       hint: s.t("Новые сообщения в чате мягко вырастают из своего угла. Выключите — будут просто появляться.",
                                 "New messages grow from their corner. Turn off to make them simply appear."), on: $messages)
            Spacer()
        }
        .background(theme.sheet.ignoresSafeArea())
        .presentationDetents([.medium])
    }
}

private struct StickersEmojiSheet: View {
    @AppStorage("stickers.suggest") private var suggest = true
    @AppStorage("emoji.big") private var big = true
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    var body: some View {
        let s = Strings(lang: lang)
        VStack(spacing: 18) {
            SheetHeader(title: s.t("Стикеры и эмодзи", "Stickers and emoji"))
            ToggleLine(title: s.t("Подсказывать стикеры", "Suggest stickers"),
                       hint: s.t("Ввели одно эмодзи — над полем появятся подходящие стикеры из ваших наборов.",
                                 "Type a single emoji to see matching stickers from your packs."), on: $suggest)
            ToggleLine(title: s.t("Крупные эмодзи", "Large emoji"),
                       hint: s.t("Сообщение из одного–трёх эмодзи показывается крупно, без пузыря.",
                                 "Messages with one to three emoji are shown large, without a bubble."), on: $big)
            Spacer()
        }
        .background(theme.sheet.ignoresSafeArea())
        .presentationDetents([.medium, .large])
    }
}
