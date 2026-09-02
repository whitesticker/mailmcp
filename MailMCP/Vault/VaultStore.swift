import CryptoKit
import Foundation

final class VaultStore: @unchecked Sendable {
    private(set) var payload: VaultPayload?
    private(set) var key: SymmetricKey?
    private(set) var salt: Data?
    private(set) var iterations: UInt32 = VaultCrypto.iterations
    private(set) var vaultURL: URL
    private(set) var lastWrittenHash: String = ""

    var isUnlocked: Bool { payload != nil && key != nil }
    var vaultID: UUID? { payload?.vaultID }

    init(vaultURL: URL = Paths.vaultURL(syncFolder: nil)) {
        self.vaultURL = vaultURL
    }

    func vaultExists(at url: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (url ?? vaultURL).path)
    }

    func create(passphrase: String, name: String = "Personal", vaultID: UUID = UUID(), at url: URL? = nil) throws {
        let url = url ?? vaultURL
        if FileManager.default.fileExists(atPath: url.path) {
            throw MailMCPError.vaultExists
        }
        let salt = try VaultCrypto.randomBytes(VaultCrypto.saltByteCount)
        let key = try VaultCrypto.deriveKey(passphrase: passphrase, salt: salt)
        let payload = VaultPayload.empty(name: name, id: vaultID)
        try write(payload: payload, key: key, salt: salt, iterations: VaultCrypto.iterations, to: url)
        self.payload = payload
        self.key = key
        self.salt = salt
        self.iterations = VaultCrypto.iterations
        self.vaultURL = url
        purgeDeviceKey(vaultID: payload.vaultID)
    }

    func unlock(passphrase: String, at url: URL? = nil) throws {
        let url = url ?? vaultURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MailMCPError.vaultNotFound
        }
        let fileData = try Data(contentsOf: url)
        let envelope = try VaultFile.decodeEnvelope(fileData)
        guard let salt = Data(base64Encoded: envelope.salt) else {
            throw MailMCPError.crypto("invalid salt")
        }
        let key = try VaultCrypto.deriveKey(passphrase: passphrase, salt: salt, iterations: envelope.iterations)
        let payload = try VaultFile.unpack(fileData: fileData, key: key)
        adopt(payload: payload, key: key, salt: salt, iterations: envelope.iterations, url: url, hash: FileHash.sha256Hex(fileData))
        purgeDeviceKey()
    }

    func lock() {
        payload = nil
        key = nil
        salt = nil
    }

    func forgetDeviceKey() throws {
        if let vaultID, vaultID != VaultPayload.unsignedID {
            KeychainWrap.deleteKey(vaultID: vaultID)
        }
        KeychainWrap.deleteLegacyKey()
        lock()
    }

    func save() throws {
        guard let payload, let key, let salt else {
            throw MailMCPError.vaultLocked
        }
        try write(payload: payload, key: key, salt: salt, iterations: iterations, to: vaultURL)
    }

    func mutate(_ body: (inout VaultPayload) -> Void) throws {
        guard var payload, let key, let salt else {
            throw MailMCPError.vaultLocked
        }
        body(&payload)
        payload.generation += 1
        try write(payload: payload, key: key, salt: salt, iterations: iterations, to: vaultURL)
        self.payload = payload
    }

    func replacePayload(_ payload: VaultPayload) throws {
        guard let key, let salt else {
            throw MailMCPError.vaultLocked
        }
        try write(payload: payload, key: key, salt: salt, iterations: iterations, to: vaultURL)
        self.payload = payload
    }

    func reloadFromLocalFile() throws {
        guard let key else { throw MailMCPError.vaultLocked }
        let fileData = try Data(contentsOf: vaultURL)
        let envelope = try VaultFile.decodeEnvelope(fileData)
        guard let salt = Data(base64Encoded: envelope.salt) else {
            throw MailMCPError.crypto("invalid salt")
        }
        let payload = try VaultFile.unpack(fileData: fileData, key: key)
        adopt(payload: payload, key: key, salt: salt, iterations: envelope.iterations, url: vaultURL, hash: FileHash.sha256Hex(fileData))
    }

    func ensureIdentity(defaultID: UUID, defaultName: String) throws {
        guard var payload, let key, let salt else {
            throw MailMCPError.vaultLocked
        }
        var changed = false
        if payload.vaultID == VaultPayload.unsignedID {
            payload.vaultID = defaultID
            changed = true
        }
        if payload.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload.name = defaultName
            changed = true
        }
        if changed {
            try write(payload: payload, key: key, salt: salt, iterations: iterations, to: vaultURL)
            self.payload = payload
            purgeDeviceKey()
        }
    }

    func changePassphrase(current: String, next: String) throws {
        try unlock(passphrase: current, at: vaultURL)
        guard let payload else { throw MailMCPError.vaultLocked }
        let salt = try VaultCrypto.randomBytes(VaultCrypto.saltByteCount)
        let key = try VaultCrypto.deriveKey(passphrase: next, salt: salt)
        var nextPayload = payload
        nextPayload.generation += 1
        try write(payload: nextPayload, key: key, salt: salt, iterations: VaultCrypto.iterations, to: vaultURL)
        self.payload = nextPayload
        self.key = key
        self.salt = salt
        self.iterations = VaultCrypto.iterations
        purgeDeviceKey()
    }

    func export(to url: URL) throws {
        guard FileManager.default.fileExists(atPath: vaultURL.path) else {
            throw MailMCPError.vaultNotFound
        }
        try VaultSync.copyAtomically(from: vaultURL, to: url)
    }

    func unpackFile(at url: URL, passphrase: String) throws -> VaultPayload {
        let data = try Data(contentsOf: url)
        let envelope = try VaultFile.decodeEnvelope(data)
        guard let salt = Data(base64Encoded: envelope.salt) else {
            throw MailMCPError.crypto("invalid salt")
        }
        let key = try VaultCrypto.deriveKey(passphrase: passphrase, salt: salt, iterations: envelope.iterations)
        return try VaultFile.unpack(fileData: data, key: key)
    }

    func unpackReplica(at url: URL) throws -> VaultPayload {
        guard let key else { throw MailMCPError.vaultLocked }
        let data = try Data(contentsOf: url)
        return try VaultFile.unpack(fileData: data, key: key)
    }

    func adoptOpened(payload: VaultPayload, key: SymmetricKey, salt: Data, iterations: UInt32, url: URL, hash: String) {
        adopt(payload: payload, key: key, salt: salt, iterations: iterations, url: url, hash: hash)
        purgeDeviceKey()
    }

    private func adopt(payload: VaultPayload, key: SymmetricKey, salt: Data, iterations: UInt32, url: URL, hash: String) {
        self.payload = payload
        self.key = key
        self.salt = salt
        self.iterations = iterations
        self.vaultURL = url
        self.lastWrittenHash = hash
    }

    private func purgeDeviceKey(vaultID: UUID? = nil) {
        let id = vaultID ?? self.vaultID
        if let id, id != VaultPayload.unsignedID {
            KeychainWrap.deleteKey(vaultID: id)
        }
        KeychainWrap.deleteLegacyKey()
    }

    private func write(payload: VaultPayload, key: SymmetricKey, salt: Data, iterations: UInt32, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try VaultFile.pack(payload: payload, key: key, salt: salt, iterations: iterations)
        try data.write(to: url, options: .atomic)
        lastWrittenHash = FileHash.sha256Hex(data)
        vaultURL = url
    }
}
