import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPane: String, CaseIterable, Identifiable {
    case safety
    case cache
    case oauth
    case vault
    case mcp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .safety: return "Safety"
        case .cache: return "Cache"
        case .oauth: return "OAuth"
        case .vault: return "Vault"
        case .mcp: return "MCP"
        }
    }

    var icon: String {
        switch self {
        case .safety: return "lock.shield"
        case .cache: return "internaldrive"
        case .oauth: return "key"
        case .vault: return "externaldrive"
        case .mcp: return "terminal"
        }
    }
}

/// Settings with a secondary list column, laid out like a mailbox's folder column.
struct SettingsWorkspaceView: View {
    enum Item: Hashable {
        case addAccount
        case addVault
        case agents
        case history
        case pane(SettingsPane)
    }

    @EnvironmentObject private var appState: AppState
    @State private var item: Item
    @AppStorage("reader.folderColumnWidth") private var listWidth: Double = 200

    private static let listRange: ClosedRange<Double> = 150...320
    private static let contentMinWidth: Double = 560

    init(initialItem: Item = .pane(.safety)) {
        _item = State(initialValue: initialItem)
    }

    var body: some View {
        GeometryReader { geometry in
            let available = Double(geometry.size.width) - Double(ColumnResizeHandle.hitWidth)
            let width = max(Self.listRange.lowerBound, min(listWidth, available - Self.contentMinWidth))
            HStack(spacing: 0) {
                list
                    .frame(width: width)
                ColumnResizeHandle(width: $listWidth, range: Self.listRange)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar(removing: .title)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ColumnTitle(text: "Settings")
            itemList
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var itemList: some View {
        List(selection: Binding(get: { item }, set: { if let value = $0 { item = value } })) {
            Section("Add") {
                Label("Add an Account", systemImage: "envelope.badge.plus")
                    .tag(Item.addAccount)
                Label("Add a Vault", systemImage: "externaldrive.badge.plus")
                    .tag(Item.addVault)
                Label("Add to an Agent", systemImage: "puzzlepiece.extension")
                    .tag(Item.agents)
            }
            Section("Activity") {
                Label("Tool History", systemImage: "clock.arrow.circlepath")
                    .tag(Item.history)
            }
            Section("Settings") {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.icon)
                        .tag(Item.pane(pane))
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case .addAccount:
            AddAccountView(inline: true)
        case .addVault:
            AddVaultView(inline: true)
        case .agents:
            AgentsView()
        case .history:
            ToolHistoryView()
        case .pane(let pane):
            SettingsView(pane: pane)
                .id(pane)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    let pane: SettingsPane
    @State private var currentPassphrase = ""
    @State private var nextPassphrase = ""
    @State private var confirmPassphrase = ""
    @State private var localStatus: String?
    @State private var vaultName = ""
    @State private var mergePassphrase = ""
    @State private var showMergeImporter = false
    @State private var unlockTarget: UUID?
    @State private var unlockPassphrase = ""
    @State private var cacheStats = MailboxCacheStore.shared.stats()
    @State private var isSyncingCache = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch pane {
                case .safety:
                    safetyForm
                case .cache:
                    cacheForm
                case .oauth:
                    oauthForm
                case .vault:
                    vaultForm
                case .mcp:
                    mcpForm
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let localStatus {
                Text(localStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .navigationTitle(pane.title)
        .onAppear {
            vaultName = appState.activeName
        }
        .onChange(of: appState.activeVaultID) { _, _ in
            vaultName = appState.activeName
        }
        .fileImporter(isPresented: $showMergeImporter, allowedContentTypes: [.item]) { result in
            handleImportedVault(result)
        }
    }

    private var safetyForm: some View {
        Form {
            Picker("Agent safety", selection: safetyBinding) {
                ForEach(SafetyMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Toggle("Confirm before send", isOn: confirmBinding)
            Text("Read-only blocks drafts, organize, and send. Confirm-before-send queues outbound mail until you approve it in MailMCP.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var cacheForm: some View {
        let usedBytes = appState.cacheUsedBytes()
        let limitBytes = appState.settings.cachePolicy.cacheLimitBytes
        let isOver = limitBytes.map { usedBytes > $0 } ?? false
        return Form {
            Section("Storage") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    SettingsTile(
                        title: "In use",
                        value: FreeSpaceControls.format(usedBytes),
                        detail: limitBytes.map { "of \(FreeSpaceControls.format($0))" } ?? "No limit",
                        tint: isOver ? .orange : nil,
                        progress: limitBytes.map { min(Double(usedBytes) / Double(max($0, 1)), 1) }
                    )
                    SettingsTile(title: "Headers", value: cacheStats.messageCount.formatted())
                    SettingsTile(title: "Bodies", value: cacheStats.bodyCount.formatted())
                    SettingsTile(
                        title: "On disk",
                        value: FreeSpaceControls.format(cacheStats.sizeBytes),
                        detail: "incl. search index"
                    )
                    SettingsTile(
                        title: "Last synced",
                        value: cacheStats.lastSyncAt?.formatted(date: .omitted, time: .shortened) ?? "Never",
                        detail: cacheStats.lastSyncAt?.formatted(date: .abbreviated, time: .omitted)
                    )
                }
                .padding(.vertical, 4)
                Picker("Cache size limit", selection: cacheLimitBinding) {
                    Text("2 GB").tag(2_000)
                    Text("5 GB").tag(5_000)
                    Text("10 GB (Default)").tag(10_000)
                    Text("20 GB").tag(20_000)
                    Text("50 GB").tag(50_000)
                    Text("No limit").tag(0)
                }
                Text("Headers and bodies of everything you or an agent open, plus each mailbox’s background sync. Attachments are never stored. Nothing is deleted automatically; over the limit, MailMCP asks how much to free.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Free Up Space") {
                FreeSpaceControls()
            }

            Section("Background Sync") {
                Toggle("Pause auto-sync on battery or Low Power Mode", isOn: pauseOnBatteryBinding)
                FlowLayout {
                    Button(isSyncingCache || !appState.syncingAccountIDs.isEmpty ? "Syncing…" : "Sync all mailboxes") {
                        isSyncingCache = true
                        Task {
                            await appState.syncMailboxCacheNow()
                            await MainActor.run {
                                cacheStats = MailboxCacheStore.shared.stats()
                                isSyncingCache = false
                                localStatus = "Mailbox cache synced."
                            }
                        }
                    }
                    .disabled(isSyncingCache || !appState.syncingAccountIDs.isEmpty || !appState.isUnlocked
                              || !appState.accounts.contains { $0.syncScope != .off })

                    Button("Clear all cache", role: .destructive) {
                        appState.clearMailboxCache()
                        cacheStats = MailboxCacheStore.shared.stats()
                        localStatus = "Mailbox cache cleared."
                    }
                }
                if !appState.accounts.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                        ForEach(appState.accounts) { account in
                            accountCacheTile(account)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Text("Each mailbox’s policy and schedule is set in its Mailbox Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Server & Bandwidth") {
                Picker("Server check cooldown", selection: cacheCooldownBinding) {
                    Text("30 seconds").tag(30)
                    Text("1 minute (Default)").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
                Picker("Daily download cap (per mailbox)", selection: cacheDailyCapBinding) {
                    Text("500 MB / day").tag(500)
                    Text("1,000 MB / day").tag(1000)
                    Text("1,500 MB / day (Default — under Gmail’s 2.5 GB limit)").tag(1500)
                    Text("2,000 MB / day").tag(2000)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            cacheStats = MailboxCacheStore.shared.stats()
        }
        .onChange(of: appState.cacheRevision) { _, _ in
            cacheStats = MailboxCacheStore.shared.stats()
        }
    }

    private func accountCacheTile(_ account: MailAccount) -> some View {
        let accStats = appState.cacheStats(for: account)
        let syncing = appState.isSyncingCache(for: account)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if syncing {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill((accStats.envelopeCount > 0 || accStats.lastSyncedAt != nil) ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                }
                Text(account.displayName.isEmpty ? account.email : account.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if account.syncScope != .off {
                    Button(syncing ? "Syncing…" : "Sync") {
                        Task { await appState.syncMailboxCacheNow(account: account) }
                    }
                    .controlSize(.small)
                    .disabled(syncing)
                }
            }
            Text(accountSyncSummary(account))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(accStats.envelopeCount.formatted()) headers · \(accStats.bodyCount.formatted()) bodies")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(accStats.lastSyncedAt.map { "Synced \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Not synced yet")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var oauthForm: some View {
        Form {
            TextField("Google OAuth client ID", text: googleBinding)
            SecureField("Google OAuth client secret", text: googleSecretBinding)
            TextField("Microsoft Azure client ID", text: microsoftBinding)
        }
        .formStyle(.grouped)
    }

    private var vaultForm: some View {
        Form {
            Section {
                ForEach(appState.registry.vaults) { vault in
                    vaultRow(vault)
                }
                if let unlockTarget {
                    SecureField(
                        "Passphrase for \(appState.registry.descriptor(id: unlockTarget)?.name ?? "vault")",
                        text: $unlockPassphrase
                    )
                    .onSubmit { unlockVault(unlockTarget) }
                }
                TextField("Name", text: $vaultName)
                FlowLayout {
                    Button("Rename") { renameVault() }
                    Button("Export…") { exportVault() }
                    if let unlockTarget {
                        Button("Unlock") { unlockVault(unlockTarget) }
                    }
                    Button("Lock this vault") {
                        if let id = appState.activeVaultID {
                            appState.lockVault(id)
                        }
                    }
                    Button("Lock all") { appState.lock() }
                    Button("Remove from this Mac", role: .destructive) {
                        if let id = appState.activeVaultID {
                            appState.removeVaultReference(id)
                        }
                    }
                }
            } header: {
                Text("Vaults")
            } footer: {
                Text("Rename labels the active vault. Export writes a portable copy. Unlock opens another vault this session; Make active selects which one mailboxes and settings use. Lock forgets the in-memory key. Remove drops it from this Mac without deleting the file.")
            }

            Section {
                LabeledContent("Local file") {
                    Text(appState.vaultURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Sync folder") {
                    Text(appState.registry.active?.syncPath ?? appState.settings.syncFolderPath ?? "Not set")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Last sync", value: lastSyncLabel)
                FlowLayout {
                    Button("Choose folder…") { pickSyncFolder() }
                    Button("Sync now") { syncNow() }
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("Choose folder picks iCloud Drive, Dropbox, or any synced directory. MailMCP keeps a local encrypted copy and mirrors it there. Sync now pushes or pulls if only one side changed; if both changed you get a merge preview.")
            }

            Section {
                SecureField("Other vault’s passphrase", text: $mergePassphrase)
                FlowLayout {
                    Button("Merge vault…") { showMergeImporter = true }
                }
            } header: {
                Text("Merge")
            } footer: {
                Text("Opens another .vault, shows additions and conflicts, then writes your choices into this vault. The other file is not changed.")
            }

            Section {
                LabeledContent("Generation", value: String(appState.activeStore?.payload?.generation ?? 0))
                SecureField("Current passphrase", text: $currentPassphrase)
                SecureField("New passphrase", text: $nextPassphrase)
                SecureField("Confirm new passphrase", text: $confirmPassphrase)
                FlowLayout {
                    Button("Change passphrase") { changePassphrase() }
                }
            } header: {
                Text("Passphrase")
            } footer: {
                Text("Change passphrase re-encrypts this vault. You type this passphrase to unlock MailMCP; agents do not unlock it.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func vaultRow(_ vault: VaultDescriptor) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(vault.name)
                Text(vaultStatus(vault))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(vault.localPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if vault.id != appState.activeVaultID, appState.unlockedVaults.contains(where: { $0.id == vault.id }) {
                Button("Make active") {
                    try? appState.switchActiveVault(vault.id)
                    localStatus = appState.statusMessage
                }
            } else if vault.id != appState.activeVaultID {
                Button("Unlock…") { unlockTarget = vault.id }
            }
        }
    }

    private func vaultStatus(_ vault: VaultDescriptor) -> String {
        let unlocked = appState.unlockedVaults.contains(where: { $0.id == vault.id })
        if vault.id == appState.activeVaultID {
            return unlocked ? "Active" : "Active, locked"
        }
        return unlocked ? "Unlocked" : "Locked"
    }

    private var mcpForm: some View {
        Form {
            Section("Agent connection") {
                if appState.mcpAgents.isEmpty {
                    LabeledContent("Status", value: appState.mcpConnectionSummary)
                } else {
                    ForEach(appState.mcpAgents) { agent in
                        LabeledContent(agent.displayName) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Connected")
                                Text(agent.connectedAt.formatted(date: .omitted, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !agent.version.isEmpty {
                                    Text(agent.version)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    if let lastMCPActivity = appState.lastMCPActivity {
                        LabeledContent(
                            "Last tool call",
                            value: lastMCPActivity.formatted(date: .omitted, time: .shortened)
                        )
                    }
                }
                if appState.isUnlocked && appState.mcpAgents.isEmpty {
                    Text("This window can read mail. Cursor is not attached to this app. Restart the MailMCP MCP in Cursor after MailMCP is open.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !appState.isUnlocked {
                    Text("Unlock the vault in this window. The helper Cursor launches only forwards to this app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Agents are talking to this running app. Quit MailMCP from the menu bar to disconnect them. Unlock stays in memory until you lock, quit, or the app is restarted — there is no idle timeout.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Quit") {
                Toggle("Command-Q keeps MailMCP in the menu bar", isOn: keepRunningBinding)
                Text("On by default so Command-Q does not kill agents. Use Quit in the menu bar icon to shut MailMCP down.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Agent visibility") {
                Picker("Mailboxes agents can use", selection: mcpExposureBinding) {
                    ForEach(MCPExposure.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                Text("Active vault only limits agents to the selected vault. All unlocked vaults includes every vault you have unlocked this session. Duplicate emails then require the account UUID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(MCPToolCatalog.groups, id: \.title) { group in
                Section {
                    Text(group.intro)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(groupEnabled(group.tools) ? "All enabled" : "All disabled", isOn: groupBinding(group.tools))
                    ForEach(group.tools) { tool in
                        toolToggle(tool)
                            .padding(.leading, 8)
                    }
                } header: {
                    Text(group.title)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func groupEnabled(_ tools: [MCPToolInfo]) -> Bool {
        tools.allSatisfy { !appState.settings.disabledTools.contains($0.name) }
    }

    private func groupBinding(_ tools: [MCPToolInfo]) -> Binding<Bool> {
        Binding(
            get: { groupEnabled(tools) },
            set: { enabled in try? appState.setTools(tools.map(\.name), enabled: enabled) }
        )
    }

    private func toolToggle(_ tool: MCPToolInfo) -> some View {
        Toggle(isOn: Binding(
            get: { !appState.settings.disabledTools.contains(tool.name) },
            set: { enabled in try? appState.setTool(tool.name, enabled: enabled) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title)
                Text(tool.intro)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var safetyBinding: Binding<SafetyMode> {
        Binding(
            get: { appState.settings.safetyMode },
            set: { value in try? appState.updateSettings { $0.safetyMode = value } }
        )
    }

    private var confirmBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.confirmBeforeSend },
            set: { value in try? appState.updateSettings { $0.confirmBeforeSend = value } }
        )
    }

    private var cacheLimitBinding: Binding<Int> {
        Binding(
            get: { appState.settings.cachePolicy.cacheLimitMB },
            set: { value in try? appState.updateSettings { $0.cachePolicy.cacheLimitMB = value } }
        )
    }

    private var pauseOnBatteryBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.cachePolicy.pauseAutoSyncOnBattery },
            set: { value in try? appState.updateSettings { $0.cachePolicy.pauseAutoSyncOnBattery = value } }
        )
    }

    private func accountSyncSummary(_ account: MailAccount) -> String {
        switch account.syncScope {
        case .off:
            return "Off (lazy sync only)"
        case .recent:
            return "Recent \(account.syncRecentCount.formatted()) Inbox messages · \(account.syncSchedule.title)"
        case .days:
            return "Recent \(account.syncDaysBack) days of Inbox · \(account.syncSchedule.title)"
        case .everything:
            return "Background sync: everything · \(account.syncSchedule.title)"
        }
    }

    private var cacheCooldownBinding: Binding<Int> {
        Binding(
            get: { appState.settings.cachePolicy.cooldownSeconds },
            set: { value in try? appState.updateSettings { $0.cachePolicy.cooldownSeconds = value } }
        )
    }

    private var cacheDailyCapBinding: Binding<Int> {
        Binding(
            get: { appState.settings.cachePolicy.dailyBandwidthCapMB },
            set: { value in try? appState.updateSettings { $0.cachePolicy.dailyBandwidthCapMB = value } }
        )
    }

    private var googleBinding: Binding<String> {
        Binding(
            get: { appState.settings.googleClientID },
            set: { value in try? appState.updateSettings { $0.googleClientID = value } }
        )
    }

    private var googleSecretBinding: Binding<String> {
        Binding(
            get: { appState.settings.googleClientSecret },
            set: { value in try? appState.updateSettings { $0.googleClientSecret = value } }
        )
    }

    private var microsoftBinding: Binding<String> {
        Binding(
            get: { appState.settings.microsoftClientID },
            set: { value in try? appState.updateSettings { $0.microsoftClientID = value } }
        )
    }

    private var mcpExposureBinding: Binding<MCPExposure> {
        Binding(
            get: { appState.mcpExposure },
            set: { appState.setMCPExposure($0) }
        )
    }

    private var keepRunningBinding: Binding<Bool> {
        Binding(
            get: { appState.keepRunningOnCommandQ },
            set: { appState.keepRunningOnCommandQ = $0 }
        )
    }

    private var lastSyncLabel: String {
        let descriptor = appState.registry.active
        let status = descriptor?.lastSyncStatus.isEmpty == false ? descriptor?.lastSyncStatus : appState.lastSyncStatus
        if let at = descriptor?.lastSyncAt {
            return "\(at.formatted(date: .abbreviated, time: .shortened)) — \(status ?? "")"
        }
        return status?.isEmpty == false ? status! : "Not synced yet"
    }

    private func renameVault() {
        do {
            try appState.renameActiveVault(vaultName)
            localStatus = appState.statusMessage
        } catch {
            localStatus = error.localizedDescription
        }
    }

    private func unlockVault(_ id: UUID) {
        do {
            try appState.unlock(passphrase: unlockPassphrase, vaultID: id)
            unlockPassphrase = ""
            unlockTarget = nil
            localStatus = appState.statusMessage
        } catch {
            localStatus = error.localizedDescription
        }
    }

    private func handleImportedVault(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                try appState.prepareMerge(from: url, passphrase: mergePassphrase)
                localStatus = "Review the merge preview."
            } catch {
                localStatus = error.localizedDescription
            }
        case .failure(let error):
            localStatus = error.localizedDescription
        }
    }

    private func syncNow() {
        do {
            _ = try appState.syncNow()
            localStatus = appState.statusMessage
        } catch {
            localStatus = error.localizedDescription
        }
    }

    private func exportVault() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "MailMCP.vault"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try appState.exportVault(to: url)
            localStatus = "Exported to \(url.path)"
        } catch {
            localStatus = error.localizedDescription
        }
    }

    private func pickSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try appState.setSyncFolder(url)
            localStatus = appState.statusMessage
        } catch {
            localStatus = error.localizedDescription
        }
    }

    private func changePassphrase() {
        guard nextPassphrase.count >= 8, nextPassphrase == confirmPassphrase else {
            localStatus = "New passphrase must match and be at least 8 characters."
            return
        }
        do {
            try appState.changePassphrase(current: currentPassphrase, next: nextPassphrase)
            currentPassphrase = ""
            nextPassphrase = ""
            confirmPassphrase = ""
            localStatus = "Passphrase updated."
        } catch {
            localStatus = error.localizedDescription
        }
    }
}

struct AgentsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var localStatus: String?
    @State private var copied = false
    @State private var expanded: Set<String> = []
    @State private var tick = 0

    private var snippet: String { MCPClientInstaller.snippet() }

    var body: some View {
        Form {
            Section {
                Text("Each agent launches a small helper that connects to this running MailMCP app. Unlock MailMCP first, then add the agent. If the window works but the agent does not, restart MailMCP in the agent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Agents") {
                ForEach(MCPClientKind.allCases) { client in
                    agentRow(client)
                }
            }
            Section("Config") {
                TextEditor(text: .constant(snippet))
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 160)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                }
                if let localStatus {
                    Text(localStatus).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Add to an Agent")
    }

    private func agentRow(_ client: MCPClientKind) -> some View {
        let state = MCPClientInstaller.state(for: client)
        _ = tick
        return DisclosureGroup(isExpanded: expandedBinding(client.id)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(client.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(state.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(dotColor(state))
                    .frame(width: 8, height: 8)
                Text(client.title)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if state != .agentMissing {
                    Button(buttonTitle(for: client, state: state)) {
                        do {
                            try appState.installMCP(for: client)
                            localStatus = appState.statusMessage
                            tick += 1
                        } catch {
                            localStatus = error.localizedDescription
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isOn in
                if isOn {
                    expanded.insert(id)
                } else {
                    expanded.remove(id)
                }
            }
        )
    }

    private func dotColor(_ state: MCPInstallState) -> Color {
        switch state {
        case .added, .stale:
            return .green
        case .notAdded:
            return .yellow
        case .agentMissing:
            return .gray
        }
    }

    private func buttonTitle(for client: MCPClientKind, state: MCPInstallState) -> String {
        switch state {
        case .added: return "Update"
        case .stale: return "Fix path"
        case .notAdded: return "Add"
        case .agentMissing: return "Add"
        }
    }
}

/// Compact stat tile used in settings panels.
struct SettingsTile: View {
    let title: String
    let value: String
    var detail: String?
    var tint: Color?
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let progress {
                ProgressView(value: progress)
                    .tint(tint ?? .accentColor)
                    .controlSize(.small)
            }
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
