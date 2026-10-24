import SwiftUI
import UIKit

// MARK: - Положение прокрутки внешнего ScrollView (для «потяни вниз — открыть аватарку»)

struct ScrollOffsetProbe: UIViewRepresentable {
    /// true — выше верха прокрутить нельзя (у человека нет аватарки: «там стоит»)
    var lockTop = false
    /// с lockTop: страница не оттягивается, но величина натяжения всё равно сообщается (отрицательным числом)
    var reportPull = false
    /// 0 — верх; отрицательное значение — оттянули вниз за край
    var onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        view.lockTop = lockTop
        view.reportPull = reportPull
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onChange = onChange
        uiView.lockTop = lockTop
        uiView.reportPull = reportPull
    }

    final class ProbeView: UIView {
        var onChange: ((CGFloat) -> Void)?
        var lockTop = false
        var reportPull = false
        private var pullAcc: CGFloat = 0
        private var resetting = false           // защита от рекурсии: сброс offset сам вызывает наблюдатель
        private var lastPull: CFTimeInterval = 0
        private var observation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            observation = nil
            guard window != nil else { return }
            var node: UIView? = superview
            while let current = node, !(current is UIScrollView) { node = current.superview }
            guard let scroll = node as? UIScrollView else { return }
            observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                guard let self, !self.resetting else { return }
                let y = scroll.contentOffset.y + scroll.adjustedContentInset.top
                if self.lockTop, y < 0 {
                    // страницу не оттягиваем, но накапливаем, насколько палец потянул вниз
                    let now = CACurrentMediaTime()
                    if now - self.lastPull > 0.3 { self.pullAcc = 0 }
                    self.lastPull = now
                    if self.reportPull {
                        self.pullAcc += -y * 1.5
                        self.onChange?(-self.pullAcc)
                    }
                    self.resetting = true
                    scroll.contentOffset.y = -scroll.adjustedContentInset.top      // не даём оттянуть вниз
                    self.resetting = false
                    if !self.reportPull { self.onChange?(0) }
                    return
                }
                if self.lockTop, y == 0, self.reportPull, scroll.isTracking, CACurrentMediaTime() - self.lastPull < 0.3 { return }   // отклик на наш же сброс
                self.pullAcc = 0
                self.onChange?(y)
            }
        }
    }
}

// MARK: - Системное окно «Поделиться»

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ShareItems: Identifiable {
    let id = UUID()
    let items: [Any]
}

// MARK: - Карточка с данными (как в Telegram: значок-цвет сверху, маленькая подпись снизу)

struct ProfileInfoRow: Identifiable {
    /// Что умеет строка при нажатии (как в Telegram: всплывает меню «скопировать» и т. д.)
    enum Kind: Equatable {
        case text
        case username(link: String?)
        case phone
        case link
    }

    /// Стабильный идентификатор: иначе при каждой перерисовке (скролл, таймеры) строка пересоздаётся и меню закрывается
    var id: String { label + "\u{1F}" + value }
    let label: String
    let value: String
    var accent = false
    var kind: Kind = .text
}

