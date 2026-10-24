import SwiftUI
import UIKit

/// Редактор фото перед отправкой: рисование, текст, поворот и обрезка (как в Telegram)
struct PhotoEditorView: View {
    let image: UIImage
    let onDone: (UIImage) -> Void
    let onCancel: () -> Void

    private enum Tool { case none, draw, text }

    private struct Stroke: Identifiable {
        let id = UUID()
        var points: [CGPoint]            // 0...1 внутри картинки
        var color: Color
        var width: CGFloat               // доля ширины картинки
    }

    private struct TextItem: Identifiable {
        let id = UUID()
        var text: String
        var color: Color
        var center: CGPoint              // 0...1 внутри картинки
        var size: CGFloat                // доля ширины картинки
    }

    @State private var base: UIImage
    @State private var history: [UIImage] = []
    @State private var strokes: [Stroke] = []
    @State private var texts: [TextItem] = []
    @State private var tool: Tool = .none
    @State private var color: Color = .white
    @State private var brush: CGFloat = 0.012
    @State private var current: Stroke?
    @State private var askText = false
    @State private var draftText = ""

    private enum Handle { case tl, tr, bl, br, t, b, l, r, move }

    @State private var cropping = false
    @State private var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)     // 0...1 внутри картинки
    @State private var cropRatio: CGFloat?                                    // nil — свободная обрезка (пропорция в пикселях)
    @State private var cropStart: CGRect?
    @State private var cropHandle: Handle?

    private let palette: [Color] = [.white, .black, .red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]

    init(image: UIImage, onDone: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
        self.image = image
        self.onDone = onDone
        self.onCancel = onCancel
        _base = State(initialValue: image)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                if cropping { cropTopBar } else { topBar }
                GeometryReader { geo in
                    if cropping { cropCanvas(in: geo.size) } else { canvas(in: geo.size) }
                }
                .padding(.vertical, 8)
                if cropping { cropToolBar } else { toolBar }
            }
        }
        .preferredColorScheme(.dark)
        .alert("Текст", isPresented: $askText) {
            TextField("Введите текст", text: $draftText)
            Button("Готово") {
                let value = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    texts.append(TextItem(text: value, color: color, center: CGPoint(x: 0.5, y: 0.5), size: 0.07))
                }
                draftText = ""
            }
            Button("Отмена", role: .cancel) { draftText = "" }
        }
    }

    // MARK: Холст

    private func fitRect(in size: CGSize) -> CGRect {
        let ar = base.size.width / max(base.size.height, 1)
        var w = size.width, h = size.width / ar
        if h > size.height { h = size.height; w = h * ar }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func canvas(in size: CGSize) -> some View {
        let rect = fitRect(in: size)
        return ZStack(alignment: .topLeading) {
            Image(uiImage: base).resizable().scaledToFit()
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            Canvas { ctx, _ in
                for stroke in strokes + (current.map { [$0] } ?? []) {
                    guard stroke.points.count > 0 else { continue }
                    var path = Path()
                    let pts = stroke.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
                    path.move(to: pts[0])
                    if pts.count == 1 { path.addLine(to: CGPoint(x: pts[0].x + 0.1, y: pts[0].y)) }
                    for p in pts.dropFirst() { path.addLine(to: p) }
                    ctx.stroke(path, with: .color(stroke.color),
                               style: StrokeStyle(lineWidth: stroke.width * rect.width, lineCap: .round, lineJoin: .round))
                }
            }
            .allowsHitTesting(false)

            ForEach(texts) { item in
                Text(item.text)
                    .font(.system(size: item.size * rect.width, weight: .bold))
                    .foregroundStyle(item.color)
                    .shadow(color: .black.opacity(0.45), radius: 2)
                    .position(x: rect.minX + item.center.x * rect.width, y: rect.minY + item.center.y * rect.height)
                    .gesture(DragGesture()
                        .onChanged { v in
                            guard let i = texts.firstIndex(where: { $0.id == item.id }) else { return }
                            texts[i].center = CGPoint(x: min(1, max(0, (v.location.x - rect.minX) / rect.width)),
                                                      y: min(1, max(0, (v.location.y - rect.minY) / rect.height)))
                        })
                    .onTapGesture(count: 2) { texts.removeAll { $0.id == item.id } }
            }

            if tool == .draw {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let p = CGPoint(x: min(1, max(0, (v.location.x - rect.minX) / rect.width)),
                                            y: min(1, max(0, (v.location.y - rect.minY) / rect.height)))
                            if current == nil { current = Stroke(points: [p], color: color, width: brush) }
                            else { current?.points.append(p) }
                        }
                        .onEnded { _ in
                            if let c = current { strokes.append(c) }
                            current = nil
                        })
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    // MARK: Панели

    private var topBar: some View {
        HStack {
            Button("Отмена", action: onCancel).foregroundStyle(.white)
            Spacer()
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(strokes.isEmpty && texts.isEmpty && history.isEmpty)
                .foregroundStyle(.white)
            Spacer()
            Button("Готово") { onDone(render(base)) }.fontWeight(.semibold).foregroundStyle(.white)
        }
        .font(.system(size: 17))
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var toolBar: some View {
        VStack(spacing: 10) {
            if tool == .draw {
                HStack(spacing: 10) {
                    ForEach(palette.indices, id: \.self) { i in
                        Circle().fill(palette[i]).frame(width: 26, height: 26)
                            .overlay(Circle().stroke(Color.white, lineWidth: color == palette[i] ? 3 : 1))
                            .onTapGesture { color = palette[i] }
                    }
                }
                Slider(value: $brush, in: 0.004...0.04).tint(.white).padding(.horizontal, 28)
            } else if tool == .text {
                HStack(spacing: 10) {
                    ForEach(palette.indices, id: \.self) { i in
                        Circle().fill(palette[i]).frame(width: 26, height: 26)
                            .overlay(Circle().stroke(Color.white, lineWidth: color == palette[i] ? 3 : 1))
                            .onTapGesture { color = palette[i] }
                    }
                }
            }
            HStack(spacing: 26) {
                toolButton("pencil.tip", active: tool == .draw) { tool = tool == .draw ? .none : .draw }
                toolButton("textformat", active: tool == .text) {
                    tool = .text
                    askText = true
                }
                toolButton("rotate.right", active: false) { rotate() }
                toolButton("crop", active: false) { startCrop() }
            }
        }
        .padding(.bottom, 14).padding(.top, 4)
    }

    private func toolButton(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(active ? Color.yellow : Color.white)
                .frame(width: 44, height: 44)
        }
    }

    // MARK: Действия

    private func undo() {
        if !texts.isEmpty { texts.removeLast() }
        else if !strokes.isEmpty { strokes.removeLast() }
        else if let last = history.popLast() { base = last }
    }

    /// Вшивает нарисованное и текст в картинку (перед поворотом или обрезкой)
    private func bake() {
        guard !strokes.isEmpty || !texts.isEmpty else { return }
        history.append(base)
        base = render(base)
        strokes = []
        texts = []
    }

    private func rotate() {
        bake()
        history.append(base)
        let size = CGSize(width: base.size.height, height: base.size.width)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        base = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.cgContext.rotate(by: .pi / 2)
            base.draw(in: CGRect(x: -base.size.width / 2, y: -base.size.height / 2, width: base.size.width, height: base.size.height))
        }
    }

    // MARK: Обрезка с сеткой

    private var cropTopBar: some View {
        HStack {
            Button("Отмена") { cropping = false }.foregroundStyle(.white)
            Spacer()
            Text("Кадрирование").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            Button("Готово") { applyCrop() }.fontWeight(.semibold).foregroundStyle(.yellow)
        }
        .font(.system(size: 17))
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var cropToolBar: some View {
        let imgW = base.size.width, imgH = base.size.height
        let options: [(String, CGFloat?)] = [("Свободно", nil), ("Оригинал", imgW / max(imgH, 1)), ("1:1", 1),
                                              ("4:3", 4.0 / 3.0), ("3:4", 3.0 / 4.0), ("16:9", 16.0 / 9.0), ("9:16", 9.0 / 16.0)]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options.indices, id: \.self) { i in
                    let on = (options[i].1 == nil && cropRatio == nil) || (options[i].1 != nil && cropRatio != nil && abs(options[i].1! - cropRatio!) < 0.001)
                    Button { setRatio(options[i].1) } label: {
                        Text(options[i].0).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(on ? Color.black : Color.white)
                            .padding(.horizontal, 14).frame(height: 34)
                            .background(on ? Color.yellow : Color.white.opacity(0.14), in: Capsule())
                    }
                }
                Button { rotateCrop() } label: {
                    Image(systemName: "rotate.right").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 34).background(Color.white.opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 16).padding(.top, 6)
    }

    private func startCrop() {
        bake()
        cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        cropRatio = nil
        cropping = true
    }

    private func rotateCrop() {
        rotate()
        cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        cropRatio = nil
    }

    /// k — отношение ширины к высоте в долях картинки (с учётом её пропорций)
    private func ratioK(_ ratio: CGFloat) -> CGFloat { ratio * base.size.height / max(base.size.width, 1) }

    private func setRatio(_ ratio: CGFloat?) {
        Haptics.impact(.light)
        withAnimation(.easeOut(duration: 0.2)) {
            cropRatio = ratio
            guard let ratio else { return }
            let k = ratioK(ratio)
            var nw: CGFloat = 1, nh = 1 / k
            if nh > 1 { nh = 1; nw = k }
            cropRect = CGRect(x: (1 - nw) / 2, y: (1 - nh) / 2, width: nw, height: nh)
        }
    }

    private func cropCanvas(in size: CGSize) -> some View {
        let rect = fitRect(in: size)
        let r = CGRect(x: rect.minX + cropRect.minX * rect.width, y: rect.minY + cropRect.minY * rect.height,
                       width: cropRect.width * rect.width, height: cropRect.height * rect.height)
        return ZStack(alignment: .topLeading) {
            Image(uiImage: base).resizable()
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            // затемнение вне рамки
            Path { p in
                p.addRect(rect)
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            // рамка и сетка 3×3
            Path { p in
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.45), lineWidth: 0.7)
            .allowsHitTesting(false)
            Rectangle().stroke(Color.white, lineWidth: 1.5)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
            // уголки и середины сторон
            ForEach(0..<8, id: \.self) { i in
                let pts: [CGPoint] = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                                      CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
                                      CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY),
                                      CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)]
                let corner = i < 4
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(width: corner ? 14 : (i < 6 ? 28 : 5), height: corner ? 14 : (i < 6 ? 5 : 28))
                    .position(pts[i])
                    .allowsHitTesting(false)
            }
            Color.clear.contentShape(Rectangle())
                .frame(width: size.width, height: size.height)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if cropStart == nil {
                            cropStart = cropRect
                            cropHandle = hitHandle(v.startLocation, r)
                        }
                        guard let start = cropStart, let handle = cropHandle else { return }
                        dragCrop(start: start, handle: handle,
                                 dx: v.translation.width / rect.width, dy: v.translation.height / rect.height)
                    }
                    .onEnded { _ in cropStart = nil; cropHandle = nil })
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func hitHandle(_ p: CGPoint, _ r: CGRect) -> Handle? {
        let t: CGFloat = 30
        func near(_ a: CGPoint) -> Bool { hypot(p.x - a.x, p.y - a.y) < t }
        if near(CGPoint(x: r.minX, y: r.minY)) { return .tl }
        if near(CGPoint(x: r.maxX, y: r.minY)) { return .tr }
        if near(CGPoint(x: r.minX, y: r.maxY)) { return .bl }
        if near(CGPoint(x: r.maxX, y: r.maxY)) { return .br }
        let inX = p.x > r.minX - t && p.x < r.maxX + t, inY = p.y > r.minY - t && p.y < r.maxY + t
        if abs(p.y - r.minY) < t * 0.8 && inX { return .t }
        if abs(p.y - r.maxY) < t * 0.8 && inX { return .b }
        if abs(p.x - r.minX) < t * 0.8 && inY { return .l }
        if abs(p.x - r.maxX) < t * 0.8 && inY { return .r }
        return r.contains(p) ? .move : nil
    }

    private func dragCrop(start: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat) {
        let minS: CGFloat = 0.08
        var l = start.minX, t = start.minY, rr = start.maxX, b = start.maxY
        func c(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }
        switch handle {
        case .move:
            let nx = c(start.minX + dx, 0, 1 - start.width), ny = c(start.minY + dy, 0, 1 - start.height)
            cropRect = CGRect(x: nx, y: ny, width: start.width, height: start.height)
            return
        case .tl: l = c(l + dx, 0, rr - minS); t = c(t + dy, 0, b - minS)
        case .tr: rr = c(rr + dx, l + minS, 1); t = c(t + dy, 0, b - minS)
        case .bl: l = c(l + dx, 0, rr - minS); b = c(b + dy, t + minS, 1)
        case .br: rr = c(rr + dx, l + minS, 1); b = c(b + dy, t + minS, 1)
        case .t: t = c(t + dy, 0, b - minS)
        case .b: b = c(b + dy, t + minS, 1)
        case .l: l = c(l + dx, 0, rr - minS)
        case .r: rr = c(rr + dx, l + minS, 1)
        }
        if let ratio = cropRatio {
            let k = ratioK(ratio)
            var w = rr - l, h = b - t
            switch handle {
            case .t, .b:
                w = h * k
                let mid = start.midX
                l = mid - w / 2; rr = mid + w / 2
            default:
                h = w / k
                if handle == .tl || handle == .tr || handle == .t { t = b - h }
                else if handle == .bl || handle == .br { b = t + h }
                else { let mid = start.midY; t = mid - h / 2; b = mid + h / 2 }
            }
            if l < 0 || rr > 1 || t < 0 || b > 1 || rr - l < minS || b - t < minS { return }     // упёрлись в край
        }
        cropRect = CGRect(x: l, y: t, width: rr - l, height: b - t)
    }

    private func applyCrop() {
        history.append(base)
        let w = base.size.width, h = base.size.height
        let rect = CGRect(x: cropRect.minX * w, y: cropRect.minY * h, width: cropRect.width * w, height: cropRect.height * h).integral
        guard rect.width >= 2, rect.height >= 2 else { cropping = false; return }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        base = UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            base.draw(at: CGPoint(x: -rect.minX, y: -rect.minY))
        }
        cropping = false
        Haptics.impact(.light)
    }

    private func render(_ source: UIImage) -> UIImage {
        guard !strokes.isEmpty || !texts.isEmpty else { return source }
        let size = source.size
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            source.draw(at: .zero)
            let cg = ctx.cgContext
            for stroke in strokes {
                guard let first = stroke.points.first else { continue }
                cg.setStrokeColor(UIColor(stroke.color).cgColor)
                cg.setLineWidth(stroke.width * size.width)
                cg.setLineCap(.round); cg.setLineJoin(.round)
                cg.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
                if stroke.points.count == 1 { cg.addLine(to: CGPoint(x: first.x * size.width + 0.1, y: first.y * size.height)) }
                for p in stroke.points.dropFirst() { cg.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height)) }
                cg.strokePath()
            }
            for item in texts {
                let font = UIFont.systemFont(ofSize: item.size * size.width, weight: .bold)
                let shadow = NSShadow()
                shadow.shadowColor = UIColor.black.withAlphaComponent(0.45)
                shadow.shadowBlurRadius = item.size * size.width * 0.06
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(item.color), .shadow: shadow]
                let str = NSAttributedString(string: item.text, attributes: attrs)
                let box = str.size()
                str.draw(at: CGPoint(x: item.center.x * size.width - box.width / 2, y: item.center.y * size.height - box.height / 2))
            }
        }
    }
}
