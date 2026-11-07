import SwiftUI
import Combine

// MARK: - Цвета профиля (как в Telegram: 8 однотонных и 8 двухцветных)

enum ProfilePalette {
    /// (верх, низ). У однотонных обе половины одинаковые.
    static let colors: [(Color, Color)] = [
        (c(0.29, 0.51, 0.78), c(0.29, 0.51, 0.78)),
        (c(0.33, 0.62, 0.22), c(0.33, 0.62, 0.22)),
        (c(0.72, 0.47, 0.20), c(0.72, 0.47, 0.20)),
        (c(0.69, 0.32, 0.28), c(0.69, 0.32, 0.28)),
        (c(0.52, 0.35, 0.78), c(0.52, 0.35, 0.78)),
        (c(0.33, 0.64, 0.68), c(0.33, 0.64, 0.68)),
        (c(0.66, 0.32, 0.50), c(0.66, 0.32, 0.50)),
        (c(0.47, 0.53, 0.62), c(0.47, 0.53, 0.62)),
        (c(0.53, 0.82, 0.93), c(0.36, 0.55, 0.82)),
        (c(0.70, 0.84, 0.40), c(0.28, 0.58, 0.38)),
        (c(0.95, 0.75, 0.30), c(0.76, 0.44, 0.30)),
        (c(0.96, 0.60, 0.45), c(0.74, 0.30, 0.34)),
        (c(0.90, 0.50, 0.90), c(0.50, 0.35, 0.78)),
        (c(0.55, 0.88, 0.76), c(0.28, 0.55, 0.74)),
        (c(0.94, 0.58, 0.62), c(0.66, 0.26, 0.50)),
        (c(0.72, 0.76, 0.82), c(0.36, 0.42, 0.50)),
        // тёмные
        (c(0.05, 0.05, 0.06), c(0.05, 0.05, 0.06)),
        (c(0.30, 0.31, 0.34), c(0.08, 0.08, 0.10)),
        (c(0.10, 0.14, 0.30), c(0.02, 0.03, 0.10)),
        (c(0.28, 0.12, 0.38), c(0.06, 0.02, 0.12)),
        (c(0.08, 0.28, 0.20), c(0.02, 0.07, 0.06)),
        (c(0.40, 0.08, 0.12), c(0.10, 0.02, 0.04)),
        (c(0.05, 0.25, 0.28), c(0.01, 0.07, 0.09)),
        (c(0.35, 0.22, 0.12), c(0.09, 0.05, 0.03)),
    ]

    private static func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

    /// Цвет россыпи эмодзи — тот же, что у профиля: у тёмных чуть светлее, у светлых чуть темнее (иначе сольётся с фоном)
    static func emojiTint(_ index: Int?, fallback: Color) -> Color {
        guard let p = pair(index) else { return fallback }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0
        UIColor(p.0).getRed(&r, green: &g, blue: &b, alpha: &a)
        UIColor(p.1).getRed(&r2, green: &g2, blue: &b2, alpha: &a)
        let (mr, mg, mb) = ((r + r2) / 2, (g + g2) / 2, (b + b2) / 2)
        let lum = 0.299 * mr + 0.587 * mg + 0.114 * mb
        if lum < 0.3 {
            let k: CGFloat = 0.2 + (0.3 - lum) * 0.3                  // чем темнее фон, тем заметнее подсветка
            return Color(red: mr + (1 - mr) * k, green: mg + (1 - mg) * k, blue: mb + (1 - mb) * k)
        }
        return Color(red: mr * 0.72, green: mg * 0.72, blue: mb * 0.72)
    }

    static func pair(_ index: Int?) -> (Color, Color)? {
        guard let index, colors.indices.contains(index) else { return nil }
        return colors[index]
    }
}

// MARK: - Фон вокруг аватарки: цвет + россыпь эмодзи

struct ProfileBackdrop: View {
    let color: Int?
    let emoji: String?
    var height: CGFloat = 330
    /// 1 — нижний край растворяется в фоне, 0 — ровная плашка (свёрнутая шапка)
    var fade: CGFloat = 1
    var showsEmoji = true
    @Environment(\.theme) private var theme

