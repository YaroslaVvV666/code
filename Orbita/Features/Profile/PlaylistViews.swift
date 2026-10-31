import SwiftUI
import Combine
import AVFoundation
import MediaPlayer
import UniformTypeIdentifiers

// MARK: - Бегущая строка

/// Текст, который плавно едет влево, если не помещается. Короткий — стоит на месте.
struct MarqueeText: View {
    let text: String
    var size: CGFloat = 14
    var color: Color
    var always: Bool = false                        // всегда бежит (тикер), даже если текст помещается
    var running: Bool = true                        // false — пока стоит на месте (например, пока профиль догружается)

    private let gap: CGFloat = 40
    private let speed: Double = 34                  // точек в секунду
    @State private var width: CGFloat = 0

    private var label: some View {
        Text(text).font(.system(size: size)).foregroundStyle(color).lineLimit(1).fixedSize()
    }

    var body: some View {
        GeometryReader { geo in
            if !running {
                label.frame(width: geo.size.width, alignment: width > geo.size.width + 1 ? .leading : .center)
            } else if width > geo.size.width + 1 || (always && width > 0) {
                TimelineView(.animation) { context in
                    let cycle = Double(width + gap) / speed
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
                    HStack(spacing: gap) { label; label }
                        .offset(x: -CGFloat(phase) * (width + gap))
                        .frame(width: geo.size.width, alignment: .leading)
                }
            } else {
                label.frame(width: geo.size.width, alignment: .center)
            }
        }
        .frame(height: size * 1.45)
        .clipped()
        .mask(
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                   .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        )
        .background(
            label.hidden().background(GeometryReader { proxy in
                Color.clear.preference(key: MarqueeWidthKey.self, value: proxy.size.width)
            })
        )
        .onPreferenceChange(MarqueeWidthKey.self) { width = $0 }
    }
}

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Плеер

