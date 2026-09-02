import Foundation

final class SMTPClient {
    private let socket = TLSSocket()
    private var reader: ProtocolReader?
    private let settings: IMAPSettings

    init(settings: IMAPSettings) {
        self.settings = settings
    }

    func send(from: String, to: [String], cc: [String], bcc: [String], rfc822: String) throws {
        let implicitTLS = settings.smtpPort == 465 || !settings.smtpStartTLS
        try socket.connect(host: settings.smtpHost, port: settings.smtpPort, useTLS: implicitTLS)
        reader = ProtocolReader(socket: socket)
        _ = try expect(prefix: "220")
        try ehlo()
        if settings.smtpStartTLS && !implicitTLS {
            _ = try command("STARTTLS", expect: "220")
            try socket.startTLS(hostname: settings.smtpHost)
            reader = ProtocolReader(socket: socket)
            try ehlo()
        }
        try authPlain()
        _ = try command("MAIL FROM:<\(bare(from))>", expect: "250")
        for recipient in to + cc + bcc {
            _ = try command("RCPT TO:<\(bare(recipient))>", expect: "250")
        }
        _ = try command("DATA", expect: "354")
        let escaped = rfc822.replacingOccurrences(of: "\r\n.", with: "\r\n..")
        try socket.write(Data((escaped.hasSuffix("\r\n") ? escaped : escaped + "\r\n").utf8))
        try socket.write(Data(".\r\n".utf8))
        _ = try expect(prefix: "250")
        _ = try? command("QUIT", expect: "221")
        socket.close()
        reader = nil
    }

    private func ehlo() throws {
        _ = try command("EHLO mailmcp.local", expect: "250")
    }

    private func authPlain() throws {
        let payload = Data([0] + Array(settings.username.utf8) + [0] + Array(settings.password.utf8))
        _ = try command("AUTH PLAIN \(payload.base64EncodedString())", expect: "235")
    }

    @discardableResult
    private func command(_ text: String, expect code: String) throws -> [String] {
        try socket.writeLine(text)
        return try expect(prefix: code)
    }

    @discardableResult
    private func expect(prefix: String) throws -> [String] {
        guard let reader else { throw MailMCPError.network("SMTP not connected") }
        var lines: [String] = []
        while true {
            let line = try reader.readLine()
            lines.append(line)
            if line.count >= 4, line[line.index(line.startIndex, offsetBy: 3)] == " " {
                if !line.hasPrefix(prefix) {
                    throw MailMCPError.provider("SMTP: \(line)")
                }
                return lines
            }
        }
    }

    private func bare(_ address: String) -> String {
        if let start = address.firstIndex(of: "<"), let end = address.firstIndex(of: ">") {
            return String(address[address.index(after: start)..<end])
        }
        return address.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
