import SwiftUI
import Combine
import UIKit
import ContactsUI

// MARK: - Кодек: текст + сущности <-> NSAttributedString

enum RichTextCodec {
    static let quoteKey = NSAttributedString.Key("orbita.quote")
    static let highlightKey = NSAttributedString.Key("orbita.highlight")
    static let markerColor = UIColor(red: 1.0, green: 0.84, blue: 0.2, alpha: 0.5)

    static func baseFont(_ size: CGFloat) -> UIFont { UIFont.systemFont(ofSize: size) }

    /// Из текста и сущностей — в атрибутированную строку для показа
    static func attributed(text: String, entities: [TextEntity], size: CGFloat,
                           color: UIColor, linkColor: UIColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: baseFont(size), .foregroundColor: color, .paragraphStyle: paragraph
        ])
        let length = (text as NSString).length

        for e in entities {
            guard e.offset >= 0, e.length > 0, e.offset + e.length <= length else { continue }
            let range = NSRange(location: e.offset, length: e.length)
            switch e.type {
            case "bold":
                addTrait(.traitBold, to: result, range: range, size: size)
            case "italic":
                addTrait(.traitItalic, to: result, range: range, size: size)
            case "underline":
                result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case "strike":
                result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case "highlight":
                result.addAttributes([highlightKey: true, .backgroundColor: markerColor], range: range)
            case "mono":
                result.enumerateAttribute(.font, in: range) { value, r, _ in
                    let font = (value as? UIFont) ?? baseFont(size)
                    let bold = font.fontDescriptor.symbolicTraits.contains(.traitBold)
                    result.addAttributes([
                        .font: UIFont.monospacedSystemFont(ofSize: size * 0.94, weight: bold ? .bold : .regular),
                        .backgroundColor: color.withAlphaComponent(0.12)
                    ], range: r)
                }
            case "link":
                if let raw = e.url, let url = URL(string: raw) {
                    result.addAttributes([.link: url, .foregroundColor: linkColor,
                                          .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
                }
            default:
                break
            }
        }

        // ссылки, набранные вручную без форматирования
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: NSRange(location: 0, length: length)) {
                guard let url = match.url, result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
                result.addAttributes([.link: url, .foregroundColor: linkColor,
                                      .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
            }
        }

        // ссылки приложения orbita://… (NSDataDetector их не знает)
        if let regex = try? NSRegularExpression(pattern: "orbita://[^\\s]+") {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: length)) {
                guard let url = URL(string: (text as NSString).substring(with: match.range)),
                      result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
                result.addAttributes([.link: url, .foregroundColor: linkColor,
                                      .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
            }
        }
        // номера телефонов: +7981…, 8981…, 8 981 799 02 69, 8-981-799-02-69
        if let regex = try? NSRegularExpression(pattern: "(?<![\\w+])\\+?\\d(?:[\\s\\-().]?\\d){8,14}(?![\\w])") {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: length)) {
                let raw = (text as NSString).substring(with: match.range)
                let digits = raw.filter(\.isNumber)
                let plus = raw.hasPrefix("+")
                let ok = plus ? (10...15).contains(digits.count)
                              : (digits.count == 11 && (digits.hasPrefix("7") || digits.hasPrefix("8"))) || (digits.count == 10 && digits.hasPrefix("9"))
                guard ok, result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil,
                      let url = URL(string: "orbita://phone/" + (plus ? "%2B" : "") + digits) else { continue }
                result.addAttributes([.link: url, .foregroundColor: linkColor,
                                      .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
            }
        }
        // @username: нажатие открывает профиль (как в Telegram)
        if let regex = try? NSRegularExpression(pattern: "(?<![\\w@/])@([A-Za-z][A-Za-z0-9_]{4,31})") {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: length)) {
                guard match.numberOfRanges > 1,
                      result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil,
                      let url = URL(string: "orbita://u/" + (text as NSString).substring(with: match.range(at: 1))) else { continue }
                result.addAttributes([.link: url, .foregroundColor: linkColor], range: match.range)
            }
        }
        return result
    }

    private static func addTrait(_ trait: UIFontDescriptor.SymbolicTraits, to string: NSMutableAttributedString,
                                 range: NSRange, size: CGFloat) {
        string.enumerateAttribute(.font, in: range) { value, r, _ in
            let font = (value as? UIFont) ?? baseFont(size)
            let traits = font.fontDescriptor.symbolicTraits.union(trait)
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                string.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: r)
            }
        }
    }

    /// Из текста, набранного в редакторе, — обратно в сущности
    static func entities(from text: NSAttributedString) -> [TextEntity] {
        var result: [TextEntity] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length), options: []) { attrs, range, _ in
            for (type, url) in activeTypes(attrs) {
                if let i = result.lastIndex(where: { $0.type == type && $0.url == url && $0.offset + $0.length == range.location }) {
                    result[i].length += range.length
                } else {
                    result.append(TextEntity(type: type, offset: range.location, length: range.length, url: url))
                }
            }
        }
        return result
    }

    private static func activeTypes(_ attrs: [NSAttributedString.Key: Any]) -> [(String, String?)] {
        var out: [(String, String?)] = []
        if let font = attrs[.font] as? UIFont {
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.traitBold) { out.append(("bold", nil)) }
            if traits.contains(.traitItalic) { out.append(("italic", nil)) }
            if traits.contains(.traitMonoSpace) { out.append(("mono", nil)) }
        }
        let link = attrs[.link]
        if let link {
            if let url = link as? URL { out.append(("link", url.absoluteString)) }
            else if let string = link as? String { out.append(("link", string)) }
        } else if let underline = attrs[.underlineStyle] as? Int, underline != 0 {
            out.append(("underline", nil))
        }
        if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 { out.append(("strike", nil)) }
        if attrs[quoteKey] != nil { out.append(("quote", nil)) }
        if attrs[highlightKey] != nil { out.append(("highlight", nil)) }
        return out
    }

    // MARK: Блоки (цитаты показываются отдельными блоками)

    struct Segment {
        let text: String
        let entities: [TextEntity]
        let isQuote: Bool
    }

    static func segments(text: String, entities: [TextEntity]) -> [Segment] {
        let ns = text as NSString
        let length = ns.length
        let quotes = entities
            .filter { $0.type == "quote" && $0.offset >= 0 && $0.length > 0 && $0.offset + $0.length <= length }
            .sorted { $0.offset < $1.offset }

        var ranges: [(range: NSRange, isQuote: Bool)] = []
        var cursor = 0
        for quote in quotes where quote.offset >= cursor {
            if quote.offset > cursor {
                ranges.append((NSRange(location: cursor, length: quote.offset - cursor), false))
            }
            ranges.append((NSRange(location: quote.offset, length: quote.length), true))
            cursor = quote.offset + quote.length
        }
        if cursor < length { ranges.append((NSRange(location: cursor, length: length - cursor), false)) }
        if ranges.isEmpty { ranges = [(NSRange(location: 0, length: length), false)] }

        let inline = entities.filter { $0.type != "quote" }
        var segments: [Segment] = []
        for item in ranges {
            var r = item.range
            while r.length > 0, ns.character(at: r.location + r.length - 1) == 10 { r.length -= 1 }
            guard r.length > 0 else { continue }

            var local: [TextEntity] = []
            for e in inline {
                let lo = max(e.offset, r.location)
                let hi = min(e.offset + e.length, r.location + r.length)
                if hi > lo { local.append(TextEntity(type: e.type, offset: lo - r.location, length: hi - lo, url: e.url)) }
            }
            segments.append(Segment(text: ns.substring(with: r), entities: local, isQuote: item.isQuote))
        }
        return segments
    }
}

