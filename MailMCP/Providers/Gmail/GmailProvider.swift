import Foundation

final class GmailProvider: MailProviding, @unchecked Sendable {
    private let account: MailAccount
    private var tokens: OAuthTokens
    private let onTokens: @MainActor (OAuthTokens) -> Void

    init(account: MailAccount, tokens: OAuthTokens, onTokens: @escaping @MainActor (OAuthTokens) -> Void) {
        self.account = account
        self.tokens = tokens
        self.onTokens = onTokens
    }

    func testConnection() async throws -> String {
        let profile = try await getJSON(path: "users/me/profile")
        let email = profile["emailAddress"] as? String ?? account.email
        return "Gmail OK — \(email)"
    }

    func fetchWatermark() async throws -> String {
        let profile = try await getJSON(path: "users/me/profile")
        if let historyID = profile["historyId"] as? String {
            return "gmail:h=\(historyID)"
        }
        if let historyNum = profile["historyId"] as? NSNumber {
            return "gmail:h=\(historyNum.stringValue)"
        }
        let total = profile["messagesTotal"] as? Int ?? 0
        return "gmail:m=\(total)"
    }

    func listFolders(includeCounts: Bool) async throws -> [MailFolderCount] {
        let json = try await getJSON(path: "users/me/labels")
        let labels = json["labels"] as? [[String: Any]] ?? []
        var result: [MailFolderCount] = []
        for label in labels {
            guard let id = label["id"] as? String, let name = label["name"] as? String else { continue }
            if includeCounts {
                let detail = try await getJSON(path: "users/me/labels/\(id)")
                result.append(
                    MailFolderCount(
                        name: name,
                        messages: detail["messagesTotal"] as? Int,
                        unseen: detail["messagesUnread"] as? Int,
                        selectable: true,
                        remoteID: id
                    )
                )
            } else {
                result.append(
                    MailFolderCount(
                        name: name,
                        messages: label["messagesTotal"] as? Int,
                        unseen: label["messagesUnread"] as? Int,
                        selectable: true,
                        remoteID: id
                    )
                )
            }
        }
        return result
    }

    func resolveMailboxes(_ requested: [String]) async throws -> [ResolvedMailbox] {
        let folders = try await listFolders(includeCounts: false)
        var hints = folders.map { FolderHint(name: $0.name, remoteID: $0.remoteID) }
        if !hints.contains(where: { $0.kind == .spam }) {
            hints.append(FolderHint(name: "SPAM", remoteID: "SPAM", kind: .spam))
        }
        if !hints.contains(where: { $0.kind == .trash }) {
            hints.append(FolderHint(name: "TRASH", remoteID: "TRASH", kind: .trash))
        }
        if !hints.contains(where: { $0.kind == .inbox }) {
            hints.append(FolderHint(name: "INBOX", remoteID: "INBOX", kind: .inbox))
        }
        let requests = requested.flatMap { MailboxRequest.parse($0) }
        return MailboxMatcher.resolve(requests, folders: hints)
    }

    func searchFoldered(_ request: FolderSearchSpec) async throws -> [MailSummary] {
        let boxes = request.mailboxes
        let kinds = Set(boxes.map { MailboxMatcher.kind(ofName: $0) })
        if kinds.isSuperset(of: [.inbox, .spam, .trash]) || boxes.contains(where: { $0.lowercased() == "anywhere" }) {
            return try await searchGmail(
                query: gmailQuery(request.query, mailbox: "anywhere", after: request.after, before: request.before),
                limit: request.limit,
                mailbox: "anywhere",
                kind: MailboxKind.other.rawValue
            )
        }
        var hits: [MailSummary] = []
        for mailbox in boxes {
            try Task.checkCancellation()
            let kind = MailboxMatcher.kind(ofName: mailbox)
            let operatorName = gmailMailboxOperator(mailbox)
            let found = try await searchGmail(
                query: gmailQuery(request.query, mailbox: operatorName, after: request.after, before: request.before),
                limit: request.limit,
                mailbox: mailbox,
                kind: kind.rawValue
            )
            hits.append(contentsOf: found)
            if hits.count >= request.limit { break }
        }
        return Array(hits.prefix(max(request.limit, 1)))
    }

