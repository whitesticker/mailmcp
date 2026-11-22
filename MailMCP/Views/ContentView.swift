import AppKit
import SwiftUI

/// Configures the sidebar split item once. Re-applying constraints on every SwiftUI update caused AppKit layout-loop crashes.
private struct SidebarConfigurator: NSViewRepresentable {
    let minWidth: CGFloat
    let maxWidth: CGFloat

    final class Coordinator {
        var configured = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configure(from: view, coordinator: context.coordinator, attempts: 10)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func configure(from view: NSView, coordinator: Coordinator, attempts: Int) {
        DispatchQueue.main.async {
            guard !coordinator.configured else { return }
            var responder: NSResponder? = view
            while let current = responder {
                if let splitVC = current as? NSSplitViewController,
                   let firstItem = splitVC.splitViewItems.first {
                    coordinator.configured = true
                    for item in splitVC.splitViewItems.dropLast() {
                        item.canCollapse = false
                    }
                    firstItem.minimumThickness = minWidth
                    firstItem.maximumThickness = maxWidth
                    if let root = view.window?.contentView {
                        configureAutoHideScrollers(in: root)
                    }
                    return
                }
                responder = current.nextResponder
            }
            if attempts > 0 {
                configure(from: view, coordinator: coordinator, attempts: attempts - 1)
            }
        }
    }

    private func configureAutoHideScrollers(in view: NSView) {
        if let scrollView = view as? NSScrollView {
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.hasHorizontalScroller = false
        }
        for subview in view.subviews {
            configureAutoHideScrollers(in: subview)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selected: ContentSelection?
    @State private var settingsItem: SettingsItem = .pane(.safety)
    @State private var mailboxPane: MailboxPane?
    /// Folder to open once a change of `selected` lands; that change otherwise resets the pane to Inbox.
    @State private var pendingPane: MailboxPane?
    @State private var pendingID: UUID?
    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            VStack(spacing: 0) {
                ColumnTitle(text: "MailMCP")
                List(selection: $selected) {
                    if !appState.pendingSends.isEmpty {
                        Section("Needs confirmation") {
                            Text("\(appState.pendingSends.count) pending send\(appState.pendingSends.count == 1 ? "" : "s")")
                                .tag(ContentSelection.pending)
                        }
                    }
                    ForEach(appState.unlockedVaults) { vault in
                        Section(vault.name) {
                            ForEach(vault.accounts) { account in
                                mailboxRow(account)
                            }
                            .onMove { offsets, destination in
                                try? appState.moveAccounts(in: vault.id, fromOffsets: offsets, toOffset: destination)
                            }
                        }
                    }
                }
                Divider()
                List(selection: $selected) {
                    Label("Settings", systemImage: "gearshape")
                        .tag(ContentSelection.settings)
                }
                .scrollDisabled(true)
                .frame(height: 44)
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 255, max: 360)
            .background(SidebarConfigurator(minWidth: 220, maxWidth: 360))
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                // A window with no toolbar items drops its toolbar and shifts every column up, so this one is always present.
                ToolbarItem {
                    Button {
                        appState.lock()
                    } label: {
                        Label("Lock", systemImage: "lock")
                    }
                    .help("Lock all vaults")
                }
            }
        } content: {
            Group {
                switch selected {
                case .settings:
                    SettingsItemList(item: $settingsItem)
                case .pending:
                    PendingSendsList(selection: $pendingID)
                case .account(let id):
                    if let account = appState.account(id: id) {
                        MailboxFolderList(account: account, pane: $mailboxPane)
                    } else {
                        Color.clear
                    }
                case nil:
                    Color.clear
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 200, max: 320)
            .toolbar { ColumnToolbarTitle(title: middleColumnTitle) }
        } detail: {
            Group {
                switch selected {
                case .settings:
                    SettingsItemDetail(item: settingsItem)
                case .pending:
                    PendingSendDetail(selection: pendingID)
                case .account(let id):
                    if let account = appState.account(id: id) {
                        MailboxPaneDetail(account: account, pane: mailboxPane)
                    } else {
                        placeholder
                    }
                case nil:
                    placeholder
                }
            }
            .navigationSplitViewColumnWidth(min: 560, ideal: 800)
        }
        .toolbar(removing: .title)
        .onChange(of: selected) { _, newValue in
            if newValue != .settings {
                settingsItem = .pane(.safety)
            }
            mailboxPane = pendingPane
            pendingPane = nil
        }
        .onAppear {
            consumeSettingsRequest()
            openPendingMessageLink()
            showRequestedMessage()
        }
        .onChange(of: appState.pendingSettingsOpen) { _, _ in consumeSettingsRequest() }
        .onChange(of: appState.pendingMessageLink) { _, _ in openPendingMessageLink() }
        .onChange(of: appState.messageOpenRequest) { _, _ in showRequestedMessage() }
    }

