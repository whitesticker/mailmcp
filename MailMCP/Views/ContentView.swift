import AppKit
import SwiftUI

private struct SidebarWidthLocker: NSViewRepresentable {
    let width: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            lockSplitView(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            lockSplitView(from: nsView)
        }
    }

    private func lockSplitView(from view: NSView) {
        var responder: NSResponder? = view
        while let current = responder {
            if let splitVC = current as? NSSplitViewController,
               let firstItem = splitVC.splitViewItems.first {
                firstItem.canCollapse = false
                firstItem.minimumThickness = width
                firstItem.maximumThickness = width
                firstItem.holdingPriority = .required
                configureAutoHideScrollers(in: firstItem.viewController.view)
                break
            }
            responder = current.nextResponder
        }
        if let root = view.window?.contentView {
            configureAutoHideScrollers(in: root)
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
    @State private var showAddAccount = false
    @State private var showAddVault = false

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            VStack(spacing: 0) {
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
                .navigationTitle("Mailboxes")
                Divider()
                List(selection: $selected) {
                    Button {
                        showAddAccount = true
                    } label: {
                        Label("Add an Account", systemImage: "envelope.badge.plus")
                    }
                    .buttonStyle(.plain)
                    Button {
                        showAddVault = true
                    } label: {
                        Label("Add vault", systemImage: "externaldrive.badge.plus")
                    }
                    .buttonStyle(.plain)
                    Label("Add to an agent", systemImage: "puzzlepiece.extension")
                        .tag(ContentSelection.agents)
                    Label("Tool history", systemImage: "clock.arrow.circlepath")
                        .tag(ContentSelection.history)
                    Label("Settings", systemImage: "gearshape")
                        .tag(ContentSelection.settings)
                }
                .scrollDisabled(true)
                .frame(height: 208)
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 255, ideal: 255, max: 255)
            .background(SidebarWidthLocker(width: 255))
            .toolbar(removing: .sidebarToggle)
        } detail: {
            if selected == .agents {
                AgentsView()
            } else if selected == .history {
                ToolHistoryView()
            } else if selected == .settings {
                SettingsView()
            } else if selected == .pending {
                PendingSendsView()
            } else if case .account(let id) = selected, let account = appState.account(id: id) {
                AccountDetailView(account: account)
                    .id(account.id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "envelope.open")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(appState.unlockedVaults.flatMap(\.accounts).isEmpty ? "Add a mailbox to get started." : "Select a mailbox.")
                        .foregroundStyle(.secondary)
                    if let status = appState.statusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showAddAccount) {
            AddAccountView()
                .environmentObject(appState)
                .frame(minWidth: 520, minHeight: 420)
        }
        .sheet(isPresented: $showAddVault) {
            AddVaultView()
                .environmentObject(appState)
        }
    }

    private func mailboxRow(_ account: MailAccount) -> some View {
        let stats = appState.cacheStats(for: account)
        let isSyncing = appState.isSyncingCache(for: account)
        let progressText = appState.syncProgressMessage(for: account)
        let effectivePolicy = appState.settings(for: account).cachePolicy.effective(for: account)
        let cacheEnabled = effectivePolicy.cacheActive

        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(account.displayName.isEmpty ? account.email : account.displayName)
                        .font(.headline)
                    if let badge = sidebarSyncBadge(account, policy: effectivePolicy) {
                        Text(badge.title)
                            .font(.system(size: 9, weight: badge.prominent ? .semibold : .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background((badge.prominent ? Color.accentColor : Color.secondary).opacity(0.15))
                            .foregroundStyle(badge.prominent ? Color.accentColor : Color.secondary)
                            .clipShape(Capsule())
                    }
                }
                Text(account.displayName.isEmpty || account.displayName == account.email
                     ? account.provider.title
                     : "\(account.email) · \(account.provider.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    if isSyncing {
                        ProgressView()
                            .controlSize(.mini)
                        Text(progressText ?? "Syncing cache…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if !cacheEnabled {
                        Circle()
                            .fill(Color.gray.opacity(0.6))
                            .frame(width: 6, height: 6)
                        Text("Not cached · requests go to server")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else if stats.envelopeCount > 0 || stats.lastSyncedAt != nil {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text(sidebarCacheSummary(stats))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if effectivePolicy.mode == .lazy {
                        Circle()
                            .fill(Color.blue.opacity(0.75))
                            .frame(width: 6, height: 6)
                        Text("Lazy · caches on agent call")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Circle()
                            .fill(Color.orange.opacity(0.8))
                            .frame(width: 6, height: 6)
                        Text("Not synced yet")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = account.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tag(ContentSelection.account(account.id))
    }

    private func sidebarSyncBadge(_ account: MailAccount, policy: CacheSyncPolicy) -> (title: String, prominent: Bool)? {
        switch account.syncScope {
        case .off:
            return policy.lazyEnabled ? ("LAZY", false) : nil
        case .recent, .days:
            return (account.syncSchedule == .manual ? "SYNC" : "AUTO", true)
        case .everything:
            return ("FULL", true)
        }
    }

    private func sidebarCacheSummary(_ stats: AccountCacheStats) -> String {
        var parts: [String] = ["\(stats.envelopeCount) title\(stats.envelopeCount == 1 ? "" : "s")"]
        if stats.bodyCount > 0 {
            parts.append("\(stats.bodyCount) bod\(stats.bodyCount == 1 ? "y" : "ies")")
        }
        if let synced = stats.lastSyncedAt {
            parts.append(synced.formatted(date: .omitted, time: .shortened))
        }
        return parts.joined(separator: " · ")
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
        let globalPolicy = appState.settings(for: account).cachePolicy
        let effectivePolicy = globalPolicy.effective(for: account)

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
                    Button("Remove account", role: .destructive) {
                        try? appState.removeAccount(account.id)
                    }
                }
            }

            Section("Background Sync") {
                Picker("Keep in sync", selection: syncScopeBinding) {
                    ForEach(AccountSyncScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                switch account.syncScope {
                case .off:
                    Text(globalPolicy.lazyEnabled
                         ? "No background traffic. This mailbox only caches what agents search for or open (lazy caching, set in Settings › Cache)."
                         : "Lazy caching is off in Settings › Cache, so agent requests for this mailbox always go to the server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .recent:
                    Picker("Messages per folder", selection: syncRecentCountBinding) {
                        Text("250").tag(250)
                        Text("500 (Default)").tag(500)
                        Text("1,000").tag(1000)
                        Text("2,500").tag(2500)
                        Text("5,000").tag(5000)
                    }
                case .days:
                    Picker("Time window", selection: syncDaysBackBinding) {
                        Text("Past 30 days").tag(30)
                        Text("Past 90 days").tag(90)
                        Text("Past 180 days").tag(180)
                        Text("Past 365 days").tag(365)
                    }
                case .everything:
                    Toggle("Download & index all message bodies (text/HTML)", isOn: fullSyncBodiesBinding)
                    Text("Downloads every folder’s headers plus text/HTML bodies in paced batches. Attachments are fetched only when an agent asks for them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if account.syncScope != .off {
                    Picker("When to sync", selection: syncScheduleBinding) {
                        ForEach(AccountSyncSchedule.allCases) { schedule in
                            Text(schedule.title).tag(schedule)
                        }
                    }
                    LabeledContent("Next sync") {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(nextSyncText(now: context.date, policy: globalPolicy))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
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
                            Text(cooldownStatusText(stats: stats, policy: effectivePolicy))
                        } else if effectivePolicy.mode == .lazy {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 8, height: 8)
                            Text("Lazy · waiting for agent requests")
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
                LabeledContent("Cached attachments", value: "\(stats.attachmentCount)")
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
                if let cacheNotice {
                    Text(cacheNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                FlowLayout {
                    if account.syncScope != .off {
                        Button(isSyncing ? "Syncing…" : (effectivePolicy.mode == .fullSync ? "Start / resume full sync" : "Sync now")) {
                            cacheNotice = nil
                            Task {
                                await appState.syncMailboxCacheNow(account: account)
                                await MainActor.run {
                                    cacheNotice = "Mailbox synced."
                                }
                            }
                        }
                        .disabled(isSyncing)
                    }

                    if isSyncing {
                        Button("Pause sync") {
                            appState.pauseMailboxSync(account: account)
                            cacheNotice = "Sync paused. Click Start / resume to continue where it left off."
                        }
                    }

                    Button("Clear mailbox cache", role: .destructive) {
                        appState.clearMailboxCache(account: account)
                        cacheNotice = "Cleared cached messages and bodies for \(account.email)."
                    }
                    .disabled(isSyncing || (stats.envelopeCount == 0 && stats.bodyCount == 0 && stats.folderCount == 0))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(account.displayName.isEmpty ? account.email : account.displayName)
        .padding()
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
        .sheet(isPresented: $showEditAccount) {
            AddAccountView(editingAccount: account)
                .environmentObject(appState)
                .frame(minWidth: 560, minHeight: 500)
        }
    }

    private func accountSyncBinding<Value>(_ keyPath: WritableKeyPath<MailAccount, Value>) -> Binding<Value> {
        Binding(
            get: { account[keyPath: keyPath] },
            set: { newValue in
                appState.updateAccountSync(accountID: account.id) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private var syncScopeBinding: Binding<AccountSyncScope> { accountSyncBinding(\.syncScope) }
    private var syncRecentCountBinding: Binding<Int> { accountSyncBinding(\.syncRecentCount) }
    private var syncDaysBackBinding: Binding<Int> { accountSyncBinding(\.syncDaysBack) }
    private var syncScheduleBinding: Binding<AccountSyncSchedule> { accountSyncBinding(\.syncSchedule) }
    private var fullSyncBodiesBinding: Binding<Bool> { accountSyncBinding(\.fullSyncBodies) }

    private func nextSyncText(now: Date, policy: CacheSyncPolicy) -> String {
        if appState.isSyncingCache(for: account) {
            return "Syncing now…"
        }
        guard account.syncSchedule != .manual else {
            return "Manual — press Sync now"
        }
        if policy.pauseAutoSyncOnBattery, let reason = appState.autoSyncPausedReason {
            return "Paused (\(reason))"
        }
        guard let next = appState.nextAutoSyncDate(for: account) else { return "—" }
        if next <= now {
            return "Due now"
        }
        let relative = RelativeDateTimeFormatter().localizedString(for: next, relativeTo: now)
        return "\(relative) (\(next.formatted(date: .omitted, time: .shortened)))"
    }

    private func cooldownStatusText(stats: AccountCacheStats, policy: CacheSyncPolicy) -> String {
        if let checked = stats.lastCheckedAt {
            let elapsed = Int(Date().timeIntervalSince(checked))
            let remaining = policy.cooldownSeconds - elapsed
            if remaining > 0 {
                return "Synced · cooldown (\(remaining)s left)"
            }
        }
        return "Synced · ready"
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
    case agents
    case history
    case settings
    case pending
    case account(UUID)
}
