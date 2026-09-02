import SwiftUI

struct PendingSendsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var busyID: UUID?
    @State private var status: String?

    var body: some View {
        Group {
            if appState.pendingSends.isEmpty {
                Text("No outbound mail waiting for confirmation.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appState.pendingSends) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.subject).font(.headline)
                        Text("To: \(item.to.joined(separator: ", "))")
                            .font(.caption)
                        Text(item.accountEmail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.body)
                            .font(.callout)
                            .lineLimit(6)
                        HStack {
                            Button(busyID == item.id ? "Sending…" : "Confirm send") {
                                Task { await confirm(item) }
                            }
                            .disabled(busyID != nil)
                            Button("Dismiss", role: .destructive) {
                                appState.removePending(id: item.id)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Pending sends")
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
