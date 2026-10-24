import XCTest
@testable import MailMCP

final class MailSearchTests: XCTestCase {
    func testLocatorRoundTripForGmailSpamFolder() {
        let folder = "[Gmail]/Spam"
        let wire = MessageLocator.imap(folder: folder, uid: "99").wire
        let parsed = MessageLocator.parse(wire)
        XCTAssertEqual(parsed.imapFolder, folder)
        XCTAssertEqual(parsed.nativeID, "99")
        XCTAssertEqual(parsed.wire, wire)
    }

    func testLocatorKeepsProviderIds() {
        let parsed = MessageLocator.parse("18c2ab")
        XCTAssertEqual(parsed.wire, "18c2ab")
        XCTAssertNil(parsed.imapFolder)
    }

    func testCanonicalMailboxAliases() {
        XCTAssertEqual(MailboxRequest.parse("spam, junk, trash"), [.canonical(.spam), .canonical(.spam), .canonical(.trash)])
        XCTAssertEqual(MailboxRequest.parse(nil), [.canonical(.everywhere)])
        XCTAssertEqual(MailboxRequest.parseOne("Deleted Items"), .canonical(.trash))
    }

    func testEverywhereResolvesInboxSpamTrashAndAllMail() {
        let folders = [
            FolderHint(name: "INBOX", kind: .inbox),
            FolderHint(name: "[Gmail]/Spam", kind: .spam),
            FolderHint(name: "[Gmail]/Trash", kind: .trash),
            FolderHint(name: "[Gmail]/All Mail", kind: .all)
        ]
        let resolved = MailboxMatcher.resolve([.canonical(.everywhere)], folders: folders)
        let names = Set(resolved.map(\.name))
        XCTAssertEqual(names, ["INBOX", "[Gmail]/Spam", "[Gmail]/Trash", "[Gmail]/All Mail"])
    }

    func testMissingSpamIsReportedEmpty() {
        let resolved = MailboxMatcher.resolve([.canonical(.spam)], folders: [FolderHint(name: "INBOX", kind: .inbox)])
        XCTAssertEqual(resolved.first?.name, "")
        XCTAssertEqual(resolved.first?.requested, "spam")
    }

    func testSearchStatusDistinguishesNoMatchesFromIncomplete() {
        XCTAssertEqual(MailSearchStatus.resolve(messages: 0, accountStatuses: ["ok", "ok"], timedOut: false, cancelled: false), MailSearchStatus.noMatches)
        XCTAssertEqual(MailSearchStatus.resolve(messages: 0, accountStatuses: ["error"], timedOut: false, cancelled: false), MailSearchStatus.error)
        XCTAssertEqual(MailSearchStatus.resolve(messages: 0, accountStatuses: ["ok", "error"], timedOut: false, cancelled: false), MailSearchStatus.incomplete)
        XCTAssertEqual(MailSearchStatus.resolve(messages: 2, accountStatuses: ["ok", "error"], timedOut: false, cancelled: false), MailSearchStatus.partial)
        XCTAssertEqual(MailSearchStatus.resolve(messages: 1, accountStatuses: ["ok"], timedOut: true, cancelled: false), MailSearchStatus.partial)
        XCTAssertEqual(MailSearchStatus.resolve(messages: 0, accountStatuses: ["unsupported"], timedOut: false, cancelled: false), MailSearchStatus.unsupported)
    }

    func testQueryParsesDatesAndMailbox() {
        let parsed = MailSearchQuery.parse("in:spam after:2026-09-07 before:2026-09-10 Under Armour 38736980")
        XCTAssertEqual(parsed.mailbox, "spam")
        XCTAssertEqual(parsed.text, "Under Armour 38736980")
        XCTAssertNotNil(parsed.after)
        XCTAssertNotNil(parsed.before)
    }

    func testCursorRoundTrip() {
        let encoded = SearchCursor.encode(skip: 20)
        XCTAssertEqual(SearchCursor.decode(encoded), 20)
    }

