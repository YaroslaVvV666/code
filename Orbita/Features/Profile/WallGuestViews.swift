import SwiftUI
import PhotosUI

// MARK: - Записи гостей на стене: текст, фото или рисунок от руки

struct WallGuestSection: View {
    let entries: [WallEntry]
    let canWrite: Bool
    let onCompose: () -> Void
    let onDelete: (WallEntry) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        if canWrite || !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(s.t("Записи гостей", "Guest posts"))
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.textSecondary)
                    Spacer()
                    if canWrite {
                        Button(action: onCompose) {
                            Label(s.t("Написать", "Write"), systemImage: "square.and.pencil")
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 14).frame(height: 32)
                                .background(theme.accent, in: Capsule())
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                if entries.isEmpty {
                    Text(s.t("Оставьте запись, нарисуйте что-нибудь или поделитесь фото.",
                             "Leave a note, draw something or share a photo."))
                        .font(.system(size: 14)).foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }
                ForEach(entries) { entry in
                    WallEntryRow(entry: entry, onDelete: { onDelete(entry) })
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

struct WallEntryRow: View {
    let entry: WallEntry
    let onDelete: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    private var ratio: CGFloat {
        entry.width > 0 && entry.height > 0 ? CGFloat(entry.width) / CGFloat(entry.height) : 1
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(name: entry.author.name, size: 36, avatarID: entry.author.avatarID)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(entry.author.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                    Text(ChatTime.short(entry.createdAt, lang: lang)).font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    Spacer(minLength: 0)
                    if entry.canDelete {
                        Menu {
                            Button(role: .destructive, action: onDelete) { Label(s.t("Удалить", "Delete"), systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.textTertiary).frame(width: 30, height: 24)
                        }
                    }
                }
                if !entry.text.isEmpty {
                    Text(entry.text).font(.system(size: 15)).foregroundStyle(theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let media = entry.mediaID {
                    RemoteImage(id: media, fill: false, maxPixel: 900, backdrop: entry.kind == "drawing" ? .white : nil)
                        .aspectRatio(ratio, contentMode: .fit)
                        .frame(maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(12)
        .card(theme, radius: 16)
    }
}

// MARK: - Окно записи

struct WallImage {
    let data: Data
    let mime: String
    let width: Int
    let height: Int
}

struct WallComposeSheet: View {
    let ownerName: String
    let onSend: (String, String, WallImage?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    enum Mode { case text, photo, drawing }
    @State private var mode: Mode = .text
    @State private var text = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var photo: WallImage?
    @State private var photoPreview: UIImage?
    @State private var strokes: [DrawStroke] = []
    @State private var color: Color = .black
    @State private var lineWidth: CGFloat = 6
    @State private var busy = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private var side: CGFloat { min(UIScreen.main.bounds.width - 32, 420) }

    private var canSend: Bool {
        guard !busy else { return false }
        switch mode {
        case .text:    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .photo:   return photo != nil
        case .drawing: return !strokes.isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(s.t("Запись на стене", "Wall post")).font(.system(size: 18, weight: .bold)).foregroundStyle(theme.text)
                .padding(.top, 18)
            Picker("", selection: $mode) {
                Text(s.t("Текст", "Text")).tag(Mode.text)
                Text(s.t("Фото", "Photo")).tag(Mode.photo)
                Text(s.t("Рисунок", "Drawing")).tag(Mode.drawing)
            }
            .pickerStyle(.segmented).padding(.horizontal, 16)

            ScrollView {
                VStack(spacing: 12) {
                    switch mode {
                    case .text:
                        TextField(s.t("Что хотите написать?", "What do you want to say?"), text: $text, axis: .vertical)
                            .lineLimit(4...10).focused($focused)
                            .padding(14).card(theme, radius: 14)
                    case .photo:
                        photoBlock
                        captionField
                    case .drawing:
                        drawingBlock
                        captionField
                    }
                    if let errorText {
                        Text(errorText).font(.system(size: 13)).foregroundStyle(theme.danger).multilineTextAlignment(.center)
                    }
                    Text(s.t("Фото и рисунки проверяются: контент 18+ не публикуется.", "Photos and drawings are checked: 18+ content is not published."))
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.interactively)

            Button(action: send) {
                Group {
                    if busy { ProgressView().tint(.white) }
                    else { Text(s.t("Опубликовать", "Post")).font(.system(size: 16, weight: .semibold)) }
                }
                .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 50)
                .background(theme.accent, in: Capsule())
                .opacity(canSend ? 1 : 0.45)
            }
            .buttonStyle(PressStyle()).disabled(!canSend)
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .onAppear { if mode == .text { focused = true } }
        .onChange(of: mode) { _, m in focused = m == .text; errorText = nil }
        .onChange(of: pickerItem) { _, item in loadPhoto(item) }
        .interactiveDismissDisabled(busy)
    }

    private var captionField: some View {
        TextField(s.t("Подпись (необязательно)", "Caption (optional)"), text: $text)
            .padding(.horizontal, 14).frame(height: 44).card(theme, radius: 14)
    }

    @ViewBuilder
    private var photoBlock: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            ZStack {
                if let photoPreview {
                    Image(uiImage: photoPreview).resizable().scaledToFit().frame(maxHeight: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 32, weight: .light))
                        Text(s.t("Выбрать фото", "Choose a photo")).font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(theme.textSecondary).frame(maxWidth: .infinity).frame(height: 180).card(theme, radius: 14)
                }
            }
        }
    }

    private static let palette: [Color] = [.black, .white, .red, .orange, .yellow, .green, .blue, .purple, .pink, .brown]

    @ViewBuilder
    private var drawingBlock: some View {
        DrawingPad(strokes: $strokes, color: color, lineWidth: lineWidth)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.textTertiary.opacity(0.4), lineWidth: 1))
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(Self.palette.enumerated()), id: \.offset) { _, c in
                        Circle().fill(c).frame(width: 30, height: 30)
                            .overlay(Circle().stroke(theme.textTertiary.opacity(0.5), lineWidth: 1))
                            .overlay(Circle().stroke(theme.accentColor, lineWidth: color == c ? 3 : 0).padding(-4))
                            .onTapGesture { color = c }
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 6)
            }
            HStack(spacing: 14) {
                ForEach([3, 6, 12, 22], id: \.self) { w in
                    Circle().fill(theme.text).frame(width: CGFloat(w) + 4, height: CGFloat(w) + 4)
                        .frame(width: 36, height: 36)
                        .background(lineWidth == CGFloat(w) ? theme.accentColor.opacity(0.25) : Color.clear, in: Circle())
                        .onTapGesture { lineWidth = CGFloat(w) }
                }
                Spacer()
                Button { if !strokes.isEmpty { strokes.removeLast() } } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(strokes.isEmpty ? theme.textTertiary : theme.text).frame(width: 40, height: 40)
                }
                .disabled(strokes.isEmpty)
                Button { strokes.removeAll() } label: {
                    Image(systemName: "trash").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(strokes.isEmpty ? theme.textTertiary : theme.danger).frame(width: 40, height: 40)
                }
                .disabled(strokes.isEmpty)
            }
        }
        .frame(width: side)
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let raw = try? await item.loadTransferable(type: Data.self),
                  let jpeg = ImageProcessing.prepare(raw, maxSide: 1600), let image = UIImage(data: jpeg) else {
                errorText = s.t("Не удалось открыть фото.", "Couldn't open the photo.")
                return
            }
            photo = WallImage(data: jpeg, mime: "image/jpeg", width: Int(image.size.width), height: Int(image.size.height))
            photoPreview = image
            errorText = nil
        }
    }

    private func send() {
        let caption = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var kind = "text"
        var image: WallImage?
        switch mode {
        case .text: break
        case .photo: kind = "photo"; image = photo
        case .drawing:
            kind = "drawing"
            guard let png = DrawingPad.png(strokes, side: side) else { return }
            image = WallImage(data: png, mime: "image/png", width: Int(side * 2), height: Int(side * 2))
        }
        busy = true; errorText = nil; focused = false
        Task {
            do {
                try await onSend(kind, caption, image)
                dismiss()
            } catch {
                errorText = s.api((error as? APIError) ?? .offline)
                busy = false
            }
        }
    }
}

