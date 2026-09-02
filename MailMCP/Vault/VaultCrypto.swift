import CommonCrypto
import CryptoKit
import Foundation
import Security

enum VaultCrypto {
    static let kdfName = "pbkdf2-sha256"
    static let iterations: UInt32 = 310_000
    static let keyByteCount = 32
    static let saltByteCount = 16

    static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, count, buf.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw MailMCPError.crypto("random generation failed")
        }
        return data
    }

    static func deriveKey(passphrase: String, salt: Data, iterations: UInt32 = iterations) throws -> SymmetricKey {
        let password = Data(passphrase.utf8)
        var derived = Data(count: keyByteCount)
        let result = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                password.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyByteCount
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            throw MailMCPError.crypto("PBKDF2 failed (\(result))")
        }
        return SymmetricKey(data: derived)
    }

    static func seal(plaintext: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else {
            throw MailMCPError.crypto("AES-GCM seal produced no combined box")
        }
        return combined
    }

    static func open(combined: Data, key: SymmetricKey) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw MailMCPError.wrongPassphrase
        }
    }

    static func keyRawBytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    static func key(from raw: Data) -> SymmetricKey {
        SymmetricKey(data: raw)
    }
}
