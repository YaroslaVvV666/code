import SwiftUI
import PhotosUI

// MARK: - Записи гостей на стене: текст, фото или рисунок от руки

struct WallGuestSection: View {
    let entries: [WallEntry]
    let canWrite: Bool
    /// Отвечать на записи могут все, кому можно писать на эту стену (и сам владелец)
    var canReply = false
    let onCompose: () -> Void
    let onDelete: (WallEntry) -> Void
    var onReply: (WallEntry) -> Void = { _ in }
    var onReact: (WallEntry, String) -> Void = { _, _ in }
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
                    WallEntryRow(entry: entry, canReply: canReply, onDelete: { onDelete(entry) },
                                 onReply: { onReply(entry) }, onReact: { onReact(entry, $0) })
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// Запись на стене — как сообщение в чате: цитата, если это ответ; реакции под записью;
/// двойной тап — ❤️, свайп влево — ответить, «😊» — выбрать реакцию
struct WallEntryRow: View {
    let entry: WallEntry
    var canReply = false
    let onDelete: () -> Void
    var onReply: () -> Void = {}
    var onReact: (String) -> Void = { _ in }
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var picking = false               // открыт ряд эмодзи для реакции
    @State private var expandedReactions = false     // раскрыт полный список (как в чате)
    @State private var dragX: CGFloat = 0
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
                    Menu {
                        if canReply {
                            Button(action: onReply) { Label(s.t("Ответить", "Reply"), systemImage: "arrowshape.turn.up.left") }
                        }
                        if !entry.text.isEmpty {
                            Button { UIPasteboard.general.string = entry.text } label: { Label(s.copy, systemImage: "doc.on.doc") }
                        }
                        if entry.canDelete {
                            Button(role: .destructive, action: onDelete) { Label(s.t("Удалить", "Delete"), systemImage: "trash") }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.textTertiary).frame(width: 30, height: 24)
                    }
                }
                if let reply = entry.reply { quote(reply) }
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
                footer
                if picking { emojiStrip.transition(.scale(scale: 0.8, anchor: .topLeading).combined(with: .opacity)) }
            }
        }
        .padding(12)
        .card(theme, radius: 16)
        .offset(x: dragX)
        .overlay(alignment: .trailing) {
            // свайп влево — ответить, как в чате
            Image(systemName: "arrowshape.turn.up.left.circle.fill")
                .font(.system(size: 24)).foregroundStyle(theme.accentColor)
                .opacity(Double(min(1, -dragX / 56)))
                .scaleEffect(min(1, -dragX / 56))
                .offset(x: 30)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { onReact("\u{2764}\u{FE0F}") })
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { v in
                    guard canReply, abs(v.translation.width) > abs(v.translation.height) * 1.6 else { return }
                    dragX = max(-80, min(0, v.translation.width))
                }
                .onEnded { _ in
                    if dragX <= -56 { Haptics.impact(.medium); onReply() }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragX = 0 }
                }
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: picking)
    }

    /// Цитата записи, на которую отвечают — полоска слева и имя, как в чате
    private func quote(_ reply: WallReply) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(theme.accentColor).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(reply.authorName).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accentColor).lineLimit(1)
                Text(reply.text.isEmpty ? (reply.kind == "drawing" ? s.t("Рисунок", "Drawing") : s.t("Фото", "Photo")) : reply.text)
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(theme.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Реакции, «😊» и «Ответить»
    private var footer: some View {
        HStack(spacing: 6) {
            ForEach(entry.reactions, id: \.emoji) { r in
                Button { onReact(r.emoji) } label: {
                    HStack(spacing: 4) {
                        AnimatedReactionEmoji(emoji: r.emoji, mine: r.mine, count: r.count)
                        Text("\(r.count)").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(r.mine ? Color.white : theme.text)
                    }
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(r.mine ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.accentColor.opacity(0.1)), in: Capsule())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
            Button { Haptics.select(); picking.toggle(); if !picking { expandedReactions = false } } label: {
                Image(systemName: picking ? "xmark" : "face.smiling")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.textSecondary)
                    .frame(width: 30, height: 26)
                    .background(theme.accentColor.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            if canReply {
                Button(action: onReply) {
                    Text(s.t("Ответить", "Reply")).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accentColor)
                        .padding(.horizontal, 6).frame(height: 26)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: entry.reactions)
    }

    private func react(_ e: String) {
        onReact(e)
        picking = false
        expandedReactions = false
    }

    private func reactButton(_ e: String) -> some View {
        Button { react(e) } label: {
            LottieEmojiView(emoji: e, size: 30, playing: false).frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
    }

    /// Как в чате: строчка главных реакций + кнопка раскрытия полного списка
    private var emojiStrip: some View {
        Group {
            if expandedReactions {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) { ForEach(AnimatedEmoji.all, id: \.self) { reactButton($0) } }
                        .padding(.horizontal, 6).padding(.vertical, 4)
                }
                .frame(height: 44)
            } else {
                HStack(spacing: 2) {
                    ForEach(Array(AnimatedEmoji.popular.prefix(6)), id: \.self) { reactButton($0) }
                    Button {
                        Haptics.impact(.light)
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expandedReactions = true }
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.textSecondary).frame(width: 34, height: 36)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
            }
        }
        .background(theme.accentColor.opacity(0.08), in: Capsule())
        .clipShape(Capsule())
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
    /// Ответ на запись: её цитата показывается сверху
    var replyTo: WallEntry? = nil
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
            Text(replyTo == nil ? s.t("Запись на стене", "Wall post") : s.t("Ответ", "Reply"))
                .font(.system(size: 18, weight: .bold)).foregroundStyle(theme.text)
                .padding(.top, 18)
            if let replyTo {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5).fill(theme.accentColor).frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(replyTo.author.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accentColor)
                        Text(replyTo.text.isEmpty ? s.t("Фото", "Photo") : replyTo.text)
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(theme.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
            }
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
                    Text(s.t("Все записи должны соответствовать правилам сообщества.", "All posts must follow the community guidelines."))
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
