import SwiftUI
import UIKit

/// Эффект реакции на весь экран: крупная анимированная эмодзи по центру,
/// вокруг неё искры, а снизу вверх вылетает стайка таких же эмодзи (как в Telegram и Max)
struct ReactionFX: Identifiable, Equatable {
    let id = UUID()
    let emoji: String
    var messageID: String = ""
    /// Реакцию поставил собеседник (пришла с сервера): эффект — только если сообщение сейчас видно на экране
    var incoming = false
}

/// Положение сообщений на экране (экранные координаты): эффект реакции вылетает прямо из нужного сообщения,
/// меню по зажатию открывается на месте пузыря.
///
/// Раньше каждая видимая строка на КАЖДОМ кадре прокрутки пересчитывала свою рамку (GeometryReader + preference),
/// и словарь всех рамок гонялся через дерево вью — заметная часть стоимости прокрутки переписки.
/// Теперь в фоне строки лежит невидимая UIView-«зонд», а рамку у неё спрашиваем только когда она нужна
/// (зажали сообщение, прилетела реакция, рассыпаем удалённое). Во время прокрутки — ноль работы.
@MainActor
final class MessageFrameProbes {
    static let shared = MessageFrameProbes()
    private final class Weak { weak var view: UIView?; init(_ v: UIView) { view = v } }
    private var probes: [String: [Weak]] = [:]
    private var adds = 0

    func register(_ id: String, _ view: UIView) {
        var list = probes[id, default: []].filter { $0.view != nil && $0.view !== view }
        list.append(Weak(view))
        probes[id] = list
        adds += 1
        if adds % 400 == 0 { compact() }
    }

    func unregister(_ id: String, _ view: UIView) {
        guard var list = probes[id] else { return }
        list.removeAll { $0.view == nil || $0.view === view }
        probes[id] = list.isEmpty ? nil : list
    }

    /// Рамка в координатах окна (то же, что .global у SwiftUI). Берём последнюю видимую в окне копию
    func frame(_ id: String) -> CGRect? {
        guard let list = probes[id] else { return nil }
        for w in list.reversed() {
            guard let v = w.view, let window = v.window, !v.isHidden else { continue }
            let r = v.convert(v.bounds, to: window)
            if r.width > 0 || r.height > 0 { return r }
        }
        return nil
    }

    private func compact() {
        probes = probes.compactMapValues { list in
            let alive = list.filter { $0.view != nil }
            return alive.isEmpty ? nil : alive
        }
    }
}

/// Невидимый зонд в фоне строки / чипа реакции
struct FrameProbe: UIViewRepresentable {
    let id: String

    final class ProbeView: UIView {
        var probeID = ""
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.probeID = id
        MessageFrameProbes.shared.register(id, v)
        return v
    }

    func updateUIView(_ v: ProbeView, context: Context) {
        guard v.probeID != id else { return }
        MessageFrameProbes.shared.unregister(v.probeID, v)
        v.probeID = id
        MessageFrameProbes.shared.register(id, v)
    }

    static func dismantleUIView(_ v: ProbeView, coordinator: ()) {
        MessageFrameProbes.shared.unregister(v.probeID, v)
    }
}

/// Доступ к рамкам «по ключу» — как раньше словарь, но считается в момент обращения
@MainActor
final class MessageFrameStore {
    struct Lookup {
        subscript(_ id: String) -> CGRect? { MessageFrameProbes.shared.frame(id) }
    }
    var frames: Lookup { Lookup() }
}

struct ReactionEffectLayer: View {
    let fx: ReactionFX
    var origin: () -> CGPoint? = { nil }   // откуда вылетает: значок реакции; нет — по центру экрана
    let onDone: () -> Void

    private struct Item {
        let dx: CGFloat
        let sway: CGFloat
        let rise: CGFloat
        let size: CGFloat
        let delay: Double
        let life: Double
        let phase: Double
        let angle: Double
        let spark: Bool
    }

    private let items: [Item]
    @State private var start = Date().addingTimeInterval(0.12)     // чуть ждём, пока значок реакции встанет на место

