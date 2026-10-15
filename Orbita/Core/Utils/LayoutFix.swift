import Foundation

/// Исправление раскладки клавиатуры (ЙЦУКЕН ↔ QWERTY)
enum LayoutFix {
    private static let cyrillic = Array("ёйцукенгшщзхъфывапролджэячсмитьбю")
    private static let latin    = Array("`qwertyuiop[]asdfghjkl;'zxcvbnm,.")

    private static let toLatinMap: [Character: Character] = Dictionary(uniqueKeysWithValues: zip(cyrillic, latin))
    private static let toCyrillicMap: [Character: Character] = Dictionary(uniqueKeysWithValues: zip(latin, cyrillic))

    private static func isCyrillic(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    /// "ьфшд" -> "mail". В режиме почты кавычка (Shift+2 в русской раскладке) -> "@".
    static func toLatin(_ text: String, emailMode: Bool = false) -> String {
        var result = ""
        for ch in text {
            if emailMode && ch == "\"" { result.append("@"); continue }
            if isCyrillic(ch), let mapped = toLatinMap[Character(ch.lowercased())] {
                result.append(ch.isUppercase ? Character(String(mapped).uppercased()) : mapped)
            } else {
                result.append(ch)
            }
        }
        return result
    }

    /// "hjccbz" -> "россия"
    static func toCyrillic(_ text: String) -> String {
        var result = ""
        for ch in text {
            if let mapped = toCyrillicMap[Character(ch.lowercased())] {
                result.append(ch.isUppercase ? Character(String(mapped).uppercased()) : mapped)
            } else {
                result.append(ch)
            }
        }
        return result
    }

    /// Варианты запроса для поиска, не зависящего от раскладки
    static func variants(of query: String) -> [String] {
        var seen = Set<String>()
        return [query, toLatin(query), toCyrillic(query)].filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
