import Foundation

enum MailMCPTools {
    static var definitions: [[String: Any]] {
        let disabled = ToolGateStore.loadDisabled()
        return catalog.filter { tool in
            guard let name = tool["name"] as? String else { return false }
            return !disabled.contains(name)
        }
    }

    private static let catalog: [[String: Any]] = [
        tool(
            "list_accounts",
            "List mailboxes in the active vault, or all unlocked vaults if that setting is on. Each row includes vault_id and vault_name.",
            [:]
        ),
        tool(
            "search_messages",
            "Search messages across selected accounts, including Spam/Junk and Trash/Deleted Items. mailbox=everywhere (default) searches inbox, spam, and trash with provider-specific names. Returns a structured result: status is no_matches, partial, incomplete, unsupported, error, or ok. Use the returned message_id to open mail found in Spam or Trash. Does not mark messages read.",
            [
                "account_id": stringProp("Account UUID or email. Repeat as comma-separated values, or omit to search every connected account."),
                "account_ids": arrayProp("Optional list of account UUIDs or emails. Combined with account_id."),
                "query": stringProp("Search text. IMAP/Gmail: from:, to:, subject:, after:YYYY-MM-DD, before:YYYY-MM-DD, in:spam / in:trash / in:everywhere."),
                "mailbox": stringProp("Canonical folder: everywhere (default), spam, trash, inbox, all, or a provider folder name. Comma-separated lists are allowed."),
                "after": stringProp("Optional inclusive start date (YYYY-MM-DD or ISO-8601)."),
                "before": stringProp("Optional exclusive end date (YYYY-MM-DD or ISO-8601)."),
                "limit": numberProp("Maximum messages to return (default 20)."),
                "cursor": stringProp("Pagination cursor from a previous nextCursor."),
                "timeout_seconds": numberProp("Deadline for the whole search (default 20). Partial results are returned on timeout.")
            ]
        ),
        tool(
            "get_message",
            "Fetch a single message body, headers, and attachment metadata. Pass message_id exactly as returned by search_messages so Spam/Trash IMAP mail can be opened. Does not mark the message read.",
            [
                "account_id": stringProp("Account UUID or email."),
                "message_id": stringProp("Location-aware id from search_messages, or a provider message id.")
            ],
            required: ["message_id"]
        ),
        tool(
            "list_threads",
            "List conversation threads matching an optional query.",
            [
                "account_id": stringProp("Account UUID or email."),
                "query": stringProp("Optional search query."),
                "limit": numberProp("Maximum threads (default 20).")
            ]
        ),
        tool(
            "modify_message",
            "Archive, trash, mark read/unread, or add/remove a label. Requires drafts/organize safety mode.",
            [
                "account_id": stringProp("Account UUID or email."),
                "message_id": stringProp("Location-aware id from search_messages, or a provider message id."),
                "action": enumProp("archive, trash, markRead, markUnread, addLabel, removeLabel"),
                "label": stringProp("Label/category for addLabel or removeLabel.")
            ],
            required: ["message_id", "action"]
        ),
        tool(
            "create_draft",
            "Create a draft. Requires drafts safety mode.",
            [
                "account_id": stringProp("Account UUID or email."),
                "to": arrayProp("Recipient email addresses."),
                "cc": arrayProp("CC addresses."),
                "bcc": arrayProp("BCC addresses."),
                "subject": stringProp("Subject."),
                "body": stringProp("Plain-text body.")
            ],
            required: ["to", "subject", "body"]
        ),
        tool(
            "send_message",
            "Send a message. Requires send safety mode. If confirm-before-send is on, this queues a pending send for confirmation in the MailMCP app.",
            [
                "account_id": stringProp("Account UUID or email."),
                "to": arrayProp("Recipient email addresses."),
                "cc": arrayProp("CC addresses."),
                "bcc": arrayProp("BCC addresses."),
                "subject": stringProp("Subject."),
                "body": stringProp("Plain-text body.")
            ],
            required: ["to", "subject", "body"]
        ),
        tool(
            "get_attachment",
            "Download one attachment as base64. Use ids from get_message. Pass the same location-aware message_id so Spam/Trash attachments resolve.",
            [
                "account_id": stringProp("Account UUID or email."),
                "message_id": stringProp("Location-aware id from search_messages or get_message."),
                "attachment_id": stringProp("Attachment id from get_message.")
            ],
            required: ["message_id", "attachment_id"]
        ),
        tool(
            "list_pending_sends",
            "List outbound messages waiting for in-app confirmation.",
            [:]
        ),
        tool(
            "list_folders",
            "List mailbox folders. Does not fetch message counts unless include_counts=true (slow on IMAP/Gmail). Use probe_accounts for a fast connection check and Spam/Trash names.",
            [
                "account_id": stringProp("Account UUID or email. Optional if only one account exists."),
                "include_counts": stringProp("true to include message and unread counts. Default false.")
            ]
        ),
        tool(
            "probe_accounts",
            "Fast connection diagnostics: ping each selected account and resolve inbox, spam, and trash names. Does not STATUS every folder.",
            [
                "account_id": stringProp("Optional account UUID or email. Omit to probe every connected account."),
                "account_ids": arrayProp("Optional list of account UUIDs or emails."),
                "timeout_seconds": numberProp("Per-account deadline (default 8).")
            ]
        ),
        tool(
            "confirm_send",
            "Confirm a pending send after the user asked you to send it. Still requires send safety mode.",
            [
                "pending_id": stringProp("Pending send UUID from send_message or list_pending_sends.")
            ],
            required: ["pending_id"]
        ),
        tool(
            "get_thread",
            "Read a conversation in date order. Pass a thread id from list_threads or a message id.",
            [
                "account_id": stringProp("Account UUID or email."),
                "thread_id": stringProp("Thread id or message id."),
                "limit": numberProp("Maximum messages (default 20).")
            ],
            required: ["thread_id"]
        ),
        tool(
            "inbox_digest",
            "Unread snapshot: aging mail, top senders, and snoozed items. Read only.",
            [
                "account_id": stringProp("Account UUID or email."),
                "limit": numberProp("How many unread items to sample (default 20).")
            ]
        ),
        tool(
            "list_contacts",
            "People you write to most, from Sent mail.",
            [
                "account_id": stringProp("Account UUID or email."),
                "limit": numberProp("Maximum contacts (default 20).")
            ]
        ),
        tool(
            "suggest_recipients",
            "Filter frequent contacts by a name or address fragment.",
            [
                "account_id": stringProp("Account UUID or email."),
                "query": stringProp("Substring to match."),
                "limit": numberProp("Maximum suggestions (default 8).")
            ]
        ),
        tool(
            "list_drafts",
            "List drafts in the mailbox. Does not send.",
            [
                "account_id": stringProp("Account UUID or email."),
                "limit": numberProp("Maximum drafts (default 20).")
            ]
        ),
        tool(
            "update_draft",
            "Replace an existing draft. Does not send.",
            [
                "account_id": stringProp("Account UUID or email."),
                "draft_id": stringProp("Draft id from list_drafts."),
                "to": arrayProp("Recipient email addresses."),
                "cc": arrayProp("CC addresses."),
                "bcc": arrayProp("BCC addresses."),
                "subject": stringProp("Subject."),
                "body": stringProp("Plain-text body.")
            ],
            required: ["draft_id", "to", "subject", "body"]
        ),
        tool(
            "delete_draft",
            "Delete a draft. Does not notify anyone.",
            [
                "account_id": stringProp("Account UUID or email."),
                "draft_id": stringProp("Draft id from list_drafts.")
            ],
            required: ["draft_id"]
        ),
        tool(
            "file_message",
            "Move a message to a folder and/or apply labels. Nobody else is notified.",
            [
                "account_id": stringProp("Account UUID or email."),
                "message_id": stringProp("Location-aware id from search_messages, or a provider message id."),
                "folder": stringProp("Destination folder name, e.g. Applied intuition."),
                "add_labels": arrayProp("Labels to add."),
                "remove_labels": arrayProp("Labels to remove.")
            ],
            required: ["message_id"]
        ),
        tool(
            "file_search",
            "Move or label every match for a search into a folder. Creates the folder if needed. Use mailbox=all for Gmail All Mail (COPY/label, does not leave All Mail). Gmail queries like has:nouserlabels work. Empty query is refused.",
            [
                "account_id": stringProp("Account UUID or email."),
                "query": stringProp("Required search. IMAP: from:, to:, subject:, in:all. Gmail: has:nouserlabels and other web operators."),
                "folder": stringProp("Destination folder, e.g. Amazon/Order."),
                "mailbox": stringProp("Optional source folder. spam, trash, everywhere, all, or a folder name. Default Inbox."),
                "limit": numberProp("Optional max messages to file this call. Use 200 for unlabeled Inbox pulls.")
            ],
            required: ["query", "folder"]
        ),
        tool(
            "snooze_message",
            "Hide a message from inbox_digest until a time. Local to this Mac; does not email anyone.",
            [
                "account_id": stringProp("Account UUID or email."),
                "message_id": stringProp("Location-aware id from search_messages, or a provider message id."),
                "until": stringProp("ISO-8601 date or +3d / +12h / +1w. Default +1d.")
            ],
            required: ["message_id"]
        ),
        tool(
            "reply_message",
            "Reply to a message. The original sender will receive mail. Requires send safety mode.",
            [
                "account_id": stringProp("Account UUID or email."),
                "message_id": stringProp("Message to reply to."),
                "body": stringProp("Your reply text."),
                "reply_all": stringProp("true to include original To/Cc.")
            ],
            required: ["message_id", "body"]
        ),
        tool(
            "import_imap_file",
            "One-time IMAP import from a local text file. Reads email/password pairs from disk; does not send the file anywhere. Skips addresses already in the vault.",
            [
                "path": stringProp("Absolute path to a local text file of email + app password pairs.")
            ],
            required: ["path"]
        ),
        tool(
            "forward_message",
            "Forward a message to someone else. Requires send safety mode.",
            [
                "account_id": stringProp("Account UUID or email."),
                "message_id": stringProp("Message to forward."),
                "to": arrayProp("New recipients."),
                "body": stringProp("Optional note above the forwarded mail.")
            ],
            required: ["message_id", "to"]
        )
    ]