    func testSpamOnlyReceiptIsFoundAndOpenedUnread() async throws {
        let spam = MockMailProvider()
        let trash = MockMailProvider()
        let dead = MockMailProvider()
        let accountSpam = MailAccount(provider: .imap, email: "spam@example.com")
        let accountTrash = MailAccount(provider: .imap, email: "trash@example.com")
        let accountDead = MailAccount(provider: .imap, email: "dead@example.com")

        spam.folders = [
            MailFolderCount(name: "INBOX", selectable: true),
            MailFolderCount(name: "Spam", selectable: true),
            MailFolderCount(name: "Trash", selectable: true)
        ]
        trash.folders = spam.folders
        spam.store(
            MailSummary(
                id: "local-spam",
                accountID: accountSpam.id,
                accountEmail: accountSpam.email,
                from: "Under Armour <orders@underarmour.com>",
                to: [accountSpam.email],
                subject: "Order 38736980",
                date: MailSearchQuery.parseDate("2026-09-08"),
                snippet: "Two pairs of shoes",
                isUnread: true,
                labels: [],
                mailbox: "Spam",
                mailboxKind: "spam"
            ),
            mailbox: "Spam",
            body: "Thanks for buying two pairs of shoes. Order 38736980."
        )
        trash.store(
            MailSummary(
                id: "local-trash",
                accountID: accountTrash.id,
                accountEmail: accountTrash.email,
                from: "Under Armour <orders@underarmour.com>",
                to: [accountTrash.email],
                subject: "Order 38736980 copy",
                date: MailSearchQuery.parseDate("2026-09-08"),
                snippet: "Receipt in trash",
                isUnread: true,
                labels: [],
                mailbox: "Trash",
                mailboxKind: "trash"
            ),
            mailbox: "Trash",
            body: "Deleted receipt for order 38736980."
        )
        dead.unreachable = true

        let result = await MailSearchCoordinator.run(
            accounts: [
                (accountSpam, spam),
                (accountTrash, trash),
                (accountDead, dead)
            ],
            request: MailSearchRequest(
                query: "Under Armour 38736980",
                mailbox: "everywhere",
                accountIDs: [],
                after: MailSearchQuery.parseDate("2026-09-07"),
                before: MailSearchQuery.parseDate("2026-09-10"),
                limit: 20,
                skip: 0,
                timeout: 5
            )
        )

        XCTAssertEqual(result.status, MailSearchStatus.partial)
        XCTAssertEqual(result.messages.count, 2)
        XCTAssertTrue(result.foldersSearched.contains { $0.name == "Spam" && $0.matched == 1 })
        XCTAssertTrue(result.foldersSearched.contains { $0.name == "Trash" && $0.matched == 1 })
        XCTAssertTrue(result.accounts.contains { $0.account == accountDead.email && $0.status == MailSearchStatus.error })

        let spamHit = try XCTUnwrap(result.messages.first { $0.mailboxKind == "spam" })
        let openedSpam = try await spam.getMessage(id: spamHit.id)
        XCTAssertTrue(openedSpam.body.contains("38736980"))
        XCTAssertTrue(openedSpam.isUnread)
        XCTAssertTrue(spam.preservedUnread.contains(spamHit.id))

        let trashHit = try XCTUnwrap(result.messages.first { $0.mailboxKind == "trash" })
        let openedTrash = try await trash.getMessage(id: trashHit.id)
        XCTAssertTrue(openedTrash.body.contains("38736980"))
        XCTAssertTrue(openedTrash.isUnread)
        XCTAssertEqual(MessageLocator.parse(trashHit.id).imapFolder, "Trash")
    }

    func testListFoldersSkipsCountsByDefault() async throws {
        let mail = MockMailProvider()
        mail.folders = [MailFolderCount(name: "INBOX", messages: 9, unseen: 2, selectable: true)]
        let unnamed = try await mail.listFolders(includeCounts: false)
        XCTAssertNil(unnamed.first?.messages)
        XCTAssertEqual(mail.countFetches, 0)
        let counted = try await mail.listFolders(includeCounts: true)
        XCTAssertEqual(counted.first?.messages, 9)
        XCTAssertEqual(mail.countFetches, 1)
    }

    func testSQLiteCacheCooldownAndWatermarkFlow() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailMCPCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MailboxCacheStore(directoryURL: tempDir)
        let coordinator = MailboxSyncCoordinator()
        let mock = MockMailProvider()
        let account = MailAccount(
            provider: .imap,
            email: "cached@example.com",
            syncScope: .recent,
            syncSchedule: .hourly
        )

