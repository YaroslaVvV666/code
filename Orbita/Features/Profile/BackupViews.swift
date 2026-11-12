import SwiftUI
import Combine
import CryptoKit
import CommonCrypto
import UniformTypeIdentifiers
import UIKit

// MARK: - Резервная копия переписок: зашифрованный файл с паролем → «Файлы» / iCloud Drive, восстановление на любом телефоне
//
// Внутри: все личные переписки (текст, даты, кто писал; вложения — подписью «Фото», «Голосовое»…) и ваши настройки
// оформления, папки, «Данные и память». Файл зашифрован AES-256-GCM, ключ — из пароля (PBKDF2-SHA256, 200 000 итераций):
// без пароля его не прочитать ни нам, ни облаку. При восстановлении то, что ещё есть на сервере, не дублируется —
// возвращается только потерянное (удалённое, исчезнувшее по сроку хранения).

struct BackupFile: Codable {
    struct Message: Codable { let mine: Bool; let text: String; let date: Double; let name: String }
    struct Chat: Codable { let id: String; let name: String; let username: String?; let messages: [Message] }
    let version: Int
    let created: Double
    let account: String
    let chats: [Chat]
    let settings: [String: String]
}

enum BackupCrypto {
    private static let magic = Data("ORBK1".utf8)

    static func key(_ password: String, salt: Data) -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8)
        salt.withUnsafeBytes { s in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000, &out, out.count)
        }
        return SymmetricKey(data: out)
    }

    static func seal(_ plain: Data, password: String) throws -> Data {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let box = try AES.GCM.seal(plain, using: key(password, salt: salt))
        guard let combined = box.combined else { throw CocoaError(.coderInvalidValue) }
        return magic + salt + combined
    }

    enum Failure: Error { case notBackup, wrongPassword }

    static func open(_ data: Data, password: String) throws -> Data {
        guard data.count > magic.count + 16 + 28, data.prefix(magic.count) == magic else { throw Failure.notBackup }
        let salt = data.subdata(in: magic.count..<(magic.count + 16))
        let body = data.subdata(in: (magic.count + 16)..<data.count)
        do {
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: body), using: key(password, salt: salt))
        } catch {
            throw Failure.wrongPassword
        }
    }
}

enum BackupManager {
    /// Что из настроек кладём в копию (своё оформление, папки, «Данные и память», статистика — нет)
    private static let settingKeys = ["isDark", "accent", "theme.mode", "chat.textSize", "chat.radius", "media.tapPaging",
                                      "anim.messages", "stickers.suggest", "emoji.big", "autoplay", "autoplay.gif",
                                      "save.privateChats", "save.groups", "save.channels", "save.edited",
                                      "cache.keepDays", "cache.maxMB", "chatFolders.v1", "orbita.chat.appearance"]

    @MainActor
    static func create(session: AppSession, password: String, progress: @escaping @MainActor (String) -> Void) async throws -> URL {
        let repo = session.messengerRepo
        let peers = session.chats.chats.map(\.peer).filter { !$0.isGroup && $0.id != session.serverID }
        var chats: [BackupFile.Chat] = []
        for (i, peer) in peers.enumerated() {
            progress("\(i + 1) / \(peers.count): \(peer.name)")
            var all: [ChatMessage] = []
            var before: Double? = nil
            repeat {
                guard let page = try? await repo.exportPage(peerID: peer.id, before: before) else { break }
                all.insert(contentsOf: page.messages, at: 0)
                before = page.before
                if !page.more { break }
            } while true
            let msgs = all.filter { !$0.isPending }.map { m in
                BackupFile.Message(mine: m.mine, text: m.text.isEmpty ? m.summary : m.text,
                                   date: m.createdAt.timeIntervalSince1970, name: m.mine ? "" : peer.name)
            }
            if !msgs.isEmpty { chats.append(.init(id: peer.id, name: peer.name, username: peer.username, messages: msgs)) }
        }
        var settings: [String: String] = [:]
        let d = UserDefaults.standard
        for k in settingKeys {
            guard let v = d.object(forKey: k) else { continue }
            if let data = v as? Data { settings[k] = "b64:" + data.base64EncodedString() }
            else { settings[k] = "\(v)" }
        }
        let file = BackupFile(version: 1, created: Date().timeIntervalSince1970, account: session.serverID, chats: chats, settings: settings)
        progress("🔒")
        let plain = try JSONEncoder().encode(file)
        let sealed = try await Task.detached(priority: .userInitiated) { try BackupCrypto.seal(plain, password: password) }.value
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Orbita-backup-\(df.string(from: Date())).orbitabackup")
        try sealed.write(to: url, options: .atomic)
        return url
    }

