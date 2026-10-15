import SwiftUI
import PhotosUI
import AVFoundation

/// Публикация шортса — отдельно от обычных постов: одно вертикальное видео (до 3 минут) и подпись
struct ReelComposerView: View {
    var onPosted: () async -> Void

    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var showEditor = false
    @State private var editModel: ReelEditModel?
    @State private var original: PreparedMedia?
    @State private var prepared: PreparedMedia?
    @State private var preparing = false
    @State private var caption = ""
    @State private var uploading = false
    @State private var errorText: String?
    @State private var tracks: [Track] = []
    @State private var music: Track?
    @FocusState private var focused: Bool

    private let maxSeconds: Double = 180
    private let maxCaption = 300
    private var s: Strings { Strings(lang: lang) }
    private var canPost: Bool { prepared != nil && !uploading && !preparing }

    private var aspectOK: Bool {
        guard let p = prepared, p.height > 0 else { return true }
        return Double(p.width) / Double(p.height) < 0.7
    }

    var body: some View {
        ZStack {
            SpaceBackground(isDark: theme.dark, showStars: false).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 18) {
                        videoCard
                        editRow
                        captionField
                        hints
                        if let errorText {
                            Text(errorText).font(.system(size: 14)).foregroundStyle(theme.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 30)
                }
                .scrollDismissesKeyboard(.interactively)
                publishBar
            }
        }
        .preferredColorScheme(theme.dark ? .dark : .light)
        .photosPicker(isPresented: $showPicker, selection: $pickerItems, maxSelectionCount: 10,
                      matching: .any(of: [.videos, .images]), photoLibrary: .shared())
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            let picked = items
            Task { await load(picked) }
        }
        .fullScreenCover(isPresented: $showEditor) {
            if let editModel {
                ReelEditorView(model: editModel, tracks: tracks, onDone: { media, track in editorFinished(media, track) },
                               onClose: { showEditor = false; if prepared == nil { discard() } })
            }
        }
        .onDisappear { if !showEditor { discard() } }
        .task {
            if let list = try? await session.socialRepo.playlist(userID: session.serverID) { tracks = list }
        }
    }

    /// Кнопки под превью: открыть редактор или заменить исходник
    @ViewBuilder
    private var editRow: some View {
        if prepared != nil {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button { showEditor = true } label: {
                        Label(s.t("Редактировать", "Edit"), systemImage: "wand.and.stars")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 42)
                            .background(theme.accent, in: Capsule())
                    }
                    .buttonStyle(PressStyle())
                    Button { showPicker = true } label: {
                        Label(s.t("Заменить", "Replace"), systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
                            .frame(maxWidth: .infinity).frame(height: 42)
                            .card(theme, radius: 21)
                    }
                    .buttonStyle(PressStyle())
                }
                .disabled(uploading)
                if let music {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note").foregroundStyle(theme.accentColor)
                        Text(music.display).font(.system(size: 14)).foregroundStyle(theme.textSecondary).lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: Части экрана

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.text)
                    .frame(width: 38, height: 38).glassCircle()
            }
            .buttonStyle(PressStyle())
            .disabled(uploading)
            Spacer()
            Text(s.t("Новый шортс", "New short")).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 8)
    }

    private var videoCard: some View {
        let width: CGFloat = 200, height = width * 16 / 9
        return Button {
            if prepared != nil { showEditor = true } else { showPicker = true }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(theme.surface)
                if let prepared, let image = UIImage(data: prepared.thumbnail) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: width, height: height).clipped()
                        .overlay(alignment: .bottomTrailing) {
                            if let d = prepared.duration {
                                Text(clock(d)).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(.black.opacity(0.55), in: Capsule()).padding(10)
                            }
                        }
                } else if preparing {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(s.t("Готовим видео…", "Preparing video…")).font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "video.badge.plus").font(.system(size: 38, weight: .light)).foregroundStyle(theme.accentColor)
                        Text(s.t("Выбрать видео или фото", "Choose video or photos")).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                        Text(s.t("Видео до 3 минут или несколько фото", "Video up to 3 min, or several photos")).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    }
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(uploading)
    }

    private var captionField: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextField(s.t("Описание и #хэштеги", "Caption and #hashtags"), text: $caption, axis: .vertical)
                .lineLimit(2...6)
                .focused($focused)
                .font(.system(size: 16)).foregroundStyle(theme.text)
                .padding(14).card(theme, radius: 16)
                .onChange(of: caption) { _, v in if v.count > maxCaption { caption = String(v.prefix(maxCaption)) } }
            Text("\(caption.count)/\(maxCaption)").font(.system(size: 12).monospacedDigit()).foregroundStyle(theme.textTertiary)
        }
    }

    @ViewBuilder
    private var hints: some View {
        VStack(alignment: .leading, spacing: 8) {
            if prepared != nil && !aspectOK {
                hint("exclamationmark.triangle.fill", s.t("Видео не вертикальное: на весь экран оно не растянется, по бокам будут чёрные полосы. Лучше снять в формате 9:16.",
                                                          "This video isn't vertical, so it won't fill the screen — expect black bars. 9:16 works best."),
                     color: .orange)
            }
            hint("sparkles", s.t("Шортс появится в ленте «Шортс» и у друзей. В обычную ленту постов он не попадает.",
                                 "Your short appears in the Shorts feed and to friends. It isn't shown in the regular post feed."),
                 color: theme.accentColor)
        }
    }

    private func hint(_ icon: String, _ text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 14)).padding(.top, 2)
            Text(text).font(.system(size: 13)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var publishBar: some View {
        Button { publish() } label: {
            Group {
                if uploading { HStack(spacing: 8) { ProgressView().tint(.white); Text(s.t("Загружаем…", "Uploading…")) } }
                else { Text(s.t("Опубликовать", "Publish")) }
            }
            .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(canPost ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.textTertiary.opacity(0.5)), in: Capsule())
        }
        .buttonStyle(PressStyle())
        .disabled(!canPost)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: Логика

    private func clock(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private func load(_ items: [PhotosPickerItem]) async {
        errorText = nil
        preparing = true
        discard()
        defer { preparing = false; pickerItems = [] }
        do {
            if let video = items.first(where: { $0.supportedContentTypes.contains { $0.conforms(to: .movie) } }) {
                let media = try await MediaPreparer.prepare(video)
                guard case .video(let url) = media.source else { errorText = s.t("Нужно видео", "Please choose a video"); return }
                original = media
                prepared = media
                editModel = ReelEditModel(video: url)
            } else {
                var images: [UIImage] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let jpeg = ImageProcessing.prepare(data, maxSide: 1600), let image = UIImage(data: jpeg) { images.append(image) }
                }
                guard !images.isEmpty else { errorText = s.t("Не удалось открыть фото", "Couldn't open the photos"); return }
                editModel = ReelEditModel(photos: images)
            }
            Haptics.impact(.light)
            showEditor = true
        } catch MediaError.tooLarge {
            errorText = s.t("Видео слишком большое", "The video is too large")
        } catch MediaError.tooLong {
            errorText = s.t("Видео слишком длинное", "The video is too long")
        } catch {
            errorText = s.t("Не удалось подготовить видео", "Couldn't prepare the video")
        }
    }

    private func editorFinished(_ media: PreparedMedia?, _ track: Track?) {
        if let old = prepared, case .video(let u) = old.source {
            var keep = false
            if let o = original, case .video(let ou) = o.source, ou == u { keep = true }
            if !keep { try? FileManager.default.removeItem(at: u) }
        }
        prepared = media ?? original
        music = track
        showEditor = false
    }

    private func discard() {
        if let p = prepared, case .video(let url) = p.source { try? FileManager.default.removeItem(at: url) }
        if let o = original, case .video(let url) = o.source { try? FileManager.default.removeItem(at: url) }
        editModel?.cleanup()
        editModel = nil
        original = nil
        prepared = nil
        music = nil
    }

    private func publish() {
        guard let media = prepared else { return }
        focused = false
        uploading = true
        errorText = nil
        Task {
            defer { uploading = false }
            do {
                let item = try await session.feedRepo.uploadMedia(media)
                _ = try await session.extras.createReel(text: caption.trimmingCharacters(in: .whitespacesAndNewlines), media: item, musicTrack: music?.id)
                discard()
                Haptics.notify(.success)
                await onPosted()
                dismiss()
            } catch {
                Haptics.notify(.error)
                errorText = s.api((error as? APIError) ?? .offline)
            }
        }
    }
}
