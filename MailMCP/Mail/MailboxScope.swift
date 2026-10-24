import Foundation

enum CanonicalMailbox: String, Sendable, CaseIterable {
    case inbox
    case spam
    case trash
    case all
    case everywhere
}

enum MailboxRequest: Equatable, Sendable {
    case canonical(CanonicalMailbox)
    case named(String)

    var token: String {
        switch self {
        case .canonical(let value): return value.rawValue
        case .named(let value): return value
        }
    }

    static func parse(_ raw: String?) -> [MailboxRequest] {
        let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return [.canonical(.everywhere)] }
        let parts = text
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.isEmpty { return [.canonical(.everywhere)] }
        return parts.map(parseOne)
    }

    static func parseOne(_ raw: String) -> MailboxRequest {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "inbox", "in":
            return .canonical(.inbox)
        case "spam", "junk", "bulk", "junkemail", "junk e-mail", "junk email":
            return .canonical(.spam)
        case "trash", "deleted", "deleteditems", "deleted items", "deleted messages", "bin":
            return .canonical(.trash)
        case "all", "allmail", "all mail":
            return .canonical(.all)
        case "everywhere", "anywhere", "allfolders", "all folders":
            return .canonical(.everywhere)
        default:
            return .named(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

enum MailboxKind: String, Codable, Sendable {
    case inbox
    case spam
    case trash
    case all
    case drafts
    case sent
    case archive
    case other
}

struct FolderHint: Sendable, Hashable {
    var name: String
    var remoteID: String?
    var kind: MailboxKind?
    var flags: [String]

    init(name: String, remoteID: String? = nil, kind: MailboxKind? = nil, flags: [String] = []) {
        self.name = name
        self.remoteID = remoteID
        self.kind = kind ?? MailboxMatcher.kind(ofName: name, flags: flags)
        self.flags = flags
    }
}

struct ResolvedMailbox: Codable, Hashable, Sendable {
    var requested: String
    var kind: String
    var name: String
    var remoteID: String?
}

enum MailboxMatcher {
    static func kind(ofName name: String, flags: [String] = []) -> MailboxKind {
        let flagText = flags.joined(separator: " ").lowercased()
        if flagText.contains("\\junk") { return .spam }
        if flagText.contains("\\trash") { return .trash }
        if flagText.contains("\\all") { return .all }
        if flagText.contains("\\drafts") { return .drafts }
        if flagText.contains("\\sent") { return .sent }
        if flagText.contains("\\archive") { return .archive }
        if flagText.contains("\\inbox") { return .inbox }

        let lower = name.lowercased()
        let last = lower.split(whereSeparator: { $0 == "/" || $0 == "." }).last.map(String.init) ?? lower
        if lower == "inbox" || last == "inbox" { return .inbox }
        if matches(last, ["spam", "junk", "bulk", "junk e-mail", "junk email"]) { return .spam }
        if matches(last, ["trash", "deleted", "deleted items", "deleted messages", "bin"]) { return .trash }
        if lower.contains("all mail") || last == "all mail" { return .all }
        if matches(last, ["drafts", "draft"]) { return .drafts }
        if last.contains("sent") { return .sent }
        if last.contains("archive") { return .archive }
        return .other
    }

    static func resolve(_ requests: [MailboxRequest], folders: [FolderHint]) -> [ResolvedMailbox] {
        var expanded: [MailboxRequest] = []
        for request in requests {
            if case .canonical(.everywhere) = request {
                expanded.append(.canonical(.inbox))
                expanded.append(.canonical(.spam))
                expanded.append(.canonical(.trash))
                if folders.contains(where: { $0.kind == .all }) {
                    expanded.append(.canonical(.all))
                }
            } else {
                expanded.append(request)
            }
        }
        var seen = Set<String>()
        var result: [ResolvedMailbox] = []
        for request in expanded {
            let matches = match(folders, request: request)
            if matches.isEmpty {
                result.append(
                    ResolvedMailbox(requested: request.token, kind: kindToken(request), name: "", remoteID: nil)
                )
                continue
            }
            for item in matches {
                let key = item.name.lowercased()
                if seen.insert(key).inserted {
                    result.append(item)
                }
            }
        }
        return result
    }

    static func match(_ folders: [FolderHint], request: MailboxRequest) -> [ResolvedMailbox] {
        switch request {
        case .canonical(.everywhere):
            return []
        case .canonical(let canonical):
            let wanted = kind(for: canonical)
            if let flagged = folders.first(where: { $0.kind == wanted }) {
                return [ResolvedMailbox(requested: canonical.rawValue, kind: wanted.rawValue, name: flagged.name, remoteID: flagged.remoteID)]
            }
            if canonical == .inbox {
                return [ResolvedMailbox(requested: "inbox", kind: MailboxKind.inbox.rawValue, name: "INBOX", remoteID: folders.first { $0.kind == .inbox }?.remoteID)]
            }
            return []
        case .named(let name):
            let lowered = name.lowercased()
            if let exact = folders.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return [ResolvedMailbox(requested: name, kind: exact.kind?.rawValue ?? MailboxKind.other.rawValue, name: exact.name, remoteID: exact.remoteID)]
            }
            if let remote = folders.first(where: { $0.remoteID?.caseInsensitiveCompare(name) == .orderedSame }) {
                return [ResolvedMailbox(requested: name, kind: remote.kind?.rawValue ?? MailboxKind.other.rawValue, name: remote.name, remoteID: remote.remoteID)]
            }
            if let partial = folders.first(where: { $0.name.lowercased().contains(lowered) }) {
                return [ResolvedMailbox(requested: name, kind: partial.kind?.rawValue ?? MailboxKind.other.rawValue, name: partial.name, remoteID: partial.remoteID)]
            }
            return [ResolvedMailbox(requested: name, kind: MailboxKind.other.rawValue, name: name, remoteID: nil)]
        }
    }

    private static func kind(for canonical: CanonicalMailbox) -> MailboxKind {
        switch canonical {
        case .inbox: return .inbox
        case .spam: return .spam
        case .trash: return .trash
        case .all: return .all
        case .everywhere: return .other
        }
    }

    private static func kindToken(_ request: MailboxRequest) -> String {
        switch request {
        case .canonical(let value): return value == .everywhere ? MailboxKind.other.rawValue : kind(for: value).rawValue
        case .named: return MailboxKind.other.rawValue
        }
    }

    private static func matches(_ value: String, _ names: [String]) -> Bool {
        names.contains { value == $0 || value.contains($0) }
    }
}
