import SwiftUI

// MARK: - Базовые стили

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 10
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * shakes), y: 0))
    }
}

/// Статичная страница: на всю высоту экрана, не «болтается» и не листается.
/// Прокрутка включается, только если контент физически не помещается
/// (например, маленький экран с открытой клавиатурой).
struct StaticPage<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: spacing) { content }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 56)
                    .padding(.bottom, 16)
                    .frame(minHeight: geo.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

// MARK: - Кнопки

struct PrimaryButton: View {
    let title: String
    var enabled = true
    var loading = false
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(loading ? 0 : 1)
                if loading { ProgressView().tint(.white) }
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(enabled ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Color.gray.opacity(0.35)),
                        in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: enabled ? theme.accentColor.opacity(theme.glow) : .clear, radius: 16, y: 6)
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled || loading)
        .animation(.easeOut(duration: 0.25), value: enabled)
        .padding(.horizontal, 24)
    }
}

struct TextActionButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.accentColor)
                .frame(height: 40)
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - Тексты и заголовки

struct ErrorText: View {
    let error: AuthError?
    @Environment(\.lang) private var lang
    @Environment(\.theme) private var theme

    var body: some View {
        if let error {
            Text(Strings(lang: lang).message(for: error))
                .font(.system(size: 13))
                .foregroundStyle(theme.danger)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .transition(.opacity)
        }
    }
}

struct StepHeader: View {
    let icon: String
    let title: String
    let subtitle: String
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            // при открытой клавиатуре иконка прячется, чтобы всё помещалось
            if !flow.keyboardVisible {
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(theme.accentColor)
                    .frame(width: 84, height: 84)
                    .card(theme, radius: 42)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            Text(title)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(theme.text)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 36)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(theme.accentColor)
                .frame(width: 22)
            Text(text).font(.system(size: 15)).foregroundStyle(theme.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .card(theme, radius: 14)
        .padding(.horizontal, 24)
    }
}

struct InfoRow: View {
    let icon: String
    let title: String
    let value: String
    var chevron = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(theme.accentColor)
                .frame(width: 22)
            Text(title).font(.system(size: 15)).foregroundStyle(theme.text)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 15)).foregroundStyle(theme.textSecondary).lineLimit(1)
            if chevron {
                Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .card(theme, radius: 14)
    }
}

// MARK: - Аватар

struct AvatarView: View {
    let name: String
    var size: CGFloat = 44
    var avatarID: String? = nil

    private static let palettes: [(Color, Color)] = [
        (Color(red: 0.36, green: 0.45, blue: 0.80), Color(red: 0.25, green: 0.30, blue: 0.62)),
        (Color(red: 0.45, green: 0.40, blue: 0.78), Color(red: 0.30, green: 0.25, blue: 0.60)),
        (Color(red: 0.30, green: 0.58, blue: 0.70), Color(red: 0.20, green: 0.40, blue: 0.55)),
        (Color(red: 0.62, green: 0.42, blue: 0.62), Color(red: 0.42, green: 0.27, blue: 0.48)),
        (Color(red: 0.72, green: 0.48, blue: 0.42), Color(red: 0.52, green: 0.32, blue: 0.32)),
        (Color(red: 0.34, green: 0.60, blue: 0.52), Color(red: 0.22, green: 0.42, blue: 0.38))
    ]

    /// Размер декодирования — по фиксированным ступеням, а не «размер × 3». Иначе у анимированных аватарок
    /// (орбита друзей «дышит» каждый кадр) каждый кадр получался новый ключ кэша → чтение и декодирование заново.
    static func pixelBucket(_ size: CGFloat) -> CGFloat {
        let want = size * 3
        for b: CGFloat in [96, 160, 256, 384, 512, 768] where want <= b { return b }
        return 1024
    }

