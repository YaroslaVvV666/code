import SwiftUI
import PhotosUI

/// Круглая кнопка «+» у аватарки: добавить фото (или первое)
struct AddPhotoBadge: View {
    @ObservedObject var store: ProfileStore
    var size: CGFloat = 30

    @Environment(\.theme) private var theme
    @State private var item: PhotosPickerItem?
    @State private var busy = false
    @State private var errorText: String?
    @Environment(\.lang) private var lang

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            ZStack {
                Circle().fill(theme.accent)
                if busy {
                    ProgressView().tint(.white).scaleEffect(0.7)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: size * 0.45, weight: .bold))
                        .foregroundStyle(Color.white)
                }
            }
            .frame(width: size, height: size)
            .overlay(Circle().stroke(theme.sheet, lineWidth: 3))
        }
        .disabled(busy)
        .alert(errorText ?? "", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .onChange(of: item) { _, new in
            guard let new else { return }
            Task { @MainActor in
                busy = true
                if let data = try? await new.loadTransferable(type: Data.self) {
                    if let error = await store.addPhoto(from: data) { errorText = Strings(lang: lang).api(error) }
                }
                busy = false
                item = nil
            }
        }
    }
}

// MARK: - Аватарка в шапке: как в Telegram показывается текущая, остальные — в просмотрщике

struct AvatarPager: View {
    let name: String
    let photos: [AvatarPhoto]
    var size: CGFloat = 112
    @Binding var index: Int                 // оставлен для совместимости, всегда показываем главную
    var addStore: ProfileStore? = nil       // если задан — рядом с аватаркой кнопка «+»
    var listening = false                   // человек сейчас слушает музыку (по данным сервера)
    var isMine = false                      // свой профиль: волна идёт, пока играет наш плеер
    var onTap: () -> Void = {}

    @Environment(\.theme) private var theme

    var body: some View {
        ListeningFXHost(remote: listening, mine: isMine, size: size) { core }
    }

    private var core: some View {
        ZStack {
            if let first = photos.first {
                RemoteImage(id: first.mediaID)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .contentShape(Circle())
                    .onTapGesture(perform: onTap)
            } else {
                AvatarView(name: name, size: size).clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(theme.stroke, lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            // «+» нужен только пока фото ещё нет; счётчик фотографий убран
            if let addStore, photos.isEmpty {
                AddPhotoBadge(store: addStore, size: max(26, size * 0.3)).offset(x: 4, y: 4)
            }
        }
    }
}

// MARK: - Просмотр на весь экран (как в Telegram): полоски сверху, счётчик, лента миниатюр

struct AvatarViewerRoute: Identifiable {
    let id = UUID()
    let index: Int
}

struct AvatarViewer: View {
    let name: String
    var onReorder: (([String]) -> Void)? = nil      // задано — это мои фото: можно сделать основным / удалить / переставить
    var onDelete: ((String) -> Void)? = nil
    var onClose: (() -> Void)? = nil               // если показан не через fullScreenCover, а поверх экрана

    @State private var photos: [AvatarPhoto]
    @State private var currentID: String?
    @State private var confirmDelete = false
    @State private var showOrder = false
    @State private var shareItems: ShareItems?
    @State private var sharing = false
    @State private var dragY: CGFloat = 0          // свайп вверх/вниз: фото едет за пальцем, отпустили дальше порога — просмотр закрывается
    @State private var dragVertical: Bool?         // направление жеста определяется в начале: вбок — листание фото

    @Environment(\.dismiss) private var dismiss
    @Environment(\.lang) private var lang
    @Environment(\.theme) private var theme

    init(name: String, photos: [AvatarPhoto], start: Int,
         onReorder: (([String]) -> Void)? = nil, onDelete: ((String) -> Void)? = nil, onClose: (() -> Void)? = nil) {
        self.name = name
        self.onClose = onClose
        self.onReorder = onReorder
        self.onDelete = onDelete
        _photos = State(initialValue: photos)
        _currentID = State(initialValue: photos.indices.contains(start) ? photos[start].id : photos.first?.id)
    }

    private func close() { if let onClose { onClose() } else { dismiss() } }

    private var s: Strings { Strings(lang: lang) }
    private var index: Int { photos.firstIndex { $0.id == currentID } ?? 0 }
    private var isEditable: Bool { onReorder != nil }

    /// 0 — фото на месте, 1 — утянуто далеко (фон и кнопки почти исчезли)
    private var pull: CGFloat { min(1, abs(dragY) / 420) }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { v in
                if dragVertical == nil { dragVertical = abs(v.translation.height) > abs(v.translation.width) * 1.3 }
                guard dragVertical == true else { return }
                dragY = v.translation.height
            }
            .onEnded { v in
                defer { dragVertical = nil }
                guard dragVertical == true else { return }
                let dy = v.translation.height, fling = v.predictedEndTranslation.height
                if abs(dy) > 110 || abs(fling) > 320 {
                    // улетает в сторону свайпа (вверх — вверх), затем просмотр закрывается
                    Haptics.impact(.light)
                    let up = (abs(fling) > abs(dy) ? fling : dy) < 0
                    withAnimation(.easeOut(duration: 0.2)) { dragY = (up ? -1 : 1) * UIScreen.main.bounds.height }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { close() }
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { dragY = 0 }
                }
            }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - Double(pull) * 0.85).ignoresSafeArea()

            Group {
            if photos.isEmpty {
                AvatarView(name: name, size: 200).clipShape(Circle())
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(photos) { photo in
                            RemoteImage(id: photo.mediaID, fill: false)
                                .containerRelativeFrame(.horizontal)
                                .id(photo.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentID)
                .ignoresSafeArea()
            }
            }
            .offset(y: dragY)
            .scaleEffect(1 - pull * 0.12)
            .simultaneousGesture(dismissDrag)

            VStack(spacing: 10) {
                topBar
                if photos.count > 1 {
                    Text(s.photoCounter(index + 1, photos.count))
                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .glassCapsule()
                }
                Spacer()
                bottomBar
            }
            .padding(.top, 8)
            .padding(.bottom, 10)
            .opacity(1 - Double(pull) * 2)              // кнопки уходят быстрее фото
        }
        .preferredColorScheme(.dark)
        .confirmationDialog(s.deletePhotoQuestion, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(s.deletePhoto, role: .destructive) { deleteCurrent() }
            Button(s.cancel, role: .cancel) {}
        }
        .sheet(isPresented: $showOrder) {
            PhotoReorderSheet(photos: photos) { ordered in
                photos = ordered
                currentID = ordered.first?.id
                onReorder?(ordered.map(\.id))
            }
            .environment(\.theme, theme)
            .presentationDetents([.large])
        }
        .sheet(item: $shareItems) { item in
            ActivitySheet(items: item.items).presentationDetents([.medium, .large])
        }
    }

