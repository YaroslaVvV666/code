import SwiftUI
import PhotosUI
import UIKit

// MARK: - Оформление отдельного чата: обои и цвет моих сообщений (хранится только на этом устройстве)

struct ChatAppearance: Codable, Equatable {
    /// "default" — фон приложения; "g:<id>" — градиент; "p:<id>" — узор; "photo" — своё фото
    var wallpaper: String = "default"
    /// Цвет моих сообщений (и акцентов в этом чате); nil — как в общей теме
    var bubble: ThemeRGB? = nil
    /// Затемнение своего фото, 0…0.7
    var dim: Double = 0.15
    /// Размыть своё фото
    var blur: Bool = false

    var isDefault: Bool { wallpaper == "default" && bubble == nil }
}

/// Готовые фоны
struct WallpaperPreset: Identifiable {
    let id: String
    let colors: [Color]
    var symbol: String? = nil           // узор поверх градиента

    static let gradients: [WallpaperPreset] = [
        .init(id: "g:aurora", colors: [Color(red: 0.11, green: 0.62, blue: 0.62), Color(red: 0.36, green: 0.30, blue: 0.78)]),
        .init(id: "g:sunset", colors: [Color(red: 0.98, green: 0.62, blue: 0.32), Color(red: 0.86, green: 0.30, blue: 0.52)]),
        .init(id: "g:ocean", colors: [Color(red: 0.20, green: 0.52, blue: 0.94), Color(red: 0.24, green: 0.80, blue: 0.88)]),
        .init(id: "g:forest", colors: [Color(red: 0.20, green: 0.56, blue: 0.40), Color(red: 0.64, green: 0.80, blue: 0.40)]),
        .init(id: "g:lavender", colors: [Color(red: 0.72, green: 0.62, blue: 0.95), Color(red: 0.95, green: 0.70, blue: 0.86)]),
        .init(id: "g:peach", colors: [Color(red: 1.00, green: 0.84, blue: 0.70), Color(red: 0.98, green: 0.62, blue: 0.62)]),
        .init(id: "g:night", colors: [Color(red: 0.06, green: 0.08, blue: 0.22), Color(red: 0.28, green: 0.16, blue: 0.46)]),
        .init(id: "g:graphite", colors: [Color(red: 0.22, green: 0.24, blue: 0.28), Color(red: 0.42, green: 0.45, blue: 0.52)])
    ]

    static let patterns: [WallpaperPreset] = [
        .init(id: "p:stars", colors: [Color(red: 0.10, green: 0.12, blue: 0.30), Color(red: 0.30, green: 0.22, blue: 0.55)], symbol: "sparkle"),
        .init(id: "p:hearts", colors: [Color(red: 0.98, green: 0.58, blue: 0.66), Color(red: 0.80, green: 0.36, blue: 0.62)], symbol: "heart.fill"),
        .init(id: "p:music", colors: [Color(red: 0.26, green: 0.40, blue: 0.86), Color(red: 0.56, green: 0.36, blue: 0.86)], symbol: "music.note"),
        .init(id: "p:planes", colors: [Color(red: 0.36, green: 0.74, blue: 0.92), Color(red: 0.20, green: 0.48, blue: 0.86)], symbol: "paperplane.fill"),
        .init(id: "p:leaves", colors: [Color(red: 0.36, green: 0.70, blue: 0.46), Color(red: 0.14, green: 0.46, blue: 0.40)], symbol: "leaf.fill"),
        .init(id: "p:moons", colors: [Color(red: 0.16, green: 0.20, blue: 0.36), Color(red: 0.08, green: 0.10, blue: 0.18)], symbol: "moon.stars.fill")
    ]

    static func find(_ id: String) -> WallpaperPreset? {
        gradients.first { $0.id == id } ?? patterns.first { $0.id == id }
    }

    /// Цвета для моих сообщений
    static let bubbles: [ThemeRGB] = [
        ThemeRGB(r: 0.30, g: 0.46, b: 0.92), ThemeRGB(r: 0.50, g: 0.40, b: 0.90), ThemeRGB(r: 0.12, g: 0.60, b: 0.68),
        ThemeRGB(r: 0.22, g: 0.64, b: 0.45), ThemeRGB(r: 0.90, g: 0.54, b: 0.20), ThemeRGB(r: 0.86, g: 0.36, b: 0.58),
        ThemeRGB(r: 0.86, g: 0.30, b: 0.30), ThemeRGB(r: 0.80, g: 0.60, b: 0.12), ThemeRGB(r: 0.32, g: 0.30, b: 0.75),
        ThemeRGB(r: 0.20, g: 0.66, b: 0.60), ThemeRGB(r: 0.38, g: 0.42, b: 0.50)
    ]
}

