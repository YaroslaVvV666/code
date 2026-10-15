import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - Заставка

struct LaunchView: View {
    var body: some View {
        OrbitLogo(size: 130)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Шаг 1: телефон

enum ActiveSheet: String, Identifiable {
    case country, language, qr
    var id: String { rawValue }
}

struct PhoneStepView: View {
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang
    @AppStorage("lang") private var langRaw = AppLanguage.ru.rawValue

    @State private var codePulse = false
    @State private var activeSheet: ActiveSheet?
    @FocusState private var phoneFocused: Bool

    private var s: Strings { Strings(lang: lang) }
    private var compact: Bool { flow.keyboardVisible }

    private var canContinue: Bool {
        !flow.phone.hasPrefix("+") && flow.code.count > 1 && flow.phoneDigits.count >= 5
    }

    var body: some View {
        StaticPage {
            if !compact {
                OrbitLogo(size: 150)
                    .padding(.bottom, -6)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            Text(s.title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(theme.text)
                .tracking(0.3)

            Text(s.subtitle)
                .font(.system(size: 15))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 40)

            fields

            ErrorText(error: flow.error)

            PrimaryButton(title: s.next, enabled: canContinue, loading: flow.isLoading) {
                phoneFocused = false
                Task { @MainActor in await flow.submitPhone() }
            }
            .padding(.top, 6)

            Spacer(minLength: 12)

            if !compact { bottomButtons }
        }
        .sheet(item: $activeSheet) { sheet in
            Group {
                switch sheet {
                case .country:
                    CountrySheet(lang: lang, selected: flow.country) { picked in
                        flow.country = picked
                        flow.code = picked.code
                    }
                case .language:
                    LanguageSheet(current: langRaw, title: s.languageTitle,
                                  languages: flow.availableLanguages) { langRaw = $0 }
                case .qr:
                    QRSheet(strings: s)
                }
            }
            .preferredColorScheme(theme.dark ? .dark : .light)
            .presentationBackground(theme.sheet)
        }
    }

    private var bottomButtons: some View {
        VStack(spacing: 16) {
            Button { activeSheet = .qr } label: {
                Label(s.qrButton, systemImage: "qrcode")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .card(theme, radius: 14)
            }
            .buttonStyle(PressStyle())
            .padding(.horizontal, 24)

            Button { activeSheet = .language } label: {
                Label(s.changeLanguage, systemImage: "globe")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.accentColor)
            }
            .buttonStyle(PressStyle())
        }
        .transition(.opacity)
    }

    // MARK: Поля

    private var fields: some View {
        VStack(spacing: 0) {
            Button {
                phoneFocused = false
                activeSheet = .country
            } label: {
                HStack(spacing: 12) {
                    if let country = flow.country {
                        Text(country.flag).font(.system(size: 22))
                        Text(country.name(lang)).foregroundStyle(theme.text)
                    } else {
                        Image(systemName: "globe").foregroundStyle(theme.textSecondary)
                        Text(s.chooseCountry).foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.bold())
                        .foregroundStyle(theme.textTertiary)
                }
                .font(.system(size: 17))
                .padding(.horizontal, 16)
                .frame(height: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle().fill(theme.stroke).frame(height: 1)

            HStack(spacing: 0) {
                TextField("+", text: $flow.code)
                    .keyboardType(.phonePad)
                    .frame(width: 68)
                    .padding(.leading, 16)
                    .foregroundStyle(codePulse ? theme.accentColor : theme.text)
                    .scaleEffect(codePulse ? 1.25 : 1, anchor: .leading)
                    .onChange(of: flow.code) { _, new in handleCodeChange(new) }

                Rectangle().fill(theme.stroke).frame(width: 1, height: 56)

                TextField(s.phone, text: $flow.phone)
                    .keyboardType(.phonePad)
                    .focused($phoneFocused)
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 16)
                    .onChange(of: flow.phone) { old, new in handlePhoneChange(old: old, new: new) }
            }
            .font(.system(size: 18, weight: .medium).monospacedDigit())
            .tint(theme.accentColor)
            .frame(height: 56)
        }
        .card(theme, radius: 18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(theme.accentColor.opacity(phoneFocused ? 0.8 : 0), lineWidth: 1.2)
        )
        .animation(.easeOut(duration: 0.2), value: phoneFocused)
        .padding(.horizontal, 24)
        .padding(.top, 14)
    }

    // MARK: Логика ввода

    private func formatted(_ digits: String) -> String {
        formatDigits(digits, code: flow.code)
    }

    private func reformatPhone() {
        guard !flow.phone.hasPrefix("+") else { return }
        let f = formatted(String(flow.phone.filter(\.isNumber)))
        if f != flow.phone { flow.phone = f }
    }

    private func applyCountry(_ c: Country, forcePulse: Bool = false) {
        let changed = (flow.country?.code != c.code) || (flow.code != c.code)
        // тот же код (например, +7 у Казахстана) — оставляем выбранную страну
        if flow.country?.code != c.code { flow.country = c }
        if flow.code != c.code { flow.code = c.code }
        if changed || forcePulse { pulseCode() }
    }

    private func pulseCode() {
        Haptics.impact(.light)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { codePulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeOut(duration: 0.3)) { codePulse = false }
        }
    }

    private func handleCodeChange(_ new: String) {
        let cleaned = "+" + String(new.filter(\.isNumber).prefix(4))
        if cleaned != new { flow.code = cleaned; return }
        if flow.country?.code != cleaned {
            flow.country = countries.first { $0.code == cleaned }
        }
        reformatPhone()
    }

    private func handlePhoneChange(old: String, new: String) {
        if flow.error != nil { flow.error = nil }
        var digits: String

        if new.hasPrefix("+") {
            // "+7981…" -> страна определяется автоматически
            let rest = String(new.dropFirst().filter(\.isNumber))
            if let match = dialMatches.first(where: { rest.hasPrefix($0.digits) }) {
                applyCountry(match)
                digits = String(rest.dropFirst(match.digits.count))
            } else {
                let text = "+" + rest
                if text != flow.phone { flow.phone = text }
                return
            }
        } else {
            digits = String(new.filter(\.isNumber))
            let wasEmpty = old.filter(\.isNumber).isEmpty

            if wasEmpty, digits.hasPrefix("8"), flow.code == "+7" || flow.country == nil {
                // "8981…" -> +7
                applyCountry(countries[0], forcePulse: true)
                digits.removeFirst()
            } else if wasEmpty, flow.code == "+7", digits.count == 11, digits.hasPrefix("7") {
                digits.removeFirst()
            }
        }

        let f = formatted(digits)
        if f != flow.phone { flow.phone = f }
    }
}

// MARK: - Шаг 2: ввод кода (SMS или почта)

struct CodeBoxes: View {
    let code: String
    let length: Int
    let focused: Bool
    let hasError: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 9) {
            ForEach(0..<length, id: \.self) { i in
                let char = i < code.count ? String(code[code.index(code.startIndex, offsetBy: i)]) : ""
                let isCurrent = focused && i == min(code.count, length - 1)
                Text(char)
                    .font(.system(size: 26, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.text)
                    .frame(width: 44, height: 58)
                    .card(theme, radius: 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(hasError ? theme.danger.opacity(0.8) : theme.accentColor,
                                    lineWidth: (isCurrent || hasError) ? 1.5 : 0)
                    )
            }
        }
        .animation(.easeOut(duration: 0.15), value: code)
    }
}

struct ResendTimer: View {
    let availableAt: Date
    let onResend: () -> Void
    @Environment(\.lang) private var lang
    @Environment(\.theme) private var theme

