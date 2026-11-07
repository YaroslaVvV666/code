import SwiftUI
import Combine
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

// MARK: - Перевод прямо в переписке (как в Telegram)
// «Перевести» в меню сообщения — текст в пузыре заменяется переводом, «Показать оригинал» возвращает.
// В каналах на чужом языке сверху плашка «Перевести на русский» / «Показать оригинал» и «…» с выбором языка,
// «Не переводить английский» и «Скрыть». Перевод делается на телефоне (Apple Translation), без сервера.

@MainActor
final class ChatTranslator: ObservableObject {
    static let shared = ChatTranslator()

    /// Чат, для которого всё это (при входе в другой чат — сбрасывается)
    private(set) var chatID = ""
    /// Перевести весь чат (плашка в канале)
    @Published var all = false
    /// Отдельные сообщения, переведённые из меню
    @Published var single: Set<String> = []
    /// Готовые переводы: id сообщения → текст
    @Published private(set) var results: [String: String] = [:]
    /// На какой язык переводим (по умолчанию — язык телефона)
    @Published var target: String = ChatTranslator.phoneLanguage
    /// Растёт, когда появились новые тексты — хост перевода берёт их в работу
    @Published private(set) var tick = 0
    private(set) var queue: [(id: String, text: String)] = []
    @Published var busy = false

    /// Языки, которые человек попросил не переводить
    @Published private(set) var never: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "translate.never") ?? [])
    /// Каналы, где плашку скрыли
    @Published private(set) var hiddenChats: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "translate.hidden") ?? [])

    static var phoneLanguage: String { Locale.preferredLanguages.first.map { String($0.prefix(2)).lowercased() } ?? "ru" }

    static var available: Bool {
        #if canImport(Translation)
        if #available(iOS 18.0, *) { return true }
        #endif
        return false
    }

    func open(chat: String) {
        guard chat != chatID else { return }
        chatID = chat
        all = false
        single = []
        results = [:]
        queue = []
    }

    func shows(_ id: String) -> Bool { (all || single.contains(id)) && results[id] != nil }
    func translation(_ id: String) -> String? { shows(id) ? results[id] : nil }

    /// Перевести одно сообщение / вернуть оригинал
    func toggle(_ message: ChatMessage) {
        if single.contains(message.id) || (all && results[message.id] != nil) {
            single.remove(message.id)
            if all { all = false }
            return
        }
        single.insert(message.id)
        request([(message.id, message.text)])
    }

    /// Плашка канала: перевести всё видимое
    func translateAll(_ messages: [ChatMessage]) {
        all = true
        request(messages.filter { !$0.text.isEmpty && !$0.mine }.map { ($0.id, $0.text) })
    }

    /// Новые сообщения в уже переведённом чате — тоже переводим
    func feed(_ messages: [ChatMessage]) {
        guard all else { return }
        request(messages.filter { !$0.text.isEmpty && !$0.mine }.map { ($0.id, $0.text) })
    }

    private func request(_ items: [(String, String)]) {
        let fresh = items.filter { results[$0.0] == nil && !queue.contains(where: { q in q.id == $0.0 }) }
        guard !fresh.isEmpty else { return }
        queue += fresh.map { (id: $0.0, text: $0.1) }
        tick += 1
    }

    func take(_ n: Int) -> [(id: String, text: String)] {
        let batch = Array(queue.prefix(n))
        queue.removeFirst(min(n, queue.count))
        return batch
    }

    func store(_ id: String, _ text: String) { results[id] = text }

    func setTarget(_ lang: String) {
        target = lang
        results = [:]
        let ids = single
        single = ids
        tick += 1
    }

    func neverTranslate(_ lang: String) {
        never.insert(lang)
        UserDefaults.standard.set(Array(never), forKey: "translate.never")
        all = false
    }

    func hideBar(_ chat: String) {
        hiddenChats.insert(chat)
        UserDefaults.standard.set(Array(hiddenChats), forKey: "translate.hidden")
        all = false
    }

    /// Основной язык текстов чата (если это не язык телефона) — для плашки «Перевести на русский»
    static func foreignLanguage(of messages: [ChatMessage]) -> String? {
        let sample = messages.suffix(20).filter { !$0.mine }.map(\.text).joined(separator: "\n")
        let letters = sample.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 40 else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(String(sample.prefix(2000)))
        guard let lang = r.dominantLanguage, lang != .undetermined else { return nil }
        let code = String(lang.rawValue.prefix(2)).lowercased()
        return code == phoneLanguage ? nil : code
    }

    static func languageName(_ code: String, in ui: AppLanguage) -> String {
        Locale(identifier: ui == .ru ? "ru_RU" : "en_US").localizedString(forLanguageCode: code) ?? code
    }

    static let choices = ["ru", "en", "uk", "de", "fr", "es", "it", "pt", "tr", "zh", "ja", "ko", "ar"]
}

