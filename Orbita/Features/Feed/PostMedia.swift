import SwiftUI
import Photos
import AVKit
import AVFoundation

// MARK: - Загрузка картинок с сервера

struct RemoteImage: View {
    let id: String
    var fill = true
    var maxPixel: CGFloat = 1280
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.surface
            CachedImage(url: ServerConfig.mediaURL(id), maxPixel: maxPixel) { image, failed in
                if let image {
                    if fill { Image(uiImage: image).resizable().scaledToFill() }
                    else { Image(uiImage: image).resizable().scaledToFit() }
                } else if failed {
                    Image(systemName: "photo").foregroundStyle(theme.textTertiary)
                } else {
                    ProgressView()
                }
            }
        }
    }
}

// MARK: - Иллюстрации (демо-посты)

struct PostArt: View {
    let kind: Int

    var body: some View {
        switch kind % 3 {
        case 0:  skyline
        case 1:  mountains
        default: cosmos
        }
    }

    private var skyline: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.33),
                                    Color(red: 0.55, green: 0.25, blue: 0.45),
                                    Color(red: 0.95, green: 0.52, blue: 0.40)],
                           startPoint: .top, endPoint: .bottom)
            Canvas { ctx, size in
                var g = SeededGenerator(seed: 7)
                let base = size.height * 0.72
                let building = Color(red: 0.07, green: 0.07, blue: 0.14)
                var x: CGFloat = 0
                var index = 0
                while x < size.width {
                    let w = CGFloat.random(in: 14...34, using: &g)
                    let h = CGFloat.random(in: 18...(size.height * 0.34), using: &g)
                    ctx.fill(Path(CGRect(x: x, y: base - h, width: w, height: h)), with: .color(building))
                    if index % 5 == 0 {
                        ctx.fill(Path(CGRect(x: x + w / 2 - 1, y: base - h - 16, width: 2, height: 16)),
                                 with: .color(building))
                    }
                    x += w + 1
                    index += 1
                }
                ctx.fill(Path(CGRect(x: 0, y: base, width: size.width, height: size.height - base)),
                         with: .color(Color(red: 0.08, green: 0.08, blue: 0.16)))
            }
        }
    }

    private var mountains: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.55, green: 0.68, blue: 0.85),
                                    Color(red: 0.92, green: 0.86, blue: 0.82)],
                           startPoint: .top, endPoint: .bottom)
            Canvas { ctx, size in
                func ridge(_ points: [CGFloat], color: Color) {
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: size.height))
                    for (i, h) in points.enumerated() {
                        p.addLine(to: CGPoint(x: size.width * CGFloat(i) / CGFloat(points.count - 1),
                                              y: size.height * h))
                    }
                    p.addLine(to: CGPoint(x: size.width, y: size.height))
                    p.closeSubpath()
                    ctx.fill(p, with: .color(color))
                }
                ridge([0.50, 0.28, 0.46, 0.20, 0.44, 0.30, 0.52], color: Color(red: 0.45, green: 0.55, blue: 0.72))
                ridge([0.66, 0.46, 0.62, 0.40, 0.64, 0.50, 0.68], color: Color(red: 0.30, green: 0.40, blue: 0.58))
                ridge([0.82, 0.68, 0.80, 0.62, 0.82, 0.70, 0.84], color: Color(red: 0.16, green: 0.24, blue: 0.40))
            }
        }
    }

    private var cosmos: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.14),
                                    Color(red: 0.14, green: 0.12, blue: 0.30)],
                           startPoint: .top, endPoint: .bottom)
            Canvas { ctx, size in
                var g = SeededGenerator(seed: 11)
                for _ in 0..<60 {
                    let x = CGFloat.random(in: 0...size.width, using: &g)
                    let y = CGFloat.random(in: 0...size.height, using: &g)
                    let r = CGFloat.random(in: 0.4...1.3, using: &g)
                    ctx.opacity = Double.random(in: 0.3...0.9, using: &g)
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)), with: .color(.white))
                }
            }
            OrbitLogo(size: 110, forceDarkTheme: true)
        }
    }
}

// MARK: - Одна ячейка медиа

struct MediaCell: View {
    let item: MediaItem

    var body: some View {
        ZStack {
            switch item.kind {
            case .art:
                PostArt(kind: item.artIndex)
            case .image:
                RemoteImage(id: item.id)
            case .video:
                if let thumb = item.thumbID { RemoteImage(id: thumb) } else { Color.black }
                Color.black.opacity(0.18)
                Image(systemName: "play.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.white)
                    .frame(width: 46, height: 46)
                    .background(Color.black.opacity(0.5), in: Circle())
            }
        }
        .overlay(alignment: .bottomLeading) {
            if item.kind == .video, let duration = item.duration {
                Text(mmss(Int(duration.rounded())))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(8)
            }
        }
    }
}

// MARK: - Сетка: размер зависит от формата и количества

struct MediaGrid: View {
    let media: [MediaItem]
    let autoplay: Bool
    let onOpen: (Int) -> Void

