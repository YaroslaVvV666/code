import Foundation

func mmss(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
}

/// Все тексты интерфейса: русский и английский
struct Strings {
    let lang: AppLanguage
    func t(_ ru: String, _ en: String) -> String { lang == .ru ? ru : en }

    // MARK: Телефон
    var title: String { t("Будь в Орбите!", "Be in Orbit!") }
    var subtitle: String { t("Выберите свою страну и введите номер телефона.",
                             "Please choose your country and enter your phone number.") }
    var chooseCountry: String { t("Выберите страну", "Choose a country") }
    var phone: String { t("Номер телефона", "Phone number") }
    var next: String { t("Продолжить", "Continue") }
    var changeLanguage: String { t("Сменить язык", "Change language") }
    var qrButton: String { t("Зарегистрироваться по QR-коду", "Sign up with QR code") }
    var search: String { t("Поиск", "Search") }
    var countryTitle: String { t("Страна", "Country") }
    var languageTitle: String { t("Язык", "Language") }
    var qrTitle: String { t("QR-код", "QR code") }
    var qrPasswordSub: String { t("Вход подтверждён на другом устройстве. Введите облачный пароль, чтобы завершить.",
                                  "Sign-in approved on your other device. Enter your cloud password to finish.") }
    var qrApprovedWait: String { t("Ждём подтверждения на другом устройстве…", "Waiting for approval on your other device…") }
    var qrHint: String { t("Отсканируйте код в приложении Orbita на другом устройстве.",
                           "Scan this code in the Orbita app on another device.") }

    // MARK: Код
    var smsSent: String { t("Мы отправили SMS с кодом на ваш номер.", "We sent an SMS with the code to your number.") }
    var emailSent: String { t("Мы отправили код на вашу почту.", "We sent a code to your email.") }
    var accountFound: String { t("Аккаунт найден — вы входите", "Account found — you're signing in") }
    var accountNew: String { t("Новый аккаунт — вы регистрируетесь", "New account — you're signing up") }
    func resendIn(_ time: String) -> String { t("Отправить код повторно через \(time)", "Resend code in \(time)") }
    var resend: String { t("Отправить код ещё раз", "Send the code again") }

    // MARK: Пароль при входе
    var passwordLoginTitle: String { t("Введите пароль", "Enter your password") }
    var passwordLoginSub: String { t("Ваш аккаунт защищён двухфакторной аутентификацией.",
                                     "Your account is protected with two-step verification.") }
    var password: String { t("Пароль", "Password") }
    var signIn: String { t("Войти", "Sign in") }

    // MARK: Имя
    var nameTitle: String { t("Как вас зовут?", "What's your name?") }
    var nameSub: String { t("Это имя увидят ваши друзья.", "Your friends will see this name.") }
    var namePlaceholder: String { t("Имя и фамилия", "First and last name") }

    // MARK: Почта
    var emailOfferTitle: String { t("Привязать почту?", "Link an email?") }
    var emailOfferSub: String { t("Почта поможет вернуть доступ к аккаунту, если вы потеряете номер.",
                                  "Email helps you recover your account if you lose your number.") }
    var bulletRecovery: String { t("Восстановление доступа к аккаунту", "Account recovery") }
    var bulletAlerts: String { t("Уведомления о новых входах", "Alerts about new sign-ins") }
    var linkEmail: String { t("Привязать почту", "Link email") }
    var skip: String { t("Пропустить", "Skip") }
    var emailTitle: String { t("Ваша почта", "Your email") }
    var emailSub: String { t("Мы проверим адрес и отправим на него код подтверждения.",
                             "We'll check the address and send you a confirmation code.") }
    var emailPlaceholder: String { "name@example.com" }
    var sendCode: String { t("Отправить код", "Send code") }

