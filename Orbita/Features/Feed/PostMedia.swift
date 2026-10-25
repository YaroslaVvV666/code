import SwiftUI
import Photos
import AVKit
import AVFoundation

// MARK: - Загрузка картинок с сервера

struct RemoteImage: View {
    let id: String
    var fill = true
    var maxPixel: CGFloat = 1280
    var backdrop: Color? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            backdrop ?? theme.surface
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
    @State private var visible = false
    @State private var ready = false                // первый кадр готов — видео плавно проявляется поверх превью
    @State private var startTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            MediaCell(item: item)
            if let player {
                // лёгкий слой AVPlayerLayer вместо VideoPlayer из AVKit: тот строит целый контроллер с элементами управления
                PlayerLayerView(player: player, gravity: .resizeAspectFill)
                    .allowsHitTesting(false)
                    .opacity(ready ? 1 : 0)
                    .animation(.easeOut(duration: 0.25), value: ready)
            }
        }
        // играет только то, что сейчас на экране: в переписке все строки построены сразу, и раньше
        // одновременно декодировались все видео чата — отсюда рывки при прокрутке
        .background(GeometryReader { g in
            let f = g.frame(in: .global)
            let on = f.maxY > -60 && f.minY < UIScreen.main.bounds.height + 60 && f.height > 0
            Color.clear
                .onAppear { setVisible(on) }
                .onChange(of: on) { _, now in setVisible(now) }
        })
        .onDisappear { setVisible(false) }
    }

    private func setVisible(_ now: Bool) {
        guard now != visible else { return }
        visible = now
        startTask?.cancel()
        if now {
            // стартуем, только если видео задержалось на экране: при быстрой прокрутке плееры не создаются зря
            startTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled, visible else { return }
                start()
            }
        } else {
            stop()
        }
    }

    private func start() {
        guard player == nil, !CallGate.busy, let url = MediaFileCache.shared.playableURL(item.id) else { return }
        let newPlayer = AVPlayer(url: url)
        newPlayer.isMuted = true
        newPlayer.volume = 0
        newPlayer.preventsDisplaySleepDuringVideoPlayback = false
        // звуковые дорожки отключаем совсем: автовоспроизведение полностью беззвучное и не перебивает музыку и голосовые
        if let item = newPlayer.currentItem {
            statusObserver = item.observe(\.status, options: [.initial, .new]) { item, _ in
                guard item.status == .readyToPlay else { return }
                for track in item.tracks where track.assetTrack?.mediaType == .audio { track.isEnabled = false }
                DispatchQueue.main.async { ready = true }
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
        ready = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
    }
}

/// Полоса перемотки без ползунка: тонкая, при нажатии становится толще; тянуть можно за любую точку
private struct SeekBar: View {
    @Binding var time: Double
    let total: Double
    @Binding var pressing: Bool
    var onChange: (Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let frac = total > 0 ? min(1, max(0, time / total)) : 0
            let h: CGFloat = pressing ? 14 : 6
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28)).frame(height: h)
                Capsule().fill(Color.white).frame(width: w * frac, height: h)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: pressing)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !pressing { pressing = true; onChange(true) }
                    time = total * Double(min(1, max(0, v.location.x / w)))
                }
                .onEnded { v in
                    time = total * Double(min(1, max(0, v.location.x / w)))
                    pressing = false
                    onChange(false)
                })
        }
        .frame(height: 40)
    }
}

private struct ViewerVideo: View {
    let item: MediaItem
    var chrome = true
    var isCurrent = true
    @Binding var playing: Bool
    var onActivity: () -> Void = {}
    var bottomPad: CGFloat = max(10, BottomInset.value)       // как у кнопки «поделиться»: скорость стоит с ней на одном уровне
    @State private var player: AVPlayer?
    @State private var time: Double = 0
    @State private var total: Double = 0
    @State private var scrubbing = false
    @State private var rate: Float = 1
    @State private var observer: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var statusObserver: NSKeyValueObservation?
    /// Видео нет на телефоне и не загрузить с сервера (нет сети / кэш очищен) — кнопка «скачать», как в Telegram
    @State private var needsDownload = false
    @State private var downloadFailed = false
    @ObservedObject private var downloads = DownloadCenter.shared
    @Environment(\.lang) private var lang

    private func glass(_ size: CGFloat) -> some View {
        Circle().fill(.ultraThinMaterial).frame(width: size, height: size)
            .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
    }