// MARK: - Показ форматированного текста

struct RichLabel: UIViewRepresentable {
    let attributed: NSAttributedString
    let linkColor: UIColor

    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Нажатие на ссылку идёт через openURL окружения: ссылки Orbita открываются внутри приложения
    final class Coordinator: NSObject, UITextViewDelegate {
        var open: (URL) -> Void = { _ in }
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            guard interaction == .invokeDefaultAction else { return true }
            open(URL)
            return false
        }
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.open = { url in openURL(url) }
        tv.linkTextAttributes = [.foregroundColor: linkColor,
                                 .underlineStyle: NSUnderlineStyle.single.rawValue]
        if !tv.attributedText.isEqual(to: attributed) { tv.attributedText = attributed }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width.map { $0.isFinite ? $0 : 320 } ?? 320
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }
}

struct FormattedText: View {
    let text: String
    let entities: [TextEntity]
    var size: CGFloat = 16
    var color: Color? = nil          // свой цвет текста (например, белый в исходящих сообщениях)

    @Environment(\.theme) private var theme

    var body: some View {
        let textColor = UIColor(color ?? theme.text)
        let linkTint = color == nil ? UIColor(theme.accentColor) : UIColor(color ?? theme.text)
        let segments = RichTextCodec.segments(text: text, entities: entities)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { item in
                let segment = item.element
                let label = RichLabel(
                    attributed: RichTextCodec.attributed(text: segment.text, entities: segment.entities, size: size,
                                                         color: textColor, linkColor: linkTint),
                    linkColor: linkTint)
                if segment.isQuote {
                    label
                        .padding(.leading, 16)
                        .padding(.trailing, 10)
                        .padding(.vertical, 8)
                        .background(theme.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .leading) {
                            Capsule().fill(theme.accentColor).frame(width: 3).padding(.vertical, 5).padding(.leading, 5)
                        }
                } else {
                    label
                }
            }
        }
    }
}

/// Лёгкий показ форматированного текста средствами SwiftUI (для пузырей в чате: без UITextView на каждое сообщение)
struct RichInlineText: View {
    let text: String
    let entities: [TextEntity]
    var size: CGFloat = 16
    var color: Color
    var linkColor: Color
    var filler = ""                        // невидимые пробелы под время сообщения
    /// Выделять номера телефонов, карт, криптоадреса, @юзернеймы и ссылки (нажатие — карточка с подробностями)
    var detect = false

