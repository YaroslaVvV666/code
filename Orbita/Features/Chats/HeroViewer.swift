import SwiftUI
import UIKit

// MARK: - Откуда «вылетает» фото (как в Telegram)

/// Рамка и картинка превью, с которого нажали. Пишется в момент нажатия и забирается при открытии просмотра.
final class HeroSource: @unchecked Sendable {
    static let shared = HeroSource()
    struct Snapshot {
        let id: String?
        let rect: CGRect
        let image: UIImage?
    }
    private var snapshot: Snapshot?
    func set(id: String?, rect: CGRect, image: UIImage?) { snapshot = Snapshot(id: id, rect: rect, image: image) }
    func take() -> Snapshot? { defer { snapshot = nil }; return snapshot }
}

/// Хранит UIView ячейки, чтобы в момент нажатия узнать её положение на экране (без слежения за прокруткой)
final class FrameBox {
    weak var view: UIView?
    var rect: CGRect { view.map { $0.convert($0.bounds, to: nil) } ?? .zero }
}

final class FrameBoxes {
    private var boxes: [Int: FrameBox] = [:]
    func box(_ i: Int) -> FrameBox {
        if let b = boxes[i] { return b }
        let b = FrameBox()
        boxes[i] = b
        return b
    }
}

struct FrameProbe: UIViewRepresentable {
    let box: FrameBox
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        box.view = v
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) { box.view = uiView }
}

// MARK: - Просмотр с «вылетом»

struct HeroViewerHost: View {
    let media: [MediaItem]
    let start: Int
    var meta: [MediaMeta] = []
    let hero: HeroSource.Snapshot?
    let onClose: () -> Void

    @State private var progress: CGFloat = 0
    @State private var ready = false
    @State private var closing = false
    @State private var fadeOut = false
    @State private var fly = false
    @State private var index: Int

    init(media: [MediaItem], start: Int, meta: [MediaMeta] = [], hero: HeroSource.Snapshot?, onClose: @escaping () -> Void) {
        self.media = media
        self.start = start
        self.meta = meta
        self.hero = hero
        self.onClose = onClose
        _index = State(initialValue: start)
    }

    private var heroImage: UIImage? {
        guard let hero, let image = hero.image, hero.rect.width > 1, media.indices.contains(start),
              hero.id == nil || hero.id == media[start].id else { return nil }
        return image
    }

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                Color.black.opacity(Double(ready && !closing ? 1 : progress)).ignoresSafeArea()

                MediaViewer(media: media, start: start, meta: meta, embedded: true,
                            pagesVisible: ready && !closing, flyIn: fly,
                            onClose: close, onIndex: { index = $0 })

                if (!ready || closing), let image = heroImage, let hero {
                    heroLayer(image, hero: hero, origin: origin, size: geo.size)
                }
            }
            .opacity(fadeOut ? 0 : 1)
            .scaleEffect(fadeOut ? 0.94 : 1)
        }
        .onAppear(perform: open)
    }

    private func heroLayer(_ image: UIImage, hero: HeroSource.Snapshot, origin: CGPoint, size: CGSize) -> some View {
        let ar = max(0.05, image.size.width / max(image.size.height, 1))
        let fit: CGSize = size.width / size.height > ar ? CGSize(width: size.height * ar, height: size.height)
                                                       : CGSize(width: size.width, height: size.width / ar)
        let end = CGRect(x: (size.width - fit.width) / 2, y: (size.height - fit.height) / 2, width: fit.width, height: fit.height)
        let from = CGRect(x: hero.rect.minX - origin.x, y: hero.rect.minY - origin.y, width: hero.rect.width, height: hero.rect.height)
        let p = progress
        let r = CGRect(x: from.minX + (end.minX - from.minX) * p, y: from.minY + (end.minY - from.minY) * p,
                       width: from.width + (end.width - from.width) * p, height: from.height + (end.height - from.height) * p)
        return Image(uiImage: image)
            .resizable().scaledToFill()
            .frame(width: max(r.width, 1), height: max(r.height, 1))
            .clipShape(RoundedRectangle(cornerRadius: 16 * (1 - p), style: .continuous))
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(false)
    }

    private func open() {
        if heroImage != nil {
            withAnimation(.spring(response: 0.44, dampingFraction: 0.86)) { progress = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) { fly = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { ready = true }
            }
        } else {
            progress = 1
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { ready = true }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { fly = true }
        }
    }

    private func close() {
        Haptics.impact(.light)
        withAnimation(.easeIn(duration: 0.18)) { fly = false }
        if heroImage != nil, index == start, ready {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { closing = true }
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { progress = 0 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { onClose() }
        } else {
            withAnimation(.easeIn(duration: 0.22)) { fadeOut = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { onClose() }
        }
    }
}
