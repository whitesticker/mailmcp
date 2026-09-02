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

    init(vaultURL: URL = Paths.vaultURL(syncFolder: nil)) {
        self.vaultURL = vaultURL
    }

    func vaultExists(at url: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (url ?? vaultURL).path)
    }

    func create(passphrase: String, at url: URL? = nil) throws {
        let url = url ?? vaultURL
        if FileManager.default.fileExists(atPath: url.path) {
            throw MailMCPError.vaultExists
        }
        let salt = try VaultCrypto.randomBytes(VaultCrypto.saltByteCount)
        let key = try VaultCrypto.deriveKey(passphrase: passphrase, salt: salt)
        var payload = VaultPayload.empty()
        payload.generation = 1
        try write(payload: payload, key: key, salt: salt, iterations: VaultCrypto.iterations, to: url)
        self.payload = payload
        self.key = key
        self.salt = salt
        self.iterations = VaultCrypto.iterations
        self.vaultURL = url
        KeychainWrap.storeKey(VaultCrypto.keyRawBytes(key))
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
        self.payload = payload
        self.key = key
        self.salt = salt
        self.iterations = envelope.iterations
        self.vaultURL = url
        self.lastWrittenHash = FileHash.sha256Hex(fileData)
        try persistDeviceConfig()
        KeychainWrap.storeKey(VaultCrypto.keyRawBytes(key))
    }

    func unlockFromKeychain(at url: URL? = nil) throws {
        let url = url ?? vaultURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MailMCPError.vaultNotFound
        }
        guard let raw = KeychainWrap.loadKey() else {
            throw MailMCPError.vaultLocked
        }
        let key = VaultCrypto.key(from: raw)
        let fileData = try Data(contentsOf: url)
        let envelope = try VaultFile.decodeEnvelope(fileData)
        guard let salt = Data(base64Encoded: envelope.salt) else {
            throw MailMCPError.crypto("invalid salt")
        }
        let payload = try VaultFile.unpack(fileData: fileData, key: key)
        self.payload = payload
        self.key = key
        self.salt = salt
        self.iterations = envelope.iterations
        self.vaultURL = url
        self.lastWrittenHash = FileHash.sha256Hex(fileData)
        try persistDeviceConfig()
    }

    func lock() {
        payload = nil
        key = nil
        salt = nil
    }

    func forgetDeviceKey() throws {
        KeychainWrap.deleteKey()
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
        KeychainWrap.storeKey(VaultCrypto.keyRawBytes(key))
    }

    func export(to url: URL) throws {
        guard FileManager.default.fileExists(atPath: vaultURL.path) else {
            throw MailMCPError.vaultNotFound
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.copyItem(at: vaultURL, to: url)
    }

    func importVault(from url: URL, passphrase: String, destination: URL? = nil) throws {
        let dest = destination ?? Paths.defaultVaultURL
        let data = try Data(contentsOf: url)
        let envelope = try VaultFile.decodeEnvelope(data)
        guard let salt = Data(base64Encoded: envelope.salt) else {
            throw MailMCPError.crypto("invalid salt")
        }
        let key = try VaultCrypto.deriveKey(passphrase: passphrase, salt: salt, iterations: envelope.iterations)
        let payload = try VaultFile.unpack(fileData: data, key: key)
        if dest != url {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try data.write(to: dest, options: .atomic)
        }
        self.payload = payload
        self.key = key
        self.salt = salt
        self.iterations = envelope.iterations
        self.vaultURL = dest
        self.lastWrittenHash = FileHash.sha256Hex(data)
        try persistDeviceConfig()
        KeychainWrap.storeKey(VaultCrypto.keyRawBytes(key))
    }

    func adoptSyncFolder(_ folder: URL) throws {
        guard let payload, let key, let salt else {
            throw MailMCPError.vaultLocked
        }
        let dest = folder.appendingPathComponent("MailMCP.vault")
        if dest != vaultURL {
            try write(payload: payload, key: key, salt: salt, iterations: iterations, to: dest)
            self.vaultURL = dest
        }
        try mutate { $0.settings.syncFolderPath = folder.path }
    }

    func reloadFromDiskIfChanged() throws -> VaultReloadResult {
        guard let key else { throw MailMCPError.vaultLocked }
        guard FileManager.default.fileExists(atPath: vaultURL.path) else {
            return .missing
        }
        let fileData = try Data(contentsOf: vaultURL)
        let hash = FileHash.sha256Hex(fileData)
        if hash == lastWrittenHash {
            return .unchanged
        }
        let envelope = try VaultFile.decodeEnvelope(fileData)
        let incoming = try VaultFile.unpack(fileData: fileData, key: key)
        if let current = payload, incoming.generation < current.generation {
            return .conflict(local: current.generation, remote: incoming.generation)
        }
        payload = incoming
        lastWrittenHash = hash
        try persistDeviceConfig()
        return .reloaded(incoming.generation)
    }

    private func write(payload: VaultPayload, key: SymmetricKey, salt: Data, iterations: UInt32, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try VaultFile.pack(payload: payload, key: key, salt: salt, iterations: iterations)
        try data.write(to: url, options: .atomic)
        lastWrittenHash = FileHash.sha256Hex(data)
        vaultURL = url
        try persistDeviceConfig()
    }

    private func persistDeviceConfig() throws {
        try DeviceConfigStore.save(
            DeviceConfig(
                vaultPath: vaultURL.path,
                lastWrittenGeneration: payload?.generation ?? 0,
                lastWrittenHash: lastWrittenHash
            )
        )
    }
}

enum VaultReloadResult: Equatable {
    case unchanged
    case reloaded(Int)
    case missing
    case conflict(local: Int, remote: Int)
}
