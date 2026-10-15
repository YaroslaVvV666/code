import Foundation

/// Открытие базы: путь, защита файлов iOS, миграции схемы.
enum Database {
    /// Единственное соединение с базой на всё приложение
    static let shared: SQLiteDB = makeConnection()

    private static func makeConnection() -> SQLiteDB {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = support.appendingPathComponent("Orbita", isDirectory: true)

        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // файлы базы недоступны, пока телефон заблокирован
        try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: dir.path)
        // и не попадают в резервные копии iCloud / iTunes
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)

        removeLegacyPlaintextDatabase(in: support)

        let db = SQLiteDB(path: dir.appendingPathComponent("orbita.sqlite").path)
        Migrations.run(on: db)
        return db
    }

    /// Старые версии хранили данные открытым текстом — удаляем эти файлы
    private static func removeLegacyPlaintextDatabase(in directory: URL) {
        for name in ["orbit.sqlite", "orbit.sqlite-wal", "orbit.sqlite-shm"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

/// Версионируемые миграции: новая версия схемы = новый элемент массива.
enum Migrations {
    static let steps: [String] = [schemaV1, schemaV2, schemaV3]

    static func run(on db: SQLiteDB) {
        let current = db.query("PRAGMA user_version").first?.first?.int ?? 0
        for (index, sql) in steps.enumerated() where index + 1 > current {
            db.exec("BEGIN")
            if db.exec(sql) {
                db.exec("PRAGMA user_version = \(index + 1)")
                db.exec("COMMIT")
            } else {
                db.exec("ROLLBACK")
                print("SQLite: миграция \(index + 1) не удалась")
                break
            }
        }
    }

    // Все персональные поля — BLOB с AES-GCM (…_enc), поиск — по слепому индексу (…_idx)
    private static let schemaV1 = """
    CREATE TABLE languages(
        code TEXT PRIMARY KEY, name TEXT NOT NULL, native_name TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1);
    INSERT OR IGNORE INTO languages(code, name, native_name) VALUES ('ru', 'Russian', 'Русский');
    INSERT OR IGNORE INTO languages(code, name, native_name) VALUES ('en', 'English', 'English');

    CREATE TABLE users(
        id TEXT PRIMARY KEY,
        phone_idx TEXT NOT NULL UNIQUE,
        phone_enc BLOB NOT NULL,
        name_enc BLOB,
        pw_salt BLOB,
        pw_hash_enc BLOB,
        created_at REAL NOT NULL);

    CREATE TABLE emails(
        email_idx TEXT PRIMARY KEY,
        user_id TEXT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
        email_enc BLOB NOT NULL,
        verified_at REAL NOT NULL);

    CREATE TABLE user_settings(
        user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        language TEXT NOT NULL REFERENCES languages(code),
        dark_theme INTEGER NOT NULL DEFAULT 1,
        updated_at REAL NOT NULL);

    CREATE TABLE verification_codes(
        id TEXT PRIMARY KEY, channel TEXT NOT NULL, code_mac TEXT NOT NULL,
        expires_at REAL NOT NULL, attempts_left INTEGER NOT NULL);

    CREATE TABLE send_log(
        id INTEGER PRIMARY KEY AUTOINCREMENT, key_idx TEXT NOT NULL, sent_at REAL NOT NULL);
    CREATE INDEX idx_send_log ON send_log(key_idx, sent_at);

    CREATE TABLE password_attempts(
        user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        attempts_left INTEGER NOT NULL, locked_until REAL);

    CREATE TABLE posts(
        id TEXT PRIMARY KEY,
        author_id TEXT NOT NULL,
        author_name_enc BLOB NOT NULL,
        body_enc BLOB NOT NULL,
        image_kind TEXT NOT NULL DEFAULT 'none',
        image_enc BLOB,
        created_at REAL NOT NULL,
        likes_seed INTEGER NOT NULL DEFAULT 0,
        is_demo INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX idx_posts_created ON posts(created_at DESC);

    CREATE TABLE post_likes(
        post_id TEXT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
        user_id TEXT NOT NULL,
        PRIMARY KEY(post_id, user_id));

    CREATE TABLE comments(
        id TEXT PRIMARY KEY,
        post_id TEXT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
        author_id TEXT NOT NULL,
        author_name_enc BLOB NOT NULL,
        body_enc BLOB NOT NULL,
        created_at REAL NOT NULL);
    CREATE INDEX idx_comments_post ON comments(post_id, created_at);
    """

    // v3: подсказка к двухфакторному паролю (зашифрована)
    private static let schemaV3 = """
    ALTER TABLE users ADD COLUMN pw_hint_enc BLOB;
    """

    // v2: публикации переехали на сервер; в настройках появились акцент и автовоспроизведение
    private static let schemaV2 = """
    DROP TABLE IF EXISTS comments;
    DROP TABLE IF EXISTS post_likes;
    DROP TABLE IF EXISTS posts;
    ALTER TABLE user_settings ADD COLUMN accent INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE user_settings ADD COLUMN autoplay INTEGER NOT NULL DEFAULT 1;
    """
}
