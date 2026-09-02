import CryptoKit
import Foundation

struct VaultEnvelope: Codable, Sendable {
    var version: Int
    var kdf: String
    var iterations: UInt32
    var salt: String
    var box: String
    var generation: Int
}

enum VaultFile {
    static func encodeEnvelope(_ envelope: VaultEnvelope) throws -> Data {
        try JSONCoders.encoder.encode(envelope)
    }

    static func decodeEnvelope(_ data: Data) throws -> VaultEnvelope {
        try JSONCoders.decoder.decode(VaultEnvelope.self, from: data)
    }

    static func pack(payload: VaultPayload, key: SymmetricKey, salt: Data, iterations: UInt32) throws -> Data {
        let plaintext = try JSONCoders.encoder.encode(payload)
        let box = try VaultCrypto.seal(plaintext: plaintext, key: key)
        let envelope = VaultEnvelope(
            version: 1,
            kdf: VaultCrypto.kdfName,
            iterations: iterations,
            salt: salt.base64EncodedString(),
            box: box.base64EncodedString(),
            generation: payload.generation
        )
        return try encodeEnvelope(envelope)
    }

    static func unpack(fileData: Data, key: SymmetricKey) throws -> VaultPayload {
        let envelope = try decodeEnvelope(fileData)
        guard let box = Data(base64Encoded: envelope.box) else {
            throw MailMCPError.crypto("invalid vault box")
        }
        let plaintext = try VaultCrypto.open(combined: box, key: key)
        return try JSONCoders.decoder.decode(VaultPayload.self, from: plaintext)
    }

    static func envelopeGeneration(of fileData: Data) -> Int? {
        try? decodeEnvelope(fileData).generation
    }
}