/// Невидимый «двигатель» перевода: берёт очередь и переводит пачками на телефоне
struct ChatTranslatorHost: View {
    @ObservedObject var translator = ChatTranslator.shared

    var body: some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            Engine(translator: translator)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
        #else
        Color.clear.frame(width: 0, height: 0)
        #endif
    }

    #if canImport(Translation)
    @available(iOS 18.0, *)
    private struct Engine: View {
        @ObservedObject var translator: ChatTranslator
        @State private var config: TranslationSession.Configuration?

        var body: some View {
            Color.clear.frame(width: 0, height: 0)
                .translationTask(config) { session in
                    await MainActor.run { translator.busy = true }
                    while true {
                        let batch = await MainActor.run { translator.take(20) }
                        if batch.isEmpty { break }
                        let requests = batch.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
                        if let out = try? await session.translations(from: requests) {
                            await MainActor.run {
                                for r in out { if let id = r.clientIdentifier { translator.store(id, r.targetText) } }
                            }
                        }
                    }
                    await MainActor.run { translator.busy = false }
                }
                .onChange(of: translator.tick) { _, _ in run() }
                .onChange(of: translator.target) { _, _ in config = nil; run() }
        }

        private func run() {
            let target = Locale.Language(identifier: translator.target)
            if config == nil || config?.target != target {
                config = TranslationSession.Configuration(source: nil, target: target)
            } else {
                config?.invalidate()
            }
        }
    }
    #endif
}

/// Плашка в канале на чужом языке: «Перевести на русский» / «Показать оригинал» и «…»
struct ChannelTranslateBar: View {
    let chatID: String
    let language: String
    let messages: [ChatMessage]
    @ObservedObject private var translator = ChatTranslator.shared
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @State private var pickLanguage = false

    var body: some View {
        let s = Strings(lang: lang)
        let targetName = ChatTranslator.languageName(translator.target, in: lang)
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button {
                Haptics.select()
                if translator.all { translator.all = false } else { translator.translateAll(messages) }
            } label: {
                HStack(spacing: 10) {
                    if translator.busy && translator.all { ProgressView().scaleEffect(0.8) }
                    else { Image(systemName: "character.bubble").font(.system(size: 19, weight: .medium)) }
                    Text(translator.all ? s.t("Показать оригинал", "Show original")
                                        : s.t("Перевести на ", "Translate to ") + (lang == .ru ? targetName.inflectedTo : targetName))
                        .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(theme.text)
                .contentTransition(.opacity)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Menu {
                Button { pickLanguage = true } label: {
                    Label(s.t("Выбрать другой язык", "Choose another language"), systemImage: "character.bubble")
                }
                Button { translator.neverTranslate(language) } label: {
                    Label(s.t("Не переводить ", "Don't translate ") + (lang == .ru ? ChatTranslator.languageName(language, in: lang).lowercased()
                                                                                   : ChatTranslator.languageName(language, in: lang)),
                          systemImage: "hand.raised")
                }
                Button { translator.hideBar(chatID) } label: {
                    Label(s.t("Скрыть", "Hide"), systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.text)
                    .frame(width: 34, height: 34).overlay(Circle().stroke(theme.text.opacity(0.6), lineWidth: 1.5))
            }
        }
        .padding(.horizontal, 14).frame(height: 50)
        .animation(.easeOut(duration: 0.2), value: translator.all)
        .confirmationDialog(s.t("Переводить на", "Translate to"), isPresented: $pickLanguage, titleVisibility: .visible) {
            ForEach(ChatTranslator.choices, id: \.self) { code in
                Button(ChatTranslator.languageName(code, in: lang).capitalized) {
                    translator.setTarget(code)
                    translator.translateAll(messages)
                }
            }
            Button(s.cancel, role: .cancel) {}
        }
    }
}

private extension String {
    /// «русский» → «русский» (для «Перевести на русский»); имена языков в винительном совпадают с именительным
    var inflectedTo: String { self.lowercased() }
}