    var body: some View {
        let segments = RichTextCodec.segments(text: text, entities: entities)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { item in
                let segment = item.element
                let isLast = item.offset == segments.count - 1
                let base = RichTextCodec.attributed(text: segment.text + (isLast ? filler : ""), entities: segment.entities,
                                                    size: size, color: UIColor(color), linkColor: UIColor(linkColor))
                let ns = detect ? ChatEntityDetector.annotate(base) : base
                let attributed = (try? AttributedString(ns, including: \.uiKit)) ?? AttributedString(segment.text)
                let label = Text(attributed).tint(linkColor).fixedSize(horizontal: false, vertical: true)
                if segment.isQuote {
                    label
                        .padding(.leading, 12)
                        .padding(.vertical, 4)
                        .overlay(alignment: .leading) { Capsule().fill(linkColor).frame(width: 3) }
                } else {
                    label
                }
            }
        }
    }
}

// MARK: - Редактор с форматированием (панель как в Telegram)

final class RichComposerController: ObservableObject {
    fileprivate weak var textView: UITextView?
    @Published private(set) var activeTypes: Set<String> = []
    @Published private(set) var length = 0
    /// Набирается @упоминание: текст после «@» (пустая строка — только что поставили @)
    @Published private(set) var mention: String?
    let maxLength = 2000
    private var linkColor: UIColor = .systemBlue

