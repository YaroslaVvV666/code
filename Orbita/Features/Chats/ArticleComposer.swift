import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Combine

/// Редактор статьи — сообщение из блоков, как статьи в Telegram:
/// «+» — заголовок (H1–H6), текст, цитата, выносная цитата, код, формула, кнопка, разделитель;
/// рядом — списки (маркированный, нумерованный, контрольный, сворачиваемый блок), таблица, скрепка (фото, видео,
/// звук и файлы, геопозиция) и эмодзи. Всё вставляется туда, где стоит курсор. Есть «Отменить» и «Повторить».
struct ArticleComposer: View {
    @ObservedObject var model: ChatModel
    /// Вызывается после отправки (поле ввода чата очищается — текст ушёл статьёй)
    var onSent: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var blocks: [ArticleBlock]
    @State private var footer: [ArticleButton] = []
    @State private var history: [[ArticleBlock]] = []
    @State private var future: [[ArticleBlock]] = []
    @State private var applying = false
    @State private var snapshotTask: Task<Void, Never>?
    @FocusState private var focus: String?
    @State private var lastFocus: String?

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showLocation = false
    @State private var showEmoji = false
    @State private var buttonDraft: ArticleButtonDraft?
    @State private var loadingMedia = 0
    @State private var sending = false
    @State private var errorText: String?
    @State private var confirmClose = false

    /// initialText — уже набранный в поле ввода текст: каждый абзац становится текстовым блоком
    init(model: ChatModel, initialText: String = "", onSent: @escaping () -> Void = {}) {
        self.model = model
        self.onSent = onSent
        _blocks = State(initialValue: Self.blocks(from: initialText))
    }