    init(fx: ReactionFX, origin: @escaping () -> CGPoint? = { nil }, onDone: @escaping () -> Void) {
        self.fx = fx
        self.origin = origin
        self.onDone = onDone
        var list: [Item] = []
        for _ in 0..<14 {
            list.append(Item(dx: .random(in: -48...48), sway: .random(in: 3...9), rise: .random(in: 50...120),
                             size: .random(in: 11...21), delay: .random(in: 0...0.25), life: .random(in: 0.8...1.3),
                             phase: .random(in: 0...6.28), angle: 0, spark: false))
        }
        for i in 0..<7 {
            list.append(Item(dx: .random(in: 26...48), sway: 0, rise: 0, size: .random(in: 9...14),
                             delay: .random(in: 0...0.12), life: .random(in: 0.5...0.8), phase: 0,
                             angle: Double(i) / 7 * 6.283 + .random(in: -0.25...0.25), spark: true))
        }
        items = list
    }

    /// Точка вылета, прижатая к экрану, чтобы эффект не уезжал за край
    private func anchor(_ size: CGSize) -> CGPoint {
        guard let o = origin() else { return CGPoint(x: size.width / 2, y: size.height * 0.55) }
        return CGPoint(x: min(max(o.x, 30), size.width - 30), y: min(max(o.y, 130), size.height - 90))
    }

    /// Символы рисуются один раз этого размера (чуть крупнее самой большой частицы), а дальше только уменьшаются
    private static let emojiBase: CGFloat = 26
    private static let sparkBase: CGFloat = 18
    /// Все частицы гаснут к ~1.67 с (старт +0.12, задержка до 0.25, жизнь до 1.3); дольше слой не держим
    private static let lifetime: Double = 1.8

    var body: some View {
        // Один Canvas вместо 21 отдельного Text: эмодзи не набираются шрифтом заново на каждом кадре,
        // а рисуются готовыми символами; 60 кадров в секунду хватает, на ProMotion не гоним 120
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { tl in
            Canvas { ctx, size in
                guard let emoji = ctx.resolveSymbol(id: 0), let spark = ctx.resolveSymbol(id: 1) else { return }
                let t = tl.date.timeIntervalSince(start)
                let a = anchor(size)                         // точка вылета — один раз за кадр, а не для каждой частицы
                for item in items {
                    draw(item, t: t, anchor: a, in: ctx, emoji: emoji, spark: spark)
                }
            } symbols: {
                Text(fx.emoji).font(.system(size: Self.emojiBase)).tag(0)
                Text("✨").font(.system(size: Self.sparkBase)).tag(1)
            }
        }
        .allowsHitTesting(false)
        .task {
            try? await Task.sleep(nanoseconds: UInt64(Self.lifetime * 1_000_000_000))
            onDone()
        }
    }

    private func draw(_ item: Item, t: Double, anchor a: CGPoint, in ctx: GraphicsContext,
                      emoji: GraphicsContext.ResolvedSymbol, spark: GraphicsContext.ResolvedSymbol) {
        let age = t - item.delay
        let p = CGFloat(age / item.life)
        guard age > 0, p < 1 else { return }
        let fadeIn = min(1, p / 0.12)
        let fadeOut = p > 0.7 ? (1 - p) / 0.3 : 1
        let eased = 1 - (1 - p) * (1 - p)
        var c = ctx
        c.opacity = Double(fadeIn * fadeOut)
        if item.spark {
            let cx = a.x + CGFloat(cos(item.angle)) * item.dx * eased
            let cy = a.y + CGFloat(sin(item.angle)) * item.dx * eased
            let scale = (0.5 + 0.8 * (1 - abs(p - 0.4))) * item.size / Self.sparkBase
            c.translateBy(x: cx, y: cy)
            c.scaleBy(x: scale, y: scale)
            c.draw(spark, at: .zero, anchor: .center)
        } else {
            let x = a.x + item.dx * (0.3 + 0.7 * eased) + item.sway * CGFloat(sin(item.phase + Double(p) * 7))
            let y = a.y - item.rise * eased
            let scale = (0.5 + 0.6 * min(1, p * 4)) * item.size / Self.emojiBase
            c.translateBy(x: x, y: y)
            c.rotate(by: .degrees(Double(item.dx) * 0.12 * Double(p)))
            c.scaleBy(x: scale, y: scale)
            c.draw(emoji, at: .zero, anchor: .center)
        }
    }
}
