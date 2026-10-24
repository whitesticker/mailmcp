import Foundation

actor MailboxSyncCoordinator {
    static let shared = MailboxSyncCoordinator()

    private var inflightSyncs: [UUID: Task<Void, Never>] = [:]
    private var lastCooldownAt: [UUID: Date] = [:]
    private var proactiveAccountIDs: Set<UUID> = []
    private var lastLazyCapCheck: Date?

    func setProactiveAccounts(_ ids: Set<UUID>) {
        proactiveAccountIDs = ids
    }

    func isSyncing(accountID: UUID) -> Bool {
        inflightSyncs[accountID] != nil
    }

    func enforceLazyCacheCap(policy: CacheSyncPolicy, store: MailboxCacheStore, force: Bool = false) {
        guard let cap = policy.lazyCacheCapBytes else { return }
        if !force, let last = lastLazyCapCheck, Date().timeIntervalSince(last) < 300 { return }
        lastLazyCapCheck = Date()
        store.evictLazyCache(capBytes: cap, protectedAccountIDs: proactiveAccountIDs)
    }

    /// Runs a cadence-driven sync, skipping the heavy work when the server watermark is unchanged.
    func scheduledSync(
        account: MailAccount,
        provider: any MailProviding,
        policy: CacheSyncPolicy,
        store: MailboxCacheStore
    ) async {
        let effectivePolicy = policy.effective(for: account)
        guard effectivePolicy.mode.isProactive, inflightSyncs[account.id] == nil else { return }

        let previous = store.accountWatermark(accountID: account.id)
        let bodiesPending = effectivePolicy.mode == .fullSync
            && effectivePolicy.fullSyncBodies
            && !store.missingBodyMessageIDs(accountID: account.id, limit: 1).isEmpty
        if previous.lastSyncedAt != nil, !bodiesPending,
           let current = try? await provider.fetchWatermark(),
           let known = previous.watermark, known == current {
            store.saveAccountWatermark(accountID: account.id, watermark: current, checkedAt: Date(), syncedAt: Date())
            if store === MailboxCacheStore.shared {
                Task { @MainActor in AppState.shared.cacheRevision &+= 1 }
            }
            return
        }
        await syncNow(account: account, provider: provider, policy: policy, store: store)
    }

    func isInCooldown(accountID: UUID, cooldownSeconds: Int, store: MailboxCacheStore) -> Bool {
        let ttl = TimeInterval(max(cooldownSeconds, 5))
        if let memoryDate = lastCooldownAt[accountID], Date().timeIntervalSince(memoryDate) < ttl {
            return true
        }
        if let persistedDate = store.accountWatermark(accountID: accountID).lastCheckedAt,
           Date().timeIntervalSince(persistedDate) < ttl {
            lastCooldownAt[accountID] = persistedDate
            return true
        }
        return false
    }

    func recordCooldown(accountID: UUID, watermark: String?, synced: Bool = false, store: MailboxCacheStore) {
        let now = Date()
        lastCooldownAt[accountID] = now
        store.saveAccountWatermark(
            accountID: accountID,
            watermark: watermark,
            checkedAt: now,
            syncedAt: synced ? now : nil
        )
    }

    func resetCooldown(accountID: UUID? = nil) {
        if let accountID {
            lastCooldownAt.removeValue(forKey: accountID)
        } else {
            lastCooldownAt.removeAll()
        }
    }

    func cancelSync(accountID: UUID) {
        if let task = inflightSyncs.removeValue(forKey: accountID) {
            task.cancel()
        }
        Task { @MainActor in
            AppState.shared.setAccountSyncing(accountID, isSyncing: false)
            AppState.shared.setAccountSyncProgress(accountID, message: "Sync paused")
        }
    }

    func triggerBackgroundSync(
        account: MailAccount,
        provider: any MailProviding,
        policy: CacheSyncPolicy,
        store: MailboxCacheStore,
        watermark: String? = nil
    ) {
        let effectivePolicy = policy.effective(for: account)
        guard effectivePolicy.mode.isProactive else { return }
        if inflightSyncs[account.id] != nil { return }

        let notifyUI = store === MailboxCacheStore.shared
        if notifyUI {
            Task { @MainActor in
                AppState.shared.setAccountSyncing(account.id, isSyncing: true)
            }
        }
        let task = Task.detached(priority: .utility) { [weak self] in
            await Self.performSync(
                account: account,
                provider: provider,
                policy: effectivePolicy,
                store: store,
                knownWatermark: watermark,
                notifyUI: notifyUI
            )
            await self?.finishSync(accountID: account.id, notifyUI: notifyUI)
        }
        inflightSyncs[account.id] = task
    }

    func syncNow(
        account: MailAccount,
        provider: any MailProviding,
        policy: CacheSyncPolicy,
        store: MailboxCacheStore
    ) async {
        if let existing = inflightSyncs[account.id] {
            await existing.value
            return
        }
        let effectivePolicy = policy.effective(for: account)
        let notifyUI = store === MailboxCacheStore.shared
        if notifyUI {
            await MainActor.run {
                AppState.shared.setAccountSyncing(account.id, isSyncing: true)
            }
        }
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await Self.performSync(
                account: account,
                provider: provider,
                policy: effectivePolicy,
                store: store,
                knownWatermark: nil,
                notifyUI: notifyUI
            )
            await self?.finishSync(accountID: account.id, notifyUI: notifyUI)
        }
        inflightSyncs[account.id] = task
        await task.value
    }

    func waitForInflight(accountID: UUID) async {
        if let task = inflightSyncs[accountID] {
            await task.value
        }
    }

    private func finishSync(accountID: UUID, notifyUI: Bool) {
        inflightSyncs.removeValue(forKey: accountID)
        if notifyUI {
            Task { @MainActor in
                AppState.shared.setAccountSyncing(accountID, isSyncing: false)
            }
        }
    }

    private static func reportProgress(_ accountID: UUID, _ message: String?, notifyUI: Bool) {
        guard notifyUI else { return }
        Task { @MainActor in
            AppState.shared.setAccountSyncProgress(accountID, message: message)
        }
    }

    private static func performSync(
        account: MailAccount,
        provider: any MailProviding,
        policy: CacheSyncPolicy,
        store: MailboxCacheStore,
        knownWatermark: String?,
        notifyUI: Bool
    ) async {
        if store.dailyBandwidthBytes(accountID: account.id) >= policy.dailyBandwidthCapBytes {
            reportProgress(
                account.id,
                "Paused at daily safety cap (\(policy.dailyBandwidthCapMB) MB)",
                notifyUI: notifyUI
            )
            return
        }

        reportProgress(account.id, "Checking folders…", notifyUI: notifyUI)
        let watermark: String?
        if let knownWatermark {
            watermark = knownWatermark
        } else {
            watermark = try? await provider.fetchWatermark()
        }

        let folders = (try? await provider.listFolders(includeCounts: false)) ?? []
        if !folders.isEmpty {
            store.saveFolders(folders, accountID: account.id)
        }

        let requestedTokens = policy.mode == .fullSync
            ? ["inbox", "all", "sent", "archive", "spam", "trash"]
            : ["inbox", "spam", "trash"]
        let resolved = (try? await provider.resolveMailboxes(requestedTokens)) ?? []
        var seenFolders = Set<String>()
        var targetFolders: [String] = []
        for name in resolved.map(\.name) where !name.isEmpty {
            if seenFolders.insert(name.lowercased()).inserted {
                targetFolders.append(name)
            }
        }
        if targetFolders.isEmpty {
            targetFolders = ["INBOX"]
        }

        let limitPerFolder = policy.targetLimitPerFolder
        let afterDate = policy.cutoffDate

        for folderName in targetFolders {
            if Task.isCancelled { return }
            if store.dailyBandwidthBytes(accountID: account.id) >= policy.dailyBandwidthCapBytes {
                reportProgress(
                    account.id,
                    "Paused at daily safety cap (\(policy.dailyBandwidthCapMB) MB)",
                    notifyUI: notifyUI
                )
                return
            }
            reportProgress(account.id, "Syncing titles in \(folderName)…", notifyUI: notifyUI)
            let spec = FolderSearchSpec(
                query: "",
                mailboxes: [folderName],
                after: afterDate,
                before: nil,
                limit: limitPerFolder
            )
            guard let summaries = try? await provider.searchFoldered(spec) else { continue }
            store.saveSummaries(summaries)
            store.addBandwidthUsage(accountID: account.id, bytes: Int64(summaries.count) * 600)
            if policy.mode == .rollingWindow {
                store.pruneRollingWindow(
                    accountID: account.id,
                    mailbox: folderName,
                    keepLatest: policy.rollingCount
                )
            }
            let oldest = summaries.compactMap(\.date).min() ?? afterDate
            let isFullySynced = policy.mode == .fullSync || summaries.count < limitPerFolder
            store.updateFolderSyncState(
                accountID: account.id,
                folderName: folderName,
                watermark: watermark,
                syncedCount: summaries.count,
                oldestSyncedAt: oldest,
                isFullySynced: isFullySynced
            )
        }

        store.saveAccountWatermark(
            accountID: account.id,
            watermark: watermark,
            checkedAt: Date(),
            syncedAt: Date()
        )

        // Phase 2: Full body download for Full Sync mode (text/HTML only, skips binary attachments)
        if policy.mode == .fullSync && policy.fullSyncBodies {
            let batchSize = account.provider == .gmail ? 10 : 25
            let pauseNs: UInt64 = account.provider == .gmail ? 2_000_000_000 : 150_000_000
            var attemptedInRun = Set<String>()

            while !Task.isCancelled {
                if store.dailyBandwidthBytes(accountID: account.id) >= policy.dailyBandwidthCapBytes {
                    reportProgress(
                        account.id,
                        "Paused at daily safety cap (\(policy.dailyBandwidthCapMB) MB)",
                        notifyUI: notifyUI
                    )
                    return
                }
                let candidates = store.missingBodyMessageIDs(accountID: account.id, limit: batchSize * 2)
                    .filter { !attemptedInRun.contains($0) }
                let batch = Array(candidates.prefix(batchSize))
                guard !batch.isEmpty else { break }
                for id in batch { attemptedInRun.insert(id) }

                let currentStats = store.accountStats(accountID: account.id)
                reportProgress(
                    account.id,
                    "Downloading bodies: \(currentStats.bodyCount) / \(currentStats.envelopeCount)…",
                    notifyUI: notifyUI
                )

                guard let fetched = try? await provider.fetchMessagesLightweight(ids: batch),
                      !fetched.messages.isEmpty else {
                    break
                }
                store.saveMessages(fetched.messages)
                store.addBandwidthUsage(accountID: account.id, bytes: max(fetched.bytesDownloaded, Int64(fetched.messages.count) * 1024))

                if notifyUI {
                    try? await Task.sleep(nanoseconds: pauseNs)
                }
            }
        }

        reportProgress(account.id, nil, notifyUI: notifyUI)
    }
}