    /// Эмодзи кольцами вокруг аватарки (как в Telegram): радиус в долях ширины, угол, размер, поворот
    private static let spots: [(r: Double, a: Double, size: Double, rot: Double)] = {
        var list: [(Double, Double, Double, Double)] = []
        for i in 0..<7 { list.append((0.30, Double(i) / 7 * 360 + 12, i % 2 == 0 ? 24 : 19, Double(i * 37 % 50) - 25)) }
        for i in 0..<11 { list.append((0.50, Double(i) / 11 * 360 + 30, i % 2 == 0 ? 20 : 26, Double(i * 53 % 60) - 30)) }
        for i in 0..<14 { list.append((0.74, Double(i) / 14 * 360 + 8, i % 3 == 0 ? 22 : 17, Double(i * 29 % 40) - 20)) }
        return list
    }()

    var body: some View {
        let pair = ProfilePalette.pair(color)
        let top = pair?.0 ?? theme.accentColor
        let bottom = pair?.1 ?? theme.accentColor.opacity(0.6)
        let tint = ProfilePalette.emojiTint(color, fallback: theme.accentColor.opacity(0.6))
        let strength: Double = pair == nil ? (theme.dark ? 0.35 : 0.22) : 0.96
        ZStack {
            LinearGradient(colors: [top.opacity(strength), bottom.opacity(strength * 0.92)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // мягкий блик сверху
            RadialGradient(colors: [Color.white.opacity(pair == nil ? 0 : 0.22), .clear],
                           center: UnitPoint(x: 0.5, y: 0.34), startRadius: 0, endRadius: 220)
            if showsEmoji, let emoji, !emoji.isEmpty {
                GeometryReader { geo in
                    let cx = geo.size.width / 2, cy = geo.size.height * 0.40
                    ForEach(Array(Self.spots.enumerated()), id: \.offset) { _, s in
                        let rad = s.a * .pi / 180
                        Text(emoji)
                            .font(.system(size: s.size))
                            .opacity(0)
                            .overlay { tint.mask(Text(emoji).font(.system(size: s.size))) }     // эмодзи окрашен в цвет профиля
                            .rotationEffect(.degrees(s.rot))
                            .opacity(0.55)
                            .position(x: cx + cos(rad) * s.r * geo.size.width * 0.62,
                                      y: cy + sin(rad) * s.r * geo.size.width * 0.52)
                    }
                }
                // 32 эмодзи с масками — одним слоем: при прокрутке профиля шапка не пересобирает их по отдельности
                .drawingGroup()
            }
        }
        .frame(height: height)
        // нижний край плавно растворяется в фоне — без обрыва
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 1 - 0.38 * Double(fade)),
                                     .init(color: fade > 0.01 ? .clear : .black, location: 1)], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }
}

extension ProfilePalette {
    /// Цвет текста поверх шапки: белый, если у профиля есть цвет
    static func ink(_ color: Int?, fallback: Color) -> Color { pair(color) == nil ? fallback : .white }
    static func inkSecondary(_ color: Int?, fallback: Color) -> Color { pair(color) == nil ? fallback : Color.white.opacity(0.78) }
}

// MARK: - Экран «Изменить цвет профиля»

struct ProfileStyleScreen: View {
    @ObservedObject var store: ProfileStore
    let back: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @ObservedObject private var leaveGuard = LeaveGuard.shared
    @State private var color: Int?
    @State private var emoji: String?
    @State private var showEmoji = false
    @State private var saving = false
    @State private var errorText: String?
    @State private var loaded = false