        mock.folders = [
            MailFolderCount(name: "INBOX", messages: 2, unseen: 1, selectable: true),
            MailFolderCount(name: "Spam", messages: 0, unseen: 0, selectable: true),
            MailFolderCount(name: "Trash", messages: 0, unseen: 0, selectable: true)
        ]
        mock.currentWatermark = "imap:m=1:u=1"
        mock.store(
            MailSummary(
                id: "101",
                accountID: account.id,
                accountEmail: account.email,
                from: "Acme <billing@acme.com>",
                to: [account.email],
                subject: "Invoice 9001",
                date: MailSearchQuery.parseDate("2026-10-01"),
                snippet: "Your October invoice is ready",
                isUnread: true,
                labels: [],
                mailbox: "INBOX",
                mailboxKind: "inbox"
            ),
            mailbox: "INBOX",
            body: "Full body for Invoice 9001."
        )

        let policy = CacheSyncPolicy(
            enabled: true,
            mode: .rollingWindow,
            rollingCount: 500,
            daysBack: 90,
            cooldownSeconds: 60
        )
        let cached = CachedMailProvider(
            account: account,
            base: mock,
            policy: policy,
            store: store,
            coordinator: coordinator
        )

        // Initial sync populates SQLite and sets the 60s cooldown
        await coordinator.syncNow(account: account, provider: mock, policy: policy, store: store)
        let searchesAfterInitialSync = mock.searchCalls
        let watermarksAfterInitialSync = mock.watermarkCalls

        // 1) Search within 60s cooldown -> 0 server search calls and 0 watermark calls
        let localHits = try await cached.searchFoldered(
            FolderSearchSpec(query: "Invoice 9001", mailboxes: ["INBOX"], after: nil, before: nil, limit: 10)
        )
        XCTAssertEqual(localHits.count, 1)
        XCTAssertEqual(localHits.first?.subject, "Invoice 9001")
        XCTAssertEqual(mock.searchCalls, searchesAfterInitialSync, "Within cooldown, search must be 100% local")
        XCTAssertEqual(mock.watermarkCalls, watermarksAfterInitialSync, "Within cooldown, no watermark network call")

        // 2) Lazy body loading: first getMessage hits provider, second getMessage is served from SQLite
        let firstMsg = try await cached.getMessage(id: localHits[0].id)
        XCTAssertEqual(firstMsg.body, "Full body for Invoice 9001.")
        XCTAssertEqual(mock.getMessageCalls, 1)
        let secondMsg = try await cached.getMessage(id: localHits[0].id)
        XCTAssertEqual(secondMsg.body, "Full body for Invoice 9001.")
        XCTAssertEqual(mock.getMessageCalls, 1, "Second getMessage must be served from local SQLite cache")

        // 3) Expire cooldown, keep watermark unchanged -> 1 watermark check, 0 server search calls
        await coordinator.resetCooldown(accountID: account.id)
        store.saveAccountWatermark(
            accountID: account.id,
            watermark: "imap:m=1:u=1",
            checkedAt: Date().addingTimeInterval(-120),
            syncedAt: Date().addingTimeInterval(-120)
        )
        let hitsUnchanged = try await cached.searchFoldered(
            FolderSearchSpec(query: "Invoice", mailboxes: ["INBOX"], after: nil, before: nil, limit: 10)
        )
        XCTAssertEqual(hitsUnchanged.count, 1)
        XCTAssertEqual(mock.watermarkCalls, watermarksAfterInitialSync + 1, "Should check server watermark once")
        XCTAssertEqual(mock.searchCalls, searchesAfterInitialSync, "Watermark unchanged -> should search locally without server search")

        // 4) Expire cooldown AND simulate new message arriving on server -> watermark changes -> uses server call + re-enters cooldown
        await coordinator.resetCooldown(accountID: account.id)
        store.saveAccountWatermark(
            accountID: account.id,
            watermark: "imap:m=1:u=1",
            checkedAt: Date().addingTimeInterval(-120),
            syncedAt: Date().addingTimeInterval(-120)
        )
        mock.currentWatermark = "imap:m=2:u=2"
        mock.store(
            MailSummary(
                id: "102",
                accountID: account.id,
                accountEmail: account.email,
                from: "GitHub <noreply@github.com>",
                to: [account.email],
                subject: "Verification code 448822",
                date: MailSearchQuery.parseDate("2026-10-22"),
                snippet: "Your code is 448822",
                isUnread: true,
                labels: [],
                mailbox: "INBOX",
                mailboxKind: "inbox"
            ),
            mailbox: "INBOX",
            body: "Your verification code is 448822."
        )

        let hitsAfterNewArrival = try await cached.searchFoldered(
            FolderSearchSpec(query: "448822", mailboxes: ["INBOX"], after: nil, before: nil, limit: 10)
        )
        XCTAssertEqual(hitsAfterNewArrival.count, 1)
        XCTAssertEqual(hitsAfterNewArrival.first?.subject, "Verification code 448822")
        XCTAssertGreaterThan(mock.searchCalls, searchesAfterInitialSync, "New watermark must use server call immediately")

