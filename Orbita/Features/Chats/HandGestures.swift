import AVFoundation
import Combine
import Vision

/// Жесты рукой, которые ловим во время записи кружка, и эмодзи-эффект, который «вылетает».
enum HandGesture: String {
    case ok            // 👌  -> ✅
    case fingerHeart   // 🫰  -> 💸
    case peace         // ✌️  -> 😎
    case fingerGun     // 🔫  -> 🔫
    case handHeart     // ❤️ (две руки) -> ❤️

    var effect: String {
        switch self {
        case .ok:          return "✅"
        case .fingerHeart: return "💸"
        case .peace:       return "😎"
        case .fingerGun:   return "🔫"
        case .handHeart:   return "❤️"
        }
    }
}

struct GestureHit: Equatable {
    let id: Int
    let effect: String
}

/// Локальная настройка: можно ли показывать эффекты жестов в кружках (правится в «Конфиденциальности»).
enum GestureEffects {
    private static let key = "orbita.gestureEffects.enabled"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Ловит жесты руки по кадрам камеры (Vision) во время записи кружка.
/// Пороги распознавания подбираются на устройстве — тут консервативные значения.
final class HandGestureDetector: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Последний распознанный жест (id растёт — чтобы один и тот же жест запускал эффект заново).
    @Published private(set) var hit: GestureHit?

    /// Включается только на время записи кружка — иначе кадры не обрабатываем.
    var active = false

    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()
    private var counter = 0
    private var lastFire = Date.distantPast
    private var lastKind: HandGesture?
    private var frameSkip = 0

    /// Не чаще одного эффекта в ~2.2 c, чтобы не частило
    private let cooldown: TimeInterval = 2.2

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard active, GestureEffects.enabled else { return }
        frameSkip = (frameSkip + 1) % 3                       // ~каждый третий кадр — хватает, экономит CPU
        guard frameSkip == 0 else { return }
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .leftMirrored, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }
        guard let hands = request.results, !hands.isEmpty else { return }
        guard let kind = Self.classify(hands) else { return }
        let now = Date()
        if now.timeIntervalSince(lastFire) < cooldown && kind == lastKind { return }
        if now.timeIntervalSince(lastFire) < 0.8 { return }    // минимальный зазор между любыми эффектами
        lastFire = now
        lastKind = kind
        counter += 1
        let hitValue = GestureHit(id: counter, effect: kind.effect)
        DispatchQueue.main.async { [weak self] in self?.hit = hitValue }
    }

    // MARK: - Классификация

    private typealias Pts = [VNHumanHandPoseObservation.JointName: CGPoint]

    private static func points(_ obs: VNHumanHandPoseObservation) -> Pts {
        guard let all = try? obs.recognizedPoints(.all) else { return [:] }
        var out: Pts = [:]
        for (name, p) in all where p.confidence > 0.3 {
            out[name] = CGPoint(x: p.location.x, y: p.location.y)   // нормализованные [0..1]
        }
        return out
    }

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// Палец разогнут, если кончик дальше от запястья, чем средний сустав (и выше него)
    private static func extended(_ tip: CGPoint?, _ pip: CGPoint?, _ wrist: CGPoint?) -> Bool {
        guard let tip, let pip, let wrist else { return false }
        return dist(tip, wrist) > dist(pip, wrist) * 1.05
    }

    private static func classify(_ hands: [VNHumanHandPoseObservation]) -> HandGesture? {
        // Сердечко двумя руками: две ладони, кончики указательных рядом сверху
        if hands.count >= 2 {
            let a = points(hands[0]), b = points(hands[1])
            if let ia = a[.indexTip], let ib = b[.indexTip], let ta = a[.thumbTip], let tb = b[.thumbTip] {
                if dist(ia, ib) < 0.18 && dist(ta, tb) < 0.22 { return .handHeart }
            }
        }
        guard let obs = hands.first else { return nil }
        let p = points(obs)
        let wrist = p[.wrist]
        let indexExt  = extended(p[.indexTip], p[.indexPIP], wrist)
        let middleExt = extended(p[.middleTip], p[.middlePIP], wrist)
        let ringExt   = extended(p[.ringTip], p[.ringPIP], wrist)
        let littleExt = extended(p[.littleTip], p[.littlePIP], wrist)
        let thumbExt  = extended(p[.thumbTip], p[.thumbIP], wrist)
        let pinch = (p[.thumbTip].flatMap { t in p[.indexTip].map { dist(t, $0) } } ?? 1) < 0.07

        // 👌 — щепоть большого и указательного, остальные три разогнуты
        if pinch && middleExt && ringExt && littleExt { return .ok }
        // 🫰 — щепоть/скрещены большой и указательный, остальные согнуты
        if pinch && !middleExt && !ringExt { return .fingerHeart }
        // ✌️ — указательный и средний разогнуты, безымянный и мизинец согнуты
        if indexExt && middleExt && !ringExt && !littleExt { return .peace }
        // 🔫 — большой и указательный разогнуты «пистолетиком», остальные согнуты
        if indexExt && thumbExt && !middleExt && !ringExt && !littleExt { return .fingerGun }
        return nil
    }
}