    var plainText: String { textView?.text ?? "" }
    var entities: [TextEntity] { textView.map { RichTextCodec.entities(from: $0.attributedText) } ?? [] }
    var isBlank: Bool { plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var pendingLoad: (text: String, entities: [TextEntity], color: UIColor)?

    func attach(_ tv: UITextView, tint: UIColor) {
        textView = tv
        linkColor = tint
        if let pending = pendingLoad {
            pendingLoad = nil
            load(text: pending.text, entities: pending.entities, color: pending.color)
        }
    }

    /// Загружает существующий текст с форматированием (правка публикации)
    func load(text: String, entities: [TextEntity], color: UIColor) {
        guard let tv = textView else {
            pendingLoad = (text, entities, color)       // поле ещё не создано — применим при создании
            return
        }
        tv.attributedText = RichTextCodec.attributed(text: text, entities: entities, size: 17,
                                                     color: color, linkColor: linkColor)
        tv.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        refresh()
    }

    // Жирный, курсив, подчёркнутый, зачёркнутый, моно
    func toggle(_ type: String) {
        guard let tv = textView else { return }
        if type == "quote" { toggleQuote(tv); return }
        if type == "link" { removeLink(tv); return }

        let range = tv.selectedRange
        if range.length == 0 {
            var attrs = tv.typingAttributes
            Self.mutate(&attrs, type: type, on: !Self.has(type, in: attrs))
            tv.typingAttributes = attrs
        } else {
            let storage = tv.textStorage
            var runs: [(range: NSRange, attrs: [NSAttributedString.Key: Any])] = []
            storage.enumerateAttributes(in: range, options: []) { attrs, r, _ in runs.append((r, attrs)) }
            let on = !runs.allSatisfy { Self.has(type, in: $0.attrs) }
            storage.beginEditing()
            for run in runs {
                var attrs = run.attrs
                Self.mutate(&attrs, type: type, on: on)
                storage.setAttributes(attrs, range: run.range)
            }
            storage.endEditing()
            tv.selectedRange = range
        }
        refresh()
    }

    private func removeLink(_ tv: UITextView) {
        let range = tv.selectedRange
        guard range.length > 0 else { return }
        tv.textStorage.removeAttribute(.link, range: range)
        tv.textStorage.removeAttribute(.underlineStyle, range: range)
        refresh()
    }

    /// Сбросить всё форматирование выделения
    func clearFormatting() {
        guard let tv = textView else { return }
        let range = tv.selectedRange
        guard range.length > 0 else { return }
        let storage = tv.textStorage
        let color = tv.textColor ?? .label
        storage.beginEditing()
        storage.setAttributes([.font: RichTextCodec.baseFont(17), .foregroundColor: color], range: range)
        storage.endEditing()
        tv.selectedRange = range
        refresh()
    }

    /// Вызывается, когда из меню выбрана «Ссылка»
    var onLinkRequest: (() -> Void)?

    /// Цитата — на весь абзац (или абзацы) выделения
    private func toggleQuote(_ tv: UITextView) {
        let ns = tv.text as NSString
        let paragraph = ns.paragraphRange(for: tv.selectedRange)
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 14
        style.headIndent = 14
        let tint = UIColor.systemGray.withAlphaComponent(0.18)

        if paragraph.length == 0 {
            var attrs = tv.typingAttributes
            if attrs[RichTextCodec.quoteKey] != nil {
                attrs[RichTextCodec.quoteKey] = nil
                attrs[.paragraphStyle] = nil
                attrs[.backgroundColor] = nil
            } else {
                attrs[RichTextCodec.quoteKey] = true
                attrs[.paragraphStyle] = style
                attrs[.backgroundColor] = tint
            }
            tv.typingAttributes = attrs
        } else {
            let storage = tv.textStorage
            let has = storage.attribute(RichTextCodec.quoteKey, at: paragraph.location, effectiveRange: nil) != nil
            storage.beginEditing()
            if has {
                storage.removeAttribute(RichTextCodec.quoteKey, range: paragraph)
                storage.removeAttribute(.paragraphStyle, range: paragraph)
                storage.removeAttribute(.backgroundColor, range: paragraph)
            } else {
                storage.addAttributes([RichTextCodec.quoteKey: true, .paragraphStyle: style, .backgroundColor: tint],
                                      range: paragraph)
            }
            storage.endEditing()
        }
        refresh()
    }

    /// Ссылка: на выделенный текст или вставкой самого адреса
    @discardableResult
    func applyLink(_ raw: String) -> Bool {
        guard let tv = textView else { return false }
        var string = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = string.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") { string = "https://" + string }
        guard let url = URL(string: string), url.host != nil else { return false }

        let range = tv.selectedRange
        if range.length > 0 {
            tv.textStorage.addAttributes([.link: url, .foregroundColor: linkColor], range: range)
        } else {
            var attrs = tv.typingAttributes
            attrs[.link] = url
            attrs[.foregroundColor] = linkColor
            let inserted = NSAttributedString(string: string, attributes: attrs)
            tv.textStorage.insert(inserted, at: range.location)
            tv.selectedRange = NSRange(location: range.location + inserted.length, length: 0)
        }
        refresh()
        return true
    }

    // MARK: Для строки ввода в чате

    /// Нажатие в поле (чтобы вернуть клавиатуру вместо панели эмодзи)
    var onFieldTap: (() -> Void)?
    private var panelHost: UIHostingController<AnyView>?

    var hasContent: Bool { !isBlank }

    /// Текст и сущности без пробелов по краям (смещения подправлены)
    func snapshot() -> (text: String, entities: [TextEntity]) {
        guard let tv = textView else { return ("", []) }
        let ns = tv.text as NSString
        var start = 0
        var end = ns.length
        let ws = CharacterSet.whitespacesAndNewlines
        while start < end, let scalar = Unicode.Scalar(ns.character(at: start)), ws.contains(scalar) { start += 1 }
        while end > start, let scalar = Unicode.Scalar(ns.character(at: end - 1)), ws.contains(scalar) { end -= 1 }
        let text = ns.substring(with: NSRange(location: start, length: end - start))
        var out: [TextEntity] = []
        for e in RichTextCodec.entities(from: tv.attributedText) {
            let lo = max(e.offset, start), hi = min(e.offset + e.length, end)
            if hi > lo { out.append(TextEntity(type: e.type, offset: lo - start, length: hi - lo, url: e.url)) }
        }
        return (text, out)
    }

    func clear() {
        guard let tv = textView else { return }
        tv.attributedText = NSAttributedString()
        tv.typingAttributes = [.font: RichTextCodec.baseFont(17), .foregroundColor: tv.textColor ?? UIColor.label]
        refresh()
    }

    func insert(_ string: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange
        let inserted = NSAttributedString(string: string, attributes: tv.typingAttributes)
        tv.textStorage.replaceCharacters(in: range, with: inserted)
        tv.selectedRange = NSRange(location: range.location + inserted.length, length: 0)
        refresh()
    }

    func backspace() {
        textView?.deleteBackward()
        refresh()
    }

    func resetInputPanel() { setInputPanel(Optional<EmptyView>.none) }

    func focus() { textView?.becomeFirstResponder() }
    func unfocus() { textView?.resignFirstResponder() }
    var isFocused: Bool { textView?.isFirstResponder ?? false }

    /// Показывает свою панель вместо клавиатуры (эмодзи/стикеры); nil — обычная клавиатура
    func setInputPanel<Content: View>(_ content: Content?, height: CGFloat = 300) {
        guard let tv = textView else { return }
        if let content {
            let host = UIHostingController(rootView: AnyView(content))
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            let container = UIInputView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: height),
                                        inputViewStyle: .keyboard)
            container.allowsSelfSizing = true
            container.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: container.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                host.view.heightAnchor.constraint(equalToConstant: height)
            ])
            panelHost = host
            tv.inputView = container
        } else {
            panelHost = nil
            tv.inputView = nil
        }
        tv.reloadInputViews()
        if !tv.isFirstResponder { tv.becomeFirstResponder() }
    }

    func refresh() {
        guard let tv = textView else { return }
        var types = Set<String>()
        let all = ["bold", "italic", "underline", "strike", "mono", "quote", "highlight", "link"]
        let range = tv.selectedRange
        if range.length == 0 {
            let attrs = tv.typingAttributes
            for type in all where Self.has(type, in: attrs) { types.insert(type) }
        } else {
            var runs: [[NSAttributedString.Key: Any]] = []
            tv.textStorage.enumerateAttributes(in: range, options: []) { attrs, _, _ in runs.append(attrs) }
            for type in all where !runs.isEmpty && runs.allSatisfy({ Self.has(type, in: $0) }) { types.insert(type) }
        }
        let count = (tv.text as NSString).length
        let query = Self.mentionQuery(in: tv)
        DispatchQueue.main.async { [weak self] in
            self?.activeTypes = types
            self?.length = count
            if self?.mention != query { self?.mention = query }
        }
    }

    /// Слово перед курсором, начинающееся с «@» (nil, если курсор не на упоминании)
    fileprivate static func mentionQuery(in tv: UITextView) -> String? {
        let ns = tv.text as NSString
        let caret = tv.selectedRange.location
        guard tv.selectedRange.length == 0, caret <= ns.length else { return nil }
        var i = caret
        while i > 0 {
            let ch = ns.character(at: i - 1)
            guard let scalar = Unicode.Scalar(ch) else { return nil }
            if scalar == "@" {
                if i - 1 > 0, let prev = Unicode.Scalar(ns.character(at: i - 2)),
                   CharacterSet.alphanumerics.contains(prev) || prev == "_" { return nil }
                return ns.substring(with: NSRange(location: i, length: caret - i))
            }
            guard CharacterSet.alphanumerics.contains(scalar) || scalar == "_" else { return nil }
            i -= 1
        }
        return nil
    }

    /// Подставляет выбранный @username вместо набранного начала
    func completeMention(_ username: String) {
        guard let tv = textView, let query = Self.mentionQuery(in: tv) else { return }
        let caret = tv.selectedRange.location
        let start = caret - (query as NSString).length - 1
        let range = NSRange(location: start, length: caret - start)
        var attrs = tv.typingAttributes
        attrs[.link] = nil
        let inserted = NSAttributedString(string: "@" + username + " ", attributes: attrs)
        tv.textStorage.replaceCharacters(in: range, with: inserted)
        tv.selectedRange = NSRange(location: start + inserted.length, length: 0)
        refresh()
    }

    // MARK: Атрибуты

    fileprivate static func has(_ type: String, in attrs: [NSAttributedString.Key: Any]) -> Bool {
        let traits = (attrs[.font] as? UIFont)?.fontDescriptor.symbolicTraits
        switch type {
        case "bold":      return traits?.contains(.traitBold) ?? false
        case "italic":    return traits?.contains(.traitItalic) ?? false
        case "mono":      return traits?.contains(.traitMonoSpace) ?? false
        case "underline": return ((attrs[.underlineStyle] as? Int) ?? 0) != 0
        case "strike":    return ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
        case "quote":     return attrs[RichTextCodec.quoteKey] != nil
        case "highlight": return attrs[RichTextCodec.highlightKey] != nil
        case "link":      return attrs[.link] != nil
        default:          return false
        }
    }

    fileprivate static func mutate(_ attrs: inout [NSAttributedString.Key: Any], type: String, on: Bool) {
        let font = (attrs[.font] as? UIFont) ?? RichTextCodec.baseFont(17)
        switch type {
        case "bold", "italic":
            let trait: UIFontDescriptor.SymbolicTraits = type == "bold" ? .traitBold : .traitItalic
            var traits = font.fontDescriptor.symbolicTraits
            if on { traits.insert(trait) } else { traits.remove(trait) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                attrs[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
            } else {
                attrs[.font] = RichTextCodec.baseFont(font.pointSize)
            }
        case "mono":
            if on {
                let bold = font.fontDescriptor.symbolicTraits.contains(.traitBold)
                attrs[.font] = UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.94, weight: bold ? .bold : .regular)
                attrs[.backgroundColor] = UIColor.systemGray.withAlphaComponent(0.2)
            } else {
                attrs[.font] = RichTextCodec.baseFont(font.pointSize / 0.94)
                attrs[.backgroundColor] = attrs[RichTextCodec.highlightKey] != nil ? RichTextCodec.markerColor : nil
            }
        case "highlight":
            attrs[RichTextCodec.highlightKey] = on ? true : nil
            attrs[.backgroundColor] = on ? RichTextCodec.markerColor : nil
        case "underline":
            attrs[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : 0
        case "strike":
            attrs[.strikethroughStyle] = on ? NSUnderlineStyle.single.rawValue : 0
        default:
            break
        }
    }
}

