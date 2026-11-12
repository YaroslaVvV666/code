import SwiftUI
import Combine
import Network
import Photos
import UIKit

// MARK: - Данные и память: настройки, которые реально работают
// Автозагрузка медиа (по сети: мобильная / Wi-Fi), автовоспроизведение, сохранение в «Фото»,
// срок хранения и предел кэша, учёт трафика и разбор, что сколько места занимает

/// Сейчас мобильная сеть или Wi-Fi
final class NetPath: @unchecked Sendable {
    static let shared = NetPath()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var _cellular = false

    var cellular: Bool { lock.withLock { _cellular } }

    private init() {
        monitor.pathUpdateHandler = { [weak self] p in
            guard let self else { return }
            let cell = p.usesInterfaceType(.cellular) && !p.usesInterfaceType(.wifi) && !p.usesInterfaceType(.wiredEthernet)
            self.lock.lock(); self._cellular = cell; self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "orbita.netpath"))
    }
}

enum AutoKind: String, CaseIterable, Identifiable {
    case photo, video, file, voice
    var id: String { rawValue }
}

enum DataPrefs {
    private static let d = UserDefaults.standard

    static func key(_ k: AutoKind, cellular: Bool) -> String { "auto.\(cellular ? "cell" : "wifi").\(k.rawValue)" }
    /// По умолчанию, как в Telegram: по Wi-Fi качается всё, по мобильной — фото и голосовые
    static func defaultAuto(_ k: AutoKind, cellular: Bool) -> Bool { cellular ? (k == .photo || k == .voice) : true }

    static func autoDownload(_ k: AutoKind, cellular: Bool) -> Bool {
        d.object(forKey: key(k, cellular: cellular)) as? Bool ?? defaultAuto(k, cellular: cellular)
    }
    /// Можно ли качать сразу — по той сети, что сейчас
    static func autoNow(_ k: AutoKind) -> Bool { autoDownload(k, cellular: NetPath.shared.cellular) }

    static func resetAuto() {
        for c in [true, false] { for k in AutoKind.allCases { d.removeObject(forKey: key(k, cellular: c)) } }
    }

    static let fileLimit = 10 * 1024 * 1024          // файлы больше 10 МБ сами не качаются никогда

    /// Срок хранения медиа на телефоне (дней), 0 — всегда
    static var keepDays: Int { d.integer(forKey: "cache.keepDays") }
    /// Предел кэша (МБ), 0 — без ограничений
    static var maxCacheMB: Int { d.integer(forKey: "cache.maxMB") }
}

// MARK: Учёт трафика

enum NetCategory: String, CaseIterable, Identifiable {
    case messages, photos, videos, voice, files
    var id: String { rawValue }
}

@MainActor
final class NetUsage: ObservableObject {
    static let shared = NetUsage()
    private static let key = "netusage.v1"
    private static let sinceKey = "netusage.since"

    @Published private(set) var counters: [String: Int] = UserDefaults.standard.dictionary(forKey: NetUsage.key) as? [String: Int] ?? [:]
    @Published private(set) var since: Date = (UserDefaults.standard.object(forKey: NetUsage.sinceKey) as? Date) ?? Date()
    private var dirty = false

    private init() {
        if UserDefaults.standard.object(forKey: Self.sinceKey) == nil { UserDefaults.standard.set(since, forKey: Self.sinceKey) }
    }

    private static func k(_ c: NetCategory, cellular: Bool, sent: Bool) -> String { "\(cellular ? "cell" : "wifi").\(c.rawValue).\(sent ? "out" : "in")" }

    /// Из любого потока: сколько ушло и пришло
    nonisolated static func add(_ c: NetCategory, sent: Int = 0, received: Int = 0) {
        guard sent > 0 || received > 0 else { return }
        let cell = NetPath.shared.cellular
        Task { @MainActor in shared.bump(c, cellular: cell, sent: sent, received: received) }
    }

