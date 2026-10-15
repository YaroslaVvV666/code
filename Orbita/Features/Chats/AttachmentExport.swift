import SwiftUI
import UIKit

/// Скачивание вложений чата (mp3, файлы, голосовые): файл загружается и открывается системное окно
/// «Сохранить в Файлы» / «Поделиться» — оттуда его можно положить в «Файлы», на iCloud Drive, отправить в другое приложение.
enum AttachmentExporter {
    @MainActor
    static func export(_ a: ChatAttachment) async -> Bool {
        guard let id = a.mediaID, let url = ServerConfig.mediaURL(id) else { return false }
        do {
            let (tmp, _) = try await URLSession.shared.download(from: url)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(fileName(for: a))
            try FileManager.default.moveItem(at: tmp, to: file)
            present(file)
            return true
        } catch {
            return false
        }
    }

    private static func fileName(for a: ChatAttachment) -> String {
        var base: String
        if let name = a.name, !name.isEmpty {
            base = name
        } else if let title = a.title, !title.isEmpty {
            base = [a.artist ?? "", title].filter { !$0.isEmpty }.joined(separator: " - ")
        } else {
            base = a.kind == .voice ? "voice" : "audio"
        }
        base = base.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "_")
        if (base as NSString).pathExtension.isEmpty {
            let mime = (a.mime ?? "").lowercased()
            let ext = mime.contains("mpeg") || mime.contains("mp3") ? "mp3"
                : mime.contains("mp4") || mime.contains("m4a") || mime.contains("aac") ? "m4a"
                : mime.contains("ogg") ? "ogg" : mime.contains("wav") ? "wav" : a.kind == .voice ? "m4a" : "mp3"
            base += "." + ext
        }
        return base
    }

    @MainActor
    private static func present(_ file: URL) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = scenes.first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view                 // для iPad
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
        top.present(sheet, animated: true)
    }
}
