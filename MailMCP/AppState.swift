import AppKit
import Foundation
import SwiftUI

struct VaultMergeSession: Identifiable {
    var id = UUID()
    var vaultID: UUID
    var incomingURL: URL?
    var incomingPayload: VaultPayload
    var preview: VaultMergePreview
    var isReplicaConflict: Bool
    var accountChoices: [String: MergeChoice]
    var settingsChoice: MergeChoice
}

struct UnlockedVaultSummary: Identifiable {
    var id: UUID
    var name: String
    var accounts: [MailAccount]
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isUnlocked = false
    @Published var accounts: [MailAccount] = []
    @Published var settings: AppSettings = .default
    @Published var vaultURL: URL = Paths.defaultVaultURL
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var pendingSends: [PendingSend] = []
    @Published var conflictMessage: String?
    @Published var lastMCPInstallPath: String?
    @Published var registry = VaultRegistry.empty
    @Published var pendingMerge: VaultMergeSession?
    @Published var lastSyncStatus: String = ""

    private var stores: [UUID: VaultStore] = [:]
    private var watchers: [UUID: VaultSyncWatcher] = [:]
    private var didAttemptKeychainUnlock = false
    private var syncDebounce: Task<Void, Never>?

    var vaultExists: Bool {
        !registry.vaults.isEmpty || FileManager.default.fileExists(atPath: Paths.defaultVaultURL.path)
    }

    var activeVaultID: UUID? { registry.activeID ?? registry.vaults.first?.id }

    var activeStore: VaultStore? {
        guard let activeVaultID else { return nil }
        return stores[activeVaultID]
    }

    var activeName: String {
        registry.active?.name ?? activeStore?.payload?.name ?? "Vault"
    }

    var mcpExposure: MCPExposure {
        registry.mcpExposure
    }

    func setMCPExposure(_ value: MCPExposure) {
        registry.mcpExposure = value
        persistRegistry()
        publishAccounts()
    }

    func settings(for account: MailAccount) -> AppSettings {
        if let store = try? storeOwning(accountID: account.id), let payload = store.payload {
            return payload.settings
        }
        return settings
    }

    var showsAllUnlockedVaults: Bool { mcpExposure == .allUnlocked }

    var unlockedVaults: [UnlockedVaultSummary] {
        registry.vaults.compactMap { descriptor in
            guard let payload = stores[descriptor.id]?.payload else { return nil }
            return UnlockedVaultSummary(id: descriptor.id, name: payload.name, accounts: payload.accounts)
        }
    }

    init() {
        registry = VaultRegistryStore.load()
        vaultURL = registry.active?.localURL ?? Paths.defaultVaultURL
        pendingSends = PendingSendStore.load()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        if vaultExists {
            tryKeychainUnlock()
        }
    }

    func tryKeychainUnlock() {
        guard !didAttemptKeychainUnlock else { return }
        didAttemptKeychainUnlock = true
        guard let descriptor = registry.active ?? registry.vaults.first else { return }
        do {
            try unlockDescriptor(descriptor, fromKeychain: true)
        } catch {
            isUnlocked = false
        }
    }

    func retryKeychainUnlock() {
        didAttemptKeychainUnlock = false
        tryKeychainUnlock()
    }

    func createVault(passphrase: String, name: String = "Personal") throws {
        let id = UUID()
        let url = Paths.localVaultURL(id: id)
        let store = VaultStore(vaultURL: url)
        try store.create(passphrase: passphrase, name: name, vaultID: id, at: url)
        stores[id] = store
        registry.upsert(
            VaultDescriptor(
                id: id,
                name: name,
                localPath: url.path,
                syncPath: nil,
                lastSyncedHash: store.lastWrittenHash,
                lastSyncAt: nil,
                lastSyncStatus: ""
            )
        )
        registry.activeID = id
        persistRegistry()
        applyUnlockedState()
    }

    func unlock(passphrase: String, vaultID: UUID? = nil) throws {
        let descriptor: VaultDescriptor
        if let vaultID, let match = registry.descriptor(id: vaultID) {
            descriptor = match
        } else if let active = registry.active {
            descriptor = active
        } else if FileManager.default.fileExists(atPath: Paths.defaultVaultURL.path) {
            try importVault(from: Paths.defaultVaultURL, passphrase: passphrase)
            return
        } else {
            throw MailMCPError.vaultNotFound
        }
        try unlockDescriptor(descriptor, passphrase: passphrase)
    }

