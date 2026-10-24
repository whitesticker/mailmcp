import Darwin
import Foundation
import SQLite3

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension Notification.Name {
    static let mailboxCacheDidChange = Notification.Name("MailMCP.mailboxCacheDidChange")
}

struct CachedFolderRecord: Codable, Hashable, Sendable {
    var accountID: UUID
    var name: String
    var remoteID: String?
    var kind: String
    var selectable: Bool
    var messages: Int?
    var unseen: Int?
    var watermark: String?
    var syncedCount: Int
    var oldestSyncedAt: Date?
    var isFullySynced: Bool
    var lastSyncedAt: Date?
}

struct AccountCacheStats: Sendable, Equatable {
    var accountID: UUID
    var envelopeCount: Int = 0
    var bodyCount: Int = 0
    var folderCount: Int = 0
    var attachmentCount: Int = 0
    var oldestMessageAt: Date?
    var newestMessageAt: Date?
    var lastSyncedAt: Date?
    var lastCheckedAt: Date?
    var watermark: String?
    var dailyBandwidthBytes: Int64 = 0
}

struct MailboxCacheStats: Sendable {
    var messageCount: Int = 0
    var bodyCount: Int = 0
    var folderCount: Int = 0
    var attachmentCount: Int = 0
    var sizeBytes: Int64 = 0
    var lastSyncAt: Date?
}

struct CacheFreeSpaceResult: Sendable {
    var messagesRemoved: Int = 0
    var bytesFreed: Int64 = 0
    var accountIDs: Set<UUID> = []
}

final class MailboxCacheStore: @unchecked Sendable {
    static let shared = MailboxCacheStore(directoryURL: Paths.mailboxCacheDirectory)

    let directoryURL: URL
    let databaseURL: URL
    let attachmentsDirectoryURL: URL