    @MainActor
    static func call(name: String, arguments: [String: Any]) async throws -> String {
        let state = AppState.shared
        guard state.isUnlocked else {
            throw MailMCPError.vaultLocked
        }
        if !ToolGateStore.isEnabled(name) {
            throw MailMCPError.safetyDenied("Tool \(name) is disabled in MailMCP → Settings → MCP.")
        }

        switch name {
        case "list_accounts":
            let rows = state.accounts.map {
                [
                    "id": $0.id.uuidString,
                    "email": $0.email,
                    "provider": $0.provider.rawValue,
                    "display_name": $0.displayName,
                    "last_error": $0.lastError ?? "",
                    "vault_id": state.vaultID(for: $0)?.uuidString ?? "",
                    "vault_name": state.vaultName(for: $0)
                ]
            }
            return try encode(rows)

        case "list_folders":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            let mail = try state.provider(for: account)
            let includeCounts = bool(arguments["include_counts"])
            let folders = try await MailDeadline.withTimeout(seconds: includeCounts ? 45 : MailDeadline.probeDefault) {
                try await mail.listFolders(includeCounts: includeCounts)
            }
            let sorted = includeCounts
                ? folders.sorted { ($0.messages ?? -1) > ($1.messages ?? -1) }
                : folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return try encode(FolderCensus(
                account: account.email,
                folderCount: sorted.count,
                includeCounts: includeCounts,
                note: includeCounts
                    ? "Folder counts can overlap (Gmail All Mail includes Inbox, Sent, etc.)."
                    : "Counts omitted. Pass include_counts=true if you need them. Use mailbox=spam/trash/everywhere on search_messages.",
                folders: sorted
            ))

        case "probe_accounts":
            return try await probeAccounts(state: state, arguments: arguments)

        case "search_messages":
            return try await searchMessages(state: state, arguments: arguments)

        case "get_message":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            let mail = try state.provider(for: account)
            guard let id = string(arguments["message_id"]) else {
                throw MailMCPError.invalidInput("message_id is required")
            }
            return try encode(try await mail.getMessage(id: id))

        case "list_threads":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            let mail = try state.provider(for: account)
            let result = try await mail.listThreads(query: string(arguments["query"]), limit: int(arguments["limit"]) ?? 20)
            return try encode(result)

        case "modify_message":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            try state.assertSafety(.drafts, for: account)
            let mail = try state.provider(for: account)
            guard let id = string(arguments["message_id"]) else {
                throw MailMCPError.invalidInput("message_id is required")
            }
            guard let actionRaw = string(arguments["action"]), let action = MailModifyAction(rawValue: actionRaw) else {
                throw MailMCPError.invalidInput("action must be archive, trash, markRead, markUnread, addLabel, or removeLabel")
            }
            try await mail.modify(id: id, action: action, label: string(arguments["label"]))
            return try encode(["status": "ok", "action": actionRaw, "message_id": id])

        case "create_draft":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            try state.assertSafety(.drafts, for: account)
            let mail = try state.provider(for: account)
            let id = try await mail.createDraft(
                to: strings(arguments["to"]),
                cc: strings(arguments["cc"]),
                bcc: strings(arguments["bcc"]),
                subject: string(arguments["subject"]) ?? "",
                body: string(arguments["body"]) ?? ""
            )
            return try encode(["status": "drafted", "id": id])

        case "send_message":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            try state.assertSafety(.send, for: account)
            return try await enqueueOrSend(
                state: state,
                account: account,
                to: strings(arguments["to"]),
                cc: strings(arguments["cc"]),
                bcc: strings(arguments["bcc"]),
                subject: string(arguments["subject"]) ?? "",
                body: string(arguments["body"]) ?? "",
                extraHeaders: [:]
            )

        case "get_attachment":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            let mail = try state.provider(for: account)
            guard let messageID = string(arguments["message_id"]), let attachmentID = string(arguments["attachment_id"]) else {
                throw MailMCPError.invalidInput("message_id and attachment_id are required")
            }
            return try encode(try await mail.getAttachment(messageID: messageID, attachmentID: attachmentID))

        case "list_pending_sends":
            return try encode(state.pendingSends)

        case "get_thread":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            let mail = try state.provider(for: account)
            guard let threadID = string(arguments["thread_id"]) else {
                throw MailMCPError.invalidInput("thread_id is required")
            }
            return try encode(try await mail.getThread(id: threadID, limit: int(arguments["limit"]) ?? 20))

        case "inbox_digest":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            let mail = try state.provider(for: account)
            let limit = int(arguments["limit"]) ?? 20
            let inboxTotal = try? await mail.messageCount(query: "")
            let unread = try await mail.search(query: "is:unread", limit: max(limit, 20)).filter(\.isUnread)
            let snoozedIDs = Set(SnoozeStore.active(accountID: account.id).map(\.messageID))
            let visible = unread.filter { !snoozedIDs.contains($0.id) }
            let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
            var senderCounts: [String: Int] = [:]
            for item in visible {
                senderCounts[item.from, default: 0] += 1
            }
            let digest = InboxDigest(
                account: account.email,
                inboxTotal: inboxTotal ?? unread.count,
                inboxUnread: unread.count,
                snoozed: snoozedIDs.count,
                needsReply: Array(visible.prefix(limit)),
                agingUnread: visible.filter { ($0.date ?? Date()) < weekAgo },
                topSenders: senderCounts.map { MailContact(address: $0.key, name: $0.key, count: $0.value) }
                    .sorted { $0.count > $1.count }
                    .prefix(8)
                    .map { $0 },
                note: "Snoozed messages are omitted from needs_reply. Digest does not change mail."
            )
            return try encode(digest)

        case "list_contacts":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            let mail = try state.provider(for: account)
            return try encode(try await mail.frequentContacts(limit: int(arguments["limit"]) ?? 20))

        case "suggest_recipients":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            let mail = try state.provider(for: account)
            let query = (string(arguments["query"]) ?? "").lowercased()
            let contacts = try await mail.frequentContacts(limit: 40)
            let filtered = query.isEmpty ? contacts : contacts.filter {
                $0.address.lowercased().contains(query) || $0.name.lowercased().contains(query)
            }
            return try encode(Array(filtered.prefix(int(arguments["limit"]) ?? 8)))

        case "list_drafts":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            let mail = try state.provider(for: account)
            return try encode(try await mail.listDrafts(limit: int(arguments["limit"]) ?? 20))

        case "update_draft":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            try state.assertSafety(.drafts, for: account)
            let mail = try state.provider(for: account)
            guard let draftID = string(arguments["draft_id"]) else {
                throw MailMCPError.invalidInput("draft_id is required")
            }
            let id = try await mail.updateDraft(
                id: draftID,
                to: strings(arguments["to"]),
                cc: strings(arguments["cc"]),
                bcc: strings(arguments["bcc"]),
                subject: string(arguments["subject"]) ?? "",
                body: string(arguments["body"]) ?? ""
            )
            return try encode(["status": "updated", "id": id])

        case "delete_draft":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            try state.assertSafety(.drafts, for: account)
            let mail = try state.provider(for: account)
            guard let draftID = string(arguments["draft_id"]) else {
                throw MailMCPError.invalidInput("draft_id is required")
            }
            try await mail.deleteDraft(id: draftID)
            return try encode(["status": "deleted", "id": draftID])

        case "file_message":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            try state.assertSafety(.drafts, for: account)
            let mail = try state.provider(for: account)
            guard let id = string(arguments["message_id"]) else {
                throw MailMCPError.invalidInput("message_id is required")
            }
            try await mail.fileMessage(
                id: id,
                folder: string(arguments["folder"]),
                addLabels: strings(arguments["add_labels"]),
                removeLabels: strings(arguments["remove_labels"])
            )
            return try encode(["status": "filed", "message_id": id])

        case "file_search":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            try state.assertSafety(.drafts, for: account)
            let mail = try state.provider(for: account)
            guard let query = string(arguments["query"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty else {
                throw MailMCPError.invalidInput("query is required; refusing to file the entire mailbox")
            }
            guard let folder = string(arguments["folder"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !folder.isEmpty else {
                throw MailMCPError.invalidInput("folder is required")
            }
            let mailbox = string(arguments["mailbox"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            let limit = int(arguments["limit"])
            let filed = try await mail.fileMatching(query: query, folder: folder, mailbox: mailbox, limit: limit)
            var payload: [String: Any] = [
                "status": "filed",
                "account": account.email,
                "query": query,
                "folder": folder,
                "mailbox": mailbox ?? "INBOX",
                "filed": filed
            ]
            if let limit { payload["limit"] = limit }
            return try encode(payload)

        case "snooze_message":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            try state.assertSafety(.drafts, for: account)
            guard let id = string(arguments["message_id"]) else {
                throw MailMCPError.invalidInput("message_id is required")
            }
            let until = parseUntil(string(arguments["until"]))
            var subject = id
            if let mail = try? state.provider(for: account),
               let message = try? await mail.getMessage(id: id) {
                subject = message.subject
            }
            SnoozeStore.snooze(accountID: account.id, messageID: id, until: until, subject: subject)
            return try encode(["status": "snoozed", "message_id": id, "until": ISO8601DateFormatter().string(from: until)])

        case "reply_message":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            try state.assertSafety(.send, for: account)
            let mail = try state.provider(for: account)
            guard let id = string(arguments["message_id"]) else {
                throw MailMCPError.invalidInput("message_id is required")
            }
            let original = try await mail.getMessage(id: id)
            let replyAll = bool(arguments["reply_all"])
            let composed = MailCompose.reply(to: original, accountEmail: account.email, body: string(arguments["body"]) ?? "", replyAll: replyAll)
            return try await enqueueOrSend(
                state: state,
                account: account,
                to: composed.to,
                cc: composed.cc,
                bcc: [],
                subject: composed.subject,
                body: composed.body,
                extraHeaders: composed.headers
            )

        case "forward_message":
            let account = try state.resolveAccount(idOrEmail: string(arguments["account_id"]))
            try state.assertSafety(.send, for: account)
            let mail = try state.provider(for: account)
            guard let id = string(arguments["message_id"]) else {
                throw MailMCPError.invalidInput("message_id is required")
            }
            let original = try await mail.getMessage(id: id)
            let to = strings(arguments["to"])
            guard !to.isEmpty else { throw MailMCPError.invalidInput("to is required") }
            let composed = MailCompose.forward(original: original, to: to, body: string(arguments["body"]) ?? "")
            return try await enqueueOrSend(
                state: state,
                account: account,
                to: to,
                cc: [],
                bcc: [],
                subject: composed.subject,
                body: composed.body,
                extraHeaders: [:]
            )

        case "confirm_send":
            guard let raw = string(arguments["pending_id"]), let id = UUID(uuidString: raw) else {
                throw MailMCPError.invalidInput("pending_id must be a UUID")
            }
            guard let pending = state.pendingSends.first(where: { $0.id == id }) else {
                throw MailMCPError.invalidInput("No pending send with that id")
            }
            let account = try state.resolveAccount(idOrEmail: pending.accountID.uuidString)
            try state.assertSafety(.send, for: account)
            let result = try await state.confirmPendingSend(pending)
            return try encode(["status": "sent", "id": result])

        case "import_imap_file":
            guard let path = string(arguments["path"])?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                throw MailMCPError.invalidInput("path is required")
            }
            let result = try state.importIMAPAccounts(fromFile: URL(fileURLWithPath: path))
            return try encode([
                "added": result.added,
                "replaced": result.replaced,
                "skipped": result.skipped,
                "errors": result.errors,
                "added_count": result.added.count,
                "skipped_count": result.skipped.count
            ])

        default:
            throw MailMCPError.invalidInput("Unknown tool: \(name)")
        }
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required
            ]
        ]
    }

    private static func stringProp(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func numberProp(_ description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }

    private static func arrayProp(_ description: String) -> [String: Any] {
        ["type": "array", "description": description, "items": ["type": "string"]]
    }

    private static func enumProp(_ description: String) -> [String: Any] {
        [
            "type": "string",
            "description": description,
            "enum": ["archive", "trash", "markRead", "markUnread", "addLabel", "removeLabel"]
        ]
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? CustomStringConvertible, !(value is NSNull) {
            let text = String(describing: value)
            return text == "<null>" ? nil : text
        }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? String {
            return ["true", "1", "yes"].contains(value.lowercased())
        }
        return false
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func strings(_ value: Any?) -> [String] {
        if let value = value as? [String] { return value }
        if let value = value as? String { return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        if let value = value as? [Any] {
            return value.compactMap { string($0) }
        }
        return []
    }

    private struct FolderCensus: Encodable {
        var account: String
        var folderCount: Int
        var includeCounts: Bool
        var note: String
        var folders: [MailFolderCount]
    }

    private static func accountIDs(_ arguments: [String: Any]) -> [String] {
        var ids = strings(arguments["account_ids"])
        if let one = string(arguments["account_id"])?.trimmingCharacters(in: .whitespacesAndNewlines), !one.isEmpty {
            ids.append(contentsOf: one.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        return ids.filter { !$0.isEmpty }
    }

    @MainActor
    private static func searchMessages(state: AppState, arguments: [String: Any]) async throws -> String {
        let accounts = try state.resolveAccounts(ids: accountIDs(arguments))
        let pairs: [(MailAccount, any MailProviding)] = try accounts.map { account in
            (account, try state.provider(for: account))
        }
        let request = MailSearchRequest(
            query: string(arguments["query"]) ?? "",
            mailbox: string(arguments["mailbox"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            accountIDs: accounts.map(\.email),
            after: MailSearchQuery.parseDate(string(arguments["after"]) ?? ""),
            before: MailSearchQuery.parseDate(string(arguments["before"]) ?? ""),
            limit: int(arguments["limit"]) ?? 20,
            skip: SearchCursor.decode(string(arguments["cursor"])),
            timeout: Double(int(arguments["timeout_seconds"]) ?? Int(MailDeadline.searchDefault))
        )
        let result = await MailSearchCoordinator.run(accounts: pairs, request: request)
        return try encode(result)
    }

    @MainActor
    private static func probeAccounts(state: AppState, arguments: [String: Any]) async throws -> String {
        let accounts = try state.resolveAccounts(ids: accountIDs(arguments))
        let timeout = Double(int(arguments["timeout_seconds"]) ?? Int(MailDeadline.probeDefault))
        let gate = MailConcurrencyGate(limit: MailDeadline.accountConcurrency)
        var rows: [AccountProbe] = []
        await withTaskGroup(of: AccountProbe.self) { group in
            for account in accounts {
                group.addTask {
                    let started = Date()
                    do {
                        return try await gate.withPermit {
                            try await MailDeadline.withTimeout(seconds: timeout) {
                                let mail = try await MainActor.run { try state.provider(for: account) }
                                let ping = try await mail.testConnection()
                                let resolved = try await mail.resolveMailboxes(["inbox", "spam", "trash"])
                                return AccountProbe(
                                    account: account.email,
                                    accountID: account.id.uuidString,
                                    provider: account.provider.rawValue,
                                    status: "ok",
                                    ping: ping,
                                    folders: resolved.filter { !$0.name.isEmpty },
                                    error: nil,
                                    elapsedMs: Int(Date().timeIntervalSince(started) * 1000)
                                )
                            }
                        }
                    } catch {
                        return AccountProbe(
                            account: account.email,
                            accountID: account.id.uuidString,
                            provider: account.provider.rawValue,
                            status: "error",
                            ping: nil,
                            folders: [],
                            error: error.localizedDescription,
                            elapsedMs: Int(Date().timeIntervalSince(started) * 1000)
                        )
                    }
                }
            }
            for await row in group {
                rows.append(row)
            }
        }
        rows.sort { $0.account.localizedCaseInsensitiveCompare($1.account) == .orderedAscending }
        return try encode(
            AccountProbeResult(
                status: rows.contains(where: { $0.status != "ok" }) ? (rows.contains(where: { $0.status == "ok" }) ? "partial" : "error") : "ok",
                accounts: rows,
                note: "Folder discovery only. Message counts were not fetched."
            )
        )
    }

    private struct AccountProbe: Encodable, Sendable {
        var account: String
        var accountID: String
        var provider: String
        var status: String
        var ping: String?
        var folders: [ResolvedMailbox]
        var error: String?
        var elapsedMs: Int
    }

    private struct AccountProbeResult: Encodable {
        var status: String
        var accounts: [AccountProbe]
        var note: String
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONCoders.prettyEncoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func encode(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    private static func enqueueOrSend(
        state: AppState,
        account: MailAccount,
        to: [String],
        cc: [String],
        bcc: [String],
        subject: String,
        body: String,
        extraHeaders: [String: String]
    ) async throws -> String {
        let pending = PendingSend(
            accountID: account.id,
            accountEmail: account.email,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: body,
            extraHeaders: extraHeaders
        )
        if state.settings(for: account).confirmBeforeSend {
            state.enqueueSend(pending)
            return try encode([
                "status": "pending_confirmation",
                "pending_id": pending.id.uuidString,
                "message": "Confirm this send in the MailMCP app or call confirm_send after the user explicitly confirms."
            ])
        }
        let mail = try state.provider(for: account)
        let id = try await mail.send(
            to: pending.to,
            cc: pending.cc,
            bcc: pending.bcc,
            subject: pending.subject,
            body: pending.body,
            extraHeaders: pending.extraHeaders
        )
        return try encode(["status": "sent", "id": id])
    }

    private static func parseUntil(_ raw: String?) -> Date {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty { return Date().addingTimeInterval(24 * 3600) }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        if value.hasPrefix("+"), value.count >= 3, let amount = Double(value.dropFirst().dropLast()) {
            let unit = value.last
            switch unit {
            case "h": return Date().addingTimeInterval(amount * 3600)
            case "w": return Date().addingTimeInterval(amount * 7 * 24 * 3600)
            default: return Date().addingTimeInterval(amount * 24 * 3600)
            }
        }
        return Date().addingTimeInterval(24 * 3600)
    }
}
