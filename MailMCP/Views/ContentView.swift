import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selected: ContentSelection?
    @State private var showAddAccount = false
    @State private var showAddVault = false

    var body: some View {
        NavigationSplitView {
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
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayName.isEmpty ? account.email : account.displayName)
                    .font(.headline)
                Text(account.displayName.isEmpty || account.displayName == account.email
                     ? account.provider.title
                     : "\(account.email) · \(account.provider.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = account.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "line.3.horizontal")
                .font(.body)
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 28, alignment: .center)
        }
        .tag(ContentSelection.account(account.id))
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

    init(account: MailAccount) {
        self.account = account
        _nickname = State(initialValue:
            account.displayName == account.email ? "" : account.displayName
        )
    }

    var body: some View {
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
        .formStyle(.grouped)
        .navigationTitle(account.displayName.isEmpty ? account.email : account.displayName)
        .padding()
        .onChange(of: account.id) { _, _ in
            result = nil
            busy = false
            nicknameStatus = nil
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
