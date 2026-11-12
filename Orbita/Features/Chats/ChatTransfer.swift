import SwiftUI
import Combine
import UniformTypeIdentifiers
import UIKit

// MARK: - Перенос переписки: экспорт из Orbita и импорт из Telegram / WhatsApp
//
// Импорт понимает:
// • Telegram Desktop → «Экспорт истории чата» в формате JSON: папка с result.json (и photos/) или сам result.json;
// • WhatsApp → «Экспорт чата»: _chat.txt (iPhone) или «Чат WhatsApp с …txt» (Android); если выбрать распакованную
//   папку — подтянутся и фото.
// Сообщения встают в переписку со своими датами и пометкой «Импортировано из Telegram / WhatsApp».
//
// Экспорт собирает папку: result.json (тот же формат, что у Telegram), messages.txt (как у WhatsApp) и photos/,
// упаковывает в .zip и отдаёт в «Поделиться».

/// Одно сообщение из чужой выгрузки
struct ImportedMessage {
    var date: Date
    var name: String
    var text: String
    var photo: URL? = nil                 // фото рядом с выгрузкой (если выбрали папку)
}

struct ImportedChat {
    var source: String                    // "telegram" | "whatsapp"
    var title: String
    var messages: [ImportedMessage]
    /// Кто писал — чтобы выбрать, кто из них «я»
    var senders: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for m in messages { counts[m.name, default: 0] += 1 }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }
}

enum ChatImportParser {
    enum Failure: Error { case unreadable, unknownFormat, empty }

