import Foundation

// MARK: - Форматирование номера

/// Шаблон номера: X — цифра, "-" — разделитель
func phonePattern(for code: String) -> String {
    switch code {
    case "+1":                                    return "XXX-XXX-XXXX"
    case "+44":                                   return "XXXX-XXXXXX"
    case "+49":                                   return "XXXX-XXXXXXX"
    case "+33", "+34", "+39":                     return "XXX-XXX-XXX"
    case "+380", "+375", "+374", "+995", "+994", "+998":
                                                  return "XX-XXX-XX-XX"
    case "+86":                                   return "XXX-XXXX-XXXX"
    case "+91":                                   return "XXXXX-XXXXX"
    default:                                      return "XXX-XXX-XX-XX"
    }
}

/// 9817990269 -> 981-799-02-69 (разделитель ставится, только если дальше есть цифры)
func formatDigits(_ digits: String, code: String, separator: Character = "-") -> String {
    let pattern = phonePattern(for: code)
    let maxDigits = pattern.filter { $0 == "X" }.count
    let trimmed = String(digits.prefix(maxDigits))

    var result = ""
    var index = trimmed.startIndex
    for ch in pattern {
        guard index < trimmed.endIndex else { break }
        if ch == "X" {
            result.append(trimmed[index])
            index = trimmed.index(after: index)
        } else {
            result.append(separator)
        }
    }
    return result
}

// MARK: - Проверки (валидация)

enum Validator {

    // Номер

    static func phoneDigitsRange(code: String) -> ClosedRange<Int> {
        let n = phonePattern(for: code).filter { $0 == "X" }.count
        return code == "+7" ? n...n : (n - 1)...n
    }

    /// nil — номер адекватный, иначе причина отказа
    static func validatePhone(code: String, digits: String) -> PhoneIssue? {
        guard code.count > 1 else { return .incomplete }

        let range = phoneDigitsRange(code: code)
        if digits.count < range.lowerBound { return .incomplete }
        if digits.count > range.upperBound { return .tooLong }

        // +7: мобильные номера России (9xx) и Казахстана (6xx, 7xx)
        if code == "+7", let first = digits.first, !"967".contains(first) { return .notMobile }

        if Set(digits).count < 3 { return .looksFake }       // 0000000000, 9099099099
        if isSequential(digits) { return .looksFake }        // 1234567890

        return nil
    }

    private static func isSequential(_ digits: String) -> Bool {
        let v = digits.compactMap { $0.wholeNumberValue }
        guard v.count > 4 else { return false }
        let up = zip(v, v.dropFirst()).allSatisfy { ($1 - $0 + 10) % 10 == 1 }
        let down = zip(v, v.dropFirst()).allSatisfy { ($0 - $1 + 10) % 10 == 1 }
        return up || down
    }

    // Имя

    /// Имя: 2–40 символов — буквы, цифры, пробел, - _ . ' (например, Adrei202)
    static func normalizeName(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Имя — любые символы (ники, эмодзи, символы), от 1 до 40, без управляющих знаков
    static func isValidName(_ name: String) -> Bool {
        (1...40).contains(name.count)
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && !name.allSatisfy(\.isWhitespace)
    }

    // Почта

    static func normalizeEmail(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isValidEmail(_ email: String) -> Bool {
        guard email.count <= 254, !email.contains(".."), !email.hasPrefix("."), !email.contains(" ") else {
            return false
        }
        let pattern = #"^[a-z0-9._%+\-]+@[a-z0-9\-]+(\.[a-z0-9\-]+)*\.[a-z]{2,}$"#
        return email.range(of: pattern, options: .regularExpression) != nil
    }

    // Пароль

    private static let commonPasswords: Set<String> = [
        "12345678", "123456789", "1234567890", "password", "password1", "qwerty123",
        "qwertyuiop", "11111111", "iloveyou1", "admin123", "orbit123", "orbita123", "12341234"
    ]

    static func isAcceptablePassword(_ password: String, phoneDigits: String) -> Bool {
        guard password.count >= 8,
              password.contains(where: \.isLetter),
              password.contains(where: \.isNumber),
              !commonPasswords.contains(password.lowercased()) else { return false }
        if phoneDigits.count >= 6, password.contains(phoneDigits) { return false }
        return true
    }

    /// 0...4
    static func passwordStrength(_ password: String) -> Int {
        var score = 0
        if password.count >= 8 { score += 1 }
        if password.count >= 12 { score += 1 }
        if password.contains(where: \.isUppercase) && password.contains(where: \.isLowercase) { score += 1 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) && password.contains(where: \.isNumber) { score += 1 }
        return score
    }
}
