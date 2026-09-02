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
            LabeledContent("Vault file", value: appState.vaultURL.path)
            LabeledContent("Generation", value: String(appState.store.payload?.generation ?? 0))
            Button("Export portable vault…") { exportVault() }
            Button("Use iCloud Drive / sync folder…") { pickSyncFolder() }
            SecureField("Current passphrase", text: $currentPassphrase)
            SecureField("New passphrase", text: $nextPassphrase)
            SecureField("Confirm new passphrase", text: $confirmPassphrase)
            Button("Change passphrase") { changePassphrase() }
            Button("Lock vault") { appState.lock() }
            Button("Forget this Mac’s Keychain wrap", role: .destructive) {
                try? appState.forgetDeviceKey()
            }
        }
        .formStyle(.grouped)
    }

    private var mcpForm: some View {
        Form {
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
                Text("Each agent keeps MCP servers in its own file on this Mac. MailMCP writes that file; the agent reloads it on next launch or MCP refresh. Nothing is stored in the cloud.")
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
