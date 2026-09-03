import Foundation

struct IMAPFolder: Sendable {
    var name: String
    var flags: [String]
}

struct IMAPFetchResult: Sendable {
    var uid: String
    var flags: [String]
    var headers: [String: String]
    var text: String
    var size: Int?
    var rawParts: [String: Data]
}

final class IMAPClient {
    private let socket = TLSSocket()
    private var reader: ProtocolReader?
    private var tagCounter = 0
    private let settings: IMAPSettings
    private(set) var selectedExists = 0

    init(settings: IMAPSettings) {
        self.settings = settings
    }

    func connect() throws {
        let implicitTLS = settings.imapPort == 993 || !settings.imapStartTLS
        try socket.connect(host: settings.imapHost, port: settings.imapPort, useTLS: implicitTLS)
        reader = ProtocolReader(socket: socket)
        _ = try readLine()
        if settings.imapStartTLS && !implicitTLS {
            _ = try command("STARTTLS")
            try socket.startTLS(hostname: settings.imapHost)
            reader = ProtocolReader(socket: socket)
        }
        try login()
    }

    func disconnect() {
        if reader != nil {
            try? command("LOGOUT")
        }
        socket.close()
        reader = nil
    }

    func listFolders() throws -> [IMAPFolder] {
        let lines = try command("LIST \"\" \"*\"")
        return lines.compactMap { line in
            guard line.hasPrefix("* LIST ") else { return nil }
            let flags = Self.extractParenthetical(line) ?? []
            guard let name = Self.lastQuotedOrAtom(line) else { return nil }
            return IMAPFolder(name: name, flags: flags)
        }
    }

    func select(_ mailbox: String) throws {
        let lines = try command("SELECT \(Self.quote(mailbox))")
        selectedExists = 0
        for line in lines {
            let parts = line.split(separator: " ")
            if parts.count >= 3, parts[0] == "*", parts[2].uppercased() == "EXISTS", let count = Int(parts[1]) {
                selectedExists = count
            }
        }
    }

