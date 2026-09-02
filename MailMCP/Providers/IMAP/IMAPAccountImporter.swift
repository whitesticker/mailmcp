import Foundation

struct IMAPImportDraft: Sendable, Equatable {
    var email: String
    var password: String
    var nickname: String
    var username: String
}

struct IMAPImportResult: Sendable {
    var added: [String]
    var replaced: [String]
    var skipped: [String]
    var errors: [String]
}

enum IMAPAccountImporter {
    private static let emailPattern = try! NSRegularExpression(
        pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,
        options: [.caseInsensitive]
    )

    static func parse(_ text: String) -> [IMAPImportDraft] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var drafts: [IMAPImportDraft] = []
        var seen = Set<String>()

        func append(_ draft: IMAPImportDraft) {
            let email = draft.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let password = draft.password.trimmingCharacters(in: .whitespacesAndNewlines)
            guard email.contains("@"), !password.isEmpty, !seen.contains(email) else { return }
            seen.insert(email)
            let nickname = draft.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            drafts.append(
                IMAPImportDraft(
                    email: email,
                    password: password,
                    nickname: nickname,
                    username: draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }

        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let csv = parseCSVRows(lines), !csv.isEmpty {
            csv.forEach(append)
            return drafts
        }

        var block: [String] = []
        func flush() {
            if let draft = parseBlock(block) {
                append(draft)
            }
            block = []
        }
        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flush()
            } else {
                block.append(line)
            }
        }
        flush()
        return drafts
    }

    static func account(from draft: IMAPImportDraft) throws -> MailAccount {
        let settings = try IMAPSettings(
            imapHost: "",
            imapPort: 993,
            imapStartTLS: false,
            smtpHost: "",
            smtpPort: 465,
            smtpStartTLS: false,
            username: draft.username.isEmpty ? draft.email : draft.username,
            password: draft.password
        ).resolvingBlankHosts(for: draft.email)
        let nickname = draft.nickname.isEmpty
            ? String(draft.email.split(separator: "@").first ?? "")
            : draft.nickname
        return MailAccount(
            provider: .imap,
            email: draft.email,
            displayName: nickname,
            imap: settings
        )
    }

    private static func parseCSVRows(_ lines: [String]) -> [IMAPImportDraft]? {
        let rows = lines.compactMap { line -> [String]? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
            if trimmed.contains("\t") {
                return trimmed.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            if trimmed.contains(",") {
                return trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            return nil
        }
        guard !rows.isEmpty, rows.allSatisfy({ $0.count >= 2 && firstEmail(in: $0[0]) != nil }) else {
            return nil
        }
        return rows.compactMap { cols in
            guard let email = firstEmail(in: cols[0]) else { return nil }
            let password = cols[1]
            let nickname = cols.count > 2 ? cols[2] : ""
            return IMAPImportDraft(email: email, password: password, nickname: nickname, username: "")
        }
    }

    private static func parseBlock(_ lines: [String]) -> IMAPImportDraft? {
        let useful = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !useful.isEmpty else { return nil }

        var email = ""
        var password = ""
        var nickname = ""
        var username = ""
        var leftovers: [String] = []

        for raw in useful {
            let labeled = splitLabel(raw)
            if let found = firstEmail(in: labeled.value) {
                if email.isEmpty { email = found }
                let after = stripEmail(labeled.value, email: found)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if password.isEmpty, !after.isEmpty, labeled.key != "email" {
                    password = after
                } else if password.isEmpty, !after.isEmpty, labeled.key == "email" || labeled.key == nil {
                    password = after
                }
                continue
            }
            switch labeled.key {
            case "password", "pass", "app password", "secret":
                if password.isEmpty { password = labeled.value }
            case "name", "nickname", "label", "display":
                if nickname.isEmpty { nickname = labeled.value }
            case "username", "user", "login":
                if username.isEmpty { username = labeled.value }
            default:
                leftovers.append(labeled.value)
            }
        }

        if password.isEmpty, let extra = leftovers.last, extra.count >= 6 {
            password = extra
            leftovers.removeLast()
        }
        if nickname.isEmpty {
            nickname = leftovers.first ?? ""
        }
        guard !email.isEmpty, !password.isEmpty else { return nil }
        return IMAPImportDraft(email: email, password: password, nickname: nickname, username: username)
    }

    private static func splitLabel(_ line: String) -> (key: String?, value: String) {
        guard let colon = line.firstIndex(of: ":") else { return (nil, line) }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 16, !key.contains("@"), !value.isEmpty else {
            return (nil, line)
        }
        return (key, value)
    }

    private static func firstEmail(in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = emailPattern.firstMatch(in: text, options: [], range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private static func stripEmail(_ text: String, email: String) -> String {
        guard let range = text.range(of: email, options: .caseInsensitive) else { return text }
        var rest = text
        rest.removeSubrange(range)
        return rest.trimmingCharacters(in: CharacterSet(charactersIn: ",;| \t"))
    }
}