    static func read(_ url: URL, password: String) async throws -> BackupFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let plain = try await Task.detached(priority: .userInitiated) { try BackupCrypto.open(data, password: password) }.value
        return try JSONDecoder().decode(BackupFile.self, from: plain)
    }

    @MainActor
    static func restore(_ file: BackupFile, chats chosen: Set<String>, settings: Bool, session: AppSession,
                        progress: @escaping @MainActor (String) -> Void) async -> (added: Int, failed: Int) {
        var added = 0, failed = 0
        let list = file.chats.filter { chosen.contains($0.id) }
        for (i, c) in list.enumerated() {
            progress("\(i + 1) / \(list.count): \(c.name)")
            let items: [[String: Any]] = c.messages.map { ["mine": $0.mine, "text": $0.text, "date": $0.date, "name": $0.name] }
            var at = 0
            while at < items.count {
                let batch = Array(items[at..<min(items.count, at + 200)])
                do { added += try await session.messengerRepo.restoreBatch(peerID: c.id, messages: batch) } catch { failed += 1; break }
                at += 200
            }
        }
        if settings {
            let d = UserDefaults.standard
            for (k, v) in file.settings {
                if v.hasPrefix("b64:"), let data = Data(base64Encoded: String(v.dropFirst(4))) { d.set(data, forKey: k) }
                else if v == "true" || v == "false" { d.set(v == "true", forKey: k) }
                else if let n = Int(v) { d.set(n, forKey: k) }
                else if let n = Double(v) { d.set(n, forKey: k) }
                else { d.set(v, forKey: k) }
            }
        }
        await session.chats.refresh()
        return (added, failed)
    }
}

// MARK: - Экран

