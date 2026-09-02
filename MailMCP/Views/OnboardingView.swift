import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var importPassphrase = ""
    @State private var showImporter = false
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MailMCP")
                    .font(.largeTitle.bold())
                Text("An encrypted vault for mailbox credentials, plus a local MCP server for agents. Nothing is uploaded.")
                    .foregroundStyle(.secondary)
            }

            if appState.vaultExists {
                GroupBox("Unlock this Mac") {
                    VStack(alignment: .leading, spacing: 12) {
                        SecureField("Vault passphrase", text: $passphrase)
                        Button("Unlock") { unlock() }
                            .keyboardShortcut(.defaultAction)
                        Button("Unlock with Touch ID / Keychain") {
                            appState.retryKeychainUnlock()
                            if !appState.isUnlocked {
                                localError = "Keychain unlock failed. Enter your passphrase."
                            }
                        }
                    }
                    .padding(8)
                }
            } else {
                GroupBox("Create a new vault") {
                    VStack(alignment: .leading, spacing: 12) {
                        SecureField("Choose a passphrase", text: $passphrase)
                        SecureField("Confirm passphrase", text: $confirm)
                        Text("This passphrase encrypts the portable vault file. You will type it on each new Mac. On this Mac, MailMCP can then unlock with Touch ID.")
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
            try appState.createVault(passphrase: passphrase)
        } catch {
            localError = error.localizedDescription
        }
    }

    private func unlock() {
        localError = nil
        do {
            try appState.unlock(passphrase: passphrase)
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
