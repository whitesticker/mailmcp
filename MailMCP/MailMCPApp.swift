import AppKit
import SwiftUI

@main
struct MailMCPEntry {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPShim.run()
        } else {
            UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
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
                .onOpenURL { url in
                    _ = OAuthBrowserFlow.handle(url: url)
                }
        }
        .commands {
            SettingsCommands(appState: appState)
        }

        MenuBarExtra("MailMCP", systemImage: appState.mcpAgentCount > 0 ? "envelope.fill" : "envelope") {
            MenuBarView()
                .environmentObject(appState)
        }
    }
}

/// Replaces the default Settings… item so ⌘, opens the in-window Settings column.
private struct SettingsCommands: Commands {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                MailMCPAppDelegate.mainWindow()?.makeKeyAndOrderFront(nil)
                appState.pendingSettingsOpen = true
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(!appState.isUnlocked)
        }
        CommandGroup(replacing: .help) {}
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
            WindowMorphController.applyInitialSize(isUnlocked: AppState.shared.isUnlocked)
        }
    }

    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.canBecomeMain && window.identifier?.rawValue != "recent-calls"
        }
    }

    static func closeExtraMainWindows() {
        let mains = NSApp.windows.filter { window in
            window.canBecomeMain && window.identifier?.rawValue != "recent-calls"
        }
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
        if let window = Self.mainWindow() {
            window.makeKeyAndOrderFront(nil)
        }
        Self.closeExtraMainWindows()
        return true
    }
}

@MainActor
enum WindowMorphController {
    static let lockedSize = NSSize(width: 360, height: 420)
    static let unlockedSize = NSSize(width: 1240, height: 720)
    static let unlockedMinSize = NSSize(width: 1100, height: 560)

    static func applyInitialSize(isUnlocked: Bool) {
        guard let window = MailMCPAppDelegate.mainWindow() else { return }
        transition(window: window, toUnlocked: isUnlocked, animated: false)
    }

    static func transition(toUnlocked: Bool, animated: Bool = true) {
        guard let window = MailMCPAppDelegate.mainWindow() else { return }
        transition(window: window, toUnlocked: toUnlocked, animated: animated)
    }

    private static func transition(window: NSWindow, toUnlocked: Bool, animated: Bool) {
        let targetContentSize = toUnlocked ? unlockedSize : lockedSize
        if !toUnlocked {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.contentMinSize = lockedSize
            window.contentMaxSize = lockedSize
        } else {
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.isMovableByWindowBackground = false
            window.contentMinSize = unlockedMinSize
            window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }

        var targetFrameRect = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContentSize))
        if toUnlocked, let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            targetFrameRect.size.width = min(targetFrameRect.width, visible.width - 24)
            targetFrameRect.size.height = min(targetFrameRect.height, visible.height - 24)
        }
        let currentFrame = window.frame
        var newOrigin = NSPoint(
            x: round(currentFrame.midX - targetFrameRect.width / 2),
            y: round(currentFrame.midY - targetFrameRect.height / 2)
        )

        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            newOrigin.x = max(visible.minX + 12, min(newOrigin.x, visible.maxX - targetFrameRect.width - 12))
            newOrigin.y = max(visible.minY + 12, min(newOrigin.y, visible.maxY - targetFrameRect.height - 12))
        }

        let newFrame = NSRect(origin: newOrigin, size: targetFrameRect.size)
        window.setFrame(newFrame, display: true, animate: animated)
    }
}

private struct BehindWindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .fullScreenUI
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct LoginWindowGlass: ViewModifier {
    let active: Bool
    let success: Bool

    func body(content: Content) -> some View {
        content
            .containerBackground(for: .window) {
                if active {
                    ZStack {
                        BehindWindowBackdrop()
                        Color.green
                            .opacity(success ? 0.38 : 0)
                            .animation(.easeInOut(duration: 0.3), value: success)
                    }
                } else {
                    Color(nsColor: .windowBackgroundColor)
                }
            }
            .toolbarBackgroundVisibility(active ? .hidden : .automatic, for: .windowToolbar)
    }
}

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showWorkspace = false
    @State private var unlockTransitionTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if showWorkspace {
                ContentView()
                    .frame(minWidth: 1100, idealWidth: 1240, maxWidth: .infinity, minHeight: 560, idealHeight: 720, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                OnboardingView()
                    .frame(width: 360, height: 420)
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
            }
        }
        .modifier(LoginWindowGlass(active: !showWorkspace, success: appState.isUnlocked))
        .onAppear {
            showWorkspace = appState.isUnlocked
            DispatchQueue.main.async {
                WindowMorphController.applyInitialSize(isUnlocked: appState.isUnlocked)
            }
        }
        .onChange(of: appState.isUnlocked) { _, unlocked in
            unlockTransitionTask?.cancel()
            if unlocked {
                unlockTransitionTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled, appState.isUnlocked else { return }
                    WindowMorphController.transition(toUnlocked: true, animated: true)
                    // The split view must first lay out at full size; built mid-resize, its sidebar rows stay squeezed.
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled, appState.isUnlocked else { return }
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                        showWorkspace = true
                    }
                }
            } else {
                RecentCallsWindowController.shared.close()
                withAnimation(.easeInOut(duration: 0.22)) {
                    showWorkspace = false
                }
                WindowMorphController.transition(toUnlocked: false, animated: true)
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
        .sheet(isPresented: $appState.cacheLimitPromptVisible) {
            CacheLimitSheet()
                .environmentObject(appState)
        }
    }
}