final class CachedMailProvider: MailProviding, @unchecked Sendable {
    let account: MailAccount
    let base: any MailProviding
    let policy: CacheSyncPolicy
    let store: MailboxCacheStore
    let coordinator: MailboxSyncCoordinator

    init(
        account: MailAccount,
        base: any MailProviding,
        policy: CacheSyncPolicy = .default,
        store: MailboxCacheStore = .shared,
        coordinator: MailboxSyncCoordinator = .shared
    ) {
        self.account = account
        self.base = base
        self.policy = policy.effective(for: account)
        self.store = store
        self.coordinator = coordinator
    }

    /// Manual-schedule mailboxes only sync when the user presses Sync now.
    private var autoSyncAllowed: Bool {
        policy.mode.isProactive && account.syncSchedule != .manual
    }

    func testConnection() async throws -> String {
        let ping = try await base.testConnection()
        if autoSyncAllowed {
            await coordinator.triggerBackgroundSync(
                account: account,
                provider: base,
                policy: policy,
                store: store
            )
        }
        return ping
    }

    func fetchWatermark() async throws -> String {
        try await base.fetchWatermark()
    }

    func listFolders() async throws -> [MailFolderCount] {
        try await listFolders(includeCounts: false)
    }

    func listFolders(includeCounts: Bool) async throws -> [MailFolderCount] {
        guard policy.cacheActive else {
            return try await base.listFolders(includeCounts: includeCounts)
        }
        let cached = store.cachedFolders(accountID: account.id)
        let inCooldown = await coordinator.isInCooldown(
            accountID: account.id,
            cooldownSeconds: policy.cooldownSeconds,
            store: store
        )
        if !cached.isEmpty, (!includeCounts || cached.contains(where: { $0.messages != nil })), inCooldown {
            return cached.map {
                MailFolderCount(
                    name: $0.name,
                    messages: includeCounts ? $0.messages : nil,
                    unseen: includeCounts ? $0.unseen : nil,
                    selectable: $0.selectable,
                    remoteID: $0.remoteID
                )
            }
        }
        let fresh = try await base.listFolders(includeCounts: includeCounts)
        store.saveFolders(fresh, accountID: account.id)
        return fresh
    }

