import Foundation

struct FolderSearchSpec: Sendable {
    var query: String
    var mailboxes: [String]
    var after: Date?
    var before: Date?
    var limit: Int
}

struct MailSearchRequest: Sendable {
    var query: String
    var mailbox: String
    var accountIDs: [String]
    var after: Date?
    var before: Date?
    var limit: Int
    var skip: Int
    var timeout: TimeInterval
}

struct MailSearchQuery: Sendable {
    var text: String
    var mailbox: String?
    var after: Date?
    var before: Date?

    static func parse(_ raw: String) -> MailSearchQuery {
        var remaining = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var mailbox: String?
        var after: Date?
        var before: Date?
        if let token = takePrefixedToken(prefix: "in:", from: &remaining) {
            mailbox = token
        }
        if let token = takePrefixedToken(prefix: "after:", from: &remaining) {
            after = parseDate(token)
        }
        if let token = takePrefixedToken(prefix: "before:", from: &remaining) {
            before = parseDate(token)
        }
        return MailSearchQuery(text: remaining.trimmingCharacters(in: .whitespacesAndNewlines), mailbox: mailbox, after: after, before: before)
    }

    static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        if let date = iso.date(from: String(trimmed.prefix(10))) {
            return date
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd", "yyyy/MM/dd", "MMM d, yyyy", "MMMM d, yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    static func gmailDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }
}

struct FolderSearchReport: Codable, Sendable {
    var account: String
    var accountID: String
    var requested: String
    var kind: String
    var name: String
    var matched: Int
    var error: String?
}

struct AccountSearchReport: Codable, Sendable {
    var account: String
    var accountID: String
    var status: String
    var error: String?
    var foldersSearched: [String]
    var matched: Int
    var elapsedMs: Int
}

struct MailSearchResponse: Codable, Sendable {
    var status: String
    var query: String
    var mailbox: String
    var foldersSearched: [FolderSearchReport]
    var accounts: [AccountSearchReport]
    var messages: [MailSummary]
    var returned: Int
    var hasMore: Bool
    var nextCursor: String?
    var timedOut: Bool
    var cancelled: Bool
    var note: String
}

enum MailSearchStatus {
    static let ok = "ok"
    static let noMatches = "no_matches"
    static let partial = "partial"
    static let incomplete = "incomplete"
    static let unsupported = "unsupported"
    static let error = "error"

    static func resolve(
        messages: Int,
        accountStatuses: [String],
        timedOut: Bool,
        cancelled: Bool
    ) -> String {
        let unique = Set(accountStatuses)
        if unique.count == 1, unique.contains(unsupported) {
            return unsupported
        }
        if unique.count == 1, unique.contains(error), messages == 0 {
            return error
        }
        let failed = accountStatuses.contains { $0 == error || $0 == incomplete || $0 == unsupported }
        if messages > 0 {
            return failed || timedOut || cancelled ? partial : ok
        }
        if timedOut || cancelled || failed {
            return incomplete
        }
        return noMatches
    }
}

enum SearchCursor {
    static func encode(skip: Int) -> String {
        Data("skip:\(max(0, skip))".utf8).base64EncodedString()
    }

    static func decode(_ raw: String?) -> Int {
        guard let raw, !raw.isEmpty else { return 0 }
        if raw.hasPrefix("skip:") {
            return Int(raw.dropFirst(5)) ?? 0
        }
        guard let data = Data(base64Encoded: raw),
              let text = String(data: data, encoding: .utf8) else {
            return Int(raw) ?? 0
        }
        if text.hasPrefix("skip:") {
            return Int(text.dropFirst(5)) ?? 0
        }
        return Int(text) ?? 0
    }
}

