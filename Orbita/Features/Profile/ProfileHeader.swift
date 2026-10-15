import SwiftUI
import UIKit

// MARK: - Положение прокрутки внешнего ScrollView (для «потяни вниз — открыть аватарку»)

struct ScrollOffsetProbe: UIViewRepresentable {
    /// true — выше верха прокрутить нельзя (у человека нет аватарки: «там стоит»)
    var lockTop = false
    /// 0 — верх; отрицательное значение — оттянули вниз за край
    var onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        view.lockTop = lockTop
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onChange = onChange
        uiView.lockTop = lockTop
    }

    final class ProbeView: UIView {
        var onChange: ((CGFloat) -> Void)?
        var lockTop = false
        private var observation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            observation = nil
            guard window != nil else { return }
            var node: UIView? = superview
            while let current = node, !(current is UIScrollView) { node = current.superview }
            guard let scroll = node as? UIScrollView else { return }
            observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                let y = scroll.contentOffset.y + scroll.adjustedContentInset.top
                if self?.lockTop == true, y < 0 {
                    scroll.contentOffset.y = -scroll.adjustedContentInset.top      // не даём оттянуть вниз
                    self?.onChange?(0)
                    return
                }
                self?.onChange?(y)
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

    private let emojis = ["😀","😎","🥳","🤩","😴","🤔","😍","🥰","😇","🤓","😤","🤯","😭","🥶","🔥","✨","🚀","🌙","⭐️","☀️",
                          "🌈","❤️","💜","💙","💚","🖤","🎧","🎮","📚","💻","☕️","🍕","🏖","🏔","✈️","🚗","🎬","🎸","⚽️","🏀",
                          "🐱","🐶","🦊","🐼","🦄","🌸","🍀","💎","👑","🎯"]

    var body: some View {
        VStack(spacing: 14) {
            Text(lang == .ru ? "Эмодзи-статус" : "Emoji status")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.text)
                .padding(.top, 20)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(emojis, id: \.self) { e in
                        Button {
                            Haptics.select()
                            onPick(e); dismiss()
                        } label: {
                            Text(e).font(.system(size: 30))
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(e == current ? theme.accentColor.opacity(0.22) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
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

    var animatableData: CGFloat {
        get { expand }
        set { expand = newValue }
    }

    var body: some View {
        let e: CGFloat = min(2, max(0, expand))
        let t1: CGFloat = min(1, e)
        let t2: CGFloat = max(0, e - 1)
        let w: CGFloat = 112 + (screen.width - 112) * t1
        let h1: CGFloat = 112 + (headerHeight - 112) * t1
        let h: CGFloat = h1 + (screen.height - headerHeight) * t2
        let x: CGFloat = (screen.width - w) / 2
        let y: CGFloat = circleTop * (1 - t1)
        let r: CGFloat = 56 * (1 - t1)
        let ui: Double = Double(max(0, (t1 - 0.6) / 0.4))
        return ZStack(alignment: .topLeading) {
            Color.clear
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
            photoLayer(fit: AvatarCollapse.smooth(t2))
            chrome(w: w, h: h, ui: ui, t2: t2)
        }
        .frame(width: w, height: h)
        .clipShape(shape)
    }

    /// fit: 0 — фото заполняет карточку (кружок, шапка), 1 — целиком по ширине экрана в своих пропорциях (как в просмотре)
    @ViewBuilder
    private func photoLayer(fit: CGFloat) -> some View {
        if photos.indices.contains(page) {
            let id: String = photos[page].mediaID
            let filled: Double = Double(1 - AvatarCollapse.smooth((fit - 0.5) / 0.5))
            let fitted: Double = Double(AvatarCollapse.smooth(fit / 0.6))
            ZStack {
                RemoteImage(id: id).opacity(filled)
                RemoteImage(id: id, fill: false, backdrop: false).opacity(fitted)
            }
            .id(photos[page].id)
            .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading),
                                    removal: .move(edge: forward ? .leading : .trailing)))
        }
    }

    private func chrome(w: CGFloat, h: CGFloat, ui: Double, t2: CGFloat) -> some View {
        ZStack {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, Color.black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 170)
            }
            VStack(alignment: .leading, spacing: 0) {
                bars
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 28, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                    if !status.isEmpty {
                        Text(status).font(.system(size: 15)).foregroundStyle(Color.white.opacity(0.8)).lineLimit(1)
                    }
                }
                .shadow(color: .black.opacity(0.35), radius: 4)
                .padding(.horizontal, 18)
                .padding(.bottom, 16 + 96 * t2)
                .allowsHitTesting(false)
            }
            .frame(width: w, height: h, alignment: .topLeading)
            zones
        }
        .frame(width: w, height: h)
        .opacity(ui)
        .allowsHitTesting(ui > 0.5)
    }

    @ViewBuilder
    private var bars: some View {
        if photos.count > 1 {
            HStack(spacing: 3) {
                ForEach(photos.indices, id: \.self) { i in
                    Capsule().fill(Color.white.opacity(i == page ? 0.95 : 0.35)).frame(height: 3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, topInset + 58)
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

// MARK: - Сворачивание аватарки в островок (как в Telegram)

/// Вся геометрия «аватарка → капля → островок» в экранных координатах. Считается только от прокрутки,
/// поэтому фото и капля всегда совпадают: их рисуют по одним и тем же числам.
///
/// Ход по `c` (0 — шапка раскрыта, 1 — свёрнута):
/// - аватарка едет со страницей и уменьшается, у островка сверху вырастает маленькая капля;
/// - аватарка подъезжает под островок и «повисает» на нём, капля тянется к её верху и срастается;
/// - с места срастания фото чернеет сверху вниз; полностью чёрное — фото убирается (под ним уже чёрный круг);
/// - чёрный круг чуть набухает, затем сжимается и втекает в островок.
struct AvatarCollapse {
    /// островок (чуть меньше настоящего, чтобы края не выглядывали): центр и размер
    static let islandCY: CGFloat = 29.5
    static let islandSize = CGSize(width: 118, height: 30)
    static var islandBottom: CGFloat { islandCY + islandSize.height / 2 }

    static let travel: CGFloat = 150          // столько прокрутки на всё сворачивание
    static let size: CGFloat = 112
    static let lift: CGFloat = 34             // аватарка едет чуть быстрее страницы (34·c²)
    static let blackAt: CGFloat = 0.68        // к этому моменту фото полностью чёрное
    static let goneAt: CGFloat = 0.98         // капля целиком в островке

    let c: CGFloat
    let center: CGPoint
    let diameter: CGFloat
    /// 0 — без затемнения, 1 — фото полностью чёрное
    var dark: CGFloat { 0.5 * touch + 0.5 * sweep }
    /// верх кружка темнеет, пока к нему тянется капля (0…1)
    let touch: CGFloat
    /// затем тёмный фронт ползёт сверху вниз (0…1)
    let sweep: CGFloat
    /// фронт затемнения в долях высоты кружка: выше `front` — чёрное, ниже `front + band` — фото
    var front: CGFloat { -Self.band + Self.band * touch + sweep }
    static let band: CGFloat = 0.5
    let photo: Double
    let blur: CGFloat
    let opacity: Double
    /// капля под островком и перемычка до верха аватарки
    let drop: CGFloat
    let neckTip: CGFloat
    let neckWidth: CGFloat

    var top: CGFloat { center.y - diameter / 2 }

    /// restTop — верх кружка на экране, когда страница не прокручена; pull — насколько оттянули вниз (0…80)
    init(raw: CGFloat, restTop: CGFloat, screenWidth: CGFloat, pull: CGFloat) {
        let c = Self.clamp(raw / Self.travel)
        self.c = c
        let ib = Self.islandBottom
        let grow: CGFloat = 1 + 0.32 * min(1, pull / 62)          // тянем вниз — кружок растёт вместе с пальцем

        // верх кружка: со страницей, пока не упрётся под островок (плавно, без излома)
        let pageTop: CGFloat = restTop - raw - Self.lift * c * c
        let hangTop: CGFloat = ib - 2
        let top: CGFloat = Self.smoothMax(pageTop, hangTop, k: 24)

        // размер: к моменту, когда стал чёрным, — 58 % от исходного; потом чуть набухает и втягивается
        let shrunk: CGFloat = Self.size * grow * (1 - 0.42 * Self.smooth(c / Self.blackAt))
        let s: CGFloat = Self.clamp((c - Self.blackAt) / (Self.goneAt - Self.blackAt))
        let swell: CGFloat = shrunk * (1 + 0.1 * Self.smooth(s / 0.3))
        let d: CGFloat = swell + (8 - swell) * Self.smooth((s - 0.3) / 0.7)
        let hangCY: CGFloat = top + d / 2
        let cy: CGFloat = hangCY + (Self.islandCY + 2 - hangCY) * Self.smooth((s - 0.05) / 0.95)
        center = CGPoint(x: screenWidth / 2, y: cy)
        diameter = d

        // чернеет от места срастания: сначала верх (пока капля тянется к нему), потом фронт ползёт вниз
        let gap: CGFloat = top - ib
        touch = Self.smooth((50 - gap) / 32)
        let hangC: CGFloat = Self.progress(whenTopReaches: ib + 10, restTop: restTop)
        sweep = Self.smooth((c - hangC) / max(0.05, Self.blackAt - 0.02 - hangC))
        photo = Double(1 - Self.smooth((c - (Self.blackAt - 0.02)) / 0.02))
        blur = 3 * Self.smooth((c - 0.1) / 0.6)                       // слабо: фото узнаётся почти до конца
        opacity = Double(1 - Self.smooth((c - Self.goneAt) / (1 - Self.goneAt)))

        // капля: маленькая, появляется рано; когда аватарка близко — тянется к её верху и срастается;
        // в конце втягивается в островок вместе с аватаркой
        let drop: CGFloat = 26 * Self.smooth((c - 0.04) / 0.3) * (1 - Self.smooth(s))
        self.drop = drop
        let join: CGFloat = Self.smooth((36 - gap) / 28)
        neckTip = (ib + 0.55 * drop) + (top + 0.2 * d - (ib + 0.55 * drop)) * join
        neckWidth = 0.75 * drop + (0.62 * d - 0.75 * drop) * join
    }

    /// при каком c верх аватарки (если ехать со страницей) окажется на высоте y
    static func progress(whenTopReaches y: CGFloat, restTop: CGFloat) -> CGFloat {
        // restTop − travel·c − lift·c² = y
        let k: CGFloat = restTop - y
        guard k > 0 else { return 0 }
        let disc: CGFloat = travel * travel + 4 * lift * k
        return clamp((-travel + disc.squareRoot()) / (2 * lift))
    }

    static func clamp(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }

    static func smooth(_ x: CGFloat) -> CGFloat {
        let t = clamp(x)
        return t * t * (3 - 2 * t)
    }

    /// максимум со скруглённым «углом» шириной k; дальше k от угла совпадает с обычным max
    static func smoothMax(_ a: CGFloat, _ b: CGFloat, k: CGFloat) -> CGFloat {
        let h: CGFloat = max(k - abs(a - b), 0) / k
        return max(a, b) + h * h * k / 4
    }
}

/// Капля островка: островок, капля под ним, перемычка и чёрный круг под фото — склеены как жидкость
/// (blur + alphaThreshold). Фото рисуется поверх, по той же геометрии.
struct IslandBlob: View {
    let g: AvatarCollapse
    let screen: CGSize

    var body: some View {
        Canvas { ctx, size in
            let midX: CGFloat = size.width / 2
            let island = CGRect(x: midX - AvatarCollapse.islandSize.width / 2,
                                y: AvatarCollapse.islandCY - AvatarCollapse.islandSize.height / 2,
                                width: AvatarCollapse.islandSize.width, height: AvatarCollapse.islandSize.height)
            let ib: CGFloat = AvatarCollapse.islandBottom
            let dropRect = CGRect(x: midX - g.drop / 2, y: ib + 0.05 * g.drop - g.drop / 2,
                                  width: g.drop, height: g.drop)
            let neckH: CGFloat = max(0, g.neckTip - AvatarCollapse.islandCY)
            let neck = CGRect(x: midX - g.neckWidth / 2, y: AvatarCollapse.islandCY,
                              width: g.neckWidth, height: neckH)
            // под фото: на 2 pt меньше, чтобы чёрный край не выглядывал из-под ещё светлого низа
            let inset: CGFloat = min(2, g.diameter / 4)
            let under = CGRect(x: g.center.x - g.diameter / 2 + inset, y: g.center.y - g.diameter / 2 + inset,
                              width: g.diameter - 2 * inset, height: g.diameter - 2 * inset)
            ctx.addFilter(.alphaThreshold(min: 0.5, color: .black))
            ctx.addFilter(.blur(radius: 8))
            ctx.drawLayer { layer in
                layer.fill(Path(roundedRect: island, cornerRadius: island.height / 2), with: .color(.black))
                if g.drop > 0.5 {
                    layer.fill(Path(ellipseIn: dropRect), with: .color(.black))
                }
                if g.neckWidth > 0.5, neckH > 0 {
                    layer.fill(Path(roundedRect: neck, cornerRadius: g.neckWidth / 2), with: .color(.black))
                }
                layer.fill(Path(ellipseIn: under), with: .color(.black))
            }
        }
        .frame(width: screen.width, height: screen.height)
        .allowsHitTesting(false)
    }
}

/// Слой «аватарка + капля островка» на весь экран. Капля снизу, фото поверх неё — по одной геометрии,
/// поэтому полупрозрачной капли поверх живого фото не бывает: фото всегда непрозрачное, а чёрное — это его затемнение.
struct CollapsingAvatarLayer: View {
    let raw: CGFloat
    let restTop: CGFloat
    let screen: CGSize
    let pull: CGFloat
    let island: Bool
    let name: String
    let photoID: String?
    let ring: Color

    var body: some View {
        let g = AvatarCollapse(raw: raw, restTop: restTop, screenWidth: screen.width, pull: pull)
        return ZStack(alignment: .topLeading) {
            if island, g.c > 0.005 { IslandBlob(g: g, screen: screen) }
            avatar(g)
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
    }

    private func avatar(_ g: AvatarCollapse) -> some View {
        let size: CGFloat = AvatarCollapse.size
        let k: CGFloat = g.diameter / size
        // без островка: без чернения, просто уменьшается и растворяется
        let dark: CGFloat = island ? g.dark : 0
        let front: CGFloat = island ? g.front : -AvatarCollapse.band
        let fade: Double = island ? g.opacity : Double(1 - AvatarCollapse.smooth((g.c - 0.5) / 0.35))
        let photoAlpha: Double = island ? g.photo : 1
        let shade = LinearGradient(colors: [.black, .clear],
                                   startPoint: UnitPoint(x: 0.5, y: front),
                                   endPoint: UnitPoint(x: 0.5, y: front + AvatarCollapse.band))
        let ringAlpha: Double = Double(1 - min(1, dark * 3))
        return ZStack {
            face
                .frame(width: size, height: size)
                .clipped()
                .blur(radius: g.blur, opaque: true)          // края не прозрачнеют — чёрное снизу не просвечивает
                .opacity(photoAlpha)
            Rectangle().fill(shade)                           // фронт затемнения ползёт сверху вниз
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(ring, lineWidth: 1).opacity(ringAlpha))
        .scaleEffect(k)
        .position(g.center)
        .opacity(fade)
    }

    @ViewBuilder
    private var face: some View {
        if let photoID {
            RemoteImage(id: photoID)
        } else {
            AvatarView(name: name, size: AvatarCollapse.size)
        }
    }
}