    func messageCount(query: String) async throws -> Int {
        var path = "users/me/messages?maxResults=1"
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            path += "&q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
        }
        let json = try await getJSON(path: path)
        if let estimate = json["resultSizeEstimate"] as? Int {
            return estimate
        }
        return (json["messages"] as? [Any])?.count ?? 0
    }

    func search(query: String, limit: Int) async throws -> [MailSummary] {
        try await searchGmail(query: query, limit: limit, mailbox: nil, kind: nil)
    }

    func getMessage(id: String) async throws -> MailMessage {
        let json = try await getJSON(path: "users/me/messages/\(id)?format=full")
        return parseMessage(json)
    }

    func listThreads(query: String?, limit: Int) async throws -> [MailThread] {
        var path = "users/me/threads?maxResults=\(min(max(limit, 1), 50))"
        if let query, !query.isEmpty {
            path += "&q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
        }
        let json = try await getJSON(path: path)
        let threads = json["threads"] as? [[String: Any]] ?? []
        var result: [MailThread] = []
        for item in threads {
            guard let id = item["id"] as? String else { continue }
            let detail = try await getJSON(path: "users/me/threads/\(id)?format=metadata&metadataHeaders=From&metadataHeaders=Subject")
            let messages = detail["messages"] as? [[String: Any]] ?? []
            let first = messages.first ?? [:]
            let payload = first["payload"] as? [String: Any]
            let headers = headerMap(payload?["headers"] as? [[String: Any]])
            let labelIDs = first["labelIds"] as? [String] ?? []
            result.append(
                MailThread(
                    id: id,
                    accountID: account.id,
                    accountEmail: account.email,
                    subject: headers["subject"] ?? "(no subject)",
                    participants: RFC822.addresses(headers["from"]),
                    snippet: (detail["snippet"] as? String) ?? (item["snippet"] as? String) ?? "",
                    date: epochMillis(first["internalDate"]),
                    messageCount: messages.count,
                    isUnread: labelIDs.contains("UNREAD")
                )
            )
        }
        return result
    }

    func modify(id: String, action: MailModifyAction, label: String?) async throws {
        var add: [String] = []
        var remove: [String] = []
        switch action {
        case .markRead: remove = ["UNREAD"]
        case .markUnread: add = ["UNREAD"]
        case .trash: add = ["TRASH"]; remove = ["INBOX"]
        case .archive: remove = ["INBOX"]
        case .addLabel:
            if let label { add = [label] }
        case .removeLabel:
            if let label { remove = [label] }
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "addLabelIds": add,
            "removeLabelIds": remove
        ])
        _ = try await authorized(path: "users/me/messages/\(id)/modify", method: "POST", body: body)
    }

    func createDraft(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws -> String {
        let raw = RFC822.makeMessage(from: account.email, to: to, cc: cc, bcc: bcc, subject: subject, body: body)
        let payload = try JSONSerialization.data(withJSONObject: [
            "message": ["raw": OAuthClient.base64URL(Data(raw.utf8))]
        ])
        let json = try await authorizedJSON(path: "users/me/drafts", method: "POST", body: payload)
        return (json["id"] as? String) ?? "draft"
    }

    func send(to: [String], cc: [String], bcc: [String], subject: String, body: String, extraHeaders: [String: String] = [:]) async throws -> String {
        let raw = RFC822.makeMessage(from: account.email, to: to, cc: cc, bcc: bcc, subject: subject, body: body, extraHeaders: extraHeaders)
        var payloadObject: [String: Any] = ["raw": OAuthClient.base64URL(Data(raw.utf8))]
        if let thread = extraHeaders["X-Thread-Id"], !thread.isEmpty {
            payloadObject["threadId"] = thread
        }
        let payload = try JSONSerialization.data(withJSONObject: payloadObject)
        let json = try await authorizedJSON(path: "users/me/messages/send", method: "POST", body: payload)
        return (json["id"] as? String) ?? "sent"
    }

    func getThread(id: String, limit: Int) async throws -> [MailMessage] {
        let json = try await getJSON(path: "users/me/threads/\(id)?format=full")
        let messages = json["messages"] as? [[String: Any]] ?? []
        return messages.prefix(limit).map { parseMessage($0) }
    }

    func listDrafts(limit: Int) async throws -> [MailDraft] {
        let json = try await getJSON(path: "users/me/drafts?maxResults=\(min(max(limit, 1), 50))")
        let drafts = json["drafts"] as? [[String: Any]] ?? []
        var result: [MailDraft] = []
        for draft in drafts {
            guard let id = draft["id"] as? String else { continue }
            let detail = try await getJSON(path: "users/me/drafts/\(id)")
            let message = (detail["message"] as? [String: Any]) ?? [:]
            let parsed = parseMessage(message)
            result.append(
                MailDraft(
                    id: id,
                    accountEmail: account.email,
                    to: parsed.to,
                    cc: parsed.cc,
                    subject: parsed.subject,
                    snippet: parsed.body,
                    date: parsed.date
                )
            )
        }
        return result
    }

    func updateDraft(id: String, to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws -> String {
        let raw = RFC822.makeMessage(from: account.email, to: to, cc: cc, bcc: bcc, subject: subject, body: body)
        let payload = try JSONSerialization.data(withJSONObject: [
            "message": ["raw": OAuthClient.base64URL(Data(raw.utf8))]
        ])
        let json = try await authorizedJSON(path: "users/me/drafts/\(id)", method: "PUT", body: payload)
        return (json["id"] as? String) ?? id
    }

    func deleteDraft(id: String) async throws {
        _ = try await authorized(path: "users/me/drafts/\(id)", method: "DELETE", body: nil)
    }

    func fileMessage(id: String, folder: String?, addLabels: [String], removeLabels: [String]) async throws {
        var add = try await resolveLabels(addLabels)
        var remove = try await resolveLabels(removeLabels)
        if let folder {
            let resolved = try await resolveLabel(folder)
            if resolved.uppercased() == "INBOX" { add.append("INBOX") }
            else if resolved.uppercased() == "TRASH" { add.append("TRASH"); remove.append("INBOX") }
            else { add.append(resolved); remove.append("INBOX") }
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "addLabelIds": add,
            "removeLabelIds": remove
        ])
        _ = try await authorized(path: "users/me/messages/\(id)/modify", method: "POST", body: body)
    }

    func frequentContacts(limit: Int) async throws -> [MailContact] {
        let json = try await getJSON(path: "users/me/messages?maxResults=40&q=in:sent")
        let messages = json["messages"] as? [[String: Any]] ?? []
        var counts: [String: Int] = [:]
        for item in messages {
            guard let id = item["id"] as? String else { continue }
            let summary = try await summary(id: id)
            for raw in summary.to {
                let key = raw.lowercased()
                counts[key, default: 0] += 1
            }
        }
        return counts.map { MailContact(address: $0.key, name: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(limit)
            .map { $0 }
    }

    func getAttachment(messageID: String, attachmentID: String) async throws -> MailAttachmentData {
        let json = try await getJSON(path: "users/me/messages/\(messageID)/attachments/\(attachmentID)")
        let encoded = json["data"] as? String ?? ""
        let padded = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        return MailAttachmentData(
            meta: MailAttachmentMeta(
                id: attachmentID,
                filename: "attachment",
                mimeType: "application/octet-stream",
                size: json["size"] as? Int
            ),
            dataBase64: padded
        )
    }

    private func searchGmail(query: String, limit: Int, mailbox: String?, kind: String?) async throws -> [MailSummary] {
        var path = "users/me/messages?maxResults=\(min(max(limit, 1), 50))"
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            path += "&q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
        }
        let json = try await getJSON(path: path)
        let messages = json["messages"] as? [[String: Any]] ?? []
        var summaries: [MailSummary] = []
        for item in messages {
            guard let id = item["id"] as? String else { continue }
            var row = try await summary(id: id)
            if row.mailbox == nil { row.mailbox = mailbox }
            if row.mailboxKind == nil { row.mailboxKind = kind }
            summaries.append(row)
        }
        return summaries
    }

    private func gmailQuery(_ text: String, mailbox: String?, after: Date?, before: Date?) -> String {
        var parts: [String] = []
        if let mailbox, !mailbox.isEmpty {
            parts.append("in:\(mailbox)")
        }
        if let after {
            parts.append("after:\(MailSearchQuery.gmailDate(after))")
        }
        if let before {
            parts.append("before:\(MailSearchQuery.gmailDate(before))")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        return parts.joined(separator: " ")
    }

    private func gmailMailboxOperator(_ mailbox: String) -> String {
        switch MailboxMatcher.kind(ofName: mailbox) {
        case .spam: return "spam"
        case .trash: return "trash"
        case .inbox: return "inbox"
        case .all: return "all"
        case .drafts: return "drafts"
        case .sent: return "sent"
        default:
            if mailbox.lowercased() == "anywhere" { return "anywhere" }
            return mailbox
        }
    }

    private func mailboxName(from labels: [String]) -> String? {
        let upper = labels.map { $0.uppercased() }
        if upper.contains("SPAM") { return "SPAM" }
        if upper.contains("TRASH") { return "TRASH" }
        if upper.contains("INBOX") { return "INBOX" }
        if upper.contains("DRAFT") { return "DRAFT" }
        if upper.contains("SENT") { return "SENT" }
        return labels.first { $0 != "UNREAD" && $0 != "IMPORTANT" && $0 != "STARRED" && $0 != "CATEGORY_PERSONAL" }
    }

    private func summary(id: String) async throws -> MailSummary {
        let json = try await getJSON(path: "users/me/messages/\(id)?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject&metadataHeaders=Date")
        let payload = json["payload"] as? [String: Any]
        let headers = headerMap(payload?["headers"] as? [[String: Any]])
        let labels = json["labelIds"] as? [String] ?? []
        let mailbox = mailboxName(from: labels)
        return MailSummary(
            id: id,
            accountID: account.id,
            accountEmail: account.email,
            threadID: json["threadId"] as? String,
            from: headers["from"] ?? "",
            to: RFC822.addresses(headers["to"]),
            subject: headers["subject"] ?? "(no subject)",
            date: epochMillis(json["internalDate"]),
            snippet: json["snippet"] as? String ?? "",
            isUnread: labels.contains("UNREAD"),
            labels: labels,
            mailbox: mailbox,
            mailboxKind: MailboxMatcher.kind(ofName: mailbox ?? "").rawValue
        )
    }

    private func parseMessage(_ json: [String: Any]) -> MailMessage {
        let payload = json["payload"] as? [String: Any] ?? [:]
        let headers = headerMap(payload["headers"] as? [[String: Any]])
        let labels = json["labelIds"] as? [String] ?? []
        let extracted = extractBodies(payload)
        return MailMessage(
            id: json["id"] as? String ?? "",
            accountID: account.id,
            accountEmail: account.email,
            threadID: json["threadId"] as? String,
            from: headers["from"] ?? "",
            to: RFC822.addresses(headers["to"]),
            cc: RFC822.addresses(headers["cc"]),
            bcc: RFC822.addresses(headers["bcc"]),
            subject: headers["subject"] ?? "(no subject)",
            date: epochMillis(json["internalDate"]),
            body: extracted.text.isEmpty ? (json["snippet"] as? String ?? "") : extracted.text,
            bodyHTML: extracted.html,
            isUnread: labels.contains("UNREAD"),
            labels: labels,
            attachments: extracted.attachments,
            mailbox: mailboxName(from: labels),
            mailboxKind: MailboxMatcher.kind(ofName: mailboxName(from: labels) ?? "").rawValue
        )
    }

    private func extractBodies(_ part: [String: Any]) -> (text: String, html: String?, attachments: [MailAttachmentMeta]) {
        var text = ""
        var html: String?
        var attachments: [MailAttachmentMeta] = []
        let mime = (part["mimeType"] as? String ?? "").lowercased()
        let body = part["body"] as? [String: Any] ?? [:]
        if let data = body["data"] as? String {
            let decoded = decodeBase64URL(data)
            if mime.contains("text/plain") {
                text = decoded
            } else if mime.contains("text/html") {
                html = decoded
            }
        }
        if let filename = part["filename"] as? String, !filename.isEmpty, let attachmentID = body["attachmentId"] as? String {
            attachments.append(
                MailAttachmentMeta(
                    id: attachmentID,
                    filename: filename,
                    mimeType: mime.isEmpty ? "application/octet-stream" : mime,
                    size: body["size"] as? Int
                )
            )
        }
        for child in part["parts"] as? [[String: Any]] ?? [] {
            let nested = extractBodies(child)
            if text.isEmpty { text = nested.text }
            if html == nil { html = nested.html }
            attachments.append(contentsOf: nested.attachments)
        }
        if text.isEmpty, let html {
            text = MIMEParser.stripHTML(html)
        }
        return (text, html, attachments)
    }

    private func headerMap(_ headers: [[String: Any]]?) -> [String: String] {
        var map: [String: String] = [:]
        for header in headers ?? [] {
            if let name = header["name"] as? String, let value = header["value"] as? String {
                map[name.lowercased()] = value
            }
        }
        return map
    }

    private func epochMillis(_ value: Any?) -> Date? {
        if let string = value as? String, let millis = Double(string) {
            return Date(timeIntervalSince1970: millis / 1000)
        }
        if let millis = value as? Double {
            return Date(timeIntervalSince1970: millis / 1000)
        }
        return nil
    }

    private func decodeBase64URL(_ value: String) -> String {
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - encoded.count % 4) % 4
        encoded += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: encoded) else { return value }
        return String(decoding: data, as: UTF8.self)
    }

    private func resolveLabel(_ name: String) async throws -> String {
        try await resolveLabels([name]).first ?? name
    }

    private func resolveLabels(_ names: [String]) async throws -> [String] {
        guard !names.isEmpty else { return [] }
        let folders = try await listFolders()
        return names.map { name in
            if let match = folders.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame || ($0.remoteID?.caseInsensitiveCompare(name) == .orderedSame)
            }) {
                return match.remoteID ?? match.name
            }
            return name
        }
    }

    private func getJSON(path: String) async throws -> [String: Any] {
        try await authorizedJSON(path: path, method: "GET", body: nil)
    }

    private func authorizedJSON(path: String, method: String, body: Data?) async throws -> [String: Any] {
        let data = try await authorized(path: path, method: method, body: body)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MailMCPError.provider("Gmail returned non-JSON")
        }
        return json
    }

    private func authorized(path: String, method: String, body: Data?) async throws -> Data {
        try await refreshIfNeeded()
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/\(path)") else {
            throw MailMCPError.provider("Bad Gmail URL")
        }
        let (data, response) = try await HTTPJSON.request(url: url, method: method, token: tokens.accessToken, body: body)
        if response.statusCode == 401 {
            tokens = try await OAuthClient.refresh(tokens: tokens)
            await MainActor.run { onTokens(tokens) }
            let retry = try await HTTPJSON.request(url: url, method: method, token: tokens.accessToken, body: body)
            if !(200..<300).contains(retry.1.statusCode) {
                throw MailMCPError.provider(String(data: retry.0, encoding: .utf8) ?? "Gmail HTTP \(retry.1.statusCode)")
            }
            return retry.0
        }
        if !(200..<300).contains(response.statusCode) {
            throw MailMCPError.provider(String(data: data, encoding: .utf8) ?? "Gmail HTTP \(response.statusCode)")
        }
        return data
    }

    private func refreshIfNeeded() async throws {
        guard tokens.isAccessTokenExpired else { return }
        tokens = try await OAuthClient.refresh(tokens: tokens)
        await MainActor.run { onTokens(tokens) }
    }
}

enum GmailUserInfo {
    static func email(tokens: OAuthTokens) async throws -> String {
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo") else {
            throw MailMCPError.oauth("Bad userinfo URL")
        }
        let (data, response) = try await HTTPJSON.request(url: url, token: tokens.accessToken)
        if !(200..<300).contains(response.statusCode) {
            throw MailMCPError.oauth(String(data: data, encoding: .utf8) ?? "userinfo failed")
        }
        let json = try OAuthClient.decodeJSON(data)
        if let email = json["email"] as? String {
            return email
        }
        throw MailMCPError.oauth("Google userinfo did not include email")
    }
}