    func folderStatus(mailbox: String) throws -> (messages: Int?, unseen: Int?) {
        let lines = try command("STATUS \(Self.quote(mailbox)) (MESSAGES UNSEEN)")
        var messages: Int?
        var unseen: Int?
        for line in lines where line.uppercased().contains("STATUS") {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == ")" }).map(String.init)
            if let index = tokens.firstIndex(where: { $0.uppercased() == "MESSAGES" }),
               index + 1 < tokens.count {
                messages = Int(tokens[index + 1])
            }
            if let index = tokens.firstIndex(where: { $0.uppercased() == "UNSEEN" }),
               index + 1 < tokens.count {
                unseen = Int(tokens[index + 1])
            }
        }
        return (messages, unseen)
    }

    func messageCount(mailbox: String = "INBOX") throws -> Int {
        if let messages = try folderStatus(mailbox: mailbox).messages {
            return messages
        }
        try select(mailbox)
        return try search(query: "", limit: Int.max).count
    }

    func search(query: String, limit: Int, oldestFirst: Bool = false) throws -> [String] {
        let criteria = IMAPSearchQuery.uidSearchCriteria(from: query)
        let cap = max(limit, 1)
        if criteria == "ALL" {
            return try fetchRecent(limit: cap).map(\.uid)
        }
        if criteria == "UNSEEN" {
            return try fetchRecentUnseen(limit: cap).map(\.uid)
        }
        let lines = try command("UID SEARCH \(criteria)")
        var uids: [String] = []
        for line in lines where line.uppercased().hasPrefix("* SEARCH") {
            let parts = line.split(separator: " ").dropFirst(2).map(String.init)
            uids.append(contentsOf: parts.filter { !$0.isEmpty })
        }
        return oldestFirst ? Array(uids.prefix(cap)) : Array(uids.suffix(cap))
    }

    func resolveMailbox(_ raw: String?) throws -> String {
        let token = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty || token.lowercased() == "inbox" { return "INBOX" }
        let lower = token.lowercased()
        if ["all", "allmail", "all mail", "[gmail]/all mail"].contains(lower) {
            return try specialFolder(matching: ["[Gmail]/All Mail", "[Google Mail]/All Mail"], flag: "\\All")
        }
        return token
    }

    func copy(uids: [String], to mailbox: String) throws {
        let chunk = 80
        var index = 0
        while index < uids.count {
            let end = min(index + chunk, uids.count)
            let set = uids[index..<end].joined(separator: ",")
            _ = try command("UID COPY \(set) \(Self.quote(mailbox))")
            index = end
        }
    }

    func createMailboxPath(_ folder: String) throws {
        if folder.caseInsensitiveCompare("INBOX") == .orderedSame { return }
        let existing = Set(try listFolders().map { $0.name.lowercased() })
        var parts: [String] = []
        for part in folder.split(separator: "/").map(String.init) where !part.isEmpty {
            parts.append(part)
            let path = parts.joined(separator: "/")
            if existing.contains(path.lowercased()) { continue }
            _ = try? command("CREATE \(Self.quote(path))")
        }
    }

    func fetch(uids: [String]) throws -> [IMAPFetchResult] {
        guard !uids.isEmpty else { return [] }
        let set = uids.joined(separator: ",")
        let spec = "UID FETCH \(set) (FLAGS RFC822.SIZE BODY.PEEK[HEADER] BODY.PEEK[TEXT]<0.200000>)"
        let lines = try command(spec)
        return Self.parseFetch(lines: lines)
    }

    func fetchRecent(limit: Int) throws -> [IMAPFetchResult] {
        guard selectedExists > 0 else { return [] }
        let cap = max(limit, 1)
        let start = max(1, selectedExists - cap + 1)
        let spec = "FETCH \(start):\(selectedExists) (UID FLAGS RFC822.SIZE BODY.PEEK[HEADER] BODY.PEEK[TEXT]<0.200000>)"
        return Self.parseFetch(lines: try command(spec))
    }

    func fetchRecentUnseen(limit: Int, window: Int = 250) throws -> [IMAPFetchResult] {
        guard selectedExists > 0 else { return [] }
        let start = max(1, selectedExists - max(window, limit) + 1)
        let spec = "FETCH \(start):\(selectedExists) (UID FLAGS RFC822.SIZE BODY.PEEK[HEADER] BODY.PEEK[TEXT]<0.200000>)"
        let items = Self.parseFetch(lines: try command(spec))
        return Array(
            items.filter { item in
                !item.flags.contains { $0.caseInsensitiveCompare("\\Seen") == .orderedSame }
            }.suffix(max(limit, 1))
        )
    }

    func fetchPart(uid: String, section: String) throws -> Data {
        let spec = "UID FETCH \(uid) (BODY.PEEK[\(section)])"
        let lines = try command(spec)
        for result in Self.parseFetch(lines: lines) {
            if let data = result.rawParts.values.first {
                return data
            }
        }
        throw MailMCPError.provider("Attachment part \(section) not found")
    }

    func expunge() throws {
        _ = try command("EXPUNGE")
    }

    func storeFlags(uid: String, add: [String] = [], remove: [String] = []) throws {
        if !add.isEmpty {
            _ = try command("UID STORE \(uid) +FLAGS (\(add.joined(separator: " ")))")
        }
        if !remove.isEmpty {
            _ = try command("UID STORE \(uid) -FLAGS (\(remove.joined(separator: " ")))")
        }
    }

    func move(uid: String, to mailbox: String) throws {
        let result = try? command("UID MOVE \(uid) \(Self.quote(mailbox))")
        if result == nil {
            _ = try command("UID COPY \(uid) \(Self.quote(mailbox))")
            try storeFlags(uid: uid, add: ["\\Deleted"])
            _ = try command("EXPUNGE")
        }
    }

    func append(mailbox: String, rfc822: String, flags: String = "\\Draft") throws {
        let payload = Data(rfc822.utf8)
        let tag = nextTag()
        let command = "\(tag) APPEND \(Self.quote(mailbox)) (\(flags)) {\(payload.count)}"
        try socket.writeLine(command)
        let ready = try readLine()
        guard ready.hasPrefix("+") else {
            throw MailMCPError.provider("APPEND rejected: \(ready)")
        }
        try socket.write(payload)
        try socket.write(Data("\r\n".utf8))
        while true {
            let line = try readLine()
            if line.hasPrefix(tag + " ") {
                if line.uppercased().contains(" OK") { return }
                throw MailMCPError.provider(line)
            }
        }
    }

    func specialFolder(matching aliases: [String], flag: String) throws -> String {
        let folders = try listFolders()
        if let flagged = folders.first(where: { $0.flags.contains(where: { $0.caseInsensitiveCompare(flag) == .orderedSame }) }) {
            return flagged.name
        }
        if let named = folders.first(where: { folder in
            aliases.contains { folder.name.caseInsensitiveCompare($0) == .orderedSame }
        }) {
            return named.name
        }
        return aliases[0]
    }

    private func login() throws {
        let user = Self.quote(settings.username)
        if settings.password.contains("\r") || settings.password.contains("\n") || settings.password.contains("\"") {
            let tag = nextTag()
            let data = Data(settings.password.utf8)
            try socket.writeLine("\(tag) LOGIN \(user) {\(data.count)}")
            let ready = try readLine()
            guard ready.hasPrefix("+") else {
                throw MailMCPError.provider("LOGIN literal rejected: \(ready)")
            }
            try socket.write(data)
            try socket.write(Data("\r\n".utf8))
            while true {
                let line = try readLine()
                if line.hasPrefix(tag + " ") {
                    if line.uppercased().contains(" OK") { return }
                    throw MailMCPError.provider("LOGIN failed")
                }
            }
        } else {
            _ = try command("LOGIN \(user) \(Self.quote(settings.password))")
        }
    }

    @discardableResult
    private func command(_ text: String) throws -> [String] {
        guard let reader else { throw MailMCPError.network("IMAP not connected") }
        let tag = nextTag()
        try socket.writeLine("\(tag) \(text)")
        var collected: [String] = []
        while true {
            let line = try readLine()
            if let literalSize = Self.trailingLiteralSize(line) {
                let blob = try reader.readExact(literalSize)
                collected.append(line)
                collected.append("LITERAL \(blob.base64EncodedString())")
                continue
            }
            if line.hasPrefix(tag + " ") {
                if line.uppercased().contains(" OK") {
                    return collected
                }
                throw MailMCPError.provider(line)
            }
            collected.append(line)
        }
    }

    private func readLine() throws -> String {
        guard let reader else { throw MailMCPError.network("IMAP not connected") }
        return try reader.readLine()
    }

    private func nextTag() -> String {
        tagCounter += 1
        return String(format: "A%04d", tagCounter)
    }

    private static func quote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func trailingLiteralSize(_ line: String) -> Int? {
        guard let open = line.lastIndex(of: "{"), let close = line.lastIndex(of: "}"), open < close else {
            return nil
        }
        if close != line.index(before: line.endIndex) { return nil }
        let digits = line[line.index(after: open)..<close]
        return Int(digits)
    }

    private static func extractParenthetical(_ line: String) -> [String]? {
        guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")") else { return nil }
        let inner = line[line.index(after: open)..<close]
        return inner.split(separator: " ").map(String.init)
    }

    private static func lastQuotedOrAtom(_ line: String) -> String? {
        if let lastQuote = line.lastIndex(of: "\"") {
            var idx = lastQuote
            var start: String.Index?
            while idx > line.startIndex {
                idx = line.index(before: idx)
                if line[idx] == "\"" {
                    start = line.index(after: idx)
                    break
                }
            }
            if let start {
                return String(line[start..<lastQuote])
            }
        }
        return line.split(separator: " ").last.map(String.init)
    }

    static func parseFetch(lines: [String]) -> [IMAPFetchResult] {
        var results: [IMAPFetchResult] = []
        var current = IMAPFetchResult(uid: "", flags: [], headers: [:], text: "", size: nil, rawParts: [:])
        var pendingLiteralKind: String?

        func flush() {
            if !current.uid.isEmpty || !current.headers.isEmpty || !current.text.isEmpty {
                results.append(current)
            }
            current = IMAPFetchResult(uid: "", flags: [], headers: [:], text: "", size: nil, rawParts: [:])
        }

        for line in lines {
            if line.hasPrefix("* ") && line.uppercased().contains(" FETCH") {
                if !current.uid.isEmpty || !current.headers.isEmpty || !current.text.isEmpty { flush() }
                if let uid = match("UID ", in: line) {
                    current.uid = uid
                }
                if let flags = extractParenthetical(after: "FLAGS", in: line) {
                    current.flags = flags
                }
                if let size = match("RFC822.SIZE ", in: line), let value = Int(size) {
                    current.size = value
                }
                if let kind = literalKind(from: line) {
                    pendingLiteralKind = kind
                }
                continue
            }
            if let kind = literalKind(from: line) {
                pendingLiteralKind = kind
            }
            if line.hasPrefix("LITERAL ") {
                let b64 = String(line.dropFirst("LITERAL ".count))
                let data = Data(base64Encoded: b64) ?? Data()
                switch pendingLiteralKind {
                case "header":
                    current.headers = RFC822.parseHeaders(String(decoding: data, as: UTF8.self))
                case "text":
                    current.text = String(decoding: data, as: UTF8.self)
                default:
                    let key = pendingLiteralKind ?? "body"
                    current.rawParts[key] = data
                    if current.text.isEmpty {
                        current.text = String(decoding: data, as: UTF8.self)
                    }
                }
                pendingLiteralKind = nil
                continue
            }
        }
        flush()
        return results
    }

    static func literalKind(from line: String) -> String? {
        let upper = line.uppercased()
        if upper.contains("HEADER]") { return "header" }
        if upper.contains("TEXT]") { return "text" }
        if upper.contains("BODY[") { return "part" }
        return nil
    }

    private static func match(_ token: String, in line: String) -> String? {
        guard let range = line.range(of: token, options: .caseInsensitive) else { return nil }
        let rest = line[range.upperBound...]
        let atom = rest.split(whereSeparator: { $0 == " " || $0 == ")" }).first
        return atom.map(String.init)
    }

    private static func extractParenthetical(after token: String, in line: String) -> [String]? {
        guard let range = line.range(of: token, options: .caseInsensitive) else { return nil }
        let rest = String(line[range.lowerBound...])
        return extractParenthetical(rest)
    }
}

