import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appState.isUnlocked ? "Vault unlocked" : "Vault locked")
                .font(.headline)
            Text("\(appState.accounts.count) mailbox\(appState.accounts.count == 1 ? "" : "es")")
                .foregroundStyle(.secondary)
            if !appState.pendingSends.isEmpty {
                Text("\(appState.pendingSends.count) send(s) waiting for confirmation")
                    .foregroundStyle(.orange)
            }
            Divider()
            Button("Open MailMCP") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            if appState.isUnlocked {
                Button("Lock vault") { appState.lock() }
            }
            Button("Install for Cursor") {
                try? appState.installCursorMCP()
            }
            Divider()
            Button("Add to an agent") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            Button("Settings") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(8)
        .frame(minWidth: 220)
    }
}