    private var palette: (Color, Color) {
        let h = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Self.palettes[h % Self.palettes.count]
    }

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }.map { String($0) }.joined()
        return letters.isEmpty ? "•" : letters.uppercased()
    }

    private var placeholder: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.95))
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [palette.0, palette.1],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    var body: some View {
        ZStack {
            if let id = avatarID, let url = ServerConfig.mediaURL(id) {
                // аватарки маленькие: декодируем сразу в нужный размер (с запасом под @3x) и держим в памяти.
                // Буквы и цветной фон — только пока фото грузится, под готовой картинкой их нет
                CachedImage(url: url, maxPixel: Self.pixelBucket(size), persistKey: id) { image, _ in
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: size, height: size)
                            .background(Color.black)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - Поля ввода

/// UITextField, который просит у системы именно английскую клавиатуру
final class LatinUITextField: UITextField {
    override var textInputMode: UITextInputMode? {
        for mode in UITextInputMode.activeInputModes {
            if let language = mode.primaryLanguage, language.hasPrefix("en") { return mode }
        }
        return super.textInputMode
    }
}

struct LatinTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var focused: Bool
    var secure: Bool
    var reveal: Bool
    var email: Bool
    var keyboard: UIKeyboardType
    var tint: UIColor
    var textColor: UIColor

    func makeUIView(context: Context) -> LatinUITextField {
        let tf = LatinUITextField()
        tf.delegate = context.coordinator
        tf.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        tf.autocapitalizationType = .none
        tf.autocorrectionType = .no
        tf.spellCheckingType = .no
        tf.keyboardType = keyboard
        tf.returnKeyType = .done
        tf.font = UIFont.systemFont(ofSize: 17)
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tf
    }

    func updateUIView(_ tf: LatinUITextField, context: Context) {
        context.coordinator.parent = self
        if tf.text != text { tf.text = text }
        tf.placeholder = placeholder
        tf.tintColor = tint
        tf.textColor = textColor

        let wantSecure = secure && !reveal
        if tf.isSecureTextEntry != wantSecure {
            tf.isSecureTextEntry = wantSecure
            let current = tf.text            // иначе iOS стирает текст при смене режима
            tf.text = nil
            tf.text = current
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: LatinTextField
        init(_ parent: LatinTextField) { self.parent = parent }

        @objc func changed(_ tf: UITextField) {
            var value = tf.text ?? ""
            // набрали в русской раскладке — превращаем в английскую
            value = LayoutFix.toLatin(value, emailMode: parent.email)
            if parent.email { value = value.replacingOccurrences(of: " ", with: "") }
            if value != (tf.text ?? "") { tf.text = value }
            if parent.text != value { parent.text = value }
        }

        func textFieldDidBeginEditing(_ tf: UITextField) {
            DispatchQueue.main.async { self.parent.focused = true }
        }

        func textFieldDidEndEditing(_ tf: UITextField) {
            DispatchQueue.main.async { self.parent.focused = false }
        }

        func textFieldShouldReturn(_ tf: UITextField) -> Bool {
            tf.resignFirstResponder()
            return true
        }
    }
}

/// Почта и пароль: только английская раскладка
struct InputField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String
    var secure = false
    var email = false
    var keyboard: UIKeyboardType = .default

    @Environment(\.theme) private var theme
    @State private var reveal = false
    @State private var focused = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 22)

            LatinTextField(placeholder: placeholder, text: $text, focused: $focused,
                           secure: secure, reveal: reveal, email: email, keyboard: keyboard,
                           tint: UIColor(theme.accentColor), textColor: UIColor(theme.text))
                .frame(maxWidth: .infinity)
                .frame(height: 30)

            if secure {
                Button { reveal.toggle() } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye").foregroundStyle(theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .card(theme, radius: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.accentColor.opacity(focused ? 0.8 : 0), lineWidth: 1.2)
        )
        .animation(.easeOut(duration: 0.2), value: focused)
        .padding(.horizontal, 24)
    }
}

/// Обычное поле (имя): любая раскладка
struct NameField: View {
    let placeholder: String
    @Binding var text: String
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person")
                .foregroundStyle(theme.textSecondary)
                .frame(width: 22)
            TextField(placeholder, text: $text)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($focused)
                .foregroundStyle(theme.text)
                .tint(theme.accentColor)
        }
        .font(.system(size: 17))
        .padding(.horizontal, 16)
        .frame(height: 56)
        .card(theme, radius: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.accentColor.opacity(focused ? 0.8 : 0), lineWidth: 1.2)
        )
        .animation(.easeOut(duration: 0.2), value: focused)
        .padding(.horizontal, 24)
    }
}

struct StrengthMeter: View {
    let level: Int          // 0...4
    @Environment(\.theme) private var theme

    private var color: Color {
        if level <= 1 { return theme.danger }
        if level == 2 { return Color.orange }
        if level == 3 { return Color.yellow }
        return Color.green
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(i < level ? color : theme.stroke)
                    .frame(height: 4)
            }
        }
        .animation(.easeOut(duration: 0.2), value: level)
        .padding(.horizontal, 28)
    }
}

// MARK: - Баннер «пришло SMS / письмо»

struct InboxBanner: View {
    let message: DeliveredMessage
    @Environment(\.lang) private var lang
    @Environment(\.theme) private var theme

    var body: some View {
        let s = Strings(lang: lang)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: message.channel == .sms ? "message.fill" : "envelope.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(message.channel == .sms ? Color.green : Color.blue,
                            in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 3) {
                Text(s.bannerTitle(message.channel))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(s.bannerBody(message))
                    .font(.system(size: 14))
                    .foregroundStyle(theme.text)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.stroke, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.2), radius: 12, y: 4)
        .padding(.horizontal, 12)
    }
}


// MARK: - Строки настроек (как в Telegram)

struct SettingsRow: View {
    let icon: String
    let tint: Color
    let title: String
    var value: String? = nil
    var showsChevron = false
    var action: (() -> Void)? = nil

    @Environment(\.theme) private var theme

    private var content: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint, in: RoundedRectangle(cornerRadius: 8))
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(theme.text)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.bold())
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .contentShape(Rectangle())
    }

    var body: some View {
        if let action {
            Button(action: action) { content }.buttonStyle(PressStyle())
        } else {
            content
        }
    }
}

struct SettingsDivider: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Rectangle().fill(theme.stroke).frame(height: 1).padding(.leading, 58)
    }
}

struct SettingsGroup<Content: View>: View {
    private let content: Content
    @Environment(\.theme) private var theme

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(spacing: 0) { content }
            .card(theme, radius: 16)
            .padding(.horizontal, 16)
    }
}

struct ToastView: View {
    let text: String
    @Environment(\.theme) private var theme
    @State private var shown = false

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(theme.danger.opacity(0.95), in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: Color.black.opacity(0.2), radius: 10, y: 4)
            .padding(.horizontal, 24)
            // мягко выезжает сверху с лёгкой пружинкой, а не появляется рывком
            .offset(y: shown ? 0 : -28)
            .scaleEffect(shown ? 1 : 0.92, anchor: .top)
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { shown = true } }
    }
}
