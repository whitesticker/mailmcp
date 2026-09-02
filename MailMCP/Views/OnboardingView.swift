import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var vaultName = "Personal"
    @State private var importPassphrase = ""
    @State private var showImporter = false
    @State private var localError: String?
    @State private var unlockTarget: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MailMCP")
                    .font(.largeTitle.bold())
                Text("An encrypted vault for mailbox credentials, plus a local MCP server for agents. Nothing is uploaded.")
                    .foregroundStyle(.secondary)
            }

            if !appState.registry.vaults.isEmpty {
                GroupBox("Unlock a vault") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(appState.registry.vaults) { vault in
                            Button(vault.name) {
                                unlockTarget = vault.id
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(unlockTarget == vault.id || (unlockTarget == nil && vault.id == appState.registry.activeID)
                                             ? Color.accentColor : Color.primary)
                        }
                        SecureField("Vault passphrase", text: $passphrase)
                        Button("Unlock") { unlock() }
                            .keyboardShortcut(.defaultAction)
                        Button(KeychainWrap.presenceButtonTitle) {
                            appState.retryKeychainUnlock()
                            if !appState.isUnlocked {
                                localError = "Touch ID was cancelled or failed. Enter your passphrase."
                            }
                        }
                    }
                    .padding(8)
                }
            } else if appState.vaultExists {
                GroupBox("Unlock this Mac") {
                    VStack(alignment: .leading, spacing: 12) {
                        SecureField("Vault passphrase", text: $passphrase)
                        Button("Unlock") { unlock() }
                            .keyboardShortcut(.defaultAction)
                        Button(KeychainWrap.presenceButtonTitle) {
                            appState.retryKeychainUnlock()
                            if !appState.isUnlocked {
                                localError = "Touch ID was cancelled or failed. Enter your passphrase."
                            }
                        }
                    }
                    .padding(8)
                }
            }

            if appState.registry.vaults.isEmpty {
                GroupBox("Create a new vault") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Vault name", text: $vaultName)
                        SecureField("Choose a passphrase", text: $passphrase)
                        SecureField("Confirm passphrase", text: $confirm)
                        Text("This passphrase encrypts the portable vault file. You will type it on each new Mac. On this Mac, MailMCP can then unlock with Touch ID or your Mac password.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Create vault") { create() }
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(8)
                }
            }

            GroupBox("Or open a portable vault") {
                VStack(alignment: .leading, spacing: 12) {
                    SecureField("Passphrase for the imported file", text: $importPassphrase)
                    Button("Import MailMCP.vault…") { showImporter = true }
                }
                .padding(8)
            }

            if let localError {
                Text(localError)
                    .foregroundStyle(.red)
            }
        }
        .padding(28)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                importVault(url)
            case .failure(let error):
                localError = error.localizedDescription
            }
        }
        .onAppear {
            unlockTarget = appState.registry.activeID ?? appState.registry.vaults.first?.id
        }
    }

    private func create() {
        localError = nil
        guard passphrase.count >= 8 else {
            localError = "Use at least 8 characters."
            return
        }
        guard passphrase == confirm else {
            localError = "Passphrases do not match."
            return
        }
        do {
            try appState.createVault(passphrase: passphrase, name: vaultName)
        } catch {
            localError = error.localizedDescription
        }
    }

    private func unlock() {
        localError = nil
        do {
            try appState.unlock(passphrase: passphrase, vaultID: unlockTarget)
        } catch {
            localError = error.localizedDescription
        }
    }

    private func importVault(_ url: URL) {
        localError = nil
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            try appState.importVault(from: url, passphrase: importPassphrase)
        } catch {
            localError = error.localizedDescription
        }
    }
}