        // Wait for the background sync triggered by the new watermark to finish
        await coordinator.waitForInflight(accountID: account.id)

        // Subsequent search inside the new 1-minute cooldown is local again
        let searchesBeforeFollowup = mock.searchCalls
        let followupHits = try await cached.searchFoldered(
            FolderSearchSpec(query: "448822", mailboxes: ["INBOX"], after: nil, before: nil, limit: 10)
        )
        XCTAssertEqual(followupHits.count, 1)
        XCTAssertEqual(mock.searchCalls, searchesBeforeFollowup, "Follow-up search within 1-min cooldown must be local")
        store.close()
    }

    func testPerAccountFullSyncDownloadsBodiesAndTracksBandwidth() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailMCPFullSyncTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MailboxCacheStore(directoryURL: tempDir)
        let coordinator = MailboxSyncCoordinator()
        let mock = MockMailProvider()
        let account = MailAccount(
            provider: .imap,
            email: "fullsync@example.com",
            syncScope: .everything,
            fullSyncBodies: true
        )

        mock.folders = [
            MailFolderCount(name: "INBOX", messages: 2, unseen: 1, selectable: true),
            MailFolderCount(name: "[Gmail]/All Mail", messages: 2, unseen: 1, selectable: true)
        ]
        mock.store(
            MailSummary(
                id: "501",
                accountID: account.id,
                accountEmail: account.email,
                from: "Stripe <receipts@stripe.com>",
                to: [account.email],
                subject: "Receipt #1",
                date: MailSearchQuery.parseDate("2025-01-10"),
                snippet: "Receipt summary",
                isUnread: false,
                labels: [],
                mailbox: "INBOX",
                mailboxKind: "inbox"
            ),
            mailbox: "INBOX",
            body: "Secret body token ALPHA-778899 inside message 501."
        )

        // Global policy says rollingWindow, but the account's own scope (.everything) wins
        let globalPolicy = CacheSyncPolicy(
            enabled: true,
            mode: .rollingWindow,
            rollingCount: 500,
            daysBack: 90,
            cooldownSeconds: 60,
            fullSyncBodies: true,
            dailyBandwidthCapMB: 1500
        )

        await coordinator.syncNow(account: account, provider: mock, policy: globalPolicy, store: store)

        let stats = store.accountStats(accountID: account.id)
        XCTAssertEqual(stats.envelopeCount, 1)
        XCTAssertEqual(stats.bodyCount, 1, "Full sync should pre-download all message bodies")
        XCTAssertGreaterThan(stats.dailyBandwidthBytes, 0, "Should track daily bandwidth bytes")

        // Searching for a token that only exists in the full body (not subject/snippet) succeeds locally!
        let cached = CachedMailProvider(
            account: account,
            base: mock,
            policy: globalPolicy,
            store: store,
            coordinator: coordinator
        )
        let bodyHits = try await cached.searchFoldered(
            FolderSearchSpec(query: "ALPHA-778899", mailboxes: ["INBOX"], after: nil, before: nil, limit: 10)
        )
        XCTAssertEqual(bodyHits.count, 1)
        XCTAssertEqual(bodyHits.first?.subject, "Receipt #1")

        // getMessage is served from SQLite without any extra network call
        let getCallsBefore = mock.getMessageCalls
        let msg = try await cached.getMessage(id: bodyHits[0].id)
        XCTAssertTrue(msg.body.contains("ALPHA-778899"))
        XCTAssertEqual(mock.getMessageCalls, getCallsBefore, "getMessage should be served from pre-synced full body cache")
        store.close()
    }

    func testLazySyncOnlyCachesRequestedQueriesAndBodies() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailMCPLazySyncTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MailboxCacheStore(directoryURL: tempDir)
        let coordinator = MailboxSyncCoordinator()
        let mock = MockMailProvider()
        let account = MailAccount(
            provider: .imap,
            email: "lazy@example.com"
        )

        mock.folders = [MailFolderCount(name: "INBOX", messages: 2, unseen: 2, selectable: true)]
        mock.currentWatermark = "imap:m=2:u=2"
        mock.store(
            MailSummary(
                id: "701",
                accountID: account.id,
                accountEmail: account.email,
                from: "United <noreply@united.com>",
                to: [account.email],
                subject: "United flight confirmation",
                date: MailSearchQuery.parseDate("2026-10-10"),
                snippet: "Flight UA 123",
                isUnread: true,
                labels: [],
                mailbox: "INBOX",
                mailboxKind: "inbox"
            ),
            mailbox: "INBOX",
            body: "United ticket body."
        )
        mock.store(
            MailSummary(
                id: "702",
                accountID: account.id,
                accountEmail: account.email,
                from: "Delta <noreply@delta.com>",
                to: [account.email],
                subject: "Delta flight confirmation",
                date: MailSearchQuery.parseDate("2026-10-11"),
                snippet: "Flight DL 456",
                isUnread: true,
                labels: [],
                mailbox: "INBOX",
                mailboxKind: "inbox"
            ),
            mailbox: "INBOX",
            body: "Delta ticket body."
        )

        let lazyPolicy = CacheSyncPolicy.default // defaults to .lazy
        XCTAssertEqual(lazyPolicy.mode, .lazy)

        let cached = CachedMailProvider(
            account: account,
            base: mock,
            policy: lazyPolicy,
            store: store,
            coordinator: coordinator
        )

        // 1) First search for "United" hits server, caches only the United result, and does NOT trigger background folder sync
        let unitedSpec = FolderSearchSpec(query: "United", mailboxes: ["INBOX"], after: nil, before: nil, limit: 10)
        let unitedHits1 = try await cached.searchFoldered(unitedSpec)
        XCTAssertEqual(unitedHits1.count, 1)
        XCTAssertEqual(mock.searchCalls, 1)
        XCTAssertEqual(store.accountStats(accountID: account.id).envelopeCount, 1, "Strict lazy mode should only cache the 1 matched summary")

        // 2) Repeat search for "United" within cooldown is served 100% locally (0 extra server search calls)
        let unitedHits2 = try await cached.searchFoldered(unitedSpec)
        XCTAssertEqual(unitedHits2.count, 1)
        XCTAssertEqual(mock.searchCalls, 1, "Repeat query in lazy mode should be served from SQLite")

        // 3) Different query ("Delta") in lazy mode is a query-cache miss -> hits server and adds Delta to SQLite
        let deltaSpec = FolderSearchSpec(query: "Delta", mailboxes: ["INBOX"], after: nil, before: nil, limit: 10)
        let deltaHits = try await cached.searchFoldered(deltaSpec)
        XCTAssertEqual(deltaHits.count, 1)
        XCTAssertEqual(mock.searchCalls, 2, "Uncached query in lazy mode must hit server")
        XCTAssertEqual(store.accountStats(accountID: account.id).envelopeCount, 2)
        store.close()
    }

    private func makeSummary(_ id: String, account: MailAccount, subject: String) -> MailSummary {
        MailSummary(
            id: id,
            accountID: account.id,
            accountEmail: account.email,
            from: "Sender <sender@example.com>",
            to: [account.email],
            subject: subject,
            date: MailSearchQuery.parseDate("2026-10-12"),
            snippet: subject,
            isUnread: false,
            labels: [],
            mailbox: "INBOX",
            mailboxKind: "inbox"
        )
    }

    func testLazyCachingOffSendsEveryRequestToServer() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailMCPLazyOffTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MailboxCacheStore(directoryURL: tempDir)
        let coordinator = MailboxSyncCoordinator()
        let mock = MockMailProvider()
        let account = MailAccount(provider: .imap, email: "nocache@example.com")
        mock.folders = [MailFolderCount(name: "INBOX", messages: 1, unseen: 0, selectable: true)]
        mock.store(makeSummary("801", account: account, subject: "Quarterly report"), mailbox: "INBOX", body: "Report body")

        let policy = CacheSyncPolicy(enabled: false)
        let cached = CachedMailProvider(account: account, base: mock, policy: policy, store: store, coordinator: coordinator)
        let spec = FolderSearchSpec(query: "Quarterly", mailboxes: ["INBOX"], after: nil, before: nil, limit: 10)

        let first = try await cached.searchFoldered(spec)
        let second = try await cached.searchFoldered(spec)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(mock.searchCalls, 2, "With lazy caching off and no background sync, every search goes to the server")

        _ = try await cached.getMessage(id: first[0].id)
        _ = try await cached.getMessage(id: first[0].id)
        XCTAssertEqual(mock.getMessageCalls, 2)
        XCTAssertEqual(store.accountStats(accountID: account.id).envelopeCount, 0, "Nothing should be cached")
        store.close()
    }

    func testLazyCachingOffStillUsesBackgroundSyncedCopy() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailMCPLazyOffProactiveTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MailboxCacheStore(directoryURL: tempDir)
        let coordinator = MailboxSyncCoordinator()
        let mock = MockMailProvider()
        let account = MailAccount(provider: .imap, email: "synced@example.com", syncScope: .recent)
        mock.folders = [MailFolderCount(name: "INBOX", messages: 1, unseen: 0, selectable: true)]
        mock.store(makeSummary("901", account: account, subject: "Payroll notice"), mailbox: "INBOX", body: "Payroll body")

        let policy = CacheSyncPolicy(enabled: false)
        await coordinator.syncNow(account: account, provider: mock, policy: policy, store: store)
        let searchesAfterSync = mock.searchCalls

        let cached = CachedMailProvider(account: account, base: mock, policy: policy, store: store, coordinator: coordinator)
        let hits = try await cached.searchFoldered(
            FolderSearchSpec(query: "Payroll", mailboxes: ["INBOX"], after: nil, before: nil, limit: 10)
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(mock.searchCalls, searchesAfterSync, "Background-synced mailbox answers locally even with lazy caching off")
        store.close()
    }

    func testPagingPastPartiallySyncedWindowIsNotServedFromCache() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailMCPPagingEdgeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MailboxCacheStore(directoryURL: tempDir)
        let account = MailAccount(provider: .imap, email: "window@example.com", syncScope: .recent)
        let oldest = Date().addingTimeInterval(-30 * 86_400)
        store.saveFolders([MailFolderCount(name: "INBOX", messages: 900, unseen: 0, selectable: true)], accountID: account.id)
        store.updateFolderSyncState(
            accountID: account.id,
            folderName: "INBOX",
            watermark: "w",
            syncedCount: 500,
            oldestSyncedAt: oldest,
            isFullySynced: false
        )
        let policy = CacheSyncPolicy.default.effective(for: account)

        XCTAssertTrue(store.canSatisfyFromCache(
            accountID: account.id, mailboxes: ["INBOX"], query: "",
            after: nil, before: oldest.addingTimeInterval(10 * 86_400), policy: policy
        ), "Pages inside the synced window stay local")
        XCTAssertFalse(store.canSatisfyFromCache(
            accountID: account.id, mailboxes: ["INBOX"], query: "",
            after: nil, before: oldest.addingTimeInterval(3_600), policy: policy
        ), "Pages at the edge of the synced window go to the server")
        store.close()
    }

    func testScheduledSyncSkipsWhenWatermarkUnchanged() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailMCPScheduledTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MailboxCacheStore(directoryURL: tempDir)
        let coordinator = MailboxSyncCoordinator()
        let mock = MockMailProvider()
        let account = MailAccount(provider: .imap, email: "sched@example.com", syncScope: .recent, syncSchedule: .every15Minutes)
        mock.folders = [MailFolderCount(name: "INBOX", messages: 1, unseen: 0, selectable: true)]
        mock.currentWatermark = "imap:m=1:u=1"
        mock.store(makeSummary("1001", account: account, subject: "Weekly digest"), mailbox: "INBOX", body: "Digest")

        await coordinator.scheduledSync(account: account, provider: mock, policy: .default, store: store)
        let searchesAfterFirst = mock.searchCalls
        XCTAssertGreaterThan(searchesAfterFirst, 0, "First scheduled run performs a real sync")

        await coordinator.scheduledSync(account: account, provider: mock, policy: .default, store: store)
        XCTAssertEqual(mock.searchCalls, searchesAfterFirst, "Unchanged watermark skips the heavy sync")

        mock.currentWatermark = "imap:m=2:u=2"
        await coordinator.scheduledSync(account: account, provider: mock, policy: .default, store: store)
        XCTAssertGreaterThan(mock.searchCalls, searchesAfterFirst, "Changed watermark triggers a real sync")
        store.close()
    }

    func testLazyCacheEvictionKeepsBackgroundSyncedAccounts() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailMCPEvictionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MailboxCacheStore(directoryURL: tempDir)
        let lazyAccount = MailAccount(provider: .imap, email: "lazy-evict@example.com")
        let syncedAccount = MailAccount(provider: .imap, email: "synced-keep@example.com", syncScope: .everything)
        let bigBody = String(repeating: "x", count: 20_000)

        for index in 0..<10 {
            for account in [lazyAccount, syncedAccount] {
                let summary = makeSummary("\(index)", account: account, subject: "Message \(index)")
                store.saveMessage(MailMessage(
                    id: summary.id, accountID: account.id, accountEmail: account.email, threadID: nil,
                    from: summary.from, to: summary.to, cc: [], bcc: [], subject: summary.subject,
                    date: summary.date, body: bigBody, bodyHTML: nil, isUnread: false, labels: [],
                    attachments: [], mailbox: "INBOX", mailboxKind: "inbox"
                ))
            }
        }
        let spec = FolderSearchSpec(query: "Message", mailboxes: ["INBOX"], after: nil, before: nil, limit: 10)
        store.recordLazyQuery(accountID: lazyAccount.id, request: spec, watermark: nil)

        let protected: Set<UUID> = [syncedAccount.id]
        let before = store.lazyCacheSizeBytes(excluding: protected)
        XCTAssertGreaterThan(before, 200_000)

        let evicted = store.evictLazyCache(capBytes: 100_000, protectedAccountIDs: protected)
        XCTAssertGreaterThan(evicted, 0)
        XCTAssertLessThanOrEqual(store.lazyCacheSizeBytes(excluding: protected), 90_000)
        XCTAssertEqual(store.accountStats(accountID: syncedAccount.id).envelopeCount, 10, "Background-synced mailbox is never trimmed")
        XCTAssertFalse(store.hasLazyQueryCached(accountID: lazyAccount.id, request: spec), "Trimmed account's query cache is invalidated")
        store.close()
    }

    func testLegacyCacheOverrideMigratesToSyncScope() throws {
        func decode(_ legacy: String?) throws -> MailAccount {
            var json: [String: Any] = [
                "id": UUID().uuidString,
                "provider": "imap",
                "email": "legacy@example.com"
            ]
            if let legacy { json["cacheOverride"] = legacy }
            let data = try JSONSerialization.data(withJSONObject: json)
            return try JSONDecoder().decode(MailAccount.self, from: data)
        }
        XCTAssertEqual(try decode(nil).syncScope, .off)
        XCTAssertEqual(try decode("useDefault").syncScope, .off)
        XCTAssertEqual(try decode("lazy").syncScope, .off)
        XCTAssertEqual(try decode("rollingWindow").syncScope, .recent)
        XCTAssertEqual(try decode("timeWindow").syncScope, .days)
        XCTAssertEqual(try decode("fullSync").syncScope, .everything)
        XCTAssertEqual(try decode("fullSync").syncSchedule, .manual)
    }
}

