import SwiftUI

struct AddAccountView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private let editingAccount: MailAccount?
    /// Shown inside the Settings panel rather than as a sheet: no Cancel, and the form resets after adding.
    private let inline: Bool
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
    @State private var syncScope = MailAccount.defaultSyncScope
    @State private var syncRecentCount = MailAccount.defaultSyncRecentCount
    @State private var syncDaysBack = 90
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?

    init(editingAccount: MailAccount? = nil, inline: Bool = false) {
        self.editingAccount = editingAccount
        self.inline = inline
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
        Form {
            Section {
                Picker("Provider", selection: $kind) {
                    ForEach(MailProviderKind.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(editingAccount != nil)
            }

            switch kind {
            case .imap:
                imapSection
            case .gmail:
                oauthSection(title: "Sign in with Google")
            case .outlook:
                oauthSection(
                    title: "Sign in with Microsoft",
                    detail: "Uses a public-client OAuth flow (the same PKCE pattern MSAL uses). Add your Azure app ID in Settings › OAuth. Redirect URI: mailmcp://oauth/microsoft"
                )
            }

            if editingAccount == nil {
                Section("Background sync") {
                    SyncPolicyPickers(scope: $syncScope, recentCount: $syncRecentCount, daysBack: $syncDaysBack)
                    Text(SyncPolicyPickers.explanation(for: syncScope) + " You can change this later in Mailbox Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if let notice {
                    Text(notice).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    if !inline {
                        Button("Cancel") { dismiss() }
                    }
                    Button(busy ? "Working…" : editingAccount == nil ? (kind == .imap ? "Add Account" : "Continue") : "Save changes") {
                        Task { await save() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(editingAccount == nil ? "Add an Account" : "Modify account")
        .onChange(of: preset) { _, newValue in
            apply(newValue)
        }
        .onChange(of: kind) { _, _ in
            error = nil
            notice = nil
        }
    }

    @ViewBuilder
    private var imapSection: some View {
        Section("Account") {
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
        }
        Section("Servers") {
            TextField("IMAP host", text: $imapHost)
            TextField("IMAP port", text: $imapPort)
            Toggle("IMAP STARTTLS (use off for implicit TLS on 993)", isOn: $imapStartTLS)
            TextField("SMTP host", text: $smtpHost)
            TextField("SMTP port", text: $smtpPort)
            Toggle("SMTP STARTTLS (use off for implicit TLS on 465)", isOn: $smtpStartTLS)
        }
    }

    private func oauthSection(title: String, detail: String? = nil) -> some View {
        Section(title) {
            if editingAccount == nil {
                TextField("Nickname (optional)", text: $nickname)
            }
            if let editingAccount {
                LabeledContent("Current account", value: editingAccount.email)
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func applySyncPolicy(to account: inout MailAccount) {
        account.syncScope = syncScope
        account.syncRecentCount = syncRecentCount
        account.syncDaysBack = syncDaysBack
    }

    /// Inline form: confirm and clear the fields so another account can be added.
    private func finish(added address: String) {
        guard inline else {
            dismiss()
            return
        }
        notice = "Added \(address). It’s now in the sidebar."
        nickname = ""
        email = ""
        username = ""
        password = ""
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
        notice = nil
        busy = true
        defer { busy = false }
        do {
            let added: String
            switch kind {
            case .imap:
                try await saveIMAP()
                added = email.trimmingCharacters(in: .whitespacesAndNewlines)
            case .gmail:
                let config = try OAuthClient.google(
                    clientID: appState.settings.googleClientID,
                    clientSecret: appState.settings.googleClientSecret
                )
                let tokens = try await OAuthClient.signIn(config: config)
                let address = try await GmailUserInfo.email(tokens: tokens)
                try saveOAuthAccount(provider: .gmail, tokens: tokens, email: address)
                added = address
            case .outlook:
                let config = try OAuthClient.microsoft(clientID: appState.settings.microsoftClientID)
                let tokens = try await OAuthClient.signIn(config: config)
                let address = try await GraphUserInfo.email(tokens: tokens)
                try saveOAuthAccount(provider: .outlook, tokens: tokens, email: address)
                added = address
            }
            if editingAccount == nil {
                finish(added: added)
            } else {
                dismiss()
            }
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
        var account = MailAccount(
            id: editingAccount?.id ?? UUID(),
            provider: .imap,
            email: address,
            displayName: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
            imap: settings,
            createdAt: editingAccount?.createdAt ?? Date()
        )
        if editingAccount == nil {
            applySyncPolicy(to: &account)
        }
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
            if let added = appState.accounts.first(where: {
                $0.provider == provider && $0.email.caseInsensitiveCompare(email) == .orderedSame
            }) {
                var configured = added
                let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedNickname.isEmpty {
                    configured.displayName = trimmedNickname
                }
                applySyncPolicy(to: &configured)
                try appState.updateAccount(configured)
            }
        }
    }
}

/// Policy picker shared by the add-mailbox sheet and Mailbox Settings (see docs/sync-retention.md).
struct SyncPolicyPickers: View {
    @Binding var scope: AccountSyncScope
    @Binding var recentCount: Int
    @Binding var daysBack: Int

    var body: some View {
        Picker("Policy", selection: $scope) {
            ForEach(AccountSyncScope.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        switch scope {
        case .recent:
            Picker("Inbox messages", selection: $recentCount) {
                Text("250").tag(250)
                Text("500").tag(500)
                Text("1,000 (Default)").tag(1000)
                Text("2,500").tag(2500)
                Text("5,000").tag(5000)
            }
        case .days:
            Picker("Days", selection: $daysBack) {
                Text("30 days").tag(30)
                Text("90 days (Default)").tag(90)
                Text("180 days").tag(180)
                Text("365 days").tag(365)
            }
        case .off, .everything:
            EmptyView()
        }
    }

    static func explanation(for scope: AccountSyncScope) -> String {
        switch scope {
        case .off:
            return "No background traffic. Only what you or an agent opens or searches is cached."
        case .recent:
            return "Keeps the newest Inbox messages cached, headers and bodies. Older mail stays cached until you free space."
        case .days:
            return "Keeps recent Inbox mail cached, headers and bodies. Older mail stays cached until you free space."
        case .everything:
            return "Caches every folder’s headers, plus text/HTML bodies when enabled. Attachments are never stored."
        }
    }
}