    var body: some View {
        let s = Strings(lang: lang)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(ceil(availableAt.timeIntervalSince(context.date))))
            if remaining > 0 {
                Text(s.resendIn(mmss(remaining)))
                    .font(.system(size: 14))
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
                    .frame(height: 40)
            } else {
                TextActionButton(title: s.resend, action: onResend)
            }
        }
    }
}

struct CodeStepView: View {
    let channel: CodeChannel

    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.theme) private var theme
    @Environment(\.lang) private var lang

    @State private var code = ""
    @State private var shake: CGFloat = 0
    @FocusState private var focused: Bool

    private var s: Strings { Strings(lang: lang) }
    private var ticket: CodeTicket? { channel == .sms ? flow.phoneTicket : flow.emailTicket }
    private var length: Int { ticket?.codeLength ?? 5 }

    var body: some View {
        StaticPage(spacing: 18) {
            StepHeader(
                icon: channel == .sms ? "message.fill" : "envelope.fill",
                title: channel == .sms ? flow.displayPhone : (ticket?.target ?? flow.email),
                subtitle: channel == .sms ? s.smsSent : s.emailSent
            )

            if channel == .sms { accountChip }

            ZStack {
                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .opacity(0.02)
                    .allowsHitTesting(false)

                CodeBoxes(code: code, length: length, focused: focused, hasError: flow.error != nil)
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .modifier(ShakeEffect(animatableData: shake))
            .padding(.top, 6)

            ErrorText(error: flow.error)

            if flow.isLoading { ProgressView() }

            if let ticket {
                ResendTimer(availableAt: ticket.resendAvailableAt) { resend() }
            }
        }
        .onChange(of: code) { _, new in
            let clean = String(new.filter(\.isNumber).prefix(length))
            if clean != new { code = clean; return }
            if !clean.isEmpty, flow.error != nil { flow.error = nil }
            if clean.count == length { submit(clean) }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true }
        }
    }

    private var accountChip: some View {
        Label(flow.isExistingUser ? s.accountFound : s.accountNew,
              systemImage: flow.isExistingUser ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(theme.accentColor)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .card(theme, radius: 15)
    }

    private func submit(_ value: String) {
        focused = false
        Task { @MainActor in
            let ok: Bool
            if channel == .sms {
                ok = await flow.verifyPhoneCode(value)
            } else {
                ok = await flow.verifyEmailCode(value)
            }
            if ok {
                Haptics.notify(.success)
            } else {
                Haptics.notify(.error)
                withAnimation(.linear(duration: 0.4)) { shake += 1 }
                code = ""
                focused = true
            }
        }
    }

    private func resend() {
        Task { @MainActor in
            if channel == .sms {
                await flow.resendPhoneCode()
            } else {
                await flow.resendEmailCode()
            }
            code = ""
            focused = true
        }
    }
}

