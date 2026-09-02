import XCTest
@testable import MailMCP

final class IMAPFetchTests: XCTestCase {
    func testParseFetchReadsPeekHeaderAndText() {
        let header = "From: Ada <ada@example.com>\r\nTo: you@example.com\r\nSubject: test\r\nContent-Type: multipart/alternative; boundary=\"000000000000e8c0a3064d48c7e0\"\r\n\r\n"
        let text = """
        --000000000000e8c0a3064d48c7e0\r
        Content-Type: text/plain; charset="UTF-8"\r
        \r
        test\r
        --000000000000e8c0a3064d48c7e0--\r
        """
        let lines = [
            "* 1 FETCH (UID 3371 FLAGS (\\Seen) RFC822.SIZE 1234 BODY.PEEK[HEADER] {890}",
            "LITERAL \(Data(header.utf8).base64EncodedString())",
            " BODY.PEEK[TEXT]<0.200000> {200}",
            "LITERAL \(Data(text.utf8).base64EncodedString())",
            ")"
        ]
        let parsed = IMAPClient.parseFetch(lines: lines)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].uid, "3371")
        XCTAssertEqual(parsed[0].headers["from"], "Ada <ada@example.com>")
        XCTAssertEqual(parsed[0].headers["subject"], "test")
        let body = MIMEParser.plainText(from: parsed[0].headers, body: parsed[0].text)
        XCTAssertEqual(body.text, "test")
    }

    func testParseFetchHeaderOnContinuationLine() {
        let header = "From: Bob <bob@example.com>\r\nSubject: hello\r\n\r\n"
        let text = "hello body"
        let lines = [
            "* 1 FETCH (UID 42 FLAGS () RFC822.SIZE 10",
            " BODY[HEADER] {20}",
            "LITERAL \(Data(header.utf8).base64EncodedString())",
            " BODY[TEXT] {10}",
            "LITERAL \(Data(text.utf8).base64EncodedString())",
            ")"
        ]
        let parsed = IMAPClient.parseFetch(lines: lines)
        XCTAssertEqual(parsed.first?.headers["from"], "Bob <bob@example.com>")
        XCTAssertEqual(parsed.first?.text, "hello body")
    }

    func testMIMEFallbackWithoutContentTypeHeader() {
        let raw = "--bound\r\nContent-Type: text/plain\r\n\r\nrecovered\r\n--bound--\r\n"
        let parsed = MIMEParser.plainText(from: [:], body: raw)
        XCTAssertEqual(parsed.text, "recovered")
    }
}
