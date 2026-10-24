import SwiftUI
import UniformTypeIdentifiers

struct AddVaultView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Personal"
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var openPassphrase = ""
    @State private var pickedURL: URL?
    @State private var showImporter = false
    @State private var error: String?
    @State private var notice: String?
    /// Shown inside the Settings panel rather than as a sheet.
    var inline = false

    var body: some View {
        Form {
            Section("Create a new vault") {
                TextField("Vault name", text: $name)
                SecureField("Passphrase", text: $passphrase)
                SecureField("Confirm passphrase", text: $confirm)
                Text("Creates an encrypted vault on this Mac and makes it active. Mailboxes you add next are stored in it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Create Vault") { create() }
                        .keyboardShortcut(.defaultAction)
                }
            }

            Section("Open an existing vault") {
                if let pickedURL {
                    LabeledContent("File") {
                        Text(pickedURL.path)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    SecureField("Passphrase for the file", text: $openPassphrase)
                }
                Text("Pick the file first, then enter its passphrase. MailMCP opens that file in place and does not make another copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(pickedURL == nil ? "Choose Vault…" : "Choose a Different File…") { showImporter = true }
                    if let pickedURL {
                        Button("Open Vault") { open(pickedURL) }
                    }
                }
            }

            if notice != nil || error != nil || !inline {
                Section {
                    if let notice {
                        Text(notice).foregroundStyle(.secondary)
                    }
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                    if !inline {
                        HStack {
                            Spacer()
                            Button("Cancel") { dismiss() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Add a Vault")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                pickedURL = url
                error = nil
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }

    private func finish(_ message: String) {
        guard inline else {
            dismiss()
            return
        }
        notice = message
        passphrase = ""
        confirm = ""
        openPassphrase = ""
        pickedURL = nil
    }

    private func create() {
        error = nil
        notice = nil
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
            finish("Created “\(name)” and made it the active vault.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func open(_ url: URL) {
        error = nil
        notice = nil
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            try appState.importVault(from: url, passphrase: openPassphrase)
            finish("Opened \(url.lastPathComponent).")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