    static func blocks(from text: String) -> [ArticleBlock] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [ArticleBlock(kind: .text)] }
        // абзацы — через пустую строку; если пустых строк нет, абзац — каждая строка
        var parts = trimmed.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count == 1 { parts = trimmed.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) } }
        return parts.filter { !$0.isEmpty }.map { p in
            var b = ArticleBlock(kind: .text)
            b.text = p
            return b
        }
    }

    private var s: Strings { Strings(lang: lang) }
    private var bg: Color { theme.dark ? Color(white: 0.11) : Color(white: 0.97) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach($blocks) { $block in
                            blockRow($block)
                                .id(block.id)
                                .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
                        }
                        if loadingMedia > 0 {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(s.t("Готовим медиа…", "Preparing media…")).font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        footerButtons
                        Color.clear.frame(height: 80)
                            .contentShape(Rectangle())
                            .onTapGesture { focusEnd() }
                    }
                    .padding(.top, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: focus) { _, f in
                    if let f { lastFocus = f }
                }
                .onChange(of: blocks.count) { old, new in
                    // новый блок — прокручиваем к нему
                    if new > old, let id = focusedBlock?.id ?? blocks.last?.id {
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .background(bg.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .onAppear {
            history = [blocks]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focus = blocks.last?.id }
        }
        .onChange(of: blocks) { _, _ in scheduleSnapshot() }
        .photosPicker(isPresented: $showPhotos, selection: $pickerItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            addPicked(items)
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.audio, .item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { addFiles(urls) }
        }
        .sheet(isPresented: $showLocation) {
            LocationShareSheet { point, _ in
                insert(mediaBlock(ArticleLocalMedia(.location(point))))
            }
            .environment(\.theme, theme).environment(\.lang, lang)
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showEmoji) {
            ArticleEmojiPicker { appendText($0) }
                .environment(\.theme, theme)
                .presentationDetents([.height(320)])
        }
        .sheet(item: $buttonDraft) { draft in
            ArticleButtonSheet(draft: draft) { result in applyButton(result) }
                .environment(\.theme, theme).environment(\.lang, lang)
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog(s.t("Удалить черновик статьи?", "Discard this article?"), isPresented: $confirmClose,
                            titleVisibility: .visible) {
            Button(s.t("Удалить", "Discard"), role: .destructive) { dismiss() }
            Button(s.cancel, role: .cancel) {}
        }
        .alert(errorText ?? "", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .interactiveDismissDisabled(hasContent)
    }

    // MARK: Верх

    private var hasContent: Bool { blocks.contains { !$0.isEmpty } || !footer.isEmpty }

    private var topBar: some View {
        HStack {
            Button {
                if hasContent { confirmClose = true } else { dismiss() }
            } label: {
                Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.text)
                    .frame(width: 48, height: 48).glassCircle()
            }
            .buttonStyle(.plain)
            Spacer()
            HStack(spacing: 0) {
                Button { undo() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 17, weight: .semibold))
                        .frame(width: 50, height: 48)
                }
                .disabled(history.count < 2)
                Button { redo() } label: {
                    Image(systemName: "arrow.uturn.forward").font(.system(size: 17, weight: .semibold))
                        .frame(width: 50, height: 48)
                }
                .disabled(future.isEmpty)
            }
            .foregroundStyle(theme.text)
            .buttonStyle(.plain)
            .glass(Capsule())
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
    }

    // MARK: Низ: панель инструментов

    private var bottomBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                Menu {
                    insertMenu
                } label: { toolIcon("plus") }
                Menu {
                    listMenu
                } label: { toolIcon("list.bullet") }
                Button { insertTable() } label: { toolIcon("tablecells") }
                Menu {
                    Button { showPhotos = true } label: { Label(s.t("Фото или видео", "Photo or video"), systemImage: "photo.on.rectangle") }
                    Button { showFiles = true } label: { Label(s.t("Звук или файл", "Audio or file"), systemImage: "music.note") }
                    Button { showLocation = true } label: { Label(s.t("Геопозиция", "Location"), systemImage: "mappin.and.ellipse") }
                } label: { toolIcon("paperclip") }
                Button { showEmoji = true } label: { toolIcon("face.smiling") }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .glass(Capsule())

            Button { send() } label: {
                ZStack {
                    if sending { ProgressView().tint(.white) } else {
                        Image(systemName: "paperplane.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 56, height: 56)
                .background(hasContent ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.gray.opacity(0.4)), in: Circle())
            }
            .buttonStyle(PressStyle())
            .disabled(sending || !hasContent || loadingMedia > 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func toolIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 20, weight: .medium)).foregroundStyle(theme.text)
            .frame(width: 50, height: 52).contentShape(Rectangle())
    }

    @ViewBuilder
    private var insertMenu: some View {
        Menu {
            ForEach(1...6, id: \.self) { lvl in
                Button("H\(lvl)") { var b = ArticleBlock(kind: .heading); b.level = lvl; insert(b) }
            }
        } label: { Label(s.t("Заголовок", "Heading"), systemImage: "h.square") }
        Button { insert(ArticleBlock(kind: .text)) } label: { Label(s.t("Текст", "Text"), systemImage: "textformat") }
        Button { insert(ArticleBlock(kind: .quote)) } label: { Label(s.t("Цитата", "Quote"), systemImage: "text.quote") }
        Button { insert(ArticleBlock(kind: .pullquote)) } label: { Label(s.t("Выносная цитата", "Pull quote"), systemImage: "quote.opening") }
        Button { insert(ArticleBlock(kind: .code)) } label: { Label(s.t("Код", "Code"), systemImage: "chevron.left.forwardslash.chevron.right") }
        Button { insert(ArticleBlock(kind: .formula)) } label: { Label(s.t("Формула", "Formula"), systemImage: "function") }
        Button { buttonDraft = ArticleButtonDraft(button: ArticleButton(), inline: true) } label: {
            Label(s.t("Кнопка", "Button"), systemImage: "link")
        }
        Button { insert(ArticleBlock(kind: .divider)) } label: { Label(s.t("Разделитель", "Divider"), systemImage: "minus") }
    }

    @ViewBuilder
    private var listMenu: some View {
        let current = currentListStyle
        listItem(nil, s.t("Без списка", "No list"), nil, current)
        listItem("bullet", s.t("Маркированный список", "Bulleted list"), "list.bullet", current)
        listItem("number", s.t("Нумерованный список", "Numbered list"), "list.number", current)
        listItem("check", s.t("Контрольный список", "Checklist"), "checklist", current)
        listItem("collapse", s.t("Сворачиваемый блок", "Collapsible block"), "rectangle.dashed", current)
    }

    private func listItem(_ style: String?, _ title: String, _ icon: String?, _ current: String?) -> some View {
        Button { setList(style) } label: {
            if current == style {
                Label(title, systemImage: "checkmark")
            } else if let icon {
                Label(title, systemImage: icon)
            } else {
                Text(title)
            }
        }
    }

    // MARK: Блоки

    private var focusedIndex: Int? {
        guard let f = focus ?? lastFocus else { return nil }
        return blocks.firstIndex { f == $0.id || f.hasPrefix($0.id + "#") }
    }
    private var focusedBlock: ArticleBlock? { focusedIndex.map { blocks[$0] } }

    @ViewBuilder
    private func blockRow(_ block: Binding<ArticleBlock>) -> some View {
        let b = block.wrappedValue
        if b.kind == .media {
            mediaEditor(block)
        } else {
            HStack(alignment: .top, spacing: 8) {
                gutter(b)
                editor(block)
            }
            .padding(.horizontal, 16)
        }
    }

    /// Значок типа блока слева: нажатие — сменить тип, переместить, удалить
    private func gutter(_ b: ArticleBlock) -> some View {
        let active = focusedBlock?.id == b.id
        return Menu {
            if ([.text, .heading, .quote, .pullquote, .code, .formula] as [ArticleBlock.Kind]).contains(b.kind) {
                Menu(s.t("Превратить в", "Turn into")) {
                    ForEach(1...6, id: \.self) { lvl in
                        Button("H\(lvl)") { convert(b.id, to: .heading, level: lvl) }
                    }
                    Button(s.t("Текст", "Text")) { convert(b.id, to: .text) }
                    Button(s.t("Цитата", "Quote")) { convert(b.id, to: .quote) }
                    Button(s.t("Выносная цитата", "Pull quote")) { convert(b.id, to: .pullquote) }
                    Button(s.t("Код", "Code")) { convert(b.id, to: .code) }
                    Button(s.t("Формула", "Formula")) { convert(b.id, to: .formula) }
                }
            }
            if b.kind == .button {
                Button { editInlineButton(b) } label: { Label(s.t("Изменить кнопку", "Edit button"), systemImage: "pencil") }
            }
            Button { move(b.id, by: -1) } label: { Label(s.t("Выше", "Move up"), systemImage: "arrow.up") }
            Button { move(b.id, by: 1) } label: { Label(s.t("Ниже", "Move down"), systemImage: "arrow.down") }
            Button(role: .destructive) { remove(b.id) } label: { Label(s.t("Удалить блок", "Delete block"), systemImage: "trash") }
        } label: {
            Group {
                switch b.kind {
                case .heading: Text("H\(b.level)").font(.system(size: 13, weight: .heavy))
                case .text: Text("T").font(.system(size: 15, weight: .heavy))
                default: Image(systemName: gutterIcon(b)).font(.system(size: 13, weight: .bold))
                }
            }
            .foregroundStyle(active ? theme.accentColor : theme.textTertiary)
            .frame(width: 28, height: 30)
            .overlay(alignment: .bottom) {
                if active { Capsule().fill(theme.accentColor).frame(width: 2, height: 10).offset(y: 12) }
            }
        }
    }

    private func gutterIcon(_ b: ArticleBlock) -> String {
        switch b.kind {
        case .quote: return "text.quote"
        case .pullquote: return "quote.opening"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .formula: return "function"
        case .button: return "link"
        case .list: return b.style == "number" ? "list.number" : (b.style == "check" ? "checklist" : "list.bullet")
        case .collapse: return "rectangle.dashed"
        case .table: return "tablecells"
        case .divider: return "minus"
        default: return "textformat"
        }
    }

    @ViewBuilder
    /// Поле, которое по ширине «обнимает» свой текст: невидимая надпись задаёт размер, поле лежит поверх.
    /// Короткий текст — узко, длинный — переносится и занимает всю доступную ширину
    private func hugging<F: View>(_ text: String, placeholder: String, font: Font, @ViewBuilder field: () -> F) -> some View {
        Text((text.isEmpty ? placeholder : text) + "  ")
            .font(font)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .frame(minWidth: 40)
            .overlay { field() }
    }

    private func editor(_ block: Binding<ArticleBlock>) -> some View {
        let b = block.wrappedValue
        switch b.kind {
        case .heading:
            TextField(s.t("Заголовок", "Heading"), text: block.text, axis: .vertical)
                .font(ArticleFonts.heading(b.level))
                .foregroundStyle(theme.text)
                .focused($focus, equals: b.id)
                .submitLabel(.next)
        case .text:
            TextField(s.t("Текст", "Text"), text: block.text, axis: .vertical)
                .font(.system(size: 17))
                .foregroundStyle(theme.text)
                .focused($focus, equals: b.id)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                Capsule().fill(theme.accentColor).frame(width: 3)
                TextField(s.t("Цитата", "Quote"), text: block.text, axis: .vertical)
                    .font(.system(size: 17)).foregroundStyle(theme.text)
                    .focused($focus, equals: b.id)
            }
            .padding(10)
            .background(theme.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .pullquote:
            VStack(spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    Text("“").font(.system(size: 30, weight: .black, design: .serif)).foregroundStyle(theme.accentColor)
                    // ширина поля — по введённому тексту: короткая цитата — небольшая плашка, длинная — до краёв
                    hugging(block.text.wrappedValue, placeholder: s.t("Выносная цитата", "Pull quote"),
                            font: .system(size: 18, weight: .medium).italic()) {
                        TextField(s.t("Выносная цитата", "Pull quote"), text: block.text, axis: .vertical)
                            .font(.system(size: 18, weight: .medium).italic()).multilineTextAlignment(.center)
                            .foregroundStyle(theme.text)
                            .focused($focus, equals: b.id)
                    }
                    Text("”").font(.system(size: 30, weight: .black, design: .serif)).foregroundStyle(theme.accentColor)
                }
                hugging(block.author.wrappedValue, placeholder: s.t("Автор", "Author"),
                        font: .system(size: 16, weight: .bold).italic()) {
                    TextField(s.t("Автор", "Author"), text: block.author)
                        .font(.system(size: 16, weight: .bold).italic()).multilineTextAlignment(.center)
                        .foregroundStyle(theme.accentColor)
                        .focused($focus, equals: b.id + "#a")
                }
            }
            .padding(12)
            .background(theme.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: .infinity)                      // сама плашка — по центру строки
        case .code:
            VStack(alignment: .leading, spacing: 6) {
                TextField(s.t("язык (python, swift…)", "language (python, swift…)"), text: block.lang)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(theme.textSecondary)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focus, equals: b.id + "#a")
                TextField(s.t("Код", "Code"), text: block.text, axis: .vertical)
                    .font(.system(size: 15, design: .monospaced)).foregroundStyle(theme.text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focus, equals: b.id)
            }
            .padding(10)
            .background(Color.black.opacity(theme.dark ? 0.35 : 0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .formula:
            VStack(spacing: 8) {
                TextField("LaTeX: E = mc^2, \\frac{a}{b}", text: block.text, axis: .vertical)
                    .font(.system(size: 15, design: .monospaced)).foregroundStyle(theme.text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focus, equals: b.id)
                if !b.text.isEmpty {
                    Text(MathText.render(b.text)).font(.system(size: 22, design: .serif).italic())
                        .foregroundStyle(theme.text).frame(maxWidth: .infinity)
                }
            }
            .padding(10)
            .background(theme.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .button:
            ArticleLinkButton(text: b.text.isEmpty ? s.t("Кнопка", "Button") : b.text, url: b.url, color: b.color,
                              mine: false, fullWidth: true)
                .allowsHitTesting(false)
                .onTapGesture { editInlineButton(b) }
                .overlay { Color.clear.contentShape(Rectangle()).onTapGesture { editInlineButton(b) } }
        case .list:
            listEditor(block)
        case .collapse:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField(s.t("Заголовок блока", "Block title"), text: block.text)
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
                        .focused($focus, equals: b.id)
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.accentColor)
                }
                TextField(s.t("Скрытый текст — откроется по нажатию", "Hidden text — opens on tap"), text: block.body, axis: .vertical)
                    .font(.system(size: 16)).foregroundStyle(theme.text)
                    .focused($focus, equals: b.id + "#a")
            }
            .padding(12)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        case .table:
            tableEditor(block)
        case .divider:
            Rectangle().fill(theme.textTertiary.opacity(0.5)).frame(height: 1).padding(.vertical, 14)
        case .media:
            EmptyView()
        }
    }

    // MARK: Списки

    private func listEditor(_ block: Binding<ArticleBlock>) -> some View {
        let b = block.wrappedValue
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(b.items.indices), id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        switch b.style {
                        case "number": Text("\(i + 1).").font(.system(size: 17, weight: .semibold).monospacedDigit())
                        case "check":
                            Button {
                                guard i < block.wrappedValue.items.count else { return }
                                Haptics.select()
                                block.wrappedValue.items[i].checked.toggle()
                            } label: {
                                Image(systemName: b.items[i].checked ? "checkmark.square.fill" : "square").font(.system(size: 18))
                            }
                            .buttonStyle(.plain)
                        default: Text("•").font(.system(size: 20, weight: .bold))
                        }
                    }
                    .foregroundStyle(theme.accentColor)
                    .frame(minWidth: 20, alignment: .trailing)
                    TextField(s.t("Пункт", "Item"), text: itemBinding(block, i), axis: .vertical)
                        .font(.system(size: 17)).foregroundStyle(theme.text)
                        .focused($focus, equals: b.id + "#i\(i)")
                        .onSubmit { addItem(block, after: i) }
                        .submitLabel(.next)
                    if b.items.count > 1 && focus == b.id + "#i\(i)" {
                        Button { removeItem(block, i) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button { addItem(block, after: block.wrappedValue.items.count - 1) } label: {
                Label(s.t("Пункт", "Item"), systemImage: "plus").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
            }
            .buttonStyle(.plain)
            .padding(.leading, 28)
        }
    }

    private func itemBinding(_ block: Binding<ArticleBlock>, _ i: Int) -> Binding<String> {
        Binding(get: { i < block.wrappedValue.items.count ? block.wrappedValue.items[i].text : "" },
                set: { v in
                    guard i < block.wrappedValue.items.count else { return }
                    // вставили несколько строк — это несколько пунктов
                    let lines = v.components(separatedBy: "\n")
                    block.wrappedValue.items[i].text = lines[0]
                    if lines.count > 1 {
                        let extra = lines.dropFirst().map { ArticleListItem(text: $0) }
                        block.wrappedValue.items.insert(contentsOf: extra, at: i + 1)
                        focus = block.wrappedValue.id + "#i\(i + extra.count)"
                    }
                })
    }

    private func addItem(_ block: Binding<ArticleBlock>, after i: Int) {
        let at = min(max(i + 1, 0), block.wrappedValue.items.count)
        block.wrappedValue.items.insert(ArticleListItem(text: ""), at: at)
        let id = block.wrappedValue.id
        DispatchQueue.main.async { focus = id + "#i\(at)" }
    }

    private func removeItem(_ block: Binding<ArticleBlock>, _ i: Int) {
        guard block.wrappedValue.items.count > 1, i < block.wrappedValue.items.count else { return }
        block.wrappedValue.items.remove(at: i)
        focus = block.wrappedValue.id + "#i\(max(0, i - 1))"
    }

    // MARK: Таблица

    private func tableEditor(_ block: Binding<ArticleBlock>) -> some View {
        let b = block.wrappedValue
        let cols = b.rows.map(\.count).max() ?? 0
        let line = theme.textTertiary.opacity(0.5)
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(b.rows.indices), id: \.self) { r in
                        GridRow {
                            ForEach(0..<cols, id: \.self) { c in
                                TextField("", text: cellBinding(block, r, c), axis: .vertical)
                                    .font(.system(size: 15, weight: b.header && r == 0 ? .semibold : .regular))
                                    .foregroundStyle(theme.text)
                                    .focused($focus, equals: b.id + "#r\(r)c\(c)")
                                    .padding(10)
                                    .frame(width: cols <= 2 ? (UIScreen.main.bounds.width - 76) / CGFloat(max(cols, 1)) : 130,
                                           alignment: .topLeading)
                                    .frame(minHeight: 50, alignment: .topLeading)
                                    .background(b.header && r == 0 ? theme.text.opacity(0.06) : Color.clear)
                                    .overlay(alignment: .trailing) { if c < cols - 1 { Rectangle().fill(line).frame(width: 0.5) } }
                                    .overlay(alignment: .bottom) { if r < b.rows.count - 1 { Rectangle().fill(line).frame(height: 0.5) } }
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(line, lineWidth: 1))
            }
            HStack(spacing: 14) {
                tableAction("plus", s.t("Строка", "Row")) { block.wrappedValue.rows.append(Array(repeating: "", count: max(cols, 1))) }
                tableAction("plus", s.t("Столбец", "Column")) {
                    guard cols < 8 else { return }
                    for r in block.wrappedValue.rows.indices { block.wrappedValue.rows[r].append("") }
                }
                Menu {
                    Button(s.t("Удалить последнюю строку", "Delete last row")) {
                        if block.wrappedValue.rows.count > 1 { block.wrappedValue.rows.removeLast() }
                    }
                    Button(s.t("Удалить последний столбец", "Delete last column")) {
                        if cols > 1 { for r in block.wrappedValue.rows.indices { block.wrappedValue.rows[r].removeLast() } }
                    }
                    Toggle(s.t("Первая строка — заголовок", "Header row"), isOn: block.header)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 17)).foregroundStyle(theme.accentColor)
                }
            }
        }
    }

    private func tableAction(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.select(); action() } label: {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accentColor)
        }
        .buttonStyle(.plain)
    }

    private func cellBinding(_ block: Binding<ArticleBlock>, _ r: Int, _ c: Int) -> Binding<String> {
        Binding(get: {
            let rows = block.wrappedValue.rows
            return r < rows.count && c < rows[r].count ? rows[r][c] : ""
        }, set: { v in
            guard r < block.wrappedValue.rows.count else { return }
            while block.wrappedValue.rows[r].count <= c { block.wrappedValue.rows[r].append("") }
            block.wrappedValue.rows[r][c] = v
        })
    }

    // MARK: Медиа

    private func mediaEditor(_ block: Binding<ArticleBlock>) -> some View {
        let b = block.wrappedValue
        return VStack(spacing: 8) {
            ZStack {
                mediaPreview(b)
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                Menu {
                    Button { move(b.id, by: -1) } label: { Label(s.t("Выше", "Move up"), systemImage: "arrow.up") }
                    Button { move(b.id, by: 1) } label: { Label(s.t("Ниже", "Move down"), systemImage: "arrow.down") }
                    Button(role: .destructive) { remove(b.id) } label: { Label(s.t("Удалить", "Delete"), systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(.black.opacity(0.5), in: Circle())
                }
                .padding(10)
            }
            .overlay(alignment: .topTrailing) {
                Menu {
                    insertMenu
                } label: {
                    Image(systemName: "plus").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(.black.opacity(0.5), in: Circle())
                }
                .simultaneousGesture(TapGesture().onEnded { focus = b.id + "#c" })
                .padding(10)
            }
            TextField(s.t("Подпись", "Caption"), text: block.caption, axis: .vertical)
                .font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .focused($focus, equals: b.id + "#c")
                .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private func mediaPreview(_ b: ArticleBlock) -> some View {
        if let local = b.local {
            switch local.source {
            case .prepared(let m):
                ZStack {
                    if let img = local.preview {
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: min(300, UIScreen.main.bounds.width * CGFloat(m.height) / CGFloat(max(m.width, 1))))
                            .clipped()
                    } else {
                        Color.gray.opacity(0.3).frame(height: 220)
                    }
                    if m.isVideo {
                        Image(systemName: "play.fill").font(.system(size: 24)).foregroundStyle(.white)
                            .frame(width: 58, height: 58).background(.black.opacity(0.55), in: Circle())
                    }
                }
            case .file(_, let name, let mime):
                HStack(spacing: 12) {
                    Image(systemName: mime.hasPrefix("audio") ? "music.note" : "doc.fill").font(.system(size: 22))
                        .foregroundStyle(.white).frame(width: 48, height: 48).background(theme.accent, in: Circle())
                    Text(name).font(.system(size: 16, weight: .medium)).foregroundStyle(theme.text).lineLimit(2)
                    Spacer()
                }
                .padding(14)
                .background(theme.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16).padding(.top, 50)
            case .location(let p):
                HStack(spacing: 12) {
                    Image(systemName: "mappin.circle.fill").font(.system(size: 34)).foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title ?? s.t("Геопозиция", "Location")).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.text)
                        Text(String(format: "%.5f, %.5f", p.lat, p.lon)).font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(theme.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16).padding(.top, 50)
            }
        }
    }

    private func mediaBlock(_ local: ArticleLocalMedia) -> ArticleBlock {
        var b = ArticleBlock(kind: .media)
        b.local = local
        return b
    }

    private func addPicked(_ items: [PhotosPickerItem]) {
        for item in items {
            loadingMedia += 1
            Task { @MainActor in
                defer { loadingMedia -= 1 }
                do {
                    let m = try await MediaPreparer.prepare(item)
                    let preview = ImageCache.downsample(m.thumbnail, maxPixel: 1000)
                    insert(mediaBlock(ArticleLocalMedia(.prepared(m), preview: preview)))
                } catch {
                    errorText = s.t("Не удалось добавить медиа", "Couldn't add the media")
                }
            }
        }
    }

    private func addFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 80 * 1024 * 1024 { errorText = s.t("Файл больше 80 МБ", "File is over 80 MB"); continue }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let name = SafeFileName.clean(url.lastPathComponent)
            let target = dir.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: target)
            } catch {
                errorText = s.t("Не удалось добавить файл", "Couldn't add the file")
                continue
            }
            let mime = UTType(filenameExtension: target.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            insert(mediaBlock(ArticleLocalMedia(.file(target, name: name, mime: mime))))
        }
    }

    // MARK: Кнопки под сообщением

    @ViewBuilder
    private var footerButtons: some View {
        if !footer.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(s.t("КНОПКИ ПОД СООБЩЕНИЕМ", "BUTTONS BELOW THE MESSAGE"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                ForEach(footer) { btn in
                    HStack {
                        ArticleLinkButton(text: btn.text, url: btn.url, color: btn.color, mine: false)
                            .allowsHitTesting(false)
                        Spacer()
                        Button { buttonDraft = ArticleButtonDraft(button: btn, inline: false, footerID: btn.id) } label: {
                            Image(systemName: "pencil").foregroundStyle(theme.accentColor)
                        }
                        Button { withAnimation { footer.removeAll { $0.id == btn.id } } } label: {
                            Image(systemName: "trash").foregroundStyle(theme.danger)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20).padding(.top, 8)
        }
    }

    private func editInlineButton(_ b: ArticleBlock) {
        buttonDraft = ArticleButtonDraft(button: ArticleButton(text: b.text, url: b.url, color: b.color), inline: true,
                                         blockID: b.id, placementLocked: true)
    }

    private func applyButton(_ r: ArticleButtonDraft) {
        if r.inline {
            if let id = r.blockID, let i = blocks.firstIndex(where: { $0.id == id }) {
                blocks[i].text = r.button.text
                blocks[i].url = r.button.url
                blocks[i].color = r.button.color
            } else {
                var b = ArticleBlock(kind: .button)
                b.text = r.button.text
                b.url = r.button.url
                b.color = r.button.color
                insert(b)
            }
        } else if let id = r.footerID, let i = footer.firstIndex(where: { $0.id == id }) {
            footer[i] = r.button
        } else if footer.count < 8 {
            withAnimation { footer.append(r.button) }
        }
    }

    // MARK: Правка

    private func insert(_ block: ArticleBlock) {
        commitSnapshot()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            if let i = focusedIndex, blocks[i].kind == .text, blocks[i].text.isEmpty {
                blocks[i] = block                      // пустая строка под курсором превращается в новый блок
                if i == blocks.count - 1, ([.media, .table, .divider, .button, .formula, .code] as [ArticleBlock.Kind]).contains(block.kind) {
                    blocks.append(ArticleBlock(kind: .text))
                }
            } else {
                let at = focusedIndex.map { $0 + 1 } ?? blocks.count
                blocks.insert(block, at: at)
                if at == blocks.count - 1, ([.media, .table, .divider, .button] as [ArticleBlock.Kind]).contains(block.kind) {
                    blocks.append(ArticleBlock(kind: .text))   // чтобы после фото/таблицы можно было писать дальше
                }
            }
        }
        let id = block.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            switch block.kind {
            case .media: focus = id + "#c"
            case .table: focus = id + "#r0c0"
            case .list: focus = id + "#i0"
            case .divider, .button:
                if let i = blocks.firstIndex(where: { $0.id == id }), i + 1 < blocks.count { focus = blocks[i + 1].id }
            default: focus = id
            }
        }
    }

    private func insertTable() {
        var b = ArticleBlock(kind: .table)
        b.rows = [["", ""], ["", ""]]
        insert(b)
    }

    private func convert(_ id: String, to kind: ArticleBlock.Kind, level: Int = 1) {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else { return }
        commitSnapshot()
        withAnimation(.easeOut(duration: 0.2)) {
            blocks[i].kind = kind
            blocks[i].level = level
        }
        focus = id
    }

    private var currentListStyle: String? {
        guard let b = focusedBlock else { return nil }
        if b.kind == .list { return b.style }
        if b.kind == .collapse { return "collapse" }
        return nil
    }

    private func setList(_ style: String?) {
        commitSnapshot()
        guard let i = focusedIndex, ([.text, .heading, .quote, .list, .collapse] as [ArticleBlock.Kind]).contains(blocks[i].kind) else {
            // курсор не в тексте — новый список
            guard let style else { return }
            var b = ArticleBlock(kind: style == "collapse" ? .collapse : .list)
            if style != "collapse" { b.style = style; b.items = [ArticleListItem(text: "")] }
            insert(b)
            return
        }
        var b = blocks[i]
        let content: String
        switch b.kind {
        case .list: content = b.items.map(\.text).joined(separator: "\n")
        case .collapse: content = [b.text, b.body].filter { !$0.isEmpty }.joined(separator: "\n")
        default: content = b.text
        }
        let lines = content.components(separatedBy: "\n")
        switch style {
        case nil:
            b.kind = .text
            b.text = content
        case "collapse":
            b.kind = .collapse
            b.text = lines.first ?? ""
            b.body = lines.dropFirst().joined(separator: "\n")
        case let st?:
            b.kind = .list
            b.style = st
            let items = lines.filter { !$0.isEmpty }.map { ArticleListItem(text: $0) }
            b.items = items.isEmpty ? [ArticleListItem(text: "")] : items
        }
        withAnimation(.easeOut(duration: 0.2)) { blocks[i] = b }
        let id = b.id
        DispatchQueue.main.async { focus = b.kind == .list ? id + "#i\(max(0, b.items.count - 1))" : id }
    }

    private func move(_ id: String, by delta: Int) {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard j >= 0, j < blocks.count else { return }
        commitSnapshot()
        Haptics.select()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { blocks.swapAt(i, j) }
    }

    private func remove(_ id: String) {
        commitSnapshot()
        withAnimation(.easeOut(duration: 0.2)) {
            blocks.removeAll { $0.id == id }
            if blocks.isEmpty { blocks = [ArticleBlock(kind: .text)] }
        }
    }

    private func focusEnd() {
        if let last = blocks.last, last.kind == .text {
            focus = last.id
        } else {
            let b = ArticleBlock(kind: .text)
            blocks.append(b)
            DispatchQueue.main.async { focus = b.id }
        }
    }

    /// Эмодзи — в поле, где стоит курсор
    private func appendText(_ e: String) {
        guard let f = focus ?? lastFocus, let i = focusedIndex else { return }
        let id = blocks[i].id
        if f == id {
            blocks[i].text += e
        } else if f == id + "#a" {
            switch blocks[i].kind {
            case .pullquote: blocks[i].author += e
            case .collapse: blocks[i].body += e
            default: blocks[i].text += e
            }
        } else if f == id + "#c" {
            blocks[i].caption += e
        } else if f.hasPrefix(id + "#i"), let k = Int(f.dropFirst(id.count + 2)), k < blocks[i].items.count {
            blocks[i].items[k].text += e
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focus = f }
    }

    // MARK: Отменить / повторить

    private func scheduleSnapshot() {
        guard !applying else { return }
        snapshotTask?.cancel()
        snapshotTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            commitSnapshot()
        }
    }

    private func commitSnapshot() {
        guard !applying, history.last != blocks else { return }
        history.append(blocks)
        if history.count > 80 { history.removeFirst() }
        future.removeAll()
    }

    private func undo() {
        snapshotTask?.cancel()
        commitSnapshot()
        guard history.count > 1 else { return }
        future.append(history.removeLast())
        restore(history.last ?? blocks)
    }

    private func redo() {
        guard let next = future.popLast() else { return }
        history.append(next)
        restore(next)
    }

    private func restore(_ state: [ArticleBlock]) {
        Haptics.select()
        applying = true
        withAnimation(.easeOut(duration: 0.18)) { blocks = state }
        DispatchQueue.main.async { applying = false }
    }

    // MARK: Отправка

    private func send() {
        let ready = blocks.filter { !$0.isEmpty }
        guard !ready.isEmpty else {
            errorText = s.t("Статья пустая", "The article is empty")
            return
        }
        focus = nil
        sending = true
        Task { @MainActor in
            let error = await model.sendArticle(blocks: ready, buttons: footer)
            sending = false
            if let error {
                errorText = s.api(error)
            } else {
                Haptics.notify(.success)
                onSent()
                dismiss()
            }
        }
    }
}

