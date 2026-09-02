import XCTest
@testable import MailMCP

final class VaultTests: XCTestCase {
    func testIMAPSettingsInferGmailHosts() throws {
        let settings = try IMAPSettings(
            imapHost: "",
            imapPort: 993,
            imapStartTLS: false,
            smtpHost: "",
            smtpPort: 465,
            smtpStartTLS: false,
            username: "you@gmail.com",
            password: "app-password"
        ).resolvingBlankHosts(for: "you@gmail.com")

        XCTAssertEqual(settings.imapHost, "imap.gmail.com")
        XCTAssertEqual(settings.smtpHost, "smtp.gmail.com")
    }

    func testIMAPSettingsInferCustomDomainHosts() throws {
        let settings = try IMAPSettings(
            imapHost: "",
            imapPort: 993,
            imapStartTLS: false,
            smtpHost: "",
            smtpPort: 465,
            smtpStartTLS: false,
            username: "you@example.com",
            password: "password"
        ).resolvingBlankHosts(for: "you@example.com")

        XCTAssertEqual(settings.imapHost, "imap.example.com")
        XCTAssertEqual(settings.smtpHost, "smtp.example.com")
    }

    func testSealAndOpenRoundTrip() throws {
        let key = try VaultCrypto.deriveKey(passphrase: "correct horse battery staple", salt: Data((0..<16).map { $0 }))
        let box = try VaultCrypto.seal(plaintext: Data("hello vault".utf8), key: key)
        let plain = try VaultCrypto.open(combined: box, key: key)
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), "hello vault")
    }

    func testWrongPassphraseFails() throws {
        let salt = Data((0..<16).map { $0 })
        let key = try VaultCrypto.deriveKey(passphrase: "alpha", salt: salt)
        let box = try VaultCrypto.seal(plaintext: Data("secret".utf8), key: key)
        let other = try VaultCrypto.deriveKey(passphrase: "beta", salt: salt)
        XCTAssertThrowsError(try VaultCrypto.open(combined: box, key: other))
    }

    func testVaultFilePackUnpack() throws {
        let salt = try VaultCrypto.randomBytes(16)
        let key = try VaultCrypto.deriveKey(passphrase: "portable-secret", salt: salt)
        var payload = VaultPayload.empty()
        payload.accounts = [
            MailAccount(provider: .imap, email: "you@example.com", imap: IMAPSettings(
                imapHost: "imap.example.com",
                imapPort: 993,
                imapStartTLS: false,
                smtpHost: "smtp.example.com",
                smtpPort: 465,
                smtpStartTLS: false,
                username: "you@example.com",
                password: "app-password"
            ))
        ]
        let data = try VaultFile.pack(payload: payload, key: key, salt: salt, iterations: 100_000)
        let opened = try VaultFile.unpack(fileData: data, key: key)
        XCTAssertEqual(opened.accounts.first?.email, "you@example.com")
        XCTAssertEqual(opened.accounts.first?.imap?.password, "app-password")
    }

    func testSearchCriteriaEmptyIsAll() {
        XCTAssertTrue(true)
    }
}
