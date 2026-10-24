import SwiftUI

/// Sends waiting for confirmation, shown in the window's middle column.
struct PendingSendsList: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(appState.pendingSends) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.subject.isEmpty ? "(No subject)" : item.subject)
                            .font(.headline)
                            .lineLimit(1)
                        Text("To: \(item.to.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 2)
                    .tag(item.id as UUID?)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// One pending send with its confirm / dismiss actions, shown in the window's detail column.
struct PendingSendDetail: View {
    @EnvironmentObject private var appState: AppState
    let selection: UUID?
    @State private var busyID: UUID?
    @State private var status: String?

    private var item: PendingSend? {
        appState.pendingSends.first { $0.id == selection } ?? appState.pendingSends.first
    }

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.subject.isEmpty ? "(No subject)" : item.subject)
                            .font(.title2.bold())
                            .textSelection(.enabled)
                        Text("To: \(item.to.joined(separator: ", "))")
                            .font(.callout)
                            .textSelection(.enabled)
                        Text("From: \(item.accountEmail)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Divider()
                        Text(item.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(20)
                }
                .toolbar {
                    ToolbarItemGroup {
                        Button {
                            Task { await confirm(item) }
                        } label: {
                            Label(busyID == item.id ? "Sending…" : "Confirm Send", systemImage: "paperplane")
                        }
                        .help("Send this message")
                        .disabled(busyID != nil)
                        Button(role: .destructive) {
                            appState.removePending(id: item.id)
                        } label: {
                            Label("Dismiss", systemImage: "xmark")
                        }
                        .help("Discard this send without sending")
                    }
                }
            } else {
                Text("No outbound mail waiting for confirmation.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottom) {
            if let status {
                Text(status)
                    .padding(8)
                    .background(.thinMaterial)
            }
        }
    }

    private func confirm(_ item: PendingSend) async {
        busyID = item.id
        defer { busyID = nil }
        do {
            _ = try await appState.confirmPendingSend(item)
            status = "Sent."
        } catch {
            status = error.localizedDescription
        }
    }
}
