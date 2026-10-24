import SwiftUI

/// Prompt shown when the cache goes over its limit (docs/sync-retention.md).
struct CacheLimitSheet: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let usedBytes = appState.cacheUsedBytes()
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "externaldrive.fill.badge.exclamationmark")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mail cache is over its limit")
                        .font(.headline)
                    Text(summary(usedBytes: usedBytes))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            FreeSpaceControls(secondaryTitle: "Remind Me Later") {
                appState.remindAboutCacheLimitLater()
            } onFreed: {
                appState.cacheLimitPromptVisible = false
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func summary(usedBytes: Int64) -> String {
        let used = FreeSpaceControls.format(usedBytes)
        let limit = appState.settings.cachePolicy.cacheLimitBytes.map(FreeSpaceControls.format) ?? "—"
        return "MailMCP is using \(used) of its \(limit) limit and keeps caching new mail. Nothing is deleted automatically; choose how much to free."
    }
}

/// Slider plus button that removes the least recently used cached mail. Used in the over-limit prompt
/// and inline in Settings › Cache. Only the local copies are removed; nothing changes on the server.
struct FreeSpaceControls: View {
    @EnvironmentObject private var appState: AppState
    var secondaryTitle: String?
    var onSecondary: (() -> Void)?
    var onFreed: (() -> Void)?

    @State private var amountMB: Double = 0
    @State private var usedBytes: Int64 = 0
    @State private var working = false
    @State private var loaded = false

    private static let stepMB: Double = 100

    private var usedMB: Double { Double(usedBytes) / 1_000_000 }
    /// `Slider` traps when its bounds are equal, so the range always spans at least two steps.
    private var range: ClosedRange<Double> {
        let upper = max((usedMB / Self.stepMB).rounded(.up) * Self.stepMB, Self.stepMB * 2)
        return Self.stepMB...upper
    }
    private var canFree: Bool { loaded && usedMB >= Self.stepMB && !working }
    private var amountBytes: Int64 { Int64(amountMB * 1_000_000) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if loaded && usedMB < Self.stepMB {
                Text("The cache is using \(Self.format(usedBytes)), so there is nothing worth freeing yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Free up")
                    Spacer()
                    Text(Self.format(amountBytes)).monospacedDigit()
                    Text("· about \(Self.format(max(usedBytes - amountBytes, 0))) left")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $amountMB, in: range, step: Self.stepMB)
                    .disabled(!canFree)
            }
            Text("Removes the local copies of the least recently opened mail. Nothing changes on the server, and removed mail is downloaded again the next time you or an agent need it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text("Freeing space…").foregroundStyle(.secondary)
                }
                Spacer()
                if let secondaryTitle {
                    Button(secondaryTitle) { onSecondary?() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(working)
                }
                Button("Free Up \(Self.format(amountBytes))") {
                    working = true
                    Task {
                        await appState.freeCacheSpace(bytes: amountBytes)
                        working = false
                        load()
                        onFreed?()
                    }
                }
                .disabled(!canFree)
            }
        }
        .onAppear(perform: load)
        .onChange(of: appState.cacheRevision) { _, _ in
            if !working { load() }
        }
    }

    private func load() {
        usedBytes = MailboxCacheStore.shared.usedBytes()
        let suggestedBytes: Int64
        if let limit = appState.settings.cachePolicy.cacheLimitBytes, usedBytes > limit {
            // Bring the cache back under the limit with 10% headroom.
            suggestedBytes = usedBytes - limit + limit / 10
        } else {
            suggestedBytes = min(1_000_000_000, usedBytes / 4)
        }
        let suggestedMB = (Double(suggestedBytes) / 1_000_000 / Self.stepMB).rounded(.up) * Self.stepMB
        amountMB = min(max(suggestedMB, range.lowerBound), range.upperBound)
        loaded = true
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
