import SwiftUI

struct AddAccountView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var kind: MailProviderKind = .imap
    @State private var preset = IMAPPreset.all[0]
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var imapHost = ""
    @State private var imapPort = "993"
    @State private var smtpHost = ""
    @State private var smtpPort = "465"
    @State private var imapStartTLS = false
    @State private var smtpStartTLS = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Provider", selection: $kind) {
                ForEach(MailProviderKind.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)

            switch kind {
            case .imap:
                imapForm
            case .gmail:
                oauthCopy(
                    title: "Sign in with Google",
                    detail: "Uses an installed-app OAuth client (PKCE). Add your Google client ID in Settings, then continue here. Redirect URI: mailmcp://oauth/google"
                )
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
                Button(busy ? "Working…" : "Continue") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
            }
        }
        .padding(20)
        .navigationTitle("Add mailbox")
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

    private func oauthCopy(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                try saveIMAP()
            case .gmail:
                let config = try OAuthClient.google(clientID: appState.settings.googleClientID)
                let tokens = try await OAuthClient.signIn(config: config)
                let address = try await GmailUserInfo.email(tokens: tokens)
                try appState.addOAuthAccount(provider: .gmail, tokens: tokens, email: address)
            case .outlook:
                let config = try OAuthClient.microsoft(clientID: appState.settings.microsoftClientID)
                let tokens = try await OAuthClient.signIn(config: config)
                let address = try await GraphUserInfo.email(tokens: tokens)
                try appState.addOAuthAccount(provider: .outlook, tokens: tokens, email: address)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveIMAP() throws {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw MailMCPError.invalidInput("Email is required") }
        guard let imapPortValue = Int(imapPort), let smtpPortValue = Int(smtpPort) else {
            throw MailMCPError.invalidInput("Ports must be numbers")
        }
        let account = MailAccount(
            provider: .imap,
            email: address,
            displayName: address,
            imap: IMAPSettings(
                imapHost: imapHost.trimmingCharacters(in: .whitespacesAndNewlines),
                imapPort: imapPortValue,
                imapStartTLS: imapStartTLS,
                smtpHost: smtpHost.trimmingCharacters(in: .whitespacesAndNewlines),
                smtpPort: smtpPortValue,
                smtpStartTLS: smtpStartTLS,
                username: username.isEmpty ? address : username,
                password: password
            )
        )
        try appState.addIMAPAccount(account)
    }
}
