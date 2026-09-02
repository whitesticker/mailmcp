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
    func frequentContacts(limit: Int) async throws -> [MailContact]
}

enum MailProviderFactory {
    @MainActor
    static func make(account: MailAccount, onTokens: @escaping @MainActor (OAuthTokens) -> Void) throws -> any MailProviding {
        switch account.provider {
        case .imap:
            guard let settings = account.imap else {
                throw MailMCPError.invalidInput("IMAP settings missing for \(account.email)")
            }
            return IMAPProvider(account: account, settings: settings)
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
