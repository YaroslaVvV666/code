import SwiftUI
import PhotosUI
import AVFoundation

/// Окно предпросмотра: показывает AVPlayer в кадре 9:16
struct ReelPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}

/// Элемент, который можно таскать, масштабировать и вращать двумя пальцами
private struct ReelDraggable<Content: View>: View {
    @Binding var cx: Double
    @Binding var cy: Double
    @Binding var scale: Double
    @Binding var rotation: Double
    let size: CGSize
    var onTap: () -> Void = {}
    var onDragging: (Double) -> Void
    var onEnd: (Double) -> Void
    @ViewBuilder var content: () -> Content

    @State private var startPos: CGPoint?
    @State private var startScale: Double?
    @State private var startRotation: Double?

    var body: some View {
        content()
            .rotationEffect(.radians(rotation))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named("reelStage"))
                    .onChanged { v in
                        if startPos == nil { startPos = CGPoint(x: cx, y: cy) }
                        guard let p = startPos else { return }
                        cx = min(max(p.x + v.translation.width / size.width, 0.02), 0.98)
                        cy = min(max(p.y + v.translation.height / size.height, 0.02), 0.98)
                        onDragging(cy)
                    }
                    .onEnded { _ in
                        startPos = nil
                        onEnd(cy)
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        if startScale == nil { startScale = scale }
                        scale = min(max((startScale ?? 1) * v.magnification, 0.3), 4)
                    }
                    .onEnded { _ in startScale = nil }
            )
            .simultaneousGesture(
                RotateGesture()
                    .onChanged { v in
                        if startRotation == nil { startRotation = rotation }
                        rotation = (startRotation ?? 0) + v.rotation.radians
                    }
                    .onEnded { _ in startRotation = nil }
            )
            .onTapGesture(perform: onTap)
            .position(x: cx * size.width, y: cy * size.height)
    }
}

/// Полоса обрезки с двумя ручками
private struct ReelTrimBar: View {
    @Binding var start: Double
    @Binding var end: Double
    let total: Double
    let maxLen: Double
    let thumbs: [UIImage]
    var onScrub: (Double) -> Void
    var onCommit: () -> Void

    private let handle: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = max(total, 0.1)
            let x0 = CGFloat(start / span) * w
            let x1 = CGFloat(end / span) * w
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if thumbs.isEmpty {
                        Rectangle().fill(Color.white.opacity(0.1))
                    } else {
                        ForEach(Array(thumbs.enumerated()), id: \.offset) { _, img in
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(width: w / CGFloat(thumbs.count), height: 52).clipped()
                        }
                    }
                }
                .frame(width: w, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Rectangle().fill(.black.opacity(0.6)).frame(width: max(0, x0), height: 52)
                Rectangle().fill(.black.opacity(0.6)).frame(width: max(0, w - x1), height: 52).offset(x: x1)

                RoundedRectangle(cornerRadius: 8).stroke(Color.yellow, lineWidth: 3)
                    .frame(width: max(handle * 2, x1 - x0), height: 52).offset(x: x0)
                    .allowsHitTesting(false)

                grip.offset(x: x0 - handle / 2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { v in
                        let t = Double(v.location.x / w) * span
                        start = min(max(t, max(0, end - maxLen)), end - 1)
                        onScrub(start)
                    }.onEnded { _ in onCommit() })
                grip.offset(x: x1 - handle / 2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { v in
                        let t = Double(v.location.x / w) * span
                        end = max(min(t, min(total, start + maxLen)), start + 1)
                        onScrub(end)
                    }.onEnded { _ in onCommit() })
            }
            .coordinateSpace(name: "trim")
        }
        .frame(height: 52)
    }

    private var grip: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.yellow)
            .frame(width: handle, height: 52)
            .overlay(Capsule().fill(.black.opacity(0.6)).frame(width: 3, height: 20))
            .contentShape(Rectangle().inset(by: -10))
    }
}

/// Ввод текста поверх видео: цвет, стиль и шрифт
private struct ReelTextEditor: View {
    @Binding var item: ReelText
    var onDone: () -> Void
    @Environment(\.lang) private var lang
    @FocusState private var focused: Bool

