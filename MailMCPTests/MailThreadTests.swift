import XCTest
import SQLite3
import SwiftMail
@testable import MailMCP

final class MailThreadTests: XCTestCase {
    private let account = MailAccount(provider: .imap, email: "me@example.com")

    func testThreadKeyIsConversationRoot() {
        let root = MessageID("<root@example.com>")
        let parent = MessageID("<parent@example.com>")
        let own = MessageID("<own@example.com>")
        let reply = MessageInfo(sequenceNumber: SequenceNumber(1), messageId: own, inReplyTo: parent, references: [root!, parent!])
        XCTAssertEqual(IMAPProvider.threadKey(reply), "<root@example.com>")

        let noReferences = MessageInfo(sequenceNumber: SequenceNumber(2), messageId: own, inReplyTo: parent)
        XCTAssertEqual(IMAPProvider.threadKey(noReferences), "<parent@example.com>")

        let first = MessageInfo(sequenceNumber: SequenceNumber(3), messageId: root)
        XCTAssertEqual(IMAPProvider.threadKey(first), "<root@example.com>")
    }

    private func summary(
        _ id: String, thread: String?, from: String, minutesAgo: Double,
        subject: String = "Plans", folder: String = "INBOX", rfc: String? = nil
    ) -> MailSummary {
        MailSummary(
            id: id, accountID: account.id, accountEmail: account.email, threadID: thread, from: from,
            to: [account.email], subject: subject, date: Date(timeIntervalSince1970: 1_700_000_000 - minutesAgo * 60),
            snippet: "", isUnread: false, labels: [], mailbox: folder, mailboxKind: "inbox", rfcMessageID: rfc
        )
    }

    func testGroupingMergesRepliesAndDropsFolderCopies() {
        let messages = [
            summary("imap|INBOX|1", thread: "<root@x>", from: "Ann", minutesAgo: 30),
            summary("imap|[Gmail]/All Mail|9", thread: "<root@x>", from: "Ann", minutesAgo: 30, folder: "[Gmail]/All Mail"),
            summary("imap|INBOX|2", thread: "<root@x>", from: "Bob", minutesAgo: 10, subject: "Re: Plans"),
            summary("imap|INBOX|3", thread: "<other@x>", from: "Cat", minutesAgo: 20, subject: "Other")
        ]
        let threads = MailThread.grouping(messages, account: account, knownCounts: ["<other@x>": 4])
        XCTAssertEqual(threads.map(\.id), ["<root@x>", "<other@x>"])
        XCTAssertEqual(threads[0].messageCount, 2)
        XCTAssertEqual(threads[0].participants, ["Ann", "Bob"])
        XCTAssertEqual(threads[0].subject, "Re: Plans")
        XCTAssertEqual(threads[1].messageCount, 4)
    }

    private func makeStore() -> (MailboxCacheStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MailThreadTests-\(UUID().uuidString)", isDirectory: true)
        return (MailboxCacheStore(directoryURL: dir), dir)
    }

    func testCacheCountsThreadMessagesOnce() {
        let (store, dir) = makeStore()
        defer { store.close(); try? FileManager.default.removeItem(at: dir) }
        store.saveSummaries([
            summary("imap|INBOX|1", thread: "<root@x>", from: "Ann", minutesAgo: 30),
            summary("imap|[Gmail]/All Mail|9", thread: "<root@x>", from: "Ann", minutesAgo: 30, folder: "[Gmail]/All Mail"),
            summary("imap|[Gmail]/All Mail|10", thread: "<root@x>", from: "Me", minutesAgo: 5, subject: "Re: Plans", folder: "[Gmail]/All Mail"),
            summary("imap|INBOX|3", thread: "<other@x>", from: "Cat", minutesAgo: 20, subject: "Other")
        ])
        let counts = store.threadMessageCounts(accountID: account.id, threadIDs: ["<root@x>", "<other@x>", "<none@x>"])
        XCTAssertEqual(counts, ["<root@x>": 2, "<other@x>": 1])
    }

