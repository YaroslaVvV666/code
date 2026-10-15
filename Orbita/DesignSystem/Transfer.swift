import SwiftUI
import Combine

// MARK: - Анимация отправки / скачивания

/// Вращающаяся дуга — «отправляется». Без таймеров: одна бесконечная анимация на слой.
struct SpinnerRing: View {
    var size: CGFloat = 12
    var lineWidth: CGFloat = 1.6
    var color: Color = .white
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.85).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
            .drawingGroup()
    }
}

/// Кольцо прогресса с крестиком/стрелкой внутри. progress == nil — неопределённая загрузка.
struct TransferRing: View {
    var progress: Double?
    var icon: String = "arrow.down"
    var size: CGFloat = 42
    var tint: Color = .white
    var track: Color = Color.white.opacity(0.28)

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: 2.4)
            if let p = progress {
                Circle().trim(from: 0, to: max(0.04, min(1, p)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: p)
            } else {
                SpinnerRing(size: size, lineWidth: 2.4, color: tint)
            }
            Image(systemName: icon).font(.system(size: size * 0.34, weight: .bold)).foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

/// Живая «отправка» вместо часиков в метке времени сообщения
struct SendingIndicator: View {
    var color: Color
    var body: some View { SpinnerRing(size: 10, lineWidth: 1.4, color: color) }
}

/// Прогресс скачиваний по mediaID (общий для всех блоков)
@MainActor
final class DownloadCenter: ObservableObject {
    static let shared = DownloadCenter()
    @Published private(set) var progress: [String: Double] = [:]

    func set(_ id: String, _ value: Double?) {
        if let value {
            // не чаще ~50 обновлений на файл
            if let old = progress[id], abs(old - value) < 0.02, value < 1 { return }
            progress[id] = value
        } else {
            progress[id] = nil
        }
    }
}

final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    let id: String
    init(id: String) { self.id = id }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let id = id
        Task { @MainActor in DownloadCenter.shared.set(id, p) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