struct FormattingTextView: UIViewRepresentable {
    let controller: RichComposerController
    let textColor: UIColor
    let tint: UIColor
    var maxHeight: CGFloat? = nil            // задано — поле растёт вместе с текстом (строка ввода в чате)

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.font = RichTextCodec.baseFont(17)
        tv.textColor = textColor
        tv.tintColor = tint
        tv.linkTextAttributes = [.foregroundColor: tint]
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.allowsEditingTextAttributes = false      // системное меню B/I/U заменено своей панелью
        tv.alwaysBounceVertical = true
        controller.attach(tv, tint: tint)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        tv.addGestureRecognizer(tap)
        return tv
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let maxHeight else { return nil }
        let width = proposal.width ?? 280
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(fitted, 36), maxHeight)
        uiView.isScrollEnabled = fitted > maxHeight
        return CGSize(width: width, height: height)
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        tv.tintColor = tint
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        let controller: RichComposerController
        init(_ controller: RichComposerController) { self.controller = controller }

        @objc func tapped() { controller.onFieldTap?() }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            let current = (tv.text ?? "") as NSString
            let newLength = current.length - range.length + (text as NSString).length
            return newLength <= controller.maxLength
        }

        // Как в Telegram: выделил текст — в меню появляется «Формат» со стилями
        func textView(_ tv: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return UIMenu(children: suggestedActions) }
            let c = controller
            func item(_ title: String, _ icon: String, _ type: String) -> UIAction {
                UIAction(title: title, image: UIImage(systemName: icon),
                         state: c.activeTypes.contains(type) ? .on : .off) { _ in c.toggle(type) }
            }
            let styles = UIMenu(title: "Формат", image: UIImage(systemName: "textformat"), children: [
                item("Жирный", "bold", "bold"),
                item("Курсив", "italic", "italic"),
                item("Подчёркнутый", "underline", "underline"),
                item("Зачёркнутый", "strikethrough", "strike"),
                item("Маркер", "highlighter", "highlight"),
                item("Цитата", "text.quote", "quote"),
                item("Моноширинный", "chevron.left.forwardslash.chevron.right", "mono"),
                UIAction(title: "Ссылка", image: UIImage(systemName: "link")) { _ in c.onLinkRequest?() },
                UIAction(title: "Обычный", image: UIImage(systemName: "textformat.size"),
                         attributes: .destructive) { _ in c.clearFormatting() }
            ])
            return UIMenu(children: [styles] + suggestedActions)
        }

        func textViewDidChange(_ tv: UITextView) { controller.refresh() }
        func textViewDidChangeSelection(_ tv: UITextView) { controller.refresh() }
    }
}


