import Foundation

/// Plain text and list previews derived from message bodies. Every provider, the cache, the reader list and
/// MCP results go through here, so a fix applies to what the user sees and what agents read alike.
enum MailText {
    static let previewLength = 200

    /// Readable text from an HTML body: drops head, style, script and comments (including Outlook
    /// conditional blocks), keeps block breaks as newlines, decodes entities and removes invisible padding.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        text = replace(comment, in: text, with: " ")
        text = replace(hiddenBlock, in: text, with: " ")
        text = replace(lineBreakTag, in: text, with: "\n")
        text = replace(cellTag, in: text, with: " ")
        text = replace(anyTag, in: text, with: "")
        return tidy(decodeEntities(text))
    }

    /// A short, single-line preview: skips links, image placeholders and "view in browser" style boilerplate.
    /// Falls back to the HTML when the plain text is empty or is markup that leaked through.
    static func preview(body: String, html: String?, subject: String = "") -> String {
        if let html, !html.isEmpty {
            // A preheader that only repeats the subject would leave the list row empty.
            if let preheader = preheader(fromHTML: html),
               preheader.compare(subject.trimmingCharacters(in: .whitespaces), options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
                return preheader
            }
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || looksLikeMarkup(body) {
                return previewLine(from: plainText(fromHTML: html))
            }
        }
        let head = String(body.prefix(previewSourceLength))
        // Some senders put escaped HTML (`&lt;strong&gt;`) in the plain-text part.
        let decoded = decodeEntities(head)
        return previewLine(from: head.contains("&lt;") ? replace(anyTag, in: decoded, with: " ") : decoded)
    }

    /// The hidden "preview text" marketing mail puts at the top of the body for inbox lists, if there is one.
    /// Only a hidden element near the start counts, so mobile-only menus further down aren't mistaken for it.
    static func preheader(fromHTML html: String) -> String? {
        var text = replace(comment, in: html, with: " ")
        text = replace(hiddenBlock, in: text, with: " ")
        if let body = text.range(of: "<body", options: .caseInsensitive) {
            text = String(text[body.lowerBound...])
        }
        let ns = text as NSString
        for match in hiddenElement.matches(in: text, range: NSRange(location: 0, length: min(ns.length, 60_000))) {
            let before = plainText(fromHTML: ns.substring(to: match.range.location))
            guard before.count < 40 else { return nil }
            let hidden = plainText(fromHTML: ns.substring(with: match.range(at: 2)))
            // Longer hidden blocks are alternate layouts (mobile/desktop), not preview text.
            guard hidden.count <= 300 else { continue }
            let candidate = previewLine(from: hidden)
            if candidate.filter(\.isLetter).count >= 8, !looksLikeMenu(candidate) { return candidate }
        }
        return nil
    }

    /// "Gifts Women MEN GIRLS BOYS": five or more capitalized words and no punctuation.
    private static func looksLikeMenu(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        return words.count >= 5
            && words.allSatisfy { $0.first?.isUppercase == true || $0.first?.isNumber == true }
            && !text.contains(where: { ".,!?:;".contains($0) })
    }

    /// Cleans a stored or provider-supplied snippet for display.
    static func cleanSnippet(_ snippet: String) -> String {
        previewLine(from: decodeEntities(snippet))
    }

    /// True when text starts with CSS or tag soup, e.g. a body converted by an older HTML stripper.
    static func looksLikeMarkup(_ text: String) -> Bool {
        let head = String(text.prefix(2_000))
        return cssBrace(in: head) != nil || head.contains("<!--") || head.hasPrefix("-->") || firstMatch(cssAtRule, in: head) != nil
    }

    // MARK: - Preview

    /// Only the start of a long body can end up in a preview.
    private static let previewSourceLength = 20_000

    private static func previewLine(from text: String) -> String {
        var parts: [String] = []
        var length = 0
        for rawLine in removeInvisible(String(text.prefix(previewSourceLength))).components(separatedBy: .newlines) {
            var line = replace(markdownLink, in: rawLine, with: "$1")
            line = replace(bracketedLink, in: line, with: " ")
            line = replace(imagePlaceholder, in: line, with: " ")
            line = replace(bareLink, in: line, with: " ")
            line = replace(tagFragment, in: line, with: " ")
            line = replace(trackingToken, in: line, with: " ")
            line = replace(emptyBrackets, in: line, with: " ")
            line = collapseSpaces(line).trimmingCharacters(in: CharacterSet(charactersIn: " |·•-–—:"))
            guard line.contains(where: { $0.isLetter || $0.isNumber }),
                  firstMatch(boilerplate, in: line) == nil,
                  firstMatch(cssAtRule, in: line)?.lowerBound != line.startIndex else { continue }
            if let brace = cssBrace(in: line) {
                // CSS can follow real text on the same line ("…Alex? @media only screen{…"); keep the whole sentences before it.
                let lead = String(line[..<brace])
                line = firstMatch(sentenceEnd, in: lead).map { String(lead[$0]) }?.trimmingCharacters(in: .whitespaces) ?? ""
                guard line.contains(where: { $0.isLetter }) else { continue }
                parts.append(line)
                break
            }
            parts.append(line)
            length += line.count + 1
            if length >= previewLength { break }
        }
        let joined = parts.joined(separator: " ")
        return joined.count > previewLength ? String(joined.prefix(previewLength)) : joined
    }

    // MARK: - Text helpers

    private static func tidy(_ text: String) -> String {
        var lines: [String] = []
        var blank = false
        for line in removeInvisible(text).components(separatedBy: .newlines) {
            let collapsed = collapseSpaces(line).trimmingCharacters(in: .whitespaces)
            if collapsed.isEmpty {
                if !lines.isEmpty { blank = true }
                continue
            }
            if blank { lines.append("") }
            blank = false
            lines.append(collapsed)
        }
        return lines.joined(separator: "\n")
    }

    private static func collapseSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \\t\\f\\v]+", with: " ", options: .regularExpression)
    }

    /// Zero-width and combining characters senders use to pad preheaders; non-breaking spaces become spaces.
    private static func removeInvisible(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x00A0, 0x2007, 0x202F:
                scalars.append(" ")
            case 0x00AD, 0x034F, 0x200B...0x200F, 0x2060...0x2064, 0xFEFF:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static let namedEntities: [String: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·",
        "zwnj": "", "zwj": "", "shy": "", "ensp": " ", "emsp": " ", "thinsp": " ", "euro": "€", "pound": "£"
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in entity.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let name = ns.substring(with: match.range(at: 1))
            if let decoded = decodeEntity(name) {
                result += decoded
            } else {
                result += ns.substring(with: match.range)
            }
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func decodeEntity(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits, radix: 10)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return namedEntities[name.lowercased()]
    }

    /// The first `{` that opens a CSS declaration block (`{ color: red` or `@media … { .x { display: none`).
    /// Checking only at braces keeps this linear on long text.
    private static func cssBrace(in text: String) -> String.Index? {
        var index = text.startIndex
        while let brace = text[index...].firstIndex(of: "{") {
            let after = text.index(after: brace)
            let window = String(text[after..<(text.index(after, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex)])
            if firstMatch(cssDeclaration, in: window) != nil { return brace }
            index = after
        }
        return nil
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> Range<String.Index>? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { Range($0.range, in: text) }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let comment = regex("<!--[\\s\\S]*?-->|<!\\[endif\\]>|<!\\[if[^>]*>")
    private static let hiddenBlock = regex("<(head|style|script|title|xml|noscript)\\b[\\s\\S]*?</\\1\\s*>")
    private static let lineBreakTag = regex("<br\\s*/?>|</?(p|div|tr|li|ul|ol|h[1-6]|table|blockquote|section|article|header|footer|center)\\b[^>]*>")
    private static let cellTag = regex("</?(td|th)\\b[^>]*>")
    private static let anyTag = regex("<[^>]+>")
    private static let entity = regex("&(#[0-9]{1,7}|#x[0-9a-f]{1,6}|[a-z]{2,8});")
    private static let hiddenElement = regex(
        "<(div|span|p|td|table)\\b[^>]*(?:display\\s*:\\s*none|max-height\\s*:\\s*0|mso-hide\\s*:\\s*all|class\\s*=\\s*[\"'][^\"']*(?:preheader|preview-?text))[^>]*>([\\s\\S]*?)</\\1\\s*>"
    )
    /// Raw or cut-off tags left in plain-text parts, e.g. `<a href= alias="instagram"`.
    private static let tagFragment = regex("</?[a-z][a-z0-9]*\\s+[a-z-]+\\s*=[^<>]*(>|$)|</?(a|b|i|u|p|br|div|span|strong|em|table|tbody|thead|td|th|tr|img|font|center)\\s*/?>")
    private static let markdownLink = regex("\\[([^\\]]{1,80})\\]\\(\\s*(https?:|mailto:)[^)]*\\)")
    private static let bracketedLink = regex("[<(\\[]\\s*(https?://|mailto:)[^>)\\]]*[>)\\]]")
    private static let bareLink = regex("(https?://|www\\.)\\S+")
    private static let imagePlaceholder = regex("\\[(image|cid|img)[^\\]]*\\]")
    private static let emptyBrackets = regex("[(\\[<{][^\\p{L}\\p{N}()\\[\\]<>{}]{0,4}[)\\]>}]|[(\\[<]\\s*$|^\\s*[)\\]>]")
    /// Image alt names glued with zeros, e.g. `banner1spring0sale` or `nav0women`.
    private static let trackingToken = try! NSRegularExpression(pattern: "\\b(?=[a-z0-9]{8,}\\b)[a-z0-9]*[a-z]0[a-z][a-z0-9]*\\b")
    /// Optional nested selector, then `property:` (`{ color:` or `{ .x { display:`).
    private static let cssDeclaration = regex("^\\s*([^{}]{0,100}\\{)?\\s*[a-z-]+\\s*:[^;{}]{0,200}[;}]")
    private static let cssAtRule = regex("@(media|font-face|import|charset|supports|keyframes)\\b")
    private static let sentenceEnd = regex(".*[.!?…](\\s|$)")
    private static let boilerplate = regex("^(view|read|open|see)\\b.{0,40}\\b(web ?page|browser|online)\\b|^having trouble (viewing|reading)|email (isn.t|not) displaying|^(click|tap) here to view|^unsubscribe\\b|^manage (your )?(preferences|subscriptions?)")
}

/// Where a reply's quoted history begins, so a conversation can show only what each message adds (as Apple Mail
/// does). Nothing is hidden unless the part above the quote has text of its own.
enum MailQuote {
    /// The new part of an HTML body, or nil when no quoted history was recognized.
    static func reply(inHTML html: String) -> String? {
        guard let start = htmlQuoteStart(html) else { return nil }
        let reply = String(html[..<start])
        return MailText.plainText(fromHTML: reply).isEmpty ? nil : reply
    }

    /// The new part of a plain-text body, or nil when no quoted history was recognized.
    static func reply(inPlainText text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let start = plainQuoteStart(lines) else { return nil }
        let reply = lines[..<start].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return reply.isEmpty ? nil : reply
    }

    private static func htmlQuoteStart(_ html: String) -> String.Index? {
        let range = NSRange(html.startIndex..., in: html)
        var starts = containerMarkers.compactMap { marker in
            marker.matches(in: html, range: range).lazy
                .compactMap { Range($0.range, in: html)?.lowerBound }
                .first { !introducesForward(html[$0...]) }
        }
        if let header = headerStart(html) { starts.append(header) }
        return starts.min()
    }

    /// Gmail and Outlook wrap forwarded mail in the same containers as quotes; a forward is the content, so it stays.
    private static func introducesForward(_ html: Substring) -> Bool {
        let text = MailText.plainText(fromHTML: String(html.prefix(1500)))
        return text.prefix(600).range(of: #"forwarded message|\bSubject\s*:\s*(FW|Fwd)\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// An Outlook-style "From: … Sent:/Date: … Subject:" block, backed up to the divider or block that opens it.
    private static func headerStart(_ html: String) -> String.Index? {
        let range = NSRange(html.startIndex..., in: html)
        for match in headerFrom.matches(in: html, range: range) {
            guard let from = Range(match.range, in: html) else { continue }
            let window = html[from.lowerBound...].prefix(1500)
            let text = MailText.plainText(fromHTML: String(window))
            guard text.range(of: #"\b(Sent|Date)\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  text.range(of: #"\bSubject\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            let before = html[html.index(from.lowerBound, offsetBy: -min(400, html.distance(from: html.startIndex, to: from.lowerBound)))..<from.lowerBound]
            // A forward's header introduces the content being shared, not history.
            if before.range(of: "forwarded message", options: .caseInsensitive) != nil || introducesForward(html[from.lowerBound...]) {
                continue
            }
            if let rule = before.range(of: "<hr", options: [.caseInsensitive, .backwards]),
               MailText.plainText(fromHTML: String(html[rule.lowerBound..<from.lowerBound])).isEmpty {
                return rule.lowerBound
            }
            let openers = ["<div", "<p"].compactMap { before.range(of: $0, options: [.caseInsensitive, .backwards])?.lowerBound }
            return openers.max() ?? from.lowerBound
        }
        return nil
    }

    private static func plainQuoteStart(_ lines: [String]) -> Int? {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in trimmed.enumerated() {
            if line.range(of: #"^-{2,}\s*Original Message\s*-{2,}"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return index
            }
            if line.hasPrefix("On "), line.hasSuffix("wrote:") || (index + 1 < trimmed.count && trimmed[index + 1].hasSuffix("wrote:")) {
                return index
            }
            if line.range(of: #"^From\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil,
               !trimmed[max(0, index - 3)..<index].contains(where: { $0.localizedCaseInsensitiveContains("forwarded message") }) {
                let next = trimmed[(index + 1)..<min(index + 5, trimmed.count)]
                if next.contains(where: { $0.range(of: #"^(Sent|Date)\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil }) {
                    return index > 0 && trimmed[index - 1].range(of: #"^_{8,}$"#, options: .regularExpression) != nil ? index - 1 : index
                }
            }
            // A trailing run of "> " lines; quotes interleaved with answers stay visible.
            if line.hasPrefix(">"), trimmed[index...].allSatisfy({ $0.isEmpty || $0.hasPrefix(">") }) {
                return index
            }
        }
        return nil
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let containerMarkers = [
        // Gmail, including its "On … wrote:" line.
        regex(#"<div[^>]*class\s*=\s*["'][^"']*\bgmail_quote\b"#),
        // Outlook on the web and Outlook for Mac.
        regex(#"<div[^>]*id\s*=\s*["']?appendonsend\b"#),
        regex(#"<hr[^>]*>\s*(<[^>]+>\s*){0,3}<div[^>]*id\s*=\s*["']?divRplyFwdMsg\b"#),
        regex(#"<div[^>]*id\s*=\s*["']?divRplyFwdMsg\b"#),
        // Apple Mail, Thunderbird, Yahoo, Proton, Zoho.
        regex(#"<blockquote[^>]*type\s*=\s*["']?cite\b"#),
        regex(#"<div[^>]*class\s*=\s*["'][^"']*\b(moz-cite-prefix|yahoo_quoted|protonmail_quote|zmail_extra)\b"#),
        regex(#"-{2,}\s*Original Message\s*-{2,}"#),
    ]
    private static let headerFrom = regex(#"(<b>|<strong>|<span[^>]*>|^|\n|<br\s*/?>)\s*From\s*:"#)
}