final class MockMailProvider: MailProviding, @unchecked Sendable {
    var folders: [MailFolderCount] = []
    var messagesByMailbox: [String: [MailSummary]] = [:]
    var bodies: [String: MailMessage] = [:]
    var unreachable = false
    var countFetches = 0
    var preservedUnread: Set<String> = []
    var currentWatermark = "mock:0"
    var watermarkCalls = 0
    var searchCalls = 0
    var getMessageCalls = 0

    func fetchWatermark() async throws -> String {
        if unreachable { throw MailMCPError.network("unreachable") }
        watermarkCalls += 1
        return currentWatermark
    }

    func store(_ summary: MailSummary, mailbox: String, body: String) {
        var row = summary
        row.id = MessageLocator.imap(folder: mailbox, uid: summary.id).wire
        row.mailbox = mailbox
        messagesByMailbox[mailbox, default: []].append(row)
        bodies[row.id] = MailMessage(
            id: row.id,
            accountID: row.accountID,
            accountEmail: row.accountEmail,
            threadID: row.threadID,
            from: row.from,
            to: row.to,
            cc: [],
            bcc: [],
            subject: row.subject,
            date: row.date,
            body: body,
            bodyHTML: nil,
            isUnread: row.isUnread,
            labels: row.labels,
            attachments: [],
            mailbox: mailbox,
            mailboxKind: row.mailboxKind
        )
    }

