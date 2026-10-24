import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum LoginScreenMode: String, CaseIterable, Identifiable {
    case unlock
    case createNew

    var id: String { rawValue }
}

private struct ShakeGeometryEffect: GeometryEffect {
    var amount: CGFloat = 9
    var shakesPerUnit: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = amount * sin(animatableData * .pi * shakesPerUnit)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

private struct LoginGlassCard: ViewModifier {
    let highlight: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .overlay(rim(shape))
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(rim(shape))
                .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 6)
        }
    }

    @ViewBuilder
    private func rim(_ shape: RoundedRectangle) -> some View {
        if let highlight {
            shape.strokeBorder(highlight.opacity(0.55), lineWidth: 1.2)
        }
    }
}

private struct LoginGlassButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var mode: LoginScreenMode = .unlock
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var vaultName = "Personal"
    @State private var customVaultURL: URL?
    @State private var localError: String?
    @State private var unlockTarget: UUID?
    @State private var showPassword = false
    @State private var shakeTrigger = 0
    @State private var unlockedPulse = false
    @FocusState private var focusedField: Bool

    private let tealGlassTint = Color(red: 0.06, green: 0.56, blue: 0.62)

    private var isUnlockedSuccess: Bool {
        appState.isUnlocked || unlockedPulse
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)

            // Clean App Logo + Title + Status
            logoHeader

            Spacer(minLength: 16)

            // Translucent Liquid Glass Card
            VStack(spacing: 12) {
                switch mode {
                case .unlock:
                    unlockSection
                case .createNew:
                    createVaultSection
                }

                if let localError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption)
                        Text(localError)
                            .font(.caption)
                            .lineLimit(2)
                    }
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(18)
            .modifier(LoginGlassCard(highlight: cardHighlight))
            .modifier(ShakeGeometryEffect(animatableData: CGFloat(shakeTrigger)))
            .padding(.horizontal, 22)

            Spacer(minLength: 12)

            footerBar
                .padding(.bottom, 14)
        }
        .frame(width: 360, height: 420)
        .onAppear {
            unlockTarget = appState.registry.activeID ?? appState.registry.vaults.first?.id
            mode = appState.vaultExists ? .unlock : .createNew
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusedField = true
            }
        }
        .onChange(of: appState.isUnlocked) { _, unlocked in
            if unlocked {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.62)) {
                    unlockedPulse = true
                }
            } else {
                unlockedPulse = false
                passphrase = ""
            }
        }
    }

    // MARK: - Glass Layers

    private var cardHighlight: Color? {
        localError != nil ? .red : nil
    }

    private func liquidGlassWell(focused: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return ZStack {
            shape.fill(Color.primary.opacity(0.06))
            shape.strokeBorder(
                focused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.10),
                lineWidth: focused ? 1.4 : 0.8
            )
        }
    }

    // MARK: - Clean App Logo Header (No Outer Circle or Lock Badge)

    private var logoHeader: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 78, height: 78)
                .shadow(
                    color: (isUnlockedSuccess ? Color.green : Color.black).opacity(isUnlockedSuccess ? 0.35 : 0.22),
                    radius: isUnlockedSuccess ? 14 : 8,
                    x: 0,
                    y: 4
                )
                .scaleEffect(isUnlockedSuccess ? 1.10 : 1.0)
                .rotation3DEffect(
                    .degrees(isUnlockedSuccess ? 12 : 0),
                    axis: (x: 0, y: 1, z: 0)
                )
                .animation(.spring(response: 0.36, dampingFraction: 0.58), value: isUnlockedSuccess)

            Text("MailMCP")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            statusPill
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if isUnlockedSuccess {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                Text("Unlocked · \(appState.accounts.count) mailbox\(appState.accounts.count == 1 ? "" : "es")")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.green)
            .padding(.horizontal, 11)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.green.opacity(0.45), lineWidth: 1)
            )
            .transition(.scale.combined(with: .opacity))
        } else if appState.mcpAgentCount > 0 {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                Text("\(appState.mcpAgentCount) agent\(appState.mcpAgentCount == 1 ? "" : "s") connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8)
            )
        } else {
            Text("Unlock your vault to serve agents")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Unlock Section (with File Picker for Vault Selection)

    private var unlockSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            vaultSelectorButton

            passphraseField(placeholder: "Enter passphrase", text: $passphrase, onSubmit: unlock)

            liquidGlassActionButton(
                title: isUnlockedSuccess ? "Unlocked" : "Unlock",
                icon: isUnlockedSuccess ? "checkmark" : nil,
                disabled: passphrase.isEmpty || isUnlockedSuccess,
                action: unlock
            )
        }
    }

    private var vaultSelectorButton: some View {
        Button {
            pickVaultFile()
        } label: {
            vaultSelectorLabel
        }
        .buttonStyle(.plain)
        .help("Click to choose a .vault file")
    }

    private var vaultSelectorLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.fill")
                .font(.caption)
                .foregroundStyle(tealGlassTint)

            VStack(alignment: .leading, spacing: 1) {
                Text(currentVaultTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(currentVaultSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(liquidGlassWell(focused: false))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var currentVaultTitle: String {
        if let customVaultURL {
            return customVaultURL.deletingPathExtension().lastPathComponent
        }
        return selectedUnlockVault?.name ?? "Personal"
    }

    private var currentVaultSubtitle: String {
        if let customVaultURL {
            return customVaultURL.path
        }
        return selectedUnlockVault?.localPath ?? Paths.defaultVaultURL.path
    }

    // MARK: - Create New Vault Mode

    private var createVaultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Vault name (e.g. Personal)", text: $vaultName)
                .textFieldStyle(.plain)
                .foregroundStyle(.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(liquidGlassWell(focused: false))

            passphraseField(placeholder: "Choose passphrase (8+ chars)", text: $passphrase, onSubmit: create)

            SecureField("Confirm passphrase", text: $confirm)
                .textFieldStyle(.plain)
                .foregroundStyle(.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(liquidGlassWell(focused: false))
                .onSubmit { create() }

            liquidGlassActionButton(
                title: "Create & Unlock Vault",
                icon: nil,
                disabled: passphrase.isEmpty || confirm.isEmpty,
                action: create
            )
        }
    }

    // MARK: - Liquid Glass Passphrase Field & Action Button

    private func passphraseField(placeholder: String, text: Binding<String>, onSubmit: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Group {
                if showPassword {
                    TextField(placeholder, text: text)
                } else {
                    SecureField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .foregroundStyle(.primary)
            .focused($focusedField)
            .onSubmit(onSubmit)

            Button {
                showPassword.toggle()
            } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(showPassword ? "Hide passphrase" : "Show passphrase")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(liquidGlassWell(focused: focusedField))
    }

    private func liquidGlassActionButton(
        title: String,
        icon: String?,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption.bold())
                }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
        .modifier(LoginGlassButtonStyle())
        .controlSize(.large)
        .tint(isUnlockedSuccess ? .green : tealGlassTint)
        .disabled(disabled)
        .keyboardShortcut(.defaultAction)
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        HStack(spacing: 16) {
            if appState.vaultExists && mode != .unlock {
                Button("Back to Unlock") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        localError = nil
                        mode = .unlock
                    }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
            }

            Button("Open .vault file…") {
                pickVaultFile()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)

            if mode != .createNew {
                Button("New vault…") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        localError = nil
                        mode = .createNew
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Native File Selection Dialog & Unlock Actions

    private func pickVaultFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a MailMCP Vault File"
        panel.message = "Select a .vault file to open and unlock."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.item, .data]
        if let selected = selectedUnlockVault {
            panel.directoryURL = URL(fileURLWithPath: selected.localPath).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        localError = nil
        mode = .unlock
        let standardized = url.standardizedFileURL
        if let existing = appState.registry.vaults.first(where: {
            URL(fileURLWithPath: $0.localPath).standardizedFileURL == standardized
        }) {
            customVaultURL = nil
            unlockTarget = existing.id
        } else {
            customVaultURL = standardized
        }
        focusedField = true
    }

    private var selectedUnlockVault: VaultDescriptor? {
        if let unlockTarget {
            return appState.registry.descriptor(id: unlockTarget)
        }
        return appState.registry.active
    }

    private func triggerError(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            localError = message
        }
        withAnimation(.default) {
            shakeTrigger += 1
        }
    }

    private func create() {
        localError = nil
        guard passphrase.count >= 8 else {
            triggerError("Use at least 8 characters.")
            return
        }
        guard passphrase == confirm else {
            triggerError("Passphrases do not match.")
            return
        }
        do {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.60)) {
                unlockedPulse = true
            }
            try appState.createVault(passphrase: passphrase, name: vaultName)
        } catch {
            unlockedPulse = false
            triggerError(error.localizedDescription)
        }
    }

    private func unlock() {
        localError = nil
        do {
            if let customVaultURL {
                let accessed = customVaultURL.startAccessingSecurityScopedResource()
                defer { if accessed { customVaultURL.stopAccessingSecurityScopedResource() } }
                try appState.importVault(from: customVaultURL, passphrase: passphrase)
            } else {
                try appState.unlock(passphrase: passphrase, vaultID: unlockTarget)
            }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.60)) {
                unlockedPulse = true
            }
        } catch {
            unlockedPulse = false
            triggerError(error.localizedDescription)
        }
    }
}