enum MailSearchCoordinator {
    static func run(
        accounts: [(MailAccount, any MailProviding)],
        request: MailSearchRequest
    ) async -> MailSearchResponse {
        let parsed = MailSearchQuery.parse(request.query)
        let mailbox = request.mailbox.isEmpty ? (parsed.mailbox ?? "everywhere") : request.mailbox
        let query = parsed.text
        let after = request.after ?? parsed.after
        let before = request.before ?? parsed.before
        let fetchLimit = min(max(request.limit + request.skip, 1), 100)
        let timeout = request.timeout > 0 ? request.timeout : MailDeadline.searchDefault
        let started = Date()
        let gate = MailConcurrencyGate(limit: MailDeadline.accountConcurrency)

        var folderReports: [FolderSearchReport] = []
        var accountReports: [AccountSearchReport] = []
        var messages: [MailSummary] = []
        var timedOut = false
        var cancelled = false

        await withTaskGroup(of: AccountOutcome.self) { group in
            for (account, provider) in accounts {
                group.addTask {
                    do {
                        return try await gate.withPermit {
                            try await MailDeadline.withTimeout(seconds: timeout) {
                                try Task.checkCancellation()
                                return try await searchAccount(
                                    account: account,
                                    provider: provider,
                                    query: query,
                                    mailbox: mailbox,
                                    after: after,
                                    before: before,
                                    limit: fetchLimit
                                )
                            }
                        }
                    } catch is CancellationError {
                        return AccountOutcome.failed(
                            account: account,
                            status: MailSearchStatus.incomplete,
                            error: "cancelled",
                            elapsedMs: elapsedMs(since: started)
                        )
                    } catch let error as MailMCPError {
                        if case .timeout = error {
                            return AccountOutcome.failed(
                                account: account,
                                status: MailSearchStatus.incomplete,
                                error: error.localizedDescription,
                                elapsedMs: elapsedMs(since: started)
                            )
                        }
                        if case .notImplemented = error {
                            return AccountOutcome.failed(
                                account: account,
                                status: MailSearchStatus.unsupported,
                                error: error.localizedDescription,
                                elapsedMs: elapsedMs(since: started)
                            )
                        }
                        return AccountOutcome.failed(
                            account: account,
                            status: MailSearchStatus.error,
                            error: error.localizedDescription,
                            elapsedMs: elapsedMs(since: started)
                        )
                    } catch {
                        return AccountOutcome.failed(
                            account: account,
                            status: MailSearchStatus.error,
                            error: error.localizedDescription,
                            elapsedMs: elapsedMs(since: started)
                        )
                    }
                }
            }
            for await outcome in group {
                folderReports.append(contentsOf: outcome.folders)
                accountReports.append(outcome.report)
                messages.append(contentsOf: outcome.messages)
                if outcome.report.error == "cancelled" { cancelled = true }
                if outcome.report.error?.localizedCaseInsensitiveContains("timed out") == true { timedOut = true }
            }
        }

        messages.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let skipped = Array(messages.dropFirst(request.skip))
        let page = Array(skipped.prefix(max(request.limit, 1)))
        let hasMore = skipped.count > page.count
        let status = MailSearchStatus.resolve(
            messages: page.count,
            accountStatuses: accountReports.map(\.status),
            timedOut: timedOut,
            cancelled: cancelled
        )
        let note: String
        switch status {
        case MailSearchStatus.noMatches:
            note = "No matches in the folders searched. Spam and Trash are included when mailbox=everywhere."
        case MailSearchStatus.partial:
            note = "Some accounts or folders failed. Successful matches are still returned. Use message_id as returned to open mail in Spam or Trash."
        case MailSearchStatus.incomplete:
            note = "Search did not finish for every account. This is not the same as no matches."
        case MailSearchStatus.unsupported:
            note = "The query uses operators this provider does not support."
        case MailSearchStatus.error:
            note = "Every selected account failed. Check probe_accounts."
        default:
            note = "Matches include location-aware message_id values. Opening a message does not mark it read."
        }
        return MailSearchResponse(
            status: status,
            query: query,
            mailbox: mailbox,
            foldersSearched: folderReports,
            accounts: accountReports,
            messages: page,
            returned: page.count,
            hasMore: hasMore,
            nextCursor: hasMore ? SearchCursor.encode(skip: request.skip + page.count) : nil,
            timedOut: timedOut,
            cancelled: cancelled,
            note: note
        )
    }

    private struct AccountOutcome: Sendable {
        var report: AccountSearchReport
        var folders: [FolderSearchReport]
        var messages: [MailSummary]

        static func failed(account: MailAccount, status: String, error: String, elapsedMs: Int) -> AccountOutcome {
            AccountOutcome(
                report: AccountSearchReport(
                    account: account.email,
                    accountID: account.id.uuidString,
                    status: status,
                    error: error,
                    foldersSearched: [],
                    matched: 0,
                    elapsedMs: elapsedMs
                ),
                folders: [],
                messages: []
            )
        }
    }