    // MARK: Двухфакторная защита
    var twoFATitle: String { t("Двухфакторная защита", "Two-step verification") }
    var twoFASub: String { t("Дополнительный пароль защитит аккаунт, даже если кто-то получит доступ к вашему номеру.",
                             "An extra password protects your account even if someone gets access to your number.") }
    var bulletPassword: String { t("Пароль при входе с нового устройства", "Password on every new device") }
    var bulletSMS: String { t("Защита, даже если перехватят SMS", "Protection even if an SMS is intercepted") }
    var enable: String { t("Включить", "Enable") }
    var passTitle: String { t("Создайте пароль", "Create a password") }
    var passSub: String { t("От 8 символов, буквы и цифры. Не используйте номер телефона.",
                            "8+ characters, letters and digits. Don't use your phone number.") }
    var passRepeat: String { t("Повторите пароль", "Repeat password") }
    var savePassword: String { t("Сохранить пароль", "Save password") }
    func strength(_ level: Int) -> String {
        switch level {
        case 0, 1: return t("Слабый пароль", "Weak password")
        case 2:    return t("Средний пароль", "Fair password")
        case 3:    return t("Хороший пароль", "Good password")
        default:   return t("Надёжный пароль", "Strong password")
        }
    }

    // MARK: Готово
    var doneTitle: String { t("Добро пожаловать в Orbita!", "Welcome to Orbita!") }
    var doneSub: String { t("Аккаунт готов к работе.", "Your account is ready.") }
    var checkPhone: String { t("Номер подтверждён", "Phone number verified") }
    func checkEmail(_ email: String?) -> String {
        if let email { return t("Почта привязана: \(email)", "Email linked: \(email)") }
        return t("Почта не привязана", "Email not linked")
    }
    func checkTwoFA(_ on: Bool) -> String {
        on ? t("Двухфакторная защита включена", "Two-step verification is on")
           : t("Двухфакторная защита выключена", "Two-step verification is off")
    }
    var start: String { t("Начать", "Get started") }
    var logout: String { t("Выйти", "Log out") }

    // MARK: Профиль
    var on: String { t("Включена", "On") }
    var off: String { t("Выключена", "Off") }
    var deleteAccount: String { t("Удалить аккаунт", "Delete account") }
    var deleteWarning: String { t("Номер, почта, пароль, публикации и настройки будут удалены без возможности восстановления.",
                                  "Your number, email, password, posts and settings will be permanently deleted.") }
    var delete: String { t("Удалить", "Delete") }
    var cancel: String { t("Отмена", "Cancel") }
    var save: String { t("Сохранить", "Save") }
    var myName: String { t("Имя", "Name") }
    var themeLabel: String { t("Тема", "Theme") }
    var you: String { t("Вы", "You") }
    var security: String { t("Шифрование данных", "Data encryption") }
    var emailLabel: String { t("Почта", "Email") }

    // MARK: Вкладки
    var tabHome: String { t("Главная", "Home") }
    var tabChats: String { t("Чаты", "Chats") }
    var tabCommunities: String { t("Сообщества", "Communities") }
    var tabProfile: String { t("Профиль", "Profile") }
    var soonSub: String { t("Этот раздел появится в следующих версиях Orbita.",
                            "This section will arrive in a future version of Orbita.") }

    // MARK: Лента
    var yourStory: String { t("Ваша история", "Your story") }
    var searchFeed: String { t("Поиск по ленте", "Search the feed") }
    var noPosts: String { t("Ничего не найдено", "Nothing found") }
    var newPost: String { t("Новая публикация", "New post") }
    var whatsNew: String { t("Что нового?", "What's new?") }
    var publish: String { t("Опубликовать", "Post") }
    var commentsTitle: String { t("Комментарии", "Comments") }
    var writeComment: String { t("Написать комментарий…", "Write a comment…") }
    var noComments: String { t("Комментариев пока нет", "No comments yet") }
    var deletePost: String { t("Удалить публикацию", "Delete post") }
    var share: String { t("Поделиться", "Share") }