    private func bump(_ c: NetCategory, cellular: Bool, sent: Int, received: Int) {
        if sent > 0 { counters[Self.k(c, cellular: cellular, sent: true), default: 0] += sent }
        if received > 0 { counters[Self.k(c, cellular: cellular, sent: false), default: 0] += received }
        guard !dirty else { return }
        dirty = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.dirty = false
            UserDefaults.standard.set(self.counters, forKey: Self.key)
        }
    }

    /// cellular: nil — все сети
    func value(_ c: NetCategory, cellular: Bool?, sent: Bool) -> Int {
        let nets = cellular.map { [$0] } ?? [true, false]
        return nets.reduce(0) { $0 + (counters[Self.k(c, cellular: $1, sent: sent)] ?? 0) }
    }

    func total(cellular: Bool?) -> Int {
        NetCategory.allCases.reduce(0) { $0 + value($1, cellular: cellular, sent: true) + value($1, cellular: cellular, sent: false) }
    }

    func reset() {
        counters = [:]
        since = Date()
        UserDefaults.standard.set(counters, forKey: Self.key)
        UserDefaults.standard.set(since, forKey: Self.sinceKey)
    }
}

// MARK: Что сколько занимает и чистка

enum StorageKind: String, CaseIterable, Identifiable {
    case photos, videos, voice, files, avatars, stickers, chats
    var id: String { rawValue }
    /// Это можно удалить (стикеры и переписки — нет: они нужны для работы без сети)
    var clearable: Bool { self != .stickers && self != .chats }
}

enum CacheJanitor {
    private static let videoExt: Set<String> = ["mp4", "mov", "m4v"]
    private static let voiceExt: Set<String> = ["m4a", "mp3", "aac", "wav", "caf", "ogg", "opus"]

    private static func kind(of url: URL) -> StorageKind {
        let e = url.pathExtension.lowercased()
        if videoExt.contains(e) { return .videos }
        if voiceExt.contains(e) { return .voice }
        return .files
    }

    private static func files(in dir: URL) -> [(url: URL, size: Int, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey, .isDirectoryKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return [] }
        var out: [(URL, Int, Date)] = []
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isDirectory != true else { continue }
            out.append((u, v.fileSize ?? 0, v.contentAccessDate ?? v.contentModificationDate ?? .distantPast))
        }
        return out
    }

    private static func dirSize(_ dir: URL) -> Int { files(in: dir).reduce(0) { $0 + $1.size } }

    private static var supportDir: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }

    /// Размеры по видам (считается в фоне)
    static func usage() -> [StorageKind: Int] {
        var out: [StorageKind: Int] = [:]
        out[.photos] = URLCache.shared.currentDiskUsage
        for f in files(in: MediaFileCache.dir) { out[kind(of: f.url), default: 0] += f.size }
        out[.avatars] = dirSize(supportDir.appendingPathComponent("avatars-v1", isDirectory: true))
        out[.stickers] = StickerVault.shared.diskUsage()
        out[.chats] = dirSize(supportDir.appendingPathComponent("Orbita", isDirectory: true))
        return out
    }

    /// Удалить выбранное; возвращает, сколько освободили
    @discardableResult
    static func clear(_ kinds: Set<StorageKind>) -> Int {
        var freed = 0
        if kinds.contains(.photos) {
            freed += URLCache.shared.currentDiskUsage
            URLCache.shared.removeAllCachedResponses()
            UserDefaults.standard.set(Date(), forKey: "cache.photosPurged")
        }
        let media = kinds.intersection([.videos, .voice, .files])
        if !media.isEmpty {
            for f in files(in: MediaFileCache.dir) where media.contains(kind(of: f.url)) {
                if (try? FileManager.default.removeItem(at: f.url)) != nil { freed += f.size }
            }
            MediaFileCache.shared.forgetAll()
        }
        if kinds.contains(.avatars) {
            for f in files(in: supportDir.appendingPathComponent("avatars-v1", isDirectory: true)) {
                if (try? FileManager.default.removeItem(at: f.url)) != nil { freed += f.size }
            }
        }
        return freed
    }

    /// Срок хранения и предел размера: запускается при старте, при уходе в фон и при смене настроек
    static func enforce() {
        Task.detached(priority: .utility) {
            var removed = false
            let keep = DataPrefs.keepDays
            if keep > 0 {
                let limit = Date().addingTimeInterval(-Double(keep) * 86400)
                for f in files(in: MediaFileCache.dir) where f.date < limit {
                    try? FileManager.default.removeItem(at: f.url); removed = true
                }
                // у картинок нет даты по отдельности: раз в «срок» кэш картинок обновляется целиком
                let last = UserDefaults.standard.object(forKey: "cache.photosPurged") as? Date ?? Date()
                if UserDefaults.standard.object(forKey: "cache.photosPurged") == nil {
                    UserDefaults.standard.set(Date(), forKey: "cache.photosPurged")
                } else if last < limit {
                    URLCache.shared.removeAllCachedResponses()
                    UserDefaults.standard.set(Date(), forKey: "cache.photosPurged")
                }
            }
            let maxMB = DataPrefs.maxCacheMB
            if maxMB > 0 {
                let cap = maxMB * 1024 * 1024
                // картинкам — до трети предела (URLCache сам вытесняет старое), остальное — видео, голосовые, файлы
                URLCache.shared.diskCapacity = min(cap / 3, 400 * 1024 * 1024)
                var list = files(in: MediaFileCache.dir).sorted { $0.date < $1.date }
                var total = list.reduce(0) { $0 + $1.size } + URLCache.shared.currentDiskUsage
                while total > cap, !list.isEmpty {
                    let f = list.removeFirst()
                    try? FileManager.default.removeItem(at: f.url); removed = true
                    total -= f.size
                }
            } else {
                URLCache.shared.diskCapacity = 400 * 1024 * 1024
            }
            if removed { MediaFileCache.shared.forgetAll() }
        }
    }
}

