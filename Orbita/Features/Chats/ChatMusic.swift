import SwiftUI
import AVFoundation
import UIKit

// MARK: - Музыка в переписке

extension ChatAttachment {
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac"]

    /// Музыкальный файл (новый тип «audio» или старый файл с расширением mp3/m4a)
    var isMusic: Bool {
        if kind == .audio { return true }
        guard kind == .file, let name else { return false }
        return Self.audioExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return ((name ?? "") as NSString).deletingPathExtension
    }

    var track: Track? {
        guard isMusic, let mediaID else { return nil }
        return Track(id: mediaID, mediaID: mediaID, title: displayTitle.isEmpty ? "Без названия" : displayTitle,
                     artist: artist ?? "", duration: duration, cover: thumbID)
    }
}

/// Музыкальное вложение вместе с сообщением, в котором оно пришло
struct ChatMusicItem: Identifiable, Equatable {
    let messageID: String
    let attachment: ChatAttachment
    let track: Track
    let mine: Bool
    var id: String { track.id }
}

func chatMusicItems(_ messages: [ChatMessage]) -> [ChatMusicItem] {
    messages.flatMap { m in
        m.attachments.compactMap { a in
            a.track.map { ChatMusicItem(messageID: m.id, attachment: a, track: $0, mine: m.mine) }
        }
    }
}

extension ChatModel {
    /// Вся музыка из переписки — для очереди «Следующие» и вкладки «Музыка»
    var musicItems: [ChatMusicItem] { chatMusicItems(messages) }
}

/// Теги mp3/m4a: название, исполнитель, обложка
enum AudioMeta {
    static func read(_ url: URL) async -> (title: String, artist: String, duration: Double, cover: Data?) {
        let asset = AVURLAsset(url: url)
        var title = "", artist = ""
        var cover: Data?
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey?.rawValue else { continue }
                if key == "title", title.isEmpty { title = (try? await item.load(.stringValue)) ?? "" }
                if key == "artist", artist.isEmpty { artist = (try? await item.load(.stringValue)) ?? "" }
                if key == "artwork", cover == nil, let data = try? await item.load(.dataValue) {
                    cover = ImageProcessing.prepare(data, maxSide: 600)
                }
            }
        }
        if title.trimmingCharacters(in: .whitespaces).isEmpty { title = url.deletingPathExtension().lastPathComponent }
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        return (title, artist, seconds.isFinite ? max(0, seconds) : 0, cover)
    }
}

// MARK: - Пузырь с музыкой

struct AudioBlock: View {
    let attachment: ChatAttachment
    let mine: Bool
    var pending = false
    let onPlay: () -> Void

    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.theme) private var theme

    private var track: Track? { attachment.track }
    private var playing: Bool { track.map { player.isCurrent($0) && player.isPlaying } ?? false }

    var body: some View {
        let primary = mine ? Color.white : theme.text
        let secondary = mine ? Color.white.opacity(0.75) : theme.textTertiary
        HStack(spacing: 12) {
            Button(action: onPlay) {
                ZStack {
                    if let cover = attachment.thumbID {
                        RemoteImage(id: cover).clipShape(Circle())
                        Circle().fill(Color.black.opacity(0.28))
                    } else {
                        Circle().fill(mine ? Color.white : theme.accentColor)
                    }
                    if pending {
                        ProgressView().tint(attachment.thumbID != nil || !mine ? .white : theme.accentColor)
                    } else {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 21, weight: .bold))
                            .foregroundStyle(attachment.thumbID != nil ? Color.white : (mine ? theme.accentColor : Color.white))
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.displayTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .padding(.trailing, 44)       // под время сообщения
            }
            Spacer(minLength: 0)
        }
        .frame(width: 244)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let main = [attachment.artist ?? "", attachment.duration > 0 ? mmss(Int(safe: attachment.duration)) : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        if !main.isEmpty { return main }
        let name = attachment.name ?? ""
        let ext = name.contains(".") ? (name.split(separator: ".").last.map { String($0).uppercased() } ?? "") : ""
        return ext.count <= 5 ? ext : ""
    }
}

// MARK: - Полоска «сейчас играет» под шапкой чата