// MARK: - Рисование пальцем

struct DrawStroke: Identifiable {
    let id = UUID()
    var points: [CGPoint]
    var color: Color
    var width: CGFloat
}

struct DrawingPad: View {
    @Binding var strokes: [DrawStroke]
    let color: Color
    let lineWidth: CGFloat
    @State private var current: DrawStroke?

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            Self.draw(strokes + (current.map { [$0] } ?? []), in: &ctx)
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in
                    if current == nil { current = DrawStroke(points: [v.location], color: color, width: lineWidth) }
                    else { current?.points.append(v.location) }
                }
                .onEnded { _ in
                    if let c = current { strokes.append(c) }
                    current = nil
                }
        )
    }

    static func draw(_ list: [DrawStroke], in ctx: inout GraphicsContext) {
        for st in list {
            guard let first = st.points.first else { continue }
            if st.points.count == 1 {
                let r = st.width / 2
                ctx.fill(Path(ellipseIn: CGRect(x: first.x - r, y: first.y - r, width: st.width, height: st.width)), with: .color(st.color))
                continue
            }
            var path = Path()
            path.move(to: first)
            for i in 1..<st.points.count {
                let a = st.points[i - 1], b = st.points[i]
                path.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
            }
            if let last = st.points.last { path.addLine(to: last) }
            ctx.stroke(path, with: .color(st.color), style: StrokeStyle(lineWidth: st.width, lineCap: .round, lineJoin: .round))
        }
    }

    /// Готовый PNG рисунка на белом фоне (×2 для чёткости)
    @MainActor
    static func png(_ strokes: [DrawStroke], side: CGFloat) -> Data? {
        let content = Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            draw(strokes, in: &ctx)
        }
        .frame(width: side, height: side)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return renderer.uiImage?.pngData()
    }
}
