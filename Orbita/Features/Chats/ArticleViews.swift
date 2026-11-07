import SwiftUI
import Combine
import UIKit

// MARK: - Статья в сообщении: модель

struct ArticleListItem: Equatable, Hashable {
    var text: String
    var checked = false
}

/// Файл, ещё не загруженный на сервер (в редакторе статьи). Сравнивается по ссылке
final class ArticleLocalMedia: Equatable {
    enum Source {
        case prepared(PreparedMedia)
        case file(URL, name: String, mime: String)
        case location(GeoPoint)
    }
    let source: Source
    let preview: UIImage?
    init(_ source: Source, preview: UIImage? = nil) {
        self.source = source
        self.preview = preview
    }
    static func == (a: ArticleLocalMedia, b: ArticleLocalMedia) -> Bool { a === b }

    var outgoing: OutgoingMedia {
        switch source {
        case .prepared(let m): return .prepared(m)
        case .file(let url, let name, let mime): return .file(url: url, name: name, mime: mime)
        case .location(let p): return .location(p, live: 0)
        }
    }
}

struct ArticleBlock: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case heading, text, quote, pullquote, code, formula, button, list, collapse, table, media, divider
    }
    var id = UUID().uuidString
    var kind: Kind
    var text = ""
    var level = 1                       // заголовок: H1…H6
    var author = ""                     // выносная цитата: автор
    var lang = ""                       // код: язык
    var url = ""                        // кнопка
    var color = "default"
    var style = "bullet"                // список: bullet | number | check
    var items: [ArticleListItem] = []
    var body = ""                       // сворачиваемый блок: содержимое
    var rows: [[String]] = []           // таблица
    var header = true                   // первая строка таблицы — заголовок
    var caption = ""                    // медиа: подпись (автор, источник)
    var media: ChatAttachment? = nil    // медиа с сервера
    var local: ArticleLocalMedia? = nil // медиа в редакторе, до загрузки

    init(kind: Kind) { self.kind = kind }

    /// Есть ли что отправлять
    var isEmpty: Bool {
        switch kind {
        case .media: return media == nil && local == nil
        case .divider: return false
        case .list: return !items.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        case .table: return !rows.joined().contains { !$0.isEmpty }
        case .button: return text.trimmingCharacters(in: .whitespaces).isEmpty || SafeLink.url(ArticleButtonStyle.normalized(url)) == nil
        case .collapse: return text.isEmpty && body.isEmpty
        default: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// JSON для сервера (медиа подставляется после загрузки)
    var json: [String: Any] {
        var d: [String: Any] = ["kind": kind.rawValue]
        switch kind {
        case .heading: d["text"] = text; d["level"] = level
        case .text, .quote, .formula: d["text"] = text
        case .pullquote: d["text"] = text; d["author"] = author
        case .code: d["text"] = text; d["lang"] = lang
        case .button: d["text"] = text; d["url"] = ArticleButtonStyle.normalized(url); d["color"] = color
        case .list:
            d["style"] = style
            d["items"] = items.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { ["text": $0.text, "checked": $0.checked] as [String: Any] }
        case .collapse: d["text"] = text; d["body"] = body
        case .table: d["rows"] = rows; d["header"] = header
        case .media: d["caption"] = caption
        case .divider: break
        }
        return d
    }
}

/// Кнопка-ссылка под сообщением (или в тексте статьи)
struct ArticleButton: Identifiable, Equatable {
    var id = UUID().uuidString
    var text = ""
    var url = ""
    var color = "default"
    var json: [String: Any] { ["text": text, "url": ArticleButtonStyle.normalized(url), "color": color] }
}

enum ArticleButtonStyle {
    static let colors = ["default", "red", "blue", "green", "orange", "yellow", "white"]

    static func title(_ c: String, _ s: Strings) -> String {
        switch c {
        case "red": return s.t("Красный", "Red")
        case "blue": return s.t("Синий", "Blue")
        case "green": return s.t("Зелёный", "Green")
        case "orange": return s.t("Оранжевый", "Orange")
        case "yellow": return s.t("Жёлтый", "Yellow")
        case "white": return s.t("Белый", "White")
        default: return s.t("Обычный", "Default")
        }
    }

    static func fill(_ c: String) -> Color? {
        switch c {
        case "red": return Color(red: 0.93, green: 0.27, blue: 0.24)
        case "blue": return Color(red: 0.2, green: 0.5, blue: 0.98)
        case "green": return Color(red: 0.2, green: 0.74, blue: 0.4)
        case "orange": return Color(red: 1.0, green: 0.55, blue: 0.15)
        case "yellow": return Color(red: 1.0, green: 0.82, blue: 0.2)
        case "white": return .white
        default: return nil
        }
    }

    static func label(_ c: String) -> Color { c == "white" || c == "yellow" ? .black : .white }

    /// «example.com» → «https://example.com»
    static func normalized(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") { return t }
        return "https://" + t
    }
}

// MARK: - Формулы: LaTeX → красивый текст

/// Лёгкий разбор частых команд LaTeX: дроби, степени и индексы, корни, греческие буквы, знаки.
/// Без внешних библиотек: формулы школьного и вузовского уровня выглядят как в учебнике
enum MathText {
    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ",
        "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ",
        "Psi": "Ψ", "Omega": "Ω", "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓", "le": "≤", "leq": "≤",
        "ge": "≥", "geq": "≥", "ne": "≠", "neq": "≠", "approx": "≈", "equiv": "≡", "sim": "∼", "infty": "∞",
        "sum": "∑", "prod": "∏", "int": "∫", "oint": "∮", "partial": "∂", "nabla": "∇", "to": "→", "rightarrow": "→",
        "leftarrow": "←", "Rightarrow": "⇒", "Leftrightarrow": "⇔", "in": "∈", "notin": "∉", "subset": "⊂",
        "cup": "∪", "cap": "∩", "forall": "∀", "exists": "∃", "emptyset": "∅", "degree": "°", "circ": "°", "angle": "∠",
        "perp": "⊥", "parallel": "∥", "ldots": "…", "dots": "…", "cdots": "⋯", "quad": "  ", ",": " ", ";": " ",
        "lim": "lim", "sin": "sin", "cos": "cos", "tan": "tan", "log": "log", "ln": "ln", "exp": "exp", "max": "max",
        "min": "min", "left": "", "right": ""
    ]
    private static let sup: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺",
        "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "y": "ʸ", "a": "ᵃ", "b": "ᵇ", "c": "ᶜ",
        "d": "ᵈ", "e": "ᵉ", "k": "ᵏ", "m": "ᵐ", "t": "ᵗ", "T": "ᵀ"
    ]
    private static let sub: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉", "+": "₊",
        "-": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "m": "ₘ", "n": "ₙ",
        "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "x": "ₓ"
    ]

    static func render(_ latex: String) -> String {
        var chars = Array(latex)
        var i = 0
        return parse(&chars, &i, stop: nil)
    }

    private static func parse(_ c: inout [Character], _ i: inout Int, stop: Character?) -> String {
        var out = ""
        while i < c.count {
            let ch = c[i]
            if let stop, ch == stop { i += 1; return out }
            switch ch {
            case "\\":
                i += 1
                var name = ""
                while i < c.count, c[i].isLetter { name.append(c[i]); i += 1 }
                if name.isEmpty, i < c.count { name = String(c[i]); i += 1 }
                switch name {
                case "frac", "dfrac", "tfrac":
                    let a = group(&c, &i), b = group(&c, &i)
                    out += wrap(a) + "⁄" + wrap(b)
                case "sqrt":
                    let a = group(&c, &i)
                    out += "√" + (a.count > 1 ? "(" + a + ")" : a)
                case "text", "mathrm", "mathbf", "operatorname":
                    out += group(&c, &i)
                case "vec":
                    out += group(&c, &i) + "\u{20D7}"
                case "bar", "overline":
                    out += group(&c, &i) + "\u{0305}"
                case "hat":
                    out += group(&c, &i) + "\u{0302}"
                case "{", "}", "%", "$", "#", "&", "_": out += name
                default: out += symbols[name] ?? name
                }
            case "^", "_":
                i += 1
                let part = group(&c, &i)
                let table = ch == "^" ? sup : sub
                let mapped = part.map { table[$0] }
                out += mapped.allSatisfy({ $0 != nil }) ? String(mapped.compactMap { $0 }) : (ch == "^" ? "^(" + part + ")" : "_(" + part + ")")
            case "{":
                i += 1
                out += parse(&c, &i, stop: "}")
            case "-":
                out += " − "; i += 1
            case "=", "+", "<", ">":
                out += " \(ch) "; i += 1
            case "*":
                out += "·"; i += 1
            default:
                out.append(ch); i += 1
            }
        }
        return out.replacingOccurrences(of: "  ", with: " ")
    }

    private static func group(_ c: inout [Character], _ i: inout Int) -> String {
        while i < c.count, c[i] == " " { i += 1 }
        guard i < c.count else { return "" }
        if c[i] == "{" {
            i += 1
            return parse(&c, &i, stop: "}").trimmingCharacters(in: .whitespaces)
        }
        if c[i] == "\\" {
            var j = i
            var one = [c[j]]
            j += 1
            while j < c.count, c[j].isLetter { one.append(c[j]); j += 1 }
            i = j
            var k = 0
            return parse(&one, &k, stop: nil)
        }
        let ch = c[i]
        i += 1
        return String(ch)
    }

    private static func wrap(_ s: String) -> String {
        s.count > 1 && s.contains(where: { "+−-· ".contains($0) }) ? "(" + s + ")" : s
    }
}