// MARK: Сохранять в «Фото»

enum SaveScope: String { case privateChats, groups, channels }

private struct SaveScopeKey: EnvironmentKey { static let defaultValue: SaveScope? = nil }
extension EnvironmentValues {
    /// Какой это чат — для «Сохранять в Фото» (nil — не чат, ничего не сохраняем)
    var saveScope: SaveScope? {
        get { self[SaveScopeKey.self] }
        set { self[SaveScopeKey.self] = newValue }
    }
}

enum IncomingSaver {
    private static let savedKey = "save.done.v1"

    static func enabled(_ scope: SaveScope) -> Bool { UserDefaults.standard.bool(forKey: "save." + scope.rawValue) }

    /// Входящее фото/видео показалось в чате — если включено, кладём его в «Фото» (один раз)
    static func consider(messageID: String, attachments: [ChatAttachment], scope: SaveScope?) {
        guard let scope, enabled(scope) else { return }
        var done = Set(UserDefaults.standard.stringArray(forKey: savedKey) ?? [])
        guard !done.contains(messageID) else { return }
        let media = attachments.filter { ($0.kind == .photo || $0.kind == .video) && $0.mediaID != nil }
        guard !media.isEmpty else { return }
        done.insert(messageID)
        UserDefaults.standard.set(Array(done.suffix(3000)), forKey: savedKey)
        Task.detached(priority: .utility) {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { return }
            for a in media {
                guard let id = a.mediaID else { continue }
                if a.kind == .video {
                    guard let url = await MediaFileCache.shared.download(id) else { continue }
                    try? await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    }
                } else if let remote = ServerConfig.mediaURL(id),
                          let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: remote, cachePolicy: .returnCacheDataElseLoad)),
                          let image = UIImage(data: data) {
                    try? await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAsset(from: image)
                    }
                }
            }
        }
    }

    /// «Сохранять изменённые фото»: отредактированное перед отправкой фото — копией в «Фото»
    static func saveEdited(_ image: UIImage) {
        guard UserDefaults.standard.bool(forKey: "save.edited") else { return }
        Task.detached(priority: .utility) {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { return }
            try? await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
        }
    }
}

// MARK: - Экран «Данные и память»

struct DataScreen: View {
    @AppStorage("autoplay") private var autoplay = true
    @AppStorage("autoplay.gif") private var autoplayGIF = true
    @AppStorage("save.privateChats") private var savePrivate = false
    @AppStorage("save.groups") private var saveGroups = false
    @AppStorage("save.channels") private var saveChannels = false
    @AppStorage("save.edited") private var saveEdited = false
    @AppStorage("cache.keepDays") private var keepDays = 0
    @AppStorage("cache.maxMB") private var maxMB = 0
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @ObservedObject private var usage = NetUsage.shared

    @State private var sheet: Sub?
    @State private var storageTotal: Int?
    @State private var autoTick = 0
    @State private var showBackup = false