// MARK: - Номер телефона в сообщении: добавить контакт, позвонить, скопировать, перейти в профиль

struct PhoneLookupSheet: View {
    let phone: String
    @EnvironmentObject private var session: AppSession
    @Environment(\.lang) private var lang
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var found: UserProfile?
    @State private var loaded = false
    @State private var addContact = false
    @State private var showProfile = false
    @State private var copied = false

    private var s: Strings { Strings(lang: lang) }
    private var display: String { phone }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(display)
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.text)
                .padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 14)
            VStack(spacing: 0) {
                row("person.crop.circle.badge.plus", s.t("Добавить контакт", "Add contact")) { addContact = true }
                divider
                row("phone", s.t("Позвонить по телефону", "Call")) {
                    if let url = URL(string: "tel:" + phone.replacingOccurrences(of: "+", with: "%2B")) { UIApplication.shared.open(url) }
                }
                row("doc.on.doc", copied ? s.t("Скопировано", "Copied") : s.t("Скопировать номер", "Copy number")) {
                    UIPasteboard.general.string = phone
                    copied = true
                    Haptics.notify(.success)
                }
                if let p = found {
                    divider
                    Button { showProfile = true } label: {
                        HStack(spacing: 14) {
                            AvatarView(name: p.name, size: 38, avatarID: p.avatarID)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.contactName ?? p.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                                Text(s.t("Перейти в профиль", "Go to profile")).font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textSecondary)
                        }
                        .padding(.horizontal, 22).padding(.vertical, 12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 14)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.sheet.ignoresSafeArea())
        .presentationDetents([.height(found == nil ? 280 : 360)])
        .presentationDragIndicator(.visible)
        .task {
            found = try? await session.profileRepo.lookup(phone: phone)
            loaded = true
        }
        .sheet(isPresented: $addContact) { NewContactView(phone: phone).ignoresSafeArea() }
        .fullScreenCover(isPresented: $showProfile) {
            if let p = found { PublicProfileSheet(source: .id(p.id)) }
        }
    }

    private var divider: some View { Rectangle().fill(theme.textSecondary.opacity(0.15)).frame(height: 0.5).padding(.leading, 22) }

    private func row(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.system(size: 20)).frame(width: 30).foregroundStyle(theme.text)
                Text(title).font(.system(size: 18)).foregroundStyle(theme.text)
                Spacer()
            }
            .padding(.horizontal, 22).padding(.vertical, 13).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Системный экран «Новый контакт» с уже подставленным номером (разрешение на контакты не нужно)
struct NewContactView: UIViewControllerRepresentable {
    let phone: String
    func makeUIViewController(context: Context) -> UINavigationController {
        let contact = CNMutableContact()
        contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))]
        let vc = CNContactViewController(forNewContact: contact)
        vc.delegate = context.coordinator
        return UINavigationController(rootViewController: vc)
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
    func makeCoordinator() -> Coord { Coord() }
    final class Coord: NSObject, CNContactViewControllerDelegate {
        func contactViewController(_ vc: CNContactViewController, didCompleteWith contact: CNContact?) {
            vc.presentingViewController?.dismiss(animated: true) ?? vc.navigationController?.presentingViewController?.dismiss(animated: true)
        }
    }
}

