import Foundation

struct IMAPProvider: MailProviding {
    let account: MailAccount
    let settings: IMAPSettings

    func testConnection() async throws -> String {
        try await withClient { client in
            let folders = try client.listFolders()
            return "IMAP OK — \(folders.count) folders"
        }
    }

    func listFolders() async throws -> [MailFolderCount] {
        try await withClient { client in
            let folders = try client.listFolders()
            return folders.map { folder in
                let noselect = folder.flags.contains { $0.caseInsensitiveCompare("\\Noselect") == .orderedSame }
                if noselect {
                    return MailFolderCount(name: folder.name, messages: nil, unseen: nil, selectable: false)
                }
                let status = try? client.folderStatus(mailbox: folder.name)
                return MailFolderCount(
                    name: folder.name,
                    messages: status?.messages,
                    unseen: status?.unseen,
                    selectable: true
                )
            }
        }
    }

    func messageCount(query: String) async throws -> Int {
        try await withClient { client in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return try client.messageCount()
            }
            if trimmed.lowercased() == "is:unread" || trimmed.lowercased() == "unseen" {
                return try client.folderStatus(mailbox: "INBOX").unseen ?? 0
            }
            try client.select("INBOX")
            return try client.search(query: query, limit: 200).count
        }
    }

    func search(query: String, limit: Int) async throws -> [MailSummary] {
        try await withClient { client in
            try client.select("INBOX")
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            let fetched: [IMAPFetchResult]
            if trimmed.isEmpty {
                fetched = try client.fetchRecent(limit: limit)
            } else if lower == "is:unread" || lower == "unseen" {
                fetched = try client.fetchRecentUnseen(limit: limit)
            } else {
                let uids = try client.search(query: query, limit: limit)
                fetched = try client.fetch(uids: uids)
            }
            return fetched.reversed().map { item in
                summary(from: item)
            }
        }
    }

    func getMessage(id: String) async throws -> MailMessage {
        try await withClient { client in
            if id.hasPrefix("draft:") {
                let drafts = try client.specialFolder(matching: ["Drafts", "[Gmail]/Drafts", "Draft"], flag: "\\Drafts")
                try client.select(drafts)
                let uid = String(id.dropFirst(6))
                guard let item = try client.fetch(uids: [uid]).first else {
                    throw MailMCPError.provider("Draft \(id) not found")
                }
                return message(from: item)
            }
            try client.select("INBOX")
            guard let item = try client.fetch(uids: [id]).first else {
                throw MailMCPError.provider("Message \(id) not found")
            }
            return message(from: item)
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
        try await withClient { client in
            try client.select("INBOX")
            switch action {
            case .markRead:
                try client.storeFlags(uid: id, add: ["\\Seen"])
            case .markUnread:
                try client.storeFlags(uid: id, remove: ["\\Seen"])
            case .trash:
                let trash = try client.specialFolder(matching: ["Trash", "Deleted", "Deleted Messages"], flag: "\\Trash")
                try client.move(uid: id, to: trash)
            case .archive:
                let archive = try client.specialFolder(matching: ["Archive", "Archived"], flag: "\\Archive")
                try client.move(uid: id, to: archive)
            case .addLabel:
                if let label {
                    try client.storeFlags(uid: id, add: [label])
                }
            case .removeLabel:
                if let label {
                    try client.storeFlags(uid: id, remove: [label])
                }
            }
        }
    }

    func createDraft(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws -> String {
        try await withClient { client in
            let drafts = try client.specialFolder(matching: ["Drafts", "Draft"], flag: "\\Drafts")
            let rfc822 = RFC822.makeMessage(from: account.email, to: to, cc: cc, bcc: bcc, subject: subject, body: body)
            try client.append(mailbox: drafts, rfc822: rfc822, flags: "\\Draft")
            return "draft-saved:\(drafts)"
        }
    }

    func send(to: [String], cc: [String], bcc: [String], subject: String, body: String, extraHeaders: [String: String] = [:]) async throws -> String {
        let rfc822 = RFC822.makeMessage(from: account.email, to: to, cc: cc, bcc: bcc, subject: subject, body: body, extraHeaders: extraHeaders)
        try SMTPClient(settings: settings).send(from: account.email, to: to, cc: cc, bcc: bcc, rfc822: rfc822)
        return "sent"
    }

    func getThread(id: String, limit: Int) async throws -> [MailMessage] {
        let seed = try await getMessage(id: id)
        let subject = seed.subject.replacingOccurrences(of: #"^(Re|Fwd|Fw):\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        let matches = try await search(query: "subject:\(subject)", limit: max(limit, 20))
        var messages: [MailMessage] = []
        for item in matches.prefix(limit) {
            messages.append(try await getMessage(id: item.id))
        }
        if messages.isEmpty { messages = [seed] }
        return messages.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    func listDrafts(limit: Int) async throws -> [MailDraft] {
        try await withClient { client in
            let drafts = try client.specialFolder(matching: ["Drafts", "[Gmail]/Drafts", "Draft"], flag: "\\Drafts")
            try client.select(drafts)
            let uids = try client.search(query: "", limit: limit)
            return try client.fetch(uids: uids).reversed().map { item in
                let parsed = MIMEParser.plainText(from: item.headers, body: item.text)
                return MailDraft(
                    id: "draft:\(item.uid)",
                    accountEmail: account.email,
                    to: RFC822.addresses(item.headers["to"]),
                    cc: RFC822.addresses(item.headers["cc"]),
                    subject: item.headers["subject"] ?? "(no subject)",
                    snippet: String(parsed.text.replacingOccurrences(of: "\n", with: " ").prefix(160)),
                    date: RFC822.date(from: item.headers["date"])
                )
            }
        }
    }

    func updateDraft(id: String, to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws -> String {
        try await deleteDraft(id: id)
        return try await createDraft(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
    }

    func deleteDraft(id: String) async throws {
        try await withClient { client in
            let drafts = try client.specialFolder(matching: ["Drafts", "[Gmail]/Drafts", "Draft"], flag: "\\Drafts")
            try client.select(drafts)
            let uid = id.hasPrefix("draft:") ? String(id.dropFirst(6)) : id
            try client.storeFlags(uid: uid, add: ["\\Deleted"])
            try? client.expunge()
        }
    }

    func fileMessage(id: String, folder: String?, addLabels: [String], removeLabels: [String]) async throws {
        try await withClient { client in
            try client.select("INBOX")
            if let folder, !folder.isEmpty {
                try client.move(uid: id, to: folder)
            }
            if !addLabels.isEmpty {
                try client.storeFlags(uid: id, add: addLabels)
            }
            if !removeLabels.isEmpty {
                try client.storeFlags(uid: id, remove: removeLabels)
            }
        }
    }

    func frequentContacts(limit: Int) async throws -> [MailContact] {
        try await withClient { client in
            let sent = try client.specialFolder(matching: ["[Gmail]/Sent Mail", "Sent", "Sent Messages", "Sent Items"], flag: "\\Sent")
            try client.select(sent)
            let uids = try client.search(query: "", limit: 80)
            let fetched = try client.fetch(uids: uids)
            var counts: [String: (name: String, count: Int)] = [:]
            for item in fetched {
                for raw in RFC822.addresses(item.headers["to"]) + RFC822.addresses(item.headers["cc"]) {
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
        let section = attachmentID.hasPrefix("imap:") ? String(attachmentID.dropFirst(5)) : attachmentID
        return try await withClient { client in
            try client.select("INBOX")
            let data = try client.fetchPart(uid: messageID, section: section)
            return MailAttachmentData(
                meta: MailAttachmentMeta(id: attachmentID, filename: "attachment", mimeType: "application/octet-stream", size: data.count),
                dataBase64: data.base64EncodedString()
            )
        }
    }

    private func withClient<T: Sendable>(_ work: @escaping @Sendable (IMAPClient) throws -> T) async throws -> T {
        let settings = self.settings
        let accountID = account.id
        return try await Task.detached {
            let gate = IMAPAccountGate.lock(for: accountID)
            gate.lock()
            defer { gate.unlock() }
            let client = IMAPClient(settings: settings)
            try client.connect()
            defer { client.disconnect() }
            return try work(client)
        }.value
    }

    private func summary(from item: IMAPFetchResult) -> MailSummary {
        let parsed = MIMEParser.plainText(from: item.headers, body: item.text)
        let snippet = String(parsed.text.replacingOccurrences(of: "\n", with: " ").prefix(180))
        return MailSummary(
            id: item.uid,
            accountID: account.id,
            accountEmail: account.email,
            threadID: item.headers["message-id"],
            from: item.headers["from"] ?? "",
            to: RFC822.addresses(item.headers["to"]),
            subject: item.headers["subject"] ?? "(no subject)",
            date: RFC822.date(from: item.headers["date"]),
            snippet: snippet,
            isUnread: !item.flags.contains(where: { $0.caseInsensitiveCompare("\\Seen") == .orderedSame }),
            labels: item.flags
        )
    }

    private func message(from item: IMAPFetchResult) -> MailMessage {
        let parsed = MIMEParser.plainText(from: item.headers, body: item.text)
        return MailMessage(
            id: item.uid,
            accountID: account.id,
            accountEmail: account.email,
            threadID: item.headers["message-id"],
            from: item.headers["from"] ?? "",
            to: RFC822.addresses(item.headers["to"]),
            cc: RFC822.addresses(item.headers["cc"]),
            bcc: RFC822.addresses(item.headers["bcc"]),
            subject: item.headers["subject"] ?? "(no subject)",
            date: RFC822.date(from: item.headers["date"]),
            body: parsed.text,
            bodyHTML: parsed.html,
            isUnread: !item.flags.contains(where: { $0.caseInsensitiveCompare("\\Seen") == .orderedSame }),
            labels: item.flags,
            attachments: parsed.attachments
        )
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