@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var queue: [Track] = []
    @Published var repeatAll = false
    @Published var shuffle = false

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var remoteReady = false
    private var videoObserver: NSObjectProtocol?

    /// Открыли видео со звуком (история, присланное видео, видео на весь экран) — песня встаёт на паузу, как в Telegram.
    /// Пауза, а не стоп: песню можно продолжить с того же места
    init() {
        videoObserver = NotificationCenter.default.addObserver(forName: .orbitaVideoWithSound, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.pause()
            }
        }
    }

    var total: Double { max(current?.duration ?? 0, 1) }
    var progress: Double { min(1, elapsed / total) }

    func isCurrent(_ track: Track) -> Bool { current?.id == track.id }

    /// Играет ли что-то из плейлиста, к которому относятся эти треки: сама песня в списке или та же очередь (ставили из плейлиста)
    func playing(from tracks: [Track], anchor: Track?) -> Track? {
        guard let current else { return nil }
        if tracks.contains(where: { $0.id == current.id }) { return current }
        if let anchor, queue.contains(where: { $0.id == anchor.id }), queue.contains(where: { $0.id == current.id }) { return current }
        return nil
    }

    /// Нажатие на трек: тот же — пауза/продолжить, другой — играть с него
    func toggle(_ track: Track, queue: [Track]) {
        if current?.id == track.id {
            isPlaying ? pause() : resume()
        } else {
            start(track, queue: queue)
        }
    }

    func start(_ track: Track, queue: [Track]) {
        guard !CallGate.blocks(.music) else { return }            // во время звонка музыка не включается
        VoicePlayer.shared.stop()
        CircleFocus.shared.stop()
        guard let url = ServerConfig.mediaURL(track.mediaID) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        AudioSessionGate.willActivate()
        try? AVAudioSession.sharedInstance().setActive(true)
        stopObserving()
        let item = AVPlayerItem(url: url)
        let avPlayer = AVPlayer(playerItem: item)
        player = avPlayer
        self.queue = queue.isEmpty ? [track] : queue
        current = track
        elapsed = 0
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.playNext(auto: true) } }
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                        queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                guard let self, seconds.isFinite else { return }
                self.elapsed = seconds
            }
        }
        avPlayer.play()
        isPlaying = true
        setupRemote()
        updateNowPlaying()
        // громкость по моментам песни — для анимации аватарки
        levels = nil
        let id = track.mediaID
        Task { [weak self] in
            let map = await LoudnessMap.load(mediaID: id)
            await MainActor.run { if self?.current?.mediaID == id { self?.levels = map } }
        }
    }

    /// Огибающая громкости текущей песни (по 0,05 с), если уже посчитана
    private(set) var levels: [Float]?

    /// Сила «толчка» 0…1 в текущий момент песни: громко — резко и сильно, тихо — еле заметно
    func energy() -> Double {
        guard let levels, let player else { return Beat.calm(Date().timeIntervalSinceReferenceDate) }
        let sec = player.currentTime().seconds
        guard sec.isFinite, sec >= 0 else { return 0 }
        let i = Int(sec / 0.05)
        var e = 0.0
        for k in 0..<8 {                                     // быстрое нарастание и мягкое затухание
            let j = i - k
            if levels.indices.contains(j) { e = max(e, Double(levels[j]) * exp(-Double(k) * 0.30)) }
        }
        return pow(min(1, e), 1.5)
    }

    /// В переписку пришла новая музыка — очередь обновляется, не сбивая текущий трек
    func syncQueue(_ tracks: [Track]) {
        guard let current, tracks.contains(where: { $0.id == current.id }), tracks != queue else { return }
        queue = tracks
    }

    func pause() { player?.pause(); isPlaying = false; updateNowPlaying() }
    func resume() {
        guard !CallGate.blocks(.music) else { return }
        player?.play(); isPlaying = true; updateNowPlaying()
    }

    func seek(toFraction fraction: Double) {
        let seconds = max(0, min(1, fraction)) * total
        elapsed = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func next() { playNext(auto: false) }

    func previous() {
        guard let current, let i = queue.firstIndex(where: { $0.id == current.id }) else { return }
        if elapsed > 3 || i == 0 {
            seek(toFraction: 0)
        } else {
            start(queue[i - 1], queue: queue)
        }
    }

    func stop() {
        stopObserving()
        player?.pause()
        player = nil
        current = nil
        isPlaying = false
        elapsed = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func playNext(auto: Bool) {
        if auto && CallGate.busy { pause(); return }                 // песня кончилась во время звонка — следующую не включаем
        guard let current, let i = queue.firstIndex(where: { $0.id == current.id }) else { return }
        if shuffle, queue.count > 1, let other = queue.filter({ $0.id != current.id }).randomElement() {
            start(other, queue: queue)
        } else if i + 1 < queue.count {
            start(queue[i + 1], queue: queue)
        } else if (repeatAll || !auto), queue.count > 1, let first = queue.first {
            start(first, queue: queue)          // вперёд с последнего трека — по кругу, а не тупик
        } else if auto {
            isPlaying = false
            seek(toFraction: 0)
            player?.pause()
        }
    }

    private func updateNowPlaying() {
        guard let current else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyPlaybackDuration: total,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
    }

    private func setupRemote() {
        guard !remoteReady else { return }
        remoteReady = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent {
                Task { @MainActor in
                    guard let self else { return }
                    self.seek(toFraction: e.positionTime / self.total)
                    self.updateNowPlaying()
                }
            }
            return .success
        }
    }

    private func stopObserving() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }
}

// MARK: - Громкость песни по времени

/// Скачивает песню и считает громкость кусочками по 0,05 с (чтобы аватарка отзывалась на настоящий звук)
enum LoudnessMap {
    private static var cache: [String: [Float]] = [:]

    @MainActor
    static func load(mediaID: String) async -> [Float]? {
        if let hit = cache[mediaID] { return hit }
        guard let url = ServerConfig.mediaURL(mediaID) else { return nil }
        let map = await Task.detached(priority: .utility) { () -> [Float]? in
            guard let (tmp, _) = try? await URLSession.shared.download(from: url) else { return nil }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("loud-\(UUID().uuidString).mp3")
            try? FileManager.default.removeItem(at: file)
            guard (try? FileManager.default.moveItem(at: tmp, to: file)) != nil else { return nil }
            defer { try? FileManager.default.removeItem(at: file) }
            return await analyze(file)
        }.value
        if let map { cache[mediaID] = map }
        return map
    }

