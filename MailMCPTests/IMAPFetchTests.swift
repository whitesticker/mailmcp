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

    func testMIMEDecodesQuotedPrintableHTML() {
        let raw = """
        From: Aeroplan <communications@mail.aircanada.com>\r
        Subject: Reminder\r
        MIME-Version: 1.0\r
        Content-Type: multipart/alternative; boundary="b1"\r
        \r
        --b1\r
        Content-Type: text/plain; charset=UTF-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Don=E2=80=99t miss out, offer ends Oct. 31. This line is long enough to be=\r
         soft wrapped.\r
        --b1\r
        Content-Type: text/html; charset=UTF-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        <table border=3D"0" cellpadding=3D"0"><tr><td>Don=E2=80=99t miss out</td></tr></table>\r
        --b1--\r
        """
        let parsed = MIMEParser.parse(raw: Data(raw.utf8))
        XCTAssertEqual(parsed.html?.trimmingCharacters(in: .whitespacesAndNewlines), "<table border=\"0\" cellpadding=\"0\"><tr><td>Don\u{2019}t miss out</td></tr></table>")
        XCTAssertEqual(parsed.text, "Don\u{2019}t miss out, offer ends Oct. 31. This line is long enough to be soft wrapped.")
        XCTAssertTrue(parsed.attachments.isEmpty)
    }

    func testMIMEWalksNestedMultipartWithBase64CharsetAndAttachment() {
        let html = Data("<p>Caf\u{E9} cr\u{E8}me</p>".data(using: .isoLatin1)!).base64EncodedString()
        let raw = """
        Content-Type: multipart/mixed; boundary=outer\r
        \r
        --outer\r
        Content-Type: multipart/alternative; boundary=inner\r
        \r
        --inner\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        plain body\r
        --inner\r
        Content-Type: text/html; charset=ISO-8859-1\r
        Content-Transfer-Encoding: base64\r
        \r
        \(html)\r
        --inner--\r
        --outer\r
        Content-Type: application/pdf; name="=?UTF-8?B?UmXMgXN1bcOpLnBkZg==?="\r
        Content-Disposition: attachment; filename="=?UTF-8?Q?R=C3=A9sum=C3=A9.pdf?="\r
        Content-Transfer-Encoding: base64\r
        \r
        JVBERi0xLjQK\r
        --outer--\r
        """
        let parsed = MIMEParser.parse(raw: Data(raw.utf8))
        XCTAssertEqual(parsed.text, "plain body")
        XCTAssertEqual(parsed.html?.trimmingCharacters(in: .whitespacesAndNewlines), "<p>Caf\u{E9} cr\u{E8}me</p>")
        XCTAssertEqual(parsed.attachments.count, 1)
        XCTAssertEqual(parsed.attachments.first?.id, "imap:2")
        XCTAssertEqual(parsed.attachments.first?.filename, "R\u{E9}sum\u{E9}.pdf")
        XCTAssertEqual(parsed.attachments.first?.mimeType, "application/pdf")
    }

    func testMIMEFallbackWithoutContentTypeHeader() {
        let raw = "--bound\r\nContent-Type: text/plain\r\n\r\nrecovered\r\n--bound--\r\n"
        let parsed = MIMEParser.plainText(from: [:], body: raw)
        XCTAssertEqual(parsed.text, "recovered")
    }
}
