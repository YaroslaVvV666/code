import SwiftUI
import UIKit
import Combine
#if canImport(Lottie)
import Lottie
#endif

/// Своё эмодзи из эмодзи-пака (как custom emoji в Telegram): картинка 100×100 или анимация Lottie.
/// В тексте сообщения стоит обычный эмодзи-заменитель, а сущность `custom_emoji` с url `u:<id>` говорит, чем его нарисовать
struct CustomEmojiInfo: Codable, Equatable {
    let id: String              // "u:<id>"
    let emoji: String           // заменитель
    let mediaID: String
    let lottie: Bool
    var pack: String? = nil
}

/// Чем вставить своё эмодзи в поле ввода
struct CustomEmojiRef: Equatable {
    let id: String
    let fallback: String
}

/// Свои эмодзи на телефоне: сведения (какой файл, анимированный ли) и сами файлы лежат на диске и работают без сети.
/// Анимации — Lottie JSON, на сервере хранятся сжатыми: распаковываются один раз и держатся в памяти
@MainActor
final class CustomEmojiStore: ObservableObject {
    static let shared = CustomEmojiStore()

    /// Растёт, когда загрузилось новое эмодзи: текст с ним перерисовывается
    @Published private(set) var version = 0

    private var infos: [String: CustomEmojiInfo] = [:]
    private var stills: [String: UIImage] = [:]
    #if canImport(Lottie)
    private var animations: [String: LottieAnimation] = [:]
    #endif
    private var loading: Set<String> = []
    private var asking: Set<String> = []
    private var api: ServerAPI?

    private static let dir: URL = {
        var d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("custom-emoji", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? d.setResourceValues(values)
        return d
    }()
    private static var indexURL: URL { dir.appendingPathComponent("index.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let list = try? JSONDecoder().decode([CustomEmojiInfo].self, from: data) {
            for i in list { infos[i.id] = i }
        }
    }

    func attach(api: ServerAPI) { self.api = api }

    func info(_ id: String) -> CustomEmojiInfo? { infos[id] }

    /// Эмодзи из своих и добавленных наборов — сведения есть сразу, без запроса
    func register(_ packs: [StickerPack]) {
        var changed = false
        for p in packs where p.kind == "emoji" {
            for s in p.stickers {
                guard let media = s.mediaID else { continue }
                let i = CustomEmojiInfo(id: s.id, emoji: s.emoji, mediaID: media, lottie: s.lottie, pack: p.id)
                if infos[s.id] != i { infos[s.id] = i; changed = true }
            }
        }
        if changed { saveIndex() }
    }

    /// Неподвижная картинка (для текста). nil — ещё грузится: покажется заменитель, а потом текст перерисуется
    func still(_ id: String) -> UIImage? {
        if let img = stills[id] { return img }
        request([id])
        return nil
    }

    #if canImport(Lottie)
    func animation(_ id: String) -> LottieAnimation? {
        if let a = animations[id] { return a }
        request([id])
        return nil
    }
    #endif

    /// Подгрузить эмодзи (сведения — одним запросом на всех, файлы — по одному)
    func request(_ ids: [String]) {
        let unknown = ids.filter { infos[$0] == nil && !asking.contains($0) }
        if !unknown.isEmpty, let api {
            unknown.forEach { asking.insert($0) }
            Task {
                defer { unknown.forEach { asking.remove($0) } }
                struct R: Decodable { let emoji: [Item] }
                struct Item: Decodable { let id: String; let emoji: String; let mediaId: String; let lottie: Bool; let pack: String? }
                let q = unknown.prefix(100).joined(separator: ",")
                guard let data = try? await api.request("GET", "/v1/custom-emoji", query: ["ids": q]),
                      let r = try? decodeAPI(R.self, from: data) else { return }
                for i in r.emoji { infos[i.id] = CustomEmojiInfo(id: i.id, emoji: i.emoji, mediaID: i.mediaId, lottie: i.lottie, pack: i.pack) }
                saveIndex()
                for i in r.emoji { load(i.id) }
            }
        }
        for id in ids where infos[id] != nil { load(id) }
    }

    private func load(_ id: String) {
        guard let info = infos[id], stills[id] == nil, !loading.contains(id) else { return }
        loading.insert(id)
        Task {
            defer { loading.remove(id) }
            let file = Self.dir.appendingPathComponent(SafeFileName.clean(info.mediaID, fallback: "x"))
            var data = try? Data(contentsOf: file)
            if data == nil, let url = ServerConfig.mediaURL(info.mediaID),
               let (fetched, resp) = try? await URLSession.shared.data(from: url),
               (resp as? HTTPURLResponse)?.statusCode == 200, fetched.count <= 2 * 1024 * 1024 {
                data = fetched
                try? fetched.write(to: file, options: .atomic)
            }
            guard let data else { return }
            if info.lottie {
                #if canImport(Lottie)
                guard let json = Self.gunzip(data) ?? (data.first == UInt8(ascii: "{") ? data : nil),
                      let anim = try? LottieAnimation.from(data: json) else { return }
                animations[id] = anim
                stills[id] = Self.snapshot(anim)
                #else
                return
                #endif
            } else {
                guard let img = ImageCache.downsample(data, maxPixel: 200) else { return }
                stills[id] = img
            }
            version += 1
        }
    }

    private func saveIndex() {
        let list = Array(infos.values.suffix(2000))
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: Self.indexURL, options: .atomic) }
    }

    #if canImport(Lottie)
    /// Кадр из середины анимации — для текста и для покоя
    private static func snapshot(_ anim: LottieAnimation) -> UIImage? {
        let view = LottieAnimationView(animation: anim, configuration: LottieConfiguration(renderingEngine: .mainThread))
        view.frame = CGRect(x: 0, y: 0, width: 120, height: 120)
        view.contentMode = .scaleAspectFit
        view.currentProgress = 0.5
        view.layoutIfNeeded()
        return UIGraphicsImageRenderer(size: view.bounds.size).image { ctx in view.layer.render(in: ctx.cgContext) }
    }
    #endif

    /// Распаковать gzip: заголовок gzip + «сырой» deflate + 8 байт хвоста
    nonisolated static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data.prefix(4096))
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 {                                   // FEXTRA
            guard b.count > i + 2 else { return nil }
            i += 2 + Int(b[i]) + Int(b[i + 1]) << 8
        }
        if flags & 8 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }      // FNAME
        if flags & 16 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }     // FCOMMENT
        if flags & 2 != 0 { i += 2 }                                               // FHCRC
        guard i < data.count - 8 else { return nil }
        let body = data.subdata(in: (data.startIndex + i)..<(data.endIndex - 8))
        guard let out = try? (body as NSData).decompressed(using: .zlib) as Data, out.count <= 2 * 1024 * 1024 else { return nil }
        return out
    }
}

