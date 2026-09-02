import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsPane: String, CaseIterable, Identifiable {
    case safety
    case oauth
    case vault
    case mcp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .safety: return "Safety"
        case .oauth: return "OAuth"
        case .vault: return "Vault"
        case .mcp: return "MCP"
        }
    }

    var icon: String {
        switch self {
        case .safety: return "lock.shield"
        case .oauth: return "key"
        case .vault: return "externaldrive"
        case .mcp: return "terminal"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pane: SettingsPane = .safety
    @State private var currentPassphrase = ""
    @State private var nextPassphrase = ""
    @State private var confirmPassphrase = ""
    @State private var localStatus: String?
    @State private var vaultName = ""
    @State private var mergePassphrase = ""
    @State private var showMergeImporter = false
    @State private var unlockTarget: UUID?
    @State private var unlockPassphrase = ""

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch pane {
                case .safety:
                    safetyForm
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
            Divider()
            HStack(spacing: 0) {
                ForEach(SettingsPane.allCases) { item in
                    Button {
                        pane = item
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: item.icon)
                                .font(.system(size: 16, weight: .semibold))
                            Text(item.title)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(pane == item ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .background(.bar)
        }
        .navigationTitle("Settings")
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

    private var oauthForm: some View {
        Form {
            TextField("Google OAuth client ID", text: googleBinding)
            TextField("Microsoft Azure client ID", text: microsoftBinding)
            Text("Desktop / public clients with PKCE. Register redirect URIs mailmcp://oauth/google and mailmcp://oauth/microsoft. Keep the app in testing mode with your own accounts until you verify it.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    Text("Agents are talking to this running app. Quit MailMCP from the menu bar to disconnect them.")
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

    private var googleBinding: Binding<String> {
        Binding(
            get: { appState.settings.googleClientID },
            set: { value in try? appState.updateSettings { $0.googleClientID = value } }
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
        .navigationTitle("Add to an agent")
        .padding()
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
