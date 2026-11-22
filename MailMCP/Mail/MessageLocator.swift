import Foundation

/// Location-aware message reference so IMAP UIDs can be opened outside Inbox.
enum MessageLocator: Hashable, Sendable {
    case imap(folder: String, uid: String)
    case draft(uid: String)
    case provider(id: String)

    private static let imapPrefix = "imap|"

    var wire: String {
        switch self {
        case .imap(let folder, let uid):
            return Self.imapPrefix + Self.encodeFolder(folder) + "|" + uid
        case .draft(let uid):
            return "draft:" + uid
        case .provider(let id):
            return id
        }
    }

    var nativeID: String {
        switch self {
        case .imap(_, let uid):
            return uid
        case .draft(let uid):
            return uid
        case .provider(let id):
            return id
        }
    }

    /// What the cache may match besides the full reference. IMAP and draft UIDs are unique only within one folder,
    /// so falling back to them would pick up a different message that happens to share the number.
    var cacheFallbackID: String? {
        if case .provider(let id) = self { return id }
        return nil
    }

    var imapFolder: String? {
        if case .imap(let folder, _) = self { return folder }
        if case .draft = self { return "Drafts" }
        return nil
    }

    var isIMAP: Bool {
        if case .imap = self { return true }
        return false
    }

    static func parse(_ raw: String) -> MessageLocator {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("draft:") {
            return .draft(uid: String(trimmed.dropFirst(6)))
        }
        if trimmed.hasPrefix(imapPrefix) {
            let rest = String(trimmed.dropFirst(imapPrefix.count))
            if let sep = rest.lastIndex(of: "|") {
                let folder = decodeFolder(String(rest[..<sep]))
                let uid = String(rest[rest.index(after: sep)...])
                if !folder.isEmpty, !uid.isEmpty {
                    return .imap(folder: folder, uid: uid)
                }
            }
        }
        return .provider(id: trimmed)
    }

    static func encodeFolder(_ folder: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._@")
        return folder.addingPercentEncoding(withAllowedCharacters: allowed) ?? folder
    }

    static func decodeFolder(_ raw: String) -> String {
        raw.removingPercentEncoding ?? raw
    }
}
