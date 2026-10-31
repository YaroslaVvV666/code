import ReplayKit
import CoreImage
import UIKit
import Darwin

/// Broadcast Upload Extension: снимает ВЕСЬ экран телефона (и когда приложение свёрнуто) и по локальному сокету
/// в общей папке App Group отдаёт кадры (JPEG) основному приложению, а оно кладёт их в видеодорожку звонка.
/// Лимит памяти у расширения ~50 МБ, поэтому кадры уменьшаются и сжимаются сразу.
final class SampleHandler: RPBroadcastSampleHandler {
    private var fd: Int32 = -1
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var lastSent: CFAbsoluteTime = 0
    private let minInterval: CFTimeInterval = 1.0 / 10.0      // не чаще 10 кадров в секунду
    private let maxWidth: CGFloat = 720

    /// Группа считается из идентификатора расширения: com.x.app.broadcast → group.com.x.app
    private var groupID: String {
        let id = Bundle.main.bundleIdentifier ?? ""
        return "group." + (id.components(separatedBy: ".").dropLast().joined(separator: "."))
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard connect() else {
            finishBroadcastWithError(NSError(domain: "Orbita", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Откройте звонок в Orbita и нажмите «Экран» ещё раз"]))
            return
        }
        observeStop()
    }

    override func broadcastFinished() {
        if fd >= 0 { close(fd); fd = -1 }
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, fd >= 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSent >= minInterval, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSent = now

        var image = CIImage(cvPixelBuffer: pixels)
        // поворот экрана: ReplayKit присылает ориентацию кадра в приложении к буферу
        if let raw = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
            image = image.oriented(forExifOrientation: raw.int32Value)
        }
        let scale = min(1, maxWidth / image.extent.width)
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = context.jpegRepresentation(of: image, colorSpace: space,
                                                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.55])
        else { return }
        send(jpeg)
    }

    // MARK: Сокет

    private func connect() -> Bool {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return false }
        let path = dir.appendingPathComponent("s").path
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 400_000)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(sock); return false }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: bytes.count) { p in for i in 0..<bytes.count { p[i] = bytes[i] } }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock, $0, len) == 0 }
        }
        if !ok { close(sock); return false }
        fd = sock
        return true
    }

    private func send(_ jpeg: Data) {
        var length = UInt32(jpeg.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(jpeg)
        let ok = packet.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < packet.count {
                let n = write(fd, base + sent, packet.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
        if !ok {                                        // приложение закрыло сокет: звонок закончился
            close(fd); fd = -1
            finishBroadcastWithError(NSError(domain: "Orbita", code: 2, userInfo: [NSLocalizedDescriptionKey: "Показ экрана остановлен"]))
        }
    }

    /// Приложение просит остановить показ (например, звонок завершён) — через Darwin-уведомление
    private func observeStop() {
        let name = (groupID + ".stop") as CFString
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
            guard let observer else { return }
            let me = Unmanaged<SampleHandler>.fromOpaque(observer).takeUnretainedValue()
            me.finishBroadcastWithError(NSError(domain: "Orbita", code: 3, userInfo: [NSLocalizedDescriptionKey: "Показ экрана остановлен"]))
        }, name, nil, .deliverImmediately)
    }
}
