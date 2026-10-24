import SwiftUI

struct AddAccountView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private let editingAccount: MailAccount?
    @State private var kind: MailProviderKind
    @State private var preset: IMAPPreset
    @State private var nickname: String
    @State private var email: String
    @State private var username: String
    @State private var password: String
    @State private var imapHost: String
    @State private var imapPort: String
    @State private var smtpHost: String
    @State private var smtpPort: String
    @State private var imapStartTLS: Bool
    @State private var smtpStartTLS: Bool
    @State private var busy = false
    @State private var error: String?

    init(editingAccount: MailAccount? = nil) {
        self.editingAccount = editingAccount
        let settings = editingAccount?.imap
        let matchingPreset = settings.flatMap { saved in
            IMAPPreset.all.first {
                !$0.imapHost.isEmpty &&
                $0.imapHost.caseInsensitiveCompare(saved.imapHost) == .orderedSame
            }
        } ?? IMAPPreset.all[0]
        _kind = State(initialValue: editingAccount?.provider ?? .imap)
        _preset = State(initialValue: matchingPreset)
        _nickname = State(initialValue: {
            guard let editingAccount,
                  !editingAccount.displayName.isEmpty,
                  editingAccount.displayName != editingAccount.email else { return "" }
            return editingAccount.displayName
        }())
        _email = State(initialValue: editingAccount?.email ?? "")
        _username = State(initialValue: settings?.username ?? "")
        _password = State(initialValue: settings?.password ?? "")
        _imapHost = State(initialValue: settings?.imapHost ?? "")
        _imapPort = State(initialValue: String(settings?.imapPort ?? 993))
        _smtpHost = State(initialValue: settings?.smtpHost ?? "")
        _smtpPort = State(initialValue: String(settings?.smtpPort ?? 465))
        _imapStartTLS = State(initialValue: settings?.imapStartTLS ?? false)
        _smtpStartTLS = State(initialValue: settings?.smtpStartTLS ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Provider", selection: $kind) {
                ForEach(MailProviderKind.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .disabled(editingAccount != nil)

            switch kind {
            case .imap:
                imapForm
            case .gmail:
                oauthCopy(title: "Sign in with Google")
            case .outlook:
                oauthCopy(
                    title: "Sign in with Microsoft",
                    detail: "Uses a public-client OAuth flow (the same PKCE pattern MSAL uses). Add your Azure app ID in Settings. Redirect URI: mailmcp://oauth/microsoft"
                )
            }

            if let error {
                Text(error).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(busy ? "Working…" : editingAccount == nil ? "Continue" : "Save changes") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
            }
        }
        .padding(20)
        .navigationTitle(editingAccount == nil ? "Add mailbox" : "Modify account")
        .onChange(of: preset) { _, newValue in
            apply(newValue)
        }
    }

    private var imapForm: some View {
        Form {
            Picker("Preset", selection: $preset) {
                ForEach(IMAPPreset.all) { item in
                    Text(item.name).tag(item)
                }
            }
            if editingAccount == nil {
                TextField("Nickname (optional)", text: $nickname)
            }
            TextField("Email", text: $email)
            TextField("Username", text: $username)
            SecureField("Password / app password", text: $password)
            TextField("IMAP host", text: $imapHost)
            TextField("IMAP port", text: $imapPort)
            Toggle("IMAP STARTTLS (use off for implicit TLS on 993)", isOn: $imapStartTLS)
            TextField("SMTP host", text: $smtpHost)
            TextField("SMTP port", text: $smtpPort)
            Toggle("SMTP STARTTLS (use off for implicit TLS on 465)", isOn: $smtpStartTLS)
        }
        .formStyle(.grouped)
    }

    private func oauthCopy(title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if editingAccount == nil {
                TextField("Nickname (optional)", text: $nickname)
            }
            if let editingAccount {
                LabeledContent("Current account", value: editingAccount.email)
            }
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func apply(_ preset: IMAPPreset) {
        if !preset.imapHost.isEmpty {
            imapHost = preset.imapHost
            imapPort = String(preset.imapPort)
            smtpHost = preset.smtpHost
            smtpPort = String(preset.smtpPort)
            imapStartTLS = preset.imapStartTLS
            smtpStartTLS = preset.smtpStartTLS
        }
    }

    private func save() async {
        error = nil
        busy = true
        defer { busy = false }
        do {
            switch kind {
            case .imap:
                try await saveIMAP()
            case .gmail:
                let config = try OAuthClient.google(
                    clientID: appState.settings.googleClientID,
                    clientSecret: appState.settings.googleClientSecret
                )
                let tokens = try await OAuthClient.signIn(config: config)
                let address = try await GmailUserInfo.email(tokens: tokens)
                try saveOAuthAccount(provider: .gmail, tokens: tokens, email: address)
            case .outlook:
                let config = try OAuthClient.microsoft(clientID: appState.settings.microsoftClientID)
                let tokens = try await OAuthClient.signIn(config: config)
                let address = try await GraphUserInfo.email(tokens: tokens)
                try saveOAuthAccount(provider: .outlook, tokens: tokens, email: address)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveIMAP() async throws {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw MailMCPError.invalidInput("Email is required") }
        guard let imapPortValue = Int(imapPort), let smtpPortValue = Int(smtpPort) else {
            throw MailMCPError.invalidInput("Ports must be numbers")
        }
        guard !password.isEmpty else {
            throw MailMCPError.invalidInput("Password or app password is required")
        }
        let settings = try IMAPSettings(
            imapHost: imapHost.trimmingCharacters(in: .whitespacesAndNewlines),
            imapPort: imapPortValue,
            imapStartTLS: imapStartTLS,
            smtpHost: smtpHost.trimmingCharacters(in: .whitespacesAndNewlines),
            smtpPort: smtpPortValue,
            smtpStartTLS: smtpStartTLS,
            username: username.isEmpty ? address : username,
            password: password
        ).resolvingBlankHosts(for: address)
        let account = MailAccount(
            id: editingAccount?.id ?? UUID(),
            provider: .imap,
            email: address,
            displayName: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
            imap: settings,
            createdAt: editingAccount?.createdAt ?? Date()
        )
        _ = try await IMAPProvider(account: account, settings: settings).testConnection()
        if editingAccount == nil {
            try appState.addIMAPAccount(account)
        } else {
            try appState.updateAccount(account)
        }
    }

    private func saveOAuthAccount(provider: MailProviderKind, tokens: OAuthTokens, email: String) throws {
        if let editingAccount {
            try appState.updateAccount(MailAccount(
                id: editingAccount.id,
                provider: provider,
                email: email,
                displayName: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
                oauth: tokens,
                createdAt: editingAccount.createdAt
            ))
        } else {
            try appState.addOAuthAccount(provider: provider, tokens: tokens, email: email)
            if !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let added = appState.accounts.first(where: {
                   $0.provider == provider && $0.email.caseInsensitiveCompare(email) == .orderedSame
               }) {
                var renamed = added
                renamed.displayName = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                try appState.updateAccount(renamed)
            }
        }
    }
}