// MARK: - Кнопка: текст, ссылка, цвет, место

struct ArticleButtonDraft: Identifiable {
    var id = UUID().uuidString
    var button: ArticleButton
    var inline: Bool                    // в тексте статьи / под сообщением
    var blockID: String? = nil          // правим кнопку в тексте
    var footerID: String? = nil         // правим кнопку под сообщением
    var placementLocked = false
}

struct ArticleButtonSheet: View {
    @State var draft: ArticleButtonDraft
    let onDone: (ArticleButtonDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    private var s: Strings { Strings(lang: lang) }

    private var valid: Bool {
        !draft.button.text.trimmingCharacters(in: .whitespaces).isEmpty
            && SafeLink.url(ArticleButtonStyle.normalized(draft.button.url)) != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // предпросмотр
                    ArticleLinkButton(text: draft.button.text.isEmpty ? s.t("Текст кнопки", "Button text") : draft.button.text,
                                      url: draft.button.url, color: draft.button.color, mine: false, fullWidth: draft.inline)
                        .allowsHitTesting(false)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)

                    if !draft.placementLocked && draft.footerID == nil {
                        Picker("", selection: $draft.inline) {
                            Text(s.t("В тексте", "In the text")).tag(true)
                            Text(s.t("Под сообщением", "Below the message")).tag(false)
                        }
                        .pickerStyle(.segmented)
                    }

                    field(s.t("Текст", "Text")) {
                        TextField(s.t("Купить чизбургер", "Buy a cheeseburger"), text: $draft.button.text)
                    }
                    field(s.t("Ссылка", "Link")) {
                        TextField("https://", text: $draft.button.url)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Text(s.t("ЦВЕТ", "COLOR")).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 10) {
                        ForEach(ArticleButtonStyle.colors, id: \.self) { c in
                            Button {
                                Haptics.select()
                                draft.button.color = c
                            } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(ArticleButtonStyle.fill(c) ?? theme.accentColor.opacity(0.3))
                                        .overlay(Circle().stroke(theme.textTertiary, lineWidth: c == "white" ? 1 : 0))
                                        .frame(width: 18, height: 18)
                                    Text(ArticleButtonStyle.title(c, s)).font(.system(size: 14)).foregroundStyle(theme.text)
                                }
                                .padding(.horizontal, 10).frame(height: 38).frame(maxWidth: .infinity)
                                .background(theme.text.opacity(draft.button.color == c ? 0.14 : 0.05), in: Capsule())
                                .overlay(Capsule().stroke(draft.button.color == c ? theme.accentColor : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text(s.t("Перед переходом человек увидит настоящий адрес ссылки.",
                             "Before opening, people will see the real link address."))
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                }
                .padding(20)
            }
            .navigationTitle(s.t("Кнопка", "Button"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(s.cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(s.t("Готово", "Done")) {
                        var d = draft
                        d.button.text = d.button.text.trimmingCharacters(in: .whitespaces)
                        d.button.url = ArticleButtonStyle.normalized(d.button.url)
                        onDone(d)
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
        }
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
            content().font(.system(size: 16)).padding(14).card(theme, radius: 14)
        }
    }
}

/// Быстрые эмодзи для статьи (полная клавиатура эмодзи — системная)
struct ArticleEmojiPicker: View {
    let onPick: (String) -> Void
    @Environment(\.theme) private var theme
    private let emojis = Array("😀😂🥹😍😎🤔🙌👍👎👏🔥✨⭐️💯❤️💔🎉🎁📌📍📣💡⚡️✅❌⚠️❓❗️👉👈👆👇🍔🍕☕️🎮🎵📷🎬📚💰🚀🌍🏆").map(String.init)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
                ForEach(Array(emojis.enumerated()), id: \.offset) { _, e in
                    Button {
                        Haptics.select()
                        onPick(e)
                    } label: {
                        Text(e).font(.system(size: 30)).frame(width: 40, height: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(theme.sheet)
    }
}