struct BackupScreen: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirm = ""
    @State private var busy: String?
    @State private var share: ShareItems?
    @State private var errorText: String?
    @State private var picking = false
    @State private var picked: URL?
    @State private var openPassword = ""
    @State private var loaded: BackupFile?
    @State private var chosen: Set<String> = []
    @State private var withSettings = true
    @State private var done: String?

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let loaded { restoreList(loaded) } else if picked != nil { unlockCard } else { createCard; restoreCard }
                    if let busy {
                        HStack(spacing: 10) { ProgressView(); Text(busy).font(.system(size: 14)).foregroundStyle(theme.textSecondary) }
                            .padding(.horizontal, 30)
                    }
                    if let errorText { Text(errorText).font(.system(size: 14)).foregroundStyle(theme.danger).padding(.horizontal, 30) }
                    if let done { Label(done, systemImage: "checkmark.circle.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.green).padding(.horizontal, 30) }
                }
                .padding(.vertical, 16)
            }
            .background(theme.sheet.ignoresSafeArea())
            .navigationTitle(s.t("Резервная копия", "Backup"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(s.t("Закрыть", "Close")) { dismiss() } } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.data, .item]) { r in
                if case .success(let url) = r { picked = url; errorText = nil }
            }
            .sheet(item: $share) { ActivitySheet(items: $0.items).presentationDetents([.medium, .large]) }
        }
    }

    private var createCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s.t("СОЗДАТЬ КОПИЮ", "CREATE A BACKUP")).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary).padding(.horizontal, 30)
            VStack(spacing: 0) {
                SecureField(s.t("Пароль для копии", "Backup password"), text: $password)
                    .padding(.horizontal, 16).frame(height: 50)
                SettingsDivider()
                SecureField(s.t("Повторите пароль", "Repeat password"), text: $confirm)
                    .padding(.horizontal, 16).frame(height: 50)
            }
            .card(theme, radius: 16).padding(.horizontal, 16)
            Text(s.t("Все личные переписки и ваши настройки (оформление, папки, «Данные и память») — одним зашифрованным файлом. Сохраните его в «Файлы» или iCloud Drive. Без пароля файл не открыть — даже нам.",
                     "All private chats and your settings in one encrypted file. Save it to Files or iCloud Drive. Without the password nobody can open it — not even us."))
                .font(.system(size: 13)).foregroundStyle(theme.textSecondary).padding(.horizontal, 30)
            Button(action: create) {
                Text(s.t("Создать резервную копию", "Create backup")).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(canCreate ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.gray.opacity(0.4)), in: Capsule())
                    .padding(.horizontal, 16)
            }
            .buttonStyle(PressStyle()).disabled(!canCreate || busy != nil)
        }
    }

    private var canCreate: Bool { password.count >= 6 && password == confirm }

    private var restoreCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s.t("ВОССТАНОВИТЬ", "RESTORE")).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 30).padding(.top, 14)
            SettingsGroup {
                SettingsRow(icon: "arrow.counterclockwise", tint: .blue, title: s.t("Выбрать файл копии", "Choose a backup file"), showsChevron: true) {
                    picking = true
                }
            }
            Text(s.t("Вернутся сообщения, которых больше нет на сервере (удалённые, исчезнувшие по сроку). То, что и так есть, не задвоится.",
                     "Messages missing on the server come back. What's already there isn't duplicated."))
                .font(.system(size: 13)).foregroundStyle(theme.textSecondary).padding(.horizontal, 30)
        }
    }

    private var unlockCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(picked?.lastPathComponent ?? "").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).padding(.horizontal, 30)
            SecureField(s.t("Пароль от копии", "Backup password"), text: $openPassword)
                .padding(.horizontal, 16).frame(height: 50).card(theme, radius: 16).padding(.horizontal, 16)
            Button {
                guard let url = picked else { return }
                busy = s.t("Расшифровываем…", "Decrypting…"); errorText = nil
                Task {
                    defer { busy = nil }
                    do {
                        let f = try await BackupManager.read(url, password: openPassword)
                        loaded = f
                        chosen = Set(f.chats.map(\.id))
                    } catch BackupCrypto.Failure.wrongPassword {
                        errorText = s.t("Неверный пароль", "Wrong password")
                    } catch {
                        errorText = s.t("Это не резервная копия Orbita", "This isn't an Orbita backup")
                    }
                }
            } label: {
                Text(s.t("Открыть", "Open")).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 50).background(theme.accent, in: Capsule()).padding(.horizontal, 16)
            }
            .buttonStyle(PressStyle()).disabled(openPassword.isEmpty || busy != nil)
            Button(s.t("Другой файл", "Another file")) { picked = nil; openPassword = "" }
                .font(.system(size: 15)).foregroundStyle(theme.accentColor).frame(maxWidth: .infinity)
        }
    }

    private func restoreList(_ f: BackupFile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s.t("Копия от ", "Backup from ") + Date(timeIntervalSince1970: f.created).formatted(date: .long, time: .shortened))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).padding(.horizontal, 30)
            if f.account != session.serverID {
                Text(s.t("Копия сделана в другом аккаунте — переписки встанут в чаты с теми же людьми.", "This backup is from another account."))
                    .font(.system(size: 13)).foregroundStyle(.orange).padding(.horizontal, 30)
            }
            VStack(spacing: 0) {
                ForEach(Array(f.chats.enumerated()), id: \.element.id) { i, c in
                    Button {
                        Haptics.select()
                        if chosen.contains(c.id) { chosen.remove(c.id) } else { chosen.insert(c.id) }
                    } label: {
                        HStack {
                            Image(systemName: chosen.contains(c.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(chosen.contains(c.id) ? theme.accentColor : theme.textTertiary)
                            Text(c.name).foregroundStyle(theme.text).lineLimit(1)
                            Spacer()
                            Text("\(c.messages.count)").foregroundStyle(theme.textSecondary).monospacedDigit()
                        }
                        .font(.system(size: 16)).padding(.horizontal, 16).frame(height: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < f.chats.count - 1 { SettingsDivider() }
                }
                SettingsDivider()
                Toggle(s.t("Вернуть и настройки", "Restore settings too"), isOn: $withSettings).tint(theme.accentColor)
                    .padding(.horizontal, 16).frame(height: 50)
            }
            .card(theme, radius: 16).padding(.horizontal, 16)
            Button {
                busy = s.t("Восстанавливаем…", "Restoring…"); errorText = nil
                Task {
                    let r = await BackupManager.restore(f, chats: chosen, settings: withSettings, session: session) { p in busy = p }
                    busy = nil
                    Haptics.notify(r.failed == 0 ? .success : .warning)
                    done = s.t("Вернули сообщений: \(r.added)", "Messages restored: \(r.added)")
                    if r.failed > 0 { errorText = s.t("Не все чаты удалось восстановить (\(r.failed))", "Some chats failed (\(r.failed))") }
                }
            } label: {
                Text(s.t("Восстановить выбранное", "Restore selected")).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 50).background(theme.accent, in: Capsule()).padding(.horizontal, 16)
            }
            .buttonStyle(PressStyle()).disabled(chosen.isEmpty || busy != nil)
        }
    }

    private func create() {
        busy = s.t("Собираем переписки…", "Collecting chats…"); errorText = nil; done = nil
        Task {
            defer { busy = nil }
            do {
                let url = try await BackupManager.create(session: session, password: password) { p in busy = s.t("Собираем: ", "Collecting: ") + p }
                Haptics.notify(.success)
                share = ShareItems(items: [url])
                done = s.t("Копия готова — сохраните её в «Файлы»", "Backup ready — save it to Files")
            } catch {
                errorText = s.t("Не удалось создать копию", "Couldn't create the backup")
            }
        }
    }
}