@MainActor
final class ChatAppearanceStore: ObservableObject {
    static let shared = ChatAppearanceStore()

    @Published private(set) var map: [String: ChatAppearance] = [:]
    /// Меняется при замене своего фото — фон перечитывает картинку
    @Published private(set) var photoTick = 0
    private var photoCache: [String: UIImage] = [:]
    private let key = "orbita.chat.appearance"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let m = try? JSONDecoder().decode([String: ChatAppearance].self, from: data) {
            map = m
        }
    }

    func appearance(_ chatID: String) -> ChatAppearance { map[chatID] ?? ChatAppearance() }

    func theme(_ base: Theme, for chatID: String) -> Theme {
        guard let rgb = map[chatID]?.bubble else { return base }
        return base.withAccent(Self.readable(rgb))
    }

    func update(_ chatID: String, _ change: (inout ChatAppearance) -> Void) {
        var a = appearance(chatID)
        change(&a)
        if a.isDefault { map[chatID] = nil } else { map[chatID] = a }
        if a.wallpaper != "photo" { removePhoto(chatID) }
        save()
    }

    func reset(_ chatID: String) {
        map[chatID] = nil
        removePhoto(chatID)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(map) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Белый текст должен читаться: слишком светлые цвета притемняем
    static func readable(_ c: ThemeRGB) -> ThemeRGB {
        let lum = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
        guard lum > 0.62 else { return c }
        let k = 0.62 / lum
        return ThemeRGB(r: c.r * k, g: c.g * k, b: c.b * k)
    }

    // MARK: своё фото

    private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func photoURL(_ chatID: String) -> URL {
        let safe = chatID.replacingOccurrences(of: "/", with: "_")
        return folder.appendingPathComponent("\(safe).jpg")
    }

    func cachedPhoto(_ chatID: String) -> UIImage? { photoCache[chatID] }

    /// Читает и разжимает фото в фоне (не на главном потоке)
    func loadPhoto(_ chatID: String) async -> UIImage? {
        if let img = photoCache[chatID] { return img }
        let url = Self.photoURL(chatID)
        let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ImageCache.downsample(data, maxPixel: 1800)
        }.value
        if let img { photoCache[chatID] = img }
        return img
    }

    /// Сохраняет выбранное фото (уменьшенное) и включает его фоном чата
    func setPhoto(_ chatID: String, data: Data) async -> Bool {
        let url = Self.photoURL(chatID)
        let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let img = ImageCache.downsample(data, maxPixel: 1800), let jpeg = img.jpegData(compressionQuality: 0.85) else { return nil }
            try? jpeg.write(to: url, options: .atomic)
            return img
        }.value
        guard let img else { return false }
        photoCache[chatID] = img
        var a = appearance(chatID)
        a.wallpaper = "photo"
        map[chatID] = a
        save()
        photoTick += 1
        return true
    }

    private func removePhoto(_ chatID: String) {
        guard photoCache[chatID] != nil || FileManager.default.fileExists(atPath: Self.photoURL(chatID).path) else { return }
        photoCache[chatID] = nil
        try? FileManager.default.removeItem(at: Self.photoURL(chatID))
        photoTick += 1
    }
}

// MARK: - Фон переписки

struct ChatWallpaperView: View {
    let chatID: String
    var showStars = false

    @ObservedObject private var store = ChatAppearanceStore.shared
    @Environment(\.theme) private var theme
    @State private var photo: UIImage?

    private var appearance: ChatAppearance { store.appearance(chatID) }

