import SwiftUI

@main
struct MailMCPEntry {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPShim.run()
        } else {
            MailMCPApp.main()
        }
    }
}

struct MailMCPApp: App {
    @NSApplicationDelegateAdaptor(MailMCPAppDelegate.self) private var appDelegate
    @ObservedObject private var appState = AppState.shared

    var body: some Scene {
        Window("MailMCP", id: "main") {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 860, minHeight: 560)
                .onOpenURL { url in
                    _ = OAuthBrowserFlow.handle(url: url)
                }
        }
        MenuBarExtra("MailMCP", systemImage: appState.mcpAgentCount > 0 ? "envelope.fill" : "envelope") {
            MenuBarView()
                .environmentObject(appState)
        }
    }
}

final class MailMCPAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            KeychainWrap.purgeKnownItems(vaultIDs: AppState.shared.registry.vaults.map(\.id))
        }
        MCPSocketHost.shared.start()
        DispatchQueue.main.async {
            Self.closeExtraMainWindows()
        }
    }

    static func closeExtraMainWindows() {
        let mains = NSApp.windows.filter { $0.canBecomeMain }
        for extra in mains.dropFirst() {
            extra.close()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MCPSocketHost.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let state = AppState.shared
            if state.isTerminatingFromMenuBar || !state.keepRunningOnCommandQ {
                return .terminateNow
            }
            for window in NSApp.windows where window.canBecomeMain {
                window.close()
            }
            state.noteCommandQParked()
            return .terminateCancel
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = NSApp.windows.first(where: \.canBecomeMain) {
            window.makeKeyAndOrderFront(nil)
        }
        Self.closeExtraMainWindows()
        return true
    }
}

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.isUnlocked {
                ContentView()
            } else {
                OnboardingView()
            }
        }
        .alert("Error", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .alert("Vault conflict", isPresented: Binding(
            get: { appState.conflictMessage != nil },
            set: { if !$0 { appState.conflictMessage = nil } }
        )) {
            Button("OK", role: .cancel) { appState.conflictMessage = nil }
        } message: {
            Text(appState.conflictMessage ?? "")
        }
        .sheet(item: $appState.pendingMerge) { _ in
            MergeVaultView()
                .environmentObject(appState)
        }
    }
}