    private let gap: CGFloat = 2

    var body: some View {
        switch media.count {
        case 0:  EmptyView()
        case 1:  single
        case 2:  twoUp
        case 3:  threeUp
        default: grid
        }
    }

    /// Один файл: высота подстраивается под кадр (от 4:5 до 16:9)
    private var single: some View {
        let item = media[0]
        let ratio = min(max(item.aspect, 0.8), 1.78)
        return Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .overlay {
                ZStack {
                    if item.kind == .video && autoplay {
                        InlineVideo(item: item)
                    } else {
                        MediaCell(item: item)
                    }
                    Color.clear.contentShape(Rectangle()).onTapGesture { onOpen(0) }
                }
            }
            .clipped()
    }

    private var twoUp: some View {
        GeometryReader { g in
            let w = (g.size.width - gap) / 2
            HStack(spacing: gap) {
                cell(0, width: w, height: g.size.height)
                cell(1, width: w, height: g.size.height)
            }
        }
        .aspectRatio(1.7, contentMode: .fit)
    }

    private var threeUp: some View {
        GeometryReader { g in
            let left = g.size.width * 0.62
            let right = g.size.width - left - gap
            let half = (g.size.height - gap) / 2
            HStack(spacing: gap) {
                cell(0, width: left, height: g.size.height)
                VStack(spacing: gap) {
                    cell(1, width: right, height: half)
                    cell(2, width: right, height: half)
                }
            }
        }
        .aspectRatio(1.25, contentMode: .fit)
    }

    private var grid: some View {
        GeometryReader { g in
            let w = (g.size.width - gap) / 2
            let h = (g.size.height - gap) / 2
            VStack(spacing: gap) {
                HStack(spacing: gap) { cell(0, width: w, height: h); cell(1, width: w, height: h) }
                HStack(spacing: gap) {
                    cell(2, width: w, height: h)
                    cell(3, width: w, height: h)
                        .overlay {
                            if media.count > 4 {
                                Color.black.opacity(0.5)
                                Text("+\(media.count - 4)")
                                    .font(.system(size: 26, weight: .semibold))
                                    .foregroundStyle(Color.white)
                            }
                        }
                }
            }
        }
        .aspectRatio(1.0, contentMode: .fit)
    }

    private func cell(_ index: Int, width: CGFloat, height: CGFloat) -> some View {
        MediaCell(item: media[index])
            .frame(width: width, height: height)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { onOpen(index) }
    }
}

// MARK: - Видео

/// Беззвучное зацикленное видео прямо в ленте (настройка «Автовоспроизведение»)
struct InlineVideo: View {
    let item: MediaItem
    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?
    @State private var statusObserver: NSKeyValueObservation?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player).allowsHitTesting(false)
            } else {
                MediaCell(item: item)
            }
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private func start() {
        guard player == nil, let url = ServerConfig.mediaURL(item.id) else { return }
        let newPlayer = AVPlayer(url: url)
        newPlayer.isMuted = true
        newPlayer.volume = 0
        newPlayer.preventsDisplaySleepDuringVideoPlayback = false
        // звуковые дорожки отключаем совсем: автовоспроизведение полностью беззвучное и не перебивает музыку и голосовые
        if let item = newPlayer.currentItem {
            statusObserver = item.observe(\.status, options: [.initial, .new]) { item, _ in
                guard item.status == .readyToPlay else { return }
                for track in item.tracks where track.assetTrack?.mediaType == .audio { track.isEnabled = false }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: newPlayer.currentItem, queue: .main
        ) { [weak newPlayer] _ in
            newPlayer?.seek(to: .zero)
            newPlayer?.play()
        }
        newPlayer.play()
        player = newPlayer
    }

    private func stop() {
        player?.pause()
        player = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
    }
}

private struct ViewerVideo: View {
    let item: MediaItem
    @State private var player: AVPlayer?
    @Environment(\.lang) private var lang

