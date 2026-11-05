import SwiftUI
import Combine
import PencilKit
import PhotosUI
import CoreImage.CIFilterBuiltins

// MARK: - Холст рисования (PencilKit)

@MainActor
final class DrawController: ObservableObject {
    let canvas = PKCanvasView()
    @Published var color: UIColor = .white
    @Published var width: CGFloat = 10
    @Published var isEraser = false

    func applyTool() {
        canvas.tool = isEraser ? PKEraserTool(.bitmap) : PKInkingTool(.pen, color: color, width: width)
    }
    func undo() { canvas.undoManager?.undo() }
    func clear() { canvas.drawing = PKDrawing() }
    var hasStrokes: Bool { !canvas.drawing.strokes.isEmpty }

    /// Картинка штрихов в заданном прямоугольнике (в точках холста)
    func strokesImage(bounds: CGRect) -> UIImage {
        canvas.drawing.image(from: bounds, scale: UIScreen.main.scale)
    }
}

private struct DrawingCanvas: UIViewRepresentable {
    @ObservedObject var controller: DrawController
    let active: Bool

    func makeUIView(context: Context) -> PKCanvasView {
        let c = controller.canvas
        c.backgroundColor = .clear
        c.isOpaque = false
        c.drawingPolicy = .anyInput
        c.tool = PKInkingTool(.pen, color: controller.color, width: controller.width)
        return c
    }

    func updateUIView(_ c: PKCanvasView, context: Context) {
        c.isUserInteractionEnabled = active
        controller.applyTool()
    }
}

// MARK: - Редактор стикера (рисование, текст, наклейки, яркость/контраст)

struct StickerEditorView: View {
    let sticker: Sticker
    let packID: String
    let repo: MessengerRepository
    let packs: [StickerPack]            // для вкладки «Стикеры» — что можно наклеить
    var onSaved: () -> Void = {}
    var onClose: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    private enum Tool { case draw, text, stickers, adjust }

    @StateObject private var draw = DrawController()
    @State private var base: UIImage?
    @State private var tool: Tool = .draw
    @State private var texts: [ReelText] = []
    @State private var stickers: [ReelSticker] = []
    @State private var selected: UUID?
    @State private var editingText: ReelText?
    @State private var stageSize: CGSize = .zero
    @State private var dragging = false              // тащат текст/наклейку — внизу видна корзина
    @State private var overTrash = false

    // настройки
    @State private var brightness: Double = 0       // -0.4…0.4
    @State private var contrast: Double = 1          // 0.6…1.6
    @State private var saturation: Double = 1        // 0…2

