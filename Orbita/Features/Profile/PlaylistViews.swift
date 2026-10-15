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

    private let gap: CGFloat = 40
    private let speed: Double = 34                  // точек в секунду
    @State private var width: CGFloat = 0

    private var label: some View {
        Text(text).font(.system(size: size)).foregroundStyle(color).lineLimit(1).fixedSize()
    }

    var body: some View {
        GeometryReader { geo in
            if width > geo.size.width + 1 {
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

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var remoteReady = false

    var total: Double { max(current?.duration ?? 0, 1) }
    var progress: Double { min(1, elapsed / total) }

    func isCurrent(_ track: Track) -> Bool { current?.id == track.id }

    /// Нажатие на трек: тот же — пауза/продолжить, другой — играть с него
    func toggle(_ track: Track, queue: [Track]) {
        if current?.id == track.id {
            isPlaying ? pause() : resume()
        } else {
            start(track, queue: queue)
        }
    }

    func start(_ track: Track, queue: [Track]) {
        VoicePlayer.shared.stop()
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
    }

    /// В переписку пришла новая музыка — очередь обновляется, не сбивая текущий трек
    func syncQueue(_ tracks: [Track]) {
        guard let current, tracks.contains(where: { $0.id == current.id }), tracks != queue else { return }
        queue = tracks
    }

    func pause() { player?.pause(); isPlaying = false; updateNowPlaying() }
    func resume() { player?.play(); isPlaying = true; updateNowPlaying() }

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
        guard let current, let i = queue.firstIndex(where: { $0.id == current.id }) else { return }
        if i + 1 < queue.count {
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

// MARK: - Строка «сейчас в профиле» под ником

/// Название первого трека плейлиста бегущей строкой. У владельца без треков — «Добавить музыку».
struct MusicStrip: View {
    let track: Track?
    let queue: [Track]
    let canAdd: Bool
    @ObservedObject var player: AudioPlayer
    let onAdd: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        if let track {
            Button {
                if !player.isCurrent(track) { player.start(track, queue: queue) }
                onAdd()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: player.isCurrent(track) && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.accentColor)
                        .frame(width: 20)
                    MarqueeText(text: track.display, size: 14, color: theme.text)
                        .frame(maxWidth: 220)
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .glassCapsule(interactive: true)
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
    @State private var editMode: EditMode = .inactive
    @State private var renaming: Track?
    @State private var titleDraft = ""
    @State private var artistDraft = ""

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if player.current != nil, model.tracks.contains(where: { player.isCurrent($0) }) {
                nowPlaying.padding(.horizontal, 14).padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            list
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: player.current?.id)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .tint(theme.accentColor)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.mp3, .mpeg4Audio, .audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.addTracks(urls) } }
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

    private var topBar: some View {
        HStack(spacing: 10) {
            glassButton("xmark") { dismiss() }
            Spacer()
            VStack(spacing: 1) {
                Text(s.playlistTitle).font(.system(size: 17, weight: .bold)).foregroundStyle(theme.text)
                Text("\(model.tracks.count) " + s.t("песен", "songs"))
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            }
            Spacer()
            if isMine {
                if model.uploadingTracks {
                    ProgressView().frame(width: 44, height: 44)
                } else {
                    glassButton("plus") { importing = true }
                }
                Button {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                } label: {
                    Image(systemName: editMode.isEditing ? "checkmark" : "arrow.up.arrow.down")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                        .frame(width: 44, height: 44).glassCircle()
                }
                .buttonStyle(.plain)
                .disabled(model.tracks.count < 2)
                .opacity(model.tracks.count < 2 ? 0.4 : 1)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 10)
    }

    private func glassButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                .frame(width: 44, height: 44).glassCircle()
        }
        .buttonStyle(.plain)
    }

    // Карточка «сейчас играет»
    private var nowPlaying: some View {
        let track = player.current
        return VStack(spacing: 4) {
            HStack(spacing: 12) {
                cover(track?.cover, size: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.title ?? "").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.text).lineLimit(1)
                    Text(track?.artist.isEmpty == false ? track!.artist : s.t("Неизвестный исполнитель", "Unknown artist"))
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
                Spacer()
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 18)).foregroundStyle(theme.text)
                }
                Button { player.isPlaying ? player.pause() : player.resume() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22)).foregroundStyle(theme.text).frame(width: 32)
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 18)).foregroundStyle(theme.text)
                }
            }
            .buttonStyle(.plain)
            FlowingProgress(progress: player.progress, tint: theme.accentColor, track: theme.stroke) { player.seek(toFraction: $0) }
            HStack {
                Text(mmss(Int(player.elapsed)))
                Spacer()
                Text(mmss(Int(player.total)))
            }
            .font(.system(size: 11).monospacedDigit()).foregroundStyle(theme.textTertiary)
        }
        .padding(14)
        .glass(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func cover(_ id: String?, size: CGFloat) -> some View {
        ZStack {
            if let id { RemoteImage(id: id) } else {
                LinearGradient(colors: [theme.accentColor.opacity(0.85), theme.accentColor.opacity(0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }

    private var list: some View {
        List {
            if model.tracks.isEmpty {
                Text(s.playlistEmpty)
                    .font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, track in
                row(track, index: index)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 3, leading: 14, bottom: 3, trailing: 14))
                    .swipeActions(edge: .trailing) {
                        if isMine {
                            Button(role: .destructive) { Task { await model.deleteTrack(track) } } label: {
                                Label(s.removeTrack, systemImage: "trash")
                            }
                        }
                    }
                    .contextMenu {
                        if isMine {
                            Button {
                                titleDraft = track.title; artistDraft = track.artist; renaming = track
                            } label: { Label(s.renameTrack, systemImage: "pencil") }
                            Button(role: .destructive) { Task { await model.deleteTrack(track) } } label: {
                                Label(s.removeTrack, systemImage: "trash")
                            }
                        }
                    }
            }
            .onMove(perform: isMine ? { from, to in Task { await model.moveTrack(from: from, to: to) } } : nil)

            if isMine && !model.tracks.isEmpty {
                Text(s.playlistHintMine)
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)
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

    private func row(_ track: Track, index: Int) -> some View {
        let isCurrent = player.isCurrent(track)
        let playing = isCurrent && player.isPlaying
        return Button { player.toggle(track, queue: model.tracks) } label: {
            HStack(spacing: 12) {
                ZStack {
                    cover(track.cover, size: 48)
                    if isCurrent {
                        Color.black.opacity(0.35).clipShape(RoundedRectangle(cornerRadius: 11.5, style: .continuous))
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isCurrent ? theme.accentColor : theme.text).lineLimit(1)
                    Text(track.artist.isEmpty ? s.t("Неизвестный исполнитель", "Unknown artist") : track.artist)
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
                Spacer()
                if track.duration > 0 {
                    Text(mmss(Int(track.duration)))
                        .font(.system(size: 13).monospacedDigit()).foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .glass(RoundedRectangle(cornerRadius: 18, style: .continuous), tint: isCurrent ? theme.accentColor.opacity(0.14) : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