    /// A reply whose References name only its parent (seen from Outlook-based senders) still joins the thread.
    func testCacheLinksRepliesThatSkipTheRoot() {
        let original = summary("imap|INBOX|1", thread: "<root@x>", from: "BAL", minutesAgo: 60, rfc: "<root@x>")
        let mine = summary("imap|Sent|2", thread: "<root@x>", from: "Me", minutesAgo: 30, folder: "Sent", rfc: "<mine@x>")
        let theirs = summary("imap|INBOX|3", thread: "<mine@x>", from: "Anna", minutesAgo: 10, rfc: "<anna@x>")
        for order in [[original, mine, theirs], [theirs, original, mine]] {
            let (store, dir) = makeStore()
            defer { store.close(); try? FileManager.default.removeItem(at: dir) }
            for item in order { store.saveSummaries([item]) }
            XCTAssertEqual(store.threadMessageCounts(accountID: account.id, threadIDs: ["<root@x>", "<mine@x>"]), ["<root@x>": 3])
            XCTAssertEqual(store.canonicalThreadIDs(accountID: account.id, keys: ["<mine@x>"]), ["<mine@x>": "<root@x>"])
        }
    }

    func testThreadSummariesDropFolderCopiesPreferringTheOpenFolder() {
        let (store, dir) = makeStore()
        defer { store.close(); try? FileManager.default.removeItem(at: dir) }
        func copy(_ id: String, _ from: String, _ minutes: Double, _ folder: String, _ kind: String) -> MailSummary {
            var item = summary(id, thread: "<root@x>", from: from, minutesAgo: minutes, folder: folder)
            item.mailboxKind = kind
            return item
        }
        store.saveSummaries([
            copy("imap|[Gmail]/All Mail|1", "Ann", 30, "[Gmail]/All Mail", "all"),
            copy("imap|INBOX|7", "Ann", 30, "INBOX", "inbox"),
            copy("imap|[Gmail]/All Mail|2", "Me", 20, "[Gmail]/All Mail", "all"),
            copy("imap|[Gmail]/Sent Mail|5", "Me", 20, "[Gmail]/Sent Mail", "sent"),
            copy("imap|[Gmail]/All Mail|3", "Bob", 10, "[Gmail]/All Mail", "all")
        ])
        let ids = store.threadSummaries(accountID: account.id, threadID: "<root@x>", preferredMailbox: "INBOX").map(\.id)
        XCTAssertEqual(ids, ["imap|INBOX|7", "imap|[Gmail]/Sent Mail|5", "imap|[Gmail]/All Mail|3"])
    }

    private struct NIOConnectionError: Error, CustomStringConvertible {
        var description: String { "NIOConnectionError(host: imap.gmail.com, port: 993, dnsAError: nil)" }
    }

    private struct RefusedError: Error, CustomStringConvertible {
        var description: String { "connect(descriptor:addr:size:): Connection refused (errno: 61)" }
    }

    func testConnectionErrorsReadAsAdvice() {
        let offline = MailMCPError.explainingConnection(NIOConnectionError(), host: "imap.gmail.com", port: 993)
        XCTAssertEqual(
            offline.localizedDescription,
            "Can’t reach imap.gmail.com:993. You appear to be offline, or the server name is wrong. Check your internet connection; background sync will try again on its own."
        )
        let refused = MailMCPError.explainingConnection(RefusedError(), host: "mail.example.com", port: 143)
        XCTAssertTrue(refused.localizedDescription.hasPrefix("mail.example.com:143 refused the connection."))
        let other = MailMCPError.explainingConnection(MailMCPError.provider("Bad UID"), host: "h", port: 1)
        XCTAssertEqual(other.localizedDescription, "Bad UID")
    }