struct ProfileInfoCard: View {
    let rows: [ProfileInfoRow]
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var copied: String?

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rowView(row)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .overlay(alignment: .bottom) {
                        if index < rows.count - 1 {
                            Rectangle().fill(theme.stroke).frame(height: 0.5).padding(.leading, 16)
                        }
                    }
            }
        }
        .card(theme, radius: 18)
        .overlay(alignment: .bottom) {
            if let copied {
                Text(copied)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
                    .padding(.horizontal, 16).frame(height: 36)
                    .glassCapsule()
                    .padding(.bottom, -18)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: copied)
    }

    @ViewBuilder
    private func rowView(_ row: ProfileInfoRow) -> some View {
        let content = VStack(alignment: .leading, spacing: 3) {
            Group {
                if row.kind == .text { LinkText(text: row.value, tint: theme.accentColor) } else { Text(row.value) }
            }
                .font(.system(size: 17))
                .foregroundStyle(row.accent ? theme.accentColor : theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Text(row.label.lowercased())
                .font(.system(size: 13))
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())

        switch row.kind {
        case .text:
            content.textSelection(.enabled)
        case .username(let link):
            Menu {
                Button { copy(row.value, toast: s.t("Имя пользователя скопировано", "Username copied")) } label: {
                    Label(s.t("Скопировать имя пользователя", "Copy username"), systemImage: "doc.on.doc")
                }
                if let link {
                    Button { copy(link, toast: s.t("Ссылка скопирована", "Link copied")) } label: {
                        Label(s.t("Скопировать ссылку", "Copy link"), systemImage: "link")
                    }
                    if let url = URL(string: link) {
                        ShareLink(item: url) { Label(s.t("Поделиться", "Share"), systemImage: "square.and.arrow.up") }
                    }
                }
            } label: { content }
            .buttonStyle(.plain)
        case .phone:
            Menu {
                Button { copy(row.value, toast: s.t("Номер скопирован", "Number copied")) } label: {
                    Label(s.t("Скопировать номер", "Copy number"), systemImage: "doc.on.doc")
                }
            } label: { content }
            .buttonStyle(.plain)
        case .link:
            Menu {
                Button { copy(row.value, toast: s.t("Ссылка скопирована", "Link copied")) } label: {
                    Label(s.t("Скопировать ссылку", "Copy link"), systemImage: "link")
                }
                if let url = URL(string: row.value) {
                    ShareLink(item: url) { Label(s.t("Поделиться", "Share"), systemImage: "square.and.arrow.up") }
                }
            } label: { content }
            .buttonStyle(.plain)
        }
    }

    private func copy(_ text: String, toast: String) {
        UIPasteboard.general.string = text
        Haptics.notify(.success)
        copied = toast
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if copied == toast { copied = nil }
        }
    }
}

// MARK: - Переключатель вкладок-«таблетка»

struct ProfileTabs: View {
    let titles: [String]
    @Binding var selection: Int
    /// Какие из titles показать в этой строке (индексы общего списка); по умолчанию все
    var only: [Int]? = nil
    @Environment(\.theme) private var theme
    @Namespace private var ns

