import Foundation

/// Защита от «вредоносных» файлов и ссылок, которые может прислать собеседник.
///
/// Имя файла, подпись, ссылка в сообщении — всё это чужие данные. Нельзя:
/// • класть файл по пути из чужого имени (`../../Library/...` перезапишет наши данные);
/// • показывать имя с невидимыми символами направления текста («фото‮gnp.exe» выглядит как «фотоexe.png»);
/// • открывать ссылки с произвольными схемами (`shortcuts://`, `file://`, `javascript:` и т.п.) одним касанием.
enum SafeFileName {
    /// Символы, которые меняют направление/видимость текста — ими подделывают расширение файла
    private static let invisible: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
        "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{FEFF}", "\u{061C}"
    ]

    /// Безопасное имя для одного компонента пути: без разделителей, `..`, управляющих и невидимых символов,
    /// не начинается с точки, не длиннее 120 символов (расширение сохраняется)
    static func clean(_ raw: String?, fallback: String = "file") -> String {
        var scalars = String.UnicodeScalarView()
        for u in (raw ?? "").unicodeScalars {
            if invisible.contains(u) { continue }
            if CharacterSet.controlCharacters.contains(u) || CharacterSet.illegalCharacters.contains(u) { continue }
            if "/\\:?*\"<>|".unicodeScalars.contains(u) { scalars.append("_"); continue }
            scalars.append(u)
        }
        var name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }          // «..», «.hidden» и т.п.
        name = name.replacingOccurrences(of: "..", with: "_")
        if name.count > 120 {
            let ext = (name as NSString).pathExtension
            let keep = ext.isEmpty || ext.count > 10 ? "" : "." + ext
            name = String(name.prefix(120 - keep.count)) + keep
        }
        return name.isEmpty ? fallback : name
    }

    /// Имя для показа на экране (подпись файла в пузыре): то же очищение, но без замены разделителей
    static func display(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in raw.unicodeScalars where !invisible.contains(u) && !CharacterSet.controlCharacters.contains(u) {
            scalars.append(u)
        }
        return String(scalars)
    }

    /// Файл точно лежит внутри папки (защита от выхода по символическим ссылкам и `..`)
    static func isInside(_ file: URL, _ folder: URL) -> Bool {
        let f = file.standardizedFileURL.resolvingSymlinksInPath().path
        let d = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return f.hasPrefix(d.hasSuffix("/") ? d : d + "/")
    }
}

enum SafeLink {
    /// Схемы, которые можно открыть касанием по ссылке из чужого текста.
    /// tel/sms/mailto система всё равно подтверждает отдельным окном.
    private static let external: Set<String> = ["http", "https", "mailto", "tel", "sms"]

    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if external.contains(scheme) {
            if scheme == "http" || scheme == "https" { return !(url.host ?? "").isEmpty }
            return true
        }
        return false
    }

    /// Ссылка из строки (превью ссылки, реклама): только разрешённые схемы, без пробелов и невидимых символов
    static func url(_ raw: String) -> URL? {
        let cleaned = SafeFileName.display(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleaned), isAllowed(url) else { return nil }
        return url
    }
}

/// Скрытая ссылка: текст «sberbank.ru», а ведёт на «sberbank-login.xyz». Такие ссылки открываются только после окна
/// с настоящим адресом (как в Telegram), а если в тексте написан другой сайт — с предупреждением о подмене.
enum HiddenLink {
    static let scheme = "orbita-hidden"

    /// Ссылка, текст которой и есть её адрес, остаётся как есть; остальные — через подтверждение
    static func wrap(_ url: URL, shown: String) -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return url }
        if normalized(shown) == normalized(url.absoluteString) { return url }
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "u", value: url.absoluteString),
                        URLQueryItem(name: "t", value: String(shown.prefix(200)))]
        return c.url ?? url
    }

    static func parse(_ url: URL) -> (url: URL, shown: String)? {
        guard url.scheme == scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "u" })?.value, let real = SafeLink.url(raw) else { return nil }
        return (real, items.first { $0.name == "t" }?.value ?? "")
    }

    /// В тексте ссылки написан один сайт, а ведёт она на другой — явная подмена
    static func spoofed(shown: String, real: URL) -> Bool {
        guard let realHost = real.host?.lowercased() else { return false }
        let text = SafeFileName.display(shown).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidate = text.contains("://") ? text : "https://" + text
        guard text.contains("."), !text.contains(" "), let shownHost = URL(string: candidate)?.host?.lowercased() else { return false }
        let a = shownHost.hasPrefix("www.") ? String(shownHost.dropFirst(4)) : shownHost
        let b = realHost.hasPrefix("www.") ? String(realHost.dropFirst(4)) : realHost
        return a != b && !b.hasSuffix("." + a)
    }

    /// Показать окно «Открыть ссылку?» и открыть после подтверждения
    @MainActor
    static func confirm(_ url: URL, shown: String, open: @escaping (URL) -> Void) {
        let lang = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "lang") ?? "") ?? .ru
        let s = Strings(lang: lang)
        let address = url.absoluteString.count > 300 ? String(url.absoluteString.prefix(300)) + "…" : url.absoluteString
        let warn = spoofed(shown: shown, real: url)
        let host = url.host ?? address
        let message = warn
            ? s.t("⚠️ Текст ссылки — «\(shown)», но она ведёт на другой сайт: \(host).\n\nТак часто маскируют мошеннические страницы.\n\n\(address)",
                  "⚠️ The link says «\(shown)», but it leads to another site: \(host).\n\nThis is a common phishing trick.\n\n\(address)")
            : address
        AppAlert.confirm(warn ? s.t("Подозрительная ссылка", "Suspicious link") : s.t("Открыть ссылку?", "Open this link?"),
                         message, ok: s.t("Открыть", "Open"), cancel: s.t("Отмена", "Cancel")) { open(url) }
    }

    private static func normalized(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for p in ["https://", "http://"] where v.hasPrefix(p) { v.removeFirst(p.count) }
        if v.hasPrefix("www.") { v.removeFirst(4) }
        while v.hasSuffix("/") { v.removeLast() }
        return v
    }
}