    var body: some View {
        ZStack {
            if CallGate.busy {
                Text(CallGate.message(lang)).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).padding(30)
            } else if let player { VideoPlayer(player: player) }
        }
        .onAppear {
            guard player == nil, !CallGate.busy, let url = ServerConfig.mediaURL(item.id) else { return }
            let newPlayer = AVPlayer(url: url)
            newPlayer.play()
            player = newPlayer
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

// MARK: - Просмотр на весь экран

struct ViewerRoute: Identifiable {
    let id = UUID()
    let index: Int
}

/// Кто прислал, когда и с какой подписью — для просмотра из переписки (как в Telegram)
struct MediaMeta: Equatable {
    var title: String
    var subtitle: String
    var text: String = ""
}

struct MediaViewer: View {
    let media: [MediaItem]
    /// Данные по каждому файлу. Если есть — сверху имя и время вместо счётчика, внизу подпись к фото.
    /// Счётчик «3 из 12» остаётся для просмотра из профиля (вкладка «Медиа»).
    var meta: [MediaMeta] = []
    @State private var index: Int
    @State private var toast: String?
    @State private var saving = false
    @State private var chrome = true
    /// Режим «герой»: фон рисует хозяин, шапка и низ вылетают отдельно, закрытие делает хозяин
    var embedded = false
    var pagesVisible = true
    var flyIn = true
    var onClose: (() -> Void)?
    var onIndex: ((Int) -> Void)?
    @Environment(\.dismiss) private var dismiss

    init(media: [MediaItem], start: Int, meta: [MediaMeta] = [], embedded: Bool = false, pagesVisible: Bool = true,
         flyIn: Bool = true, onClose: (() -> Void)? = nil, onIndex: ((Int) -> Void)? = nil) {
        self.media = media
        self.meta = meta
        self.embedded = embedded
        self.pagesVisible = pagesVisible
        self.flyIn = flyIn
        self.onClose = onClose
        self.onIndex = onIndex
        _index = State(initialValue: max(0, min(start, max(media.count - 1, 0))))
    }

    private var current: MediaItem? { media.indices.contains(index) ? media[index] : nil }

    var body: some View {
        ZStack {
            if !embedded { Color.black.ignoresSafeArea() }

            TabView(selection: $index) {
                ForEach(Array(media.enumerated()), id: \.offset) { item in
                    page(item.element).tag(item.offset)
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { chrome.toggle() } }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .opacity(pagesVisible ? 1 : 0)

            if chrome {
                VStack {
                    HStack(spacing: 10) {
                        roundButton("xmark") { if let onClose { onClose() } else { dismiss() } }
                        Spacer()
                        VStack(spacing: 1) {
                            if meta.indices.contains(index) {
                                Text(meta[index].title)
                                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                Text(meta[index].subtitle)
                                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                            } else {
                                Text(media.count > 1 ? "\(index + 1) из \(media.count)" : (current?.kind == .video ? "Видео" : "Фото"))
                                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                        roundButton(saving ? "ellipsis" : "arrow.down.to.line") { Task { await save() } }
                    }
                    .padding(.horizontal, 14).padding(.top, embedded ? TopInset.value + 4 : 8)
                    .offset(y: flyIn ? 0 : -70).opacity(flyIn ? 1 : 0)
                    Spacer()
                    if meta.indices.contains(index), !meta[index].text.isEmpty {
                        Text(meta[index].text)
                            .font(.system(size: 17)).foregroundStyle(.white)
                            .multilineTextAlignment(.leading).lineLimit(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18).padding(.bottom, 6)
                            .shadow(color: .black.opacity(0.6), radius: 4)
                            .padding(.top, 24)
                            .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                            .offset(y: flyIn ? 0 : 70).opacity(flyIn ? 1 : 0)
                    }
                    HStack {
                        if let url = current.flatMap({ ServerConfig.mediaURL($0.id) }) {
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.bottom, embedded ? max(10, BottomInset.value) : 10)
                    .offset(y: flyIn ? 0 : 70).opacity(flyIn ? 1 : 0)
                }
                .transition(.opacity)
            }

            if let toast {
                VStack { Spacer(); ToastView(text: toast).padding(.bottom, 70) }
                    .allowsHitTesting(false).transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: index) { _, v in onIndex?(v) }
    }

    private func roundButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func flash(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { if toast == text { toast = nil } }
        }
    }

    /// Сохраняет текущее фото или видео в галерею
    private func save() async {
        guard let item = current, let url = ServerConfig.mediaURL(item.id), !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let (tmp, _) = try await URLSession.shared.download(from: url)
            let ext = item.kind == .video ? "mp4" : "jpg"
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("save-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: tmp, to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { flash("Разрешите доступ к фото в Настройках"); return }
            try await PHPhotoLibrary.shared().performChanges {
                if item.kind == .video {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file)
                }
            }
            Haptics.notify(.success)
            flash("Сохранено в галерею")
        } catch {
            flash("Не удалось сохранить")
        }
    }

    @ViewBuilder
    private func page(_ item: MediaItem) -> some View {
        switch item.kind {
        case .image: RemoteImage(id: item.id, fill: false)
        case .art:   PostArt(kind: item.artIndex).aspectRatio(item.aspect, contentMode: .fit)
        case .video: ViewerVideo(item: item)
        }
    }
}