    func resolveMailboxes(_ requested: [String]) async throws -> [ResolvedMailbox] {
        guard policy.cacheActive else {
            return try await base.resolveMailboxes(requested)
        }
        let cached = store.cachedFolders(accountID: account.id)
        if !cached.isEmpty {
            let hints = cached.map {
                FolderHint(
                    name: $0.name,
                    remoteID: $0.remoteID,
                    kind: MailboxKind(rawValue: $0.kind)
                )
            }
            let requests = requested.flatMap { MailboxRequest.parse($0) }
            let resolved = MailboxMatcher.resolve(requests, folders: hints)
            if resolved.contains(where: { !$0.name.isEmpty }) {
                return resolved
            }
        }
        let resolved = try await base.resolveMailboxes(requested)
        if let folders = try? await base.listFolders(includeCounts: false), !folders.isEmpty {
            store.saveFolders(folders, accountID: account.id)
        } else {
            let synthesized = resolved
                .filter { !$0.name.isEmpty }
                .map { MailFolderCount(name: $0.name, messages: nil, unseen: nil, selectable: true, remoteID: $0.remoteID) }
            if !synthesized.isEmpty {
                store.saveFolders(synthesized, accountID: account.id)
            }
        }
        return resolved
    }

    func searchFoldered(_ request: FolderSearchSpec) async throws -> [MailSummary] {
        guard policy.cacheActive else {
            return try await base.searchFoldered(request)
        }

        let boxes = request.mailboxes.isEmpty ? ["INBOX"] : request.mailboxes
        let isProactiveCovered = policy.mode.isProactive && store.canSatisfyFromCache(
            accountID: account.id,
            mailboxes: boxes,
            query: request.query,
            after: request.after,
            policy: policy
        )
        let isLazyQueryCovered = policy.lazyEnabled
            && !IMAPSearchQuery.looksLikeGmailRaw(request.query)
            && store.hasLazyQueryCached(accountID: account.id, request: request)
        let canServeLocally = isProactiveCovered || isLazyQueryCovered

        let inCooldown = await coordinator.isInCooldown(
            accountID: account.id,
            cooldownSeconds: policy.cooldownSeconds,
            store: store
        )

        // Step 1: Within 1-minute cooldown and cache covers this folder/query -> 100% local (0 network calls)
        if inCooldown && canServeLocally {
            return store.search(
                accountID: account.id,
                mailboxes: boxes,
                query: request.query,
                after: request.after,
                before: request.before,
                limit: request.limit
            )
        }

        // Step 2: Cooldown expired -> Check lightweight server watermark before searching
        if canServeLocally {
            let previousWatermark = store.accountWatermark(accountID: account.id).watermark
            if let currentWatermark = try? await base.fetchWatermark() {
                if let previousWatermark, previousWatermark == currentWatermark {
                    // No new messages on server -> set 1-minute cooldown and serve locally
                    await coordinator.recordCooldown(
                        accountID: account.id,
                        watermark: currentWatermark,
                        synced: false,
                        store: store
                    )
                    return store.search(
                        accountID: account.id,
                        mailboxes: boxes,
                        query: request.query,
                        after: request.after,
                        before: request.before,
                        limit: request.limit
                    )
                } else {
                    // New messages arrived -> serve via server call, write-through to cache, enforce 1-min cooldown
                    let serverHits = try await base.searchFoldered(request)
                    store.saveSummaries(serverHits)
                    store.addBandwidthUsage(accountID: account.id, bytes: Int64(serverHits.count) * 600)
                    if policy.lazyEnabled {
                        store.recordLazyQuery(accountID: account.id, request: request, watermark: currentWatermark)
                    }
                    await coordinator.recordCooldown(
                        accountID: account.id,
                        watermark: currentWatermark,
                        synced: !policy.mode.isProactive,
                        store: store
                    )
                    if autoSyncAllowed {
                        await coordinator.triggerBackgroundSync(
                            account: account,
                            provider: base,
                            policy: policy,
                            store: store,
                            watermark: currentWatermark
                        )
                    }
                    return serverHits
                }
            }
        }

        // Step 3: Cache miss (new query in Lazy mode, or proactive cache not yet warm) -> use server & write-through
        let serverHits = try await base.searchFoldered(request)
        store.saveSummaries(serverHits)
        store.addBandwidthUsage(accountID: account.id, bytes: Int64(serverHits.count) * 600)
        let watermark = try? await base.fetchWatermark()
        if policy.lazyEnabled {
            store.recordLazyQuery(accountID: account.id, request: request, watermark: watermark)
            await coordinator.enforceLazyCacheCap(policy: policy, store: store)
        }
        await coordinator.recordCooldown(
            accountID: account.id,
            watermark: watermark,
            synced: !policy.mode.isProactive,
            store: store
        )
        if autoSyncAllowed {
            await coordinator.triggerBackgroundSync(
                account: account,
                provider: base,
                policy: policy,
                store: store,
                watermark: watermark
            )
        }
        return serverHits
    }

