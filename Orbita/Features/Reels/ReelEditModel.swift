import SwiftUI
import AVFoundation
import Combine

/// Состояние редактора шортса: исходник, обрезка, фильтр, текст, фото, музыка и громкости.
/// Предпросмотр играет исходный файл с тем же фильтром, что потом будет в готовом ролике.
@MainActor
final class ReelEditModel: ObservableObject {
    enum Kind { case video, photos }

    static let maxSeconds: Double = 60        // шортс — не длиннее минуты; длиннее — выбираешь нужный момент

    let kind: Kind
    private(set) var sourceVideo: URL?

    @Published var photos: [UIImage] = []
    @Published var photoSeconds: Double = 3 {
        didSet { if oldValue != photoSeconds, kind == .photos { scheduleRebuild() } }
    }
    @Published private(set) var baseURL: URL?
    @Published private(set) var baseDuration: Double = 0
    @Published private(set) var ready = false
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0

    @Published var filter: ReelFilter = .none { didSet { if oldValue != filter { applyComposition() } } }
    @Published var texts: [ReelText] = []
    /// Положение и масштаб самого видео в кадре 9:16 (двигается и увеличивается пальцами)
    @Published var zoom: Double = 1
    @Published var offsetX: Double = 0
    @Published var offsetY: Double = 0
    var moved: Bool { abs(zoom - 1) > 0.01 || abs(offsetX) > 0.005 || abs(offsetY) > 0.005 }
    func resetPlacement() { zoom = 1; offsetX = 0; offsetY = 0 }
    @Published var stickers: [ReelSticker] = []

    @Published private(set) var music: Track?
    @Published private(set) var musicFile: URL?
    @Published private(set) var musicLoading = false
    @Published var musicVolume: Double = 0.7 { didSet { musicPlayer.volume = Float(musicVolume) } }
    @Published var originalVolume: Double = 1 { didSet { player.volume = Float(originalVolume) } }
    @Published var musicStart: Double = 0 { didSet { if oldValue != musicStart { restartMusic() } } }

    @Published private(set) var isPlaying = false
    @Published private(set) var exporting = false
    @Published private(set) var exportProgress: Double = 0
    @Published var failed = false

    let player = AVPlayer()
    private let musicPlayer = AVPlayer()
    private var fill = true
    /// Пропорции исходного видео (ширина / высота) и режим «на весь кадр» — для рамки видео в редакторе
    private(set) var videoAspect: Double = 9.0 / 16.0
    var videoFills: Bool { fill }
    private var timeObserver: Any?
    private var endObservers: [NSObjectProtocol] = []
    private var rebuildTask: Task<Void, Never>?
    private var musicCache: [String: URL] = [:]
    private var tempFiles: [URL] = []

    var trimLength: Double { max(0, trimEnd - trimStart) }
    var hasAudioTrackHint: Bool { kind == .video }

    /// Менялось ли что-то — иначе можно отправить исходник без пересжатия
    var hasEdits: Bool {
        guard kind == .video else { return true }
        return trimStart > 0.05 || trimEnd < baseDuration - 0.05 || filter != .none || !texts.isEmpty
            || !stickers.isEmpty || music != nil || abs(originalVolume - 1) > 0.01 || moved
    }

    init(video: URL) {
        kind = .video
        sourceVideo = video
        player.actionAtItemEnd = .none
        musicPlayer.actionAtItemEnd = .none
    }

    init(photos: [UIImage]) {
        kind = .photos
        self.photos = photos
        player.actionAtItemEnd = .none
        musicPlayer.actionAtItemEnd = .none
    }

    // MARK: Подготовка

