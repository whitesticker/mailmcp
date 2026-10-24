import Foundation

protocol MailProviding: Sendable {
    func testConnection() async throws -> String
    func fetchWatermark() async throws -> String
    func search(query: String, limit: Int) async throws -> [MailSummary]
    func messageCount(query: String) async throws -> Int
    func listFolders() async throws -> [MailFolderCount]
    func listFolders(includeCounts: Bool) async throws -> [MailFolderCount]
    func resolveMailboxes(_ requested: [String]) async throws -> [ResolvedMailbox]
    func searchFoldered(_ request: FolderSearchSpec) async throws -> [MailSummary]
    func getMessage(id: String) async throws -> MailMessage
    func fetchMessagesLightweight(ids: [String]) async throws -> (messages: [MailMessage], bytesDownloaded: Int64)
    func listThreads(query: String?, limit: Int) async throws -> [MailThread]
    func modify(id: String, action: MailModifyAction, label: String?) async throws
    func createDraft(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws -> String
    func send(to: [String], cc: [String], bcc: [String], subject: String, body: String, extraHeaders: [String: String]) async throws -> String
    func getAttachment(messageID: String, attachmentID: String) async throws -> MailAttachmentData
    func getThread(id: String, limit: Int) async throws -> [MailMessage]
    func listDrafts(limit: Int) async throws -> [MailDraft]
    func updateDraft(id: String, to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws -> String
    func deleteDraft(id: String) async throws
    func fileMessage(id: String, folder: String?, addLabels: [String], removeLabels: [String]) async throws
    func fileMatching(query: String, folder: String, mailbox: String?, limit: Int?) async throws -> Int
    func frequentContacts(limit: Int) async throws -> [MailContact]
}

extension MailProviding {
    func fetchWatermark() async throws -> String {
        let count = try await messageCount(query: "")
        return "count:\(count)"
    }

    func listFolders() async throws -> [MailFolderCount] {
        try await listFolders(includeCounts: false)
    }

    func fetchMessagesLightweight(ids: [String]) async throws -> (messages: [MailMessage], bytesDownloaded: Int64) {
        var result: [MailMessage] = []
        var bytes: Int64 = 0
        for id in ids {
            try Task.checkCancellation()
            if let message = try? await getMessage(id: id) {
                result.append(message)
                bytes += Int64(message.body.utf8.count + (message.bodyHTML?.utf8.count ?? 0) + 1024)
            }
        }
        return (result, bytes)
    }

    func resolveMailboxes(_ requested: [String]) async throws -> [ResolvedMailbox] {
        let folders = try await listFolders(includeCounts: false)
        let hints = folders.map { FolderHint(name: $0.name, remoteID: $0.remoteID) }
        let requests = requested.flatMap { MailboxRequest.parse($0) }
        return MailboxMatcher.resolve(requests, folders: hints)
    }

    func searchFoldered(_ request: FolderSearchSpec) async throws -> [MailSummary] {
        var hits: [MailSummary] = []
        let boxes = request.mailboxes.isEmpty ? ["INBOX"] : request.mailboxes
        for mailbox in boxes {
            var query = request.query
            if !mailbox.isEmpty, !query.lowercased().contains("in:") {
                query = query.isEmpty ? "in:\(mailbox)" : "in:\(mailbox) \(query)"
            }
            let found = try await search(query: query, limit: request.limit)
            hits.append(contentsOf: found.map { summary in
                var copy = summary
                if copy.mailbox == nil { copy.mailbox = mailbox }
                if copy.mailboxKind == nil { copy.mailboxKind = MailboxMatcher.kind(ofName: mailbox).rawValue }
                return copy
            })
            if hits.count >= request.limit { break }
        }
        if let after = request.after {
            hits = hits.filter { ($0.date ?? .distantFuture) >= after }
        }
        if let before = request.before {
            hits = hits.filter { ($0.date ?? .distantPast) < before }
        }
        return Array(hits.prefix(max(request.limit, 1)))
    }

    func fileMatching(query: String, folder: String, mailbox: String? = nil, limit: Int? = nil) async throws -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MailMCPError.invalidInput("query is required; refusing to file the entire mailbox")
        }
        let dest = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty else {
            throw MailMCPError.invalidInput("folder is required")
        }
        var scoped = trimmed
        if let mailbox, !mailbox.isEmpty, !scoped.lowercased().contains("in:") {
            scoped = "in:\(mailbox) \(scoped)"
        }
        var filed = 0
        let cap = limit ?? Int.max
        while filed < cap {
            let batch = min(50, cap - filed)
            let hits = try await search(query: scoped, limit: batch)
            if hits.isEmpty { break }
            for hit in hits {
                try await fileMessage(id: hit.id, folder: dest, addLabels: [], removeLabels: [])
                filed += 1
                if filed >= cap { break }
            }
            if hits.count < batch { break }
        }
        return filed
    }
}

enum MailProviderFactory {
    @MainActor
    static func make(account: MailAccount, onTokens: @escaping @MainActor (OAuthTokens) -> Void) throws -> any MailProviding {
        switch account.provider {
        case .imap:
            guard let settings = account.imap else {
                throw MailMCPError.invalidInput("IMAP settings missing for \(account.email)")
            }
            return IMAPProvider(
                account: account,
                settings: try settings.resolvingBlankHosts(for: account.email)
            )
        case .gmail:
            guard let oauth = account.oauth else {
                throw MailMCPError.oauth("Gmail account is not signed in")
            }
            return GmailProvider(account: account, tokens: oauth, onTokens: onTokens)
        case .outlook:
            guard let oauth = account.oauth else {
                throw MailMCPError.oauth("Outlook account is not signed in")
            }
            return GraphProvider(account: account, tokens: oauth, onTokens: onTokens)
        }
    }
}
