import Foundation

enum RFC822 {
    static func parseHeaders(_ raw: String) -> [String: String] {
        var unfolded: [String] = []
        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first?.isWhitespace == true, let last = unfolded.popLast() {
                unfolded.append(last + " " + line.trimmingCharacters(in: .whitespaces))
            } else {
                unfolded.append(String(line))
            }
        }
        var headers: [String: String] = [:]
        for line in unfolded {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            if let existing = headers[name], !existing.isEmpty {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        return headers
    }

    static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    static func makeMessage(
        from: String,
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String,
        body: String,
        extraHeaders: [String: String] = [:]
    ) -> String {
        var lines = [
            "From: \(from)",
            "To: \(to.joined(separator: ", "))"
        ]
        if !cc.isEmpty { lines.append("Cc: \(cc.joined(separator: ", "))") }
        if !bcc.isEmpty { lines.append("Bcc: \(bcc.joined(separator: ", "))") }
        for (key, value) in extraHeaders where !value.isEmpty {
            lines.append("\(key): \(value)")
        }
        lines.append("Subject: \(subject)")
        lines.append("Date: \(rfc2822Now())")
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=utf-8")
        lines.append("Content-Transfer-Encoding: 8bit")
        lines.append("")
        lines.append(body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n"))
        if !body.hasSuffix("\n") {
            lines.append("")
        }
        return lines.joined(separator: "\r\n")
    }

    static func rfc2822Now() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: Date())
    }

    static func addresses(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

enum MIMEParser {
    static func plainText(from headers: [String: String], body: String) -> (text: String, html: String?, attachments: [MailAttachmentMeta]) {
        var headers = headers
        let contentType = headers["content-type"]?.lowercased() ?? ""
        if contentType.contains("multipart/") {
            return parseMultipart(headers: headers, body: body)
        }
        if (contentType.isEmpty || contentType == "text/plain"),
           let inferred = inferredMultipartType(from: body) {
            headers["content-type"] = inferred
            return parseMultipart(headers: headers, body: body)
        }
        if contentType.contains("text/html") {
            return (stripHTML(body), body, [])
        }
        return (body, nil, [])
    }

    private static func inferredMultipartType(from body: String) -> String? {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("--") else { return nil }
        guard trimmed.range(of: "Content-Type:", options: .caseInsensitive) != nil else { return nil }
        let first = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let token = first.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.hasPrefix("--") else { return nil }
        return "multipart/mixed; boundary=\(token)"
    }

    private static func parseMultipart(headers: [String: String], body: String) -> (String, String?, [MailAttachmentMeta]) {
        guard let boundary = boundary(from: headers["content-type"] ?? "") else {
            return (body, nil, [])
        }
        let normalizedBody = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let parts = normalizedBody.components(separatedBy: "--" + boundary)
        var text = ""
        var html: String?
        var attachments: [MailAttachmentMeta] = []
        var index = 0
        for part in parts {
            if part.isEmpty || part.hasPrefix("--") { continue }
            index += 1
            let split = splitHeadersAndBody(part)
            let ctype = split.headers["content-type"]?.lowercased() ?? ""
            let disposition = split.headers["content-disposition"] ?? ""
            let filename = filename(from: disposition) ?? filename(from: split.headers["content-type"] ?? "")
            if filename != nil || disposition.lowercased().contains("attachment") {
                attachments.append(
                    MailAttachmentMeta(
                        id: "imap:\(index)",
                        filename: filename ?? "attachment-\(index)",
                        mimeType: ctype.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "application/octet-stream",
                        size: split.body.utf8.count
                    )
                )
                continue
            }
            if ctype.contains("text/plain") && text.isEmpty {
                text = split.body.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if ctype.contains("text/html") && html == nil {
                html = split.body
            }
        }
        if text.isEmpty, let html {
            text = stripHTML(html)
        }
        return (text, html, attachments)
    }

    private static func splitHeadersAndBody(_ part: String) -> (headers: [String: String], body: String) {
        let normalized = part.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        if let range = normalized.range(of: "\n\n") {
            let headerText = String(normalized[..<range.lowerBound])
            let body = String(normalized[range.upperBound...])
            return (RFC822.parseHeaders(headerText), body)
        }
        return ([:], normalized)
    }

    private static func boundary(from contentType: String) -> String? {
        let pattern = "boundary="
        guard let range = contentType.range(of: pattern, options: .caseInsensitive) else { return nil }
        var value = String(contentType[range.upperBound...])
        if let semi = value.firstIndex(of: ";") {
            value = String(value[..<semi])
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
    }

    private static func filename(from value: String) -> String? {
        guard let range = value.range(of: "filename=", options: .caseInsensitive) else { return nil }
        var name = String(value[range.upperBound...])
        if let semi = name.firstIndex(of: ";") {
            name = String(name[..<semi])
        }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
    }

    static func stripHTML(_ html: String) -> String {
        var result = html
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