    func importVault(from url: URL, passphrase: String) throws {
        if let existing = registry.vaults.first(where: { $0.localPath == url.path }) {
            try unlockDescriptor(existing, passphrase: passphrase)
            return
        }
        let data = try Data(contentsOf: url)
        let envelope = try VaultFile.decodeEnvelope(data)
        guard let salt = Data(base64Encoded: envelope.salt) else {
            throw MailMCPError.crypto("invalid salt")
        }
        let key = try VaultCrypto.deriveKey(passphrase: passphrase, salt: salt, iterations: envelope.iterations)
        var payload = try VaultFile.unpack(fileData: data, key: key)
        if payload.vaultID == VaultPayload.unsignedID {
            payload.vaultID = UUID()
        }
        let dest = Paths.localVaultURL(id: payload.vaultID)
        let store = VaultStore(vaultURL: dest)
        if FileManager.default.fileExists(atPath: dest.path), dest.standardizedFileURL != url.standardizedFileURL {
            try store.unlock(passphrase: passphrase, at: dest)
        } else {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if dest.standardizedFileURL != url.standardizedFileURL {
                try VaultSync.copyAtomically(from: url, to: dest)
            }
            try store.unlock(passphrase: passphrase, at: dest)
        }
        try store.ensureIdentity(defaultID: payload.vaultID, defaultName: payload.name)
        let id = store.payload?.vaultID ?? payload.vaultID
        stores[id] = store
        registry.upsert(
            VaultDescriptor(
                id: id,
                name: store.payload?.name ?? payload.name,
                localPath: dest.path,
                syncPath: nil,
                lastSyncedHash: store.lastWrittenHash,
                lastSyncAt: nil,
                lastSyncStatus: ""
            )
        )
        registry.activeID = id
        persistRegistry()
        applyUnlockedState()
    }

    func exportVault(to url: URL) throws {
        guard let store = activeStore else { throw MailMCPError.vaultLocked }
        try store.export(to: url)
        statusMessage = "Vault exported."
    }

    func switchActiveVault(_ id: UUID) throws {
        guard stores[id]?.isUnlocked == true else {
            throw MailMCPError.vaultLocked
        }
        registry.activeID = id
        persistRegistry()
        applyUnlockedState()
    }