    func testConnection() async throws -> String {
        if unreachable { throw MailMCPError.network("unreachable") }
        return "OK"
    }

    func search(query: String, limit: Int) async throws -> [MailSummary] {
        try await searchFoldered(FolderSearchSpec(query: query, mailboxes: ["INBOX"], after: nil, before: nil, limit: limit))
    }

    func messageCount(query: String) async throws -> Int { 0 }

    func listFolders() async throws -> [MailFolderCount] {
        try await listFolders(includeCounts: false)
    }

    func listFolders(includeCounts: Bool) async throws -> [MailFolderCount] {
        if unreachable { throw MailMCPError.network("unreachable") }
        if includeCounts {
            countFetches += 1
            return folders
        }
        return folders.map { MailFolderCount(name: $0.name, messages: nil, unseen: nil, selectable: $0.selectable, remoteID: $0.remoteID) }
    }

    func resolveMailboxes(_ requested: [String]) async throws -> [ResolvedMailbox] {
        if unreachable { throw MailMCPError.network("unreachable") }
        let hints = folders.map { FolderHint(name: $0.name, remoteID: $0.remoteID) }
        return MailboxMatcher.resolve(requested.flatMap { MailboxRequest.parse($0) }, folders: hints)
    }

    func searchFoldered(_ request: FolderSearchSpec) async throws -> [MailSummary] {
        if unreachable { throw MailMCPError.network("unreachable") }
        searchCalls += 1
        let needle = request.query.lowercased()
        var hits: [MailSummary] = []
        for mailbox in request.mailboxes {
            let rows = messagesByMailbox[mailbox] ?? []
            hits.append(contentsOf: rows.filter { summary in
                let haystack = (summary.subject + " " + summary.snippet + " " + summary.from).lowercased()
                let tokens = needle.split { $0.isWhitespace }.map(String.init).filter { !$0.isEmpty }
                if !tokens.isEmpty, tokens.contains(where: { !haystack.contains($0) }) { return false }
                if let after = request.after, let date = summary.date, date < after { return false }
                if let before = request.before, let date = summary.date, date >= before { return false }
                return true
            })
        }
        return Array(hits.prefix(max(request.limit, 1)))
    }

