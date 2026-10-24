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

    @Published private(set) var messages: [MailSummary] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var openMessage: MailMessage?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var isLoadingMessage = false
    @Published private(set) var reachedEnd = false
    @Published private(set) var hasLoadedOnce = false
    @Published private(set) var listError: String?
    @Published private(set) var messageError: String?
    @Published private(set) var remoteAllowedMessageIDs: Set<String> = []
    @Published var actionError: String?
    @Published var searchText = ""

    static let pageSize = 50
    private static let markReadDelayNs: UInt64 = 2_000_000_000

    private weak var appState: AppState?
    private var refreshTask: Task<Void, Never>?
    private var moreTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var markReadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var pendingRemovals: Set<String> = []
    private var started = false

    init(accountID: UUID, folder: String) {
        self.accountID = accountID
        self.folder = folder
    }

    var account: MailAccount? { appState?.account(id: accountID) }
    var folderKind: MailboxKind { MailboxMatcher.kind(ofName: folder) }
    var selectedSummary: MailSummary? { messages.first { $0.id == selectedID } }
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
        for task in [refreshTask, moreTask, messageTask, markReadTask, searchTask] {
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
        guard !reachedEnd, !isLoadingMore, !isRefreshing, let oldest = messages.last?.date else { return }
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
        let cached = cachedPage(limit: max(messages.count, Self.pageSize))
        if !cached.isEmpty, cached != messages {
            messages = cached
        }
    }

    private static func sorted(_ items: [MailSummary]) -> [MailSummary] {
        items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    // MARK: - Reading

    func select(_ id: String?) {
        guard id != selectedID else { return }
        selectedID = id
        markReadTask?.cancel()
        messageTask?.cancel()
        messageError = nil
        guard let id else {
            openMessage = nil
            isLoadingMessage = false
            return
        }
        openMessage = nil
        isLoadingMessage = true
        messageTask = Task { [weak self] in
            guard let self else { return }
            do {
                let message = try await self.provider().getMessage(id: id)
                try Task.checkCancellation()
                self.openMessage = message
                self.isLoadingMessage = false
                if self.messages.first(where: { $0.id == id })?.isUnread ?? message.isUnread {
                    self.scheduleMarkRead(id)
                }
            } catch {
                if Task.isCancelled { return }
                self.messageError = error.localizedDescription
                self.isLoadingMessage = false
            }
        }
    }

    private func scheduleMarkRead(_ id: String) {
        markReadTask?.cancel()
        markReadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.markReadDelayNs)
            guard let self, !Task.isCancelled, self.selectedID == id else { return }
            await self.setRead(true, id: id)
        }
    }

    func isUnread(_ id: String?) -> Bool {
        guard let id else { return false }
        return messages.first { $0.id == id }?.isUnread ?? false
    }

    func toggleRead(id: String?) {
        guard let id else { return }
        if id == selectedID {
            markReadTask?.cancel()
        }
        let markRead = isUnread(id)
        Task { await setRead(markRead, id: id) }
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
        if openMessage?.id == id {
            openMessage?.isUnread = unread
        }
    }

    // MARK: - Triage

    func remove(id: String?, _ removal: Removal) {
        guard let id, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let removed = messages[index]
        pendingRemovals.insert(id)
        messages.remove(at: index)
        if selectedID == id {
            let next = messages.indices.contains(index) ? messages[index].id : messages.last?.id
            select(next)
        }
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

    func openAttachment(_ attachment: MailAttachmentMeta, in message: MailMessage) {
        let blocked: Set<String> = ["app", "command", "tool", "sh", "zsh", "bash", "terminal", "scpt", "applescript", "workflow", "pkg", "mpkg", "jar", "dmg"]
        let ext = (attachment.filename as NSString).pathExtension.lowercased()
        Task { [weak self] in
            guard let self else { return }
            do {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MailMCP Attachments", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(Self.safeFilename(attachment.filename))
                try await self.writeAttachment(attachment, messageID: message.id, to: url)
                if blocked.contains(ext) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                self.actionError = error.localizedDescription
            }
        }
    }

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
    let onOpenSettings: () -> Void
    @StateObject private var model: MailboxReaderModel
    @AppStorage("reader.listColumnWidth") private var listWidth: Double = 340

    private static let listRange: ClosedRange<Double> = 240...600
    private static let readerMinWidth: Double = 300

    init(account: MailAccount, folder: String, onOpenSettings: @escaping () -> Void) {
        self.account = account
        self.folder = folder
        self.onOpenSettings = onOpenSettings
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
        .navigationSubtitle(account.displayName.isEmpty ? account.email : account.displayName)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search \(ReaderFolders.title(for: folder))")
        .onSubmit(of: .search) { model.refresh() }
        .onChange(of: model.searchText) { _, _ in model.searchTextChanged() }
        .onChange(of: appState.cacheRevision) { _, _ in model.cacheDidChange() }
        .onAppear { model.start(appState: appState) }
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

            Button {
                onOpenSettings()
            } label: {
                Label("Mailbox Settings", systemImage: "info.circle")
            }
            .help("Mailbox settings and cache")
        }
    }
}