    var body: some View {
        let a = appearance
        ZStack {
            if a.wallpaper == "photo" {
                // фон приложения — пока фото читается с диска
                SpaceBackground(isDark: theme.dark, showStars: false)
                if let img = photo ?? store.cachedPhoto(chatID) {
                    Color.clear
                        .overlay {
                            Image(uiImage: img).resizable().scaledToFill()
                                .blur(radius: a.blur ? 18 : 0)
                        }
                        .clipped()
                        .overlay(Color.black.opacity(a.dim))
                        .transition(.opacity)
                }
            } else if let preset = WallpaperPreset.find(a.wallpaper) {
                WallpaperFill(preset: preset, dark: theme.dark)
            } else {
                SpaceBackground(isDark: theme.dark, showStars: showStars)
            }
        }
        .ignoresSafeArea()
        .task(id: "\(a.wallpaper)-\(store.photoTick)") {
            guard a.wallpaper == "photo" else { photo = nil; return }
            let img = await store.loadPhoto(chatID)
            withAnimation(.easeOut(duration: 0.2)) { photo = img }
        }
    }
}

/// Градиент (и узор) готового фона; в тёмной теме — притушенный
struct WallpaperFill: View {
    let preset: WallpaperPreset
    let dark: Bool
    var compact = false

    var body: some View {
        ZStack {
            LinearGradient(colors: preset.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            if let symbol = preset.symbol {
                WallpaperPattern(symbol: symbol, step: compact ? 26 : 54, size: compact ? 9 : 18)
            }
            Color.black.opacity(dark ? 0.38 : 0)
        }
    }
}

/// Повторяющийся узор из значков; рисуется один раз (Canvas), не анимируется
struct WallpaperPattern: View {
    let symbol: String
    var step: CGFloat = 54
    var size: CGFloat = 18

    var body: some View {
        Canvas { ctx, sz in
            guard let mark = ctx.resolveSymbol(id: 0) else { return }
            var row = 0
            var y: CGFloat = step / 2
            while y < sz.height + step {
                var x: CGFloat = row % 2 == 0 ? step / 2 : step
                var i = row
                while x < sz.width + step {
                    var c = ctx
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .degrees(Double((i * 37) % 50) - 25))
                    c.draw(mark, at: .zero)
                    x += step
                    i += 1
                }
                y += step * 0.86
                row += 1
            }
        } symbols: {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.16))
                .tag(0)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Настройки оформления чата

struct ChatAppearanceSheet: View {
    let chatID: String
    let chatName: String

    @ObservedObject private var store = ChatAppearanceStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var baseTheme
    @Environment(\.lang) private var lang
    @State private var pickerItem: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var customColor: Color = .blue

