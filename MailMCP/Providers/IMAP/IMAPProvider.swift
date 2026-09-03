import Foundation
import SwiftMail

struct IMAPProvider: MailProviding {
    let account: MailAccount
    let settings: IMAPSettings

    func testConnection() async throws -> String {
        try await withServer { server in
            let folders = try await server.listMailboxes()
            return "IMAP OK — \(folders.count) folders"
        }
    }

    func listFolders() async throws -> [MailFolderCount] {
        try await withServer { server in
            let folders = try await server.listMailboxes()
            var rows: [MailFolderCount] = []
            for folder in folders {
                if !folder.isSelectable {
                    rows.append(MailFolderCount(name: folder.name, messages: nil, unseen: nil, selectable: false))
                    continue
                }
                let status = try? await server.mailboxStatus(folder.name)
                rows.append(
                    MailFolderCount(
                        name: folder.name,
                        messages: status?.messageCount,
                        unseen: status?.unseenCount,
                        selectable: true
                    )
                )
            }
            return rows
        }
    }

    func messageCount(query: String) async throws -> Int {
        try await withServer { server in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return try await server.mailboxStatus("INBOX").messageCount ?? 0
            }
            if trimmed.lowercased() == "is:unread" || trimmed.lowercased() == "unseen" {
                return try await server.mailboxStatus("INBOX").unseenCount ?? 0
            }
            let (source, remaining) = Self.splitMailbox(from: query)
            let mailboxName = try await Self.resolveSourceMailbox(server, source)
            if remaining.isEmpty {
                return try await server.mailboxStatus(mailboxName).messageCount ?? 0
            }
            if remaining.lowercased() == "is:unread" || remaining.lowercased() == "unseen" {
                return try await server.mailboxStatus(mailboxName).unseenCount ?? 0
            }
            try await server.selectMailbox(mailboxName)
            let matches: MessageIdentifierSet<UID> = try await server.search(
                criteria: Self.searchCriteria(from: remaining)
            )
            return matches.count
        }
    }

    func search(query: String, limit: Int) async throws -> [MailSummary] {
        let (source, remaining) = Self.splitMailbox(from: query)
        let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = max(limit, 1)
        if IMAPSearchQuery.looksLikeGmailRaw(trimmed) {
            let rawUIDs = try await gmailRawUIDs(query: trimmed, mailbox: source, limit: cap)
            return try await withServer { server in
                let mailboxName = try await Self.resolveSourceMailbox(server, source)
                try await server.selectMailbox(mailboxName)
                let parsed = try rawUIDs.map { try Self.uid(from: $0) }
                let infos = try await Self.fetchInfos(server: server, uids: parsed)
                return infos.reversed().map { self.summary(from: $0) }
            }
        }
        return try await withServer { server in
            let mailboxName = try await Self.resolveSourceMailbox(server, source)
            let mailbox = try await server.selectMailbox(mailboxName)
            let lower = trimmed.lowercased()
            let infos: [MessageInfo]
            if trimmed.isEmpty {
                infos = try await Self.fetchLatest(server: server, mailbox: mailbox, limit: cap)
            } else if lower == "is:unread" || lower == "unseen" {
                infos = try await Self.fetchLatestUnseen(server: server, mailbox: mailbox, limit: cap)
            } else {
                let matches: MessageIdentifierSet<UID> = try await server.search(
                    criteria: Self.searchCriteria(from: trimmed)
                )
                let uids = Array(matches.toArray().suffix(cap))
                infos = try await Self.fetchInfos(server: server, uids: uids)
            }
            return infos.reversed().map { self.summary(from: $0) }
        }
    }

    func getMessage(id: String) async throws -> MailMessage {
        try await withServer { server in
            if id.hasPrefix("draft:") {
                try await server.listSpecialUseMailboxes()
                try await server.selectMailbox(try await specialFolder(server, .drafts))
                let uid = try Self.uid(from: String(id.dropFirst(6)))
                return try await loadMessage(server: server, uid: uid)
            }
            let uid = try Self.uid(from: id)
            do {
                try await server.selectMailbox("INBOX")
                return try await loadMessage(server: server, uid: uid)
            } catch {
                try await server.selectMailbox(try await Self.resolveSourceMailbox(server, "all"))
                return try await loadMessage(server: server, uid: uid)
            }
        }
    }

    func listThreads(query: String?, limit: Int) async throws -> [MailThread] {
        let messages = try await search(query: query ?? "", limit: limit)
        var groups: [String: [MailSummary]] = [:]
        for message in messages {
            let key = message.threadID ?? message.subject.lowercased()
            groups[key, default: []].append(message)
        }
        return groups.map { key, items in
            let newest = items.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) } ?? items[0]
            return MailThread(
                id: key,
                accountID: account.id,
                accountEmail: account.email,
                subject: newest.subject,
                participants: Array(Set(items.map(\.from))),
                snippet: newest.snippet,
                date: newest.date,
                messageCount: items.count,
                isUnread: items.contains(where: \.isUnread)
            )
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    func modify(id: String, action: MailModifyAction, label: String?) async throws {
        try await withServer { server in
            try await server.listSpecialUseMailboxes()
            try await server.selectMailbox("INBOX")
            let uid = try Self.uid(from: id)
            switch action {
            case .markRead:
                try await server.store(flags: [.seen], on: MessageIdentifierSet(uid), operation: .add)
            case .markUnread:
                try await server.store(flags: [.seen], on: MessageIdentifierSet(uid), operation: .remove)
            case .trash:
                try await server.move(message: uid, to: try await specialFolder(server, .trash))
            case .archive:
                try await server.move(message: uid, to: try await specialFolder(server, .archive))
            case .addLabel:
                if let label {
                    try await server.store(flags: Self.flags(from: [label]), on: MessageIdentifierSet(uid), operation: .add)
                }
            case .removeLabel:
                if let label {
                    try await server.store(flags: Self.flags(from: [label]), on: MessageIdentifierSet(uid), operation: .remove)
                }
            }
        }
    }

    func createDraft(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws -> String {
        try await withServer { server in
            try await server.listSpecialUseMailboxes()
            let drafts = try await specialFolder(server, .drafts)
            let result = try await server.createDraft(from: makeEmail(to: to, cc: cc, bcc: bcc, subject: subject, body: body), in: drafts)
            if let uid = result.firstUID {
                return "draft:\(uid.value)"
            }
            return "draft-saved:\(drafts)"
        }
    }

    func send(to: [String], cc: [String], bcc: [String], subject: String, body: String, extraHeaders: [String: String] = [:]) async throws -> String {
        var email = makeEmail(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
        if !extraHeaders.isEmpty {
            email.additionalHeaders = extraHeaders
        }
        try await withSMTP { smtp in
            try await smtp.sendEmail(email)
        }
        return "sent"
    }

    func getThread(id: String, limit: Int) async throws -> [MailMessage] {
        let seed = try await getMessage(id: id)
        let subject = seed.subject.replacingOccurrences(
            of: #"^(Re|Fwd|Fw):\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let matches = try await search(query: "subject:\(subject)", limit: max(limit, 20))
        var messages: [MailMessage] = []
        for item in matches.prefix(limit) {
            messages.append(try await getMessage(id: item.id))
        }
        if messages.isEmpty { messages = [seed] }
        return messages.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    func listDrafts(limit: Int) async throws -> [MailDraft] {
        try await withServer { server in
            try await server.listSpecialUseMailboxes()
            let drafts = try await specialFolder(server, .drafts)
            let mailbox = try await server.selectMailbox(drafts)
            let infos = try await Self.fetchLatest(server: server, mailbox: mailbox, limit: max(limit, 1))
            return infos.reversed().map { item in
                MailDraft(
                    id: "draft:\(item.uid?.value ?? item.sequenceNumber.value)",
                    accountEmail: account.email,
                    to: item.to,
                    cc: item.cc,
                    subject: item.subject ?? "(no subject)",
                    snippet: String((item.subject ?? "").prefix(160)),
                    date: item.date ?? item.internalDate
                )
            }
        }
    }

    func updateDraft(id: String, to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws -> String {
        try await deleteDraft(id: id)
        return try await createDraft(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
    }

    func deleteDraft(id: String) async throws {
        try await withServer { server in
            try await server.listSpecialUseMailboxes()
            try await server.selectMailbox(try await specialFolder(server, .drafts))
            let uid = try Self.uid(from: id.hasPrefix("draft:") ? String(id.dropFirst(6)) : id)
            try await server.store(flags: [.deleted], on: MessageIdentifierSet(uid), operation: .add)
            try? await server.expunge()
        }
    }

    func fileMessage(id: String, folder: String?, addLabels: [String], removeLabels: [String]) async throws {
        try await withServer { server in
            if let folder, !folder.isEmpty {
                try await Self.ensureMailboxPath(server, folder)
            }
            try await server.selectMailbox("INBOX")
            let uid = try Self.uid(from: id)
            if let folder, !folder.isEmpty {
                try await server.move(message: uid, to: folder)
            }
            if !addLabels.isEmpty {
                try await server.store(flags: Self.flags(from: addLabels), on: MessageIdentifierSet(uid), operation: .add)
            }
            if !removeLabels.isEmpty {
                try await server.store(flags: Self.flags(from: removeLabels), on: MessageIdentifierSet(uid), operation: .remove)
            }
        }
    }

    func fileMatching(query: String, folder: String, mailbox: String? = nil, limit: Int? = nil) async throws -> Int {
        var trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MailMCPError.invalidInput("query is required; refusing to file the entire mailbox")
        }
        let dest = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty else {
            throw MailMCPError.invalidInput("folder is required")
        }
        if let mailbox, !mailbox.isEmpty, !trimmed.lowercased().contains("in:") {
            trimmed = "in:\(mailbox) \(trimmed)"
        }
        let (source, remaining) = Self.splitMailbox(from: trimmed)
        if IMAPSearchQuery.looksLikeGmailRaw(remaining) {
            return try await gmailRawFile(query: remaining, destination: dest, mailbox: source, limit: limit)
        }
        return try await withServer { server in
            try await Self.ensureMailboxPath(server, dest)
            let mailboxName = try await Self.resolveSourceMailbox(server, source)
            try await server.selectMailbox(mailboxName)
            let matches: MessageIdentifierSet<UID> = try await server.search(
                criteria: Self.searchCriteria(from: remaining)
            )
            var uids = matches.toArray()
            if let limit, limit > 0 {
                uids = Array(uids.prefix(limit))
            }
            guard !uids.isEmpty else { return 0 }
            let copyOnly = Self.isAllMail(mailboxName)
            let chunkSize = 80
            var index = 0
            while index < uids.count {
                let end = min(index + chunkSize, uids.count)
                let set = MessageIdentifierSet(Array(uids[index..<end]))
                if copyOnly {
                    try await server.copy(messages: set, to: dest)
                } else {
                    try await server.move(messages: set, to: dest)
                }
                index = end
            }
            return uids.count
        }
    }

    func frequentContacts(limit: Int) async throws -> [MailContact] {
        try await withServer { server in
            try await server.listSpecialUseMailboxes()
            let sent = try await specialFolder(server, .sent)
            let mailbox = try await server.selectMailbox(sent)
            let infos = try await Self.fetchLatest(server: server, mailbox: mailbox, limit: 80)
            var counts: [String: (name: String, count: Int)] = [:]
            for item in infos {
                for raw in item.to + item.cc {
                    let address = raw.lowercased()
                    if address.contains(account.email.lowercased()) { continue }
                    let current = counts[address]
                    counts[address] = (raw, (current?.count ?? 0) + 1)
                }
            }
            return counts.map { MailContact(address: $0.key, name: $0.value.name, count: $0.value.count) }
                .sorted { $0.count > $1.count }
                .prefix(limit)
                .map { $0 }
        }
    }

    func getAttachment(messageID: String, attachmentID: String) async throws -> MailAttachmentData {
        let sectionName = attachmentID.hasPrefix("imap:") ? String(attachmentID.dropFirst(5)) : attachmentID
        return try await withServer { server in
            try await server.selectMailbox("INBOX")
            let uid = try Self.uid(from: messageID)
            let info = try await server.fetchMessageInfo(
                for: uid,
                options: [.envelope, .flags, .bodyStructure]
            )
            let data = try await server.fetchPart(section: Section(sectionName), of: uid)
            let part = info?.parts.first { $0.section.description == sectionName }
            let decoded = part.map { data.decoded(for: $0) } ?? data
            return MailAttachmentData(
                meta: MailAttachmentMeta(
                    id: attachmentID,
                    filename: part?.filename ?? "attachment",
                    mimeType: part?.contentType ?? "application/octet-stream",
                    size: decoded.count
                ),
                dataBase64: decoded.base64EncodedString()
            )
        }
    }

    private func loadMessage(server: IMAPServer, uid: UID) async throws -> MailMessage {
        guard let info = try await server.fetchMessageInfo(
            for: uid,
            options: [.envelope, .internalDate, .flags, .bodyStructure]
        ) else {
            throw MailMCPError.provider("Message \(uid.value) not found")
        }
        let skeleton = Message(header: info, parts: info.parts)
        let bodyParts = skeleton.bodies
        let requests = bodyParts.map { (uid: uid, section: $0.section) }
        var text = ""
        var html: String?
        if !requests.isEmpty {
            let fetched = try await server.fetchPartsPipelined(parts: requests)
            for part in bodyParts {
                guard let data = fetched[uid]?.first(where: { $0.section == part.section })?.data else { continue }
                let decoded = data.decoded(for: part)
                let string = String(data: decoded, encoding: .utf8) ?? String(decoding: decoded, as: UTF8.self)
                if part.contentType.lowercased().hasPrefix("text/html") {
                    html = string
                } else if text.isEmpty {
                    text = string
                }
            }
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let html {
            text = Self.stripHTML(html)
        }
        return MailMessage(
            id: String(uid.value),
            accountID: account.id,
            accountEmail: account.email,
            threadID: info.messageId?.description,
            from: info.from ?? "",
            to: info.to,
            cc: info.cc,
            bcc: info.bcc,
            subject: info.subject ?? "(no subject)",
            date: info.date ?? info.internalDate,
            body: text,
            bodyHTML: html,
            isUnread: !info.flags.contains(where: { if case .seen = $0 { return true }; return false }),
            labels: info.flags.map(Self.flagLabel),
            attachments: skeleton.attachments.map { part in
                MailAttachmentMeta(
                    id: "imap:\(part.section.description)",
                    filename: part.filename ?? "attachment",
                    mimeType: part.contentType,
                    size: nil
                )
            }
        )
    }

    private func summary(from info: MessageInfo) -> MailSummary {
        MailSummary(
            id: String(info.uid?.value ?? info.sequenceNumber.value),
            accountID: account.id,
            accountEmail: account.email,
            threadID: info.messageId?.description,
            from: info.from ?? "",
            to: info.to,
            subject: info.subject ?? "(no subject)",
            date: info.date ?? info.internalDate,
            snippet: String((info.subject ?? "").prefix(180)),
            isUnread: !info.flags.contains(where: { if case .seen = $0 { return true }; return false }),
            labels: info.flags.map(Self.flagLabel)
        )
    }

    private func makeEmail(to: [String], cc: [String], bcc: [String], subject: String, body: String) -> Email {
        return Email(
            sender: Self.address(account.email),
            recipients: to.map(Self.address),
            ccRecipients: cc.map(Self.address),
            bccRecipients: bcc.map(Self.address),
            subject: subject,
            textBody: body
        )
    }

    private enum SpecialKind {
        case drafts, trash, archive, sent
    }

    private func specialFolder(_ server: IMAPServer, _ kind: SpecialKind) async throws -> String {
        switch kind {
        case .drafts:
            if let name = try? await server.draftsFolder.name { return name }
            return "Drafts"
        case .trash:
            if let name = try? await server.trashFolder.name { return name }
            return "Trash"
        case .archive:
            if let name = try? await server.archiveFolder.name { return name }
            return "Archive"
        case .sent:
            if let name = try? await server.sentFolder.name { return name }
            return "Sent"
        }
    }

    private func gmailRawUIDs(query: String, mailbox: String?, limit: Int, oldestFirst: Bool = true) async throws -> [String] {
        let settings = self.settings
        let accountID = account.id
        return try await Task.detached {
            let gate = IMAPAccountGate.lock(for: accountID)
            gate.lock()
            defer { gate.unlock() }
            let client = IMAPClient(settings: settings)
            try client.connect()
            defer { client.disconnect() }
            let name = try client.resolveMailbox(mailbox)
            try client.select(name)
            return try client.search(query: query, limit: limit, oldestFirst: oldestFirst)
        }.value
    }

    private func gmailRawFile(query: String, destination: String, mailbox: String?, limit: Int?) async throws -> Int {
        let settings = self.settings
        let accountID = account.id
        let cap = limit ?? Int.max
        return try await Task.detached {
            let gate = IMAPAccountGate.lock(for: accountID)
            gate.lock()
            defer { gate.unlock() }
            let client = IMAPClient(settings: settings)
            try client.connect()
            defer { client.disconnect() }
            try client.createMailboxPath(destination)
            let name = try client.resolveMailbox(mailbox ?? "all")
            try client.select(name)
            let uids = try client.search(query: query, limit: max(cap, 1), oldestFirst: true)
            guard !uids.isEmpty else { return 0 }
            if name.localizedCaseInsensitiveContains("all mail")
                || destination.caseInsensitiveCompare("INBOX") == .orderedSame {
                try client.copy(uids: uids, to: destination)
            } else {
                for uid in uids {
                    try client.move(uid: uid, to: destination)
                }
            }
            return uids.count
        }.value
    }

    private func withServer<T: Sendable>(_ work: @escaping @Sendable (IMAPServer) async throws -> T) async throws -> T {
        let settings = self.settings
        let accountID = account.id
        return try await Task.detached {
            let gate = IMAPAccountGate.lock(for: accountID)
            gate.lock()
            defer { gate.unlock() }
            var lastError: Error = MailMCPError.network("IMAP connect failed")
            for attempt in 1...3 {
                let server = IMAPServer(
                    host: settings.imapHost,
                    port: settings.imapPort,
                    transportSecurity: Self.imapTransport(settings),
                    responseBufferLimit: 8 * 1024 * 1024
                )
                do {
                    try await server.connect()
                    try await server.login(username: settings.username, password: settings.password)
                    let result = try await work(server)
                    try? await server.logout()
                    return result
                } catch {
                    lastError = error
                    try? await server.disconnect()
                    if attempt == 3 || !Self.isRetryable(error) {
                        throw error
                    }
                    try await Task.sleep(nanoseconds: UInt64(250_000_000 * attempt))
                }
            }
            throw lastError
        }.value
    }

    private func withSMTP(_ work: @escaping @Sendable (SMTPServer) async throws -> Void) async throws {
        let settings = self.settings
        try await Task.detached {
            let server = SMTPServer(
                host: settings.smtpHost,
                port: settings.smtpPort,
                transportSecurity: Self.smtpTransport(settings)
            )
            try await server.connect()
            try await server.login(username: settings.username, password: settings.password)
            try await work(server)
            try? await server.disconnect()
        }.value
    }

    private static func fetchLatest(server: IMAPServer, mailbox: Mailbox.Selection, limit: Int) async throws -> [MessageInfo] {
        guard let set = mailbox.latest(limit) else { return [] }
        return try await server.fetchMessageInfosBulk(using: set, options: .slim)
    }

    private static func fetchLatestUnseen(server: IMAPServer, mailbox: Mailbox.Selection, limit: Int, window: Int = 250) async throws -> [MessageInfo] {
        guard let set = mailbox.latest(max(window, limit)) else { return [] }
        let infos = try await server.fetchMessageInfosBulk(using: set, options: .slim)
        return Array(
            infos.filter { info in
                !info.flags.contains { if case .seen = $0 { return true }; return false }
            }.suffix(max(limit, 1))
        )
    }

    private static func fetchInfos(server: IMAPServer, uids: [UID]) async throws -> [MessageInfo] {
        guard !uids.isEmpty else { return [] }
        return try await server.fetchMessageInfosBulk(using: MessageIdentifierSet(uids), options: .slim)
    }

    private static func ensureMailboxPath(_ server: IMAPServer, _ folder: String) async throws {
        let existing = Set((try await server.listMailboxes()).map { $0.name.lowercased() })
        var parts: [String] = []
        for part in folder.split(separator: "/").map(String.init) where !part.isEmpty {
            parts.append(part)
            let path = parts.joined(separator: "/")
            if existing.contains(path.lowercased()) { continue }
            try? await server.createMailbox(path)
        }
    }

    private static func splitMailbox(from query: String) -> (String?, String) {
        var remaining = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let token = takePrefixedToken(prefix: "in:", from: &remaining) {
            return (token, remaining)
        }
        return (nil, remaining)
    }

    private static func isAllMail(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("all mail")
    }

    private static func resolveSourceMailbox(_ server: IMAPServer, _ raw: String?) async throws -> String {
        let token = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty || token.lowercased() == "inbox" { return "INBOX" }
        let lower = token.lowercased()
        if ["all", "allmail", "all mail", "[gmail]/all mail"].contains(lower) {
            let folders = try await server.listMailboxes()
            if let match = folders.first(where: { $0.name.localizedCaseInsensitiveContains("All Mail") }) {
                return match.name
            }
            return "[Gmail]/All Mail"
        }
        return token
    }

    private static func searchCriteria(from query: String) -> [SearchCriteria] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [.all] }
        let lower = trimmed.lowercased()
        if lower == "is:unread" || lower == "unseen" { return [.unseen] }
        var remaining = trimmed
        var parts: [SearchCriteria] = []
        let prefixes: [(String, (String) -> SearchCriteria)] = [
            ("from:", { .from($0) }),
            ("to:", { .to($0) }),
            ("subject:", { .subject($0) })
        ]
        for (prefix, make) in prefixes {
            while let token = takePrefixedToken(prefix: prefix, from: &remaining) {
                parts.append(make(token))
            }
        }
        remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if remaining.count >= 2, remaining.hasPrefix("\""), remaining.hasSuffix("\"") {
            remaining = String(remaining.dropFirst().dropLast())
        }
        if !remaining.isEmpty {
            parts.append(.text(remaining))
        }
        return parts.isEmpty ? [.all] : parts
    }

    private static func takePrefixedToken(prefix: String, from remaining: inout String) -> String? {
        guard let range = remaining.range(of: prefix, options: .caseInsensitive) else { return nil }
        var index = range.upperBound
        while index < remaining.endIndex, remaining[index].isWhitespace {
            index = remaining.index(after: index)
        }
        guard index < remaining.endIndex else {
            remaining.removeSubrange(range.lowerBound..<remaining.endIndex)
            remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            return nil
        }
        let value: String
        let consumedEnd: String.Index
        if remaining[index] == "\"" {
            let innerStart = remaining.index(after: index)
            if let close = remaining[innerStart...].firstIndex(of: "\"") {
                value = String(remaining[innerStart..<close])
                consumedEnd = remaining.index(after: close)
            } else {
                value = String(remaining[innerStart...])
                consumedEnd = remaining.endIndex
            }
        } else {
            var end = index
            while end < remaining.endIndex, !remaining[end].isWhitespace {
                end = remaining.index(after: end)
            }
            value = String(remaining[index..<end])
            consumedEnd = end
        }
        remaining.removeSubrange(range.lowerBound..<consumedEnd)
        remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func uid(from raw: String) throws -> UID {
        guard let value = UInt32(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            throw MailMCPError.invalidInput("Invalid IMAP UID \(raw)")
        }
        return UID(value)
    }

    private static func flags(from labels: [String]) -> [Flag] {
        labels.map { label in
            switch label.lowercased() {
            case "\\seen", "seen": return .seen
            case "\\answered", "answered": return .answered
            case "\\flagged", "flagged": return .flagged
            case "\\deleted", "deleted": return .deleted
            case "\\draft", "draft": return .draft
            default: return .custom(label)
            }
        }
    }

    private static func flagLabel(_ flag: Flag) -> String {
        switch flag {
        case .seen: return "\\Seen"
        case .answered: return "\\Answered"
        case .flagged: return "\\Flagged"
        case .deleted: return "\\Deleted"
        case .draft: return "\\Draft"
        case .custom(let value): return value
        }
    }

    private static func address(_ raw: String) -> EmailAddress {
        EmailAddress(raw) ?? EmailAddress(address: raw)
    }

    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func imapTransport(_ settings: IMAPSettings) -> MailTransportSecurity {
        if settings.imapPort == 993 { return .implicitTLS }
        if settings.imapStartTLS { return .startTLS }
        return .automatic
    }

    private static func smtpTransport(_ settings: IMAPSettings) -> MailTransportSecurity {
        if settings.smtpPort == 465 { return .implicitTLS }
        if settings.smtpStartTLS { return .startTLS }
        return .automatic
    }

    private static func isRetryable(_ error: Error) -> Bool {
        let text = String(describing: error) + error.localizedDescription
        return text.localizedCaseInsensitiveContains("ssl")
            || text.localizedCaseInsensitiveContains("tls")
            || text.localizedCaseInsensitiveContains("timeout")
            || text.localizedCaseInsensitiveContains("connection reset")
            || text.localizedCaseInsensitiveContains("broken pipe")
            || text.localizedCaseInsensitiveContains("connectionfailed")
            || text.localizedCaseInsensitiveContains("notconnected")
    }
}

enum IMAPAccountGate {
    private static let tableLock = NSLock()
    private static var gates: [UUID: NSLock] = [:]

    static func lock(for accountID: UUID) -> NSLock {
        tableLock.lock()
        defer { tableLock.unlock() }
        if let existing = gates[accountID] { return existing }
        let created = NSLock()
        gates[accountID] = created
        return created
    }
}
