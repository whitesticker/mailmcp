import SwiftUI

struct MergeVaultView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(appState.pendingMerge?.isReplicaConflict == true
                 ? "Sync conflict"
                 : "Merge vault")
                .font(.title2.bold())
            Text("Choose current vs incoming for each difference. The incoming file is left unchanged. The result is encrypted with this vault’s key.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let session = appState.pendingMerge {
                if session.preview.isNoOp {
                    Text("No differences to merge.")
                } else {
                    Form {
                        if !session.preview.additions.isEmpty {
                            Section("Additions from incoming") {
                                ForEach(session.preview.additions) { account in
                                    Text("\(account.email) · \(account.provider.title)")
                                }
                            }
                        }
                        if !session.preview.onlyInCurrent.isEmpty {
                            Section("Only in current vault") {
                                ForEach(session.preview.onlyInCurrent) { account in
                                    Text("\(account.email) · \(account.provider.title)")
                                }
                            }
                        }
                        ForEach(session.preview.conflicts) { conflict in
                            Section(conflict.current.email) {
                                Picker("Choice", selection: choiceBinding(conflict.key)) {
                                    Text("Keep current").tag(MergeChoice.current)
                                    Text("Use incoming").tag(MergeChoice.incoming)
                                }
                                LabeledContent("Current nickname", value: conflict.current.displayName)
                                LabeledContent("Incoming nickname", value: conflict.incoming.displayName)
                                LabeledContent("Current protocol", value: conflict.current.provider.title)
                                LabeledContent("Incoming protocol", value: conflict.incoming.provider.title)
                            }
                        }
                        if session.preview.settingsDiffer {
                            Section("Vault settings") {
                                Picker("Settings", selection: settingsBinding) {
                                    Text("Keep current").tag(MergeChoice.current)
                                    Text("Use incoming").tag(MergeChoice.incoming)
                                }
                                Text("Safety mode, MCP tools, OAuth client IDs, and sync folder are compared as one group.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .formStyle(.grouped)
                }
            }

            HStack {
                Button("Cancel") {
                    appState.cancelMerge()
                    dismiss()
                }
                Spacer()
                Button("Apply merge") {
                    do {
                        try appState.applyPendingMerge()
                        dismiss()
                    } catch {
                        appState.errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appState.pendingMerge?.preview.isNoOp == true)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
    }

    private func choiceBinding(_ key: String) -> Binding<MergeChoice> {
        Binding(
            get: { appState.pendingMerge?.accountChoices[key] ?? .current },
            set: { appState.updateMergeChoice(accountKey: key, choice: $0) }
        )
    }

    private var settingsBinding: Binding<MergeChoice> {
        Binding(
            get: { appState.pendingMerge?.settingsChoice ?? .current },
            set: { appState.updateMergeSettingsChoice($0) }
        )
    }
}