    func getMessage(id: String) async throws -> MailMessage {
        if unreachable { throw MailMCPError.network("unreachable") }
        getMessageCalls += 1
        guard let message = bodies[id] else {
            throw MailMCPError.provider("not found")
        }
        if message.isUnread {
            preservedUnread.insert(id)
        }
        return message
    }

    func listThreads(query: String?, limit: Int) async throws -> [MailThread] { [] }
    func modify(id: String, action: MailModifyAction, label: String?) async throws {}
    func createDraft(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws -> String { "draft" }
    func send(to: [String], cc: [String], bcc: [String], subject: String, body: String, extraHeaders: [String: String]) async throws -> String { "sent" }
    func getAttachment(messageID: String, attachmentID: String) async throws -> MailAttachmentData {
        MailAttachmentData(meta: MailAttachmentMeta(id: attachmentID, filename: "a", mimeType: "text/plain", size: 0), dataBase64: "")
    }
    func getThread(id: String, limit: Int) async throws -> [MailMessage] { [] }
    func listDrafts(limit: Int) async throws -> [MailDraft] { [] }
    func updateDraft(id: String, to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws -> String { id }
    func deleteDraft(id: String) async throws {}
    func fileMessage(id: String, folder: String?, addLabels: [String], removeLabels: [String]) async throws {}
    func frequentContacts(limit: Int) async throws -> [MailContact] { [] }
}

final class OAuthLoopbackTests: XCTestCase {
    func testCallbackLineKeepsCodeAndState() throws {
        let url = OAuthLoopbackServer.callbackURL(
            requestLine: "GET /?state=xyz&code=abc HTTP/1.1",
            redirectURI: "http://127.0.0.1:9"
        )
        let items = URLComponents(url: try XCTUnwrap(url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first { $0.name == "code" }?.value, "abc")
        XCTAssertEqual(items?.first { $0.name == "state" }?.value, "xyz")
        XCTAssertEqual(url?.host, "127.0.0.1")
        XCTAssertEqual(url?.port, 9)
    }

    func testFaviconIsNotACallback() {
        XCTAssertNil(
            OAuthLoopbackServer.callbackURL(
                requestLine: "GET /favicon.ico HTTP/1.1",
                redirectURI: "http://127.0.0.1:9"
            )
        )
    }

    func testListenerReturnsAuthorizationCode() async throws {
        let server = try await OAuthLoopbackServer.start()
        defer { server.stop() }
        let target = try XCTUnwrap(URL(string: server.redirectURI + "/?code=abc&state=xyz"))
        async let callback = server.nextCallback()
        let (body, response) = try await URLSession.shared.data(from: target)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertTrue(String(data: body, encoding: .utf8)?.contains("signed in") == true)
        let got = try await callback
        let items = URLComponents(url: got, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first { $0.name == "code" }?.value, "abc")
        XCTAssertEqual(items?.first { $0.name == "state" }?.value, "xyz")
    }
}