    @State private var saving = false
    @State private var note: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                stage
                bottomBar
            }
        }
        .task { await loadBase() }
        // ввод текста — прямо поверх стикера (как в шортсах): стикер виден под затемнением
        .overlay {
            if editingText != nil {
                ReelTextEditor(item: Binding(get: { editingText ?? ReelText(text: "") }, set: { editingText = $0 })) { commitText() }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: editingText == nil)
        .overlay(alignment: .top) {
            if let note {
                Text(note).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 40).background(.ultraThinMaterial, in: Capsule()).padding(.top, 60)
            }
        }
    }

    // MARK: Верх

    private var topBar: some View {
        HStack {
            if tool == .draw && (draw.hasStrokes) {
                circleButton("arrow.uturn.backward") { draw.undo() }
            } else {
                Color.clear.frame(width: 40, height: 40)
            }
            Spacer()
            if tool == .draw && draw.hasStrokes {
                Button { draw.clear() } label: {
                    Text(s.t("Очистить всё", "Clear all")).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).frame(height: 40).background(.white.opacity(0.14), in: Capsule())
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).frame(height: 56)
    }

    // MARK: Сцена

    private var stage: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let size = CGSize(width: side, height: side)
            ZStack {
                Group {
                    if let base {
                        Image(uiImage: base).resizable().scaledToFill()
                            .frame(width: side, height: side).clipped()
                            .brightness(brightness).contrast(contrast).saturation(saturation)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(width: side, height: side)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selected = nil } }

                // наклейки и текст: тащить пальцем, щипком — размер, двумя пальцами — наклон (как в шортсах)
                ForEach($stickers) { $st in
                    ReelDraggable(cx: $st.cx, cy: $st.cy, scale: $st.scale, rotation: $st.rotation, size: size,
                                  onTap: { select(st.id) },
                                  onDragging: { cy in dragMoved(st.id, cy) },
                                  onEnd: { cy in dragEnded(st.id, cy) }) {
                        ReelStickerView(item: st, unit: side).overlay { outline(selected == st.id) }
                    }
                }
                ForEach($texts) { $t in
                    if editingText?.id != t.id {
                        ReelDraggable(cx: $t.cx, cy: $t.cy, scale: $t.scale, rotation: $t.rotation, size: size,
                                      onTap: { if selected == t.id { editingText = t } else { select(t.id) } },
                                      onDragging: { cy in dragMoved(t.id, cy) },
                                      onEnd: { cy in dragEnded(t.id, cy) }) {
                            ReelTextView(item: t, unit: side).overlay { outline(selected == t.id) }
                        }
                    }
                }
                // рисование — поверх, ловит касания только во вкладке «Рисунок»
                DrawingCanvas(controller: draw, active: tool == .draw)
                    .frame(width: side, height: side)
                    .allowsHitTesting(tool == .draw)

                // корзина: перетащите сюда текст или наклейку, чтобы удалить
                if dragging {
                    Image(systemName: "trash.fill")
                        .font(.system(size: overTrash ? 22 : 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: overTrash ? 58 : 48, height: overTrash ? 58 : 48)
                        .background(overTrash ? Color.red : Color.black.opacity(0.5), in: Circle())
                        .position(x: side / 2, y: side - 40)
                        .allowsHitTesting(false)
                        .transition(.scale.combined(with: .opacity))
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: overTrash)
                }
            }
            .frame(width: side, height: side)
            .coordinateSpace(name: "reelStage")
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.15), value: dragging)
            .onAppear { stageSize = size }
            .onChange(of: side) { _, v in stageSize = CGSize(width: v, height: v) }
        }
    }

    private func outline(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(.white)
            .padding(-6)
            .opacity(on ? 0.95 : 0)
            .allowsHitTesting(false)
    }

    private func select(_ id: UUID) {
        if selected != id { Haptics.select() }
        withAnimation(.easeOut(duration: 0.15)) { selected = id }
    }

    private func dragMoved(_ id: UUID, _ cy: Double) {
        if !dragging { dragging = true }
        let over = cy > 0.86
        if over != overTrash { overTrash = over; if over { Haptics.impact(.light) } }
        if selected != id { selected = id }
    }

    private func dragEnded(_ id: UUID, _ cy: Double) {
        dragging = false
        overTrash = false
        if cy > 0.86 { removeItem(id); Haptics.impact(.medium) }
    }

    private func removeItem(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.2)) {
            texts.removeAll { $0.id == id }
            stickers.removeAll { $0.id == id }
            if selected == id { selected = nil }
        }
    }

    // MARK: Низ — инструменты

    private var bottomBar: some View {
        VStack(spacing: 10) {
            toolPanel
            HStack(spacing: 10) {
                circleButton("xmark") { onClose() }
                Spacer()
                segmented
                Spacer()
                Button { save() } label: {
                    Group { if saving { ProgressView().tint(.white) } else { Image(systemName: "checkmark").font(.system(size: 18, weight: .bold)) } }
                        .foregroundStyle(.white).frame(width: 46, height: 46).background(theme.accentColor, in: Circle())
                }
                .disabled(saving || base == nil)
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }

    /// Панель инструментов — значки, как в Telegram: рисунок, текст, стикер, настройка света
    private var segmented: some View {
        HStack(spacing: 0) {
            seg(.draw, s.t("Рисунок", "Draw")) {
                Image(systemName: "pencil.tip.crop.circle").font(.system(size: 27, weight: .regular))
            }
            seg(.text, s.t("Текст", "Text")) {
                ToolPlusGlyph { Image(systemName: "character.textbox").font(.system(size: 23, weight: .regular)) }
            }
            seg(.stickers, s.t("Стикеры", "Stickers")) {
                ToolPlusGlyph { Image(systemName: "face.smiling").font(.system(size: 23, weight: .regular)) }
            }
            seg(.adjust, s.t("Свет", "Adjust")) {
                AdjustGlyph()
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 56)
        .background(Color(white: 0.11), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private func seg<G: View>(_ t: Tool, _ title: String, @ViewBuilder _ glyph: () -> G) -> some View {
        Button {
            Haptics.select()
            withAnimation(.easeOut(duration: 0.15)) { tool = t; selected = nil }
            if t == .text && texts.isEmpty { addText() }          // сразу — ввод текста поверх стикера
        } label: {
            glyph()
                .foregroundStyle(tool == t ? Color.white : Color.white.opacity(0.45))
                .frame(width: 52, height: 44)
                .background {
                    if tool == t { Capsule().fill(.white.opacity(0.12)) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var toolPanel: some View {
        VStack(spacing: 10) {
            if let id = selected, tool != .draw, texts.contains(where: { $0.id == id }) || stickers.contains(where: { $0.id == id }) {
                selectionControls(id)
            }
            toolOptions
        }
        .animation(.easeOut(duration: 0.18), value: selected)
    }

    /// Выбран текст или наклейка: размер, наклон, изменить текст, удалить
    private func selectionControls(_ id: UUID) -> some View {
        let isText = texts.contains { $0.id == id }
        return HStack(spacing: 10) {
            controlButton("minus.magnifyingglass") { adjust(id, scale: -0.12) }
            controlButton("plus.magnifyingglass") { adjust(id, scale: 0.12) }
            controlButton("rotate.left") { adjust(id, rotation: -.pi / 12) }
            controlButton("rotate.right") { adjust(id, rotation: .pi / 12) }
            if isText, let t = texts.first(where: { $0.id == id }) {
                controlButton("character.cursor.ibeam") { editingText = t }
            }
            controlButton("trash", tint: .red) { removeItem(id); Haptics.impact(.medium) }
        }
        .padding(.horizontal, 16)
        .transition(.opacity)
    }

    private func controlButton(_ icon: String, tint: Color = .white, _ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            action()
        } label: {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 46, height: 40).background(.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func adjust(_ id: UUID, scale: Double = 0, rotation: Double = 0) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            if let i = texts.firstIndex(where: { $0.id == id }) {
                texts[i].scale = min(4, max(0.3, texts[i].scale + scale))
                texts[i].rotation += rotation
            } else if let i = stickers.firstIndex(where: { $0.id == id }) {
                stickers[i].scale = min(4, max(0.3, stickers[i].scale + scale))
                stickers[i].rotation += rotation
            }
        }
    }

    @ViewBuilder private var toolOptions: some View {
        switch tool {
        case .draw:     drawPanel
        case .text:     addRow(s.t("Добавить текст", "Add text"), "textformat") { addText() }
        case .stickers: stickerPanel
        case .adjust:   adjustPanel
        }
    }

    private var drawPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Button { draw.isEraser = false } label: {
                    Image(systemName: "pencil.tip").font(.system(size: 18)).foregroundStyle(draw.isEraser ? .white.opacity(0.5) : .white)
                        .frame(width: 40, height: 36).background(draw.isEraser ? Color.clear : .white.opacity(0.15), in: Capsule())
                }
                Button { draw.isEraser = true } label: {
                    Image(systemName: "eraser").font(.system(size: 18)).foregroundStyle(draw.isEraser ? .white : .white.opacity(0.5))
                        .frame(width: 40, height: 36).background(draw.isEraser ? .white.opacity(0.15) : Color.clear, in: Capsule())
                }
                Slider(value: $draw.width, in: 3...40).tint(.white).frame(maxWidth: 140)
            }
            colorRow { draw.color = UIColor($0); draw.isEraser = false }
        }
        .padding(.horizontal, 16)
    }

    private var stickerPanel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(packs.flatMap { $0.stickers }.prefix(40)) { st in
                    Button { addSticker(st) } label: {
                        StickerImage(sticker: st, size: 52)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 64)
    }

    private var adjustPanel: some View {
        VStack(spacing: 8) {
            slider(s.t("Яркость", "Brightness"), $brightness, -0.4, 0.4)
            slider(s.t("Контраст", "Contrast"), $contrast, 0.6, 1.6)
            slider(s.t("Насыщенность", "Saturation"), $saturation, 0, 2)
        }
        .padding(.horizontal, 20)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ lo: Double, _ hi: Double) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).frame(width: 96, alignment: .leading)
            Slider(value: value, in: lo...hi).tint(.white)
        }
    }

    private func addRow(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 44).background(.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain).padding(.horizontal, 16)
    }

    private func colorRow(_ pick: @escaping (Color) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(0..<ReelPalette.colors.count, id: \.self) { i in
                    Button { pick(ReelPalette.colors[i]) } label: {
                        Circle().fill(ReelPalette.colors[i]).frame(width: 28, height: 28)
                            .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 40)
    }

    private func circleButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(.white.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Действия

    private func addText() {
        var t = ReelText(text: "")
        t.cy = 0.5
        texts.append(t)
        selected = t.id
        editingText = t
    }

    /// Готово в редакторе текста: пустой текст убираем, иначе он остаётся на стикере выбранным
    private func commitText() {
        guard let e = editingText else { return }
        let trimmed = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = texts.firstIndex(where: { $0.id == e.id }) {
            if trimmed.isEmpty { texts.remove(at: i); if selected == e.id { selected = nil } }
            else { var v = e; v.text = trimmed; texts[i] = v; selected = e.id }
        }
        editingText = nil
    }

    private func addSticker(_ st: Sticker) {
        Task {
            guard let img = await stickerUIImage(st) else { return }
            let item = ReelSticker(image: img)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { stickers.append(item) }
            selected = item.id
            Haptics.impact(.light)
        }
    }

    private func loadBase() async {
        base = await stickerUIImage(sticker)
    }

    private func stickerUIImage(_ st: Sticker) async -> UIImage? {
        if let media = st.mediaID, let url = ServerConfig.mediaURL(media) {
            return await ImageCache.shared.load(url, maxPixel: 1024)
        }
        if let url = st.url {
            return await ImageCache.shared.load(url, maxPixel: 1024)
        }
        return nil
    }

    private func save() {
        guard let base, !saving else { return }
        saving = true
        selected = nil
        Task {
            let out = CGSize(width: 512, height: 512)
            let flat = render(base: base, out: out)
            guard let data = flat?.pngData() ?? flat?.jpegData(compressionQuality: 0.9),
                  let media = try? MediaPreparer.prepareImage(data),
                  let att = try? await repo.upload(.prepared(media)), let mid = att.mediaID else {
                note = s.t("Не удалось сохранить", "Couldn't save"); saving = false
                return
            }
            // заменяем: добавляем новый стикер с тем же эмодзи, старый убираем
            do {
                try await repo.addSticker(packID: packID, mediaID: mid, emoji: sticker.emoji.isEmpty ? "⭐️" : sticker.emoji)
                if sticker.id.hasPrefix("u:") || sticker.mediaID != nil {
                    try? await repo.deleteSticker(packID: packID, stickerID: sticker.id)
                }
                Haptics.notify(.success)
                onSaved(); onClose()
            } catch {
                note = s.t("Не удалось сохранить", "Couldn't save"); saving = false
            }
        }
    }

    /// Собираем всё в одну картинку: фон (с коррекцией), штрихи, наклейки и текст
    private func render(base: UIImage, out: CGSize) -> UIImage? {
        let stage = stageSize.width > 1 ? stageSize : CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: out)
        return renderer.image { _ in
            // фон — «заполнить» квадрат, с яркостью/контрастом/насыщенностью
            let adjusted = adjust(base) ?? base
            drawFill(adjusted, in: CGRect(origin: .zero, size: out))
            // штрихи рисования
            let strokes = draw.strokesImage(bounds: CGRect(origin: .zero, size: stage))
            strokes.draw(in: CGRect(origin: .zero, size: out))
            // текст и наклейки — через ImageRenderer того же холста, что и на экране
            let overlay = ImageRenderer(content: ReelOverlayCanvas(texts: texts, stickers: stickers, size: out))
            overlay.scale = 1
            overlay.uiImage?.draw(in: CGRect(origin: .zero, size: out))
        }
    }

    private func drawFill(_ image: UIImage, in rect: CGRect) {
        let k = max(rect.width / image.size.width, rect.height / image.size.height)
        let w = image.size.width * k, h = image.size.height * k
        image.draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }

    private func adjust(_ image: UIImage) -> UIImage? {
        guard brightness != 0 || contrast != 1 || saturation != 1, let ci = CIImage(image: image) else { return image }
        let f = CIFilter.colorControls()
        f.inputImage = ci
        f.brightness = Float(brightness); f.contrast = Float(contrast); f.saturation = Float(saturation)
        let ctx = CIContext()
        guard let out = f.outputImage, let cg = ctx.createCGImage(out, from: ci.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }
}

/// Значок с маленьким «+» снизу слева (добавить текст / добавить стикер)
private struct ToolPlusGlyph<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.leading, 7).padding(.bottom, 6)
            .overlay(alignment: .bottomLeading) {
                Image(systemName: "plus").font(.system(size: 12, weight: .bold))
            }
    }
}

/// Значок «настройки»: два ползунка
private struct AdjustGlyph: View {
    var body: some View {
        VStack(spacing: 7) {
            line(knob: 0.32)
            line(knob: 0.7)
        }
        .frame(width: 30, height: 24)
    }

    private func line(knob: CGFloat) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().frame(height: 2.2).frame(maxHeight: .infinity)
                Circle().fill(Color(white: 0.11)).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(lineWidth: 2.2))
                    .offset(x: g.size.width * knob - 4.5)
            }
        }
        .frame(height: 9)
    }
}