    private var shown: [(offset: Int, element: String)] {
        let all = Array(titles.enumerated())
        guard let only else { return all }
        return all.filter { only.contains($0.offset) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(shown, id: \.offset) { index, title in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = index }
                } label: {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.65)
                        .foregroundStyle(selection == index ? theme.text : theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background {
                            if selection == index {
                                Capsule().fill(theme.dark ? Color.white.opacity(0.12) : Color.white)
                                    .shadow(color: .black.opacity(theme.dark ? 0 : 0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "tab", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(theme.surface, in: Capsule())
        .overlay(Capsule().stroke(theme.stroke, lineWidth: 1))
    }
}

// MARK: - Раскрытая шапка: фото на всю ширину, полоски сверху, имя внизу

struct ExpandedAvatarHeader: View {
    let name: String
    let status: String
    let photos: [AvatarPhoto]
    @Binding var page: Int
    let onOpen: () -> Void

    var body: some View {
        Color.clear
            .aspectRatio(0.94, contentMode: .fit)
            .overlay {
                if photos.indices.contains(page) {
                    RemoteImage(id: photos[page].mediaID)
                        .id(photos[page].id)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, Color.black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if !status.isEmpty {
                        Text(status).font(.system(size: 15)).foregroundStyle(Color.white.opacity(0.8)).lineLimit(1)
                    }
                }
                .shadow(color: .black.opacity(0.35), radius: 4)
                .padding(.horizontal, 18).padding(.bottom, 16)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                if photos.count > 1 {
                    HStack(spacing: 3) {
                        ForEach(photos.indices, id: \.self) { i in
                            Capsule().fill(Color.white.opacity(i == page ? 0.95 : 0.35)).frame(height: 3)
                        }
                    }
                    .padding(.horizontal, 12).padding(.top, 10)
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                // нажатие слева / справа листает фото, посередине — открывает просмотр
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { step(-1) }
                    Color.clear.contentShape(Rectangle()).onTapGesture(perform: onOpen)
                    Color.clear.contentShape(Rectangle()).onTapGesture { step(1) }
                }
            }
            .clipped()
            .simultaneousGesture(
                // свайп по фото листает аватарки, как в Telegram
                DragGesture(minimumDistance: 24).onEnded { v in
                    guard abs(v.translation.width) > abs(v.translation.height) * 1.4, abs(v.translation.width) > 40 else { return }
                    step(v.translation.width < 0 ? 1 : -1)
                }
            )
    }

    private func step(_ delta: Int) {
        guard photos.count > 1 else { onOpen(); return }
        let next = max(0, min(photos.count - 1, page + delta))
        guard next != page else { return }
        Haptics.select()
        withAnimation(.easeInOut(duration: 0.26)) { page = next }
    }
}

// MARK: - Выбор эмодзи-статуса

struct EmojiStatusSheet: View {
    let current: String?
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    private let emojis = AnimatedEmoji.all            // в статус можно поставить только анимированные эмодзи

    var body: some View {
        VStack(spacing: 14) {
            Text(lang == .ru ? "Эмодзи-статус" : "Emoji status")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.text)
                .padding(.top, 20)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 8), spacing: 6) {
                    ForEach(emojis, id: \.self) { e in
                        Button {
                            Haptics.select()
                            onPick(e); dismiss()
                        } label: {
                            LottieEmojiView(emoji: e, size: 34)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(e == current ? theme.accentColor.opacity(0.22) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }
            if current != nil {
                Button(lang == .ru ? "Убрать статус" : "Remove status") { onPick(""); dismiss() }
                    .font(.system(size: 16)).foregroundStyle(theme.danger).padding(.bottom, 14)
            }
        }
    }
}

// MARK: - Порядок фото

struct PhotoReorderSheet: View {
    @State var photos: [AvatarPhoto]
    let onDone: ([AvatarPhoto]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(photos) { photo in
                    HStack(spacing: 12) {
                        RemoteImage(id: photo.mediaID)
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Text(s.photoDateShort(photo.createdAt))
                            .font(.system(size: 16)).foregroundStyle(theme.text)
                        if photo.id == photos.first?.id {
                            Spacer()
                            Text(s.t("основное", "main")).font(.system(size: 13)).foregroundStyle(theme.accentColor)
                        }
                    }
                    .listRowBackground(theme.surface)
                }
                .onMove { photos.move(fromOffsets: $0, toOffset: $1) }
            }
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .navigationTitle(s.t("Порядок фото", "Photo order"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(s.t("Готово", "Done")) { onDone(photos); dismiss() }.fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(s.cancel) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Фото, которое вырастает из кружка аватарки

/// expand: 0 — кружок, 1 — шапка на всю ширину, 2 — весь экран. Значение анимируется пружиной,
/// поэтому форма, размер и скругление плавно перетекают друг в друга (как в Telegram).
struct AvatarStage: View, Animatable {
    var expand: CGFloat
    let circleTop: CGFloat
    let screen: CGSize
    let headerHeight: CGFloat
    let topInset: CGFloat
    let photos: [AvatarPhoto]
    let page: Int
    let forward: Bool
    let name: String
    let status: String
    let onStep: (Int) -> Void
    let onCenter: () -> Void
    let onVertical: (CGFloat) -> Void
    var onClose: () -> Void = {}
    var track: Track? = nil
    var queue: [Track] = []
    var player: AudioPlayer? = nil
    var onMusic: () -> Void = {}

    var animatableData: CGFloat {
        get { expand }
        set { expand = newValue }
    }

    /// Высота строки с песней (MusicBar) и размытой полоски под ней: сама строка + мягкий переход сверху
    private static let musicBarHeight: CGFloat = 38
    private static let musicStripHeight: CGFloat = 70

    var body: some View {
        let e: CGFloat = min(2, max(0, expand))
        let t1: CGFloat = min(1, e)
        let t2: CGFloat = max(0, e - 1)
        let w: CGFloat = 112 + (screen.width - 112) * t1
        let h1: CGFloat = 112 + (headerHeight - 112) * t1
        let h: CGFloat = h1                                           // на последней ступени фото не растёт, а съезжает в центр
        let x: CGFloat = (screen.width - w) / 2
        let y: CGFloat = circleTop * (1 - t1) + (screen.height - headerHeight) / 2 * t2
        let r: CGFloat = 56 * (1 - t1)
        let ui: Double = Double(max(0, (t1 - 0.6) / 0.4))
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(Double(t2))                       // чёрный фон вокруг, как предпросмотр фото
            card(w: w, h: h, r: r, ui: ui, t2: t2)
                .offset(x: x, y: y)
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        .opacity(e > 0.01 ? 1 : 0)
    }

    private func card(w: CGFloat, h: CGFloat, r: CGFloat, ui: Double, t2: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        return ZStack {
            Color.black
            photoLayer
            chrome(w: w, h: h, ui: ui, t2: t2)
        }
        .frame(width: w, height: h)
        .clipShape(shape)
    }

    @ViewBuilder
    private var photoLayer: some View {
        if photos.indices.contains(page) {
            RemoteImage(id: photos[page].mediaID)
                .id(photos[page].id)
                .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading),
                                        removal: .move(edge: forward ? .leading : .trailing)))
        }
    }

    private func chrome(w: CGFloat, h: CGFloat, ui: Double, t2: CGFloat) -> some View {
        ZStack {
            // как в Telegram: нижняя часть фото плавно размывается под ником и номером
            if photos.indices.contains(page) {
                RemoteImage(id: photos[page].mediaID)
                    .frame(width: w + 160, height: h + 160)
                    .clipped()
                    .blur(radius: 20)
                    .frame(width: w, height: h)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0.7),
                                                 .init(color: .black, location: 0.88)],
                                         startPoint: .top, endPoint: .bottom))
                    .opacity(1 - Double(t2))
                    .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, Color.black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
                    .padding(.bottom, track != nil ? Self.musicBarHeight : 0)      // под песней не затемняем — там своё размытие
                    .opacity(1 - Double(t2))
            }
            // как в Telegram: строка с песней лежит не на чёрном, а на сильно размытом фото.
            // Размывается только узкая нижняя полоска фото, а не всё фото — раскрытие аватарки не тяжелеет
            if track != nil, photos.indices.contains(page) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    RemoteImage(id: photos[page].mediaID)
                        .frame(width: w, height: h)
                        .clipped()
                        .frame(width: w, height: Self.musicStripHeight, alignment: .bottom)   // та же картинка, только низ
                        .clipped()
                        .blur(radius: 36, opaque: true)
                        .overlay(Color.black.opacity(0.2))                // белый текст читается на любом фото
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                                     .init(color: .black, location: 0.45)],
                                             startPoint: .top, endPoint: .bottom))
                }
                .frame(width: w, height: h)
                .opacity(1 - Double(t2))
                .allowsHitTesting(false)
            }
            zones                                  // под содержимым: нажатия на полосу с песней и на ник доходят до них
            VStack(alignment: .leading, spacing: 0) {
                bars(t2: t2)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 28, weight: .bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                    if !status.isEmpty {
                        Text(status).font(.system(size: 15)).foregroundStyle(Color.white.opacity(0.8)).lineLimit(1)
                    }
                }
                .shadow(color: .black.opacity(0.35), radius: 4)
                .padding(.horizontal, 18)
                .padding(.bottom, track != nil ? 10 : 16)
                .opacity(1 - Double(t2))
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.5) {
                    // долгое нажатие на номер и тег копирует их
                    UIPasteboard.general.string = status
                    Haptics.impact(.medium)
                }
                if let track, let player {
                    MusicBar(track: track, queue: queue, player: player, onOpen: onMusic)
                        .opacity(1 - Double(t2))
                }
            }
            .frame(width: w, height: h, alignment: .topLeading)
            // в последнем положении — кнопка «выйти» в углу фото
            if t2 > 0.5 {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Color.black.opacity(0.45), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.top, 22).padding(.trailing, 10)
                .frame(width: w, height: h)
                .opacity(Double(t2))
            }
        }
        .frame(width: w, height: h)
        .opacity(ui)
        .allowsHitTesting(ui > 0.5)
    }

    @ViewBuilder
    private func bars(t2: CGFloat) -> some View {
        if photos.count > 1 {
            HStack(spacing: 3) {
                ForEach(photos.indices, id: \.self) { i in
                    Capsule().fill(Color.white.opacity(i == page ? 0.95 : 0.35)).frame(height: 3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, (topInset - 4) * (1 - t2) + 8 * t2)      // в последнем положении фото не под статус-баром: полоски у самого верха фото
            .allowsHitTesting(false)
        }
    }

    /// слева / справа — соседнее фото, посередине — на весь экран (и обратно); свайпы тоже листают
    private var zones: some View {
        HStack(spacing: 0) {
            Color.clear.contentShape(Rectangle()).onTapGesture { onStep(-1) }
            Color.clear.contentShape(Rectangle()).onTapGesture { onCenter() }
            Color.clear.contentShape(Rectangle()).onTapGesture { onStep(1) }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20).onEnded { v in
                let dx = v.translation.width, dy = v.translation.height
                if abs(dx) > abs(dy) * 1.2, abs(dx) > 40 { onStep(dx < 0 ? 1 : -1) } else if abs(dy) > abs(dx) { onVertical(dy) }
            }
        )
    }
}