// MARK: - Своё эмодзи на экране

/// Своё эмодзи: анимированное (Lottie) или картинка. Пока не загрузилось — обычный эмодзи-заменитель
struct CustomEmojiView: View {
    let id: String
    var fallback = ""
    var size: CGFloat = 28
    var animate = true

    @ObservedObject private var store = CustomEmojiStore.shared
    @State private var visible = false
    @State private var start = Date()

    var body: some View {
        let _ = store.version
        ZStack {
            #if canImport(Lottie)
            if animate, visible, let anim = store.animation(id) {
                let duration = max(0.1, anim.duration)
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                    let p = ctx.date.timeIntervalSince(start) / duration
                    LottieView(animation: anim)
                        .currentProgress(p.truncatingRemainder(dividingBy: 1))
                        .resizable()
                }
            } else if let img = store.still(id) {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                Text(fallback).font(.system(size: size * 0.8))
            }
            #else
            if let img = store.still(id) {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                Text(fallback).font(.system(size: size * 0.8))
            }
            #endif
        }
        .frame(width: size, height: size)
        .onAppear { visible = true; start = Date() }
        .onDisappear { visible = false }
    }
}

extension ChatMessage {
    /// Свои эмодзи в тексте (по порядку)
    var customEmoji: [(range: NSRange, id: String)] {
        entities.filter { $0.type == "custom_emoji" }.compactMap { e in
            guard let url = e.url else { return nil }
            return (NSRange(location: e.offset, length: e.length), url)
        }
        .sorted { $0.range.location < $1.range.location }
    }

    /// Сообщение только из своих эмодзи (1–3 штуки, без другого текста) — показываем крупно и анимированно
    var bigCustomEmoji: [String]? {
        let list = customEmoji
        guard !list.isEmpty, list.count <= 3, attachments.isEmpty, reply == nil else { return nil }
        let ns = text as NSString
        var rest = text
        for item in list.reversed() where item.range.location + item.range.length <= ns.length {
            rest = (rest as NSString).replacingCharacters(in: item.range, with: "")
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? list.map(\.id) : nil
    }
}
