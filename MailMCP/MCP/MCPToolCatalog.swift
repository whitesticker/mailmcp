import Foundation

enum MCPToolAudience: String, Sendable {
    case readOnly
    case mailboxAdd
    case mailboxAlter
    case reachesOthers
}

struct MCPToolInfo: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var title: String
    var intro: String
    var audience: MCPToolAudience
}

enum MCPToolCatalog {
    static let all: [MCPToolInfo] = [
        MCPToolInfo(name: "list_accounts", title: "List accounts", intro: "Shows which mailboxes are in the unlocked vault.", audience: .readOnly),
        MCPToolInfo(name: "search_messages", title: "Search messages", intro: "Finds messages by text or from:/to:/subject:.", audience: .readOnly),
        MCPToolInfo(name: "get_message", title: "Get message", intro: "Reads one message body, headers, and attachment names.", audience: .readOnly),
        MCPToolInfo(name: "get_thread", title: "Get thread", intro: "Reads a conversation in date order.", audience: .readOnly),
        MCPToolInfo(name: "list_threads", title: "List threads", intro: "Groups matching messages into conversations.", audience: .readOnly),
        MCPToolInfo(name: "list_folders", title: "List folders", intro: "Counts messages and unread mail in each folder.", audience: .readOnly),
        MCPToolInfo(name: "inbox_digest", title: "Inbox digest", intro: "Unread, aging threads, top senders, and snoozed mail.", audience: .readOnly),
        MCPToolInfo(name: "list_contacts", title: "List contacts", intro: "People you write to most, from Sent mail.", audience: .readOnly),
        MCPToolInfo(name: "suggest_recipients", title: "Suggest recipients", intro: "Autocomplete addresses from recent Sent mail.", audience: .readOnly),
        MCPToolInfo(name: "list_drafts", title: "List drafts", intro: "Shows drafts waiting in the mailbox.", audience: .readOnly),
        MCPToolInfo(name: "get_attachment", title: "Get attachment", intro: "Downloads one attachment as base64.", audience: .readOnly),
        MCPToolInfo(name: "list_pending_sends", title: "List pending sends", intro: "Outbound mail waiting for your confirmation.", audience: .readOnly),

        MCPToolInfo(name: "create_draft", title: "Create draft", intro: "Writes a draft. Does not send.", audience: .mailboxAdd),
        MCPToolInfo(name: "snooze_message", title: "Snooze message", intro: "Hides a message from the digest until a time you choose. Local to MailMCP.", audience: .mailboxAdd),

        MCPToolInfo(name: "modify_message", title: "Modify message", intro: "Archive, trash, read/unread, or change labels. Only your mailbox.", audience: .mailboxAlter),
        MCPToolInfo(name: "file_message", title: "File message", intro: "Moves a message into a folder or applies labels. Nobody else is notified.", audience: .mailboxAlter),
        MCPToolInfo(name: "update_draft", title: "Update draft", intro: "Edits an existing draft. Does not send.", audience: .mailboxAlter),
        MCPToolInfo(name: "delete_draft", title: "Delete draft", intro: "Deletes a draft from your mailbox.", audience: .mailboxAlter),

        MCPToolInfo(name: "send_message", title: "Send message", intro: "Sends new mail to other people.", audience: .reachesOthers),
        MCPToolInfo(name: "reply_message", title: "Reply", intro: "Replies to a message. The other person will see it.", audience: .reachesOthers),
        MCPToolInfo(name: "forward_message", title: "Forward", intro: "Forwards a message to someone else.", audience: .reachesOthers),
        MCPToolInfo(name: "confirm_send", title: "Confirm send", intro: "Releases a queued send after you approve it.", audience: .reachesOthers)
    ]

    static var readOnly: [MCPToolInfo] { all.filter { $0.audience == .readOnly } }
    static var mailboxAdd: [MCPToolInfo] { all.filter { $0.audience == .mailboxAdd } }
    static var mailboxAlter: [MCPToolInfo] { all.filter { $0.audience == .mailboxAlter } }
    static var mailboxOnly: [MCPToolInfo] { mailboxAdd + mailboxAlter }
    static var reachesOthers: [MCPToolInfo] { all.filter { $0.audience == .reachesOthers } }

    static var groups: [(title: String, intro: String, tools: [MCPToolInfo])] {
        [
            ("Read only", "These tools inspect mail. They do not archive, draft, or send.", readOnly),
            ("Add to your mailbox", "Creates drafts or snoozes. Nobody else is notified.", mailboxAdd),
            ("Delete or alter your mailbox", "Archive, move, edit, or delete. Nobody else is notified.", mailboxAlter),
            ("Reaches other people", "Send, reply, and forward. Confirm-before-send still applies.", reachesOthers)
        ]
    }
}

enum ToolGateStore {
    static var url: URL {
        Paths.applicationSupport.appendingPathComponent("disabled-tools.json")
    }

    static func loadDisabled() -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let names = try? JSONCoders.decoder.decode([String].self, from: data) else {
            return []
        }
        return Set(names)
    }

    static func save(_ names: [String]) {
        try? FileManager.default.createDirectory(at: Paths.applicationSupport, withIntermediateDirectories: true)
        try? JSONCoders.encoder.encode(names).write(to: url, options: .atomic)
    }

    static func isEnabled(_ name: String) -> Bool {
        !loadDisabled().contains(name)
    }
}