    /// Файл или папка из «Файлов»: ищем result.json / *.txt внутри
    static func parse(_ url: URL) throws -> ImportedChat {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            if let json = files.first(where: { $0.lastPathComponent.lowercased() == "result.json" }) {
                return try telegram(json, folder: url)
            }
            if let txt = files.first(where: { $0.pathExtension.lowercased() == "txt" }) {
                return try whatsapp(txt, folder: url)
            }
            throw Failure.unknownFormat
        }
        switch url.pathExtension.lowercased() {
        case "json": return try telegram(url, folder: nil)
        case "txt": return try whatsapp(url, folder: nil)
        default: throw Failure.unknownFormat
        }
    }

    // MARK: Telegram (result.json)

    static func telegram(_ url: URL, folder: URL?) throws -> ImportedChat {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable }
        // выгрузка одного чата — сам объект; выгрузка «всех чатов» — первый личный чат
        let chat: [String: Any]
        if root["messages"] != nil {
            chat = root
        } else if let list = (root["chats"] as? [String: Any])?["list"] as? [[String: Any]], let first = list.first {
            chat = first
        } else {
            throw Failure.unknownFormat
        }
        let raw = chat["messages"] as? [[String: Any]] ?? []
        var out: [ImportedMessage] = []
        for m in raw where (m["type"] as? String ?? "message") == "message" {
            let ts = (m["date_unixtime"] as? String).flatMap(Double.init)
                ?? (m["date"] as? String).flatMap { ISO8601DateFormatter.telegram.date(from: $0)?.timeIntervalSince1970 }
            guard let ts else { continue }
            var text = flatten(m["text"])
            var photo: URL?
            if let p = m["photo"] as? String, let folder { photo = folder.appendingPathComponent(p) }
            if text.isEmpty {
                if m["photo"] != nil, photo == nil { text = "📷 Фото" }
                else if let kind = m["media_type"] as? String { text = mediaLabel(kind) }
                else if m["file"] != nil { text = "📎 Файл" }
                else if let sticker = m["sticker_emoji"] as? String { text = sticker }
            }
            guard !text.isEmpty || photo != nil else { continue }
            out.append(ImportedMessage(date: Date(timeIntervalSince1970: ts), name: m["from"] as? String ?? "—", text: text, photo: photo))
        }
        guard !out.isEmpty else { throw Failure.empty }
        return ImportedChat(source: "telegram", title: chat["name"] as? String ?? "Telegram", messages: out)
    }

    /// Текст Telegram бывает строкой или массивом кусочков (жирный, ссылки…) — склеиваем
    private static func flatten(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let parts = v as? [Any] {
            return parts.map { p -> String in
                if let s = p as? String { return s }
                return (p as? [String: Any])?["text"] as? String ?? ""
            }.joined()
        }
        return ""
    }

    private static func mediaLabel(_ kind: String) -> String {
        switch kind {
        case "voice_message": return "🎤 Голосовое сообщение"
        case "video_message": return "⭕️ Видеосообщение"
        case "video_file": return "🎬 Видео"
        case "audio_file": return "🎵 Аудио"
        case "sticker": return "🙂 Стикер"
        case "animation": return "GIF"
        default: return "📎 Вложение"
        }
    }

    // MARK: WhatsApp (_chat.txt)

    /// iPhone: «[15.03.2024, 21:04:55] Имя: текст»; Android: «15.03.2024, 21:04 - Имя: текст» (и вариации с / и AM/PM)
    private static let iosLine = try! NSRegularExpression(pattern: #"^\[(\d{1,2}[./]\d{1,2}[./]\d{2,4}),? (\d{1,2}:\d{2}(?::\d{2})?(?:\s?[AaPp][Mm])?)\] ([^:]+): (.*)$"#)
    private static let androidLine = try! NSRegularExpression(pattern: #"^(\d{1,2}[./]\d{1,2}[./]\d{2,4}),? (\d{1,2}:\d{2}(?:\s?[AaPp][Mm])?) [-–] ([^:]+): (.*)$"#)

    static func whatsapp(_ url: URL, folder: URL?) throws -> ImportedChat {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.unreadable }
        let clean = raw.replacingOccurrences(of: "\u{200E}", with: "").replacingOccurrences(of: "\u{202F}", with: " ")
        var out: [ImportedMessage] = []
        for line in clean.components(separatedBy: .newlines) {
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = iosLine.firstMatch(in: line, range: range) ?? androidLine.firstMatch(in: line, range: range),
               let date = waDate(ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2))) {
                let name = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
                var text = ns.substring(with: m.range(at: 4))
                var photo: URL?
                // вложение: «<attached: 00000012-PHOTO-….jpg>» (iPhone) или «IMG-….jpg (file attached)» (Android)
                if let file = attachmentName(text) {
                    if let folder, ["jpg", "jpeg", "png", "heic", "webp"].contains((file as NSString).pathExtension.lowercased()) {
                        photo = folder.appendingPathComponent(file)
                        text = ""
                    } else {
                        text = (file as NSString).pathExtension.lowercased() == "opus" ? "🎤 Голосовое сообщение" : "📎 " + file
                    }
                }
                if text.contains("<Media omitted>") || text.contains("<Без медиафайлов>") { text = "📎 Вложение" }
                out.append(ImportedMessage(date: date, name: name, text: text, photo: photo))
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty, !out.isEmpty {
                out[out.count - 1].text += "\n" + line                     // продолжение многострочного сообщения
            }
        }
        // служебная строка «Сообщения и звонки защищены сквозным шифрованием» — без автора, её отбрасываем
        out.removeAll { $0.text.contains("end-to-end encrypted") || $0.text.contains("сквозным шифрованием") }
        guard !out.isEmpty else { throw Failure.empty }
        let title = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "WhatsApp Chat with ", with: "").replacingOccurrences(of: "Чат WhatsApp с ", with: "")
        return ImportedChat(source: "whatsapp", title: title == "_chat" ? "WhatsApp" : title, messages: out)
    }

    private static func attachmentName(_ text: String) -> String? {
        if let r = text.range(of: #"<attached: ([^>]+)>"#, options: .regularExpression) {
            return String(text[r]).replacingOccurrences(of: "<attached: ", with: "").replacingOccurrences(of: ">", with: "")
        }
        if text.hasSuffix("(file attached)") || text.hasSuffix("(файл добавлен)") {
            return text.components(separatedBy: " (").first
        }
        return nil
    }

    private static func waDate(_ day: String, _ time: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let d = day.replacingOccurrences(of: "/", with: ".")
        let t = time.uppercased().replacingOccurrences(of: " ", with: "")
        let year4 = d.split(separator: ".").last?.count == 4
        let timeFmt = t.hasSuffix("AM") || t.hasSuffix("PM") ? (t.filter { $0 == ":" }.count == 2 ? "h:mm:ssa" : "h:mma")
                                                             : (t.filter { $0 == ":" }.count == 2 ? "HH:mm:ss" : "HH:mm")
        for dayFmt in [year4 ? "dd.MM.yyyy" : "dd.MM.yy", year4 ? "MM.dd.yyyy" : "MM.dd.yy"] {
            f.dateFormat = dayFmt + " " + timeFmt
            if let date = f.date(from: d + " " + t) { return date }
        }
        return nil
    }
}

