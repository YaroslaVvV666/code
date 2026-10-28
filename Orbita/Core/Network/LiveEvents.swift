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
    /// Каждая пришедшая пачка тем: подмножество из "dm", "group", "call", "typing".
    let events = PassthroughSubject<Set<String>, Never>()

    init(api: ServerAPI) { self.api = api }

    /// Запускается один раз при входе и крутится, пока жив сеанс. Таймаут 15 с — меньше 20-секундного
    /// таймаута запроса, поэтому «вишение» всегда завершается штатным ответом, а не обрывом.
    func run() async {
        while !Task.isCancelled {
            do {
                let data = try await api.request("GET", "/v1/events/wait", query: ["timeout": "15"])
                let topics = (try? JSONDecoder().decode(LiveTopicsDTO.self, from: data).topics) ?? []
                if !topics.isEmpty { events.send(Set(topics)) }
            } catch {
                try? await Task.sleep(nanoseconds: 2_000_000_000)   // сеть недоступна — пауза и снова встаём на ожидание
            }
        }
    }

    /// Ждать первую пачку, пересекающуюся с `want`, либо истечения `timeout` секунд (страховка, если побудка не дошла).
    /// Экраны используют это вместо фиксированного короткого сна в цикле обновления.
    func waitForTopics(_ want: Set<String>, timeout: TimeInterval) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var done = false
            var bag: AnyCancellable?
            func finish() {
                if done { return }
                done = true
                bag?.cancel()
                cont.resume()
            }
            bag = events.sink { topics in if !topics.isDisjoint(with: want) { finish() } }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                finish()
            }
        }
    }
}