    private let lock = NSLock()
    private var db: OpaquePointer?
    /// Separate read-only connection so the UI never waits behind a sync write transaction (WAL lets readers run alongside the writer).
    private let readLock = NSLock()
    private var readDB: OpaquePointer?
    private let touchQueue = DispatchQueue(label: "MailMCP.cache.touch", qos: .utility)
    private let notifyLock = NSLock()
    private var notifyPending = false

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.databaseURL = directoryURL.appendingPathComponent("envelope-index.sqlite")
        self.attachmentsDirectoryURL = directoryURL.appendingPathComponent("attachments", isDirectory: true)
        openAndMigrate()
        openReader()
    }

    deinit {
        close()
    }

    func close() {
        readLock.lock()
        if let reader = readDB {
            sqlite3_close(reader)
            readDB = nil
        }
        readLock.unlock()
        lock.lock()
        if let current = db {
            sqlite3_close(current)
            db = nil
        }
        lock.unlock()
    }

    private func openReader() {
        lock.lock()
        let ready = db != nil
        lock.unlock()
        guard ready else { return }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            return
        }
        readLock.lock()
        readDB = handle
        readLock.unlock()
    }

    /// Runs a read on the reader connection, or on the writer (under its lock) if the reader couldn't be opened.
    private func read<T>(_ fallback: T, _ body: (OpaquePointer) -> T) -> T {
        readLock.lock()
        if let readDB {
            defer { readLock.unlock() }
            return body(readDB)
        }
        readLock.unlock()
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return fallback }
        return body(db)
    }

    private func touchMessage(accountID: String, messageID: String) {
        touchQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let db = self.db else { return }
            self.touchMessageLocked(accountID: accountID, messageID: messageID, on: db)
        }
    }

    // MARK: - Folders & Watermarks

    func saveFolders(_ folders: [MailFolderCount], accountID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        exec("BEGIN IMMEDIATE TRANSACTION;", on: db)
        let sql = """
        INSERT INTO folders (account_id, name, remote_id, kind, selectable, messages, unseen, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        ON CONFLICT(account_id, name) DO UPDATE SET
            remote_id = COALESCE(excluded.remote_id, folders.remote_id),
            kind = excluded.kind,
            selectable = excluded.selectable,
            messages = COALESCE(excluded.messages, folders.messages),
            unseen = COALESCE(excluded.unseen, folders.unseen),
            updated_at = excluded.updated_at;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            let now = Date().timeIntervalSince1970
            for folder in folders {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                let kind = MailboxMatcher.kind(ofName: folder.name).rawValue
                bindText(stmt, index: 1, accountID.uuidString)
                bindText(stmt, index: 2, folder.name)
                bindOptionalText(stmt, index: 3, folder.remoteID)
                bindText(stmt, index: 4, kind)
                sqlite3_bind_int(stmt, 5, folder.selectable ? 1 : 0)
                bindOptionalInt(stmt, index: 6, folder.messages)
                bindOptionalInt(stmt, index: 7, folder.unseen)
                sqlite3_bind_double(stmt, 8, now)
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        exec("COMMIT;", on: db)
    }

    func cachedFolders(accountID: UUID) -> [CachedFolderRecord] {
        read([]) { db in
            let sql = """
            SELECT name, remote_id, kind, selectable, messages, unseen, watermark,
                   synced_count, oldest_synced_at, is_fully_synced, last_synced_at
            FROM folders
            WHERE account_id = ?1
            ORDER BY name COLLATE NOCASE ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, accountID.uuidString)

            var rows: [CachedFolderRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = columnText(stmt, 0) ?? ""
                let remoteID = columnText(stmt, 1)
                let kind = columnText(stmt, 2) ?? MailboxKind.other.rawValue
                let selectable = sqlite3_column_int(stmt, 3) != 0
                let messages = columnOptionalInt(stmt, 4)
                let unseen = columnOptionalInt(stmt, 5)
                let watermark = columnText(stmt, 6)
                let syncedCount = Int(sqlite3_column_int(stmt, 7))
                let oldestSyncedAt = columnOptionalDate(stmt, 8)
                let isFullySynced = sqlite3_column_int(stmt, 9) != 0
                let lastSyncedAt = columnOptionalDate(stmt, 10)
                rows.append(
                    CachedFolderRecord(
                        accountID: accountID,
                        name: name,
                        remoteID: remoteID,
                        kind: kind,
                        selectable: selectable,
                        messages: messages,
                        unseen: unseen,
                        watermark: watermark,
                        syncedCount: syncedCount,
                        oldestSyncedAt: oldestSyncedAt,
                        isFullySynced: isFullySynced,
                        lastSyncedAt: lastSyncedAt
                    )
                )
            }
            return rows
        }
    }

    func updateFolderSyncState(
        accountID: UUID,
        folderName: String,
        watermark: String?,
        syncedCount: Int,
        oldestSyncedAt: Date?,
        isFullySynced: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        let kind = MailboxMatcher.kind(ofName: folderName).rawValue
        let now = Date().timeIntervalSince1970
        let sql = """
        INSERT INTO folders (
            account_id, name, kind, selectable, watermark, synced_count,
            oldest_synced_at, is_fully_synced, last_synced_at, updated_at
        )
        VALUES (?1, ?2, ?3, 1, ?4, ?5, ?6, ?7, ?8, ?8)
        ON CONFLICT(account_id, name) DO UPDATE SET
            watermark = COALESCE(excluded.watermark, folders.watermark),
            synced_count = MAX(excluded.synced_count, folders.synced_count),
            oldest_synced_at = CASE
                WHEN folders.oldest_synced_at IS NULL THEN excluded.oldest_synced_at
                WHEN excluded.oldest_synced_at IS NULL THEN folders.oldest_synced_at
                ELSE MIN(folders.oldest_synced_at, excluded.oldest_synced_at)
            END,
            is_fully_synced = MAX(excluded.is_fully_synced, folders.is_fully_synced),
            last_synced_at = excluded.last_synced_at,
            updated_at = excluded.updated_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, accountID.uuidString)
        bindText(stmt, index: 2, folderName)
        bindText(stmt, index: 3, kind)
        bindOptionalText(stmt, index: 4, watermark)
        sqlite3_bind_int(stmt, 5, Int32(syncedCount))
        bindOptionalDouble(stmt, index: 6, oldestSyncedAt?.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 7, isFullySynced ? 1 : 0)
        sqlite3_bind_double(stmt, 8, now)
        _ = sqlite3_step(stmt)
    }

    func accountWatermark(accountID: UUID) -> (watermark: String?, lastCheckedAt: Date?, lastSyncedAt: Date?) {
        read((nil, nil, nil)) { db in
            let sql = "SELECT watermark, last_checked_at, last_synced_at FROM account_sync_state WHERE account_id = ?1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return (nil, nil, nil) }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, accountID.uuidString)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return (nil, nil, nil) }
            return (
                columnText(stmt, 0),
                columnOptionalDate(stmt, 1),
                columnOptionalDate(stmt, 2)
            )
        }
    }

    func saveAccountWatermark(accountID: UUID, watermark: String?, checkedAt: Date = Date(), syncedAt: Date? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        let sql = """
        INSERT INTO account_sync_state (account_id, watermark, last_checked_at, last_synced_at)
        VALUES (?1, ?2, ?3, ?4)
        ON CONFLICT(account_id) DO UPDATE SET
            watermark = COALESCE(excluded.watermark, account_sync_state.watermark),
            last_checked_at = excluded.last_checked_at,
            last_synced_at = COALESCE(excluded.last_synced_at, account_sync_state.last_synced_at);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, accountID.uuidString)
        bindOptionalText(stmt, index: 2, watermark)
        sqlite3_bind_double(stmt, 3, checkedAt.timeIntervalSince1970)
        bindOptionalDouble(stmt, index: 4, syncedAt?.timeIntervalSince1970)
        _ = sqlite3_step(stmt)
        notifyChange()
    }

    // MARK: - Summaries & Messages

    func saveSummaries(_ summaries: [MailSummary]) {
        guard !summaries.isEmpty else { return }
        lock.lock()
        guard let db else {
            lock.unlock()
            return
        }

        exec("BEGIN IMMEDIATE TRANSACTION;", on: db)
        let now = Date().timeIntervalSince1970
        for summary in summaries {
            upsertSummaryLocked(summary, now: now, on: db)
        }
        exec("COMMIT;", on: db)
        lock.unlock()
        notifyChange()
    }

    func saveMessage(_ message: MailMessage) {
        saveMessages([message])
    }

    func saveMessages(_ messages: [MailMessage]) {
        guard !messages.isEmpty else { return }
        lock.lock()
        guard let db else {
            lock.unlock()
            return
        }

        exec("BEGIN IMMEDIATE TRANSACTION;", on: db)
        let now = Date().timeIntervalSince1970
        let bodySQL = """
        INSERT INTO message_bodies (account_id, message_id, body_text, body_html, attachments_json, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        ON CONFLICT(account_id, message_id) DO UPDATE SET
            body_text = excluded.body_text,
            body_html = excluded.body_html,
            attachments_json = excluded.attachments_json,
            updated_at = excluded.updated_at;
        """
        var stmt: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, bodySQL, -1, &stmt, nil) == SQLITE_OK

        for message in messages {
            let summary = MailSummary(
                id: message.id,
                accountID: message.accountID,
                accountEmail: message.accountEmail,
                threadID: message.threadID,
                from: message.from,
                to: message.to,
                subject: message.subject,
                date: message.date,
                snippet: String(message.body.prefix(200)),
                isUnread: message.isUnread,
                labels: message.labels,
                mailbox: message.mailbox,
                mailboxKind: message.mailboxKind
            )
            upsertSummaryLocked(summary, cc: message.cc, bcc: message.bcc, hasBody: true, now: now, on: db)

            let attachmentsJSON = (try? String(decoding: JSONCoders.encoder.encode(message.attachments), as: UTF8.self)) ?? "[]"
            if prepared, let stmt {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, index: 1, message.accountID.uuidString)
                bindText(stmt, index: 2, message.id)
                bindText(stmt, index: 3, message.body)
                bindOptionalText(stmt, index: 4, message.bodyHTML)
                bindText(stmt, index: 5, attachmentsJSON)
                sqlite3_bind_double(stmt, 6, now)
                _ = sqlite3_step(stmt)
            }
            refreshFTSLocked(accountID: message.accountID.uuidString, messageID: message.id, bodyText: message.body, on: db)
        }
        if let stmt {
            sqlite3_finalize(stmt)
        }
        exec("COMMIT;", on: db)
        lock.unlock()
        notifyChange()
    }

    /// Newest messages without a cached body. With `mailbox`, only the newest `window` messages of that
    /// folder (on or after `since`) are considered, so recent/days policies never backfill older mail.
    func missingBodyMessageIDs(
        accountID: UUID,
        limit: Int,
        mailbox: String? = nil,
        since: Date? = nil,
        window: Int? = nil
    ) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }

        var clauses = ["account_id = ?1"]
        if mailbox != nil {
            clauses.append("(LOWER(mailbox) = LOWER(?3) OR LOWER(mailbox_kind) = LOWER(?4))")
        }
        if since != nil {
            clauses.append("date_ts >= ?5")
        }
        let windowClause = window.map { "LIMIT \(max($0, 1))" } ?? ""
        let sql = """
        SELECT message_id FROM (
            SELECT message_id, has_body, date_ts
            FROM messages
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY COALESCE(date_ts, 0) DESC
            \(windowClause)
        )
        WHERE has_body = 0
        ORDER BY COALESCE(date_ts, 0) DESC
        LIMIT ?2;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, accountID.uuidString)
        sqlite3_bind_int(stmt, 2, Int32(max(limit, 1)))
        if let mailbox {
            bindText(stmt, index: 3, mailbox)
            bindText(stmt, index: 4, MailboxMatcher.kind(ofName: mailbox).rawValue)
        }
        if let since {
            sqlite3_bind_double(stmt, 5, since.timeIntervalSince1970)
        }

        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = columnText(stmt, 0), !id.isEmpty {
                ids.append(id)
            }
        }
        return ids
    }

    func addBandwidthUsage(accountID: UUID, bytes: Int64) {
        guard bytes > 0 else { return }
        lock.lock()
        guard let db else {
            lock.unlock()
            return
        }
        let dayKey = Self.utcDayKey()
        let sql = """
        INSERT INTO account_bandwidth (account_id, day_key, bytes_downloaded)
        VALUES (?1, ?2, ?3)
        ON CONFLICT(account_id, day_key) DO UPDATE SET
            bytes_downloaded = account_bandwidth.bytes_downloaded + excluded.bytes_downloaded;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            bindText(stmt, index: 1, accountID.uuidString)
            bindText(stmt, index: 2, dayKey)
            sqlite3_bind_int64(stmt, 3, bytes)
            _ = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        lock.unlock()
    }

    func dailyBandwidthBytes(accountID: UUID) -> Int64 {
        read(0) { db in
            return dailyBandwidthBytesLocked(accountID: accountID.uuidString, on: db)
        }
    }

    private func dailyBandwidthBytesLocked(accountID: String, on db: OpaquePointer) -> Int64 {
        let dayKey = Self.utcDayKey()
        let sql = "SELECT bytes_downloaded FROM account_bandwidth WHERE account_id = ?1 AND day_key = ?2 LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, accountID)
        bindText(stmt, index: 2, dayKey)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    private static func utcDayKey() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    func getMessage(accountID: UUID, id: String) -> MailMessage? {
        read(nil) { db in
            let sql = """
            SELECT m.message_id, m.account_email, m.thread_id, m.from_addr, m.to_json,
                   m.cc_json, m.bcc_json, m.subject, m.date_ts, m.is_unread, m.labels_json,
                   m.mailbox, m.mailbox_kind, b.body_text, b.body_html, b.attachments_json
            FROM messages m
            INNER JOIN message_bodies b
                ON m.account_id = b.account_id AND m.message_id = b.message_id
            WHERE m.account_id = ?1 AND (m.message_id = ?2 OR m.native_id = ?3)
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }
            let nativeID = MessageLocator.parse(id).nativeID
            bindText(stmt, index: 1, accountID.uuidString)
            bindText(stmt, index: 2, id)
            bindText(stmt, index: 3, nativeID)

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let messageID = columnText(stmt, 0) ?? id
            touchMessage(accountID: accountID.uuidString, messageID: messageID)
            let accountEmail = columnText(stmt, 1) ?? ""
            let threadID = columnText(stmt, 2)
            let from = columnText(stmt, 3) ?? ""
            let to = decodeStringArray(columnText(stmt, 4))
            let cc = decodeStringArray(columnText(stmt, 5))
            let bcc = decodeStringArray(columnText(stmt, 6))
            let subject = columnText(stmt, 7) ?? "(no subject)"
            let date = columnOptionalDate(stmt, 8)
            let isUnread = sqlite3_column_int(stmt, 9) != 0
            let labels = decodeStringArray(columnText(stmt, 10))
            let mailbox = columnText(stmt, 11)
            let mailboxKind = columnText(stmt, 12)
            let bodyText = columnText(stmt, 13) ?? ""
            let bodyHTML = columnText(stmt, 14)
            let attachmentsJSON = columnText(stmt, 15) ?? "[]"
            let attachments = (try? JSONCoders.decoder.decode([MailAttachmentMeta].self, from: Data(attachmentsJSON.utf8))) ?? []

            return MailMessage(
                id: messageID,
                accountID: accountID,
                accountEmail: accountEmail,
                threadID: threadID,
                from: from,
                to: to,
                cc: cc,
                bcc: bcc,
                subject: subject,
                date: date,
                body: bodyText,
                bodyHTML: bodyHTML,
                isUnread: isUnread,
                labels: labels,
                attachments: attachments,
                mailbox: mailbox,
                mailboxKind: mailboxKind
            )
        }
    }

    // MARK: - Local Search

    func search(
        accountID: UUID,
        mailboxes: [String]?,
        query: String,
        after: Date?,
        before: Date?,
        limit: Int
    ) -> [MailSummary] {
        read([]) { db in
            let parsed = ParsedCacheQuery.parse(query)
            var clauses: [String] = ["m.account_id = ?"]
            var bindings: [SQLBindValue] = [.text(accountID.uuidString)]

            if let mailboxes, !mailboxes.isEmpty {
                let nonAnywhere = mailboxes.filter { $0.lowercased() != "anywhere" && $0.lowercased() != "everywhere" }
                if !nonAnywhere.isEmpty {
                    var subClauses: [String] = []
                    for box in nonAnywhere {
                        let kind = MailboxMatcher.kind(ofName: box).rawValue
                        if kind != MailboxKind.other.rawValue {
                            subClauses.append("(LOWER(m.mailbox) = LOWER(?) OR LOWER(m.mailbox_kind) = LOWER(?))")
                            bindings.append(.text(box))
                            bindings.append(.text(kind))
                        } else {
                            subClauses.append("LOWER(m.mailbox) = LOWER(?)")
                            bindings.append(.text(box))
                        }
                    }
                    clauses.append("(" + subClauses.joined(separator: " OR ") + ")")
                }
            }

            if let unreadOnly = parsed.unreadOnly {
                clauses.append("m.is_unread = ?")
                bindings.append(.int(unreadOnly ? 1 : 0))
            }

            for fromFilter in parsed.fromTokens {
                clauses.append("LOWER(m.from_addr) LIKE ?")
                bindings.append(.text("%\(fromFilter.lowercased())%"))
            }

            for toFilter in parsed.toTokens {
                clauses.append("LOWER(m.to_json) LIKE ?")
                bindings.append(.text("%\(toFilter.lowercased())%"))
            }

            for subjectFilter in parsed.subjectTokens {
                clauses.append("LOWER(m.subject) LIKE ?")
                bindings.append(.text("%\(subjectFilter.lowercased())%"))
            }

            if let after {
                clauses.append("m.date_ts >= ?")
                bindings.append(.double(after.timeIntervalSince1970))
            }
            if let before {
                clauses.append("m.date_ts < ?")
                bindings.append(.double(before.timeIntervalSince1970))
            }

            var joinFTS = ""
            if !parsed.textTokens.isEmpty {
                if let ftsExpr = Self.makeFTSExpression(parsed.textTokens) {
                    joinFTS = "INNER JOIN messages_fts fts ON fts.rowid = m.rowid"
                    clauses.append("messages_fts MATCH ?")
                    bindings.append(.text(ftsExpr))
                } else {
                    for token in parsed.textTokens {
                        clauses.append("(LOWER(m.subject) LIKE ? OR LOWER(m.snippet) LIKE ? OR LOWER(m.from_addr) LIKE ?)")
                        let pat = "%\(token.lowercased())%"
                        bindings.append(.text(pat))
                        bindings.append(.text(pat))
                        bindings.append(.text(pat))
                    }
                }
            }

            let cap = max(limit, 1)
            let sql = """
            SELECT m.message_id, m.account_email, m.thread_id, m.from_addr, m.to_json,
                   m.subject, m.date_ts, m.snippet, m.is_unread, m.labels_json,
                   m.mailbox, m.mailbox_kind
            FROM messages m
            \(joinFTS)
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY COALESCE(m.date_ts, 0) DESC
            LIMIT \(cap);
            """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK || stmt == nil {
                // Fallback to LIKE if FTS syntax rejected a query token
                return searchWithLikeFallbackLocked(
                    accountID: accountID,
                    mailboxes: mailboxes,
                    parsed: parsed,
                    after: after,
                    before: before,
                    limit: cap,
                    on: db
                )
            }
            guard let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }

            for (idx, value) in bindings.enumerated() {
                let pos = Int32(idx + 1)
                switch value {
                case .text(let s): bindText(stmt, index: pos, s)
                case .int(let i): sqlite3_bind_int(stmt, pos, Int32(i))
                case .double(let d): sqlite3_bind_double(stmt, pos, d)
                }
            }

            return collectSummariesLocked(stmt: stmt, accountID: accountID)
        }
    }

    func messageCount(accountID: UUID, mailbox: String = "INBOX", unreadOnly: Bool = false) -> Int? {
        read(nil) { db in
            let kind = MailboxMatcher.kind(ofName: mailbox).rawValue
            var sql = """
            SELECT COUNT(*) FROM messages
            WHERE account_id = ?1 AND (LOWER(mailbox) = LOWER(?2) OR LOWER(mailbox_kind) = LOWER(?3))
            """
            if unreadOnly {
                sql += " AND is_unread = 1"
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, accountID.uuidString)
            bindText(stmt, index: 2, mailbox)
            bindText(stmt, index: 3, kind)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    func canSatisfyFromCache(
        accountID: UUID,
        mailboxes: [String],
        query: String,
        after: Date?,
        before: Date? = nil,
        policy: CacheSyncPolicy
    ) -> Bool {
        if IMAPSearchQuery.looksLikeGmailRaw(query) {
            return false
        }
        let cached = cachedFolders(accountID: accountID)
        if !cached.isEmpty {
            let targetBoxes = mailboxes.isEmpty ? ["INBOX"] : mailboxes
            var allBoxesSynced = true
            for box in targetBoxes {
                if box.lowercased() == "anywhere" || box.lowercased() == "everywhere" {
                    if !cached.contains(where: { $0.kind == MailboxKind.inbox.rawValue && $0.lastSyncedAt != nil }) {
                        allBoxesSynced = false
                        break
                    }
                    continue
                }
                let kind = MailboxMatcher.kind(ofName: box).rawValue
                guard let folder = cached.first(where: {
                    $0.name.caseInsensitiveCompare(box) == .orderedSame
                        || ($0.kind == kind && kind != MailboxKind.other.rawValue)
                }), folder.lastSyncedAt != nil else {
                    allBoxesSynced = false
                    break
                }
                if folder.isFullySynced { continue }
                if let after, let oldest = folder.oldestSyncedAt, after < oldest {
                    allBoxesSynced = false
                    break
                }
                // Paging past the synced window (within a day, since server date filters are day-granular) needs the server.
                if let before, let oldest = folder.oldestSyncedAt, before <= oldest.addingTimeInterval(86_400) {
                    allBoxesSynced = false
                    break
                }
            }
            if allBoxesSynced {
                return true
            }
        }
        return false
    }

    func recordLazyQuery(
        accountID: UUID,
        request: FolderSearchSpec,
        watermark: String?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        let key = Self.queryKey(for: request)
        let sql = """
        INSERT INTO cached_queries (account_id, query_key, limit_fetched, watermark, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5)
        ON CONFLICT(account_id, query_key) DO UPDATE SET
            limit_fetched = MAX(cached_queries.limit_fetched, excluded.limit_fetched),
            watermark = COALESCE(excluded.watermark, cached_queries.watermark),
            updated_at = excluded.updated_at;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            bindText(stmt, index: 1, accountID.uuidString)
            bindText(stmt, index: 2, key)
            sqlite3_bind_int(stmt, 3, Int32(max(request.limit, 1)))
            bindOptionalText(stmt, index: 4, watermark)
            sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
            _ = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    func hasLazyQueryCached(accountID: UUID, request: FolderSearchSpec) -> Bool {
        read(false) { db in
            let key = Self.queryKey(for: request)
            let sql = """
            SELECT limit_fetched FROM cached_queries
            WHERE account_id = ?1 AND query_key = ?2
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, accountID.uuidString)
            bindText(stmt, index: 2, key)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
            let fetched = Int(sqlite3_column_int(stmt, 0))
            return fetched >= max(request.limit, 1)
        }
    }

    func invalidateLazyQueries(accountID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        exec("DELETE FROM cached_queries WHERE account_id = '\(accountID.uuidString)';", on: db)
    }

    private static func queryKey(for request: FolderSearchSpec) -> String {
        let boxes = (request.mailboxes.isEmpty ? ["INBOX"] : request.mailboxes)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .sorted()
            .joined(separator: ",")
        let q = request.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let afterStr = request.after.map { String(Int($0.timeIntervalSince1970)) } ?? ""
        let beforeStr = request.before.map { String(Int($0.timeIntervalSince1970)) } ?? ""
        return "boxes=\(boxes)|q=\(q)|after=\(afterStr)|before=\(beforeStr)"
    }

    // MARK: - Mutations & Invalidation

    func applyModify(accountID: UUID, id: String, action: MailModifyAction, label: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        let nativeID = MessageLocator.parse(id).nativeID
        switch action {
        case .markRead, .markUnread:
            let unread = action == .markUnread ? 1 : 0
            let sql = "UPDATE messages SET is_unread = ?1 WHERE account_id = ?2 AND (message_id = ?3 OR native_id = ?4);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                sqlite3_bind_int(stmt, 1, Int32(unread))
                bindText(stmt, index: 2, accountID.uuidString)
                bindText(stmt, index: 3, id)
                bindText(stmt, index: 4, nativeID)
                _ = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        case .trash:
            let sql = "UPDATE messages SET mailbox = 'Trash', mailbox_kind = 'trash' WHERE account_id = ?1 AND (message_id = ?2 OR native_id = ?3);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                bindText(stmt, index: 1, accountID.uuidString)
                bindText(stmt, index: 2, id)
                bindText(stmt, index: 3, nativeID)
                _ = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        case .archive:
            let sql = "UPDATE messages SET mailbox = 'Archive', mailbox_kind = 'archive' WHERE account_id = ?1 AND (message_id = ?2 OR native_id = ?3);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                bindText(stmt, index: 1, accountID.uuidString)
                bindText(stmt, index: 2, id)
                bindText(stmt, index: 3, nativeID)
                _ = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        case .addLabel, .removeLabel:
            guard let label, !label.isEmpty else { return }
            updateLabelsLocked(
                accountID: accountID,
                id: id,
                add: action == .addLabel ? [label] : [],
                remove: action == .removeLabel ? [label] : [],
                folder: nil,
                on: db
            )
        }
    }

    func applyFileMessage(accountID: UUID, id: String, folder: String?, addLabels: [String], removeLabels: [String]) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        updateLabelsLocked(accountID: accountID, id: id, add: addLabels, remove: removeLabels, folder: folder, on: db)
    }

    func adjustFolderUnseen(accountID: UUID, folder: String, delta: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        let sql = """
        UPDATE folders SET unseen = MAX(unseen + ?1, 0)
        WHERE account_id = ?2 AND name = ?3 AND unseen IS NOT NULL;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(delta))
        bindText(stmt, index: 2, accountID.uuidString)
        bindText(stmt, index: 3, folder)
        _ = sqlite3_step(stmt)
    }

    func deleteMessage(accountID: UUID, id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        let nativeID = MessageLocator.parse(id).nativeID
        exec("BEGIN IMMEDIATE TRANSACTION;", on: db)
        let ftsDel = """
        DELETE FROM messages_fts WHERE rowid IN (
            SELECT rowid FROM messages WHERE account_id = ?1 AND (message_id = ?2 OR native_id = ?3)
        );
        """
        var stmt1: OpaquePointer?
        if sqlite3_prepare_v2(db, ftsDel, -1, &stmt1, nil) == SQLITE_OK, let stmt1 {
            bindText(stmt1, index: 1, accountID.uuidString)
            bindText(stmt1, index: 2, id)
            bindText(stmt1, index: 3, nativeID)
            _ = sqlite3_step(stmt1)
            sqlite3_finalize(stmt1)
        }

        for table in ["message_bodies", "messages"] {
            let sql = "DELETE FROM \(table) WHERE account_id = ?1 AND (message_id = ?2 OR native_id = ?3);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                bindText(stmt, index: 1, accountID.uuidString)
                bindText(stmt, index: 2, id)
                bindText(stmt, index: 3, nativeID)
                _ = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
        exec("COMMIT;", on: db)
    }

    // MARK: - Global Size Limit

    /// Bytes held in live database pages (messages, bodies and the search index). Unlike the file size,
    /// this drops as soon as rows are deleted.
    func usedBytes() -> Int64 {
        read(0) { db in
            return usedBytesLocked(on: db)
        }
    }

    private func usedBytesLocked(on db: OpaquePointer) -> Int64 {
        let pageSize = Int64(scalarInt("PRAGMA page_size;", on: db))
        let pages = Int64(scalarInt("PRAGMA page_count;", on: db))
        let free = Int64(scalarInt("PRAGMA freelist_count;", on: db))
        return max(pages - free, 0) * pageSize
    }

    /// Deletes least-recently-used messages (last opened, else last synced) until roughly `bytes` are freed.
    /// Only ever called on the user's request. Affected accounts lose their sync coverage so reads go to the
    /// server until the next sync.
    @discardableResult
    func freeSpace(bytes target: Int64) -> CacheFreeSpaceResult {
        // Pending "last opened" updates must land first so recently read mail is kept.
        touchQueue.sync {}
        lock.lock()
        guard let db, target > 0 else {
            lock.unlock()
            return CacheFreeSpaceResult()
        }
        let startBytes = usedBytesLocked(on: db)
        var estimated: Int64 = 0
        var result = CacheFreeSpaceResult()
        var affectedAccounts = Set<String>()

        exec("BEGIN IMMEDIATE TRANSACTION;", on: db)
        while estimated < target {
            let sql = """
            SELECT m.rowid, m.account_id, m.message_id,
                   LENGTH(m.subject) * 2 + LENGTH(m.snippet) * 2 + LENGTH(m.to_json) + LENGTH(m.from_addr) * 2
                   + LENGTH(m.cc_json) + LENGTH(m.labels_json) + 300
                   + COALESCE((SELECT LENGTH(b.body_text) * 2 + COALESCE(LENGTH(b.body_html), 0)
                                      + LENGTH(b.attachments_json)
                               FROM message_bodies b
                               WHERE b.account_id = m.account_id AND b.message_id = m.message_id), 0)
            FROM messages m
            ORDER BY COALESCE(m.last_accessed_at, m.updated_at) ASC, COALESCE(m.date_ts, 0) ASC
            LIMIT 500;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { break }
            var batch: [(rowid: Int64, accountID: String, messageID: String, bytes: Int64)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                batch.append((
                    sqlite3_column_int64(stmt, 0),
                    columnText(stmt, 1) ?? "",
                    columnText(stmt, 2) ?? "",
                    sqlite3_column_int64(stmt, 3)
                ))
            }
            sqlite3_finalize(stmt)
            if batch.isEmpty { break }

            for item in batch {
                if estimated >= target { break }
                exec("DELETE FROM messages_fts WHERE rowid = \(item.rowid);", on: db)
                deleteRowLocked(table: "message_bodies", accountID: item.accountID, messageID: item.messageID, on: db)
                exec("DELETE FROM messages WHERE rowid = \(item.rowid);", on: db)
                estimated += item.bytes
                result.messagesRemoved += 1
                affectedAccounts.insert(item.accountID)
            }
        }
        for accountID in affectedAccounts {
            for sql in [
                "DELETE FROM cached_queries WHERE account_id = ?1;",
                "UPDATE folders SET watermark = NULL, synced_count = 0, oldest_synced_at = NULL, is_fully_synced = 0 WHERE account_id = ?1;",
                "UPDATE account_sync_state SET watermark = NULL WHERE account_id = ?1;"
            ] {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                    bindText(stmt, index: 1, accountID)
                    _ = sqlite3_step(stmt)
                    sqlite3_finalize(stmt)
                }
            }
        }
        exec("COMMIT;", on: db)
        if result.messagesRemoved > 0 {
            // FTS5 keeps delete markers until segments merge; optimize reclaims their pages now.
            exec("INSERT INTO messages_fts(messages_fts) VALUES('optimize');", on: db)
            exec("PRAGMA wal_checkpoint(TRUNCATE);", on: db)
        }
        result.bytesFreed = max(startBytes - usedBytesLocked(on: db), 0)
        result.accountIDs = Set(affectedAccounts.compactMap(UUID.init(uuidString:)))
        lock.unlock()

        if result.messagesRemoved > 0 {
            notifyChange()
        }
        return result
    }

    private func deleteRowLocked(table: String, accountID: String, messageID: String, on db: OpaquePointer) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "DELETE FROM \(table) WHERE account_id = ?1 AND message_id = ?2;",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK, let stmt else { return }
        bindText(stmt, index: 1, accountID)
        bindText(stmt, index: 2, messageID)
        _ = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func touchMessageLocked(accountID: String, messageID: String, on db: OpaquePointer) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "UPDATE messages SET last_accessed_at = ?3 WHERE account_id = ?1 AND message_id = ?2;",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK, let stmt else { return }
        bindText(stmt, index: 1, accountID)
        bindText(stmt, index: 2, messageID)
        sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        _ = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: - Contacts & Threads from Cache

    func frequentContacts(accountID: UUID, accountEmail: String, limit: Int) -> [MailContact] {
        read([]) { db in
            let sql = """
            SELECT to_json FROM messages
            WHERE account_id = ?1 AND (LOWER(mailbox_kind) = 'sent' OR LOWER(from_addr) LIKE ?2)
            ORDER BY COALESCE(date_ts, 0) DESC
            LIMIT 200;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, accountID.uuidString)
            bindText(stmt, index: 2, "%\(accountEmail.lowercased())%")

            var counts: [String: (name: String, count: Int)] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let recipients = decodeStringArray(columnText(stmt, 0))
                for raw in recipients {
                    let lower = raw.lowercased()
                    if lower.contains(accountEmail.lowercased()) { continue }
                    let existing = counts[lower]
                    counts[lower] = (raw, (existing?.count ?? 0) + 1)
                }
            }
            return counts.map { MailContact(address: $0.key, name: $0.value.name, count: $0.value.count) }
                .sorted { $0.count > $1.count }
                .prefix(max(limit, 1))
                .map { $0 }
        }
    }

    func accountStats(accountID: UUID) -> AccountCacheStats {
        read(AccountCacheStats(accountID: accountID)) { db in
            let id = accountID.uuidString
            var result = AccountCacheStats(accountID: accountID)

            var msgStmt: OpaquePointer?
            if sqlite3_prepare_v2(
                db,
                "SELECT COUNT(*), MIN(date_ts), MAX(date_ts) FROM messages WHERE account_id = ?1;",
                -1,
                &msgStmt,
                nil
            ) == SQLITE_OK, let msgStmt {
                bindText(msgStmt, index: 1, id)
                if sqlite3_step(msgStmt) == SQLITE_ROW {
                    result.envelopeCount = Int(sqlite3_column_int(msgStmt, 0))
                    result.oldestMessageAt = columnOptionalDate(msgStmt, 1)
                    result.newestMessageAt = columnOptionalDate(msgStmt, 2)
                }
                sqlite3_finalize(msgStmt)
            }

            result.bodyCount = scalarInt(
                "SELECT COUNT(*) FROM message_bodies WHERE account_id = ?1;",
                param: id,
                on: db
            )
            result.folderCount = scalarInt(
                "SELECT COUNT(*) FROM folders WHERE account_id = ?1;",
                param: id,
                on: db
            )
            result.attachmentCount = scalarInt(
                "SELECT COUNT(*) FROM attachments WHERE account_id = ?1;",
                param: id,
                on: db
            )

            var syncStmt: OpaquePointer?
            if sqlite3_prepare_v2(
                db,
                "SELECT watermark, last_checked_at, last_synced_at FROM account_sync_state WHERE account_id = ?1;",
                -1,
                &syncStmt,
                nil
            ) == SQLITE_OK, let syncStmt {
                bindText(syncStmt, index: 1, id)
                if sqlite3_step(syncStmt) == SQLITE_ROW {
                    result.watermark = columnText(syncStmt, 0)
                    result.lastCheckedAt = columnOptionalDate(syncStmt, 1)
                    result.lastSyncedAt = columnOptionalDate(syncStmt, 2)
                }
                sqlite3_finalize(syncStmt)
            }
            result.dailyBandwidthBytes = dailyBandwidthBytesLocked(accountID: id, on: db)
            return result
        }
    }

    func stats() -> MailboxCacheStats {
        read(MailboxCacheStats()) { db in
            var result = MailboxCacheStats()
            result.messageCount = scalarInt("SELECT COUNT(*) FROM messages;", on: db)
            result.bodyCount = scalarInt("SELECT COUNT(*) FROM message_bodies;", on: db)
            result.folderCount = scalarInt("SELECT COUNT(*) FROM folders;", on: db)
            result.attachmentCount = scalarInt("SELECT COUNT(*) FROM attachments;", on: db)

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT MAX(last_synced_at) FROM account_sync_state;", -1, &stmt, nil) == SQLITE_OK, let stmt {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    result.lastSyncAt = columnOptionalDate(stmt, 0)
                }
                sqlite3_finalize(stmt)
            }
            result.sizeBytes = Self.directorySize(at: directoryURL)
            return result
        }
    }

    func clearAll(accountID: UUID? = nil) {
        lock.lock()
        guard let db else {
            lock.unlock()
            return
        }

        if let accountID {
            let id = accountID.uuidString
            exec("BEGIN IMMEDIATE TRANSACTION;", on: db)
            for sql in [
                "DELETE FROM messages_fts WHERE rowid IN (SELECT rowid FROM messages WHERE account_id = '\(id)');",
                "DELETE FROM message_bodies WHERE account_id = '\(id)';",
                "DELETE FROM messages WHERE account_id = '\(id)';",
                "DELETE FROM folders WHERE account_id = '\(id)';",
                "DELETE FROM attachments WHERE account_id = '\(id)';",
                "DELETE FROM cached_queries WHERE account_id = '\(id)';",
                "DELETE FROM account_sync_state WHERE account_id = '\(id)';"
            ] {
                exec(sql, on: db)
            }
            exec("COMMIT;", on: db)
            let accountAttDir = attachmentsDirectoryURL.appendingPathComponent(id, isDirectory: true)
            try? FileManager.default.removeItem(at: accountAttDir)
        } else {
            exec("BEGIN IMMEDIATE TRANSACTION;", on: db)
            for table in ["messages_fts", "message_bodies", "messages", "folders", "attachments", "cached_queries", "account_sync_state"] {
                exec("DELETE FROM \(table);", on: db)
            }
            exec("COMMIT;", on: db)
            exec("VACUUM;", on: db)
            try? FileManager.default.removeItem(at: attachmentsDirectoryURL)
        }
        lock.unlock()
        notifyChange()
    }

    // MARK: - Internal SQLite Helpers

    private func openAndMigrate() {
        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            return
        }
        chmod(databaseURL.path, 0o600)
        self.db = handle

        exec("PRAGMA journal_mode = WAL;", on: handle)
        exec("PRAGMA synchronous = NORMAL;", on: handle)
        exec("PRAGMA foreign_keys = ON;", on: handle)

        let schema = """
        CREATE TABLE IF NOT EXISTS account_sync_state (
            account_id TEXT PRIMARY KEY,
            watermark TEXT,
            last_checked_at REAL,
            last_synced_at REAL
        );

        CREATE TABLE IF NOT EXISTS account_bandwidth (
            account_id TEXT NOT NULL,
            day_key TEXT NOT NULL,
            bytes_downloaded INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (account_id, day_key)
        );

        CREATE TABLE IF NOT EXISTS cached_queries (
            account_id TEXT NOT NULL,
            query_key TEXT NOT NULL,
            limit_fetched INTEGER NOT NULL DEFAULT 0,
            watermark TEXT,
            updated_at REAL NOT NULL,
            PRIMARY KEY (account_id, query_key)
        );

        CREATE TABLE IF NOT EXISTS folders (
            account_id TEXT NOT NULL,
            name TEXT NOT NULL,
            remote_id TEXT,
            kind TEXT NOT NULL,
            selectable INTEGER NOT NULL DEFAULT 1,
            messages INTEGER,
            unseen INTEGER,
            watermark TEXT,
            synced_count INTEGER NOT NULL DEFAULT 0,
            oldest_synced_at REAL,
            is_fully_synced INTEGER NOT NULL DEFAULT 0,
            last_synced_at REAL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (account_id, name)
        );

        CREATE TABLE IF NOT EXISTS messages (
            rowid INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            native_id TEXT NOT NULL,
            account_email TEXT NOT NULL,
            thread_id TEXT,
            from_addr TEXT NOT NULL,
            to_json TEXT NOT NULL,
            cc_json TEXT NOT NULL DEFAULT '[]',
            bcc_json TEXT NOT NULL DEFAULT '[]',
            subject TEXT NOT NULL,
            date_ts REAL,
            snippet TEXT NOT NULL,
            is_unread INTEGER NOT NULL DEFAULT 0,
            labels_json TEXT NOT NULL DEFAULT '[]',
            mailbox TEXT,
            mailbox_kind TEXT,
            has_body INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL,
            UNIQUE (account_id, message_id)
        );

        CREATE INDEX IF NOT EXISTS idx_messages_account_mailbox_date
            ON messages (account_id, mailbox, date_ts DESC);
        CREATE INDEX IF NOT EXISTS idx_messages_account_kind_date
            ON messages (account_id, mailbox_kind, date_ts DESC);
        CREATE INDEX IF NOT EXISTS idx_messages_account_native
            ON messages (account_id, native_id);
        CREATE INDEX IF NOT EXISTS idx_messages_account_thread
            ON messages (account_id, thread_id);

        CREATE TABLE IF NOT EXISTS message_bodies (
            account_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            body_text TEXT NOT NULL,
            body_html TEXT,
            attachments_json TEXT NOT NULL DEFAULT '[]',
            updated_at REAL NOT NULL,
            PRIMARY KEY (account_id, message_id)
        );

        CREATE TABLE IF NOT EXISTS attachments (
            account_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            attachment_id TEXT NOT NULL,
            filename TEXT NOT NULL,
            mime_type TEXT NOT NULL,
            size INTEGER,
            disk_path TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (account_id, message_id, attachment_id)
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            from_addr,
            to_addrs,
            subject,
            snippet,
            body_text,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        """
        exec(schema, on: handle)
        exec("ALTER TABLE messages ADD COLUMN last_accessed_at REAL;", on: handle)

        if scalarInt("PRAGMA user_version;", on: handle) < 1 {
            // IMAP bodies cached before MIME transfer decoding was fixed are still quoted-printable/base64.
            exec("""
            BEGIN IMMEDIATE TRANSACTION;
            DELETE FROM message_bodies WHERE message_id LIKE 'imap|%';
            UPDATE messages SET has_body = 0 WHERE message_id LIKE 'imap|%';
            PRAGMA user_version = 1;
            COMMIT;
            """, on: handle)
        }
        if scalarInt("PRAGMA user_version;", on: handle) < 2 {
            reclassifyMailboxKindsLocked(on: handle)
            exec("PRAGMA user_version = 2;", on: handle)
        }
        if scalarInt("PRAGMA user_version;", on: handle) < 3 {
            // Attachments are no longer cached (docs/sync-retention.md, v2).
            exec("DELETE FROM attachments;", on: handle)
            try? FileManager.default.removeItem(at: attachmentsDirectoryURL)
            exec("PRAGMA user_version = 3;", on: handle)
        }
    }

    /// Recomputes stored folder kinds after `MailboxMatcher.kind` stopped matching substrings (e.g. "Robinhood" as trash).
    private func reclassifyMailboxKindsLocked(on db: OpaquePointer) {
        var pairs: [(table: String, name: String, kind: String)] = []
        for (table, column) in [("messages", "mailbox"), ("folders", "name")] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT DISTINCT \(column), \(table == "messages" ? "mailbox_kind" : "kind") FROM \(table) WHERE \(column) IS NOT NULL;", -1, &stmt, nil) == SQLITE_OK,
                  let stmt else { continue }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let name = columnText(stmt, 0) else { continue }
                let stored = columnText(stmt, 1) ?? ""
                let kind = MailboxMatcher.kind(ofName: name).rawValue
                if kind != stored { pairs.append((table, name, kind)) }
            }
            sqlite3_finalize(stmt)
        }
        guard !pairs.isEmpty else { return }
        exec("BEGIN IMMEDIATE TRANSACTION;", on: db)
        for pair in pairs {
            let sql = pair.table == "messages"
                ? "UPDATE messages SET mailbox_kind = ?1 WHERE mailbox = ?2;"
                : "UPDATE folders SET kind = ?1 WHERE name = ?2;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                bindText(stmt, index: 1, pair.kind)
                bindText(stmt, index: 2, pair.name)
                _ = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
        exec("COMMIT;", on: db)
    }

    private func upsertSummaryLocked(
        _ summary: MailSummary,
        cc: [String] = [],
        bcc: [String] = [],
        hasBody: Bool = false,
        now: Double,
        on db: OpaquePointer
    ) {
        let nativeID = MessageLocator.parse(summary.id).nativeID
        let toJSON = encodeStringArray(summary.to)
        let ccJSON = encodeStringArray(cc)
        let bccJSON = encodeStringArray(bcc)
        let labelsJSON = encodeStringArray(summary.labels)
        let mailbox = summary.mailbox ?? MessageLocator.parse(summary.id).imapFolder
        let kind = summary.mailboxKind ?? mailbox.map { MailboxMatcher.kind(ofName: $0).rawValue }

        let sql = """
        INSERT INTO messages (
            account_id, message_id, native_id, account_email, thread_id,
            from_addr, to_json, cc_json, bcc_json, subject, date_ts,
            snippet, is_unread, labels_json, mailbox, mailbox_kind, has_body, updated_at
        )
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
        ON CONFLICT(account_id, message_id) DO UPDATE SET
            thread_id = COALESCE(excluded.thread_id, messages.thread_id),
            from_addr = excluded.from_addr,
            to_json = excluded.to_json,
            cc_json = CASE WHEN excluded.cc_json = '[]' THEN messages.cc_json ELSE excluded.cc_json END,
            bcc_json = CASE WHEN excluded.bcc_json = '[]' THEN messages.bcc_json ELSE excluded.bcc_json END,
            subject = excluded.subject,
            date_ts = COALESCE(excluded.date_ts, messages.date_ts),
            snippet = CASE WHEN excluded.snippet = '' THEN messages.snippet ELSE excluded.snippet END,
            is_unread = excluded.is_unread,
            labels_json = excluded.labels_json,
            mailbox = COALESCE(excluded.mailbox, messages.mailbox),
            mailbox_kind = COALESCE(excluded.mailbox_kind, messages.mailbox_kind),
            has_body = MAX(messages.has_body, excluded.has_body),
            updated_at = excluded.updated_at;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
            bindText(stmt, index: 1, summary.accountID.uuidString)
            bindText(stmt, index: 2, summary.id)
            bindText(stmt, index: 3, nativeID)
            bindText(stmt, index: 4, summary.accountEmail)
            bindOptionalText(stmt, index: 5, summary.threadID)
            bindText(stmt, index: 6, summary.from)
            bindText(stmt, index: 7, toJSON)
            bindText(stmt, index: 8, ccJSON)
            bindText(stmt, index: 9, bccJSON)
            bindText(stmt, index: 10, summary.subject)
            bindOptionalDouble(stmt, index: 11, summary.date?.timeIntervalSince1970)
            bindText(stmt, index: 12, summary.snippet)
            sqlite3_bind_int(stmt, 13, summary.isUnread ? 1 : 0)
            bindText(stmt, index: 14, labelsJSON)
            bindOptionalText(stmt, index: 15, mailbox)
            bindOptionalText(stmt, index: 16, kind)
            sqlite3_bind_int(stmt, 17, hasBody ? 1 : 0)
            sqlite3_bind_double(stmt, 18, now)
            _ = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        refreshFTSLocked(accountID: summary.accountID.uuidString, messageID: summary.id, bodyText: nil, on: db)
    }

    private func refreshFTSLocked(accountID: String, messageID: String, bodyText: String?, on db: OpaquePointer) {
        let lookupSQL = """
        SELECT m.rowid, m.from_addr, m.to_json, m.subject, m.snippet, COALESCE(b.body_text, '')
        FROM messages m
        LEFT JOIN message_bodies b
            ON m.account_id = b.account_id AND m.message_id = b.message_id
        WHERE m.account_id = ?1 AND m.message_id = ?2
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, lookupSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        bindText(stmt, index: 1, accountID)
        bindText(stmt, index: 2, messageID)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_finalize(stmt)
            return
        }
        let rowid = sqlite3_column_int64(stmt, 0)
        let fromAddr = columnText(stmt, 1) ?? ""
        let toAddrs = decodeStringArray(columnText(stmt, 2)).joined(separator: " ")
        let subject = columnText(stmt, 3) ?? ""
        let snippet = columnText(stmt, 4) ?? ""
        let resolvedBody = bodyText ?? columnText(stmt, 5) ?? ""
        sqlite3_finalize(stmt)

        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM messages_fts WHERE rowid = ?1;", -1, &delStmt, nil) == SQLITE_OK, let delStmt {
            sqlite3_bind_int64(delStmt, 1, rowid)
            _ = sqlite3_step(delStmt)
            sqlite3_finalize(delStmt)
        }

        let insertSQL = """
        INSERT INTO messages_fts (rowid, from_addr, to_addrs, subject, snippet, body_text)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6);
        """
        var insStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, insertSQL, -1, &insStmt, nil) == SQLITE_OK, let insStmt {
            sqlite3_bind_int64(insStmt, 1, rowid)
            bindText(insStmt, index: 2, fromAddr)
            bindText(insStmt, index: 3, toAddrs)
            bindText(insStmt, index: 4, subject)
            bindText(insStmt, index: 5, snippet)
            bindText(insStmt, index: 6, resolvedBody)
            _ = sqlite3_step(insStmt)
            sqlite3_finalize(insStmt)
        }
    }

    private func updateLabelsLocked(
        accountID: UUID,
        id: String,
        add: [String],
        remove: [String],
        folder: String?,
        on db: OpaquePointer
    ) {
        let nativeID = MessageLocator.parse(id).nativeID
        let selectSQL = "SELECT message_id, labels_json, mailbox, mailbox_kind FROM messages WHERE account_id = ?1 AND (message_id = ?2 OR native_id = ?3) LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        bindText(stmt, index: 1, accountID.uuidString)
        bindText(stmt, index: 2, id)
        bindText(stmt, index: 3, nativeID)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_finalize(stmt)
            return
        }
        let messageID = columnText(stmt, 0) ?? id
        var labels = decodeStringArray(columnText(stmt, 1))
        var mailbox = columnText(stmt, 2)
        var mailboxKind = columnText(stmt, 3)
        sqlite3_finalize(stmt)

        for item in remove {
            labels.removeAll { $0.caseInsensitiveCompare(item) == .orderedSame }
        }
        for item in add where !labels.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }) {
            labels.append(item)
        }
        if let folder, !folder.isEmpty {
            mailbox = folder
            mailboxKind = MailboxMatcher.kind(ofName: folder).rawValue
        }

        let updateSQL = "UPDATE messages SET labels_json = ?1, mailbox = ?2, mailbox_kind = ?3 WHERE account_id = ?4 AND message_id = ?5;"
        var upStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, updateSQL, -1, &upStmt, nil) == SQLITE_OK, let upStmt {
            bindText(upStmt, index: 1, encodeStringArray(labels))
            bindOptionalText(upStmt, index: 2, mailbox)
            bindOptionalText(upStmt, index: 3, mailboxKind)
            bindText(upStmt, index: 4, accountID.uuidString)
            bindText(upStmt, index: 5, messageID)
            _ = sqlite3_step(upStmt)
            sqlite3_finalize(upStmt)
        }
    }

    private func searchWithLikeFallbackLocked(
        accountID: UUID,
        mailboxes: [String]?,
        parsed: ParsedCacheQuery,
        after: Date?,
        before: Date?,
        limit: Int,
        on db: OpaquePointer
    ) -> [MailSummary] {
        var clauses: [String] = ["m.account_id = ?"]
        var bindings: [SQLBindValue] = [.text(accountID.uuidString)]

        if let mailboxes, !mailboxes.isEmpty {
            let nonAnywhere = mailboxes.filter { $0.lowercased() != "anywhere" && $0.lowercased() != "everywhere" }
            if !nonAnywhere.isEmpty {
                var subClauses: [String] = []
                for box in nonAnywhere {
                    let kind = MailboxMatcher.kind(ofName: box).rawValue
                    subClauses.append("(LOWER(m.mailbox) = LOWER(?) OR LOWER(m.mailbox_kind) = LOWER(?))")
                    bindings.append(.text(box))
                    bindings.append(.text(kind))
                }
                clauses.append("(" + subClauses.joined(separator: " OR ") + ")")
            }
        }
        for token in parsed.textTokens {
            let pat = "%\(token.lowercased())%"
            clauses.append("(LOWER(m.subject) LIKE ? OR LOWER(m.snippet) LIKE ? OR LOWER(m.from_addr) LIKE ?)")
            bindings.append(.text(pat))
            bindings.append(.text(pat))
            bindings.append(.text(pat))
        }
        if let after {
            clauses.append("m.date_ts >= ?")
            bindings.append(.double(after.timeIntervalSince1970))
        }
        if let before {
            clauses.append("m.date_ts < ?")
            bindings.append(.double(before.timeIntervalSince1970))
        }
        let sql = """
        SELECT m.message_id, m.account_email, m.thread_id, m.from_addr, m.to_json,
               m.subject, m.date_ts, m.snippet, m.is_unread, m.labels_json,
               m.mailbox, m.mailbox_kind
        FROM messages m
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY COALESCE(m.date_ts, 0) DESC
        LIMIT \(limit);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (idx, value) in bindings.enumerated() {
            let pos = Int32(idx + 1)
            switch value {
            case .text(let s): bindText(stmt, index: pos, s)
            case .int(let i): sqlite3_bind_int(stmt, pos, Int32(i))
            case .double(let d): sqlite3_bind_double(stmt, pos, d)
            }
        }
        return collectSummariesLocked(stmt: stmt, accountID: accountID)
    }

    private func collectSummariesLocked(stmt: OpaquePointer, accountID: UUID) -> [MailSummary] {
        var hits: [MailSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = columnText(stmt, 0) ?? ""
            let email = columnText(stmt, 1) ?? ""
            let threadID = columnText(stmt, 2)
            let from = columnText(stmt, 3) ?? ""
            let to = decodeStringArray(columnText(stmt, 4))
            let subject = columnText(stmt, 5) ?? "(no subject)"
            let date = columnOptionalDate(stmt, 6)
            let snippet = columnText(stmt, 7) ?? ""
            let isUnread = sqlite3_column_int(stmt, 8) != 0
            let labels = decodeStringArray(columnText(stmt, 9))
            let mailbox = columnText(stmt, 10)
            let mailboxKind = columnText(stmt, 11)
            hits.append(
                MailSummary(
                    id: id,
                    accountID: accountID,
                    accountEmail: email,
                    threadID: threadID,
                    from: from,
                    to: to,
                    subject: subject,
                    date: date,
                    snippet: snippet,
                    isUnread: isUnread,
                    labels: labels,
                    mailbox: mailbox,
                    mailboxKind: mailboxKind
                )
            )
        }
        return hits
    }

    private static func makeFTSExpression(_ tokens: [String]) -> String? {
        var cleaned: [String] = []
        for token in tokens {
            let safe = token
                .replacingOccurrences(of: "\"", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if safe.isEmpty { continue }
            cleaned.append("\"\(safe)\"")
        }
        guard !cleaned.isEmpty else { return nil }
        return cleaned.joined(separator: " AND ")
    }

    private enum SQLBindValue {
        case text(String)
        case int(Int)
        case double(Double)
    }

    private func exec(_ sql: String, on db: OpaquePointer) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func scalarInt(_ sql: String, on db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func scalarInt(_ sql: String, param: String, on db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, param)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Coalesced: a sync writes in many small batches, and each notification re-renders every cache-backed view.
    private func notifyChange() {
        guard self === MailboxCacheStore.shared else { return }
        notifyLock.lock()
        defer { notifyLock.unlock() }
        guard !notifyPending else { return }
        notifyPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.notifyLock.lock()
            self.notifyPending = false
            self.notifyLock.unlock()
            NotificationCenter.default.post(name: .mailboxCacheDidChange, object: nil)
        }
    }

    private func bindText(_ stmt: OpaquePointer, index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT_DESTRUCTOR)
    }

    private func bindOptionalText(_ stmt: OpaquePointer, index: Int32, _ value: String?) {
        if let value {
            bindText(stmt, index: index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindOptionalInt(_ stmt: OpaquePointer, index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int(stmt, index, Int32(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindOptionalDouble(_ stmt: OpaquePointer, index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, index) else {
            return nil
        }
        return String(cString: cStr)
    }

    private func columnOptionalInt(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(stmt, index))
    }

    private func columnOptionalDate(_ stmt: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }

    private func encodeStringArray(_ values: [String]) -> String {
        guard let data = try? JSONCoders.encoder.encode(values) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeStringArray(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8),
              let values = try? JSONCoders.decoder.decode([String].self, from: data) else {
            return []
        }
        return values
    }

    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

private struct ParsedCacheQuery {
    var fromTokens: [String] = []
    var toTokens: [String] = []
    var subjectTokens: [String] = []
    var unreadOnly: Bool?
    var textTokens: [String] = []

    static func parse(_ raw: String) -> ParsedCacheQuery {
        var remaining = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ParsedCacheQuery()
        if remaining.isEmpty { return result }

        _ = takePrefixedToken(prefix: "in:", from: &remaining)
        while let token = takePrefixedToken(prefix: "from:", from: &remaining) {
            result.fromTokens.append(token)
        }
        while let token = takePrefixedToken(prefix: "to:", from: &remaining) {
            result.toTokens.append(token)
        }
        while let token = takePrefixedToken(prefix: "subject:", from: &remaining) {
            result.subjectTokens.append(token)
        }
        while let token = takePrefixedToken(prefix: "is:", from: &remaining) {
            if token.lowercased() == "unread" { result.unreadOnly = true }
            if token.lowercased() == "read" { result.unreadOnly = false }
        }
        remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if remaining.lowercased() == "unseen" {
            result.unreadOnly = true
            return result
        }
        if remaining.count >= 2, remaining.hasPrefix("\""), remaining.hasSuffix("\"") {
            let phrase = String(remaining.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            if !phrase.isEmpty { result.textTokens.append(phrase) }
        } else {
            result.textTokens = remaining
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter { !$0.isEmpty }
        }
        return result
    }
}