private extension ISO8601DateFormatter {
    static let telegram: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return f
    }()
}

// MARK: - Экспорт

enum ChatExporter {
    /// Собирает папку (result.json, messages.txt, photos/) и упаковывает в .zip
    static func export(peer: ChatPeer, myName: String, repo: MessengerRepository,
                       withPhotos: Bool, progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        var all: [ChatMessage] = []
        var before: Double? = nil
        repeat {
            let page = try await repo.exportPage(peerID: peer.id, before: before)
            all.insert(contentsOf: page.messages, at: 0)
            before = page.before
            await progress("\(all.count)")
            if !page.more { break }
        } while true

        let safe = SafeFileName.clean(peer.name, fallback: "chat")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Orbita_\(safe)_\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("photos"), withIntermediateDirectories: true)

        var json: [[String: Any]] = []
        var txt = ""
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "dd.MM.yyyy, HH:mm:ss"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        var photoIndex = 0
        for (i, m) in all.enumerated() {
            let name = m.mine ? myName : (m.imported?.name.isEmpty == false ? m.imported!.name : peer.name)
            var item: [String: Any] = ["id": i + 1, "type": "message", "date": iso.string(from: m.createdAt),
                                       "date_unixtime": String(Int(m.createdAt.timeIntervalSince1970)),
                                       "from": name, "from_id": m.mine ? "user_me" : "user_\(peer.id)", "text": m.text]
            var line = m.text
            if withPhotos, let photo = m.attachments.first(where: { $0.kind == .photo }), let id = photo.mediaID,
               let url = ServerConfig.mediaURL(id), let (data, _) = try? await URLSession.shared.data(from: url) {
                photoIndex += 1
                let file = "photos/photo_\(photoIndex).jpg"
                try? data.write(to: dir.appendingPathComponent(file))
                item["photo"] = file
                line = "<attached: \(file)>" + (m.text.isEmpty ? "" : "\n" + m.text)
                if photoIndex % 10 == 0 { await progress("📷 \(photoIndex)") }
            } else if line.isEmpty {
                line = m.summary
                item["text"] = m.summary
            }
            json.append(item)
            txt += "[\(df.string(from: m.createdAt))] \(name): \(line)\n"
        }
        let root: [String: Any] = ["name": peer.name, "type": "personal_chat", "id": peer.id, "messages": json]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: dir.appendingPathComponent("result.json"))
        try txt.data(using: .utf8)?.write(to: dir.appendingPathComponent("messages.txt"))
        if photoIndex == 0 { try? FileManager.default.removeItem(at: dir.appendingPathComponent("photos")) }
        return try zip(dir)
    }

    /// Папка → .zip системными средствами (NSFileCoordinator «для отправки»)
    private static func zip(_ dir: URL) throws -> URL {
        var result: URL?
        var failure: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: .forUploading, error: &coordError) { tmp in
            let target = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + ".zip")
            try? FileManager.default.removeItem(at: target)
            do { try FileManager.default.copyItem(at: tmp, to: target); result = target } catch { failure = error }
        }
        if let coordError { throw coordError }
        if let failure { throw failure }
        guard let result else { throw ChatImportParser.Failure.unreadable }
        return result
    }
}

// MARK: - Экран переноса

