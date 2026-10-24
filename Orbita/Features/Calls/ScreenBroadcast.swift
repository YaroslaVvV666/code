import SwiftUI
import UIKit
import ReplayKit
import CoreVideo
import Darwin

/// Показ ВСЕГО экрана, в том числе когда приложение свёрнуто: системное окно «Начать вещание» запускает расширение
/// (Extension/Broadcast), оно шлёт кадры сюда по локальному сокету в общей папке App Group.
/// Приложение остаётся живым в фоне, пока идёт звонок (аудиорежим), поэтому кадры продолжают уходить собеседнику.
final class ScreenBroadcast {
    static let shared = ScreenBroadcast()

    /// Расширение вложено в приложение и App Group настроена — иначе работает показ только экрана самого приложения
    static var available: Bool { shared.extensionID != nil && shared.socketPath != nil }

    private(set) var extensionID: String?
    private var group: String { "group." + (Bundle.main.bundleIdentifier ?? "") }
    private(set) var socketPath: String?

    private var listener: Int32 = -1
    private var client: Int32 = -1
    private var running = false
    private let queue = DispatchQueue(label: "orbita.screenbroadcast")
    private var onFrame: ((CVPixelBuffer, Int64) -> Void)?
    private var onStart: (() -> Void)?
    private var onEnd: (() -> Void)?

    private init() {
        if let plugins = Bundle.main.builtInPlugInsURL,
           let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) {
            for url in items where url.pathExtension == "appex" {
                if let b = Bundle(url: url), let ext = b.infoDictionary?["NSExtension"] as? [String: Any],
                   (ext["NSExtensionPointIdentifier"] as? String) == "com.apple.broadcast-services-upload" {
                    extensionID = b.bundleIdentifier
                }
            }
        }
        if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            socketPath = dir.appendingPathComponent("s").path
        }
    }

    // MARK: Приём кадров

    /// Начинаем слушать сокет и показываем системное окно запуска вещания
    func begin(onStart: @escaping () -> Void, onFrame: @escaping (CVPixelBuffer, Int64) -> Void, onEnd: @escaping () -> Void) -> Bool {
        guard let path = socketPath, let ext = extensionID else { return false }
        stop(notify: false)
        self.onStart = onStart; self.onFrame = onFrame; self.onEnd = onEnd
        unlink(path)
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(sock); return false }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: bytes.count) { p in for i in 0..<bytes.count { p[i] = bytes[i] } }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, len) == 0 } }
        guard bound, listen(sock, 1) == 0 else { close(sock); return false }
        listener = sock
        running = true
        queue.async { [weak self] in self?.acceptLoop(sock) }
        Self.presentPicker(extensionID: ext)
        return true
    }

    /// Остановить показ: расширению отправляется Darwin-уведомление, сокет закрывается
    func stop(notify: Bool = true) {
        running = false
        if notify {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFNotificationName((group + ".stop") as CFString), nil, nil, true)
        }
        if client >= 0 { shutdown(client, SHUT_RDWR); close(client); client = -1 }
        if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener); listener = -1 }
        if let p = socketPath { unlink(p) }
    }

    private func acceptLoop(_ sock: Int32) {
        let c = accept(sock, nil, nil)
        guard c >= 0, running else { return }
        client = c
        DispatchQueue.main.async { self.onStart?() }
        var header = [UInt8](repeating: 0, count: 4)
        while running {
            guard readFully(c, &header, 4) else { break }
            let n = Int(UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3]))
            guard n > 0, n < 4_000_000 else { break }
            var data = [UInt8](repeating: 0, count: n)
            guard readFully(c, &data, n) else { break }
            if let buffer = Self.pixelBuffer(fromJPEG: Data(data)) {
                let ns = Int64(CACurrentMediaTime() * 1_000_000_000)
                onFrame?(buffer, ns)
            }
        }
        let wasRunning = running
        stop(notify: false)
        if wasRunning { DispatchQueue.main.async { self.onEnd?() } }
    }

    private func readFully(_ fd: Int32, _ buf: UnsafeMutablePointer<UInt8>, _ count: Int) -> Bool {
        var got = 0
        while got < count {
            let n = read(fd, buf + got, count - got)
            if n <= 0 { return false }
            got += n
        }
        return true
    }

    private static func pixelBuffer(fromJPEG data: Data) -> CVPixelBuffer? {
        guard let image = UIImage(data: data)?.cgImage else { return nil }
        let w = image.width & ~1, h = image.height & ~1
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer
    }

    // MARK: Системное окно «Начать вещание»

    /// У RPSystemBroadcastPickerView нет публичного способа открыть окно кодом: нажимаем его внутреннюю кнопку
    @MainActor
    private static func presentPicker(extensionID: String) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.keyWindow else { return }
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: -100, y: -100, width: 44, height: 44))
        picker.preferredExtension = extensionID
        picker.showsMicrophoneButton = false
        window.addSubview(picker)
        for case let button as UIButton in picker.subviews { button.sendActions(for: .touchUpInside) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { picker.removeFromSuperview() }
    }
}
