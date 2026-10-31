import Foundation
import Security
import CryptoKit

/// Обёртка над системной связкой ключей iOS (Keychain).
/// Ключи шифрования лежат только здесь — в самой базе их нет.
enum Keychain {
    private static let service = "app.orbita.secrets"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> (status: OSStatus, data: Data?) {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, status == errSecSuccess ? item as? Data : nil)
    }

    @discardableResult
    static func write(_ data: Data, account: String) -> Bool {
        SecItemDelete(baseQuery(account) as CFDictionary)
        var attrs = baseQuery(account)
        attrs[kSecValueData as String] = data
        // только на этом устройстве, только пока оно разблокировано, не попадает в резервные копии
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    /// Имена всех сохранённых записей, начинающихся с `prefix`
    static func accounts(withPrefix prefix: String) -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]] else { return [] }
        return list.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }
    }

    static func string(_ account: String) -> String? {
        read(account).data.flatMap { String(data: $0, encoding: .utf8) }
    }

    static func setString(_ value: String, account: String) {
        write(Data(value.utf8), account: account)
    }

    /// 256-битный ключ: читаем из Keychain или создаём при первом запуске.
    /// Если Keychain временно недоступен (например, устройство заблокировано),
    /// сохранённый ключ НЕ перезаписываем — иначе данные станут нечитаемыми.
    static func symmetricKey(account: String) -> SymmetricKey {
        let result = read(account)
        if let data = result.data { return SymmetricKey(data: data) }
        if result.status == errSecItemNotFound {
            let key = SymmetricKey(size: .bits256)
            write(key.withUnsafeBytes { Data($0) }, account: account)
            return key
        }
        return SymmetricKey(size: .bits256)
    }
}
