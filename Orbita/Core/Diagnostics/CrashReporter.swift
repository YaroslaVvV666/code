import Foundation
import UIKit
import MetricKit
import Darwin
import Combine

/// Отчёты о падениях: если приложение вылетело, при следующем запуске предлагаем отправить отчёт в поддержку (@support).
/// Источники: необработанное исключение Objective-C, сигнал (SIGSEGV, SIGABRT…) и отчёты MetricKit от самой iOS
/// (они приходят на следующий день и ловят то, что не видно изнутри: нехватку памяти, зависания, падения в системных библиотеках)
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    private static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("crash-reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    /// Путь для обработчика сигналов: заранее, в C-строке (в момент падения выделять память нельзя)
    private static var signalPath: [CChar] = []

    func start() {
        Self.signalPath = Array(Self.dir.appendingPathComponent("signal-\(Int(Date().timeIntervalSince1970)).txt").path.utf8CString)
        NSSetUncaughtExceptionHandler { e in
            CrashReporter.write("Исключение: \(e.name.rawValue)\nПричина: \(e.reason ?? "—")\n\n" +
                                e.callStackSymbols.prefix(40).joined(separator: "\n"))
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig) { code in
                // только безопасные в обработчике сигнала вызовы: open/write/close
                CrashReporter.signalPath.withUnsafeBufferPointer { p in
                    let fd = open(p.baseAddress!, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                    if fd >= 0 {
                        var msg = Array("Сигнал \(code)\n".utf8)
                        _ = write(fd, &msg, msg.count)
                        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
                        let n = backtrace(&frames, 64)
                        backtrace_symbols_fd(&frames, n, fd)
                        close(fd)
                    }
                }
                signal(code, SIG_DFL)
                raise(code)
            }
        }
        MXMetricManager.shared.add(self)
    }

    private static func write(_ body: String) {
        let url = dir.appendingPathComponent("crash-\(Int(Date().timeIntervalSince1970)).txt")
        try? body.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MetricKit: отчёты iOS о падениях и зависаниях
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            for c in p.crashDiagnostics ?? [] {
                let head = "Падение (iOS): исключение \(c.exceptionType?.stringValue ?? "—"), сигнал \(c.signal?.stringValue ?? "—")\n" +
                           "Версия: \(c.applicationVersion)\n\n"
                let tree = String(data: c.callStackTree.jsonRepresentation(), encoding: .utf8) ?? ""
                Self.write(head + String(tree.prefix(6000)))
            }
            for h in p.hangDiagnostics ?? [] {
                Self.write("Зависание (iOS): \(h.hangDuration.description)\nВерсия: \(h.applicationVersion)")
            }
        }
    }

    /// Неотправленные отчёты (самый свежий первым)
    var pending: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "txt" && ((try? Data(contentsOf: $0))?.isEmpty == false) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Текст для поддержки: устройство, версия и начало отчёта (без личных данных — только стек вызовов)
    func reportText() -> String? {
        guard let url = pending.first, let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "🐞 Отчёт о сбое Orbita\nУстройство: \(DeviceInfo.model), \(DeviceInfo.system)\nВерсия: \(version) (\(build))\n" +
               "Отчётов накопилось: \(pending.count)\n\n" + String(body.prefix(3200))
    }

    func clear() {
        for u in pending { try? FileManager.default.removeItem(at: u) }
    }
}
