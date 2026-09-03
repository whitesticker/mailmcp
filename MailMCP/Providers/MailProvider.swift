import Foundation

protocol MailProviding: Sendable {
    func testConnection() async throws -> String
    func search(query: String, limit: Int) async throws -> [MailSummary]
    func messageCount(query: String) async throws -> Int
    func listFolders() async throws -> [MailFolderCount]
    func getMessage(id: String) async throws -> MailMessage
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
