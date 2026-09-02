import CommonCrypto
import Foundation

struct DeviceConfig: Codable, Sendable {
    var vaultPath: String
    var lastWrittenGeneration: Int
    var lastWrittenHash: String
}

struct VaultDescriptor: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var localPath: String
    var syncPath: String?
    var lastSyncedHash: String
    var lastSyncAt: Date?
    var lastSyncStatus: String

    var localURL: URL { URL(fileURLWithPath: localPath) }

    var replicaURL: URL? {
        guard let syncPath, !syncPath.isEmpty else { return nil }
        return URL(fileURLWithPath: syncPath, isDirectory: true).appendingPathComponent("MailMCP.vault")
    }
}

struct VaultRegistry: Codable, Sendable {
    var vaults: [VaultDescriptor]
    var activeID: UUID?
    var mcpExposure: MCPExposure
    var keepRunningOnCommandQ: Bool

    static let empty = VaultRegistry(vaults: [], activeID: nil, mcpExposure: .activeOnly, keepRunningOnCommandQ: true)

    enum CodingKeys: String, CodingKey {
        case vaults, activeID, mcpExposure, keepRunningOnCommandQ
    }

    init(vaults: [VaultDescriptor], activeID: UUID?, mcpExposure: MCPExposure, keepRunningOnCommandQ: Bool = true) {
        self.vaults = vaults
        self.activeID = activeID
        self.mcpExposure = mcpExposure
        self.keepRunningOnCommandQ = keepRunningOnCommandQ
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vaults = try container.decode([VaultDescriptor].self, forKey: .vaults)
        activeID = try container.decodeIfPresent(UUID.self, forKey: .activeID)
        mcpExposure = try container.decodeIfPresent(MCPExposure.self, forKey: .mcpExposure) ?? .activeOnly
        keepRunningOnCommandQ = try container.decodeIfPresent(Bool.self, forKey: .keepRunningOnCommandQ) ?? true
    }

    var active: VaultDescriptor? {
        if let activeID, let match = vaults.first(where: { $0.id == activeID }) {
            return match
        }
        return vaults.first
    }

    mutating func upsert(_ descriptor: VaultDescriptor) {
        if let index = vaults.firstIndex(where: { $0.id == descriptor.id }) {
            vaults[index] = descriptor
        } else {
            vaults.append(descriptor)
        }
        if activeID == nil {
            activeID = descriptor.id
        }
    }

    mutating func replaceID(_ oldID: UUID, with newID: UUID) {
        if let index = vaults.firstIndex(where: { $0.id == oldID }) {
            vaults[index].id = newID
        }
        if activeID == oldID {
            activeID = newID
        }
    }

    func descriptor(id: UUID) -> VaultDescriptor? {
        vaults.first(where: { $0.id == id })
    }
}

enum VaultRegistryStore {
    static var url: URL {
        Paths.applicationSupport.appendingPathComponent("device-config.json")
    }

    static func load() -> VaultRegistry {
        if let data = try? Data(contentsOf: url) {
            if let registry = decodeRegistry(data) {
                return registry
            }
            if let legacy = try? JSONCoders.decoder.decode(DeviceConfig.self, from: data) {
                let migrated = migrateLegacy(legacy)
                try? save(migrated)
                return migrated
            }
        }
        let bootstrapped = bootstrapFromDefaultFile()
        if !bootstrapped.vaults.isEmpty {
            try? save(bootstrapped)
        }
        return bootstrapped
    }

    static func save(_ registry: VaultRegistry) throws {
        try FileManager.default.createDirectory(at: Paths.applicationSupport, withIntermediateDirectories: true)
        try JSONCoders.encoder.encode(registry).write(to: url, options: .atomic)
    }

    static func decodeRegistry(_ data: Data) -> VaultRegistry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["vaults"] != nil else {
            return nil
        }
        return try? JSONCoders.decoder.decode(VaultRegistry.self, from: data)
    }

    static func migrateLegacy(_ config: DeviceConfig) -> VaultRegistry {
        let id = UUID()
        let localPath = config.vaultPath
        let syncPath: String?
        if config.vaultPath == Paths.defaultVaultURL.path
            || config.vaultPath.hasPrefix(Paths.applicationSupport.path) {
            syncPath = nil
        } else {
            syncPath = URL(fileURLWithPath: config.vaultPath).deletingLastPathComponent().path
        }
        let descriptor = VaultDescriptor(
            id: id,
            name: "Personal",
            localPath: localPath,
            syncPath: syncPath,
            lastSyncedHash: config.lastWrittenHash,
            lastSyncAt: nil,
            lastSyncStatus: "Migrated from a single-vault setup."
        )
        return VaultRegistry(vaults: [descriptor], activeID: id, mcpExposure: .activeOnly, keepRunningOnCommandQ: true)
    }

    static func bootstrapFromDefaultFile() -> VaultRegistry {
        let url = Paths.defaultVaultURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        let id = UUID()
        let descriptor = VaultDescriptor(
            id: id,
            name: "Personal",
            localPath: url.path,
            syncPath: nil,
            lastSyncedHash: "",
            lastSyncAt: nil,
            lastSyncStatus: ""
        )
        return VaultRegistry(vaults: [descriptor], activeID: id, mcpExposure: .activeOnly, keepRunningOnCommandQ: true)
    }
}

enum DeviceConfigStore {
    static var url: URL { VaultRegistryStore.url }

    static func load() -> DeviceConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONCoders.decoder.decode(DeviceConfig.self, from: data)
    }

    static func save(_ config: DeviceConfig) throws {
        try VaultRegistryStore.save(VaultRegistryStore.migrateLegacy(config))
    }
}

enum Paths {
    static var applicationSupport: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MailMCP", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var defaultVaultURL: URL {
        applicationSupport.appendingPathComponent("MailMCP.vault")
    }

    static var pendingSendsURL: URL {
        applicationSupport.appendingPathComponent("pending-sends.json")
    }

    static var mcpSocket: URL {
        applicationSupport.appendingPathComponent("mcp.sock")
    }

    static var pendingIMAPImportURL: URL {
        applicationSupport.appendingPathComponent("pending-imap-import-path")
    }

    static func localVaultURL(id: UUID) -> URL {
        applicationSupport
            .appendingPathComponent("vaults", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("MailMCP.vault")
    }

    static func vaultURL(syncFolder: String?) -> URL {
        if let syncFolder, !syncFolder.isEmpty {
            return URL(fileURLWithPath: syncFolder, isDirectory: true)
                .appendingPathComponent("MailMCP.vault")
        }
        if let active = VaultRegistryStore.load().active {
            return active.localURL
        }
        return defaultVaultURL
    }
}

enum FileHash {
    static func sha256Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(fileAt url: URL) throws -> String {
        sha256Hex(try Data(contentsOf: url))
    }
}