// MARK: - Статья в пузыре сообщения

struct ArticleBody: View {
    let blocks: [ArticleBlock]
    let mine: Bool
    var pending = false
    let textColor: Color
    let secondary: Color
    let messageID: String
    var blocked = false
    var onOpenMedia: (ChatAttachment) -> Void = { _ in }
    var onOpenFile: (ChatAttachment) -> Void = { _ in }
    var onPlayAudio: (ChatAttachment) -> Void = { _ in }

    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    /// Статья шире обычного сообщения — почти на всю ширину экрана
    static var width: CGFloat { min(UIScreen.main.bounds.width * 0.86, 460) }

    private var accent: Color { mine ? .white : theme.accentColor }
    private var tint: Color { mine ? Color.white.opacity(0.14) : (theme.dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, b in
                block(b, index: index)
            }
        }
        .frame(width: Self.width, alignment: .leading)
    }

    @ViewBuilder
    private func block(_ b: ArticleBlock, index: Int) -> some View {
        switch b.kind {
        case .heading:
            Text(b.text)
                .font(ArticleFonts.heading(b.level))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.top, index == 0 ? 10 : 4)
        case .text:
            RichInlineText(text: b.text, entities: [], size: 16, color: textColor, linkColor: accent, detect: !blocked)
                .padding(.horizontal, 12)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                Capsule().fill(accent).frame(width: 3)
                Text(b.text).font(.system(size: 16)).foregroundStyle(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
            }
            .padding(.vertical, 8).padding(.leading, 2).padding(.trailing, 8)
            .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "quote.closing").font(.system(size: 13, weight: .bold)).foregroundStyle(accent.opacity(0.8))
                    .padding(8)
            }
            .padding(.horizontal, 10)
        case .pullquote:
            PullQuoteView(text: b.text, author: b.author, textColor: textColor, accent: mine ? .white : theme.accentColor, tint: tint)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
        case .code:
            CodeBlockView(code: b.text, lang: b.lang, textColor: textColor, secondary: secondary, mine: mine)
                .padding(.horizontal, 10)
        case .formula:
            Text(MathText.render(b.text))
                .font(.system(size: 22, design: .serif).italic())
                .foregroundStyle(textColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .textSelection(.enabled)
        case .button:
            ArticleLinkButton(text: b.text, url: b.url, color: b.color, mine: mine, fullWidth: true)
                .padding(.horizontal, 10)
                .allowsHitTesting(!blocked)
        case .list:
            ArticleListView(block: b, textColor: textColor, accent: accent, secondary: secondary)
                .padding(.horizontal, 12)
        case .collapse:
            CollapseBlockView(title: b.text, content: b.body, textColor: textColor, accent: accent, tint: tint)
                .padding(.horizontal, 10)
        case .table:
            ArticleTableView(rows: b.rows, header: b.header, textColor: textColor, mine: mine)
                .padding(.horizontal, 10)
        case .media:
            if let a = b.media {
                VStack(spacing: 6) {
                    mediaView(a)
                    if !b.caption.isEmpty {
                        Text(b.caption).font(.system(size: 14)).foregroundStyle(secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.horizontal, 12)
                    }
                }
            }
        case .divider:
            Rectangle().fill(secondary.opacity(0.35)).frame(height: 1).padding(.horizontal, 30).padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func mediaView(_ a: ChatAttachment) -> some View {
        switch a.kind {
        case .photo, .video:
            // фото и видео — во всю ширину статьи, как в Telegram
            MediaBlock(items: [a], pending: pending) { _ in if !blocked { onOpenMedia(a) } }
                .frame(maxWidth: .infinity)
        case .voice:
            VoiceBlock(attachment: a, mine: mine, pending: pending).padding(.horizontal, 10)
        case .audio:
            AudioBlock(attachment: a, mine: mine, pending: pending) { if !blocked { onPlayAudio(a) } }.padding(.horizontal, 10)
        case .file:
            Group {
                if a.isMusic {
                    AudioBlock(attachment: a, mine: mine) { if !blocked { onPlayAudio(a) } }
                } else {
                    FileBlock(attachment: a, mine: mine, pending: pending) { if !blocked { onOpenFile(a) } }
                }
            }
            .padding(.horizontal, 10)
        case .location:
            if let geo = a.geo {
                LocationBlock(geo: geo, messageID: messageID, mine: mine, pending: pending)
                    .padding(.horizontal, 10).allowsHitTesting(!blocked)
            }
        default:
            EmptyView()
        }
    }
}