    func search(query: String, limit: Int) async throws -> [MailSummary] {
        guard policy.cacheActive else {
            return try await base.search(query: query, limit: limit)
        }
        let parsed = MailSearchQuery.parse(query)
        let mailbox = parsed.mailbox ?? "INBOX"
        return try await searchFoldered(
            FolderSearchSpec(
                query: parsed.text,
                mailboxes: [mailbox],
                after: parsed.after,
                before: parsed.before,
                limit: limit
            )
        )
    }

    func messageCount(query: String) async throws -> Int {
        guard policy.cacheActive else {
            return try await base.messageCount(query: query)
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let inCooldown = await coordinator.isInCooldown(
            accountID: account.id,
            cooldownSeconds: policy.cooldownSeconds,
            store: store
        )
        if inCooldown {
            if trimmed.isEmpty, let count = store.messageCount(accountID: account.id, mailbox: "INBOX", unreadOnly: false), count > 0 {
                return count
            }
            if (trimmed == "is:unread" || trimmed == "unseen"),
               let count = store.messageCount(accountID: account.id, mailbox: "INBOX", unreadOnly: true) {
                return count
            }
        }
        return try await base.messageCount(query: query)
    }

    func getMessage(id: String) async throws -> MailMessage {
        if policy.cacheActive, let cached = store.getMessage(accountID: account.id, id: id) {
            return cached
        }
        let fresh = try await base.getMessage(id: id)
        if policy.cacheActive {
            store.saveMessage(fresh)
            let bytes = Int64(fresh.body.utf8.count + (fresh.bodyHTML?.utf8.count ?? 0) + 1024)
            store.addBandwidthUsage(accountID: account.id, bytes: bytes)
            if policy.lazyEnabled {
                await coordinator.enforceLazyCacheCap(policy: policy, store: store)
            }
        }
        return fresh
    }

    func fetchMessagesLightweight(ids: [String]) async throws -> (messages: [MailMessage], bytesDownloaded: Int64) {
        let fetched = try await base.fetchMessagesLightweight(ids: ids)
        if policy.cacheActive && !fetched.messages.isEmpty {
            store.saveMessages(fetched.messages)
            store.addBandwidthUsage(accountID: account.id, bytes: max(fetched.bytesDownloaded, Int64(fetched.messages.count) * 1024))
        }
        return fetched
    }

    func listThreads(query: String?, limit: Int) async throws -> [MailThread] {
        guard policy.cacheActive else {
            return try await base.listThreads(query: query, limit: limit)
        }
        let messages = try await search(query: query ?? "", limit: max(limit * 2, 20))
        if messages.isEmpty {
            return try await base.listThreads(query: query, limit: limit)
        }
        var groups: [String: [MailSummary]] = [:]
        for message in messages {
            let key = message.threadID ?? message.subject.lowercased()
            groups[key, default: []].append(message)
        }
        return groups.map { key, items in
            let newest = items.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) } ?? items[0]
            return MailThread(
                id: key,
                accountID: account.id,
                accountEmail: account.email,
                subject: newest.subject,
                participants: Array(Set(items.map(\.from))),
                snippet: newest.snippet,
                date: newest.date,
                messageCount: items.count,
                isUnread: items.contains(where: \.isUnread)
            )
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        .prefix(max(limit, 1))
        .map { $0 }
    }

