import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReaderFolder: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let title: String
    let systemImage: String
    let kind: MailboxKind
    let unseen: Int?
}

enum ReaderFolders {
    private static let hiddenNames: Set<String> = ["UNREAD", "CHAT", "[GMAIL]", "[GOOGLE MAIL]"]
    static let gmailSystemLabels: Set<String> = ["INBOX", "SENT", "DRAFT", "SPAM", "TRASH", "STARRED", "IMPORTANT", "UNREAD", "CHAT"]

    static func visible(_ folders: [MailFolderCount]) -> [ReaderFolder] {
        folders.compactMap { folder -> ReaderFolder? in
            let upper = folder.name.uppercased()
            guard folder.selectable, !hiddenNames.contains(upper), !upper.hasPrefix("CATEGORY_") else { return nil }
            let kind = MailboxMatcher.kind(ofName: folder.name)
            return ReaderFolder(
                name: folder.name,
                title: title(for: folder.name),
                systemImage: icon(for: folder.name, kind: kind),
                kind: kind,
                unseen: folder.unseen
            )
        }
        .sorted { lhs, rhs in
            let left = rank(lhs), right = rank(rhs)
            if left != right { return left < right }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    static func inboxName(in folders: [MailFolderCount]) -> String {
        folders.first { MailboxMatcher.kind(ofName: $0.name) == .inbox }?.name ?? "INBOX"
    }

    static func title(for name: String) -> String {
        switch name.uppercased() {
        case "INBOX": return "Inbox"
        case "SENT": return "Sent"
        case "DRAFT", "DRAFTS": return "Drafts"
        case "SPAM": return "Spam"
        case "TRASH": return "Trash"
        case "STARRED": return "Starred"
        case "IMPORTANT": return "Important"
        default:
            return name.split(separator: "/").last.map(String.init) ?? name
        }
    }

    private static func icon(for name: String, kind: MailboxKind) -> String {
        switch name.uppercased() {
        case "STARRED": return "star"
        case "IMPORTANT": return "tag"
        default: break
        }
        switch kind {
        case .inbox: return "tray"
        case .drafts: return "doc"
        case .sent: return "paperplane"
        case .archive: return "archivebox"
        case .all: return "tray.full"
        case .spam: return "xmark.bin"
        case .trash: return "trash"
        case .other: return "folder"
        }
    }

    private static func rank(_ folder: ReaderFolder) -> Int {
        switch folder.name.uppercased() {
        case "STARRED": return 1
        case "IMPORTANT": return 2
        default: break
        }
        switch folder.kind {
        case .inbox: return 0
        case .drafts: return 3
        case .sent: return 4
        case .archive: return 5
        case .all: return 6
        case .spam: return 7
        case .trash: return 8
        case .other: return 10
        }
    }
}

enum MailDisplayFormat {
    static func address(_ raw: String) -> (name: String, email: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
            let email = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            let name = trimmed[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return (name.isEmpty ? email : name, email)
        }
        return (trimmed, trimmed)
    }

    static func initials(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }.prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }

    static func listDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// List preview text without a leading copy of the subject, which many senders repeat as the first line.
    static func preview(snippet: String, subject: String) -> String {
        let text = MailText.cleanSnippet(snippet)
        let title = collapsed(subject)
        guard !title.isEmpty,
              let range = text.range(of: title, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) else {
            return text
        }
        let rest = text[range.upperBound...].drop { " -–—:|·.!".contains($0) }
        return rest.count < 3 ? "" : String(rest)
    }

    private static func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ConversationRow: Identifiable, Equatable {
    var id: String { latest.id }
    let key: String
    let latest: MailSummary
    let memberIDs: [String]
    let isUnread: Bool
    /// Messages in the conversation, including ones filed in other folders when the cache knows them.
    let count: Int
}

@MainActor
final class MailboxReaderModel: ObservableObject {
    enum Removal {
        case archive
        case trash
        case move(String)
    }

    let accountID: UUID
    let folder: String

    @Published private(set) var messages: [MailSummary] = [] {
        didSet {
            // A message opened from a link may be older than the loaded page; keep its row while it is open.
            if let linked, linked.id == selectedID, !messages.contains(where: { $0.id == linked.id }) {
                messages = Self.sorted(messages + [linked])
                return
            }
            rebuildRows()
            // Toolbar actions only act on listed rows, so a conversation that leaves the list (e.g. filtered out by search) closes too.
            if let selectedID, !messages.contains(where: { $0.id == selectedID }),
               !(conversationKey.map { key in rows.contains { $0.key == key } } ?? false) {
                select(nil)
            }
        }
    }
    /// The list as Gmail shows it: one row per conversation, represented by its newest listed message.
    @Published private(set) var rows: [ConversationRow] = []
    /// The open conversation, oldest first, including messages filed in other folders (e.g. your replies in Sent).
    @Published private(set) var conversation: [MailSummary] = []
    private var conversationKey: String?
    private var canonicalThreads: [String: String] = [:]
    /// Mail-style: a conversation row shows every message stacked; a message picked under an expanded row shows alone.
    @Published private(set) var showsConversation = false
    /// Conversation rows expanded in the list to show their messages.
    @Published private(set) var expandedKeys: Set<String> = []
    /// Bodies for the stacked conversation view, by message id.
    @Published private(set) var conversationBodies: [String: MailMessage] = [:]
    /// The message a link pointed at, scrolled to and marked within the stacked conversation.
    @Published private(set) var focusedMessageID: String?
    private var bodyTasks: [String: Task<Void, Never>] = [:]
    private var childrenCache: [String: [MailSummary]] = [:]
    @Published private(set) var selectedID: String?
    @Published private(set) var openMessage: MailMessage?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var isLoadingMessage = false
    /// Set once a message has taken long enough to load (usually a server fetch) that the reader should show it.
    @Published private(set) var isLoadingSlowly = false
    @Published private(set) var reachedEnd = false
    @Published private(set) var hasLoadedOnce = false
    @Published private(set) var listError: String?
    @Published private(set) var messageError: String?
    @Published private(set) var remoteAllowedMessageIDs: Set<String> = []
    /// Newer mail found by background sync, held back until the user clicks the new-mail pill.
    @Published private(set) var incoming: [MailSummary] = []
    /// Rows just inserted at the top; highlighted briefly.
    @Published private(set) var freshIDs: Set<String> = []
    @Published private(set) var scrollToTopRequest = 0
    /// Set when a link opens a message, until the list has scrolled to its row.
    @Published var pendingReveal = false
    @Published var actionError: String?
    @Published var searchText = ""

    static let pageSize = 50
    private static let revealLimit = 2000
    private static let markReadDelayNs: UInt64 = 2_000_000_000

    private weak var appState: AppState?
    private var refreshTask: Task<Void, Never>?
    private var moreTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var markReadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var pendingRemovals: Set<String> = []
    private var linked: MailSummary?
    private var started = false
    private var freshTask: Task<Void, Never>?

    init(accountID: UUID, folder: String) {
        self.accountID = accountID
        self.folder = folder
    }

    var account: MailAccount? { appState?.account(id: accountID) }
    var folderKind: MailboxKind { MailboxMatcher.kind(ofName: folder) }
    var selectedSummary: MailSummary? { selectedRow?.latest }
    var selectedRow: ConversationRow? {
        guard let key = conversationKey else { return nil }
        return rows.first { $0.key == key }
    }
    var showsRecipients: Bool { folderKind == .sent || folderKind == .drafts }
    private var activeQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var cacheActive: Bool {
        guard let appState, let account else { return false }
        return appState.settings(for: account).cachePolicy.effective(for: account).cacheActive
    }

    var canArchive: Bool {
        guard let account else { return false }
        if account.provider == .gmail { return folderKind == .inbox }
        return ![.archive, .all, .trash, .drafts].contains(folderKind)
    }

    var canTrash: Bool { folderKind != .trash }

    func moveDestinations() -> [ReaderFolder] {
        guard let appState, let account else { return [] }
        return ReaderFolders.visible(appState.mailFolders(for: account))
            .filter { $0.name != folder && $0.kind != .drafts && $0.kind != .sent }
    }

    func start(appState: AppState) {
        guard !started else { return }
        started = true
        self.appState = appState
        paintFromCache()
        refresh()
        if let account {
            appState.refreshFolders(for: account)
        }
    }

    func stop() {
        for task in [refreshTask, moreTask, messageTask, markReadTask, searchTask, freshTask] {
            task?.cancel()
        }
    }

    private func provider() throws -> any MailProviding {
        guard let appState, let account else {
            throw MailMCPError.invalidInput("This mailbox is no longer available.")
        }
        return try appState.provider(for: account)
    }

    // MARK: - List

    private func cachedPage(limit: Int) -> [MailSummary] {
        MailboxCacheStore.shared.search(
            accountID: accountID,
            mailboxes: [folder],
            query: activeQuery,
            after: nil,
            before: nil,
            limit: limit
        )
        .filter { !pendingRemovals.contains($0.id) }
    }

    private func paintFromCache() {
        guard cacheActive else { return }
        let cached = cachedPage(limit: max(messages.count, Self.pageSize))
        if !cached.isEmpty {
            messages = cached
        }
    }

    func refresh() {
        refreshTask?.cancel()
        listError = nil
        isRefreshing = true
        let query = activeQuery
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let hits = try await self.provider().searchFoldered(
                    FolderSearchSpec(query: query, mailboxes: [self.folder], after: nil, before: nil, limit: Self.pageSize)
                )
                try Task.checkCancellation()
                self.applyFirstPage(hits)
            } catch {
                if Task.isCancelled { return }
                self.listError = error.localizedDescription
            }
            self.isRefreshing = false
            self.hasLoadedOnce = true
        }
    }

