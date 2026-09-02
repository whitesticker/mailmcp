import AppKit
import Foundation
import SwiftUI

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

    let store = VaultStore()
    private var syncWatcher: VaultSyncWatcher?
    private var didAttemptKeychainUnlock = false

    var vaultExists: Bool { store.vaultExists() }

    init() {
        vaultURL = store.vaultURL
        pendingSends = PendingSendStore.load()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        if store.vaultExists() {
            tryKeychainUnlock()
        }
    }

    func tryKeychainUnlock() {
        guard !didAttemptKeychainUnlock else { return }
        didAttemptKeychainUnlock = true
        do {
            try store.unlockFromKeychain()
            applyUnlockedState()
        } catch {
            isUnlocked = false
        }
    }

    func retryKeychainUnlock() {
        didAttemptKeychainUnlock = false
        tryKeychainUnlock()
    }

    func createVault(passphrase: String) throws {
        try store.create(passphrase: passphrase)
        applyUnlockedState()
    }

    func unlock(passphrase: String) throws {
        try store.unlock(passphrase: passphrase)
        applyUnlockedState()
    }

    func importVault(from url: URL, passphrase: String) throws {
        try store.importVault(from: url, passphrase: passphrase)
        applyUnlockedState()
    }

    func exportVault(to url: URL) throws {
        try store.export(to: url)
        statusMessage = "Vault exported."
    }

    func lock() {
        store.lock()
        isUnlocked = false
        accounts = []
        statusMessage = "Vault locked."
        stopWatcher()
    }

    func forgetDeviceKey() throws {
        try store.forgetDeviceKey()
        isUnlocked = false
        accounts = []
        stopWatcher()
    }

    func changePassphrase(current: String, next: String) throws {
        try store.changePassphrase(current: current, next: next)
        statusMessage = "Passphrase updated."
    }

    func addIMAPAccount(_ account: MailAccount) throws {
        try store.mutate { payload in
            payload.accounts.removeAll { $0.email.caseInsensitiveCompare(account.email) == .orderedSame && $0.provider == .imap }
            payload.accounts.append(account)
        }
        applyUnlockedState()
    }

    func updateAccount(_ account: MailAccount) throws {
        guard accounts.contains(where: { $0.id == account.id }) else {
            throw MailMCPError.accountNotFound
        }
        try store.mutate { payload in
            if let index = payload.accounts.firstIndex(where: { $0.id == account.id }) {
                payload.accounts[index] = account
            }
        }
        applyUnlockedState()
    }

    func addOAuthAccount(provider: MailProviderKind, tokens: OAuthTokens, email: String) throws {
        try store.mutate { payload in
            payload.accounts.removeAll { $0.email.caseInsensitiveCompare(email) == .orderedSame && $0.provider == provider }
            payload.accounts.append(
                MailAccount(provider: provider, email: email, displayName: email, oauth: tokens)
            )
        }
        applyUnlockedState()
    }

    func updateTokens(accountID: UUID, tokens: OAuthTokens) {
        try? store.mutate { payload in
            if let index = payload.accounts.firstIndex(where: { $0.id == accountID }) {
                payload.accounts[index].oauth = tokens
                payload.accounts[index].lastError = nil
            }
        }
        applyUnlockedState(preserveStatus: true)
    }

    func setAccountError(accountID: UUID, message: String?) {
        try? store.mutate { payload in
            if let index = payload.accounts.firstIndex(where: { $0.id == accountID }) {
                payload.accounts[index].lastError = message
            }
        }
        applyUnlockedState(preserveStatus: true)
    }

    func removeAccount(_ id: UUID) throws {
        try store.mutate { payload in
            payload.accounts.removeAll { $0.id == id }
        }
        applyUnlockedState()
    }

    func moveAccounts(fromOffsets: IndexSet, toOffset: Int) throws {
        var reordered = accounts
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        try store.mutate { payload in
            payload.accounts = reordered
        }
        applyUnlockedState(preserveStatus: true)
    }

    func updateSettings(_ body: (inout AppSettings) -> Void) throws {
        try store.mutate { payload in
            body(&payload.settings)
        }
        applyUnlockedState(preserveStatus: true)
        startWatcherIfNeeded()
    }

    func setSyncFolder(_ url: URL) throws {
        try store.adoptSyncFolder(url)
        applyUnlockedState()
        startWatcherIfNeeded()
        statusMessage = "Vault will sync from \(url.path)"
    }

    func handleExternalReload() {
        do {
            switch try store.reloadFromDiskIfChanged() {
            case .unchanged, .missing:
                break
            case .reloaded(let generation):
                applyUnlockedState()
                statusMessage = "Vault updated from disk (generation \(generation))."
            case .conflict(let local, let remote):
                conflictMessage = "Vault conflict: this Mac is generation \(local), the file is \(remote). Export a copy before overwriting."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func provider(for account: MailAccount) throws -> any MailProviding {
        try MailProviderFactory.make(account: account) { [weak self] tokens in
            self?.updateTokens(accountID: account.id, tokens: tokens)
        }
    }

    func resolveAccount(idOrEmail: String?) throws -> MailAccount {
        guard let payload = store.payload else { throw MailMCPError.vaultLocked }
        if let idOrEmail, !idOrEmail.isEmpty {
            if let uuid = UUID(uuidString: idOrEmail),
               let account = payload.accounts.first(where: { $0.id == uuid }) {
                return account
            }
            if let account = payload.accounts.first(where: { $0.email.caseInsensitiveCompare(idOrEmail) == .orderedSame }) {
                return account
            }
            throw MailMCPError.accountNotFound
        }
        if payload.accounts.count == 1 {
            return payload.accounts[0]
        }
        throw MailMCPError.invalidInput("Pass account_id or account_email when more than one mailbox is configured.")
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
        try assertSafety(.send)
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

    func assertSafety(_ required: SafetyMode) throws {
        let mode = store.payload?.settings.safetyMode ?? .readOnly
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

    private func applyUnlockedState(preserveStatus: Bool = false) {
        guard let payload = store.payload else {
            isUnlocked = false
            return
        }
        isUnlocked = true
        accounts = payload.accounts
        settings = payload.settings
        ToolGateStore.save(payload.settings.disabledTools)
        vaultURL = store.vaultURL
        if !preserveStatus {
            statusMessage = "Unlocked — \(accounts.count) account\(accounts.count == 1 ? "" : "s")"
        }
        startWatcherIfNeeded()
    }

    private func startWatcherIfNeeded() {
        stopWatcher()
        guard let folder = store.payload?.settings.syncFolderPath, !folder.isEmpty else { return }
        syncWatcher = VaultSyncWatcher(url: store.vaultURL) { [weak self] in
            Task { @MainActor in
                self?.handleExternalReload()
            }
        }
        syncWatcher?.start()
    }

    private func stopWatcher() {
        syncWatcher?.stop()
        syncWatcher = nil
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
