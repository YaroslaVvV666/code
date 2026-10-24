import SwiftUI
import Photos
import UIKit

/// Меню скрепки, как в Telegram: сетка недавних фото и видео, внизу вкладки «Галерея / Файл / Опрос».
/// Шторка двигается: тянешь вверх — на весь экран, вниз — прячется.
struct AttachSheet: View {
    var canPoll: Bool
    var maxCount = 10
    var onAssets: ([PHAsset]) -> Void
    var onFiles: () -> Void
    var onPoll: () -> Void
    var onPhoto: (Data) -> Void = { _ in }
    var onVideo: (URL) -> Void = { _ in }
    var onSystemPicker: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    private enum Filter { case all, photos, videos }

    @State private var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var assets: [PHAsset] = []
    @State private var selected: [String] = []
    @State private var filter: Filter = .all
    @ObservedObject private var camera = AttachCamera.shared
    @State private var showCamera = false
    @State private var leaving = false
    private var s: Strings { Strings(lang: lang) }

    private var allowed: Bool { status == .authorized || status == .limited }
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 2), count: 3) }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                if allowed {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            if filter == .all || filter == .photos, !camera.denied {
                                CameraTile(camera: camera) {
                                    showCamera = true
                                }
                            }
                            ForEach(assets, id: \.localIdentifier) { asset in cell(asset) }
                        }
                        .padding(.bottom, 110)
                    }
                    .overlay {
                        if assets.isEmpty {
                            Text(s.t("Здесь пока пусто", "Nothing here yet")).font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                        }
                    }
                } else {
                    denied
                }
            }
            bottomBar
        }
        .background(theme.sheet.ignoresSafeArea())
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .fullScreenCover(isPresented: $showCamera, onDismiss: { if !leaving { camera.start() } }) {
            if false {
                SystemCameraView(onImage: { data in
                    leaving = true; showCamera = false; dismiss(); onPhoto(data)
                }, onVideo: { url in
                    leaving = true; showCamera = false; dismiss(); onVideo(url)
                }, onCancel: { showCamera = false })
                .ignoresSafeArea()
                .overlay { CameraLaunchCover() }
            } else {
                CameraCaptureView(camera: camera, onPhoto: { data in
                    leaving = true; showCamera = false; dismiss(); onPhoto(data)
                }, onVideo: { url in
                    leaving = true; showCamera = false; dismiss(); onVideo(url)
                }, onClose: { camera.setZoom(1); showCamera = false })
            }
        }
        .task {
            if status == .notDetermined {
                status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            reload()
        }
        .onChange(of: filter) { _, _ in reload() }
    }

    // MARK: Верх

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).foregroundStyle(theme.text)
                    .frame(width: 44, height: 44).glassCircle()
                    .frame(width: 54, height: 54).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Menu {
                Button { filter = .all } label: { Label(s.t("Недавние", "Recents"), systemImage: filter == .all ? "checkmark" : "clock") }
                Button { filter = .photos } label: { Label(s.t("Фото", "Photos"), systemImage: filter == .photos ? "checkmark" : "photo") }
                Button { filter = .videos } label: { Label(s.t("Видео", "Videos"), systemImage: filter == .videos ? "checkmark" : "video") }
                if status == .limited {
                    Button { onSystemPicker() } label: { Label(s.t("Выбрать из всей галереи", "Pick from library"), systemImage: "photo.on.rectangle") }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(theme.text)
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.textSecondary)
                }
            }
            Spacer()
            Color.clear.frame(width: 54, height: 54)
        }
        .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
    }

    private var title: String {
        switch filter {
        case .all: return s.t("Недавние", "Recents")
        case .photos: return s.t("Фото", "Photos")
        case .videos: return s.t("Видео", "Videos")
        }
    }

    // MARK: Ячейка

    private func cell(_ asset: PHAsset) -> some View {
        let index = selected.firstIndex(of: asset.localIdentifier)
        return Color.clear
            .aspectRatio(0.78, contentMode: .fit)
            .overlay { AssetThumb(asset: asset) }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .video {
                    Text(mmss(Int(asset.duration.rounded())))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                ZStack {
                    Circle().fill(index != nil ? theme.accentColor : Color.black.opacity(0.18))
                    Circle().stroke(.white, lineWidth: 2)
                    if let index { Text("\(index + 1)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white) }
                }
                .frame(width: 26, height: 26)
                .padding(8)
            }
            .overlay { if index != nil { Color.black.opacity(0.18).allowsHitTesting(false) } }
            .contentShape(Rectangle())
            .onTapGesture { toggle(asset) }
    }

    private func toggle(_ asset: PHAsset) {
        Haptics.impact(.light)
        let id = asset.localIdentifier
        if let i = selected.firstIndex(of: id) { selected.remove(at: i) }
        else if selected.count < maxCount { selected.append(id) }
        else { Haptics.notify(.warning) }
    }

    // MARK: Низ

    @ViewBuilder
    private var bottomBar: some View {
        if !selected.isEmpty {
            Button {
                let chosen = selected.compactMap { id in assets.first { $0.localIdentifier == id } }
                dismiss()
                onAssets(chosen)
            } label: {
                Text(s.t("Добавить", "Add") + " (\(selected.count))")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(theme.accent, in: Capsule())
                    .shadow(color: theme.accentColor.opacity(0.4), radius: 10, y: 4)
            }
            .buttonStyle(PressStyle())
            .padding(.horizontal, 16).padding(.bottom, 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            HStack(spacing: 0) {
                tab("photo.on.rectangle.fill", s.t("Галерея", "Gallery"), on: true) { }
                tab("doc.fill", s.attachFile, on: false) { dismiss(); onFiles() }
                if canPoll { tab("chart.bar.fill", s.t("Опрос", "Poll"), on: false) { dismiss(); onPoll() } }
            }
            .padding(6)
            .glass(Capsule())
            .padding(.horizontal, 16).padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func tab(_ icon: String, _ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 22, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(on ? theme.accentColor : theme.textSecondary)
            .frame(maxWidth: .infinity).frame(height: 56)
            .background(on ? theme.accentColor.opacity(0.16) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var denied: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40, weight: .light)).foregroundStyle(theme.textTertiary)
            Text(s.t("Нет доступа к фото", "No access to photos")).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text(s.t("Открыть настройки", "Open Settings")).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 20).frame(height: 42).background(theme.accent, in: Capsule())
            }
            .buttonStyle(PressStyle())
            Button { onSystemPicker() } label: {
                Text(s.t("Выбрать через системное окно", "Use the system picker")).font(.system(size: 15)).foregroundStyle(theme.accentColor)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Данные

    private func reload() {
        guard allowed else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 400
        switch filter {
        case .all: options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        case .photos: options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .videos: options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        }
        let result = PHAsset.fetchAssets(with: options)
        var list: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        assets = list
    }
}

/// Миниатюра из галереи
private struct AssetThumb: View {
    let asset: PHAsset
    @State private var image: UIImage?
    private static let manager = PHCachingImageManager()

    var body: some View {
        GeometryReader { g in
            ZStack {
                Color.gray.opacity(0.2)
                if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped() }
            }
        }
        .task(id: asset.localIdentifier) {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            Self.manager.requestImage(for: asset, targetSize: CGSize(width: 360, height: 480), contentMode: .aspectFill, options: options) { img, _ in
                if let img { DispatchQueue.main.async { image = img } }
            }
        }
    }
}

/// Превращает выбранные в галерее фото и видео в вложения
enum AssetLoader {
    struct Failure: Error {}

    static func prepare(_ asset: PHAsset) async throws -> PreparedMedia {
        if asset.mediaType == .video {
            let file = try await videoFile(asset)
            defer { try? FileManager.default.removeItem(at: file) }
            return try await MediaPreparer.prepare(videoFile: file)
        }
        let image = try await fullImage(asset)
        guard let jpeg = image.jpegData(compressionQuality: 0.92), let data = ImageProcessing.prepare(jpeg) else { throw Failure() }
        return try MediaPreparer.prepareImage(data)
    }

    private static func fullImage(_ asset: PHAsset) async throws -> UIImage {
        try await withCheckedThrowingContinuation { c in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = true
            var done = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 2400, height: 2400), contentMode: .aspectFit, options: options) { img, info in
                guard !done else { return }
                if let img, (info?[PHImageResultIsDegradedKey] as? Bool) != true { done = true; c.resume(returning: img) }
                else if img == nil { done = true; c.resume(throwing: Failure()) }
            }
        }
    }

    private static func videoFile(_ asset: PHAsset) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizeVideo }) ?? resources.first(where: { $0.type == .video }) else { throw Failure() }
        let ext = (resource.originalFilename as NSString).pathExtension
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pick-\(UUID().uuidString).\(ext.isEmpty ? "mov" : ext)")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        return try await withCheckedThrowingContinuation { c in
            PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options) { error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: file) }
            }
        }
    }
}


/// Пока системная камера запускается (до ~секунды), вместо пустого чёрного экрана — «Камера…» с крутилкой
private struct CameraLaunchCover: View {
    @Environment(\.lang) private var lang
    @State private var visible = true
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(.white).scaleEffect(1.3)
                Text(Strings(lang: lang).t("Открываем камеру…", "Opening camera…"))
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation(.easeOut(duration: 0.25)) { visible = false }
        }
    }
}