struct ChatTransferSheet: View {
    let peer: ChatPeer
    let myName: String
    let repo: MessengerRepository
    var onImported: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var picking = false
    @State private var parsed: ImportedChat?
    @State private var meName: String?
    @State private var errorText: String?
    @State private var busy: String?
    @State private var done: String?
    @State private var shareURL: ShareItems?
    @State private var withPhotos = true

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let parsed { preview(parsed) } else { intro }
                    if let busy {
                        HStack(spacing: 10) { ProgressView(); Text(busy).font(.system(size: 14)).foregroundStyle(theme.textSecondary) }
                    }
                    if let done {
                        Label(done, systemImage: "checkmark.circle.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.green)
                    }
                    if let errorText {
                        Text(errorText).font(.system(size: 14)).foregroundStyle(theme.danger)
                    }
                }
                .padding(20)
            }
            .navigationTitle(s.t("Перенос переписки", "Chat transfer"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(s.t("Закрыть", "Close")) { dismiss() } } }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.json, .plainText, .folder], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            do {
                let chat = try ChatImportParser.parse(url)
                withAnimation { parsed = chat; meName = chat.senders.first?.name; errorText = nil; done = nil }
            } catch {
                errorText = s.t("Не получилось прочитать выгрузку. Нужен result.json из Telegram или _chat.txt из WhatsApp.",
                                "Couldn't read the export. Use result.json from Telegram or _chat.txt from WhatsApp.")
            }
        }
        .sheet(item: $shareURL) { ActivitySheet(items: $0.items).presentationDetents([.medium, .large]) }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            card(icon: "square.and.arrow.down.on.square.fill", tint: .blue,
                 title: s.t("Импорт из Telegram или WhatsApp", "Import from Telegram or WhatsApp"),
                 text: s.t("Telegram Desktop: чат → ⋮ → «Экспорт истории чата» → формат JSON. Выберите папку выгрузки (подтянутся и фото) или result.json.\nWhatsApp: чат → имя → «Экспорт чата». Распакуйте архив и выберите папку или _chat.txt.",
                           "Telegram Desktop: chat → ⋮ → Export chat history → JSON. Pick the export folder (photos too) or result.json.\nWhatsApp: chat → name → Export chat. Unzip and pick the folder or _chat.txt.")) {
                picking = true
            }
            VStack(alignment: .leading, spacing: 10) {
                card(icon: "square.and.arrow.up.on.square.fill", tint: .green,
                     title: s.t("Экспорт этой переписки", "Export this chat"),
                     text: s.t("Архив .zip: result.json (как у Telegram), messages.txt (как у WhatsApp) и фото. Его можно сохранить или перенести.",
                               "A .zip with result.json (Telegram format), messages.txt (WhatsApp format) and photos.")) {
                    runExport()
                }
                Toggle(s.t("Вместе с фото", "Include photos"), isOn: $withPhotos).tint(theme.accentColor)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func card(icon: String, tint: Color, title: String, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 48, height: 48).background(tint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                    Text(text).font(.system(size: 13)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(theme.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .disabled(busy != nil)
    }

    private func preview(_ chat: ImportedChat) -> some View {
        let df = Date.FormatStyle(date: .abbreviated, time: .omitted)
        let first = chat.messages.first?.date ?? Date(), last = chat.messages.last?.date ?? Date()
        let photos = chat.messages.filter { $0.photo != nil }.count
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: chat.source == "telegram" ? "paperplane.circle.fill" : "phone.bubble.fill")
                    .font(.system(size: 34)).foregroundStyle(chat.source == "telegram" ? Color(red: 0.16, green: 0.6, blue: 0.9) : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title).font(.system(size: 18, weight: .bold)).foregroundStyle(theme.text).lineLimit(1)
                    Text(s.t("\(chat.messages.count) сообщений · \(first.formatted(df)) – \(last.formatted(df))",
                             "\(chat.messages.count) messages · \(first.formatted(df)) – \(last.formatted(df))")
                         + (photos > 0 ? s.t(" · фото: \(photos)", " · photos: \(photos)") : ""))
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                }
            }
            Text(s.t("КТО ИЗ НИХ — ВЫ?", "WHICH ONE IS YOU?")).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
            VStack(spacing: 0) {
                ForEach(chat.senders.prefix(6), id: \.name) { sender in
                    Button { meName = sender.name; Haptics.select() } label: {
                        HStack {
                            Image(systemName: meName == sender.name ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(meName == sender.name ? theme.accentColor : theme.textTertiary)
                            Text(sender.name).foregroundStyle(theme.text)
                            Spacer()
                            Text("\(sender.count)").foregroundStyle(theme.textSecondary).font(.system(size: 13))
                        }
                        .padding(.horizontal, 14).frame(height: 46).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(theme.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(s.t("Ваши сообщения станут вашими, остальные — от \(peer.name). У обоих появится пометка «Импортировано из \(chat.source == "telegram" ? "Telegram" : "WhatsApp")».",
                     "Your messages become yours, the rest — from \(peer.name). Both will see “Imported from \(chat.source == "telegram" ? "Telegram" : "WhatsApp")”."))
                .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            Button { runImport(chat) } label: {
                Text(s.t("Импортировать в чат с \(peer.name)", "Import into chat with \(peer.name)"))
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressStyle())
            .disabled(busy != nil || meName == nil)
            Button(s.t("Выбрать другой файл", "Pick another file")) { picking = true }
                .font(.system(size: 15)).foregroundStyle(theme.accentColor).frame(maxWidth: .infinity)
        }
    }

    private func runImport(_ chat: ImportedChat) {
        guard let meName else { return }
        busy = s.t("Переносим…", "Importing…")
        errorText = nil
        Task { @MainActor in
            defer { busy = nil }
            var added = 0
            var batch: [[String: Any]] = []
            let total = chat.messages.count
            for (i, m) in chat.messages.enumerated() {
                var item: [String: Any] = ["mine": m.name == meName, "text": m.text, "date": m.date.timeIntervalSince1970, "name": m.name]
                // фото из папки выгрузки: загружаем как обычное фото
                if let url = m.photo, let data = try? Data(contentsOf: url), let prepared = try? MediaPreparer.prepareImage(data),
                   let up = try? await repo.upload(.prepared(prepared)) {
                    item["attachments"] = [up.json]
                }
                batch.append(item)
                if batch.count == 200 || i == total - 1 {
                    do {
                        added += try await repo.importBatch(peerID: peer.id, source: chat.source, messages: batch)
                    } catch {
                        errorText = s.api((error as? APIError) ?? .offline)
                        return
                    }
                    batch = []
                    busy = s.t("Перенесено \(added) из \(total)…", "Imported \(added) of \(total)…")
                }
            }
            Haptics.notify(.success)
            done = s.t("Готово: перенесено \(added) сообщений", "Done: \(added) messages imported")
            parsed = nil
            onImported()
        }
    }

    private func runExport() {
        busy = s.t("Собираем переписку…", "Collecting messages…")
        errorText = nil
        Task { @MainActor in
            defer { busy = nil }
            do {
                let url = try await ChatExporter.export(peer: peer, myName: myName, repo: repo, withPhotos: withPhotos) { p in
                    busy = s.t("Собираем… \(p)", "Collecting… \(p)")
                }
                Haptics.notify(.success)
                shareURL = ShareItems(items: [url])
            } catch {
                errorText = s.api((error as? APIError) ?? .offline)
            }
        }
    }
}

/// Пометка на перенесённом сообщении
struct ImportedBadge: View {
    let info: ImportedInfo
    let mine: Bool
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    var body: some View {
        let s = Strings(lang: lang)
        HStack(spacing: 4) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 10, weight: .bold))
            Text(s.t("Импортировано из \(info.source)", "Imported from \(info.source)") + (info.name.isEmpty ? "" : " · " + info.name))
                .font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(mine ? Color.white.opacity(0.7) : theme.textSecondary)
        .padding(.horizontal, 11).padding(.top, 6)
    }
}
