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

    static func splitMessage(_ raw: String) -> (headers: [String: String], body: String) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if let range = normalized.range(of: "\n\n") {
            return (parseHeaders(String(normalized[..<range.lowerBound])), String(normalized[range.upperBound...]))
        }
        return (parseHeaders(normalized), "")
    }

    static func addresses(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// Parses MIME bodies on a Latin-1 "wire" string (one character per byte) so transfer encodings and charsets decode losslessly.
enum MIMEParser {
    typealias Parsed = (text: String, html: String?, attachments: [MailAttachmentMeta])

    private struct Collector {
        var text = ""
        var html: String?
        var attachments: [MailAttachmentMeta] = []
    }

    static func parse(raw: Data) -> Parsed {
        let wire = normalizeLineEndings(wireString(raw))
        let split = splitHeadersAndBody(wire, trimLeading: false)
        return parse(headers: split.headers, wireBody: split.body)
    }

    static func plainText(from headers: [String: String], body: String) -> Parsed {
        parse(headers: headers, wireBody: normalizeLineEndings(wireString(Data(body.utf8))))
    }

    private static func parse(headers: [String: String], wireBody: String) -> Parsed {
        var collector = Collector()
        walk(headers: headers, body: wireBody, section: [], into: &collector)
        var text = collector.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, let html = collector.html {
            text = stripHTML(html)
        }
        return (text, collector.html, collector.attachments)
    }

    private static func walk(headers: [String: String], body: String, section: [Int], into collector: inout Collector) {
        var contentType = headers["content-type"] ?? ""
        let declared = mediaType(contentType)
        if declared.isEmpty || declared == "text/plain", let inferred = inferredMultipartType(from: body) {
            contentType = inferred
        }
        let type = mediaType(contentType).isEmpty ? "text/plain" : mediaType(contentType)

        if type.hasPrefix("multipart/"), let boundary = boundary(from: contentType) {
            for (offset, part) in multipartBodies(body, boundary: boundary).enumerated() {
                let split = splitHeadersAndBody(part, trimLeading: true)
                walk(headers: split.headers, body: split.body, section: section + [offset + 1], into: &collector)
            }
            return
        }

        let disposition = headers["content-disposition"] ?? ""
        let filename = parameter("filename", in: disposition) ?? parameter("name", in: contentType)
        let encoding = headers["content-transfer-encoding"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let isText = type == "text/plain" || type == "text/html"
        if !isText || filename != nil || disposition.lowercased().hasPrefix("attachment") {
            let sectionID = section.isEmpty ? "1" : section.map(String.init).joined(separator: ".")
            let encodedSize = body.utf8.count
            collector.attachments.append(
                MailAttachmentMeta(
                    id: "imap:\(sectionID)",
                    filename: filename.map(decodeEncodedWords) ?? "attachment-\(sectionID)",
                    mimeType: type,
                    size: encoding == "base64" ? encodedSize * 3 / 4 : encodedSize
                )
            )
            return
        }

        let decoded = decodeText(transferDecoded(body, encoding: encoding), charset: parameter("charset", in: contentType))
        if type == "text/html" {
            if collector.html == nil { collector.html = decoded }
        } else if collector.text.isEmpty {
            collector.text = decoded
        }
    }

    private static func wireString(_ data: Data) -> String {
        String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    private static func wireBytes(_ wire: String) -> Data {
        Data(wire.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
    }

    private static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func mediaType(_ contentType: String) -> String {
        contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    private static func transferDecoded(_ wire: String, encoding: String) -> Data {
        switch encoding {
        case "quoted-printable":
            return quotedPrintableDecoded(wireBytes(wire))
        case "base64":
            var compact = wire.filter { !$0.isWhitespace }
            if compact.count % 4 != 0 {
                compact += String(repeating: "=", count: 4 - compact.count % 4)
            }
            return Data(base64Encoded: compact, options: .ignoreUnknownCharacters) ?? wireBytes(wire)
        default:
            return wireBytes(wire)
        }
    }

    static func quotedPrintableDecoded(_ bytes: Data) -> Data {
        let input = [UInt8](bytes)
        var output = Data(capacity: input.count)
        var index = 0
        func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        while index < input.count {
            let byte = input[index]
            guard byte == UInt8(ascii: "=") else {
                output.append(byte)
                index += 1
                continue
            }
            var lookahead = index + 1
            while lookahead < input.count, input[lookahead] == UInt8(ascii: " ") || input[lookahead] == UInt8(ascii: "\t") {
                lookahead += 1
            }
            if lookahead < input.count, input[lookahead] == UInt8(ascii: "\n") {
                index = lookahead + 1
            } else if lookahead >= input.count {
                index = lookahead
            } else if index + 2 < input.count, let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2]) {
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(byte)
                index += 1
            }
        }
        return output
    }

    private static func decodeText(_ data: Data, charset: String?) -> String {
        if let charset, let encoding = stringEncoding(charset), let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    private static func stringEncoding(_ charset: String) -> String.Encoding? {
        let name = charset.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")).lowercased()
        guard !name.isEmpty else { return nil }
        if name == "utf-8" || name == "utf8" || name == "us-ascii" { return .utf8 }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    /// Decodes RFC 2047 words such as `=?UTF-8?B?...?=` in filenames.
    private static func decodeEncodedWords(_ wireValue: String) -> String {
        let value = decodeText(wireBytes(wireValue), charset: nil)
            .replacingOccurrences(of: #"\?=\s+=\?"#, with: "?==?", options: .regularExpression)
        guard value.contains("=?"),
              let regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#) else { return value }
        var result = ""
        var cursor = value.startIndex
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let whole = Range(match.range, in: value),
                  let charsetRange = Range(match.range(at: 1), in: value),
                  let modeRange = Range(match.range(at: 2), in: value),
                  let textRange = Range(match.range(at: 3), in: value) else { continue }
            let payload = String(value[textRange])
            let bytes: Data
            if value[modeRange].lowercased() == "b" {
                bytes = transferDecoded(payload, encoding: "base64")
            } else {
                bytes = quotedPrintableDecoded(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
            }
            result += value[cursor..<whole.lowerBound]
            result += decodeText(bytes, charset: String(value[charsetRange]))
            cursor = whole.upperBound
        }
        result += value[cursor...]
        return result
    }

    private static func parameter(_ name: String, in header: String) -> String? {
        for piece in header.split(separator: ";").dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            if key == name || key == name + "*" {
                let value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func multipartBodies(_ body: String, boundary: String) -> [String] {
        let delimiter = "--" + boundary
        var parts: [String] = []
        var current: [Substring] = []
        var inside = false
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == delimiter + "--" {
                if inside { parts.append(current.joined(separator: "\n")) }
                return parts
            }
            if trimmed == delimiter {
                if inside { parts.append(current.joined(separator: "\n")) }
                current = []
                inside = true
                continue
            }
            if inside { current.append(line) }
        }
        if inside, !current.isEmpty { parts.append(current.joined(separator: "\n")) }
        return parts
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

    private static func splitHeadersAndBody(_ part: String, trimLeading: Bool) -> (headers: [String: String], body: String) {
        let normalized = trimLeading ? String(part.drop { $0 == "\n" }) : part
        if normalized.hasPrefix("\n") {
            return ([:], String(normalized.dropFirst()))
        }
        if let range = normalized.range(of: "\n\n") {
            let headerText = String(normalized[..<range.lowerBound])
            let body = String(normalized[range.upperBound...])
            return (RFC822.parseHeaders(headerText), body)
        }
        if normalized.range(of: #"^[A-Za-z-]+:"#, options: .regularExpression) != nil {
            return (RFC822.parseHeaders(normalized), "")
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