    private static func analyze(_ file: URL) async -> [Float]? {
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let rate = 8000.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: rate
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        let bucket = Int(rate * 0.05)
        var levels: [Float] = []
        var acc = 0.0
        var n = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Int16](repeating: 0, count: length / 2)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &samples) == kCMBlockBufferNoErr else { continue }
            for v in samples {
                let f = Double(v) / 32768
                acc += f * f
                n += 1
                if n == bucket { levels.append(Float((acc / Double(n)).squareRoot())); acc = 0; n = 0 }
            }
        }
        guard levels.count > 20 else { return nil }
        // нормируем: «громко» — это верхние 5% песни, всё остальное относительно них
        let sorted = levels.sorted()
        let top = max(0.02, sorted[Int(Double(sorted.count - 1) * 0.95)])
        return levels.map { min(1, $0 / top) }
    }
}

// MARK: - Строка «сейчас в профиле» под ником

/// Название первого трека плейлиста бегущей строкой. У владельца без треков — «Добавить музыку».
struct MusicStrip: View {
    let track: Track?
    let queue: [Track]
    let canAdd: Bool
    @ObservedObject var player: AudioPlayer
    var marquee: Bool = true                        // бежит ли строка (в профиле — только когда всё догрузилось)
    let onAdd: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        // если из этого плейлиста уже что-то играет — показываем именно эту песню и ничего не перезапускаем
        let playing = player.playing(from: queue, anchor: track)
        if let track = playing ?? track {
            Button {
                if playing == nil { player.start(track, queue: queue) }
                onAdd()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: player.isCurrent(track) && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.accentColor)
                        .frame(width: 20)
                    MarqueeText(text: track.display, size: 14, color: theme.text, always: true, running: marquee)
                        .frame(maxWidth: 220)
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .contentShape(Capsule())                 // нажимается вся капсула, а не только текст и значок
                .glassCapsule(interactive: true)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        } else if canAdd {
            Button(action: onAdd) {
                HStack(spacing: 6) {
                    Image(systemName: "music.note").font(.system(size: 12, weight: .semibold))
                    Text(Strings(lang: lang).addMusic).font(.system(size: 14))
                }
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .glassCapsule(interactive: true)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Как в Telegram: когда фото раскрыто, песня превращается в плоскую полосу у нижнего края фото
struct MusicBar: View {
    let track: Track
    let queue: [Track]
    @ObservedObject var player: AudioPlayer
    let onOpen: () -> Void

    var body: some View {
        let playing = player.playing(from: queue, anchor: track)
        let track = playing ?? track
        Button {
            if playing == nil { player.start(track, queue: queue) }
            onOpen()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: player.isCurrent(track) && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.white).frame(width: 18)
                MarqueeText(text: track.display, size: 14, color: .white)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(Color.black.opacity(0.06))          // под строкой — размытое фото профиля, а не чёрная плашка
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Текущая полоска прогресса (течёт, перематывается пальцем)

struct FlowingProgress: View {
    let progress: Double
    var tint: Color = .white
    var track: Color = .white.opacity(0.22)
    let onSeek: (Double) -> Void

    @State private var dragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let value = dragging ? dragValue : progress
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint).frame(width: max(0, w * value))
            }
            .frame(height: dragging ? 9 : 5)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        dragValue = min(1, max(0, g.location.x / w))
                    }
                    .onEnded { g in
                        let v = min(1, max(0, g.location.x / w))
                        dragValue = v
                        onSeek(v)
                        dragging = false
                    }
            )
            .animation(.linear(duration: dragging ? 0 : 0.26), value: progress)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging)
        }
        .frame(height: 24)
    }
}

// MARK: - Плейлист (liquid glass)

struct PlaylistSheet: View {
    @ObservedObject var model: UserPageModel
    @ObservedObject var player: AudioPlayer
    let isMine: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var importing = false
    @State private var renaming: Track?
    @State private var deleting: Track?
    @State private var reordering = false
    @State private var titleDraft = ""
    @State private var artistDraft = ""
    @State private var scrubbing = false
    @State private var scrub: Double = 0