/// Слой в координатах всего экрана (от самого верха, под статус-баром и островом) — где бы он ни лежал в иерархии.
/// Сам в раскладке ничего не раздувает: это обычный GeometryReader.
struct ScreenSpace<Content: View>: View {
    /// размер экрана и экранные координаты верха-слева этого слоя в раскладке
    @ViewBuilder let content: (CGSize, CGPoint) -> Content

    var body: some View {
        GeometryReader { g in
            let origin = g.frame(in: .global)
            let screen = UIScreen.main.bounds.size
            content(screen, origin.origin)
                .frame(width: screen.width, height: screen.height, alignment: .topLeading)
                .offset(x: -origin.minX, y: -origin.minY)
        }
    }
}

// MARK: - Эмодзи-статус рядом с ником: всегда анимирован (у всех, кто смотрит профиль)

struct StatusEmoji: View {
    let emoji: String
    let size: CGFloat
    /// Свой профиль: нажатие открывает выбор статуса. Чужой — нажатие ничего не делает
    var onTap: (() -> Void)? = nil

    private var animated: String? {
        AnimatedEmoji.all.first { $0 == emoji || LottieEmojiStore.code($0, keepVariation: false) == LottieEmojiStore.code(emoji, keepVariation: false) }
    }

    var body: some View {
        Group {
            if let animated {
                // играет по кругу, пока профиль на экране; мелкий размер — готовыми кадрами, почти без нагрузки
                LottieEmojiView(emoji: animated, size: size, loop: true)
            } else {
                Text(emoji).font(.system(size: size * 0.8))
            }
        }
        .contentShape(Rectangle().inset(by: -8))
        .onTapGesture {
            guard let onTap else { return }
            Haptics.impact(.light)
            onTap()
        }
        .allowsHitTesting(onTap != nil)
    }
}

/// Ник и эмодзи-статус: статус всегда анимирован; на своём профиле по нажатию — смена статуса
struct NameWithStatus: View {
    let name: String
    let emoji: String?
    let fontSize: CGFloat
    /// Нажатие на эмодзи-статус (свой профиль — смена статуса)
    var onEmojiTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
            if let emoji, !emoji.isEmpty { StatusEmoji(emoji: emoji, size: fontSize * 1.15, onTap: onEmojiTap) }
        }
    }
}
