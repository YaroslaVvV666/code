import SwiftUI

/// Ссылки в обычном тексте (описания, комментарии, био): находит адреса и делает их нажимаемыми.
/// Нажатие идёт через openURL окружения — ссылки Orbita открываются внутри приложения.
enum Linkify {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Адрес в слове, если оно целиком — ссылка
    static func url(in word: String) -> URL? {
        guard word.count > 3, let detector else { return nil }
        let ns = word as NSString
        let all = NSRange(location: 0, length: ns.length)
        guard let match = detector.firstMatch(in: word, options: [], range: all),
              match.range.length >= ns.length - 2 else { return nil }
        return match.url
    }

    static func attributed(_ text: String, underline: Bool = true) -> AttributedString {
        var result = AttributedString(text)
        guard let detector else { return result }
        let ns = text as NSString
        for match in detector.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, let r = Range(match.range, in: text),
                  let lower = AttributedString.Index(r.lowerBound, within: result),
                  let upper = AttributedString.Index(r.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
            if underline { result[lower..<upper].underlineStyle = .single }
        }
        return result
    }
}

/// Текст с нажимаемыми ссылками
struct LinkText: View {
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        Text(Linkify.attributed(text)).tint(tint)
    }
}