    private func skip(_ icon: String, _ delta: Double) -> some View {
        Button {
            guard let player else { return }
            Haptics.impact(.light)
            let target = max(0, min(total, time + delta))
            time = target
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            onActivity()
        } label: {
            Image(systemName: icon).font(.system(size: 26, weight: .regular)).foregroundStyle(.white)
                .frame(width: 66, height: 66).background(glass(66))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        ZStack {
            Color.black
            if CallGate.busy {
                Text(CallGate.message(lang)).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).padding(30)
            } else if needsDownload {
                downloadPlaceholder
            } else if let player {
                // целиком по центру, чёрные поля вокруг — как фото
                PlayerLayerView(player: player, gravity: .resizeAspect)
                    .allowsHitTesting(false)
                if chrome {
                    HStack(spacing: 40) {
                        skip("gobackward.15", -15)
                        Button { toggle(); onActivity() } label: {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 32)).foregroundStyle(.white)
                                .frame(width: 78, height: 78).background(glass(78))
                        }
                        .buttonStyle(.plain)
                        skip("goforward.15", 15)
                    }
                    .transition(.opacity)

                    VStack(spacing: 12) {
                        Spacer()
                        HStack(spacing: 12) {
                            Text(Self.clock(time)).font(.system(size: 14, weight: .medium).monospacedDigit()).foregroundStyle(.white)
                            SeekBar(time: $time, total: total, pressing: $scrubbing) { editing in
                                onActivity()
                                if !editing { player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
                            }
                            Text(Self.clock(total)).font(.system(size: 14, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                        }
                        .padding(.horizontal, 20).frame(height: 56)
                        .background(Color(white: 0.09).opacity(0.92), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                        .padding(.horizontal, 12)

                        // скорость воспроизведения
                        Menu {
                            ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { r in
                                Button { setRate(r); onActivity() } label: {
                                    Label(r == 1 ? "Обычная" : "\(r.formatted())×", systemImage: rate == r ? "checkmark" : "speedometer")
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "gearshape").font(.system(size: 18))
                                if rate != 1 { Text("\(rate.formatted())×").font(.system(size: 14, weight: .semibold)) }
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22).frame(height: 44)
                            .background(Color(white: 0.09).opacity(0.92), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                        }
                    }
                    .padding(.bottom, bottomPad)
                    .transition(.opacity)
                }
            }
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.22), value: chrome)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: isCurrent) { _, now in
            if now, let player {
                NotificationCenter.default.post(name: .orbitaVideoWithSound, object: nil)
                player.play(); player.rate = rate; playing = true
            } else { player?.pause() }
        }
    }

    private func setRate(_ r: Float) {
        rate = r
        player?.defaultRate = r
        if playing { player?.rate = r }
    }

    private func toggle() {
        guard let player else { return }
        if playing { player.pause(); playing = false }
        else {
            if total > 0, time >= total - 0.05 { player.seek(to: .zero) }
            NotificationCenter.default.post(name: .orbitaVideoWithSound, object: nil)
            player.play(); player.rate = rate; playing = true
        }
    }

    /// Превью и кнопка «скачать» / кольцо загрузки
    private var downloadPlaceholder: some View {
        let progress = downloads.progress[item.id]
        return ZStack {
            if let thumb = item.thumbID { RemoteImage(id: thumb, fill: false, backdrop: .black).opacity(0.6) }
            VStack(spacing: 12) {
                Button { download() } label: {
                    TransferRing(progress: progress, icon: progress == nil ? "arrow.down" : "xmark", size: 64)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                }
                .buttonStyle(.plain)
                .disabled(progress != nil)
                if downloadFailed && progress == nil {
                    Text(lang == .en ? "No connection. Tap to try again" : "Нет сети. Нажмите, чтобы повторить")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
    }

    private func download() {
        downloadFailed = false
        Task {
            if let local = await MediaFileCache.shared.download(item.id) {
                needsDownload = false
                begin(local)
            } else {
                downloadFailed = true
            }
        }
    }

    private func start() {
        guard player == nil, !CallGate.busy else { return }
        // уже на телефоне — играем с него (и без сети)
        if let local = MediaFileCache.shared.cached(item.id) { begin(local); return }
        if NetworkState.shared.offline { needsDownload = true; return }
        guard let url = ServerConfig.mediaURL(item.id) else { return }
        begin(url)
        // пока смотришь — сохраняется на телефон (сразу, без очереди фоновых загрузок)
        let id = item.id
        Task.detached(priority: .utility) { await MediaFileCache.shared.download(id) }
    }

    private func begin(_ url: URL) {
        guard player == nil else { return }
        let av = AVAudioSession.sharedInstance()
        try? av.setCategory(.playback, mode: .moviePlayback)
        AudioSessionGate.willActivate()
        try? av.setActive(true)
        let newPlayer = AVPlayer(url: url)
        observer = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { t in
            if !scrubbing { time = t.seconds.isFinite ? t.seconds : 0 }
            if let d = newPlayer.currentItem?.duration.seconds, d.isFinite, d > 0 { total = d }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: newPlayer.currentItem, queue: .main) { _ in
            if isCurrent { playing = false }
        }
        // с сервера не грузится (сеть пропала) — вместо чёрного экрана кнопка «скачать»
        if !url.isFileURL {
            statusObserver = newPlayer.currentItem?.observe(\.status, options: [.new]) { item, _ in
                guard item.status == .failed else { return }
                DispatchQueue.main.async {
                    guard MediaFileCache.shared.cached(self.item.id) == nil else { return }
                    stop()
                    needsDownload = true
                }
            }
        }
        if isCurrent {
            NotificationCenter.default.post(name: .orbitaVideoWithSound, object: nil)      // музыка — на паузу
            newPlayer.play(); playing = true
        }
        player = newPlayer
    }

    private func stop() {
        if let observer { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObserver?.invalidate()
        observer = nil; endObserver = nil; statusObserver = nil
        player?.pause()
        player = nil
    }

    private static func clock(_ t: Double) -> String {
        let n = Int(max(0, t.isFinite ? t : 0))
        return String(format: "%d:%02d", n / 60, n % 60)
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
    @State private var tick = 0
    @State private var videoPlaying = true
    @State private var lastID: String?
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
        viewerContent.onAppear { hideKeyboard() }
    }

    private var viewerContent: some View {
        ZStack {
            if !embedded { Color.black.ignoresSafeArea() }

            TabView(selection: $index) {
                ForEach(Array(media.enumerated()), id: \.offset) { item in
                    page(item.element, at: item.offset).tag(item.offset)
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { chrome.toggle() }; tick += 1 }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .id(media.count)            // список дополнился — страницы собираются заново, иначе листание зависает
            .ignoresSafeArea()
            .opacity(pagesVisible ? 1 : 0)

            if chrome {
                VStack {
                    HStack(spacing: 10) {
                        roundButton("chevron.left") { if let onClose { onClose() } else { dismiss() } }
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
                        Menu {
                            Button { Task { await save() } } label: { Label("Сохранить в галерею", systemImage: "arrow.down.to.line") }
                        } label: {
                            Image(systemName: saving ? "arrow.down.circle" : "ellipsis")
                                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(.ultraThinMaterial, in: Circle())
                        }
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
        .onChange(of: index) { _, v in onIndex?(v); lastID = media.indices.contains(v) ? media[v].id : nil }
        // список дополнился (подтянулась вся история) — остаёмся на том же файле, а не на том же номере
        .onChange(of: media.map(\.id)) { _, ids in
            if let id = lastID, let i = ids.firstIndex(of: id), i != index { index = i }
        }
        .onAppear { lastID = current?.id }
        // у видео кнопки сами пропадают через 5 секунд, как в шортсах; нажатие по экрану возвращает их
        .task(id: "\(tick)-\(chrome)-\(videoPlaying)-\(index)") {
            guard chrome, videoPlaying, current?.kind == .video else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.25)) { chrome = false } }
        }
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
    private func page(_ item: MediaItem, at i: Int) -> some View {
        switch item.kind {
        case .image: ZoomableViewerImage(id: item.id)
        case .art:   PostArt(kind: item.artIndex).aspectRatio(item.aspect, contentMode: .fit)
        case .video: ViewerVideo(item: item, chrome: chrome, isCurrent: i == index, playing: $videoPlaying, onActivity: { tick += 1 },
                                bottomPad: embedded ? max(10, BottomInset.value) : 10)
        }
    }
}


/// Фото в просмотре: чёрный фон до краёв, щипок и двойной тап — увеличение
struct ZoomableViewerImage: View {
    let id: String
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragBase: CGSize = .zero

    var body: some View {
        RemoteImage(id: id, fill: false, backdrop: .black)
            .background(Color.black)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(MagnifyGesture()
                .onChanged { v in scale = min(5, max(1, base * v.magnification)) }
                .onEnded { _ in
                    base = scale
                    if scale <= 1.02 { reset() }
                })
            // перетаскивание нужно только при увеличении; иначе оно перехватывает свайп и фото не листаются
            .simultaneousGesture(DragGesture()
                .onChanged { v in
                    guard scale > 1 else { return }
                    offset = CGSize(width: dragBase.width + v.translation.width, height: dragBase.height + v.translation.height)
                }
                .onEnded { _ in if scale > 1 { dragBase = offset } },
                including: scale > 1.02 ? .all : .none)
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    if scale > 1 { reset() } else { scale = 2.5; base = 2.5 }
                }
            }
    }

    private func reset() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            scale = 1; base = 1; offset = .zero; dragBase = .zero
        }
    }
}