// MARK: - Пароль при входе (если включена 2FA)

struct PasswordLoginView: View {
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.lang) private var lang
    @State private var password = ""

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        StaticPage(spacing: 18) {
            StepHeader(icon: "lock.shield", title: s.passwordLoginTitle, subtitle: s.passwordLoginSub)

            InputField(placeholder: s.password, text: $password, icon: "key", secure: true)
                .padding(.top, 8)

            if let hint = flow.twoFAHint {
                Label(s.t("Подсказка: ", "Hint: ") + hint, systemImage: "lightbulb")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .padding(.horizontal, 28).frame(maxWidth: .infinity, alignment: .leading)
            }

            ErrorText(error: flow.error)

            Spacer(minLength: 12)

            PrimaryButton(title: s.signIn, enabled: !password.isEmpty, loading: flow.isLoading) {
                Task { @MainActor in
                    let ok = await flow.checkPassword(password)
                    if !ok {
                        Haptics.notify(.error)
                        password = ""
                    }
                }
            }
        }
        .onChange(of: password) { _, _ in if flow.error != nil { flow.error = nil } }
    }
}

// MARK: - Имя

struct NameStepView: View {
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.lang) private var lang
    @State private var name = ""

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        StaticPage(spacing: 18) {
            StepHeader(icon: "person.crop.circle", title: s.nameTitle, subtitle: s.nameSub)

            NameField(placeholder: s.namePlaceholder, text: $name)
                .padding(.top, 8)

            ErrorText(error: flow.error)

            Spacer(minLength: 12)

            PrimaryButton(title: s.next,
                          enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty,
                          loading: flow.isLoading) {
                Task { @MainActor in
                    let ok = await flow.saveName(name)
                    if !ok { Haptics.notify(.error) }
                }
            }
        }
        .onChange(of: name) { _, _ in if flow.error != nil { flow.error = nil } }
    }
}

// MARK: - Предложение (почта / двухфакторная защита)

struct OfferStepView: View {
    let icon: String
    let title: String
    let subtitle: String
    let bullets: [(String, String)]
    let primary: String
    let secondary: String
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        StaticPage {
            StepHeader(icon: icon, title: title, subtitle: subtitle)
                .padding(.bottom, 10)

            ForEach(Array(bullets.enumerated()), id: \.offset) { item in
                FeatureRow(icon: item.element.0, text: item.element.1)
            }

            Spacer(minLength: 12)

            PrimaryButton(title: primary, action: onPrimary)

            TextActionButton(title: secondary, action: onSecondary)
        }
    }
}

// MARK: - Ввод почты

struct EmailInputView: View {
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.lang) private var lang

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        StaticPage(spacing: 18) {
            StepHeader(icon: "at", title: s.emailTitle, subtitle: s.emailSub)

            InputField(placeholder: s.emailPlaceholder, text: $flow.email, icon: "envelope",
                       email: true, keyboard: .emailAddress)
                .padding(.top, 8)

            ErrorText(error: flow.error)

            Spacer(minLength: 12)

            PrimaryButton(title: s.sendCode,
                          enabled: !flow.email.trimmingCharacters(in: .whitespaces).isEmpty,
                          loading: flow.isLoading) {
                Task { @MainActor in await flow.submitEmail() }
            }
        }
        .onChange(of: flow.email) { _, _ in if flow.error != nil { flow.error = nil } }
    }
}