    private static func searchAccount(
        account: MailAccount,
        provider: any MailProviding,
        query: String,
        mailbox: String,
        after: Date?,
        before: Date?,
        limit: Int
    ) async throws -> AccountOutcome {
        let started = Date()
        try Task.checkCancellation()
        let resolved = try await provider.resolveMailboxes(MailboxRequest.parse(mailbox).map(\.token))
        var folders: [FolderSearchReport] = []
        var hits: [MailSummary] = []
        var folderNames: [String] = []
        var lastError: String?
        var anyUnsupported = false

        let missing = resolved.filter { $0.name.isEmpty }
        let usable = resolved.filter { !$0.name.isEmpty }
        for item in missing {
            folders.append(
                FolderSearchReport(
                    account: account.email,
                    accountID: account.id.uuidString,
                    requested: item.requested,
                    kind: item.kind,
                    name: "",
                    matched: 0,
                    error: "Folder \(item.requested) was not found"
                )
            )
        }

        if !usable.isEmpty {
            do {
                let found = try await provider.searchFoldered(
                    FolderSearchSpec(
                        query: query,
                        mailboxes: usable.map(\.name),
                        after: after,
                        before: before,
                        limit: limit
                    )
                )
                hits = found
                var remaining = found
                for item in usable {
                    let matched = remaining.filter { summary in
                        summary.mailbox?.caseInsensitiveCompare(item.name) == .orderedSame
                            || summary.mailboxKind == item.kind
                    }
                    if !matched.isEmpty {
                        remaining.removeAll { summary in matched.contains(summary) }
                    }
                    let count: Int
                    if usable.count == 1 {
                        count = found.count
                    } else {
                        count = matched.count
                    }
                    folders.append(
                        FolderSearchReport(
                            account: account.email,
                            accountID: account.id.uuidString,
                            requested: item.requested,
                            kind: item.kind,
                            name: item.name,
                            matched: count,
                            error: nil
                        )
                    )
                    folderNames.append(item.name)
                }
            } catch let error as MailMCPError {
                if case .notImplemented = error {
                    anyUnsupported = true
                    lastError = error.localizedDescription
                } else {
                    lastError = error.localizedDescription
                }
                for item in usable {
                    folders.append(
                        FolderSearchReport(
                            account: account.email,
                            accountID: account.id.uuidString,
                            requested: item.requested,
                            kind: item.kind,
                            name: item.name,
                            matched: 0,
                            error: lastError
                        )
                    )
                }
            } catch {
                lastError = error.localizedDescription
                for item in usable {
                    folders.append(
                        FolderSearchReport(
                            account: account.email,
                            accountID: account.id.uuidString,
                            requested: item.requested,
                            kind: item.kind,
                            name: item.name,
                            matched: 0,
                            error: lastError
                        )
                    )
                }
            }
        }

        let status: String
        if anyUnsupported {
            status = MailSearchStatus.unsupported
        } else if lastError != nil, hits.isEmpty {
            status = MailSearchStatus.error
        } else if lastError != nil {
            status = MailSearchStatus.partial
        } else {
            status = hits.isEmpty ? MailSearchStatus.noMatches : MailSearchStatus.ok
        }
        return AccountOutcome(
            report: AccountSearchReport(
                account: account.email,
                accountID: account.id.uuidString,
                status: status,
                error: lastError,
                foldersSearched: folderNames,
                matched: hits.count,
                elapsedMs: elapsedMs(since: started)
            ),
            folders: folders,
            messages: hits
        )
    }

    private static func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

func takePrefixedToken(prefix: String, from remaining: inout String) -> String? {
    guard let range = remaining.range(of: prefix, options: .caseInsensitive) else { return nil }
    var index = range.upperBound
    while index < remaining.endIndex, remaining[index].isWhitespace {
        index = remaining.index(after: index)
    }
    guard index < remaining.endIndex else {
        remaining.removeSubrange(range.lowerBound..<remaining.endIndex)
        remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        return nil
    }
    let value: String
    let consumedEnd: String.Index
    if remaining[index] == "\"" {
        let innerStart = remaining.index(after: index)
        if let close = remaining[innerStart...].firstIndex(of: "\"") {
            value = String(remaining[innerStart..<close])
            consumedEnd = remaining.index(after: close)
        } else {
            value = String(remaining[innerStart...])
            consumedEnd = remaining.endIndex
        }
    } else {
        var end = index
        while end < remaining.endIndex, !remaining[end].isWhitespace {
            end = remaining.index(after: end)
        }
        value = String(remaining[index..<end])
        consumedEnd = end
    }
    remaining.removeSubrange(range.lowerBound..<consumedEnd)
    remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}
