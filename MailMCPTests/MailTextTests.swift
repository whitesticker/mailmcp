import XCTest
import SQLite3
@testable import MailMCP

final class MailTextTests: XCTestCase {
    /// Shaped like a real newsletter: Outlook conditional comments, several style blocks, a hidden preheader padded with &#847;.
    private let newsletterHTML = """
    <!DOCTYPE html><html><head><title></title>
    <!--[if !mso]>--><meta http-equiv="X-UA-Compatible" content="IE=edge" /><!--<![endif]-->
    <style type="text/css">table { border-collapse: separate; } .ExternalClass { width: 100%; }</style>
    <style>@media (max-width: 480px) { .card { padding: 24px 20px !important; } }</style>
    <!--[if mso]><xml><o:PixelsPerInch>96</o:PixelsPerInch></xml><style>body { font-family: Arial; }</style><![endif]-->
    </head><body>
    <div style="display:none">Newsletter · Weekly Team Digest &#847; &#847; &#847; &zwnj;&nbsp;</div>
    <h1>Weekly Team Digest is ready</h1>
    <p><strong>Team &amp; Product</strong> developments from the past day.<br/>Second line</p>
    <table><tr><td>Cell A</td><td>Cell B</td></tr></table>
    </body></html>
    """

    func testPlainTextDropsStylesCommentsAndPadding() {
        let text = MailText.plainText(fromHTML: newsletterHTML)
        XCTAssertEqual(text, """
        Newsletter · Weekly Team Digest

        Weekly Team Digest is ready

        Team & Product developments from the past day.
        Second line

        Cell A Cell B
        """)
    }

    func testPreviewPrefersPreheader() {
        XCTAssertEqual(MailText.preview(body: "Weekly Team Digest is ready", html: newsletterHTML), "Newsletter · Weekly Team Digest")
        // A preheader that just repeats the subject is skipped.
        XCTAssertEqual(
            MailText.preview(body: "Weekly Team Digest is ready", html: newsletterHTML, subject: "newsletter · weekly team digest"),
            "Weekly Team Digest is ready"
        )
    }

    func testPreheaderIgnoresHiddenMenusFurtherDown() {
        let html = """
        <html><body><h1>Big sale this weekend on everything in the store, online and in person</h1>
        <div style="display:none">MEN WOMEN KIDS GIFTS</div><p>Details</p></body></html>
        """
        XCTAssertNil(MailText.preheader(fromHTML: html))
        XCTAssertNil(MailText.preheader(fromHTML: "<body><div style=\"display:none\">Gifts Women MEN GIRLS BOYS TODDLER</div></body>"))
        let layout = String(repeating: "Your package was shipped and arrives tomorrow. ", count: 10)
        XCTAssertNil(MailText.preheader(fromHTML: "<body><div style=\"display: none\">\(layout)</div></body>"))
        let classed = "<body><span class=\"preheader\">Your receipt from the coffee shop</span><table><tr><td>Logo</td></tr></table></body>"
        XCTAssertEqual(MailText.preheader(fromHTML: classed), "Your receipt from the coffee shop")
    }

    func testPreviewFallsBackToHTMLWhenTextIsLeakedCSS() {
        let html = newsletterHTML.replacingOccurrences(of: "style=\"display:none\"", with: "")
        let legacy = "--> table { border-collapse: separate; } .ExternalClass { width: 100%; } 96 Newsletter · Weekly Team Digest"
        XCTAssertTrue(MailText.looksLikeMarkup(legacy))
        XCTAssertEqual(
            MailText.preview(body: legacy, html: html),
            "Newsletter · Weekly Team Digest Weekly Team Digest is ready Team & Product developments from the past day. Second line Cell A Cell B"
        )
    }

    func testPreviewSkipsLinksPlaceholdersAndBoilerplate() {
        let body = """
        View as a Web page:
        https://trk.email.example.com/m/1/10000001/00-a00000

        [image: Example Shop logo]
        Your gift list is ready. ( https://example.com/list )
        Shop [Deals](https://example.com/deals) &copy; Example Shop banner1spring0sale0deals
        """
        XCTAssertEqual(MailText.preview(body: body, html: nil), "Your gift list is ready. Shop Deals © Example Shop")
    }

    func testPreviewDecodesEscapedMarkupInPlainText() {
        let body = "Example Store &zwnj;&#847;&zwnj; &lt;strong&gt;SPRING SALE&lt;/strong&gt; Ends 4/30."
        XCTAssertEqual(MailText.preview(body: body, html: nil), "Example Store SPRING SALE Ends 4/30.")
    }