// MARK: - Создание пароля (двухфакторная защита)

struct TwoFASetupView: View {
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.lang) private var lang
    @Environment(\.theme) private var theme

    @State private var password = ""
    @State private var confirm = ""

    private var s: Strings { Strings(lang: lang) }
    private var level: Int { password.isEmpty ? 0 : max(1, Validator.passwordStrength(password)) }

    var body: some View {
        StaticPage {
            StepHeader(icon: "key.fill", title: s.passTitle, subtitle: s.passSub)
                .padding(.bottom, 6)

            InputField(placeholder: s.password, text: $password, icon: "key", secure: true)
            InputField(placeholder: s.passRepeat, text: $confirm, icon: "checkmark.shield", secure: true)

            if !password.isEmpty {
                VStack(spacing: 6) {
                    StrengthMeter(level: level)
                    Text(s.strength(level))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                .transition(.opacity)
            }

            ErrorText(error: flow.error)

            Spacer(minLength: 12)

            PrimaryButton(title: s.savePassword,
                          enabled: !password.isEmpty && !confirm.isEmpty,
                          loading: flow.isLoading) {
                Task { @MainActor in
                    let ok = await flow.savePassword(password, confirm: confirm)
                    if !ok { Haptics.notify(.error) }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: password.isEmpty)
        .onChange(of: password) { _, _ in if flow.error != nil { flow.error = nil } }
        .onChange(of: confirm) { _, _ in if flow.error != nil { flow.error = nil } }
    }
}

// MARK: - Готово

struct CheckRow: View {
    let ok: Bool
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(ok ? theme.accentColor : theme.textTertiary)
            Text(text).font(.system(size: 15)).foregroundStyle(theme.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .card(theme, radius: 14)
        .padding(.horizontal, 24)
    }
}

struct DoneStepView: View {
    @EnvironmentObject private var flow: AuthFlow
    @Environment(\.lang) private var lang
    @Environment(\.theme) private var theme

    private var s: Strings { Strings(lang: lang) }

    var body: some View {
        StaticPage(spacing: 12) {
            StepHeader(icon: "checkmark.seal", title: s.doneTitle, subtitle: s.doneSub)
                .padding(.bottom, 12)

            CheckRow(ok: true, text: s.checkPhone)
            CheckRow(ok: !InterestsStore.load(flow.userID ?? "").isEmpty,
                     text: InterestsStore.load(flow.userID ?? "").isEmpty
                        ? s.t("Интересы не выбраны — ленту можно настроить позже", "No interests yet — set them up later")
                        : s.t("Интересы выбраны: лента «Для вас» готова", "Interests saved: your For You feed is ready"))
            Text(s.t("Почту и двухфакторную защиту можно добавить в Настройках в любой момент.",
                     "You can add email and two-step protection in Settings at any time."))
                .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 36).padding(.top, 4)

            Spacer(minLength: 12)

            PrimaryButton(title: s.start) { flow.enterApp() }
        }
    }
}

// MARK: - Выбор страны (снизу)

struct CountrySheet: View {
    let lang: AppLanguage
    let selected: Country?
    let onSelect: (Country) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    /// Поиск не зависит от раскладки: "hjccbz" найдёт «Россия», "Россия" найдёт Russia
    private var filtered: [Country] {
        guard !search.isEmpty else { return countries }
        let variants = LayoutFix.variants(of: search)
        return countries.filter { c in
            variants.contains { v in
                c.ru.localizedCaseInsensitiveContains(v) ||
                c.en.localizedCaseInsensitiveContains(v) ||
                c.code.contains(v)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { c in
                Button {
                    onSelect(c)
                    dismiss()
                } label: {
                    HStack {
                        Text("\(c.flag) \(c.name(lang))").foregroundStyle(.primary)
                        Spacer()
                        Text(c.code).foregroundStyle(.secondary)
                        if c == selected {
                            Image(systemName: "checkmark").foregroundStyle(.blue)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Strings(lang: lang).search)
            .navigationTitle(Strings(lang: lang).countryTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Смена языка (список из базы)

struct LanguageSheet: View {
    let current: String
    let title: String
    let languages: [LanguageInfo]
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(languages) { item in
                Button {
                    onSelect(item.code)
                    dismiss()
                } label: {
                    HStack {
                        Text(item.nativeName).foregroundStyle(.primary)
                        Spacer()
                        if item.code == current {
                            Image(systemName: "checkmark").foregroundStyle(.blue)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
    }
}