    private var s: Strings { Strings(lang: lang) }
    private var hasPlayer: Bool { player.current != nil && model.tracks.contains(where: { player.isCurrent($0) }) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            list
            if hasPlayer { playerPanel.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .background(theme.sheet.ignoresSafeArea())
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: hasPlayer)
        .onAppear { player.syncQueue(model.tracks) }
        .onChange(of: model.tracks) { _, tracks in player.syncQueue(tracks) }
        .presentationDetents([.large])                 // на всю высоту, до самого низа — ничего не просвечивает
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.sheet)
        .tint(theme.accentColor)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.mp3, .mpeg4Audio, .audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.addTracks(urls) } }
        }
        .confirmationDialog(s.t("Удалить песню из плейлиста?", "Remove this song from the playlist?"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button(s.t("Удалить", "Remove"), role: .destructive) {
                if let track = deleting { Task { await model.deleteTrack(track) } }
                deleting = nil
            }
            Button(s.cancel, role: .cancel) { deleting = nil }
        } message: {
            if let track = deleting { Text(track.display) }
        }
        .alert(s.renameTrack, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(s.trackTitleField, text: $titleDraft)
            TextField(s.trackArtistField, text: $artistDraft)
            Button(s.save) {
                if let track = renaming { Task { await model.rename(track, title: titleDraft, artist: artistDraft) } }
                renaming = nil
            }
            Button(s.cancel, role: .cancel) { renaming = nil }
        }
    }

    // MARK: Верх

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                glassButton("xmark") { dismiss() }
                if isMine { Color.clear.frame(width: 48, height: 48) }      // чтобы заголовок оставался по центру
            }
            Spacer()
            VStack(spacing: 1) {
                Text(isMine ? s.t("Ваш плейлист", "Your playlist") : s.playlistTitle)
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(theme.text)
                    .lineLimit(1).minimumScaleFactor(0.6).fixedSize(horizontal: false, vertical: true)
                Text("\(model.tracks.count) " + s.t("песен", "songs"))
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            }
            Spacer()
            if isMine {
                HStack(spacing: 10) {
                if model.uploadingTracks {
                    ProgressView().frame(width: 48, height: 48)
                } else {
                    glassButton("plus") { importing = true }
                }
                glassButton(reordering ? "checkmark" : "arrow.up.arrow.down") {
                    withAnimation { reordering.toggle() }
                }
                .disabled(model.tracks.count < 2)
                .opacity(model.tracks.count < 2 ? 0.4 : 1)
                }
            } else {
                Color.clear.frame(width: 48, height: 48)
            }
        }
        .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 12)
    }

    private func glassButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.text)
                .frame(width: 48, height: 48).glassCircle()
        }
        .buttonStyle(.plain)
    }

    /// Обложка трека: загруженная вместе с ним, иначе — картинка, вшитая в mp3 (её отдаёт сервер); нет ничего — градиент с нотой
    private func cover(_ track: Track?, size: CGFloat, round: Bool = false) -> some View {
        let placeholder = ZStack {
            LinearGradient(colors: [theme.accentColor.opacity(0.85), theme.accentColor.opacity(0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note").font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(.white.opacity(0.9))
        }
        return ZStack {
            placeholder
            if let track {
                if let id = track.cover {
                    RemoteImage(id: id)
                } else {
                    CachedImage(url: ServerConfig.mediaURL(track.mediaID + "/cover"), maxPixel: 300) { image, _ in
                        if let image { Image(uiImage: image).resizable().scaledToFill().transition(.opacity) }
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: round ? size / 2 : size * 0.22, style: .continuous))
    }

    // MARK: Список — одна скруглённая карточка

    private var list: some View {
        List {
            if model.tracks.isEmpty {
                Text(s.playlistEmpty)
                    .font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, track in
                row(track)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(theme.stroke)
                    .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 10))
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 72 }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if isMine {
                            Button { deleting = track } label: { Label(s.removeTrack, systemImage: "trash") }
                                .tint(.red)
                        }
                    }
                    .contextMenu {
                        if isMine {
                            Button {
                                titleDraft = track.title; artistDraft = track.artist; renaming = track
                            } label: { Label(s.renameTrack, systemImage: "pencil") }
                            Button(role: .destructive) { deleting = track } label: {
                                Label(s.removeTrack, systemImage: "trash")
                            }
                        }
                    }
            }
            .onMove(perform: isMine ? { from, to in Task { await model.moveTrack(from: from, to: to) } } : nil)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // «ручки» перетаскивания появляются в режиме сортировки (в нём свайп-удаление не работает — так устроен iOS)
        .environment(\.editMode, .constant(isMine && reordering ? .active : .inactive))
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 14)
        .overlay(alignment: .bottom) {
            if let error = model.error {
                ToastView(text: s.api(error)).padding(.bottom, 20)
                    .task(id: error) {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        model.error = nil
                    }
            }
        }
    }

    private func row(_ track: Track) -> some View {
        let isCurrent = player.isCurrent(track)
        let playing = isCurrent && player.isPlaying
        let artist = track.artist.isEmpty ? s.t("Неизвестный исполнитель", "Unknown artist") : track.artist
        return Button { player.toggle(track, queue: model.tracks) } label: {
            HStack(spacing: 14) {
                ZStack {
                    cover(track, size: 50, round: true)
                    Circle().fill(Color.black.opacity(isCurrent ? 0.45 : 0.28)).frame(width: 50, height: 50)
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isCurrent ? theme.accentColor : theme.text).lineLimit(1)
                    Text((track.duration > 0 ? mmss(Int(safe: track.duration)) + " • " : "") + artist)
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Нижний плеер

    private var playerPanel: some View {
        let track = player.current
        let progress = scrubbing ? scrub : player.progress
        return VStack(spacing: 14) {
            HStack(spacing: 14) {
                cover(track, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track?.title ?? "").font(.system(size: 19, weight: .bold)).foregroundStyle(theme.text).lineLimit(1)
                    Text(track?.artist.isEmpty == false ? track!.artist : s.t("Неизвестный исполнитель", "Unknown artist"))
                        .font(.system(size: 15)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
                Spacer()
                if let track, let url = ServerConfig.mediaURL(track.mediaID) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 22, weight: .regular)).foregroundStyle(theme.text)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                }
            }

            VStack(spacing: 6) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.textTertiary.opacity(0.35))
                        Capsule().fill(theme.text).frame(width: max(8, g.size.width * progress))
                    }
                    .frame(height: 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in scrubbing = true; scrub = max(0, min(1, v.location.x / max(1, g.size.width))) }
                        .onEnded { v in
                            player.seek(toFraction: max(0, min(1, v.location.x / max(1, g.size.width))))
                            scrubbing = false
                        })
                }
                .frame(height: 24)
                HStack {
                    Text(mmss(Int(safe: (scrubbing ? scrub : player.progress) * player.total)))
                    Spacer()
                    Text("-" + mmss(max(0, Int(safe: player.total - (scrubbing ? scrub : player.progress) * player.total))))
                }
                .font(.system(size: 13).monospacedDigit()).foregroundStyle(theme.textSecondary)
            }

            HStack {
                modeButton("shuffle", on: player.shuffle) { player.shuffle.toggle() }
                Spacer()
                Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 30)) }
                Spacer()
                Button { player.isPlaying ? player.pause() : player.resume() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 44)).frame(width: 60)
                }
                Spacer()
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 30)) }
                Spacer()
                modeButton("repeat", on: player.repeatAll) { player.repeatAll.toggle() }
            }
            .foregroundStyle(theme.text)
            .buttonStyle(.plain)

            if isMine, let track {
                Button { deleting = track } label: {
                    Text(s.t("Удалить из профиля", "Remove from profile"))
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(theme.text)
                        .frame(maxWidth: .infinity).frame(height: 58)
                        .background(theme.textTertiary.opacity(0.28), in: Capsule())
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
    }

    private func modeButton(_ icon: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.impact(.light); action() } label: {
            Image(systemName: icon).font(.system(size: 22, weight: .semibold))
                .foregroundStyle(on ? theme.accentColor : theme.textSecondary)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
