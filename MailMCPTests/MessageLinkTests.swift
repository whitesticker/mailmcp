import XCTest
@testable import MailMCP

final class MessageLinkTests: XCTestCase {
    private let accountID = UUID(uuidString: "6F1C1A52-1D3B-4B7A-9E59-2E1B0C7D4F10")!

    func testRoundTripsIMAPLocator() {
        let id = MessageLocator.imap(folder: "[Gmail]/Spam", uid: "99").wire
        let url = MessageLink(accountID: accountID, messageID: id).url
        XCTAssertEqual(url.scheme, "mailmcp")
        XCTAssertEqual(url.host, "message")
        let parsed = MessageLink(url: url)
        XCTAssertEqual(parsed?.accountID, accountID)
        XCTAssertEqual(parsed?.messageID, id)
        XCTAssertEqual(parsed.map { MessageLocator.parse($0.messageID).imapFolder }, "[Gmail]/Spam")
    }

    func testRoundTripsGraphIdWithReservedCharacters() {
        let id = "AAMkAGI2+TU/x=&y=="
        let url = MessageLink(accountID: accountID, messageID: id).url
        XCTAssertFalse(url.absoluteString.contains("+"))
        XCTAssertFalse(url.absoluteString.contains("&y"))
        XCTAssertEqual(MessageLink(url: url)?.messageID, id)
    }

    func testToolResultsLinkMessagesButNotThreads() throws {
        struct Result: Encodable {
            var messages: [MailSummary]
            var threads: [MailThread]
        }
        let id = MessageLocator.imap(folder: "INBOX", uid: "42").wire
        let result = Result(
            messages: [MailSummary(id: id, accountID: accountID, accountEmail: "me@example.com", from: "a@example.com",
                                   to: [], subject: "Hi", date: nil, snippet: "", isUnread: false, labels: [])],
            threads: [MailThread(id: "t1", accountID: accountID, accountEmail: "me@example.com", subject: "Hi",
                                 participants: [], snippet: "", date: nil, messageCount: 1, isUnread: false)]
        )
        let json = try MailMCPTools.encodeLinked(result)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let message = try XCTUnwrap((object["messages"] as? [[String: Any]])?.first)
        let link = try XCTUnwrap(message["link"] as? String)
        XCTAssertEqual(MessageLink(url: try XCTUnwrap(URL(string: link)))?.messageID, id)
        XCTAssertNil((object["threads"] as? [[String: Any]])?.first?["link"])
        XCTAssertFalse(json.contains("\\/"), "links stay readable for agents")
    }

    func testRejectsIncompleteOrForeignLinks() {
        XCTAssertNil(MessageLink(url: URL(string: "mailmcp://message?id=abc")!))
        XCTAssertNil(MessageLink(url: URL(string: "mailmcp://message?account=not-a-uuid&id=abc")!))
        XCTAssertNil(MessageLink(url: URL(string: "mailmcp://message?account=\(accountID.uuidString)&id=")!))
        XCTAssertNil(MessageLink(url: URL(string: "mailmcp://oauth/callback?code=1")!))
        XCTAssertTrue(MessageLink.isMessageURL(URL(string: "mailmcp://message?id=abc")!))
        XCTAssertFalse(MessageLink.isMessageURL(URL(string: "mailmcp://oauth/callback")!))
    }
}