    func testCleanSnippetKeepsSentencesBeforeInlineCSS() {
        XCTAssertEqual(
            MailText.cleanSnippet("Have you seen our latest offers, Alex? @media only screen{html{min-height:100%;background:#f3f3f3}}"),
            "Have you seen our latest offers, Alex?"
        )
        XCTAssertEqual(MailText.cleanSnippet("#outlook a { padding:0; } body { margin:0; }"), "")
    }

    func testPreviewLeavesOrdinaryProseAlone() {
        let body = "Hi {name}, your code is 1234.\n(555) 010-0000 (Note: pickup only)"
        XCTAssertFalse(MailText.looksLikeMarkup(body))
        XCTAssertEqual(MailText.preview(body: body, html: nil), "Hi {name}, your code is 1234. (555) 010-0000 (Note: pickup only)")
    }

    func testPreviewIsCappedAtPreviewLength() {
        let body = String(repeating: "word ", count: 200)
        XCTAssertEqual(MailText.preview(body: body, html: nil).count, MailText.previewLength)
    }

    // MARK: - Cache

    private func makeStore() -> (MailboxCacheStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MailTextTests-\(UUID().uuidString)", isDirectory: true)
        return (MailboxCacheStore(directoryURL: dir), dir)
    }

    private func message(_ id: String, account: MailAccount, body: String, html: String?) -> MailMessage {
        MailMessage(
            id: id, accountID: account.id, accountEmail: account.email, threadID: nil,
            from: "Sender <s@example.com>", to: [account.email], cc: [], bcc: [], subject: "Hello",
            date: Date(), body: body, bodyHTML: html, isUnread: false, labels: [], attachments: [],
            mailbox: "INBOX", mailboxKind: "inbox"
        )
    }

    private func summary(_ id: String, account: MailAccount, snippet: String) -> MailSummary {
        MailSummary(
            id: id, accountID: account.id, accountEmail: account.email, from: "Sender <s@example.com>",
            to: [account.email], subject: "Hello", date: Date(), snippet: snippet, isUnread: false,
            labels: [], mailbox: "INBOX", mailboxKind: "inbox"
        )
    }

