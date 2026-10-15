import Foundation

/// Локальный «сервер» на базе зашифрованной SQLite.
/// Номера, почты, имена и хэши паролей в базе лежат только в виде шифртекста.
actor LocalAuthBackend: AuthBackend {

    private let db: SQLiteDB
    private let vault: Vault

    private let codeLifetime: TimeInterval = 300            // код живёт 5 минут
    private let maxSendsPerHour = 5
    private let maxCodeAttempts = 5
    private let maxPasswordAttempts = 5

    /// Коды, которые отправил настоящий сервер (SMS / почта): проверка идёт на нём
    private var remoteTickets: [UUID: (channel: CodeChannel, target: String)] = [:]
    private var pendingLogins: [String: QRLoginResult] = [:]
    private var pendingTwoFA: [String: TwoFAChallenge] = [:]
    /// Последний подтверждённый пароль: нужен серверу как «текущий» при смене или снятии
    private var lastPassword: [String: String] = [:]

    init(db: SQLiteDB = Database.shared, vault: Vault = .shared) {
        self.db = db
        self.vault = vault
    }

    // MARK: Языки и настройки

    func supportedLanguages() async -> [LanguageInfo] {
        db.query("SELECT code, name, native_name FROM languages WHERE enabled = 1 ORDER BY rowid")
            .compactMap { row in
                guard let code = row[0].string, let name = row[1].string, let native = row[2].string else { return nil }
                return LanguageInfo(code: code, name: name, nativeName: native)
            }
    }

    func loadSettings(phone: String) async -> UserSettings? {
        let rows = db.query("""
            SELECT s.language, s.dark_theme, s.accent, s.autoplay
            FROM user_settings s JOIN users u ON u.id = s.user_id
            WHERE u.phone_idx = ?
            """, [.text(phoneIndex(phone))])
        guard let row = rows.first, let language = row[0].string else { return nil }
        return UserSettings(language: language, isDark: (row[1].int ?? 1) == 1,
                            accent: row[2].int ?? 0, autoplay: (row[3].int ?? 1) == 1)
    }

    func saveSettings(_ settings: UserSettings, phone: String) async {
        guard let user = fetchUser(phone: phone) else { return }
        db.run("""
            INSERT INTO user_settings(user_id, language, dark_theme, accent, autoplay, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(user_id) DO UPDATE SET
                language = excluded.language,
                dark_theme = excluded.dark_theme,
                accent = excluded.accent,
                autoplay = excluded.autoplay,
                updated_at = excluded.updated_at
            """, [.text(user.id), .text(settings.language), .integer(settings.isDark ? 1 : 0),
                  .integer(settings.accent), .integer(settings.autoplay ? 1 : 0),
                  .real(Date().timeIntervalSince1970)])
        let id = user.id
        Task { await AccountClient.pushSettings(userID: id, settings) }       // и на сервер: при новом входе вернутся как были
    }

    // MARK: Поиск в базе

    func phoneExists(_ phone: String) async -> Bool {
        await latency()
        return !db.query("SELECT 1 FROM users WHERE phone_idx = ? LIMIT 1", [.text(phoneIndex(phone))]).isEmpty
    }

    func isEmailTaken(_ email: String, excluding phone: String) async -> Bool {
        await latency()
        let rows = db.query("""
            SELECT 1 FROM emails
            WHERE email_idx = ?
              AND user_id <> COALESCE((SELECT id FROM users WHERE phone_idx = ?), '')
            LIMIT 1
            """, [.text(emailIndex(email)), .text(phoneIndex(phone))])
        return !rows.isEmpty
    }

    // MARK: Коды

    func requestCode(channel: CodeChannel, target: String, resendOf: CodeTicket?) async throws -> (CodeTicket, DeliveredMessage?) {
        // 1) настоящий сервер: он сам шлёт SMS / письмо и ограничивает частоту
        if case .sent(let debug, let expiresIn, let resendIn) = try await OTPClient.send(channel: channel, to: target) {
            let id = UUID()
            remoteTickets[id] = (channel, target)
            let now = Date()
            let ticket = CodeTicket(id: id, channel: channel, target: target, codeLength: 6,
                                    expiresAt: now.addingTimeInterval(TimeInterval(expiresIn)),
                                    resendAvailableAt: now.addingTimeInterval(TimeInterval(resendIn)))
            // debug_code приходит только от сервера в режиме разработки (ORBITA_OTP_DEV=1)
            return (ticket, debug.map { DeliveredMessage(channel: channel, target: target, code: $0) })
        }
        // 2) сервера или провайдера нет — локальная имитация
        await latency()

        let key = vault.blindIndex("\(channel.rawValue):\(target)", context: "send_log")
        let now = Date().timeIntervalSince1970

        db.run("DELETE FROM send_log WHERE sent_at < ?", [.real(now - 86_400)])
        db.run("DELETE FROM verification_codes WHERE expires_at < ?", [.real(now)])

        let log = db.query("SELECT sent_at FROM send_log WHERE key_idx = ? AND sent_at > ? ORDER BY sent_at",
                           [.text(key), .real(now - 3600)])
            .compactMap { $0.first?.double }

        // не больше 5 отправок в час
        if log.count >= maxSendsPerHour, let first = log.first {
            throw AuthError.tooManyRequests(retryAfter: max(1, Int(3600 - (now - first))))
        }
        // пауза между отправками растёт: 1 мин, 2 мин, 5 мин
        if let last = log.last {
            let cooldown = Self.cooldown(afterSends: log.count)
            if now - last < cooldown {
                throw AuthError.tooManyRequests(retryAfter: Int(ceil(cooldown - (now - last))))
            }
        }

        if let old = resendOf {                              // старый код перестаёт действовать
            db.run("DELETE FROM verification_codes WHERE id = ?", [.text(old.id.uuidString)])
        }

        let length = channel == .sms ? 5 : 6
        let code = (0..<length).map { _ in String(Int.random(in: 0...9)) }.joined()
        let id = UUID()
        let expires = now + codeLifetime

        db.run("INSERT INTO send_log(key_idx, sent_at) VALUES (?, ?)", [.text(key), .real(now)])
        // сам код не хранится — только его HMAC
        db.run("""
            INSERT INTO verification_codes(id, channel, code_mac, expires_at, attempts_left)
            VALUES (?, ?, ?, ?, ?)
            """, [.text(id.uuidString), .text(channel.rawValue),
                  .text(vault.blindIndex(code, context: "code|\(id.uuidString)")),
                  .real(expires), .integer(maxCodeAttempts)])

        let ticket = CodeTicket(
            id: id,
            channel: channel,
            target: target,
            codeLength: length,
            expiresAt: Date(timeIntervalSince1970: expires),
            resendAvailableAt: Date(timeIntervalSince1970: now + Self.cooldown(afterSends: log.count + 1))
        )
        return (ticket, DeliveredMessage(channel: channel, target: target, code: code))
    }

    func takeLogin(phone: String) async -> QRLoginResult? {
        defer { pendingLogins[phone] = nil }
        return pendingLogins[phone]
    }

    func twoFAChallenge(phone: String) async -> TwoFAChallenge? { pendingTwoFA[phone] }

    func discardTwoFA(phone: String) async { pendingTwoFA[phone] = nil }

    func completeTwoFA(phone: String, password: String) async throws -> QRLoginResult {
        guard let challenge = pendingTwoFA[phone] else { throw AuthError.codeExpired }
        let login = try await OTPClient.completeTwoFA(challenge, password: password)
        pendingTwoFA[phone] = nil
        lastPassword[phone] = password
        return login
    }

    func verify(_ ticket: CodeTicket, code: String) async throws {
        if let remote = remoteTickets[ticket.id] {
            switch try await OTPClient.verify(channel: remote.channel, to: remote.target, code: code) {
            case .login(let login): pendingLogins[remote.target] = login
            case .twofa(let challenge): pendingTwoFA[remote.target] = challenge
            case .none: break
            }
            remoteTickets[ticket.id] = nil
            return
        }
        await latency()

        let id = ticket.id.uuidString
        let rows = db.query("SELECT code_mac, expires_at, attempts_left FROM verification_codes WHERE id = ?",
                            [.text(id)])
        guard let row = rows.first,
              let stored = row[0].string,
              let expires = row[1].double,
              let left = row[2].int else { throw AuthError.codeExpired }

        if Date().timeIntervalSince1970 > expires {
            db.run("DELETE FROM verification_codes WHERE id = ?", [.text(id)])
            throw AuthError.codeExpired
        }
        let candidate = vault.blindIndex(code, context: "code|\(id)")
        if Vault.constantTimeEqual(Data(candidate.utf8), Data(stored.utf8)) {
            db.run("DELETE FROM verification_codes WHERE id = ?", [.text(id)])
            return
        }
        let newLeft = left - 1
        if newLeft <= 0 {
            db.run("DELETE FROM verification_codes WHERE id = ?", [.text(id)])
            throw AuthError.tooManyAttempts
        }
        db.run("UPDATE verification_codes SET attempts_left = ? WHERE id = ?", [.integer(newLeft), .text(id)])
        throw AuthError.wrongCode(attemptsLeft: newLeft)
    }

    private static func cooldown(afterSends n: Int) -> TimeInterval {
        n <= 1 ? 60 : (n == 2 ? 120 : 300)
    }

    // MARK: Аккаунты

    func signIn(phone: String) async -> UserRecord {
        await latency()
        if let existing = fetchUser(phone: phone) { return existing }

        let id = UUID().uuidString
        db.run("""
            INSERT INTO users(id, phone_idx, phone_enc, created_at) VALUES (?, ?, ?, ?)
            """, [.text(id), .text(phoneIndex(phone)),
                  .blob(vault.sealString(phone, context: "users.phone|\(id)")),
                  .real(Date().timeIntervalSince1970)])
        return fetchUser(phone: phone)
            ?? UserRecord(id: id, phone: phone, name: nil, email: nil, hasTwoFactor: false, createdAt: Date())
    }

    func user(id: String) async -> UserRecord? {
        fetchUser(whereClause: "u.id = ?", [.text(id)])
    }

    func setName(_ name: String, for phone: String) async {
        guard let user = fetchUser(phone: phone) else { return }
        db.run("UPDATE users SET name_enc = ? WHERE id = ?",
               [.blob(vault.sealString(name, context: "users.name|\(user.id)")), .text(user.id)])
    }

    func changePhone(from old: String, to new: String) async throws {
        await latency()
        guard let user = fetchUser(phone: old) else { throw AuthError.unknown }
        if fetchUser(phone: new) != nil { throw AuthError.phoneTaken }
        db.run("UPDATE users SET phone_idx = ?, phone_enc = ? WHERE id = ?",
               [.text(phoneIndex(new)),
                .blob(vault.sealString(new, context: "users.phone|\(user.id)")),
                .text(user.id)])
    }

    func adoptAccount(id: String, phone: String, name: String?) async -> UserRecord {
        if let existing = fetchUser(whereClause: "u.id = ?", [.text(id)]) { return existing }
        // старая локальная запись с тем же номером, но другим id, больше не нужна
        if let stale = fetchUser(phone: phone) {
            db.run("DELETE FROM users WHERE id = ?", [.text(stale.id)])
        }
        db.run("INSERT INTO users(id, phone_idx, phone_enc, created_at) VALUES (?, ?, ?, ?)",
               [.text(id), .text(phoneIndex(phone)),
                .blob(vault.sealString(phone, context: "users.phone|\(id)")),
                .real(Date().timeIntervalSince1970)])
        if let name, !name.isEmpty {
            db.run("UPDATE users SET name_enc = ? WHERE id = ?",
                   [.blob(vault.sealString(name, context: "users.name|\(id)")), .text(id)])
        }
        return fetchUser(whereClause: "u.id = ?", [.text(id)])
            ?? UserRecord(id: id, phone: phone, name: name, email: nil, hasTwoFactor: false, createdAt: Date())
    }

    func attachEmail(_ email: String, to phone: String) async throws {
        await latency()
        guard Validator.isValidEmail(email) else { throw AuthError.invalidEmail }
        guard let user = fetchUser(phone: phone) else { throw AuthError.unknown }

        let ok = db.transaction {
            db.run("DELETE FROM emails WHERE user_id = ?", [.text(user.id)])
            return db.run("""
                INSERT INTO emails(email_idx, user_id, email_enc, verified_at) VALUES (?, ?, ?, ?)
                """, [.text(emailIndex(email)), .text(user.id),
                      .blob(vault.sealString(email, context: "emails.email|\(user.id)")),
                      .real(Date().timeIntervalSince1970)])
        }
        if !ok { throw AuthError.emailTaken }                // UNIQUE: почта уже у другого аккаунта
        let id = user.id
        Task { await AccountClient.pushEmail(userID: id, email: email) }
    }

    func passwordHint(for phone: String) async -> String? {
        guard let row = db.query("SELECT id, pw_hint_enc FROM users WHERE phone_idx = ?", [.text(phoneIndex(phone))]).first,
              let id = row[0].string, let blob = row[1].data else { return nil }
        let hint = vault.openString(blob, context: "users.pwhint|\(id)")
        return (hint?.isEmpty ?? true) ? nil : hint
    }

    func setPassword(_ password: String, hint: String, for phone: String) async throws {
        await latency()
        guard let user = fetchUser(phone: phone) else { throw AuthError.unknown }
        let salt = PasswordHasher.makeSalt()
        let hash = PasswordHasher.hash(password, salt: salt)
        // хэш дополнительно зашифрован: без ключа из Keychain его не подобрать офлайн
        let sealed = vault.seal(hash, context: "users.pw|\(user.id)")
        db.run("UPDATE users SET pw_salt = ?, pw_hash_enc = ? WHERE id = ?",
               [.blob(salt), .blob(sealed), .text(user.id)])
        if hint.isEmpty {
            db.run("UPDATE users SET pw_hint_enc = NULL WHERE id = ?", [.text(user.id)])
        } else {
            db.run("UPDATE users SET pw_hint_enc = ? WHERE id = ?",
                   [.blob(vault.sealString(hint, context: "users.pwhint|\(user.id)")), .text(user.id)])
        }
        // облачная копия: после выхода или на другом устройстве пароль спросят и там
        await AccountClient.setPassword(userID: user.id, password: password, hint: hint, current: lastPassword[phone])
        lastPassword[phone] = password
    }

    func checkPassword(_ password: String, for phone: String) async throws {
        await latency()

        // сначала сервер: он знает пароль, даже если аккаунт открыт на новом устройстве
        if let user = fetchUser(phone: phone) {
            switch await AccountClient.check(userID: user.id, password: password) {
            case .ok:                       lastPassword[phone] = password; return
            case .wrong(let left):          throw AuthError.wrongPassword(attemptsLeft: left)
            case .locked(let seconds):      throw AuthError.locked(retryAfter: seconds)
            case .notEnabled, .unavailable: break
            }
        }
        try checkLocalPassword(password, for: phone)
        lastPassword[phone] = password
        // пароль был только на этом телефоне — переносим его на сервер
        if let user = fetchUser(phone: phone) {
            let hint = await passwordHint(for: phone) ?? ""
            await AccountClient.setPassword(userID: user.id, password: password, hint: hint, current: nil)
        }
    }

    private func checkLocalPassword(_ password: String, for phone: String) throws {
        let rows = db.query("SELECT id, pw_salt, pw_hash_enc FROM users WHERE phone_idx = ?",
                            [.text(phoneIndex(phone))])
        guard let row = rows.first,
              let id = row[0].string,
              let salt = row[1].data,
              let sealed = row[2].data,
              let stored = vault.open(sealed, context: "users.pw|\(id)") else { throw AuthError.unknown }

        let now = Date().timeIntervalSince1970
        var left = maxPasswordAttempts
        var lockedUntil: Double?

        if let a = db.query("SELECT attempts_left, locked_until FROM password_attempts WHERE user_id = ?",
                            [.text(id)]).first {
            left = a[0].int ?? maxPasswordAttempts
            lockedUntil = a[1].double
        }
        if let until = lockedUntil {
            if until > now { throw AuthError.locked(retryAfter: Int(until - now) + 1) }
            left = maxPasswordAttempts                       // блокировка закончилась
        }

        if Vault.constantTimeEqual(PasswordHasher.hash(password, salt: salt), stored) {
            db.run("DELETE FROM password_attempts WHERE user_id = ?", [.text(id)])
            return
        }

        left -= 1
        if left <= 0 {
            savePasswordState(userID: id, left: maxPasswordAttempts, lockedUntil: now + 300)
            throw AuthError.locked(retryAfter: 300)
        }
        savePasswordState(userID: id, left: left, lockedUntil: nil)
        throw AuthError.wrongPassword(attemptsLeft: left)
    }

    func removePassword(for phone: String) async throws {
        await latency()
        guard let user = fetchUser(phone: phone) else { throw AuthError.unknown }
        db.run("UPDATE users SET pw_salt = NULL, pw_hash_enc = NULL, pw_hint_enc = NULL WHERE id = ?", [.text(user.id)])
        db.run("DELETE FROM password_attempts WHERE user_id = ?", [.text(user.id)])
        await AccountClient.removePassword(userID: user.id, password: lastPassword[phone] ?? "")
        lastPassword[phone] = nil
    }

    // MARK: Данные аккаунта с сервера

    func pullAccount(phone: String) async {
        guard let user = fetchUser(phone: phone),
              let remote = await AccountClient.fetch(userID: user.id) else { return }
        let marker = Data("remote".utf8)
        let sealedRow = db.query("SELECT pw_hash_enc FROM users WHERE id = ?", [.text(user.id)]).first?[0].data
        let hasLocal = sealedRow != nil
        let isMarker = sealedRow.flatMap { vault.open($0, context: "users.pw|\(user.id)") } == marker

        if remote.twofa {
            // на этом устройстве пароля ещё не было: ставим пометку «пароль есть на сервере»
            if !hasLocal {
                db.run("UPDATE users SET pw_salt = NULL, pw_hash_enc = ? WHERE id = ?",
                       [.blob(vault.seal(marker, context: "users.pw|\(user.id)")), .text(user.id)])
            }
            if let hint = remote.hint {
                db.run("UPDATE users SET pw_hint_enc = ? WHERE id = ?",
                       [.blob(vault.sealString(hint, context: "users.pwhint|\(user.id)")), .text(user.id)])
            }
        } else if isMarker {
            // пароль сняли на другом устройстве
            db.run("UPDATE users SET pw_salt = NULL, pw_hash_enc = NULL, pw_hint_enc = NULL WHERE id = ?", [.text(user.id)])
        }

        if let email = remote.email, user.email == nil, Validator.isValidEmail(email) {
            db.run("INSERT OR IGNORE INTO emails(email_idx, user_id, email_enc, verified_at) VALUES (?, ?, ?, ?)",
                   [.text(emailIndex(email)), .text(user.id),
                    .blob(vault.sealString(email, context: "emails.email|\(user.id)")),
                    .real(Date().timeIntervalSince1970)])
        }
        if let object = remote.settings, let s = AccountClient.settings(from: object) {
            db.run("""
                INSERT INTO user_settings(user_id, language, dark_theme, accent, autoplay, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(user_id) DO UPDATE SET
                    language = excluded.language, dark_theme = excluded.dark_theme,
                    accent = excluded.accent, autoplay = excluded.autoplay, updated_at = excluded.updated_at
                """, [.text(user.id), .text(s.language), .integer(s.isDark ? 1 : 0),
                      .integer(s.accent), .integer(s.autoplay ? 1 : 0), .real(Date().timeIntervalSince1970)])
        }
    }

    func deleteAccount(phone: String) async {
        await latency()
        guard let user = fetchUser(phone: phone) else { return }
        db.transaction {
            // почта, настройки и попытки входа удаляются каскадом
            return db.run("DELETE FROM users WHERE id = ?", [.text(user.id)])
        }
    }

    func resetDatabase() async {
        db.exec("""
            DELETE FROM users;
            DELETE FROM verification_codes;
            DELETE FROM send_log;
            """)
    }

    // MARK: Служебное

    private func phoneIndex(_ phone: String) -> String {
        vault.blindIndex(phone, context: "users.phone")
    }

    private func emailIndex(_ email: String) -> String {
        vault.blindIndex(email, context: "emails.email")
    }

    private func fetchUser(phone: String) -> UserRecord? {
        fetchUser(whereClause: "u.phone_idx = ?", [.text(phoneIndex(phone))])
    }

    private func fetchUser(whereClause: String, _ params: [SQLValue]) -> UserRecord? {
        let rows = db.query("""
            SELECT u.id, u.phone_enc, u.name_enc, u.pw_hash_enc IS NOT NULL, u.created_at, e.email_enc
            FROM users u LEFT JOIN emails e ON e.user_id = u.id
            WHERE \(whereClause)
            """, params)
        guard let r = rows.first,
              let id = r[0].string,
              let phoneData = r[1].data,
              let phone = vault.openString(phoneData, context: "users.phone|\(id)") else { return nil }

        let name = r[2].data.flatMap { vault.openString($0, context: "users.name|\(id)") }
        let email = r[5].data.flatMap { vault.openString($0, context: "emails.email|\(id)") }
        return UserRecord(id: id, phone: phone, name: name, email: email,
                          hasTwoFactor: (r[3].int ?? 0) == 1,
                          createdAt: Date(timeIntervalSince1970: r[4].double ?? 0))
    }

    private func savePasswordState(userID: String, left: Int, lockedUntil: Double?) {
        db.run("""
            INSERT INTO password_attempts(user_id, attempts_left, locked_until) VALUES (?, ?, ?)
            ON CONFLICT(user_id) DO UPDATE SET
                attempts_left = excluded.attempts_left,
                locked_until = excluded.locked_until
            """, [.text(userID), .integer(left), lockedUntil.map { SQLValue.real($0) } ?? .null])
    }

    private func latency() async {
        try? await Task.sleep(nanoseconds: 400_000_000)      // имитация сети
    }
}
