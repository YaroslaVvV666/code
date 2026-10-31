import SwiftUI
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
        .sheet(item: $editingText) { item in
            StickerTextEditor(item: item) { updated in
                if let i = texts.firstIndex(where: { $0.id == updated.id }) {
                    if updated.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { texts.remove(at: i) }
                    else { texts[i] = updated }
                }
                editingText = nil
            }
            .presentationBackground(.black)
        }
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
            ZStack {
                if let base {
                    Image(uiImage: base).resizable().scaledToFill()
                        .frame(width: side, height: side).clipped()
                        .brightness(brightness).contrast(contrast).saturation(saturation)
                } else {
                    ProgressView().tint(.white)
                }
                // наклейки и текст
                ForEach(stickers) { st in
                    ReelStickerView(item: st, unit: side)
                        .rotationEffect(.radians(st.rotation))
                        .position(x: st.cx * side, y: st.cy * side)
                        .overlay(selectionRing(selected == st.id, side: side * 0.42 * st.scale))
                        .gesture(overlayDrag(id: st.id, side: side, isText: false))
                        .onTapGesture { selected = st.id }
                }
                ForEach(texts) { t in
                    ReelTextView(item: t, unit: side)
                        .rotationEffect(.radians(t.rotation))
                        .position(x: t.cx * side, y: t.cy * side)
                        .gesture(overlayDrag(id: t.id, side: side, isText: true))
                        .onTapGesture { editingText = t }
                }
                // рисование — поверх, ловит касания только во вкладке «Рисунок»
                DrawingCanvas(controller: draw, active: tool == .draw)
                    .frame(width: side, height: side)
                    .allowsHitTesting(tool == .draw)
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { stageSize = CGSize(width: side, height: side) }
            .onChange(of: side) { _, v in stageSize = CGSize(width: v, height: v) }
        }
    }

    private func selectionRing(_ on: Bool, side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            .foregroundStyle(.white.opacity(on ? 0.9 : 0)).frame(width: side + 14, height: side + 14)
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

    private var segmented: some View {
        HStack(spacing: 2) {
            seg(.draw, s.t("Рисунок", "Draw"))
            seg(.stickers, s.t("Стикеры", "Stickers"))
            seg(.text, s.t("Текст", "Text"))
            seg(.adjust, s.t("Свет", "Adjust"))
        }
        .padding(3).background(.white.opacity(0.1), in: Capsule())
    }

    private func seg(_ t: Tool, _ title: String) -> some View {
        Button { tool = t; selected = nil } label: {
            Text(title).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tool == t ? .black : .white)
                .padding(.horizontal, 12).frame(height: 32)
                .background(tool == t ? AnyShapeStyle(.white) : AnyShapeStyle(.clear), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var toolPanel: some View {
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

    // MARK: Жесты наклеек/текста

    private func overlayDrag(id: UUID, side: CGFloat, isText: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                selected = id
                let dx = v.translation.width / side, dy = v.translation.height / side
                move(id: id, isText: isText, dx: dx, dy: dy)
            }
            .onEnded { _ in dragStart[id] = nil }
    }

    @State private var dragStart: [UUID: (Double, Double)] = [:]
    private func move(id: UUID, isText: Bool, dx: Double, dy: Double) {
        if isText, let i = texts.firstIndex(where: { $0.id == id }) {
            let start = dragStart[id] ?? (texts[i].cx, texts[i].cy)
            dragStart[id] = start
            texts[i].cx = min(1, max(0, start.0 + dx)); texts[i].cy = min(1, max(0, start.1 + dy))
        } else if let i = stickers.firstIndex(where: { $0.id == id }) {
            let start = dragStart[id] ?? (stickers[i].cx, stickers[i].cy)
            dragStart[id] = start
            stickers[i].cx = min(1, max(0, start.0 + dx)); stickers[i].cy = min(1, max(0, start.1 + dy))
        }
    }

    // MARK: Действия

    private func addText() {
        let t = ReelText(text: "")
        editingText = t
        texts.append(t)
    }

    private func addSticker(_ st: Sticker) {
        Task {
            guard let img = await stickerUIImage(st) else { return }
            stickers.append(ReelSticker(image: img))
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
        // сбрасываем «накопитель» перетаскивания
        dragStart = [:]
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

// MARK: - Ввод текста

private struct StickerTextEditor: View {
    @State var item: ReelText
    var onDone: (ReelText) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea().onTapGesture { onDone(item) }
            VStack(spacing: 18) {
                HStack {
                    Spacer()
                    Button { onDone(item) } label: {
                        Text("Готово").font(.system(size: 16, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 18).frame(height: 40).background(.white, in: Capsule())
                    }
                }
                .padding(.horizontal, 16).padding(.top, 16)
                Spacer()
                TextField("", text: $item.text, axis: .vertical)
                    .focused($focused)
                    .font(.system(size: 34, weight: .bold, design: ReelPalette.design(item.font)))
                    .multilineTextAlignment(.center).tint(.white)
                    .foregroundStyle(ReelPalette.color(item.color))
                    .padding(.horizontal, 24).lineLimit(1...6)
                Spacer()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(0..<ReelPalette.colors.count, id: \.self) { i in
                            Button { item.color = i } label: {
                                Circle().fill(ReelPalette.colors[i]).frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(.white, lineWidth: item.color == i ? 3 : 1).opacity(item.color == i ? 1 : 0.4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 12)
            }
        }
        .onAppear { focused = true }
    }
}