    enum Sub: String, Identifiable { case storage, network, cellular, wifi; var id: String { rawValue } }

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsRow(icon: "chart.pie.fill", tint: Color(red: 0.2, green: 0.55, blue: 0.98),
                            title: s.t("Использование памяти", "Storage usage"),
                            value: storageTotal.map { bytes($0) } ?? "…", showsChevron: true) { sheet = .storage }
                SettingsDivider()
                SettingsRow(icon: "chart.bar.fill", tint: Color(red: 0.2, green: 0.75, blue: 0.4),
                            title: s.t("Использование трафика", "Data usage"),
                            value: bytes(usage.total(cellular: nil)), showsChevron: true) { sheet = .network }
            }

            header(s.t("Автозагрузка медиа", "Automatic media download"))
            SettingsGroup {
                autoRow(cellular: true)
                SettingsDivider()
                autoRow(cellular: false)
                SettingsDivider()
                Button {
                    Haptics.select()
                    DataPrefs.resetAuto()
                    autoTick += 1
                } label: {
                    Text(s.t("Сбросить настройки автозагрузки", "Reset auto-download settings"))
                        .font(.system(size: 16)).foregroundStyle(theme.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).frame(height: 50).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
            footer(s.t("Что скачивается само, когда вы листаете чаты. Остальное — по нажатию. Файлы больше 10 МБ сами не скачиваются.",
                       "What downloads by itself while you scroll chats. Everything else — on tap. Files over 10 MB never auto-download."))

            header(s.t("Сохранять в Фото", "Save to Photos"))
            SettingsGroup {
                toggleRow("person.fill", .blue, s.t("Личные чаты", "Private chats"), $savePrivate)
                SettingsDivider()
                toggleRow("person.2.fill", .green, s.t("Группы", "Groups"), $saveGroups)
                SettingsDivider()
                toggleRow("megaphone.fill", .orange, s.t("Каналы", "Channels"), $saveChannels)
            }
            footer(s.t("Новые входящие фото и видео сами сохраняются в «Фото».", "New incoming photos and videos are saved to Photos automatically."))

            header(s.t("Автовоспроизведение", "Autoplay"))
            SettingsGroup {
                toggleRow("sparkles.tv.fill", .purple, "GIF", $autoplayGIF)
                SettingsDivider()
                toggleRow("play.rectangle.fill", .orange, s.t("Видео", "Videos"), $autoplay)
            }
            footer(s.autoplayHint)

            header(s.t("Хранение", "Storage"))
            SettingsGroup {
                pickerRow("clock.fill", .teal, s.t("Хранить медиа", "Keep media"), value: keepTitle(keepDays),
                          options: [3, 7, 30, 0].map { ($0, keepTitle($0)) }, selection: $keepDays)
                SettingsDivider()
                pickerRow("externaldrive.fill", .indigo, s.t("Максимальный размер кэша", "Maximum cache size"), value: maxTitle(maxMB),
                          options: [1024, 5120, 16384, 0].map { ($0, maxTitle($0)) }, selection: $maxMB)
            }
            footer(s.t("Фото, видео и файлы, которые вы не открывали дольше этого срока, удаляются с телефона — при необходимости скачаются снова.",
                       "Media you haven't opened for longer than this is removed from the phone and re-downloaded if needed."))

            header(s.t("Резервная копия", "Backup"))
            SettingsGroup {
                SettingsRow(icon: "lock.doc.fill", tint: .indigo, title: s.t("Резервная копия переписок", "Chat backup"),
                            showsChevron: true) { showBackup = true }
            }
            footer(s.t("Зашифрованный файл со всеми личными переписками и настройками — сохраните в «Файлы» или iCloud Drive и восстановите на любом телефоне.",
                       "An encrypted file with all your private chats and settings — save it to Files or iCloud Drive and restore on any phone."))

            header(s.t("Другое", "Other"))
            SettingsGroup {
                toggleRow("photo.badge.checkmark.fill", .pink, s.t("Сохранять изменённые фото", "Save edited photos"), $saveEdited)
            }
            footer(s.t("Фото, которые вы отредактировали перед отправкой, сохраняются копией в «Фото».",
                       "Photos you edit before sending are also saved to Photos."))
        }
        .padding(.bottom, 10)
        .task { await refreshTotal() }
        .onChange(of: keepDays) { _, _ in CacheJanitor.enforce(); Task { try? await Task.sleep(nanoseconds: 600_000_000); await refreshTotal() } }
        .onChange(of: maxMB) { _, _ in CacheJanitor.enforce(); Task { try? await Task.sleep(nanoseconds: 600_000_000); await refreshTotal() } }
        .onChange(of: savePrivate) { _, on in if on { askPhotos() } }
        .onChange(of: saveGroups) { _, on in if on { askPhotos() } }
        .onChange(of: saveChannels) { _, on in if on { askPhotos() } }
        .onChange(of: saveEdited) { _, on in if on { askPhotos() } }
        .sheet(isPresented: $showBackup) {
            BackupScreen().environment(\.theme, theme).environment(\.lang, lang)
        }
        .sheet(item: $sheet, onDismiss: { Task { await refreshTotal() }; autoTick += 1 }) { sub in
            Group {
                switch sub {
                case .storage: StorageUsageView()
                case .network: NetworkUsageView()
                case .cellular: AutoDownloadView(cellular: true)
                case .wifi: AutoDownloadView(cellular: false)
                }
            }
            .environment(\.theme, theme).environment(\.lang, lang)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private func refreshTotal() async {
        let u = await Task.detached(priority: .utility) { CacheJanitor.usage() }.value
        storageTotal = u.values.reduce(0, +)
    }

    private func askPhotos() {
        Task { _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
    }

    private func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    private func autoSummary(cellular: Bool) -> String {
        _ = autoTick
        let on = AutoKind.allCases.filter { DataPrefs.autoDownload($0, cellular: cellular) }
        if on.isEmpty { return s.t("Выключено", "Off") }
        return on.map { autoName($0) }.joined(separator: ", ")
    }

    func autoName(_ k: AutoKind) -> String {
        switch k {
        case .photo: return s.t("Фото", "Photos")
        case .video: return s.t("Видео", "Videos")
        case .file: return s.t("Файлы", "Files")
        case .voice: return s.t("Голосовые", "Voice")
        }
    }

    private func autoRow(cellular: Bool) -> some View {
        Button { sheet = cellular ? .cellular : .wifi } label: {
            HStack(spacing: 14) {
                Image(systemName: cellular ? "antenna.radiowaves.left.and.right" : "wifi")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(cellular ? Color.green : Color.blue, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(cellular ? s.t("Через мобильную сеть", "Using cellular") : s.t("Через Wi-Fi", "Using Wi-Fi"))
                        .font(.system(size: 16)).foregroundStyle(theme.text)
                    Text(autoSummary(cellular: cellular))
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 14).frame(height: 60).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private func toggleRow(_ icon: String, _ tint: Color, _ title: String, _ value: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint, in: RoundedRectangle(cornerRadius: 8))
            Text(title).font(.system(size: 16)).foregroundStyle(theme.text)
            Spacer()
            Toggle("", isOn: value).labelsHidden().tint(theme.accentColor)
        }
        .padding(.horizontal, 14).frame(height: 52)
    }

    private func pickerRow(_ icon: String, _ tint: Color, _ title: String, value: String,
                           options: [(Int, String)], selection: Binding<Int>) -> some View {
        Menu {
            ForEach(options, id: \.0) { o in
                Button {
                    Haptics.select()
                    selection.wrappedValue = o.0
                } label: {
                    if selection.wrappedValue == o.0 { Label(o.1, systemImage: "checkmark") } else { Text(o.1) }
                }
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(tint, in: RoundedRectangle(cornerRadius: 8))
                Text(title).font(.system(size: 16)).foregroundStyle(theme.text).lineLimit(1)
                Spacer(minLength: 8)
                Text(value).font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12)).foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 14).frame(height: 52).contentShape(Rectangle())
        }
    }

    private func keepTitle(_ d: Int) -> String {
        switch d {
        case 3: return s.t("3 дня", "3 days")
        case 7: return s.t("1 неделя", "1 week")
        case 30: return s.t("1 месяц", "1 month")
        default: return s.t("Всегда", "Forever")
        }
    }

    private func maxTitle(_ mb: Int) -> String {
        mb == 0 ? s.t("Без ограничений", "No limit") : ByteCountFormatter.string(fromByteCount: Int64(mb) * 1024 * 1024, countStyle: .file)
    }

    private func header(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 30).padding(.top, 26).padding(.bottom, 8)
    }

    private func footer(_ t: String) -> some View {
        Text(t).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 30).padding(.top, 8)
    }
}

