import Foundation

/// «5 секунд назад», «минуту назад», «2 часа назад», «месяц назад», «год назад»
func agoText(_ date: Date, lang: AppLanguage, now: Date = Date()) -> String {
    let sec = max(0, Int(now.timeIntervalSince(date)))
    let units: [(Int, (Int) -> String, (Int) -> String)] = [
        (31_536_000, { ruWord($0, "год", "года", "лет") }, { $0 == 1 ? "year" : "years" }),
        (2_592_000, { ruWord($0, "месяц", "месяца", "месяцев") }, { $0 == 1 ? "month" : "months" }),
        (604_800, { ruWord($0, "неделю", "недели", "недель") }, { $0 == 1 ? "week" : "weeks" }),
        (86_400, { ruWord($0, "день", "дня", "дней") }, { $0 == 1 ? "day" : "days" }),
        (3_600, { ruWord($0, "час", "часа", "часов") }, { $0 == 1 ? "hour" : "hours" }),
        (60, { ruWord($0, "минуту", "минуты", "минут") }, { $0 == 1 ? "minute" : "minutes" }),
    ]
    for (size, ru, en) in units where sec >= size {
        let n = sec / size
        if lang == .ru { return (n == 1 ? ru(1) : "\(n) " + ru(n)) + " назад" }
        return (n == 1 ? "1 " : "\(n) ") + en(n) + " ago"
    }
    if lang == .ru { return "\(sec) " + ruWord(sec, "секунду", "секунды", "секунд") + " назад" }
    return "\(sec) " + (sec == 1 ? "second" : "seconds") + " ago"
}

private func ruWord(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let a = n % 100, b = n % 10
    if a >= 11 && a <= 14 { return many }
    if b == 1 { return one }
    if b >= 2 && b <= 4 { return few }
    return many
}
