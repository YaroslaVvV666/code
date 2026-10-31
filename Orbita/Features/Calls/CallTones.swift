import AVFoundation

/// Мягкие мелодии звонка, которые рисуются прямо в коде (без файлов): колокольчик с плавной атакой и затуханием.
/// Аудио- и видеозвонок звучат по-разному, а в конце — короткий нисходящий «отбой».
@MainActor
final class CallTones {
    static let shared = CallTones()

    enum Kind { case incomingVoice, incomingVideo, outgoingVoice, outgoingVideo, end }

    private var player: AVAudioPlayer?
    private var cache: [String: Data] = [:]
    private let rate = 44_100.0

    // MARK: Ноты

    private func hz(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }

    /// Колокольчик: основной тон + мягкие обертоны, быстрая плавная атака, экспоненциальное затухание
    private func bell(into buf: inout [Float], at start: Double, midi: Double, length: Double, gain: Float) {
        let f = hz(midi)
        let first = Int(start * rate)
        let n = Int(length * rate)
        for i in 0..<n where first + i < buf.count {
            let t = Double(i) / rate
            let attack = min(1, t / 0.012)
            let decay = exp(-t * (3.2 / length) * 2.1)
            let tone = sin(2 * .pi * f * t) + 0.28 * sin(2 * .pi * f * 2 * t) * exp(-t * 6) + 0.10 * sin(2 * .pi * f * 3.01 * t) * exp(-t * 9)
            buf[first + i] += Float(tone * attack * decay) * gain
        }
    }

    private func wav(_ samples: [Float]) -> Data {
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices { pcm[i] = Int16(max(-1, min(1, samples[i])) * 32_000) }
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(pcm.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(bytes)
        pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }

    private func make(_ kind: Kind) -> Data {
        let key = "\(kind)"
        if let c = cache[key] { return c }
        let seconds: Double
        switch kind {
        case .incomingVoice: seconds = 3.2
        case .incomingVideo: seconds = 2.6
        case .outgoingVoice: seconds = 4.0
        case .outgoingVideo: seconds = 3.6
        case .end: seconds = 0.9
        }
        var b = [Float](repeating: 0, count: Int(seconds * rate))
        switch kind {
        case .incomingVoice:       // спокойный восходящий аккорд: ми – соль – си – ми
            for (i, m) in [64.0, 67, 71, 76].enumerated() { bell(into: &b, at: Double(i) * 0.26, midi: m, length: 1.6, gain: 0.30) }
        case .incomingVideo:       // более лёгкая и «прыгучая»: до – ми – соль – до – соль
            for (i, m) in [72.0, 76, 79, 84, 79].enumerated() { bell(into: &b, at: Double(i) * 0.17, midi: m, length: 1.2, gain: 0.26) }
        case .outgoingVoice:       // тёплые долгие гудки: два мягких тона
            for s in [0.0, 0.55] { bell(into: &b, at: s, midi: 69, length: 1.4, gain: 0.26); bell(into: &b, at: s, midi: 76, length: 1.2, gain: 0.10) }
        case .outgoingVideo:       // чуть выше и короче
            for s in [0.0, 0.40] { bell(into: &b, at: s, midi: 74, length: 1.0, gain: 0.24); bell(into: &b, at: s, midi: 81, length: 0.9, gain: 0.09) }
        case .end:                 // мягкий нисходящий отбой
            bell(into: &b, at: 0.0, midi: 79, length: 0.5, gain: 0.30)
            bell(into: &b, at: 0.17, midi: 72, length: 0.6, gain: 0.30)
        }
        let data = wav(b)
        cache[key] = data
        return data
    }

    // MARK: Управление

    /// Играть: зацикленно (звонок) или один раз (отбой)
    func play(_ kind: Kind, takeOverSession: Bool) {
        stop()
        if takeOverSession {
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? s.setActive(true)
        }
        guard let p = try? AVAudioPlayer(data: make(kind)) else { return }
        p.numberOfLoops = kind == .end ? 0 : -1
        p.volume = kind == .end ? 0.8 : 0.9
        p.prepareToPlay()
        p.play()
        player = p
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
