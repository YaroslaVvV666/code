import SwiftUI
import AVFoundation

/// Голосовое и кружок продолжают играть после выхода из переписки — но только пока ты на вкладке «Чаты».
/// Голосовое — полоска сверху (скорость, закрыть), кружок — маленький круг в углу: смахни его в любую сторону, и он выключится.
struct ChatsBackgroundMedia: View {
    @ObservedObject var chats: ChatsModel
    @ObservedObject private var focus = CircleFocus.shared
    let tab: MainTab
    let barHeight: CGFloat

    private var visible: Bool { tab == .chats && !chats.chatOpen }

    var body: some View {
        ZStack {
            if visible, let circle = focus.current {
                CirclePiP(playback: circle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 14).padding(.bottom, barHeight + 14)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: visible)
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: focus.current != nil)
        .allowsHitTesting(visible)
    }
}

/// Музыка и голосовое сверху списка чатов: часть раскладки, поэтому не наезжает на строку поиска и папки
struct ChatsTopIsland: View {
    let session: AppSession
    @ObservedObject private var voice = VoicePlayer.shared
    @ObservedObject private var player: AudioPlayer
    @Environment(\.theme) private var theme
    @State private var showPlayer = false

    init(session: AppSession) {
        self.session = session
        _player = ObservedObject(wrappedValue: session.player)
    }

    var body: some View {
        Group {
            if player.current != nil || voice.currentID != nil {
                VStack(spacing: 8) {
                    NowPlayingBar { showPlayer = true }
                    VoiceNowBar(includeCircle: false)
                }
                .environmentObject(player)
                .padding(.top, 2).padding(.bottom, 12)             // воздух до папок «Все», «Новые»…
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: voice.currentID)
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: player.current?.id)
        .sheet(isPresented: $showPlayer) {
            FullPlayerSheet(items: [], addToProfile: nil)
                .environmentObject(player).environmentObject(session)
                .environment(\.theme, theme)
                .presentationDragIndicator(.hidden)
        }
    }
}

/// Маленький кружок в углу: тап — пауза, свайп в любую сторону — выключить
struct CirclePiP: View {
    @ObservedObject var playback: CirclePlayback
    @Environment(\.theme) private var theme
    @State private var drag: CGSize = .zero
    private let size: CGFloat = 124

    var body: some View {
        ZStack {
            Color.black
            if let player = playback.player { PlayerLayerView(player: player) }
            if !playback.isPlaying {
                Image(systemName: "play.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 48, height: 48).background(.black.opacity(0.4), in: Circle())
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().trim(from: 0, to: playback.progress).stroke(theme.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .rotationEffect(.degrees(-90)).padding(2))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .offset(drag)
        .opacity(1 - min(0.6, Double(hypot(drag.width, drag.height)) / 260))
        .contentShape(Circle())
        .onTapGesture { playback.isPlaying ? playback.pause() : playback.resume() }
        .gesture(DragGesture(minimumDistance: 8)
            .onChanged { drag = $0.translation }
            .onEnded { v in
                let d = hypot(v.translation.width, v.translation.height)
                let p = hypot(v.predictedEndTranslation.width, v.predictedEndTranslation.height)
                if d > 60 || p > 160 {
                    Haptics.impact(.light)
                    let k: CGFloat = 900 / max(1, p)
                    withAnimation(.easeOut(duration: 0.22)) {
                        drag = CGSize(width: v.predictedEndTranslation.width * k, height: v.predictedEndTranslation.height * k)
                    }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        playback.stop()
                        drag = .zero
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { drag = .zero }
                }
            })
    }
}