// MARK: - Номера, карты, криптоадреса, @юзернеймы и ссылки в тексте сообщения

/// Что нашли в тексте сообщения. Выделяется ссылкой со своей схемой — нажатие открывает карточку, а не меню сообщения
struct ChatEntity: Identifiable, Equatable {
    enum Kind: String { case phone, card, crypto, username }
    let kind: Kind
    let value: String               // телефон и карта — только цифры; адрес и юзернейм — как есть
    var id: String { kind.rawValue + ":" + value }

    static let scheme = "orbita-entity"

    var url: URL? {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = kind.rawValue
        c.path = "/" + value
        return c.url
    }

    init(kind: Kind, value: String) { self.kind = kind; self.value = value }

    init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host, let kind = Kind(rawValue: host) else { return nil }
        let value = String(url.path.dropFirst())
        guard !value.isEmpty else { return nil }
        self.kind = kind
        self.value = value
    }
}

enum ChatEntityDetector {
    private static let card = try? NSRegularExpression(pattern: "(?<![0-9])(?:[0-9][ -]?){15,18}[0-9](?![0-9])")
    private static let username = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_@])@([A-Za-z][A-Za-z0-9_]{4,31})")
    private static let crypto = try? NSRegularExpression(pattern:
        "(?<![A-Za-z0-9])(0x[a-fA-F0-9]{40}|bc1[ac-hj-np-z02-9]{11,71}|[13][a-km-zA-HJ-NP-Z1-9]{25,34}|T[1-9A-HJ-NP-Za-km-z]{33}|(?:EQ|UQ)[A-Za-z0-9_-]{46})(?![A-Za-z0-9])")
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue
                                                       | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    /// Карта — 16–19 цифр, проходящих проверку Луна (так отличаем её от длинных чисел и телефонов)
    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    static func annotate(_ source: NSAttributedString) -> NSAttributedString {
        let text = source.string
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return source }
        let out = NSMutableAttributedString(attributedString: source)
        var taken: [NSRange] = []
        out.enumerateAttribute(.link, in: full) { value, r, _ in if value != nil { taken.append(r) } }      // ссылки из форматирования
        func free(_ r: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, r).length > 0 } }
        func mark(_ r: NSRange, _ url: URL?) {
            guard let url, free(r) else { return }
            taken.append(r)
            out.addAttributes([.link: url, .underlineStyle: NSUnderlineStyle.single.rawValue], range: r)
        }

        // сначала то, что NSDataDetector принял бы за телефон: карты и криптоадреса
        for m in card?.matches(in: text, range: full) ?? [] {
            let digits = ns.substring(with: m.range).filter(\.isNumber)
            if (16...19).contains(digits.count), luhn(digits) { mark(m.range, ChatEntity(kind: .card, value: digits).url) }
        }
        for m in crypto?.matches(in: text, range: full) ?? [] {
            mark(m.range, ChatEntity(kind: .crypto, value: ns.substring(with: m.range)).url)
        }
        for m in username?.matches(in: text, range: full) ?? [] where m.numberOfRanges > 1 {
            mark(m.range, ChatEntity(kind: .username, value: ns.substring(with: m.range(at: 1))).url)
        }
        for m in detector?.matches(in: text, range: full) ?? [] {
            if m.resultType == .phoneNumber, let phone = m.phoneNumber {
                let digits = phone.filter(\.isNumber)
                if digits.count >= 10 { mark(m.range, ChatEntity(kind: .phone, value: digits).url) }
            } else if m.resultType == .link, let url = m.url, url.scheme?.hasPrefix("http") == true {
                mark(m.range, url)                                  // обычная ссылка: нажатие — открыть
            }
        }
        return out
    }
}

/// Подробности о найденном: страна номера, платёжная система и банк карты, сеть криптоадреса
enum ChatEntityInfo {
    /// Цифры номера в международном виде (8XXXXXXXXXX → 7XXXXXXXXXX)
    static func international(_ digits: String) -> String {
        if digits.count == 11 && digits.hasPrefix("8") { return "7" + digits.dropFirst() }
        if digits.count == 10 && digits.hasPrefix("9") { return "7" + digits }
        return digits
    }

    private static let countries: [(String, String, String)] = [
        ("375", "Беларусь", "Belarus"), ("380", "Украина", "Ukraine"), ("998", "Узбекистан", "Uzbekistan"),
        ("996", "Киргизия", "Kyrgyzstan"), ("992", "Таджикистан", "Tajikistan"), ("993", "Туркменистан", "Turkmenistan"),
        ("994", "Азербайджан", "Azerbaijan"), ("995", "Грузия", "Georgia"), ("374", "Армения", "Armenia"),
        ("373", "Молдова", "Moldova"), ("371", "Латвия", "Latvia"), ("370", "Литва", "Lithuania"), ("372", "Эстония", "Estonia"),
        ("971", "ОАЭ", "UAE"), ("972", "Израиль", "Israel"), ("90", "Турция", "Turkey"), ("86", "Китай", "China"),
        ("49", "Германия", "Germany"), ("44", "Великобритания", "United Kingdom"), ("33", "Франция", "France"),
        ("39", "Италия", "Italy"), ("34", "Испания", "Spain"), ("48", "Польша", "Poland"), ("81", "Япония", "Japan"),
        ("82", "Южная Корея", "South Korea"), ("91", "Индия", "India"), ("1", "США или Канада", "USA or Canada"),
    ]

