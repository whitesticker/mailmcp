import Foundation

final class GraphProvider: MailProviding, @unchecked Sendable {
    private let account: MailAccount
    private var tokens: OAuthTokens
    private let onTokens: @MainActor (OAuthTokens) -> Void

    init(account: MailAccount, tokens: OAuthTokens, onTokens: @escaping @MainActor (OAuthTokens) -> Void) {
        self.account = account
        self.tokens = tokens
        self.onTokens = onTokens
    }

    func testConnection() async throws -> String {
        let me = try await getJSON(path: "me")
        let email = (me["mail"] as? String) ?? (me["userPrincipalName"] as? String) ?? account.email
        return "Microsoft Graph OK — \(email)"
    }

    func listFolders() async throws -> [MailFolderCount] {
        let json = try await getJSON(path: "me/mailFolders?$top=100")
        let folders = json["value"] as? [[String: Any]] ?? []
        return folders.compactMap { folder in
            guard let name = folder["displayName"] as? String else { return nil }
            return MailFolderCount(
                name: name,
                messages: folder["totalItemCount"] as? Int,
                unseen: folder["unreadItemCount"] as? Int,
                selectable: true,
                remoteID: folder["id"] as? String
            )
        }
    }

    func messageCount(query: String) async throws -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let json = try await getJSON(path: "me/mailFolders/inbox")
            return (json["totalItemCount"] as? Int) ?? 0
        }
        return try await search(query: query, limit: 50).count
    }

    func search(query: String, limit: Int) async throws -> [MailSummary] {
        let top = min(max(limit, 1), 50)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if trimmed.isEmpty {
            path = "me/messages?$top=\(top)&$select=id,subject,from,toRecipients,receivedDateTime,bodyPreview,isRead,conversationId,categories"
        } else if trimmed.lowercased() == "is:unread" || trimmed.lowercased() == "unseen" {
            path = "me/messages?$top=\(top)&$filter=isRead eq false&$select=id,subject,from,toRecipients,receivedDateTime,bodyPreview,isRead,conversationId,categories"
        } else {
            let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            path = "me/messages?$top=\(top)&$search=%22\(encoded)%22&$select=id,subject,from,toRecipients,receivedDateTime,bodyPreview,isRead,conversationId,categories"
        }
        let json = try await getJSON(path: path)
        let items = json["value"] as? [[String: Any]] ?? []
        return items.compactMap { summary(from: $0) }
    }

    func getMessage(id: String) async throws -> MailMessage {
        let json = try await getJSON(path: "me/messages/\(id)")
        return message(from: json)
    }

    func listThreads(query: String?, limit: Int) async throws -> [MailThread] {
        let messages = try await search(query: query ?? "", limit: limit)
        var groups: [String: [MailSummary]] = [:]
        for message in messages {
            groups[message.threadID ?? message.id, default: []].append(message)
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
        switch action {
        case .markRead, .markUnread:
            let body = try JSONSerialization.data(withJSONObject: ["isRead": action == .markRead])
            _ = try await authorized(path: "me/messages/\(id)", method: "PATCH", body: body)
        case .trash:
            _ = try await authorized(path: "me/messages/\(id)/move", method: "POST", body: try JSONSerialization.data(withJSONObject: ["destinationId": "deleteditems"]))
        case .archive:
            _ = try await authorized(path: "me/messages/\(id)/move", method: "POST", body: try JSONSerialization.data(withJSONObject: ["destinationId": "archive"]))
        case .addLabel:
            if let label {
                let current = try await getJSON(path: "me/messages/\(id)?$select=categories")
                var categories = current["categories"] as? [String] ?? []
                if !categories.contains(label) { categories.append(label) }
                let body = try JSONSerialization.data(withJSONObject: ["categories": categories])
                _ = try await authorized(path: "me/messages/\(id)", method: "PATCH", body: body)
            }
        case .removeLabel:
            if let label {
                let current = try await getJSON(path: "me/messages/\(id)?$select=categories")
                let categories = (current["categories"] as? [String] ?? []).filter { $0 != label }
                let body = try JSONSerialization.data(withJSONObject: ["categories": categories])
                _ = try await authorized(path: "me/messages/\(id)", method: "PATCH", body: body)
            }
        }
    }

    func createDraft(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws -> String {
        let payload = graphMessage(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
        let json = try await authorizedJSON(path: "me/messages", method: "POST", body: try JSONSerialization.data(withJSONObject: payload))
        return (json["id"] as? String) ?? "draft"
    }

    func send(to: [String], cc: [String], bcc: [String], subject: String, body: String, extraHeaders: [String: String] = [:]) async throws -> String {
        var message = graphMessage(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
        if !extraHeaders.isEmpty {
            message["internetMessageHeaders"] = extraHeaders.map { ["name": $0.key, "value": $0.value] }
        }
        _ = try await authorized(path: "me/sendMail", method: "POST", body: try JSONSerialization.data(withJSONObject: ["message": message]))
        return "sent"
    }

    func getThread(id: String, limit: Int) async throws -> [MailMessage] {
        let json = try await getJSON(path: "me/messages?$filter=conversationId eq '\(id)'&$top=\(min(max(limit, 1), 50))")
        let items = json["value"] as? [[String: Any]] ?? []
        return items.map { message(from: $0) }
    }

    func listDrafts(limit: Int) async throws -> [MailDraft] {
        let json = try await getJSON(path: "me/mailFolders/drafts/messages?$top=\(min(max(limit, 1), 50))&$select=id,subject,toRecipients,ccRecipients,bodyPreview,receivedDateTime")
        let items = json["value"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return MailDraft(
                id: id,
                accountEmail: account.email,
                to: addresses(item["toRecipients"]),
                cc: addresses(item["ccRecipients"]),
                subject: item["subject"] as? String ?? "(no subject)",
                snippet: item["bodyPreview"] as? String ?? "",
                date: ISO8601DateFormatter().date(from: item["receivedDateTime"] as? String ?? "")
            )
        }
    }

    func updateDraft(id: String, to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws -> String {
        let payload = graphMessage(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
        _ = try await authorized(path: "me/messages/\(id)", method: "PATCH", body: try JSONSerialization.data(withJSONObject: payload))
        return id
    }

    func deleteDraft(id: String) async throws {
        _ = try await authorized(path: "me/messages/\(id)", method: "DELETE", body: nil)
    }

    func fileMessage(id: String, folder: String?, addLabels: [String], removeLabels: [String]) async throws {
        if let folder, !folder.isEmpty {
            let folders = try await listFolders()
            let match = folders.first { $0.name.caseInsensitiveCompare(folder) == .orderedSame }
            let dest = match?.remoteID ?? match?.name ?? folder
            _ = try await authorized(
                path: "me/messages/\(id)/move",
                method: "POST",
                body: try JSONSerialization.data(withJSONObject: ["destinationId": dest])
            )
        }
        for label in addLabels {
            try await modify(id: id, action: .addLabel, label: label)
        }
        for label in removeLabels {
            try await modify(id: id, action: .removeLabel, label: label)
        }
    }

    func frequentContacts(limit: Int) async throws -> [MailContact] {
        let json = try await getJSON(path: "me/mailFolders/sentitems/messages?$top=40&$select=toRecipients")
        let items = json["value"] as? [[String: Any]] ?? []
        var counts: [String: Int] = [:]
        for item in items {
            for raw in addresses(item["toRecipients"]) {
                counts[raw.lowercased(), default: 0] += 1
            }
        }
        return counts.map { MailContact(address: $0.key, name: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(limit)
            .map { $0 }
    }

    func getAttachment(messageID: String, attachmentID: String) async throws -> MailAttachmentData {
        let json = try await getJSON(path: "me/messages/\(messageID)/attachments/\(attachmentID)")
        return MailAttachmentData(
            meta: MailAttachmentMeta(
                id: attachmentID,
                filename: json["name"] as? String ?? "attachment",
                mimeType: json["contentType"] as? String ?? "application/octet-stream",
                size: json["size"] as? Int
            ),
            dataBase64: json["contentBytes"] as? String ?? ""
        )
    }

    private func summary(from json: [String: Any]) -> MailSummary? {
        guard let id = json["id"] as? String else { return nil }
        return MailSummary(
            id: id,
            accountID: account.id,
            accountEmail: account.email,
            threadID: json["conversationId"] as? String,
            from: address(json["from"]),
            to: addresses(json["toRecipients"]),
            subject: json["subject"] as? String ?? "(no subject)",
            date: ISO8601DateFormatter().date(from: json["receivedDateTime"] as? String ?? ""),
            snippet: json["bodyPreview"] as? String ?? "",
            isUnread: (json["isRead"] as? Bool) == false,
            labels: json["categories"] as? [String] ?? []
        )
    }

    private func message(from json: [String: Any]) -> MailMessage {
        let body = json["body"] as? [String: Any] ?? [:]
        let content = body["content"] as? String ?? ""
        let type = (body["contentType"] as? String ?? "").lowercased()
        let attachmentsJSON = json["attachments"] as? [[String: Any]] ?? []
        let attachments = attachmentsJSON.compactMap { item -> MailAttachmentMeta? in
            guard let id = item["id"] as? String else { return nil }
            return MailAttachmentMeta(
                id: id,
                filename: item["name"] as? String ?? "attachment",
                mimeType: item["contentType"] as? String ?? "application/octet-stream",
                size: item["size"] as? Int
            )
        }
        return MailMessage(
            id: json["id"] as? String ?? "",
            accountID: account.id,
            accountEmail: account.email,
            threadID: json["conversationId"] as? String,
            from: address(json["from"]),
            to: addresses(json["toRecipients"]),
            cc: addresses(json["ccRecipients"]),
            bcc: addresses(json["bccRecipients"]),
            subject: json["subject"] as? String ?? "(no subject)",
            date: ISO8601DateFormatter().date(from: json["receivedDateTime"] as? String ?? ""),
            body: type == "html" ? MIMEParser.stripHTML(content) : content,
            bodyHTML: type == "html" ? content : nil,
            isUnread: (json["isRead"] as? Bool) == false,
            labels: json["categories"] as? [String] ?? [],
            attachments: attachments
        )
    }

    private func graphMessage(to: [String], cc: [String], bcc: [String], subject: String, body: String) -> [String: Any] {
        [
            "subject": subject,
            "body": ["contentType": "Text", "content": body],
            "toRecipients": to.map { ["emailAddress": ["address": $0]] },
            "ccRecipients": cc.map { ["emailAddress": ["address": $0]] },
            "bccRecipients": bcc.map { ["emailAddress": ["address": $0]] }
        ]
    }

    private func address(_ value: Any?) -> String {
        guard let object = value as? [String: Any],
              let email = object["emailAddress"] as? [String: Any] else { return "" }
        let address = email["address"] as? String ?? ""
        if let name = email["name"] as? String, !name.isEmpty {
            return "\(name) <\(address)>"
        }
        return address
    }

    private func addresses(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).map { address($0) }.filter { !$0.isEmpty }
    }

    private func getJSON(path: String) async throws -> [String: Any] {
        try await authorizedJSON(path: path, method: "GET", body: nil)
    }

    private func authorizedJSON(path: String, method: String, body: Data?) async throws -> [String: Any] {
        let data = try await authorized(path: path, method: method, body: body)
        if data.isEmpty { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MailMCPError.provider("Graph returned non-JSON")
        }
        return json
    }

    private func authorized(path: String, method: String, body: Data?) async throws -> Data {
        try await refreshIfNeeded()
        guard let url = URL(string: "https://graph.microsoft.com/v1.0/\(path)") else {
            throw MailMCPError.provider("Bad Graph URL")
        }
        var headers: [String: String] = [:]
        if path.contains("$search=") {
            headers["ConsistencyLevel"] = "eventual"
        }
        let (data, response) = try await HTTPJSON.request(url: url, method: method, token: tokens.accessToken, body: body, headers: headers)
        if response.statusCode == 401 {
            tokens = try await OAuthClient.refresh(tokens: tokens)
            await MainActor.run { onTokens(tokens) }
            let retry = try await HTTPJSON.request(url: url, method: method, token: tokens.accessToken, body: body, headers: headers)
            if !(200..<300).contains(retry.1.statusCode) {
                throw MailMCPError.provider(String(data: retry.0, encoding: .utf8) ?? "Graph HTTP \(retry.1.statusCode)")
            }
            return retry.0
        }
        if !(200..<300).contains(response.statusCode) {
            throw MailMCPError.provider(String(data: data, encoding: .utf8) ?? "Graph HTTP \(response.statusCode)")
        }
        return data
    }

    private func refreshIfNeeded() async throws {
        guard tokens.isAccessTokenExpired else { return }
        tokens = try await OAuthClient.refresh(tokens: tokens)
        await MainActor.run { onTokens(tokens) }
    }
}

enum GraphUserInfo {
    static func email(tokens: OAuthTokens) async throws -> String {
        guard let url = URL(string: "https://graph.microsoft.com/v1.0/me") else {
            throw MailMCPError.oauth("Bad Graph me URL")
        }
        let (data, response) = try await HTTPJSON.request(url: url, token: tokens.accessToken)
        if !(200..<300).contains(response.statusCode) {
            throw MailMCPError.oauth(String(data: data, encoding: .utf8) ?? "me failed")
        }
        let json = try OAuthClient.decodeJSON(data)
        if let mail = json["mail"] as? String, !mail.isEmpty { return mail }
        if let upn = json["userPrincipalName"] as? String { return upn }
        throw MailMCPError.oauth("Microsoft profile did not include email")
    }
}