// MARK: - Шапка подэкранов

private struct SubHeader: View {
    let title: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    var body: some View {
        ZStack {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(theme.textSecondary)
                        .frame(width: 34, height: 34).background(theme.surface, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 8)
    }
}

/// Круговая диаграмма по долям (как в «Использовании памяти» Telegram)
private struct Donut: View {
    let parts: [(value: Double, color: Color)]
    var body: some View {
        let total = max(parts.reduce(0) { $0 + $1.value }, 1)
        ZStack {
            Circle().stroke(Color.gray.opacity(0.18), lineWidth: 26)
            ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                let start = parts.prefix(i).reduce(0) { $0 + $1.value } / total
                let end = start + p.value / total
                Circle()
                    .trim(from: start, to: max(start, end - 0.004))
                    .stroke(p.color, style: StrokeStyle(lineWidth: 26, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

// MARK: - Использование памяти

struct StorageUsageView: View {
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var sizes: [StorageKind: Int] = [:]
    @State private var loaded = false
    @State private var selected: Set<StorageKind> = Set(StorageKind.allCases.filter(\.clearable))
    @State private var clearing = false
    @State private var freed = 0

    private var s: Strings { Strings(lang: lang) }

    private func title(_ k: StorageKind) -> String {
        switch k {
        case .photos: return s.t("Фото", "Photos")
        case .videos: return s.t("Видео и кружки", "Videos")
        case .voice: return s.t("Голосовые и музыка", "Voice & music")
        case .files: return s.t("Файлы", "Files")
        case .avatars: return s.t("Аватарки", "Profile photos")
        case .stickers: return s.t("Стикеры", "Stickers")
        case .chats: return s.t("Переписки без сети", "Offline chats")
        }
    }

    private func color(_ k: StorageKind) -> Color {
        switch k {
        case .photos: return Color(red: 0.2, green: 0.55, blue: 0.98)
        case .videos: return Color(red: 0.6, green: 0.35, blue: 0.95)
        case .voice: return Color(red: 0.98, green: 0.55, blue: 0.2)
        case .files: return Color(red: 0.2, green: 0.75, blue: 0.4)
        case .avatars: return Color(red: 0.95, green: 0.3, blue: 0.5)
        case .stickers: return Color(red: 0.98, green: 0.8, blue: 0.2)
        case .chats: return Color(red: 0.45, green: 0.6, blue: 0.7)
        }
    }

    private var total: Int { sizes.values.reduce(0, +) }
    private var selectedBytes: Int { selected.reduce(0) { $0 + (sizes[$1] ?? 0) } }
    private func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader(title: s.t("Использование памяти", "Storage usage"))
            ScrollView {
                VStack(spacing: 18) {
                    ZStack {
                        Donut(parts: StorageKind.allCases.map { (Double(sizes[$0] ?? 0), color($0)) })
                            .frame(width: 180, height: 180)
                            .animation(.easeOut(duration: 0.5), value: total)
                        VStack(spacing: 2) {
                            Text(loaded ? bytes(total) : "…").font(.system(size: 24, weight: .bold)).foregroundStyle(theme.text)
                            Text(s.t("на телефоне", "on this phone")).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        }
                    }
                    .padding(.top, 10)

                    Text(s.t("Всё, что Orbita хранит на телефоне. Удалённое скачается заново, когда понадобится — сообщения и медиа остаются на сервере.",
                             "Everything Orbita keeps on this phone. Removed media re-downloads when needed — it stays on the server."))
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 28)

                    SettingsGroup {
                        ForEach(Array(StorageKind.allCases.enumerated()), id: \.element) { i, k in
                            row(k)
                            if i < StorageKind.allCases.count - 1 { SettingsDivider() }
                        }
                    }

                    Button {
                        guard selectedBytes > 0 else { return }
                        let kinds = selected
                        Haptics.impact(.soft)
                        Task {
                            freed = await Task.detached(priority: .userInitiated) { CacheJanitor.clear(kinds) }.value
                            clearing = true
                            await load()
                        }
                    } label: {
                        Text(selectedBytes > 0 ? s.t("Очистить ", "Clear ") + bytes(selectedBytes) : s.t("Нечего очищать", "Nothing to clear"))
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 54)
                            .background(selectedBytes > 0 ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.gray.opacity(0.4)),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(PressStyle())
                    .disabled(selectedBytes == 0)

                    Text(s.t("Стикеры ваших наборов и переписки для работы без сети не удаляются: они нужны, чтобы Orbita открывалась и без интернета.",
                             "Your sticker packs and offline chats aren't removed: Orbita needs them to work without internet."))
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary).padding(.horizontal, 30)
                }
                .padding(.bottom, 30)
            }
        }
        .background(theme.sheet.ignoresSafeArea())
        .task { await load() }
        .fullScreenCover(isPresented: $clearing) {
            CacheClearView(freedBytes: freed) { clearing = false }
                .preferredColorScheme(theme.dark ? .dark : .light)
        }
    }

    private func load() async {
        sizes = await Task.detached(priority: .userInitiated) { CacheJanitor.usage() }.value
        loaded = true
    }

    private func row(_ k: StorageKind) -> some View {
        let n = sizes[k] ?? 0
        let pct = total > 0 ? Double(n) / Double(total) * 100 : 0
        return Button {
            guard k.clearable else { return }
            Haptics.select()
            if selected.contains(k) { selected.remove(k) } else { selected.insert(k) }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(k.clearable && selected.contains(k) ? color(k) : Color.clear)
                    Circle().stroke(k.clearable ? color(k) : theme.textTertiary, lineWidth: 2)
                    if k.clearable && selected.contains(k) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    } else if !k.clearable {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(theme.textTertiary)
                    }
                }
                .frame(width: 22, height: 22)
                Text(title(k)).font(.system(size: 16)).foregroundStyle(theme.text)
                Text(pct >= 0.1 ? String(format: "%.1f%%", pct) : (n > 0 ? "<0.1%" : ""))
                    .font(.system(size: 13)).foregroundStyle(theme.textTertiary)
                Spacer(minLength: 6)
                Text(bytes(n)).font(.system(size: 15)).foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 14).frame(height: 50).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - Использование трафика

struct NetworkUsageView: View {
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @ObservedObject private var usage = NetUsage.shared
    @State private var net = 0                // 0 — все, 1 — мобильная, 2 — Wi-Fi
    @State private var confirmReset = false