    private var s: Strings { Strings(lang: lang) }
    private var name: String { store.profile?.name ?? "" }
    private var changed: Bool { color != store.profile?.styleColor || emoji != store.profile?.styleEmoji }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 0) {
                preview
                Divider().overlay(theme.stroke)
                swatches
                Divider().overlay(theme.stroke).padding(.leading, 16)
                Button { showEmoji = true } label: {
                    HStack {
                        Text(s.t("Фоновый эмодзи", "Background emoji")).font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(theme.text)
                        Spacer()
                        Text(emoji ?? "—").font(.system(size: 24))
                        Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .padding(.horizontal, 16).frame(height: 58).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .card(theme, radius: 22)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            Text(s.t("Цвет и эмодзи видят все, кто открывает ваш профиль.", "Everyone who opens your profile sees this color and emoji."))
                .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)

            Button {
                withAnimation(.easeOut(duration: 0.2)) { color = nil; emoji = nil }
            } label: {
                Text(s.t("Сбросить цвет профиля", "Reset profile color"))
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).frame(height: 54).card(theme, radius: 27)
            }
            .buttonStyle(PressStyle())

            if let errorText { Text(errorText).font(.system(size: 13)).foregroundStyle(theme.danger) }

            PrimaryButton(title: s.t("Применить стиль", "Apply style"), enabled: changed, loading: saving) { apply() }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 96)                 // кнопка «Применить» не прячется под нижней панелью вкладок
        .onAppear {
            guard !loaded else { return }
            loaded = true
            color = store.profile?.styleColor
            emoji = store.profile?.styleEmoji
        }
        .sheet(isPresented: $showEmoji) {
            BackdropEmojiPicker(selected: emoji) { picked in
                emoji = picked
                showEmoji = false
            }
            .environment(\.theme, theme).environment(\.lang, lang)
            .presentationDetents([.medium, .large])
            .presentationBackground(theme.sheet)
        }
        // предупреждение «вы не сохранили»: пока есть несохранённые изменения — помечаем экран «грязным»
        .onChange(of: changed) { _, v in leaveGuard.dirty = v }
        .onChange(of: leaveGuard.saveSignal) { _, _ in apply() }   // «Сохранить» в предупреждении
        .onDisappear { LeaveGuard.shared.dirty = false }
    }

    /// Высота превью — по содержимому (аватарка, имя, «в сети»), без пустой полосы до цветов
    private static let previewHeight: CGFloat = 250

    private var preview: some View {
        ZStack(alignment: .top) {
            ProfileBackdrop(color: color, emoji: emoji, height: Self.previewHeight)
            VStack(spacing: 6) {
                AvatarView(name: name, size: 118, avatarID: store.profile?.avatarID).clipShape(Circle())
                    .padding(.top, 28)
                Text(name.isEmpty ? s.you : name)
                    .font(.system(size: 26, weight: .bold)).foregroundStyle(ProfilePalette.ink(color, fallback: theme.text))
                Text(s.online).font(.system(size: 16)).foregroundStyle(ProfilePalette.inkSecondary(color, fallback: theme.textSecondary))
            }
        }
        .frame(height: Self.previewHeight, alignment: .top)
        .clipped()
    }

    private var swatches: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { col in
                        let index = row * 8 + col
                        let pair = ProfilePalette.colors[index]
                        Button {
                            Haptics.select()
                            withAnimation(.easeOut(duration: 0.2)) { color = index }
                        } label: {
                            Circle()
                                .fill(LinearGradient(stops: [.init(color: pair.0, location: 0.5), .init(color: pair.1, location: 0.5)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 34, height: 34)
                                .overlay {
                                    if color == index {
                                        Circle().stroke(Color.white, lineWidth: 2.5).padding(-4)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 16)
    }

    private func apply() {
        saving = true
        Task {
            defer { saving = false }
            var patch = ProfilePatch()
            if color == nil && emoji == nil {
                patch.resetStyle = true
            } else {
                patch.styleColor = color
                patch.styleEmoji = emoji
            }
            if let error = await store.update(patch) { errorText = s.api(error) } else { back() }
        }
    }
}

/// Выбор эмодзи для россыпи на фоне
struct BackdropEmojiPicker: View {
    let selected: String?
    let onPick: (String?) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(s.t("Фоновый эмодзи", "Background emoji")).font(.system(size: 18, weight: .bold)).foregroundStyle(theme.text)
                Spacer()
                Button(s.t("Без эмодзи", "None")) { onPick(nil) }.foregroundStyle(theme.accentColor)
            }
            .padding(16)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 6) {
                    ForEach(EmojiData.categories.flatMap(\.items), id: \.self) { e in
                        Button { onPick(e) } label: {
                            Text(e).font(.system(size: 28)).frame(height: 40)
                                .background(e == selected ? theme.accentColor.opacity(0.25) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }
}


/// Отступ сверху (статус-бар / «остров») — чтобы цвет профиля доходил до самого края экрана
private struct PageTopInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    /// Сколько прокручиваемая страница заходит под статус-бар (0 — обычная страница внутри безопасной зоны)
    var pageTopInset: CGFloat {
        get { self[PageTopInsetKey.self] }
        set { self[PageTopInsetKey.self] = newValue }
    }
}

enum TopInset {
    static var value: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first(where: \.isKeyWindow)?.safeAreaInsets.top ?? 59
    }
}

enum BottomInset {
    static var value: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first(where: \.isKeyWindow)?.safeAreaInsets.bottom ?? 34
    }
}

struct ScrollTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}