    private func openPendingMessageLink() {
        guard appState.pendingMessageLink != nil else { return }
        Task { await appState.openPendingMessageLink() }
    }

    /// Selects the linked message's mailbox and folder; that folder's reader then picks up the request.
    private func showRequestedMessage() {
        guard let request = appState.messageOpenRequest else { return }
        let pane = MailboxPane.folder(request.folder)
        if selected == .account(request.accountID) {
            mailboxPane = pane
        } else {
            pendingPane = pane
            selected = .account(request.accountID)
        }
    }

    private var middleColumnTitle: String {
        switch selected {
        case .settings:
            return "Settings"
        case .pending:
            return "Needs Confirmation"
        case .account(let id):
            guard let account = appState.account(id: id) else { return "" }
            return account.displayName.isEmpty ? account.email : account.displayName
        case nil:
            return ""
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.open")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            if appState.unlockedVaults.flatMap(\.accounts).isEmpty {
                Text("Add a mailbox to get started.")
                    .foregroundStyle(.secondary)
                Button("Add an Account…") {
                    selected = .settings
                    settingsItem = .addAccount
                }
            } else {
                Text("Select a mailbox.")
                    .foregroundStyle(.secondary)
            }
            if let status = appState.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func consumeSettingsRequest() {
        guard appState.pendingSettingsOpen else { return }
        appState.pendingSettingsOpen = false
        selected = .settings
        if let pane = appState.pendingSettingsPane {
            appState.pendingSettingsPane = nil
            settingsItem = .pane(pane)
        }
    }

    private func mailboxRow(_ account: MailAccount) -> some View {
        let status = MailboxStatus(account: account, appState: appState)
        let hasNickname = !account.displayName.isEmpty && account.displayName != account.email
        return HStack(alignment: .center, spacing: 8) {
            MailboxStatusIndicator(status: status)
            VStack(alignment: .leading, spacing: 2) {
                Text(hasNickname ? account.displayName : account.email)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if hasNickname {
                    Text(account.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .help("\(status.kindHelp) · \(status.text)")
        .tag(ContentSelection.account(account.id))
    }
}

/// The middle column's title, shown in the toolbar strip above it. It also keeps the toolbar split at that column's
/// edge: SwiftUI only splits there when the column has an item of its own, otherwise the detail buttons drift left.
struct ColumnToolbarTitle: ToolbarContent {
    let title: String

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            item.sharedBackgroundVisibility(.hidden)
        } else {
            item
        }
    }

    private var item: some ToolbarContent {
        ToolbarItem {
            Text(title.isEmpty ? " " : title)
                .font(.largeTitle.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.tail)
                .frame(maxWidth: 260, alignment: .leading)
                .padding(.leading, 6)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// Large bold column heading, like the sidebar title in macOS system apps.
struct ColumnTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.largeTitle.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }
}

/// Sync/cache state of a mailbox, shared by the sidebar dot and the mailbox card.
struct MailboxStatus {
    enum Kind { case syncing, error, cached, lazy, notSynced }

    let kind: Kind
    /// One entry per stat, shown on its own line in the mailbox card.
    let lines: [String]
    let badge: (title: String, prominent: Bool)?

    var text: String { lines.joined(separator: " · ") }

    var badgeHelp: String? {
        switch badge?.title {
        case "LAZY": return "Lazy: nothing syncs in the background. Messages you or an agent open are kept on this Mac."
        case "AUTO": return "Auto: recent Inbox mail syncs to this Mac on a schedule."
        case "SYNC": return "Manual: recent Inbox mail syncs to this Mac when you press Sync now."
        case "FULL": return "Full: every folder syncs to this Mac in the background."
        default: return nil
        }
    }

    var kindHelp: String {
        switch kind {
        case .syncing: return "Syncing now"
        case .error: return "Red: the last connection to the server failed"
        case .cached: return "Green: cached on this Mac"
        case .lazy: return "Blue: lazy cache, nothing synced in the background"
        case .notSynced: return "Orange: not synced yet"
        }
    }

    static func help(forLine line: String) -> String? {
        if line.hasSuffix("header") || line.hasSuffix("headers") {
            return "Headers: messages whose sender, subject and date are stored on this Mac"
        }
        if line.hasSuffix("body") || line.hasSuffix("bodies") {
            return "Bodies: messages whose full text is stored too, so they open and search without the server"
        }
        return nil
    }

    @MainActor
    init(account: MailAccount, appState: AppState) {
        let stats = appState.cacheStats(for: account)
        let policy = appState.settings(for: account).cachePolicy.effective(for: account)
        switch account.syncScope {
        case .off: badge = ("LAZY", false)
        case .recent, .days: badge = (account.syncSchedule == .manual ? "SYNC" : "AUTO", true)
        case .everything: badge = ("FULL", true)
        }
        if appState.isSyncingCache(for: account) {
            kind = .syncing
            lines = [appState.syncProgressMessage(for: account) ?? "Syncing…"]
        } else if let error = account.lastError, !error.isEmpty {
            kind = .error
            lines = [error]
        } else if stats.envelopeCount > 0 || stats.lastSyncedAt != nil {
            kind = .cached
            var parts = ["\(stats.envelopeCount.formatted()) header\(stats.envelopeCount == 1 ? "" : "s")"]
            if stats.bodyCount > 0 {
                parts.append("\(stats.bodyCount.formatted()) bod\(stats.bodyCount == 1 ? "y" : "ies")")
            }
            if let synced = stats.lastSyncedAt {
                parts.append("Synced \(synced.formatted(date: .omitted, time: .shortened))")
            }
            lines = parts
        } else if policy.mode == .lazy {
            kind = .lazy
            lines = ["Lazy · caches what you or agents open"]
        } else {
            kind = .notSynced
            lines = ["Not synced yet"]
        }
    }

    var color: Color {
        switch kind {
        case .syncing: return .accentColor
        case .error: return .red
        case .cached: return .green
        case .lazy: return .blue.opacity(0.75)
        case .notSynced: return .orange.opacity(0.8)
        }
    }
}

struct MailboxStatusIndicator: View {
    let status: MailboxStatus

    var body: some View {
        Group {
            if status.kind == .syncing {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(status.color).frame(width: 8, height: 8)
            }
        }
        .frame(width: 12, height: 12)
    }
}

/// Summary card at the top of a mailbox's folder column.
private struct MailboxInfoCard: View {
    @EnvironmentObject private var appState: AppState
    let account: MailAccount

    var body: some View {
        let status = MailboxStatus(account: account, appState: appState)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                MailboxStatusIndicator(status: status)
                    .help(status.kindHelp)
                if let badge = status.badge {
                    Text(badge.title)
                        .font(.system(size: 9, weight: badge.prominent ? .semibold : .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((badge.prominent ? Color.accentColor : Color.secondary).opacity(0.15))
                        .foregroundStyle(badge.prominent ? Color.accentColor : Color.secondary)
                        .clipShape(Capsule())
                        .help(status.badgeHelp ?? "")
                }
                Text(account.provider.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ForEach(status.lines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(status.kind == .error ? Color.red : Color.secondary)
                    .lineLimit(status.kind == .error ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(MailboxStatus.help(forLine: line) ?? "")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

struct AccountDetailView: View {
    @EnvironmentObject private var appState: AppState
    let account: MailAccount
    @State private var busy = false
    @State private var result: String?
    @State private var showEditAccount = false
    @State private var nickname: String
    @State private var nicknameStatus: String?
    @State private var cacheNotice: String?
    @State private var confirmRemove = false

    init(account: MailAccount) {
        self.account = account
        _nickname = State(initialValue:
            account.displayName == account.email ? "" : account.displayName
        )
    }

    var body: some View {
        let stats = appState.cacheStats(for: account)
        let isSyncing = appState.isSyncingCache(for: account)
        let progressText = appState.syncProgressMessage(for: account)
        let effectivePolicy = appState.settings(for: account).cachePolicy.effective(for: account)

        Form {
            Section("Nickname") {
                TextField("Nickname (optional)", text: $nickname)
                HStack {
                    Button("Save nickname") {
                        saveNickname()
                    }
                    if let nicknameStatus {
                        Text(nicknameStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Account") {
                LabeledContent("Email", value: account.email)
                LabeledContent("Provider", value: account.provider.title)
                LabeledContent("Added", value: account.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let error = account.lastError, !error.isEmpty {
                    LabeledContent("Last error") {
                        Text(error).foregroundStyle(.red)
                    }
                }
                if let result {
                    Text(result)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                FlowLayout {
                    Button(busy ? "Testing…" : "Test connection") {
                        Task { await test() }
                    }
                    .disabled(busy)
                    Button("Modify account credentials…") {
                        showEditAccount = true
                    }
                    Menu("Copy to Vault") {
                        ForEach(otherVaults) { vault in
                            Button(vault.name) {
                                do {
                                    try appState.copyAccount(account.id, toVault: vault.id)
                                    result = "Copied to \(vault.name). The copy syncs on its own; this mailbox stays here."
                                } catch {
                                    result = error.localizedDescription
                                }
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(otherVaults.isEmpty)
                    .help(otherVaults.isEmpty ? "Unlock or create another vault to copy this mailbox into" : "Copy this mailbox and its sign-in to another unlocked vault")
                    Button("Remove account…", role: .destructive) {
                        confirmRemove = true
                    }
                }
                Text("Remove account deletes this mailbox’s sign-in from the vault and its cached mail from this Mac. Nothing changes on the server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Background Sync") {
                SyncMailboxRow(account: account, showsIdentity: false)
                if let cacheNotice {
                    Text(cacheNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                FlowLayout {
                    Button("Clear mailbox cache", role: .destructive) {
                        appState.clearMailboxCache(account: account)
                        cacheNotice = "Cleared cached messages and bodies for \(account.email)."
                    }
                    .disabled(isSyncing || (stats.envelopeCount == 0 && stats.bodyCount == 0 && stats.folderCount == 0))
                    Button("Sync Settings for All Mailboxes…") {
                        appState.openSettings(.sync)
                    }
                    .help("Settings › Sync lists every mailbox’s sync policy and schedule in one place")
                }
                Text("Clear mailbox cache deletes only this mailbox’s local copies. Mail stays on the server, and the next sync downloads it again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local Cache") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        if isSyncing {
                            ProgressView()
                                .controlSize(.small)
                            Text(progressText ?? "Syncing…")
                        } else if !effectivePolicy.cacheActive {
                            Circle()
                                .fill(Color.gray)
                                .frame(width: 8, height: 8)
                            Text("Not cached · requests go to server")
                                .foregroundStyle(.secondary)
                        } else if let progressText, !progressText.isEmpty {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 8, height: 8)
                            Text(progressText)
                                .foregroundStyle(.secondary)
                        } else if stats.envelopeCount > 0 || stats.lastSyncedAt != nil {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(syncedStatusText(stats: stats, now: context.date))
                            }
                        } else if effectivePolicy.mode == .lazy {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 8, height: 8)
                            Text("Lazy · caches what you or agents open")
                                .foregroundStyle(.secondary)
                        } else {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 8, height: 8)
                            Text("Not synced yet")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if effectivePolicy.mode == .fullSync && effectivePolicy.fullSyncBodies && stats.envelopeCount > 0 {
                    LabeledContent("Body mirror progress") {
                        HStack(spacing: 8) {
                            ProgressView(
                                value: Double(min(stats.bodyCount, stats.envelopeCount)),
                                total: Double(max(stats.envelopeCount, 1))
                            )
                            .frame(width: 120)
                            Text("\(stats.bodyCount) / \(stats.envelopeCount) (\(Int((Double(min(stats.bodyCount, stats.envelopeCount)) / Double(max(stats.envelopeCount, 1))) * 100))%)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Cached titles / headers", value: "\(stats.envelopeCount)")
                LabeledContent("Cached full bodies", value: "\(stats.bodyCount)")
                LabeledContent("Cached folders", value: "\(stats.folderCount)")
                LabeledContent("Today’s download usage") {
                    Text("\(ByteCountFormatter.string(fromByteCount: stats.dailyBandwidthBytes, countStyle: .file)) / \(effectivePolicy.dailyBandwidthCapMB) MB daily safety cap")
                        .foregroundStyle(.secondary)
                }
                if let oldest = stats.oldestMessageAt, let newest = stats.newestMessageAt {
                    LabeledContent("Cached date span") {
                        Text("\(oldest.formatted(date: .abbreviated, time: .omitted)) – \(newest.formatted(date: .abbreviated, time: .omitted))")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Last synced") {
                    if let synced = stats.lastSyncedAt {
                        Text("\(synced.formatted(date: .abbreviated, time: .shortened)) (\(RelativeDateTimeFormatter().localizedString(for: synced, relativeTo: Date())))")
                    } else {
                        Text("Never")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Last server check") {
                    if let checked = stats.lastCheckedAt {
                        Text(checked.formatted(date: .abbreviated, time: .standard))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(account.displayName.isEmpty ? account.email : account.displayName)
        .toolbar {
            ToolbarItem {
                Button {
                    cacheNotice = nil
                    Task { await appState.syncMailboxCacheNow(account: account) }
                } label: {
                    Label("Sync Now", systemImage: "arrow.clockwise")
                }
                .help(account.syncScope == .off ? "Background sync is off for this mailbox" : "Sync this mailbox now")
                .disabled(isSyncing || account.syncScope == .off)
            }
        }
        .onChange(of: account.id) { _, _ in
            result = nil
            busy = false
            nicknameStatus = nil
            cacheNotice = nil
            nickname = account.displayName == account.email ? "" : account.displayName
        }
        .onChange(of: account.displayName) { _, value in
            nickname = value == account.email ? "" : value
        }
        .confirmationDialog(
            "Remove \(account.email)?",
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button("Remove Account", role: .destructive) {
                try? appState.removeAccount(account.id)
            }
        } message: {
            Text("Its sign-in is deleted from this vault and its cached mail from this Mac. Mail on the server is not touched. You can add the account again later.")
        }
        .sheet(isPresented: $showEditAccount) {
            AddAccountView(editingAccount: account)
                .environmentObject(appState)
                .frame(minWidth: 560, minHeight: 500)
        }
    }

    private var otherVaults: [UnlockedVaultSummary] {
        appState.unlockedVaults.filter { vault in
            !vault.accounts.contains {
                $0.provider == account.provider && $0.email.caseInsensitiveCompare(account.email) == .orderedSame
            }
        }
    }

    private func syncedStatusText(stats: AccountCacheStats, now: Date) -> String {
        guard let checked = stats.lastCheckedAt ?? stats.lastSyncedAt else { return "Synced" }
        if now.timeIntervalSince(checked) < 60 {
            return "Synced · checked just now"
        }
        return "Synced · checked \(RelativeDateTimeFormatter().localizedString(for: checked, relativeTo: now))"
    }

    private func saveNickname() {
        do {
            var updated = account
            updated.displayName = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            try appState.updateAccount(updated)
            nicknameStatus = "Saved"
        } catch {
            nicknameStatus = error.localizedDescription
        }
    }

    private func test() async {
        busy = true
        defer { busy = false }
        do {
            let mail = try appState.provider(for: account)
            let message = try await mail.testConnection()
            result = message
            appState.setAccountError(accountID: account.id, message: nil)
        } catch {
            result = error.localizedDescription
            appState.setAccountError(accountID: account.id, message: error.localizedDescription)
        }
    }
}

enum ContentSelection: Hashable {
    case settings
    case pending
    case account(UUID)
}

/// The folder column for one mailbox, followed by either the reader (message list and message) or the mailbox's settings.
enum MailboxPane: Hashable {
    case folder(String)
    case settings

    static func resolved(_ pane: MailboxPane?, folders: [MailFolderCount]) -> MailboxPane {
        pane ?? .folder(ReaderFolders.inboxName(in: folders))
    }
}

/// A mailbox's folders, shown in the window's middle column.
struct MailboxFolderList: View {
    @EnvironmentObject private var appState: AppState
    let account: MailAccount
    @Binding var pane: MailboxPane?

    var body: some View {
        let current = MailboxPane.resolved(pane, folders: appState.mailFolders(for: account))
        let folders = ReaderFolders.visible(appState.mailFolders(for: account))
        VStack(spacing: 0) {
            MailboxInfoCard(account: account)
                .padding(.top, 6)
            List(selection: Binding(get: { current }, set: { pane = $0 })) {
                Section {
                    Label("Mailbox Settings", systemImage: "gearshape")
                        .tag(MailboxPane.settings)
                }
                Section("Folders") {
                    if folders.isEmpty {
                        Label("Inbox", systemImage: "tray")
                            .tag(MailboxPane.folder("INBOX"))
                    }
                    ForEach(folders) { folder in
                        Label(folder.title, systemImage: folder.systemImage)
                            .lineLimit(1)
                            .badge(showsBadge(folder) ? (folder.unseen ?? 0) : 0)
                            .help(folderHelp(folder))
                            .tag(MailboxPane.folder(folder.name))
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { appState.refreshFolders(for: account) }
        .onChange(of: account.id) { _, _ in appState.refreshFolders(for: account) }
    }

    private func folderHelp(_ folder: ReaderFolder) -> String {
        guard showsBadge(folder), let unseen = folder.unseen, unseen > 0 else { return folder.title }
        return "\(folder.title): \(unseen.formatted()) unread"
    }

    private func showsBadge(_ folder: ReaderFolder) -> Bool {
        folder.kind == .inbox || folder.kind == .other || folder.kind == .spam
    }
}

/// The open folder (message list and reader) or the mailbox's settings, shown in the window's detail column.
struct MailboxPaneDetail: View {
    @EnvironmentObject private var appState: AppState
    let account: MailAccount
    let pane: MailboxPane?

    var body: some View {
        switch MailboxPane.resolved(pane, folders: appState.mailFolders(for: account)) {
        case .settings:
            AccountDetailView(account: account)
        case .folder(let name):
            MailboxReaderView(account: account, folder: name)
                .id("\(account.id)|\(name)")
        }
    }
}
