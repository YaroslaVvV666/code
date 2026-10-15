import SwiftUI
import QuickLook
import UIKit
import UniformTypeIdentifiers

/// Просмотр файла из чата как в Telegram: сверху имя и «закрыть», внизу «Сохранить» и «Поделиться».
/// Текстовые файлы (txt, md, csv, json, код…) показываются прямо в приложении в любой кодировке; остальное — через Quick Look.
struct FileViewerSheet: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var text: String?
    @State private var showExporter = false
    @State private var shareItems: ShareItems?

    private var s: Strings { Strings(lang: lang) }
    private static let textExtensions: Set<String> = ["txt", "md", "log", "csv", "json", "xml", "yml", "yaml", "ini", "swift",
                                                      "py", "js", "ts", "html", "css", "c", "h", "cpp", "java", "kt", "sh", "rtf", "tsv", "srt"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
                        .frame(width: 40, height: 40).glassCircle()
                }
                .buttonStyle(.plain)
                VStack(spacing: 1) {
                    Text(url.lastPathComponent).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                    Text(sizeText).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                Button { shareItems = ShareItems(items: [url]) } label: {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                        .frame(width: 40, height: 40).glassCircle()
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Group {
                if let text {
                    ScrollView {
                        Text(text)
                            .font(.system(size: 15, design: Self.isCode(url) ? .monospaced : .default))
                            .foregroundStyle(theme.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                } else {
                    QuickLookView(url: url)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button { showExporter = true } label: {
                Label(s.t("Сохранить в Файлы", "Save to Files"), systemImage: "arrow.down.doc")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(theme.accent, in: Capsule())
            }
            .buttonStyle(PressStyle())
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(theme.sheet.ignoresSafeArea())
        .task { text = Self.readText(url) }
        .sheet(isPresented: $showExporter) { DocumentExporter(url: url).ignoresSafeArea() }
        .sheet(item: $shareItems) { ActivitySheet(items: $0.items).presentationDetents([.medium, .large]) }
    }

    private var sizeText: String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return bytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) : ""
    }

    private static func isCode(_ url: URL) -> Bool {
        !["txt", "md", "rtf", "srt", "log"].contains(url.pathExtension.lowercased())
    }

    /// Читает текст в UTF-8, UTF-16 или Windows-1251 — чтобы русские файлы не превращались в «кракозябры»
    private static func readText(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        guard textExtensions.contains(ext) || ext.isEmpty,
              let data = try? Data(contentsOf: url), data.count < 3_000_000 else { return nil }
        if ext == "rtf" { return nil }                                    // RTF покажет Quick Look
        if let s = String(data: data, encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .windowsCP1251) { return s }
        return String(data: data, encoding: .isoLatin1)
    }
}

/// «Сохранить в Файлы» — системное окно выбора папки
struct DocumentExporter: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