struct NowPlayingBar: View {
    let onOpen: () -> Void

    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.theme) private var theme

    var body: some View {
        if let track = player.current {
            HStack(spacing: 10) {
                Button {
                    player.isPlaying ? player.pause() : player.resume()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(theme.accentColor)
                        .frame(width: 52, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        Text("\(mmss(Int(safe: player.elapsed))) / \(mmss(Int(safe: track.duration)))" + (track.artist.isEmpty ? "" : " · " + track.artist))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { player.stop() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 52, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            .frame(height: 56)
            .glass(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Capsule().fill(theme.accentColor)
                        .frame(width: max(0, (geo.size.width - 28) * player.progress), height: 2)
                        .padding(.horizontal, 14)
                        .animation(.linear(duration: 0.26), value: player.progress)
                }
                .frame(height: 3).padding(.bottom, 3)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)                       // воздух между островком и перепиской
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Большой плеер (как в Spotify)

struct FullPlayerSheet: View {
    let items: [ChatMusicItem]                      // музыка этой переписки (может быть пустой)
    let addToProfile: ((ChatMusicItem) async -> Bool)?

    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var showQueue = false
    @State private var scrubbing = false
    @State private var scrub: Double = 0
    @State private var added: Set<String> = []
    @State private var adding = false

    private var s: Strings { Strings(lang: lang) }
    private var track: Track? { player.current }
    private var currentItem: ChatMusicItem? { items.first { $0.id == track?.id } }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                Capsule().fill(Color.white.opacity(0.35)).frame(width: 40, height: 5).padding(.top, 8)
                if showQueue { queueView } else { Spacer(minLength: 8); cover; Spacer(minLength: 8) }
                titleRow
                scrubber
                controls
                queueHeader
                if let item = currentItem, addToProfile != nil { addButton(item) }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showQueue)
    }

    private var background: some View {
        // Размер фона жёстко задан размером экрана: раньше картинка-обложка «в натуральную величину» раздувала весь плеер,
        // и кнопки уезжали за края.
        GeometryReader { geo in
            ZStack {
                Color(red: 0.07, green: 0.07, blue: 0.09)
                if let cover = track?.cover {
                    RemoteImage(id: cover, maxPixel: 300)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 60).opacity(0.6).scaleEffect(1.35)
                    LinearGradient(colors: [theme.accentColor.opacity(0.25), .clear], startPoint: .top, endPoint: .center)
                } else {
                    LinearGradient(colors: [theme.accentColor.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                }
                Color.black.opacity(0.35)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }

    private var cover: some View {
        Group {
            if let id = track?.cover {
                // квадрат нужного размера, а картинка заполняет его и обрезается — не раздувая вёрстку
                Color.clear.overlay { RemoteImage(id: id, maxPixel: 900) }
            } else {
                ZStack {
                    LinearGradient(colors: [theme.accentColor.opacity(0.9), theme.accentColor.opacity(0.35)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: 80, weight: .light)).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        .scaleEffect(player.isPlaying ? 1 : 0.9)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
        .padding(.horizontal, 8)
    }

    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track?.title ?? "")
                .font(.system(size: 24, weight: .bold)).foregroundStyle(.white).lineLimit(1)
            Text(track?.artist.isEmpty == false ? track!.artist : s.t("Неизвестный исполнитель", "Unknown artist"))
                .font(.system(size: 17)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            FlowingProgress(progress: player.progress, tint: .white, track: .white.opacity(0.22)) { player.seek(toFraction: $0) }
            HStack {
                Text(mmss(Int(safe: player.elapsed)))
                Spacer()
                Text(mmss(Int(safe: player.total)))
            }
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.top, 10)
    }

    private var controls: some View {
        HStack {
            Button { player.repeatAll.toggle() } label: {
                Image(systemName: "repeat").font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(player.repeatAll ? theme.accentColor : .white.opacity(0.55))
            }
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 30)).foregroundStyle(.white)
            }
            Spacer()
            Button { player.isPlaying ? player.pause() : player.resume() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 76)).foregroundStyle(.white)
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 30)).foregroundStyle(.white)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    // «Следующая песня» — раскрывается в список всей музыки переписки
    private var queueHeader: some View {
        Button { showQueue.toggle() } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(showQueue ? s.t("Скрыть список", "Hide list") : s.t("Список песен", "Song list"))
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    Text("\(player.queue.count) " + s.t("песен", "songs"))
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Image(systemName: showQueue ? "chevron.down" : "list.bullet").foregroundStyle(.white.opacity(0.7))
            }
            .padding(14)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    private var nextTrack: Track? {
        guard let track, let i = player.queue.firstIndex(where: { $0.id == track.id }), i + 1 < player.queue.count else { return nil }
        return player.queue[i + 1]
    }

    private var queueView: some View {
        let list = items.isEmpty ? player.queue.map { ChatMusicItem(messageID: "", attachment: ChatAttachment(kind: .audio), track: $0, mine: false) } : items
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(list) { item in
                    let selected = item.id == track?.id
                    Button {
                        player.start(item.track, queue: list.map(\.track))
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                if let c = item.track.cover { RemoteImage(id: c) } else { theme.accentColor.opacity(0.35) }
                                Image(systemName: selected && player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            }
                            .frame(width: 46, height: 46)
                            .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.track.title).font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(selected ? theme.accentColor : .white).lineLimit(1)
                                Text([item.track.duration > 0 ? mmss(Int(safe: item.track.duration)) : "", item.track.artist]
                                        .filter { !$0.isEmpty }.joined(separator: " • "))
                                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 9).padding(.horizontal, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.top, 12)
    }

    private func addButton(_ item: ChatMusicItem) -> some View {
        let done = added.contains(item.id)
        return Button {
            guard !done, !adding else { return }
            adding = true
            Task {
                if await addToProfile?(item) == true {
                    added.insert(item.id)
                    Haptics.notify(.success)
                }
                adding = false
            }
        } label: {
            HStack(spacing: 8) {
                if adding { ProgressView().tint(.white) } else {
                    Image(systemName: done ? "checkmark" : "person.crop.circle.badge.plus")
                }
                Text(done ? s.t("Добавлено в профиль", "Added to profile") : s.t("Добавить в профиль", "Add to profile"))
                    .font(.system(size: 18, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(done ? AnyShapeStyle(Color.white.opacity(0.18)) : AnyShapeStyle(theme.accent), in: Capsule())
        }
        .buttonStyle(PressStyle())
        .padding(.top, 10)
    }
}

// MARK: - Полоска «играет голосовое» (скорость, закрыть) — вместо трека

struct VoiceNowBar: View {
    var includeCircle = true
    @ObservedObject private var voice = VoicePlayer.shared
    @ObservedObject private var focus = CircleFocus.shared

    var body: some View {
        if includeCircle, let circle = focus.current {
            CircleNowBar(playback: circle)
        } else if voice.currentID != nil {
            NowBarLayout(title: nil, isPlaying: voice.isPlaying, progress: voice.progress, duration: voice.duration, rate: voice.rate,
                         onToggle: { voice.isPlaying ? voice.pause() : voice.resume() },
                         onSeek: { voice.seek(toFraction: $0) },
                         onRate: { voice.cycleRate() },
                         onClose: { voice.stop() })
        }
    }
}

/// Полоска «играет видеосообщение» — те же кнопки: пауза, перемотка, скорость, закрыть
struct CircleNowBar: View {
    @ObservedObject var playback: CirclePlayback

    var body: some View {
        NowBarLayout(title: Strings(lang: .ru).t("Видеосообщение", "Video message"), isPlaying: playback.isPlaying, progress: playback.progress,
                     duration: playback.duration, rate: VoicePlayer.shared.rate,
                     onToggle: { playback.isPlaying ? playback.pause() : playback.resume() },
                     onSeek: { playback.seek(toFraction: $0) },
                     onRate: { VoicePlayer.shared.cycleRate(); playback.applyRate() },
                     onClose: { playback.stop() })
    }
}

struct NowBarLayout: View {
    let title: String?
    let isPlaying: Bool
    let progress: Double
    let duration: Double
    let rate: Float
    var onToggle: () -> Void
    var onSeek: (Double) -> Void
    var onRate: () -> Void
    var onClose: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(theme.accentColor)
                    .frame(width: 48, height: 52).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, -8)

            VStack(alignment: .leading, spacing: 4) {
                Text(title.map { _ in Strings(lang: lang).t("Видеосообщение", "Video message") }
                     ?? Strings(lang: lang).t("Голосовое сообщение", "Voice message"))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                FlowingProgress(progress: progress, tint: theme.accentColor, track: theme.stroke) { onSeek($0) }
                    .frame(height: 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(mmss(Int(safe: progress * duration)))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(theme.textSecondary)

            Button {
                Haptics.impact(.light)
                onRate()
            } label: {
                Text(rate == 1 ? "1×" : (rate == 1.5 ? "1.5×" : "2×"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(rate == 1 ? theme.text : Color.white)
                    .frame(minWidth: 34).padding(.horizontal, 6).frame(height: 28)
                    .background(rate == 1 ? AnyShapeStyle(theme.surface) : AnyShapeStyle(theme.accent), in: Capsule())
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 52, height: 52)                     // большая зона нажатия — по всей высоте полоски
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, -8)
        }
        .padding(.horizontal, 12).frame(height: 52)
        .glass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
