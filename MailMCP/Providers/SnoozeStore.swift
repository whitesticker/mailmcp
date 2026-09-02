import Foundation

struct SnoozeRecord: Codable, Hashable, Identifiable, Sendable {
    var id: String { "\(accountID.uuidString):\(messageID)" }
    var accountID: UUID
    var messageID: String
    var until: Date
    var subject: String
}

enum SnoozeStore {
    static var url: URL {
        Paths.applicationSupport.appendingPathComponent("snoozed.json")
    }

    static func load() -> [SnoozeRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let items = (try? JSONCoders.decoder.decode([SnoozeRecord].self, from: data)) ?? []
        let active = items.filter { $0.until > Date() }
        if active.count != items.count { save(active) }
        return active
    }

    static func save(_ items: [SnoozeRecord]) {
        try? FileManager.default.createDirectory(at: Paths.applicationSupport, withIntermediateDirectories: true)
        try? JSONCoders.encoder.encode(items).write(to: url, options: .atomic)
    }

    static func snooze(accountID: UUID, messageID: String, until: Date, subject: String) {
        var items = load().filter { !($0.accountID == accountID && $0.messageID == messageID) }
        items.append(SnoozeRecord(accountID: accountID, messageID: messageID, until: until, subject: subject))
        save(items)
    }

    static func isSnoozed(accountID: UUID, messageID: String) -> Bool {
        load().contains { $0.accountID == accountID && $0.messageID == messageID && $0.until > Date() }
    }

    static func active(accountID: UUID) -> [SnoozeRecord] {
        load().filter { $0.accountID == accountID }
    }
}

enum MailCompose {
    static func reply(to original: MailMessage, accountEmail: String, body: String, replyAll: Bool) -> (to: [String], cc: [String], subject: String, body: String, headers: [String: String]) {
        let selfAddress = accountEmail.lowercased()
        let from = RFC822.addresses(original.from).first ?? original.from
        var to = [from].filter { !$0.lowercased().contains(selfAddress) }
        var cc: [String] = []
        if replyAll {
            let others = (original.to + original.cc).filter { !$0.lowercased().contains(selfAddress) && $0.caseInsensitiveCompare(from) != .orderedSame }
            cc = others
        }
        if to.isEmpty { to = [from] }
        let subject = original.subject.lowercased().hasPrefix("re:") ? original.subject : "Re: \(original.subject)"
        let quoted = quote(original)
        var headers: [String: String] = [:]
        if let messageID = original.threadID, !messageID.isEmpty {
            if messageID.contains("@") || messageID.contains("<") {
                headers["In-Reply-To"] = messageID
                headers["References"] = messageID
            }
            headers["X-Thread-Id"] = messageID
        }
        return (to, cc, subject, body.trimmingCharacters(in: .whitespacesAndNewlines) + quoted, headers)
    }

    static func forward(original: MailMessage, to: [String], body: String) -> (subject: String, body: String) {
        let subject = original.subject.lowercased().hasPrefix("fwd:") || original.subject.lowercased().hasPrefix("fw:")
            ? original.subject
            : "Fwd: \(original.subject)"
        let header = """


        ---------- Forwarded message ----------
        From: \(original.from)
        Date: \(original.date?.formatted() ?? "")
        Subject: \(original.subject)
        To: \(original.to.joined(separator: ", "))

        \(original.body)
        """
        return (subject, body.trimmingCharacters(in: .whitespacesAndNewlines) + header)
    }

    private static func quote(_ original: MailMessage) -> String {
        let lines = original.body.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        return "\n\nOn \(original.date?.formatted() ?? "an earlier date"), \(original.from) wrote:\n\(lines)"
    }
}