    private var s: Strings { Strings(lang: lang) }
    private var a: ChatAppearance { store.appearance(chatID) }
    /// Тема без своего цвета чата (вокруг шторки — общая), превью — с ним
    private var plainTheme: Theme { var t = baseTheme; t.customAccent = nil; return t }
    private var previewTheme: Theme { store.theme(plainTheme, for: chatID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    preview
                    section(s.t("Фон", "Background")) { wallpapers }
                    if a.wallpaper == "photo" { photoControls }
                    section(s.t("Цвет моих сообщений", "My message colour")) { bubbles }
                    if !a.isDefault {
                        Button(role: .destructive) {
                            withAnimation { store.reset(chatID) }
                        } label: {
                            Text(s.t("Сбросить оформление", "Reset appearance")).font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(plainTheme.danger)
                                .frame(maxWidth: .infinity).frame(height: 48)
                                .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(s.t("Оформление видно только вам и только в этом чате.", "Only you see this, and only in this chat."))
                        .font(.system(size: 13)).foregroundStyle(plainTheme.textTertiary)
                        .frame(maxWidth: .infinity)
                }
                .padding(16)
            }
            .background(plainTheme.sheet.ignoresSafeArea())
            .navigationTitle(s.t("Обои и цвет", "Wallpaper & colour"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(s.t("Готово", "Done")) { dismiss() }.foregroundStyle(plainTheme.accentColor)
                }
            }
        }
        .environment(\.theme, plainTheme)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            loadingPhoto = true
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    _ = await store.setPhoto(chatID, data: data)
                }
                loadingPhoto = false
                pickerItem = nil
            }
        }
    }

    // превью: фон и два сообщения
    private var preview: some View {
        let colors = ChatColors(theme: previewTheme)
        return ZStack {
            ChatWallpaperView(chatID: chatID)
            VStack(spacing: 8) {
                HStack {
                    Text(s.t("Привет! Как тебе новые обои? 🌌", "Hi! How do you like the new wallpaper? 🌌"))
                        .font(.system(size: 15)).foregroundStyle(colors.incomingText)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(colors.incoming, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    Spacer(minLength: 40)
                }
                HStack {
                    Spacer(minLength: 40)
                    Text(s.t("Огонь, оставляю 🔥", "Love it, keeping it 🔥"))
                        .font(.system(size: 15)).foregroundStyle(colors.outgoingText)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(previewTheme.accent, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
            }
            .padding(14)
            if loadingPhoto { ProgressView().tint(.white) }
        }
        .environment(\.theme, previewTheme)
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .topLeading) {
            Text(chatName).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(10)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 12, weight: .semibold)).foregroundStyle(plainTheme.textTertiary)
            content()
        }
    }

    private var wallpapers: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                tile(selected: a.wallpaper == "default", label: s.t("Обычный", "Default")) {
                    SpaceBackground(isDark: plainTheme.dark, showStars: false)
                } action: { store.update(chatID) { $0.wallpaper = "default" } }

                PhotosPicker(selection: $pickerItem, matching: .images) {
                    VStack(spacing: 6) {
                        ZStack {
                            if a.wallpaper == "photo", let img = store.cachedPhoto(chatID) {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else {
                                plainTheme.surface
                                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 22))
                                    .foregroundStyle(plainTheme.accentColor)
                            }
                        }
                        .frame(width: 72, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(selection(a.wallpaper == "photo"))
                        Text(s.t("Своё фото", "Photo")).font(.system(size: 12)).foregroundStyle(plainTheme.textSecondary)
                    }
                }
                .buttonStyle(.plain)

                ForEach(WallpaperPreset.gradients + WallpaperPreset.patterns) { p in
                    tile(selected: a.wallpaper == p.id, label: nil) {
                        WallpaperFill(preset: p, dark: plainTheme.dark, compact: true)
                    } action: { store.update(chatID) { $0.wallpaper = p.id } }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func tile<C: View>(selected: Bool, label: String?, @ViewBuilder _ content: () -> C, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { action() }
            Haptics.impact(.light)
        } label: {
            VStack(spacing: 6) {
                content()
                    .frame(width: 72, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(selection(selected))
                Text(label ?? " ").font(.system(size: 12)).foregroundStyle(plainTheme.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func selection(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(on ? plainTheme.accentColor : plainTheme.stroke, lineWidth: on ? 3 : 1)
    }

    private var photoControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sun.min").foregroundStyle(plainTheme.textSecondary)
                Slider(value: Binding(get: { a.dim }, set: { v in store.update(chatID) { $0.dim = v } }), in: 0...0.7)
                    .tint(plainTheme.accentColor)
                Image(systemName: "moon.fill").foregroundStyle(plainTheme.textSecondary)
            }
            Toggle(s.t("Размыть фото", "Blur photo"), isOn: Binding(get: { a.blur }, set: { v in store.update(chatID) { $0.blur = v } }))
                .tint(plainTheme.accentColor)
                .foregroundStyle(plainTheme.text)
        }
        .padding(14)
        .glass(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var bubbles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // «как в теме»
                Button {
                    withAnimation { store.update(chatID) { $0.bubble = nil } }
                } label: {
                    Circle().fill(plainTheme.accent).frame(width: 38, height: 38)
                        .overlay(Image(systemName: "circle.lefthalf.filled").font(.system(size: 14)).foregroundStyle(.white))
                        .overlay(Circle().stroke(plainTheme.text, lineWidth: a.bubble == nil ? 2.5 : 0).padding(-4))
                }
                .buttonStyle(.plain)
                ForEach(WallpaperPreset.bubbles, id: \.self) { c in
                    Button {
                        withAnimation { store.update(chatID) { $0.bubble = c } }
                        Haptics.impact(.light)
                    } label: {
                        Circle().fill(c.color).frame(width: 38, height: 38)
                            .overlay(Circle().stroke(plainTheme.text, lineWidth: a.bubble == c ? 2.5 : 0).padding(-4))
                    }
                    .buttonStyle(.plain)
                }
                ColorPicker("", selection: Binding(get: { customColor }, set: { c in
                    customColor = c
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, al: CGFloat = 0
                    guard UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &al) else { return }
                    let rgb = ThemeRGB(r: Double(max(0, min(1, r))), g: Double(max(0, min(1, g))), b: Double(max(0, min(1, b))))
                    store.update(chatID) { $0.bubble = rgb }
                }), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 38, height: 38)
            }
            .padding(6)
        }
    }
}