    var body: some View {
        let s = Strings(lang: lang)
        let fg = ReelPalette.color(item.color)
        let filled = item.style == 1
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    chip("textformat.size") { item.font = (item.font + 1) % ReelPalette.fontCount }
                    chip(filled ? "a.square.fill" : (item.style == 2 ? "sparkles" : "a.square")) { item.style = (item.style + 1) % 3 }
                    Spacer()
                    Button(action: onDone) {
                        Text(s.t("Готово", "Done")).font(.system(size: 16, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 18).frame(height: 40).background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.top, 8)

                Spacer(minLength: 0)
                TextField("", text: $item.text, axis: .vertical)
                    .focused($focused)
                    .font(.system(size: 34, weight: .bold, design: ReelPalette.design(item.font)))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(filled ? (ReelPalette.isLight(item.color) ? Color.black : Color.white) : fg)
                    .tint(.white)
                    .padding(.horizontal, filled ? 16 : 0).padding(.vertical, filled ? 8 : 0)
                    .background(filled ? fg : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: item.style == 2 ? fg.opacity(0.9) : .clear, radius: 10)
                    .padding(.horizontal, 24)
                    .lineLimit(1...6)
                Spacer(minLength: 0)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(0..<ReelPalette.colors.count, id: \.self) { i in
                            Button { item.color = i } label: {
                                Circle().fill(ReelPalette.colors[i]).frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(.white, lineWidth: item.color == i ? 3 : 1).opacity(item.color == i ? 1 : 0.4))
                                    .frame(width: 40, height: 40).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 10)
            }
        }
        .onAppear { focused = true }
    }

    private func chip(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(.white.opacity(0.16), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Редактор шортса в стиле TikTok
struct ReelEditorView: View {
    @ObservedObject var model: ReelEditModel
    let tracks: [Track]
    var onDone: (PreparedMedia?, Track?) -> Void
    var onClose: () -> Void

    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    private enum Tool { case music, filter, trim }

    @State private var tool: Tool?
    @State private var editing: ReelText?
    @State private var dragging = false
    @State private var overTrash = false
    @State private var stickerPick: [PhotosPickerItem] = []
    @State private var addPhotoPick: [PhotosPickerItem] = []
    @State private var confirmClose = false
    @State private var thumbs: [UIImage] = []

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                stage
                if let tool { panel(tool).transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: tool)

            if editing != nil {
                ReelTextEditor(item: Binding(get: { editing ?? ReelText(text: "") }, set: { editing = $0 })) { commitText() }
                    .transition(.opacity)
                    .zIndex(2)
            }
            if model.exporting {
                ZStack {
                    Color.black.opacity(0.65).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView(value: model.exportProgress).tint(.white).frame(width: 180)
                        Text(s.t("Собираем шортс…", "Rendering your short…") + " \(Int(model.exportProgress * 100))%")
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    }
                }
                .zIndex(3)
            }
        }
        .preferredColorScheme(.dark)
        .task { await model.start() }
        .onDisappear { model.pause() }
        .task(id: model.baseURL) { await loadThumbs() }
        .onChange(of: stickerPick) { _, items in
            guard !items.isEmpty else { return }
            let picked = items
            stickerPick = []
            Task { await addStickers(picked) }
        }
        .onChange(of: addPhotoPick) { _, items in
            guard !items.isEmpty else { return }
            let picked = items
            addPhotoPick = []
            Task { await addSlides(picked) }
        }
        .alert(s.t("Не получилось", "Something went wrong"), isPresented: $model.failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(s.t("Не удалось обработать видео или загрузить музыку. Попробуйте ещё раз.",
                     "Couldn't process the video or load the music. Please try again."))
        }
        .confirmationDialog(s.t("Выйти без сохранения?", "Discard changes?"), isPresented: $confirmClose, titleVisibility: .visible) {
            Button(s.t("Выйти", "Discard"), role: .destructive) { onClose() }
            Button(s.t("Продолжить", "Keep editing"), role: .cancel) {}
        }
    }

    // MARK: Верх

    private var topBar: some View {
        HStack {
            Button {
                if !model.texts.isEmpty || !model.stickers.isEmpty || model.music != nil || model.filter != .none
                    || (model.kind == .video && model.hasEdits) || model.kind == .photos {
                    confirmClose = true
                } else { onClose() }
            } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(.white.opacity(0.16), in: Circle())
                    .frame(width: 48, height: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if model.ready {
                Text(clock(model.trimLength)).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10).frame(height: 28).background(.white.opacity(0.12), in: Capsule())
                Spacer()
            }
            Button { finish() } label: {
                Text(s.t("Далее", "Next")).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 20).frame(height: 40)
                    .background(Color(red: 0.99, green: 0.17, blue: 0.33), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!model.ready || model.exporting)
            .opacity(model.ready ? 1 : 0.5)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    // MARK: Сцена

    private var stage: some View {
        GeometryReader { geo in
            let h = min(geo.size.height, geo.size.width * 16 / 9)
            let w = h * 9 / 16
            let size = CGSize(width: w, height: h)
            ZStack {
                ReelPlayerLayer(player: model.player)
                Color.clear.contentShape(Rectangle()).onTapGesture { if tool != nil { tool = nil } else { model.togglePlay() } }

                ForEach($model.stickers) { $st in
                    ReelDraggable(cx: $st.cx, cy: $st.cy, scale: $st.scale, rotation: $st.rotation, size: size,
                                  onDragging: { cy in dragging = true; overTrash = cy > 0.86 },
                                  onEnd: { cy in
                        dragging = false; overTrash = false
                        if cy > 0.86 { model.stickers.removeAll { $0.id == st.id }; Haptics.impact(.medium) }
                    }) { ReelStickerView(item: st, unit: w) }
                    .contextMenu {
                        Button(role: .destructive) { model.stickers.removeAll { $0.id == st.id } } label: {
                            Label(s.t("Удалить", "Delete"), systemImage: "trash")
                        }
                    }
                }
                ForEach($model.texts) { $t in
                    if editing?.id != t.id {
                        ReelDraggable(cx: $t.cx, cy: $t.cy, scale: $t.scale, rotation: $t.rotation, size: size,
                                      onTap: { editing = t },
                                      onDragging: { cy in dragging = true; overTrash = cy > 0.86 },
                                      onEnd: { cy in
                            dragging = false; overTrash = false
                            if cy > 0.86 { model.texts.removeAll { $0.id == t.id }; Haptics.impact(.medium) }
                        }) { ReelTextView(item: t, unit: w) }
                        .contextMenu {
                            Button { editing = t } label: { Label(s.t("Изменить", "Edit"), systemImage: "pencil") }
                            Button(role: .destructive) { model.texts.removeAll { $0.id == t.id } } label: {
                                Label(s.t("Удалить", "Delete"), systemImage: "trash")
                            }
                        }
                    }
                }

                if !model.isPlaying && model.ready && !dragging {
                    Image(systemName: "play.fill").font(.system(size: 26)).foregroundStyle(.white)
                        .frame(width: 64, height: 64).background(.black.opacity(0.35), in: Circle())
                        .allowsHitTesting(false)
                }
                if !model.ready { ProgressView().tint(.white) }
                if dragging {
                    VStack {
                        Spacer()
                        Image(systemName: "trash.fill").font(.system(size: overTrash ? 24 : 19)).foregroundStyle(.white)
                            .frame(width: overTrash ? 58 : 46, height: overTrash ? 58 : 46)
                            .background(overTrash ? Color.red : Color.black.opacity(0.55), in: Circle())
                            .padding(.bottom, 14)
                            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: overTrash)
                    }
                    .allowsHitTesting(false)
                }
                rail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .coordinateSpace(name: "reelStage")
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .padding(.vertical, 4)
    }

    private var rail: some View {
        VStack(spacing: 14) {
            railButton("textformat", s.t("Текст", "Text")) {
                tool = nil
                model.pause()
                editing = ReelText(text: "")
                model.texts.append(editing!)
            }
            PhotosPicker(selection: $stickerPick, maxSelectionCount: 4, matching: .images) {
                railLabel("photo.on.rectangle.angled", s.t("Фото", "Photo"))
            }
            .buttonStyle(.plain)
            railButton("music.note", s.t("Музыка", "Music"), active: model.music != nil || tool == .music) { toggle(.music) }
            if model.kind == .video {
                railButton(model.originalVolume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill", s.t("Звук", "Sound"),
                           active: model.originalVolume < 0.01) {
                    model.originalVolume = model.originalVolume < 0.01 ? 1 : 0
                    Haptics.impact(.light)
                }
            }
            railButton("camera.filters", s.t("Фильтры", "Filters"), active: model.filter != .none || tool == .filter) { toggle(.filter) }
            railButton(model.kind == .video ? "scissors" : "photo.stack", model.kind == .video ? s.t("Обрезка", "Trim") : s.t("Слайды", "Slides"),
                       active: tool == .trim) { toggle(.trim) }
        }
        .padding(.top, 12).padding(.trailing, 8)
        .zIndex(5)
    }

    private func toggle(_ t: Tool) { tool = (tool == t) ? nil : t }

    private func railButton(_ icon: String, _ title: String, active: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { railLabel(icon, title, active: active).contentShape(Rectangle()) }
            .buttonStyle(.plain)
    }

    private func railLabel(_ icon: String, _ title: String, active: Bool = false) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(active ? Color.yellow : .white)
                .frame(width: 42, height: 42).background(.black.opacity(0.45), in: Circle())
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2)
        }
    }

    // MARK: Панели

    @ViewBuilder
    private func panel(_ tool: Tool) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text(title(of: tool)).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Button { self.tool = nil } label: {
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(.white.opacity(0.14), in: Circle())
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            switch tool {
            case .music: musicPanel
            case .filter: filterPanel
            case .trim: model.kind == .video ? AnyView(trimPanel) : AnyView(slidesPanel)
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 14)
        .background(Color(white: 0.1), in: UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
    }

    private func title(of tool: Tool) -> String {
        switch tool {
        case .music: return s.t("Музыка и звук", "Music & sound")
        case .filter: return s.t("Фильтры", "Filters")
        case .trim: return model.kind == .video ? s.t("Обрезка", "Trim") : s.t("Фото в шортсе", "Slides")
        }
    }

    private var musicPanel: some View {
        VStack(spacing: 12) {
            if tracks.isEmpty {
                Text(s.t("Добавьте треки в плейлист профиля — их можно будет ставить на шортс.",
                         "Add tracks to your profile playlist to use them in shorts."))
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.65)).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        trackRow(nil)
                        ForEach(tracks) { trackRow($0) }
                    }
                }
                .frame(maxHeight: 132)
            }
            if model.musicLoading {
                HStack(spacing: 8) { ProgressView().tint(.white); Text(s.t("Загружаем трек…", "Loading track…")).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)) }
            }
            volumeRow("music.note", s.t("Музыка", "Music"), $model.musicVolume, enabled: model.music != nil)
            volumeRow(model.originalVolume < 0.01 ? "speaker.slash.fill" : "video.fill", s.t("Звук видео", "Video sound"), $model.originalVolume,
                      enabled: model.kind == .video)
            if model.music != nil, model.musicStartLimit > 1 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.t("Начало фрагмента", "Start from") + " · " + clock(model.musicStart))
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                    Slider(value: $model.musicStart, in: 0...model.musicStartLimit).tint(.white)
                }
            }
            if model.music != nil {
                Button(role: .destructive) { Task { await model.setMusic(nil) } } label: {
                    Label(s.t("Убрать музыку", "Remove music"), systemImage: "trash")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(red: 1, green: 0.35, blue: 0.35))
                        .frame(maxWidth: .infinity).frame(height: 40).background(.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func trackRow(_ track: Track?) -> some View {
        let selected = model.music?.id == track?.id
        return Button {
            Haptics.impact(.light)
            Task { await model.setMusic(track) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: track == nil ? "nosign" : "music.note").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 32, height: 32).background(.white.opacity(0.12), in: Circle())
                Text(track?.display ?? s.t("Без музыки", "No music")).font(.system(size: 15)).foregroundStyle(.white).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.yellow) }
            }
            .padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func volumeRow(_ icon: String, _ label: String, _ value: Binding<Double>, enabled: Bool) -> some View {
        HStack(spacing: 10) {
            Button { value.wrappedValue = value.wrappedValue < 0.01 ? 1 : 0 } label: {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).frame(width: 26)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            Text(label).font(.system(size: 14)).foregroundStyle(.white).frame(width: 82, alignment: .leading)
            Slider(value: value, in: 0...1).tint(.white).disabled(!enabled)
            Text("\(Int(value.wrappedValue * 100))").font(.system(size: 13).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                .frame(width: 30, alignment: .trailing)
        }
        .opacity(enabled ? 1 : 0.4)
    }

    private var filterPanel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(ReelFilter.allCases) { f in
                    Button { model.filter = f; Haptics.impact(.light) } label: {
                        VStack(spacing: 6) {
                            Circle().fill(LinearGradient(colors: [f.tint, f.tint.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                                .frame(width: 54, height: 54)
                                .overlay(Circle().stroke(.yellow, lineWidth: model.filter == f ? 3 : 0))
                                .overlay(Image(systemName: f == .none ? "nosign" : "camera.filters").foregroundStyle(.white.opacity(0.9)))
                            Text(f.title(s)).font(.system(size: 12)).foregroundStyle(model.filter == f ? Color.yellow : .white)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var trimPanel: some View {
        VStack(spacing: 10) {
            ReelTrimBar(start: $model.trimStart, end: $model.trimEnd, total: model.baseDuration,
                        maxLen: ReelEditModel.maxSeconds, thumbs: thumbs,
                        onScrub: { model.scrub(to: $0) }, onCommit: { model.loop() })
            HStack {
                Text(clock(model.trimStart)).monospacedDigit()
                Spacer()
                Text(s.t("Длительность", "Length") + " " + clock(model.trimLength)).monospacedDigit().foregroundStyle(.white)
                Spacer()
                Text(clock(model.trimEnd)).monospacedDigit()
            }
            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
            if model.baseDuration > ReelEditModel.maxSeconds {
                Text(s.t("Шортс — не длиннее 3 минут", "A short can't be longer than 3 minutes"))
                    .font(.system(size: 12)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var slidesPanel: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(model.photos.enumerated()), id: \.offset) { idx, img in
                        Image(uiImage: img).resizable().scaledToFill().frame(width: 52, height: 84).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(alignment: .topTrailing) {
                                if model.photos.count > 1 {
                                    Button { model.photos.remove(at: idx); model.photosChanged() } label: {
                                        Image(systemName: "xmark.circle.fill").font(.system(size: 18))
                                            .foregroundStyle(.white, .black.opacity(0.7)).padding(2)
                                    }
                                }
                            }
                            .contextMenu {
                                if idx > 0 {
                                    Button { model.photos.swapAt(idx, idx - 1); model.photosChanged() } label: {
                                        Label(s.t("Влево", "Move left"), systemImage: "arrow.left")
                                    }
                                }
                                if idx < model.photos.count - 1 {
                                    Button { model.photos.swapAt(idx, idx + 1); model.photosChanged() } label: {
                                        Label(s.t("Вправо", "Move right"), systemImage: "arrow.right")
                                    }
                                }
                            }
                    }
                    if model.photos.count < 20 {
                        PhotosPicker(selection: $addPhotoPick, maxSelectionCount: 10, matching: .images) {
                            Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 52, height: 84).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "timer").foregroundStyle(.white)
                Text(s.t("Одно фото", "Per photo") + " · " + String(format: "%.1f", model.photoSeconds) + s.t(" с", " s"))
                    .font(.system(size: 14)).foregroundStyle(.white)
                Slider(value: $model.photoSeconds, in: 1...8, step: 0.5).tint(.white)
            }
            Text(s.t("Зажмите фото, чтобы поменять порядок", "Press and hold a photo to reorder"))
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Действия

    private func clock(_ t: Double) -> String {
        let v = Int(t.rounded())
        return String(format: "%d:%02d", v / 60, v % 60)
    }

    private func commitText() {
        guard let e = editing else { return }
        let trimmed = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = model.texts.firstIndex(where: { $0.id == e.id }) {
            if trimmed.isEmpty { model.texts.remove(at: i) } else { var v = e; v.text = trimmed; model.texts[i] = v }
        }
        editing = nil
        model.play()
    }

    private func finish() {
        Task {
            // видео без правок отправляем как есть — без повторного сжатия
            if model.kind == .video, !model.hasEdits { model.pause(); onDone(nil, nil); return }
            guard let url = await model.exportVideo(), let media = await ReelRender.describe(url) else { return }
            model.pause()
            onDone(media, model.music)
        }
    }

    private func addStickers(_ items: [PhotosPickerItem]) async {
        var offset = 0.0
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let jpeg = ImageProcessing.prepare(data, maxSide: 900), let image = UIImage(data: jpeg) else { continue }
            var st = ReelSticker(image: image)
            st.cx = 0.5 + offset; st.cy = 0.5 + offset
            offset += 0.06
            model.stickers.append(st)
        }
        Haptics.impact(.light)
    }

    private func addSlides(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard model.photos.count < 20,
                  let data = try? await item.loadTransferable(type: Data.self),
                  let jpeg = ImageProcessing.prepare(data, maxSide: 1600), let image = UIImage(data: jpeg) else { continue }
            model.photos.append(image)
        }
        model.photosChanged()
    }

    private func loadThumbs() async {
        guard model.kind == .video, let url = model.baseURL, model.baseDuration > 0 else { thumbs = []; return }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        var out: [UIImage] = []
        let count = 8
        for i in 0..<count {
            let t = model.baseDuration * (Double(i) + 0.5) / Double(count)
            if let r = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) { out.append(UIImage(cgImage: r.image)) }
        }
        thumbs = out
    }
}
