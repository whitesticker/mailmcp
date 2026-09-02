import Foundation

enum VaultSyncOutcome: String, Equatable, Sendable {
    case noReplica
    case unchanged
    case pushed
    case pulled
    case conflict
}

struct VaultSyncResult: Equatable, Sendable {
    var outcome: VaultSyncOutcome
    var localHash: String
    var replicaHash: String
    var message: String
}

enum VaultSync {
    static func reconcile(localURL: URL, replicaURL: URL, lastSyncedHash: String) throws -> VaultSyncResult {
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw MailMCPError.vaultNotFound
        }
        let localHash = try FileHash.sha256Hex(fileAt: localURL)
        let replicaExists = FileManager.default.fileExists(atPath: replicaURL.path)

        if !replicaExists {
            try copyAtomically(from: localURL, to: replicaURL)
            return VaultSyncResult(
                outcome: .pushed,
                localHash: localHash,
                replicaHash: localHash,
                message: "Copied the vault into the sync folder."
            )
        }

        let replicaHash = try FileHash.sha256Hex(fileAt: replicaURL)
        if localHash == replicaHash {
            return VaultSyncResult(
                outcome: .unchanged,
                localHash: localHash,
                replicaHash: replicaHash,
                message: "Local vault and sync folder copy already match."
            )
        }

        let last = lastSyncedHash
        let localChanged = !last.isEmpty && localHash != last
        let replicaChanged = !last.isEmpty && replicaHash != last

        if last.isEmpty {
            return VaultSyncResult(
                outcome: .conflict,
                localHash: localHash,
                replicaHash: replicaHash,
                message: "Local vault and sync folder copy both exist and differ. Review the merge preview."
            )
        }
        if localChanged && replicaChanged {
            return VaultSyncResult(
                outcome: .conflict,
                localHash: localHash,
                replicaHash: replicaHash,
                message: "Both copies changed since the last sync. Review the merge preview."
            )
        }
        if localChanged && !replicaChanged {
            try copyAtomically(from: localURL, to: replicaURL)
            return VaultSyncResult(
                outcome: .pushed,
                localHash: localHash,
                replicaHash: localHash,
                message: "Pushed local changes to the sync folder."
            )
        }
        if replicaChanged && !localChanged {
            try copyAtomically(from: replicaURL, to: localURL)
            return VaultSyncResult(
                outcome: .pulled,
                localHash: replicaHash,
                replicaHash: replicaHash,
                message: "Pulled changes from the sync folder."
            )
        }

        return VaultSyncResult(
            outcome: .unchanged,
            localHash: localHash,
            replicaHash: replicaHash,
            message: "Nothing to sync."
        )
    }

    static func copyAtomically(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        if FileManager.default.fileExists(atPath: temp.path) {
            try FileManager.default.removeItem(at: temp)
        }
        try FileManager.default.copyItem(at: source, to: temp)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
    }
}
