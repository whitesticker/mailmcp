import SwiftUI
import UniformTypeIdentifiers

struct AddVaultView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Personal"
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var openPassphrase = ""
    @State private var showImporter = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a vault")
                .font(.title2.bold())

            GroupBox("Create a new vault") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Vault name", text: $name)
                    SecureField("Passphrase", text: $passphrase)
                    SecureField("Confirm passphrase", text: $confirm)
                    FlowLayout {
                        Button("Create vault") { create() }
                            .keyboardShortcut(.defaultAction)
                    }
                    Text("Creates an encrypted vault on this Mac and makes it active. Mailboxes you add next are stored in it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox("Open an existing vault") {
                VStack(alignment: .leading, spacing: 10) {
                    SecureField("Passphrase for the file", text: $openPassphrase)
                    FlowLayout {
                        Button("Open vault…") { showImporter = true }
                    }
                    Text("Copies a portable .vault onto this Mac, unlocks it, and makes it active. The original file is not changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            if let error {
                Text(error).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 420)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                open(url)
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }

    private func create() {
        error = nil
        guard passphrase.count >= 8 else {
            error = "Use at least 8 characters."
            return
        }
        guard passphrase == confirm else {
            error = "Passphrases do not match."
            return
        }
        do {
            try appState.createVault(passphrase: passphrase, name: name)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func open(_ url: URL) {
        error = nil
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            try appState.importVault(from: url, passphrase: openPassphrase)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