    private var s: Strings { Strings(lang: lang) }
    private var cellular: Bool? { net == 0 ? nil : net == 1 }
    private func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    private func title(_ c: NetCategory) -> String {
        switch c {
        case .messages: return s.t("Сообщения и ленты", "Messages & feeds")
        case .photos: return s.t("Фото", "Photos")
        case .videos: return s.t("Видео", "Videos")
        case .voice: return s.t("Голосовые и музыка", "Voice & music")
        case .files: return s.t("Файлы", "Files")
        }
    }

    private func color(_ c: NetCategory) -> Color {
        switch c {
        case .messages: return Color(red: 0.2, green: 0.55, blue: 0.98)
        case .photos: return Color(red: 0.2, green: 0.75, blue: 0.4)
        case .videos: return Color(red: 0.6, green: 0.35, blue: 0.95)
        case .voice: return Color(red: 0.98, green: 0.55, blue: 0.2)
        case .files: return Color(red: 0.95, green: 0.3, blue: 0.5)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader(title: s.t("Использование трафика", "Data usage"))
            Picker("", selection: $net) {
                Text(s.t("Все", "All")).tag(0)
                Text(s.t("Мобильная", "Cellular")).tag(1)
                Text("Wi-Fi").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 18) {
                    ZStack {
                        Donut(parts: NetCategory.allCases.map {
                            (Double(usage.value($0, cellular: cellular, sent: true) + usage.value($0, cellular: cellular, sent: false)), color($0))
                        })
                        .frame(width: 180, height: 180)
                        VStack(spacing: 2) {
                            Text(bytes(usage.total(cellular: cellular))).font(.system(size: 24, weight: .bold)).foregroundStyle(theme.text)
                            Text(s.t("с ", "since ") + usage.since.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        }
                    }
                    .padding(.top, 10)
                    .animation(.easeOut(duration: 0.35), value: net)

                    ForEach(NetCategory.allCases) { c in
                        let out = usage.value(c, cellular: cellular, sent: true)
                        let inn = usage.value(c, cellular: cellular, sent: false)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Circle().fill(color(c)).frame(width: 10, height: 10)
                                Text(title(c).uppercased()).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                            }
                            .padding(.horizontal, 30)
                            SettingsGroup {
                                SettingsRow(icon: "arrow.up", tint: color(c), title: s.t("Отправлено", "Sent"), value: bytes(out))
                                SettingsDivider()
                                SettingsRow(icon: "arrow.down", tint: color(c), title: s.t("Получено", "Received"), value: bytes(inn))
                            }
                        }
                    }

                    Button { confirmReset = true } label: {
                        Text(s.t("Сбросить статистику", "Reset statistics"))
                            .font(.system(size: 16)).foregroundStyle(theme.danger)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .card(theme, radius: 16).padding(.horizontal, 16)
                    }
                    .buttonStyle(PressStyle())
                }
                .padding(.bottom, 30)
            }
        }
        .background(theme.sheet.ignoresSafeArea())
        .confirmationDialog(s.t("Сбросить статистику трафика?", "Reset data usage statistics?"), isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button(s.t("Сбросить", "Reset"), role: .destructive) { usage.reset() }
            Button(s.cancel, role: .cancel) {}
        }
    }
}

