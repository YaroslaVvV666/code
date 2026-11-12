import Foundation
import Combine

private struct LiveTopicsDTO: Decodable { let topics: [String] }

/// Один общий long-poll на весь сеанс. Держит «висящий» запрос к /v1/events/wait и, как только сервер сообщает,
/// что для пользователя что-то произошло (новое сообщение, звонок, набор), раздаёт темы всем экранам.
/// Заменяет постоянный частый опрос: экраны обновляются по событию, а не по таймеру.
///
/// Важно: long-poll ведёт ТОЛЬКО этот объект (один висящий запрос). Экраны подписываются на `events`
/// внутри приложения — так сервер не видит несколько конкурирующих ожиданий одного пользователя.
@MainActor
final class LiveEvents: ObservableObject {
    private let api: ServerAPI
    /// Каждая пришедшая пачка тем: подмножество из "dm", "group", "call", "typing". Для .onReceive в экранах.
    let events = PassthroughSubject<Set<String>, Never>()

    // Реестр ждущих waitForTopics: id -> (интересующие темы, как разбудить). Без Combine-подписки на каждого —
    // чтобы не плодить retain-cycle и утечки в частом цикле обновления.
    private var waiters: [Int: (want: Set<String>, resume: (Set<String>) -> Void)] = [:]
    private var nextWaiterID = 0

    init(api: ServerAPI) { self.api = api }

    /// Запускается один раз при входе и крутится, пока жив сеанс. Таймаут 15 с — меньше 20-секундного
    /// таймаута запроса, поэтому «вишение» всегда завершается штатным ответом, а не обрывом.
    func run() async {
        while !Task.isCancelled {
            do {
                let data = try await api.request("GET", "/v1/events/wait", query: ["timeout": "15"])
                let topics = Set((try? JSONDecoder().decode(LiveTopicsDTO.self, from: data).topics) ?? [])
                if !topics.isEmpty { deliver(topics) }
            } catch {
                try? await Task.sleep(nanoseconds: 2_000_000_000)   // сеть недоступна — пауза и снова встаём на ожидание
            }
        }
    }

    private func deliver(_ topics: Set<String>) {
        events.send(topics)                          // экранам на .onReceive
        for (id, w) in waiters where !topics.isDisjoint(with: w.want) {
            waiters[id] = nil
            w.resume(topics.intersection(w.want))
        }
    }

    /// Ждать первую пачку, пересекающуюся с `want`, либо истечения `timeout` секунд (страховка, если побудка не дошла).
    /// Экраны используют это вместо фиксированного короткого сна в цикле обновления.
    /// Возвращает темы, которые пришли (пусто — разбудил таймаут): экран может обновить только нужное
    @discardableResult
    func waitForTopics(_ want: Set<String>, timeout: TimeInterval) async -> Set<String> {
        let id = nextWaiterID
        nextWaiterID += 1
        return await withCheckedContinuation { (cont: CheckedContinuation<Set<String>, Never>) in
            waiters[id] = (want, { cont.resume(returning: $0) })
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                if let w = waiters[id] {             // ещё не разбудили событием — будим по таймауту
                    waiters[id] = nil
                    w.resume([])
                }
            }
        }
    }
}