enum ArticleFonts {
    /// H1 — самый крупный, H6 — почти как текст. С засечками, как заголовки статей
    static func heading(_ level: Int) -> Font {
        let sizes: [CGFloat] = [30, 25, 22, 19, 17, 15]
        return .system(size: sizes[min(max(level, 1), 6) - 1], weight: level <= 2 ? .bold : .semibold, design: .serif)
    }
}

/// Выносная цитата: по центру, курсивом, в кавычках-«ёлочках», с автором снизу
struct PullQuoteView: View {
    let text: String
    let author: String
    let textColor: Color
    let accent: Color
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text("“").font(.system(size: 30, weight: .black, design: .serif)).foregroundStyle(accent).offset(y: -4)
                Text(text).font(.system(size: 18, weight: .medium).italic()).foregroundStyle(textColor)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text("”").font(.system(size: 30, weight: .black, design: .serif)).foregroundStyle(accent)
                    .frame(maxHeight: .infinity, alignment: .bottom).offset(y: 6)
            }
            if !author.isEmpty {
                Text(author).font(.system(size: 16, weight: .bold).italic()).foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct CodeBlockView: View {
    let code: String
    let lang: String
    let textColor: Color
    let secondary: Color
    let mine: Bool
    @State private var copied = false
    @Environment(\.lang) private var appLang

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(lang.isEmpty ? "code" : lang).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    Haptics.select()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Label(copied ? Strings(lang: appLang).t("Скопировано", "Copied") : Strings(lang: appLang).t("Копировать", "Copy"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(secondary)
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 14, design: .monospaced)).foregroundStyle(textColor)
                    .fixedSize(horizontal: true, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color.black.opacity(mine ? 0.22 : 0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ArticleListView: View {
    let block: ArticleBlock
    let textColor: Color
    let accent: Color
    let secondary: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(block.items.enumerated()), id: \.offset) { i, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(i, item).frame(minWidth: 18, alignment: .trailing)
                    Text(item.text).font(.system(size: 16)).foregroundStyle(textColor)
                        .strikethrough(block.style == "check" && item.checked, color: secondary)
                        .opacity(block.style == "check" && item.checked ? 0.7 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(_ i: Int, _ item: ArticleListItem) -> some View {
        switch block.style {
        case "number": Text("\(i + 1).").font(.system(size: 16, weight: .semibold).monospacedDigit()).foregroundStyle(accent)
        case "check":
            Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(item.checked ? accent : secondary)
        default: Text("•").font(.system(size: 18, weight: .bold)).foregroundStyle(accent)
        }
    }
}

struct CollapseBlockView: View {
    let title: String
    let content: String
    let textColor: Color
    let accent: Color
    let tint: Color
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Haptics.select()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { open.toggle() }
            } label: {
                HStack {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(textColor)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold)).foregroundStyle(accent)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Text(content).font(.system(size: 15)).foregroundStyle(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipped()
    }
}

struct ArticleTableView: View {
    let rows: [[String]]
    let header: Bool
    let textColor: Color
    let mine: Bool

    var body: some View {
        let line = mine ? Color.white.opacity(0.28) : Color.gray.opacity(0.35)
        let cols = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(0..<cols, id: \.self) { c in
                            Text(c < row.count ? row[c] : "")
                                .font(.system(size: 15, weight: header && r == 0 ? .semibold : .regular))
                                .foregroundStyle(textColor)
                                .frame(minWidth: 70, maxWidth: 220, minHeight: 40, alignment: .leading)
                                .padding(.horizontal, 10)
                                .background(header && r == 0 ? line.opacity(0.5) : Color.clear)
                                .overlay(alignment: .trailing) { if c < cols - 1 { Rectangle().fill(line).frame(width: 0.5) } }
                                .overlay(alignment: .bottom) { if r < rows.count - 1 { Rectangle().fill(line).frame(height: 0.5) } }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(line, lineWidth: 1))
        }
    }
}

/// Кнопка-ссылка: цветная капсула со стрелкой «↗». Открывается после окна с настоящим адресом
struct ArticleLinkButton: View {
    let text: String
    let url: String
    let color: String
    let mine: Bool
    var fullWidth = false

    @Environment(\.theme) private var theme

    var body: some View {
        let fill = ArticleButtonStyle.fill(color)
        let label = fill.map { _ in ArticleButtonStyle.label(color) } ?? (mine ? Color.white : theme.accentColor)
        Button {
            guard let u = SafeLink.url(ArticleButtonStyle.normalized(url)) else { return }
            Haptics.impact(.light)
            HiddenLink.confirm(u, shown: text) { UIApplication.shared.open($0) }
        } label: {
            HStack(spacing: 6) {
                Text(text).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(label)
            .padding(.horizontal, 16).frame(minHeight: 40)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background {
                if let fill {
                    Capsule().fill(fill)
                } else {
                    Capsule().fill(mine ? Color.white.opacity(0.18) : theme.accentColor.opacity(0.14))
                }
            }
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - Значок «развернуть в статью» над кнопкой отправки

/// Стеклянный кружок со «страницей» и бегущим по кругу акцентным бликом: длинный текст можно превратить в статью
struct ArticleExpandButton: View {
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var spin = false
    @State private var pop = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .scaleEffect(pop ? 1 : 0.6)
                Image(systemName: "sparkle")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(theme.accentColor)
                    .offset(x: 9, y: -9)
                    .opacity(pop ? 1 : 0)
            }
            .frame(width: 38, height: 38)
            .glassCircle()
            .overlay(
                Circle()
                    .strokeBorder(AngularGradient(colors: [theme.accentColor, theme.accentColor.opacity(0.05),
                                                           theme.accentColor.opacity(0.05), theme.accentColor],
                                                  center: .center), lineWidth: 1.6)
                    .rotationEffect(.degrees(spin ? 360 : 0))
            )
            .shadow(color: theme.accentColor.opacity(0.35), radius: 6, y: 2)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(Text("Статья"))
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.5).delay(0.05)) { pop = true }
            withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}