    private func applyFirstPage(_ hits: [MailSummary]) {
        let page = Self.sorted(hits.filter { !pendingRemovals.contains($0.id) })
        if hasLoadedOnce, activeQuery.isEmpty {
            let newer = newerThanShown(page)
            if !newer.isEmpty { highlight(Set(newer.map(\.id))) }
        }
        incoming = []
        if hits.count >= Self.pageSize, let oldest = page.last?.date {
            let ids = Set(page.map(\.id))
            messages = page + messages.filter { !ids.contains($0.id) && ($0.date ?? .distantPast) < oldest }
            reachedEnd = false
        } else {
            messages = page
            reachedEnd = true
        }
    }

    func loadMore() {
        // A linked message pinned below the loaded page doesn't count, or paging would skip everything above it.
        let paged = messages.filter { $0.id != linked?.id }
        guard !reachedEnd, !isLoadingMore, !isRefreshing, let oldest = (paged.isEmpty ? messages : paged).last?.date else { return }
        isLoadingMore = true
        let query = activeQuery
        moreTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isLoadingMore = false }
            do {
                let mail = try self.provider()
                // Gmail and IMAP date filters are day-granular, so overlap by a day and drop duplicates.
                let dayStart = Calendar.current.startOfDay(for: oldest)
                let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? oldest
                var fresh = try await self.fetchOlder(mail, query: query, before: nextDay)
                if fresh.isEmpty {
                    fresh = try await self.fetchOlder(mail, query: query, before: dayStart)
                }
                try Task.checkCancellation()
                if fresh.isEmpty {
                    self.reachedEnd = true
                } else {
                    self.messages = Self.sorted(self.messages + fresh)
                }
            } catch {
                if Task.isCancelled { return }
                self.listError = error.localizedDescription
            }
        }
    }

    private func fetchOlder(_ mail: any MailProviding, query: String, before: Date) async throws -> [MailSummary] {
        let hits = try await mail.searchFoldered(
            FolderSearchSpec(query: query, mailboxes: [folder], after: nil, before: before, limit: Self.pageSize)
        )
        let known = Set(messages.map(\.id))
        return hits.filter { !known.contains($0.id) && !pendingRemovals.contains($0.id) }
    }

    func searchTextChanged() {
        searchTask?.cancel()
        linked = nil
        guard !activeQuery.isEmpty else {
            paintFromCache()
            refresh()
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled, self.cacheActive else { return }
            self.messages = self.cachedPage(limit: Self.pageSize)
            self.reachedEnd = true
        }
    }

    func cacheDidChange() {
        guard cacheActive, activeQuery.isEmpty, !isRefreshing, account?.syncScope != .off else { return }
        let held = Set(incoming.map(\.id))
        let cached = cachedPage(limit: max(messages.count, Self.pageSize) + incoming.count + Self.pageSize)
        guard !cached.isEmpty else { return }
        guard hasLoadedOnce, !messages.isEmpty else {
            if cached != messages { messages = Array(cached.prefix(max(messages.count, Self.pageSize))) }
            return
        }
        // Mail newer than the top row waits behind the pill so the list doesn't jump under the reader.
        let newer = newerThanShown(cached)
        let newerIDs = Set(newer.map(\.id))
        if !newer.isEmpty, newerIDs != held {
            incoming = newer
        }
        let pinnedRows = linked.map { pinned in cached.contains { $0.id == pinned.id } ? 0 : 1 } ?? 0
        let visible = Array(cached.filter { !newerIDs.contains($0.id) }.prefix(messages.count - pinnedRows))
        if visible != messages {
            messages = visible
        }
    }

    /// Reveals held-back mail at the top of the list.
    func showIncoming() {
        guard !incoming.isEmpty else { return }
        let ids = Set(incoming.map(\.id))
        messages = Self.sorted(incoming + messages.filter { !ids.contains($0.id) })
        incoming = []
        highlight(ids)
        scrollToTopRequest &+= 1
    }

    private func newerThanShown(_ candidates: [MailSummary]) -> [MailSummary] {
        let shown = Set(messages.map(\.id))
        let top = messages.compactMap(\.date).max() ?? .distantPast
        return candidates.filter { !shown.contains($0.id) && ($0.date ?? .distantPast) > top }
    }

    private func highlight(_ ids: Set<String>) {
        freshIDs = ids
        freshTask?.cancel()
        freshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.8)) { self?.freshIDs = [] }
        }
    }

    private static func sorted(_ items: [MailSummary]) -> [MailSummary] {
        items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    // MARK: - Conversations

    /// Drafts stay one row each; elsewhere messages group by thread id, following ids the cache has linked to their conversation.
    private func conversationKey(of message: MailSummary) -> String {
        guard folderKind != .drafts, let thread = message.threadID else { return message.id }
        return canonicalThreads[thread] ?? thread
    }

    private func rebuildRows() {
        let store = MailboxCacheStore.shared
        let grouping = cacheActive && folderKind != .drafts
        canonicalThreads = grouping ? store.canonicalThreadIDs(accountID: accountID, keys: Set(messages.compactMap(\.threadID))) : [:]
        var groups: [String: [MailSummary]] = [:]
        var order: [String] = []
        for message in messages {
            let key = conversationKey(of: message)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(message)
        }
        let counts = grouping ? store.threadMessageCounts(accountID: accountID, threadIDs: Set(order)) : [:]
        let built = order.compactMap { key -> ConversationRow? in
            guard let members = groups[key], let latest = members.first else { return nil }
            var seen = Set<String>()
            let unique = members.filter { seen.insert(MailThread.copyKey($0)).inserted }
            return ConversationRow(
                key: key,
                latest: latest,
                memberIDs: members.map(\.id),
                isUnread: members.contains(where: \.isUnread),
                count: max(unique.count, counts[key] ?? 0)
            )
        }
        childrenCache = [:]
        if built != rows { rows = built }
        if let conversationKey {
            let fresh = conversationMembers(key: conversationKey)
            if fresh != conversation { conversation = fresh }
        }
    }

    private func key(of id: String) -> String? {
        if let message = messages.first(where: { $0.id == id }) { return conversationKey(of: message) }
        if conversation.contains(where: { $0.id == id }) { return conversationKey }
        return nil
    }

    /// Listed messages in the same conversation as `id`; row actions apply to all of them, as in Gmail.
    private func memberIDs(of id: String) -> [String] {
        guard let key = key(of: id), let row = rows.first(where: { $0.key == key }) else { return [id] }
        return row.memberIDs
    }

    /// What a toolbar or menu action on `id` touches: the one message when it was picked on its own, else its conversation.
    private func actionIDs(for id: String) -> [String] {
        if !showsConversation, id == selectedID, messages.contains(where: { $0.id == id }) { return [id] }
        return memberIDs(of: id)
    }

    /// An expanded row's messages, newest first, including ones filed in other folders.
    func children(of row: ConversationRow) -> [MailSummary] {
        if let cached = childrenCache[row.key] { return cached }
        let members = Array(conversationMembers(key: row.key).reversed())
        childrenCache[row.key] = members
        return members
    }

    func toggleExpanded(_ row: ConversationRow) {
        if expandedKeys.contains(row.key) {
            expandedKeys.remove(row.key)
        } else {
            expandedKeys.insert(row.key)
        }
    }

    /// Loads one stacked message's body; the cache answers first, so most open instantly.
    func loadConversationBody(_ id: String) {
        guard conversationBodies[id] == nil, bodyTasks[id] == nil else { return }
        if openMessage?.id == id, let openMessage {
            conversationBodies[id] = openMessage
            return
        }
        bodyTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.bodyTasks[id] = nil }
            if let message = try? await self.provider().getMessage(id: id), !Task.isCancelled {
                self.conversationBodies[id] = message
            }
        }
    }

    /// Listed members plus, from the cache, the rest of the thread in other folders, oldest first.
    private func conversationMembers(key: String) -> [MailSummary] {
        let listed = rows.first { $0.key == key }.map { row in messages.filter { row.memberIDs.contains($0.id) } } ?? []
        guard cacheActive, folderKind != .drafts, listed.contains(where: { $0.threadID != nil }) else {
            return listed.reversed()
        }
        var members = MailboxCacheStore.shared.threadSummaries(accountID: accountID, threadID: key, preferredMailbox: folder)
        for message in listed where !members.contains(where: { $0.id == message.id }) {
            if let copy = members.firstIndex(where: { MailThread.copyKey($0) == MailThread.copyKey(message) }) {
                members[copy] = message
            } else {
                members.append(message)
            }
        }
        return members.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    private func openConversation(containing id: String) {
        let key = key(of: id) ?? id
        guard key != conversationKey else { return }
        conversationKey = key
        conversation = conversationMembers(key: key)
        for task in bodyTasks.values { task.cancel() }
        bodyTasks = [:]
        conversationBodies = [:]
    }

    /// A row click shows the whole conversation, as Apple Mail does.
    func selectRow(_ id: String?) {
        guard let id else {
            select(nil)
            return
        }
        let key = key(of: id) ?? id
        guard key != conversationKey || selectedID == nil || !showsConversation else { return }
        focusedMessageID = nil
        openConversation(containing: id)
        showsConversation = conversation.count > 1
        select(id)
    }

    /// A message picked under an expanded row shows on its own.
    func selectSingle(_ id: String) {
        if let row = rows.first(where: { childrenCache[$0.key]?.contains { $0.id == id } ?? false }) {
            openConversation(containing: row.id)
        }
        showsConversation = false
        focusedMessageID = nil
        if id == selectedID { return }
        select(id)
    }

    // MARK: - Reading

    func select(_ id: String?) {
        guard id != selectedID else { return }
        if id != linked?.id { linked = nil }
        markReadTask?.cancel()
        messageTask?.cancel()
        messageError = nil
        guard let id else {
            selectedID = nil
            conversationKey = nil
            conversation = []
            showsConversation = false
            focusedMessageID = nil
            for task in bodyTasks.values { task.cancel() }
            bodyTasks = [:]
            conversationBodies = [:]
            openMessage = nil
            isLoadingMessage = false
            isLoadingSlowly = false
            return
        }
        openConversation(containing: id)
        selectedID = id
        // The previous message stays up until this one arrives so the reader (and its web view) isn't torn down per click.
        isLoadingMessage = true
        isLoadingSlowly = false
        messageTask = Task { [weak self] in
            guard let self else { return }
            let slowTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self, self.selectedID == id, self.isLoadingMessage else { return }
                self.isLoadingSlowly = true
            }
            defer { slowTimer.cancel() }
            do {
                let message = try await self.provider().getMessage(id: id)
                try Task.checkCancellation()
                self.openMessage = message
                self.isLoadingMessage = false
                self.isLoadingSlowly = false
                if self.isUnread(id) || message.isUnread {
                    self.scheduleMarkRead(id)
                }
            } catch {
                if Task.isCancelled { return }
                self.openMessage = nil
                self.messageError = error.localizedDescription
                self.isLoadingMessage = false
                self.isLoadingSlowly = false
            }
        }
    }

    /// Loads cached mail down to `date`, so an older linked message shows in place instead of after a gap.
    private func fillFromCache(through date: Date?) {
        let paged = messages.filter { $0.id != linked?.id }
        guard let date, cacheActive, activeQuery.isEmpty, let oldest = paged.last?.date, date < oldest else { return }
        let known = Set(messages.map(\.id))
        let older = MailboxCacheStore.shared.search(
            accountID: accountID,
            mailboxes: [folder],
            query: "",
            after: date,
            before: oldest,
            limit: Self.revealLimit
        )
        .filter { !known.contains($0.id) && !pendingRemovals.contains($0.id) }
        if !older.isEmpty { messages = Self.sorted(messages + older) }
    }

    /// Shows a message opened from a `mailmcp://message` link, or why it couldn't be opened.
    func openLinked(_ request: MessageOpenRequest) {
        markReadTask?.cancel()
        messageTask?.cancel()
        isLoadingMessage = false
        isLoadingSlowly = false
        guard let message = request.message else {
            linked = nil
            selectedID = nil
            openMessage = nil
            messageError = request.error ?? "This message couldn’t be opened."
            return
        }
        fillFromCache(through: message.date)
        let summary = messages.first { $0.id == message.id } ?? MailSummary(
            id: message.id,
            accountID: message.accountID,
            accountEmail: message.accountEmail,
            threadID: message.threadID,
            from: message.from,
            to: message.to,
            subject: message.subject,
            date: message.date,
            snippet: MailText.preview(body: message.body, html: message.bodyHTML, subject: message.subject),
            isUnread: message.isUnread,
            labels: message.labels,
            mailbox: message.mailbox,
            mailboxKind: message.mailboxKind
        )
        linked = summary
        showsConversation = false
        selectedID = message.id
        messageError = nil
        openMessage = message
        if !messages.contains(where: { $0.id == message.id }) {
            messages = Self.sorted(messages + [summary])
        }
        openConversation(containing: message.id)
        showsConversation = conversation.count > 1
        focusedMessageID = showsConversation ? message.id : nil
        pendingReveal = true
        if summary.isUnread {
            scheduleMarkRead(message.id)
        }
    }

    func copyLink(id: String?) {
        guard let id else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MessageLink(accountID: accountID, messageID: id).url.absoluteString, forType: .string)
    }

    /// Opening a conversation reads all of it, as in Gmail.
    private func scheduleMarkRead(_ id: String) {
        markReadTask?.cancel()
        markReadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.markReadDelayNs)
            guard let self, !Task.isCancelled, self.selectedID == id else { return }
            for member in self.actionIDs(for: id) {
                await self.setRead(true, id: member)
            }
        }
    }

    /// Whether any listed message in `id`'s conversation is unread.
    func isUnread(_ id: String?) -> Bool {
        guard let id else { return false }
        let members = Set(actionIDs(for: id))
        return messages.contains { members.contains($0.id) && $0.isUnread }
    }

    /// Reads the whole conversation, or marks just its newest listed message unread.
    func toggleRead(id: String?) {
        guard let id else { return }
        if memberIDs(of: id).contains(selectedID ?? "") {
            markReadTask?.cancel()
        }
        if isUnread(id) {
            let members = actionIDs(for: id)
            Task { for member in members { await setRead(true, id: member) } }
        } else {
            let single = actionIDs(for: id).count == 1 && !showsConversation && id == selectedID
            let newest = single ? id : rows.first(where: { $0.memberIDs.contains(id) })?.latest.id ?? id
            Task { await setRead(false, id: newest) }
        }
    }

    private func setRead(_ read: Bool, id: String) async {
        guard let index = messages.firstIndex(where: { $0.id == id }), messages[index].isUnread == read else { return }
        setUnreadLocally(id, unread: !read)
        do {
            try await provider().modify(id: id, action: read ? .markRead : .markUnread, label: nil)
            appState?.adjustUnseen(accountID: accountID, folder: folder, delta: read ? -1 : 1)
        } catch {
            setUnreadLocally(id, unread: read)
            actionError = error.localizedDescription
        }
    }

    private func setUnreadLocally(_ id: String, unread: Bool) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].isUnread = unread
        }
        if linked?.id == id {
            linked?.isUnread = unread
        }
        if openMessage?.id == id {
            openMessage?.isUnread = unread
        }
    }

    // MARK: - Triage

    /// Archives, trashes or moves every listed message in `id`'s conversation, then opens the next row.
    func remove(id: String?, _ removal: Removal) {
        guard let id else { return }
        let members = actionIDs(for: id)
        let rowIndex = rows.firstIndex { !Set($0.memberIDs).isDisjoint(with: members) }
        let wasOpen = selectedID.map { selected in members.contains(selected) || key(of: selected) == key(of: id) } ?? false
        for member in members {
            removeMessage(id: member, removal)
        }
        if wasOpen {
            let next = rowIndex.flatMap { rows.indices.contains($0) ? rows[$0].id : rows.last?.id }
            select(nil)
            selectRow(next)
        }
    }

    private func removeMessage(id: String, _ removal: Removal) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let removed = messages[index]
        if linked?.id == id { linked = nil }
        pendingRemovals.insert(id)
        messages.remove(at: index)
        let removeLabels = labelsToRemoveOnMove()
        Task { [weak self] in
            guard let self else { return }
            defer { self.pendingRemovals.remove(id) }
            do {
                let mail = try self.provider()
                switch removal {
                case .archive:
                    try await mail.modify(id: id, action: .archive, label: nil)
                case .trash:
                    try await mail.modify(id: id, action: .trash, label: nil)
                case .move(let destination):
                    try await mail.fileMessage(id: id, folder: destination, addLabels: [], removeLabels: removeLabels)
                }
                if removed.isUnread {
                    self.appState?.adjustUnseen(accountID: self.accountID, folder: self.folder, delta: -1)
                    if case .move(let destination) = removal {
                        self.appState?.adjustUnseen(accountID: self.accountID, folder: destination, delta: 1)
                    }
                }
            } catch {
                self.messages = Self.sorted(self.messages + [removed])
                self.actionError = error.localizedDescription
            }
        }
    }

    /// Gmail "move" only adds a label, so leaving a user label has to drop it explicitly.
    private func labelsToRemoveOnMove() -> [String] {
        guard account?.provider == .gmail,
              folderKind == .other,
              !ReaderFolders.gmailSystemLabels.contains(folder.uppercased()) else { return [] }
        return [folder]
    }

    // MARK: - Remote content

    func allowsRemoteContent(for message: MailMessage) -> Bool {
        if remoteAllowedMessageIDs.contains(message.id) { return true }
        let sender = MailDisplayFormat.address(message.from).email.lowercased()
        return account?.trustedImageSenders.contains(sender) ?? false
    }

    func loadRemoteContent(for message: MailMessage) {
        remoteAllowedMessageIDs.insert(message.id)
    }

    func trustSender(of message: MailMessage) {
        let sender = MailDisplayFormat.address(message.from).email.lowercased()
        guard !sender.isEmpty else { return }
        appState?.updateAccountSync(accountID: accountID) { account in
            if !account.trustedImageSenders.contains(sender) {
                account.trustedImageSenders.append(sender)
            }
        }
    }

    // MARK: - Attachments

    /// Attachments are only written where the user chooses; MailMCP keeps no copy (docs/sync-retention.md).
    func saveAttachment(_ attachment: MailAttachmentMeta, in message: MailMessage) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.safeFilename(attachment.filename)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.writeAttachment(attachment, messageID: message.id, to: url)
            } catch {
                self.actionError = error.localizedDescription
            }
        }
    }

    private func writeAttachment(_ attachment: MailAttachmentMeta, messageID: String, to url: URL) async throws {
        let payload = try await provider().getAttachment(messageID: messageID, attachmentID: attachment.id)
        var base64 = payload.dataBase64
        if base64.count % 4 != 0 {
            base64 += String(repeating: "=", count: 4 - base64.count % 4)
        }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            throw MailMCPError.invalidInput("The attachment “\(attachment.filename)” could not be decoded.")
        }
        try data.write(to: url, options: .atomic)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineAgentNameKey as String: "MailMCP"
        ]
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    private static func safeFilename(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "attachment" + cleaned : cleaned
    }
}