    private func column(_ sql: String, in dir: URL) -> String? {
        var db: OpaquePointer?
        sqlite3_open_v2(dir.appendingPathComponent("envelope-index.sqlite").path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    func testCacheStoresCleanPreviewAndKeepsServerSnippets() {
        let (store, dir) = makeStore()
        defer { store.close(); try? FileManager.default.removeItem(at: dir) }
        let account = MailAccount(provider: .gmail, email: "a@example.com")

        store.saveSummaries([summary("gmail-1", account: account, snippet: "Server snippet")])
        store.saveMessage(message("gmail-1", account: account, body: "", html: newsletterHTML))
        XCTAssertEqual(column("SELECT snippet FROM messages WHERE message_id = 'gmail-1';", in: dir), "Server snippet")

        let imapID = MessageLocator.imap(folder: "INBOX", uid: "7").wire
        store.saveMessage(message(imapID, account: account, body: "", html: newsletterHTML))
        // A later header-only listing must not replace the preview.
        store.saveSummaries([summary(imapID, account: account, snippet: "")])
        XCTAssertEqual(column("SELECT snippet FROM messages WHERE message_id = '\(imapID)';", in: dir), "Newsletter · Weekly Team Digest")
    }

    func testBackfillRebuildsLegacyBodiesAndPreviews() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = MailAccount(provider: .imap, email: "b@example.com")
        let imapID = MessageLocator.imap(folder: "INBOX", uid: "9").wire
        store.saveMessage(message(imapID, account: account, body: "Hi", html: newsletterHTML))
        store.close()

        let legacy = "--> table { border-collapse: separate; } 96 Newsletter · Weekly Team Digest"
        var db: OpaquePointer?
        sqlite3_open_v2(dir.appendingPathComponent("envelope-index.sqlite").path, &db, SQLITE_OPEN_READWRITE, nil)
        sqlite3_exec(db, """
        UPDATE message_bodies SET body_text = '\(legacy)';
        UPDATE messages SET snippet = '\(legacy)';
        PRAGMA user_version = 3;
        """, nil, nil, nil)
        sqlite3_close(db)

        let reopened = MailboxCacheStore(directoryURL: dir)
        defer { reopened.close() }
        reopened.backfillPreviewsIfNeeded()

        let body = try XCTUnwrap(reopened.getMessage(accountID: account.id, id: imapID)?.body)
        XCTAssertTrue(body.hasPrefix("Newsletter · Weekly Team Digest\n\nWeekly Team Digest is ready"))
        XCTAssertEqual(column("SELECT snippet FROM messages WHERE message_id = '\(imapID)';", in: dir), "Newsletter · Weekly Team Digest")
        XCTAssertEqual(column("PRAGMA user_version;", in: dir), "5")
    }

    // MARK: - Quoted history

    func testOutlookReplyHidesHeaderBlockAndQuote() {
        let html = """
        <div><p>Thank you for letting us know.</p><p>Have a great day.</p></div>
        <hr style="display:inline-block;width:98%" tabindex="-1">
        <div id="divRplyFwdMsg" dir="ltr"><b>From:</b> Sam Lee &lt;w@example.com&gt;<br><b>Sent:</b> Monday, March 2, 2026 9:00 AM<br><b>Subject:</b> Re: Schedule question</div>
        <div>This is the earlier message we sent.</div>
        """
        let reply = MailQuote.reply(inHTML: html)
        XCTAssertNotNil(reply)
        XCTAssertTrue(reply!.contains("Have a great day."))
        XCTAssertFalse(reply!.contains("earlier message"))
        XCTAssertFalse(reply!.contains("<hr"))
    }

    func testOutlookDesktopHeaderWithoutContainer() {
        let html = """
        <p class="MsoNormal">Sounds good, see you then.</p>
        <div style="border:none;border-top:solid #E1E1E1 1.0pt"><p class="MsoNormal"><b><span>From:</span></b><span> Ann</span></p>
        <p class="MsoNormal"><b>Sent:</b> Monday</p><p class="MsoNormal"><b>Subject:</b> Lunch</p></div><p>Old text</p>
        """
        let reply = MailQuote.reply(inHTML: html)
        XCTAssertEqual(reply.map { MailText.plainText(fromHTML: $0) }, "Sounds good, see you then.")
    }

    func testGmailAndAppleQuotes() {
        let gmail = #"<div dir="ltr">Works for me.</div><br><div class="gmail_quote"><div class="gmail_attr">On Mon, Ann wrote:</div><blockquote>Old</blockquote></div>"#
        XCTAssertEqual(MailQuote.reply(inHTML: gmail).map { MailText.plainText(fromHTML: $0) }, "Works for me.")
        let apple = #"<div>Yes.</div><div><br><blockquote type="cite"><div>Old question?</div></blockquote></div>"#
        XCTAssertEqual(MailQuote.reply(inHTML: apple).map { MailText.plainText(fromHTML: $0) }, "Yes.")
    }

    func testForwardsAndQuoteOnlyBodiesStayWhole() {
        let forward = #"<div>FYI</div><div class="gmail_quote"><div class="gmail_attr">---------- Forwarded message ---------<br>From: Ann<br>Date: Mon<br>Subject: Plans</div><div>The plan</div></div>"#
        XCTAssertNil(MailQuote.reply(inHTML: forward))
        let outlookForward = #"<p>See below</p><hr><div id="divRplyFwdMsg"><b>From:</b> Ann<br><b>Sent:</b> Mon<br><b>Subject:</b> FW: Plans</div>"#
        XCTAssertNil(MailQuote.reply(inHTML: outlookForward))
        let quoteOnly = #"<div class="gmail_quote">On Mon, Ann wrote:<blockquote>Old</blockquote></div>"#
        XCTAssertNil(MailQuote.reply(inHTML: quoteOnly))
        XCTAssertNil(MailQuote.reply(inHTML: "<p>No history here.</p>"))
    }

    func testPlainTextQuotes() {
        XCTAssertEqual(MailQuote.reply(inPlainText: "Sure.\n\nOn Mon, Oct 6, 2025 at 9:00 AM Ann <a@x.com>\nwrote:\n> Old\n"), "Sure.")
        XCTAssertEqual(MailQuote.reply(inPlainText: "Done.\n\n-----Original Message-----\nFrom: Ann\n"), "Done.")
        XCTAssertEqual(MailQuote.reply(inPlainText: "Ok\n________________________________\nFrom: Ann\nSent: Mon\nSubject: Hi\n"), "Ok")
        XCTAssertEqual(MailQuote.reply(inPlainText: "Thanks\n> one\n> two"), "Thanks")
        XCTAssertNil(MailQuote.reply(inPlainText: "> question one\nanswer one\n> question two\nanswer two"))
        XCTAssertNil(MailQuote.reply(inPlainText: "FYI\n---------- Forwarded message ---------\nFrom: Ann\nDate: Mon\nSubject: Plans"))
    }
}