    static func phone(_ digits: String, lang: AppLanguage) -> String {
        let s = Strings(lang: lang)
        let d = international(digits)
        if d.hasPrefix("7") && d.count == 11 {
            let second = d.dropFirst().first
            if second == "6" || second == "7" { return s.t("Номер Казахстана", "Kazakhstan number") }
            return second == "9" ? s.t("Мобильный номер Российской Федерации", "Russian mobile number")
                                 : s.t("Номер Российской Федерации", "Russian Federation number")
        }
        if let c = countries.first(where: { d.hasPrefix($0.0) }) { return s.t("Страна номера: ", "Country: ") + (lang == .ru ? c.1 : c.2) }
        return s.t("Номер телефона", "Phone number")
    }

    /// Платёжная система по первым цифрам
    static func cardSystem(_ digits: String) -> String {
        let p2 = Int(digits.prefix(2)) ?? 0, p4 = Int(digits.prefix(4)) ?? 0
        if (2200...2204).contains(p4) { return "Мир" }
        if digits.hasPrefix("4") { return "Visa" }
        if (51...55).contains(p2) || (2221...2720).contains(p4) { return "Mastercard" }
        if p2 == 62 { return "UnionPay" }
        if p2 == 34 || p2 == 37 { return "American Express" }
        if p2 == 35 { return "JCB" }
        if digits.hasPrefix("6011") || p2 == 65 { return "Discover" }
        if p2 == 50 || (56...69).contains(p2) { return "Maestro" }
        return ""
    }

    /// Банк по первым цифрам (BIN) — самые распространённые российские банки
    private static let banks: [(String, String, String)] = [
        ("220220", "Сбербанк", "Sberbank"), ("4276", "Сбербанк", "Sberbank"), ("4279", "Сбербанк", "Sberbank"),
        ("5469", "Сбербанк", "Sberbank"), ("4274", "Сбербанк", "Sberbank"),
        ("220070", "Т-Банк", "T-Bank"), ("437772", "Т-Банк", "T-Bank"), ("553691", "Т-Банк", "T-Bank"), ("521324", "Т-Банк", "T-Bank"),
        ("220015", "Альфа-Банк", "Alfa-Bank"), ("415428", "Альфа-Банк", "Alfa-Bank"), ("477964", "Альфа-Банк", "Alfa-Bank"),
        ("548673", "Альфа-Банк", "Alfa-Bank"),
        ("220024", "ВТБ", "VTB"), ("418868", "ВТБ", "VTB"), ("527883", "ВТБ", "VTB"),
        ("220001", "Газпромбанк", "Gazprombank"), ("487415", "Газпромбанк", "Gazprombank"),
        ("220030", "Райффайзенбанк", "Raiffeisenbank"), ("462729", "Райффайзенбанк", "Raiffeisenbank"),
        ("220029", "Банк Открытие", "Otkritie Bank"), ("220100", "Совкомбанк", "Sovcombank"), ("220077", "Почта Банк", "Pochta Bank"),
    ]

    static func card(_ digits: String, lang: AppLanguage) -> String {
        let s = Strings(lang: lang)
        let system = cardSystem(digits)
        let bank = banks.first { digits.hasPrefix($0.0) }.map { lang == .ru ? $0.1 : $0.2 }
        let head = system.isEmpty ? s.t("Банковская карта", "Bank card") : s.t("Карта ", "") + system + s.t("", " card")
        return bank.map { head + " · " + $0 } ?? head
    }

    /// Сеть криптоадреса и ссылка на обозреватель
    static func crypto(_ address: String) -> (network: String, explorer: URL?) {
        if address.hasPrefix("0x") {
            return ("Ethereum / EVM (ERC-20, BEP-20)", URL(string: "https://etherscan.io/address/" + address))
        }
        if address.hasPrefix("T") && address.count == 34 {
            return ("TRON (TRC-20)", URL(string: "https://tronscan.org/#/address/" + address))
        }
        if address.hasPrefix("EQ") || address.hasPrefix("UQ") {
            return ("TON", URL(string: "https://tonviewer.com/" + address))
        }
        return ("Bitcoin", URL(string: "https://mempool.space/address/" + address))
    }

    /// Номер карты группами по 4 цифры
    static func grouped(_ digits: String) -> String {
        stride(from: 0, to: digits.count, by: 4).map { i -> String in
            let start = digits.index(digits.startIndex, offsetBy: i)
            let end = digits.index(start, offsetBy: min(4, digits.count - i))
            return String(digits[start..<end])
        }.joined(separator: " ")
    }
}