    func start() async {
        guard !ready else { play(); return }
        if kind == .video, let url = sourceVideo {
            let asset = AVURLAsset(url: url)
            let duration = ((try? await asset.load(.duration))?.seconds) ?? 0
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let natural = try? await track.load(.naturalSize), let tf = try? await track.load(.preferredTransform) {
                let r = CGRect(origin: .zero, size: natural).applying(tf)
                let aspect = abs(r.width) / max(1, abs(r.height))
                videoAspect = Double(aspect)
                fill = aspect < 0.7        // вертикальное — на весь кадр; горизонтальное — с полосами
            }
            baseURL = url
            baseDuration = duration
            trimStart = 0
            trimEnd = min(duration, Self.maxSeconds)
            ready = true
            installPlayer()
        } else {
            await rebuildNow()
        }
    }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.rebuildNow()
        }
    }

    func photosChanged() { scheduleRebuild() }

    private func rebuildNow() async {
        guard kind == .photos, !photos.isEmpty else { return }
        let imgs = photos, secs = photoSeconds
        do {
            let url = try await Task.detached(priority: .userInitiated) { try await ReelRender.makeSlideshow(imgs, seconds: secs) }.value
            if let old = baseURL { try? FileManager.default.removeItem(at: old) }
            baseURL = url
            baseDuration = Double(imgs.count) * max(0.5, (secs / 0.5).rounded() * 0.5)
            fill = true
            trimStart = 0
            trimEnd = min(baseDuration, Self.maxSeconds)
            ready = true
            installPlayer()
        } catch {
            if !(error is CancellationError) { failed = true }
        }
    }

    // MARK: Плеер

    private func installPlayer() {
        guard let baseURL else { return }
        let asset = AVURLAsset(url: baseURL)
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = ReelRender.composition(for: asset, filter: filter, overlay: nil, fill: fill)
        player.replaceCurrentItem(with: item)
        player.volume = Float(originalVolume)

        if let t = timeObserver { player.removeTimeObserver(t); timeObserver = nil }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        endObservers.forEach { NotificationCenter.default.removeObserver($0) }
        endObservers = [
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.loop() }
            }
        ]
        loop()
    }

    private func applyComposition() {
        guard let item = player.currentItem, let baseURL else { return }
        item.videoComposition = ReelRender.composition(for: AVURLAsset(url: baseURL), filter: filter, overlay: nil, fill: fill)
    }

    private func tick(_ t: Double) {
        if isPlaying, trimEnd > 0, t >= trimEnd - 0.03 { loop() }
    }

    func loop() {
        player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        restartMusic()
        play()
    }

    func play() {
        let av = AVAudioSession.sharedInstance()
        try? av.setCategory(.playback, mode: .moviePlayback)
        AudioSessionGate.willActivate()
        try? av.setActive(true)
        player.play()
        if musicFile != nil { musicPlayer.play() }
        isPlaying = true
    }

    func pause() {
        player.pause(); musicPlayer.pause()
        isPlaying = false
    }

    func togglePlay() { isPlaying ? pause() : play() }

    /// Показать кадр под ползунком обрезки
    func scrub(to seconds: Double) {
        player.pause(); musicPlayer.pause()
        isPlaying = false
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Музыка

    func setMusic(_ track: Track?) async {
        music = track
        musicPlayer.pause()
        guard let track else {
            musicFile = nil
            musicPlayer.replaceCurrentItem(with: nil)
            return
        }
        musicLoading = true
        defer { musicLoading = false }
        var local = musicCache[track.mediaID]
        if local == nil {
            local = try? await ReelRender.download(track)
            if let local { musicCache[track.mediaID] = local }
        }
        guard music?.id == track.id else { return }          // успели выбрать другой
        guard let local else { music = nil; musicFile = nil; failed = true; return }
        musicFile = local
        musicStart = 0
        let item = AVPlayerItem(url: local)
        musicPlayer.replaceCurrentItem(with: item)
        musicPlayer.volume = Float(musicVolume)
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.musicPlayer.seek(to: .zero)
                if self.isPlaying { self.musicPlayer.play() }
            }
        }
        restartMusic()
        if isPlaying { musicPlayer.play() }
    }

    private func restartMusic() {
        guard musicFile != nil else { return }
        musicPlayer.seek(to: CMTime(seconds: musicStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Насколько можно сдвинуть начало фрагмента музыки
    var musicStartLimit: Double { max(0, (music?.duration ?? 0) - max(trimLength, 1)) }

    // MARK: Результат

    private func overlayImage() -> CIImage? {
        guard !texts.isEmpty || !stickers.isEmpty else { return nil }
        let renderer = ImageRenderer(content: ReelOverlayCanvas(texts: texts, stickers: stickers, size: ReelRender.canvas))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }

    /// Собирает финальный ролик. Если ничего не менялось — возвращает nil, и можно отправлять исходник
    func exportVideo() async -> URL? {
        guard let baseURL else { return nil }
        pause()
        exporting = true
        exportProgress = 0
        defer { exporting = false }
        let job = ReelRender.Job(baseURL: baseURL, fill: fill, zoom: zoom, dx: offsetX, dy: offsetY, trimStart: trimStart, trimEnd: trimEnd, filter: filter,
                                 overlay: overlayImage(), musicFile: music == nil ? nil : musicFile, musicStart: musicStart,
                                 musicVolume: Float(musicVolume), originalVolume: Float(originalVolume))
        do {
            return try await ReelRender.export(job) { [weak self] p in
                Task { @MainActor in self?.exportProgress = p }
            }
        } catch {
            failed = true
            return nil
        }
    }

    func cleanup() {
        rebuildTask?.cancel()
        player.pause(); musicPlayer.pause()
        if let t = timeObserver { player.removeTimeObserver(t); timeObserver = nil }
        endObservers.forEach { NotificationCenter.default.removeObserver($0) }
        endObservers = []
        player.replaceCurrentItem(with: nil)
        musicPlayer.replaceCurrentItem(with: nil)
        isPlaying = false
        for url in musicCache.values { try? FileManager.default.removeItem(at: url) }
        musicCache = [:]
        if kind == .photos, let b = baseURL { try? FileManager.default.removeItem(at: b) }
        AudioSessionGate.deactivate()
    }
}