    // Сверху: назад | имя и дата по центру | «Изм.»
    private var topBar: some View {
        HStack {
            Button { close() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 42, height: 42)
                    .glassCircle()
                    .frame(width: 64, height: 64).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, -11)
            .zIndex(10)

            Spacer(minLength: 8)

            VStack(spacing: 1) {
                Text(name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.white).lineLimit(1)
                if photos.indices.contains(index) {
                    Text(s.photoDate(photos[index].createdAt))
                        .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 42)
            .glassCapsule()

            Spacer(minLength: 8)

            if isEditable, !photos.isEmpty {
                Menu {
                    if index != 0 {
                        Button { makeMain() } label: { Label(s.makeMain, systemImage: "star") }
                    }
                    if photos.count > 1 {
                        Button { showOrder = true } label: { Label(s.t("Изменить порядок", "Reorder"), systemImage: "arrow.up.arrow.down") }
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label(s.deletePhoto, systemImage: "trash")
                    }
                } label: {
                    Text(s.t("Изм.", "Edit"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 16)
                        .frame(height: 42)
                        .glassCapsule()
                        .padding(.horizontal, 8).padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .padding(.trailing, -8)
            } else {
                Color.clear.frame(width: 42, height: 42)
            }
        }
        .padding(.horizontal, 14)
    }

    // Снизу: «поделиться» слева, лента миниатюр по центру, корзина справа
    private var bottomBar: some View {
        VStack(spacing: 12) {
            if photos.count > 1 { thumbnails }
            HStack {
                Button(action: share) {
                    Group {
                        if sharing { ProgressView().tint(.white) } else {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .medium))
                        }
                    }
                    .foregroundStyle(Color.white)
                    .frame(width: 46, height: 46)
                    .glassCircle()
                    .frame(width: 66, height: 66).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, -10)
                .disabled(photos.isEmpty || sharing)

                Spacer()

                if isEditable, !photos.isEmpty {
                    Button { confirmDelete = true } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color.white)
                            .frame(width: 46, height: 46)
                            .glassCircle()
                            .frame(width: 66, height: 66).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, -10)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func share() {
        guard photos.indices.contains(index), !sharing else { return }
        sharing = true
        let id = photos[index].mediaID
        Task {
            defer { sharing = false }
            if let url = await FileDownloader.download(mediaID: id, name: "avatar.jpg") {
                shareItems = ShareItems(items: [url])
            }
        }
    }

    // Лента миниатюр: быстро перейти к любому из многих фото
    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(photos) { photo in
                        let selected = photo.id == currentID
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { currentID = photo.id }
                        } label: {
                            RemoteImage(id: photo.mediaID)
                                .frame(width: selected ? 52 : 44, height: selected ? 52 : 44)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white, lineWidth: selected ? 2 : 0))
                                .opacity(selected ? 1 : 0.65)
                                .padding(.horizontal, 3).padding(.vertical, 2)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id("t-" + photo.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 56)
            .onChange(of: currentID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("t-" + id, anchor: .center) }
            }
            .onAppear {
                if let id = currentID { proxy.scrollTo("t-" + id, anchor: .center) }
            }
        }
    }

    private func makeMain() {
        guard photos.indices.contains(index), index != 0 else { return }
        let photo = photos[index]
        withAnimation {
            photos.remove(at: index)
            photos.insert(photo, at: 0)
            currentID = photo.id
        }
        onReorder?(photos.map(\.id))
    }

    private func deleteCurrent() {
        guard photos.indices.contains(index) else { return }
        let removed = photos[index]
        let next = photos.indices.contains(index + 1) ? photos[index + 1].id : (index > 0 ? photos[index - 1].id : nil)
        withAnimation {
            photos.removeAll { $0.id == removed.id }
            currentID = next
        }
        onDelete?(removed.id)
        if photos.isEmpty { close() }
    }
}