enum IMAPSearchQuery {
    static func looksLikeGmailRaw(_ query: String) -> Bool {
        let lower = query.lowercased()
        let markers = [
            "has:", "label:", "-in:", "-label:", "nouserlabels",
            "category:", "filename:", "older_than:", "newer_than:"
        ]
        return markers.contains { lower.contains($0) }
    }

    static func uidSearchCriteria(from query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "ALL" }
        let lower = trimmed.lowercased()
        if lower == "is:unread" || lower == "unseen" { return "UNSEEN" }
        if looksLikeGmailRaw(trimmed) {
            return "X-GM-RAW \(quote(trimmed))"
        }
        var remaining = trimmed
        var parts: [String] = []
        let prefixes = [("from:", "FROM"), ("to:", "TO"), ("subject:", "SUBJECT")]
        for (prefix, atom) in prefixes {
            if let range = remaining.range(of: prefix, options: .caseInsensitive) {
                let after = remaining[range.upperBound...]
                let token = after.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                if !token.isEmpty {
                    parts.append("\(atom) \(quote(token))")
                    remaining = remaining.replacingOccurrences(of: prefix + token, with: "", options: .caseInsensitive)
                }
            }
        }
        remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            parts.append("TEXT \(quote(remaining))")
        }
        return parts.isEmpty ? "ALL" : parts.joined(separator: " ")
    }

    private static func quote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