// MARK: - Автозагрузка по сети

struct AutoDownloadView: View {
    let cellular: Bool
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var values: [AutoKind: Bool] = [:]

    private var s: Strings { Strings(lang: lang) }

    private func meta(_ k: AutoKind) -> (String, Color, String) {
        switch k {
        case .photo: return ("photo.fill", .blue, s.t("Фото", "Photos"))
        case .video: return ("video.fill", .purple, s.t("Видео и кружки", "Videos & video messages"))
        case .file: return ("doc.fill", .green, s.t("Файлы до 10 МБ", "Files up to 10 MB"))
        case .voice: return ("mic.fill", .orange, s.t("Голосовые сообщения", "Voice messages"))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SubHeader(title: cellular ? s.t("Мобильная сеть", "Cellular") : "Wi-Fi")
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(s.t("СКАЧИВАТЬ АВТОМАТИЧЕСКИ", "DOWNLOAD AUTOMATICALLY"))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 30).padding(.top, 14)
                    SettingsGroup {
                        ForEach(Array(AutoKind.allCases.enumerated()), id: \.element) { i, k in
                            let m = meta(k)
                            HStack(spacing: 14) {
                                Image(systemName: m.0).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                    .frame(width: 30, height: 30).background(m.1, in: RoundedRectangle(cornerRadius: 8))
                                Text(m.2).font(.system(size: 16)).foregroundStyle(theme.text)
                                Spacer()
                                Toggle("", isOn: Binding(get: { values[k] ?? DataPrefs.autoDownload(k, cellular: cellular) },
                                                         set: { v in
                                                             values[k] = v
                                                             UserDefaults.standard.set(v, forKey: DataPrefs.key(k, cellular: cellular))
                                                         }))
                                    .labelsHidden().tint(theme.accentColor)
                            }
                            .padding(.horizontal, 14).frame(height: 52)
                            if i < AutoKind.allCases.count - 1 { SettingsDivider() }
                        }
                    }
                    Text(cellular
                         ? s.t("Выключенное по мобильной сети не тратит трафик: в чате будет кнопка «скачать».",
                               "Anything turned off won't use cellular data: chats show a download button instead.")
                         : s.t("По Wi-Fi обычно включено всё.", "Usually everything is on for Wi-Fi."))
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary).padding(.horizontal, 30)
                }
            }
        }
        .background(theme.sheet.ignoresSafeArea())
    }
}

/// Фото в чате: если автозагрузка фото по текущей сети выключена и картинки ещё нет на телефоне —
/// вместо неё кнопка «скачать» (не тратим трафик); нажали — загружается
struct GatedRemoteImage: View {
    let id: String
    @State private var allowed: Bool

    init(id: String) {
        self.id = id
        var ok = DataPrefs.autoNow(.photo)
        if !ok, let url = ServerConfig.mediaURL(id),
           URLCache.shared.cachedResponse(for: URLRequest(url: url)) != nil || ImageCache.shared.memory(url, maxPixel: 1280) != nil {
            ok = true
        }
        _allowed = State(initialValue: ok)
    }

    var body: some View {
        if allowed {
            RemoteImage(id: id)
        } else {
            ZStack {
                Color.gray.opacity(0.35)
                Button {
                    Haptics.select()
                    allowed = true
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Color.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
