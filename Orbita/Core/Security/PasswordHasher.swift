import Foundation
import Security
import CommonCrypto

/// Хэширование паролей: PBKDF2-HMAC-SHA256, 600 000 итераций, случайная соль.
/// (На боевом сервере лучше Argon2id, но PBKDF2 — штатное средство iOS.)
enum PasswordHasher {
    static let iterations: UInt32 = 600_000

    static func makeSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    static func hash(_ password: String, salt: Data) -> Data {
        var derived = [UInt8](repeating: 0, count: 32)
        let saltBytes = [UInt8](salt)
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 password, password.utf8.count,
                                 saltBytes, saltBytes.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                 iterations,
                                 &derived, derived.count)
        return Data(derived)
    }
}
