import Foundation

/// Тексты редактирования профиля, фотографий, устройств и QR-кодов
extension Strings {
    private var locale: Locale { Locale(identifier: lang.rawValue) }

    // Редактирование профиля
    var editProfile: String { t("Изменить профиль", "Edit profile") }
    var editShort: String { t("Изм.", "Edit") }
    var done: String { t("Готово", "Done") }
    var firstName: String { t("Имя", "First name") }
    var lastName: String { t("Фамилия", "Last name") }
    var namesHint: String { t("Введите имя и, если хотите, фамилию.", "Enter your name and, optionally, a last name.") }
    var birthday: String { t("День рождения", "Birthday") }
    var addBirthday: String { t("Добавить", "Add") }
    var removeDate: String { t("Удалить дату", "Remove date") }
    var withoutYear: String { t("Без года", "No year") }
    var accountSection: String { t("Аккаунт", "Account") }
    var saving: String { t("Сохраняем…", "Saving…") }

    func birthdayText(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let parts = value.components(separatedBy: "-")
        var comps = DateComponents()
        if value.hasPrefix("--"), parts.count == 4 {
            comps.month = Int(parts[2]); comps.day = Int(parts[3]); comps.year = 2000
        } else if parts.count == 3 {
            comps.year = Int(parts[0]); comps.month = Int(parts[1]); comps.day = Int(parts[2])
        } else { return nil }
        guard let date = Calendar(identifier: .gregorian).date(from: comps) else { return nil }
        return FormatterCache.localized(date, template: value.hasPrefix("--") ? "dMMMM" : "dMMMMy", locale: locale)
    }

    // Смена номера
    var phoneChangeTitle: String { t("Смена номера", "Change number") }
    var newPhoneNumber: String { t("Новый номер", "New number") }
    var phoneChangeHint: String { t("Мы отправим код подтверждения на новый номер. Вы останетесь в своём аккаунте.",
                                    "We'll send a confirmation code to the new number. You'll stay in your account.") }
    var getCode: String { t("Получить код", "Get code") }
    var codeFromSMS: String { t("Код из SMS", "SMS code") }
    var confirm: String { t("Подтвердить", "Confirm") }
    func codeSentTo(_ number: String) -> String { t("Код отправлен на \(number)", "Code sent to \(number)") }

    // Фотографии
    var profilePhotos: String { t("Фотографии профиля", "Profile photos") }
    var addPhoto: String { t("Добавить фото", "Add photo") }
    var mainPhoto: String { t("Основное", "Main") }
    var makeMain: String { t("Сделать основным", "Set as main") }
    var deletePhoto: String { t("Удалить фото", "Delete photo") }
    var deletePhotoQuestion: String { t("Удалить это фото из профиля?", "Delete this photo from your profile?") }
    var reorderHint: String { t("Удерживайте фото и перетащите, чтобы поменять порядок. Первое показывается в профиле.",
                                "Hold a photo and drag to reorder. The first one is shown on your profile.") }
    func photoCounter(_ index: Int, _ total: Int) -> String { t("\(index) из \(total)", "\(index) of \(total)") }

    func photoDate(_ date: Date) -> String {
        FormatterCache.localized(date, template: "dMMMMyHHmm", locale: locale)
    }

    func photoDateShort(_ date: Date) -> String {
        FormatterCache.localized(date, template: "dMMMy", locale: locale)
    }

    // Устройства
    var devices: String { t("Устройства", "Devices") }
    var thisDevice: String { t("Это устройство", "This device") }
    var activeSessions: String { t("Активные сеансы", "Active sessions") }
    var terminateOthers: String { t("Завершить все другие сеансы", "Terminate all other sessions") }
    var terminateSession: String { t("Завершить сеанс", "Terminate session") }
    func terminateQuestion(_ device: String) -> String {
        t("Завершить сеанс на устройстве «\(device)»? Там нужно будет войти заново.",
          "Terminate the session on “\(device)”? It will have to sign in again.")
    }
    var connectDevice: String { t("Подключить устройство", "Link device") }
    var devicesHint: String { t("Чтобы войти в Orbita на другом устройстве, откройте на нём экран входа, выберите вход по QR-коду и отсканируйте его здесь.",
                                "To sign in on another device, open its sign-in screen, choose QR sign-in and scan the code here.") }
    var sessionsHint: String { t("Нажмите на сеанс, чтобы завершить его.", "Tap a session to terminate it.") }
    var online: String { t("в сети", "online") }
    var unknownDevice: String { t("Неизвестное устройство", "Unknown device") }

    func lastSeen(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 300 { return online }
        return FormatterCache.formatter("\(locale.identifier)|lastSeen") { f in
            f.locale = locale
            f.dateStyle = .medium
            f.timeStyle = .short
            f.doesRelativeDateFormatting = true
        }.string(from: date)
    }

    // Сканер и вход по QR
    var scanTitle: String { t("Сканировать QR-код", "Scan QR code") }
    var scanHint: String { t("Наведите камеру на QR-код Orbita", "Point the camera at an Orbita QR code") }
    var notOrbitaCode: String { t("Это не код Orbita", "This isn't an Orbita code") }
    var openSettings: String { t("Открыть настройки", "Open Settings") }
    var loginRequestTitle: String { t("Вход в Orbita", "Sign in to Orbita") }
    func loginRequestBody(_ device: String) -> String {
        t("Устройство «\(device)» просит войти в ваш аккаунт.", "“\(device)” is asking to sign in to your account.")
    }
    var approveLogin: String { t("Подтвердить вход", "Approve sign-in") }
    var loginWarning: String { t("Подтверждайте вход, только если этот код показан на вашем устройстве. Если код прислал или показал другой человек — откажитесь.",
                                 "Approve only if this code is shown on your own device. If someone else sent or showed you the code, decline.") }
    var deviceConnected: String { t("Устройство подключено", "Device linked") }
    var qrExpired: String { t("Код устарел или уже использован.", "The code has expired or was already used.") }
    var qrStep1: String { t("Откройте Orbita на устройстве, где вы уже вошли", "Open Orbita on a device where you're signed in") }
    var qrStep2: String { t("Профиль → Устройства → Подключить устройство", "Profile → Devices → Link device") }
    var qrStep3: String { t("Наведите камеру на этот код", "Point the camera at this code") }
    var qrRefreshing: String { t("Обновляем код…", "Refreshing the code…") }

    // Чужой профиль
    var profileNotFound: String { t("Профиль не найден", "Profile not found") }
    var close: String { t("Закрыть", "Close") }
}