    func testThreadRefreshForgetsIMAPWatermarksOnce() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gmail = MailAccount(provider: .gmail, email: "g@example.com")
        store.saveSummaries([summary("imap|INBOX|1", thread: "<own@x>", from: "Ann", minutesAgo: 1)])
        store.saveAccountWatermark(accountID: account.id, watermark: "uidnext:5", syncedAt: Date())
        store.saveAccountWatermark(accountID: gmail.id, watermark: "history:1", syncedAt: Date())

        store.refreshIMAPThreadIDsIfNeeded()
        XCTAssertEqual(store.accountWatermark(accountID: account.id).watermark, "uidnext:5", "waits for the preview backfill")

        store.backfillPreviewsIfNeeded()
        store.refreshIMAPThreadIDsIfNeeded()
        XCTAssertNil(store.accountWatermark(accountID: account.id).watermark)
        XCTAssertEqual(store.accountWatermark(accountID: gmail.id).watermark, "history:1")

        store.saveAccountWatermark(accountID: account.id, watermark: "uidnext:6", syncedAt: Date())
        store.refreshIMAPThreadIDsIfNeeded()
        XCTAssertEqual(store.accountWatermark(accountID: account.id).watermark, "uidnext:6")
        store.close()
    }

    // MARK: - IMAP UIDs are per folder

    private func message(_ id: String, folder: String, body: String, unread: Bool = true) -> MailMessage {
        MailMessage(
            id: id, accountID: account.id, accountEmail: account.email, threadID: nil, from: "Ann", to: [account.email],
            cc: [], bcc: [], subject: body, date: Date(timeIntervalSince1970: 1_700_000_000), body: body, bodyHTML: nil,
            isUnread: unread, labels: [], attachments: [], mailbox: folder, mailboxKind: "inbox"
        )
    }

    func testIMAPLookupsNeverBorrowAnotherFoldersUID() {
        let (store, dir) = makeStore()
        defer { store.close(); try? FileManager.default.removeItem(at: dir) }
        store.saveMessages([message("imap|INBOX|9", folder: "INBOX", body: "Newsletter")])
        store.saveSummaries([summary("imap|%5BGmail%5D%2FSpam|9", thread: nil, from: "Lainey", minutesAgo: 1, folder: "[Gmail]/Spam")])

        XCTAssertNil(store.getMessage(accountID: account.id, id: "imap|%5BGmail%5D%2FSpam|9"), "uncached body must go to the server")
        store.applyModify(accountID: account.id, id: "imap|%5BGmail%5D%2FSpam|9", action: .markRead, label: nil)
        XCTAssertEqual(store.getMessage(accountID: account.id, id: "imap|INBOX|9")?.isUnread, true)
    }

    func testIMAPMoveDropsTheStaleRowAndRepairRemovesMislabeledOnes() {
        let (store, dir) = makeStore()
        defer { store.close(); try? FileManager.default.removeItem(at: dir) }
        store.saveMessages([message("imap|INBOX|9", folder: "INBOX", body: "Newsletter")])
        store.saveSummaries([
            summary("imap|%5BGmail%5D%2FSpam|9", thread: nil, from: "Lainey", minutesAgo: 1, folder: "[Gmail]/Spam"),
            summary("imap|%5BGmail%5D%2FSpam|5", thread: nil, from: "Old", minutesAgo: 2, folder: "INBOX")
        ])
        let inbox = { store.search(accountID: self.account.id, mailboxes: ["INBOX"], query: "", after: nil, before: nil, limit: 10).map(\.id) }

        store.applyFileMessage(accountID: account.id, id: "imap|%5BGmail%5D%2FSpam|9", folder: "INBOX", addLabels: [], removeLabels: [])
        XCTAssertEqual(Set(inbox()), ["imap|INBOX|9", "imap|%5BGmail%5D%2FSpam|5"])

        store.backfillPreviewsIfNeeded()
        store.refreshIMAPThreadIDsIfNeeded()
        store.dropMislabeledIMAPRowsIfNeeded()
        XCTAssertEqual(inbox(), ["imap|INBOX|9"])
    }
}
