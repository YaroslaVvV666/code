import Foundation

struct Country: Identifiable, Hashable {
    let flag: String
    let ru: String
    let en: String
    let code: String
    var id: String { en }
    var digits: String { String(code.dropFirst()) }
    func name(_ lang: AppLanguage) -> String { lang == .ru ? ru : en }
}

let countries: [Country] = [
    Country(flag: "🇷🇺", ru: "Россия", en: "Russia", code: "+7"),
    Country(flag: "🇰🇿", ru: "Казахстан", en: "Kazakhstan", code: "+7"),
    Country(flag: "🇺🇦", ru: "Украина", en: "Ukraine", code: "+380"),
    Country(flag: "🇧🇾", ru: "Беларусь", en: "Belarus", code: "+375"),
    Country(flag: "🇺🇸", ru: "США", en: "United States", code: "+1"),
    Country(flag: "🇨🇦", ru: "Канада", en: "Canada", code: "+1"),
    Country(flag: "🇬🇧", ru: "Великобритания", en: "United Kingdom", code: "+44"),
    Country(flag: "🇩🇪", ru: "Германия", en: "Germany", code: "+49"),
    Country(flag: "🇫🇷", ru: "Франция", en: "France", code: "+33"),
    Country(flag: "🇮🇹", ru: "Италия", en: "Italy", code: "+39"),
    Country(flag: "🇪🇸", ru: "Испания", en: "Spain", code: "+34"),
    Country(flag: "🇹🇷", ru: "Турция", en: "Türkiye", code: "+90"),
    Country(flag: "🇦🇿", ru: "Азербайджан", en: "Azerbaijan", code: "+994"),
    Country(flag: "🇦🇲", ru: "Армения", en: "Armenia", code: "+374"),
    Country(flag: "🇬🇪", ru: "Грузия", en: "Georgia", code: "+995"),
    Country(flag: "🇺🇿", ru: "Узбекистан", en: "Uzbekistan", code: "+998"),
    Country(flag: "🇦🇪", ru: "ОАЭ", en: "UAE", code: "+971"),
    Country(flag: "🇨🇳", ru: "Китай", en: "China", code: "+86"),
    Country(flag: "🇯🇵", ru: "Япония", en: "Japan", code: "+81"),
    Country(flag: "🇮🇳", ru: "Индия", en: "India", code: "+91")
]

/// Коды от длинных к коротким — для автоопределения страны по "+..."
let dialMatches: [Country] = countries.sorted { $0.digits.count > $1.digits.count }

/// "+79817990269" -> (Россия, "9817990269")
func splitE164(_ phone: String) -> (country: Country, digits: String)? {
    guard phone.hasPrefix("+") else { return nil }
    let rest = String(phone.dropFirst())
    guard let match = dialMatches.first(where: { rest.hasPrefix($0.digits) }) else { return nil }
    return (match, String(rest.dropFirst(match.digits.count)))
}