    func getThread(id: String, limit: Int) async throws -> [MailMessage] {
        let messages = try await base.getThread(id: id, limit: limit)
        if policy.cacheActive {
            for message in messages {
                store.saveMessage(message)
            }
        }
        return messages
    }

    func getAttachment(messageID: String, attachmentID: String) async throws -> MailAttachmentData {
        if policy.cacheActive,
           let cached = store.cachedAttachment(accountID: account.id, messageID: messageID, attachmentID: attachmentID) {
            return cached
        }
        let fresh = try await base.getAttachment(messageID: messageID, attachmentID: attachmentID)
        if policy.cacheActive {
            store.saveAttachment(fresh, accountID: account.id, messageID: messageID)
        }
        return fresh
    }

    func modify(id: String, action: MailModifyAction, label: String?) async throws {
        try await base.modify(id: id, action: action, label: label)
        if policy.cacheActive {
            store.applyModify(accountID: account.id, id: id, action: action, label: label)
        }
    }

    func createDraft(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws -> String {
        try await base.createDraft(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
    }

    func send(to: [String], cc: [String], bcc: [String], subject: String, body: String, extraHeaders: [String: String]) async throws -> String {
        try await base.send(to: to, cc: cc, bcc: bcc, subject: subject, body: body, extraHeaders: extraHeaders)
    }

    func listDrafts(limit: Int) async throws -> [MailDraft] {
        try await base.listDrafts(limit: limit)
    }

    func updateDraft(id: String, to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws -> String {
        try await base.updateDraft(id: id, to: to, cc: cc, bcc: bcc, subject: subject, body: body)
    }

    func deleteDraft(id: String) async throws {
        try await base.deleteDraft(id: id)
        if policy.cacheActive {
            store.deleteMessage(accountID: account.id, id: id)
        }
    }

    func fileMessage(id: String, folder: String?, addLabels: [String], removeLabels: [String]) async throws {
        try await base.fileMessage(id: id, folder: folder, addLabels: addLabels, removeLabels: removeLabels)
        if policy.cacheActive {
            store.applyFileMessage(accountID: account.id, id: id, folder: folder, addLabels: addLabels, removeLabels: removeLabels)
        }
    }

    func fileMatching(query: String, folder: String, mailbox: String?, limit: Int?) async throws -> Int {
        let count = try await base.fileMatching(query: query, folder: folder, mailbox: mailbox, limit: limit)
        if policy.cacheActive, count > 0 {
            await coordinator.resetCooldown(accountID: account.id)
            store.invalidateLazyQueries(accountID: account.id)
            if autoSyncAllowed {
                await coordinator.triggerBackgroundSync(
                    account: account,
                    provider: base,
                    policy: policy,
                    store: store
                )
            }
        }
        return count
    }

    func frequentContacts(limit: Int) async throws -> [MailContact] {
        if policy.cacheActive {
            let cached = store.frequentContacts(accountID: account.id, accountEmail: account.email, limit: limit)
            if !cached.isEmpty {
                return cached
            }
        }
        return try await base.frequentContacts(limit: limit)
    }
}