private struct MessageListPane: View {
    @ObservedObject var model: MailboxReaderModel

    var body: some View {
        Group {
            if model.messages.isEmpty {
                emptyState
            } else {
                List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    ForEach(model.messages) { message in
                        MessageRow(message: message, showsRecipients: model.showsRecipients)
                            .tag(message.id as String?)
                            .contextMenu { rowMenu(message) }
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
        }
        .overlay(alignment: .top) {
            if model.isRefreshing && !model.messages.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 6)
            }
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
        Button(message.isUnread ? "Mark as Read" : "Mark as Unread") {
            model.toggleRead(id: message.id)
        }
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

private struct MessageRow: View {
    let message: MailSummary
    let showsRecipients: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(message.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(correspondent)
                        .fontWeight(message.isUnread ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(MailDisplayFormat.listDate(message.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                    .font(.callout)
                    .lineLimit(1)
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

    private var correspondent: String {
        if showsRecipients {
            let names = message.to.map { MailDisplayFormat.address($0).name }
            return names.isEmpty ? "(no recipients)" : "To: " + names.joined(separator: ", ")
        }
        let name = MailDisplayFormat.address(message.from).name
        return name.isEmpty ? "(unknown sender)" : name
    }

    private var snippet: String {
        message.snippet
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct MessageReadingPane: View {
    @ObservedObject var model: MailboxReaderModel

    var body: some View {
        if let message = model.openMessage {
            MessageDetail(message: message, model: model)
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

private struct MessageDetail: View {
    let message: MailMessage
    @ObservedObject var model: MailboxReaderModel

    var body: some View {
        let allowRemote = model.allowsRemoteContent(for: message)
        VStack(spacing: 0) {
            header
                .padding(16)
            if !allowRemote, let html = message.bodyHTML, MailBodyDocument.hasRemoteContent(html) {
                remoteContentBanner
            }
            Divider()
            MailHTMLView(
                html: MailBodyDocument.html(for: message, allowRemoteContent: allowRemote),
                allowRemoteContent: allowRemote
            )
        }
    }

    private var header: some View {
        let sender = MailDisplayFormat.address(message.from)
        return VStack(alignment: .leading, spacing: 10) {
            Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                SenderAvatar(name: sender.name, email: sender.email)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(sender.name)
                            .fontWeight(.semibold)
                        if sender.name != sender.email {
                            Text(sender.email)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    if !message.to.isEmpty {
                        recipientLine("To", message.to)
                    }
                    if !message.cc.isEmpty {
                        recipientLine("Cc", message.cc)
                    }
                }
                .textSelection(.enabled)
                Spacer(minLength: 8)
                if let date = message.date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

    private func recipientLine(_ label: String, _ addresses: [String]) -> some View {
        Text("\(label): " + addresses.map { MailDisplayFormat.address($0).name }.joined(separator: ", "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .help(addresses.joined(separator: ", "))
    }

    private func attachmentChip(_ attachment: MailAttachmentMeta) -> some View {
        Button {
            model.openAttachment(attachment, in: message)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "paperclip")
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
        .help("Open \(attachment.filename)")
        .contextMenu {
            Button("Open") { model.openAttachment(attachment, in: message) }
            Button("Save…") { model.saveAttachment(attachment, in: message) }
        }
    }

    private var remoteContentBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)
            Text("Remote images are blocked so the sender can’t tell when you open this message.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Load Images") { model.loadRemoteContent(for: message) }
                .controlSize(.small)
            Button("Always from Sender") { model.trustSender(of: message) }
                .controlSize(.small)
                .help("Always load remote images from \(MailDisplayFormat.address(message.from).email)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.12))
    }
}

private struct SenderAvatar: View {
    let name: String
    let email: String

    var body: some View {
        Text(MailDisplayFormat.initials(name))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Circle().fill(color.gradient))
    }

    private var color: Color {
        let palette: [Color] = [.blue, .teal, .green, .orange, .pink, .purple, .indigo, .brown]
        let sum = email.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }
}