// MARK: - Сворачивание шапки при прокрутке (для страниц внутри ScrollView)

/// Положение прокрутки страницы. Два независимых источника — SwiftUI (GeometryReader в именованном пространстве
/// «pageScroll») и UIKit (contentOffset): если один не сработает, работает другой.
/// 0 — верх страницы, > 0 — прокрутили вниз, < 0 — оттянули вниз за край.
final class PageScrollTracker: ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    var onChange: ((CGFloat) -> Void)?
    private var marker: CGFloat = 0
    private var probe: CGFloat = 0

    func setMarker(_ value: CGFloat) { marker = value; merge() }
    func setProbe(_ value: CGFloat) { probe = value; merge() }

    private func merge() {
        let v = abs(marker) >= abs(probe) ? marker : probe
        guard abs(v - offset) >= 1 else { return }
        offset = v
        onChange?(v)
    }
}

/// Невидимая отметка в самом верху страницы: следит за прокруткой и (по желанию) не даёт оттянуть страницу вниз
struct PageScrollMarker: View {
    @EnvironmentObject private var tracker: PageScrollTracker
    @Environment(\.pageTopInset) private var topInset
    var lockTop = false
    var reportPull = false

    var body: some View {
        GeometryReader { g in
            Color.clear
                .onChange(of: g.frame(in: .named("pageScroll")).minY) { _, y in tracker.setMarker(-(y - topInset)) }
        }
        .frame(height: 0)
        .background {
            ScrollOffsetProbe(lockTop: lockTop, reportPull: reportPull) { tracker.setProbe($0) }
                .frame(width: 1, height: 1)
        }
    }
}

/// Сжимает и гасит вид по мере прокрутки: 0 — верх страницы, 1 — прокрутили на `distance`
struct CollapseFX: ViewModifier {
    var endScale: CGFloat = 1
    var fadeFrom: CGFloat = 0
    var fadeTo: CGFloat = 1
    var distance: CGFloat = 150
    @EnvironmentObject private var tracker: PageScrollTracker

    func body(content: Content) -> some View {
        let p = max(0, min(1, tracker.offset / distance))
        let fade = max(0, min(1, (p - fadeFrom) / max(0.01, fadeTo - fadeFrom)))
        return content
            .scaleEffect(1 - (1 - endScale) * p, anchor: .top)
            .opacity(1 - Double(fade))
    }
}

extension View {
    func collapsing(endScale: CGFloat = 1, fadeFrom: CGFloat = 0, fadeTo: CGFloat = 1) -> some View {
        modifier(CollapseFX(endScale: endScale, fadeFrom: fadeFrom, fadeTo: fadeTo))
    }
}

/// Закреплённая плашка с ником: остаётся наверху видимой области, пока страница прокручивается
struct StickyProfileBar: View {
    let name: String
    let subtitle: String
    let color: Int?
    var height: CGFloat = 54
    var startAt: CGFloat = 92
    @Environment(\.theme) private var theme
    @Environment(\.pageTopInset) private var topInset
    @ObservedObject var tracker: PageScrollTracker

    var body: some View {
        let offset = tracker.offset
        let appear = Double(max(0, min(1, (offset - startAt) / 30)))
        ZStack {
            ProfileBarBackground(color: color, height: height + topInset)
            VStack(spacing: 1) {
                Text(name).font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ProfilePalette.ink(color, fallback: theme.text)).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12))
                        .foregroundStyle(ProfilePalette.inkSecondary(color, fallback: theme.textSecondary)).lineLimit(1)
                }
            }
            .padding(.horizontal, 60)
            .padding(.top, topInset)
        }
        .frame(height: height + topInset)
        .opacity(appear)
        .contentShape(Rectangle())
        .onTapGesture {}                              // кнопки под размытием не нажимаются
        .allowsHitTesting(appear > 0.3)
        .offset(y: max(0, offset) - topInset)         // плашка прижата к самому верху экрана, под статус-баром
    }
}


/// Фон закреплённой плашки: за ником, «Изм.» и QR ничего не видно (сильное размытие + затемнение),
/// и только у самого нижнего края всё плавно сходит на нет — без видимых стыков
struct ProfileBarBackground: View {
    let color: Int?
    let height: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial)
            Rectangle().fill(.ultraThickMaterial)
        }
        .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                     .init(color: .black, location: 0.72),
                                     .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}
