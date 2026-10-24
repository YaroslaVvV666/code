import SwiftUI

/// Страница трека (как в TikTok): название, кто исполняет и все шортсы, снятые под эту музыку
struct ReelMusicPage: View {
    let music: PostMusic

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss

    @State private var page: MusicPage?
    @State private var failed = false
    @State private var opened: Post?

    private var s: Strings { Strings(lang: lang) }
    private var track: Track {
        Track(id: music.mediaID, mediaID: music.mediaID, title: page?.title ?? music.title,
              artist: page?.artist ?? music.artist, duration: 0)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    content
                }
                .padding(.top, 70).padding(.bottom, 40)
            }
            Button { session.player.stop(); dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(.white.opacity(0.16), in: Circle())
                    .frame(width: 48, height: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 10).padding(.top, 4)
        }
        .preferredColorScheme(.dark)
        .task {
            do { page = try await session.socialRepo.musicPage(mediaID: music.mediaID) } catch { failed = true }
        }
        .onDisappear { if session.player.current?.id == music.mediaID { session.player.stop() } }
        .fullScreenCover(item: $opened) { post in
            MusicShortsCover(reels: (page?.posts ?? [post]).map { Reel(post: $0, state: "none") },
                             startID: post.id, onClose: { opened = nil })
                .environmentObject(session).environmentObject(flow)
                .environment(\.theme, theme).environment(\.lang, lang)
        }
    }

    private var coverURL: URL? { ServerConfig.mediaURL(music.mediaID + "/cover") }

    /// Заглушка: градиент с нотой. Настоящая обложка (если она вшита в аудиофайл) ложится сверху
    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.35, blue: 1), Color(red: 1, green: 0.35, blue: 0.6)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "music.note").font(.system(size: 44, weight: .semibold)).foregroundStyle(.white)
        }
    }

    private var coverView: some View {
        CachedImage(url: coverURL, maxPixel: 512) { image, _ in
            ZStack {
                placeholder
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 128, height: 128)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: image != nil)
        }
        .frame(width: 128, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    private var header: some View {
        VStack(spacing: 12) {
            coverView

            Text(page?.title ?? music.title)
                .font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            if !(page?.artist ?? music.artist).isEmpty {
                Text(page?.artist ?? music.artist).font(.system(size: 15)).foregroundStyle(.white.opacity(0.65))
            }
            if let page {
                Text(s.t("Видео под этот трек: \(page.posts.count)", "Videos with this sound: \(page.posts.count)"))
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
            }

            Button {
                Haptics.impact(.light)
                session.player.toggle(track, queue: [track])
            } label: {
                let playing = session.player.current?.id == track.id && session.player.isPlaying
                Label(playing ? s.t("Пауза", "Pause") : s.t("Слушать", "Listen"),
                      systemImage: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 26).frame(height: 44).background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let page {
            if page.posts.isEmpty {
                Text(s.t("Пока нет видео под этот трек", "No videos with this sound yet"))
                    .font(.system(size: 15)).foregroundStyle(.white.opacity(0.6)).padding(.top, 30)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(page.posts) { post in
                        Color(white: 0.1).aspectRatio(9.0 / 16.0, contentMode: .fit)
                            .overlay {
                                if let m = post.media.first { RemoteImage(id: m.thumbID ?? m.id) }
                            }
                            .overlay(alignment: .bottomLeading) {
                                HStack(spacing: 4) {
                                    Image(systemName: "heart.fill").font(.system(size: 10))
                                    Text("\(post.likes)").font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 3).padding(6)
                            }
                            .overlay(alignment: .topLeading) {
                                Text(post.author.username.map { "@" + $0 } ?? post.author.name)
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                    .shadow(color: .black.opacity(0.7), radius: 3).padding(6)
                            }
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture { opened = post }
                    }
                }
            }
        } else if failed {
            Text(s.t("Не удалось загрузить", "Couldn't load")).foregroundStyle(.white.opacity(0.6)).padding(.top, 30)
        } else {
            ProgressView().tint(.white).padding(.top, 30)
        }
    }
}

/// Шортсы под один звук: вертикальная лента, открытая на выбранном ролике (а не пост)
struct MusicShortsCover: View {
    let reels: [Reel]
    let startID: String
    let onClose: () -> Void

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var flow: AuthFlow
    @State private var authorID: String?

    var body: some View {
        ReelsView(onOpenAuthor: { authorID = $0.id }, suspended: authorID != nil,
                  fixed: reels, startID: startID, onClose: onClose)
            .profileSheet(id: $authorID)
    }
}


/// Звук из шортса открывается как обычная песня: обложка, перемотка, «Добавить в профиль».
/// Кнопка справа сверху ведёт на страницу со всеми видео под этот звук
struct SoundSheet: View {
    let music: PostMusic

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var showVideos = false

    private var track: Track {
        Track(id: music.mediaID, mediaID: music.mediaID, title: music.title, artist: music.artist, duration: 0)
    }

    private var item: ChatMusicItem {
        ChatMusicItem(messageID: "", attachment: ChatAttachment(kind: .audio, mediaID: music.mediaID, title: music.title, artist: music.artist),
                      track: track, mine: false)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            FullPlayerSheet(items: [item], addToProfile: { _ in
                (try? await session.socialRepo.addSoundToProfile(mediaID: music.mediaID, title: music.title, artist: music.artist)) != nil
            })
            .environmentObject(session.player)
            Button { showVideos = true } label: {
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(.white.opacity(0.16), in: Circle())
                    .frame(width: 52, height: 52).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8).padding(.trailing, 10)
        }
        .onAppear { if session.player.current?.id != track.id { session.player.start(track, queue: [track]) } }
        .fullScreenCover(isPresented: $showVideos) {
            ReelMusicPage(music: music)
                .environmentObject(session).environmentObject(flow)
                .environment(\.theme, theme).environment(\.lang, lang)
        }
    }
}
