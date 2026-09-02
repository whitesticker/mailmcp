import SwiftUI

@main
struct MailMCPEntry {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPStdioServer.run()
        } else {
            MailMCPApp.main()
        }
    }
}

struct MailMCPApp: App {
    @ObservedObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup("MailMCP", id: "main") {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 860, minHeight: 560)
                .onOpenURL { url in
                    _ = OAuthBrowserFlow.handle(url: url)
                }
        }
        MenuBarExtra("MailMCP", systemImage: "envelope.fill") {
            MenuBarView()
                .environmentObject(appState)
        }
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
    }
}
