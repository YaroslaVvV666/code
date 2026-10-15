import Foundation
import CryptoKit

/// Шифрование данных перед записью в базу.
///
/// • AES-256-GCM: шифрует и защищает от подмены. В «контекст» (AAD) входит
///   название поля и id записи, поэтому зашифрованное значение нельзя
///   перенести в другую строку или колонку.
/// • Слепой индекс (HMAC-SHA256): позволяет искать запись по номеру или почте,
///   не храня их в открытом виде.
/// • Два разных ключа: для данных и для индексов. Оба лежат в Keychain.
final class Vault: @unchecked Sendable {
    static let shared = Vault()

    private let dataKey: SymmetricKey
    private let indexKey: SymmetricKey

    init(dataKey: SymmetricKey = Keychain.symmetricKey(account: "orbita.key.data.v1"),
         indexKey: SymmetricKey = Keychain.symmetricKey(account: "orbita.key.index.v1")) {
        self.dataKey = dataKey
        self.indexKey = indexKey
    }

    func seal(_ data: Data, context: String) -> Data {
        let box = try? AES.GCM.seal(data, using: dataKey, authenticating: Data(context.utf8))
        return box?.combined ?? Data()
    }

    func open(_ sealed: Data, context: String) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: dataKey, authenticating: Data(context.utf8))
    }

    func sealString(_ string: String, context: String) -> Data {
        seal(Data(string.utf8), context: context)
    }

    func openString(_ sealed: Data, context: String) -> String? {
        open(sealed, context: context).flatMap { String(data: $0, encoding: .utf8) }
    }

    func blindIndex(_ value: String, context: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data((context + "|" + value).utf8), using: indexKey)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        let x = Array(a), y = Array(b)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