    // MARK: Баннер «SMS / почта»
    func bannerTitle(_ channel: CodeChannel) -> String {
        channel == .sms ? t("Сообщения · Orbita", "Messages · Orbita") : t("Почта · Orbita", "Mail · Orbita")
    }
    func bannerBody(_ message: DeliveredMessage) -> String {
        message.channel == .sms
        ? t("Ваш код для входа в Orbita: \(message.code). Никому его не сообщайте.",
            "Your Orbita login code: \(message.code). Don't share it with anyone.")
        : t("Код подтверждения почты: \(message.code)", "Email confirmation code: \(message.code)")
    }

    // MARK: Ошибки
    func message(for error: AuthError) -> String {
        switch error {
        case .invalidPhone(let issue):
            switch issue {
            case .incomplete: return t("Номер введён не полностью.", "The number looks incomplete.")
            case .tooLong:    return t("В номере слишком много цифр.", "The number has too many digits.")
            case .notMobile:  return t("Укажите мобильный номер: он должен начинаться с 9.",
                                       "Please enter a mobile number.")
            case .looksFake:  return t("Похоже, этот номер не настоящий. Проверьте его.",
                                       "This number doesn't look real. Please check it.")
            }
        case .invalidEmail:   return t("Проверьте адрес почты.", "Please check the email address.")
        case .invalidName:    return t("Имя — от 1 до 40 символов.", "Name: 1–40 characters.")
        case .phoneTaken:     return t("Этот номер уже привязан к другому аккаунту.",
                                       "This number is already linked to another account.")
        case .emailTaken:     return t("Эта почта уже привязана к другому аккаунту.",
                                       "This email is already linked to another account.")
        case .tooManyRequests(let n):
            return t("Слишком часто. Повторите через \(mmss(n)).", "Too many requests. Try again in \(mmss(n)).")
        case .wrongCode(let left):
            return t("Неверный код. Осталось попыток: \(left).", "Wrong code. Attempts left: \(left).")
        case .codeExpired:    return t("Срок действия кода истёк. Запросите новый.", "The code has expired. Request a new one.")
        case .tooManyAttempts: return t("Слишком много неверных попыток. Запросите новый код.",
                                        "Too many wrong attempts. Request a new code.")
        case .weakPassword:   return t("Пароль слишком простой: нужно 8+ символов, буквы и цифры.",
                                       "Password is too simple: 8+ characters, letters and digits.")
        case .passwordMismatch: return t("Пароли не совпадают.", "Passwords don't match.")
        case .hintGivesAway:  return t("Подсказка не должна содержать сам пароль.", "The hint must not contain the password itself.")
        case .passwordRequired: return t("Введите пароль двухфакторной защиты.", "Enter your two-step password.")
        case .wrongPassword(let left):
            return t("Неверный пароль. Осталось попыток: \(left).", "Wrong password. Attempts left: \(left).")
        case .locked(let n):
            return t("Вход заблокирован. Повторите через \(mmss(n)).", "Sign-in is locked. Try again in \(mmss(n)).")
        case .deliveryFailed: return t("Не удалось отправить или проверить код. Проверьте номер и связь с сервером.",
                                       "Couldn't send or check the code. Check the number and the server connection.")
        case .otpNotConfigured:
            return t("Сервер запущен без отправки SMS, поэтому войти в существующий аккаунт нельзя (иначе создался бы новый с тем же номером). Перезапустите server.py с ORBITA_OTP_DEV=1 или подключите SMS-провайдера.",
                     "The server runs without SMS, so you can't sign in to an existing account (a duplicate would be created). Restart server.py with ORBITA_OTP_DEV=1 or configure an SMS provider.")
        case .unknown:        return t("Что-то пошло не так. Попробуйте ещё раз.", "Something went wrong. Please try again.")
        }
    }
}

extension Int {
    /// Int(Double) падает на NaN/∞ — для таймеров плеера берём безопасно.
    init(safe d: Double) { self = d.isFinite ? Int(Swift.max(0, Swift.min(d, 359_999))) : 0 }
}