// MARK: - Музыкальный визуализатор вокруг аватарки, пока человек слушает музыку

/// Выбирает, чьё воспроизведение показывать: своё (плеер приложения, с настоящей громкостью) или чужое (по данным сервера)
struct ListeningFXHost<Content: View>: View {
    let remote: Bool
    let mine: Bool
    let size: CGFloat
    @ViewBuilder let content: Content
    @EnvironmentObject private var session: AppSession

    var body: some View {
        if mine {
            LocalFX(player: session.player, size: size) { content }
        } else {
            ListeningFX(active: remote, size: size, energy: { Beat.calm($0) }) { content }
        }
    }
}

private struct LocalFX<Content: View>: View {
    @ObservedObject var player: AudioPlayer
    let size: CGFloat
    @ViewBuilder let content: Content
    var body: some View { ListeningFX(active: player.isPlaying, size: size, energy: { _ in player.energy() }) { content } }
}

/// Аватарка «дышит» в такт, вокруг мягкая капля с волнами и всплывающие капельки.
/// Чем громче звук — тем сильнее толчок и больше движения; в тихих местах всё плавно и почти незаметно
struct ListeningFX<Content: View>: View {
    let active: Bool
    let size: CGFloat
    let energy: (Double) -> Double
    @ViewBuilder let content: Content

    var body: some View {
        if active {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let e = energy(t)
                content
                    .scaleEffect(1 + 0.04 * CGFloat(e))
                    .background { BeatVisualizer(size: size, energy: e, time: t).allowsHitTesting(false) }
            }
        } else {
            content
        }
    }
}

enum Beat {
    static func hash(_ i: Int, _ salt: Double) -> Double {
        let x = sin(Double(i) * 127.1 + salt * 311.7) * 43758.5453
        return x - floor(x)
    }

    /// Для чужой страницы настоящей громкости нет: мягкие «вдохи» разной силы, без резких пиков
    static func calm(_ t: Double) -> Double {
        let slow = 0.5 + 0.5 * sin(t * 1.9)
        let swell = 0.5 + 0.5 * sin(t * 0.45 + 1.3)
        let pulse = pow(0.5 + 0.5 * sin(t * 4.2), 3) * 0.5
        return min(1, 0.12 + 0.28 * slow * (0.5 + 0.5 * swell) + pulse * (0.3 + 0.5 * swell))
    }
}

struct BeatVisualizer: View {
    let size: CGFloat
    let energy: Double
    let time: Double
    var hue: Double? = nil            // свой цвет (аватарки на орбите); nil — плывущая радуга, как у основной аватарки