struct MailboxReaderView: View {
    @EnvironmentObject private var appState: AppState
    let account: MailAccount
    let folder: String
    @StateObject private var model: MailboxReaderModel
    @AppStorage("reader.listColumnWidth") private var listWidth: Double = 340

    private static let listRange: ClosedRange<Double> = 240...600
    private static let readerMinWidth: Double = 300

    init(account: MailAccount, folder: String) {
        self.account = account
        self.folder = folder
        _model = StateObject(wrappedValue: MailboxReaderModel(accountID: account.id, folder: folder))
    }

    var body: some View {
        GeometryReader { geometry in
            let available = Double(geometry.size.width) - Double(ColumnResizeHandle.hitWidth)
            let width = max(Self.listRange.lowerBound, min(listWidth, available - Self.readerMinWidth))
            HStack(spacing: 0) {
                MessageListPane(model: model)
                    .frame(width: width)
                ColumnResizeHandle(width: $listWidth, range: Self.listRange)
                MessageReadingPane(model: model)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .navigationTitle(ReaderFolders.title(for: folder))
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search \(ReaderFolders.title(for: folder))")
        .onSubmit(of: .search) { model.refresh() }
        .onChange(of: model.searchText) { _, _ in model.searchTextChanged() }
        .onChange(of: appState.cacheRevision) { _, _ in model.cacheDidChange() }
        .onChange(of: appState.messageOpenRequest) { _, _ in consumeOpenRequest() }
        .onAppear {
            model.start(appState: appState)
            consumeOpenRequest()
        }
        .onDisappear { model.stop() }
        .toolbar { toolbarContent }
        .alert(
            "Couldn’t complete that",
            isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    private func consumeOpenRequest() {
        guard let request = appState.messageOpenRequest,
              request.accountID == account.id, request.folder == folder else { return }
        appState.messageOpenRequest = nil
        model.openLinked(request)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.refresh()
            } label: {
                Label("Get Mail", systemImage: "arrow.clockwise")
            }
            .help("Check for new mail")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isRefreshing)

            Button {
                model.remove(id: model.selectedID, .archive)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .help("Archive")
            .keyboardShortcut("a", modifiers: [.control, .command])
            .disabled(model.selectedSummary == nil || !model.canArchive)

            Button {
                model.remove(id: model.selectedID, .trash)
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .help("Move to Trash")
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.selectedSummary == nil || !model.canTrash)

            Button {
                model.toggleRead(id: model.selectedID)
            } label: {
                if model.isUnread(model.selectedID) {
                    Label("Mark as Read", systemImage: "envelope.open")
                } else {
                    Label("Mark as Unread", systemImage: "envelope.badge")
                }
            }
            .help(model.isUnread(model.selectedID) ? "Mark as Read" : "Mark as Unread")
            .keyboardShortcut("u", modifiers: [.shift, .command])
            .disabled(model.selectedSummary == nil)

            Menu {
                ForEach(model.moveDestinations()) { destination in
                    Button {
                        model.remove(id: model.selectedID, .move(destination.name))
                    } label: {
                        Label(destination.title, systemImage: destination.systemImage)
                    }
                }
            } label: {
                Label("Move to", systemImage: "folder")
            }
            .help("Move to folder")
            .disabled(model.selectedSummary == nil)
        }
    }
}

private struct MessageListPane: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: MailboxReaderModel

    var body: some View {
        Group {
            if model.messages.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    messageList
                        .onChange(of: model.scrollToTopRequest) { _, _ in
                            guard let first = model.rows.first?.id else { return }
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                                proxy.scrollTo(first, anchor: .top)
                            }
                        }
                        .onChange(of: model.pendingReveal) { _, _ in reveal(proxy) }
                        .onAppear { reveal(proxy) }
                }
            }
        }
        .overlay(alignment: .top) {
            banner
                .padding(.top, 8)
                .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: bannerKey)
        }
        .safeAreaInset(edge: .bottom) {
            if let error = model.listError, !model.messages.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .lineLimit(2)
                    Spacer()
                    Button("Retry") { model.refresh() }
                }
                .font(.caption)
                .padding(8)
                .background(.bar)
            }
        }
    }

    private var syncText: String? {
        guard let account = model.account, appState.isSyncingCache(for: account) else { return nil }
        return appState.syncProgressMessage(for: account) ?? "Syncing…"
    }

    private var bannerKey: String {
        if !model.incoming.isEmpty { return "new\(model.incoming.count)" }
        if let syncText { return "sync:\(syncText)" }
        return model.isRefreshing && !model.messages.isEmpty ? "refresh" : "none"
    }

    @ViewBuilder
    private var banner: some View {
        if !model.incoming.isEmpty {
            NewMailPill(messages: model.incoming) { model.showIncoming() }
                .transition(.move(edge: .top).combined(with: .opacity))
        } else if let syncText {
            StatusPill(text: syncText)
                .transition(.move(edge: .top).combined(with: .opacity))
        } else if model.isRefreshing && !model.messages.isEmpty {
            StatusPill(text: "Checking for new mail…")
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var messageList: some View {
        List(selection: selection) {
                    ForEach(model.rows) { row in
                        MessageRow(
                            row: row,
                            showsRecipients: model.showsRecipients,
                            isExpanded: model.expandedKeys.contains(row.key),
                            toggle: { model.toggleExpanded(row) }
                        )
                        .tag(row.id as String?)
                        .listRowBackground(
                            model.freshIDs.contains(row.id) ? Color.accentColor.opacity(0.14) : Color.clear
                        )
                        .contextMenu { rowMenu(row.latest) }
                        if model.expandedKeys.contains(row.key) {
                            ForEach(model.children(of: row)) { child in
                                ConversationChildRow(message: child, folder: model.folder, ownAddress: model.account?.email)
                                    .tag(Self.childTag(child.id) as String?)
                                    .id(Self.childTag(child.id))
                                    .contextMenu { rowMenu(child) }
                            }
                        }
                    }
                    if !model.reachedEnd {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        }
                        .onAppear { model.loadMore() }
                    }
                }
                .listStyle(.inset)
                .onDeleteCommand {
                    if model.canTrash { model.remove(id: model.selectedID, .trash) }
                }
    }

    private static let childPrefix = "child|"

    /// Scrolls a linked message's row into view once the list has laid it out.
    private func reveal(_ proxy: ScrollViewProxy) {
        guard model.pendingReveal else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let target = selection.wrappedValue {
                proxy.scrollTo(target, anchor: .center)
            }
            model.pendingReveal = false
        }
    }

    private static func childTag(_ id: String) -> String { childPrefix + id }

    /// Conversation rows select the whole conversation; rows under an expanded conversation select one message.
    private var selection: Binding<String?> {
        Binding(
            get: {
                guard let id = model.selectedID, let row = model.selectedRow else { return nil }
                if !model.showsConversation, model.expandedKeys.contains(row.key) { return Self.childTag(id) }
                return row.id
            },
            set: { value in
                if let value, value.hasPrefix(Self.childPrefix) {
                    model.selectSingle(String(value.dropFirst(Self.childPrefix.count)))
                } else {
                    model.selectRow(value)
                }
            }
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isRefreshing && !model.hasLoadedOnce {
            ProgressView("Loading messages…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.listError {
            ContentUnavailableView {
                Label("Couldn’t load messages", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { model.refresh() }
            }
        } else if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            ContentUnavailableView("No Messages", systemImage: "tray")
        }
    }

    @ViewBuilder
    private func rowMenu(_ message: MailSummary) -> some View {
        Button(model.isUnread(message.id) ? "Mark as Read" : "Mark as Unread") {
            model.toggleRead(id: message.id)
        }
        Button("Copy Link") { model.copyLink(id: message.id) }
        Divider()
        if model.canArchive {
            Button("Archive") { model.remove(id: message.id, .archive) }
        }
        if model.canTrash {
            Button("Move to Trash") { model.remove(id: message.id, .trash) }
        }
        let destinations = model.moveDestinations()
        if !destinations.isEmpty {
            Menu("Move to") {
                ForEach(destinations) { destination in
                    Button(destination.title) { model.remove(id: message.id, .move(destination.name)) }
                }
            }
        }
    }
}

/// Apple Mail–style row: the newest message's sender, date and subject, with a count badge that expands the
/// conversation in place.
private struct MessageRow: View {
    let row: ConversationRow
    let showsRecipients: Bool
    let isExpanded: Bool
    let toggle: () -> Void

    private var message: MailSummary { row.latest }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(row.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(correspondent)
                        .fontWeight(row.isUnread ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(MailDisplayFormat.listDate(message.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if row.count > 1 {
                        countBadge
                    }
                }
                if !snippet.isEmpty {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var countBadge: some View {
        Button(action: toggle) {
            HStack(spacing: 2) {
                Text("\(row.count)")
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide the messages in this conversation" : "Show the \(row.count) messages in this conversation")
        .accessibilityLabel("\(row.count) messages")
    }

    private var correspondent: String {
        if showsRecipients {
            let names = message.to.map { MailDisplayFormat.address($0).name }
            return names.isEmpty ? "(no recipients)" : "To: " + names.joined(separator: ", ")
        }
        let name = MailDisplayFormat.address(message.from).name
        return name.isEmpty ? "(unknown sender)" : name
    }

    private var snippet: String {
        MailDisplayFormat.preview(snippet: message.snippet, subject: message.subject)
    }
}

/// One message under an expanded conversation row; mail filed elsewhere (e.g. your reply in Sent) names its folder.
private struct ConversationChildRow: View {
    let message: MailSummary
    let folder: String
    let ownAddress: String?

    var body: some View {
        let sender = MailDisplayFormat.address(message.from)
        let isOwn = sender.email.caseInsensitiveCompare(ownAddress ?? "") == .orderedSame
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(message.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 6, height: 6)
            Text(isOwn ? "Me" : sender.name)
                .fontWeight(message.isUnread ? .semibold : .regular)
                .lineLimit(1)
            if let mailbox = message.mailbox, mailbox.caseInsensitiveCompare(folder) != .orderedSame {
                Text(ReaderFolders.title(for: mailbox))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(MailDisplayFormat.listDate(message.date))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.leading, 22)
        .padding(.vertical, 1)
    }
}

private struct MessageReadingPane: View {
    @ObservedObject var model: MailboxReaderModel

    var body: some View {
        if model.showsConversation, model.conversation.count > 1 {
            StackedConversationView(model: model)
        } else if let message = model.openMessage {
            MessageDetail(message: message, model: model)
                .opacity(model.isLoadingSlowly ? 0.35 : 1)
                .overlay {
                    if model.isLoadingSlowly {
                        ProgressView()
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: model.isLoadingSlowly)
        } else if model.isLoadingMessage {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.messageError {
            ContentUnavailableView("Couldn’t open this message", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ContentUnavailableView("No Message Selected", systemImage: "envelope")
        }
    }
}

/// Apple Mail–style conversation: every message on its own sheet, newest at the top, in one scroll.
private struct StackedConversationView: View {
    @ObservedObject var model: MailboxReaderModel
    @State private var showsAll = false

    private static let initialCount = 10

    var body: some View {
        let newestFirst = Array(model.conversation.reversed())
        let shown = showsAll ? newestFirst : Array(newestFirst.prefix(Self.initialCount))
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(shown) { summary in
                        Group {
                            if let message = model.conversationBodies[summary.id] {
                                MessageDetail(message: message, model: model, stacked: true)
                            } else {
                                loadingSheet(summary)
                            }
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8).stroke(
                                summary.id == model.focusedMessageID ? Color.accentColor : Color.primary.opacity(0.08),
                                lineWidth: summary.id == model.focusedMessageID ? 2 : 1
                            )
                        )
                        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                        .id(summary.id)
                        .onAppear { model.loadConversationBody(summary.id) }
                    }
                    if shown.count < newestFirst.count {
                        Button("Show \(newestFirst.count - shown.count) Earlier Messages") { showsAll = true }
                            .buttonStyle(.link)
                            .padding(.vertical, 4)
                    }
                }
                .padding(12)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .onChange(of: model.conversation.first?.id) { _, _ in showsAll = false }
            .onChange(of: model.focusedMessageID) { _, _ in focus(proxy) }
            .onAppear { focus(proxy) }
        }
    }

    /// Brings the linked message's sheet to the top; scrolls again once the bodies above it have sized themselves.
    private func focus(_ proxy: ScrollViewProxy) {
        guard let id = model.focusedMessageID else { return }
        let newestFirst = model.conversation.reversed().map(\.id)
        if let index = newestFirst.firstIndex(of: id), index >= Self.initialCount { showsAll = true }
        Task { @MainActor in
            for delay: UInt64 in [50_000_000, 700_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                guard model.focusedMessageID == id else { return }
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }

    private func loadingSheet(_ summary: MailSummary) -> some View {
        let sender = MailDisplayFormat.address(summary.from)
        return HStack(alignment: .top, spacing: 10) {
            SenderAvatar(name: sender.name, email: sender.email)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(sender.name).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(summary.date?.formatted(date: .abbreviated, time: .shortened) ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(MailDisplayFormat.preview(snippet: summary.snippet, subject: summary.subject))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            ProgressView().controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MessageDetail: View {
    let message: MailMessage
    @ObservedObject var model: MailboxReaderModel
    /// One sheet in the conversation view: the subject moves under the sender and the body grows to fit instead of scrolling.
    var stacked = false
    @State private var linkCopied = false
    @State private var bodyHeight: CGFloat = 80
    @State private var showsQuoted = false

    var body: some View {
        let allowRemote = model.allowsRemoteContent(for: message)
        VStack(spacing: 0) {
            header
                .padding(stacked ? 14 : 16)
            if !allowRemote, let html = message.bodyHTML, MailBodyDocument.hasRemoteContent(html) {
                remoteContentBanner
            }
            Divider()
            if stacked {
                let quoted = MailBodyDocument.hasQuotedHistory(message)
                MailHTMLView(
                    html: MailBodyDocument.html(for: message, allowRemoteContent: allowRemote, hidingQuotes: !showsQuoted),
                    allowRemoteContent: allowRemote,
                    onContentHeight: { bodyHeight = max($0, 40) }
                )
                .frame(height: bodyHeight)
                if quoted {
                    quotedToggle
                }
            } else {
                MailHTMLView(
                    html: MailBodyDocument.html(for: message, allowRemoteContent: allowRemote),
                    allowRemoteContent: allowRemote
                )
            }
        }
    }

    private var header: some View {
        let sender = MailDisplayFormat.address(message.from)
        return VStack(alignment: .leading, spacing: 10) {
            if !stacked {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    copyLinkButton
                }
            }
            HStack(alignment: .top, spacing: 10) {
                SenderAvatar(name: sender.name, email: sender.email)
                VStack(alignment: .leading, spacing: 2) {
                    senderLines(sender)
                    if stacked {
                        Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                            .font(.callout)
                            .lineLimit(2)
                    }
                    if !message.to.isEmpty {
                        recipientLine("To", message.to)
                    }
                    if !message.cc.isEmpty {
                        recipientLine("Cc", message.cc)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                if stacked { copyLinkButton }
            }
            if !message.attachments.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(message.attachments) { attachment in
                        attachmentChip(attachment)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var copyLinkButton: some View {
        Button {
            model.copyLink(id: message.id)
            linkCopied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                linkCopied = false
            }
        } label: {
            Label(linkCopied ? "Copied" : "Copy Link", systemImage: linkCopied ? "checkmark" : "link")
                .labelStyle(.iconOnly)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help("Copy a mailmcp:// link that opens this message")
        .accessibilityLabel(linkCopied ? "Link copied" : "Copy link to this message")
    }

    /// Widest layout that fits: name, address and date on one line; then the date beside the name; then one line each, with the address truncating first.
    private func senderLines(_ sender: (name: String, email: String)) -> some View {
        let showsEmail = sender.name != sender.email
        let name = Text(sender.name).fontWeight(.semibold)
        let email = Text(sender.email).foregroundStyle(.secondary)
        let date = Text(message.date?.formatted(date: .abbreviated, time: .shortened) ?? "")
            .font(.caption)
            .foregroundStyle(.secondary)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                name
                if showsEmail { email }
                Spacer(minLength: 8)
                date
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    name
                    Spacer(minLength: 8)
                    date
                }
                if showsEmail { email.lineLimit(1).truncationMode(.middle) }
            }
            VStack(alignment: .leading, spacing: 2) {
                name.lineLimit(1)
                if showsEmail { email.lineLimit(1).truncationMode(.middle) }
                date
            }
        }
        .help(showsEmail ? "\(sender.name) <\(sender.email)>" : sender.email)
    }

    private func recipientLine(_ label: String, _ addresses: [String]) -> some View {
        Text("\(label): " + addresses.map { MailDisplayFormat.address($0).name }.joined(separator: ", "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .help(addresses.joined(separator: ", "))
    }

    private func attachmentChip(_ attachment: MailAttachmentMeta) -> some View {
        Button {
            model.saveAttachment(attachment, in: message)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle")
                Text(attachment.filename)
                    .lineLimit(1)
                if let size = attachment.size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .buttonStyle(.bordered)
        .help("Save \(attachment.filename) to a folder you choose")
    }

    /// Earlier messages quoted in a reply stay folded away, since the conversation shows them as their own sheets.
    private var quotedToggle: some View {
        Button {
            showsQuoted.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Text(showsQuoted ? "Hide Quoted Text" : "Show Quoted Text")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showsQuoted ? "Hide the earlier messages quoted in this reply" : "Show the earlier messages quoted in this reply")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var remoteContentBanner: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                remoteContentNotice
                    .frame(minWidth: 220, idealWidth: 300, maxWidth: .infinity, alignment: .leading)
                remoteContentButtons
            }
            VStack(alignment: .leading, spacing: 6) {
                remoteContentNotice
                HStack(spacing: 8) {
                    remoteContentButtons
                }
                .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12))
    }

    private var remoteContentNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text("Remote images are blocked so the sender can’t tell when you open this message.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var remoteContentButtons: some View {
        Button("Load Images") { model.loadRemoteContent(for: message) }
            .controlSize(.small)
            .fixedSize()
        Button("Always from Sender") { model.trustSender(of: message) }
            .controlSize(.small)
            .fixedSize()
            .help("Always load remote images from \(MailDisplayFormat.address(message.from).email)")
    }
}

/// Twitter-style "new posts" pill: avatars of the newest senders plus a count.
private struct NewMailPill: View {
    let messages: [MailSummary]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HStack(spacing: -7) {
                    ForEach(Array(messages.prefix(3).enumerated()), id: \.offset) { _, message in
                        let sender = MailDisplayFormat.address(message.from)
                        SenderAvatar(name: sender.name, email: sender.email, size: 22)
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                    }
                }
                Text("↑ \(messages.count) new message\(messages.count == 1 ? "" : "s")")
                    .font(.callout.weight(.semibold))
            }
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 7, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show new messages")
        .accessibilityLabel("Show \(messages.count) new message\(messages.count == 1 ? "" : "s")")
    }
}

/// Neutral, non-interactive pill for sync progress.
private struct StatusPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini)
            Text(text)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}

private struct SenderAvatar: View {
    let name: String
    let email: String
    var size: CGFloat = 34

    var body: some View {
        Text(MailDisplayFormat.initials(name))
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color.gradient))
    }

    private var color: Color {
        let palette: [Color] = [.blue, .teal, .green, .orange, .pink, .purple, .indigo, .brown]
        let sum = email.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }
}
