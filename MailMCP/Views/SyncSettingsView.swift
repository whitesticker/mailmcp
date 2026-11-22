import SwiftUI

/// Settings › Sync: every mailbox's background sync in one list. Rows edit the same account fields as Mailbox Settings.
struct SyncSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var bulkScope = MailAccount.defaultSyncScope
    @State private var bulkRecentCount = MailAccount.defaultSyncRecentCount
    @State private var bulkDaysBack = 90
    @State private var bulkSchedule = MailAccount.defaultSyncSchedule
    @State private var confirmApply = false
    @State private var isSyncingAll = false
    @State private var status: String?

    var body: some View {
        let vaults = appState.unlockedVaults.filter { !$0.accounts.isEmpty }
        let mailboxCount = vaults.reduce(0) { $0 + $1.accounts.count }
        Form {
            Section {
                Toggle("Pause auto-sync on battery or Low Power Mode", isOn: pauseOnBatteryBinding)
                Button(isSyncingAll || !appState.syncingAccountIDs.isEmpty ? "Syncing…" : "Sync All Mailboxes") {
                    syncAll()
                }
                .disabled(isSyncingAll || !appState.syncingAccountIDs.isEmpty || !appState.isUnlocked
                          || !vaults.flatMap(\.accounts).contains { $0.syncScope != .off })
                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("All Mailboxes")
            } footer: {
                Text("Sync All runs every mailbox whose policy isn’t Off, one after another.")
            }

            Section("Server & Bandwidth") {
                Picker("Server check cooldown", selection: cooldownBinding) {
                    Text("30 seconds").tag(30)
                    Text("1 minute (Default)").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
                Picker("Daily download cap (per mailbox)", selection: dailyCapBinding) {
                    Text("500 MB / day").tag(500)
                    Text("1,000 MB / day").tag(1000)
                    Text("1,500 MB / day (Default — under Gmail’s 2.5 GB limit)").tag(1500)
                    Text("2,000 MB / day").tag(2000)
                }
            }

            Section {
                SyncPolicyPickers(scope: $bulkScope, recentCount: $bulkRecentCount, daysBack: $bulkDaysBack)
                if bulkScope != .off {
                    Picker("When to sync", selection: $bulkSchedule) {
                        ForEach(AccountSyncSchedule.allCases) { schedule in
                            Text(schedule.title).tag(schedule)
                        }
                    }
                }
                Button("Apply to All Mailboxes…") {
                    confirmApply = true
                }
                .disabled(mailboxCount == 0)
            } header: {
                Text("Apply to All")
            } footer: {
                Text("Sets this policy and schedule on every mailbox in your unlocked vaults. Each mailbox keeps its own setting for downloading bodies with Everything.")
            }

            if vaults.isEmpty {
                Section("Mailboxes") {
                    Text("No mailboxes yet. Add an account to choose how it syncs.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(vaults) { vault in
                Section {
                    ForEach(vault.accounts) { account in
                        SyncMailboxRow(account: account)
                    }
                } header: {
                    Text(vaults.count > 1 ? vault.name : "Mailboxes")
                } footer: {
                    if vault.id == vaults.last?.id {
                        Text("The same settings appear in each mailbox’s Mailbox Settings. A change in either place shows in both.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Apply to \(mailboxCount) mailbox\(mailboxCount == 1 ? "" : "es")?",
            isPresented: $confirmApply,
            titleVisibility: .visible
        ) {
            Button("Apply to All") { applyToAll(count: mailboxCount) }
        } message: {
            Text("Every mailbox will use \(bulkSummary). You can still change single mailboxes afterwards.")
        }
    }

    private var bulkSummary: String {
        let scope: String
        switch bulkScope {
        case .off: return "Off (lazy sync only)"
        case .recent: scope = "the recent \(bulkRecentCount.formatted()) Inbox messages"
        case .days: scope = "the recent \(bulkDaysBack) days of Inbox"
        case .everything: scope = "Everything"
        }
        return "\(scope), \(bulkSchedule.title.lowercased())"
    }

    private func applyToAll(count: Int) {
        let scope = bulkScope, recentCount = bulkRecentCount, daysBack = bulkDaysBack, schedule = bulkSchedule
        appState.updateAllAccountsSync { account in
            account.syncScope = scope
            switch scope {
            case .recent: account.syncRecentCount = recentCount
            case .days: account.syncDaysBack = daysBack
            case .off, .everything: break
            }
            if scope != .off {
                account.syncSchedule = schedule
            }
        }
        status = "Applied to \(count) mailbox\(count == 1 ? "" : "es")."
    }

    private func syncAll() {
        isSyncingAll = true
        status = nil
        Task {
            await appState.syncMailboxCacheNow()
            isSyncingAll = false
            status = "All mailboxes synced."
        }
    }

    private var pauseOnBatteryBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.cachePolicy.pauseAutoSyncOnBattery },
            set: { value in try? appState.updateSettings { $0.cachePolicy.pauseAutoSyncOnBattery = value } }
        )
    }

    private var cooldownBinding: Binding<Int> {
        Binding(
            get: { appState.settings.cachePolicy.cooldownSeconds },
            set: { value in try? appState.updateSettings { $0.cachePolicy.cooldownSeconds = value } }
        )
    }

    private var dailyCapBinding: Binding<Int> {
        Binding(
            get: { appState.settings.cachePolicy.dailyBandwidthCapMB },
            set: { value in try? appState.updateSettings { $0.cachePolicy.dailyBandwidthCapMB = value } }
        )
    }
}

/// One mailbox: status, policy, schedule, and Sync now / Pause, edited in place.
/// Shared by Settings › Sync and Mailbox Settings, which already names the mailbox and so hides it.
struct SyncMailboxRow: View {
    @EnvironmentObject private var appState: AppState
    let account: MailAccount
    var showsIdentity = true

    var body: some View {
        let status = MailboxStatus(account: account, appState: appState)
        let syncing = appState.isSyncingCache(for: account)
        VStack(alignment: .leading, spacing: 8) {
            if showsIdentity {
                HStack(alignment: .center, spacing: 8) {
                    MailboxStatusIndicator(status: status)
                        .help(status.kindHelp)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hasNickname ? account.displayName : account.email)
                            .fontWeight(.medium)
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
                    syncButton(syncing: syncing)
                }
                controls
            } else {
                HStack(alignment: .top, spacing: 8) {
                    controls
                        .frame(maxWidth: .infinity, alignment: .leading)
                    syncButton(syncing: syncing)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !showsIdentity {
                    MailboxStatusIndicator(status: status)
                        .help(status.kindHelp)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(statusLine(now: context.date, syncing: syncing))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(!syncing && account.lastError?.isEmpty == false ? Color.red : Color.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hasNickname ? account.displayName : account.email)
    }

    @ViewBuilder
    private func syncButton(syncing: Bool) -> some View {
        if syncing {
            Button("Pause") { appState.pauseMailboxSync(account: account) }
                .help("Stop this sync. Sync Now resumes where it left off.")
        } else {
            Button("Sync Now") {
                Task { await appState.syncMailboxCacheNow(account: account) }
            }
            .disabled(account.syncScope == .off)
            .help(account.syncScope == .off ? "Background sync is off for this mailbox" : "Sync this mailbox now")
        }
    }

    private var controls: some View {
        FlowLayout(spacing: 8) {
            Picker("Policy", selection: binding(\.syncScope)) {
                ForEach(AccountSyncScope.allCases) { scope in
                    Text(Self.scopeTitle(scope)).tag(scope)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help(SyncPolicyPickers.explanation(for: account.syncScope))
            switch account.syncScope {
            case .recent:
                Picker("Inbox messages", selection: binding(\.syncRecentCount)) {
                    ForEach(SyncPolicyPickers.recentCounts, id: \.self) { count in
                        Text("\(count.formatted()) messages").tag(count)
                    }
                }
                .labelsHidden()
                .fixedSize()
            case .days:
                Picker("Days", selection: binding(\.syncDaysBack)) {
                    ForEach(SyncPolicyPickers.dayCounts, id: \.self) { days in
                        Text("\(days) days").tag(days)
                    }
                }
                .labelsHidden()
                .fixedSize()
            case .off, .everything:
                EmptyView()
            }
            if account.syncScope != .off {
                Picker("When to sync", selection: binding(\.syncSchedule)) {
                    ForEach(AccountSyncSchedule.allCases) { schedule in
                        Text(schedule.title).tag(schedule)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if account.syncScope == .everything {
                Toggle("Download bodies", isOn: binding(\.fullSyncBodies))
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .padding(.vertical, 3)
                    .help("Download and index every message’s text and HTML, not just headers")
            }
        }
    }

    private var hasNickname: Bool {
        !account.displayName.isEmpty && account.displayName != account.email
    }

    private static func scopeTitle(_ scope: AccountSyncScope) -> String {
        switch scope {
        case .off: return "Off (lazy only)"
        case .recent: return "Recent messages"
        case .days: return "Recent days"
        case .everything: return "Everything"
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<MailAccount, Value>) -> Binding<Value> {
        Binding(
            get: { account[keyPath: keyPath] },
            set: { newValue in
                appState.updateAccountSync(accountID: account.id) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func statusLine(now: Date, syncing: Bool) -> String {
        if syncing {
            return appState.syncProgressMessage(for: account) ?? "Syncing…"
        }
        if let error = account.lastError, !error.isEmpty {
            return error
        }
        let stats = appState.cacheStats(for: account)
        var parts: [String] = []
        if let synced = stats.lastSyncedAt {
            parts.append("Synced \(RelativeDateTimeFormatter().localizedString(for: synced, relativeTo: now))")
        } else {
            parts.append("Not synced yet")
        }
        parts.append("\(stats.envelopeCount.formatted()) headers · \(stats.bodyCount.formatted()) bodies")
        parts.append(nextSyncText(now: now))
        return parts.joined(separator: " · ")
    }

    private func nextSyncText(now: Date) -> String {
        if account.syncScope == .off {
            return "Caches only what you or agents open"
        }
        if account.syncSchedule == .manual {
            return "Manual"
        }
        if appState.settings(for: account).cachePolicy.pauseAutoSyncOnBattery, let reason = appState.autoSyncPausedReason {
            return "Auto-sync paused (\(reason))"
        }
        guard let next = appState.nextAutoSyncDate(for: account) else { return "Manual" }
        if next.timeIntervalSince(now) < 60 {
            return "Next sync due now"
        }
        return "Next \(RelativeDateTimeFormatter().localizedString(for: next, relativeTo: now))"
    }
}
