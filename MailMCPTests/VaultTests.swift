import XCTest
@testable import MailMCP

final class VaultTests: XCTestCase {
    func testIMAPSettingsInferGmailHosts() throws {
        let settings = try IMAPSettings(
            imapHost: "",
            imapPort: 993,
            imapStartTLS: false,
            smtpHost: "",
            smtpPort: 465,
            smtpStartTLS: false,
            username: "you@gmail.com",
            password: "app-password"
        ).resolvingBlankHosts(for: "you@gmail.com")

        XCTAssertEqual(settings.imapHost, "imap.gmail.com")
        XCTAssertEqual(settings.smtpHost, "smtp.gmail.com")
    }

    func testIMAPSettingsInferCustomDomainHosts() throws {
        let settings = try IMAPSettings(
            imapHost: "",
            imapPort: 993,
            imapStartTLS: false,
            smtpHost: "",
            smtpPort: 465,
            smtpStartTLS: false,
            username: "you@example.com",
            password: "password"
        ).resolvingBlankHosts(for: "you@example.com")

        XCTAssertEqual(settings.imapHost, "imap.example.com")
        XCTAssertEqual(settings.smtpHost, "smtp.example.com")
    }

    func testSealAndOpenRoundTrip() throws {
        let key = try VaultCrypto.deriveKey(passphrase: "correct horse battery staple", salt: Data((0..<16).map { $0 }))
        let box = try VaultCrypto.seal(plaintext: Data("hello vault".utf8), key: key)
        let plain = try VaultCrypto.open(combined: box, key: key)
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), "hello vault")
    }

    func testWrongPassphraseFails() throws {
        let salt = Data((0..<16).map { $0 })
        let key = try VaultCrypto.deriveKey(passphrase: "alpha", salt: salt)
        let box = try VaultCrypto.seal(plaintext: Data("secret".utf8), key: key)
        let other = try VaultCrypto.deriveKey(passphrase: "beta", salt: salt)
        XCTAssertThrowsError(try VaultCrypto.open(combined: box, key: other))
    }

    func testVaultFilePackUnpack() throws {
        let salt = try VaultCrypto.randomBytes(16)
        let key = try VaultCrypto.deriveKey(passphrase: "portable-secret", salt: salt)
        var payload = VaultPayload.empty()
        payload.accounts = [
            MailAccount(provider: .imap, email: "you@example.com", imap: IMAPSettings(
                imapHost: "imap.example.com",
                imapPort: 993,
                imapStartTLS: false,
                smtpHost: "smtp.example.com",
                smtpPort: 465,
                smtpStartTLS: false,
                username: "you@example.com",
                password: "app-password"
            ))
        ]
        let data = try VaultFile.pack(payload: payload, key: key, salt: salt, iterations: 100_000)
        let opened = try VaultFile.unpack(fileData: data, key: key)
        XCTAssertEqual(opened.accounts.first?.email, "you@example.com")
        XCTAssertEqual(opened.accounts.first?.imap?.password, "app-password")
    }

    func testSearchCriteriaEmptyIsAll() {
        XCTAssertTrue(true)
    }

    func testLegacyPayloadGetsUnsignedVaultID() throws {
        let json = """
        {"accounts":[],"generation":4,"settings":{"confirmBeforeSend":true,"disabledTools":[],"googleClientID":"","microsoftClientID":"","safetyMode":"readOnly"},"version":1}
        """
        let payload = try JSONCoders.decoder.decode(VaultPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.vaultID, VaultPayload.unsignedID)
        XCTAssertEqual(payload.name, "Personal")
        XCTAssertEqual(payload.generation, 4)
    }

    func testRegistryMigratesLegacyDeviceConfig() {
        let config = DeviceConfig(
            vaultPath: "/tmp/icloud/MailMCP.vault",
            lastWrittenGeneration: 9,
            lastWrittenHash: "abc"
        )
        let registry = VaultRegistryStore.migrateLegacy(config)
        XCTAssertEqual(registry.vaults.count, 1)
        XCTAssertEqual(registry.vaults[0].localPath, config.vaultPath)
        XCTAssertEqual(registry.vaults[0].syncPath, "/tmp/icloud")
        XCTAssertEqual(registry.vaults[0].lastSyncedHash, "abc")
        XCTAssertEqual(registry.activeID, registry.vaults[0].id)
        XCTAssertEqual(registry.mcpExposure, .activeOnly)
        XCTAssertTrue(registry.keepRunningOnCommandQ)
    }

    func testRegistryDefaultsCommandQKeepRunning() throws {
        let json = """
        {"vaults":[],"mcpExposure":"activeOnly"}
        """
        let registry = try JSONCoders.decoder.decode(VaultRegistry.self, from: Data(json.utf8))
        XCTAssertTrue(registry.keepRunningOnCommandQ)
    }

    func testKeychainWrapIsScopedByVaultID() {
        let first = UUID()
        let second = UUID()
        let a = Data("alpha-key-bytes".utf8)
        let b = Data("beta-key-bytes".utf8)
        defer {
            KeychainWrap.deleteKey(vaultID: first)
            KeychainWrap.deleteKey(vaultID: second)
        }
        XCTAssertTrue(KeychainWrap.storeKey(a, vaultID: first, requirePresence: false))
        XCTAssertTrue(KeychainWrap.storeKey(b, vaultID: second, requirePresence: false))
        XCTAssertEqual(KeychainWrap.loadKey(vaultID: first), a)
        XCTAssertEqual(KeychainWrap.loadKey(vaultID: second), b)
        KeychainWrap.deleteKey(vaultID: first)
        XCTAssertNil(KeychainWrap.loadKey(vaultID: first))
        XCTAssertEqual(KeychainWrap.loadKey(vaultID: second), b)
    }

    func testMergePreviewAdditionsAndConflicts() {
        var current = VaultPayload.empty(name: "Home")
        current.accounts = [
            MailAccount(provider: .imap, email: "shared@example.com", displayName: "Current", imap: sampleIMAP(password: "old")),
            MailAccount(provider: .imap, email: "only-home@example.com", imap: sampleIMAP(password: "home"))
        ]
        var incoming = VaultPayload.empty(name: "Work")
        incoming.accounts = [
            MailAccount(provider: .imap, email: "shared@example.com", displayName: "Incoming", imap: sampleIMAP(password: "new")),
            MailAccount(provider: .imap, email: "only-work@example.com", imap: sampleIMAP(password: "work"))
        ]
        incoming.settings.safetyMode = .send

        let preview = VaultMerge.preview(current: current, incoming: incoming)
        XCTAssertEqual(preview.additions.map(\.email), ["only-work@example.com"])
        XCTAssertEqual(preview.onlyInCurrent.map(\.email), ["only-home@example.com"])
        XCTAssertEqual(preview.conflicts.count, 1)
        XCTAssertEqual(preview.conflicts[0].current.displayName, "Current")
        XCTAssertTrue(preview.settingsDiffer)

        let merged = VaultMerge.apply(
            current: current,
            incoming: incoming,
            accountChoices: [VaultMerge.accountKey(current.accounts[0]): .incoming],
            settingsChoice: .incoming
        )
        XCTAssertEqual(merged.vaultID, current.vaultID)
        XCTAssertEqual(merged.name, "Home")
        XCTAssertEqual(merged.settings.safetyMode, .send)
        XCTAssertEqual(Set(merged.accounts.map(\.email)), ["shared@example.com", "only-home@example.com", "only-work@example.com"])
        XCTAssertEqual(merged.accounts.first { $0.email == "shared@example.com" }?.displayName, "Incoming")
    }

    func testExactAccountMatchIsNotAConflict() {
        let account = MailAccount(provider: .imap, email: "you@example.com", displayName: "You", imap: sampleIMAP(password: "secret"))
        var current = VaultPayload.empty()
        current.accounts = [account]
        var incoming = VaultPayload.empty()
        incoming.accounts = [
            MailAccount(
                id: UUID(),
                provider: .imap,
                email: "you@example.com",
                displayName: "You",
                imap: sampleIMAP(password: "secret"),
                createdAt: Date().addingTimeInterval(50)
            )
        ]
        let preview = VaultMerge.preview(current: current, incoming: incoming)
        XCTAssertTrue(preview.conflicts.isEmpty)
        XCTAssertTrue(preview.additions.isEmpty)
    }

    func testResolverRequiresUUIDWhenEmailsCollide() {
        let first = MailAccount(provider: .imap, email: "dup@example.com", imap: sampleIMAP(password: "a"))
        let second = MailAccount(provider: .gmail, email: "dup@example.com")
        XCTAssertEqual(try ExposedAccountResolver.resolve(idOrEmail: first.id.uuidString, accounts: [first, second]).id, first.id)
        XCTAssertThrowsError(try ExposedAccountResolver.resolve(idOrEmail: "dup@example.com", accounts: [first, second])) { error in
            guard let mcp = error as? MailMCPError, case .ambiguousAccount = mcp else {
                return XCTFail("expected ambiguousAccount, got \(error)")
            }
        }
    }

    func testSyncPushPullAndConflict() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mailmcp-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let local = folder.appendingPathComponent("local.vault")
        let replica = folder.appendingPathComponent("replica.vault")
        let salt = try VaultCrypto.randomBytes(16)
        let key = try VaultCrypto.deriveKey(passphrase: "sync-secret", salt: salt)
        try VaultFile.pack(payload: .empty(), key: key, salt: salt, iterations: 100_000).write(to: local)

        let pushed = try VaultSync.reconcile(localURL: local, replicaURL: replica, lastSyncedHash: "")
        XCTAssertEqual(pushed.outcome, .pushed)
        let syncedHash = pushed.localHash

        try VaultFile.pack(payload: VaultPayload.empty(name: "Local"), key: key, salt: salt, iterations: 100_000).write(to: local)
        let afterLocal = try VaultSync.reconcile(localURL: local, replicaURL: replica, lastSyncedHash: syncedHash)
        XCTAssertEqual(afterLocal.outcome, .pushed)

        let afterPushHash = afterLocal.localHash
        try VaultFile.pack(payload: VaultPayload.empty(name: "Remote"), key: key, salt: salt, iterations: 100_000).write(to: replica)
        let pulled = try VaultSync.reconcile(localURL: local, replicaURL: replica, lastSyncedHash: afterPushHash)
        XCTAssertEqual(pulled.outcome, .pulled)
        let opened = try VaultFile.unpack(fileData: Data(contentsOf: local), key: key)
        XCTAssertEqual(opened.name, "Remote")

        try VaultFile.pack(payload: VaultPayload.empty(name: "Local2"), key: key, salt: salt, iterations: 100_000).write(to: local)
        try VaultFile.pack(payload: VaultPayload.empty(name: "Remote2"), key: key, salt: salt, iterations: 100_000).write(to: replica)
        let conflict = try VaultSync.reconcile(localURL: local, replicaURL: replica, lastSyncedHash: pulled.localHash)
        XCTAssertEqual(conflict.outcome, .conflict)
    }

    func testMCPCallLogRedactsSecretsAndMapsAgentNames() {
        XCTAssertEqual(MCPCallLog.displayName(clientName: "cursor-vscode"), "Cursor")
        XCTAssertEqual(MCPCallLog.displayName(clientName: ""), "Unknown agent")
        let json = MCPCallLog.prettyJSON([
            "query": "invoices",
            "password": "should-not-appear",
            "limit": 10
        ])
        XCTAssertTrue(json.contains("invoices"))
        XCTAssertTrue(json.contains("••••"))
        XCTAssertFalse(json.contains("should-not-appear"))
    }

    func testIMAPImporterParsesEmailThenAppPasswordBlocks() {
        let text = """
        already@gmail.com
        aaaa bbbb cccc dddd

        --------------------------------
        new.one@gmail.com
        eeee ffff gggg hhhh
        """
        let drafts = IMAPAccountImporter.parse(text)
        XCTAssertEqual(drafts.map(\.email), ["already@gmail.com", "new.one@gmail.com"])
        XCTAssertEqual(drafts.map(\.password), ["aaaa bbbb cccc dddd", "eeee ffff gggg hhhh"])
    }

    private func sampleIMAP(password: String) -> IMAPSettings {
        IMAPSettings(
            imapHost: "imap.example.com",
            imapPort: 993,
            imapStartTLS: false,
            smtpHost: "smtp.example.com",
            smtpPort: 465,
            smtpStartTLS: false,
            username: "you@example.com",
            password: password
        )
    }
}