    /// Цвет почти не меняется в пределах кадра (соседние оттенки), а сам оттенок очень медленно плывёт по кругу:
    /// жёлтый → зелёный → голубой → … Полный круг около минуты
    private func tint(_ x: Double, _ t: Double, sat: Double = 0.55, bri: Double = 1) -> Color {
        if let base = hue {
            let h = (base + (x - 0.5) * 0.06 + 1).truncatingRemainder(dividingBy: 1)
            return Color(hue: h, saturation: min(1, sat + 0.25), brightness: bri)
        }
        let h = (t * 0.017 + x * 0.07).truncatingRemainder(dividingBy: 1)
        return Color(hue: h < 0 ? h + 1 : h, saturation: sat, brightness: bri)
    }

    var body: some View {
        Canvas { gc, sz in
            let t = time
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let r = size / 2
            let e = CGFloat(energy)
            let eD = energy

            // 1. Мягкое свечение позади аватарки
            gc.drawLayer { l in
                l.addFilter(.blur(radius: size * 0.16))
                l.blendMode = .plusLighter
                for i in 0..<2 {
                    let a = t * (0.30 + Double(i) * 0.1) * (i == 0 ? 1 : -1) + Double(i) * 3.1
                    let cx = c.x + cos(a) * r * 0.5, cy = c.y + sin(a) * r * 0.5
                    let big = r * (0.70 + 0.35 * e)
                    l.fill(Path(ellipseIn: CGRect(x: cx - big, y: cy - big, width: big * 2, height: big * 2)),
                           with: .color(tint(Double(i), t, sat: 0.7).opacity(0.20 + 0.26 * eD)))
                }
            }

            // 2. Капля вокруг аватарки: плавно колышется, на громком — сильнее толчок
            func drop(grow: CGFloat, amp: CGFloat, phase: Double) -> Path {
                var path = Path()
                let m = 120
                for i in 0...m {
                    let a = Double(i) / Double(m) * 2 * Double.pi
                    let w = sin(a * 2 + t * 0.9 + phase) * 0.6 + sin(a * 3 - t * 1.3 + phase * 1.7) * 0.4
                    let rr = r * 1.06 + grow + r * amp * CGFloat(w)
                    let pt = CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                path.closeSubpath()
                return path
            }
            let amp = 0.012 + 0.07 * e
            let body = drop(grow: 0, amp: amp, phase: 0)
            gc.drawLayer { l in
                l.addFilter(.blur(radius: 5 + 4 * e))
                l.fill(body, with: .color(tint(0.5, t, sat: 0.6).opacity(0.30 + 0.35 * eD)))
            }
            let line = GraphicsContext.Shading.conicGradient(
                Gradient(colors: [tint(0, t, sat: 0.5), tint(0.5, t, sat: 0.55), tint(1, t, sat: 0.5),
                                  tint(0.5, t, sat: 0.55), tint(0, t, sat: 0.5)]),
                center: c, angle: .degrees(t * 20))
            gc.stroke(body, with: line, lineWidth: 1.8 + 1.4 * e)
            gc.stroke(drop(grow: 4 + 9 * e, amp: amp * 1.3, phase: 2.2), with: line, lineWidth: 0.8)

            // 3. Капельки отрываются и уплывают вверх
            let count = 9 + Int(9 * e)
            for i in 0..<count {
                let h1 = Beat.hash(i + 40, 2.1), h2 = Beat.hash(i + 40, 5.7), h3 = Beat.hash(i + 40, 9.3)
                let life = 3.4 + h1 * 3.5
                let ph = (t / life + h2).truncatingRemainder(dividingBy: 1)
                let ang = h3 * 2 * Double.pi + sin(t * 0.35 + h1 * 6) * 0.3
                let dist = r * (1.2 + 0.65 * CGFloat(ph))
                let x = c.x + cos(ang) * dist + CGFloat(sin(t * 0.7 + h2 * 8)) * 3
                let y = c.y + sin(ang) * dist - CGFloat(ph) * size * 0.26
                let alpha = sin(ph * Double.pi) * (0.35 + 0.5 * h1)
                let d = (2.4 + 3.2 * CGFloat(h2) + 2.6 * e) * (1 - CGFloat(ph) * 0.35)
                gc.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)),
                        with: .color(tint(h1, t, sat: 0.45).opacity(alpha)))
            }
        }
        .frame(width: size * 2.8, height: size * 2.8)
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}