    func renameActiveVault(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MailMCPError.invalidInput("Vault name cannot be empty.")
        }
        try mutateActive { $0.name = trimmed }
        if let id = activeVaultID, var descriptor = registry.descriptor(id: id) {
            descriptor.name = trimmed
            registry.upsert(descriptor)
            persistRegistry()
        }
        applyUnlockedState(preserveStatus: true)
        statusMessage = "Vault renamed."
    }

    func lockVault(_ id: UUID) {
        stores[id]?.lock()
        stores.removeValue(forKey: id)
        stopWatcher(id)
        if registry.activeID == id {
            registry.activeID = stores.keys.first
            persistRegistry()
        }
        if stores.isEmpty {
            isUnlocked = false
            accounts = []
            statusMessage = "Vault locked."
            stopAllWatchers()
        } else {
            applyUnlockedState()
            statusMessage = "Locked \(registry.descriptor(id: id)?.name ?? "vault")."
        }
    }

    func lock() {
        for id in Array(stores.keys) {
            stores[id]?.lock()
        }
        stores.removeAll()
        isUnlocked = false
        accounts = []
        statusMessage = "Vault locked."
        stopAllWatchers()
    }

    func forgetDeviceKey() throws {
        guard let store = activeStore, let id = store.vaultID else {
            throw MailMCPError.vaultLocked
        }
        try store.forgetDeviceKey()
        stores.removeValue(forKey: id)
        if stores.isEmpty {
            isUnlocked = false
            accounts = []
        } else if registry.activeID == id {
            registry.activeID = stores.keys.first
            persistRegistry()
            applyUnlockedState()
        }
        stopWatcher(id)
        statusMessage = "Forgot Keychain wrap for this Mac."
    }

    func removeVaultReference(_ id: UUID) {
        lockVault(id)
        registry.vaults.removeAll { $0.id == id }
        if registry.activeID == id {
            registry.activeID = registry.vaults.first?.id
        }
        persistRegistry()
        if stores.isEmpty {
            isUnlocked = false
            accounts = []
        } else {
            applyUnlockedState()
        }
        statusMessage = "Removed vault from this Mac. The file was not deleted."
    }

    func changePassphrase(current: String, next: String) throws {
        guard let store = activeStore else { throw MailMCPError.vaultLocked }
        try store.changePassphrase(current: current, next: next)
        statusMessage = "Passphrase updated."
    }

    func addIMAPAccount(_ account: MailAccount) throws {
        try mutateActive { payload in
            payload.accounts.removeAll { $0.email.caseInsensitiveCompare(account.email) == .orderedSame && $0.provider == .imap }
            payload.accounts.append(account)
        }
        applyUnlockedState()
    }

    func updateAccount(_ account: MailAccount) throws {
        let store = try storeOwning(accountID: account.id)
        try store.mutate { payload in
            if let index = payload.accounts.firstIndex(where: { $0.id == account.id }) {
                payload.accounts[index] = account
            }
        }
        applyUnlockedState()
    }

    func addOAuthAccount(provider: MailProviderKind, tokens: OAuthTokens, email: String) throws {
        try mutateActive { payload in
            payload.accounts.removeAll { $0.email.caseInsensitiveCompare(email) == .orderedSame && $0.provider == provider }
            payload.accounts.append(
                MailAccount(provider: provider, email: email, displayName: email, oauth: tokens)
            )
        }
        applyUnlockedState()
    }

    func updateTokens(accountID: UUID, tokens: OAuthTokens) {
        guard let store = try? storeOwning(accountID: accountID) else { return }
        try? store.mutate { payload in
            if let index = payload.accounts.firstIndex(where: { $0.id == accountID }) {
                payload.accounts[index].oauth = tokens
                payload.accounts[index].lastError = nil
            }
        }
        applyUnlockedState(preserveStatus: true)
    }

    func setAccountError(accountID: UUID, message: String?) {
        guard let store = try? storeOwning(accountID: accountID) else { return }
        try? store.mutate { payload in
            if let index = payload.accounts.firstIndex(where: { $0.id == accountID }) {
                payload.accounts[index].lastError = message
            }
        }
        applyUnlockedState(preserveStatus: true)
    }

    func removeAccount(_ id: UUID) throws {
        let store = try storeOwning(accountID: id)
        try store.mutate { payload in
            payload.accounts.removeAll { $0.id == id }
        }
        applyUnlockedState()
    }

    func moveAccounts(in vaultID: UUID, fromOffsets: IndexSet, toOffset: Int) throws {
        guard let store = stores[vaultID], let current = store.payload?.accounts else {
            throw MailMCPError.vaultLocked
        }
        var reordered = current
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        try store.mutate { payload in
            payload.accounts = reordered
        }
        applyUnlockedState(preserveStatus: true)
    }

    func account(id: UUID) -> MailAccount? {
        unlockedVaults.flatMap(\.accounts).first { $0.id == id }
    }

    func updateSettings(_ body: (inout AppSettings) -> Void) throws {
        try mutateActive { payload in
            body(&payload.settings)
        }
        applyUnlockedState(preserveStatus: true)
        startWatchers()
    }

    func setSyncFolder(_ url: URL) throws {
        guard let id = activeVaultID, let store = activeStore else {
            throw MailMCPError.vaultLocked
        }
        try mutateActive { payload in
            payload.settings.syncFolderPath = url.path
        }
        var descriptor = registry.descriptor(id: id) ?? VaultDescriptor(
            id: id,
            name: store.payload?.name ?? "Personal",
            localPath: store.vaultURL.path,
            syncPath: url.path,
            lastSyncedHash: "",
            lastSyncAt: nil,
            lastSyncStatus: ""
        )
        descriptor.syncPath = url.path
        registry.upsert(descriptor)
        persistRegistry()
        applyUnlockedState()
        startWatchers()
        try syncNow(vaultID: id)
        statusMessage = "Vault will sync from \(url.path)"
    }

    @discardableResult
    func syncNow(vaultID: UUID? = nil) throws -> VaultSyncResult {
        let id = vaultID ?? activeVaultID
        guard let id, let store = stores[id], store.isUnlocked else {
            throw MailMCPError.vaultLocked
        }
        guard var descriptor = registry.descriptor(id: id) else {
            throw MailMCPError.vaultNotFound
        }
        let folder = descriptor.syncPath ?? store.payload?.settings.syncFolderPath
        guard let folder, !folder.isEmpty else {
            let result = VaultSyncResult(
                outcome: .noReplica,
                localHash: store.lastWrittenHash,
                replicaHash: "",
                message: "Choose an iCloud Drive, Dropbox, or sync folder first."
            )
            lastSyncStatus = result.message
            descriptor.lastSyncStatus = result.message
            registry.upsert(descriptor)
            persistRegistry()
            return result
        }
        let replica = descriptor.replicaURL
            ?? URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("MailMCP.vault")

        let result = try VaultSync.reconcile(
            localURL: store.vaultURL,
            replicaURL: replica,
            lastSyncedHash: descriptor.lastSyncedHash
        )
        switch result.outcome {
        case .pushed, .unchanged:
            descriptor.lastSyncedHash = result.localHash
            descriptor.lastSyncAt = Date()
            descriptor.lastSyncStatus = result.message
        case .pulled:
            try store.reloadFromLocalFile()
            descriptor.lastSyncedHash = result.replicaHash
            descriptor.lastSyncAt = Date()
            descriptor.lastSyncStatus = result.message
        case .conflict:
            let incoming = try store.unpackReplica(at: replica)
            if let current = store.payload, VaultMerge.preview(current: current, incoming: incoming).isNoOp {
                if incoming.generation > current.generation {
                    try VaultSync.copyAtomically(from: replica, to: store.vaultURL)
                    try store.reloadFromLocalFile()
                    descriptor.lastSyncedHash = result.replicaHash
                    descriptor.lastSyncStatus = "Kept the newer identical vault copy."
                } else {
                    try VaultSync.copyAtomically(from: store.vaultURL, to: replica)
                    descriptor.lastSyncedHash = result.localHash
                    descriptor.lastSyncStatus = "Replaced the older identical vault copy."
                }
                descriptor.lastSyncAt = Date()
                lastSyncStatus = descriptor.lastSyncStatus
            } else {
                presentMerge(store: store, incoming: incoming, incomingURL: replica, isReplicaConflict: true)
                descriptor.lastSyncStatus = result.message
            }
        case .noReplica:
            descriptor.lastSyncStatus = result.message
        }
        registry.upsert(descriptor)
        persistRegistry()
        lastSyncStatus = result.message
        if result.outcome == .pulled {
            applyUnlockedState(preserveStatus: true)
        }
        statusMessage = result.message
        return result
    }

    func prepareMerge(from url: URL, passphrase: String) throws {
        guard let store = activeStore else {
            throw MailMCPError.vaultLocked
        }
        let incoming = try store.unpackFile(at: url, passphrase: passphrase)
        presentMerge(store: store, incoming: incoming, incomingURL: url, isReplicaConflict: false)
    }

    func applyPendingMerge() throws {
        guard let session = pendingMerge,
              let store = stores[session.vaultID],
              let current = store.payload else {
            throw MailMCPError.vaultLocked
        }
        let merged = VaultMerge.apply(
            current: current,
            incoming: session.incomingPayload,
            accountChoices: session.accountChoices,
            settingsChoice: session.settingsChoice
        )
        try store.replacePayload(merged)
        if var descriptor = registry.descriptor(id: session.vaultID) {
            descriptor.name = merged.name
            if session.isReplicaConflict, let replica = descriptor.replicaURL {
                try VaultSync.copyAtomically(from: store.vaultURL, to: replica)
                descriptor.lastSyncedHash = store.lastWrittenHash
                descriptor.lastSyncAt = Date()
                descriptor.lastSyncStatus = "Merged both copies."
                lastSyncStatus = descriptor.lastSyncStatus
            }
            registry.upsert(descriptor)
            persistRegistry()
        }
        pendingMerge = nil
        applyUnlockedState()
        statusMessage = "Merged vault."
    }

    func cancelMerge() {
        pendingMerge = nil
    }

    func updateMergeChoice(accountKey: String, choice: MergeChoice) {
        guard var session = pendingMerge else { return }
        session.accountChoices[accountKey] = choice
        pendingMerge = session
    }

    func updateMergeSettingsChoice(_ choice: MergeChoice) {
        guard var session = pendingMerge else { return }
        session.settingsChoice = choice
        pendingMerge = session
    }

    func handleExternalReload(vaultID: UUID) {
        syncDebounce?.cancel()
        syncDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            do {
                _ = try syncNow(vaultID: vaultID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func provider(for account: MailAccount) throws -> any MailProviding {
        try MailProviderFactory.make(account: account) { [weak self] tokens in
            self?.updateTokens(accountID: account.id, tokens: tokens)
        }
    }

    func resolveAccount(idOrEmail: String?) throws -> MailAccount {
        try ExposedAccountResolver.resolve(idOrEmail: idOrEmail, accounts: exposedAccounts())
    }

    func vaultName(for account: MailAccount) -> String {
        for summary in unlockedVaults where summary.accounts.contains(where: { $0.id == account.id }) {
            return summary.name
        }
        return activeName
    }

    func vaultID(for account: MailAccount) -> UUID? {
        for summary in unlockedVaults where summary.accounts.contains(where: { $0.id == account.id }) {
            return summary.id
        }
        return activeVaultID
    }

    func enqueueSend(_ pending: PendingSend) {
        pendingSends.append(pending)
        PendingSendStore.save(pendingSends)
    }

    func removePending(id: UUID) {
        pendingSends.removeAll { $0.id == id }
        PendingSendStore.save(pendingSends)
    }

    func confirmPendingSend(_ pending: PendingSend) async throws -> String {
        let account = try resolveAccount(idOrEmail: pending.accountID.uuidString)
        try assertSafety(.send, for: account)
        let mail = try provider(for: account)
        let result = try await mail.send(
            to: pending.to,
            cc: pending.cc,
            bcc: pending.bcc,
            subject: pending.subject,
            body: pending.body,
            extraHeaders: pending.extraHeaders
        )
        removePending(id: pending.id)
        return result
    }

    func assertSafety(_ required: SafetyMode, for account: MailAccount? = nil) throws {
        let mode: SafetyMode
        if let account, let store = try? storeOwning(accountID: account.id) {
            mode = store.payload?.settings.safetyMode ?? .readOnly
        } else {
            mode = activeStore?.payload?.settings.safetyMode ?? .readOnly
        }
        switch required {
        case .readOnly:
            return
        case .drafts:
            guard mode.allowsOrganize else {
                throw MailMCPError.safetyDenied("MailMCP is in read-only mode. Allow drafts/organize in Settings.")
            }
        case .send:
            guard mode.allowsSend else {
                throw MailMCPError.safetyDenied("Sending is disabled. Set safety mode to “Read + drafts + send” in Settings.")
            }
        }
    }

    func installCursorMCP() throws {
        try installMCP(for: .cursor)
    }

    func installMCP(for client: MCPClientKind) throws {
        let path = try MCPClientInstaller.install(client)
        lastMCPInstallPath = path
        statusMessage = "Installed MailMCP for \(client.title) → \(path)"
    }

    func setTool(_ name: String, enabled: Bool) throws {
        try setTools([name], enabled: enabled)
    }

    func setTools(_ names: [String], enabled: Bool) throws {
        try updateSettings { settings in
            var disabled = Set(settings.disabledTools)
            for name in names {
                if enabled {
                    disabled.remove(name)
                } else {
                    disabled.insert(name)
                }
            }
            settings.disabledTools = disabled.sorted()
        }
        ToolGateStore.save(settings.disabledTools)
    }

    private func unlockDescriptor(_ descriptor: VaultDescriptor, passphrase: String? = nil, fromKeychain: Bool = false) throws {
        let store = stores[descriptor.id] ?? VaultStore(vaultURL: descriptor.localURL)
        if fromKeychain {
            try store.unlockFromKeychain(expectedID: descriptor.id, at: descriptor.localURL)
        } else if let passphrase {
            try store.unlock(passphrase: passphrase, at: descriptor.localURL)
        } else {
            throw MailMCPError.vaultLocked
        }
        try store.ensureIdentity(defaultID: descriptor.id, defaultName: descriptor.name)
        var updated = descriptor
        if let payload = store.payload {
            if payload.vaultID != descriptor.id {
                stores.removeValue(forKey: descriptor.id)
                registry.replaceID(descriptor.id, with: payload.vaultID)
                updated.id = payload.vaultID
            }
            updated.name = payload.name
            updated.localPath = store.vaultURL.path
            if updated.syncPath == nil {
                updated.syncPath = payload.settings.syncFolderPath
            }
        }
        stores[updated.id] = store
        registry.upsert(updated)
        registry.activeID = updated.id
        persistRegistry()
        applyUnlockedState()
    }

    private func presentMerge(store: VaultStore, incoming: VaultPayload, incomingURL: URL, isReplicaConflict: Bool) {
        guard let current = store.payload, let id = store.vaultID else { return }
        let preview = VaultMerge.preview(current: current, incoming: incoming)
        var choices: [String: MergeChoice] = [:]
        for conflict in preview.conflicts {
            choices[conflict.key] = .current
        }
        pendingMerge = VaultMergeSession(
            vaultID: id,
            incomingURL: incomingURL,
            incomingPayload: incoming,
            preview: preview,
            isReplicaConflict: isReplicaConflict,
            accountChoices: choices,
            settingsChoice: .current
        )
        if preview.isNoOp {
            statusMessage = "The incoming vault already matches this one."
        }
    }

    private func mutateActive(_ body: (inout VaultPayload) -> Void) throws {
        guard let store = activeStore else { throw MailMCPError.vaultLocked }
        try store.mutate(body)
        if let id = store.vaultID, var descriptor = registry.descriptor(id: id) {
            descriptor.name = store.payload?.name ?? descriptor.name
            registry.upsert(descriptor)
            persistRegistry()
        }
    }

    private func storeOwning(accountID: UUID) throws -> VaultStore {
        for store in stores.values {
            if store.payload?.accounts.contains(where: { $0.id == accountID }) == true {
                return store
            }
        }
        throw MailMCPError.accountNotFound
    }

    private func exposedAccounts() -> [MailAccount] {
        if showsAllUnlockedVaults {
            return unlockedVaults.flatMap(\.accounts)
        }
        return activeStore?.payload?.accounts ?? []
    }

    private func applyUnlockedState(preserveStatus: Bool = false) {
        guard let store = activeStore, store.isUnlocked else {
            isUnlocked = !stores.isEmpty
            publishAccounts()
            return
        }
        isUnlocked = true
        settings = store.payload?.settings ?? .default
        ToolGateStore.save(settings.disabledTools)
        vaultURL = store.vaultURL
        publishAccounts()
        if !preserveStatus {
            statusMessage = "Unlocked — \(accounts.count) account\(accounts.count == 1 ? "" : "s")"
        }
        startWatchers()
    }

    private func publishAccounts() {
        accounts = exposedAccounts()
    }

    private func persistRegistry() {
        try? VaultRegistryStore.save(registry)
    }

    private func startWatchers() {
        stopAllWatchers()
        for descriptor in registry.vaults {
            guard stores[descriptor.id]?.isUnlocked == true,
                  let replica = descriptor.replicaURL else { continue }
            let id = descriptor.id
            let watcher = VaultSyncWatcher(url: replica) { [weak self] in
                Task { @MainActor in
                    self?.handleExternalReload(vaultID: id)
                }
            }
            watcher.start()
            watchers[id] = watcher
        }
    }

    private func stopWatcher(_ id: UUID) {
        watchers[id]?.stop()
        watchers.removeValue(forKey: id)
    }

    private func stopAllWatchers() {
        for watcher in watchers.values {
            watcher.stop()
        }
        watchers.removeAll()
    }
}

enum PendingSendStore {
    static func load() -> [PendingSend] {
        guard let data = try? Data(contentsOf: Paths.pendingSendsURL) else { return [] }
        return (try? JSONCoders.decoder.decode([PendingSend].self, from: data)) ?? []
    }

    static func save(_ items: [PendingSend]) {
        try? JSONCoders.encoder.encode(items).write(to: Paths.pendingSendsURL, options: .atomic)
    }
}
