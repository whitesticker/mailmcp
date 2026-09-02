import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selected: ContentSelection?
    @State private var showAddAccount = false

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
                    Section("Mailboxes") {
                        ForEach(appState.accounts) { account in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(account.email)
                                    .font(.headline)
                                Text(account.provider.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let error = account.lastError, !error.isEmpty {
                                    Text(error)
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                        .lineLimit(2)
                                }
                            }
                            .tag(ContentSelection.account(account.id))
                        }
                    }
                }
                .navigationTitle("Mailboxes")
                Divider()
                List(selection: $selected) {
                    Label("Add to an agent", systemImage: "puzzlepiece.extension")
                        .tag(ContentSelection.agents)
                    Label("Settings", systemImage: "gearshape")
                        .tag(ContentSelection.settings)
                }
                .scrollDisabled(true)
                .frame(height: 96)
                .listStyle(.sidebar)
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        showAddAccount = true
                    } label: {
                        Label("Add account", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if selected == .agents {
                AgentsView()
            } else if selected == .settings {
                SettingsView()
            } else if selected == .pending {
                PendingSendsView()
            } else if case .account(let id) = selected, let account = appState.accounts.first(where: { $0.id == id }) {
                AccountDetailView(account: account)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "envelope.open")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(appState.accounts.isEmpty ? "Add a mailbox to get started." : "Select a mailbox.")
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
    }
}

struct AccountDetailView: View {
    @EnvironmentObject private var appState: AppState
    let account: MailAccount
    @State private var busy = false
    @State private var result: String?

    var body: some View {
        Form {
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
            Button("Remove account", role: .destructive) {
                try? appState.removeAccount(account.id)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(account.email)
        .padding()
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
    case settings
    case pending
    case account(UUID)
}
