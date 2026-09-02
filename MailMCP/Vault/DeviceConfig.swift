import CommonCrypto
import Foundation

struct DeviceConfig: Codable, Sendable {
    var vaultPath: String
    var lastWrittenGeneration: Int
    var lastWrittenHash: String
}

enum DeviceConfigStore {
    static var url: URL {
        Paths.applicationSupport.appendingPathComponent("device-config.json")
    }

    static func load() -> DeviceConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONCoders.decoder.decode(DeviceConfig.self, from: data)
    }

    static func save(_ config: DeviceConfig) throws {
        try FileManager.default.createDirectory(at: Paths.applicationSupport, withIntermediateDirectories: true)
        try JSONCoders.encoder.encode(config).write(to: url, options: .atomic)
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

    static func vaultURL(syncFolder: String?) -> URL {
        if let syncFolder, !syncFolder.isEmpty {
            return URL(fileURLWithPath: syncFolder, isDirectory: true)
                .appendingPathComponent("MailMCP.vault")
        }
        if let stored = DeviceConfigStore.load()?.vaultPath, !stored.isEmpty {
            return URL(fileURLWithPath: stored)
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
}
